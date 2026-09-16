import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yi_m1_controller/protocol/camera_state.dart';
import 'package:yi_m1_controller/protocol/viewfinder_layout.dart';
import 'package:yi_m1_controller/ui/pages/live_view_page.dart';

import 'fakes.dart';

/// Does a camera that is charging reach the user as **charging**, and not as a
/// percentage that cannot exist?
///
/// ## The two sources this file rests on
///
/// **Measured, on this body** — one controlled pair, from the maintainer: on the
/// charger `BatteryLevel` reads `101`; unplugging it and reading again gives `75`.
/// Earlier readings of `100`, `75` and `50` were all taken unplugged, and `101` has only
/// ever been seen on charge (`analysis/67` §7.3). That is a correlation, measured.
///
/// **Stated by the manufacturer's own code** — the official app's live-view battery
/// widget draws the drawable literally named `…_battery_charging` for exactly `101` and
/// empties the level instead of drawing one
/// (`app/re/jadx-out/sources/com/xiaoyi/mirrorlesscamera/view/CustomBatteryLoading.java`
/// lines 50-54), and the same class rejects any reading above `101` outright
/// (`setProgress`, line 93). That is what the value **means**, and it is why the test is
/// equality rather than "above 100".
///
/// What is still not measured: whether the body reports `101` at every charge level, and
/// what a partly charged one reports. Both ends this file can check are checked — `101`
/// must read as charging, `75` must still read as its own percentage.
///
/// ## Why the sweep comes first
///
/// The first check names **no** new API: it reads every `Text` the page draws and fails
/// on any percentage above 100. That is the defect itself, stated where it is visible,
/// and it is what makes this check able to fail on the broken build — `AGENTS.md` §8.
/// Its failure on the unfixed tree was:
///
///     readout column, wide band (en) drew "101%" for a reading of 101.
///
/// The checks after it are the positive half: the row must say the true thing, in both
/// languages, at both draw sites, and still measure inside the width budget
/// `analysis/55` set for the narrow column.
void main() {
  // The emulator's window: landscape `normal` is the body once the shell's app bar and
  // tab strip have taken their share, `full` is what `btn-fullscreen` hands back, and
  // portrait is the maintainer's phone. The same three the readout checks use.
  const normal = Size(914, 297);
  const full = Size(914, 411);
  const portrait = Size(411, 727);

  /// A camera state in remote mode, with the battery reading under test.
  ///
  /// `SurplusPhotoCnts` is a real count so the strip's `…  {left}` half is present: the
  /// strip draws the reading and the count together, and a fixture without the count
  /// would leave the right-hand `Text` shorter than it is in use.
  CameraState charged(int battery) => CameraState({
        'ExposureMode': 'Auto',
        'ImageAspect': '4:3',
        'ShutterSpeed': '1/125s',
        'Fnumber': '2.8',
        'ISOSetting': '400',
        'WB': 'Auto',
        'ColorMode': 'Standard',
        'BatteryLevel': '$battery',
        'SurplusPhotoCnts': '999',
      });

  /// The layouts the two draw sites live in, and the language each is checked in.
  ///
  /// Site 1 — the readout column's `电量 / …` row — exists where the page uses side
  /// columns: `normal` gives it the wide 156 dp band, full screen gives it the narrow
  /// 78 dp one (`analysis/55`). Site 2 — the compact strip's `…  剩 {left}` — is the
  /// portrait top band. Both sites in both languages is six runs per reading.
  ///
  /// `clean` is false for portrait because the top band **already** overflows there by
  /// 12 px with this fixture, before this round's change: `top_band_histogram_fit_test`
  /// documents the same band overflowing by 44 px with a longer one, and calls it the
  /// pre-existing wrap overflow of `analysis/60` §5. Demanding "no exception" in
  /// portrait would be asserting that other defect away, so the exception is consumed
  /// and not asserted on — the measurements below are taken from the laid-out tree,
  /// which does not depend on it. The landscape layouts must be clean.
  const sites = <({
    String name,
    Size size,
    bool fullScreen,
    String locale,
    bool clean
  })>[
    (
      name: 'readout column, wide band',
      size: normal,
      fullScreen: false,
      locale: 'en',
      clean: true
    ),
    (
      name: 'readout column, wide band',
      size: normal,
      fullScreen: false,
      locale: 'zh',
      clean: true
    ),
    (
      name: 'readout column, narrow band',
      size: full,
      fullScreen: true,
      locale: 'en',
      clean: true
    ),
    (
      name: 'readout column, narrow band',
      size: full,
      fullScreen: true,
      locale: 'zh',
      clean: true
    ),
    (
      name: 'state strip (portrait)',
      size: portrait,
      fullScreen: false,
      locale: 'en',
      clean: false
    ),
    (
      name: 'state strip (portrait)',
      size: portrait,
      fullScreen: false,
      locale: 'zh',
      clean: false
    ),
  ];

  /// Pumps the page, and returns whatever it threw while laying out (null when clean).
  Future<Object?> pump(
    WidgetTester tester,
    ({String name, Size size, bool fullScreen, String locale, bool clean}) site, {
    required CameraState state,
  }) async {
    await tester.binding.setSurfaceSize(site.size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final app = connectedTestAppState();
    addTearDown(app.dispose);
    app.fullScreen = site.fullScreen;
    app.setTestCameraState(state);
    await tester
        .pumpWidget(localizedApp(LiveViewPage(app: app), locale: Locale(site.locale)));
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 40));
    }
    final thrown = tester.takeException();
    if (site.clean) {
      expect(thrown, isNull,
          reason: '${site.name} (${site.locale}) threw while laying out with a '
              'battery reading of ${state.batteryLevel}, so nothing below was measured '
              'on a real tree');
    }
    return thrown;
  }

  /// Every `Text` on screen that carries a percentage, with the number in it.
  ///
  /// Deliberately reads what is **painted** rather than what any part of the code
  /// believes: the two draw sites format the reading themselves (`'$battery%'` in the
  /// readout column, `readoutBatteryAndLeft` in the strip), so a check against either
  /// one alone would miss the other.
  List<({String text, int percent})> drawnPercentages(WidgetTester tester) {
    final out = <({String text, int percent})>[];
    for (final e in find.byType(Text).evaluate()) {
      final w = e.widget as Text;
      final data = w.data;
      if (data == null) continue;
      final m = RegExp(r'(\d+)\s*%').firstMatch(data);
      if (m == null) continue;
      out.add((text: data, percent: int.parse(m.group(1)!)));
    }
    return out;
  }

  /// The `FittedBox` scale a drawn readout value is painted at, the type size that works
  /// out to, the value's own design width, and the width the band actually offered it.
  ///
  /// `getRect` measured against the render object's own size, never `getSize`: every
  /// readout row sits in a `FittedBox(scaleDown)`, whose child keeps its **design**
  /// size, so `getSize` reports what the layout wanted rather than what is on screen
  /// (`analysis/45` §4 — and `analysis/75`: a check that measured the wrong box passes
  /// on the defect).
  ///
  /// `offered` is read off the scaling `FittedBox`'s own constraints rather than
  /// recomputed from `kMinReadoutBand`: `analysis/55`'s 66 dp is `78 − 2×2` of row
  /// padding `− 2×4` of `_BandFitted`, and a check that redid that subtraction would
  /// agree with itself while the band drew something else.
  ({double scale, double drawn, double design, double offered}) paintedValue(
      WidgetTester tester, Finder finder) {
    expect(finder, findsOneWidget,
        reason: 'the row being measured is not on screen exactly once, so the '
            'measurement below is not about it');
    final box = tester.renderObject<RenderBox>(finder);
    final painted = tester.getRect(finder).size;
    final fitted =
        find.ancestor(of: finder, matching: find.byType(FittedBox)).first;
    final offered = tester.renderObject<RenderBox>(fitted).constraints.maxWidth;
    final scale = box.size.width == 0 ? 1.0 : painted.width / box.size.width;
    final fontSize = tester.widget<Text>(finder).style?.fontSize ?? 12.0;
    return (
      scale: scale,
      drawn: fontSize * scale,
      design: box.size.width,
      offered: offered,
    );
  }

  /// The readout column must not have wrapped the value onto a second line.
  void expectOneLine(WidgetTester tester, Finder finder, String what) {
    final para = tester.renderObject<RenderParagraph>(finder);
    expect(para.didExceedMaxLines, isFalse,
        reason: '$what was wrapped onto a second line, which changes the row height '
            'and makes the column jump while the camera reports new values');
  }

  testWidgets('a camera on the charger is never drawn as a percentage above 100',
      (tester) async {
    final offenders = <String>[];
    for (final site in sites) {
      await pump(tester, site, state: charged(101));
      final l = site.locale == 'en' ? en : zh;
      final readout = site.name.startsWith('readout');

      for (final d in drawnPercentages(tester).where((d) => d.percent > 100)) {
        offenders.add('${site.name} (${site.locale}) drew "${d.text}"');
      }

      // The other half of the same assertion, and it is why this sweep names no new
      // API: a fix that stopped drawing the reading instead of correcting it would pass
      // the check above. Both of these are the row's own surroundings — the label the
      // readout column pairs the value with, and the shot count the strip draws beside
      // it — so this half is a statement about the layout rather than about the fix.
      if (readout) {
        expect(find.text(l.readoutBattery), findsOneWidget,
            reason: '${site.name} (${site.locale}) has no ${l.readoutBattery} row at '
                'all, so the percentage check above had nothing to look at');
      } else {
        expect(find.textContaining('999'), findsWidgets,
            reason: '${site.name} (${site.locale}) does not draw the remaining-shot '
                'count any more, so the reading beside it is gone rather than fixed');
      }
    }
    expect(offenders, isEmpty,
        reason: '${offenders.join('; ')}. The camera reports charging as the reading 101 '
            'instead of a percentage, so a percentage that cannot exist is on screen '
            'where the truth belongs');
  });

  testWidgets('the charging reading is drawn as charging, at both sites and in '
      'both languages', (tester) async {
    // The two numbers the short form is a consequence of, measured in the tree rather
    // than quoted: the narrow column's value budget, and how wide the long word is.
    double? narrowBudget;
    double? longWordWidth;

    for (final site in sites) {
      await pump(tester, site, state: charged(101));
      final l = site.locale == 'en' ? en : zh;
      final readout = site.name.startsWith('readout');
      // What each site must draw. The narrow column takes its own short form, the wide
      // column and the strip take the word whole — that pairing *is* the decision this
      // round made, so it is asserted rather than left to the eye.
      final expected = !readout
          ? l.readoutBatteryChargingAndLeft('999')
          : site.size == full
              ? l.readoutBatteryChargingCompact
              : l.readoutBatteryCharging;

      expect(find.text('101%'), findsNothing,
          reason: '${site.name} (${site.locale}) still draws the impossible '
              'percentage');
      expect(find.text(expected), findsOneWidget,
          reason: '${site.name} (${site.locale}) does not say "$expected" for a camera '
              'on the charger; it drew '
              '${drawnPercentages(tester).map((d) => '"${d.text}"').join(', ')}');

      if (readout) {
        // Standing on the label, so the row is the pair it has always been rather
        // than a word with nothing saying what it is about.
        expect(find.text(l.readoutBattery), findsOneWidget,
            reason: 'the ${l.readoutBattery} label left the row when the value '
                'changed, so nothing on screen says what "$expected" is about');
        expectOneLine(tester, find.text(expected), 'the charging word');
        final m = paintedValue(tester, find.text(expected));
        debugPrint('  ${site.name.padRight(26)} ${site.locale}  "$expected" '
            'budget=${m.offered.toStringAsFixed(1)}dp '
            'design=${m.design.toStringAsFixed(1)}dp '
            'scale=${m.scale.toStringAsFixed(3)} drawn=${m.drawn.toStringAsFixed(1)}dp');
        expect(m.scale, greaterThanOrEqualTo(site.size == full ? 0.75 : 0.95),
            reason: '${site.name} (${site.locale}) paints "$expected" at '
                '${m.scale.toStringAsFixed(3)} (${m.drawn.toStringAsFixed(1)} dp). The '
                'narrow column is held to 0.75 and the wide one to 0.95 '
                '(analysis/55) — a word that has to be scaled down is a word that does '
                'not fit, and the fix is a shorter one rather than smaller type');
        // "Fits" stated directly as well as through the scale: the word is drawn at its
        // own size inside what the band offered it, so no scaling is happening at all.
        expect(m.design, lessThanOrEqualTo(m.offered),
            reason: 'the charging word wants ${m.design.toStringAsFixed(1)} dp of the '
                '${m.offered.toStringAsFixed(1)} dp ${site.name} offers it '
                '(${site.locale})');

        if (site.size == full) {
          narrowBudget = m.offered;
        } else if (site.locale == 'en') {
          longWordWidth = m.design;
        }

        // And the other form is *not* on screen: the wide column does not abbreviate,
        // and the narrow one does not overflow itself.
        final other = site.size == full
            ? l.readoutBatteryCharging
            : l.readoutBatteryChargingCompact;
        expect(find.text(other), findsNothing,
            reason: '${site.name} (${site.locale}) drew "$other", which belongs to the '
                'other width of this column');
      } else {
        // The strip carries the count too, and stays inside its row: it is the one draw
        // site that is **not** inside a `FittedBox`, so nothing would scale a word that
        // outgrew the space — it would clip or throw instead. The row is `Expanded`
        // (the joined readout) + 8 dp + this text, so what has to fit is this text plus
        // the gap, and the measurement is of the `Row` that holds them.
        final finder = find.text(expected);
        final rect = tester.getRect(finder);
        final row = tester.getRect(
            find.ancestor(of: finder, matching: find.byType(Row)).first);
        debugPrint('  ${site.name.padRight(26)} ${site.locale}  "$expected" '
            '${rect.width.toStringAsFixed(1)}dp of a ${row.width.toStringAsFixed(1)}dp '
            'row (right=${rect.right.toStringAsFixed(1)}dp of ${site.size.width}dp), '
            'height=${rect.height.toStringAsFixed(1)}dp');
        expect(rect.width + 8, lessThanOrEqualTo(row.width),
            reason: 'the strip drew "$expected" at ${rect.width.toStringAsFixed(1)} dp '
                'in a ${row.width.toStringAsFixed(1)} dp row (${site.locale}), so the '
                'word and its gap no longer fit and nothing here scales them back');
        expect(rect.right, lessThanOrEqualTo(site.size.width + 0.5),
            reason: 'the strip drew "$expected" out to '
                '${rect.right.toStringAsFixed(1)} dp on a ${site.size.width} dp screen');
        expect(rect.height, lessThanOrEqualTo(20),
            reason: 'the strip drew "$expected" in ${rect.height.toStringAsFixed(1)} dp '
                'of height, which is more than one line');
      }
    }

    // The decision, as arithmetic on two numbers measured above rather than as prose:
    // the long word does not fit the narrow column at the legibility floor, so that
    // column has a word of its own. If the column gets wider, or the long word shorter,
    // this fails and the second ARB key should be reconsidered rather than kept.
    expect(narrowBudget, isNotNull,
        reason: 'the full-screen readout column was not measured, so the short form is '
            'in the tree for no stated reason');
    expect(longWordWidth, isNotNull,
        reason: 'the long charging word was not measured, so nothing here says why the '
            'narrow column draws a different one');
    final wouldBeScale = narrowBudget! / longWordWidth!;
    debugPrint('  the narrow column offers ${narrowBudget.toStringAsFixed(1)}dp; the '
        'long word is ${longWordWidth.toStringAsFixed(1)}dp, so it would be drawn at '
        '${wouldBeScale.toStringAsFixed(3)} — the 0.75 floor is why the narrow band has '
        'its own word');
    expect(wouldBeScale, lessThan(0.75),
        reason: 'the narrow column offers ${narrowBudget.toStringAsFixed(1)} dp and the '
            'long word wants ${longWordWidth.toStringAsFixed(1)} dp, so it would be '
            'drawn at ${wouldBeScale.toStringAsFixed(3)} — at or above this column\'s '
            '0.75 floor. The column can now take the one word, so the short form is a '
            'second ARB key with no measurement behind it any more');
  });

  testWidgets('a normal reading is still drawn as its own percentage, at both sites',
      (tester) async {
    // The neighbour case, and the reason a fix that always says "charging" fails: 75 is
    // the reading the same body gives with the charger out.
    for (final site in sites) {
      await pump(tester, site, state: charged(75));
      final l = site.locale == 'en' ? en : zh;
      final readout = site.name.startsWith('readout');

      expect(readout ? find.text('75%') : find.text(l.readoutBatteryAndLeft('75', '999')),
          findsOneWidget,
          reason: '${site.name} (${site.locale}) does not show the reading itself for '
              '75; it drew '
              '${drawnPercentages(tester).map((d) => '"${d.text}"').join(', ')}');
      expect(find.text(l.readoutBatteryCharging), findsNothing,
          reason: '${site.name} (${site.locale}) says "charging" for an unplugged '
              'camera reading 75');
      expect(find.text(l.readoutBatteryChargingAndLeft('999')), findsNothing,
          reason: '${site.name} (${site.locale}) says "charging" for an unplugged '
              'camera reading 75');
    }
  });

  test('the fact is computed once, from the reading, and the reading is not clamped',
      () {
    CameraState battery(String v) => CameraState({'BatteryLevel': v});

    // Measured: 101 on charge, 75 off.
    expect(battery('101').isCharging, isTrue,
        reason: '101 is the reading the camera gives on the charger');
    expect(battery('75').isCharging, isFalse,
        reason: '75 is the reading the same body gives with the charger out — the '
            'neighbour a fix that always says "charging" would fail');

    // The rest of the range, and the values that are not a reading at all.
    for (final v in ['100', '50', '0']) {
      expect(battery(v).isCharging, isFalse, reason: '$v is a percentage, not charge');
    }
    for (final v in ['', 'n/a', '101.0', '-5']) {
      expect(battery(v).isCharging, isFalse,
          reason: '"$v" is not the charging reading, and guessing here would put a word '
              'on screen for a value the camera never sent');
    }

    // **Equality, not a threshold**, and the reason is the manufacturer's own code
    // rather than caution: the official app draws `…_battery_charging` for exactly
    // `101` and its `setProgress` returns early for `i > 101`, so nothing above it is a
    // reading the camera's own client recognises. If this flips back to `> 100`, the
    // two assertions below are what fails.
    expect(CameraState.kBatteryChargingReading, 101);
    expect(battery('102').isCharging, isFalse,
        reason: 'a reading above 101 is rejected outright by the official app '
            '(CustomBatteryLoading.setProgress: `if (i > 101 || i < 0) return;`), so it '
            'is not a charge state this app may claim: it has to draw what the camera '
            'sent');

    // `batteryPercent` is untouched: no clamping, so nothing downstream of the raw
    // reading changes meaning.
    expect(battery('101').batteryPercent, 101);
    expect(battery('101').batteryLevel, '101');
    expect(battery('0').batteryPercent, 0);
    expect(battery('102').batteryPercent, 102,
        reason: 'the reading itself is never rewritten, so a value this app does not '
            'understand still reaches the UI as the camera sent it');
  });

  test('the charging words fit the widths the two draw sites have', () {
    // `analysis/55`: the narrow column leaves a value 66 dp, and this app's font metrics
    // are one em per character (`readout_legibility_test.dart`), so
    // `kCompactReadoutLength` = 7 characters = 84.0 dp at 12 sp, drawn at 0.79.
    for (final (name, l) in [('en', en), ('zh', zh)]) {
      expect(l.readoutBatteryChargingCompact.length,
          lessThanOrEqualTo(kCompactReadoutLength),
          reason: 'the $name short form "${l.readoutBatteryChargingCompact}" is '
              '${l.readoutBatteryChargingCompact.length} characters; the narrow column '
              'is sized for $kCompactReadoutLength, and the widget check above measures '
              'what the tree does with it');
      // The wide column is 156 dp and leaves the value 144 — the width `Incandescent`
      // (12 characters, 144.0 dp) set. The long word must not be the thing that widens
      // it.
      expect(l.readoutBatteryCharging.length * 12.0, lessThanOrEqualTo(144.0),
          reason: 'the $name long form "${l.readoutBatteryCharging}" wants '
              '${l.readoutBatteryCharging.length * 12}.0 dp, more than the 144 dp the '
              'wide column is sized for');
    }
  });
}
