import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yi_m1_controller/ui/pages/live_view_page.dart';

import 'fakes.dart';
import 'package:yi_m1_controller/l10n/l10n.dart';

/// Does entering full screen make the controls *bigger*, or smaller?
///
/// ## Why this test exists
///
/// Full screen is supposed to buy picture area by removing chrome. If it also shrinks
/// the shutter, it has taken the space back out of the controls — the one thing the
/// user has to hit without looking. Reported from the emulator as "optimise the control
/// sizes and layout after entering full screen".
///
/// ## `getRect`, not `getSize`
///
/// The controls live inside a `FittedBox(scaleDown)` (`_BandFitted`), so a control's own
/// layout size is its **design** size and says nothing about what is on screen. Only
/// `getRect` applies the ancestor transform. `analysis/45` records a round that was lost
/// by measuring the wrong one — `getSize` reported 68 dp for a button rendering at 15.
void main() {
  // The emulator's window, landscape. `normal` is the body once the shell's app bar and
  // tab strip have taken their share; `full` is what `btn-fullscreen` hands back.
  const normal = Size(914, 297);
  const full = Size(914, 411);

  Future<void> pump(WidgetTester tester, Size size, {required bool fullScreen}) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final app = connectedTestAppState();
    addTearDown(app.dispose);
    app.fullScreen = fullScreen;
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

  /// The size actually painted, ancestor transforms included.
  Size rendered(WidgetTester tester, String key) {
    final f = find.byKey(ValueKey<String>(key));
    if (f.evaluate().isEmpty) return Size.zero;
    return tester.getRect(f).size;
  }

  testWidgets('report rendered control sizes: normal vs full screen',
      (tester) async {
    const keys = [
      'btn-shutter',
      'btn-focus-centre',
      'btn-preview-toggle',
      'btn-fullscreen',
      'btn-settings-toggle',
    ];

    await pump(tester, normal, fullScreen: false);
    final normalSizes = {for (final k in keys) k: rendered(tester, k)};

    await pump(tester, full, fullScreen: true);
    final fullSizes = {for (final k in keys) k: rendered(tester, k)};

    debugPrint('  control                  normal      full screen');
    for (final k in keys) {
      final a = normalSizes[k]!;
      final b = fullSizes[k]!;
      debugPrint('  ${k.padRight(22)} '
          '${a.shortestSide.toStringAsFixed(1).padLeft(7)} '
          '${b.shortestSide.toStringAsFixed(1).padLeft(13)}');
    }

    final preview = rendered(tester, 'live-preview-area');
    debugPrint('  preview area in full screen: '
        '${preview.width.toStringAsFixed(1)} x ${preview.height.toStringAsFixed(1)}');

    // The frame is the thing full screen exists to enlarge, so hold that too — a change
    // that buys control size by giving back more picture than full screen gained is not
    // a fix.
    expect(preview.width * preview.height, greaterThan(396 * 297),
        reason: 'full screen exists to show more picture than the normal layout; a '
            'frame no larger than the normal 396x297 has given that away');

    for (final k in keys) {
      final a = normalSizes[k]!;
      final b = fullSizes[k]!;
      expect(b.shortestSide, greaterThanOrEqualTo(a.shortestSide - 0.5),
          reason: '$k renders at ${b.shortestSide.toStringAsFixed(1)}dp in full '
              'screen against ${a.shortestSide.toStringAsFixed(1)}dp normally. Full '
              'screen removes chrome to give the picture room; taking it back out of '
              'the controls is the wrong trade — the shutter is the one control that '
              'has to be hittable without looking');
    }

    // Material's floor, stated independently of whatever the normal layout manages.
    expect(fullSizes['btn-shutter']!.shortestSide, greaterThanOrEqualTo(48),
        reason: 'the shutter in full screen is below Material\'s 48dp minimum tap '
            'target, so the mode meant to make shooting easier makes it harder');
  });
}
