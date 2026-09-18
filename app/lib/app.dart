import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show SchedulerBinding, SchedulerPhase;
import 'package:marionette_flutter/marionette_flutter.dart';

import 'state/app_state.dart';
import 'l10n/l10n.dart';
import 'platform/onboarding_prefs.dart';
import 'protocol/wire_format.dart';
import 'transport/album.dart';
import 'transport/camera_connection.dart';
import 'transport/file_pairing_store.dart';
import 'transport/flutter_ble_transport.dart';
import 'transport/http_transport.dart';
import 'transport/wifi_joiner.dart';
import 'ui/licences.dart';
import 'ui/pages/album_page.dart';
import 'ui/pages/first_run_flow.dart';
import 'ui/pages/live_view_page.dart';

/// Whether to install the agent-driving binding.
///
/// ## Why a `--dart-define` and not `kDebugMode`
///
/// `MarionetteBinding` opens a VM-service control surface that lets an agent
/// inspect the widget tree and synthesize taps. That must not exist in a build
/// handed to a user, and "must not" is stronger than a runtime `if`:
///
///  * the flag is read through `fromEnvironment`, which is resolved at **compile
///    time**, so with it absent the Dart compiler **tree-shakes** the binding call
///    and the import behind it out of the release binary entirely — there is no
///    reachable code path, not merely an unentered branch;
///  * `kDebugMode` cannot be used from `lib/` at all, because the analyzer refuses
///    to let shipping code import a `dev_dependency`
///    (`depend_on_referenced_packages`), and that rule is right: a debug-only
///    import in production code is how instrumentation ships by accident.
///
/// So the run command that wants to be driven passes the flag:
///
/// ```
/// flutter run --dart-define=MARIONETTE=1
/// ```
///
/// and every ordinary build — including `flutter build apk --release` — omits it
/// and gets the plain `WidgetsFlutterBinding`.
bool get _useMarionette {
  // Both spellings accepted on purpose. `bool.fromEnvironment` is only true for
  // `=true`, so a bare `=1` would silently read as false and look like the binding
  // being broken rather than the flag being wrong.
  const asBool = bool.fromEnvironment('MARIONETTE');
  const asString = String.fromEnvironment('MARIONETTE');
  return asBool || asString == '1' || asString == 'true';
}

/// Whether to start in a **simulated connected state**, for UI verification.
///
/// ## Why this exists
///
/// Every screen the user actually complains about lives behind a successful
/// connection: the live preview, the two landscape side bands, the shutter, the
/// settings second level, the album grid, the paused-preview banner. Reaching any
/// of them needs a paired camera over BLE — and **the Android emulator has no
/// Bluetooth adapter at all**, so on a desk the entire connected half of the app
/// is unreachable and gets verified by reading layout code instead of looking at
/// it. That is how the duplicate nav bar and the landscape overflow both shipped.
///
/// This flag fabricates the connection instead: the same `testHttp`/`testIdentity`
/// seam the widget tests already use (`test/fakes.dart`), wired in at startup.
/// The camera is never contacted — every command is answered by a stub.
///
/// ## Why it cannot reach a user
///
/// Identical reasoning to [_useMarionette], and it matters more here because a
/// fake camera in a shipped build would be a lie about the user's hardware:
///
///  * `fromEnvironment` resolves at **compile time**, so without the flag the Dart
///    compiler tree-shakes the whole branch out — there is no reachable path, not
///    merely an untaken one;
///  * `task.ps1 build` additionally greps the release artifact for the marker
///    string, so a regression that made it reachable fails the build rather than
///    the user's trust.
///
/// Run it with:
///
/// ```
/// flutter run --dart-define=FAKE_CAMERA=1 --dart-define=MARIONETTE=1
/// ```
bool get _useFakeCamera {
  const asBool = bool.fromEnvironment('FAKE_CAMERA');
  const asString = String.fromEnvironment('FAKE_CAMERA');
  return asBool || asString == '1' || asString == 'true';
}

