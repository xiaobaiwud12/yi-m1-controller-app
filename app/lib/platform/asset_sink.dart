import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../sync/asset_sink_contract.dart';
import '../sync/sync_ledger.dart';
import 'media_store_bridge.dart';

// `AssetSink` and `NullAssetSink` live in `sync/asset_sink_contract.dart`, which
// has no Flutter dependency, so the sync engine can be driven offline. This file
// is the Android implementation and is allowed to use Flutter and `dart:io` —
// which is why it lives in `platform/` rather than in `sync/`.

/// Stores transferred files in the phone's **shared** media store.
///
/// ## What this replaced, and why the old approach could not work
///
/// An earlier version wrote into `getExternalStorageDirectory()` — i.e.
/// `Android/data/<package>/files/Pictures/…` — and then shelled out to
/// `am broadcast … MEDIA_SCANNER_SCAN_FILE` to have it indexed. Its own comment
/// claimed the directory was "visible in the gallery after scanning". It is not,
/// and the scanner is not either:
///
/// * **Android 11+ hides `Android/data/` from other apps.** The gallery has no
///   read access at all, so a synced photo was invisible exactly where the user
///   looks for it. This was a shipping defect in the app's headline feature.
/// * **`MEDIA_SCANNER_SCAN_FILE` does nothing on Android 10+** — the receiver is
///   not exported — and `am` cannot be executed by an app at all, because that
///   needs `android.permission.DUMP`, which is signature-level and can never be
///   granted. The failure was swallowed by `catchError`, so nothing ever said so.
///
/// MediaStore is the sanctioned route: it needs **no runtime permission** on any
/// supported release, because the app inserts its own contributions.
///
/// ## Why the previous objection to MediaStore was wrong
///
/// The old comment rejected MediaStore because "`ContentResolver.insert` with
/// `IS_PENDING` renames the asset, which breaks the `path`+`date` identity".
/// Both halves are false:
///
/// * the filename is supplied through `DISPLAY_NAME` and is preserved — a suffix
///   appears only on a genuine collision, which for this camera means two different
///   shots sharing a name; and
/// * identity is not the filename anyway. `AssetGroup` pairs a RAW+JPEG shot by the
///   **name stem**, so `YI000123.JPG` beside `YI000123.DNG` still pairs — and the
///   synced-set identity is `AssetId.key` (`path|captureSeconds`), which is not the
///   display name at all. (A `syncKey` getter used to be named here; it was removed as
///   dead code in `analysis/79` #17 — see `AlbumFile`.) The camera's own naming is what
///   makes the stem pairing work, which is precisely why it must be preserved.
///
/// ## Capture date (T15) — and exactly what is set, and what is not
///
/// The bytes are the camera's own file and are written verbatim, so nothing here
/// decodes or re-encodes them, and this class never reads or rewrites a metadata
/// tag — re-encoding is how apps "ruin" photos, and it is not needed to fix the
/// sort order.
///
/// The one thing the bytes are not, as they arrive from the camera, is *dated
/// correctly*: the body writes a naive local wall clock from a clock that has no
/// timezone, so a photo the app displays as 18:40 reached the gallery as 10:40 on
/// a phone at +08:00. `SyncEngine` rewrites that field, in place, to the instant
/// it also hands over here — `exif_wall_clock.dart` has the mechanism, the
/// evidence and the bounds. **By the time bytes reach this class the date inside
/// them is already the one the app shows.**
///
/// What would still be wrong without help is the date the *index* carries, which is
/// "when the phone wrote the file" — so a 2019 photo synced today files under
/// today. With a scan there was an mtime to set first; with MediaStore there is no
/// scan, so the instants are handed over explicitly as `DATE_ADDED`,
/// `DATE_MODIFIED` and `DATE_TAKEN` at insert time. That is strictly more reliable
/// than the mtime route, which depended on the scanner reading the file after the
/// timestamp had been applied.
///
/// * **Covered:** `DATE_ADDED` / `DATE_MODIFIED` / `DATE_TAKEN` — what galleries
///   and pickers sort and group on.
/// * **Covered, indirectly:** `DATE_TAKEN` is *also* derived by MediaProvider from
///   the image's own EXIF, and that is now the right value rather than the camera's
///   GMT rendering of it — which is the half that a sort-order test cannot see.
/// * **Not covered:** a file with no EXIF and no camera-supplied date. The instant
///   is then a claim backed only by the camera's listing, which is the right trade
///   for a photo and is the only clock that was present.
/// * **Not covered:** anything that read the date earlier and cached it. Nothing
///   on the phone can fix those.
class MediaStoreSink implements AssetSink {
  /// Where synced assets appear. `DCIM` because that is what "sync to the phone's
  /// gallery" means to every other camera app, and it keeps the M1's files
  /// distinguishable from screenshots and downloads.
  static const folder = 'DCIM/YI M1/';

