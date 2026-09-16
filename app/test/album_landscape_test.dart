import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yi_m1_controller/ui/pages/album_page.dart';

import 'fakes.dart';
import 'package:yi_m1_controller/l10n/l10n.dart';

/// The album must give the photos real height in landscape.
///
/// ## Why this is measured rather than looked at
///
/// On a 914x411 window the sync bar stacked above the grid left the grid about 60dp:
/// the tiles rendered as a sliver with their capture dates cut off. A screenshot showed
/// it, but a screenshot is not a check — the layout was "working" and unusable at the
/// same time, which is exactly the state a page drifts back into.
///
/// So the assertion is the thing the user actually needs: **the grid gets more height
/// in landscape than the stacked layout could give it**, and the sync controls are still
/// reachable in their side column. Reverting to the stacked bar fails this.
void main() {
  /// The body height a landscape phone leaves the page, measured on the emulator.
  const landscape = Size(914, 297);
  const portrait = Size(411, 727);

  Future<void> pump(WidgetTester tester, Size size) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final app = connectedTestAppState();
    addTearDown(app.dispose);
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      home: AlbumPage(app: app),
    ));
    // The page loads its first listing after awaiting the durable ledger, and that
    // ledger is read from **real files**. A widget test runs in a fake-async zone
    // where real I/O never completes, so `pump` alone left the page on its spinner
    // forever and the grid was reported missing — three runs went into diagnosing
    // that. `runAsync` steps outside the zone long enough for the read to finish.
    //
    // Worth knowing generally: **any widget test of a page that awaits disk at
    // startup needs this**, and without it the page looks empty rather than slow.
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump(const Duration(milliseconds: 60));
    }

    // Preconditions, asserted rather than assumed. Without the album the page shows
    // its "connect first" message and there is no grid to measure; without the
    // listing it shows "No photos found". Both look identical to a layout bug from
    // the assertion below, and that ambiguity cost two runs here.
    expect(app.album, isNotNull,
        reason: 'the injected link is not ready, so the page cannot list anything');
  }

  testWidgets('the grid gets the height, not the sync bar, in landscape',
      (tester) async {
    await pump(tester, landscape);
    expect(tester.takeException(), isNull);

    final grid = find.byType(GridView);
    if (grid.evaluate().isEmpty) {
      // Say what *is* on screen. "Found 0 GridViews" does not distinguish a spinner
      // from an error message from the empty state, and all three are reachable here.
      final texts = find
          .byType(Text)
          .evaluate()
          .map((e) => (e.widget as Text).data)
          .whereType<String>()
          .toList();
      fail('no GridView. On screen: $texts');
    }

    final gridBox = tester.getSize(grid);
    // Half the window is the bar to beat: stacked, the grid was left ~60 of ~300.
    expect(gridBox.height, greaterThan(landscape.height * 0.5),
        reason: 'landscape grid is ${gridBox.height}dp of ${landscape.height}dp — '
            'the sync bar is still taking the height it should be taking width for');

    // The controls must not have been sacrificed to get there.
    expect(find.byKey(const ValueKey<String>('btn-sync-mode')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('toggle-pause-stream')),
        findsOneWidget);
    expect(find.byKey(const ValueKey<String>('btn-sync-start')), findsOneWidget);
  });

  testWidgets('portrait keeps the sync bar above the grid', (tester) async {
    await pump(tester, portrait);
    expect(tester.takeException(), isNull);

    final grid = find.byType(GridView);
    expect(grid, findsOneWidget);

    // The bar is above, so the grid starts below the window's midpoint-ish top area
    // and the two are stacked rather than side by side.
    final gridBox = tester.getRect(grid);
    expect(gridBox.width, closeTo(portrait.width, 1.0),
        reason: 'a side column in portrait would leave the grid narrow — this '
            'layout is meant to apply only to wide, short windows');
  });
}
