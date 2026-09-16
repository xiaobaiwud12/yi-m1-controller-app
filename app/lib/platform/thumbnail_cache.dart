import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../transport/album_thumbnail_cache.dart';

/// The album's thumbnail cache as the app ships it: in the app's own **cache**
/// directory.
///
/// ## Why the cache directory and not the documents directory
///
/// The three stores beside it (`FilePairingStore`, `FileSyncStore`) write to the app's
/// documents directory, because what they hold is state the user would notice losing —
/// a pairing costs a walk to the camera, a ledger costs a re-download. This holds
/// pictures the camera still has, so it belongs where the platform expects disposable
/// files: `getApplicationCacheDirectory()` is `context.getCacheDir()` on Android, which
/// the OS may reclaim under storage pressure, and which does not appear as "app data"
/// the user is entitled to wonder about.
///
/// The failure mode of that reclamation is the behaviour the app had before this cache
/// existed: the next visit fetches the thumbnail from the camera. Nothing here is
/// load-bearing, so the disposable directory is the correct one — and saying so in the
/// code is cheaper than a future round wondering why the thumbnails went missing after
/// the phone ran out of space.
///
/// ## Why this is a file of its own
///
/// `AGENTS.md` §4.1: the Flutter-free implementation lives in `lib/transport/`, so
/// `tool/verify_transport.dart` can exercise the format, the key, the cap and the
/// eviction in the plain Dart VM; anything that needs `package:flutter` lives here. This
/// is the *only* part of the thumbnail cache that needs a plugin, so it is the only part
/// that is here — one function, and the class it hands over is the tested one.
AlbumThumbnailCache appThumbnailCache() => AlbumThumbnailCache(
      directory: getApplicationCacheDirectory,
      onLog: (m) => debugPrint('[album-cache] $m'),
    );
