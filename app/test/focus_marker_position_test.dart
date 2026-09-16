/// Failing-first check for the tap-to-focus marker, measured on hardware.
///
/// ## The measurement this file encodes
///
/// `RCDoFocus`'s reply carries **no information about where the camera focused**.
/// Run from a PC against the real camera over HTTP:
///
/// | `Mode`   | requested (Posx,Posy) | camera replied |
/// |----------|-----------------------|----------------|
/// | `Manual` | (642, 91)             | **(642, 91)** — an echo of the request |
/// | `Manual` | (100, 500)            | **(100, 500)** — an echo |
/// | `Auto`   | (642, 91)             | **(360, 240)** |
/// | `Auto`   | (100, 500)            | **(360, 240)** |
/// | `Auto`   | (800, 600)            | **(360, 240)** |
/// | `Auto`   | (0, 0)                | **(360, 240)** |
///
/// Cross-checked: after moving the AF point with `Mode=Manual`, a following
/// `Mode=Auto` request **still** replies `(360, 240)`.  So `Auto` is a
/// hard-coded constant and `Manual` is an echo.  Neither names a focus point.
///
/// Confirmed visually as well: tapping the preview at (60,220) and at (350,620)
/// put the on-screen marker in the **same place**
/// (`analysis/emulator/151_focus_topleft.png`, `152_focus_bottomright.png`).
///
/// The app sends `Mode='Auto'`, so every tap used to make the marker jump to the
/// centre of the frame — worse than leaving it where the user tapped, because a
/// marker that moves away and lands on a meaningless point is a claim the camera
/// never made.
///
/// ## Why this is a widget test
///
/// The defect is not in the mapping arithmetic — `tool/verify_transport.dart`
/// pins that, and it is correct.  The defect is that **the page moved the
/// marker after the user tapped it**, which is visible only in the tree: the
/// position of the widget, measured on screen, against the finger position.
library;

import 'dart:io';

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
/// One key and not two: the page no longer has a "confirmed" and an
/// "unconfirmed" box.  There is nothing for the camera to confirm — see the
/// table above — so a second state would be a distinction without a difference.
const Key focusMarkerKey = ValueKey<String>('focus-marker');

/// Every command the page put on the wire, in order.
class _Wire {
  final List<String> sent = [];
  final Map<String, List<CameraResponse>> script = {};

  /// The parameters each command was sent with, aligned with [sent].
  final List<(String command, Map<String, Object> params)> calls = [];

  CameraHttpClient get client =>
      CameraHttpClient(overrideSend: (cmd, params) async {
        sent.add(cmd);
        calls.add((cmd, params));
        final q = script[cmd];
        if (q != null && q.isNotEmpty) return q.removeAt(0);
        return const CameraResponse(code: 200, raw: '{"code":200}', data: 'ok');
      });

  int count(String cmd) => sent.where((c) => c == cmd).length;

  Map<String, Object> paramsOf(String cmd) =>
      calls.lastWhere((c) => c.$1 == cmd).$2;
}

