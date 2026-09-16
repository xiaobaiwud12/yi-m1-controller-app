import 'package:flutter/services.dart';

/// The Android media-store bridge: the platform half of [MediaStoreSink].
///
/// ## Why a channel and not a package
///
/// Flutter has no binding for `ContentResolver`, and the alternative — pulling in
/// a plugin — would put a third party between this app and the user's photos. The
/// native half is `MainActivity.storeMedia`, which is deliberately small: insert,
/// write, publish.
///
/// ## Why the calls answer data rather than throwing
///
/// A transfer that loses a photo must be reported as a **failed transfer**, not
/// as an unhandled exception: the sync engine retries failures and records them in
/// the ledger, whereas an exception that escapes reaches the zone handler and the
/// photo is silently missing from both the phone and the count. So every method
/// here converts a platform failure into a value.
class MediaStoreBridge {
  static const MethodChannel _channel =
      MethodChannel('com.cem1.yi_m1_controller/media');

  /// Whether a platform implementation is present at all.
  ///
  /// False on tests and on any non-Android host, where the caller falls back to
  /// writing a plain file.
  static Future<bool> get available async {
    try {
      final ok = await _channel.invokeMethod<bool>('available');
      return ok ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Ask for the storage permission that Android 9 and older need to write into
  /// the shared photo library.
  ///
  /// Answers `true` on Android 10+ **without showing anything**: the modern
  /// MediaStore API needs no permission, so a prompt there would be pure noise.
  ///
  /// Returned as a value rather than thrown so a sync can start either way and let
  /// the per-file failure carry the reason — a sync that refuses to start cannot
  /// tell the user *which* file would have failed.
  static Future<bool> requestLegacyStorage() async {
    try {
      return await _channel.invokeMethod<bool>('requestLegacyStorage') ?? false;
    } on MissingPluginException {
      // No bridge: the caller is on a host with no media store, where the file
      // fallback is used and needs nothing.
      return true;
    } on PlatformException {
      return false;
    }
  }

  /// Insert [bytes] into the shared media store, answering its `content://` URI.
  static Future<MediaStoreEntry> store({
    required Uint8List bytes,
    required String displayName,
    required String mimeType,
    String relativePath = 'DCIM/YI M1/',
    DateTime? capturedAt,
  }) async {
    try {
      final raw = await _channel.invokeMethod<Object?>('storeMedia', {
        'bytes': bytes,
        'displayName': displayName,
        'mimeType': mimeType,
        'relativePath': relativePath,
        // Epoch **seconds**, matching MediaStore's own units for DATE_ADDED /
        // DATE_MODIFIED. Converting here rather than natively keeps one definition
        // of the wire format, and the camera's dates are already seconds.
        if (capturedAt != null)
          'capturedAtEpochSeconds': capturedAt.toUtc().millisecondsSinceEpoch ~/ 1000,
      });
      if (raw is! Map) {
        return const MediaStoreEntry.failed('the media bridge answered nothing');
      }
      final uri = raw['uri'] as String?;
      final error = raw['error'] as String?;
      if (uri == null || uri.isEmpty) {
        return MediaStoreEntry.failed(error ?? 'MediaStore refused the insert');
      }
      return MediaStoreEntry(uri: uri, error: error);
    } on MissingPluginException {
      return const MediaStoreEntry.failed('this build has no media bridge');
    } on PlatformException catch (e) {
      return MediaStoreEntry.failed('${e.code}: ${e.message}');
    }
  }

  /// Read a stored asset's bytes back from the shared library.
  ///
  /// Answers `null` when the row cannot be read — a deleted photo, a URI from
  /// another app, or no bridge at all. The caller falls back to the camera only
  /// when the user asks for it, because a synced photo must be viewable with the
  /// camera switched off.
  static Future<Uint8List?> read(String uri) async {
    if (uri.isEmpty) return null;
    try {
      return await _channel.invokeMethod<Uint8List>('readMedia', {'uri': uri});
    } on Object {
      return null;
    }
  }

  /// Delete a row this app created. Answers whether the platform removed it.
  static Future<bool> delete(String uri) async {
    if (uri.isEmpty) return false;
    try {
      return await _channel.invokeMethod<bool>('deleteMedia', {'uri': uri}) ?? false;
    } on Object {
      return false;
    }
  }

  /// Open [uri] in whichever app the user has for [mimeType].
  static Future<bool> open(String uri, String mimeType) async {
    try {
      return await _channel.invokeMethod<bool>(
            'openUri',
            {'uri': uri, 'mimeType': mimeType},
          ) ??
          false;
    } on Object {
      return false;
    }
  }

  /// Hand [uris] to the system share sheet.
  static Future<bool> share(
    List<String> uris, {
    required String mimeType,
    String? title,
  }) async {
    if (uris.isEmpty) return false;
    try {
      return await _channel.invokeMethod<bool>('shareUris', {
            'uris': uris,
            'mimeType': mimeType,
            if (title != null) 'title': title,
          }) ??
          false;
    } on Object {
      return false;
    }
  }
}

/// One stored asset.
///
/// [error] is non-null even on success when the platform had something to say —
/// for instance when the row was published after a partial write. Carrying it
/// instead of dropping it is deliberate: a warning the UI can show beats a
/// silent repair.
class MediaStoreEntry {
  /// The `content://` URI, or empty when nothing was stored.
  final String uri;
  final String? error;

  const MediaStoreEntry({required this.uri, this.error});

  const MediaStoreEntry.failed(String this.error) : uri = '';

  bool get ok => uri.isNotEmpty;

  @override
  String toString() => 'MediaStoreEntry(${ok ? uri : 'FAILED: $error'})';
}