  /// Fallback for hosts with no media bridge (tests, desktop).
  final _fallback = _FileFallback();

  /// URI per `assetKey|quality`, for the UI and for tests to assert.
  final _uris = <String, String>{};
  final _warnings = <String>[];

  /// Whether the shared media store was unreachable, so the bytes went somewhere
  /// the gallery cannot see.
  ///
  /// Recorded rather than assumed: the sink still stores the file, but the user
  /// must be told, because a silent fall back to an invisible directory is the
  /// exact defect this class was rewritten to remove.
  bool _usedFallback = false;
  bool get usedFallback => _usedFallback;

  /// Non-fatal complaints, in order. Surfaced in the UI rather than logged away.
  List<String> get warnings => List.unmodifiable(_warnings);

  Map<String, String> get storedUris => Map.unmodifiable(_uris);

  @override
  Future<String> store({
    required String assetKey,
    required String fileName,
    required Uint8List bytes,
    required AssetQuality quality,
    DateTime? capturedAt,
  }) async {
    // Previews and thumbnails get a distinct name so an upgrade never overwrites
    // the rendition the gallery is currently showing, and so a stale preview is
    // obvious rather than masquerading as the original.
    final suffix = switch (quality) {
      AssetQuality.original => '',
      AssetQuality.preview => '.preview.jpg',
      AssetQuality.thumbnail => '.thumb.jpg',
      // `none` means "not fetched yet", so `store` must never be handed it. The
      // old switch fell through to the empty suffix here, which would have written
      // an unfetched rendition over the original's name — a loud failure is the
      // right answer for a caller that has lost track of what it holds.
      AssetQuality.none => throw ArgumentError.value(
          quality,
          'quality',
          'store() cannot store a rendition that has no quality; '
              'AssetQuality.none means "nothing fetched yet"',
        ),
    };
    final displayName = '$fileName$suffix';

    // Only the original carries the capture date. A preview is a temporary
    // rendition that will be superseded, and dating it would make two rows claim
    // the same shutter press.
    final when = quality == AssetQuality.original ? capturedAt : null;
    // Kept, not leftover debug: the date is the one field whose loss is **invisible**
    // from the app. The grid and the ledger both look right whether or not the
    // capture instant survives the trip into MediaStore, and it was silently dropped
    // twice — once at insert, once when the publish scan re-derived it. This line is
    // what makes that class of failure visible next time. Prefixed like `[sync]` and
    // `[ble]`.
    debugPrint('[media] $displayName (${quality.name}) '
        'capturedAt=${when?.toIso8601String() ?? "none"}');

    final entry = await MediaStoreBridge.store(
      bytes: bytes,
      displayName: displayName,
      mimeType: mimeFor(displayName),
      relativePath: folder,
      capturedAt: when,
    );

    if (entry.ok) {
      // A `content://` URI is the only proof the photo is in the shared library.
      // Anything else — an app-private path, an empty string — is readable by this
      // app alone, so recording it as the original is how a sync drew a tick for a
      // photo the user could not find. The native side now also refuses to report
      // success until the pending row is published; this is the Dart half of the
      // same contract, so neither layer can quietly reintroduce it.
      if (!entry.uri.startsWith('content://')) {
        _usedFallback = true;
        _warnings.add('$displayName: not a content URI (${entry.uri})');
        throw StateError(
            'MediaStore returned "${entry.uri}", which the gallery cannot see, '
            'for $displayName');
      }
      if (entry.error != null) _warnings.add('$displayName: ${entry.error}');
      _uris['$assetKey|${quality.name}'] = entry.uri;
      return entry.uri;
    }

    // Do not report an app-private fallback as a gallery success. The old path
    // made the sync ledger mark an invisible file as done, so tapping Download
    // appeared to work while the system gallery stayed empty. Fail the transfer
    // so it can be retried or explained to the user.
    _usedFallback = true;
    _warnings.add('$displayName: ${entry.error ?? "media store unavailable"}');
    throw StateError(
        'MediaStore did not publish $displayName: ${entry.error ?? "unknown error"}');
  }

