/// Album browsing and download — the "auto-sync photos to the phone" feature.
///
/// Reverse-engineered from the firmware and cross-checked against the official
/// app's own code.  See `analysis/07-album-sync-protocol.md` for the full writeup
/// and the evidence.
///
/// Summary of the wire protocol:
///
/// * `GetFileList` takes `range_start` + `range_end` and **requires both**.
///   It is **1-based, 60 files per page**.  Leaving the parameters out makes the
///   handler return -1 without writing a response body, which the HTTP server
///   surfaces as a bare **404** — that is why this endpoint was long believed to
///   be missing from the firmware.  It is not.
/// * `GetFile` takes `path` + `resulotion` (**the firmware's spelling**) and
///   returns the file's **raw bytes** as the HTTP body — no JSON, no base64.
/// * Error code `1506` (`no pic anymore err`) means "past the end of the album"
///   and should be treated as success.
///
/// Everything here is dart:io only, so it can be exercised from the plain Dart VM
/// against the real camera without Flutter.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:typed_data';

import 'http_transport.dart';

/// One entry from `GetFileList`.
class AlbumFile {
  /// Full path on the camera, e.g. `/DCIM/100YICAM/YI000001.JPG`.
  ///
  /// The firmware copies this into a **50-byte** buffer, so anything longer
  /// cannot be fetched.  [isPathTooLong] flags that case rather than letting the
  /// camera fail with a confusing 404.
  final String path;

  /// Capture time as Unix **seconds**.  The camera sends this as a *string*.
  final DateTime? captureTime;

  /// One of `picture`, `video`, `raw`, `rawJpeg`, `panorama`.
  final String fileType;

  /// Reported by the firmware; meaning unverified (likely a write-protect flag).
  final bool protectStatus;

  const AlbumFile({
    required this.path,
    required this.fileType,
    this.captureTime,
    this.protectStatus = false,
  });

  String get fileName {
    final i = path.lastIndexOf('/');
    return i < 0 ? path : path.substring(i + 1);
  }

  /// The handler memcpy's `path` into a 50-byte buffer, so longer paths cannot
  /// work regardless of what the filesystem allows.
  bool get isPathTooLong => path.length > 50;

  /// Longer than `DeleteFile` can take.
  ///
  /// **This is not the same limit as [isPathTooLong], and the difference is a
  /// trap.**  `GetFile` copies the path into a 50-byte buffer; `DeleteFile` copies
  /// *each entry of `file_list`* into a 56-byte slot (`stride 56 bytes` at
  /// `text+0x153350`), so it accepts about 52 characters.  A path of 51 or 52
  /// characters can therefore be **deleted but not downloaded**.
  ///
  /// The consequence for a RAW+JPEG pair is the reason this getter exists: a pair
  /// whose JPEG cannot be fetched might still have a deletable RAW, and deleting
  /// it would orphan the JPEG.  A pair is deleted as a unit or not at all, so the
  /// stricter of the two limits is the one that governs.
  bool get isDeletePathTooLong => path.length > deletePathLimit;

  /// What the firmware's `DeleteFile` handler can carry in one `file_list` entry.
  ///
  /// The true bound is "≤ ~52 characters" from the 56-byte stride, and paths are
  /// padded by the C string terminator, so this is the conservative end of a range
  /// the disassembly does not pin down exactly.  Refusing a path that would in
  /// fact have fitted costs nothing and is visible; sending one that does not fit
  /// is a `memcpy` onto a truncated path, i.e. a different file deleted.
  static const int deletePathLimit = 52;

  bool get isVideo => fileType == 'video';

  /// True when **this file is** a RAW.
  ///
  /// ## This used to include `rawJpeg`, and that was wrong
  ///
  /// Measured on the real 3.1-cn body (`analysis/50`): `GetFileList` returns **one entry
  /// per shutter press**, and a RAW+JPEG shot is a single entry whose `path` ends
  /// **`.JPG`** and whose `filetype` is `rawJpeg`. There is no second `.DNG` entry.
  /// `GetFile` on that `.JPG` returns JPEG bytes (`FF D8 FF E1 … Exif`), so the entry is
  /// a JPEG — yet `isRaw` counted it as a RAW, which badged every such tile `RAW` and
  /// gave the grouping logic the wrong primary.
  ///
  /// `rawJpeg` means *"this shot also has a RAW"*, which is [hasRawSibling], not this.
  ///
  /// The [rawSibling] this class derives carries `filetype = 'raw'`, so it is the only
  /// thing for which this getter is true.
  bool get isRaw => fileType == 'raw';

