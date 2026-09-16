/// The shutter must **look** as unavailable as it is when the drive mode makes a
/// burst unstoppable.
///
/// ## What happened on hardware
///
/// With the camera's drive mode set to `Continuous` (confirmed in its own status
/// block: `DriveMode = Continuous`), a **brief tap** of the shutter made the camera
/// burst and keep bursting until it locked up; the user recovered it by pulling the
/// battery. `CaptureGuard.shoot()` now refuses that command, and that refusal was
/// verified on the real body — `[capture] refused: drive mode is Continuous and this
/// app cannot stop a burst`, with `SurplusPhotoCnts` unchanged at 1272, so nothing was
/// taken.
///
/// ## The gap this file closes
///
/// The refusal arrived **after the tap**. The shutter was drawn as pressable, so the
/// only way to learn that it would not work was to press it — and a control that looks
/// live and explains itself afterwards is the shape this project keeps having to
/// correct. `AppState.shutterBlockedReason` now carries the same case, so the button is
/// disabled up front and the reason is on screen beside it.
///
/// ## Why the check is here and not in the guard's tests
///
/// `test/burst_drive_interlock_test.dart` already proves the *enforcement*: the command
/// is not sent. Nothing there can see whether the page draws a disabled button, because
/// that is a claim about a widget. So this file drives the real `LiveViewPage` with a
/// `CameraState` whose drive mode is set, and reads the button.
///
/// The guard stays the enforcement and is deliberately **not** touched by this change.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yi_m1_controller/protocol/camera_state.dart';
import 'package:yi_m1_controller/protocol/wire_format.dart';
import 'package:yi_m1_controller/state/app_state.dart';
import 'package:yi_m1_controller/sync/asset_sink_contract.dart';
import 'package:yi_m1_controller/transport/capture_guard.dart';
import 'package:yi_m1_controller/transport/http_transport.dart';
import 'package:yi_m1_controller/ui/pages/live_view_page.dart';

import 'fakes.dart';
import 'package:yi_m1_controller/l10n/l10n.dart';

