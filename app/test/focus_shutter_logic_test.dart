/// Pure-logic checks for the two real-hardware defects in this agent's scope:
/// where the focus marker goes, and whether a blocked shutter can be recovered.
///
/// ## Why these are `test()` and not `testWidgets()`
///
/// Nothing here needs a widget tree, a rendering pipeline or a camera — it is
/// library logic over `FocusMapper` and `CaptureGuard`.  They live under
/// `test/` rather than in `tool/verify_*.dart` for one practical reason: the
/// `logic` layer of `tools/task.ps1` runs a **hard-coded** list of three
/// `tool/verify_*.dart` scripts, so a new file there would silently never run —
/// and adding a fourth would mean editing the runner, which is outside this
/// change's scope.  Being discovered by `flutter test` puts them inside
/// `-Only analyze,widget`, which is where anything touching `lib/ui/**` goes
/// anyway.
///
/// `flutter test test/focus_shutter_logic_test.dart`
///
/// ## What used to be checked here, and why it is gone
///
/// A group of checks asserted that a `RCDoFocus` reply carrying `Posx`/`Posy`
/// moved the marker, and that an unusable reply moved it to the plane centre as
/// "unconfirmed".  Those encoded the assumption that the reply names where the
/// camera focused.  Measured on hardware, it does not — `Manual` echoes the
/// request and `Auto` answers a hard-coded `(360, 240)` — so the whole
/// `confirm`/`parseEcho`/`FocusConfirmation` surface has been removed rather
/// than left in place with a special case.  See the table in
/// `lib/protocol/focus_mapper.dart`, and
/// `test/focus_marker_position_test.dart` for the on-screen half.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:yi_m1_controller/protocol/focus_mapper.dart';
import 'package:yi_m1_controller/transport/capture_guard.dart';
import 'package:yi_m1_controller/transport/http_transport.dart';

CameraResponse _ok([Object? data]) =>
    CameraResponse(code: 200, raw: '{"code":200}', data: data);