  /// True when this entry is a JPEG that **also** has a RAW beside it.
  ///
  /// The firmware reports this as `filetype == 'rawJpeg'` on the `.JPG` entry.
  bool get hasRawSibling => fileType == 'rawJpeg';

  /// The RAW half of a `rawJpeg` shot, or null when there is none.
  ///
  /// ## Two things about this that are easy to get wrong
  ///
  /// 1. **The firmware never lists it.** The path is derived by convention — same
  ///    directory and basename as the JPEG, with `.DNG`.
  ///
  /// 2. **It can only be fetched at [FileResolution.original].** Measured against the
  ///    real camera: `Thumbnail` answers **`204 No Content`** with a zero-byte body, and
  ///    `MidThumb` answers **`404`**. `Original` answers `200` with 31,931,408 bytes
  ///    beginning `II*\0` — a genuine DNG. **`204` here means "I cannot produce that
  ///    resolution", not "no such file"**; reading it as the latter is exactly the
  ///    mistake `analysis/50` §2 records, and it would have concluded that the RAW does
  ///    not exist.
  ///
  /// The RAW is not small: ~32 MB each, so a card of 18 such shots is ~574 MB over a
  /// slow radio. Fetching them is therefore **opt-in** ([SyncPlan.skipRaw] defaults to
  /// skipping, and the album's sync bar carries the switch that turns it on —
  /// `toggle-sync-raw`) — the same shoot-it-your-way principle as the rest of this app.
  AlbumFile? get rawSibling {
    if (!hasRawSibling) return null;
    final slash = path.lastIndexOf('/');
    final dir = slash < 0 ? '' : path.substring(0, slash + 1);
    var base = slash < 0 ? path : path.substring(slash + 1);
    final dot = base.lastIndexOf('.');
    if (dot > 0) base = base.substring(0, dot);
    if (base.isEmpty) return null;
    return AlbumFile(
      path: '$dir$base.DNG',
      fileType: 'raw',
      captureTime: captureTime,
      protectStatus: protectStatus,
    );
  }

  /// Stable identity for sync bookkeeping. `date` is second-resolution and the
  /// filename can repeat across folders, so use both.
  String get syncKey => '$path|${captureTime?.millisecondsSinceEpoch ?? 0}';

  factory AlbumFile.fromJson(Map<String, dynamic> j) {
    final rawDate = j['date'];
    DateTime? t;
    if (rawDate is String && rawDate.isNotEmpty) {
      final secs = int.tryParse(rawDate);
      if (secs != null) t = DateTime.fromMillisecondsSinceEpoch(secs * 1000);
    } else if (rawDate is num) {
      t = DateTime.fromMillisecondsSinceEpoch(rawDate.toInt() * 1000);
    }
    return AlbumFile(
      path: (j['path'] as String?) ?? '',
      fileType: (j['filetype'] as String?) ?? '',
      captureTime: t,
      protectStatus: j['protectStatus'] == true,
    );
  }

  @override
  String toString() => 'AlbumFile($fileType, $path)';
}

/// Which rendition of a file to fetch.
///
/// The string values are the firmware's, including the misspelling.  Do not
/// "correct" them.
enum FileResolution {
  /// Full-resolution original.
  original('Original'),

  /// Medium thumbnail (~viewfinder-sized) — good for previews and grids.
  midThumb('MidThumb'),

  /// Smallest thumbnail — cheapest, best for long lists.
  thumbnail('Thumbnail');

  const FileResolution(this.wire);
  final String wire;
}

/// Message codes for the failures in this file that reach the user's screen.
///
/// ## Why the prose stays here and a code travels beside it
///
/// `AGENTS.md` §4.1 keeps this file free of `package:flutter`, so it cannot call
/// `AppLocalizations`. The sentences below are, however, the whole reason several of
/// these branches exist — *"DeleteFile answered 404 … means the request shape was
/// rejected — not that the file is gone"* is a firmware behaviour that was measured,
/// and it is the difference between a user retrying and a user concluding their
/// photo was deleted. Moving the sentence up into the UI would move it away from the
/// `catch (e) { if (e.isBadParameters) … }` that decides it.
///
/// So: the English sentence stays, verbatim, as the fallback and as what
/// `toString()` prints in a log; a code and the values it interpolates travel with
/// it; and the UI resolves the code through `lib/l10n/message_text.dart`. A code the
/// UI does not know renders the English sentence — complete and correct — so the
/// failure information can never be *lost*, only left untranslated.
///
/// `kAlbumErrorCodes` is compared against the resolver by
/// `test/l10n_message_codes_test.dart`.
abstract final class AlbumErrorCodes {
  static const listingRejected = 'albumErrListingRejected';
  static const listingFailed = 'albumErrListingFailed';
  static const pathTooLong = 'albumErrPathTooLong';
  static const deleteRejected = 'albumErrDeleteRejected';
  static const deleteNoPaths = 'albumErrDeleteNoPaths';
  static const deleteTooMany = 'albumErrDeleteTooMany';
  static const deleteAll = 'albumErrDeleteAll';
  static const deletePathTooLong = 'albumErrDeletePathTooLong';

