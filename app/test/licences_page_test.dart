import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yi_m1_controller/app.dart';
import 'package:yi_m1_controller/l10n/l10n.dart';
import 'package:yi_m1_controller/ui/licences.dart';

import 'fakes.dart';

/// The in-app open-source licence page.
///
/// ## Why this file exists
///
/// `analysis/63` §7.2 / §12.3 item 15 found no `showLicensePage`, `LicensePage`,
/// `LicenseRegistry` or `AboutDialog` anywhere under `lib/` — the app bundled
/// Apache-2.0, MIT and BSD-3-Clause code and told the user nothing about it. The fix
/// is one button and one page, and the page is exactly the kind of thing that
/// **looks present in code and is unreachable in practice**: a `showLicensePage`
/// call behind a key nobody taps, a `LicenseRegistry` entry that never gets
/// registered, or a legalese line resolved from the wrong context all read as
/// "done" in review.
///
/// So the assertions are on the rendered page, reached the way a user reaches it:
/// tap `btn-licences`, then look.
void main() {
  testWidgets('the app bar opens a licence page that names this app and its terms',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(411, 727));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    // A connected state, so the shell draws its app bar rather than the startup
    // error screen. The button must exist at every link state, though — the licence
    // does not depend on the camera — which the disconnected case below asserts.
    final app = connectedTestAppState();
    await tester.pumpWidget(localizedApp(HomeShell(testApp: app)));
    await tester.pump();

    final button = find.byKey(const ValueKey<String>('btn-licences'));
    expect(button, findsOneWidget,
        reason: 'a licence page with no way to reach it satisfies nothing: '
            'Apache-2.0 §4 and BSD-3 attribution are about the recipient');

    await tester.tap(button);
    await tester.pumpAndSettle();

    // The page itself, not just "a route was pushed".
    expect(find.byType(LicensePage), findsOneWidget);

    // The application's own identity and its terms. `applicationLegalese` is a
    // `Text` inside the page, so this is the rendered claim rather than the
    // constant.
    expect(find.text(englishStrings.appTitle), findsOneWidget);
    expect(find.text(englishStrings.licencesLegalese), findsOneWidget);

    // This app's own licence entry, which `NOTICES` cannot carry because it is not
    // a pub package. Its absence is the failure mode that looks like success: the
    // page renders, listing every *other* project's licence.
    expect(find.text('yi-m1-controller-app'), findsOneWidget,
        reason: 'the page lists bundled packages from NOTICES; this app has to '
            'register itself or it is the one component missing from its own '
            'licence page');
  });

  testWidgets('the licence entry is registered once, not once per visit',
      (tester) async {
    final app = connectedTestAppState();
    await tester.pumpWidget(localizedApp(HomeShell(testApp: app)));
    await tester.pump();

    final button = find.byKey(const ValueKey<String>('btn-licences'));
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.byType(LicensePage), findsOneWidget);

    // Close it and open it again. `LicenseRegistry.addLicense` appends, so a
    // register-on-open would list this app once per visit.
    //
    // A fixed-duration pump rather than `pumpAndSettle` for the pop: the licence page
    // keeps a pending future while it streams `LicenseRegistry`, so nothing quiesces
    // while it is on screen or leaving. The assertion below does not depend on the
    // transition finishing.
    Navigator.of(tester.element(find.byType(LicensePage))).pop();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(button);
    await tester.pump();

    final entries = await LicenseRegistry.licenses
        .where((e) => e.packages.contains('yi-m1-controller-app'))
        .toList()
        .timeout(const Duration(seconds: 5));
    expect(entries, hasLength(1),
        reason: 'the entry was registered more than once');
  });

  testWidgets('the licence button is reachable with no camera at all',
      (tester) async {
    // The same defect class as the guide button: a control that only exists in the
    // connected state is a control a new user cannot find.
    //
    // No `addTearDown(app.dispose)`: `HomeShell` owns whatever it is handed and
    // disposes it itself, so disposing here as well throws during teardown.
    await tester.pumpWidget(localizedApp(HomeShell(testApp: testAppState())));
    await tester.pump();

    expect(find.byKey(const ValueKey<String>('btn-licences')), findsOneWidget);
  });

  testWidgets('the page and the button read in the chosen language',
      (tester) async {
    final app = connectedTestAppState();
    await tester.pumpWidget(
      localizedApp(HomeShell(testApp: app), locale: const Locale('zh')),
    );
    await tester.pump();

    final button = tester.widget<IconButton>(
      find.byKey(const ValueKey<String>('btn-licences')),
    );
    expect(button.tooltip, chineseStrings.licencesTooltip);

    await tester.tap(find.byKey(const ValueKey<String>('btn-licences')));
    await tester.pumpAndSettle();
    expect(find.text(chineseStrings.licencesLegalese), findsOneWidget);
  });

  test('the repository the page points at is the release repository', () {
    // The development repository is private and stays private. A link to it from a
    // shipped build is a dead end for the user and a hint about a repository that is
    // not theirs to read.
    expect(kReleaseRepoUrl, contains('yi-m1-controller-app'));
    expect(kReleaseRepoUrl, isNot(endsWith('/yi-m1-controller')));
  });
}
