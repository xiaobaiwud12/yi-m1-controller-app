import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yi_m1_controller/app.dart';
import 'package:yi_m1_controller/l10n/l10n.dart';
import 'package:yi_m1_controller/sync/ui_prefs.dart';
import 'package:yi_m1_controller/ui/pages/album_page.dart';
import 'package:yi_m1_controller/ui/widgets/exposure_dial.dart';

import 'fakes.dart';

/// The end-to-end locale check: does choosing a language actually change what is
/// drawn, and does the choice survive a restart?
///
/// ## Why the wiring is the thing under test
///
/// Every other check in this round is about *strings*. This one is about the three
/// joins between them, each of which can be wrong while every string is right:
///
/// 1. the preference is stored and read back ([UiPrefs]);
/// 2. the stored tag reaches `MaterialApp.locale` — `null` for "follow the phone",
///    which is the join that fails *silently* if it is mistyped, because English is
///    the fallback and a wrong tag therefore looks like a working app;
/// 3. the frame after the choice is already in the new language, so the user does not
///    have to relaunch to find out whether the setting worked.
void main() {
  testWidgets('the drawn language follows the stored choice, without a restart',
      (tester) async {
    // A connected state, so the shell draws its navigation bar and both tabs rather
    // than the startup-error screen.
    final app = connectedTestAppState();
    expect(app.localeTag, kLocaleSystem,
        reason: 'a fresh install must follow the phone, not pick a language');

    await tester.pumpWidget(YiM1ControllerApp(
      testHome: HomeShell(testApp: app),
    ));
    await tester.pump();

    // The control. The test binding's platform locale is `en_US`, so before any
    // choice the English string is on screen — without this, the check below would
    // also pass if the app drew Chinese for some unrelated reason.
    expect(find.text(englishStrings.navSync), findsOneWidget,
        reason: 'the shell should be following the platform locale (en)');
    expect(find.text(chineseStrings.navSync), findsNothing);

    // What the Settings picker does: one assignment on AppState.
    app.localeTag = kLocaleChinese;
    await tester.pump();

    expect(find.text(chineseStrings.navSync), findsOneWidget,
        reason: 'the frame after the choice is already in the chosen language');
    expect(find.text(englishStrings.navSync), findsNothing,
        reason: 'the English label is still drawn, so the choice did not reach '
            'MaterialApp.locale');

    // And back, so the check is not satisfied by a one-way latch.
    app.localeTag = kLocaleEnglish;
    await tester.pump();
    expect(find.text(englishStrings.navSync), findsOneWidget);
    expect(find.text(chineseStrings.navSync), findsNothing);

    // Deliberately **not** `app.dispose()`: the shell owns the state it was handed
    // and disposes it when the tree is torn down. Disposing it here as well made the
    // teardown throw `A ValueNotifier<Uint8List?> was used after being disposed`,
    // which reads like a localization defect and is only a double dispose.
  });

  testWidgets('a whole page is drawn in the chosen language', (tester) async {
    // The shell test above proves the *wiring*; this proves the wiring reaches a page
    // that was actually converted string by string. `AlbumPage` is used because it is
    // fully localized and draws its sync bar unconditionally, so the string under
    // assertion is on screen in the state the fixture provides.
    final app = connectedTestAppState();
    await tester.pumpWidget(
        localizedApp(AlbumPage(app: app), locale: const Locale('zh')));
    await tester.pump();

    expect(find.text(chineseStrings.syncNothingQueued), findsOneWidget,
        reason: 'the Chinese album page should say 队列为空');
    expect(find.text(englishStrings.syncNothingQueued), findsNothing,
        reason: 'the English sync bar is still drawn, so the locale did not reach '
            'the page');

    await tester.pumpWidget(
        localizedApp(AlbumPage(app: app), locale: const Locale('en')));
    await tester.pump();
    expect(find.text(englishStrings.syncNothingQueued), findsOneWidget);
    expect(find.text(chineseStrings.syncNothingQueued), findsNothing);
  });

  testWidgets('the app title follows the locale too', (tester) async {
    // The task switcher's label. It comes from `onGenerateTitle` rather than a
    // `Text`, so it is the one string a naive `find.text` sweep would miss.
    final app = connectedTestAppState();
    await tester.pumpWidget(YiM1ControllerApp(
      testLocaleTag: kLocaleChinese,
      testHome: HomeShell(testApp: app),
    ));
    await tester.pump();
    expect(find.text(chineseStrings.appTitle), findsOneWidget);
    expect(find.text(englishStrings.appTitle), findsNothing);
  });

  test('the choice is written to the preference file and read back', () async {
    final store = MemoryPrefsStore();
    final prefs = UiPrefs(store: store);
    await prefs.load();
    expect(prefs.localeTag, kLocaleSystem);

    prefs.setLocaleTag(kLocaleChinese);
    await prefs.save();

    final reloaded = UiPrefs(store: store);
    await reloaded.load();
    expect(reloaded.localeTag, kLocaleChinese,
        reason: 'the stored file is: ${await store.read()}');
    expect(await store.read(), contains('"locale":"zh"'));
  });

  test('a preference file written before this setting existed follows the phone',
      () async {
    // The upgrade path, and the reason the default matters: an existing user has a
    // `UiPrefs` file with no `locale` field, and it must not decide their language.
    final legacy = UiPrefs(
      store: MemoryPrefsStore('{"version":1,"open":["image"],"keepScreenOn":true}'),
    );
    await legacy.load();
    expect(legacy.localeTag, kLocaleSystem);
  });

  test('an unknown locale tag falls back to following the phone', () async {
    // A file written by a build that later grows a third language must not pin an
    // older build to a language it cannot draw.
    final f = UiPrefs(store: MemoryPrefsStore('{"version":1,"locale":"fr"}'));
    await f.load();
    expect(f.localeTag, kLocaleSystem);
  });

  test('the dial headings keep the settled bilingual pairing', () {
    // `analysis/60` settled the pairing 感光度 ISO / 模式 Mode / 曝光补偿 EV /
    // 光圈 Aperture / 快门 Shutter, and the Chinese half of it is the maintainer's own
    // vocabulary. This asserts both halves, so a later "tidy-up" of either language
    // has to be deliberate rather than a side effect of an ARB edit.
    expect(chineseStrings.dialAperture, '光圈');
    expect(chineseStrings.dialShutter, '快门');
    expect(chineseStrings.dialIso, '感光度');
    expect(chineseStrings.dialEv, '曝光补偿');
    expect(chineseStrings.dialMode, '模式');

    expect(englishStrings.dialAperture, 'Aperture');
    expect(englishStrings.dialShutter, 'Shutter');
    expect(englishStrings.dialIso, 'ISO');
    expect(englishStrings.dialEv, 'EV');
    expect(englishStrings.dialMode, 'Mode');

    // And the heading is resolved through the ARB, not through the widget's own
    // `const` fallback. That fallback is English now — a Chinese literal compiled into
    // a widget is a string that shows up in an English UI — so if `dialHeading` ever
    // stopped resolving, the Chinese UI would quietly read English and these two lines
    // are what would notice.
    expect(dialHeading(chineseStrings, kEvDialIdentity), '曝光补偿');
    expect(dialHeading(englishStrings, kEvDialIdentity), 'EV');
    expect(dialHeading(chineseStrings, ExposureParam.iso.identity), '感光度');
    expect(dialHeading(englishStrings, ExposureParam.iso.identity), 'ISO');
    expect(dialHeading(chineseStrings, kModeDialIdentity), '模式');
  });

  test('a system tag becomes a null Locale, not English', () {
    // The single most damaging one-character mistake available here: returning
    // `Locale('en')` would pin every device to English and look like it worked on a
    // developer's phone.
    expect(localeFromTag(kLocaleSystem), isNull);
    expect(localeFromTag(kLocaleEnglish), const Locale('en'));
    expect(localeFromTag(kLocaleChinese), const Locale('zh'));
  });

  test('a region-tagged locale still reports the right stored tag', () {
    // The picker highlights the current choice; a phone set to `zh_Hant_TW` must
    // highlight the Chinese row rather than none.
    expect(tagFromLocale(const Locale('zh', 'CN')), kLocaleChinese);
    expect(tagFromLocale(const Locale('en', 'GB')), kLocaleEnglish);
    expect(tagFromLocale(null), kLocaleSystem);
    expect(tagFromLocale(const Locale('fr')), kLocaleSystem);
  });

  test('the two locales differ on a camera term a photographer would notice', () {
    // Not a translation-quality check — a check that the ARB files are two files.
    // 感光度 is the word a Chinese photographer uses for ISO; if this ever equals the
    // English, something has replaced the Chinese file with the English one.
    expect(chineseStrings.readoutIso, '感光度');
    expect(englishStrings.readoutIso, 'ISO');
    expect(chineseStrings.readoutAperture, '光圈');
    expect(chineseStrings.readoutShutter, '快门');
    expect(chineseStrings.readoutEv, '曝光补偿');
    expect(chineseStrings.histogramTooltip, contains('直方图'));
    expect(chineseStrings.syncModeAutoOriginalOnly, contains('原图'));
    expect(chineseStrings.albumTitleCount(3), contains('张'));
  });
}
