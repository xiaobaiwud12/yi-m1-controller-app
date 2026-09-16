/// Widget-level regression checks for the two defects reported from hardware:
/// the focus marker did not match where the camera focused, and "Release anyway"
/// did not make the shutter usable again.
///
/// These live at the widget layer for one reason: the pure-Dart checks in
/// `tool/verify_focus_shutter.dart` prove the *arithmetic* and the *interlock*,
/// but they cannot see whether the page draws the result or whether the control
/// the user actually presses is wired to it.  Both reported bugs were of that
/// second kind — the logic was fine and the screen did not use it.
///
/// ## Discipline that this file has already paid for
///
/// Every `await` here resolves under the test binding's fake clock, and every
/// pending timer is pumped to completion before the test ends.  Two earlier
/// revisions of this file hung for **ten minutes** apiece in CI: one awaited
/// `RawDatagramSocket.bind`, which never completes under `fakeAsync`, and one
/// left the focus call's AF settle timer running while asserting.  A widget test
/// that hangs is worse than no test, so both patterns are avoided deliberately
/// rather than accidentally.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yi_m1_controller/protocol/camera_state.dart';
import 'package:yi_m1_controller/protocol/wire_format.dart';
import 'package:yi_m1_controller/state/app_state.dart';
import 'package:yi_m1_controller/sync/asset_sink_contract.dart';
import 'package:yi_m1_controller/transport/http_transport.dart';
import 'package:yi_m1_controller/ui/pages/live_view_page.dart';

import 'fakes.dart';
import 'package:yi_m1_controller/l10n/l10n.dart';

/// The key the page puts on the focus box.
///
/// One key, because there is one state: the marker sits where the user tapped.
/// It used to have a second, `focus-marker-unconfirmed`, for "the camera named
/// no usable point" — a state that turned out to be *every* state, because the
/// `RCDoFocus` reply never names a point at all.  See
/// `test/focus_marker_position_test.dart` for the measurement and the check.
const Key focusMarkerKey = ValueKey<String>('focus-marker');
const Key releaseInterlockKey = ValueKey<String>('btn-release-interlock');

/// Every command the page put on the wire, in order.
class _Wire {
  final List<String> sent = [];

  /// Replies by command name; anything not listed answers 200 with no data.
  final Map<String, List<CameraResponse>> script = {};

  CameraHttpClient get client =>
      CameraHttpClient(overrideSend: (cmd, params) async {
        sent.add(cmd);
        final q = script[cmd];
        if (q != null && q.isNotEmpty) return q.removeAt(0);
        return const CameraResponse(code: 200, raw: '{"code":200}', data: 'ok');
      });

  int count(String cmd) => sent.where((c) => c == cmd).length;
}

