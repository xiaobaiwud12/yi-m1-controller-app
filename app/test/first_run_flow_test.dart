import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yi_m1_controller/platform/onboarding_prefs.dart';
import 'package:yi_m1_controller/state/app_state.dart';
import 'package:yi_m1_controller/sync/asset_sink_contract.dart';
import 'package:yi_m1_controller/sync/sync_ledger.dart';
import 'package:yi_m1_controller/sync/ui_prefs.dart';
import 'package:yi_m1_controller/ui/pages/first_run_flow.dart';

import 'fakes.dart';
import 'silent_ble.dart';
import 'package:yi_m1_controller/l10n/l10n.dart';

/// The first-run flow itself: what it asks, what it records, and what it refuses
/// to pretend about.
///
/// ## Why the assertions are shaped the way they are
///
/// The flow is deliberately built out of things that can be **counted** rather than
/// things that can be read: three steps, one question with three answers, a named
/// control for each action. A test that asserted on prose would pass a build that
/// quietly grew a fourth step or dropped the pairing step, which is the failure
/// mode of every onboarding screen ever shipped — it grows until people dismiss it
/// without reading.
///
/// The pairing step gets its own group because of a specific temptation: a step
/// that shows a spinner while a human walks over to the camera and presses a button
/// is the app lying about progress. [LinkStatus] already distinguishes
/// "establishing" from "awaiting a human", so the check is that the screen renders
/// the app's own sentence for the state rather than an animation of its own.
void main() {
  late OnboardingPrefs prefs;

  setUp(() {
    prefs = OnboardingPrefs(store: MemorySyncStore());
  });

  /// Pump the flow the way the app reaches it: pushed as a route.
  ///
  /// `runAsync` is not needed here. An [AppState] built on the test seam does no
  /// disk I/O of its own, and this file never touches a file — the persistence
  /// cases live in `onboarding_prefs_test.dart`, where the real store is the point.
  Future<AppState> pumpFlow(
    WidgetTester tester, {
    Size size = const Size(411, 727),
    FirstRunEntry entry = FirstRunEntry.firstRun,
    AppState? app,
    VoidCallback? onFinished,
    VoidCallback? onExited,
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final state = app ?? connectedTestAppState();
    // Only when this helper built it. A caller that passes its own app disposes it
    // itself, and disposing twice throws "A ValueNotifier was used after being
    // disposed" from `AppState.dispose` — reported as a failure of whichever test
    // happened to run it last, saying nothing about the app.
    if (app == null) addTearDown(state.dispose);

    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            key: const ValueKey<String>('test-open-flow'),
            onPressed: () => openFirstRunFlow(
              context,
              app: state,
              prefs: prefs,
              entry: entry,
              onFinished: onFinished,
              onExited: onExited,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.byKey(const ValueKey<String>('test-open-flow')));
    await tester.pump();
    // A second pump lets the route transition finish, so the finders below are
    // looking at a settled page rather than at one sliding in.
    await tester.pump(const Duration(milliseconds: 400));
    return state;
  }

  Finder next() => find.byKey(const ValueKey<String>('btn-onboarding-next'));
  Finder back() => find.byKey(const ValueKey<String>('btn-onboarding-back'));
  Finder exit() => find.byKey(const ValueKey<String>('btn-onboarding-exit'));

  /// The constant half of the app's own pairing instruction.
  ///
  /// The refId varies per attempt, so the needle is the ARB's sentence cut before
  /// `(refId` rather than a fragment re-typed here.
  final pressAllow = en.linkPressAllow('0').split('(refId').first.trim();

  /// Tap a control and let the step change settle.
  ///
  /// `warnIfMissed: false` because these tests are about **what the flow does**, not
  /// about how far down a step an option happens to sit; a control that is below the
  /// fold in a landscape window is a layout question, and the layout is asserted
  /// separately by the size cases at the bottom of this file. The tap itself has to
  /// land, and every test here asserts the consequence of the tap, so a tap that
  /// silently did nothing fails the test that follows it.
  ///
  /// Deliberately **no** scrolling here. An earlier version scrolled the step body
  /// first, which moved the page and left assertions about text further down looking
  /// at a different part of the scroll view than the one they were written against.
  Future<void> tapThrough(WidgetTester tester, Finder f) async {
    await tester.tap(f, warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 350));
  }

  /// Tap an option inside a scrolling step, bringing it into view first.
  Future<void> tapInStep(WidgetTester tester, Finder f) async {
    final scrollable = find.descendant(
      of: find.byType(SingleChildScrollView),
      matching: find.byType(Scrollable),
    );
    if (scrollable.evaluate().isNotEmpty) {
      await tester.ensureVisible(f);
      await tester.pump();
    }
    await tester.tap(f, warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 350));
  }

  testWidgets('it is three steps, and each one says what it is', (tester) async {
    await pumpFlow(tester);

    // Exactly three, asserted through the step indicator: a fourth step added
    // later fails here rather than silently lengthening the flow.
    expect(find.text(en.firstRunStepOf(1, 3)), findsOneWidget);
    expect(find.text(en.firstRunStepWhatItDoes), findsOneWidget);

    await tapThrough(tester, next());
    // Exactly one step mounted, which is what the `PageView` version got wrong: it
    // advanced the counter and left step 1's body on screen, so the flow told the
    // user they were on step 2 while showing them step 1.
    expect(find.byKey(const ValueKey<String>('onboarding-step-1')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('onboarding-step-0')), findsNothing);
    expect(find.text(en.firstRunStepOf(2, 3)), findsOneWidget);
    expect(find.text(en.firstRunStepWhatItDoes), findsNothing);
    expect(find.text(en.firstRunStepHowPhotosCome), findsOneWidget);
    expect(find.text(en.firstRunStepHowPhotosCome), findsOneWidget);

    await tapThrough(tester, next());
    expect(find.text(en.firstRunStepOf(3, 3)), findsOneWidget);
    expect(find.text(en.firstRunStepPair), findsOneWidget);

    expect(tester.takeException(), isNull);
    // And there is no step 4: the forward control is gone on the last step.
    expect(next(), findsNothing);
  });

  testWidgets('step 1 states the two things that surprise people',
      (tester) async {
    // Not decoration. "One client at a time" is why a paired PC takes the phone's
    // place and why Windows then reports a PSK mismatch that is really a refused
    // station (analysis/46 §9.1.1); the camera-body confirmation is why pairing
    // looks frozen for ten seconds. Both were expensive to learn.
    await pumpFlow(tester);
    // Both cards' own sentences, looked up rather than re-typed: each widget draws its
    // ARB string whole, so the whole sentence is the honest needle.
    expect(find.textContaining(en.firstRunWifiOneDeviceTitle), findsOneWidget);
    expect(find.textContaining(en.firstRunAcceptOnCameraDetail), findsOneWidget);
  });

  testWidgets('step 2 asks once and records the answer', (tester) async {
    await pumpFlow(tester);
    await tapThrough(tester, next());

    // Three modes, matching the engine's own enum, each pressable by key.
    for (final id in kSyncModeIds) {
      expect(find.byKey(ValueKey<String>('btn-sync-mode-$id')), findsOneWidget,
          reason: 'no control for $id, so that mode cannot be chosen here');
    }

    await tapInStep(
        tester, find.byKey(const ValueKey<String>('btn-sync-mode-manualOnly')));
    expect(prefs.syncMode, 'manualOnly',
        reason: 'the answer was not recorded, so the question is theatre');
    expect(prefs.askedSyncMode, isTrue);
    expect(prefs.onboardingDone, isFalse,
        reason: 'answering one step is not finishing the flow');
  });

  testWidgets('step 2 shows the trade-off, not just the names', (tester) async {
    await pumpFlow(tester);
    await tapThrough(tester, next());
    // The trade-off is the whole reason to ask: a small picture that appears in
    // seconds versus several megabytes over a slow radio. A screen that listed three
    // labels would be a question the user cannot answer.
    expect(find.textContaining(en.firstRunSyncAutoPreviewBody), findsWidgets);
    expect(find.textContaining(en.firstRunSyncAutoOriginalTitle), findsWidgets);
    expect(find.textContaining(en.firstRunSyncAutoOriginalBody), findsWidgets);
    // Verbatim from the manual option: "Nothing moves until you choose it." The
    // camel case is deliberate — the phrase opens a sentence, and a lower-case
    // substring search for it finds nothing while the sentence sits there on screen.
    // That mismatch reads as "the option is missing" when it is the test that is
    // wrong, so the pattern is case-insensitive rather than rewritten to match. The
    // needle is the ARB entry, never a fragment re-typed here.
    expect(
        find.textContaining(RegExp(RegExp.escape(en.firstRunSyncManualBody),
            caseSensitive: false)),
        findsWidgets);
    // All three options are present, counted by widget: a step that showed one
    // option and a paragraph would otherwise pass every assertion above.
    expect(find.byType(RadioListTile<String>), findsNWidgets(kSyncModeChoices.length));
  });

  testWidgets('step 3 shows the real pairing state and does not fake progress',
      (tester) async {
    // The `awaitingUserConfirm` state, reached the way the app reaches it: a BLE
    // transport that finds the camera and reads its identity, and a pairing
    // characteristic that never answers — so the state machine stops exactly where
    // a human is required and nowhere else.
    final app = AppState(ble: SilentBleTransport(), sink: NullAssetSink());
    addTearDown(app.dispose);

    await pumpFlow(tester, app: app);
    await tapThrough(tester, next());
    await tapThrough(tester, next());

    final start = find.byKey(const ValueKey<String>('btn-onboarding-pair'));
    expect(start, findsOneWidget);
    await tapThrough(tester, start);

    // The app's own sentence for this state, not the flow's paraphrase: it carries
    // the refId and the word the camera's own screen uses.
    expect(find.textContaining(pressAllow), findsOneWidget,
        reason: 'the flow did not surface the state the app is actually in');
    expect(find.textContaining(en.firstRunPairAccept), findsOneWidget,
        reason: 'the waiting-on-a-human step must say so in words');

    // And it must NOT claim progress it cannot observe: a spinner here would have
    // the app implying it is working while the next move belongs to the user.
    expect(find.byType(CircularProgressIndicator), findsNothing,
        reason: 'a spinner while waiting for a human is invented progress');
    expect(find.byType(LinearProgressIndicator), findsNothing);

    // Let the abandoned sequence run out **inside** the test. The pairing wait is
    // 25 s and the credential read retries every 2 s, so this is the one place a
    // `Future.delayed` is left outstanding — and `flutter_test` checks for pending
    // timers *before* its teardown callbacks run, so a test that walks away here is
    // failed with "A Timer is still pending", which says nothing about the screen
    // being checked.
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(seconds: 2));
    }
    // The sequence ends by giving up, which is the honest outcome with no camera
    // there to confirm — and it proves the timers really did run out rather than the
    // pump having skipped them.
    expect(app.link.stage.name, 'failed');
  });

  testWidgets('nothing is in flight before the user asks to pair',
      (tester) async {
    // The negative control for the check above: the same step, the same finders,
    // before the button is pressed. If a spinner were painted unconditionally, the
    // previous test would pass for the wrong reason.
    final app = AppState(ble: SilentBleTransport(), sink: NullAssetSink());
    addTearDown(app.dispose);

    await pumpFlow(tester, app: app);
    await tapThrough(tester, next());
    await tapThrough(tester, next());
    expect(find.textContaining(pressAllow), findsNothing);
    expect(app.link.stage.name, 'idle');
  });

  testWidgets('a saved answer is shown when the flow is re-opened',
      (tester) async {
    // Re-opening it is how the user changes their mind, so it has to show what
    // they chose rather than resetting to the default and silently overwriting it
    // on the next press of Next.
    final store = MemorySyncStore();
    final saved = OnboardingPrefs(store: store)
      ..setSyncMode('autoOriginalOnly')
      ..setOnboardingDone(true);
    await saved.save();
    prefs = OnboardingPrefs(store: store);
    await prefs.load();

    await pumpFlow(tester, entry: FirstRunEntry.revisit);
    await tapThrough(tester, next());

    final group = tester.widget<RadioGroup<String>>(
      find.byKey(const ValueKey<String>('onboarding-sync-mode')),
    );
    expect(group.groupValue, 'autoOriginalOnly',
        reason: 'the recorded answer was not reflected back to the user');
  });

  testWidgets('a revisit can be closed without touching anything',
      (tester) async {
    // The flow must never be a wall, and "short, skippable" applies doubly when
    // the user only came back to look.
    var exited = 0;
    await pumpFlow(tester,
        entry: FirstRunEntry.revisit, onExited: () => exited++);
    expect(find.text(en.firstRunTitle), findsOneWidget);

    await tester.tap(exit());
    // `maybePop` is asynchronous: the pop is registered on a microtask, so it needs
    // a frame of its own to start and then a full transition to finish. Pumping once
    // for 400 ms left the route in the tree, which reads as "Close did nothing" when
    // it is the test that stopped watching too early.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));

    expect(exited, 1, reason: 'closing it did not report back to the caller');
    expect(find.byKey(const ValueKey<String>('first-run-flow')), findsNothing);
  });

  testWidgets('a first run can be skipped from step 1', (tester) async {
    // "Short, skippable, never a wall": the way out is offered before anything has
    // been asked, and it is recorded so the flow cannot reappear.
    var finished = 0;
    await pumpFlow(tester, onFinished: () => finished++);

    expect(find.text(en.firstRunSkip), findsOneWidget);
    await tester.tap(exit());
    await tester.pump(const Duration(milliseconds: 400));

    expect(finished, 1);
    expect(prefs.onboardingDone, isTrue,
        reason: 'skipping must be recorded, or the flow returns every launch');
    expect(prefs.syncMode, isNotNull,
        reason: 'skipping still leaves a usable mode rather than none');
  });

  testWidgets('back returns to an earlier step instead of leaving',
      (tester) async {
    await pumpFlow(tester);
    expect(back(), findsNothing, reason: 'step 1 has nothing to go back to');

    await tapThrough(tester, next());
    expect(find.text(en.firstRunStepOf(2, 3)), findsOneWidget);
    expect(back(), findsOneWidget);

    await tapThrough(tester, back());
    expect(find.text(en.firstRunStepOf(1, 3)), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('first-run-flow')), findsOneWidget,
        reason: 'going back left the flow');
  });

  for (final size in const [Size(411, 727), Size(914, 411), Size(320, 480)]) {
    testWidgets('every step fits at ${size.width}x${size.height}',
        (tester) async {
      // Landscape is the case this project keeps breaking: 914x411 with a body
      // about a third shorter than the screen. An overflow is an error in Flutter,
      // not a cosmetic warning, so it is asserted rather than eyeballed.
      await pumpFlow(tester, size: size);
      for (var i = 0; i < 3; i++) {
        final error = tester.takeException();
        if (error != null) {
          final detail = error is FlutterError
              ? error.diagnostics.map((d) => d.toString()).join('\n')
              : '$error';
          fail('step ${i + 1} failed layout at $size:\n$detail');
        }
        if (i < 2) await tapThrough(tester, next());
      }
    });
  }

  testWidgets('a landscape window shows the whole step without scrolling',
      (tester) async {
    // **This is the check that a screenshot found and the overflow check could not.**
    // At 914x411 the emulator showed the pairing status card cut through the middle
    // of a sentence and the explanation entirely below the fold. Nothing overflowed —
    // the body is a scroll view, so the content was simply out of sight — which is
    // exactly the failure a layout-error assertion is blind to.
    //
    // The measurement is the scroll view's own extent against the box it was given:
    // if the content is taller than the viewport, some of this step cannot be read
    // without scrolling, and the step is longer than the window it is shown in.
    final app = testAppState();
    addTearDown(app.dispose);
    await pumpFlow(tester, size: const Size(914, 411), app: app);
    await tapThrough(tester, next());
    await tapThrough(tester, next());

    expect(find.text(en.firstRunStepOf(3, 3)), findsOneWidget,
        reason: 'the landscape case must still be the pairing step');

    final scrollable = find.descendant(
      of: find.byType(SingleChildScrollView),
      matching: find.byType(Scrollable),
    );
    expect(scrollable, findsOneWidget);
    final position = tester.state<ScrollableState>(scrollable).position;
    expect(
      position.maxScrollExtent,
      lessThanOrEqualTo(0.5),
      reason: 'the pairing step needs ${position.maxScrollExtent}px of scrolling in a '
          '914x411 window, so part of it is off screen — the state the emulator showed',
    );
  });

  testWidgets('landscape puts the status beside the checklist, not under it',
      (tester) async {
    // The specific decision the fix took, asserted so a later tidy-up cannot undo it
    // silently: in a wide, short window the four-step checklist and the status card
    // share a row, because width is what that window has spare.
    //
    // A **disconnected** app, so the status card is showing the state a first-time
    // user is actually in. The connected fixture would put "Connected. The Camera tab
    // now has…" there — also correct, but it measures the layout against a sentence
    // this screen will hardly ever show.
    final app = testAppState();
    addTearDown(app.dispose);
    await pumpFlow(tester, size: const Size(914, 411), app: app);
    await tapThrough(tester, next());
    await tapThrough(tester, next());

    final checklist = tester.getRect(find.text(en.firstRunPairFind));
    final status = tester.getRect(find.textContaining(en.firstRunNotConnected));
    expect(status.left, greaterThan(checklist.right - 1),
        reason: 'the status card is not to the right of the checklist in landscape');
    expect((status.center.dy - checklist.center.dy).abs(), lessThan(120),
        reason: 'the two blocks are not side by side');
  });

  // ---------------------------------------------------------- the retry
  //
  // ## What this group is for
  //
  // Reported from the phone: *"in the first-run flow, occasionally I press Accept once
  // and the camera's Bluetooth does not connect; it takes a second pairing attempt to
  // connect and get the Wi-Fi password. Before there was a first-run flow I could just
  // press retry several times. Inside the first run it reports an error and the only
  // way is to leave the flow and start again."*
  //
  // That is `AGENTS.md` §7.1's shape — a feature that made something the user could do
  // **impossible** — and the two halves of it are different things. A pairing attempt
  // failing and needing a second one is the camera's behaviour (`analysis/46`, the
  // ten-second Accept window); having no way back in is the flow's.
  //
  // So these checks are about the **way back in**: that it exists in the failed state,
  // that pressing it starts another attempt, that it does not leave the flow, and that
  // it cannot overlap an attempt that is still running.
  group('a failed pairing can be retried from inside the flow', () {
    ({AppState app, CountingBleTransport ble}) failingApp() {
      final ble = CountingBleTransport();
      final app = AppState(
        ble: ble,
        sink: NullAssetSink(),
        // Memory-backed, so the launch path has no platform-channel gap under it —
        // the same reason `connectedTestAppState` injects both (see `fakes.dart`).
        testOnboardingPrefs: OnboardingPrefs(store: MemoryPrefsStore()),
        testUiPrefs: UiPrefs(store: MemoryPrefsStore()),
      );
      addTearDown(app.dispose);
      return (app: app, ble: ble);
    }

    Finder pair() => find.byKey(const ValueKey<String>('btn-onboarding-pair'));

    /// Walk to the pairing step, which is the only step the pairing control is on.
    Future<void> walkToPairingStep(WidgetTester tester) async {
      await tapThrough(tester, next());
      await tapThrough(tester, next());
    }

    /// Let the attempt settle.
    ///
    /// The sequence is `store.load()` → `ble.findCamera()` → give up, so a few frames
    /// is all it needs — but the pump is what makes it happen at all, and asserting the
    /// outcome below is what proves it did.
    Future<void> settleAttempt(WidgetTester tester) async {
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    testWidgets('the step keeps a live retry, and it starts another attempt without '
        'leaving the flow', (tester) async {
      final (:app, :ble) = failingApp();
      await pumpFlow(tester, app: app);

      // Preconditions: nothing has been attempted yet, and on the pairing step the
      // control exists and is the way in.
      expect(ble.searches, 0, reason: 'precondition: something is already in flight');
      await walkToPairingStep(tester);
      expect(pair(), findsOneWidget);
      expect(tester.widget<FilledButton>(pair()).onPressed, isNotNull,
          reason: 'precondition: the first attempt could not be started at all');

      await tapThrough(tester, pair());
      await settleAttempt(tester);

      expect(ble.searches, 1, reason: 'the attempt never reached the transport');
      expect(app.link.stage.name, 'failed',
          reason: 'precondition: the fixture did not end the attempt in failure, so the '
              'state this check is about is not the one on screen');

      // ## The defect
      //
      // Before the fix the control was still there but dead: `pairingStarted` latched
      // it off for the life of the page, so a failed attempt inside the flow could not
      // be retried at all.
      expect(pair(), findsOneWidget,
          reason: 'the pairing step lost its control when the attempt failed');
      expect(tester.widget<FilledButton>(pair()).onPressed, isNotNull,
          reason: 'the pairing control is dead after a failed attempt, so the only way '
              'to try again is to leave the flow and start over — the reported defect');
      expect(find.text(en.firstRunPairTryAgain), findsOneWidget,
          reason: 'the control still reads "Start pairing", so nothing on screen tells '
              'the user it can be pressed again');
      expect(find.text(en.firstRunPairFailedHelp), findsOneWidget,
          reason: 'the failed state does not say what to do next');

      // **Reachable**, not merely present: inside the flow's own box, which is what
      // "the button must be reachable in the failed state" means. The footer is
      // deliberately outside the scrolling step body, so it cannot be scrolled away.
      final box = tester.getRect(find.byKey(const ValueKey<String>('first-run-flow')));
      expect(box.contains(tester.getRect(pair()).center), isTrue,
          reason: 'the retry is outside the flow window: ${tester.getRect(pair())} is '
              'not inside $box');

      // ## Using it starts another attempt — and stays put
      await tester.tap(pair());
      await tester.pump(const Duration(milliseconds: 350));

      expect(ble.searches, 2,
          reason: 'pressing the retry did not start a second pairing attempt');
      expect(find.byKey(const ValueKey<String>('first-run-flow')), findsOneWidget,
          reason: 'the retry left the flow, which is the thing it exists to avoid');
      expect(find.byKey(const ValueKey<String>('onboarding-step-2')), findsOneWidget,
          reason: 'the retry moved the flow off the pairing step');
      // The fixture fails again, so the state under test is the one it left — and the
      // control is live for a third attempt rather than being a one-shot.
      expect(app.link.stage.name, 'failed');
      expect(tester.widget<FilledButton>(pair()).onPressed, isNotNull,
          reason: 'the retry was good for one press only');
    });

    testWidgets('a second attempt cannot be started while one is on the wire',
        (tester) async {
      // The bound on the retry, asserted rather than argued: it is **not** a limit on
      // how many times the user may try — every attempt needs a person at the camera,
      // so the user is the rate limit. What it must never do is put two pairing
      // requests on a camera with one control path and one pairing slot
      // (`analysis/04`, `AGENTS.md` §5).
      final (:app, :ble) = failingApp();
      ble.pending = Completer<String?>();
      await pumpFlow(tester, app: app);
      await walkToPairingStep(tester);
      await tapThrough(tester, pair());
      await settleAttempt(tester);

      expect(ble.searches, 1, reason: 'precondition: no attempt started');
      expect(app.link.isBusy, isTrue,
          reason: 'precondition: the attempt is not in flight, so there is nothing to '
              'overlap');
      expect(tester.widget<FilledButton>(pair()).onPressed, isNull,
          reason: 'a second connect can be started while the first is still on the '
              'wire — on this camera that is the known wedge precondition');

      // The attempt ends, and the control comes back with it.
      ble.pending!.complete(null);
      await settleAttempt(tester);
      expect(app.link.stage.name, 'failed');
      expect(tester.widget<FilledButton>(pair()).onPressed, isNotNull,
          reason: 'the control did not come back when the attempt ended');
    });
  });
}

/// A BLE transport that never finds the camera, and counts how many times it was
/// asked.
///
/// One call to [findCamera] is one pairing attempt: it is the first thing
/// `CameraConnection.connect()` does, so an attempt that dies here fails in a few
/// frames instead of sitting through the 25-second pairing wait — which is the
/// difference between a check that can be read and one that is mostly `pump`.
///
/// [pending] is how "an attempt is on the wire" is held open on purpose: the retry
/// must not be able to overlap one, and that is only checkable against a search that
/// has not answered yet.
class CountingBleTransport extends FakeBleTransport {
  int searches = 0;
  Completer<String?>? pending;

  @override
  Future<String?> findCamera() {
    searches++;
    return pending?.future ?? Future<String?>.value(null);
  }
}
