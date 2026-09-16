import 'package:flutter_test/flutter_test.dart';
import 'package:yi_m1_controller/transport/capture_guard.dart';
import 'package:yi_m1_controller/transport/http_transport.dart';

/// A burst must never be started by an app that cannot stop it.
///
/// ## What happened on hardware
///
/// With the camera's drive mode set to **Continuous**, a **brief tap** of the shutter — not
/// even a long press — made the camera burst immediately and keep bursting until it locked
/// up. The user recovered it by pulling the battery.
///
/// ## Why it was ours
///
/// The official app's `LiveViewFragment.onTouch` (line 1387) treats the shutter as a
/// **hold**: `ACTION_DOWN` only focuses and, for Continuous/Bulb/Time, returns without
/// shooting; `ACTION_UP` is what fires. A burst is then ended by a **separate** command —
/// `RCCancelShooting` (`C3701b.m17028g`) or `RCCancelShooting1` for long exposures
/// (`m17031h`).
///
/// This app sent `RCDoShooting` and **never either cancel**. So in Continuous it started
/// something it had no way to stop. Both cancel commands were already in the command table;
/// nothing was missing but their use.
///
/// The fix under test is the interlock, not the burst feature: until hold-to-burst is
/// implemented and verified on hardware, the app declines and says why.
void main() {
  CaptureGuard guardWith(String drive, {List<String>? sent}) => CaptureGuard(
        http: () => CameraHttpClient(overrideSend: (command, params) async {
          sent?.add(command);
          return const CameraResponse(code: 200, data: 'ok', raw: '{"code":200}');
        }),
        driveMode: () => drive,
        minInterval: Duration.zero,
      );

  group('a drive mode whose burst cannot be stopped is refused', () {
    for (final mode in ['Continuous', '2SDelay', '10SDelay']) {
      test('$mode is refused, and nothing is sent', () async {
        final sent = <String>[];
        final r = await guardWith(mode, sent: sent).shoot();

        expect(r.outcome, CaptureOutcome.blocked,
            reason: 'in $mode one RCDoShooting makes the camera burst until it locks '
                'up, and this app has no cancel command wired up. Starting it is the '
                'defect that cost a battery pull');
        expect(sent, isEmpty,
            reason: 'a guard that declines must not have already sent the command — '
                'the whole point is that the burst never begins');
        expect(r.reason, contains(mode),
            reason: 'the message has to name the mode, or the user cannot act on it');
      });
    }
  });

  group('Single is the mode where one request means one frame', () {
    test('Single is allowed to shoot', () async {
      final sent = <String>[];
      final r = await guardWith('Single', sent: sent).shoot();

      expect(r.outcome, CaptureOutcome.ok);
      expect(sent, contains('RCDoShooting'));
    });

    test('an unknown or missing drive mode does not block shooting', () async {
      // The status JSON may not have arrived yet. Refusing then would make the shutter
      // unusable for the first moments after connecting, which is a worse failure than
      // the one being guarded against — and the default this camera reports is Single.
      final sent = <String>[];
      final r = await guardWith('', sent: sent).shoot();

      expect(r.outcome, CaptureOutcome.ok);
      expect(sent, contains('RCDoShooting'));
    });
  });
}
