import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// How much of the phone the album's thumbnails may occupy, on disk.
///
/// ## Why this number
///
/// A grid thumbnail is **one request of a few KB** (measured on the real body:
/// `analysis/50` §2, reproduced in `analysis/61` §1 — a `.JPG` at `Thumbnail` answers
/// `200` with 3,552 B and 6,785 B in the two samples). At the larger measured cost, a
/// full **1000-shot card is `kThousandShotCardBytes`**, and this cap holds one with room over.
///
/// **The bound that matters is the card, because the card is the feature.** The maintainer
/// asked for this cache because *"every time I connect and open the album the thumbnails
/// reload"* — so a cap that forces a large card to re-fetch most of itself has given back
/// what the cache was built to save, and on a **single-threaded camera** each of those is a
/// request competing with the live view (`AGENTS.md` §4 item 6).
///
/// ## The bound that was argued here before, and why it is gone
///
/// The previous justification was *"the cap has to be smaller than one photograph, so a
/// cache for 170dp pictures can never become a place originals are kept"* — argued from
/// **9.4 MB**, a figure that was never measured (`analysis/79` #19/#20). The real
/// `Original` is **4,897,837 B** (`analysis/50` §2), so at 8 MiB the sentence was false;
/// the inflated number is what hid it.
///
/// **It was then replaced with 2 MiB to make the sentence true, and that traded the wrong
/// thing.** The two claims are arithmetically incompatible — a cap under one 4.9 MB
/// photograph cannot also be over a 6.8 MB card — and the smaller one preserves a rule
/// about **8 MB of a reclaimable cache directory** at the cost of re-fetching **~705 tiles
/// on a 1000-shot card**, every session. Being under one photograph protects nothing a user
/// would notice; holding the card is what they asked for.
///
/// **What actually bounds this cache is that it is bounded** — growth is capped, eviction
/// is oldest-fetched first, entries over `kThumbMaxEntryBytes` are never kept, only
/// successes are written, and the whole directory is one Android can reclaim. That is the
/// property to keep, and it does not need a number smaller than a photograph to hold.
const int kAlbumThumbnailCacheMaxBytes = 8 * 1024 * 1024;

/// The largest single response worth keeping: a thumbnail, or the `MidThumb` the
/// viewer asks for.
///
/// **The size is a declared measurement, not a round number.** This said "~186 KB,
/// measured — `album_page.dart`'s `AssetViewerPage` note", and neither half held: 186 KB
/// is not a measurement this tree contains, and the note it cited was itself an
/// unmeasured assertion (`analysis/79` #20). The two recorded `MidThumb` responses are
/// **106,375 B and 196,495 B** (`analysis/50` §2, `analysis/61` §1) — 106 KB and 196 KB,
/// a factor of nearly two apart, which is the actual reason this limit is a *shape*
/// (one small rendition) rather than a size.
///
/// Deliberately **not** unbounded. The grid's chain is
/// `Thumbnail → MidThumb → Original`, and for a file with no small rendition it
/// therefore reaches the original: 4.9–5.6 MB for a JPEG, 31.9 MB for a `.DNG`
/// (`measured_sizes.dart`). Three of those would evict a whole card's worth of thumbnails
/// to store pictures that are not thumbnails. A tile drawn from such a response still
/// shows the picture in memory — it is simply not persisted, and the next visit asks
/// the camera again.
const int kAlbumThumbnailCacheMaxEntryBytes = 512 * 1024;

