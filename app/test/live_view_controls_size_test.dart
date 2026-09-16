import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yi_m1_controller/protocol/camera_state.dart';
import 'package:yi_m1_controller/protocol/http_params.dart';
import 'package:yi_m1_controller/state/app_state.dart';
import 'package:yi_m1_controller/ui/pages/live_view_page.dart';
import 'package:yi_m1_controller/ui/widgets/exposure_dial.dart';

import 'fakes.dart';
import 'package:yi_m1_controller/l10n/l10n.dart';

/// Measurements for the controls the user reported as too small, and for the
/// settings panel they reported as showing too few rows.
///
/// ## Why measure first
///
/// "The buttons feel small" and "the panel only shows two rows" are both claims about
/// numbers — a button's tap target and a panel's usable height. Writing them down turns
/// the report into something a change can be checked against, and stops the fix from
/// being a guess that happens to look better in one screenshot.
///
/// The portrait body is 411x727: the emulator's window minus the shell's app bar and tab
/// strip, measured from `dumpsys`-backed bounds rather than assumed. Getting that wrong
/// once already made an overflow test pass while the device overflowed.
///
/// ## The box this file used to read, and why every number in it was wrong
///
/// `getSize` returns the **layout** box. The controls live inside `_BandFitted`, whose
/// `FittedBox(fit: BoxFit.scaleDown)` scales painting and hit-testing but not
/// constraints, so the layout box is not what the user sees — `analysis/45` §4 records
/// the same trap costing a round, and `fullscreen_controls_size_test.dart` records
/// `getSize` reporting 68 dp for a button drawn at 15.
///
/// Measured in the same run that asserted `>= 64`, on the tree **before** the fix this
/// file's checks found:
///
///     control              orientation   getSize   getRect (painted)
///     btn-shutter          portrait        68.0        62.9
///     btn-focus-centre     portrait        56.0        51.8
///     btn-shutter          landscape       68.0        55.0
///     btn-focus-centre     landscape       56.0        45.3
///
/// So the shutter passed `>= 64` while being painted at 62.9, and the landscape focus
/// button passed `>= 48` while being painted **below Material's floor**. The assertions
/// below are on `getRect` — the rect with every ancestor transform applied, which is
/// what `analysis/45` §4 calls the only honest answer for "how big is it on screen".
///
/// ## Two things fell out of measuring it
///
/// 1. **Portrait was losing 7.5% for nothing.** The bar is 320 dp wide and pads itself
///    8 dp a side, so the row inside it was laid out in 296 dp — the row was *designed*
///    at 320 and its own `FittedBox` quietly took it to 0.925. The row is now designed
///    at the width the bar actually gives it (`_ShutterBar._barPaddingX`), and portrait
///    paints the controls at 1.0: the shutter at **68.0**, not 62.9.
/// 2. **Landscape is 0.875**, and that is the settled trade rather than a defect: the
///    control band is 288 dp (`analysis/54`, held there by
///    `fullscreen_band_split_test.dart`) and the bar is 320, so the band's `_BandFitted`
///    scales the whole bar as one piece. Measured: shutter **59.5**, focus-centre
///    **49.0**. The design-space `>= 64` this file used to assert is not a number this
///    layout can deliver, and asserting it in the painted space is what says so.
///
/// ## And the dials, which are the same defect one layer down
///
/// A dial's `stepHeight` is 12 **screen** dp of finger, and `_drag` converted the local
/// delta with `box.maxWidth / designWidth` — a ratio of two *design* numbers
/// (`111/175` = 0.634), because a `FittedBox` lays its child out with unbounded
/// constraints and every `LayoutBuilder` inside it sees design space. Measured on the
/// reference body: the wide dial is really painted at **0.803** and the compact one at
/// **1.0**, so the wide shutter dial cost **15.2 dp per detent** and, in the one-dial
/// modes, the EV dial cost **18.9** — two dials in the same column, one gesture, 4 dp
/// apart. The check at the end of this file drags the real page and counts detents.
void main() {
  const portrait = Size(411, 727);
  const landscape = Size(914, 297);

  /// The full-screen landscape body: 914x411, the surface `analysis/60` measures.
  const fullScreenBody = Size(914, 411);

  /// A camera state in a given exposure mode, with the values the page needs to seat
  /// its dials and its state strip.
  CameraState stateIn(String mode) => CameraState({
        'ExposureMode': mode,
        'ImageAspect': '4:3',
        // 44 of 57 in the shutter ladder, so a 27-detent downward drag has room and
        // does not clamp — `kShutterSpeeds` is `TIME, BULB, 60s … 1/4000s`.
        'ShutterSpeed': '1/250s',
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

  Future<AppState> pump(
    WidgetTester tester,
    Size size, {
    CameraState? state,
    bool fullScreen = false,
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final app = connectedTestAppState(previewRunning: true);
    addTearDown(app.dispose);
    if (state != null) {
      // Before the first pump, so the strip and the dials are in the very first frame
      // that is laid out.
      app.setTestCameraState(state);
      app.fullScreen = fullScreen;
    }
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      home: LiveViewPage(app: app),
    ));
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 40));
    }
    return app;
  }

  /// The size the user can see and hit: `getRect` applies every ancestor transform,
  /// `getSize` does not.
  double paintedSizeOf(WidgetTester tester, String key) =>
      tester.getRect(find.byKey(ValueKey<String>(key))).shortestSide;

  /// Both boxes, printed, so a change in either one is visible in the log rather than
  /// only in the assertion that reads one of them.
  void report(WidgetTester tester, String key) {
    final f = find.byKey(ValueKey<String>(key));
    if (f.evaluate().isEmpty) {
      debugPrint('  $key: ABSENT');
      return;
    }
    final laid = tester.getSize(f);
    final painted = tester.getRect(f);
    debugPrint('  $key: laid ${laid.width.toStringAsFixed(1)} x '
        '${laid.height.toStringAsFixed(1)}, painted '
        '${painted.width.toStringAsFixed(1)} x '
        '${painted.height.toStringAsFixed(1)} '
        '(scale ${(painted.width / laid.width).toStringAsFixed(3)})');
  }

  testWidgets('portrait: the controls are painted at their design size',
      (tester) async {
    final app = await pump(tester, portrait);
    expect(tester.takeException(), isNull);

    for (final key in ['btn-shutter', 'btn-focus-centre', 'btn-settings-toggle']) {
      report(tester, key);
    }

    // Material's own guidance: 48dp is the *minimum* tap target, and a shutter is
    // the primary action of a camera — it should be comfortably above it. This is the
    // same 64 the file always asked for; what changed is that it is now read off the
    // **painted** rect, where the old reading reported a 68 dp layout box for a button
    // drawn at 62.9.
    expect(paintedSizeOf(tester, 'btn-shutter'), greaterThanOrEqualTo(64),
        reason: 'the shutter is the primary control of a camera app; 48-56dp is a '
            'minimum tap target, not a comfortable primary action — and this is the '
            'size it is drawn at, not the size it is laid out at');
    expect(paintedSizeOf(tester, 'btn-focus-centre'), greaterThanOrEqualTo(48),
        reason: 'the focus button is painted at '
            '${paintedSizeOf(tester, 'btn-focus-centre')} dp; 48 is Material\'s floor');

    await app.stopPreview();
  });

  testWidgets('portrait: the settings panel gets usable height', (tester) async {
    final app = await pump(tester, portrait);
    await tester.tap(find.byKey(const ValueKey<String>('btn-settings-toggle')));
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.takeException(), isNull);

    final panel = find.byKey(const ValueKey<String>('live-settings-panel'));
    expect(panel, findsOneWidget,
        reason: 'the panel needs a key so its height can be measured at all');
    // `getRect`, like the controls above: the panel is not inside a scaling ancestor
    // today, and measuring it the same way is what would notice if it became one.
    final h = tester.getRect(panel).height;
    debugPrint('  settings panel height: ${h.toStringAsFixed(1)}dp of '
        '${portrait.height}dp body');

    // Header (~44) + tab strip (~34) are fixed chrome. Anything under ~200dp total
    // leaves barely two rows, which is what was reported.
    expect(h, greaterThanOrEqualTo(240),
        reason: 'panel is ${h.toStringAsFixed(0)}dp: minus ~78dp of header and tabs '
            'that is too few settings rows to be worth opening');

    await app.stopPreview();
  });

  testWidgets('landscape: the controls are painted above the minimum tap target',
      (tester) async {
    final app = await pump(tester, landscape);
    expect(tester.takeException(), isNull);

    for (final key in [
      'btn-shutter',
      'btn-focus-centre',
      'btn-preview-toggle',
      'btn-fullscreen',
      'btn-settings-toggle',
    ]) {
      report(tester, key);
    }

    // The fixture has to be exercising the scaling, or the assertions below are the
    // layout ones again under a different name — `AGENTS.md` §8, and the shape this
    // whole file was fixed for.
    expect(paintedSizeOf(tester, 'btn-shutter'),
        lessThan(tester.getSize(find.byKey(const ValueKey<String>('btn-shutter')))
            .shortestSide),
        reason: 'the landscape band is narrower than the shutter row, so the painted '
            'button must be smaller than the layout box; if the two agree, this check '
            'has stopped measuring what it claims to');

    // 48 is Material's floor and it is the honest threshold here: the control band is
    // 288 dp and the row 320 (`analysis/54`), so the band's `FittedBox` paints the row
    // at 0.875 — 59.5 dp of shutter and 49.0 of focus. The old `>= 64` was a claim
    // about the layout box and could not be met by anything on screen.
    expect(paintedSizeOf(tester, 'btn-shutter'), greaterThanOrEqualTo(48),
        reason: 'the shutter is painted at '
            '${paintedSizeOf(tester, 'btn-shutter')} dp in landscape');
    expect(paintedSizeOf(tester, 'btn-focus-centre'), greaterThanOrEqualTo(48),
        reason: 'the focus button is painted at '
            '${paintedSizeOf(tester, 'btn-focus-centre')} dp in landscape, against '
            'Material\'s 48 dp floor');

    await app.stopPreview();
  });

  testWidgets('full screen: one detent costs 12 dp of finger, on every dial',
      (tester) async {
    // ## Why this belongs in a file about control sizes
    //
    // "The dial is hard to use" and "the button is too small" are the same measurement
    // asked two ways: how much of the *screen* does the finger have to cross. A dial's
    // contract is one detent per `ExposureDial.stepHeight` = 12 **screen** dp, on every
    // dial, whatever the layout does to its size — the same sentence the class writes in
    // three places.
    //
    // The arithmetic that implements it read `box.maxWidth / designWidth` inside the
    // dial's own `FittedBox`, and that ratio is a ratio of design numbers: 0.634 for the
    // wide dial whichever size it is drawn at, and 1.0 for the compact one. So this
    // layout — where the wide dial is painted at 0.803 and the compact one at 1.0 — had
    // the two disagreeing by 5 dp per detent, and in the one-dial modes by 7.
    final app = await pump(tester,
        fullScreenBody, state: stateIn('M'), fullScreen: true);
    tester.takeException();

    // The controls in this layout, for the record. The shutter is a real target here at
    // **55.9** (0.8214); the three 56 dp side controls come out at **46.0**, i.e. two dp
    // under Material's 48 dp floor, and the settings toggle at **34.8**. None of those
    // three is asserted below: the full-screen column's slot arithmetic is `analysis/60`'s
    // settled table (`fullScreenColumnSlots`, the pinned shutter, the dial region), and
    // re-opening it to buy 2 dp is a different round than this one. They are printed so
    // that the numbers are in the log rather than only in a comment — the whole lesson of
    // `analysis/45` §4 is that a control's size is a measurement, not a claim.
    for (final key in [
      'btn-shutter',
      'btn-focus-centre',
      'btn-preview-toggle',
      'btn-fullscreen',
      'btn-settings-toggle',
    ]) {
      report(tester, key);
    }
    expect(paintedSizeOf(tester, 'btn-shutter'), greaterThanOrEqualTo(48),
        reason: 'the shutter is painted at ${paintedSizeOf(tester, 'btn-shutter')} dp '
            'in full screen, against Material\'s 48 dp floor');

    const shutterKey = 'dial-shutter';
    const isoKey = 'dial-iso';
    for (final key in [shutterKey, isoKey]) {
      expect(find.byKey(ValueKey<String>(key)), findsOneWidget,
          reason: 'mode M in full screen seats $key; without it this check would '
              'measure nothing');
      // The dial's *inner* scale: the rail is 3 design dp wide and sits inside the
      // dial's own `FittedBox`, so its painted/laid ratio is the scale the ladder,
      // the type and the gesture all share. (The dial's keyed box is outside that
      // `FittedBox`, which is why `mode_aware_dials_test`'s ratio of 1.0 is about the
      // band and not about this.)
      final rail = find.descendant(
          of: find.byKey(ValueKey<String>(key)),
          matching: find.byKey(const ValueKey<String>('dial-rail')));
      expect(rail, findsOneWidget);
      final scale = tester.getRect(rail).width / tester.getSize(rail).width;
      debugPrint('  $key: painted scale ${scale.toStringAsFixed(3)} '
          '(rect ${tester.getRect(find.byKey(ValueKey<String>(key)))} vs '
          'laid ${tester.getSize(find.byKey(ValueKey<String>(key)))})');
    }

    // The two scales are genuinely different in this layout — that is what makes one
    // gesture on each of them a test rather than two ways of writing 12.
    double innerScale(String key) {
      final rail = find.descendant(
          of: find.byKey(ValueKey<String>(key)),
          matching: find.byKey(const ValueKey<String>('dial-rail')));
      return tester.getRect(rail).width / tester.getSize(rail).width;
    }

    expect(innerScale(shutterKey), lessThan(0.9),
        reason: 'the wide dial is designed at $kDialWidth x the design box and given a '
            'cell of about 49 dp, so it is painted at ~0.80; a value near 1.0 means the '
            'fixture is no longer producing the two-scale layout this check needs');
    expect(innerScale(isoKey), closeTo(1.0, 0.02),
        reason: 'the compact dial is designed at $kCompactDialWidth for the 78 dp '
            'readout band and is painted at 1.0 — the dial the wide one disagreed with');

    // ## The drag, and how the count is kept honest
    //
    // 30 dp a move, eleven moves, downward: 330 dp of finger for 27 detents at 12 dp
    // each, and the move that spends the recogniser's touch slop is performed **before**
    // the start index is read, so the count does not depend on knowing how much the
    // slop ate (`exposure_dial_test.dart` records that a slice under the slop never
    // reaches the widget).
    //
    // `label` is how the identity writes a wire value for a person — `labelFor` for the
    // three exposure parameters, `evLabel` for the EV dial (which writes a positive EV
    // as `+4.0`, so reading the raw pool back would find nothing).
    int readoutIndex(String key, List<String> pool, String Function(String) label) {
      final labels = [for (final v in pool) label(v)];
      final shown = tester
          .widgetList<Text>(find.descendant(
              of: find.byKey(ValueKey<String>(key)), matching: find.byType(Text)))
          .map((t) => t.data)
          .whereType<String>()
          .where(labels.contains)
          .toList();
      expect(shown.length, 3,
          reason: 'the ladder draws three lines — above, at, below the readout — and '
              'the middle one is the value; found $shown');
      return labels.indexOf(shown[1]);
    }

    final dial = find.byKey(const ValueKey<String>(shutterKey));
    final gesture = await tester.startGesture(tester.getCenter(dial));
    await tester.pump(const Duration(milliseconds: 16));
    await gesture.moveBy(const Offset(0, 30));
    await tester.pump(const Duration(milliseconds: 16));
    final before = readoutIndex(shutterKey, kShutterSpeeds, (v) => labelFor(v, ExposureParam.shutter));
    for (var i = 0; i < 11; i++) {
      await gesture.moveBy(const Offset(0, 30));
      await tester.pump(const Duration(milliseconds: 16));
    }
    final after = readoutIndex(shutterKey, kShutterSpeeds, (v) => labelFor(v, ExposureParam.shutter));
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 16));
    debugPrint('  dial-shutter: ${before - after} detents for 330 screen dp '
        '(330 / 12 = 27.5, so 27 crossed with 6 dp of finger left in the carry; '
        'painted scale ${innerScale(shutterKey).toStringAsFixed(3)})');

    expect(before, greaterThan(27),
        reason: 'the fixture starts the shutter at index $before of ${kShutterSpeeds.length} '
            'and the drag needs 27 detents below it; a start near the bottom would clamp '
            'and this check would measure the clamp instead');
    expect(before - after, 27,
        reason: '330 dp of finger crossed ${before - after} detents — 330 / 12 = 27.5, so '
            '27 is one detent per **12** dp of screen travel with the remaining 6 dp still '
            'in the carry. 12 dp of finger per detent is the figure `_drag`, the class doc '
            'and `haptic_feedback_test` all name, spelled here rather than read from the '
            'private constant because it is the *claim* — and this dial is painted at '
            '${innerScale(shutterKey).toStringAsFixed(3)} of its design size, which is '
            'exactly the number the old arithmetic read as 0.634');

    await app.stopPreview();

    // ## The same gesture on the dial that filled its slot
    //
    // In M the column holds two dials and each gets a ~49 dp cell, so the wide dial is
    // painted at 0.803. In P/Auto/C it holds **one**, which fills the slot and is painted
    // at **1.0** — and the old arithmetic read the same 0.634 for both, so the EV dial was
    // the furthest out of any of them: `12 x 1.0 / 0.634` = **18.9 dp** per detent against
    // the 12 the class promises, while the compact ISO dial in the column beside it was
    // drawn at 1.0 and read as 1.0, i.e. exactly right. Two dials, one gesture, 7 dp apart.
    final pApp = await pump(tester,
        fullScreenBody, state: stateIn('P'), fullScreen: true);
    tester.takeException();
    const evKey = 'dial-ev';
    expect(find.byKey(const ValueKey<String>(evKey)), findsOneWidget,
        reason: 'mode P seats the EV dial and nothing else above the shutter; this is '
            'the one-dial slot the old arithmetic was furthest out on');
    debugPrint('  $evKey: painted scale ${innerScale(evKey).toStringAsFixed(3)} '
        '(cell ${tester.getSize(find.byKey(const ValueKey<String>(evKey)))})');
    expect(innerScale(evKey), closeTo(1.0, 0.02),
        reason: 'the single dial fills the slot, so it is painted at 1.0 — the scale the '
            'old arithmetic called 0.634');

    // 30 dp a move — **two and a half** detents each — so the count never sits on a
    // `truncate()` boundary: a move that lands on an exact multiple of 12 leaves the
    // remainder at 0 ± floating-point noise, and one ulp below it costs a whole detent.
    // (Measured: 24 dp moves on this dial, whose scale is 1.0 to within a rounding error,
    // crossed 11 detents instead of 12 for exactly that reason.) Six moves upward is 180
    // dp for 15 detents, and the fixture's -0.7 is index 13 of 31, so nothing clamps.
    final evDial = find.byKey(const ValueKey<String>(evKey));
    final evGesture = await tester.startGesture(tester.getCenter(evDial));
    await tester.pump(const Duration(milliseconds: 16));
    await evGesture.moveBy(const Offset(0, -30));
    await tester.pump(const Duration(milliseconds: 16));
    final evBefore = readoutIndex(evKey, kEvValues, evLabel);
    for (var i = 0; i < 6; i++) {
      await evGesture.moveBy(const Offset(0, -30));
      await tester.pump(const Duration(milliseconds: 16));
    }
    final evAfter = readoutIndex(evKey, kEvValues, evLabel);
    await evGesture.up();
    await tester.pump(const Duration(milliseconds: 16));
    debugPrint('  $evKey: ${evAfter - evBefore} detents for 180 screen dp '
        '(180 / 12 = 15 exactly; painted scale '
        '${innerScale(evKey).toStringAsFixed(3)})');

    expect(kEvValues.length - evBefore, greaterThanOrEqualTo(15),
        reason: 'the fixture starts EV at index $evBefore of ${kEvValues.length} and the '
            'drag crosses 15 detents upwards; fewer available would clamp and this would '
            'measure the clamp');
    expect(evAfter - evBefore, 15,
        reason: '180 dp of finger crossed ${evAfter - evBefore} detents — 180 / 12 = 15, '
            'one detent per 12 dp of screen travel — on a dial painted at '
            '${innerScale(evKey).toStringAsFixed(3)}. The old arithmetic would have given '
            'about 9 (18.9 dp each), because it read this dial\'s scale as 0.634');
    await pApp.stopPreview();
  });
}