/// Whether to talk to a **real** camera at a fixed address, skipping BLE.
///
/// ## Why this is not the same thing as [fakeVerificationHttp]
///
/// `FAKE_CAMERA` fabricates both the connection *and* the answers: every command
/// is served by a stub, so it can make the connected screens reachable but it can
/// never be evidence that anything works. This flag fabricates **only the BLE
/// step**. The HTTP client it installs is a real [CameraHttpClient] talking over a
/// real socket, so `RCStartRemoteCtl`, `GetFileList`, `GetFile` and the live-view
/// stream are the genuine article.
///
/// ## What it is for
///
/// The emulator has no Bluetooth adapter, so the app's normal route to "ready" —
/// BLE pair, read credentials, join the access point, probe HTTP — cannot run
/// there, and the entire connected half of the app is unreachable on a desk. The
/// emulator *can* however reach the camera's IP directly: its slirp user-mode
/// network NATs guest sockets through the host's, so once the PC is joined to the
/// camera's access point a request from the guest arrives at 192.168.0.10 from the
/// PC's own Wi-Fi address. That is what makes a real camera drivable from the
/// emulator at all — see `analysis/46`.
///
/// The live-view stream needs one more piece the emulator cannot supply by
/// itself, because the camera sends frames to *the address its HTTP request came
/// from* — the host — rather than into the guest. `tools/camera_bridge.py` plus
/// the emulator console's `redir add udp:54321:54321` close that gap; neither is
/// part of the app.
///
/// ## Why it cannot reach a user
///
/// Same reasoning as [_useFakeCamera], and the same two independent guards:
/// `fromEnvironment` resolves at **compile time**, so without the flag the branch
/// is tree-shaken out of the binary; and `task.ps1 build` greps the packaged
/// artifact for [kDirectCameraMarker], so a regression that made it reachable
/// fails the build.
///
/// Run it with:
///
/// ```
/// flutter run -d emulator-5554 --dart-define=DIRECT_CAMERA=1 \
///     --dart-define=MARIONETTE=1
/// ```
///
/// `CAMERA_HOST` / `CAMERA_PORT` override where it points; the defaults are the
/// camera's real address, so the common case needs no arguments.
bool get _useDirectCamera {
  const asBool = bool.fromEnvironment('DIRECT_CAMERA');
  const asString = String.fromEnvironment('DIRECT_CAMERA');
  return asBool || asString == '1' || asString == 'true';
}

/// Where [_useDirectCamera] points.
///
/// Defaults to the camera's fixed address, because that is what the emulator
/// reaches when the PC is on the camera's access point. Overriding it is how the
/// same path is exercised against a stand-in camera on the host — which is the
/// only way to test the transport without the hardware.
const String kDirectCameraHost =
    String.fromEnvironment('CAMERA_HOST', defaultValue: '192.168.0.10');
const int kDirectCameraPort =
    int.fromEnvironment('CAMERA_PORT', defaultValue: 80);

/// A marker the release build asserts is absent.
///
/// `task.ps1 build` searches the packaged binary for this exact string, the same
/// way it does for `MarionetteBinding`. Kept as a top-level constant so it cannot
/// be tree-shaken away when the flag is off — a check that disappears when it
/// passes checks nothing.
const String kFakeCameraMarker = 'FAKE_CAMERA_VERIFICATION_ONLY';

/// The marker for [_useDirectCamera], asserted absent from release builds by
/// `task.ps1 build` for exactly the reason [kFakeCameraMarker] is.
///
/// The leak this guards against is subtler than the fake camera's. A stub that
/// answers everything is obviously wrong; a *real* client pointed at a
/// compile-time address is not wrong at all — it is a shipped build that ignores
/// the user's own camera and dials a hard-coded IP, which reads as "the app
/// cannot find my camera" and would be debugged as a network fault for a long
/// time before anyone suspected the build.
const String kDirectCameraMarker = 'DIRECT_CAMERA_VERIFICATION_ONLY';

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

/// The stub camera used by [_useFakeCamera].
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

/// The **real** client [_useDirectCamera] installs.
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

/// The locale tag the shell last saw on [AppState], for [YiM1ControllerApp].
///
/// ## Why a notifier up here rather than a `MaterialApp` inside the shell
///
/// The chosen language lives on `AppState`, which `_HomeShellState` constructs —
/// *below* `MaterialApp`. `MaterialApp.locale` has to be above it, because
/// `Localizations` is what every `AppLocalizations.of(context)` below reads. Lifting
/// the whole shell above `MaterialApp` would be a restructuring of the one file this
/// round is meant to touch least; a notifier is what the same file already does for
/// the other piece of state that is produced below and consumed above
/// ([_launchError]).
///
/// Defaults to [kLocaleSystem], so the frames before the preference file has been
/// read are drawn in the phone's own language rather than in a guess.
final ValueNotifier<String> _localeTag = ValueNotifier<String>(kLocaleSystem);

