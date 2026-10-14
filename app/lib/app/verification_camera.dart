import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;

import '../protocol/wire_format.dart';
import '../transport/album.dart';
import '../transport/http_transport.dart';
import 'configuration.dart';

/// One decodable **JPEG** for the fake camera's thumbnails and originals.
///
/// ## Why the format is not a free choice
///
/// It must be a JPEG, because the album names these files `YI000001.JPG` and the sync
/// engine checks that a `.JPG` ends with the end-of-image marker before storing it.
/// A PNG fixture therefore makes every transfer fail with
///
/// ```
/// [sync] YI000001.JPG: truncated image (missing end-of-image marker) — retrying
/// ```
///
/// — the engine behaving correctly and the harness being wrong. It cost a round trip:
/// two of five tiles sat in "Retrying…" and it looked like a bug in the transfer path
/// until the log named the marker.
///
/// A **visible** image rather than a 1x1 dot, for the same reason: a black 1x1 tile is
/// indistinguishable from a thumbnail that failed to load, so the first fixture would
/// have let "thumbnails are broken" pass a visual check.
///
/// ## And why the *resolution* is not a free choice either
///
/// Measured on the real 3.1-cn body (`analysis/50`, reproduced in `analysis/61`):
///
/// | request | real camera |
/// |---|---|
/// | `.JPG` `Thumbnail` | 200, ~6.8 KB |
/// | **`.DNG` `Thumbnail`** | **204 No Content, zero bytes** |
/// | `.DNG` `MidThumb` | **404** |
/// | `.DNG` `Original` | 200, ~32 MB |
///
/// A harness that answers a `.DNG` thumbnail with a JPEG is a harness in which the
/// whole missing-thumbnail defect is invisible — the grid would look perfect on the
/// desk and blank on the phone. So the stub **refuses** what the camera refuses; see
/// [fakeCameraThumbnail].
Uint8List fakeVerificationImage() => _fakeJpeg;

/// The album listing the fake camera reports.
///
/// Shaped like the real `GetFileList` page — `path`, `date` as a **string** of Unix
/// seconds, `filetype`, `protectStatus` — and deliberately **short**, because a page
/// shorter than 60 entries is the firmware's own end-of-album signal, so the grid
/// stops paging instead of asking for page 2 forever.
///
/// The contents cover the cases the UI has to distinguish, because a listing of
/// identical JPEGs would verify none of them:
///
/// * a plain JPEG;
/// * a RAW+JPEG pair, which must render as **one** row with a `RAW+JPG` badge
///   (two rows would double the count and split the selection);
/// * a RAW on its own, which must be badged `RAW` rather than shown as a JPEG;
/// * a video.
List<Object> fakeAlbumPage() => [
      {
        'path': '/DCIM/101YICAM/YI000001.JPG',
        'date': '1700000000',
        'filetype': 'picture',
        'protectStatus': false,
      },
      {
        'path': '/DCIM/101YICAM/YI000002.JPG',
        'date': '1700000100',
        'filetype': 'picture',
        'protectStatus': false,
      },
      {
        'path': '/DCIM/101YICAM/YI000002.DNG',
        'date': '1700000100',
        'filetype': 'raw',
        'protectStatus': false,
      },
      {
        'path': '/DCIM/101YICAM/YI000003.DNG',
        'date': '1700000200',
        'filetype': 'raw',
        'protectStatus': false,
      },
      {
        'path': '/DCIM/101YICAM/YI000004.MP4',
        'date': '1700000300',
        'filetype': 'video',
        'protectStatus': false,
      },
    ];