  static const Set<String> all = {
    listingRejected,
    listingFailed,
    pathTooLong,
    deleteRejected,
    deleteNoPaths,
    deleteTooMany,
    deleteAll,
    deletePathTooLong,
  };
}

/// Raised for camera-side errors that are not transport failures.
class AlbumException implements Exception {
  /// The sentence, in English — see [AlbumErrorCodes].
  final String message;

  final int? code;

  /// Which sentence [message] is, or null for a failure that has no user-facing
  /// wording of its own (a stalled socket, an HTTP status this app did not write).
  final String? messageCode;

  /// The values [message] interpolates, so a translation places them itself.
  final Map<String, Object?> messageParams;

  const AlbumException(this.message, [this.code, this.messageCode,
      this.messageParams = const {}]);

  /// True when the camera cannot produce the requested rendition **at all**.
  ///
  /// ## `204` does not mean "no such file", and it does not mean "try another size"
  ///
  /// Measured on the real 3.1-cn body (`analysis/50` §2, independently reproduced in
  /// `analysis/61` §1): a **`.DNG`** answers `Thumbnail` with **`204 No Content`** and a
  /// **zero-byte body**, and `MidThumb` with **`404`**. `Original` answers `200` with
  /// 31,931,408 bytes beginning `II*\0` — a genuine DNG. So the camera *can* read the
  /// file; it simply has no thumbnail for it.
  ///
  /// That makes `204` a **definitive** answer about one rendition, not a transient
  /// failure. The two things that follow from it:
  ///
  /// * a caller that walks a chain of renditions should **skip a `204` rather than
  ///   abort** — the next resolution may well exist where this one did not. (Ordering
  ///   the chain cheapest-first is what makes that pay off: a `204` on `Thumbnail`
  ///   costs one empty reply, not a second full transfer.)
  /// * and nothing may pass the **zero bytes** to an image decoder. `Image.memory`
  ///   throws `Failed to decode image` for them, and on the album grid that reached
  ///   `FlutterError.onError`; `AGENTS.md` §8 is the rule that this must be an
  ///   explicit check rather than a hope.
  bool get isNoContent => code == 204;

  @override
  String toString() => code == null
      ? 'AlbumException: $message'
      : 'AlbumException($code): $message';
}

/// Album access: paging over `GetFileList` and streaming bytes out of `GetFile`.
class CameraAlbum {
  static const int pageSize = 60;

  /// Firmware error codes, from the strings `"get file num err"` /
  /// `"no pic anymore err"`.
  static const int codeInternalError = 1505;
  static const int codeEndOfAlbum = 1506;

  /// The most paths one `DeleteFile` request may carry.
  ///
  /// The handler clamps with `cmp r0,#0x1e / movgt r0,#0x1e` — **30 entries**,
  /// verified in the firmware at `text+0x153290`.  The official app hands over the
  /// whole selection and lets the camera clamp it, which silently drops everything
  /// past the thirtieth path: a user who selected 40 photos is told they were
  /// deleted and 10 are still on the card.  This client batches instead, so no
  /// path is ever dropped without a name attached to it.
  static const int deleteBatchSize = 30;

  final CameraHttpClient http;
  final String host;
  final int port;

  /// Optional test seam for the download path.
  ///
  /// `download` speaks raw HTTP for the body (it must — the response is the file
  /// itself, not JSON), which means it would otherwise need a real camera to
  /// exercise.  The higher layers that matter most to get right — the sync queue,
  /// preview-then-upgrade ordering, retry and integrity handling — are all built
  /// on top of it, so being able to drive them offline is worth one injectable
  /// function.
  final Future<Uint8List> Function(AlbumFile file, FileResolution resolution)?
      overrideDownload;

  /// Timeout for one file transfer.
  ///
  /// Generous by necessity: a full-resolution photo is ~9 MB and the camera
  /// serves it over its own 802.11n AP at roughly 1.7 MB/s, so a 20-second limit
  /// fails on exactly the transfers the feature exists for.  Measured on
  /// hardware: 9.4 MB in 5.6 s on an idle link, and markedly slower while the
  /// live-view stream is running.
  final Duration timeout;
  final HttpClient _client;

  CameraAlbum(this.http,
      {String? host,
      this.port = 80,
      this.timeout = const Duration(seconds: 90),
      this.overrideDownload})
      : host = host ?? CameraHttpClient.defaultHost,
        _client = HttpClient() {
    _client.connectionTimeout = timeout;
  }