/// The app shell.
///
/// Material 3, dark by default, because this is a camera controller: it is used
/// next to a viewfinder, often at night, and a light UI next to the preview is
/// actively unpleasant.
///
/// The **mode badge** in the app bar is the visible half of the dual-firmware
/// design (see `analysis/08-ce-app-dual-mode.md`): the app never assumes a
/// patched camera, it reports what it found and disables what is unavailable with
/// an explanation rather than hiding it.
void main() {
  // `runZonedGuarded` comes **first**, and the binding is initialised inside it.
  //
  // That ordering is a bug fix, not tidiness. The binding used to be initialised
  // in the root zone while `runApp` ran inside a guarded child zone, and the
  // framework treats that mismatch as an error:
  //
  //   Zone mismatch. The Flutter bindings were initialized in a different zone
  //   than is now being used.
  //
  // It goes through `FlutterError.onError`, which this app sets to surface a
  // startup failure — so the app did not merely warn, it replaced its whole UI with
  // "The app failed to start" and the zone-mismatch text. **Every debug build was
  // broken this way** while release worked, because the check is debug-only, which
  // is why it survived: the artifact that gets tested by hand was the release one.
  //
  // It was found by driving the running app with `marionette` (see
  // `tools/marionette.ps1`) rather than by reading this file.
  runZonedGuarded(
    () {
      // `PaintingBinding.instance` throws unless a binding exists, and it throws
      // *before* `runApp`, which produces a splash screen that never goes away and
      // no error the user can see. So the binding comes first — inside this zone.
      //
      // The binding choice is where `marionette_flutter` hooks in; see
      // [_useMarionette] for why it is a compile-time flag rather than `kDebugMode`.
      if (_useMarionette) {
        MarionetteBinding.ensureInitialized();
      } else {
        WidgetsFlutterBinding.ensureInitialized();
      }

      // Bound the image cache before anything decodes.
      //
      // The live view repaints with a **new byte array every frame**, and
      // `MemoryImage` hashes the array's *identity* rather than its contents, so
      // every frame becomes a fresh cache entry. Decoded frames accumulate at
      // roughly 1.9 MB each, thirty times a second, on top of the encoded bytes —
      // enough to churn the default 100 MB cache and keep the eviction policy busy
      // for the whole preview. Evicting each frame by hand would mean reconstructing
      // the exact cache key (a `MemoryImage` plus whichever `cacheWidth` the widget
      // happened to use), which is fragile; a small ceiling achieves the same thing
      // robustly.
      //
      // Non-zero rather than zero so a frame already on screen is not evicted out
      // from under itself, which would show as a flash. It must not be fatal: an
      // optimisation that can prevent the app from launching is worse than the
      // memory churn it avoids.
      try {
        // 8 MiB of decoded images and 12 entries. This is the **Flutter image cache**,
        // which holds decoded bitmaps in memory — a different budget from the album's
        // on-disk thumbnail cache (`AlbumThumbnailCache`), and the two numbers are
        // unrelated even though both are "8 MB"-ish.
        PaintingBinding.instance.imageCache.maximumSizeBytes = 8 << 20; // 8 MiB
        PaintingBinding.instance.imageCache.maximumSize = 12;
      } on Object catch (e) {
        debugPrint('could not bound the image cache ($e); continuing');
      }

      // Surface a startup failure instead of sitting on the splash screen.
      //
      // A throw during the first build — a platform channel that is missing, a file
      // store that cannot be reached — otherwise leaves a **blank screen with no
      // explanation**, which is indistinguishable from a hang and gives the user
      // nothing to report. Recording the first error lets the shell render it.
      //
      // ## Why this is scoped to startup
      //
      // The first version recorded *any* `FlutterError` for the life of the
      // process, so a single mid-session failure replaced the entire app with
      // "The app failed to start" — permanently, because nothing ever cleared the
      // notifier. It was reported from hardware as a sporadic screen reading
      // `Exception: Invalid image data`: one corrupt preview frame (the camera and
      // the radio both produce them) was enough to end the session, and the text
      // told the user it was a start-up problem, which it was not.
      //
      // So the latch is armed only until the first frame is on screen. After that
      // an error is still printed, but the app keeps running — and the image path
      // has its own `errorBuilder`, so a bad frame does not reach here at all.
      FlutterError.onError = (details) {
        FlutterError.presentError(details);
        if (_starting) _launchError.value = details.exceptionAsString();
      };
      runApp(const YiM1ControllerApp());

      // Armed until the first frame is drawn. `addPostFrameCallback` runs after
      // the first successful build, which is the earliest point at which "the app
      // started" is a true statement.
      WidgetsBinding.instance.addPostFrameCallback((_) => _starting = false);
    },
    (e, s) {
      debugPrint('uncaught: $e\n$s');
      if (_starting) _launchError.value = '$e';
    },
  );
}

/// Whether the app is still in its first frame.
///
/// Gates [_launchError]: an error before the first frame means the app genuinely
/// could not start and the shell should say so, while an error afterwards is a
/// runtime problem the app is expected to survive.
bool _starting = true;

/// The first error seen while starting, if any.
///
/// A `ValueNotifier` rather than a callback because the shell may not be built
/// yet when the error arrives, and the shell needs to see one that happened
/// before it existed.
final ValueNotifier<String?> _launchError = ValueNotifier<String?>(null);

class YiM1ControllerApp extends StatelessWidget {
  /// The language tag to draw in, for a test that wants a specific one.
  ///
  /// Null — the production default — reads [_localeTag], which the shell keeps in
  /// step with `AppState.localeTag`. A test supplies a constant here when it is
  /// asserting what a locale *draws* rather than which locale was chosen; the
  /// end-to-end path (Settings → `AppState` → here → the painted text) is asserted
  /// separately in `test/l10n_locale_switch_test.dart`.
  final String? testLocaleTag;