/// What the fake camera hands back for one `GetFile` — the download seam behind
/// `FAKE_CAMERA=1`.
///
/// Shaped by the table above rather than by convenience: the `.DNG` cases throw the
/// same [AlbumException] the real `CameraAlbum.download` throws for the same status
/// (`204` for a RAW thumbnail, `404` for a RAW `MidThumb`), because that is the
/// contract the grid is written against. A stub that quietly returned bytes would make
/// the harness disagree with the camera in exactly the place the camera is surprising.
///
/// ## The one row of that table that is a **hope**, not a measurement
///
/// A **video** falls through to the 834 bytes below, i.e. this stub answers a video's
/// `Thumbnail` with a real JPEG. **Nothing measured that.** `analysis/50` measured
/// `.JPG` (200) and `.DNG` (204 at `Thumbnail`, 404 at `MidThumb`, 200 at `Original`);
/// the listing in `analysis/61` shows the card carries `video` entries, and no round
/// has asked this camera for one's thumbnail. So the fake camera may be disagreeing
/// with the hardware here in exactly the way it disagreed over `.DNG` — the way that
/// made a broken grid look perfect on the desk.
///
/// It is left as-is rather than guessed at, because a stub that invents a `204` would
/// be a fabricated camera behaviour, which is worse. What the grid does about it does
/// **not** depend on the answer: `CameraAlbum.gridVideoThumbnailChain` stops at
/// `MidThumb`, so a video is never asked for the video file itself whether or not the
/// first rung produces a frame. The checks that model the worst case do so locally,
/// and say so — `album_thumbnails_test.dart`, "a video whose every rendition is
/// refused…".
Future<Uint8List> fakeCameraThumbnail(
    AlbumFile file, FileResolution resolution) async {
  final dng = file.path.toUpperCase().endsWith('.DNG');
  if (dng && resolution == FileResolution.thumbnail) {
    throw AlbumException(
      'HTTP 204 for ${file.path} at ${resolution.wire}: the camera cannot produce '
      'that rendition (this is how this firmware answers a RAW thumbnail — the file '
      'itself is still there)',
      204,
    );
  }
  if (dng && resolution == FileResolution.midThumb) {
    throw AlbumException('HTTP 404 downloading ${file.path}: ', 404);
  }
  return _fakeJpeg;
}

/// 834 bytes of JPEG, inlined because it is small. Regenerate with
/// `python tools/make_fake_camera_image.py` — and the generator asserts the same
/// SOI/EOI markers the sync engine checks, so a regenerated fixture cannot silently
/// become a PNG again.
final Uint8List _fakeJpeg = base64Decode(
  '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDABQODxIPDRQSEBIXFRQYHjIhHhwcHj0sLiQySUBM'
  'S0dARkVQWnNiUFVtVkVGZIhlbXd7gYKBTmCNl4x9lnN+gXz/2wBDARUXFx4aHjshITt8U0ZT'
  'fHx8fHx8fHx8fHx8fHx8fHx8fHx8fHx8fHx8fHx8fHx8fHx8fHx8fHx8fHx8fHx8fHz/wAAR'
  'CABIAGADASIAAhEBAxEB/8QAFwABAQEBAAAAAAAAAAAAAAAAAAYEBf/EACQQAAECAwkBAQAA'
  'AAAAAAAAAAABAwIEBRESFTVTgqKy0UFh/8QAGAEBAQEBAQAAAAAAAAAAAAAAAAMEBQH/xAAk'
  'EQABAgYCAQUAAAAAAAAAAAAAAQIDBBEUMlESE3EhQWFiof/aAAwDAQACEQMRAD8A2AHBqVRm'
  'mJ51tp27BDZYl1F+J+HGhw1iLRDovejEqp3gS+Lz2vwh8GLz2vwh8L2j9oSuGlQCXxee1+EP'
  'gxee1+EPgtH7QXDSoBL4vPa/CHwYvPa/CHwWj9oLhpUAl8XntfhD4MXntfhD4LR+0Fw0qAcG'
  'm1Gafnmm3Xb0EVtqXUT4v4d4hEhrDWilWPR6VQEvWcze29UKgl6zmb23qheUzXwSmMTEAVFG'
  'yxnd2U2xYnW2tDPDZzWhLgtQZrz6/pa3+SKBagXn1/Rb/JFAqKzlj23shLmmFE7G1oRiM4LQ'
  '20bM2d3VSoJejZmzu6qVBim808GiXxBL1nM3tvVCoJes5m9t6oJTNfAmMTEVFGyxnd2Ulyoo'
  '2WM7uyl5vBPJKXyNoAOabQAADFWcse29kJcqKzlj23shLnSlMF8mKYyNtGzNnd1UqCXo2Zs7'
  'uqlQQm808FZfEEvWcze29UKg4NSp00/POuNNXoIrLFvInxP08lXI16qq+x7HRVb6HIBtwie0'
  'OcPowie0OcPpv7WbQycHaMQNuET2hzh9GET2hzh9HazaDg7RiBtwie0OcPowie0OcPo7WbQc'
  'HaMQNuET2hzh9GET2hzh9HazaDg7Qo2Zs7uqlQcGm06aYnmnHWrsENtq3kX4v6d4wTTkc9FR'
  'fY1wEVG+oABlLgAAAAAAAAAAAAAAH//Z',
);