/// The album grid's thumbnails, on disk, so opening the album twice does not fetch
/// them twice.
///
/// ## The report this exists for
///
/// *"Every time I connect the camera and open the album the thumbnails reload — is that
/// necessary?"* It is not. And the cost is not only the wait: this camera is a
/// **single-threaded HTTP server with no watchdog** (`AGENTS.md` §4.6), and while the
/// live view is streaming, every thumbnail request competes with the preview — which is
/// why three rules in this project exist at all (`analysis/37`–`39`). Browsing the album
/// with the preview running is the worst case, so re-fetching a picture the phone
/// already holds is pressure the feature should be removing, not adding.
///
/// ## One file per entry, in the app's own cache directory
///
/// Not a single JSON file with base64 thumbnails. The established stores
/// (`FilePairingStore`, `FileSyncStore`) are single files written whole and renamed into
/// place, and that shape is wrong for this payload: a measured 1000-shot card of
/// thumbnails is **6.8 MB** (`kMeasuredCardOfThumbnailsBytes`), and a whole-file rewrite
/// **per thumbnail** would be gigabytes of writes to fill one album. One small file per
/// entry makes each write a few KB and each read one file.
///
/// The directory is the app's **cache** directory (`getApplicationCacheDirectory`,
/// wired in `lib/platform/thumbnail_cache.dart`) rather than its documents directory,
/// and deliberately: this is disposable by construction. Android may reclaim it under
/// storage pressure, and the failure mode when it does is that the next visit fetches
/// from the camera — i.e. exactly today's behaviour. Nothing the user would miss lives
/// here.
///
/// ## The key
///
/// [AlbumFile] shots are identified by `path|captureSeconds` — the same pair the grid's
/// tiles are keyed by (`album-tile-<path>|<dateSeconds>`, `AssetId.key`), reused rather
/// than reinvented. Two consequences, both wanted:
///
/// * a file **re-shot to the same name** has a new capture second and is therefore a
///   different entry, so a stale picture cannot be served for a new photo;
/// * the **path** dominates the key, so camera-clock weirdness (this camera has no RTC
///   and is set from the phone on connect — see `sync_ledger.dart`) can only cost a
///   cache *hit*, never produce a wrong picture.
///
/// The key is written into the entry as a header line, not only hashed into its name: a
/// hash collision, a leftover file, or any other damage then reads as a **miss** rather
/// than as somebody else's photograph. That is the whole reason the header exists.
///
/// ## What is never written
///
/// Only successful bytes, and only if they are a picture: [put] refuses an empty body, a
/// body that is not a JPEG, and anything past [kAlbumThumbnailCacheMaxEntryBytes]. **A
/// failure is never cached.** A `.DNG` with no thumbnail and a request that failed to
/// arrive are different facts, and only the first is a property of the file — so
/// `_thumbFailed` in the album page stays memory-only, and a tile that failed once is
/// asked for again on the next visit rather than becoming a permanent blank.
///
/// ## What invalidates an entry, and what does not
///
/// Invalidated by: a re-shot file (new second), a re-named file, a card whose clock
/// moved, the cap ([kAlbumThumbnailCacheMaxBytes]), the OS reclaiming the cache
/// directory, and a delete the app itself performed (the album page removes the entry
/// for every shot a fresh listing confirmed gone).
///
/// **Not** invalidated by: a delete performed *outside* the app followed by a
/// same-named file written inside the **same second**. That needs the same path, the
/// same absolute second, and different bytes; the app cannot see it and does not try.
/// The realistic half of it — the app's own delete — is handled, because that is the
/// half the app can know about.
///
/// Writing is `tmp` + rename, like `FileSyncStore`, so a kill mid-write cannot leave a
/// truncated entry behind. Nothing is read at startup and nothing is scanned at startup:
/// a read is one file, so the launch path gains no work and no new asynchronous gap.
class AlbumThumbnailCache {
  AlbumThumbnailCache({
    required Future<Directory> Function() directory,
    this.maxBytes = kAlbumThumbnailCacheMaxBytes,
    this.maxEntryBytes = kAlbumThumbnailCacheMaxEntryBytes,
    void Function(String message)? onLog,
  })  : _resolve = directory,
        _onLog = onLog;

  /// The header's first token, and this format's version.
  ///
  /// Checked on every read, so an entry written by a future format — or by nothing to
  /// do with this app — is a miss rather than bytes handed to an image decoder.
  static const String magic = 'YI-THUMB 1';

  /// The subdirectory created inside whatever directory the app hands over, so the
  /// cache's files are never mixed with anything else that lives in the app's cache.
  static const String directoryName = 'album_thumbs';

  static const String suffix = '.bin';
  static const String _tmpSuffix = '.tmp';

  final Future<Directory> Function() _resolve;

  /// The cap this instance enforces. Injectable so the eviction path can be exercised
  /// with a few kilobytes instead of eight megabytes.
  final int maxBytes;

  /// The largest single entry this instance will keep.
  final int maxEntryBytes;

  final void Function(String message)? _onLog;

  Directory? _root;

  /// Bytes currently held, or null until the directory has been measured once.
  ///
  /// ## Why this is a running total and not a scan per write
  ///
  /// The fetch loop is **serial**: a directory listing on every `put` would insert
  /// `O(entries)` stats between one thumbnail and the next, on a card where that loop is
  /// already the slow part. The directory is scanned only when the total has to be
  /// trusted — once, and then whenever the cap is crossed and victims have to be found.
  int? _bytes;

  bool _readFailureLogged = false;
  bool _writeFailureLogged = false;

