import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yi_m1_controller/protocol/camera_state.dart';
import 'package:yi_m1_controller/ui/pages/live_view_page.dart';

import 'fakes.dart';
import 'package:yi_m1_controller/l10n/l10n.dart';

/// The live view must survive a large system font.
///
/// ## Why this exists now
///
/// The portrait end rows used to be given half the slack around the frame — a figure
/// derived from the *screen*, so text size could not affect it. They are now sized from
/// their content (72dp top, 172dp bottom) so that the settings panel can have the rest.
/// A constant that was measured at the default text scale is exactly the kind of thing
/// that overflows when a user has their phone set to large text, and an overflow is a
/// Flutter **error** with the yellow-and-black stripe, not a cosmetic tightness.
///
/// Android's maximum is 2.0; 1.3 and 1.5 are the common accessibility settings and are
/// what this checks. The bands are allowed to be tight — that is a judgement call — but
/// they may not throw.
///
/// ## The camera state, and the three checks that were asserting nothing
///
/// This file used to build `connectedTestAppState(previewRunning: true)` and inject no
/// camera state, so `cameraState` stayed **null** — and `_TopBand` only draws
/// `_StateStrip` when there is a state. Three of its cases therefore asserted
/// `takeException() == null` about a strip that **was not in the tree**, while the strip
/// was the one band child that did not fit: it joined up to seven camera values into one
/// `Text` with no `maxLines`, wrapped, and the band's `Column` painted the overflow
/// outside its box — `_TopBand`'s wrapper is a plain `Container` with no clip, so the
/// stripe went over the live preview. That is `analysis/79` §4, and the fixture is the
/// half of it that could not see it.
///
/// Every case below now injects a state **and asserts the strip is present**, so the
/// file cannot go blind the same way twice. Measured before the fix (411x727, the same
/// fixture):
///
///     text scale   overflow, en     overflow, zh
///        1.0          44 px            28 px
///        1.3         106 px            85 px
///        1.5         196 px           148 px
///        2.0         427 px           459 px
///
/// ## What those numbers are, and what they are not
///
/// They are this fixture's numbers, and this fixture draws in **`flutter_test`'s font**,
/// which is neither the device's font nor a neutral stand-in for it. The chain is
/// specific and worth knowing before quoting any of them: `MaterialApp` installs
/// `fontFamily: 'monospace'` as its root `DefaultTextStyle` (deliberately — *"consider
/// putting your text in a `Material`"*), this file pumps `LiveViewPage` as `home:` with
/// **no `Scaffold`**, and the strip therefore inherits that family. Read back off the
/// laid-out `RenderParagraph`, the strip's texts report `family=monospace`; in the app
/// the page is a `Scaffold`'s body (`lib/app.dart:1123`) and the family is `Roboto`.
///
/// Re-measured with the real thing — Roboto loaded from the copy the Flutter SDK ships
/// (`bin/cache/artifacts/material_fonts/roboto-regular.ttf`) and the page pumped the way
/// the app builds it (`Scaffold` body, so the theme's family really applies) — the same
/// fixture overflows by:
///
///     text scale   overflow, en     overflow, zh
///        1.0          12 px             0 px
///        1.3          22 px            22 px
///        1.5          52 px            28 px
///        2.0         108 px            76 px
///
/// (zh carries a substitution caveat: Roboto has no CJK coverage, so those glyphs fall
/// back to the test font. Nothing here is a claim about the maintainer's own phone —
/// `adb shell settings get font_scale` was never run — but the defect does not depend on
/// that answer: English overflows at the **default** scale with this state.)
///
/// ## Why the file still asserts in the test font
///
/// Two reasons, and neither is "the numbers are close". The property asserted is
/// structural — the strip cannot grow past the one line the band is sized for — and the
/// Roboto sweep above agrees with it at every scale, so the check is not measuring a
/// font. And the two fonts fail differently: the test font is ~2.5x **wider** per glyph
/// (the joined values line is 770.5 dp against Roboto's 352.7) but its default line
/// height is **shorter** (the battery text's line box is 13 dp at 1.0 against Roboto's
/// 18, which is why the Roboto band is 88 dp at 2.0 where this fixture's is 82.5). A
/// check that only ever saw one of them would be entitled to neither column, which is
/// why both are written down here.
void main() {
  /// A camera state with seven reportable values — the strip's worst case, and the
  /// state the defect lives in.
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

  /// Lay the page out at [size] and [scale], then **leave the preview stopped**.
  ///
  /// `previewRunning: true` is a claim about the link, not a stream — but it is
  /// the state a page turns into a live 250 ms chrome ticker, and `flutter_test`
  /// checks "no timer is pending" *before* `addTearDown` callbacks run.  A test
  /// body that ends with the preview claimed as running therefore fails on the
  /// binding's own invariant, with a message about timers that says nothing
  /// about text scale.  Stopping it is also what production does when the user
  /// turns the preview off, so the last frame rendered is the one asserted on.
  Future<void> pumpAt(
      WidgetTester tester, Size size, double scale, Locale locale) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final app = connectedTestAppState(previewRunning: true);
    addTearDown(app.dispose);
    // Before the first pump: the strip has to be in the first frame that is laid out,
    // because that is the frame whose band overflows.
    app.setTestCameraState(withState);
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: locale,
      theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      home: MediaQuery(
        data: MediaQueryData(size: size, textScaler: TextScaler.linear(scale)),
        child: LiveViewPage(app: app),
      ),
    ));
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 40));
    }
    await app.stopPreview();
    await tester.pump(const Duration(milliseconds: 300));
  }

  const scales = <double>[1.0, 1.3, 1.5, 2.0];
  const locales = <Locale>[Locale('en'), Locale('zh')];

  /// The surfaces this sweeps, and whether the strip is in the tree on each.
  ///
  /// The third one is not decoration: 800x600 is short enough that the page gives up on
  /// its end bands (`bands.$2 == 0`) and stacks the strip in its **own column** under the
  /// picture. That is where an unbounded strip is worst — it does not merely paint over
  /// the preview there, it pushes the shutter and the navigation row off the bottom of
  /// the page, which is the defect `live_view_overflow_test.dart` records ("the settings
  /// toggle was unreachable"). It is measured at **46 dp** there, one line plus the
  /// gradient's padding, and no surface below overflows at any scale in either language.
  ///
  /// The fourth is the narrow end of the range this app runs on (320 dp is the smallest
  /// body worth caring about) and it was added because it **failed**: the strip's own row
  /// is fine while the values line yields, but the battery fact beside it is not in an
  /// `Expanded`, and on this surface at text scale 2.0 in Chinese it alone was wider than
  /// the row — `A RenderFlex overflowed by 20 pixels on the right`, a second overflow in
  /// the same widget with a different cause from the vertical one this file exists for.
  const surfaces = <({Size size, String name, bool strip})>[
    (size: Size(411, 727), name: 'portrait', strip: true),
    (size: Size(914, 297), name: 'landscape', strip: false),
    (size: Size(800, 600), name: 'short window', strip: true),
    (size: Size(320, 568), name: 'small phone', strip: true),
  ];

  for (final locale in locales) {
    for (final surface in surfaces) {
      for (final scale in scales) {
        testWidgets(
            '${surface.name} survives text scale $scale in ${locale.languageCode}',
            (tester) async {
          await pumpAt(tester, surface.size, scale, locale);

          if (surface.strip) {
            // The fixture's own check, and the one whose absence hid this defect for a
            // round: with no camera state the strip is not built at all, and every
            // assertion below is then about a widget that does not exist.
            expect(find.byKey(const ValueKey<String>('state-strip')), findsOneWidget,
                reason: 'the fixture must inject a camera state; without one '
                    '`_StateStrip` is not in the tree and this file checks nothing');
            debugPrint('  [${surface.name} $scale ${locale.languageCode}] strip painted '
                '${tester.getRect(find.byKey(const ValueKey<String>('state-strip')))}');
          } else {
            expect(find.byKey(const ValueKey<String>('state-strip')), findsNothing,
                reason: 'this surface draws the camera state in a side column '
                    '(`_SideState`), so the strip is the wrong widget to look for here');
          }

          expect(tester.takeException(), isNull,
              reason: 'the ${surface.name} live view overflowed at text scale $scale '
                  'in ${locale.languageCode}');
        });
      }
    }
  }

  testWidgets('the shutter stays above the minimum tap target when text is large',
      (tester) async {
    await pumpAt(tester, const Size(411, 727), 2.0, const Locale('en'));
    final f = find.byKey(const ValueKey<String>('btn-shutter'));
    expect(f, findsOneWidget);
    // `getRect` this time, and that is the correction: the shutter sits inside a
    // `FittedBox`, so `getSize` reports the box *before* the scale while `getRect`
    // reports the rect the user's thumb has to land in (`analysis/45` §4). The old
    // version of this check asserted `getSize` against a fixed size the button was
    // built with, so **no text scale could change its answer** — it was a check on a
    // constant wearing the name of a check on the screen. Measured now: 68.0 portrait
    // at every scale, and 62.9 before the row-width fix recorded in
    // `live_view_controls_size_test.dart`.
    final painted = tester.getRect(f).shortestSide;
    final laid = tester.getSize(f).shortestSide;
    debugPrint('  btn-shutter at 2.0: painted $painted, laid $laid');
    expect(painted, greaterThanOrEqualTo(48),
        reason: 'the shutter is painted at $painted dp with the system font at 2.0; '
            'Material\'s floor is 48');
    expect(painted, closeTo(laid, 0.01),
        reason: 'the shutter is painted at $painted dp against a $laid dp layout: the '
            'band must not scale the primary control down to pay for the larger text — '
            'the text is what yields, and `_StateStrip` is bounded to one line for '
            'exactly that reason');
  });
}
