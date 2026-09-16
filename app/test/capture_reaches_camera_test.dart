import 'package:flutter_test/flutter_test.dart';
import 'package:yi_m1_controller/transport/capture_guard.dart';
import 'package:yi_m1_controller/transport/http_transport.dart';

/// An enabled shutter must put `RCDoShooting` on the wire.
///
/// ## The question this settles
///
/// Reported from hardware: "the shutter does nothing, and I suspect the app misjudged
/// the camera's state and never sent the command". That is a real possibility — four of
/// the five gates refuse **before touching the network**, and from the outside a gate
/// that declines is indistinguishable from a camera that refuses.
///
/// The screenshots did suggest the command went out: the shutter was drawn **enabled**
/// (a large white button) immediately before the press, and an enabled shutter means
/// `shutterBlockedReason` was null, so nothing in `AppState` was gating it. But "the
/// reasoning looks sound" is not evidence, and the two cases need opposite fixes — so
/// this asserts the wire traffic instead.
void main() {
  test('a first press reaches the camera and reports what it said', () async {
    final sent = <String>[];
    final logged = <String>[];

    final g = CaptureGuard(
      http: () => CameraHttpClient(overrideSend: (command, params) async {
        sent.add(command);
        // Exactly what the camera is believed to answer for a stranded capture state.
        return const CameraResponse(
          code: 1000,
          data: 'photo fail',
          raw: '{"code":1000,"data":"photo fail"}',
        );
      }),
      log: logged.add,
      minInterval: Duration.zero,
    );

    final r = await g.shoot();

    expect(sent, contains('RCDoShooting'),
        reason: 'an interlock that is not quarantined must send the command; if this '
            'fails the shutter is being stopped inside the app and the camera is being '
            'blamed for it');
    expect(r.outcome, CaptureOutcome.rejected);
    // The reply is carried out, so the UI can show what the camera actually said
    // rather than a sentence the app composed.
    expect(r.response?.raw, contains('photo fail'));
    expect(logged.join('\n'), contains('RCDoShooting'),
        reason: 'the log is how the next bug report distinguishes the two cases');
    expect(logged.join('\n'), contains('code=1000'));
  });

  test('a quarantined guard does NOT send, and the log says so', () async {
    final sent = <String>[];
    final logged = <String>[];
    final g = CaptureGuard(
      http: () => CameraHttpClient(overrideSend: (command, params) async {
        sent.add(command);
        if (command == 'RCDoShooting') {
          return const CameraResponse(
              code: 1000, data: 'photo fail', raw: '{"code":1000}');
        }
        return const CameraResponse(code: 200, data: 'ok', raw: '{"code":200}');
      }),
      log: logged.add,
      minInterval: Duration.zero,
    );

    await g.shoot();
    sent.clear();
    // Immediately again: inside the cool-down, so it must decline without sending.
    final second = await g.shoot();

    expect(second.outcome, CaptureOutcome.blocked);
    expect(sent, isEmpty,
        reason: 'the whole point of the cool-down is that nothing leaves the app; a '
            'blocked attempt that still fired would be the overlap this guard exists '
            'to prevent');
  });
}
