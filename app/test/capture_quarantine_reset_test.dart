import 'package:flutter_test/flutter_test.dart';
import 'package:yi_m1_controller/transport/capture_guard.dart';
import 'package:yi_m1_controller/transport/http_transport.dart';

/// A power cycle must clear the capture interlock.
///
/// ## The bug
///
/// `CaptureGuard` had no idea when the link went away. Its quarantine — "this camera
/// session's capture state is suspect" — therefore outlived the camera it was about.
///
/// That is backwards for the one recovery that works. Stranded capture-state flags are
/// cleared only by a power cycle (`analysis/40`, `analysis/43` §1), and a power cycle
/// drops the camera's access point, so the app reconnects to a **fresh** camera while
/// still refusing to shoot at it. Reported from hardware as: the shutter is stuck,
/// "Release anyway" changes nothing, and the message says the state is stuck — on a
/// camera that had just been restarted.
///
/// `onLinkLost` is the one place the guard forgets without a health probe, and it is
/// safe because there is no capture in flight over a link that no longer exists.
void main() {
  /// A guard whose camera always answers `photo fail`, i.e. the stranded state.
  CaptureGuard stranded() => CaptureGuard(
        http: () => CameraHttpClient(overrideSend: (command, params) async {
          if (command == 'RCDoShooting') {
            return const CameraResponse(
              code: 1000,
              data: 'photo fail',
              raw: '{"code":1000,"data":"photo fail"}',
            );
          }
          return const CameraResponse(code: 200, data: 'ok', raw: '{"code":200}');
        }),
        // No live-view signal, so the health probe rests on HTTP alone — which lets the
        // test drive the quarantine without simulating a stream.
      );

  test('a refused capture quarantines the shutter', () async {
    final g = stranded();
    final r = await g.shoot();
    expect(r.outcome, CaptureOutcome.rejected);
    expect(g.isQuarantined, isTrue,
        reason: 'photo fail is the hang precursor and must stop further captures');
  });

  test('the quarantine survives an unrelated probe', () async {
    final g = stranded();
    await g.shoot();
    // The camera answers HTTP fine; only the capture state is suspect. A probe that
    // passes must not be read as "captures work again" — that is the assumption the
    // firmware evidence falsifies: nothing but the ready branch clears the flags.
    expect(g.isQuarantined, isTrue);
  });

  test('losing the link clears the quarantine', () async {
    final g = stranded();
    await g.shoot();
    expect(g.isQuarantined, isTrue);

    // The camera is power-cycled, which drops its access point.
    g.onLinkLost();

    expect(g.isQuarantined, isFalse,
        reason: 'the quarantine was a verdict about the old camera session; the user '
            'power-cycled it, reconnected, and the app still refused to shoot');
    expect(g.isBusy, isFalse,
        reason: 'a reservation cannot be in flight over a link that no longer exists, '
            'and leaving it set would block every later press before the network is '
            'even touched');
  });

  test('the camera can be shot again after a reconnect', () async {
    var refuse = true;
    final g = CaptureGuard(
      http: () => CameraHttpClient(overrideSend: (command, params) async {
        if (command == 'RCDoShooting' && refuse) {
          return const CameraResponse(
              code: 1000, data: 'photo fail', raw: '{"code":1000}');
        }
        return const CameraResponse(code: 200, data: 'ok', raw: '{"code":200}');
      }),
    );

    expect((await g.shoot()).outcome, CaptureOutcome.rejected);
    g.onLinkLost();
    // Same camera, restarted: now it accepts.
    refuse = false;
    expect((await g.shoot()).outcome, CaptureOutcome.ok,
        reason: 'after a power cycle and reconnect the shutter must work again');
  });
}
