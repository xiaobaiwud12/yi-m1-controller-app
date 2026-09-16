import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yi_m1_controller/state/app_state.dart';
import 'package:yi_m1_controller/ui/pages/album_page.dart';
import 'package:yi_m1_controller/ui/pages/live_view_page.dart';
import 'package:yi_m1_controller/ui/pages/video_page.dart';

import 'fakes.dart';
import 'package:yi_m1_controller/l10n/l10n.dart';

/// Widget smoke tests: do the screens actually build?
///
/// ## Why this file exists
///
/// Every other check in this repo reads code — `dart analyze` for types, the
/// `tool/verify_*.dart` scripts for pure logic, `audit_app_capabilities.py` for
/// reachability. **None of them executes a widget.** A malformed tree, an
/// assertion in a `build`, a `TabBar` without a controller, a `FittedBox` fed a
/// zero: all of those are invisible to a static check and all of them are a
/// crash or a blank screen on the device.
///
/// That gap was called out explicitly after the settings menu and the landscape
/// bands were reworked — the change was verified by reading the Flutter SDK
/// sources, not by running them. This is the cheapest way to close it: the app's
/// own screens, pumped at phone and landscape sizes, with no camera attached.
///
/// ## What it deliberately does not test
///
/// Live-view rendering with a real frame stream, camera communication, and
/// platform channels. Those need a device. What is asserted here is the weaker
/// but genuinely useful claim: **the screens build, at both orientations, without
/// throwing** — including the disconnected state the app launches into.
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('yi_m1_test_');
    useTempStorage(tmp.path);
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// A widget that proves each screen actually produced its own tree.
  ///
  /// Deliberately not `Scaffold`: the live-view page is a full-bleed `Stack`,
  /// because a `Scaffold` background behind a live preview is a grey border the
  /// user should never see. Asserting on `Scaffold` therefore tested an
  /// assumption about the design rather than the design itself — the first
  /// version of this file did exactly that and reported a false failure.
  final markers = <String, Finder>{
    'live view': find.byType(LiveViewPage),
    'album': find.byType(Scaffold),
    'video': find.byType(Scaffold),
  };

  /// Every screen, at a size that exercises one layout branch.
  Future<void> pumpAll(WidgetTester tester, Size size, String label) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final app = testAppState();
    addTearDown(app.dispose);

    for (final entry in <String, Widget Function()>{
      'live view': () => LiveViewPage(app: app),
      'album': () => AlbumPage(app: app),
      'video': () => VideoPage(app: app),
    }.entries) {
      await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
        home: entry.value(),
      ));
      // Two pumps: one to build, one to settle the first layout pass. `pumpAndSettle`
      // is not usable here because the live-view page runs a periodic ticker.
      await tester.pump(const Duration(milliseconds: 50));

      expect(
        tester.takeException(),
        isNull,
        reason: '${entry.key} threw while building at $label',
      );
      // A screen that renders nothing is a failure the exception check cannot
      // see: an empty `SizedBox.shrink()` at the root throws nothing either.
      expect(
        markers[entry.key]!,
        findsWidgets,
        reason: '${entry.key} rendered nothing recognisable at $label',
      );
    }
  }

  testWidgets('every screen builds in portrait', (tester) async {
    await pumpAll(tester, const Size(1080, 2136), 'portrait');
  });

  testWidgets('every screen builds in landscape', (tester) async {
    // The case the side-band rewrite is for. 20:9, which leaves ~160dp of band
    // per side at 4:3 — the geometry the layout checks pin numerically.
    await pumpAll(tester, const Size(2136, 1080), 'landscape');
  });

  testWidgets('landscape does not starve the picture for the bands',
      (tester) async {
    // The measured half of "landscape got worse". The side bands are paid for out
    // of the preview's width, so a band that reserves space for a column that does
    // not fill it is a picture that shrank for nothing — and that is invisible to
    // a screenshot-free test.
    //
    // This asserts on the rendered box rather than re-deriving the layout maths,
    // because the maths can be right while the tree lays out differently: the
    // first attempt at this used `Expanded(flex:)` values that added up to more
    // than the row, which silently shrank the middle child.
    const screen = Size(2136, 1080);
    await tester.binding.setSurfaceSize(screen);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final app = testAppState();
    addTearDown(app.dispose);

    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      home: LiveViewPage(app: app),
    ));
    await tester.pump(const Duration(milliseconds: 50));

    final preview = find.byKey(previewAreaKey);
    expect(preview, findsOneWidget);
    final size = tester.getSize(preview);

    // Two thirds of a 20:9 screen is the floor: a 4:3 frame flanked by two bands
    // is the design, and a 3:1 split of 2136 leaves 1424 for the picture. Below
    // this ratio the bands are claiming more than the picture, which is the
    // complaint.
    expect(
      size.width / screen.width,
      greaterThanOrEqualTo(0.6),
      reason: 'landscape preview is only ${size.width} of ${screen.width} wide',
    );
    expect(size.height, greaterThan(0),
        reason: 'landscape preview collapsed vertically');
  });

  testWidgets('every screen builds on a small phone', (tester) async {
    // Narrow enough that the bands cannot fit a control column, so the layout
    // falls back to overlaying them. That branch is only reached on a device
    // smaller than the one this was developed against.
    await pumpAll(tester, const Size(720, 1280), 'small');
  });

  testWidgets('the settings surface opens without throwing', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1080, 2136));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final app = testAppState();
    addTearDown(app.dispose);

    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      home: LiveViewPage(app: app),
    ));
    await tester.pump(const Duration(milliseconds: 50));

    // The settings toggle is the only route to the second level, and the menu is
    // where the collapsed groups live — a `TabBar` without a controller throws
    // here and nowhere else.
    final settingsButton = find.byIcon(Icons.tune);
    if (settingsButton.evaluate().isNotEmpty) {
      await tester.tap(settingsButton.first);
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.takeException(), isNull,
          reason: 'opening the settings surface threw');
    }
  });

  testWidgets('a disconnected AppState reports why the shutter is blocked',
      (tester) async {
    // Not a widget assertion, but it belongs with the screens: the shutter is
    // disabled on launch, and a disabled control with no stated reason reads as a
    // broken app. The string is the user-visible half of that decision.
    final app = testAppState();
    addTearDown(app.dispose);
    expect(app.shutterBlockedReason, isNotNull);
    expect(app.shutterBlockedReason, contains('Not connected'));
  });

  group('while connected', () {
    // The states the user has actually reported bugs in. They are all gated on
    // `link.isReady`, which needs a paired camera — and an Android emulator has no
    // Bluetooth adapter, so the real sequence cannot be shortened there. Injecting
    // the HTTP client reaches them in a plain widget test, which is what makes
    // "landscape squeezes the picture" and "the banner's buttons" **measurable**
    // instead of something argued from the layout code.

    Future<AppState> pumpConnected(WidgetTester tester, Size size) async {
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
      return app;
    }

    testWidgets('the connected link really is ready', (tester) async {
      // The precondition every other test in this group rests on. If the injection
      // silently stopped working, the assertions below would pass against the
      // *disconnected* layout instead — which is exactly the false confidence this
      // group exists to remove.
      final app = await pumpConnected(tester, const Size(1080, 2400));
      expect(app.link.isReady, isTrue, reason: app.link.message);
    });

    testWidgets('portrait keeps the picture and shows the camera readout',
        (tester) async {
      await pumpConnected(tester, const Size(1080, 2400));
      expect(tester.takeException(), isNull);
      final preview = tester.getSize(find.byKey(previewAreaKey));
      expect(preview.width / 1080, greaterThan(0.9),
          reason: 'portrait bands should be vertical, not horizontal');
    });

    testWidgets('landscape gives the picture the majority of the width',
        (tester) async {
      // The measured form of "landscape got worse". The side bands are paid for
      // out of the picture's width, so this asserts the picture still owns most of
      // the screen. A 4:3 frame on a 20:9 screen leaves ~160dp per side, which is
      // 2/3 of the width for the frame; below 0.6 the columns are claiming more
      // than the thing being composed.
      const w = 2136.0;
      await pumpConnected(tester, const Size(w, 1080));
      expect(tester.takeException(), isNull);

      final preview = tester.getSize(find.byKey(previewAreaKey));
      expect(preview.width / w, greaterThanOrEqualTo(0.6),
          reason: 'landscape picture is only ${preview.width} of $w wide');
      expect(preview.height, greaterThan(0));
    });

    testWidgets('landscape carries the camera readout and the shutter together',
        (tester) async {
      // Both side bands must actually hold something. An empty band is the failure
      // the fix was about: it costs the picture width and shows nothing.
      await pumpConnected(tester, const Size(2136, 1080));
      expect(tester.takeException(), isNull);
      expect(find.byIcon(Icons.photo_camera_outlined), findsWidgets);
      // The camera identity chip only renders in the band layout.
      expect(find.textContaining('M1'), findsWidgets);
    });

    testWidgets('there is exactly one navigation row', (tester) async {
      // The duplicate-nav defect, asserted against the thing that was actually
      // duplicated. The banded branch used to emit `nav` twice while the fallback
      // branch emitted it once, so it only ever appeared on a screen with room for
      // a bottom band — which is why it survived every static check.
      //
      // Counting the widget (via its key) rather than a label: an earlier version of
      // this test looked for the text "Capture" and failed on a *correct* build,
      // because the wording in that branch is "Settings". Counting the widget is the
      // precise statement of the bug and does not break when the labels change.
      for (final size in const [Size(1080, 2400), Size(2136, 1080)]) {
        await pumpConnected(tester, size);
        expect(
          tester.takeException(),
          isNull,
          reason: 'building at $size threw',
        );
        expect(
          find.byKey(bottomNavKey),
          findsOneWidget,
          reason: 'expected exactly one navigation row at $size',
        );
      }
    });
  });

  group('the paused-preview banner', () {
    // This banner sits over the middle of the picture while a transfer runs, so
    // getting it wrong is expensive: the device report was "the card cannot be
    // closed" and its only action made things worse by stopping the preview the
    // user was trying to get back. Neither is reachable in a headless test
    // through the real page — the banner needs a connected camera and a transfer
    // holding the stream — so it takes its dependencies as arguments and is
    // driven directly here.

    Future<void> pumpBanner(
      WidgetTester tester, {
      required VoidCallback onKeepRunning,
      required VoidCallback onStopPreview,
      String? reason,
    }) async {
      await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
        home: Scaffold(
          body: StreamPausedBanner(
            reason: reason,
            fps: 0,
            onKeepRunning: onKeepRunning,
            onStopPreview: onStopPreview,
          ),
        ),
      ));
      await tester.pump();
    }

    testWidgets('states the pause and shows zero fps', (tester) async {
      await pumpBanner(tester,
          onKeepRunning: () {}, onStopPreview: () {}, reason: 'Copying photos.');
      expect(find.text(en.livePreviewPausedForTransfer), findsOneWidget);
      expect(find.text('Copying photos.'), findsOneWidget);
      // Zero is the honest reading while held, not a spinner over a still frame.
      expect(find.text(en.liveFps('0')), findsOneWidget);
    });

    testWidgets('falls back to its own explanation with no reason supplied',
        (tester) async {
      await pumpBanner(tester, onKeepRunning: () {}, onStopPreview: () {});
      // Verbatim from the fallback string: "The preview shares one Wi-Fi link
      // with the transfer". Asserting on a paraphrase of it failed, which is the
      // right outcome — a test that matches what it wishes the text said is not
      // testing the text.
      expect(find.textContaining(en.livePausedBannerBody), findsOneWidget);
      // And it must not claim the camera confirmed anything: the protocol has no
      // way to report stream state, so the wording is about what the app asked
      // for, not about what the camera did.
      expect(find.textContaining('camera said'), findsNothing);
    });

    testWidgets('the close button dismisses it', (tester) async {
      // The reported defect. A card pinned over the picture with no way out is
      // worse than no card.
      await pumpBanner(tester, onKeepRunning: () {}, onStopPreview: () {});
      expect(find.text(en.livePreviewPausedForTransfer), findsOneWidget);
      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();
      expect(find.text(en.livePreviewPausedForTransfer), findsNothing);
    });

    testWidgets('dismissing it does NOT stop the preview', (tester) async {
      // The distinction that matters: hiding the notice and changing the camera's
      // state are different actions, and conflating them would stop the stream
      // because the user wanted the card out of the way.
      var stopped = 0;
      await pumpBanner(tester,
          onKeepRunning: () {}, onStopPreview: () => stopped++);
      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();
      expect(stopped, 0);
    });

    testWidgets('"keep the preview running" asks for a resume, not a stop',
        (tester) async {
      var kept = 0;
      var stopped = 0;
      await pumpBanner(tester,
          onKeepRunning: () => kept++, onStopPreview: () => stopped++);
      await tester.tap(find.text(en.liveKeepPreviewRunning));
      await tester.pump();
      expect(kept, 1);
      expect(stopped, 0, reason: 'the primary action must not stop the stream');
      // And it gets out of the way once acted on.
      expect(find.text(en.livePreviewPausedForTransfer), findsNothing);
    });

    testWidgets('"stop the preview" is the explicit escape', (tester) async {
      var kept = 0;
      var stopped = 0;
      await pumpBanner(tester,
          onKeepRunning: () => kept++, onStopPreview: () => stopped++);
      await tester.tap(find.text(en.liveStopPreview));
      await tester.pump();
      expect(stopped, 1);
      expect(kept, 0);
    });
  });
}