  /// The shell to draw, for a test.
  ///
  /// Production passes nothing and gets `const HomeShell()`, which builds a
  /// plugin-backed BLE transport and reads two files — neither exists under
  /// `flutter test`. Supplying a shell built around `AppState(testHttp:)`
  /// (`test/fakes.dart`) is what makes the *locale path* testable end to end:
  /// `AppState.localeTag` → [_localeTag] → `MaterialApp.locale` → the painted string.
  /// Without this seam that path is only ever assembled in production, which is the
  /// "parts wired wrong" gap `analysis/41` §7.11 describes.
  final Widget? testHome;

  const YiM1ControllerApp({super.key, this.testLocaleTag, this.testHome});

  /// The same widget, pinned to [tag] — for a test that renders a locale directly.
  const YiM1ControllerApp.withLocale(String this.testLocaleTag, {super.key})
      : testHome = null;
  @override
  Widget build(BuildContext context) {
    final tag = testLocaleTag;
    return ValueListenableBuilder<String>(
      valueListenable: _localeTag,
      builder: (context, liveTag, _) => MaterialApp(
        // Resolved through the delegate rather than written as a literal: the task
        // switcher shows this, and an app that calls itself "M1 Controller" in the
        // Chinese task switcher while drawing Chinese everywhere else is exactly the
        // half-translated state this round exists to avoid.
        onGenerateTitle: (context) => l10nOf(context).appTitle,
        debugShowCheckedModeBanner: false,
        // The three delegates the generator emits: this app's strings, plus the
        // framework's own Material and Cupertino strings. Without the last two the
        // framework text (a platform dialog's buttons, a `Slider`'s semantics)
        // stays English no matter what locale is selected.
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        // `null` means "follow the phone", which is the default and the only
        // correct behaviour for a user who has never opened Settings.
        locale: localeFromTag(tag ?? liveTag),
        theme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.dark,
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF7DB3FF),
            brightness: Brightness.dark,
          ),
          scaffoldBackgroundColor: const Color(0xFF0E0E0E),
        ),
        home: testHome ?? const HomeShell(),
        builder: (context, child) => ValueListenableBuilder<String?>(
          valueListenable: _launchError,
          builder: (context, err, _) => err == null
              ? (child ?? const SizedBox.shrink())
              : _StartupError(
                  err,
                  // An escape hatch, deliberately. The diagnostic is only useful if
                  // the user can get past it: the failure may be in one subsystem,
                  // and the rest of the app is still worth reaching — that is how
                  // the error text gets reported at all.
                  onDismiss: () => _launchError.value = null,
                ),
        ),
      ),
    );
  }
}

/// What the user sees when the app could not start.
class _StartupError extends StatelessWidget {
  final String message;

  /// Lets the user past the diagnostic and into the app anyway.
  final VoidCallback? onDismiss;

