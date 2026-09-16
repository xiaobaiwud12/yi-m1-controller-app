/// **How often the phone is allowed to buzz, and which of two things it is saying.**
///
/// ## The two dial events, and why there are two hooks rather than one
///
/// The dials are detented: one drag crosses as many detents as the finger travels
/// (12 dp of *finger*, see `_ExposureDialState.stepHeight`). A turning dial has two
/// distinct things to report, and they are **not competitors**:
///
/// | event | when | kind | Android constant |
/// |---|---|---|---|
/// | the finger crossed a detent | during the drag, per detent | [detentTick] | `CLOCK_TICK` |
/// | the value left for the camera | when the gate delivers it | [commandSent] | `CONTEXT_CLICK` |
///
/// The first version of this feature hooked only the second, and the reason was sound:
/// `ExposureDialQueue`'s gate is where a value stops being a widget's opinion and starts
/// being a command, so a tick there is one tick per command **by construction**. What it
/// missed is that `DialCoalescer` **holds everything while the finger is down**, so on a
/// real phone nothing was sent until release and therefore nothing ticked until release
/// — the maintainer's *"there is no per-detent tick, it only ticks when I let go"*.
/// Hooking `_step` for the per-detent tick is not the mistake that reading suggests: the
/// mistake was having only the send tick. So both hooks exist, they carry **different
/// kinds**, and the arithmetic below keeps them apart.
///
/// ## The relation that keeps the tiers honest
///
/// **send-ticks == commands sent**, counted at the channel, is still the load-bearing
/// assertion of this file, and it is the one that fails if the *send* tick is moved to
/// `_step` (it then fires once per detent, while the drag is still under the finger and
/// before the coalescer has released anything). Detent-ticks are counted separately and
/// against the number of detents the readout actually crossed — measured from the
/// rendered readout, never from a drag-arithmetic constant, because this fixture's dial
/// is `_BandFitted` to 0.37 and the handover's "13 detents" was measured in a 183 dp band
/// (`analysis/66` §5).
///
/// ## What this file can and cannot establish
///
/// `[V]` — the number of `HapticFeedback.*` calls on `SystemChannels.platform`, of which
/// kind, for a real gesture on the real `LiveViewPage`, with the real `HapticFeedback`
/// calls (no injected callback): a test that counts its own counter proves nothing about
/// the app. `[H]` — how any of it *feels*: how strong `CLOCK_TICK` is against
/// `CONTEXT_CLICK`, whether the two dial sensations are separable by thumb, and whether
/// this phone's haptic engine is even enabled. That is the user's to judge on hardware.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yi_m1_controller/l10n/l10n.dart';
import 'package:yi_m1_controller/protocol/camera_state.dart';
import 'package:yi_m1_controller/protocol/http_params.dart';
import 'package:yi_m1_controller/protocol/viewfinder_layout.dart';
import 'package:yi_m1_controller/protocol/wire_format.dart';
import 'package:yi_m1_controller/state/app_state.dart';
import 'package:yi_m1_controller/sync/asset_sink_contract.dart';
import 'package:yi_m1_controller/transport/http_transport.dart';
import 'package:yi_m1_controller/ui/haptics.dart';
import 'package:yi_m1_controller/ui/pages/album_page.dart';
import 'package:yi_m1_controller/ui/pages/live_view_page.dart';
import 'package:yi_m1_controller/ui/widgets/exposure_dial.dart';

import 'fakes.dart';