  /// The range pair for a 0-based [page].
  ///
  /// Page 0 -> (1, 60); page 1 -> (61, 120).  Note this is **not** `page*60`:
  /// the firmware's indexing is 1-based.
  static (int, int) pageRange(int page) => (page * pageSize + 1, (page + 1) * pageSize);

  /// Fetch one page of the album.
  ///
  /// Returns the files on that page.  A short page (< [pageSize]) means the end
  /// of the album has been reached; [listAll] uses that to stop.
  ///
  /// Throws [AlbumException] on a camera-side error other than the two expected
  /// end-of-album conditions.  Throws [CameraHttpException] if the request
  /// itself fails — a 404 here means the parameters or a firmware assumption are
  /// wrong, not that the endpoint is absent.
  Future<List<AlbumFile>> listPage(int page) async {
    final (start, end) = pageRange(page);
    final CameraResponse r;
    try {
      r = await http.send('GetFileList', {
        'range_start': '$start',
        'range_end': '$end',
      });
    } on CameraHttpException catch (e) {
      if (e.isBadParameters) {
        throw AlbumException(
          'GetFileList answered 404 for range $start..$end. On this firmware that '
          'means the parameters were rejected, not that the command is missing.',
          e.statusCode,
          AlbumErrorCodes.listingRejected,
          {'start': start, 'end': end},
        );
      }
      rethrow;
    }

    if (r.code == codeEndOfAlbum) return const <AlbumFile>[];
    if (r.code != 200) {
      throw AlbumException('GetFileList failed: ${r.raw}', r.code,
          AlbumErrorCodes.listingFailed, {'raw': r.raw});
    }

    final data = r.data;
    if (data is! List) return const <AlbumFile>[];
    return data
        .whereType<Map>()
        .map((m) => AlbumFile.fromJson(m.cast<String, dynamic>()))
        .where((f) => f.path.isNotEmpty)
        .toList(growable: false);
  }

  /// Walk the whole album.  Stops when a page comes back short, which is the
  /// firmware's own end-of-album signal.
  ///
  /// [maxPages] is a safety valve: if the camera ever returns full pages
  /// forever, this stops instead of looping until the battery dies.
  Stream<AlbumFile> listAll({int maxPages = 200}) async* {
    for (var page = 0; page < maxPages; page++) {
      final files = await listPage(page);
      yield* Stream.fromIterable(files);
      if (files.length < pageSize) return;
    }
  }

