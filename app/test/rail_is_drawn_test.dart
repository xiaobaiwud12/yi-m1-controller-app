import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yi_m1_controller/l10n/l10n.dart';
import 'package:yi_m1_controller/protocol/camera_state.dart';
import 'package:yi_m1_controller/ui/pages/live_view_page.dart';

import 'fakes.dart';

/// The camera state the dials' ladders come from, in the mode under test.
///
/// Copied from `mode_aware_dials_test.dart`'s own helper, which is declared inside that
/// file's `main()` and so cannot be imported. Kept close to it on purpose: these values put
/// each dial near the middle of its ladder, and `FnumberMin`/`FnumberMax` are what clip the
/// aperture ladder — the subject of `analysis/74`.
CameraState stateIn(String mode) => CameraState({
      'ExposureMode': mode,
      'ImageAspect': '4:3',
      'ShutterSpeed': '1/4000s',
      'Fnumber': '1.0',
      'FnumberMin': '1.0',
      'FnumberMax': '16',
      'ISOSetting': '400',
      'WB': 'Incandescent',
      'ColorMode': 'HContrastBW',
      'BatteryLevel': '100',
      'SurplusPhotoCnts': '9999',
      'EV': '-0.7',
    });

/// The position rail must be **drawn**, on every dial, in every mode.
///
/// ## How this was found
///
/// The maintainer, looking at landscape full screen on their phone:
///
/// > 为什么只有光圈有进度条而别的都删除了
///
/// and then the question that turned it into a diagnosis:
///
/// > 此外"光圈"何谈余量？？
///
/// **There is none.** Aperture is a short ladder bounded by the lens, and that question is
/// what pointed away from "a design choice" and towards "a coincidence".
///
/// The rail draws one `Expanded` tick per ladder entry, and each carried a fixed `margin`
/// of `width * 0.25` top and bottom — **1.5 dp out of the ~35 dp the rail has**. Past
/// roughly 23 entries a tick's own share is shorter than the margin it carries, so every
/// tick lays out at zero height and the whole rail disappears:
///
/// | dial | entries | per tick | minus 1.5 dp | drawn |
/// |---|---|---|---|---|
/// | aperture | 14 | 2.5 dp | 1.0 dp | yes |
/// | mode | 6 | 5.8 dp | 4.3 dp | yes |
/// | ISO | ~30 | 1.2 dp | -0.3 dp | no |
/// | shutter | 57 | 0.6 dp | -0.9 dp | no |
///
/// So the only dial still showing a rail was the one whose ladder happened to be short
/// enough — exactly the pattern reported, and why it read as a decision about aperture
/// rather than a bug in the rail.
///
/// ## Why "the widget exists" would not have caught it
///
/// `find.byKey('dial-rail')` passes on the broken build: the `Padding` is in the tree for
/// every dial. What was wrong is that **nothing inside it had any height**. So this measures
/// the drawn ticks. Run against the pre-fix code it must fail with a tallest tick of 0.0.
void main() {
  const full = Size(914, 411);

  Future<void> pump(WidgetTester tester, String mode) async {
    await tester.binding.setSurfaceSize(full);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final app = connectedTestAppState(previewRunning: true);
    addTearDown(app.dispose);
    // The dials live in **full screen**, and the flag is set directly rather than by
    // tapping `btn-fullscreen`: a tap depends on the button's position surviving whatever
    // else the page is doing, and this check is not about the toggle.
    app.fullScreen = true;
    // Each dial's ladder comes from the camera's own report, so the state is injected
    // rather than left at the fixture's default — the default is what let the aperture
    // ladder defect through (`analysis/74`: every fixture used `Fnumber: '1.0'`).
    app.setTestCameraState(stateIn(mode));
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      // Wrapped like production: `HomeShell` rebuilds the page through an
      // `AnimatedBuilder` on `AppState`, and a page pumped bare gets **no rebuild** when
      // the state changes (`mode_aware_dials_test.dart` records the same trap).
      home: AnimatedBuilder(
          animation: app, builder: (_, __) => LiveViewPage(app: app)),
    ));
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 40));
    }
    // Stopped **inside the body**: `previewRunning: true` starts `AppState`'s 250 ms
    // ticker and `flutter_test` checks for pending timers before teardowns run
    // (`analysis/57`).
    await app.stopPreview();
  }

  /// The drawn height of the tallest tick inside [dial]'s rail. Zero means the rail is in
  /// the tree and invisible, which is the defect.
  double tallestTick(WidgetTester tester, String dial) {
    final rail = find.descendant(
      of: find.byKey(ValueKey<String>(dial)),
      matching: find.byKey(const ValueKey<String>('dial-rail')),
    );
    expect(rail, findsOneWidget, reason: '$dial has no rail in the tree at all');
    final ticks = find.descendant(of: rail, matching: find.byType(Container));
    expect(ticks, findsWidgets, reason: '$dial rail has no ticks');
    var tallest = 0.0;
    for (final e in ticks.evaluate()) {
      final r = e.renderObject;
      if (r is! RenderBox) continue;
      // **The margin is the trap.** A `Container`'s `size` is its **outer** box, margin
      // included, so it is the `Expanded`'s share whether or not anything is painted
      // inside it — a first version of this check measured that and passed on the broken
      // build. What is visible is the box minus the margin it carries, and that is what
      // goes to zero once the ladder is long enough.
      final m = tester.widget<Container>(find.byWidget(e.widget)).margin;
      final inset = m is EdgeInsets ? m.vertical : 0.0;
      final visible = r.size.height - inset;
      if (visible > tallest) tallest = visible;
    }
    return tallest;
  }

  testWidgets('M draws a rail on the short ladder AND the long one',
      (tester) async {
    // M seats the aperture and the shutter — 14 entries and 57 — so it is the mode where
    // the difference showed. It is the screen the maintainer was looking at.
    await pump(tester, 'M');

    for (final dial in <String>['dial-aperture', 'dial-shutter']) {
      expect(find.byKey(ValueKey<String>(dial)), findsOneWidget,
          reason: '$dial is not on screen in M, so this check is not measuring M');
      final h = tallestTick(tester, dial);
      expect(h, greaterThan(0.0),
          reason: '$dial is in M and its rail draws nothing — tallest tick $h dp. The '
              'rail is one `Expanded` per ladder entry, so a long ladder collapses once '
              'each tick is shorter than the gap it carries. Aperture has 14 entries, '
              'shutter 57, and before the fix only the short one was visible.');
    }
  });

  testWidgets('and A does too, where the pairs differ', (tester) async {
    // A seats EV and aperture, so the long ladder here is EV. A second mode because the
    // defect was ladder-length-dependent rather than mode-dependent — a fix that happened
    // to work in M could still leave A empty.
    await pump(tester, 'A');
    for (final dial in <String>['dial-ev', 'dial-aperture']) {
      expect(find.byKey(ValueKey<String>(dial)), findsOneWidget,
          reason: '$dial is not on screen in A');
      expect(tallestTick(tester, dial), greaterThan(0.0),
          reason: '$dial draws no rail in A');
    }
  });

  testWidgets('the left column keeps what already worked', (tester) async {
    // ISO is the other long ladder (~30) and the mode dial the other short one (6). A fix
    // must not trade one for the other.
    await pump(tester, 'M');
    for (final dial in <String>['dial-iso', 'dial-mode']) {
      expect(tallestTick(tester, dial), greaterThan(0.0),
          reason: '$dial draws no rail');
    }
  });
}