void main() {
  /// The reference device, and the window every measurement in `analysis/60` is on.
  const full = Size(914, 411);

  /// The dial's own pacing window, spelled here rather than borrowed so that a change
  /// to `kDialPacingWindow` shows up as a failing count instead of a passing one.
  const window = Duration(milliseconds: 350);

  late Haptics haptics;

  setUp(() {
    haptics = Haptics.install();
  });

  tearDown(() {
    haptics.remove();
  });

  testWidgets('the counter really is on the channel the app uses, per kind',
      (tester) async {
    // ## Why this check exists at all
    //
    // Every other check in this file is a **count of zero or of one**, and a counter
    // that is not wired to anything reports zero forever — so a broken interception
    // makes "no tick for a discarded value" pass and "one tick per command" fail in a
    // way that reads like the opposite bug. This drives `HapticFeedback` itself, through
    // the real `SystemChannels.platform`, and requires the call to arrive.
    //
    // It drives **two different kinds**, because every check below asks for a kind by
    // name: a counter that lumped them together would make "the send tick is not the
    // detent tick" pass on a build that sent one constant for both.
    //
    // It is also the statement that the interception is at the right layer: the app does
    // not call the channel directly anywhere, it calls `HapticFeedback`, and this is that
    // API seen from the platform's side.
    expect(haptics.ticks, 0);
    await HapticFeedback.selectionClick();
    await HapticFeedback.lightImpact();
    await tester.pump();
    expect(haptics.ticks, 2,
        reason: '`HapticFeedback` did not reach the channel mock, so nothing else in '
            'this file measures a haptic at all');
    expect(haptics.detentTicks, 1,
        reason: 'the kind is not read off the argument, so "the light tick is the '
            'detent one" cannot be measured: ${haptics.trace}');
    expect(haptics.pressTicks, 1, reason: 'kinds are being lumped: ${haptics.trace}');
    expect(haptics.sendTicks, 0);
  });

  testWidgets('the four sensations are four different platform constants',
      (tester) async {
    // The requirement is distinctness **at the constant level**: two gestures that ask
    // the platform for the same `HapticFeedbackType` are two gestures a phone is
    // entitled to render identically, and no amount of documentation fixes that. The
    // dial's pair (light while turning / heavier when it leaves) and the shutter's pair
    // (press / release) must be four different constants, not three and not two.
    //
    // `[V]` for the constants; `[H]` for whether the phone renders them differently.
    detentTick();
    commandSent();
    shutterPress();
    shutterRelease();
    await tester.pump();

    expect(haptics.trace.toSet(), hasLength(4),
        reason: 'four gestures asked for ${haptics.trace.toSet().length} distinct '
            'constants: ${haptics.trace}');
    expect(haptics.detentTicks, 1);
    expect(haptics.sendTicks, 1);
    expect(haptics.pressTicks, 1);
    expect(haptics.releaseTicks, 1);
    expect(haptics.trace[0], contains('selectionClick'),
        reason: 'the dial detent is the lightest thing the platform offers and must '
            'stay the selection tick: ${haptics.trace}');
    expect(haptics.trace[1], contains('heavyImpact'),
        reason: 'the send is the heavier half of the dial pair: ${haptics.trace}');
  });

  // ---------------------------------------------------------------------------
  // The dials
  // ---------------------------------------------------------------------------

  /// A camera status block with [mode] and ISO [iso] set, and nothing else the dials
  /// read left ambiguous.
  CameraState stateWith(String mode, String iso) => CameraState({
        'ExposureMode': mode,
        'ImageAspect': '4:3',
        'ShutterSpeed': '1/30s',
        'Fnumber': '1.7',
        'ISOSetting': iso,
        'WB': 'Auto',
        'ColorMode': 'Standard',
        'BatteryLevel': '75',
        'SurplusPhotoCnts': '1272',
        'FocusMode': 'S-AF',
        'DriveMode': 'Single',
        'FileFormat': 'JPG-L',
        'MeteringMode': 'Multi',
        'ImageQuality': '20',
        'LensStatus': '1',
        'EV': '0.0',
      });

  /// The real page, with a real camera state and `RC…` commands recorded as they are
  /// sent — the same seam `exposure_ladder_test.dart` uses.
  ///
  /// [size] is the window. The dial checks want the reference full-screen body
  /// (`914x411`, which is where the dial layout exists at all); the shutter checks want
  /// the portrait body, where the shutter is drawn at its own size and is not sharing
  /// the column with two dials.
  Future<(AppState app, List<String> sent)> pumpLive(
    WidgetTester tester, {
    required String mode,
    String iso = '400',
    bool previewRunning = false,
    Size size = full,
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final sent = <String>[];
    final app = AppState(
      ble: FakeBleTransport(),
      sink: NullAssetSink(),
      testPreviewRunning: previewRunning,
      testIdentity: const CameraIdentity(
        protocolVersion: 1,
        firmwareVersion: '3.1-cn ',
        regionMarker: 'M1CN',
      ),
      testHttp: CameraHttpClient(overrideSend: (command, params) async {
        sent.add('$command=${params[AppState.paramCommands[command]]}');
        if (command == 'RCGetStatus') {
          return const CameraResponse(
              code: 200,
              data: {'BatteryLevel': '3'},
              raw: '{"code":200,"data":{"BatteryLevel":"3"}}');
        }
        return const CameraResponse(
            code: 200, data: 'ok', raw: '{"code":200,"data":"ok"}');
      }),
    );
    addTearDown(app.dispose);
    app.fullScreen = size.width > size.height;
    app.setTestCameraState(stateWith(mode, iso));
    app.frameNotifier.value = onePixelPng;

    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      home: MediaQuery(
        data: MediaQueryData(size: size),
        child: AnimatedBuilder(
          key: UniqueKey(),
          animation: app,
          builder: (context, _) => LiveViewPage(app: app),
        ),
      ),
    ));
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 40));
    }
    sent.clear();
    return (app, sent);
  }

  /// Stop the 250 ms chrome ticker the page runs while the preview is claimed as up,
  /// so the test does not end with a pending periodic timer.
  Future<void> quiet(WidgetTester tester, AppState app) async {
    await app.stopPreview();
    await tester.pump(const Duration(milliseconds: 300));
  }

  /// One vertical drag on the dial keyed [key], in the shape the dial's own tests
  /// measured as reliably delivered: one move per pump, each well over touch slop.
  ///
  /// [dy] is **screen** logical pixels, which is what the dial's own arithmetic is
  /// written against (`stepHeight` is a finger measurement, deliberately not a design
  /// one) — the dial converts to its own space internally.
  Future<void> dragBy(WidgetTester tester, String key, double dy) async {
    final g = await tester
        .startGesture(tester.getCenter(find.byKey(ValueKey<String>(key))));
    await tester.pump(const Duration(milliseconds: 16));
    for (var i = 0; i < 2; i++) {
      await g.moveBy(Offset(0, dy / 2));
      await tester.pump(const Duration(milliseconds: 32));
    }
    await g.up();
    await tester.pump();
  }

  Future<void> dragUp(WidgetTester tester, String key, double dy) =>
      dragBy(tester, key, -dy);

  Future<void> dragDown(WidgetTester tester, String key, double dy) =>
      dragBy(tester, key, dy);

  /// Let every pacing window in the path expire, so a settled value is really sent.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 3; i++) {
      await tester.pump(window + const Duration(milliseconds: 60));
    }
  }

  /// The line the dial keyed [key] is reading out, found by **geometry** rather than
  /// by string: the readout is the 15 dp line, its neighbours are 10.
  ///
  /// Keyed on size because a dial at either end of its ladder draws only two lines,
  /// and then "the middle of three" is a neighbour. See `exposure_ladder_test.dart`,
  /// which lost a round to exactly that.
  String readoutOf(WidgetTester tester, String key) {
    final box = tester.getRect(find.byKey(ValueKey<String>(key)));
    final found = <(double, String)>[];
    for (final e in find.byType(Text).evaluate()) {
      final t = e.widget as Text;
      if (t.data == null) continue;
      final ro = e.renderObject;
      if (ro is! RenderBox || !ro.hasSize) continue;
      final r = ro.localToGlobal(Offset.zero) & ro.size;
      if (!box.contains(r.center)) continue;
      if (r.height < 14) continue;
      found.add((r.center.dy, t.data!));
    }
    found.sort((a, b) => a.$1.compareTo(b.$1));
    return found.isEmpty ? '?' : found.first.$2;
  }

  group('a dial ticks per detent while turning, per command when it sends', () {
    // ## The load-bearing check of this round
    //
    // The dial is **detented**: a drag across 12 dp of *finger* travel moves it one
    // step, so any real drag crosses several values of the camera's ladder. Two counts
    // come out of one gesture and this file keeps them apart:
    //
    // * **detent ticks** — `selectionClick`, one per detent the readout crossed, while
    //   the finger is still down. This is what makes the dial feel detented, and its
    //   absence was the reported defect (*"there is no per-detent tick, it only ticks
    //   when I let go"*).
    // * **send ticks** — `heavyImpact`, one per command that leaves the app. Counted
    //   against `sent` below, which is the assertion that fails if this one is moved
    //   back to `_step`.
    //
    // The number of detents crossed is **measured**, not asserted from the drag
    // arithmetic: the handover's "a 160 dp drag crosses 13 detents" was measured in a
    // 183 dp band, and this fixture's ISO dial is in the 78 dp readout column, where
    // `_BandFitted` scales the dial to 0.37 and the same finger travel crosses fewer
    // steps. Quoting 13 here would be a number borrowed from another layout — what
    // travels is the **relation** between detents, commands and ticks.
    testWidgets('a multi-detent drag: one command, one per detent, one more for the send',
        (tester) async {
      final (app, sent) = await pumpLive(tester, mode: 'M', iso: '400');

      final startIndex = kIsoValues.indexOf(readoutOf(tester, 'dial-iso'));
      expect(startIndex, 3,
          reason: 'the fixture did not seat the ISO dial on 400 (index 3 of '
              '$kIsoValues)');

      await dragUp(tester, 'dial-iso', 160);
      await settle(tester);

      final endIndex = kIsoValues.indexOf(readoutOf(tester, 'dial-iso'));
      final detents = endIndex - startIndex;
      debugPrint('  ISO ${kIsoValues[startIndex]} -> ${kIsoValues[endIndex]} '
          '($detents detents)  sent=$sent  trace=${haptics.trace}');

      expect(detents, greaterThanOrEqualTo(5),
          reason: 'the drag crossed only $detents detents, so "many detents, one '
              'command, many light ticks" is not being measured at all — both counts '
              'below would pass on a build that ticked once for the whole gesture');
      expect(sent.where((s) => s.startsWith('$kCmdIso=')).toList(),
          ['$kCmdIso=${kIsoValues[endIndex]}'],
          reason: 'the dial crossed $detents detents and must have sent exactly the '
              'value it stopped on, once');

      // **The send count, and the assertion that pins the tier.** One tick per value
      // that left the app. Move `commandSent()` into `_step` — the tempting mistake,
      // because `_step` is the funnel every input path reaches — and this becomes
      // $detents for one command, and the check below about the finger being down fails
      // outright.
      expect(haptics.sendTicks, sent.length,
          reason: 'the phone sent the heavier tick ${haptics.sendTicks} time(s) for '
              '${sent.length} command(s): ${haptics.trace}. One per command is the '
              'whole contract of that tick; a tick per detent would be $detents.');

      // **The detent count**, measured against the readout's own travel rather than
      // against a number chosen here: one light tick per detent crossed, none skipped
      // (a debounce would make a fast drag silent, which is the sensation this exists
      // to provide) and none doubled.
      expect(haptics.detentTicks, detents,
          reason: 'the readout crossed $detents detents and the phone ticked '
              '${haptics.detentTicks} light tick(s): ${haptics.trace}');
      expect(haptics.detentTicks + haptics.sendTicks, haptics.ticks,
          reason: 'something ticked that is neither a detent nor a send: '
              '${haptics.trace}');

      await quiet(tester, app);
    });

    testWidgets('two gestures are two commands and two send ticks', (tester) async {
      // The negative control for the check above: a build that ticked *once per dial,
      // ever* — or that hooked something outside the gesture path entirely — passes
      // "many detents, one command" and fails this.
      //
      // ISO 1600 rather than 400, so both drags have the whole ladder below them to
      // move into: at 400 the second one runs into `Auto` at the bottom, clamps, and
      // sends nothing — which is a property of the ladder, not of the haptics.
      final (app, sent) = await pumpLive(tester, mode: 'M', iso: '1600');

      await dragDown(tester, 'dial-iso', 72);
      await settle(tester);
      final detentsAfterFirst = haptics.detentTicks;
      await dragDown(tester, 'dial-iso', 72);
      await settle(tester);

      expect(sent, hasLength(2),
          reason: 'two settled gestures must reach the camera as two commands: $sent');
      expect(haptics.sendTicks, 2,
          reason: 'two gestures, ${haptics.sendTicks} send tick(s): ${haptics.trace}');
      // And the light tick is not a once-per-dial event either: the second gesture
      // crossed its own detents.
      expect(haptics.detentTicks, greaterThan(detentsAfterFirst),
          reason: 'the second drag crossed detents and ticked nothing: '
              '${haptics.trace}');

      await quiet(tester, app);
    });

    testWidgets('under the finger the light tick fires, the heavier one does not',
        (tester) async {
      // ## This is the reported defect, and it is two assertions with opposite signs
      //
      // *"There is no per-detent tick — it only ticks when I let go."* Both halves are
      // checked here, on the real page, at the one moment that tells them apart: while
      // the finger is still down. The light tick must be **happening** (once per detent
      // crossed so far) and the heavier one must **not** — because `DialCoalescer` holds
      // every value until the finger comes up, so nothing has left for the camera yet.
      //
      // A single "something ticked" check would pass on either half alone, which is how
      // the original implementation shipped: it ticked, once, on release.
      final (app, sent) = await pumpLive(tester, mode: 'M', iso: '400');

      final before = readoutOf(tester, 'dial-iso');
      final startIndex = kIsoValues.indexOf(before);
      final g = await tester
          .startGesture(tester.getCenter(find.byKey(const ValueKey<String>('dial-iso'))));
      await tester.pump(const Duration(milliseconds: 16));
      for (var i = 0; i < 2; i++) {
        await g.moveBy(const Offset(0, -30));
        await tester.pump(const Duration(milliseconds: 32));
      }

      // The premise: the spin really did cross detents, so a detent really was passed.
      // Without this the check passes on a dial that never moved.
      final during = readoutOf(tester, 'dial-iso');
      expect(during, isNot(before),
          reason: 'the drag did not move the readout ($before -> $during), so no detent '
              'was crossed and "nothing ticked" is not evidence about anything');
      final crossed = kIsoValues.indexOf(during) - startIndex;

      expect(haptics.detentTicks, crossed,
          reason: 'the readout moved $before -> $during ($crossed detent(s)) under the '
              'finger and the phone gave ${haptics.detentTicks} detent tick(s) '
              '(${haptics.trace}) — this is the per-detent sensation, and its absence '
              'is "只有松手才咔"');
      expect(sent, isEmpty, reason: 'nothing may be sent mid-spin either: $sent');
      expect(haptics.sendTicks, 0,
          reason: 'the heavier confirmation fired for a value the camera has not been '
              'told about — a value being passed through is not a value the user chose: '
              '${haptics.trace}');

      await g.up();
      await settle(tester);

      // And when the finger comes up, the value that *is* chosen is sent — once — and it
      // is that send the heavier tick belongs to.
      expect(sent.where((s) => s.startsWith('$kCmdIso=')), hasLength(1),
          reason: 'the settled value must still be delivered: $sent');
      expect(haptics.sendTicks, 1,
          reason: 'the gesture settled on a value and sent it, so the heavier tick must '
              'fire exactly once: ${haptics.trace}');
      expect(haptics.detentTicks, crossed,
          reason: 'letting go must not add detent ticks — the detents were crossed on '
              'the way, and a release is not a detent: ${haptics.trace}');

      await quiet(tester, app);
    });

    testWidgets('a value the queue drops produces no tick', (tester) async {
      // ## The other half, and why it is driven at the queue rather than through the page
      //
      // A queue that is discarded — `ExposureDialQueue.discardPending`, and the
      // `dispose` behind it — throws away a value that was offered and never sent. A
      // tick for it would be the phone confirming a value the camera never heard.
      //
      // It is checked here rather than through a gesture because **the page has no
      // reachable path to it**: `ExposureDialQueue.discardPending` is called from
      // `dispose` alone (`live_view_page.dart` disposes its queue when the page goes
      // away), and the per-dial `discardPending` behind `didUpdateWidget` needs a dial
      // seated with `enabled: false`, which the layout plan never produces — a mode that
      // owns a parameter has that parameter's dial **removed**, not disabled. That is a
      // finding about the existing code, not something this round changed, and it is
      // recorded in `analysis/66` rather than papered over with a test that looks like a
      // gesture but is not one.
      final set = <String>[];
      final queue = ExposureDialQueue(onSet: (dial, value) => set.add('$dial=$value'));
      addTearDown(queue.dispose);

      // **The gate sends on offer, and that is measured rather than assumed** — a
      // consequence of the two-tier design worth pinning: `_schedule` has no window to
      // wait out when nothing is cooling, so the first value of a gesture is delivered
      // by the gate as soon as the tier above releases it. The 350 ms pacing lives in
      // `_ExposureDialState`'s own coalescer, which a dial is built with and which this
      // fixture deliberately leaves out; what is being checked here is the tier the tick
      // is on. If the gate ever gains a window, this line fails and the check below has
      // to be rewritten rather than silently measuring something else.
      queue.spin('dial-iso')('1600');
      expect(set, ['dial-iso=1600'],
          reason: 'the gate delivers on offer — see the comment above');
      expect(haptics.sendTicks, set.length,
          reason: 'the send and the heavier tick are the same event: ${haptics.trace}');
      // The queue has no gesture and therefore no detents: the light tick must not be
      // reachable from here at all, or `discardPending` below could be hiding one.
      expect(haptics.detentTicks, 0,
          reason: 'the queue ticked a detent without a finger: ${haptics.trace}');

      // Now drop the *next* value, and prove nothing at all happens for it — no
      // delivery, and in particular no tick, which is the claim that matters: a tick for
      // a value the camera never heard is the phone confirming something that did not
      // happen.
      queue.spin('dial-iso')('3200');
      queue.discardPending();
      await tester.pump(window + const Duration(milliseconds: 60));

      expect(set, ['dial-iso=1600'],
          reason: 'the dropped value must not be delivered late: $set');
      expect(haptics.ticks, 1,
          reason: 'a value that was never sent ticked: ${haptics.trace}');

      // And the negative control for the drop itself: without `discardPending` the same
      // sequence *does* deliver. A "drop" that never drops would make the line above pass
      // for the wrong reason.
      queue.spin('dial-iso')('6400');
      await tester.pump(window + const Duration(milliseconds: 60));
      expect(set, ['dial-iso=1600', 'dial-iso=6400'],
          reason: 'the queue stopped delivering after a discard, so the check above '
              'cannot tell a drop from a queue that has died: $set');
      expect(haptics.sendTicks, 2);
    });

    testWidgets('a drag on a disabled dial does nothing at all', (tester) async {
      // ## Why this one drives the widget directly
      //
      // `不可调` is the dial's own state, and the page never seats a dial the mode owns
      // — in P mode the aperture dial is **absent**, not disabled (`fullScreenDialsAboveShutter`
      // returns only the EV dial). So there is no camera state that reaches this branch
      // through the page, and a check that tried would be asserting on a dial that is not
      // on screen. The `ExposureDial` is therefore pumped with `enabled: false` the way
      // `exposure_dial_test.dart` does, and the claim is about the widget: **a disabled
      // dial is not a control, so it must not tick.**
      final spins = <String>[];
      await tester.binding.setSurfaceSize(const Size(183, 61));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
        home: Scaffold(
          backgroundColor: Colors.black,
          body: Center(
            child: ExposureDial(
              param: ExposureParam.iso,
              values: kIsoValues,
              value: '400',
              enabled: false,
              disabledReason: 'P 模式下相机自己决定感光度',
              onSpin: spins.add,
            ),
          ),
        ),
      ));
      await tester.pump();

      expect(find.text('P 模式下相机自己决定感光度'), findsOneWidget,
          reason: 'the disabled dial must be drawn saying why — this is the state the '
              'check is about');

      await dragUp(tester, 'dial-iso', 160);
      await settle(tester);

      expect(spins, isEmpty, reason: 'a disabled dial reported $spins');
      expect(haptics.ticks, 0,
          reason: 'a disabled dial ticked: ${haptics.trace}');
      // Named separately, because the two dial ticks are hooked in two different places
      // and `'不可调'` has to silence **both**: the per-detent one is now inside `_step`,
      // which a disabled dial must not reach, and the send one is behind the page's
      // `onSet`, which must never be called for it.
      expect(haptics.detentTicks, 0,
          reason: 'a disabled dial crossed detents that do not exist: '
              '${haptics.trace}');
      expect(haptics.sendTicks, 0,
          reason: 'a disabled dial confirmed a value it never sent: ${haptics.trace}');
    });
  });

  // ---------------------------------------------------------------------------
  // The shutter
  // ---------------------------------------------------------------------------

  group('the shutter presses and releases distinguishably', () {
    // ## Why the shutter is the second thing that buzzes
    //
    // It is a **press-and-hold** control: down starts a burst, up stops it, and a
    // burst nothing stops strands the camera until its battery is pulled. So the
    // release is not a courtesy — it is the feedback for the action that keeps the
    // camera alive, and it has to be tellable apart from the press by feel alone,
    // because the user is looking at the subject and not at the phone.
    testWidgets('down and up are two ticks, of two different kinds', (tester) async {
      final (app, sent) = await pumpLive(tester, mode: 'M',
          previewRunning: true, size: const Size(1080, 2400));

      // The premise, asserted rather than assumed: a shutter that cannot shoot has no
      // `Listener` wired at all, and this check would then be measuring nothing.
      expect(app.shutterBlockedReason, isNull,
          reason: 'the shutter must be live for a press to reach the app at all: '
              '${app.shutterBlockedReason}');

      final shutter = find.byKey(const ValueKey<String>('btn-shutter'));
      expect(shutter, findsOneWidget);
      final centre = tester.getCenter(shutter);
      debugPrint('  shutter rect=${tester.getRect(shutter)}');

      final g = await tester.startGesture(centre);
      await tester.pump(const Duration(milliseconds: 30));

      final afterDown = List<String>.from(haptics.trace);
      expect(afterDown, hasLength(1),
          reason: 'the press must confirm itself: the user has to know the hold '
              'registered before the burst starts. trace=$afterDown sent=$sent');

      await g.up();
      await tester.pump(const Duration(milliseconds: 30));

      expect(haptics.trace, hasLength(2),
          reason: 'press and release must both tick — the release is the one that says '
              'the burst was stopped. trace=${haptics.trace}');
      expect(haptics.trace[1], isNot(haptics.trace[0]),
          reason: 'press and release ticked the same way (${haptics.trace}), so they are '
              'not distinguishable by feel — which is the requirement, not a preference: '
              'the two mean opposite things');

      // ## And the shutter's pair must not be the dial's pair
      //
      // Four sensations are in use and the shutter's two have to be separable from the
      // dial's two as well as from each other: a press that felt like a dial detent
      // would read as "I turned something", and a release that felt like a dial send
      // would read as "a value was sent" — during a burst, on a control whose release is
      // the half that keeps the camera alive. Asserted by kind, because that is what the
      // platform is actually asked for.
      expect(haptics.pressTicks, 1,
          reason: 'the press is `lightImpact` and nothing else: ${haptics.trace}');
      expect(haptics.releaseTicks, 1,
          reason: 'the release is `mediumImpact` and nothing else: ${haptics.trace}');
      expect(haptics.detentTicks, 0,
          reason: 'the shutter asked for the dial detent tick, so a press is '
              'indistinguishable from a turn: ${haptics.trace}');
      expect(haptics.sendTicks, 0,
          reason: 'the shutter asked for the dial send tick: ${haptics.trace}');

      await quiet(tester, app);
    });

    testWidgets('a shutter that cannot shoot does not tick', (tester) async {
      // The negative control. With the preview down the shutter is blocked and the
      // `Listener` is not even wired; a tick here would be the phone reporting a
      // press the app refused to act on.
      final (app, _) = await pumpLive(tester, mode: 'M',
          size: const Size(1080, 2400));
      expect(app.shutterBlockedReason, isNotNull,
          reason: 'this check needs a shutter that is actually blocked, and with no '
              'preview claimed as running it must be');

      final centre =
          tester.getCenter(find.byKey(const ValueKey<String>('btn-shutter')));
      final g = await tester.startGesture(centre);
      await tester.pump(const Duration(milliseconds: 30));
      await g.up();
      await tester.pump(const Duration(milliseconds: 30));

      expect(haptics.ticks, 0,
          reason: 'a blocked shutter ticked ${haptics.trace}');

      await quiet(tester, app);
    });
  });

  // ---------------------------------------------------------------------------
  // The album's selection
  // ---------------------------------------------------------------------------

  group('album selection', () {
    Future<AppState> pumpAlbum(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(411, 727));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final app = connectedTestAppState();
      addTearDown(app.dispose);
      await tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
        home: AlbumPage(app: app),
      ));
      // The page reads the durable ledger off disk at startup, and real I/O never
      // finishes inside a widget test's fake-async zone — without `runAsync` the page
      // stays on its spinner and there is no grid to tap.
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 60)));
        await tester.pump(const Duration(milliseconds: 60));
      }
      return app;
    }

    testWidgets('choosing a tile and removing it are one tick each',
        (tester) async {
      final app = await pumpAlbum(tester);

      await tester.tap(find.byKey(const ValueKey<String>('btn-album-select')));
      await tester.pump(const Duration(milliseconds: 30));
      final grid = find.descendant(
          of: find.byType(GridView), matching: find.byType(GestureDetector));
      expect(grid, findsWidgets,
          reason: 'the fixture listed no photos, so there is no tile to select');

      await tester.tap(grid.first);
      await tester.pump(const Duration(milliseconds: 30));
      expect(haptics.ticks, 1,
          reason: 'selecting a tile must tick once: ${haptics.trace}');
      // The **light** tick, the same constant as a dial detent — "the selection moved
      // through discrete values" is the question `selectionClick` answers, and a tile is
      // a discrete selection. Not the dial's send tick: nothing left for the camera.
      expect(haptics.detentTicks, 1, reason: '${haptics.trace}');
      expect(haptics.sendTicks, 0, reason: '${haptics.trace}');

      await tester.tap(grid.first);
      await tester.pump(const Duration(milliseconds: 30));
      expect(haptics.ticks, 2,
          reason: 'deselecting must tick too — it is the same one bit of state, and a '
              'selection with no way to feel it is the thing being fixed: '
              '${haptics.trace}');

      // Entering selection mode is a mode change, not a selection: nothing is selected
      // yet and nothing may have ticked for the button that got us here.
      expect(haptics.ticks - 2, 0);

      await app.stopPreview();
      await tester.pump(const Duration(milliseconds: 300));
    });
  });
}