  /// Download one file's bytes.
  ///
  /// [resolution] defaults to the full-resolution original.  Use [FileResolution.midThumb]
  /// or [FileResolution.thumbnail] when you only need a preview — those are far
  /// cheaper and are what the official app uses for grids.
  ///
  /// Throws [AlbumException] if the camera refuses the path (including the
  /// 50-character limit, which is checked up front rather than round-tripped).
  Future<Uint8List> download(
    AlbumFile file, {
    FileResolution resolution = FileResolution.original,
    void Function(int received)? onProgress,
  }) async {
    if (file.isPathTooLong) {
      throw AlbumException(
        'path is ${file.path.length} chars; the firmware copies it into a 50-byte '
        'buffer so this can never be fetched: ${file.path}',
        null,
        AlbumErrorCodes.pathTooLong,
        {'length': file.path.length, 'path': file.path},
      );
    }

    final override = overrideDownload;
    if (override != null) {
      final bytes = await override(file, resolution);
      // Report progress on the injected path too, or a caller using it sees a
      // permanently zero byte count. (An offline check caught exactly that.)
      onProgress?.call(bytes.length);
      return bytes;
    }

    final uri = Uri(
      scheme: 'http',
      host: host,
      port: port,
      queryParameters: {
        'data': jsonEncode({
          'command': 'GetFile',
          'path': file.path,
          // The firmware's spelling. Not a typo on our side.
          'resulotion': resolution.wire,
        }),
      },
    );

    final HttpClientRequest req;
    try {
      req = await _client.getUrl(uri).timeout(timeout);
    } on TimeoutException {
      throw AlbumException('timeout opening download for ${file.path}');
    } on SocketException catch (e) {
      throw AlbumException('cannot reach camera: ${e.osError?.message ?? e.message}');
    }

    final HttpClientResponse resp;
    try {
      resp = await req.close().timeout(timeout);
    } on TimeoutException {
      throw AlbumException(
          'timeout waiting for the response headers for ${file.path}');
    } on SocketException catch (e) {
      throw AlbumException('cannot reach camera: ${e.osError?.message ?? e.message}');
    }
    if (resp.statusCode != 200) {
      final body = await resp.transform(utf8.decoder).join().timeout(timeout);
      throw AlbumException(
        // A 204 is called out by name because it is the one status whose meaning is
        // counter-intuitive, and because it is measured rather than guessed: this
        // camera answers `Thumbnail` on a `.DNG` with 204 and no body, meaning "I
        // cannot produce that resolution" — **not** "no such file". See
        // `AlbumFile.rawSibling` and `AlbumException.isNoContent`.
        resp.statusCode == 204
            ? 'HTTP 204 for ${file.path} at ${resolution.wire}: the camera cannot '
                'produce that rendition (this is how this firmware answers a RAW '
                'thumbnail — the file itself is still there)'
            : 'HTTP ${resp.statusCode} downloading ${file.path}: ${body.trim()}',
        resp.statusCode,
      );
    }

    // The body is the raw file. Stream it so a 20 MB RAW does not need to exist
    // twice in memory.
    //
    // `timeout` is applied to the body as an **idle** timeout, not as a cap on the
    // total: the camera serves the file off the card while the live-view stream
    // saturates the same radio, so a slow-but-moving transfer must be allowed to
    // finish, while a read that stops producing bytes must not outlive the budget.
    // Without this the `await for` below has no deadline of any kind — the
    // connection timeout only covers establishing the socket, so a camera that
    // stops mid-body hangs the transfer, and the sync queue behind it, forever.
    final builder = BytesBuilder(copy: false);
    try {
      await for (final chunk in resp.timeout(timeout)) {
        builder.add(chunk);
        onProgress?.call(builder.length);
      }
    } on TimeoutException {
      throw AlbumException(
        'the download of ${file.path} stalled: no data for '
        '${timeout.inSeconds}s after ${builder.length} bytes',
      );
    }
    final bytes = builder.takeBytes();
    // ## A `200` with an empty body is not a photo
    //
    // Every caller of this method hands the result straight to `Image.memory`, and
    // zero bytes reach the decoder as `Failed to decode image`. That is a **decoded
    // crash** — Flutter's own log line, reproduced from the phone — where the honest
    // report is "the camera answered with nothing". The caller cannot tell the two
    // apart from a `Uint8List` that happens to be empty, and the fix belongs here,
    // where the status code and the byte count are both known.
    if (bytes.isEmpty) {
      throw AlbumException(
        'the camera answered 200 for ${file.path} at ${resolution.wire} with an '
        'empty body; there is nothing to decode',
        resp.statusCode,
      );
    }
    return bytes;
  }

  /// Download with a fallback chain: original, then mid, then thumbnail.
  ///
  /// A full-resolution transfer can fail on a marginal link; degrading beats
  /// losing the photo entirely.  The returned tuple reports what was actually
  /// obtained so the caller can record the real quality.
  ///
  /// ## [skipNoContent], and the one case where degrading is the wrong answer
  ///
  /// `204` means the camera **cannot produce that rendition** — measured, and the
  /// reason it is a getter on [AlbumException] rather than a string match. It is
  /// therefore not a link problem that a lower resolution would survive, and for the
  /// caller that walks *down* from `Original` it is a positive answer: a `204` at
  /// `Original` means the file is not there at that size, so continuing to
  /// `MidThumb` and `Thumbnail` is real work for a result already known.
  ///
  /// Left **false** by default, because "degrade rather than lose the photo" is this
  /// method's whole contract and a caller that wants the file at any size must keep
  /// trying. **The album grid leaves it false as well**, for the opposite reason to the
  /// one this paragraph used to give: its chain starts at the *cheapest* rendition, so a
  /// `204` there is exactly the case that must keep degrading — see
  /// `CameraAlbum.gridThumbnailChain`. (It said "the album grid passes `true`" until
  /// 2026-09-16; the call site has never passed it, and `analysis/70` §15 argues the
  /// false value is the correct one.)
  Future<(Uint8List, FileResolution)> downloadWithFallback(
    AlbumFile file, {
    List<FileResolution> chain = const [
      FileResolution.original,
      FileResolution.midThumb,
      FileResolution.thumbnail,
    ],
    bool skipNoContent = false,
    void Function(int received)? onProgress,
  }) async {
    Object? lastError;
    // Named rather than silent: when every rendition is unavailable, "no thumbnail"
    // and "the link is down" have to be told apart by whoever reads the log.
    final unavailable = <String>[];
    for (final res in chain) {
      try {
        final bytes = await download(file, resolution: res, onProgress: onProgress);
        if (bytes.isNotEmpty) return (bytes, res);
        // Unreachable through `download`, which now refuses an empty body; kept
        // because the override seam is not required to.
        lastError = AlbumException('empty body for ${file.path} at ${res.wire}');
      } on AlbumException catch (e) {
        if (e.isNoContent) {
          unavailable.add(res.wire);
          if (skipNoContent) continue;
        }
        lastError = e;
      } catch (e) {
        lastError = e;
      }
    }
    throw AlbumException(
      'all renditions failed for ${file.path}: $lastError'
      '${unavailable.isEmpty ? '' : ' (the camera reported no '
          '${unavailable.join(', ')} rendition)'}',
    );
  }