  const _StartupError(this.message, {this.onDismiss});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    return Material(
      color: const Color(0xFF0E0E0E),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.error_outline,
                    color: Colors.redAccent, size: 40),
                const SizedBox(height: 12),
                Text(l.startupFailedTitle,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 10),
                Text(
                  l.startupFailedBody,
                  style: const TextStyle(
                      color: Colors.white54, fontSize: 12.5, height: 1.4),
                ),
                const SizedBox(height: 14),
                SelectableText(message,
                    style: const TextStyle(
                        color: Colors.orangeAccent,
                        fontSize: 12,
                        fontFamily: 'monospace',
                        height: 1.4)),
                if (onDismiss != null) ...[
                  const SizedBox(height: 18),
                  FilledButton.icon(
                    key: const ValueKey<String>('btn-startup-error-dismiss'),
                    onPressed: onDismiss,
                    icon: const Icon(Icons.arrow_forward, size: 18),
                    label: Text(l.continueToApp),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------

/// The app shell: a title bar, a two-tab body, and the firmware badge.
class HomeShell extends StatefulWidget {
  /// A ready-made state, for tests.
  ///
  /// `initState` builds the real dependencies — a plugin-backed BLE transport and a
  /// file-backed pairing store — which a widget test cannot supply. This is the same
  /// seam the rest of the project uses (`AppState(testHttp:, testIdentity:)`), lifted
  /// one level so the *shell* can be exercised: the build stamp lives in its app bar,
  /// and asserting it is worth more than asserting the app bar exists.
  final AppState? testApp;

  /// The first-run preferences, injected so a test can supply an in-memory store.
  ///
  /// Production passes nothing and gets the file-backed one. The seam exists because
  /// the **gate** below reads two files before it can decide whether to show the
  /// flow, and a widget test has no documents directory of its own.
  final OnboardingPrefs? onboardingPrefs;

  /// Force the flow on or off, for a test that wants to look at it.
  ///
  /// Null — the production default — means "let the shell decide", which is what the
  /// tests that verify the decision (`first_run_gate_test.dart`) need: they inject a
  /// prefs store and a pairing record and check what the shell does with them.
  ///
  /// A test that injects an [AppState] but **not** this gets the flow suppressed. Not
  /// a shortcut: the shell's decision is two file reads, and a widget test's fake-async
  /// zone never completes real I/O (`analysis/41` §7.9), so a shell test that awaits
  /// the decision hangs instead of failing. `testApp` already means "this state is
  /// supplied", and that extends to "the first run is done".
  final bool? showOnboarding;

  /// Where the recorded sync mode is handed over.
  ///
  /// Called with one of [kSyncModeIds] whenever the flow records an answer. The app
  /// passes nothing today, which is the one piece of wiring this change could not
  /// complete: `SyncEngine.mode` belongs to the album/sync layer, and the flow
  /// deliberately does not reach into it. `analysis/56-first-run-and-pairing.md` §6
  /// names the exact line the owner has to add; until then the answer is recorded
  /// and **not** applied, which is stated there rather than papered over.
  final void Function(String modeId)? onSyncModeRecorded;

  const HomeShell({
    super.key,
    this.testApp,
    this.onboardingPrefs,
    this.showOnboarding,
    this.onSyncModeRecorded,
  });

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  AppState? _app;
  String? _startupError;
  int _tab = 0;

  /// The durable first-run answers — the mode the user chose, and whether they have
  /// been through the flow at all.
  late final OnboardingPrefs _prefs;

  /// False until the gate has read its two files.
  ///
  /// The gate's question — *has this person paired before, and have they seen the
  /// flow* — is answered by two files, and **neither answer may be guessed**: showing
  /// the introduction to a returning user is the complaint this feature exists to
  /// avoid, and skipping it for a first-time user leaves them exactly where they
  /// were. So the first frame waits for the read rather than drawing a default.
  ///
  /// It is one `await` on two small local files, and what is on screen meanwhile is
  /// the app's own background colour — the same thing the frame after it shows.
  /// `test/first_run_gate_test.dart` asserts the flow appears when nothing is on
  /// file, which is the case that would break if this wait silently never finished.
  bool _booted = false;

  /// Whether the first-run flow should be on screen.
  bool _showOnboarding = false;

  @override
  void initState() {
    super.initState();
    // Every dependency is constructed here rather than in `main`, so a failure
    // lands inside the widget tree where it can be shown instead of before
    // `runApp`, where it leaves the splash screen up forever with no explanation.
    //
    // That is not hypothetical: this app hung on launch once already, because
    // `PaintingBinding.instance` was touched before any binding existed.
    // Constructing a plugin-backed transport is the same class of risk.
    //
    // The injected test state is also the only path allowed to skip the boot wait.
    // A widget test's fake-async zone never completes real file I/O
    // (`analysis/41` §7.9), and `testApp` means the test has already said which
    // state it wants — so asking the disk again would hang every existing shell
    // test for a fact the test has already provided.
    if (widget.testApp != null) {
      _app = widget.testApp;
      _bindLocale(_app!);
      _prefs = widget.onboardingPrefs ?? OnboardingPrefs();
      // A shell test that injects a state is not asked to sit through the gate's two
      // file reads — see [HomeShell.showOnboarding]. A test that *is* about the
      // decision passes `showOnboarding` explicitly and gets it.
      _showOnboarding = widget.showOnboarding ?? false;
      _booted = true;
      return;
    }
    try {
      final pairing = FilePairingStore();
      _app = AppState(
        ble: FlutterBlueBleTransport(),
        // Persisted, because the camera holds only one pairing and creating it
        // needs a physical confirmation on the camera body. An in-memory store
        // sends the user back to the camera on every app launch.
        store: pairing,
        // Without this the app can only *tell* the user to join the camera's
        // network by hand. Supplying the platform delegate lets Android raise its
        // own one-tap consent dialog instead.
        wifiJoin: PlatformWifiJoinDelegate(),
        // Compile-time only; absent from every real build. See [_useFakeCamera].
        //
        // `DIRECT_CAMERA` takes precedence over `FAKE_CAMERA` when both are set:
        // they are two answers to the same question ("what is the app talking
        // to?"), and preferring the honest one — a real socket to a real camera —
        // means a run that set both by accident still produces usable evidence.
        testHttp: _useDirectCamera
            ? directCameraHttp()
            : (_useFakeCamera ? fakeVerificationHttp() : null),
        testAlbumDownload:
            _useFakeCamera ? fakeCameraThumbnail : null,
        testIdentity: _useDirectCamera
            ? kDirectCameraIdentity
            : (_useFakeCamera
                ? const CameraIdentity(
                    protocolVersion: 1,
                    firmwareVersion: '3.1-cn ',
                    regionMarker: 'M1CN',
                  )
                : null),
      );
      _prefs = widget.onboardingPrefs ?? _filePrefs();
      _bindLocale(_app!);
      unawaited(_decide(pairing));
    } on Object catch (e, s) {
      debugPrint('AppState construction failed: $e\n$s');
      _startupError = '$e';
      // A failed construction must not leave the shell on its boot frame forever:
      // `_StartupError` is the screen that explains what happened, and it is drawn
      // from `_app == null` below.
      _prefs = widget.onboardingPrefs ?? OnboardingPrefs();
      _booted = true;
    }
  }

  /// The file-backed preferences, beside the ledger and the UI layout.
  static OnboardingPrefs _filePrefs() => OnboardingPrefs(
        store: PrefsStore(),
        onLog: (m) => debugPrint(m),
      );

  /// Keep [_localeTag] — and through it `MaterialApp.locale` — in step with the state.
  ///
  /// A listener rather than a read inside `build`: the tag changes when the *user*
  /// changes it in Settings, which is not a rebuild of this widget, and reading it
  /// during a build would leave the `MaterialApp` one frame behind the button press.
  /// The first assignment is the file's remembered answer, applied before the shell
  /// has drawn anything in the wrong language.
  void _bindLocale(AppState app) {
    app.addListener(_syncLocale);
    _syncLocale();
  }

  void _syncLocale() {
    final app = _app;
    if (app == null) return;
    if (_localeTag.value == app.localeTag) return;
    // `_bindLocale` runs from `initState`, which is inside the build phase — and
    // `ValueNotifier.value =` marks the `ValueListenableBuilder` above this widget
    // dirty, which the framework rejects mid-build
    // (`setState() or markNeedsBuild() called during build`). Deferring to the end of
    // the frame is the fix rather than a workaround: the tag is applied before the
    // next frame is composited either way, and the only thing that would be lost by
    // reading it a frame earlier is nothing at all — the remembered preference arrives
    // from an async file read and cannot be known during `initState` anyway.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final a = _app;
        if (a != null && _localeTag.value != a.localeTag) {
          _localeTag.value = a.localeTag;
        }
      });
      return;
    }
    _localeTag.value = app.localeTag;
  }

