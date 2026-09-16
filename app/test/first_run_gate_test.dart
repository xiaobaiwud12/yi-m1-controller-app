import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yi_m1_controller/app.dart';
import 'package:yi_m1_controller/platform/onboarding_prefs.dart';

import 'fakes.dart';
import 'package:yi_m1_controller/l10n/l10n.dart';

/// The first-run **gate** and the way back into it.
///
/// ## What is asserted here, and what is not
///
/// The decision itself — "should the flow run" — is one boolean over two files, and
/// `HomeShell.showOnboarding` is the seam that lets a test state the answer instead of
/// waiting for it. A widget test's fake-async zone never completes real file I/O
/// (`analysis/41` §7.9), so a test that awaited the decision would hang instead of
/// failing, which is why the shell does not make an injected-state test wait for it.
///
/// What *is* asserted here:
///
/// * the flow appears when it is asked for, and the app is usable behind it;
/// * **Skip is recorded to the file** — the assertion that a flow which only hides
///   itself in memory fails, and the one that matters, because a skip that is not
///   remembered means the flow returns on every launch;
/// * the recorded answer survives a reload, which is the whole point of asking at
///   pairing time;
/// * the flow is reachable again from the app bar, at both window shapes.
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('yi_m1_firstrun_');
    useTempStorage(tmp.path);
  });

  tearDown(() {
    try {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Left to the OS; these assertions are about which screen is shown.
    }
  });

  File fileNamed(String name) =>
      File('${tmp.path}${Platform.pathSeparator}$name');

  /// The preferences the app builds for itself, pointed at the temp directory.
  ///
  /// The **real** store, with only the documents directory swapped by
  /// `useTempStorage` — a hand-built one is what hid the fact that the first version
  /// never actually saved anything (see [PrefsStore]).
  OnboardingPrefs appPrefs({void Function(String)? onLog}) =>
      OnboardingPrefs(store: PrefsStore(), onLog: onLog);

  Future<void> pumpShell(
    WidgetTester tester,
    Size size, {
    bool? showOnboarding,
    OnboardingPrefs? prefs,
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final app = connectedTestAppState();
    // `HomeShell` owns and disposes whatever it is handed — see the note in
    // `build_stamp_test.dart`; disposing here as well threw on teardown.
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      home: HomeShell(
        testApp: app,
        onboardingPrefs: prefs ?? appPrefs(),
        showOnboarding: showOnboarding,
      ),
    ));
    await tester.pump(const Duration(milliseconds: 50));
  }

  group('with a returning user', () {
    testWidgets('the flow does not run and the app is usable', (tester) async {
      // The default a returning user gets. `showOnboarding: false` is what the shell
      // decides for somebody who has been through the flow or has a stored pairing —
      // see `_decide` — and the failure it guards against is the worst kind here: the
      // same introduction appearing again on every launch, over the photo library the
      // user was trying to reach.
      await pumpShell(tester, const Size(411, 727), showOnboarding: false);

      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey<String>('first-run-flow')), findsNothing,
          reason: 'the first-run flow ran for a user who had seen it');
      expect(find.byKey(const ValueKey<String>('nav-shell')), findsOneWidget,
          reason: 'the shell did not render, so the user got a blank screen');
      // And the app behind it works: the tab strip is there to be used.
      expect(find.byType(NavigationBar), findsOneWidget);
    });

    testWidgets('the gate treats a stored pairing as "not a first run"',
        (tester) async {
      // The half of "does not run for an already-paired returning user" that has no
      // preference file to go on: this user upgraded from a build that had no
      // onboarding at all, so only the pairing record can tell the truth. The record
      // below is the shape `FilePairingStore` actually holds, and `hasWifiCredentials`
      // is the test `_decide` applies — not `canReuseSession`, because the connection
      // layer deliberately drops a session the camera refused while keeping the
      // credentials.
      fileNamed('camera_pairing.json').writeAsStringSync(
          '{"protocol":"1","ssid":"YI_M1_XXXXXX","passkey":"12345678"}');
      await pumpShell(tester, const Size(411, 727), showOnboarding: false);

      expect(find.byKey(const ValueKey<String>('first-run-flow')), findsNothing);
      expect(find.byKey(const ValueKey<String>('nav-shell')), findsOneWidget);
    });
  });

  group('on a first launch', () {
    testWidgets('the flow runs, and skip is written to the file',
        (tester) async {
      // Real file I/O for the one thing that has to be real: the write. `runAsync` is
      // required — the load in `initState` and the save on skip are genuine I/O, and
      // inside the fake clock they never complete (`analysis/41` §7.9).
      final prefs = appPrefs();
      await pumpShell(tester, const Size(411, 727),
          showOnboarding: true, prefs: prefs);
      await tester.runAsync(prefs.load);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey<String>('first-run-flow')), findsOneWidget,
          reason: 'a brand-new install went straight to a disconnected Capture '
              'page, which is the gap this flow exists to close');
      // The app is behind it, not replaced by it: the flow is short and skippable,
      // and "never a wall" means the thing underneath is already built.
      expect(find.byKey(const ValueKey<String>('nav-shell')), findsOneWidget);

      final skip = find.byKey(const ValueKey<String>('btn-onboarding-exit'));
      expect(skip, findsOneWidget,
          reason: 'the flow always offers a way past itself');
      expect(find.text(en.firstRunSkip), findsOneWidget);

      await tester.runAsync(() async {
        await tester.tap(skip);
        await Future<void>.delayed(const Duration(milliseconds: 150));
      });
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));

      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey<String>('first-run-flow')), findsNothing,
          reason: 'skipping did not dismiss the flow');
      expect(find.byKey(const ValueKey<String>('nav-shell')), findsOneWidget);
      expect(prefs.onboardingDone, isTrue,
          reason: 'the flow did not record that it had been seen, so it will run '
              'again on the next launch');

      // And what was recorded survives a relaunch, which is the whole point of
      // asking at pairing time.
      final reloaded = appPrefs();
      await tester.runAsync(reloaded.load);
      expect(reloaded.onboardingDone, isTrue,
          reason: 'nothing was written to disk, so the next launch asks again');
      expect(reloaded.syncMode, kDefaultSyncModeId,
          reason: 'a skip still leaves a usable mode rather than none');
    });
  });

  /// Take the layout complaint the **shell** is allowed to make, and nothing else.
  ///
  /// The disconnected Capture page's connect bar overflows its row by 31 px at
  /// 411 dp (`live_view_page.dart:3706`) — a portrait defect of the shell, present
  /// with the flow on screen or without it, and visible here only because the shell
  /// is built and laid out behind the flow. It is swallowed **by name** so these
  /// groups stay statements about the first-run flow: an exception from the flow
  /// itself, or any overflow inside it, still fails.
  void drainShellLayoutNoise(WidgetTester tester) {
    final e = tester.takeException();
    if (e == null) return;
    final text = '$e';
    // Two **fixture** artifacts, named individually so this cannot swallow anything
    // else:
    //
    // * the shell's connect-bar overflow (above);
    // * `A AppState was used after being disposed` — a test that pumps the whole app
    //   twice disposes the first tree's `AppState` while its launch `_load()` is still
    //   pending, and that continuation calls `notifyListeners` on a disposed notifier.
    //   In release that is a no-op; in a test it is an assertion. It belongs to
    //   `AppState`'s dispose contract and to nobody in this round.
    expect(text,
        anyOf(contains('RenderFlex overflowed'),
            contains('was used after being disposed')),
        reason: 'the fixture threw: $e');
    expect(text, isNot(contains('first_run_flow.dart')),
        reason: 'the first-run flow threw: $e');
  }

  group('on a cleared install, through the gate the app really runs', () {
    /// Pump the shell the way `main()` does: **no injected `AppState` and no
    /// `showOnboarding` override**.
    ///
    /// ## Why the override is not good enough to catch this
    ///
    /// `HomeShell.showOnboarding` is a seam. Passing it true proves what the shell
    /// does *once it has been told to show the flow*; it skips `_decide`, which is
    /// the only thing that reads the two stores. The defect this group exists for
    /// survived a whole emulator round precisely because the seam was the only thing
    /// under test **and** the emulator's preference file already said `seen=true`:
    /// the gate short-circuited, the flow was never constructed, and every check
    /// stayed green. So the fresh state is built here out of an **empty store** and
    /// an **empty documents directory** (`useTempStorage`, installed in `setUp`),
    /// and the gate is allowed to make its own decision.
    Future<void> pumpThroughTheGate(
      WidgetTester tester, {
      required OnboardingPrefs prefs,
      required List<String> recorded,
      Size size = const Size(411, 727),
    }) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(localizedApp(HomeShell(
        onboardingPrefs: prefs,
        onSyncModeRecorded: recorded.add,
      )));
      // The gate's two reads are genuine I/O — one of them is a real file in the
      // temp documents directory — and inside the fake clock they never complete
      // (`analysis/41` §7.9). `runAsync` is what lets the decision happen at all;
      // without it the shell sits on its boot frame and the flow is simply absent,
      // which would make every assertion below pass for the wrong reason.
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pump();

      // The premise every assertion in this group rests on: the gate finished its
      // reads and left its boot frame.
      expect(find.byKey(const ValueKey<String>('first-run-boot')), findsNothing,
          reason: 'the gate never finished its reads, so nothing below is measured');
      drainShellLayoutNoise(tester);
    }

    testWidgets('the flow appears on step 1 and waits for the user', (tester) async {
      // **The defect this check was written for.** `_FirstRunFlowState.initState`
      // recorded `kDefaultSyncModeId` and called `onModeChosen` when the preference
      // had no answer — so a brand-new install had its sync mode decided, written to
      // the file and handed to the running engine **before the user saw the screen
      // asking the question**. On hardware the two log lines are six milliseconds
      // apart:
      //
      //   first-run gate: seen=false paired=false show=true
      //   first-run: sync mode recorded as autoPreviewThenOriginal
      //
      // The recorded value is the default because that is exactly what a step
      // writing its own default produces — the app answered for the user.
      final store = MemoryPrefsStore();
      final prefs = OnboardingPrefs(store: store);
      final recorded = <String>[];
      await pumpThroughTheGate(tester, prefs: prefs, recorded: recorded);

      expect(find.byKey(const ValueKey<String>('first-run-flow')), findsOneWidget,
          reason: 'a cleared install got no first-run flow at all');
      // ...on its **first** step, which is the part the maintainer never saw.
      expect(find.byKey(const ValueKey<String>('onboarding-step-0')), findsOneWidget,
          reason: 'the flow opened on a step other than the first one');
      expect(find.byKey(const ValueKey<String>('onboarding-step-1')), findsNothing);
      expect(find.byKey(const ValueKey<String>('onboarding-step-2')), findsNothing);
      expect(find.text(en.firstRunStepWhatItDoes), findsWidgets,
          reason: 'the first-use page is not the page on screen');

      // **The assertion that would have caught it.** Nothing may be recorded, and
      // nothing may be written, until a human answers.
      expect(recorded, isEmpty,
          reason: 'a mode was handed to the engine before the user chose one: '
              '$recorded');
      expect(prefs.askedSyncMode, isFalse,
          reason: 'the flow answered its own question');
      expect(prefs.syncMode, isNull);
      expect(prefs.onboardingDone, isFalse,
          reason: 'the flow recorded itself as seen without being read');

      // It stays there, unaided. Ten pumps is 1 s of frames and several `AppState`
      // ticks — the shell rebuilds on its own ticker, so a flow that leaves on a
      // rebuild has ten chances to do it here.
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.byKey(const ValueKey<String>('first-run-flow')), findsOneWidget,
            reason: 'the flow left the screen on its own after ${i + 1} pumps');
        expect(find.byKey(const ValueKey<String>('onboarding-step-0')),
            findsOneWidget,
            reason: 'the flow moved off step 1 on its own after ${i + 1} pumps');
      }
      expect(recorded, isEmpty,
          reason: 'the flow finished itself: $recorded');
      expect(prefs.syncMode, isNull);

      // And nothing reached the store either — the preference is the half that
      // survives a restart, so an in-memory-only answer would still be a defect.
      final reread = OnboardingPrefs(store: store);
      await tester.runAsync(reread.load);
      expect(reread.askedSyncMode, isFalse,
          reason: 'a sync mode was written to the preference store by nobody');
      expect(reread.onboardingDone, isFalse,
          reason: 'the flow wrote "seen" without the user seeing it');
    });

    testWidgets('the same flow, opened from `?`, does the same thing',
        (tester) async {
      // **The comparison.** The two entry points mount differently — the first run
      // is a `Positioned.fill` sibling inside the shell's `Stack`, the guide is a
      // pushed route — and if only one of them showed its pages the difference would
      // have to be in the mounting, not in the steps. It is measured rather than
      // argued: a returning user (so the gate stays out of the way), then the app
      // bar's `?`.
      final prefs = OnboardingPrefs(
          store: MemoryPrefsStore(
              '{"version":1,"syncMode":"manualOnly","onboardingDone":true}'));
      final recorded = <String>[];
      await pumpThroughTheGate(tester, prefs: prefs, recorded: recorded);

      expect(find.byKey(const ValueKey<String>('first-run-flow')), findsNothing,
          reason: 'a returning user was shown the flow again');
      expect(find.byKey(const ValueKey<String>('nav-shell')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey<String>('btn-first-run-guide')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      drainShellLayoutNoise(tester);
      expect(find.byKey(const ValueKey<String>('first-run-flow')), findsOneWidget,
          reason: 'the guide pushed nothing');
      expect(find.byKey(const ValueKey<String>('onboarding-step-0')), findsOneWidget,
          reason: 'the guide opened on a step other than the first one');
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.byKey(const ValueKey<String>('first-run-flow')), findsOneWidget,
            reason: 'the guide left the screen on its own after ${i + 1} pumps');
      }
      // A revisit decides nothing on the user's behalf — §`_openGuide`.
      expect(recorded, isEmpty,
          reason: 'opening the guide recorded a mode: $recorded');
    });

    testWidgets('but answering it does record — the counter is wired',
        (tester) async {
      // The premise check for the two above, in the shape `analysis/66` §3 uses: an
      // assertion that nothing is ever recorded is also satisfied by a counter that
      // is not connected to anything, or by a flow whose second step never renders.
      // So walk to the question and answer it, and require the record to appear.
      final store = MemoryPrefsStore();
      final prefs = OnboardingPrefs(store: store);
      final recorded = <String>[];
      await pumpThroughTheGate(tester, prefs: prefs, recorded: recorded);

      await tester.tap(find.byKey(const ValueKey<String>('btn-onboarding-next')));
      await tester.pump();
      expect(find.byKey(const ValueKey<String>('onboarding-step-1')), findsOneWidget,
          reason: 'Next did not reach the sync-mode question');
      expect(recorded, isEmpty, reason: 'reaching the question recorded an answer');

      // `ensureVisible` + `warnIfMissed: false`, the idiom `first_run_flow_test.dart`
      // uses: the third option of a scrolling step can sit below the fold in a
      // 411 dp-tall window, and whether it does is a layout question this check is
      // not about. The tap still has to land — the assertions below are its
      // consequence, so a tap that did nothing fails here.
      final manual =
          find.byKey(const ValueKey<String>('btn-sync-mode-manualOnly'));
      await tester.ensureVisible(manual);
      await tester.pump();
      await tester.tap(manual, warnIfMissed: false);
      await tester.pump();
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 150)));

      expect(recorded, equals(<String>['manualOnly']),
          reason: 'answering the question recorded nothing');
      expect(prefs.syncMode, equals('manualOnly'));
      final reread = OnboardingPrefs(store: store);
      await tester.runAsync(reread.load);
      expect(reread.syncMode, equals('manualOnly'),
          reason: 'the answer never reached the store');
    });
  });

  group('the flow is on the SCREEN, not merely in the tree', () {
    // ## Why a group of pixel assertions exists at all
    //
    // Everything above is a statement about the **widget tree** — `findsOneWidget`,
    // `findsNothing`, `getSize`. The maintainer's phone says the first-use page was
    // never visible, and reports *"did not tap it, and did not see it"*, so the two
    // facts have to be reconciled rather than one of them explained away:
    //
    //   the flow is constructed and in the tree   [V]
    //   the screen showed the app's own page      [V, from the screenshot]
    //
    // This project has already paid twice tonight for reading the first as evidence of
    // the second: the histogram below the shutter "was not rendering" (it was), and a
    // readout column measured correct while the screen showed something else. **A widget
    // in the tree is `[V]` about the tree and `[H]` about the screen.** So this group
    // stops reading the tree and looks at the rendered image.
    //
    // ## Why a differential instead of a stored baseline
    //
    // `analysis/63`/`AGENTS.md` §11 deleted the project's one golden baseline because it
    // was **vacuously green**: one distinct colour, a fully transparent 1080x2136 image,
    // passing under any rendering at all. A stored baseline is exactly as strong as that
    // file, so nothing here is stored. Instead the two screens are compared **to each
    // other**:
    //
    //   * A — a cleared install (empty store, the real gate, no `showOnboarding` seam);
    //   * B — a returning user (the gate hides the flow) — which is precisely what the
    //     maintainer's screenshot shows.
    //
    // Two blank or two identical images cannot satisfy "A is not B", and B doubles as the
    // failing-first control: run the same measurement on the screen that has no flow on
    // it and it must come out empty. That is the defect being checked for — a mount that
    // paints the shell and nothing else.
    //
    // The fingerprint is `Color(0xFF171717)`, the `_SurpriseCard` background, and it is a
    // **measured** fingerprint rather than a chosen one: `grep -rn 0xFF171717 app/lib`
    // finds it in `first_run_flow.dart` alone, so on this build its pixels can only have
    // been painted by the flow.

    const Size screen = Size(411, 727);
    const int card = 0xFF171717;

    /// Pump the shell with the probe wrapped around the whole app, through the real gate.
    Future<void> pumpProbed(WidgetTester tester,
        {required OnboardingPrefs prefs}) async {
      await tester.binding.setSurfaceSize(screen);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(RepaintBoundary(
        key: const ValueKey<String>('screen-probe'),
        child: localizedApp(HomeShell(onboardingPrefs: prefs)),
      ));
      // Alternating `runAsync` and `pump`, because the launch path is a chain of real
      // platform round trips (the gate's two stores, then `AppState._load`'s four) — each
      // completes in real time but resumes on the fake clock, so one long slice completes
      // only the first hop. The last few slices also let `_load()` **finish**: a tree
      // disposed while it is still in flight calls `notifyListeners` on a disposed
      // `AppState`, which is an assertion in a test (`AppState`'s dispose contract, not
      // this round's).
      for (var i = 0; i < 8; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 40)));
        await tester.pump(const Duration(milliseconds: 40));
      }
      expect(find.byKey(const ValueKey<String>('first-run-boot')), findsNothing,
          reason: 'the gate never finished its reads, so nothing below is measured');
      drainShellLayoutNoise(tester);
    }

    /// The screen as raw RGBA — `runAsync` because rasterisation is real asynchronous
    /// work that never completes inside the fake clock.
    Future<Uint8List> shot(WidgetTester tester) async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey<String>('screen-probe')));
      late Uint8List pixels;
      await tester.runAsync(() async {
        final image = await boundary.toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        // **A copy, not a view.** `data.buffer.asUint8List(...)` hands back the engine's
        // external memory, and `dispose()` below frees it — the next `toImage` in the
        // same test then reuses those bytes and the first capture silently becomes a
        // copy of the second. It produced `0 of 298797 pixels differ` between two
        // screens that a card-colour count distinguishes by 71855 against 5: a
        // measurement that contradicted itself, which is the same shape as the two
        // accidents this group exists for.
        pixels = Uint8List.fromList(
            data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
        image.dispose();
      });
      return pixels;
    }

    /// How many pixels are exactly [argb]. Exact, because both the card fill and its
    /// 1 px border are flat colours — a fuzzy match would also catch an anti-aliased
    /// edge of something else.
    int countArgb(Uint8List rgba, int argb) {
      final r = (argb >> 16) & 0xFF, g = (argb >> 8) & 0xFF, b = argb & 0xFF;
      var n = 0;
      for (var i = 0; i + 3 < rgba.length; i += 4) {
        if (rgba[i] == r && rgba[i + 1] == g && rgba[i + 2] == b) n++;
      }
      return n;
    }

    int differentPixels(Uint8List a, Uint8List b) {
      final n = a.length < b.length ? a.length : b.length;
      var d = 0;
      for (var i = 0; i + 3 < n; i += 4) {
        if (a[i] != b[i] || a[i + 1] != b[i + 1] || a[i + 2] != b[i + 2]) d++;
      }
      return d;
    }

    testWidgets('the cleared-install screen paints the flow, not the shell',
        (tester) async {
      // A: the state the maintainer was in.
      await pumpProbed(tester,
          prefs: OnboardingPrefs(store: MemoryPrefsStore()));
      expect(find.byKey(const ValueKey<String>('first-run-flow')), findsOneWidget,
          reason: 'the tree fact this group exists to stop trusting on its own');
      // The mount is a `Positioned.fill` inside the shell's `Stack`, so the flow must
      // own the **whole** window and not a collapsed box: measured, not assumed.
      expect(tester.getSize(find.byKey(const ValueKey<String>('first-run-flow'))),
          screen,
          reason: 'the overlay did not get the window, so it could not have been seen');

      final a = await shot(tester);
      expect(a.length, screen.width * screen.height * 4,
          reason: 'the probe did not capture the window');

      final cardsOnA = countArgb(a, card);
      final distinctA = <int>{};
      for (var i = 0; i + 3 < a.length; i += 4) {
        distinctA.add((a[i] << 16) | (a[i + 1] << 8) | a[i + 2]);
      }
      debugPrint('  A: ${screen.width}x${screen.height} '
          'card-coloured pixels=$cardsOnA distinct colours=${distinctA.length}');

      // The premise of every image assertion in this file: a screen made of one
      // colour is the shape the deleted golden had, and it would satisfy any
      // "the images differ" claim for the wrong reason.
      expect(distinctA.length, greaterThan(20),
          reason: 'the capture is blank or flat (${distinctA.length} distinct '
              'colours), so it cannot be evidence about what is on screen');

      // **The claim**: the flow's own cards are on the screen. Its two `_SurpriseCard`s
      // are 411-40 dp wide and ~60 dp tall each, so a few thousand pixels of this
      // colour are expected; a screen showing the shell has none.
      expect(cardsOnA, greaterThan(2000),
          reason: 'the screen the user gets on a cleared install contains '
              '$cardsOnA pixels of the flow\'s card colour — the flow is in the tree '
              'and not on the screen');
    });

    testWidgets('and the control: a screen without the flow has none of it',
        (tester) async {
      // B: the returning user, whose screen is what the maintainer photographed. This
      // is the negative control that makes the assertion above falsifiable — without
      // it, a colour count is a number with nothing to compare against.
      await pumpProbed(
        tester,
        prefs: OnboardingPrefs(
            store: MemoryPrefsStore(
                '{"version":1,"syncMode":"manualOnly","onboardingDone":true}')),
      );
      expect(find.byKey(const ValueKey<String>('first-run-flow')), findsNothing);

      final b = await shot(tester);
      final cardsOnB = countArgb(b, card);
      final distinctB = <int>{};
      for (var i = 0; i + 3 < b.length; i += 4) {
        distinctB.add((b[i] << 16) | (b[i + 1] << 8) | b[i + 2]);
      }
      debugPrint('  B: card-coloured pixels=$cardsOnB '
          'distinct colours=${distinctB.length}');

      expect(distinctB.length, greaterThan(20),
          reason: 'the control screen is blank, so it proves nothing');
      expect(cardsOnB, lessThan(200),
          reason: 'the shell alone paints $cardsOnB pixels of the flow\'s card colour, '
              'so the count above does not discriminate the flow from the shell');
    });

    testWidgets('mounting the flow writes no preference file at all',
        (tester) async {
      // ## The question that decides whether the flash and the recording are one defect
      //
      // If the mount-time recording persisted `onboardingDone: true`, then the flow would
      // mark itself **seen** as it appeared, and anything that re-evaluated the gate
      // afterwards would replace it with the shell — a flash, caused by the defect this
      // round fixed. That is the first hypothesis worth killing, and it is killed by
      // reading the file rather than by reading `encode()`: the write is fire-and-forget
      // and the value it lands with is a fact about the disk.
      //
      // The **real** store is used (`appPrefs()` → `PrefsStore` → `useTempStorage`), and
      // the file is `onboarding_prefs.json`, which nothing else in the app writes at
      // launch: `UiPrefs` writes its own file, the ledger and the queue write theirs, and
      // `AppState._load()` only *reads* this one.
      final prefs = appPrefs(onLog: debugPrint);
      await tester.binding.setSurfaceSize(screen);
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(RepaintBoundary(
        key: const ValueKey<String>('screen-probe'),
        child: localizedApp(HomeShell(onboardingPrefs: prefs)),
      ));
      // **Alternating `runAsync` and `pump`, not one long slice.** With the real store
      // the gate is a chain of real platform round trips — the documents directory, the
      // existence check, the read, then the same again for the pairing record — and each
      // one completes in real time but resumes on the fake clock. A single
      // `runAsync(300ms)` therefore completes only the *first* hop, and the frame after
      // it is still the boot frame. (It read as "the gate did not reach the flow" while
      // the gate's own log line said `show=true` — the same shape as the measurement
      // this round is about: the number contradicted the log, and the fixture was wrong.)
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 40)));
        await tester.pump(const Duration(milliseconds: 40));
      }
      drainShellLayoutNoise(tester);
      expect(find.byKey(const ValueKey<String>('first-run-flow')), findsOneWidget,
          reason: 'the gate did not reach the flow, so nothing was measured');

      // And the fire-and-forget write, had there been one, would have landed by now.
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 200)));

      final file = fileNamed('onboarding_prefs.json');
      final exists = file.existsSync();
      final contents = exists ? file.readAsStringSync() : '(the file is absent)';
      debugPrint('  onboarding_prefs.json: exists=$exists contents=$contents');

      expect(exists, isFalse,
          reason: 'mounting the first-run flow wrote $contents — a preference the user '
              'never chose, persisted before the question was asked');
    });

    testWidgets('frame by frame from launch: boot, then the flow, and it stays',
        (tester) async {
      // ## Why this is a trace and not an assertion about a settled tree
      //
      // The report from hardware is *"something flashed past"*: the flow mounts and the
      // screen ends up on the shell. Every check above pumps and **settles** before it
      // looks, so a widget that is present for one frame and gone the next passes all of
      // them — the tree it asserts on is the settled one. So this one records every
      // frame from launch and prints it, and the assertion is about the **sequence**:
      // once the flow has been painted it must still be painted on every later frame.
      //
      // It drives `YiM1ControllerApp` — the real `MaterialApp`, the real `_localeTag`
      // and `_launchError` wiring — with the real gate behind it. Its `testHome` seam
      // supplies the shell, not the gate decision: `_decide` still reads the stores, so
      // the state under test is still a cleared install.
      //
      // `flowPixels` is the part that is about the screen: `findsOneWidget` would say
      // "present" for a flow that is in the tree and painted over, which is exactly the
      // distinction this project has already lost twice.
      await tester.binding.setSurfaceSize(screen);
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final frames = <({int boot, int flow, int shell, int pixels})>[];
      final lines = <String>[];
      Future<void> record(int i) async {
        final boot =
            find.byKey(const ValueKey<String>('first-run-boot')).evaluate().length;
        final flow =
            find.byKey(const ValueKey<String>('first-run-flow')).evaluate().length;
        final shell =
            find.byKey(const ValueKey<String>('nav-shell')).evaluate().length;
        // Drained per frame: an exception thrown on a frame is itself a finding, and
        // leaving it pending would fail the test naming the shell's overflow instead.
        final err = tester.takeException();
        final pixels = countArgb(await shot(tester), card);
        frames.add((boot: boot, flow: flow, shell: shell, pixels: pixels));
        lines.add('frame $i: boot=$boot flow=$flow shell=$shell '
            'flowPixels=$pixels'
            '${err == null ? '' : ' EXCEPTION=${err.toString().split('\n').first}'}');
      }

      await tester.pumpWidget(RepaintBoundary(
        key: const ValueKey<String>('screen-probe'),
        child: YiM1ControllerApp(
          testHome: HomeShell(
            // **The real store, on real files** — not `MemoryPrefsStore`. The one
            // environment difference the desk had left: the device's `PrefsStore` writes
            // through `path_provider` and a real `writeAsString`, and the mount-time
            // `save()` this defect is about is a real asynchronous write there. A trace
            // taken against an in-memory store would be a trace of a different install.
            onboardingPrefs: appPrefs(),
          ),
        ),
      ));
      await record(0);

      // **Sixty frames, not fifteen.** Fourteen frames of 16 ms is 224 ms of the
      // widget clock — deliberately just short of `AppState`'s **250 ms chrome
      // ticker**, which starts as soon as the live view behind the flow reports itself
      // on screen and notifies every listener four times a second for the life of the
      // session. A flow that survives 224 ms and dies at 260 ms would pass a short
      // trace, so the trace covers several ticker periods.
      for (var i = 1; i <= 60; i++) {
        // `runAsync` in slices so the gate's real file reads — and `AppState._load`'s
        // four of them — can complete between frames, which is what makes the frames
        // after them observable at all.
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 12)));
        await tester.pump(const Duration(milliseconds: 16));
        await record(i);
      }
      debugPrint(lines.map((f) => '  $f').join('\n'));

      final painted = [
        for (var i = 0; i < frames.length; i++)
          if (frames[i].pixels > 2000) i
      ];
      expect(painted, isNotEmpty,
          reason: 'the flow was never painted on any frame of a cleared install:\n'
              '${lines.join('\n')}');
      // Once it is on the screen it stays on the screen, for every later frame.
      for (var i = painted.first; i < frames.length; i++) {
        expect(frames[i].pixels, greaterThan(2000),
            reason: 'the flow was painted at frame ${painted.first} and gone by frame '
                '$i — that is the reported flash:\n${lines.join('\n')}');
        expect(frames[i].flow, 1,
            reason: 'the flow left the tree at frame $i:\n${lines.join('\n')}');
      }
    });

    testWidgets('the two screens are different images', (tester) async {
      // The differential, stated directly and in the terms the parent asked for: "the
      // screen is not the shell's own". This is the assertion that fails if the overlay
      // ever becomes transparent, zero-sized, or painted **under** the shell — three
      // different mount defects, one measurement, none of which the tree can see.
      await pumpProbed(tester,
          prefs: OnboardingPrefs(store: MemoryPrefsStore()));
      final a = await shot(tester);
      drainShellLayoutNoise(tester);

      // **Torn down first, on purpose.** `pumpWidget` updates the tree in place, and
      // `HomeShell` has the same type at the same position in both pumps, so the second
      // one would **reuse `_HomeShellState`** — keeping `_prefs` and `_showOnboarding`
      // from the first — and this measurement would compare a screen with itself. It
      // did: `0 of 298797 pixels differ` while the card count in the neighbouring checks
      // read 71855 against 5. An empty pump in between forces a fresh state, which is
      // what "the other screen" means.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();

      await pumpProbed(
        tester,
        prefs: OnboardingPrefs(
            store: MemoryPrefsStore(
                '{"version":1,"syncMode":"manualOnly","onboardingDone":true}')),
      );
      final b = await shot(tester);
      expect(countArgb(b, card), lessThan(200),
          reason: 'the second pump still has the flow on it, so this comparison is '
              'not the comparison it claims to be');

      final diff = differentPixels(a, b);
      final total = screen.width * screen.height;
      debugPrint('  A vs B: $diff of $total pixels differ '
          '(${(100 * diff / total).toStringAsFixed(1)}%)');

      expect(diff / total, greaterThan(0.02),
          reason: 'the cleared-install screen and the returning-user screen agree on '
              '${(100 * (1 - diff / total)).toStringAsFixed(1)}% of their pixels — the '
              'screen with the first-run flow on it looks like the screen without it, '
              'which is the report being checked');
    });
  });

  group('reaching it again', () {
    testWidgets('the app bar offers it, including in landscape', (tester) async {
      // A first-run flow the user cannot re-open is a trap the moment they want to
      // change their mind about the sync mode — the one answer the flow records, so
      // this button is the only route back to it.
      //
      // Landscape (914x411) is the case this project has already broken twice: the
      // shell's app bar holds the title, the firmware badge and the build stamp, and
      // the title row once wanted 352dp inside a 283dp box. Every added action
      // competes for what is left, so the overflow assertion runs at both sizes — and
      // the button is looked for at both, because hiding the guide on a wide screen is
      // exactly the mistake that makes a control unreachable where it is most useful.
      for (final size in const [Size(411, 727), Size(914, 411)]) {
        await pumpShell(tester, size, showOnboarding: false);

        final button = find.byKey(const ValueKey<String>('btn-first-run-guide'));
        expect(button, findsOneWidget,
            reason: 'no way back into the flow at $size');
        expect(tester.takeException(), isNull,
            reason: 'the app bar overflowed at $size once the action was added');

        await tester.tap(button);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        expect(tester.takeException(), isNull);
        expect(find.byKey(const ValueKey<String>('first-run-flow')),
            findsOneWidget,
            reason: 'the button pushed nothing at $size');

        // Close it, so the next size starts from a clean route stack rather than
        // tapping through the one still on screen — which is what the first version
        // did, and it reported the *disabled* button behind the route as a miss.
        await tester.tap(find.byKey(const ValueKey<String>('btn-onboarding-exit')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byKey(const ValueKey<String>('first-run-flow')), findsNothing,
            reason: 'the guide could not be closed at $size');
      }
    });
  });
}
