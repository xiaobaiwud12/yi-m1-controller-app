import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yi_m1_controller/app.dart';

import 'fakes.dart';
import 'package:yi_m1_controller/l10n/l10n.dart';

/// The app bar must show which build this is.
///
/// ## Why
///
/// A release APK was installed on hardware and reported as not containing UI fixes that
/// had been verified on the emulator. Inspecting the shipped binary showed the fixes
/// **were** in it, but nothing on screen identified the build, so the report could not be
/// settled by looking. The stamp is the answer to "is this the build I just made?", and
/// it is only worth having if it actually renders.
///
/// `tools/task.ps1 build` asserts the other half — that the stamped value is present in
/// the packaged `libapp.so` — because a build that silently falls back to `dev` would
/// look identical from the outside.
void main() {
  testWidgets('the app bar carries a build stamp', (tester) async {
    await tester.binding.setSurfaceSize(const Size(411, 727));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final app = connectedTestAppState();
    // No `addTearDown(app.dispose)`: `HomeShell` owns whatever it is handed and
    // disposes it in its own `dispose`, so disposing here as well threw
    // "A ValueNotifier was used after being disposed" during teardown.

    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      home: HomeShell(testApp: app),
    ));
    await tester.pump(const Duration(milliseconds: 50));

    final stamp = find.byKey(const ValueKey<String>('build-stamp'));
    expect(stamp, findsOneWidget,
        reason: 'without a visible build identity, "the release does not contain the '
            'fix" cannot be settled by looking at the app');

    // Under `flutter test` there is no `--dart-define`, so the compile-time default is
    // what renders. Asserting it is `dev` also documents what the fallback means: this
    // binary came from a working tree, not from a stamped build.
    expect(find.descendant(of: stamp, matching: find.text('dev')), findsOneWidget);
  });
}