  /// Decide whether to run the first-run flow, then let the shell draw.
  ///
  /// Two independent reasons to skip it, and both are needed:
  ///
  /// 1. **The user has been through it** — [OnboardingPrefs.onboardingDone], set by
  ///    finishing *and* by skipping.
  /// 2. **The user has paired before.** This is the one that matters for anybody
  ///    upgrading from a build that had no onboarding at all: they have no
  ///    preference file, so reason 1 says "first run", and only the stored pairing
  ///    record can tell the truth. Walking a returning user through the
  ///    introduction would be a regression introduced by *adding* a feature.
  ///
  /// The pairing record's test is `hasWifiCredentials` rather than
  /// `canReuseSession`: a session token can be forgotten deliberately (the
  /// connection layer drops one the camera refused), while the stored SSID and
  /// passkey are the marks of a pairing that actually happened.
  Future<void> _decide(FilePairingStore pairing) async {
    var seen = false;
    var paired = false;
    try {
      await _prefs.load();
      seen = _prefs.onboardingDone;
      paired = PairingRecord.fromMap(await pairing.load()).hasWifiCredentials;
    } on Object catch (e) {
      // Neither file is worth a failed launch, and the safe default is the one that
      // does not put a new screen in front of somebody who was trying to reach the
      // camera — the app worked without onboarding for its whole life until now.
      debugPrint('first-run gate: unreadable state ($e); not showing the flow');
      seen = true;
    }
    if (!mounted) return;
    setState(() {
      _showOnboarding = widget.showOnboarding ?? (!seen && !paired);
      _booted = true;
    });
    debugPrint('first-run gate: seen=$seen paired=$paired '
        'show=$_showOnboarding');
  }

  /// Record an answer from the flow and hand it on.
  ///
  /// The write happens inside the flow (`OnboardingPrefs.save`), because it owns the
  /// preference; what happens here is the hand-over, which is the part the app shell
  /// is the only place for.
  /// Hand the recorded mode to the running engine.
  ///
  /// ## Why this is not just a log line
  ///
  /// It was: `_onSyncModeRecorded` printed the choice and called an optional callback that
  /// **nothing ever supplied** — `HomeShell()` is constructed without arguments — so the
  /// preference was written correctly and read correctly at the *next* launch, and did
  /// nothing at all in the session where the user actually chose it. Pick "Manual — only
  /// what I pick", open the Sync tab, and the dropdown still shows the default. That is the
  /// same shape as the defect this round is about: a value recorded in one place and never
  /// reaching the thing that acts on it.
  ///
  /// The engine is set directly rather than through `AppState.setSyncMode`, which takes the
  /// listed files so it can re-derive the queue. There is nothing to re-derive here: the
  /// first run happens before any listing exists. The plain setter notifies, so every
  /// listener sees the choice immediately.
  void _onSyncModeRecorded(String modeId) {
    widget.onSyncModeRecorded?.call(modeId);
    _app?.sync.mode = syncModeFromId(modeId);
    debugPrint('first-run: sync mode recorded as $modeId');
  }