/// The stub camera used by [useFakeCamera].
///
/// Answers the commands the connected screens actually read, and nothing more:
///
/// * `RCGetStatus` is the liveness probe, so it must answer plausibly or the link
///   guard marks the connection lost;
/// * `GetFileList` returns a short page, which is also the firmware's own
///   end-of-album signal, so the album grid stops paging;
/// * `RCDoFocus` answers with `Posx`/`Posy` because the focus marker is drawn from
///   the camera's reply rather than from the tap — a stub that omitted them would
///   make the marker look broken;
/// * everything else answers `200`. That is deliberately permissive: this harness
///   exists to make the **UI** reachable, and the protocol layer already has its
///   own offline checks. It is not evidence that any command works.
CameraHttpClient fakeVerificationHttp() {
  // Referencing the marker keeps it in the binary when the flag is ON, which is
  // what lets `task.ps1 build` grep for it.
  debugPrint('$kFakeCameraMarker: simulating a connected camera');
  return CameraHttpClient(overrideSend: (command, params) async {
    switch (command) {
      case 'RCGetStatus':
        return const CameraResponse(
          code: 200,
          data: {'BatteryLevel': '3'},
          raw: '{"code":200,"data":{"BatteryLevel":"3"}}',
        );
      case 'RCDoFocus':
        return const CameraResponse(
          code: 200,
          data: {'Posx': '400', 'Posy': '300'},
          raw: '{"code":200,"data":{"Posx":"400","Posy":"300"}}',
        );
      case 'GetFileList':
        return CameraResponse(
          code: 200,
          data: fakeAlbumPage(),
          raw: '{"code":200,"data":[...]}',
        );
      default:
        return const CameraResponse(
          code: 200,
          data: 'ok',
          raw: '{"code":200,"data":"ok"}',
        );
    }
  });
}

/// The **real** client [useDirectCamera] installs.
///
/// No `overrideSend`, no stub: this is the same object the app builds after a
/// successful BLE pairing, aimed at a compile-time address instead of the one the
/// camera told it. Everything above it — the capture interlock, the album, the
/// sync engine — cannot tell the difference, which is the point.
CameraHttpClient directCameraHttp() {
  // Referencing the marker keeps it in the binary when the flag is ON, which is
  // what lets `task.ps1 build` grep for it.
  debugPrint('$kDirectCameraMarker: talking to '
      '$kDirectCameraHost:$kDirectCameraPort');
  return CameraHttpClient(host: kDirectCameraHost, port: kDirectCameraPort);
}

/// What the app bar reports when the BLE step was skipped.
///
/// Deliberately **not** the real camera's `3.1-cn / M1CN`. That value comes from
/// the firmware-info characteristic, and nothing on this path read it — so
/// printing it would be a fabricated measurement wearing the costume of a real
/// one, and the badge exists precisely so a screenshot can settle "which camera
/// answered". `direct` instead says the true thing: no pairing happened, and this
/// build was told where to dial.
///
/// It also keeps the app on the conservative side of its own dual-mode logic,
/// because `isChinaModel` is false for this marker: no MOD-only feature is
/// offered on the strength of an identity nobody verified.
const CameraIdentity kDirectCameraIdentity = CameraIdentity(
  protocolVersion: 1,
  firmwareVersion: 'direct',
  regionMarker: 'DIRECT',
);