/// A `RCDoFocus` reply of the shape the camera actually sends.
///
/// Note what these tests do **not** do with it: nothing on screen depends on it
/// any more.  It is scripted so the reply path is exercised and the assertions
/// after it prove the marker ignored it.
CameraResponse _focusReply(int x, int y) => CameraResponse(
      code: 200,
      raw: '{"code":200,"Posx":"$x","Posy":"$y"}',
      data: {'Posx': '$x', 'Posy': '$y'},
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  useTempStorage(
      Directory.systemTemp.createTempSync('focus_marker_position').path);

  Future<AppState> pumpLive(
    WidgetTester tester,
    _Wire wire, {
    bool previewRunning = false,
  }) async {
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
      testHttp: wire.client,
      testPreviewRunning: previewRunning,
    );
    addTearDown(app.dispose);
    app.setTestCameraState(const CameraState({
      'ExposureMode': 'M',
      'ImageAspect': '4:3',
      'BatteryLevel': '75',
      'SurplusPhotoCnts': '120',
    }));
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

  /// The preview box the tap gesture is on, i.e. the coordinate space the
  /// marker's position is expressed in.
  Rect previewBox(WidgetTester tester) {
    final finder = find.descendant(
      of: find.byKey(previewAreaKey),
      matching: find.byType(GestureDetector),
    );
    expect(finder, findsWidgets, reason: 'the preview subtree did not render');
    return tester.getRect(finder.first);
  }

  /// Advance past the 350 ms debounce and the AF settle window, in steps, so
  /// every timer the focus path creates is pumped rather than left pending.
  Future<void> pumpRoundTrip(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
  }

  testWidgets('the marker stays on the tap when Auto replies with its constant',
      (tester) async {
    // `(360, 240)` is what the hardware answers for *every* Auto request.  A
    // marker that follows it ends up in the middle of the frame no matter where
    // the user tapped — which is exactly what the two emulator screenshots show.
    final wire = _Wire();
    wire.script['RCDoFocus'] = [
      const CameraResponse(
        code: 200,
        raw: '{"code":200,"Posx":"360","Posy":"240"}',
        data: {'Posx': '360', 'Posy': '240'},
      ),
    ];
    final app = await pumpLive(tester, wire);
    final box = previewBox(tester);

    // Deliberately far from the centre, so a centre-landing marker is
    // unambiguous rather than a rounding question.
    final tapLocal = Offset(box.width * 0.12, box.height * 0.84);
    final tapAt = box.topLeft + tapLocal;
    await tester.tapAt(tapAt);
    await tester.pump(const Duration(milliseconds: 40));

    expect(find.byKey(focusMarkerKey), findsOneWidget,
        reason: 'the focus box must appear as soon as the user taps');

    await pumpRoundTrip(tester);

    expect(wire.count('RCDoFocus'), 1,
        reason: 'the tap should have sent exactly one focus command');
    final markerCentre = tester.getCenter(find.byKey(focusMarkerKey));
    expect((markerCentre - tapAt).distance, lessThan(0.5),
        reason: 'the marker moved to $markerCentre after a tap at $tapAt — the '
            'reply is a hard-coded constant, not a focus point');
    expect(app.focusInFlight, isFalse);
  });

  testWidgets('the marker is drawn at once, without waiting for a reply',
      (tester) async {
    // The camera may never answer.  The marker is the user's own input being
    // acknowledged, so it must not depend on the round trip.
    final wire = _Wire();
    final app = await pumpLive(tester, wire);
    final box = previewBox(tester);

    final tapAt = box.topLeft + Offset(box.width * 0.7, box.height * 0.2);
    await tester.tapAt(tapAt);
    await tester.pump();

    expect(find.byKey(focusMarkerKey), findsOneWidget,
        reason: 'a tap that has not been answered yet is still a tap');
    final centre = tester.getCenter(find.byKey(focusMarkerKey));
    expect((centre - tapAt).distance, lessThan(0.5), reason: '$centre vs $tapAt');

    await pumpRoundTrip(tester);
    expect(app.focusInFlight, isFalse);
  });

  testWidgets('no second marker state claims the camera confirmed anything',
      (tester) async {
    // The previous design grew a second marker key, `focus-marker-unconfirmed`,
    // for "the camera named no usable point".  With the table above applied to
    // *both* modes there is no point the camera ever names, so that state is not
    // an edge case — it is every case, and a distinction that is always the same
    // value is not information.
    final wire = _Wire();
    wire.script['RCDoFocus'] = [
      const CameraResponse(
        code: 200,
        raw: '{"code":200,"Posx":"360","Posy":"240"}',
        data: {'Posx': '360', 'Posy': '240'},
      ),
    ];
    await pumpLive(tester, wire);
    final box = previewBox(tester);

    await tester.tapAt(box.topLeft + Offset(box.width / 2, box.height / 2));
    await pumpRoundTrip(tester);

    expect(find.byKey(focusMarkerKey), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('focus-marker-unconfirmed')),
        findsNothing);
  });

  testWidgets('a tap sends Mode=Manual to the point that was tapped',
      (tester) async {
    // ## The substantive defect, and the one no check could see
    //
    // `LiveViewFragment.java:697-717` — the official app's `FocusView` touch
    // callback — sets `CameraSettingParams.f13979r = DoFocusValue.Manual` and
    // then sends that point.  `Auto` belongs to a different entry point
    // (`LiveViewFragment:639/641`), not to a tap on the preview.
    //
    // We sent `Auto`.  Measured against the real camera, `Auto` answers
    // `(360, 240)` for **every** request — `360 = 640/2 + 40`, `240 = 480/2`,
    // the centre of the 4:3 focus plane, which is also `FocusView.java:241-244`'s
    // own out-of-bounds fallback — while `Manual` echoes the request and so
    // honours it end to end.
    //
    // No existing test could catch this because **none of them looked at the
    // `Mode` value**: they asserted that a command was sent, and a command was.
    // This asserts what actually went on the wire, at the lowest layer that can
    // see the page's own parameter building — the widget layer, because the value
    // is chosen by the page's handler and passed through `AppState.focusAt`.
    final wire = _Wire();
    wire.script['RCDoFocus'] = [_focusReply(642, 91)];
    await pumpLive(tester, wire);
    final box = previewBox(tester);

    // A known fraction of the preview box, so the expected camera coordinates
    // are derivable rather than copied from whatever the code happened to do.
    // The box is 4:3, so `FocusMapper` maps it with the narrow plane:
    //   x = localX * 640 / width + 40 ;  y = localY * 480 / height
    const fx = 0.25;
    const fy = 0.75;
    await tester.tapAt(box.topLeft + Offset(box.width * fx, box.height * fy));
    await pumpRoundTrip(tester);

    expect(wire.count('RCDoFocus'), 1, reason: 'sent: ${wire.sent}');
    final params = wire.paramsOf('RCDoFocus');
    expect(params['Mode'], 'Manual',
        reason: 'the official app sends Manual for a tap; Auto is the entry '
            'point that answers a constant, which is how the marker ended up in '
            'the middle of the frame on every tap');
    // Spelled out, so a wrong divisor is a named failure rather than a string
    // comparison against the same formula the code uses.
    expect(params['Posx'], '${(640 * fx + 40).round()}');
    expect(params['Posx'], '200');
    expect(params['Posy'], '${(480 * fy).round()}');
    expect(params['Posy'], '360');
  });

  testWidgets('the centre-focus control sends Manual too', (tester) async {
    // The same command through the other entry point.  A `Manual` tap path and
    // an `Auto` button would be two different requests from one screen, and the
    // button is what a user presses when the tap did not land.
    //
    // The control is disabled unless the preview is running — the same gate the
    // hardware imposes — so the app is built with that state explicitly.
    final wire = _Wire();
    wire.script['RCDoFocus'] = [_focusReply(400, 300)];
    final app = await pumpLive(tester, wire, previewRunning: true);
    await tester.tap(find.byKey(const ValueKey<String>('btn-focus-centre')));
    await pumpRoundTrip(tester);

    expect(wire.count('RCDoFocus'), 1, reason: 'sent: ${wire.sent}');
    final params = wire.paramsOf('RCDoFocus');
    expect(params['Mode'], 'Manual');
    expect(params['Posx'], '400');
    expect(params['Posy'], '300');

    // A running preview means a live 250 ms chrome ticker, and a widget test
    // that ends with a pending timer fails on the binding's own invariant
    // rather than on anything it was checking.  Stopping the preview is the
    // dispose path a page leaving the screen takes.
    await app.stopPreview();
    await tester.pump(const Duration(milliseconds: 300));
  });
}
