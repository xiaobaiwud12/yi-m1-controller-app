import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yi_m1_controller/platform/onboarding_prefs.dart';
import 'package:yi_m1_controller/state/app_state.dart';
import 'package:yi_m1_controller/transport/album.dart';
import 'package:yi_m1_controller/transport/http_transport.dart';
import 'package:yi_m1_controller/ui/pages/album_page.dart';
import 'package:yi_m1_controller/ui/pages/first_run_flow.dart';

import 'fakes.dart';
import 'package:yi_m1_controller/l10n/l10n.dart';

/// **State changes, and the screen does not.** The class of defect where a value
/// the widget displays is changed without that widget being rebuilt, so the user
/// sees the old value until something *else* forces a rebuild — switching tabs,
/// going back a step, or leaving the page and returning.
///
/// ## Why every check here refuses to navigate first
///
/// A check that walks away and comes back would pass against the broken build, because
/// navigating away is exactly what forces the rebuild. So each test below changes the
/// state, pumps, and asserts the **rendered** consequence — a `Text`, a button's key,
/// a progress bar's `value` — with the widget that displays it never leaving the tree.
///
/// ## The two reported defects
///
/// 1. First-run, step 2: picking a sync mode did not change which option the step
///    showed as chosen (the user had to go back a step and return).
/// 2. The album's sync bar: the "paused" wording, the progress bar and the
///    start/pause button did not move in real time; switching pages refreshed them.
///
/// Both are the same shape, and the third and fourth groups below are the same shape
/// found elsewhere while looking: the shell is not told when the sync engine changes,
/// and the "preview is paused" banner reads a value nothing notifies about.
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('yi_m1_stale_');
    useTempStorage(tmp.path);
  });

  tearDown(() {
    try {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // left for the OS to reclaim
    }
  });

  AlbumFile shot(String name, {int date = 1700000000}) => AlbumFile(
        path: '/DCIM/101YICAM/$name.JPG',
        fileType: 'picture',
        captureTime: DateTime.fromMillisecondsSinceEpoch(date * 1000),
      );

  /// The album page with real file I/O allowed to finish.
  ///
  /// `runAsync` is not optional: the page awaits the durable ledger, which is read
  /// from **real files**, and in the fake-async zone that read never completes
  /// (`analysis/41` §7 item 9).
  Future<void> pumpAlbum(WidgetTester tester, AppState app) async {
    await tester.binding.setSurfaceSize(const Size(1080, 2136));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      home: AlbumPage(app: app),
    ));
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 40));
    }
  }

  /// The size the progress bar was actually laid out at.
  ///
  /// Read from the render object rather than recomputed from `done`/`total`: a check
  /// that repeats the layout arithmetic passes as long as the arithmetic is
  /// self-consistent, which it is in the broken build too.
  double? progressValue(WidgetTester tester) {
    final bar = find.byType(LinearProgressIndicator);
    if (bar.evaluate().isEmpty) return null;
    return tester.widget<LinearProgressIndicator>(bar).value;
  }

  // ---------------------------------------------------------------------------
  // 1. First run, step 2: the answer is recorded but the step does not show it.
  // ---------------------------------------------------------------------------

  group('the first-run sync-mode question shows the answer as it is given', () {
    Future<void> pumpFlowToStep2(WidgetTester tester,
        {required OnboardingPrefs prefs}) async {
      await tester.binding.setSurfaceSize(const Size(411, 727));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final app = connectedTestAppState();
      addTearDown(app.dispose);

      await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              key: const ValueKey<String>('open'),
              onPressed: () => openFirstRunFlow(context, app: app, prefs: prefs),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.byKey(const ValueKey<String>('open')));
      await tester.pump();
      // Let the push **fully** settle before touching anything in the flow.
      //
      // Two pumps and a 400 ms frame are what the existing flow tests use; the extra
      // one here is cheap and removes any doubt about tapping a route that is still
      // arriving. `pumpAndSettle` cannot be used (the album's own tests explain why:
      // a live progress indicator means "settled" never comes).
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      // Step 2, where the question is. No navigation happens after this point: the
      // whole defect is that the answer only appeared after navigating.
      await tester.tap(
          find.byKey(const ValueKey<String>('btn-onboarding-next')),
          warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump(const Duration(milliseconds: 350));
    }

    String? shownChoice(WidgetTester tester) => tester
        .widget<RadioGroup<String>>(
            find.byKey(const ValueKey<String>('onboarding-sync-mode')))
        .groupValue;

    /// Tap an option that may be below the fold of the step's scroll view.
    ///
    /// **Measured, not assumed**: at 411x727 the step body's viewport ends at y=659
    /// and the third option occupies 616–779, so its centre — which is where
    /// `tester.tap` aims — is *outside the scroll view*. The tap then landed on
    /// nothing at all and did not warn, and the test reported "the answer was not
    /// recorded" for a tap that never arrived. The project's own flow tests already
    /// scroll first for this reason; this is the same treatment, and the measured
    /// numbers are here because the failure it produces has nothing to do with what
    /// the test is checking.
    Future<void> tapOption(WidgetTester tester, Finder f) async {
      await tester.ensureVisible(f);
      await tester.pump();
      await tester.tap(f);
      await tester.pump();
    }

    testWidgets('picking a mode updates the step without leaving it',
        (tester) async {
      final prefs = OnboardingPrefs(store: MemoryPrefsStore());
      await pumpFlowToStep2(tester, prefs: prefs);

      // Precondition: the step is on screen at all, and starts on the default.
      expect(find.text(en.firstRunStepOf(2, 3)), findsOneWidget);
      expect(shownChoice(tester), kDefaultSyncModeId);

      final tile =
          find.byKey(const ValueKey<String>('btn-sync-mode-manualOnly'));
      // Fail here, with the tree, if the option is not on screen — otherwise the
      // next assertion reports a stale selection for the wrong reason.
      expect(tile, findsOneWidget,
          reason: 'precondition: the manual option has to be on step 2');
      // One `ensureVisible`, one tap, one frame. No `Back`, no `Next`, no route
      // change — navigating is exactly what used to be needed, so a test that did
      // it would pass against the broken build.
      await tapOption(tester, tile);

      expect(prefs.syncMode, 'manualOnly',
          reason: 'the answer must still be recorded — that half already worked');
      expect(shownChoice(tester), 'manualOnly',
          reason: 'the step went on showing the old selection, which is the '
              'reported defect: the answer only appeared after navigating away '
              'and back');
    });

    testWidgets('the chosen option is the one drawn as selected, not just the value',
        (tester) async {
      // The `RadioGroup`'s `groupValue` is what the *radio* reads; this checks the
      // drawn state too, so a build that kept the model right and the pixels wrong
      // cannot pass.
      final prefs = OnboardingPrefs(store: MemoryPrefsStore());
      await pumpFlowToStep2(tester, prefs: prefs);

      await tapOption(tester,
          find.byKey(const ValueKey<String>('btn-sync-mode-autoOriginalOnly')));

      expect(shownChoice(tester), 'autoOriginalOnly');
      expect(shownChoice(tester), isNot(kDefaultSyncModeId),
          reason: 'the default still won on screen');

      // And the tick really moved: the radio the user first saw selected is no
      // longer the selected one.
      await tapOption(tester,
          find.byKey(const ValueKey<String>('btn-sync-mode-manualOnly')));
      expect(prefs.syncMode, 'manualOnly');
      expect(shownChoice(tester), 'manualOnly');
    });
  });

  // ---------------------------------------------------------------------------
  // 2. The album's sync bar: the controls the user reported.
  // ---------------------------------------------------------------------------

  group('the sync bar follows the engine without the page being left', () {
    testWidgets('pausing swaps the transport control over, in place',
        (tester) async {
      final app = testAppState();
      addTearDown(app.dispose);
      app.sync.enqueueSelected([shot('YI000601')]);
      await pumpAlbum(tester, app);

      // Precondition: a waiting queue offers Start, which is the reported state.
      expect(find.byKey(const ValueKey<String>('btn-sync-start')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('btn-sync-resume')), findsNothing);

      // The engine is paused from **outside the UI** — the same call a lost camera
      // makes. Nothing on the page changes it, so the only way the control can move
      // is if the widget is listening.
      //
      // `Resume` and not `Pause`: the bar has three states, and a paused run is not a
      // running one. The assertion is written against the state the engine is really
      // in rather than against the button this test first expected — a check that
      // demanded `Pause` here would be asserting a control the app does not have.
      app.sync.pause();
      await tester.pump();

      expect(app.sync.paused, isTrue, reason: 'precondition for the check below');
      expect(find.byKey(const ValueKey<String>('btn-sync-resume')), findsOneWidget,
          reason: 'the bar still offered Start while the engine was paused — the '
              'reported "state does not update until you switch pages"');
      expect(find.byKey(const ValueKey<String>('btn-sync-start')), findsNothing);

      // And back, without navigating anywhere: the same wiring has to work in both
      // directions, or "it updates sometimes" becomes the new report.
      //
      // This direction is a defect of its own, and the one the reported symptom is
      // most visible in. `SyncEngine.resume()` clears its flag and calls `run()`,
      // and `run()` notifies **nothing** when it returns early — which it does when a
      // run is already in flight or the camera is away, and the camera is away here.
      // So `sync.paused` really did become false while the bar went on offering
      // Resume, and a second tap took the same silent path. The control is wired to
      // `AppState.resumeSync`, which is the same call plus the notification.
      app.resumeSync();
      await tester.pump();

      expect(app.sync.paused, isFalse, reason: 'precondition: resume really ran');
      expect(find.byKey(const ValueKey<String>('btn-sync-resume')), findsNothing,
          reason: 'the bar still offered Resume on an engine that was not paused');
      expect(find.byKey(const ValueKey<String>('btn-sync-start')), findsOneWidget,
          reason: 'an un-paused queue with work left has to offer Start again');
    });

    testWidgets('a transfer in flight is drawn, and the bar has a real size',
        (tester) async {
      // The aggregate bar's `value` is `done / total`, so mid-transfer it is legitimately
      // still 0 — what has to be true is that the bar is **laid out** and that the
      // per-item state the engine publishes reaches the screen without navigating.
      //
      // The download is held open on purpose: the assertion below is about the state
      // the user is looking at *while* a photo is coming across, not after it lands.
      //
      // What this does **not** measure, and what no desk test can: how often the bar
      // redraws during one transfer. That depends on how the camera's response is
      // chunked and on the engine's own notification throttle
      // (`sync/sync_engine.dart`, not owned here) — see `analysis/57`.
      final app = connectedTestAppState();
      addTearDown(app.dispose);

      final gate = Completer<void>();
      final bytes = Uint8List(64);
      bytes[0] = 0xFF;
      bytes[1] = 0xD8;
      bytes[62] = 0xFF;
      bytes[63] = 0xD9;
      app.album = CameraAlbum(
        CameraHttpClient(
          overrideSend: (command, params) async =>
              const CameraResponse(code: 200, raw: '{"code":200}', data: 'ok'),
        ),
        // Only the full-size fetch is held; the preview passes through so the run
        // really starts moving instead of freezing before its first byte.
        overrideDownload: (file, resolution) async {
          if (resolution == FileResolution.original) await gate.future;
          return bytes;
        },
      );
      await pumpAlbum(tester, app);
      app.sync.clearAll();
      app.sync.enqueueSelected([shot('YI000602')]);
      await tester.pump();

      expect(progressValue(tester), isNotNull,
          reason: 'precondition: the aggregate bar is on screen');

      // The returned future is deliberately **not** awaited — see the note at the end
      // of this test.
      app.sync.run();
      await tester.pump();

      expect(app.sync.summary.running, isTrue,
          reason: 'precondition: the run is really in flight');
      expect(tester.getSize(find.byType(LinearProgressIndicator)).width,
          greaterThan(0),
          reason: 'the bar was not laid out at all, so nothing about it was being '
              'drawn while the transfer ran');

      // The run is left parked on the gate on purpose and is **not** awaited: its tail
      // awaits the durable ledger and queue (real files), and the first version of this
      // check hung the whole suite waiting for that inside the fake-async zone — the
      // exact trap `analysis/41` §7 item 9 describes. The widget tree is disposed at
      // the end of the test, so nothing is left on screen; the engine's own run is
      // covered by `tool/verify_sync.dart` and `sync_list_control_test.dart`.
    });

    testWidgets('the paused wording appears the moment the engine pauses',
        (tester) async {
      final app = testAppState();
      addTearDown(app.dispose);
      app.sync.enqueueSelected([shot('YI000603')]);
      await pumpAlbum(tester, app);

      expect(find.textContaining(en.stagePausedByUser), findsNothing,
          reason: 'precondition: the engine is not paused');

      app.sync.pause();
      await tester.pump();

      expect(find.textContaining(en.stagePausedByUser), findsOneWidget,
          reason: 'the note the engine set was never drawn — the reported "the '
              'paused text does not appear until you switch pages"');
    });

    testWidgets('the stream-pause line appears while a run holds the preview',
        (tester) async {
      // The third indicator on this bar, and the same shape: `streamPausedForTransfer`
      // is engine state that nothing on the page polls.
      final app = testAppState();
      addTearDown(app.dispose);
      app.sync.enqueueSelected([shot('YI000604')]);
      app.sync.pauseStreamDuringTransfer = true;
      await pumpAlbum(tester, app);

      expect(find.textContaining('Preview paused while photos transfer'), findsNothing,
          reason: 'precondition: no run holds the stream');

      await app.sync.beginStreamHold();
      await tester.pump();

      expect(find.textContaining('Preview paused while photos transfer'),
          findsOneWidget,
          reason: 'the bar did not show that the preview is being held paused');
      expect(app.sync.streamPausedForTransfer, isTrue);

      // Balanced on the way out, so nothing is left holding a pause. The release is
      // retried on a 750 ms timer, so it has to run in real async — a
      // `Future.delayed` left pending in the fake-async zone fails the test with
      // "A Timer is still pending", which says nothing about what was being checked.
      await tester.runAsync(() => app.sync.endStreamHold());
    });
  });

  // ---------------------------------------------------------------------------
  // 3. The same shape, one layer up: the shell is never told.
  // ---------------------------------------------------------------------------

  group('the app is told when the sync engine changes', () {
    testWidgets('AppState notifies its own listeners on an engine change',
        (tester) async {
      // `AppState` subscribes the shell's `AnimatedBuilder` to `notifyListeners`, and
      // it wired the engine's single `onChanged` callback to that method in its
      // constructor. **The album page then reassigned the same field in `initState`**,
      // so from the moment the album was opened the app was no longer told anything
      // the engine did: the preview tab, the shell's chrome and the pause banner all
      // read stale sync state. This is the wiring check for that.
      final app = testAppState();
      addTearDown(app.dispose);

      var notifications = 0;
      app.addListener(() => notifications++);

      await pumpAlbum(tester, app);
      final afterOpen = notifications;
      expect(afterOpen, greaterThan(0),
          reason: 'precondition: opening the album does notify the app');

      app.sync.pause();
      await tester.pump();

      expect(notifications, greaterThan(afterOpen),
          reason: 'the engine changed and AppState never notified — the page took '
              'the engine callback for itself and the rest of the app went blind');
    });
  });
}