  /// Where one entry lives.
  ///
  /// Exposed for diagnostics and because a check has to be able to damage an entry on
  /// purpose to show what the header gate does with it.
  Future<File> entryFile(String key) async => _fileFor(await _dir(), key);

  /// The entry's file name: FNV-1a 32 of the whole key, so a camera path (which contains
  /// `/`, `.` and `|`) needs no escaping and every name is one fixed length.
  ///
  /// A **published** function rather than `String.hashCode`, which is not promised to be
  /// stable across runs; `tool/verify_transport.dart` pins it against the published test
  /// vectors, so the names on a device are reproducible from the key alone.
  static String entryName(String key) {
    var hash = 0x811c9dc5;
    for (final unit in key.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return 't${hash.toRadixString(16).padLeft(8, '0')}$suffix';
  }

  /// The bytes for [key], or null.
  ///
  /// **Never throws**, whatever is wrong with the directory, the file or its contents: a
  /// cache that can break the grid it accelerates is worse than no cache, and "I could
  /// not read it" and "I never had it" lead to the same correct action — ask the camera.
  ///
  /// ## One `open`, and no `exists()` in front of it
  ///
  /// A probe followed by a read is two round trips to the file system for one answer, and
  /// this call sits **on the grid's serial loop** — every await here is time the next tile
  /// waits. A missing file is what the read itself reports, and it is the *common* case on
  /// a first visit, so it must not be logged as a failure either.
  Future<Uint8List?> read(String key) async {
    try {
      final file = _fileFor(await _dir(), key);
      final Uint8List raw;
      try {
        raw = await file.readAsBytes();
      } on FileSystemException {
        // No entry under this key (or it went away between sessions): a miss.
        return null;
      }
      final end = raw.indexOf(0x0A);
      if (end <= 0) return null;
      // The identity gate: this entry must say it is the one that was asked for.
      if (String.fromCharCodes(raw, 0, end) != _header(key)) return null;
      if (end + 1 >= raw.length) return null;
      final body = Uint8List.sublistView(raw, end + 1);
      // Belt as well as braces: only a picture was ever written, and only a picture may
      // reach `Image.memory` — a zero-byte or truncated body is the phone's own
      // `FlutterImageDecoderImplDefault: Failed to decode image`.
      if (!_isPicture(body)) return null;
      return body;
    } on Object catch (e) {
      _logRead('could not read $key ($e)');
      return null;
    }
  }

  /// Store [bytes] for [key]. Returns whether they were kept.
  ///
  /// Refuses — without writing anything — an empty body, a body that is not a JPEG, and
  /// a body larger than [maxEntryBytes]. Callers must not treat `false` as an error:
  /// it is the normal outcome for a `.DNG`'s full-size original and for anything the
  /// camera mangled.
  Future<bool> put(String key, Uint8List bytes) async {
    if (bytes.length > maxEntryBytes) return false;
    if (!_isPicture(bytes)) return false;

    Directory dir;
    File file;
    try {
      dir = await _dir();
      file = _fileFor(dir, key);
    } on Object catch (e) {
      _logWrite('could not resolve the cache directory ($e)');
      return false;
    }

    final tmp = File('${file.path}$_tmpSuffix');
    try {
      final body = BytesBuilder(copy: false)
        ..add(utf8.encode('${_header(key)}\n'))
        ..add(bytes);
      final entry = body.takeBytes();
      await tmp.writeAsBytes(entry, flush: true);
      await tmp.rename(file.path);
      // ## A running estimate, re-derived the moment it matters
      //
      // No `exists()`/`length()` probe for a previous version of this key: two more round
      // trips to the file system on the grid's serial loop, to keep an estimate exact in a
      // case that is now rare (a key is rewritten only when a shot is fetched again, and a
      // cache hit means it is not). The estimate is exact after [_measure], and [_evict]
      // recomputes it from the directory — so an overwrite can only make eviction happen
      // *earlier*, never later, and never past the cap.
      _bytes = (_bytes ?? (await _measure(dir)).bytes) + entry.length;
    } on Object catch (e) {
      _logWrite('could not write $key ($e)');
      try {
        if (await tmp.exists()) await tmp.delete();
      } on Object {
        // A leftover `.tmp` is inert: it is never read, and never counted.
      }
      return false;
    }

    if (_bytes! > maxBytes) await _evict(dir);
    return true;
  }

  /// Drop what is cached for [key], if anything.
  ///
  /// Used when a delete is confirmed: the key is `path|capture second`, and the one
  /// thing it cannot see is a same-named file written inside the same second afterwards.
  /// The app knows about its own deletes, so it drops the entry rather than leaving a
  /// picture of a file that is gone to be served for a file that is not.
  Future<void> remove(String key) async {
    try {
      final dir = await _dir();
      final file = _fileFor(dir, key);
      if (!await file.exists()) return;
      final length = await file.length();
      await file.delete();
      if (_bytes != null) _bytes = _bytes! - length;
    } on Object catch (e) {
      _logWrite('could not remove $key ($e)');
    }
  }

  /// What the cache currently holds. For diagnostics and for the checks.
  Future<({int entries, int bytes})> stats() async {
    try {
      return await _measure(await _dir());
    } on Object {
      return (entries: 0, bytes: 0);
    }
  }

  // ------------------------------------------------------------------ internals

  static String _header(String key) => '$magic $key';

  /// `FF D8 … FF D9`, the two markers everything else in this project already checks: the
  /// sync engine refuses a `.JPG` that does not end with EOI (`sync_engine.dart`,
  /// measured as this camera's most likely corruption — a truncated response), and the
  /// live-view receiver frames every datagram the same way (`liveview.dart`).
  ///
  /// Applied here because the alternative is what the grid's own comment records: a
  /// truncated transfer or a JSON error page landing in `Image.memory` as
  /// `Failed to decode image`. Bytes that are not a picture are not a cache entry.
  static bool _isPicture(Uint8List b) =>
      b.length >= 4 &&
      b[0] == 0xFF &&
      b[1] == 0xD8 &&
      b[b.length - 2] == 0xFF &&
      b[b.length - 1] == 0xD9;

  Future<Directory> _dir() async {
    final cached = _root;
    if (cached != null) return cached;
    final base = await _resolve();
    final dir = Directory('${base.path}${Platform.pathSeparator}$directoryName');
    if (!await dir.exists()) await dir.create(recursive: true);
    _root = dir;
    return dir;
  }

  File _fileFor(Directory dir, String key) =>
      File('${dir.path}${Platform.pathSeparator}${entryName(key)}');

  /// Every entry in [dir], with what it costs.
  ///
  /// Only `*.bin`: a `.tmp` from a write that was killed, or anything else that finds its
  /// way into this directory, is not an entry — it is neither counted against the cap
  /// nor deleted by eviction.
  Future<List<({File file, int length, DateTime modified})>> _entries(
      Directory dir) async {
    final out = <({File file, int length, DateTime modified})>[];
    await for (final e in dir.list(followLinks: false)) {
      if (e is! File || !e.path.endsWith(suffix)) continue;
      try {
        out.add((
          file: e,
          length: await e.length(),
          modified: await e.lastModified(),
        ));
      } on Object {
        // Vanished between the listing and the stat; not an entry any more.
      }
    }
    return out;
  }

  Future<({int entries, int bytes})> _measure(Directory dir) async {
    final entries = await _entries(dir);
    return (
      entries: entries.length,
      bytes: entries.fold<int>(0, (sum, e) => sum + e.length),
    );
  }

  /// Delete the oldest entries until the total fits.
  ///
  /// Oldest by **file mtime**, which for these files is when the thumbnail was fetched
  /// (an entry is only ever rewritten when the shot is). Reads do not touch it: making
  /// every cache hit a metadata write to flash, a thousand times per album, to buy
  /// recency ordering a card-sized cache never needs — the cap is deliberately generous
  /// enough that a full card does not evict at all.
  Future<void> _evict(Directory dir) async {
    try {
      final entries = await _entries(dir);
      entries.sort((a, b) {
        final byTime = a.modified.compareTo(b.modified);
        return byTime != 0 ? byTime : a.file.path.compareTo(b.file.path);
      });
      var total = entries.fold<int>(0, (sum, e) => sum + e.length);
      for (final e in entries) {
        if (total <= maxBytes) break;
        try {
          await e.file.delete();
          total -= e.length;
        } on Object {
          // Could not delete it; the cap is a bound, not a promise, and the next write
          // will try again.
        }
      }
      _bytes = total;
    } on Object catch (e) {
      _logWrite('could not evict ($e)');
    }
  }

  void _logRead(String message) {
    if (_readFailureLogged) return;
    _readFailureLogged = true;
    _onLog?.call('$message — the grid will ask the camera instead');
  }

  void _logWrite(String message) {
    if (_writeFailureLogged) return;
    _writeFailureLogged = true;
    _onLog?.call('$message — thumbnails will be fetched again next time');
  }
}
