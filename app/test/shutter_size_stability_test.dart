import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yi_m1_controller/ui/pages/live_view_page.dart';

import 'fakes.dart';
import 'package:yi_m1_controller/l10n/l10n.dart';

/// The controls must not change size when the shutter is blocked.
///
/// ## The bug this exists for
///
/// Reported from hardware with screenshots: without the preview the controls drew small
/// — as they had before the size fix — and they became correct once the preview started;
/// touching the shutter put them back to small. The build stamp in those screenshots
/// showed the current binary, so it was not a stale APK.
///
/// The cause was arithmetic in the layout. `_BandFitted` wraps the shutter bar in a
/// `FittedBox`, which measures its child with **unbounded width**, so the blocked-state
/// sentence below the row was laid out as one unbroken line. The bar's natural width
/// became that sentence — about 1490dp — and the `FittedBox` scaled everything,
/// shutter included, to fit it into the band:
///
///     portrait, blocked     0.271   (a 68dp shutter drawn at 18.4dp)
///     portrait, previewing  1.000
///     landscape, blocked    0.188   (12.8dp)
///     landscape, previewing 0.814
///
/// `403 / 0.271` and `280 / 0.188` are the same ~1490dp, which is what identified it.
///
/// ## What is asserted
///
/// Not the exact scale — that is the layout's business — but the property a user
/// notices: **the same control looks the same whatever the camera is doing.** A status
/// line appearing next to a button must not resize the button.
void main() {
  /// The size the control is actually **painted** at.
  ///
  /// `getRect` applies ancestor transforms and `getSize` does not, so the ratio is the
  /// scale the `FittedBox` is applying. Using the wrong one of these two is what made an
  /// earlier measurement round report 18.4dp for a button the device was drawing at 68 —
  /// see `analysis/45`.
  double paintedSize(WidgetTester tester, String key) =>
      tester.getRect(find.byKey(ValueKey<String>(key))).shortestSide;

  /// Lay the page out, measure, and **leave the preview stopped**.
  ///
  /// `previewRunning: true` is a claim about the link, not a stream — but it is
  /// the state a page turns into a live 250 ms chrome ticker, and `flutter_test`
  /// checks "no timer is pending" *before* `addTearDown` callbacks run, so a test
  /// body that ends with the preview claimed as running fails on the binding's
  /// own invariant.  Stopping it is what production does when the user turns the
  /// preview off; the measured size is taken before that.
  Future<double> pumpAndMeasure(
    WidgetTester tester,
    Size size,
    String key, {
    required bool previewing,
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final app = connectedTestAppState(previewRunning: previewing);
    addTearDown(app.dispose);
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
    final measured = paintedSize(tester, key);
    if (previewing) {
      await app.stopPreview();
      await tester.pump(const Duration(milliseconds: 300));
    }
    return measured;
  }

  for (final entry in <String, Size>{
    'portrait': const Size(411, 727),
    'landscape': const Size(914, 297),
  }.entries) {
    testWidgets('${entry.key}: the shutter is the same size blocked or previewing',
        (tester) async {
      final blocked =
          await pumpAndMeasure(tester, entry.value, 'btn-shutter', previewing: false);
      expect(tester.takeException(), isNull);

      final running =
          await pumpAndMeasure(tester, entry.value, 'btn-shutter', previewing: true);
      expect(tester.takeException(), isNull);

      expect(running, closeTo(blocked, 0.5),
          reason: 'the shutter is painted at ${blocked}dp with the camera blocked and '
              '${running}dp with the preview running. A control that changes size when '
              'a status line appears beside it is the reported defect: the interface '
              'appeared to revert to an older version when the shutter was touched.');

      // And it must be a usable control in both states, not merely consistent.
      expect(blocked, greaterThanOrEqualTo(48),
          reason: 'a 68dp shutter drawn at ${blocked}dp is below the minimum tap '
              'target — the state-dependent scaling is back');
    });
  }
}
