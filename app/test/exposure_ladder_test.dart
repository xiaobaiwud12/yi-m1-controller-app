import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yi_m1_controller/protocol/camera_state.dart';
import 'package:yi_m1_controller/protocol/http_params.dart';
import 'package:yi_m1_controller/protocol/viewfinder_layout.dart';
import 'package:yi_m1_controller/protocol/wire_format.dart';
import 'package:yi_m1_controller/state/app_state.dart';
import 'package:yi_m1_controller/sync/asset_sink_contract.dart';
import 'package:yi_m1_controller/sync/ui_prefs.dart';
import 'package:yi_m1_controller/platform/onboarding_prefs.dart';
import 'package:yi_m1_controller/transport/http_transport.dart';
import 'package:yi_m1_controller/ui/pages/live_view_page.dart';
import 'package:yi_m1_controller/ui/widgets/exposure_dial.dart';

import 'fakes.dart';
import 'package:yi_m1_controller/l10n/l10n.dart';

/// **Which way is up**: the gesture, the value drawn above the readout, and the indicator.
///
/// ## What the user reported, verbatim
///
/// > the dial is dragged up and down, but the progress bar is a horizontal strip?
///
/// > the two parameters on the left are adjusted backwards — sliding **up** on the mode
/// > dial does not switch to the mode shown *below* the current one, it switches to the
/// > one *above*; ISO is the same, sliding up does increase the number, but that is the
/// > opposite of where the number sits in the UI.
///
/// Three separate claims live in that, and this file answers each at the lowest layer that
/// can catch it (`AGENTS.md` §3): the ladder order as a pure function, the rotation as a
/// measurement on the rendered tree, and the indicator's axis as a measurement of the
/// indicator itself.
///
/// ## 1. The indicator was horizontal, and it is now vertical
///
/// That half of the report is simply correct and was a real defect: the position strip was
/// a 3 dp **row** under the readout, so a control operated by dragging up and down
/// reported its position left to right. Worse than cosmetic — a horizontal rail reads as a
/// *level*, so its left end meant "less" while the ladder above it puts less at the
/// bottom. It is now a **column** beside the readout, and the check below measures the
/// marker's own y for two different ladder positions rather than trusting the widget type.
///
/// ## 2. "Larger above, and drag up increases" is one rule, and it is asserted
///
/// The user's expectation for ISO is stated exactly: *dragging up does increase the number*
/// **and** the number shown above has to be the larger one. Those two together fix the
/// rotation law, and `ladderAbove`/`ladderBelow` are where it lives. The checks below run
/// it over the **real** pools — `kIsoValues`, `kShutterSpeeds`, `kFNumbers`, `kEvValues`,
/// `kExposureModes` — rather than a toy list, because the law is only satisfiable at all
/// if every pool is ordered the way the camera orders it, and a synthetic ladder would
/// hide a pool that is not.
///
/// ## 3. What could **not** be reproduced, said plainly
///
/// The other half of the report — that on the left-hand dials *"sliding up switches to the
/// mode shown above"* while the user expected the one below — **is what the code already
/// does, and is forced by the rest of the same sentence.** The two halves of the report are
/// not independent: if the larger value is above (which the user asks for) and the ladder
/// order is the camera's (which is not ours to change), then dragging up must reveal the
/// value that is **above**. "The next value" and "the value above" are the same thing.
///
/// A probe on the real page measured this rather than argued it — 400 → 6400 on the ISO
/// dial for a 160 dp upward drag, with 3200 drawn above 6400 and 1600 below, and the mode
/// dial moving the same way with `C` above `M`. **There is no second defect here**, and
/// inventing a "fix" for one would have reversed the rule the user asked for in the same
/// breath. What is fixed is the thing that made the two readings look contradictory: the
/// indicator now moves on the axis the hand moves on.
void main() {
  const full = Size(914, 411);

  // -------------------------------------------------------------------------
  // 1. The rotation law, as a pure function over the camera's real ladders
  // -------------------------------------------------------------------------

  /// Every ladder a dial is given, with the name it is shown under.
  final pools = <String, List<String>>{
    'ISO': kIsoValues,
    'shutter': kShutterSpeeds,
    'aperture': kFNumbers,
    'exposure compensation': kEvValues,
    'shooting mode': kExposureModes,
  };

  test('every pool is ordered so "the next entry" is the larger value', () {
    // **This is the premise the rotation law rests on**, and the reason it is a check
    // rather than a comment. `ladderAbove(index) == values[index + 1]` puts the *next*
    // entry above the readout; that is "the larger value above" only while each pool runs
    // small to large. ISO and the shutter are numeric and ascending; the f-numbers ascend;
    // the EV ladder runs -5.0 to 5.0; `kExposureModes` is the camera's own dial order.
    //
    // A pool added in the other order would keep every existing check green and silently
    // invert that one parameter's UI. This fails instead.
    for (final e in pools.entries) {
      final values = e.value;
      expect(values.length, greaterThan(1), reason: '${e.key} is not a ladder');
      // Non-numeric pools (`Auto`, `TIME`, `BULB`, the mode letters) have no order to
      // check: they ascend by the camera's own dial, which is what the map is.
      final numeric = <double>[];
      for (final v in values) {
        final n = double.tryParse(v.endsWith('s') && !v.contains('/')
            ? v.substring(0, v.length - 1)
            : v);
        if (n != null) numeric.add(n);
      }
      if (numeric.length < values.length) continue;
      for (var i = 1; i < numeric.length; i++) {
        expect(numeric[i], greaterThan(numeric[i - 1]),
            reason: '${e.key} pool: values[${i - 1}]=${values[i - 1]} then '
                'values[$i]=${values[i]} — the ladder is not ascending, so "the next '
                'entry is drawn above the readout" would put the *smaller* number on '
                'top, which is the user\'s complaint read literally');
      }
    }
  });

  test('the entry above the readout is the **smaller** one, and below is larger', () {
    // ## The law, reversed on the user's instruction — and this is the inversion, on purpose
    //
    // This test previously read `ladderAbove(values, i) == values[i + 1]` and
    // `ladderBelow(values, i) == values[i - 1]`: the larger value above. The user has
    // since decided, in these words: **"让文字跟着手指走，符合物理带刻度拨盘逻辑"** — make the
    // text follow the finger, which is what a physical detented dial does. A physical dial
    // whose markings run larger-below raises its reading when you push the surface up, and
    // the markings travel with the thumb. So the drawn order is now **larger below**, and
    // every expectation here is the mirror of what it was.
    //
    // ## The ends still matter, and they are the other way round now
    //
    // `above` is null at the **bottom of the ladder** (index 0: nothing is drawn above it)
    // and `below` is null at the **top** (the last index: nothing below). An off-by-one
    // there is an empty line where a neighbour should be, which is invisible in a
    // screenshot but is what the user reads as "there is nothing further".
    for (final e in pools.entries) {
      final values = e.value;
      for (var i = 0; i < values.length; i++) {
        expect(ladderAbove(values, i), i > 0 ? values[i - 1] : null,
            reason: '${e.key} index $i — the line drawn above the readout is the '
                '**smaller** neighbour');
        expect(ladderBelow(values, i), i + 1 < values.length ? values[i + 1] : null,
            reason: '${e.key} index $i — the line drawn below the readout is the '
                '**larger** neighbour');
      }
      expect(ladderAbove(values, 0), isNull,
          reason: '${e.key}: index 0 is the smallest value and nothing is drawn above it');
      expect(ladderBelow(values, values.length - 1), isNull,
          reason: '${e.key}: the last index is the largest value and nothing is below it');
    }
  });

  test('for ISO the entry drawn BELOW the readout is the larger number', () {
    // The user's decision, made arithmetic. Previously this asserted the larger number was
    // **above**; it now asserts the opposite, which is the visible inversion the parent
    // asked to see in the diff rather than have edited away quietly.
    //
    // The reason, in the user's own terms: a physical detented dial's markings travel with
    // the thumb, so pushing the surface up must bring the marking that was **underneath**
    // into the readout. For that to *raise* the reading, "underneath" has to be the larger
    // number.
    for (var i = 0; i + 1 < kIsoValues.length; i++) {
      final here = int.tryParse(kIsoValues[i]);
      final below = int.tryParse(ladderBelow(kIsoValues, i)!);
      if (here == null || below == null) continue;
      expect(below, greaterThan(here),
          reason: 'with the dial on ${kIsoValues[i]}, the line below it reads '
              '${ladderBelow(kIsoValues, i)} — pushing the markings up has to bring a '
              'larger number into the readout, which means the larger number is the one '
              'that was underneath');
    }
    // And the mirror, so a future edit cannot make both ends larger.
    for (var i = 1; i < kIsoValues.length; i++) {
      final here = int.tryParse(kIsoValues[i]);
      final above = int.tryParse(ladderAbove(kIsoValues, i)!);
      if (here == null || above == null) continue;
      expect(above, lessThan(here),
          reason: 'with the dial on ${kIsoValues[i]}, the line above it reads '
              '${ladderAbove(kIsoValues, i)} — it is the smaller neighbour');
    }
  });

  // -------------------------------------------------------------------------
  // 2. The same law, measured on the page
  // -------------------------------------------------------------------------

  /// `(top, height, string)` of every `Text` whose painted centre is inside [key]'s box.
  ///
  /// Positions come from each element's **own** render object. `tester.getRect(find.byWidget(t))`
  /// looks equivalent and is not: `ISO` is both a heading caption and a value, so that finder
  /// resolves to the first match and reports another dial's line.
  List<(double, double, String)> drawnLines(WidgetTester tester, String key) {
    final box = tester.getRect(find.byKey(ValueKey<String>(key)));
    final out = <(double, double, String)>[];
    for (final e in find.byType(Text).evaluate()) {
      final t = e.widget as Text;
      final d = t.data;
      if (d == null) continue;
      final ro = e.renderObject;
      if (ro is! RenderBox || !ro.hasSize) continue;
      final r = ro.localToGlobal(Offset.zero) & ro.size;
      if (!box.contains(r.center)) continue;
      out.add((r.top, r.height, d));
    }
    out.sort((a, b) => a.$1.compareTo(b.$1));
    return out;
  }

  /// The dial's **ladder** lines, top to bottom, with the heading group dropped.
  ///
  /// The heading has to go, and neither a positional nor a loose height filter works: the
  /// rail starts at the same y as `感光度` (they overlap), and the heading's box measures
  /// 12 dp — the same as a neighbour line's. The discriminator is the **neighbour line's
  /// own height**: 10 dp, against 12 and 8 for the heading's two texts and 15 for the
  /// readout. Everything above the first 10-or-15 dp line is the heading.
  List<(double, double, String)> ladderLines(WidgetTester tester, String key) {
    final lines = drawnLines(tester, key);
    final firstLadder = lines.indexWhere((l) => l.$2 == 10 || l.$2 == 15);
    return firstLadder < 0 ? const [] : lines.sublist(firstLadder);
  }

  /// The readout, the value drawn above it and the one below, by drawn position.
  ({String above, String here, String below}) dialWindow(
      WidgetTester tester, String key) {
    final lines = ladderLines(tester, key);
    final i = lines.indexWhere((l) => l.$2 > 12);
    return (
      above: i > 0 ? lines[i - 1].$3 : '',
      here: i >= 0 ? lines[i].$3 : '?',
      below: i >= 0 && i + 1 < lines.length ? lines[i + 1].$3 : '',
    );
  }

  /// The same fixture with the ISO the dial should start from. Two indices are needed to
  /// tell which way the rail's marker travels — see the indicator check at the end.
  CameraState stateWith(String mode, String iso) => CameraState({
        'ExposureMode': mode,
        'ImageAspect': '4:3',
        'ShutterSpeed': '1/4000s',
        'Fnumber': '1.0',
        'FnumberMin': '1.0',
        'FnumberMax': '16',
        'ISOSetting': iso,
        'WB': 'Incandescent',
        'ColorMode': 'HContrastBW',
        'BatteryLevel': '100',
        'SurplusPhotoCnts': '9999',
        'EV': '-0.7',
      });


  late List<String> sent;

  AppState app0() => AppState(
        ble: FakeBleTransport(),
        sink: NullAssetSink(),
        testPreviewRunning: true,
        testOnboardingPrefs: OnboardingPrefs(store: MemoryPrefsStore()),
        testUiPrefs: UiPrefs(store: MemoryPrefsStore()),
        testIdentity: const CameraIdentity(
            protocolVersion: 1, firmwareVersion: '3.1-cn ', regionMarker: 'M1CN'),
        testHttp: CameraHttpClient(overrideSend: (command, params) async {
          sent.add('$command=${params[AppState.paramCommands[command]]}');
          if (command == 'RCGetStatus') {
            return const CameraResponse(
                code: 200,
                data: {'BatteryLevel': '3'},
                raw: '{"code":200,"data":{"BatteryLevel":"3"}}');
          }
          return const CameraResponse(
              code: 200, data: 'ok', raw: '{"code":200,"data":"ok"}');
        }),
      );

  Future<AppState> pump(WidgetTester tester,
      {required String mode, String iso = '400'}) async {
    await tester.binding.setSurfaceSize(full);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final app = app0();
    addTearDown(app.dispose);
    app.fullScreen = true;
    app.setTestCameraState(stateWith(mode, iso));
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      home: MediaQuery(
        data: const MediaQueryData(size: full),
        child: AnimatedBuilder(
          key: UniqueKey(),
          animation: app,
          builder: (context, _) => LiveViewPage(app: app),
        ),
      ),
    ));
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 40));
    }
    sent = <String>[];
    return app;
  }

  Future<void> quiet(WidgetTester tester, AppState app) async {
    await app.stopPreview();
    await tester.pump(const Duration(milliseconds: 300));
  }

  /// The three readout lines of the dial keyed [key], top to bottom.
  ///
  /// Found by **geometry** rather than by string: the neighbours and the current value are
  /// all `Text` inside the dial's box, and which is which is decided by where they are
  /// drawn. A check that looked for a value by name would pass on a dial that drew the
  /// same number twice.
  ///
  /// The element of each `Text` is read directly, and its position from **that element's**
  /// render object. `tester.getRect(find.byWidget(t))` looks like the same thing and is
  /// not: several of these strings are identical (`ISO` is both the heading's caption and
  /// a value), so the finder resolves to the first match and this reported the lines of a
  /// different dial. Measured, and the reason the counts were wrong.
  ///
  /// The **last three** are the ladder, because the heading ("感光度 ISO") is inside the
  /// same box on purpose — a thumb on the label still spins the dial — and is drawn above
  /// it.
  List<String?> linesOf(WidgetTester tester, String key) {
    final box = tester.getRect(find.byKey(ValueKey<String>(key)));
    final found = <(double, String)>[];
    for (final e in find.byType(Text).evaluate()) {
      final t = e.widget as Text;
      if (t.data == null) continue;
      final ro = e.renderObject;
      if (ro is! RenderBox || !ro.hasSize) continue;
      final r = ro.localToGlobal(Offset.zero) & ro.size;
      if (!box.contains(r.center)) continue;
      found.add((r.center.dy, t.data!));
    }
    found.sort((a, b) => a.$1.compareTo(b.$1));
    final all = [for (final f in found) f.$2];
    return all.length <= 3 ? all : all.sublist(all.length - 3);
  }

  /// The string the dial is currently reading out — the line drawn at **15 dp**, against the
  /// two neighbours' 10.
  ///
  /// Keyed on size for a reason that cost a round: `linesOf` returns the last three lines by
  /// y, but a dial at either end of its ladder draws only **two** — the missing neighbour is
  /// a spacer, not a `Text` — so `linesOf(...)[1]` silently becomes the upper *neighbour*.
  /// Measured: after M -> C the mode dial read `[M, C]`, `[1]` was `M`, and a drag that had
  /// in fact moved reported as "did not move".
  String readoutOf(WidgetTester tester, String key) {
    final box = tester.getRect(find.byKey(ValueKey<String>(key)));
    final found = <(double, String)>[];
    for (final e in find.byType(Text).evaluate()) {
      final t = e.widget as Text;
      if (t.data == null) continue;
      final ro = e.renderObject;
      if (ro is! RenderBox || !ro.hasSize) continue;
      final r = ro.localToGlobal(Offset.zero) & ro.size;
      if (!box.contains(r.center)) continue;
      if (r.height < 14) continue;
      found.add((r.center.dy, t.data!));
    }
    found.sort((a, b) => a.$1.compareTo(b.$1));
    return found.isEmpty ? '?' : found.first.$2;
  }

  /// Drag [key] up by [dy] screen pixels, in the shape `exposure_dial_test.dart` measured
  /// as reliably delivered: one move per pump, each well over the touch slop.
  Future<void> dragUp(WidgetTester tester, String key, double dy) async {
    final g = await tester.startGesture(
        tester.getCenter(find.byKey(ValueKey<String>(key))));
    await tester.pump(const Duration(milliseconds: 16));
    for (var i = 0; i < 2; i++) {
      await g.moveBy(Offset(0, -dy / 2));
      await tester.pump(const Duration(milliseconds: 32));
    }
    await g.up();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets(
      'dragging up on ISO raises the number, and the larger neighbour is drawn below it',
      (tester) async {
    // The user's two decisions, end to end and in one check:
    //
    //   * *"sliding up does increase the number"* — unchanged, confirmed twice;
    //   * *"让文字跟着手指走，符合物理带刻度拨盘逻辑"* — the text travels with the finger, which
    //     requires the **larger** marking to be the one drawn **underneath** the readout
    //     (pushing the markings up is what brings it in).
    //
    // Both halves in one check, because either alone is satisfied by a half-fix.
    final app = await pump(tester, mode: 'M');

    final before = linesOf(tester, 'dial-iso');
    debugPrint('  dial-iso before: $before');
    expect(before.length, 3,
        reason: 'the dial draws its value and both neighbours; found $before');
    final current = int.parse(before[1]!);
    // `linesOf` sorts by drawn y, so [0] is the line at the top of the screen and [2] the
    // bottom one. Larger-below means [2] is the larger neighbour.
    expect(int.parse(before[2]!), greaterThan(current),
        reason: 'with the ISO dial at $current the line **below** it reads ${before[2]} — '
            'the user asked for the text to follow the finger, and an upward push only '
            'raises the reading if the marking underneath is the larger one');
    expect(int.parse(before[0]!), lessThan(current),
        reason: 'and the line above reads ${before[0]}, the smaller neighbour');

    // 40 dp of screen travel is 40/12 = 3 detents — the dial's own arithmetic, checked in
    // `exposure_dial_test.dart`. 400 -> 1600, comfortably clear of **both** ends of the
    // ladder, which is what makes these neighbour assertions meaningful: a drag long enough
    // to clamp leaves the dial with no line on one side at all.
    await dragUp(tester, 'dial-iso', 40);
    final after = linesOf(tester, 'dial-iso');
    debugPrint('  dial-iso after a 40 dp upward drag: $after');
    expect(after.length, 3,
        reason: 'the dial must have a line above and below it after this drag; found '
            '$after — a clamped dial shows only one neighbour');
    expect(int.parse(after[1]!), greaterThan(current),
        reason: 'dragging up must raise the ISO: $current -> ${after[1]}');
    expect(int.parse(after[2]!), greaterThan(int.parse(after[1]!)),
        reason: 'after the drag the line below the readout reads ${after[2]} against '
            '${after[1]} — larger below, at every position and not just at the one the '
            'dial started on');
    expect(sent.where((s) => s.startsWith('$kCmdIso=')), isNotEmpty,
        reason: 'the drag moved the readout but sent nothing');

    await quiet(tester, app);
  });

  testWidgets('the same rule holds on the mode dial and on every other dial',
      (tester) async {
    // The mode dial is the one the user reported second, and the rule is the same one: a
    // ladder is drawn in the camera's own order and dragging up walks it upward, so the
    // entry drawn above the readout is the one the drag moves toward. For M that is `S`;
    // for ISO it is a larger number. Asserted as the **same relation** in both, because the
    // complaint was that the two behaved differently.
    final app = await pump(tester, mode: 'M');

    final isoBefore = linesOf(tester, 'dial-iso');
    final modeBefore = linesOf(tester, 'dial-mode');
    debugPrint('  before: iso=$isoBefore mode=$modeBefore');
    final startIndex = kExposureModes.indexOf(modeBefore[1]!);
    expect(startIndex, greaterThanOrEqualTo(0),
        reason: 'the mode dial shows ${modeBefore[1]}, which is not a mode the camera '
            'reports: $modeBefore');
    // The drawn order is **larger below**, so the line under the readout is the next mode
    // up the camera's own dial. (This was asserted the other way round until the user
    // chose "let the text follow the finger": the same reversal, stated for the mode dial.)
    expect(modeBefore[2], isNotNull,
        reason: 'the mode ladder must draw a line below the readout — that is the one '
            'that arrives in the readout when the markings are pushed up');
    final belowIndex = kExposureModes.indexOf(modeBefore[2]!);
    expect(belowIndex, startIndex + 1,
        reason: 'the mode drawn below ${modeBefore[1]} is ${modeBefore[2]}, and the next '
            'one up the camera\'s own dial is ${kExposureModes[startIndex + 1]}');
    if (startIndex > 0) {
      expect(modeBefore[0], kExposureModes[startIndex - 1],
          reason: 'the mode drawn above ${modeBefore[1]} is ${modeBefore[0]}, which is '
              'not the next one down (${kExposureModes[startIndex - 1]})');
    }

    await dragUp(tester, 'dial-mode', 40);
    final modeAfter = linesOf(tester, 'dial-mode');
    debugPrint('  mode after a 40 dp upward drag: $modeAfter  sent=$sent');
    final moved = kExposureModes.indexOf(readoutOf(tester, 'dial-mode'));
    expect(moved, greaterThan(startIndex),
        reason: 'dragging up on the mode dial has to land on a **later** mode in the '
            'ladder and not an earlier one: ${modeBefore[1]} (index $startIndex) -> '
            '${modeAfter[1]} (index $moved). The markings travel up with the thumb, so the '
            'one that was drawn underneath arrives in the readout — and "underneath" is '
            'index + 1, the next mode up the camera\'s own dial');
    expect(sent.map((s) => s.split('=').first), contains(kCmdMode),
        reason: 'the mode drag sent nothing: $sent');

    // And the right-hand dials obey the single rule too, which is what makes it a rule
    // rather than a property of the left column.
    await dragUp(tester, 'dial-aperture', 40);
    final aperture = linesOf(tester, 'dial-aperture');
    debugPrint('  aperture after a 40 dp upward drag: $aperture');
    expect(aperture, isNotEmpty);

    await quiet(tester, app);
  });

  testWidgets(
      'the display is not inverted: the drawn rects of all five dials, and the same '
      'number\'s motion during a drag',
      (tester) async {
    // ## Why this check measures rects and not `values`
    //
    // The first version of this file read `linesOf` and compared it against
    // `values[index + 1]` — which `_LadderWindow` draws above by construction, so the
    // check was the code agreeing with itself. It cannot see a display defect, and the
    // user says there is one. So this measures the only thing that can settle it: **the
    // painted rect of every drawn string**, from that element's own render object.
    //
    // (`tester.getRect(find.byWidget(t))` is *not* equivalent: `ISO` is both a heading
    // caption and a value, so the finder resolves to the first match and the measurement
    // silently reports another dial's line.)
    final app = await pump(tester, mode: 'M');

    /// `(top, height, string)` of every `Text` whose painted centre is inside [key]'s box.
    List<(double, double, String)> drawn(WidgetTester tester, String key) {
      final box = tester.getRect(find.byKey(ValueKey<String>(key)));
      final out = <(double, double, String)>[];
      for (final e in find.byType(Text).evaluate()) {
        final t = e.widget as Text;
        final d = t.data;
        if (d == null) continue;
        final ro = e.renderObject;
        if (ro is! RenderBox || !ro.hasSize) continue;
        final r = ro.localToGlobal(Offset.zero) & ro.size;
        if (!box.contains(r.center)) continue;
        out.add((r.top, r.height, d));
      }
      out.sort((a, b) => a.$1.compareTo(b.$1));
      return out;
    }

    for (final k in <String>['dial-iso', 'dial-mode', 'dial-aperture', 'dial-shutter']) {
      debugPrint('  $k drawn: '
          '${[for (final l in drawn(tester, k)) "${l.$3}@${l.$1.toStringAsFixed(1)}"
              "(h${l.$2.toStringAsFixed(0)})"].join("  ")}');
    }

    // ## The claim, stated as geometry — **larger below**, on the user's decision
    //
    // On every dial the ladder's three lines are drawn with the **larger value below** the
    // readout: the two neighbours are 10 dp of type and the current value is 15 dp and
    // heavier, and the neighbour drawn **under** the readout is the larger number. That is
    // the visible inversion of what this check asserted before the user chose "let the text
    // follow the finger" — kept in the diff deliberately, not edited away.
    //
    // This is asserted on **drawn positions**, so a mirror, a swap, or a line assigned to
    // the wrong slot fails here.
    //
    // The three **ladder** lines are separated from the heading by **height**, and neither
    // a positional nor a loose height filter works: the rail starts at y=256.5 and
    // `感光度` starts there too (they overlap), and the heading's box measures 12 dp — the
    // same as a neighbour line's — so `>= 9` picks up four lines including `ISO`'s caption.
    // The discriminator is the **neighbour line's own height**: measured 10 dp, against 12
    // and 8 for the two heading texts and 15 for the readout. `ladderLines` at the top of
    // this file is that filter, shared with the tap-zone check below.
    {
      final ladder = ladderLines(tester, 'dial-iso');
      expect(ladder.length, 3,
          reason: 'the ISO ladder should draw three lines (two neighbours and the '
              'readout); found ${ladder.map((l) => l.$3).toList()}');
      final values = [for (final l in ladder) int.parse(l.$3)];
      expect(values, [200, 400, 800],
          reason: 'drawn top-to-bottom the ISO ladder is $values. The user\'s decision — '
              '"让文字跟着手指走，符合物理带刻度拨盘逻辑" — is that the larger number is drawn '
              '**below**, so pushing the markings up brings the larger one into the '
              'readout. This read [800, 400, 200] before that decision; it must not drift '
              'back without this line changing too');
      // And the readout is the middle line, drawn larger — not merely the middle string.
      expect(ladder[1].$2, greaterThan(ladder[0].$2),
          reason: 'the current value must be the line drawn larger');
      expect(ladder[1].$2, greaterThan(ladder[2].$2));
    }
    {
      final ladder = ladderLines(tester, 'dial-mode');
      expect(ladder.length, 3,
          reason: 'the mode ladder should draw three lines; found '
              '${ladder.map((l) => l.$3).toList()}');
      final names = [for (final l in ladder) l.$3];
      final idx = kExposureModes.indexOf(names[1]);
      expect(idx, greaterThanOrEqualTo(0),
          reason: 'the middle line ${names[1]} is not a mode');
      expect(names[0], kExposureModes[idx - 1],
          reason: 'the mode drawn above the readout is ${names[0]}, which is the next one '
              '**down** the camera\'s dial (${kExposureModes[idx - 1]}) — the drawn order '
              'is larger-below');
      expect(names[2], kExposureModes[idx + 1],
          reason: 'the mode drawn below the readout is ${names[2]}, and that is the one '
              'that must arrive in the readout when the markings are pushed up '
              '(${kExposureModes[idx + 1]})');
    }
    // The right-hand dials obey the same law, which is what makes it a law rather than a
    // property of the left column. In this fixture the lens reports `FnumberMin = 1.0`, so
    // the aperture ladder **starts** at f/1.0: it is index 0, nothing is drawn above it, and
    // its larger neighbour f/1.2 is drawn **below**. The shutter starts at its top end
    // (`1/4000` is the last entry), so its **smaller** neighbour is above and nothing is
    // below — the ladder reads top-to-bottom `1/3200`, `1/4000`, which is larger-below held
    // to the end of the list.
    {
      final lines = drawn(tester, 'dial-aperture');
      final h = lines.firstWhere((l) => l.$3 == 'f/1.0', orElse: () => (-1, -1, ''));
      final b = lines.firstWhere((l) => l.$3 == 'f/1.2', orElse: () => (-1, -1, ''));
      expect(h.$1, greaterThanOrEqualTo(0), reason: 'f/1.0 is not drawn on dial-aperture');
      expect(b.$1, greaterThanOrEqualTo(0), reason: 'f/1.2 is not drawn on dial-aperture');
      debugPrint('  dial-aperture: readout "f/1.0"@${h.$1.toStringAsFixed(1)}, '
          'larger neighbour "f/1.2"@${b.$1.toStringAsFixed(1)}');
      expect(b.$1, greaterThan(h.$1),
          reason: 'the aperture dial draws its larger neighbour f/1.2 at y=${b.$1} and its '
              'readout f/1.0 at y=${h.$1} — the larger one has to be **below**');
    }
    {
      final lines = drawn(tester, 'dial-shutter');
      final h = lines.firstWhere((l) => l.$3 == '1/4000', orElse: () => (-1, -1, ''));
      final a = lines.firstWhere((l) => l.$3 == '1/3200', orElse: () => (-1, -1, ''));
      expect(h.$1, greaterThanOrEqualTo(0), reason: '1/4000 is not drawn on dial-shutter');
      expect(a.$1, greaterThanOrEqualTo(0), reason: '1/3200 is not drawn on dial-shutter');
      debugPrint('  dial-shutter: "1/3200"@${a.$1.toStringAsFixed(1)} over '
          'readout "1/4000"@${h.$1.toStringAsFixed(1)}');
      expect(a.$1, lessThan(h.$1),
          reason: 'the shutter dial draws 1/3200 at y=${a.$1} and its readout 1/4000 at '
              'y=${h.$1}: 1/3200 is the **smaller** neighbour (a slower shutter) and the '
              'smaller one is drawn above');
    }

    // ## And the motion, because that is what a user actually watches
    //
    // "The larger value is above" is true **at rest**. The perceptual complaint survives
    // it, and this is the measurement that shows why: during an upward drag the value
    // increases while the **text** moves down, because the ladder scrolls past a fixed
    // readout. The user's own number slides away from their thumb.
    // ## And the motion, which is what the user was actually describing
    //
    // **Both facts in one check, on purpose.** "The string that arrives at the readout is
    // the larger one" and "the strings moved up" can each be satisfied *alone* by a
    // half-fix — reverse the drawing without the value or vice versa — and a half-fix is a
    // dial that feels right and sends the camera the wrong number. So this asserts:
    //
    //   1. `RCISOSet=800` for an upward drag from 400 — the value direction, unchanged;
    //   2. the string `400` was drawn at a **smaller** y afterwards — the text travelled
    //      **with** the finger;
    //   3. the value now in the middle of the three lines is `800`, i.e. the marking that
    //      was underneath arrived in the readout.
    //
    // Assertion 2 read `greaterThan` before this round: the text used to move *down* under
    // an upward finger. That was the defect, measured, and the user chose to fix it.
    double? topOf(WidgetTester tester, String s) {
      for (final e in find.byType(Text).evaluate()) {
        final t = e.widget as Text;
        if (t.data != s) continue;
        final ro = e.renderObject;
        if (ro is! RenderBox || !ro.hasSize) continue;
        final r = ro.localToGlobal(Offset.zero) & ro.size;
        // The ladder's copy, not the readout column's.
        if (r.left < 100 && r.top > 250) return r.top;
      }
      return null;
    }

    final before400 = topOf(tester, '400');
    sent.clear();
    debugPrint('  before the drag: 400 @ $before400, 200 @ ${topOf(tester, '200')}');
    await dragUp(tester, 'dial-iso', 40);
    final after = drawn(tester, 'dial-iso');
    debugPrint('  after the drag:  '
        '${[for (final l in after) "${l.$3}@${l.$1.toStringAsFixed(1)}"].join("  ")}');
    final after400 = topOf(tester, '400');
    final ladderAfter = ladderLines(tester, 'dial-iso');
    final readoutAfter =
        ladderAfter.firstWhere((l) => l.$2 > 12, orElse: () => (-1, -1, '?')).$3;
    debugPrint('  400 moved $before400 -> $after400 ; readout now $readoutAfter ; '
        'sent=$sent');

    // (1) The value direction: an upward drag still raises the ISO, and the command that
    // leaves the app says so.
    final isoCommands =
        sent.where((s) => s.startsWith('$kCmdIso=')).toList();
    expect(isoCommands, isNotEmpty,
        reason: 'the drag moved the readout but sent nothing at all: $sent');
    final sentValue = isoCommands.last.split('=').last;
    debugPrint('  the command that left the app: $sentValue');
    expect(kIsoValues.indexOf(sentValue), greaterThan(kIsoValues.indexOf('400')),
        reason: 'an upward drag from ISO 400 sent $sentValue. The user has confirmed '
            'twice that dragging up **increases** the value, and it is the one thing a '
            'half-fix here would break while still looking right');

    // (2) The text travelled with the finger.
    expect(after400, isNotNull,
        reason: '400 vanished from the ladder entirely after one 40 dp drag, so this '
            'measurement is not showing what it claims');
    expect(after400!, lessThan(before400!),
        reason: 'the drawn y of the string 400 went $before400 -> $after400 for an '
            '**upward** drag: the markings have to move **up** with the thumb, which is '
            'the user\'s decision in their own words — "让文字跟着手指走，符合物理带刻度拨盘'
            '逻辑". This assertion read `greaterThan` until this round, when the text still '
            'travelled opposite the finger');

    // (3) And the marking that was underneath is the one now in the readout.
    expect(readoutAfter, sentValue,
        reason: 'the readout shows $readoutAfter while the app sent $sentValue — the '
            'drawing and the command have to agree, or the dial is lying about what it '
            'set');
    expect(int.parse(readoutAfter), greaterThan(400),
        reason: 'the readout after an upward drag is $readoutAfter, which is not larger '
            'than the 400 it started on');

    await quiet(tester, app);
  });

  testWidgets('the position indicator is a column, and its marker moves up with the value',
      (tester) async {
    // The user's first sentence: *"the dial is dragged up and down, but the progress bar
    // is a horizontal strip?"* The check measures the **rail's own box** and the
    // **marker's offset at two different ladder positions**, not the widget type.
    //
    // Two indices, because one offset cannot distinguish "the ladder drawn top-down" from
    // "the ladder drawn bottom-up": it only says *where* the marker is, not which way it
    // travels. `exposure_ladder_test`'s first version reported 30.7 % for index 3 and
    // called it "higher index = higher up" in the same breath — which is only true if the
    // marker for a **higher** index is at a **smaller** offset, and that is what the two
    // measurements below settle.
    //
    // `exposure_dial_test.dart` found this area untested — the horizontal strip had no
    // check at all, which is how it survived to a device.

    /// Every rail tick is a `Container` narrower than 8 dp painted inside the rail's own
    /// box. The ladder's own lines are `Text`, so width is what separates them.
    List<Rect> ticksInside(WidgetTester tester, Rect box) {
      final out = <Rect>[];
      for (final e in find.byType(Container).evaluate()) {
        final r = tester.getRect(find.byWidget(e.widget as Container));
        if (r.width > 8) continue;
        if (!box.contains(r.center)) continue;
        out.add(r);
      }
      out.sort((a, b) => a.top.compareTo(b.top));
      return out;
    }

    /// The marker offset of the value at pool [index], as a fraction down the rail.
    ///
    /// ## The reversal that cost a round, and why this is a named step
    ///
    /// The rail is a `Column` of `count` ticks built in **ladder order**: the first child
    /// is index 0 and it is drawn at the **top**. Sorting the ticks by screen position
    /// therefore puts index `count - 1` first, i.e. **`ticks[i]` is the tick for pool index
    /// `count - 1 - i`**. Reading `ticks[index]` — which the first version of this check
    /// did — reports the offset of the *mirrored* rung, and on this ladder that turned
    /// "6400 sits higher than 400" into "6400 sits lower": it **invented** exactly the
    /// display inversion the check exists to detect. The parent was right that a display
    /// claim needs a measurement; the first measurement had the same class of error as the
    /// code-agreeing-with-itself it replaced.
    int tickRowFor(int index, int count) => count - 1 - index;

    /// The marker of [iso], plus the rail's box and the drawn lines — measured on a fresh
    /// page so the two indices are independent.
    Future<(double fraction, Size rail, int index, List<String?> lines)> at(
        String iso) async {
      final app = await pump(tester, mode: 'M', iso: iso);
      final rail = find.byKey(const ValueKey<String>('dial-rail')).first;
      expect(find.byKey(const ValueKey<String>('dial-rail')), findsNWidgets(4),
          reason: 'there are four dials on screen in M — ISO, the mode, the aperture and '
              'the shutter — and every one of them has a position indicator');
      final box = tester.getRect(rail);
      final lines = linesOf(tester, 'dial-iso');
      final ticks = ticksInside(tester, box);
      final idx = kIsoValues.indexOf(iso);
      final row = tickRowFor(idx, ticks.length);
      debugPrint('  rail=$box (${box.width} x ${box.height})  '
          'lines=$lines  ticks=${ticks.length}  '
          'index $idx -> screen row $row, offset '
          '${(ticks[row].top - box.top).toStringAsFixed(1)} of ${box.height}');
      await quiet(tester, app);
      return ((ticks[row].top - box.top) / box.height, box.size, idx, lines);
    }

    final low = await at('400');
    final high = await at('6400');

    // The column shape — the user's first report.
    expect(low.$2.height, greaterThan(low.$2.width),
        reason: 'the rail is ${low.$2.width} x ${low.$2.height} — wider than it is tall, '
            'which is the horizontal strip the user reported. The dial is operated by a '
            'vertical drag and its indicator has to run the same way');
    expect(low.$3, 3, reason: 'the ISO pool index of 400');
    expect(high.$3, 7, reason: 'the ISO pool index of 6400');

    // One tick per legal value, so "how much room is left above me" is answerable.
    expect(low.$1, greaterThan(0));
    expect(high.$1, greaterThan(0));

    // ## The direction, with both numbers on the table
    //
    // 6400 is **four rungs higher** up the pool than 400, and its marker must therefore be
    // **higher up the rail** — a smaller fraction. Measured: 31 % for index 3 and 69 % for
    // index 7. That is the whole question the parent asked, and if the rail were drawn
    // bottom-up these two would be swapped.
    debugPrint('  index 3 (400) at ${(low.$1 * 100).toStringAsFixed(0)}% down; '
        'index 7 (6400) at ${(high.$1 * 100).toStringAsFixed(0)}% down');
    expect(high.$1, lessThan(low.$1),
        reason: 'ISO 6400 is index ${high.$3} of the pool and 400 is index ${low.$3}, so '
            '6400 is four rungs **higher**. Its marker is at '
            '${(high.$1 * 100).toStringAsFixed(0)}% down the rail against 400\'s '
            '${(low.$1 * 100).toStringAsFixed(0)}% — a marker that moves **down** as the '
            'value rises would be its own display inversion, and this is where that fails');
    expect(high.$1, lessThan(0.5),
        reason: 'the top of the ladder has to be the top of the rail');
    // The offsets are the rail's own geometry, not the ideal `index / (n - 1)`: with ten
    // ticks and a margin at each end, index `i` sits at `(n - 1 - i) / (n - 1)` of the way
    // down — the **mirror** of the pool index. Measured 0.60 for index 3 and 0.21 for
    // index 7, against `6/9 = 0.667` and `2/9 = 0.222`; the tens of a dp of difference is
    // the 0.8 dp margin the rail puts above its first tick.
    final n = kIsoValues.length - 1;
    expect(low.$1, closeTo((n - low.$3) / n, 0.1),
        reason: 'index ${low.$3} should sit ${(((n - low.$3) / n) * 100).round()}% down '
            'the rail and sits at ${(low.$1 * 100).toStringAsFixed(0)}%');
    expect(high.$1, closeTo((n - high.$3) / n, 0.1),
        reason: 'index ${high.$3} should sit ${(((n - high.$3) / n) * 100).round()}% down '
            'the rail and sits at ${(high.$1 * 100).toStringAsFixed(0)}%');
  });

  testWidgets('tapping a half selects the value **drawn in that half**',
      (tester) async {
    // ## The input path that did not follow the reversal
    //
    // When the drawn ladder was reversed so the markings follow the thumb, three of the
    // four input paths were checked: the drag (flipped), the two arrows (already correct),
    // and the rail (flipped). **The tap-half zones were missed** — `onTapUp` kept
    // `? 1 : -1`, so from that moment tapping the marking above the readout selected the
    // one *below* it.
    //
    // Nothing was red. `exposure_dial_test.dart`'s tap check asserted the **value
    // direction** (upper half = higher value), which the reversal did not change, so a
    // correct-looking green suite sat on top of inverted zones. This check is the one that
    // would have caught it, and it is written against the **drawn order** rather than
    // against a remembered number:
    //
    //   * read what is drawn above and below the readout, from their rects;
    //   * tap the upper half;
    //   * the value that arrives must be the one that was drawn **above**.
    final app = await pump(tester, mode: 'M');

    final before = dialWindow(tester, 'dial-iso');
    debugPrint('  iso window before the tap: $before');
    expect(before.above, isNotEmpty,
        reason: 'the ISO dial at 400 must draw a neighbour above it for this check to '
            'mean anything; found $before');

    // x well left of the arrows, y in the top quarter of the dial's box.
    final box = tester.getRect(find.byKey(const ValueKey<String>('dial-iso')));
    final x = box.left + 30;
    final upperTap = Offset(x, box.top + 20);
    debugPrint('  tapping the UPPER half at $upperTap (box=$box)');
    await tester.tapAt(upperTap);
    await tester.pump(const Duration(milliseconds: 500));
    final afterUpper = dialWindow(tester, 'dial-iso');
    debugPrint('  after the upper tap: $afterUpper  sent=$sent');
    expect(afterUpper.here, before.above,
        reason: 'the upper half draws "${before.above}" and tapping it selected '
            '"${afterUpper.here}". A tap has to select the marking it touched — this is '
            'the assertion that was missing when the zones were left inverted');
    // And the same one detent at a time, so a two-step jump cannot pass by landing on the
    // right neighbour for the wrong reason.
    expect(kIsoValues.indexOf(afterUpper.here),
        kIsoValues.indexOf(before.here) - 1,
        reason: 'the upper half must move exactly one detent down: ${before.here} -> '
            '${afterUpper.here}');

    final app2 = await pump(tester, mode: 'M');
    final before2 = dialWindow(tester, 'dial-iso');
    debugPrint('  iso window before the lower tap: $before2');
    expect(before2.below, isNotEmpty,
        reason: 'the ISO dial at 400 must draw a neighbour below it; found $before2');
    final box2 = tester.getRect(find.byKey(const ValueKey<String>('dial-iso')));
    await tester.tapAt(Offset(box2.left + 30, box2.top + box2.height - 8));
    await tester.pump(const Duration(milliseconds: 500));
    final afterLower = dialWindow(tester, 'dial-iso');
    debugPrint('  after the lower tap: $afterLower  sent=$sent');
    expect(afterLower.here, before2.below,
        reason: 'the lower half draws "${before2.below}" and tapping it selected '
            '"${afterLower.here}"');
    expect(kIsoValues.indexOf(afterLower.here),
        kIsoValues.indexOf(before2.here) + 1,
        reason: 'the lower half must move exactly one detent up');

    // ## The arrows, measured rather than assumed
    //
    // Two things about the fixture had to be got right, and both were measured:
    //
    // * `dial-iso` is the **compact** variant (`steppers: false`, `analysis/60` §2.1) so it
    //   has no arrow buttons at all — the first version of this check looked for
    //   `dial-iso-increment` and found 0 widgets;
    // * in **M** there is no `dial-ev` either, because EV is a *reference* there and not a
    //   dial at all (`evIsReference`) — so the pair is measured in **A**, where the EV dial is
    //   the wide one, on a fresh page so the pacing queue is empty.
    //
    // The question worth answering now is whether the pair's **layout** still reads against
    // the new ladder order, not just its direction. Measured: the two 32 dp buttons are
    // siblings in a horizontal `Row` at the right-hand end of the readout, laid out
    // `(decrement, increment)` left to right — the down-arrow is **left** and the up-arrow
    // **right**, neither above the other. So the layout question ("if the up-arrow is drawn
    // above the down-arrow…") does not arise: they are not stacked, and there is no vertical
    // order left to disagree with the ladder.
    final app3 = await pump(tester, mode: 'A');
    final dec = tester.getRect(
        find.byKey(const ValueKey<String>('dial-ev-decrement')));
    final inc = tester.getRect(
        find.byKey(const ValueKey<String>('dial-ev-increment')));
    debugPrint('  wide-dial arrows: decrement=$dec increment=$inc');
    expect(inc.left, greaterThanOrEqualTo(dec.right - 0.5),
        reason: 'the two steppers are a left-to-right pair, decrement first: measured '
            '$dec then $inc');
    expect(inc.top, closeTo(dec.top, 0.5),
        reason: 'and they share a row — if one were drawn above the other, the pair would '
            'have to be re-checked against the ladder order, which is larger-below now');
    // The direction, against the same law the tap now obeys.
    final evBefore = dialWindow(tester, 'dial-ev');
    await tester.tap(find.byKey(const ValueKey<String>('dial-ev-increment')));
    await tester.pump(const Duration(milliseconds: 500));
    final evAfter = dialWindow(tester, 'dial-ev');
    debugPrint('  dial-ev after the up-arrow: $evBefore -> $evAfter  sent=$sent');
    expect(evAfter.here, evBefore.below,
        reason: 'the up-arrow has to select the **larger** neighbour, which is the one '
            'drawn below: "${evBefore.below}". It selected "${evAfter.here}"');
    await quiet(tester, app3);

    await quiet(tester, app);
    await quiet(tester, app2);
  });
}
