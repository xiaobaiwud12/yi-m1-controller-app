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
bool get useMarionette {
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
/// settings second level, the album grid, the paused-preview banner. Without a
/// camera or virtual BLE peripheral, the normal connection path cannot reach
/// those screens. Supported emulators can run a virtual BLE camera (see
/// `analysis/58`); this flag is the shorter path for UI-only verification.
///
/// This flag fabricates the connection instead: the same `testHttp`/`testIdentity`
/// seam the widget tests already use (`test/fakes.dart`), wired in at startup.
/// The camera is never contacted — every command is answered by a stub.
///
/// ## Why it cannot reach a user
///
/// Identical reasoning to [useMarionette], and it matters more here because a
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
bool get useFakeCamera {
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
/// This route skips BLE even when the emulator supports virtual peripherals.
/// It requires a real camera and the host to be on its access point. The
/// emulator can reach the camera's IP directly: its slirp user-mode
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
/// Same reasoning as [useFakeCamera], and the same two independent guards:
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
bool get useDirectCamera {
  const asBool = bool.fromEnvironment('DIRECT_CAMERA');
  const asString = String.fromEnvironment('DIRECT_CAMERA');
  return asBool || asString == '1' || asString == 'true';
}

/// Where [useDirectCamera] points.
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
/// way it does for `MarionetteBinding`. The fake-camera branch references this
/// marker when enabled; without the flag it must disappear from the shipped
/// binary. The independent APK scan keeps its own expected marker string.
const String kFakeCameraMarker = 'FAKE_CAMERA_VERIFICATION_ONLY';

/// The marker for [useDirectCamera], asserted absent from release builds by
/// `task.ps1 build` for exactly the reason [kFakeCameraMarker] is.
///
/// The leak this guards against is subtler than the fake camera's. A stub that
/// answers everything is obviously wrong; a *real* client pointed at a
/// compile-time address is not wrong at all — it is a shipped build that ignores
/// the user's own camera and dials a hard-coded IP, which reads as "the app
/// cannot find my camera" and would be debugged as a network fault for a long
/// time before anyone suspected the build.
const String kDirectCameraMarker = 'DIRECT_CAMERA_VERIFICATION_ONLY';