  void close() => _client.close(force: true);

  /// Delete one batch of paths from the card.
  ///
  /// `DeleteFile` is keyed on **`file_list`**, and the firmware's parser expects a
  /// **JSON array** of path strings (verified at `text+0x153290`; the official app
  /// sends `linkedHashMap.put("file_list", String[])`).  So this is the one
  /// request in the app whose parameter is not a plain string, which is why
  /// `CameraHttpClient.send` takes `Map<String, Object>` rather than
  /// `Map<String, String>`.
  ///
  /// The batch is validated here as well as in the UI, because this is the last
  /// point before bytes leave the phone:
  ///
  /// * **`ALL` is refused outright.**  The firmware treats a first entry of `ALL`
  ///   as "delete everything on the card"; it is a literal string in the same
  ///   string pool as `file_list`, so it costs one careless edit to reach, and it
  ///   is unrecoverable on a camera with no undo.  A path list can only ever be
  ///   built from paths the album actually listed, and this guard means even a
  ///   bug that fabricated one cannot turn into "format my card".
  /// * More than [deleteBatchSize] paths, or a path over the 52-character slot the
  ///   handler copies into, throws [AlbumException] with the offending value
  ///   **before** sending.  A request that exceeds either limit does not fail
  ///   cleanly on this firmware; the official app's silent truncation at 30 is the
  ///   behaviour being designed against.
  ///
  /// A `code: 200` here means the camera *accepted* the request.  It is not
  /// evidence that any file was removed — see `album_delete.dart`, which verifies
  /// against a fresh listing rather than believing this.
  ///
  /// ## Why this is the one caller that opts in to a dangerous command
  ///
  /// `DeleteFile` is in `kDangerousCommands`, so the transport refuses it unless it
  /// arrives with an approval (`http_transport.dart`). This is where that approval
  /// is minted, and the position of the call is the point: it is *after* every check
  /// above, so an approval is only ever created for a request that has already
  /// passed them. Reading down the function, the last thing that happens before the
  /// camera is asked to destroy something is the sentence that says why it is
  /// allowed to — and the list being sent is the argument, not a flag.
  Future<CameraResponse> deleteFileList(List<String> paths) async {
    if (paths.isEmpty) {
      throw const AlbumException('DeleteFile needs at least one path', null,
          AlbumErrorCodes.deleteNoPaths);
    }
    if (paths.length > deleteBatchSize) {
      throw AlbumException(
        'DeleteFile takes at most $deleteBatchSize paths per call and was given '
        '${paths.length}; the firmware clamps the list and silently drops the '
        'rest, so this would look like success while leaving files behind',
        null,
        AlbumErrorCodes.deleteTooMany,
        {'limit': deleteBatchSize, 'count': paths.length},
      );
    }
    for (final p in paths) {
      if (p.toUpperCase() == 'ALL') {
        throw const AlbumException(
          'refusing to send DeleteFile file_list "ALL": on this firmware that '
          'means delete every file on the card',
          null,
          AlbumErrorCodes.deleteAll,
        );
      }
      if (p.length > AlbumFile.deletePathLimit) {
        throw AlbumException(
          'DeleteFile copies each path into a 56-byte slot, so "$p" '
          '(${p.length} chars) would be truncated and could delete the wrong '
          'file; the limit is ${AlbumFile.deletePathLimit}',
          null,
          AlbumErrorCodes.deletePathTooLong,
          {
            'path': p,
            'length': p.length,
            'limit': AlbumFile.deletePathLimit,
          },
        );
      }
    }

    final CameraResponse r;
    try {
      r = await http.sendApproved(
        'DeleteFile',
        {'file_list': paths},
        approval: DangerousApproval.forCommand(
          'DeleteFile',
          (_) => _logDeleteAuthorization(paths),
        ),
      );
    } on CameraHttpException catch (e) {
      if (e.isBadParameters) {
        throw AlbumException(
          'DeleteFile answered 404 for ${paths.length} path(s). On this firmware '
          'that means the request shape was rejected — not that the file is gone.',
          e.statusCode,
          AlbumErrorCodes.deleteRejected,
          {'count': paths.length},
        );
      }
      rethrow;
    }
    return r;
  }