void main() {
  group('a focus command is sent to the point that was tapped', () {
    // A 4:3 preview box as the page lays it out: 1080x810.
    const vw = 1080.0;
    const vh = 810.0;

    test('the four corners and the centre land where the official app puts them',
        () {
      // The whole of the tap-to-focus contract that can be checked offline: the
      // camera's plane is 640x480 offset by x=+40 on 4:3, and the answer to
      // "where did the tap go" has to be this and not the preview's own pixel
      // space.  (0,0) is deliberately *not* the origin of the plane — x starts
      // at +40 — which is the mistake that puts every point 40 px to the left.
      expect(
          FocusMapper.toCamera(
              localX: 0, localY: 0, viewWidth: vw, viewHeight: vh, aspect: '4:3'),
          (40, 0));
      expect(
          FocusMapper.toCamera(
              localX: vw, localY: vh, viewWidth: vw, viewHeight: vh, aspect: '4:3'),
          (680, 480));
      expect(
          FocusMapper.toCamera(
              localX: vw / 2,
              localY: vh / 2,
              viewWidth: vw,
              viewHeight: vh,
              aspect: '4:3'),
          (360, 240));
    });

    test('the vertical scale uses the view height, not the width', () {
      // Measured from hardware history: using the width for both axes silently
      // squashed every focus point vertically, by an amount that grew toward the
      // top and bottom of the frame.  A square view is the only shape where the
      // two formulas disagree visibly, which is why the view here is square.
      const w = 1000.0;
      const h = 1000.0;
      final at30 = FocusMapper.toCamera(
          localX: 0, localY: h * 0.3, viewWidth: w, viewHeight: h, aspect: '4:3');
      expect(at30.$2, (h * 0.3 * 480 / h).round(), reason: 'height divisor');
      expect(at30.$2, isNot((h * 0.3 * 640 / w).round()),
          reason: 'the width divisor is the defect');

      // ...and the horizontal scale still uses the width.
      final at50 = FocusMapper.toCamera(
          localX: w * 0.5, localY: 0, viewWidth: w, viewHeight: h, aspect: '4:3');
      expect(at50.$1, 360);
    });

    test('a wide aspect uses the wide plane, where y may be negative', () {
      // 720x540, y offset by -30: the top of the frame is above zero, so a
      // clamp to `0..size` — the obvious thing to write — shifts every point.
      expect(
          FocusMapper.toCamera(
              localX: 0, localY: 0, viewWidth: 1080, viewHeight: 607.5, aspect: '16:9'),
          (0, -30));
      expect(FocusMapper.isPlausible(0, -30, '16:9'), isTrue);
      expect(FocusMapper.isPlausible(0, 0, '4:3'), isFalse,
          reason: 'the 4:3 plane starts at x = 40');
    });

    test('every corner of every aspect maps inside the plane the camera accepts',
        () {
      // This is the check that catches a wrong divisor or a swapped axis: a
      // point outside the plane is either rejected by the camera or silently
      // clamped onto an edge, and both look like "focus went somewhere odd".
      for (final aspect in const ['4:3', '3:2', '16:9', '1:1']) {
        final w = aspect == '16:9' ? 1080.0 : 1080.0;
        final h = aspect == '16:9' || aspect == '3:2' ? w * 9 / 16 : w * 3 / 4;
        for (final p in [
          (0.0, 0.0),
          (w, 0.0),
          (0.0, h),
          (w, h),
          (w / 2, h / 2),
        ]) {
          final (x, y) = FocusMapper.toCamera(
              localX: p.$1,
              localY: p.$2,
              viewWidth: w,
              viewHeight: h,
              aspect: aspect);
          expect(FocusMapper.isPlausible(x, y, aspect), isTrue,
              reason: '$aspect corner (${p.$1}, ${p.$2}) -> ($x, $y)');
        }
      }
    });

    test('forward and inverse agree, which is how the squashing stayed hidden',
        () {
      // Two functions that must agree are two functions that can disagree, and
      // with a 4:3 view the wrong divisor gives the same number — so the
      // round-trip is asserted on a view shape that is not 4:3.
      const w = 1000.0;
      const h = 1000.0;
      final (cx, cy) = FocusMapper.toCamera(
          localX: w * 0.25, localY: h * 0.75, viewWidth: w, viewHeight: h, aspect: '4:3');
      final (vx, vy) = FocusMapper.fromCamera(
          x: cx, y: cy, viewWidth: w, viewHeight: h, aspect: '4:3');
      expect(vx, closeTo(w * 0.25, 1.0));
      expect(vy, closeTo(h * 0.75, 1.0));
    });

    test('an off-frame reply is not something the mapper will invent a use for',
        () {
      // Real replies have carried 17710 and 63244 (see
      // `analysis/11-liveview-state-json.md` §6). Nothing reads them any more,
      // and `isPlausible` is what says so out loud rather than a marker landing
      // nowhere near the picture.
      expect(FocusMapper.isPlausible(17710, 63244, '4:3'), isFalse);
      expect(FocusMapper.isPlausible(17710, 63244, '16:9'), isFalse);
    });
  });

  group('the shutter interlock can always be recovered', () {
    // The clock is injected so a stuck reservation can be tested without
    // sleeping through a real timeout.
    late DateTime now;
    setUp(() => now = DateTime(2026, 1, 1, 12));

    test('a live capture survives a release', () async {
      // The firmware punishes exactly one overlap, and "the camera is fine" is
      // not the claim "nothing is on the wire".
      final sent = <String>[];
      final guard = CaptureGuard(
        http: () => CameraHttpClient(overrideSend: (cmd, params) async {
          sent.add(cmd);
          await Future<void>.delayed(const Duration(milliseconds: 120));
          return _ok();
        }),
        minInterval: Duration.zero,
        quarantine: Duration.zero,
        measureFps: () async {
          await Future<void>.delayed(const Duration(milliseconds: 200));
          return 30.0;
        },
        clock: () => now,
      );
      final onTheWire = guard.shoot();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final releasing = guard.forceRelease();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final whileLive = await guard.shoot();
      expect(await releasing, isTrue);
      await onTheWire;
      expect(sent.where((c) => c == 'RCDoShooting').length, 1,
          reason: 'sent: $sent');
      expect(whileLive.outcome, CaptureOutcome.blocked);
    });

    test('a stuck reservation is recoverable, which is the dead end', () async {
      // A reservation that is never cleared is the state in which no press can
      // ever work again: `shoot` answers `blocked` before it touches the network,
      // so waiting does not help and the user has no way out.
      final sent = <String>[];
      final release = Completer<void>();
      final guard = CaptureGuard(
        http: () => CameraHttpClient(overrideSend: (cmd, params) async {
          sent.add(cmd);
          if (cmd == 'RCDoShooting') {
            await release.future;
            return _ok();
          }
          return _ok();
        }),
        minInterval: Duration.zero,
        quarantine: Duration.zero,
        measureFps: () async => 30.0,
        staleAfter: const Duration(seconds: 30),
        clock: () => now,
      );
      final stuck = guard.shoot();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(guard.isBusy, isTrue);
      expect(guard.isStale, isFalse);

      expect((await guard.shoot()).outcome, CaptureOutcome.blocked);
      expect(sent.where((c) => c == 'RCDoShooting').length, 1,
          reason: 'a second shot must not reach a camera with one outstanding');

      now = now.add(const Duration(seconds: 45));
      expect(guard.isStale, isTrue);
      expect(guard.describe(), contains('stuck'),
          reason: 'the status must not claim to be capturing');

      expect(await guard.forceRelease(), isTrue);
      expect(guard.isBusy, isFalse);
      release.complete();
      await stuck;
      expect((await guard.shoot()).outcome, CaptureOutcome.ok,
          reason: 'the shutter must work again without a power cycle');
    });

    test('a release against an unanswering camera does not claim success',
        () async {
      final guard = CaptureGuard(
        http: () => CameraHttpClient(overrideSend: (cmd, params) async {
          throw const CameraHttpException('cannot reach 192.168.0.10');
        }),
        minInterval: Duration.zero,
        quarantine: Duration.zero,
        measureFps: () async => 30.0,
        clock: () => now,
      );
      expect(await guard.forceRelease(), isFalse);
      expect(guard.isQuarantined, isTrue,
          reason: 'the shutter must not be handed back pointed at a dead camera');
    });

    test('an unexpected throw never strands the reservation', () async {
      // `_inFlight` is what makes the shutter permanently unusable, and it
      // outlives the page, the link and the camera.  Anything escaping `shoot`
      // has to leave it clear.
      final guard = CaptureGuard(
        http: () => CameraHttpClient(overrideSend: (cmd, params) async {
          if (cmd == 'RCDoShooting') throw StateError('seam blew up');
          return _ok();
        }),
        minInterval: Duration.zero,
        quarantine: Duration.zero,
        measureFps: () async => 30.0,
        clock: () => now,
      );
      expect((await guard.shoot()).outcome, CaptureOutcome.transportError);
      expect(guard.isBusy, isFalse);
    });

    test('two simultaneous presses still send exactly one command', () async {
      final sent = <String>[];
      final guard = CaptureGuard(
        http: () => CameraHttpClient(overrideSend: (cmd, params) async {
          sent.add(cmd);
          await Future<void>.delayed(const Duration(milliseconds: 30));
          return _ok();
        }),
        minInterval: Duration.zero,
        quarantine: Duration.zero,
        measureFps: () async => 30.0,
        clock: () => now,
      );
      final results = await Future.wait([guard.shoot(), guard.shoot()]);
      expect(sent.where((c) => c == 'RCDoShooting').length, 1, reason: '$sent');
      expect(
          results.where((r) => r.outcome == CaptureOutcome.blocked).length, 1);
    });
  });
}
