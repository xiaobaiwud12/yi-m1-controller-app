import 'dart:typed_data';

import 'sync_ledger.dart';

/// Where a finished file is handed so it becomes visible to the gallery.
///
/// Deliberately free of Flutter and of `dart:io`, so the sync engine can be
/// driven by `tool/verify_sync.dart` in the plain Dart VM.  The Android
/// implementation lives in `asset_sink.dart`.
abstract class AssetSink {
  /// Persist [bytes] and return a local identifier (a path or a content URI).
  ///
  /// [capturedAt] is the instant the *camera* says the shot was taken, straight
  /// from `GetFileList`'s `date` field.  It is a `DateTime`, i.e. `dart:core`, so
  /// this file still needs neither Flutter nor `dart:io` and `tool/verify_sync.dart`
  /// can still drive the sync engine in the plain VM.
  ///
  /// ## Why the sink needs it at all
  ///
  /// The bytes handed to [store] are the camera's own file, fetched by `GetFile`
  /// with `resulotion: Original` and written without a single byte being decoded
  /// or re-encoded. What the *engine* has already done to them is one thing, and
  /// only one: the naive date inside the file's own EXIF has been rewritten to the
  /// same instant as [capturedAt] — see `exif_wall_clock.dart` for why a gallery
  /// reads that field and not the columns below, and for the bounds on what may be
  /// overwritten. Nothing else in the file is read, moved or regenerated, and this
  /// class neither reads nor writes metadata.
  ///
  /// What is *not* intact is the file's **modification time**, which is "when the
  /// phone wrote it".  Android's MediaStore fills `DATE_ADDED`/`DATE_MODIFIED`
  /// from exactly that, so a 2019 photo synced today is filed under today in any
  /// gallery that sorts on those columns.  That is table stake T15, and it is a
  /// *storage* fix, not an image-processing one: the sink's job is to make the
  /// capture instant the file's own timestamp.
  ///
  /// > **2026-09-16 correction.** The paragraph above used to say the EXIF was
  /// > "already intact" and that nothing rewrote metadata. The first half was true
  /// > of the *camera's* fields and the second half was the defect: the body writes
  /// > a naive wall clock from a clock with no timezone, so a photo the app
  /// > displayed as 18:40 arrived in the gallery as 10:40 on a phone at +08:00.
  /// > The app's own columns were always right, which is why sorting looked
  /// > correct and the claim was withdrawn once. Recorded in `analysis/80`.
  ///
  /// An implementation that cannot do that (a content-URI sink) must ignore the
  /// hint rather than fake it, and should say so in its own documentation — see
  /// `MediaStoreSink`, which states what setting an mtime does and does not
  /// cover on Android.
  Future<String> store({
    required String assetKey,
    required String fileName,
    required Uint8List bytes,
    required AssetQuality quality,
    DateTime? capturedAt,
  });

  /// Replace a previously stored rendition, used when upgrading in place.
  Future<void> replace(String localId, Uint8List bytes);
}

/// The MIME type implied by a filename or a `content://` URI.
///
/// Lives here, in the Flutter-free contract, rather than on the Android sink, so
/// `tool/verify_sync.dart` can check it in the plain VM. It is worth checking
/// because a wrong type is **silent**: sharing a JPEG as
/// `application/octet-stream` makes most receivers refuse it, and labelling a RAW
/// as `image/jpeg` makes the gallery list a file it cannot decode.
///
/// The **native** side has its own copy (`MediaKind` in Kotlin) because the value
/// is also needed when Dart is not in the picture — the store call classifies by
/// filename independently. The two are pinned to the same table by tests on both
/// sides; if you change one, change the other.
String mimeTypeForName(String nameOrUri) {
  final base = nameOrUri.split('?').first;
  final dot = base.lastIndexOf('.');
  final slash = base.lastIndexOf('/');
  // An extension only counts if the dot is in the final path segment *and* there
  // is a stem before it: a directory named `foo.jpg` must not make every file
  // under it a JPEG, and a dotfile named `.jpg` is a name rather than an image.
  final ext = dot > slash && dot > 0 ? base.substring(dot + 1).toLowerCase() : '';
  return switch (ext) {
    'jpg' || 'jpeg' => 'image/jpeg',
    'dng' => 'image/x-adobe-dng',
    'png' => 'image/png',
    'heic' || 'heif' => 'image/heic',
    'tif' || 'tiff' => 'image/tiff',
    'mp4' => 'video/mp4',
    'mov' => 'video/quicktime',
    'avi' => 'video/x-msvideo',
    // A `content://` URI carrying no extension is common for rows the system
    // renamed. `*/*` is honest: it lets the receiving app decide, whereas naming
    // the wrong concrete type makes it refuse.
    _ => '*/*',
  };
}

/// Whether a stored filename is a throwaway rendition rather than a real asset.
///
/// The sink writes previews as `<name>.preview.jpg` and thumbnails as
/// `<name>.thumb.jpg`. They are shared as-is when the full-resolution copy has not
/// arrived yet — a preview the user can send beats a share sheet that attaches
/// nothing — but the UI can use this to say so.
bool isRenditionName(String fileName) =>
    fileName.endsWith('.preview.jpg') || fileName.endsWith('.thumb.jpg');

/// A sink that keeps nothing.  Used by the offline checks and by a dry run.
class NullAssetSink implements AssetSink {
  int stored = 0;
  final List<String> log = [];

  /// The capture instant each `store` call was given, in call order.
  ///
  /// Recorded rather than merely accepted because "the sync engine passes the
  /// camera's date through to the sink" is exactly the kind of claim that is
  /// true in the code and false in the running app once someone edits a call
  /// site; `tool/verify_sync.dart` asserts on this list.
  final List<DateTime?> capturedAt = [];

  @override
  Future<String> store({
    required String assetKey,
    required String fileName,
    required Uint8List bytes,
    required AssetQuality quality,
    DateTime? capturedAt,
  }) async {
    stored++;
    log.add('$fileName:${quality.name}');
    this.capturedAt.add(capturedAt);
    return 'null://$assetKey/${quality.name}';
  }

  @override
  Future<void> replace(String localId, Uint8List bytes) async {}
}