  void _finishOnboarding() {
    if (!_showOnboarding) return;
    setState(() => _showOnboarding = false);
  }

  /// Push the flow again, from the app bar.
  void _openGuide() {
    final app = _app;
    if (app == null) return;
    openFirstRunFlow(
      context,
      app: app,
      prefs: _prefs,
      // A revisit decides nothing on the user's behalf: they came back to change one
      // answer or to read the pairing steps, and leaving without touching anything
      // must leave everything as it was.
      entry: FirstRunEntry.revisit,
      onModeChosen: _onSyncModeRecorded,
      onExited: () => debugPrint('first-run: guide closed'),
    );
  }

  @override
  void dispose() {
    _app?.removeListener(_syncLocale);
    _app?.dispose();
    super.dispose();
  }

  Future<void> _confirmDisconnect(BuildContext context) async {
    final l = l10nOf(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.disconnectTitle),
        content: Text(l.disconnectBody),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(l.cancel)),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(l.disconnect)),
        ],
      ),
    );
    if (ok == true) await _app?.disconnect();
  }

  @override
  Widget build(BuildContext context) {
    final app = _app;
    if (app == null) {
      return _StartupError(
          _startupError ?? l10nOf(context).startupUnknownError);
    }
    if (!_booted) {
      // The frame or two between launch and the gate's answer. Deliberately the same
      // colour as the shell's own background: the alternative — guessing — either
      // shows a returning user an introduction they have already dismissed or shows
      // a first-time user nothing at all, and both are worse than two blank frames.
      return const Scaffold(
        key: ValueKey<String>('first-run-boot'),
        backgroundColor: Color(0xFF0E0E0E),
        body: SizedBox.expand(),
      );
    }
    return Stack(
      children: [
        Positioned.fill(child: _shell(app)),
        // The first-run flow, when it is the gate's answer.
        //
        // A `Stack` sibling rather than a route: it is not a place the user navigated
        // to, and the back gesture must not dismiss it into a state where the app has
        // been "seen" without the user ever having seen it. The flow's own Skip button
        // is the only way past it, which is what makes the recorded decision honest.
        //
        // `_showOnboarding` is set only after the gate has read both files, so this
        // branch cannot flash an introduction at a returning user for a frame.
        if (_showOnboarding)
          Positioned.fill(
            child: FirstRunFlow(
              app: app,
              prefs: _prefs,
              entry: FirstRunEntry.firstRun,
              onModeChosen: _onSyncModeRecorded,
              onFinished: _finishOnboarding,
            ),
          ),
      ],
    );
  }

  Widget _shell(AppState app) {
    return AnimatedBuilder(
      animation: app,
      builder: (context, _) {
        final l = l10nOf(context);
        return Scaffold(
        key: const ValueKey<String>('nav-shell'),
        // Hidden in full-screen mode so the live view gets the whole window — the
        // point of the mode is that the status strip, the picture and the controls are
        // not squeezed by the shell's own chrome. `null` rather than a zero-height
        // `AppBar`, which would still reserve its status-bar inset.
        appBar: app.fullScreen
            ? null
            : AppBar(
          backgroundColor: const Color(0xFF151515),
          foregroundColor: Colors.white,
          // Scaled down rather than allowed to overflow.
          //
          // The title holds the app name, the firmware badge and the build stamp, and on
          // a 411dp phone that row wanted 352dp inside a 283dp box —
          // `A RenderFlex overflowed by 69 pixels on the right`, found by
          // `test/build_stamp_test.dart` as soon as the stamp was added.
          //
          // `scaleDown` is the same mechanism the live view uses for its bands: it only
          // ever shrinks, and only when the row genuinely does not fit, so a wide phone
          // or a short firmware string is unaffected.
          title: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Row(
              children: [
                Text(l.appTitle, style: const TextStyle(fontSize: 16)),
                const SizedBox(width: 10),
                _FirmwareBadge(app: app),
                const SizedBox(width: 8),
                const _BuildStamp(),
              ],
            ),
          ),
          actions: [
            // The way back into the first-run flow, at **every** link state.
            //
            // A flow the user cannot re-open is a trap the moment they change their
            // mind, and the one answer it records — the sync mode — is exactly the
            // kind of choice people revise. It is not hidden while connected either:
            // the sync mode is a decision about the app, not about the current link,
            // and a help entry that disappears as soon as the app works is the
            // discoverability defect `AGENTS.md` §7.1 describes.
            //
            // An `IconButton` rather than a `PopupMenuButton` on purpose. The title
            // row above already needed `scaleDown` because it wanted 352dp in a 283dp
            // box; a popup menu reserves an intrinsic 48dp plus an 8dp arrow and is
            // laid out **at its natural size** rather than scaled, so on the 411dp
            // body it is what would overflow next.
            IconButton(
              key: const ValueKey<String>('btn-first-run-guide'),
              tooltip: l.guideTooltip,
              onPressed: _openGuide,
              icon: const Icon(Icons.help_outline),
            ),
            // Manual disconnect. The camera's access point costs it battery and
            // admits one client, so leaving it up because the app was backgrounded
            // is rude to the hardware.
            if (app.link.isReady || app.link.isLost)
              IconButton(
                key: const ValueKey<String>('btn-disconnect-camera'),
                tooltip: l.disconnectTooltip,
                onPressed: () => _confirmDisconnect(context),
                icon: const Icon(Icons.link_off),
              ),
            IconButton(
              key: const ValueKey<String>('btn-check-camera'),
              tooltip: l.checkCameraTooltip,
              onPressed: app.link.isReady
                  ? () async {
                      final ok = await app.verifyAlive();
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content:
                            Text(ok ? l.cameraResponding : l.cameraSilent),
                        duration: const Duration(seconds: 2),
                      ));
                    }
                  : null,
              icon: const Icon(Icons.wifi_tethering),
            ),
            // Licences and the "who made this" statement: the app bundles
            // Apache-2.0, MIT and BSD-3-Clause code, and a licence page is how those
            // notices reach someone who installed an APK rather than a tarball
            // (`analysis/63` §7.2). Reachable at every link state, like the guide
            // button above — the licence does not depend on the camera being on.
            IconButton(
              key: const ValueKey<String>('btn-licences'),
              tooltip: l.licencesTooltip,
              onPressed: () => showAppLicences(context),
              icon: const Icon(Icons.info_outline),
            ),
          ],
        ),
        body: IndexedStack(
          index: _tab,
          children: [
            LiveViewPage(app: app),
            AlbumPage(app: app),
          ],
        ),
        bottomNavigationBar: app.fullScreen
            ? null
            : NavigationBar(
                selectedIndex: _tab,
                onDestinationSelected: (i) => setState(() => _tab = i),
                height: 58,
                labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
                destinations: [
                  NavigationDestination(
                    icon: const Icon(Icons.camera_outlined),
                    selectedIcon: const Icon(Icons.camera),
                    label: l.navCapture,
                  ),
                  NavigationDestination(
                    icon: const Icon(Icons.photo_library_outlined),
                    selectedIcon: const Icon(Icons.photo_library),
                    label: l.navSync,
                  ),
                ],
              ),
        );
      },
    );
  }
}