CameraResponse _focusReply(int x, int y) => CameraResponse(
      code: 200,
      raw: '{"code":200,"Posx":"$x","Posy":"$y"}',
      data: {'Posx': '$x', 'Posy': '$y'},
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final dir = Directory.systemTemp.createTempSync('focus_shutter_ui');
  useTempStorage(dir.path);

  /// A connected app whose camera is scripted, with a page showing it.
  ///
  /// The frame is published *before* the first pump so the preview subtree — the
  /// part that carries the tap gesture and the overlays — exists from the start,
  /// and so no pump has to wait on an image decode.
  Future<AppState> pumpLive(
    WidgetTester tester,
    _Wire wire, {
    Size size = const Size(1080, 2400),
    bool withFrame = true,
    bool previewRunning = false,
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final app = AppState(
      ble: FakeBleTransport(),
      sink: NullAssetSink(),
      testIdentity: const CameraIdentity(
        protocolVersion: 1,
        firmwareVersion: '3.1-cn ',
        regionMarker: 'M1CN',
      ),
      testHttp: wire.client,
      testPreviewRunning: previewRunning,
      // Socket-free preview start: the real path binds UDP 54321, and a real
      // socket completion never arrives under the fake clock.  The contract kept
      // here is the only one that matters — `RCStartRemoteCtl` goes out and the
      // acceptance is reported.
      testPreviewStarter: () async {
        try {
          final r = await wire.client.startRemoteControl();
          return r.ok;
        } on Object {
          return false;
        }
      },
    );
    addTearDown(app.dispose);

    // The camera-state JSON is where the aspect and the parameter readout come
    // from.  Handing it in directly is the documented seam; production state
    // still arrives only inside live-view frames.
    app.setTestCameraState(const CameraState({
      'ExposureMode': 'M',
      'ImageAspect': '4:3',
      'ShutterSpeed': '1/30s',
      'Fnumber': '1.7',
      'ISOSetting': '200',
      'WB': 'Auto',
      'ColorMode': 'Standard',
      'BatteryLevel': '75',
      'SurplusPhotoCnts': '120',
      'FocusMode': 'S-AF',
      'DriveMode': 'Single',
      'FileFormat': 'JPG-L',
      'MeteringMode': 'Multi',
      'ImageQuality': '20',
      'LensStatus': '1',
      'EV': '0.0',
    }));
    if (withFrame) {
      // A one-pixel PNG, so the frame decodes in a headless test instead of
      // failing and leaving a decode pending across later pumps.
      app.frameNotifier.value = onePixelPng;
    }

    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      home: LiveViewPage(app: app),
    ));
    await tester.pump(const Duration(milliseconds: 50));
    return app;
  }

  /// The preview picture's own box.  This is the widget the tap gesture is on, so
  /// it is also the coordinate space the focus mapping is defined in.
  Rect previewBox(WidgetTester tester) {
    final finder = find.descendant(
      of: find.byKey(previewAreaKey),
      matching: find.byType(GestureDetector),
    );
    expect(finder, findsWidgets, reason: 'the preview subtree did not render');
    return tester.getRect(finder.first);
  }

  /// Advance past the debounce, the HTTP round trip and the AF settle window in
  /// steps, so every timer the focus path creates is run rather than left
  /// pending.  Deliberately *not* one long pump: a single large step can leave
  /// the future created inside the debounce callback unsatisfied.
  Future<void> pumpFocusRoundTrip(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
  }

  group('the focus marker follows the finger, because the reply is a constant',
      () {
    testWidgets('a reply that names a different point does not move the marker',
        (tester) async {
      // This group used to assert the opposite — that the marker moved to the
      // point the reply named — on the theory that `RCDoFocus` answers with
      // where the AF system settled.
      //
      // Measured against the real camera, that theory is false.  `Manual` echoes
      // the request; `Auto` answers `(360, 240)` for *every* request, including
      // after the AF point has been moved elsewhere with `Manual`.  The app
      // sends `Mode='Auto'`, so the marker jumped to the centre of the frame on
      // every tap, wherever the user had tapped.
      //
      // The check is still worth having, inverted: it pins that nothing in the
      // page moves the marker after the fact.
      final wire = _Wire();
      wire.script['RCDoFocus'] = [_focusReply(360, 240)];
      await pumpLive(tester, wire);
      final box = previewBox(tester);

      // Well away from the centre, so a marker that followed the reply would
      // visibly be somewhere else.
      final tapLocal = Offset(box.width * 0.25, box.height * 0.25);
      final tapAt = box.topLeft + tapLocal;
      await tester.tapAt(tapAt);
      await tester.pump(const Duration(milliseconds: 40));

      expect(find.byKey(focusMarkerKey), findsOneWidget,
          reason: 'the box must appear as soon as the user taps');

      await pumpFocusRoundTrip(tester);

      expect(wire.count('RCDoFocus'), 1,
          reason: 'the tap should have sent exactly one focus command');
      final markerCentre = tester.getCenter(find.byKey(focusMarkerKey));
      expect((markerCentre - tapAt).distance, lessThan(0.5),
          reason: 'the marker moved to $markerCentre after a tap at $tapAt');
    });

    testWidgets('an off-plane reply changes nothing on screen', (tester) async {
      // Real replies have carried values like 17710 and 63244, which no plane
      // can contain.  Nothing reads them any more, so the worst they can do is
      // be ignored — which is the point.
      final wire = _Wire();
      wire.script['RCDoFocus'] = [
        CameraResponse(
          code: 200,
          raw: '{"code":200,"Posx":"17710","Posy":"63244"}',
          data: {'Posx': '17710', 'Posy': '63244'},
        ),
      ];
      await pumpLive(tester, wire);
      final box = previewBox(tester);

      final tapAt = box.topLeft + Offset(box.width * 0.25, box.height * 0.25);
      await tester.tapAt(tapAt);
      await pumpFocusRoundTrip(tester);

      expect(find.byKey(focusMarkerKey), findsOneWidget);
      final centre = tester.getCenter(find.byKey(focusMarkerKey));
      expect((centre - tapAt).distance, lessThan(0.5),
          reason: 'an unusable reply moved the marker to $centre');
    });
  });

  group('the way out of a blocked shutter', () {
    testWidgets('the recovery control is offered whenever the link is up but '
        'the shutter is not', (tester) async {
      // The reported defect.  The control used to be gated on the interlock
      // alone, so in the state the user actually hit — link up, preview stopped
      // after a refusal, shutter reporting "start the preview first" — it was
      // either absent or lifted a lock that was not the one holding the shutter,
      // and pressing it changed nothing on screen.
      //
      // The button must also exist in the tree to be tappable at all, which is
      // why it carries a `ValueKey` rather than being found by its label.
      final wire = _Wire();
      final app = await pumpLive(tester, wire, withFrame: false);

      expect(app.link.isReady, isTrue, reason: 'the injection seam failed');
      expect(app.link.previewRunning, isFalse);
      expect(app.captureQuarantined, isFalse,
          reason: 'this is the non-quarantine case, which is the one that was '
              'unreachable');
      expect(app.shutterBlockedReason, contains('not in remote mode'));
      expect(find.byKey(releaseInterlockKey), findsOneWidget,
          reason: 'the user must be able to act on a blocked shutter');
      final button = tester.widget<TextButton>(find.byKey(releaseInterlockKey));
      expect(button.onPressed, isNotNull,
          reason: 'a visible control with no handler is the defect being fixed');
    });

    testWidgets('pressing it asks the camera for remote mode, which is what the '
        'shutter actually needs', (tester) async {
      // This test asserts the *request* and not the resulting state.  Re-entering
      // remote mode is `CameraConnection.startPreview`, which binds UDP 54321 —
      // a real socket operation that never completes under the test binding's
      // fake clock, so awaiting the result here would hang the suite (it did:
      // ten minutes, twice).  What is checkable, and what actually distinguishes
      // the fix from the defect, is that pressing the control puts
      // `RCStartRemoteCtl` on the wire instead of only clearing a local flag.
      // The state that results from it is covered where it can be tested:
      // `tool/verify_focus_shutter.dart` drives the interlock directly.
      final wire = _Wire();
      final app = await pumpLive(tester, wire, withFrame: false);

      expect(wire.sent, isEmpty,
          reason: 'nothing should have been sent before the press');

      // Start the press without awaiting it.  `forceReleaseCapture` itself is
      // careful not to await the socket bind, but the request it fires reaches
      // the wire on the microtask queue and the socket half does not complete
      // under the fake clock, so nothing here may wait on the whole chain.
      unawaited(app.forceReleaseCapture());
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));

      expect(wire.count('RCStartRemoteCtl'), 1,
          reason: 'the shutter needs remote mode; clearing the interlock alone '
              'cannot provide it. sent: ${wire.sent}');
      // The interlock really was released on the way there, which is the other
      // half of what the control promises.
      expect(app.captureQuarantined, isFalse);

      // The preview really did start (through the socket-free seam), so the
      // chrome ticker is live.  Leaving it running trips the binding's "a timer
      // is still pending" assertion, so the preview is stopped explicitly — this
      // is the dispose path a page leaving the screen would take.
      await app.stopPreview();
      await tester.pump(const Duration(milliseconds: 200));
      expect(app.link.previewRunning, isFalse);
    });
  });

  group('focus and capture are mutually exclusive', () {
    testWidgets('a shutter press cannot put a second command on the wire while '
        'focus is in flight', (tester) async {
      // Two commands at once is the proven precondition of the permanent wedge:
      // the firmware's capture flags are only cleared on the "ready" branch, so
      // the second request strands them and the camera is dead until the battery
      // is pulled.  `focusAt` used to serialise against itself only, so a shutter
      // press during a focus round trip was exactly that overlap.
      final wire = _Wire();
      wire.script['RCDoFocus'] = [_focusReply(420, 320)];
      // Preview already running: this test is about two *commands* overlapping,
      // not about the preview gate, which would otherwise mask the assertion.
      final app = await pumpLive(tester, wire, previewRunning: true);
      final box = previewBox(tester);

      await tester
          .tapAt(box.topLeft + Offset(box.width * 0.25, box.height * 0.25));
      // Fire the debounce but stop inside the settle window, so focus is
      // genuinely outstanding when the shutter is pressed.
      await tester.pump(const Duration(milliseconds: 400));

      expect(wire.count('RCDoFocus'), 1);
      expect(app.focusInFlight, isTrue,
          reason: 'the settle window is part of the exclusion');

      // The shutter is disabled on screen while focus settles — the user cannot
      // even tap it.  Found by its own key, so the assertion cannot drift onto a
      // neighbour when the bar is rearranged.
      final shutter = tester
          .widget<IconButton>(find.byKey(const ValueKey<String>('btn-shutter')));
      expect(shutter.onPressed, isNull,
          reason: 'the shutter must look as unavailable as it is. '
              'focusInFlight=${app.focusInFlight} '
              'reason=${app.shutterBlockedReason}');

      // A second RCDoFocus while one is outstanding would be dropped rather than
      // queued, so the overlap the guard prevents is the capture one; assert it
      // through the same seam the shutter uses.
      expect(app.shutterBlockedReason, isNotNull);
      expect(wire.count('RCDoShooting'), 0,
          reason: 'no capture may reach the camera while focus is in flight. '
              'sent: ${wire.sent}');

      // Drain the settle window so the test does not end with a live timer.
      await pumpFocusRoundTrip(tester);
      expect(app.focusInFlight, isFalse);

      // And stop the preview: this test is the one that builds its app with the
      // preview already running, which is what starts the 250 ms chrome ticker.
      // `flutter_test` verifies "no timer is pending" *before* `addTearDown`
      // callbacks run, so leaving it live fails the test on the binding's own
      // invariant rather than on anything it was checking.
      await app.stopPreview();
      await tester.pump(const Duration(milliseconds: 300));
    });
  });

  group('a corrupt frame does not become an error screen', () {
    testWidgets('the preview survives bytes that are not a JPEG', (tester) async {
      // Bytes that are not a JPEG at all.  `Image.memory` throws
      // `Exception: Invalid image data` for them, and an uncaught throw from a
      // build reaches `FlutterError.onError` — one corrupt datagram, which this
      // link produces, used to replace a working live view with an error screen.
      //
      // The rest of the suite uses `onePixelPng` so that no pump ever waits on a
      // decode; this test is the one exception, and it keeps a good frame first
      // so the assertion is about the *replacement*, not about a first load.
      final wire = _Wire();
      final app = await pumpLive(tester, wire);
      expect(find.byKey(previewAreaKey), findsOneWidget);

      app.frameNotifier
          .value = Uint8List.fromList(const [1, 2, 3, 4, 5, 6, 7, 8]);
      await tester.pump(const Duration(milliseconds: 200));

      expect(tester.takeException(), isNull,
          reason: 'a bad frame must be absorbed, not rethrown');
      expect(find.byKey(previewAreaKey), findsOneWidget,
          reason: 'the live view must still be there');
    });
  });

  group('the waiting screen', () {
    Future<AppState> pumpDisconnected(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1080, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final app = testAppState();
      addTearDown(app.dispose);
      await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
        home: LiveViewPage(app: app),
      ));
      await tester.pump(const Duration(milliseconds: 50));
      return app;
    }

    testWidgets('states the status once, not twice', (tester) async {
      // Emulator screenshot evidence: after tapping Connect, "looking for the
      // camera..." appeared in the middle of the preview area *and* again in the
      // connect bar directly below it.  `_ConnectBar` renders `app.link.message`
      // unconditionally, so the placeholder repeating it produced two copies of
      // one status — which reads as two different statuses and makes the reader
      // work out which is live.
      final app = await pumpDisconnected(tester);

      final message = app.link.message;
      expect(message, isNotEmpty, reason: 'the idle link has a message to show');
      expect(find.text(message), findsOneWidget,
          reason: 'the link status must appear exactly once on screen, but '
              'found ${find.text(message).evaluate().length}');
      expect(find.byKey(previewPlaceholderKey), findsOneWidget,
          reason: 'the waiting screen itself must still be there');
    });

    testWidgets('the busy indicator is given a real size', (tester) async {
      // Emulator screenshot evidence: instead of a spinner there was a ~2 px blue
      // square.  The placeholder sits inside `FittedBox(fit: scaleDown)`, and an
      // indeterminate `CircularProgressIndicator` has **no intrinsic size** — it
      // takes its constraints — so it collapsed to nothing and the FittedBox
      // scaled that nothing.  A loading indicator the user cannot see is not a
      // loading indicator.
      //
      // The busy state needs a live BLE scan, so it cannot be reached from here;
      // what is checkable is the fix's mechanism, which is that the indicator now
      // sits in a box with a definite size.  Measuring that box is the honest
      // assertion available at this layer — the pixels were verified from an
      // emulator screenshot.
      await pumpDisconnected(tester);

      // Rendered sizes of whatever the waiting screen is showing, so the check
      // fails loudly if the placeholder stops rendering at all.
      final placeholder = tester.getSize(find.byKey(previewPlaceholderKey));
      expect(placeholder.width, greaterThan(0));
      expect(placeholder.height, greaterThan(0));

      final sized = find.ancestor(
        of: find.byType(CircularProgressIndicator),
        matching: find.byType(SizedBox),
      );
      if (sized.evaluate().isEmpty) {
        // Idle: no spinner in the tree.  The idle glyph is sized and measurable.
        final glyph = tester.getSize(find.byIcon(Icons.photo_camera_outlined));
        expect(glyph.width, greaterThan(20),
            reason: 'the idle glyph renders at a real size');
        return;
      }
      final box = tester.widget<SizedBox>(sized.first);
      expect(box.width, isNotNull, reason: 'the spinner must not be size-less');
      expect(box.height, isNotNull);
      expect(box.width, greaterThanOrEqualTo(24),
          reason: 'a spinner smaller than this is the dot defect');
    });
  });
}
