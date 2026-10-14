import 'package:flutter/foundation.dart';

import '../platform/file_pairing_store.dart';
import '../platform/flutter_ble_transport.dart';
import '../platform/onboarding_prefs.dart';
import '../platform/wifi_joiner.dart';
import '../protocol/wire_format.dart';
import '../state/app_state.dart';
import 'configuration.dart';
import 'verification_camera.dart';

/// Constructed inside the shell's startup error boundary, never before runApp.
class AppDependencies {
  final AppState state;
  final FilePairingStore pairing;
  final OnboardingPrefs onboardingPrefs;

  const AppDependencies(this.state, this.pairing, this.onboardingPrefs);
}

AppDependencies createAppDependencies({OnboardingPrefs? onboardingPrefs}) {
  final pairing = FilePairingStore();
  final state = AppState(
    ble: FlutterBlueBleTransport(),
    // Persisted, because the camera holds only one pairing and creating it
    // needs a physical confirmation on the camera body. An in-memory store
    // sends the user back to the camera on every app launch.
    store: pairing,
    // Without this the app can only *tell* the user to join the camera's
    // network by hand. Supplying the platform delegate lets Android raise its
    // own one-tap consent dialog instead.
    wifiJoin: PlatformWifiJoinDelegate(),
    // Compile-time only; absent from every real build. See [useFakeCamera].
    //
    // `DIRECT_CAMERA` takes precedence over `FAKE_CAMERA` when both are set:
    // they are two answers to the same question ("what is the app talking
    // to?"), and preferring the honest one — a real socket to a real camera —
    // means a run that set both by accident still produces usable evidence.
    testHttp: useDirectCamera
        ? directCameraHttp()
        : (useFakeCamera ? fakeVerificationHttp() : null),
    testAlbumDownload: useFakeCamera ? fakeCameraThumbnail : null,
    testIdentity: useDirectCamera
        ? kDirectCameraIdentity
        : (useFakeCamera
            ? const CameraIdentity(
                protocolVersion: 1,
                firmwareVersion: '3.1-cn ',
                regionMarker: 'M1CN',
              )
            : null),
  );
  final prefs = onboardingPrefs ??
      OnboardingPrefs(store: PrefsStore(), onLog: (m) => debugPrint(m));
  return AppDependencies(state, pairing, prefs);
}
