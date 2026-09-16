import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yi_m1_controller/protocol/camera_state.dart';
import 'package:yi_m1_controller/protocol/http_params.dart';
import 'package:yi_m1_controller/protocol/viewfinder_layout.dart';
import 'package:yi_m1_controller/ui/pages/live_view_page.dart';

import 'fakes.dart';
import 'package:yi_m1_controller/l10n/l10n.dart';
import 'package:yi_m1_controller/l10n/param_labels.dart';

/// A 1x1 PNG, so `Image.memory` decodes and the frame box is laid out.
///
/// Local rather than imported: this check needs **a** frame, not a particular one —
/// what is measured is the size of the box the frame is drawn in, and its pixels are
/// irrelevant. (`fakes.dart`'s fixtures are the ones that have to be a real JPEG,
/// because the *sync engine* integrity-checks them; that constraint does not apply
/// here, and the shared file is edited by other work in this tree.)
final Uint8List _frame = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

/// Is the camera readout **legible**, in both landscape layouts?
///
/// ## Why this file exists
///
/// `fullscreen_controls_size_test.dart` pins the size of every control, and it was
/// bought by narrowing the readout column to 78 dp. `fullscreen_band_split_test.dart`
/// then asked only that the readout still *renders* — complete, unclipped, unwrapped,
/// above a 0.30 floor. Every one of those was true while the column was unreadable:
/// the widest value it draws, `Incandescent`, came out at a `FittedBox` scale of
/// **0.458**, i.e. 5.5 dp of type. "Not clipped" and "can be read" are different
/// claims, and only the second one is the product requirement.
///
/// So this file measures the thing that matters — how large the type is actually
/// painted — against the strings the camera can really report, in both layouts.
///
/// ## The strings, and where they come from
///
/// Not invented: `app/tools/measure_readout_strings.py` enumerates the camera's own
/// vocabulary out of `http_params.dart` (232 constants, 219 display values), and the
/// pools below are the ones the readout's rows read from. The value the previous
/// round sized this column against, `AperturePriority`, is an **enum constant name**
/// — `rcExposureMode.AperturePriority` carries `'A'` — so a 16-character string that
/// never reaches the screen was standing in for a 1-character one.
///
/// ## `getRect`, not `getSize`
///
/// Every readout row and every control sits inside a `FittedBox(scaleDown)`, so its
/// laid-out size is its **design** size and says nothing about the screen.
/// `analysis/45` §4 records a round lost to measuring `getSize`.
void main() {
  // The emulator's window, landscape: `normal` is the body once the shell's app bar
  // and tab strip have taken their share, `full` is what `btn-fullscreen` hands back.
  const normal = Size(914, 297);
  const full = Size(914, 411);

  /// The longest value each readout row can be asked to draw, and the pool it comes
  /// from. `f/` and `%` are the row's own formatting (`_SideState`).
  final rowPools = <String, List<String>>{
    'Mode': kExposureModes,
    'Shutter': kShutterSpeeds,
    'Aperture': kFNumbers,
    'ISO': kIsoValues,
    'EV': kEvValues,
    'WB': kWbValues,
    'Style': kColorModes,
  };

  /// Battery and the remaining-shot count are the camera's numbers, not enums, so
  /// there is no pool to enumerate. Both are checked to pass through **unchanged**:
  /// truncating `12345` to `1234` would not be an abbreviation, it would be a
  /// different number.
  const numberRows = <String>['0%', '100%', '0', '999', '9999', '99999'];

  /// The worst case for the narrow column: every row holding the longest string its
  /// own pool allows.
  CameraState widestState() => CameraState({
        'ExposureMode': 'Auto',
        'ImageAspect': '4:3',
        'ShutterSpeed': '1/4000s',
        'Fnumber': '1.0',
        'ISOSetting': '25600',
        'EV': '-5.0',
        'WB': 'Incandescent',
        'ColorMode': 'HContrastBW',
        'BatteryLevel': '100',
        'SurplusPhotoCnts': '9999',
      });

  /// The same nine rows, holding the shortest strings they can.
  CameraState shortestState() => CameraState({
        'ExposureMode': 'M',
        'ImageAspect': '4:3',
        'ShutterSpeed': '1s',
        'Fnumber': '32',
        'ISOSetting': '100',
        'EV': '0.0',
        'WB': 'Auto',
        'ColorMode': 'Vivid',
        'BatteryLevel': '0',
        'SurplusPhotoCnts': '0',
      });

  Future<void> pump(
    WidgetTester tester,
    Size size, {
    required bool fullScreen,
    CameraState? state,
    bool withFrame = false,
    bool scaffold = false,
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final app = connectedTestAppState();
    addTearDown(app.dispose);
    app.fullScreen = fullScreen;
    app.setTestCameraState(state ?? widestState());
    if (withFrame) app.frameNotifier.value = _frame;
    final page = LiveViewPage(app: app);
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      // The settings sheet is built from `ListTile`s, which assert a `Material`
      // ancestor; in the app that is `HomeShell`'s `Scaffold`.
      home: scaffold ? Scaffold(body: page) : page,
    ));
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 40));
    }
    expect(tester.takeException(), isNull);
  }

  /// Every readout row currently on screen: label, value, and the `FittedBox` scale
  /// the value is painted at — `getRect / getSize`, which *is* the scale
  /// (`analysis/45` §4).
  List<({String label, String value, double scale, double drawn})> readoutRows(
      WidgetTester tester) {
    final out = <({String label, String value, double scale, double drawn})>[];
    final valueLabels = <String, String>{
      'Auto': 'Mode',
      '1/4000s': 'Shutter',
      '1/4000': 'Shutter',
      'f/1.0': 'Aperture',
      '25600': 'ISO',
      '-5.0': 'EV',
      'Incandescent': 'WB',
      'Incand.': 'WB',
      'HContrastBW': 'Style',
      'HC-BW': 'Style',
      '100%': 'Battery',
      '9999': 'Left',
    };
    for (final e in find.byType(Text).evaluate()) {
      final w = e.widget as Text;
      final ro = e.renderObject;
      if (ro is! RenderBox || w.data == null) continue;
      final label = valueLabels[w.data];
      if (label == null) continue;
      final painted = tester.getRect(find.byWidget(w)).size;
      final laid = ro.size;
      out.add((
        label: label,
        value: w.data!,
        scale: laid.width == 0 ? 1 : painted.width / laid.width,
        drawn: (w.style?.fontSize ?? 12) *
            (laid.width == 0 ? 1 : painted.width / laid.width),
      ));
      // The property every later assertion rests on, asserted per row: the value is
      // one line, and it is not clipped.
      final para = ro is RenderParagraph ? ro : null;
      expect(para?.didExceedMaxLines, isFalse,
          reason: '"${w.data}" was wrapped onto a second line, which changes the row '
              'height and makes the column jump while the camera reports new values');
      expect(painted.width, lessThanOrEqualTo(laid.width + 0.5),
          reason: '"${w.data}" is painted wider than the box it was laid out in');
    }
    return out;
  }

  /// The height the readout column's own `Column` occupies — the thing that must not
  /// move when a value gets longer.
  double readoutColumnHeight(WidgetTester tester) {
    for (final e in find.byType(Column).evaluate()) {
      final ro = e.renderObject as RenderBox;
      final parent = ro.parent;
      if (parent is! RenderBox) continue;
      if (!parent.runtimeType.toString().contains('Viewport')) continue;
      if (!_containsText(e, 'WB')) continue;
      return ro.size.height;
    }
    fail('the readout column was not found, so nothing was measured');
  }

  test('every value the readout can draw has a short form that fits the narrow band',
      () {
    // The narrow column leaves a value 66 dp (78, less 2+2 dp of row padding and
    // 4+4 dp of `_BandFitted`), and this app's font metrics are one em per character:
    // seven characters is 84.0 dp. So the *length* check below is what makes the
    // measured 0.79 in the widget test a bound rather than one sample — every value in
    // every pool is at most this long, and the longest one is measured in the tree.
    var longest = 0;
    var checked = 0;
    var shortened = 0;

    void check(String rendered) {
      final short = compactReadoutValue(rendered);
      checked++;
      expect(short.length, lessThanOrEqualTo(kCompactReadoutLength),
          reason: '"$rendered" is drawn as "$short", which is ${short.length} '
              'characters. At ${short.length * 12}.0 dp of type in the 66 dp the narrow '
              'band leaves, that is below the 0.75 floor this column is held to');
      if (short != rendered) shortened++;
      if (short.length > longest) longest = short.length;
    }

    for (final entry in rowPools.entries) {
      final label = entry.key;
      for (final v in entry.value) {
        // The row's own formatting, so this checks what is drawn rather than what the
        // protocol carries: the aperture row prefixes `f/`, the battery row `%`.
        check(switch (label) {
          'Aperture' => 'f/$v',
          'Battery' => '$v%',
          _ => v,
        });
      }
    }
    for (final v in numberRows) {
      check(v);
      expect(compactReadoutValue(v), v,
          reason: '"$v" was rewritten. Only words this file knows may be shortened: a '
              'number that is truncated is a wrong value, not an abbreviation');
    }

    // The pools are the fixture, so the fixture has to be real — `AGENTS.md` §8: a
    // fixture that quietly shrinks makes every assertion built on it meaningless.
    expect(checked, greaterThanOrEqualTo(200),
        reason: 'only $checked values were checked, so the pools did not load');
    expect(longest, kCompactReadoutLength,
        reason: 'nothing checked is $kCompactReadoutLength characters long, so the '
            'widget test below is not measuring the worst case the band allows');

    // **Unambiguous, checked rather than asserted in prose.** Two different settings
    // must never be drawn the same way, and a short form must never read as a
    // different setting's full name — which is how `Incand.` is acceptable and `I`
    // is not.
    for (final entry in rowPools.entries) {
      final pool = entry.value;
      final shortToValue = <String, String>{};
      for (final v in pool) {
        final rendered = entry.key == 'Aperture' ? 'f/$v' : v;
        final short = compactReadoutValue(rendered);
        final clash = shortToValue[short];
        expect(clash, isNull,
            reason: '${entry.key} draws both "$clash" and "$v" as "$short", so the row '
                'cannot say which setting the camera is in');
        shortToValue[short] = v;
        expect(pool.contains(short) && short != v, isFalse,
            reason: '${entry.key} draws "$v" as "$short", which is another '
                'setting\'s own name');
      }
    }

    debugPrint('  short forms: $checked values checked, $shortened rewritten, '
        'longest $longest characters');
  });

  testWidgets('the narrow column draws every row above the legibility floor',
      (tester) async {
    // Full screen on the reference body: 914x411, a 4:3 frame wanting 548 of the 914,
    // so the readout band is 78 and the values get 66.
    await pump(tester, full, fullScreen: true);

    final rows = readoutRows(tester);
    expect(rows.length, greaterThanOrEqualTo(9),
        reason: 'only ${rows.length} readout rows rendered, so this measured nothing');
    debugPrint('  full screen, 78 dp band:');
    for (final r in rows) {
      debugPrint('    ${r.label.padRight(9)} "${r.value}" '
          'scale=${r.scale.toStringAsFixed(3)} '
          'drawn=${r.drawn.toStringAsFixed(1)}dp');
    }

    for (final r in rows) {
      // **0.75, and it is derived rather than chosen.** The longest short form is
      // `kCompactReadoutLength` = 7 characters = 84.0 dp at 12 sp, into 66 dp, so the
      // worst row this column can be asked to draw lands at 0.786 — and the test above
      // proves no pool value is longer than that. This floor is what turns "the text
      // is not clipped" into "the text can be read": the shape it caught was 0.458.
      expect(r.scale, greaterThanOrEqualTo(0.75),
          reason: 'the ${r.label} row draws "${r.value}" at '
              '${(r.scale * 100).toStringAsFixed(0)}% of its size, i.e. '
              '${r.drawn.toStringAsFixed(1)} dp of type. The column may be narrow, but '
              'it is a readout — before the short forms existed this row was 5.5 dp');
    }

    // The value that *pays* in this layout, named so a future change that quietly
    // stops shortening cannot pass by leaving every other row untouched.
    final wb = rows.firstWhere((r) => r.label == 'WB');
    expect(wb.value, 'Incand.',
        reason: 'the narrow column should draw the white balance short form; it drew '
            '"${wb.value}"');
  });

  testWidgets('the wide column draws the camera\'s own words at full size',
      (tester) async {
    // Normal landscape on the same body: 914x297, so the frame is **height**-limited
    // at 396x297 and there are 518 dp of slack beside it — 230 of them left over once
    // the control column has its 288. The readout asks for the 156 its own longest
    // word needs, and is taken up on it.
    await pump(tester, normal, fullScreen: false);

    final rows = readoutRows(tester);
    debugPrint('  normal landscape, band = ${rows.length} rows:');
    for (final r in rows) {
      debugPrint('    ${r.label.padRight(9)} "${r.value}" '
          'scale=${r.scale.toStringAsFixed(3)} '
          'drawn=${r.drawn.toStringAsFixed(1)}dp');
    }
    expect(rows.length, greaterThanOrEqualTo(9));

    for (final r in rows) {
      expect(r.scale, greaterThanOrEqualTo(0.95),
          reason: 'the ${r.label} row draws "${r.value}" at '
              '${(r.scale * 100).toStringAsFixed(0)}% in the normal landscape layout, '
              'where the band is wide enough for the camera\'s own words. Scaling here '
              'is width spent on nothing');
    }
    // And the words are the camera's, not the short forms: this is where the full
    // vocabulary stays visible.
    final drawn = rows.map((r) => r.value).toSet();
    expect(drawn, contains('Incandescent'));
    expect(drawn, contains('HContrastBW'));
    expect(drawn, isNot(contains('Incand.')));
  });

  testWidgets('the readout column keeps its height when the camera reports longer '
      'values', (tester) async {
    // The requirement, stated as a number: a row whose value has to be scaled down
    // must not become a *shorter* row, because the eight rows below it would move
    // every time the camera reports a different setting — at 30 fps, while the user
    // is looking at them.
    //
    // This is not hypothetical: `FittedBox` sizes itself with
    // `constrainSizeAndAttemptToPreserveAspectRatio`, so a scaled-down value is
    // scaled-down in **height** too. Measured before the slots were fixed, in the
    // 78 dp band: `Incandescent` — scaled to 0.458 — laid out 6.4 dp tall against
    // `Sunny`'s 14.0, and the column moved 4.2 dp between the two fixture states.
    //
    // The third state is the auto-ISO one, where the *label* changes too (`ISO` ->
    // `ISO auto`, 72.0 dp against the same 66).
    final autoIso = CameraState({
      'ExposureMode': 'Auto',
      'ImageAspect': '4:3',
      'ShutterSpeed': '1/4000s',
      'Fnumber': '1.0',
      'ISOSetting': 'Auto',
      'ISOAutoValue': '25600',
      'EV': '-5.0',
      'WB': 'Incandescent',
      'ColorMode': 'HContrastBW',
      'BatteryLevel': '100',
      'SurplusPhotoCnts': '9999',
    });

    for (final (label, size, isFull) in [
      ('normal landscape', normal, false),
      ('full screen', full, true),
    ]) {
      final heights = <String, double>{};
      for (final (name, state) in [
        ('shortest values', shortestState()),
        ('their longest values', widestState()),
        ('auto ISO', autoIso),
      ]) {
        await pump(tester, size, fullScreen: isFull, state: state);
        heights[name] = readoutColumnHeight(tester);
      }
      final shown = heights.entries
          .map((e) => '${e.key} ${e.value.toStringAsFixed(1)} dp')
          .join(', ');
      debugPrint('  $label readout column: $shown');

      for (final e in heights.entries) {
        expect(e.value, closeTo(heights.values.first, 0.5),
            reason: 'the readout column is ${e.value.toStringAsFixed(1)} dp tall with '
                '${e.key} and ${heights.values.first.toStringAsFixed(1)} dp with the '
                'shortest, so the column moves when the camera reports a different '
                'setting — every row below the one that changed shifts');
      }
    }
  });

  testWidgets('the readout takes its width out of margin, not out of the picture',
      (tester) async {
    // The trade `analysis/54` made was "the readout pays for the controls keeping
    // their size". This is the other half of it, and it is the reason restoring the
    // normal layout's readout is free: on a 914x297 body the picture is
    // **height**-limited — a 4:3 frame 297 dp tall is 396 dp wide, and no band width
    // changes that — so the readout's width comes out of the black beside the frame.
    //
    // Measured on the frame box itself rather than on the preview area, which is the
    // difference that matters: the preview *area* is 470 wide normally and 548 in full
    // screen, and those two numbers say nothing about how much picture there is.
    for (final (label, size, isFull) in [
      ('normal landscape', normal, false),
      ('full screen', full, true),
    ]) {
      await pump(tester, size, fullScreen: isFull, withFrame: true);
      final frame = find.byType(AspectRatio);
      expect(frame, findsOneWidget,
          reason: 'no 4:3 frame box was laid out in $label, so the picture was not '
              'measured — the preview shows a placeholder without a frame');
      final box = tester.getRect(frame);
      debugPrint('  $label: picture ${box.width.toStringAsFixed(1)} x '
          '${box.height.toStringAsFixed(1)} at left=${box.left.toStringAsFixed(1)} '
          '(readout band ${box.left > 0 ? "to its left" : "none"})');

      expect(box.height, closeTo(size.height, 0.5),
          reason: 'the $label picture is ${box.height} dp tall in a ${size.height} dp '
              'body, so the side columns are taking height as well as width');
      expect(box.width, closeTo(size.height * 4 / 3, 0.5),
          reason: 'the $label picture is ${box.width} dp wide, not the '
              '${(size.height * 4 / 3).toStringAsFixed(0)} a height-limited 4:3 frame '
              'gets. The readout band has started eating the picture rather than the '
              'margin beside it');
    }
  });

  testWidgets('the full word is still reachable while the column shows the short one',
      (tester) async {
    // Abbreviation is only acceptable if the camera's own spelling is available
    // somewhere. It is: the white-balance dropdown in the settings sheet lists the
    // firmware's pool, whatever the readout band is doing.
    await pump(tester, full, fullScreen: true, scaffold: true);
    // The camera's own spelling of that value, as the one path from the firmware's
    // pool to a drawn word renders it — `paramLabel` — rather than a literal.
    expect(find.text(paramLabel(en, 'Incandescent')), findsNothing,
        reason: 'the readout should be drawing the short form in this band');

    await tester.tap(find.byKey(const ValueKey<String>('btn-settings-toggle')));
    await tester.pump(const Duration(milliseconds: 50));

    final row = find.ancestor(
      of: find.text(en.settingsRowRCWBSet),
      matching: find.byType(ListTile),
    );
    expect(row, findsOneWidget, reason: 'the white-balance row was not in the sheet');
    final dropdown = find.descendant(
      of: row,
      matching: find.byType(DropdownButton<String>),
    );
    expect(dropdown, findsOneWidget);
    // The row is below the fold in a 411 dp landscape body, so it has to be scrolled
    // to before it can be tapped — an earlier version of this check tapped an
    // off-screen row, the tap missed, and the `find.text` below still passed on the
    // row's own *hint*, which is the current value. Asserting on the count is what
    // makes the difference visible: the hint is one widget, the open menu is another.
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    await tester.tap(dropdown);
    await tester.pumpAndSettle();

    expect(find.text(paramLabel(en, 'Incandescent')), findsAtLeastNWidgets(2),
        reason: 'the settings menu is the one place the camera\'s own white-balance '
            'spellings are listed, and it is not showing them: only the row\'s own '
            'value line was found, which is there whether or not the menu opens');
  });
}

/// Does [root]'s subtree contain a `Text` with exactly [data]?
bool _containsText(Element root, String data) {
  var found = false;
  void visit(Element e) {
    if (found) return;
    final w = e.widget;
    if (w is Text && w.data == data) {
      found = true;
      return;
    }
    e.visitChildren(visit);
  }

  visit(root);
  return found;
}