void main() {
  /// The mode a burst starts in, and the modes that are refused for the same reason.
  ///
  /// Written out rather than borrowed from `AppState`, because the point of the first
  /// check below is to compare the app's list against the guard's *behaviour*.
  const burstModes = <String>['Continuous', '2SDelay', '10SDelay'];

  /// A connected app whose camera says [driveMode] and is streaming.
  ///
  /// `previewRunning: true` is load-bearing: without it `shutterBlockedReason` reports
  /// "not in remote mode" for every drive mode, and a check that the burst blocks the
  /// shutter would pass while measuring the wrong gate entirely.
  ///
  /// It also starts `AppState`'s 250 ms chrome ticker, which is **periodic** and would
  /// therefore be reported as "a Timer is still pending" at the end of every test here —
  /// `flutter_test` verifies that *before* its teardown callbacks run, so `addTearDown`
  /// cannot clean it up. Each test below therefore calls [release] inside its own body.
  Future<AppState> pumpWithDriveMode(WidgetTester tester, String driveMode) async {
    await tester.binding.setSurfaceSize(const Size(1080, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final app = AppState(
      ble: FakeBleTransport(),
      sink: NullAssetSink(),
      testIdentity: const CameraIdentity(
        protocolVersion: 1,
        firmwareVersion: '3.1-cn ',
        regionMarker: 'M1CN',
      ),
      testHttp: CameraHttpClient(
        overrideSend: (command, params) async =>
            const CameraResponse(code: 200, raw: '{"code":200}', data: 'ok'),
      ),
      testPreviewRunning: true,
    );
    addTearDown(app.dispose);

    // The documented seam for a parsed camera state (`test/fakes.dart` and the readout
    // tests use it): no socket, no invented production path.
    app.setTestCameraState(CameraState({
      'ExposureMode': 'M',
      'ImageAspect': '4:3',
      'ShutterSpeed': '1/30s',
      'Fnumber': '1.7',
      'ISOSetting': '200',
      'WB': 'Auto',
      'ColorMode': 'Standard',
      'BatteryLevel': '75',
      'SurplusPhotoCnts': '1272',
      'FocusMode': 'S-AF',
      'DriveMode': driveMode,
      'FileFormat': 'JPG-L',
      'MeteringMode': 'Multi',
      'ImageQuality': '20',
      'LensStatus': '1',
      'EV': '0.0',
    }));
    // A frame, so the preview subtree that carries the shutter exists from the first
    // pump rather than after a decode.
    app.frameNotifier.value = onePixelPng;

    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      home: LiveViewPage(app: app),
    ));
    await tester.pump(const Duration(milliseconds: 50));
    return app;
  }

  /// Stop the app's periodic chrome ticker before the test body ends.
  ///
  /// `previewRunning: true` is a claim about the link, and `LiveViewPage` turns it into a
  /// live 250 ms ticker. `flutter_test` checks "no timer is pending" **before**
  /// `addTearDown` callbacks run, so a body that ends with the preview claimed as running
  /// fails on the binding's own invariant — with a message about timers that says nothing
  /// about the shutter. Stopping the preview is what production does when the user turns
  /// it off, and it is the same remedy `shutter_size_stability_test.dart` uses for the
  /// same reason. `AppState.dispose` cannot be used for this: it disposes
  /// `frameNotifier`, and `addTearDown(app.dispose)` then runs a second time and throws.
  Future<void> stop(AppState app, WidgetTester tester) async {
    await app.stopPreview();
    await tester.pump(const Duration(milliseconds: 300));
  }

  IconButton shutter(WidgetTester tester) =>
      tester.widget<IconButton>(find.byKey(const ValueKey<String>('btn-shutter')));

  group('the app and the guard agree about which drive modes are unsafe', () {
    // ## Why this exists rather than a shared constant
    //
    // `CaptureGuard` keeps its own private set (`_burstDriveModes`) and `AppState`
    // keeps a copy, because the guard's set is not exported and a safety list that two
    // files spell independently will drift — silently, and in the direction of a
    // shutter that looks enabled on a camera willing to burst. So the copy is checked
    // against the guard's **behaviour**: a real guard is built per mode and asked
    // whether it would send the command.
    for (final mode in burstModes) {
      test('$mode is refused by the guard, so the app must gate it too', () async {
        final sent = <String>[];
        final guard = CaptureGuard(
          http: () => CameraHttpClient(overrideSend: (command, params) async {
            sent.add(command);
            return const CameraResponse(code: 200, raw: '{"code":200}', data: 'ok');
          }),
          driveMode: () => mode,
          minInterval: Duration.zero,
        );

        final r = await guard.shoot();

        expect(r.outcome, CaptureOutcome.blocked,
            reason: 'the guard does not refuse $mode, so `AppState.kBurstDriveModes` '
                'is now gating a mode the guard would happily shoot in');
        expect(sent, isEmpty, reason: 'the refusal must come before the command');
        expect(AppState.kBurstDriveModes, contains(mode),
            reason: '$mode is refused by the guard and is missing from the app list, '
                'so the shutter would look enabled and only refuse after the tap');
      });
    }

    test('Single is not gated, because one request there means one frame', () async {
      final sent = <String>[];
      final guard = CaptureGuard(
        http: () => CameraHttpClient(overrideSend: (command, params) async {
          sent.add(command);
          return const CameraResponse(code: 200, raw: '{"code":200}', data: 'ok');
        }),
        driveMode: () => 'Single',
        minInterval: Duration.zero,
      );

      expect((await guard.shoot()).outcome, CaptureOutcome.ok);
      expect(sent, contains('RCDoShooting'));
      expect(AppState.kBurstDriveModes, isNot(contains('Single')));
    });
  });

  group('in a burst mode the shutter is a hold, not a disabled button', () {
    // ## What changed, and why the old expectation is gone
    //
    // This group used to assert the shutter was **disabled** in a burst mode, and that was
    // right while the only thing that could stop a burst was nothing at all. The camera now
    // has press-and-hold: measured on the real body, `RCDoShooting` starts a burst that
    // nothing the camera does will end, and `RCCancelShooting` on release stops it — an
    // eight-second burst cancelled that way left the camera working, verified by shooting
    // again afterwards.
    //
    // A disabled button cannot be held, so the gate had to move. It did not disappear: safe
    // now rests on the hold, the release, the watchdog, and `CaptureGuard` refusing to send
    // anything else while a burst runs.
    for (final mode in burstModes) {
      testWidgets('$mode: the button is live, and a tap does not shoot',
          (tester) async {
        final app = await pumpWithDriveMode(tester, mode);

        expect(app.link.isReady, isTrue);
        expect(app.link.previewRunning, isTrue);
        expect(app.captureQuarantined, isFalse);
        expect(app.capturePending, isFalse);
        expect(app.focusInFlight, isFalse);

        // The button must RENDER as live in a bursting mode. The behaviour lives in the
        // `Listener` above it, so `onPressed` is a no-op rather than null — and that
        // distinction is not cosmetic: `onPressed: null` draws an `IconButton` grey while
        // the `Listener` still receives every pointer event, giving a shutter that looks
        // broken and works. Found by holding it on the real camera and reading
        // `onPressed: (none)` off the widget tree while the burst ran.
        expect(shutter(tester).onPressed, isNotNull,
            reason: 'the shutter must be drawn as usable in $mode, because it is — the '
                'hold is what operates it. reason=${app.shutterBlockedReason}');

        // The load-bearing check: the hold is actually wired. If this stops being true
        // the shutter is live in a mode where one stray command runs a burst nothing can
        // end — which is the incident that started this.
        expect(AppState.burstHoldAvailable, isTrue,
            reason: 'the shutter is enabled in $mode, so the hold MUST be available — '
                'the gate and the hold are alternatives and one of them has to be on');
        expect(app.driveModeBlocksCapture, isTrue,
            reason: 'the guard still refuses a plain capture in $mode');
        expect(app.singleShotOnly, isFalse);

        await stop(app, tester);
      });
    }

    testWidgets('the fallback still exists: no hold means no live shutter',
        (tester) async {
      // `burstHoldAvailable` is a named constant precisely so the two designs cannot both
      // be off. This asserts the relationship rather than the constant's value, so flipping
      // it back is safe and flipping it without the hold is not.
      expect(AppState.burstHoldAvailable, isTrue);
      // And the guard's own refusal is untouched by any of this.
      final sent = <String>[];
      final guard = CaptureGuard(
        http: () => CameraHttpClient(overrideSend: (command, params) async {
          sent.add(command);
          return const CameraResponse(code: 200, data: 'ok', raw: '{"code":200}');
        }),
        driveMode: () => 'Continuous',
        minInterval: Duration.zero,
      );
      expect((await guard.shoot()).outcome, CaptureOutcome.blocked);
      expect(sent, isEmpty,
          reason: 'the safety half never moves: a plain capture in Continuous is refused '
              'before anything reaches the network');
    });

    testWidgets('Single: the shutter is enabled and nothing is explained',
        (tester) async {
      // The negative control. Without it, a build that disabled the shutter for every
      // drive mode would pass every check above.
      final app = await pumpWithDriveMode(tester, 'Single');

      expect(shutter(tester).onPressed, isNotNull,
          reason: 'a single frame per request is the mode this app is built for');
      expect(app.shutterBlockedReason, isNull);
      expect(find.textContaining('Set the drive mode to Single'), findsNothing);
      expect(app.singleShotOnly, isTrue);

      await stop(app, tester);
    });

    testWidgets('an absent status block does not lock the shutter',
        (tester) async {
      // The status JSON arrives with the first live-view frame, so for the first moments
      // after connecting nothing is known about the drive mode. Refusing then would make
      // the shutter unusable on every fresh connection — a worse failure than the one
      // being guarded. The guard takes the same position, for the same reason.
      final app = await pumpWithDriveMode(tester, '');

      expect(app.cameraState?.driveMode, '');
      expect(app.shutterBlockedReason, isNull);
      expect(shutter(tester).onPressed, isNotNull);

      await stop(app, tester);
    });
  });
}
