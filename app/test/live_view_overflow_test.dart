import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yi_m1_controller/ui/pages/live_view_page.dart';

import 'fakes.dart';
import 'package:yi_m1_controller/l10n/l10n.dart';

/// Opening the settings panel must not overflow the page.
///
/// ## Why this file exists
///
/// Found by driving the running app on the emulator: tapping the settings toggle
/// produced
///
/// ```
/// The overflowing RenderFlex has an orientation of Axis.vertical.
/// constraints: BoxConstraints(0.0<=w<=411.4, 0.0<=h<=727.5)
/// size: Size(411.4, 727.5)
/// creator: Column ← LayoutBuilder ← ... ← LiveViewPage
/// ```
///
/// — the page's root `Column` was taller than the space it had once the second-level
/// panel was inserted, so the panel (and whatever it pushed) was clipped with the
/// black-and-yellow overflow stripes. An overflow is an **error condition in
/// Flutter**, not a cosmetic warning: content is unreachable and, because the same
/// error reaches `FlutterError.onError`, it is also the kind of thing that used to
/// replace the app with the startup-error screen.
///
/// The existing smoke test had a "settings surface opens" case, but it guarded the tap
/// with `if (settingsButton.evaluate().isNotEmpty)` — a condition that **silently
/// passes when the button is not found**, which is exactly when the test should fail.
/// This one taps by key and asserts the panel is actually on screen, so it cannot pass
/// by doing nothing.
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('yi_m1_overflow_');
    useTempStorage(tmp.path);
  });

  tearDown(() {
    try {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // left to the OS; the assertions are about layout, not temp files
    }
  });

  /// Pump a connected live view at a given size and return the app.
  Future<void> pump(WidgetTester tester, Size size) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final app = connectedTestAppState();
    addTearDown(app.dispose);
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      home: LiveViewPage(app: app),
    ));
    await tester.pump(const Duration(milliseconds: 50));
  }

  /// Fail if anything overflowed, naming the widget so the cause is obvious.
  ///
  /// The diagnostics are included deliberately: `tester.takeException()` hands back a
  /// `FlutterError` whose `toString()` is only the summary line ("A RenderFlex
  /// overflowed by 66 pixels on the right"), and the creator chain that says *which*
  /// widget overflowed lives in `diagnostics`. Without it the failure names a symptom
  /// and not the cause, which cost a round trip here.
  void expectNoOverflow(WidgetTester tester, String when) {
    final error = tester.takeException();
    if (error == null) return;
    final detail = error is FlutterError
        ? error.diagnostics.map((d) => d.toString()).join('\n')
        : '$error';
    fail('layout failed $when:\n$detail');
  }

  testWidgets('the settings panel does not overflow in portrait',
      (tester) async {
    // The **measured** body size from the emulator, not a screen size:
    // `setSurfaceSize` takes logical pixels, and the live-view page only gets what
    // is left after the shell's app bar and tab strip. Passing the whole screen
    // would hand the page ~800 logical pixels of height where it really has ~727,
    // which is why the first version of this test passed while the device
    // overflowed.
    await pump(tester, const Size(411, 727));
    expectNoOverflow(tester, 'before the panel opened');

    final toggle = find.byKey(const ValueKey<String>('btn-settings-toggle'));
    expect(toggle, findsOneWidget,
        reason: 'the settings toggle must exist while connected, or this test '
            'cannot reach the panel it is about to judge');

    await tester.tap(toggle);
    await tester.pump(const Duration(milliseconds: 50));

    expectNoOverflow(tester, 'after opening the settings panel');
    // Proof the tap did something: a test that fails to open the panel would
    // otherwise pass by never exercising it.
    expect(find.text(en.liveHideSettings), findsOneWidget,
        reason: 'the toggle did not actually open the panel');
  });

  testWidgets('the settings panel does not overflow in landscape',
      (tester) async {
    // Also measured: 914x411 screen minus the shell's chrome.
    await pump(tester, const Size(914, 297));
    expectNoOverflow(tester, 'before the panel opened');

    final toggle = find.byKey(const ValueKey<String>('btn-settings-toggle'));
    expect(toggle, findsOneWidget);
    await tester.tap(toggle);
    await tester.pump(const Duration(milliseconds: 50));

    expectNoOverflow(tester, 'after opening the settings panel in landscape');
  });

  testWidgets('the settings panel does not overflow on a short screen',
      (tester) async {
    // The case that overflows first: not enough height for the panel plus the
    // preview plus the bands. A small phone, or a device with a large font.
    await pump(tester, const Size(320, 480));
    expectNoOverflow(tester, 'before the panel opened');

    final toggle = find.byKey(const ValueKey<String>('btn-settings-toggle'));
    expect(toggle, findsOneWidget);
    await tester.tap(toggle);
    await tester.pump(const Duration(milliseconds: 50));

    expectNoOverflow(tester, 'after opening the panel on a short screen');
  });
}