/// Which build this is, in the app bar.
///
/// ## Why this exists
///
/// A release APK was installed on hardware and reported as not containing UI fixes that
/// had been verified on the emulator. Checking the shipped binary showed the fixes
/// **were** in it — but there was no way for either side to say *which build* was
/// running, so the report could not be settled by looking. That is the gap this closes.
///
/// It is deliberately in the app bar rather than behind a diagnostics sheet: the
/// question "is this the build I just made" is asked while looking at the screen, and an
/// answer that needs three taps is an answer nobody gets.
///
/// The value comes from `--dart-define=BUILD_STAMP=...`, which `tools/task.ps1 build`
/// fills with the short commit and the build time. It reads `dev` for a `flutter run`,
/// which is itself useful: it says the binary came from a working tree rather than from
/// a stamped build.
class _BuildStamp extends StatelessWidget {
  const _BuildStamp();

  /// `String.fromEnvironment` resolves at **compile time**, so a release build with no
  /// stamp carries the literal `dev` and nothing else — the value cannot be changed by
  /// anything at runtime, including a file on the device.
  static const String stamp = String.fromEnvironment('BUILD_STAMP', defaultValue: 'dev');

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey<String>('build-stamp'),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.white10,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        stamp,
        style: const TextStyle(fontSize: 10.5, color: Colors.white54, height: 1.3),
      ),
    );
  }
}

/// Shows which firmware behaviour the app is talking to.///
/// The app works fully against a **stock** camera: live view, capture, parameters
/// and full-resolution album download were all verified on unmodified firmware.
/// The badge exists so that when a patched camera *is* present the user can see
/// the app noticed — and so a limitation is attributed to the right place.
class _FirmwareBadge extends StatelessWidget {
  final AppState app;
  const _FirmwareBadge({required this.app});

  @override
  Widget build(BuildContext context) {
    final id = app.link.identity;
    if (id == null) {
      return _Badge(text: l10nOf(context).firmwareNotConnected, muted: true);
    }
    return _Badge(text: id.firmwareVersion.trim(), muted: false);
  }
}

class _Badge extends StatelessWidget {
  final String text;
  final bool muted;
  const _Badge({required this.text, required this.muted});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: muted ? Colors.white12 : Colors.blueGrey.shade700,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(text,
          style: const TextStyle(fontSize: 11, color: Colors.white70, height: 1.4)),
    );
  }
}