/// Counts `HapticFeedback` calls by intercepting the **method call**, not by wrapping
/// the app's own call site.
///
/// ## Why the interception is at the channel
///
/// `HapticFeedback` is a static API over `SystemChannels.platform`
/// (`flutter/lib/src/services/haptic_feedback.dart`), so a counter injected into the
/// widget would prove only that the widget called *something the test supplied*. The
/// channel is the last point the app controls and the first point the platform sees,
/// which makes the count here a statement about what a phone would be asked to do.
///
/// ## Why the count is per **kind**
///
/// There are four kinds in use and the requirement is that they be tellable apart, so a
/// single total would be blind to the defect that matters most: two gestures collapsing
/// onto one platform constant. Every assertion that cares about a kind asks for that
/// kind by the name the platform is given (`HapticFeedbackType.heavyImpact`), which is
/// also what makes "the heavier tick is on the send, not on the step" measurable.
///
/// `SystemChannels.platform` is the **same** channel the rest of the app already talks
/// on (screen-on, system UI), so the mock is deliberately narrow: it records only
/// `HapticFeedback.vibrate` and passes everything else through unchanged, because a
/// blanket handler would silently answer those other calls as well.
class Haptics {
  final List<MethodCall> calls = [];

  MethodChannel get _channel => SystemChannels.platform;