  /// The authorisation the transport runs immediately before a `DeleteFile` goes
  /// out — the sentence behind `DangerousApproval.forCommand`.
  ///
  /// It logs rather than returns, because by the time it is called everything that
  /// could refuse the request has already run: the value here is that a destructive
  /// command is *accounted for* on the record it is about, at the moment it happens.
  /// `dart:developer` and not `print`, so that this layer stays compatible with the
  /// plain Dart VM the offline checks run in and the line is a log rather than
  /// console noise on a device. The paths are named because a delete is the one
  /// operation where "which files" is the whole question.
  void _logDeleteAuthorization(List<String> paths) {
    developer.log(
      'sending DeleteFile for ${paths.length} path(s): ${paths.join(', ')}',
      name: 'yi_m1.album.delete',
    );
  }

  /// The renditions a **grid** tile may use, cheapest first.
  ///
  /// ## Why the grid needs its own chain rather than `original` first
  ///
  /// The sync engine's chain starts at `Original` because its job is the real file.
  /// A grid tile's job is a picture roughly 170 dp wide, so the order is inverted —
  /// and the inversion is what makes the measured `204` cheap.
  ///
  /// The failure this exists for: a group whose primary is a **`.DNG`** asks for
  /// `Thumbnail` and this firmware answers **`204` with a zero-byte body**. The grid
  /// used to call `download()` once, at `Thumbnail`, and swallow the throw — so the
  /// tile sat on a spinner forever with nothing in the log. With the chain it falls
  /// through to `MidThumb`, which is the same request the viewer makes and is
  /// known to work for a JPEG.
  ///
  /// `Original` is the **last** resort on purpose. It is 4.9 MB for a JPEG and
  /// 31.9 MB for a RAW, over a radio the live view is already using (`AGENTS.md`
  /// §4.6), so it is only worth spending when every smaller rendition is genuinely
  /// absent. A `.DNG` answers `Thumbnail` with `204` and `MidThumb` with `404`, so
  /// it will reach `Original` — which is correct and unavoidable: the camera has no
  /// thumbnail of a RAW, and the only thing it will hand over is the RAW.
  static const List<FileResolution> gridThumbnailChain = [
    FileResolution.thumbnail,
    FileResolution.midThumb,
    FileResolution.original,
  ];

  /// The renditions a grid tile may use for a **video**, cheapest first.
  ///
  /// ## Why a video stops one rung early
  ///
  /// A video's `Original` is the video. `Image.memory` cannot decode an MP4 at all, so
  /// the last rung of [gridThumbnailChain] can only end in a broken-image icon — after
  /// the camera has served the whole file over its own access point, on a
  /// single-threaded server sharing the radio with the live view (`AGENTS.md` §4.6).
  ///
  /// It is worse than one wasted transfer, and that is why this is a defect rather
  /// than a preference: the grid fetches **one tile at a time** (`_pumpThumbs`), so a
  /// video that reaches that rung holds up **every tile behind it in the queue** — and
  /// the tiles behind it are the ones the user is scrolling towards. Measured on the
  /// desk before this existed (`album_thumbnails_test.dart`, "the grid never asks a
  /// video for its full-size original"): a three-tile card with one video produced
  ///
  /// ```
  /// P9150003.JPG@Thumbnail
  /// P9150002.MP4@Thumbnail
  /// P9150002.MP4@MidThumb
  /// P9150002.MP4@Original     <- the video, for a 170dp tile
  /// P9150001.JPG@Thumbnail
  /// ```
  ///
  /// So a video is asked for its still renditions and nothing beyond them. The right
  /// end state when a video has neither is the tile's own "no picture" icon, which it
  /// already draws — with the `VIDEO` badge next to it saying what the entry is.
  ///
  /// ## What is *not* claimed here
  ///
  /// What this firmware answers for a video's `Thumbnail` is **unmeasured**
  /// (`analysis/50` measured `.JPG` and `.DNG`; `analysis/61` shows the card carries
  /// `video` entries, and nothing more). This chain is correct either way: if the
  /// camera produces a frame, the first rung delivers it and the deeper ones are never
  /// reached; if it does not, the grid stops at `MidThumb` instead of asking for the
  /// video.
  static const List<FileResolution> gridVideoThumbnailChain = [
    FileResolution.thumbnail,
    FileResolution.midThumb,
  ];

  /// The grid's chain for one file — see [gridThumbnailChain] and
  /// [gridVideoThumbnailChain] for why a video is the shorter one.
  ///
  /// A method on the file rather than a second constant at the call site, so the rule
  /// lives beside the two chains it chooses between and the UI layer has nothing to
  /// remember.
  static List<FileResolution> gridChainFor(AlbumFile file) =>
      file.isVideo ? gridVideoThumbnailChain : gridThumbnailChain;
}

