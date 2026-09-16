import 'package:flutter_test/flutter_test.dart';
import 'package:yi_m1_controller/transport/capture_guard.dart';
import 'package:yi_m1_controller/transport/http_transport.dart';

/// A burst must always be stoppable. That is the whole requirement.
///
/// ## What this exists for
///
/// With the drive mode in **Continuous**, a brief tap of the shutter made the camera burst
/// until it locked up and had to be recovered by pulling the battery. The app sent
/// `RCDoShooting` and had no way to end what it started — while the official app treats the
/// shutter as a **hold** (`LiveViewFragment.onTouch`, line 1387) and ends a capture with
/// `RCCancelShooting` (`C3701b.m17028g`) or `RCCancelShooting1` for long exposures
/// (`m17031h`). Both names were already in `http_commands.dart`.
///
/// ## What is established here and what is not
///
/// These checks pin the **contract**: a start is only believed after the camera
/// acknowledges it, a stop always goes out, and a stop is never gated by the interlock.
/// They do **not** establish what the camera does with `RCCancelShooting` — [H], see
/// [CaptureGuard.cancelShootingCommand]. That needs hardware.
void main() {
  ({CaptureGuard guard, List<String> sent}) make(
      {String drive = 'Continuous', bool startOk = true}) {
    final sent = <String>[];
    final guard = CaptureGuard(
      http: () => CameraHttpClient(overrideSend: (command, params) async {
        sent.add(command);
        if (command == 'RCDoShooting' && !startOk) {
          return const CameraResponse(
              code: 1000, data: 'photo fail', raw: '{"code":1000}');
        }
        return const CameraResponse(code: 200, data: 'ok', raw: '{"code":200}');
      }),
      driveMode: () => drive,
      minInterval: Duration.zero,
    );
    return (guard: guard, sent: sent);
  }

  group('starting a burst', () {
    test('only in a bursting drive mode', () async {
      final single = make(drive: 'Single');
      final r = await single.guard.startBurst();
      expect(r.outcome, CaptureOutcome.blocked);
      expect(single.sent, isEmpty,
          reason: 'Single takes one frame per request; a "hold" there is a stray second '
              'request, which is the overlap this guard exists to prevent');
    });

    test('is not believed until the camera acknowledges it', () async {
      final refused = make(startOk: false);
      final r = await refused.guard.startBurst();

      expect(r.outcome, isNot(CaptureOutcome.ok));
      expect(refused.guard.burstActive, isFalse,
          reason: 'a refused start that still set the flag would make a release send a '
              'cancel for a burst that never began, and the UI claim one that is not '
              'running');
    });

    test('a second start while one is running is refused', () async {
      final g = make();
      await g.guard.startBurst();
      final second = await g.guard.startBurst();

      expect(second.outcome, CaptureOutcome.blocked);
      expect(g.sent.where((c) => c == 'RCDoShooting').length, 1,
          reason: 'two overlapping capture requests are what strands the camera');
    });
  });

  group('stopping a burst', () {
    test('sends the cancel command and clears the flag', () async {
      final g = make();
      await g.guard.startBurst();
      expect(g.guard.burstActive, isTrue);

      await g.guard.stopBurst();

      expect(g.sent, contains(CaptureGuard.cancelShootingCommand));
      expect(g.guard.burstActive, isFalse);
      expect(g.guard.burstStopAttempts, 1);
    });

    test('is never gated by the interlock, even mid-capture', () async {
      // The one send in this class that must not be refused. A guard that declined here
      // because a capture was in flight would leave the camera bursting — which is the
      // fault, not a protection against it.
      final g = make();
      await g.guard.startBurst();
      await g.guard.stopBurst();
      g.sent.clear();

      // Stop again with no burst running: still sends, because the command's exact effect
      // is not established and a cancel for nothing costs one request.
      await g.guard.stopBurst();
      expect(g.sent, contains(CaptureGuard.cancelShootingCommand),
          reason: 'an unconditional stop is the safe direction: it can only end a capture '
              'that should not be running');
      expect(g.guard.burstStopAttempts, 2);
    });

    test('a failure is reported rather than swallowed', () async {
      final guard = CaptureGuard(
        http: () => CameraHttpClient(overrideSend: (command, params) async {
          throw const CameraHttpException('the link is gone');
        }),
        driveMode: () => 'Continuous',
        minInterval: Duration.zero,
      );
      await guard.stopBurst();

      expect(guard.lastBurstStopError, isNotNull,
          reason: 'after a failed stop the burst may still be running, and a silent '
              'failure here is a camera that keeps shooting');
      expect(guard.burstStopAttempts, 1);
    });
  });

  group('losing the link does not lose the burst', () {
    test('onLinkLost attempts a stop first', () async {
      final g = make();
      await g.guard.startBurst();
      g.sent.clear();

      g.guard.onLinkLost();

      expect(g.guard.burstStopAttempts, greaterThanOrEqualTo(1),
          reason: 'the camera does not need the link to keep bursting, so forgetting the '
              'session without trying to end it leaves it shooting');
    });
  });
}
