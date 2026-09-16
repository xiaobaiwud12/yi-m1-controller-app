/// Failing-first check for the second hardware defect: **the live view keeps
/// decoding while something else is on screen.**
///
/// ## The measurement
///
/// With the album tab displayed, the camera stream was still being pulled and
/// decoded at ~30 fps for frames nobody could see: the host-side bridge moved
/// **46 906 datagrams / 2.47 GB** while the album tab was on screen
/// (`analysis/emulator/bridge_run.log`).
///
/// The CPU figure that used to be quoted here has been **withdrawn**: it was
/// measured on an emulator with no GPU (software GL) and a debug/JIT build, where
/// a controlled A/B gave 103–169 % with the preview on against 0 % with it off —
/// and about half of that is rasterisation a real GPU does for free.  It supports
/// no claim about a phone.  What supports this change is that the work is
/// **wasted by construction**: with the preview covered, ~30 frames a second are
/// decoded whose output nobody can see.
///
/// `HomeShell` uses an `IndexedStack`, so `LiveViewPage` stays alive and keeps
/// its frame subscription when the album replaces it.
///
/// ## What is fixed, and what is deliberately not
///
/// Only the **client-side** decision to drop frames nobody can see.  The
/// camera's stream is left running: `PauseMovieStream` / `RCStopMovieStream` /
/// `RCStopRemoteCtl` have never been verified on hardware and the project
/// forbids sending them by default (`AGENTS.md` §4.6, `analysis/37`–`39`).
/// Nothing in this file asserts anything about them being sent, and that
/// absence is itself the requirement.
///
/// And while the page **is** visible, nothing is dropped: see the
/// "visible path is a straight wire" group, which pins one-in/one-out against
/// the user's standing ban on client-side frame skipping.
///
/// ## The two layers here, and why both
///
/// * `FrameGate` is transport-layer logic and is checked in a plain `test()`
///   with a stream the test drives — no widget, no socket, no camera.
/// * the page-to-gate **wiring** is checked by building the real `HomeShell` and
///   switching the real tab strip.  A test that built its own gate and called
///   `hide()` on it would prove the gate works and say nothing about whether
///   anything ever calls it — which is the defect class this project has paid
///   for twice (`analysis/47` §5, `analysis/41` §7.17).
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yi_m1_controller/app.dart';
import 'package:yi_m1_controller/state/app_state.dart';
import 'package:yi_m1_controller/sync/asset_sink_contract.dart';
import 'package:yi_m1_controller/transport/frame_gate.dart';
import 'package:yi_m1_controller/transport/http_transport.dart';
import 'package:yi_m1_controller/transport/liveview.dart';
import 'package:yi_m1_controller/protocol/camera_state.dart';
import 'package:yi_m1_controller/protocol/wire_format.dart';

import 'fakes.dart';
import 'package:yi_m1_controller/l10n/l10n.dart';

