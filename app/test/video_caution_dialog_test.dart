import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yi_m1_controller/ui/pages/video_page.dart';

import 'fakes.dart';
import 'package:yi_m1_controller/l10n/l10n.dart';

/// The hardware caveat must be dismissable.
///
/// ## The bug this exists for
///
/// Auto-showing was guarded by `!_acknowledged`, and "Not now" deliberately leaves
/// `_acknowledged` false — it is not an acknowledgement. So popping the dialog rebuilt
/// the page, the guard passed again, and the dialog was **re-shown immediately**. The
/// user's report was "clicking Not now does nothing": the dialog was simply still
/// there.
///
/// A dismissal and an acknowledgement are different decisions. This pins the
/// dismissal, and pins that the caveat is still reachable afterwards — the app bar's
/// button is how it is meant to be re-read, so making it disappear for good would be a
/// different bug.
void main() {
  Future<void> pumpVideo(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(411, 727));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    // `previewRunning: true` because the caveat is only shown once the gear is
    // usable, and the gear needs remote mode. Without it the page never reaches the
    // code under test and every assertion below fails for the wrong reason.
    final app = connectedTestAppState(previewRunning: true);
    addTearDown(app.dispose);
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      home: VideoPage(app: app),
    ));
    // The dialog is scheduled in a post-frame callback, so it needs a frame to land.
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 30));
    }
  }

  final Finder dialog = find.text(en.videoCautionTitle);

  testWidgets('the caveat appears once', (tester) async {
    await pumpVideo(tester);
    expect(dialog, findsOneWidget,
        reason: 'the caveat should be shown when the page opens with a live link');
  });

  testWidgets('"Not now" closes it and it stays closed', (tester) async {
    await pumpVideo(tester);
    expect(dialog, findsOneWidget);

    await tester.tap(find.text(en.videoNotNow));
    // Several frames: the bug was that the *rebuild after the pop* re-showed it, so a
    // single pump would miss it.
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(dialog, findsNothing,
        reason: '"Not now" left the dialog on screen — it was re-shown by the rebuild '
            'that popping it caused, which is why the button looked dead');
    expect(tester.takeException(), isNull);
  });

  testWidgets('"I understand" closes it too', (tester) async {
    await pumpVideo(tester);

    await tester.tap(find.text(en.videoUnderstandContinue));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(dialog, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the caveat can still be re-read on demand', (tester) async {
    await pumpVideo(tester);
    await tester.tap(find.text(en.videoNotNow));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(dialog, findsNothing);

    // "Always re-readable" is the documented promise; suppressing the automatic
    // showing must not have removed the manual one.
    await tester.tap(find.byIcon(Icons.report_gmailerrorred));
    await tester.pump(const Duration(milliseconds: 50));
    expect(dialog, findsOneWidget,
        reason: 'the app bar button must still open the caveat after a dismissal');
  });
}
