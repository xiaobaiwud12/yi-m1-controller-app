import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import 'home_shell.dart';
import 'presentation_state.dart';
import 'startup_error_view.dart';

class YiM1ControllerApp extends StatelessWidget {
  /// The language tag to draw in, for a test that wants a specific one.
  ///
  /// Null — the production default — reads [appPresentation.localeTag], which the shell keeps in
  /// step with `AppState.localeTag`. A test supplies a constant here when it is
  /// asserting what a locale *draws* rather than which locale was chosen; the
  /// end-to-end path (Settings → `AppState` → here → the painted text) is asserted
  /// separately in `test/l10n_locale_switch_test.dart`.
  final String? testLocaleTag;

  /// The shell to draw, for a test.
  ///
  /// Production passes nothing and gets `const HomeShell()`, which builds a
  /// plugin-backed BLE transport and reads two files — neither exists under
  /// `flutter test`. Supplying a shell built around `AppState(testHttp:)`
  /// (`test/fakes.dart`) is what makes the *locale path* testable end to end:
  /// `AppState.localeTag` → [appPresentation.localeTag] → `MaterialApp.locale` → the painted string.
  /// Without this seam that path is only ever assembled in production, which is the
  /// "parts wired wrong" gap `analysis/41` §7.11 describes.
  final Widget? testHome;

  const YiM1ControllerApp({super.key, this.testLocaleTag, this.testHome});

  /// The same widget, pinned to [tag] — for a test that renders a locale directly.
  const YiM1ControllerApp.withLocale(String this.testLocaleTag, {super.key})
      : testHome = null;
  @override
  Widget build(BuildContext context) {
    final tag = testLocaleTag;
    return ValueListenableBuilder<String>(
      valueListenable: appPresentation.localeTag,
      builder: (context, liveTag, _) => MaterialApp(
        // Resolved through the delegate rather than written as a literal: the task
        // switcher shows this, and an app that calls itself "M1 Controller" in the
        // Chinese task switcher while drawing Chinese everywhere else is exactly the
        // half-translated state this round exists to avoid.
        onGenerateTitle: (context) => l10nOf(context).appTitle,
        debugShowCheckedModeBanner: false,
        // The three delegates the generator emits: this app's strings, plus the
        // framework's own Material and Cupertino strings. Without the last two the
        // framework text (a platform dialog's buttons, a `Slider`'s semantics)
        // stays English no matter what locale is selected.
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        // `null` means "follow the phone", which is the default and the only
        // correct behaviour for a user who has never opened Settings.
        locale: localeFromTag(tag ?? liveTag),
        theme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.dark,
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF7DB3FF),
            brightness: Brightness.dark,
          ),
          scaffoldBackgroundColor: const Color(0xFF0E0E0E),
        ),
        home: testHome ?? const HomeShell(),
        builder: (context, child) => ValueListenableBuilder<String?>(
          valueListenable: appPresentation.launchError,
          builder: (context, err, _) => err == null
              ? (child ?? const SizedBox.shrink())
              : StartupErrorView(
                  err,
                  // An escape hatch, deliberately. The diagnostic is only useful if
                  // the user can get past it: the failure may be in one subsystem,
                  // and the rest of the app is still worth reaching — that is how
                  // the error text gets reported at all.
                  onDismiss: () => appPresentation.launchError.value = null,
                ),
        ),
      ),
    );
  }
}