/// Sketch of the sync policy, so the UI layer has one place to reason about it.
///
/// Deliberately not implemented here: the camera's AP has **no internet
/// passthrough**, so while a sync runs the phone is offline.  That makes a
/// resumable, background-friendly design essential rather than optional.
///
/// ## What is live in this class, and where
///
/// `skipRaw` is the field the album page decides with: [forQueue] builds the plan
/// every queue action runs under, from the RAW switch in the sync bar
/// (`toggle-sync-raw`, persisted as `UiPrefs.includeRaw`), and
/// `plannedQueue` in `sync/asset_group.dart` is the only thing that reads it. Before
/// that existed this class was **constructed nowhere in `lib/`** — the policy was
/// documented here, the queue did the opposite, and nothing on screen said so
/// (`analysis/79`, finding #2).
///
/// `skipVideos` and `since` remain a sketch with no caller in `lib/`. They are the
/// *browsing* policy's shape, and no browsing path applies them: the sync modes decide
/// what a browsed page means (`SyncEngine.enqueueBrowsed`), and a video is
/// deliberately queued like any other shot. They are checked in
/// `tool/verify_transport.dart` and are kept rather than deleted because deleting them
/// would quietly drop the "skip videos" half of the decision this class exists to hold.
class SyncPlan {
  /// Only pull files captured at or after this instant.  `null` = everything.
  final DateTime? since;

  /// Skip videos (they are large and rarely wanted in the phone album).
  final bool skipVideos;

  /// Skip RAW (or fetch the paired JPEG instead — the camera reports `rawJpeg`
  /// as its own filetype).
  final bool skipRaw;

  /// RAW is **skipped by default**, and this default is a decision rather than an
  /// accident.
  ///
  /// It used to be `false` while being unreachable in practice: nothing derived a
  /// `.DNG` path, so no RAW was ever queued however the flag was set. Now that
  /// [AlbumFile.rawSibling] makes them reachable, the default decides whether a user's
  /// first sync quietly pulls **~32 MB per RAW+JPEG shot** — about 574 MB for the card
  /// measured in `analysis/50` — over a radio that also carries the live view.
  ///
  /// Silently starting to do that is the kind of change that arrives as a data bill. So
  /// the capability ships **off**, and turning it on is the user's call; the same
  /// shoot-it-your-way principle the preview-quality and burst work follow.
  ///
  /// ## "Off" is a default, not an absence — the call is reachable
  ///
  /// This paragraph used to be the whole implementation: nothing constructed a
  /// `SyncPlan`, so the class documented a policy that the queue contradicted — one tap
  /// on a `rawJpeg` shot queued the JPEG **and** the 32 MB `.DNG`, and the tile said
  /// nothing about it. So the sentence above is now backed by a control:
  ///
  /// * **what a user who wants the RAW does** — open the album, and in the sync bar
  ///   turn on **"Also fetch the RAW (.DNG, ~32 MB a shot)"** (`toggle-sync-raw`);
  /// * that switch's label states the cost **before** it is paid, and turning it on
  ///   queues nothing on its own — `AGENTS.md` §4.6, a queued shot is not a
  ///   transferring one, and the sync bar still owns the start;
  /// * the choice is remembered (`UiPrefs.includeRaw`), so it does not have to be
  ///   re-made every launch;
  /// * every tile of a shot that owns a RAW says so, and says whether that RAW is
  ///   still outstanding — `AssetGroup.rawPending`.
  const SyncPlan({this.since, this.skipVideos = true, this.skipRaw = true});

  /// The plan an **album queue action** runs under, from the user's own opt-in.
  ///
  /// The inversion lives here rather than at the call site so the page names what the
  /// user chose and cannot get the double negative backwards.
  ///
  /// `skipVideos` and `since` are left at "no opinion" on purpose: a queue action runs
  /// over shots the user named (a selection, the viewer's save button) or over a page
  /// an automatic mode already accepted, and neither may be dropped by a size filter it
  /// never agreed to. `plannedQueue` reads this plan for the RAW decision only — see its
  /// documentation for why the RAW is the one question a *group* has to answer.
  const SyncPlan.forQueue({required bool includeRaw})
      : since = null,
        skipVideos = false,
        skipRaw = !includeRaw;

  bool wants(AlbumFile f) {
    if (skipVideos && f.isVideo) return false;
    if (skipRaw && f.isRaw) return false;
    final t = f.captureTime;
    if (since != null && t != null && t.isBefore(since!)) return false;
    return true;
  }
}