  /// One entry per haptic, as the platform would see it: the `HapticFeedbackType.*`
  /// string, or `vibrate` for the argument-less `HapticFeedback.vibrate()`.
  List<String> get trace =>
      [for (final c in calls) '${c.arguments ?? '(no argument)'}'];

  int get ticks => calls.length;

  /// How many calls of one `HapticFeedback` kind, named as the platform's own argument
  /// spells it — `selectionClick`, `heavyImpact`, `lightImpact`, `mediumImpact`.
  int of(String type) => trace.where((t) => t.endsWith('.$type')).length;

  /// The dial's **light** tick: `HapticFeedback.selectionClick` / `CLOCK_TICK`. One per
  /// detent the finger crosses, and one per album tile toggle.
  int get detentTicks => of('selectionClick');

  /// The dial's **heavier** tick: `HapticFeedback.heavyImpact` / `CONTEXT_CLICK`. One
  /// per value that actually leaves the app for the camera.
  int get sendTicks => of('heavyImpact');

  /// The shutter's press: `HapticFeedback.lightImpact` / `VIRTUAL_KEY`.
  int get pressTicks => of('lightImpact');

  /// The shutter's release: `HapticFeedback.mediumImpact` / `KEYBOARD_TAP`.
  int get releaseTicks => of('mediumImpact');

  Haptics._();

  static Haptics install() {
    final h = Haptics._();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(h._channel, (call) async {
      if (call.method == 'HapticFeedback.vibrate') h.calls.add(call);
      return null;
    });
    return h;
  }

  void remove() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  }
}
