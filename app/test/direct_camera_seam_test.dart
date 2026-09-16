import 'package:flutter_test/flutter_test.dart';
import 'package:yi_m1_controller/app.dart';

/// The `DIRECT_CAMERA` seam must stay a **real** camera client.
///
/// ## Why this test exists
///
/// `DIRECT_CAMERA` and `FAKE_CAMERA` both make the connected screens reachable
/// on a desk, so they look interchangeable from the outside and it would be easy
/// to collapse one into the other while tidying up. They are not interchangeable,
/// and the difference is the entire value of this one:
///
/// * `FAKE_CAMERA` answers every command from a stub, so a preview it "renders"
///   is evidence about the stub;
/// * `DIRECT_CAMERA` fabricates only the BLE step and dials a real address over a
///   real socket, so a preview it renders is evidence about the camera, the
///   emulator's NAT, and the host bridge — which is the only reason it was added
///   (`analysis/46`).
///
/// If this seam ever grew an `overrideSend`, every emulator run would keep
/// passing while testing nothing, and nothing else in the project would notice:
/// the checks that exist are about the *release* artifact, and this flag is
/// absent from it by design.
void main() {
  test('the direct camera seam is a real client, not the stub', () {
    final direct = directCameraHttp();
    expect(direct.overrideSend, isNull,
        reason: 'DIRECT_CAMERA must reach a socket; a stub here would make every '
            'emulator run evidence about the stub instead of the camera');

    // The contrast that makes the assertion above meaningful: the other seam
    // *is* a stub, so `overrideSend == null` distinguishes them rather than
    // being true of both.
    expect(fakeVerificationHttp().overrideSend, isNotNull);
  });

  test('the direct camera seam dials the configured address', () {
    expect(directCameraHttp().host, kDirectCameraHost);
    expect(directCameraHttp().port, kDirectCameraPort);
    // A test runs without any `--dart-define`, so these are the defaults the
    // `String/int.fromEnvironment` fallbacks supply. Asserting them by value
    // rather than against the constants is deliberate: a changed default would
    // silently retarget every emulator run, and the constants would follow it.
    expect(kDirectCameraHost, '192.168.0.10',
        reason: "the camera's fixed address, so the ordinary emulator run needs "
            'no arguments');
    expect(kDirectCameraPort, 80);
  });

  test('the direct camera seam does not invent a firmware identity', () {
    // The badge exists so a screenshot can settle *which* camera answered. The
    // real value comes from the firmware-info characteristic, and this path never
    // read it — so claiming `3.1-cn` here would be a fabricated measurement, and
    // `isChinaModel` would then gate MOD-only features on a value nobody checked.
    expect(kDirectCameraIdentity.firmwareVersion, 'direct');
    expect(kDirectCameraIdentity.regionMarker, 'DIRECT');
    expect(kDirectCameraIdentity.isChinaModel, isFalse);
  });

  test('the markers the release build greps for are non-empty', () {
    // `tools/task.ps1 build` searches the packaged dex/so for these exact
    // strings. An empty or renamed constant would make that search succeed
    // unconditionally — a check that cannot fail.
    expect(kFakeCameraMarker, isNotEmpty);
    expect(kDirectCameraMarker, isNotEmpty);
    expect(kDirectCameraMarker, isNot(kFakeCameraMarker));
  });
}
