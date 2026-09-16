import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderFlex;
import 'package:flutter_test/flutter_test.dart';
import 'package:yi_m1_controller/protocol/camera_state.dart';
import 'package:yi_m1_controller/state/app_state.dart';
import 'package:yi_m1_controller/ui/pages/live_view_page.dart';

import 'fakes.dart';
import 'package:yi_m1_controller/l10n/l10n.dart';

/// The portrait top band must fit what it is asked to hold.
///
/// ## How this was found
///
/// Not by a test — by reading the log of a hardware run for the burst work:
///
/// ```
/// A RenderFlex overflowed by 55 pixels on the bottom.
///   Column: live_view_page.dart:1069:14
///   creator: Column ← Padding ← ColoredBox ← Container ← _TopBand ← SizedBox ← …
/// ```
///
/// `_TopBand` holds three things: the toggle row, the state strip, and — when the user turns
/// it on — the histogram panel. Its height is `_topBandWant`, which is `_topBandHeight`
/// (documented as measured from "the icon row plus the one-line state strip") plus
/// `_histogramPanelHeight`. **The histogram is not in the first measurement**, so turning it
/// on overflowed the band.
///
/// ## Why wrapping every child in `_BandFitted` was not the fix
///
/// It looked like the obvious answer — the file already says this row "was the one band child
/// left unwrapped" when it overflowed horizontally, so the rule seemed to be "nothing goes in
/// unwrapped". It does not generalise: a `FittedBox` inside a `Column` is laid out with an
/// **unbounded** main axis, so it never scales along it. `_BandFitted` fixes horizontal
/// overflow and cannot fix vertical. The band's height has to know what it is holding.
///
/// ## What the panel actually measures, and why both earlier numbers were wrong
///
/// 46 was estimated from `HistogramView(height: 38)` plus a guess at the padding; 55 was
/// inferred backwards from the device's 9 px overflow. Measured on the laid-out tree instead
/// (this file's last check prints it), the panel is **not one height**:
///
///     state                        panel (getSize)   panel's own Column
///     no frame sampled yet              43.0          38 + 1 + 0     (39)
///     first frame sampled               57.0          38 + 1 + 14    (53)
///
/// `HistogramReadout` is `SizedBox.shrink()` while `histogram.samples == 0`, so the panel
/// **grows by one line of readout text** the moment the camera delivers a frame. A band sized
/// for the pre-frame panel is correct for the first second of a session and 14 dp short
/// afterwards, which is why `_histogramPanelHeight` is 57.
///
/// ## The fixture could not reach the state the bug lives in
///
/// The fixture here used to be `connectedTestAppState()` and nothing else, which leaves
/// `cameraState` **null** — so `_StateStrip` was never built, the band had room to spare, and
/// the check was green against a band the device draws differently. It now injects a camera
/// state, which puts the strip at its real content.
///
/// ## Two overflows lived in this band, and they were not the same defect
///
/// With a camera state injected, this fixture used to overflow by **44 px with the
/// histogram off**. That was the state strip wrapping: seven camera values joined into
/// one `Text` with no `maxLines`, inside an `Expanded`, in a band whose height is the
/// constant `_topBandHeight` — documented as *"the icon row plus the one-line state
/// strip"*. The band's `Column` painted the overflow outside its box as the
/// yellow-and-black stripe, over the preview, because `_TopBand`'s wrapper is a
/// `Container` with no clip.
///
/// 44 px is this fixture's font, not the device's: the fixtures pump `LiveViewPage` as
/// `MaterialApp.home` with no `Scaffold`, so the text inherits `MaterialApp`'s
/// `fontFamily: 'monospace'` root style and `flutter_test` draws it in its own font,
/// while the app puts the page in a `Scaffold` body and draws Roboto. Re-measured in
/// Roboto the same state overflows by **12 px at text scale 1.0** — so the default text
/// scale really was broken, just far shallower than 44 suggests. The method and both
/// columns are written out in `live_view_text_scale_test.dart`.
///
/// That one is **fixed**, and in this round: `_StateStrip` is bounded to the one line
/// the band is sized for, and the band's height is the layout's ask as a *minimum*
/// rather than a fixed box, so a larger system font makes it a few dp taller instead of
/// overflowing. So the assertions below no longer have to tolerate an exception — they
/// ask for none, and `live_view_text_scale_test.dart` sweeps the same strip across both
/// locales at four text scales.
///
/// The other was this file's own subject: the band's height did not know about the
/// histogram panel. Those assertions stay, and they are still about the panel.
///
/// ## The helper that could not see either of them
///
/// `bandAround` used to report the `Column`'s own `size` as its "content". A `Column`
/// in a bounded box reports the **box**: 116 dp of children in a 72 dp box measures 72,
/// so "the contents fit inside it" compared 72 with 72 and could not fail — the same
/// shape as the fixture that injected no camera state. It now sums the children's
/// heights, which is the number that overflows.
void main() {
  // The emulator's window minus the shell's app bar and tab strip, in portrait.
  const portrait = Size(411, 727);

  /// A camera state with long values, so the state strip is at its real content rather
  /// than absent — the correction to the fixture described above.
  const withState = CameraState({
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

  /// Returns the app so the caller can stop the preview **inside** the body.
  ///
  /// Not in a teardown: `previewRunning: true` starts `AppState`'s 250 ms periodic ticker and
  /// `flutter_test` checks "no timer pending" *before* teardowns run, so a teardown is too
  /// late. Cost a cycle to rediscover.
  Future<AppState> pump(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(portrait);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final app = connectedTestAppState(previewRunning: true);
    addTearDown(app.dispose);
    // Set **before the first pump**, so the strip is in the very first frame the band is
    // laid out in. Injected after a pump it would only reach the second layout, and the
    // first one is the one that overflows.
    app.setTestCameraState(withState);
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

  /// Every child of the band's `Column`, summed.
  ///
  /// **Not** the `Column`'s own `size`: a `Column` in a bounded box reports the box, so
  /// a 116 dp stack of children in a 72 dp box measures 72 and an assertion that the
  /// contents fit compares 72 with 72. The sum is the number the `RenderFlex` overflows
  /// by, and it is the one that was 44 px too big.
  double stackedHeight(RenderBox columnBox) {
    final flex = columnBox as RenderFlex;
    var total = 0.0;
    RenderBox? child = flex.firstChild;
    while (child != null) {
      total += child.size.height;
      child = flex.childAfter(child);
    }
    return total;
  }

  /// The portrait top band's box, and the total height of what is inside it.
  ///
  /// Read off the render tree rather than recomputed from `_topBandWant`: a check that
  /// recomputed the constant would agree with itself while the device drew the stripe.
  ///
  /// `_TopBand` is `Container > ColoredBox > Padding > Column`, so from the column three
  /// ancestors up is the box whose height the band was given.
  ({double box, double content}) bandAround(WidgetTester tester, Finder child) {
    final columnBox = tester.renderObject<RenderBox>(
      find.ancestor(of: child, matching: find.byType(Column)).first,
    );
    final padding = columnBox.parent! as RenderBox;
    final coloredBox = padding.parent! as RenderBox;
    return (box: coloredBox.size.height, content: stackedHeight(columnBox));
  }

  testWidgets('the band pays for the histogram, and only for the histogram',
      (tester) async {
    // The whole point of the constant, as one arithmetic statement: the band's height and
    // its content height both grow by the panel when the panel appears, and by nothing
    // else. A constant that is too small shows up as content exceeding box; a constant
    // that is too large shows up as the band growing by more than the panel, which is
    // picture paid for nothing.
    final off = await pump(tester);
    final without = bandAround(
      tester,
      find.byKey(const ValueKey<String>('toggle-histogram')),
    );
    debugPrint('  top band, histogram off: box=${without.box} '
        'content=${without.content}');

    final on = await pump(tester);
    await tester.tap(find.byKey(const ValueKey<String>('toggle-histogram')));
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.takeException(), isNull,
        reason: 'turning the histogram on overflowed the band');
    final panel = tester.getSize(
        find.byKey(const ValueKey<String>('histogram-panel')));
    final onBand = bandAround(
      tester,
      find.byKey(const ValueKey<String>('histogram-panel')),
    );
    debugPrint('  top band, histogram on:  box=${onBand.box} '
        'content=${onBand.content} panel=${panel.height}');

    // 1. **The band pays for the histogram, and the content fits inside it.** This is the
    //    assertion the whole file is for. `content` is the sum of the band's children, so
    //    it is the number a `RenderFlex` overflows by — the `Column`'s own size is its
    //    box and would read 72 whatever happened inside it.
    expect(onBand.content, lessThanOrEqualTo(onBand.box + 0.5),
        reason: 'the band\'s contents are ${onBand.content} dp tall in a '
            '${onBand.box} dp box with the histogram on');
    expect(without.content, lessThanOrEqualTo(without.box + 0.5),
        reason: 'the band is ${without.box} dp and its contents are '
            '${without.content} dp with the histogram **off** — that is the toggle row '
            'plus one line of state strip, and if it does not fit, the strip has grown '
            'past the one line the constant is measured against');

    // 2. The band's growth is sized for the panel at its **tallest**, not at the height it
    //    happens to have in this frame. That distinction is the defect this constant kept
    //    having: `HistogramReadout` is `SizedBox.shrink()` until the camera's first frame
    //    is sampled, so a band sized for the panel as it measures *now* (43 dp here)
    //    overflows by a line of text one second into every session. The growth is
    //    therefore bounded below by what is on screen and above by the panel's full
    //    height — and it is pinned at the upper bound on purpose.
    final grew = onBand.box - without.box;
    expect(grew, greaterThanOrEqualTo(panel.height - 0.5),
        reason: 'the band grew by $grew dp for a panel already measuring '
            '${panel.height} dp — the panel is being clipped before it even has a '
            'readout');
    expect(grew, lessThanOrEqualTo(57.0 + 0.5),
        reason: 'the band grew by $grew dp for the histogram; 57 is the measured height '
            'of the panel with a live readout and there is nothing else in it');

    // 3. And the band's contents still fit **after** the growth — the state the empty
    //    panel does not reach, because content there is the strip plus a 43 dp panel.
    expect(without.content + 57.0, lessThanOrEqualTo(onBand.box + 0.5),
        reason: 'the band reserves ${onBand.box} dp; the toggle row, the state strip and '
            'a panel with a live readout come to ${without.content + 57.0} dp, so the '
            'band is short by ${without.content + 57.0 - onBand.box} dp the moment the '
            'camera delivers a frame');

    await off.stopPreview();
    await on.stopPreview();
  });

  testWidgets('the band is sized for the panel after frames arrive, not before',
      (tester) async {
    // The state that decided the constant. `HistogramReadout` is `SizedBox.shrink()`
    // until `histogram.samples > 0`, so the panel grows by a line of text the moment the
    // camera delivers a frame — and a constant tuned to the pre-frame panel overflows
    // a second into every session.
    //
    // Measured rather than asserted from the constant: the panel's own box with no
    // sample, plus the readout line measured on **the style the readout uses**
    // (`HistogramReadout`: 10.5 sp at `height: 1.3`). Measuring it that way avoids a
    // test-only accessor on the page just to prove a font metric.
    final app = await pump(tester);
    await tester.tap(find.byKey(const ValueKey<String>('toggle-histogram')));
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.takeException(), isNull,
        reason: 'turning the histogram on overflowed the band');

    final empty = tester
        .getSize(find.byKey(const ValueKey<String>('histogram-panel')))
        .height;
    debugPrint('  histogram panel with no sample: ${empty}dp');

    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Center(
        child: Text('mean 68  blown 5.4%  crushed 22.9%',
            style: const TextStyle(fontSize: 10.5, height: 1.3)),
      ),
    ));
    await tester.pump();
    final line = tester.getRect(find.byType(Text).first).height;
    debugPrint('  histogram readout line: ${line}dp');

    expect(line, greaterThan(0),
        reason: 'the readout draws a line of text, so the panel with a live sample is '
            'strictly taller than the panel without one');
    expect(empty + line, greaterThan(empty),
        reason: 'the two states must not measure the same, or this check is vacuous');
    expect(empty + line, lessThanOrEqualTo(57.0 + 0.5),
        reason: 'a panel with a live readout measures ${empty + line} dp, which is what '
            '`_histogramPanelHeight` has to cover');

    await app.stopPreview();
  });

  testWidgets('and the band shrinks back when the histogram is turned off',
      (tester) async {
    // The band's height is derived from `_showHistogram`, so both directions matter: a fix
    // that only ever grew the band would leave the picture smaller forever.
    final app = await pump(tester);
    final toggle = find.byKey(const ValueKey<String>('toggle-histogram'));

    final before = bandAround(tester, toggle);
    await tester.tap(toggle);
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.takeException(), isNull,
        reason: 'the histogram overflowed the band on the way on');
    await tester.tap(toggle);
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.takeException(), isNull,
        reason: 'the histogram overflowed the band on the way off');
    final after = bandAround(tester, toggle);

    expect(after.box, closeTo(before.box, 0.5),
        reason: 'the band was ${before.box} dp, grew for the panel and came back to '
            '${after.box} dp');
    await app.stopPreview();
  });
}