  @override
  Future<void> replace(String localId, Uint8List bytes) async {
    // Nothing to do: an upgrade writes the original under a *different* name, and
    // the preview is left in place because deleting it the moment the upgrade
    // lands can race the gallery's own read of the row it is displaying. The
    // ledger decides which rendition is authoritative; the stale preview is a
    // cosmetic cost the album grid already accounts for.
  }

  /// Remove a stored asset, when the user deletes it from the app as well.
  ///
  /// Without this, deleting a shot leaves the phone's copy behind and the album
  /// grid and the system gallery disagree about what exists.
  Future<bool> remove(String localId) async {
    if (localId.isEmpty) return false;
    if (!localId.startsWith('content://')) return _fallback.remove(localId);
    final ok = await MediaStoreBridge.delete(localId);
    if (ok) _uris.removeWhere((_, v) => v == localId);
    return ok;
  }

  /// Open a stored asset in another app.
  Future<bool> open(String localId) =>
      MediaStoreBridge.open(localId, mimeFor(localId));

  /// Hand stored assets to the system share sheet.
  Future<bool> share(List<String> localIds, {String? title}) {
    if (localIds.isEmpty) return Future.value(false);
    // A mixed selection has to be shared as `*/*`, because a share intent carries
    // one type. Guessing the first item's type instead would make a JPEG+MP4
    // selection fail in whichever app only accepts video.
    final types = localIds.map(mimeFor).toSet();
    final mime = types.length == 1 ? types.first : '*/*';
    return MediaStoreBridge.share(localIds, mimeType: mime, title: title);
  }

  /// The MIME type implied by a filename or a `content://` URI.
  ///
  /// Delegates to the shared, Flutter-free [mimeTypeForName] so there is exactly
  /// one table. The native side has its own copy (`MediaKind` in Kotlin) for the
  /// store call, and both are pinned by tests.
  static String mimeFor(String nameOrUri) => mimeTypeForName(nameOrUri);
}

/// A plain-file fallback for hosts without the media bridge.
///
/// Deliberately **not** the primary path any more. It exists so a test or a
/// desktop run still produces bytes on disk, and [MediaStoreSink.usedFallback]
/// records that it was used.
class _FileFallback {
  Directory? _root;

  Future<Directory> _dir() async {
    final cached = _root;
    if (cached != null) return cached;
    final base = await getExternalStorageDirectory() ??
        await getApplicationDocumentsDirectory();
    final d = Directory('${base.path}${Platform.pathSeparator}YI M1');
    if (!await d.exists()) await d.create(recursive: true);
    _root = d;
    return d;
  }

  Future<String> store({
    required String assetKey,
    required String fileName,
    required Uint8List bytes,
    DateTime? capturedAt,
  }) async {
    final dir = await _dir();
    final f = File('${dir.path}${Platform.pathSeparator}$fileName');
    await f.writeAsBytes(bytes, flush: true);
    // Still worth setting: a file manager reads the directory entry even where a
    // gallery cannot reach the directory at all.
    if (capturedAt != null) await setCaptureTime(f, capturedAt);
    return f.path;
  }

  Future<bool> remove(String path) async {
    try {
      final f = File(path);
      if (!await f.exists()) return false;
      await f.delete();
      return true;
    } on Object {
      return false;
    }
  }

  /// Make [capturedAt] the file's modification time.
  ///
  /// Returns whether a timestamp was applied, and never throws: a photo with a
  /// stale date is a sorting nuisance, whereas failing the transfer to protect it
  /// would be a lost photo.
  static Future<bool> setCaptureTime(File f, DateTime capturedAt) async {
    final when = capturedAt.toUtc();
    // Below this, a "capture date" is a broken clock rather than a date: the
    // firmware reports `0` when it does not know, and the Unix epoch as a file
    // timestamp sorts a photo to 1970 — a worse lie than "today" because it also
    // looks deliberate.
    if (when.isBefore(DateTime.utc(1990))) return false;
    try {
      await f.setLastModified(when);
      return true;
    } on Object catch (e) {
      debugPrint('could not date ${f.path} from the capture time ($e)');
      return false;
    }
  }
}
