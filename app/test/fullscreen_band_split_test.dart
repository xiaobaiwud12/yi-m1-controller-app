import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yi_m1_controller/protocol/camera_state.dart';
import 'package:yi_m1_controller/protocol/viewfinder_layout.dart';
import 'package:yi_m1_controller/ui/pages/live_view_page.dart';
import 'package:yi_m1_controller/ui/widgets/exposure_dial.dart';

import 'fakes.dart';
import 'package:yi_m1_controller/l10n/l10n.dart';

/// The band the two landscape side columns have to share, and who wins it.
///
/// ## Why this file exists separately from `fullscreen_controls_size_test.dart`
///
/// That one measures the **rendered** size of every control and is the check the
/// defect was reported against. This one covers the one thing it cannot see: **where
/// the width went**, because "the controls got their size back" and "the readout was
/// starved to pay for it" are both consistent with those numbers, and only the band
/// arithmetic separates them.
///
/// The readout's own legibility — how large its type is actually painted, in both
/// layouts, against the camera's real vocabulary — is measured in
/// `readout_legibility_test.dart`. It used to be checked here, with a fixture built
/// from enum *constant names* (`AperturePriority`, `CenterWeighted`) that the UI never
/// draws; this file now only asks that the column is not squeezed out of the width
/// the control band needs.
///
/// The defect itself: `ViewfinderLayout` used to split the slack evenly (183 / 183
/// on a 914x411 body) when the two columns' own widths did not both fit, so the
/// 320 dp shutter row was scaled to 0.547 and the 68 dp shutter was painted at
/// **34.4 dp**, below Material's 48 dp floor, in the mode whose whole purpose is to
/// make shooting easier. See `analysis/54`.
void main() {
  const normal = Size(914, 297);
  const full = Size(914, 411);

  /// The longest value each readout row can be asked to draw, per
  /// `app/tools/measure_readout_strings.py` and the pools in `http_params.dart`:
  /// `Incandescent` (12 characters) and `HContrastBW` (11) are the long ones, and
  /// `1/4000s` the longest shutter label.
  ///
  /// A fixture built from anything else — an enum constant name, a short value —
  /// measures a column that does not exist. `readout_legibility_test.dart` walks the
  /// whole pools for the same reason.
  const widest = CameraState({
    'ExposureMode': 'Auto',
    'ImageAspect': '4:3',
    'ShutterSpeed': '1/4000s',
    'Fnumber': '1.0',
    'ISOSetting': '25600',
    'WB': 'Incandescent',
    'ColorMode': 'HContrastBW',
    'BatteryLevel': '100',
    'SurplusPhotoCnts': '9999',
    'EV': '-5.0',
  });

  Future<void> pump(WidgetTester tester, Size size, {required bool fullScreen}) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final app = connectedTestAppState();
    addTearDown(app.dispose);
    app.fullScreen = fullScreen;
    app.setTestCameraState(widest);
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
    expect(tester.takeException(), isNull);
  }

  /// The three columns of the landscape row: readout band, picture, control band.
  ///
  /// Read off the laid-out tree rather than recomputed from `ViewfinderLayout`, so a
  /// page that stopped passing its measured widths — or that let one band's content
  /// push its way wider — cannot pass this by agreeing with itself.
  List<double> columnWidths(WidgetTester tester) {
    final row = find.byType(Row).evaluate().first.renderObject as RenderFlex;
    final widths = <double>[];
    for (var c = row.firstChild; c != null; c = row.childAfter(c)) {
      widths.add(c.size.width);
    }
    return widths;
  }

  testWidgets('the control band does not lose width to the readout in full screen',
      (tester) async {
    await pump(tester, normal, fullScreen: false);
    final normalCols = columnWidths(tester);

    await pump(tester, full, fullScreen: true);
    final fullCols = columnWidths(tester);

    debugPrint('  columns (readout, picture, controls)  normal=$normalCols  '
        'full=$fullCols');

    expect(normalCols.length, 3, reason: 'landscape should be three columns');
    expect(fullCols.length, 3, reason: 'landscape should be three columns');

    // The arithmetic that was wrong. 288 is the control column's own design width
    // (the shutter bar is 320 dp and `_BandFitted` takes 4 dp a side off it), and it
    // is the number `analysis/54` records the defect against: at 183 the shutter was
    // painted at 34.4 dp.
    expect(fullCols[2], greaterThanOrEqualTo(288),
        reason: 'the control band is ${fullCols[2]} dp in full screen. Below 288 the '
            'shutter row no longer fits and `FittedBox` scales the controls down — '
            'which is the defect, not a tight fit');
    // Which is to say it is not smaller than the normal layout's, because the
    // controls are the thing a thumb has to find without looking.
    expect(fullCols[2], greaterThanOrEqualTo(normalCols[2]),
        reason: 'full screen took width away from the controls '
            '(${fullCols[2]} against ${normalCols[2]} dp normally)');

    // And the readout is what paid in the **full-screen** layout. Stated as the
    // layout's own floor rather than an equality, so a future body that leaves more
    // slack is free to be generous — and note that the normal layout's readout is
    // *wider* than this floor (156 dp, the width the camera's own words need), which
    // is not a contradiction: the two layouts have different slack to spend.
    expect(fullCols[0], greaterThanOrEqualTo(kMinReadoutBand),
        reason: 'the readout band is ${fullCols[0]} dp, under the '
            '$kMinReadoutBand dp floor `ViewfinderLayout` is supposed to hold for it');
    // The picture, which is what full screen was for. The two layouts no longer come
    // out with the same bands — the normal one gives the readout 156 dp of the 518 it
    // has spare — so the assertion is the absolute one the sibling test uses rather
    // than a comparison: a change that buys control size by giving the picture back is
    // not a fix. (The 4:3 frame *inside* this area is 396x297 in the normal layout and
    // 548x411 in full screen; `readout_legibility_test.dart` measures that box, because
    // the area's width is not the picture's width.)
    for (final (label, cols, height) in [
      ('normal', normalCols, normal.height),
      ('full screen', fullCols, full.height),
    ]) {
      expect(cols[1] * height, greaterThan(396.0 * 297.0),
          reason: 'the $label picture is only ${cols[1]} x $height, no larger than the '
              '396x297 a 4:3 frame gets on the 914x297 body. Full screen exists to '
              'show more picture than that');
    }
  });

  testWidgets('the readout is the column that scales, not the controls',
      (tester) async {
    // The precise statement of the trade, in one place: in full screen the readout
    // column is scaled and the control column is not.
    //
    // `getRect`/`getSize` is the pair that matters here — inside a `FittedBox` they
    // differ by exactly the scale factor (`analysis/45` §4), so the ratio of the two
    // *is* the scale. Using `getSize` on both sides would report 1.0 for everything
    // and this check would be decorative.
    await pump(tester, full, fullScreen: true);

    double scaleOf(String key) {
      final f = find.byKey(ValueKey<String>(key));
      final painted = tester.getRect(f).size.width;
      final laid = tester.getSize(f).width;
      return laid == 0 ? 1 : painted / laid;
    }

    for (final k in ['btn-shutter', 'btn-focus-centre', 'btn-preview-toggle']) {
      expect(scaleOf(k), greaterThan(0.7),
          reason: '$k is drawn at ${scaleOf(k)} of its layout size in full screen, '
              'which is the control band being squeezed again');
    }
    // The measured figures, since this is the file that owns them: all three are drawn at
    // **0.809** in full screen — the same as in the normal landscape layout, and the
    // figure `analysis/54` quotes for the shutter (55.04 dp painted against a 68 dp
    // design). It is `_BandFitted` around the 320 dp shutter row, and it is unchanged by
    // the pinned-shutter column.
    debugPrint('  scale in full screen: '
        '${[for (final k in ['btn-shutter', 'btn-focus-centre', 'btn-preview-toggle']) "$k=${scaleOf(k).toStringAsFixed(3)}"].join(" ")}');
    for (final k in ['btn-shutter', 'btn-focus-centre', 'btn-preview-toggle']) {
      expect(scaleOf(k), greaterThan(0.7),
          reason: '$k is drawn at ${scaleOf(k)} of its layout size in full screen, '
              'which is the control band being squeezed again');
    }
    // The measured figures for the record, since this is the file that owns them:
    // the shutter is 55.04 x 55.04 painted against a 68 dp layout, i.e. **0.809** — the
    // same in the normal layout and in full screen, and the number `analysis/54` quotes.
    debugPrint('  scale in full screen: '
        '${[for (final k in ['btn-shutter', 'btn-focus-centre', 'btn-preview-toggle']) "$k=${scaleOf(k).toStringAsFixed(3)}"].join(" ")}');

    // The readout text, by the same measure: it is inside `_BandFitted` too, and the
    // page accepted the scaling *there* instead. The row is named by the value it
    // draws in this band — the white balance, whose short form is the one string the
    // narrow column cannot draw at full size (7 characters, 84.0 dp, into 66).
    final value = find.text('Incand.');
    expect(value, findsOneWidget,
        reason: 'the narrow readout column should be drawing the white-balance short '
            'form; if it is drawing something else this check measures that instead');
    final painted = tester.getRect(value).size.width;
    final laid = tester.getSize(value).width;
    expect(painted, lessThan(laid),
        reason: 'the readout was expected to be the column that pays for the control '
            'band in full screen, and it is not scaled at all');
  });

  testWidgets('the control column holds the dials and still fits its band',
      (tester) async {
    // **This check used to reserve a slot for a dial that did not exist yet.** It read
    // "the control column's content is 293.1 dp against a 411 dp band, so there is
    // 117.9 dp spare — enough for a 56 dp dial plus its 8 dp of column padding", and it
    // identified the control column as *the side column shorter than 300 dp*.
    //
    // The dials now exist (`analysis/60`), and that premise is gone rather than
    // violated: the same layout measures **384.0 dp** (readout column: the 250 dp
    // readout plus ISO and the shooting mode) and **349.1 dp** (control column: the
    // toggle row, one EV dial, the blocked shutter bar and the navigation row), so
    // neither column is under 300 dp and the "spare height" question no longer has a
    // meaning — the slot is occupied.
    //
    // What survives is the property the check exists for and the one that would break:
    // **a side column taller than its band is scrolled**, and its content is then scaled
    // by the same `FittedBox` that painted the shutter at 34.4 dp. Both are asserted
    // below, together with the dials actually being in the column. (The full per-mode
    // table, the design sizes and the text-scale sweep are in
    // `mode_aware_dials_test.dart`.)
    await pump(tester, full, fullScreen: true);
    final slots = fullScreenColumnSlots(full.height);

    // ## What this check is about, restated for the slotted column
    //
    // Its original subject was: *a side column taller than its band is scrolled **and
    // scaled**.* Under the content-sized column those were one event, because the scroll
    // view's content was the whole column and `_BandFitted` scaled all of it — that is the
    // mechanism that painted the shutter at 34.4 dp (`analysis/54`).
    //
    // The slotted column separates them (the user's third report: the shutter must not
    // move and the space around it must fill). Each slot has a computed height, and only
    // the **below** slot scrolls — deliberately, because the camera's explanation of a
    // refused shot is 142 dp of text and the slot is 125.2. So "the column scrolls" is no
    // longer the defect; what is a defect is either of the two things the slot arithmetic
    // exists to prevent:
    //
    //   * the **shutter** being scaled — checked by `mode_aware_dials_test.dart`, whose
    //     rect is identical across all eight mode x histogram combinations;
    //   * a **dial** being squeezed — checked here, as the dial filling the cell the
    //     slots gave it at scale 1.0.
    //
    // What survives of the original check is that both side columns are still on screen
    // and that the band is not overrun. The `_BandFitted` boxes are also asserted to have
    // their content inside them, which is the property whose violation *is* the 34.4 dp
    // defect.
    var sideColumns = 0;
    for (final e in find.byType(FittedBox).evaluate()) {
      final ro = e.renderObject as RenderBox;
      if (ro.size.width <= 0 || ro.size.height <= 0) continue;
      debugPrint('  band fitted box ${ro.size} '
          'constraints=${ro.constraints}');
    }
    for (final e in find.byType(Column).evaluate()) {
      final ro = e.renderObject as RenderBox;
      final p = ro.parent;
      if (p is! RenderBox || !p.runtimeType.toString().contains('Viewport')) {
        continue;
      }
      sideColumns++;
      debugPrint('  side column natural=${ro.size.height.toStringAsFixed(1)} '
          'viewport=${p.size.height.toStringAsFixed(1)}');
      // The **band** is what must not be overrun. A scrollable slot whose content is
      // taller than it is the design (the message), so the assertion is against the band
      // — 411 dp — and not against the slot, which would forbid the scroll.
      expect(ro.size.height, lessThanOrEqualTo(full.height + 0.5),
          reason: 'a side column is ${ro.size.height} dp tall in a ${full.height} dp '
              'band — the column itself is overrunning, not merely scrolling');
    }
    expect(sideColumns, 2,
        reason: 'expected the two landscape side columns, found $sideColumns');

    // And the slot is occupied by the dial the fixture's mode asks for. This fixture is
    // in `Auto`, where the camera owns both the aperture and the shutter, so the plan
    // seats exactly one dial above the shutter and the ISO and mode dials on the left.
    for (final k in ['dial-ev', 'dial-iso', 'dial-mode']) {
      expect(find.byKey(ValueKey<String>(k)), findsOneWidget,
          reason: '$k is missing from the full-screen layout');
    }
    // ## What the digits are now
    //
    // The single dial gets the **whole** dial region, because the region is sized from the
    // band and not from how many dials a mode has — that is what keeps the shutter still
    // (`mode_aware_dials_test.dart` measures its rect across all eight mode x histogram
    // combinations). In `Auto` that is one dial filling 102 dp of the `fullScreenColumnSlots`
    // region, where M's two share the same region between them.
    //
    // So the assertion is not "the cell is 48 dp" — that constant is gone, because a fixed
    // cell is exactly what a content-sized column produced. It is the property that
    // replaced it: the dial **fills** its cell and is drawn at its design width, and the
    // cell is what the slot arithmetic says.
    final cell = slots.above - 2 * kColumnChildPadding;
    final evFinder = find.byKey(const ValueKey<String>('dial-ev'));
    final ev = tester.getRect(evFinder);
    debugPrint('  slots=$slots  dial cell=$cell  dial-ev painted=$ev');
    expect(ev.height, closeTo(cell, 0.5),
        reason: 'the dial is ${ev.height} dp in a $cell dp cell: a single dial fills the '
            'region the shutter pinning gave it (analysis/60 §the slotted column)');
    expect(ev.width, closeTo(kDialWidth, 0.5),
        reason: 'a dial drawn narrower than its $kDialWidth dp design has been scaled '
            'down by the band, which is the defect analysis/45 records');
    expect(ev.width / tester.getSize(evFinder).width, closeTo(1.0, 0.01),
        reason: 'the dial is drawn at ${ev.width / tester.getSize(evFinder).width} of its '
            'layout size rather than filling the cell it was handed');
  });
}