/// Build one datagram in the shape the camera really sends.
///
/// The offsets are the measured ones the receiver validates against
/// (`transport/liveview.dart`): a 12-byte header, a parameter block ending at
/// [kJpegOffset], then a JPEG that ends at the last two bytes of the datagram.
/// The JPEG body is filler rather than real entropy-coded data: what the
/// receiver checks is the **markers**, and a frame that failed validation would
/// be counted `malformed` and never reach the gate at all — a fixture that
/// silently made the test vacuous.
Uint8List liveViewDatagram(int frameIndex) {
  final b = Uint8List(kJpegOffset + 8);
  final bd = ByteData.sublistView(b);
  bd.setUint32(0, frameIndex, Endian.big);
  bd.setUint32(4, frameIndex * 3003, Endian.big);
  bd.setUint32(8, kSessionMarker, Endian.big);
  b[4] = 0x7B; // '{'
  b[5] = 0x7D; // '}' — a parameter block, so the state decode path is real
  b[kJpegOffset + 0] = 0xFF;
  b[kJpegOffset + 1] = 0xD8;
  b[kJpegOffset + 2] = 0xFF;
  b[kJpegOffset + 3] = 0x11;
  b[kJpegOffset + 4] = 0x22;
  b[kJpegOffset + 5] = 0x33;
  b[kJpegOffset + 6] = 0xFF;
  b[kJpegOffset + 7] = 0xD9;
  return b;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the frame gate drops frames nobody can see', () {
    late StreamController<LiveViewFrame> source;
    late FrameGate gate;
    late int delivered;

    setUp(() {
      source = StreamController<LiveViewFrame>.broadcast();
      delivered = 0;
      gate = FrameGate(
        frames: source.stream,
        onFrame: (_) => delivered++,
      );
    });

    tearDown(() async {
      gate.dispose();
      await source.close();
    });

    /// Push one frame and let the delivery land.
    ///
    /// `await Future<void>.value()` is not enough on a broadcast stream: the
    /// event is delivered on a later microtask, so a counter read immediately
    /// after `add` sees the *previous* state and every assertion here would pass
    /// for the wrong reason.
    Future<void> push(int i) async {
      source.add(LiveViewFrame(
        frameIndex: i,
        timestamp: i * 3003,
        jpeg: Uint8List.fromList(const [0xFF, 0xD8, 0xFF, 0xD9]),
      ));
      await Future<void>.delayed(Duration.zero);
    }

    test('frames are delivered while the page is visible', () async {
      gate.start();
      await push(1);
      expect(delivered, 1);
    });

    test('and NOT delivered once the page is hidden', () async {
      gate.start();
      await push(1);
      expect(delivered, 1, reason: 'the control: visible really does deliver');

      gate.setVisible(false);
      await push(2);
      await push(3);
      expect(delivered, 1,
          reason: 'this is the defect: 30 frames a second were still being '
              'handed to a page that is not on screen');
      expect(gate.isDelivering, isFalse);
    });

    test('returning to the page resumes delivery immediately', () async {
      gate.start();
      gate.setVisible(false);
      await push(1);
      expect(delivered, 0);

      gate.setVisible(true);
      await push(2);
      expect(delivered, 1,
          reason: 'coming back must not wait for a new subscription or a '
              'restart of the stream');
    });

    test('hiding and showing again is idempotent', () async {
      gate.start();
      gate.setVisible(false);
      gate.setVisible(false);
      await push(1);
      expect(delivered, 0);

      gate.setVisible(true);
      gate.setVisible(true);
      await push(2);
      expect(delivered, 1,
          reason: 'a re-asserted visibility must not double-subscribe and '
              'deliver every frame twice');
    });

    test('a frame arriving while hidden is not delivered late', () async {
      // Not a queue.  A frame is only worth showing at the moment it arrives;
      // replaying stale ones on return would show the user a picture from
      // however long the album was open.
      gate.start();
      gate.setVisible(false);
      await push(1);
      await push(2);
      gate.setVisible(true);
      expect(delivered, 0, reason: 'frames from while it was hidden were '
          'buffered and replayed');
    });

    test('stop() delivers nothing further', () async {
      gate.start();
      gate.setVisible(true);
      await push(1);
      gate.stop();
      await push(2);
      expect(delivered, 1);
    });
  });

  group('the visible path is a straight wire', () {
    /// ## Why this group exists
    ///
    /// The user has a standing rule: **the client does not skip frames.**  It was
    /// implemented once ("draw every other frame to halve the cost") and removed
    /// on request, because it buys CPU the user cannot see and pays with
    /// smoothness the user can — `app_state.dart` carries that note where the
    /// skipping used to be.
    ///
    /// `FrameGate` drops frames that are **hidden**, which is a different thing:
    /// nobody can see them, so nothing visible is lost.  But it is adjacent
    /// enough that it must not be allowed to drift into the banned shape, and the
    /// only way to hold that line is a check on the visible path itself: **what
    /// arrives is what is delivered, one for one.**  A future "let us coalesce
    /// bursts while we are at it" turns this red.
    test('every frame that arrives while visible is delivered, exactly once',
        () async {
      final source = StreamController<LiveViewFrame>.broadcast();
      final delivered = <LiveViewFrame>[];
      final gate = FrameGate(
        frames: source.stream,
        onFrame: delivered.add,
        visible: true,
      );
      addTearDown(() async {
        gate.dispose();
        await source.close();
      });

      const n = 12;
      gate.start();
      for (var i = 1; i <= n; i++) {
        source.add(LiveViewFrame(
          frameIndex: i,
          timestamp: i * 3003,
          jpeg: Uint8List.fromList(const [0xFF, 0xD8, 0xFF, 0xD9]),
        ));
      }
      await Future<void>.delayed(Duration.zero);

      expect(delivered, hasLength(n),
          reason: 'the visible path dropped or coalesced frames — that is the '
              'client-side frame skipping the user banned, wearing a new name');
      expect(delivered.map((f) => f.frameIndex).toList(),
          List<int>.generate(n, (i) => i + 1),
          reason: 'the frames arrived out of order or some were repeated');
    });

    test('hiding and showing does not change the visible delivery rate',
        () async {
      // The visibility toggle must not become a throttle: a burst that spans a
      // hide/show boundary delivers every frame that arrived while visible, and
      // none that did not.
      final source = StreamController<LiveViewFrame>.broadcast();
      final delivered = <int>[];
      final gate = FrameGate(
        frames: source.stream,
        onFrame: (f) => delivered.add(f.frameIndex),
        visible: true,
      );
      addTearDown(() async {
        gate.dispose();
        await source.close();
      });

      Future<void> push(int i) async {
        source.add(LiveViewFrame(
          frameIndex: i,
          timestamp: i * 3003,
          jpeg: Uint8List.fromList(const [0xFF, 0xD8, 0xFF, 0xD9]),
        ));
        await Future<void>.delayed(Duration.zero);
      }

      gate.start();
      await push(1);
      await push(2);
      gate.setVisible(false);
      await push(3);
      await push(4);
      gate.setVisible(true);
      await push(5);
      await push(6);

      expect(delivered, [1, 2, 5, 6],
          reason: 'exactly the frames that arrived while visible, in order, and '
              'no others');
    });
  });

  group('the live view page tells the app when it is off screen', () {
    /// A `HomeShell` with a connected app, wired the way production wires it.
    ///
    /// The tab strip in the shell is tapped rather than the gate being poked
    /// directly: the defect was that `IndexedStack` keeps the page alive, and the
    /// only way to reproduce that is to let the shell do it.
    ///
    /// `testHttp` is what puts the injected connection into `ready`, which is
    /// half of what `_applyFrameWiring` requires.  Without it the link stays
    /// `idle` and the gate never starts — the assertions below would then pass
    /// for the wrong reason, because nothing would ever have been delivered.
    ///
    /// `runAsync` is required and is not optional.  Binding a real
    /// `RawDatagramSocket` is genuine I/O, and a real completion **never
    /// arrives** inside a widget test's fake-async zone — the same trap that
    /// hung `capture_wiring_test` for ten minutes (`analysis/47` §6,
    /// `analysis/41` §7.9).
    Future<(AppState, CameraLiveView, List<String>)> pumpShell(
        WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1080, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      // Not the camera's port: the app under test is running in an emulator on
      // this machine and 54321 is forwarded to the camera, so binding it here
      // would fail or, worse, steal the real stream.
      final liveView = CameraLiveView(port: 54987);
      final sent = <String>[];
      final app = AppState(
        ble: FakeBleTransport(),
        sink: NullAssetSink(),
        testLiveView: liveView,
        testHttp: CameraHttpClient(overrideSend: (cmd, params) async {
          sent.add(cmd);
          if (cmd == 'RCGetStatus') {
            return const CameraResponse(
              code: 200,
              data: {'BatteryLevel': '3'},
              raw: '{"code":200,"data":{"BatteryLevel":"3"}}',
            );
          }
          return const CameraResponse(code: 200, raw: '{"code":200}');
        }),
        testIdentity: const CameraIdentity(
          protocolVersion: 1,
          firmwareVersion: '3.1-cn ',
          regionMarker: 'M1CN',
        ),
        testPreviewRunning: true,
      );
      // No `addTearDown(app.dispose)`: `HomeShell` owns whatever it is handed and
      // disposes it in its own `dispose`, so disposing here as well threw
      // "A ValueNotifier was used after being disposed" during teardown — the
      // same note `build_stamp_test.dart` carries.
      app.setTestCameraState(const CameraState({
        'ExposureMode': 'M',
        'ImageAspect': '4:3',
        'BatteryLevel': '75',
        'SurplusPhotoCnts': '120',
      }));

      expect(app.link.isReady, isTrue, reason: 'the injection seam failed');
      expect(app.link.previewRunning, isTrue);

      await tester.runAsync(() => liveView.start());
      expect(liveView.isRunning, isTrue, reason: 'the receiver did not bind');

      await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
        home: HomeShell(testApp: app),
      ));
      await tester.pump(const Duration(milliseconds: 50));
      return (app, liveView, sent);
    }

    /// Deliver one frame through the receiver's real parser and let the stream
    /// deliver it, then pump the tree.
    Future<void> feed(
      WidgetTester tester,
      CameraLiveView liveView,
      int index,
    ) async {
      liveView.feedLiveViewDatagram(liveViewDatagram(index));
      await tester.pump(const Duration(milliseconds: 20));
    }

    Future<void> switchTab(WidgetTester tester, String label) async {
      await tester.tap(find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text(label),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    testWidgets('hiding the tab stops frames reaching the app, and showing it '
        'starts them again', (tester) async {
      final (app, liveView, _) = await pumpShell(tester);

      // Visible: the controller.  Without this half, a gate stuck shut would
      // pass the whole test.
      expect(app.frameFeed.isDelivering, isTrue,
          reason: 'the capture tab is what the app opens on');
      await feed(tester, liveView, 1);
      expect(app.frame, isNotNull,
          reason: 'the preview must work while it is being looked at');

      await switchTab(tester, en.navSync);
      expect(app.frameFeed.isDelivering, isFalse,
          reason: 'the album tab is on screen and the live view is not, but the '
              'page never said so — so ~30 frames a second were still being '
              'decoded for a page nobody can see');

      final whileHidden = app.frame;
      await feed(tester, liveView, 2);
      await feed(tester, liveView, 3);
      expect(identical(app.frame, whileHidden), isTrue,
          reason: 'frames were still being published to a page nobody can see; '
              'each one is a full 800x600 JPEG decode in the widget that is '
              'still mounted behind the album');

      await switchTab(tester, en.navCapture);
      expect(app.frameFeed.isDelivering, isTrue,
          reason: 'returning to the tab must resume promptly');
      await feed(tester, liveView, 4);
      expect(identical(app.frame, whileHidden), isFalse,
          reason: 'the preview did not come back');
      expect(app.frame, isNotNull);
    });

    testWidgets('the link keeps being measured while the tab is hidden',
        (tester) async {
      // The stall detector is a real feature and must not be broken by this
      // change.  Its input is datagram *arrival* — `LiveViewStats.noteArrival`,
      // called by the receiver for every datagram including malformed ones — so
      // "the camera stopped sending" must stay distinguishable from "you left
      // the tab open".  Without this, `isStalled` would freeze on the hidden tab
      // and the one verdict the detector exists to give would be unavailable.
      final (app, liveView, _) = await pumpShell(tester);

      await feed(tester, liveView, 1);
      final before = app.stats.received;
      expect(before, greaterThan(0), reason: 'the control: arrival is counted');

      await switchTab(tester, en.navSync);
      await feed(tester, liveView, 2);
      await feed(tester, liveView, 3);
      expect(app.stats.received, greaterThan(before),
          reason: 'the receiver stopped measuring the link when the page went '
              'off screen');
    });

    testWidgets('the camera stream is never told to stop', (tester) async {
      // The client-side decision must not become a camera command.
      // `PauseMovieStream`, `RCStopMovieStream` and `RCStopRemoteCtl` are
      // unverified on hardware and are forbidden by default; a "fix" that sent
      // one of them would risk the wedge this project has already paid for.
      final (_, liveViewBound, sent) = await pumpShell(tester);
      expect(liveViewBound.isRunning, isTrue,
          reason: 'the receiver must be bound for this to be the real path');
      await switchTab(tester, en.navSync);
      await switchTab(tester, en.navCapture);

      expect(sent, isEmpty,
          reason: 'hiding the tab put commands on the wire: $sent — the stream '
              'must be left alone');
    });
  });

  group('the fixture this file relies on', () {
    test('is one the receiver accepts', () async {
      // AGENTS.md §8: a fixture whose failure mode is to make other checks
      // vacuous must carry its own check.  If this datagram stopped validating,
      // every assertion above would pass with nothing ever reaching the gate.
      //
      // A real socket, because `feedLiveViewDatagram` goes through the same
      // `_handle` the socket feeds and refuses to run without one — a shortcut
      // straight to the stream would let a rejected fixture look like a
      // delivered frame.
      final stats = LiveViewStats();
      final view = CameraLiveView(port: 54989, stats: stats);
      final got = <LiveViewFrame>[];
      final sub = view.frames.listen(got.add);
      addTearDown(() async {
        await sub.cancel();
        await view.dispose();
      });

      await view.start();
      view.feedLiveViewDatagram(liveViewDatagram(7));
      await Future<void>.delayed(Duration.zero);

      expect(stats.received, 1);
      expect(stats.malformed, 0,
          reason: 'the fixture is not a datagram the receiver accepts, so it '
              'never reaches the gate and this whole file checks nothing');
      expect(got, hasLength(1));
      expect(got.single.frameIndex, 7);
      expect(got.single.jpeg.length, 8);
    });
  });
}
