import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yi_m1_controller/protocol/http_params.dart';
import 'package:yi_m1_controller/ui/widgets/exposure_dial.dart';
import 'package:yi_m1_controller/l10n/l10n.dart';

import 'fakes.dart';

/// The exposure dial: what it must show, how it must be driven, and — the part
/// that can hurt the camera — **how often it is allowed to talk to it**.
///
/// ## Why the command rate is tested before the look
///
/// The camera is a single-threaded HTTP server with no watchdog, and a preview
/// stream is running the whole time the dial is being used (`AGENTS.md` §4.6). A
/// ladder of 57 shutter speeds crossed by one thumb, one command per detent, is
/// 57 requests against a server that answers one at a time while it is also
/// pushing 800x600 JPEGs. That is the failure this file exists to prevent, so it
/// is asserted as a **count**, not described in a comment.
///
/// The official app does the same thing for the same reason, and it is the
/// reference for the policy: `C3701b.java:586` cancels the in-flight request for
/// a parameter when a newer one for that parameter arrives, and
/// `C3701b.java:594` drops a queued duplicate for the same parameter. Only the
/// settled value is worth sending.
///
/// ## Why the fit is measured
///
/// The dial has to live in the **183 dp** control band of a 914x411 dp landscape
/// screen, which is where the shutter already is. 183 is measured, not assumed:
/// the live-view page asks for a 288 dp control band and a 176 dp info band, but
/// only 366 dp of horizontal slack exists, so `ViewfinderLayout` splits it evenly
/// — 183 / 183. The same probe showed the band's existing content (a 320 dp
/// shutter row) is drawn at **0.534** scale there, and a control scaled to half is
/// the exact defect `analysis/45` records. So the dial must fit 183 dp at scale
/// 1.0, which is what the width assertion below pins.
void main() {
  /// The control band on the reference device. See the library comment.
  const bandWidth = 183.0;

  /// The pacing window a dial uses unless told otherwise.
  const window = Duration(milliseconds: 350);

  /// Bumped by [pumpDial] so every pump gets a genuinely fresh dial. See the
  /// comment on `pumpDial`.
  var pumpSeq = 0;

  /// A `n`-long ladder of distinct strings, so an assertion about which entry is
  /// current cannot be satisfied by two entries that read the same.
  List<String> ladder(int n) =>
      [for (var i = 0; i < n; i++) 'v${i.toString().padLeft(3, '0')}'];

  /// Pump one dial on its own at [size] and return the recorded spins.
  ///
  /// The list is mutated in place, so it keeps filling during later pumps.
  ///
  /// Each call wraps the dial in a **freshly keyed** box. Without that,
  /// `pumpWidget` reuses the `ExposureDial`'s `State` across calls — so a test
  /// that pumps the same dial twice gets the *second* run starting from the
  /// first run's optimistic index, and a decrement test silently measures
  /// "3 - 1 = 2" while reporting it as a wrong-direction bug. A unique key makes
  /// every pump a genuinely new dial, which is what these tests mean.
  Future<List<String>> pumpDial(
    WidgetTester tester, {
    required List<String> values,
    required int index,
    ExposureParam param = ExposureParam.iso,
    bool enabled = true,
    String? disabledReason,
    Size size = const Size(bandWidth, 64),
    double textScale = 1.0,
  }) async {
    final spins = <String>[];
    // The dial takes the camera's *value string*, not an index: resolving an
    // index is exactly the kind of drift that ends with a control setting the
    // wrong thing, so the widget takes what the camera would be told.
    final value = index >= 0 && index < values.length ? values[index] : null;
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      home: Builder(builder: (context) {
        // Copied from the ambient data so the surface size the test set is the
        // one the dial lays out against; only the text scale is overridden.
        final mq = MediaQuery.of(context);
        return MediaQuery(
          data: mq.copyWith(textScaler: TextScaler.linear(textScale)),
          child: Scaffold(
            backgroundColor: Colors.black,
            body: Center(
              child: KeyedSubtree(
                key: ValueKey<String>('pump-${pumpSeq++}'),
                child: ExposureDial(
                  param: param,
                  values: values,
                  value: value,
                  enabled: enabled,
                  disabledReason: disabledReason,
                  onSpin: spins.add,
                ),
              ),
            ),
          ),
        );
      }),
    ));
    await tester.pump();
    return spins;
  }

  /// Let the pacing window expire so a settled value is actually delivered.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump(window + const Duration(milliseconds: 60));
  }

  /// A drag built from explicit moves, each **pumped**, each big enough to be
  /// delivered.
  ///
  /// Two things about `flutter_test`'s gesture plumbing were measured with a
  /// throwaway probe and both bit this file:
  ///
  /// * `tester.drag` performs the whole gesture between two pumps, so a test
  ///   written with it cannot observe *when* a command was sent — which is the
  ///   only thing these tests are about;
  /// * a bare `TestGesture.moveBy` does not deliver its update until a frame
  ///   runs, and the drag recogniser spends its touch slop on the way in. Moves
  ///   smaller than the slop can therefore vanish entirely: three pumped moves of
  ///   16 dp produced **no** steps at all, while two of 20 dp and one of 40 dp
  ///   both worked. The shapes below are the ones that provably arrive.
  Future<void> spinBy(
    WidgetTester tester,
    Finder target,
    List<double> moves,
  ) async {
    final g = await tester.startGesture(tester.getCenter(target));
    await tester.pump(const Duration(milliseconds: 16));
    for (final dy in moves) {
      await g.moveBy(Offset(0, dy));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await tester.pump(const Duration(milliseconds: 16));
  }

  // -------------------------------------------------------------------------
  // 1. Identity and readout — "which of the three am I changing"
  // -------------------------------------------------------------------------

  testWidgets('the dial says which parameter it is', (tester) async {
    await pumpDial(tester, values: kIsoValues, index: 3);
    expect(find.byKey(const ValueKey<String>('dial-iso')), findsOneWidget,
        reason: 'every interactive control needs a ValueKey so it can be found '
            'and clicked (AGENTS.md §5)');

    // The label has to be readable at a glance, so assert on the rendered widget
    // rather than on a string in the source.
    expect(find.text(en.dialIso), findsOneWidget);
    // And the readout is the camera's own value string, not a re-spelling.
    expect(find.text(kIsoValues[3]), findsWidgets);
  });

  testWidgets('all three parameters get their own key', (tester) async {
    for (final e in <ExposureParam, String>{
      ExposureParam.aperture: 'dial-aperture',
      ExposureParam.shutter: 'dial-shutter',
      ExposureParam.iso: 'dial-iso',
    }.entries) {
      await pumpDial(tester,
          values: const ['1.7', '2.0', '2.8'], index: 1, param: e.key);
      expect(find.byKey(ValueKey<String>(e.value)), findsOneWidget,
          reason: '${e.key} must be addressable by key');
    }
  });

  testWidgets('the neighbouring values are visible around the current one',
      (tester) async {
    // The "available values" half of the requirement: the user must be able to
    // see what a step will get them without committing to it.
    await pumpDial(tester, values: kIsoValues, index: 3);
    expect(find.text(kIsoValues[2]), findsWidgets,
        reason: 'the step below should be visible as context');
    expect(find.text(kIsoValues[4]), findsWidgets,
        reason: 'the step above should be visible as context');
    expect(find.text(kIsoValues[0]), findsNothing,
        reason: 'only the neighbourhood is shown; all 57 shutter speeds do not '
            'fit in a 183 dp band and an unreadable list is not context');
  });

  // -------------------------------------------------------------------------
  // 2. Pacing — the camera-safety contract
  // -------------------------------------------------------------------------

  testWidgets('one drag sends one command, after the finger lifts',
      (tester) async {
    final spins = await pumpDial(tester, values: ladder(40), index: 20);
    final dial = find.byKey(const ValueKey<String>('dial-iso'));

    final g = await tester.startGesture(tester.getCenter(dial));
    await tester.pump(const Duration(milliseconds: 16));

    for (var i = 0; i < 3; i++) {
      await g.moveBy(const Offset(0, -40));
      await tester.pump(const Duration(milliseconds: 16));
      expect(spins, isEmpty,
          reason: 'the value was still moving; a command per detent is what '
              'floods the camera. After move ${i + 1}: $spins');
    }

    await g.up();
    await tester.pump(const Duration(milliseconds: 16));
    expect(spins.length, 1,
        reason: 'one gesture, ONE command carrying the value the finger stopped '
            'on — not one per detent. Got $spins');

    await settle(tester);
    expect(spins.length, 1, reason: 'and still one. Got $spins');
    final crossed = int.parse(spins.single.substring(1)) - 20;
    expect(crossed, greaterThan(0),
        reason: 'dragging up must raise the value. Got $spins');
  });

  testWidgets('a burst of taps ends with the value the user stopped on',
      (tester) async {
    final spins = await pumpDial(tester, values: kIsoValues, index: 3);
    final inc = find.byKey(const ValueKey<String>('dial-iso-increment'));

    for (var i = 0; i < 5; i++) {
      await tester.tap(inc);
      await tester.pump(const Duration(milliseconds: 40));
    }
    await settle(tester);

    // The contract is not "exactly one command". It is two things at once, and
    // both are load-bearing:
    //
    //   * **bounded** — five taps inside one pacing window must not become five
    //     requests against a single-threaded server that is streaming preview;
    //   * **convergent** — the LAST value must actually arrive. The first version
    //     of this widget delivered the first value and then quietly dropped the
    //     rest, so the camera would have sat on ISO 800 while the screen said
    //     12800 and nothing would ever have reconciled them. That is the bug this
    //     assertion exists for, and it was found by writing the assertion down.
    expect(spins.last, kIsoValues[8],
        reason: 'the dial ends on ${kIsoValues[8]}; the camera must end there '
            'too. Got $spins');
    expect(spins.length, lessThanOrEqualTo(2),
        reason: 'five taps must not produce five requests; got $spins');
    expect(spins.toSet().length, spins.length,
        reason: 'and no value may be sent twice; got $spins');
  });

  testWidgets('the paced command really reaches the callback after settling',
      (tester) async {
    // The narrow claim behind the coalescing policy: a value offered while the
    // window is closed is **deferred, not dropped**.
    final spins = await pumpDial(tester,
        values: const ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h'], index: 0,
        param: ExposureParam.aperture);
    final inc = find.byKey(const ValueKey<String>('dial-aperture-increment'));

    await tester.tap(inc); // -> b, sent at once
    await tester.pump(const Duration(milliseconds: 20));
    await tester.tap(inc); // -> c, must wait for the window
    await tester.pump(const Duration(milliseconds: 20));
    expect(spins, ['b'], reason: 'the second change is inside the window');

    await settle(tester);
    expect(spins, ['b', 'c'],
        reason: 'and it is delivered when the window closes. A coalescer that '
            'dropped it would leave the camera on b with the screen showing c. '
            'Got $spins');
  });

  // The pacing rule is the part of this widget that can hurt the camera, so it is
  // also tested without a widget tree at all: in a bare test the fake clock is
  // the only thing advancing time, and the ordering is not entangled with how the
  // gesture arena happened to resolve.
  testWidgets('DialCoalescer: burst, held spin, last value wins, one in flight',
      (tester) async {
    final sent = <String>[];
    final c = DialCoalescer(
      send: (v) {
        sent.add(v);
        return null;
      },
      window: const Duration(milliseconds: 350),
    );

    // Five changes inside one window.
    for (final v in ['a', 'b', 'c', 'd', 'e']) {
      c.offer(v);
      await tester.pump(const Duration(milliseconds: 40));
    }
    expect(sent, ['a'],
        reason: 'the first offer is delivered immediately — a command that '
            'waits for a window before being sent would feel disconnected from '
            'the camera');
    await tester.pump(const Duration(milliseconds: 400));
    expect(sent, ['a', 'e'],
        reason: 'and the window settles on the LAST value, not the first and not '
            'a queue. Got $sent');

    // A held spin sends nothing at all, however long it is held.
    sent.clear();
    c.hold();
    for (final v in ['f', 'g', 'h']) {
      c.offer(v);
      await tester.pump(const Duration(milliseconds: 400));
    }
    expect(sent, isEmpty,
        reason: 'a value being dragged through is not a value the user chose');
    c.release();
    await tester.pump(const Duration(milliseconds: 10));
    expect(sent, ['h'], reason: 'the settled value, sent once, on release');

    // **One request in flight, ever.** The camera is single-threaded, so this is
    // the number that matters — not the rate. A send whose future has not
    // completed must not be overlapped by the next one.
    final slow = Completer<void>();
    final slowSent = <String>[];
    final c2 = DialCoalescer(
      send: (v) {
        slowSent.add(v);
        return v == 'p' ? slow.future : null;
      },
      window: const Duration(milliseconds: 50),
    );
    c2.offer('p');
    await tester.pump(const Duration(milliseconds: 200));
    c2.offer('q');
    await tester.pump(const Duration(milliseconds: 200));
    expect(slowSent, ['p'],
        reason: 'q must wait for p: two commands in flight is the condition '
            'analysis/41 §4.4 records as a precondition of the known hang. '
            'Got $slowSent');
    slow.complete();
    await tester.pump(const Duration(milliseconds: 200));
    expect(slowSent, ['p', 'q'],
        reason: 'and once p is answered, the waiting value goes. Got $slowSent');

    // A value left pending when the link goes away must not be delivered later.
    sent.clear();
    c.hold();
    c.offer('i');
    c.discardPending();
    c.release();
    await tester.pump(const Duration(seconds: 2));
    expect(sent, isEmpty,
        reason: 'the radio is gone; retrying behind the user\'s back is how a '
            'stale parameter gets applied to the next session');

    // And the next session starts with a clean slate rather than waiting out a
    // cooldown that belonged to the old one.
    c.offer('j');
    expect(sent, ['j']);

    c.dispose();
    c2.dispose();
  });

  testWidgets('a ratcheted spin is paced, not sent per detent', (tester) async {
    // Driven through the arrow buttons rather than a synthetic drag. The pacing
    // contract is about **how often `onSpin` fires**, and a button tap is the one
    // input flutter_test delivers with no ambiguity — `moveBy` needs a pump per
    // slice and the recogniser eats the first one as touch slop, which is a
    // property of the harness rather than of the dial. The drag path is covered
    // separately, including that it sends nothing until the finger lifts.
    final spins = await pumpDial(tester, values: ladder(40), index: 20);
    final inc = find.byKey(const ValueKey<String>('dial-iso-increment'));

    // Twelve taps, each pumped well inside the 350 ms pacing window.
    for (var i = 0; i < 12; i++) {
      await tester.tap(inc);
      await tester.pump(const Duration(milliseconds: 40));
    }
    await settle(tester);

    expect(spins, isNotEmpty,
        reason: 'coalescing must not degenerate into "never sends"');
    expect(spins.length, lessThanOrEqualTo(3),
        reason: 'twelve changes across ~480 ms plus a settle must not become '
            'twelve requests against a server that is streaming preview. '
            'Got $spins');
    // The value the user stopped on is what the camera ends up holding. This is
    // the half of the policy that a naive "drop when cooling" gets wrong.
    expect(spins.last, 'v032',
        reason: 'twelve taps from v020 land on v032. Got $spins');
  });

  testWidgets('nothing is sent while a spin is held, and it lands on release',
      (tester) async {
    // The camera-safety half of the policy, and the half a user can feel: the
    // value being dragged *through* is not the value being chosen.
    //
    // Note what is deliberately not asserted here: what the readout shows
    // mid-drag. `find.text` walks the element tree that existed when `pump` was
    // last called, so it reports the *previous* frame's readout and a check
    // written against it fails for a reason that has nothing to do with the dial.
    final spins = await pumpDial(tester, values: ladder(40), index: 20);
    final dial = find.byKey(const ValueKey<String>('dial-iso'));

    final g = await tester.startGesture(tester.getCenter(dial));
    await tester.pump(const Duration(milliseconds: 16));
    for (var i = 0; i < 2; i++) {
      await g.moveBy(const Offset(0, -40));
      await tester.pump(const Duration(milliseconds: 32));
      expect(spins, isEmpty,
          reason: 'the finger is still down after move ${i + 1}');
    }

    await g.up();
    await settle(tester);
    expect(spins, isNotEmpty,
        reason: 'and the moment the finger lifts, the settled value goes');
    expect(spins.single.compareTo('v020'), greaterThan(0),
        reason: 'dragging up must raise the value. Got $spins');
  });

  testWidgets('dragging up raises the value and down lowers it', (tester) async {
    // A wheel whose direction is backwards is a real defect and is invisible to a
    // test that only counts commands.
    //
    // The gesture shape matters and was found by experiment, not by reasoning:
    // the recogniser only accepts the drag once a frame has run *after* the move,
    // so releasing without that pump makes the whole gesture vanish. Both drag
    // tests above use this shape, and so do these.
    final up = await pumpDial(tester, values: ladder(40), index: 20);
    final dial = find.byKey(const ValueKey<String>('dial-iso'));

    final g = await tester.startGesture(tester.getCenter(dial));
    await tester.pump(const Duration(milliseconds: 16));
    for (var i = 0; i < 2; i++) {
      await g.moveBy(const Offset(0, -40));
      await tester.pump(const Duration(milliseconds: 32));
    }
    await g.up();
    await settle(tester);
    expect(up, isNotEmpty, reason: 'an 80 dp upward drag moved nothing');
    expect(up.single.compareTo('v020'), greaterThan(0),
        reason: 'dragging up is a longer shutter / a wider stop. Got $up');
  });

  testWidgets('a downward drag lowers the value by the same rule',
      (tester) async {
    final down = await pumpDial(tester, values: ladder(40), index: 20);
    final dial = find.byKey(const ValueKey<String>('dial-iso'));

    final g = await tester.startGesture(tester.getCenter(dial));
    await tester.pump(const Duration(milliseconds: 16));
    for (var i = 0; i < 2; i++) {
      await g.moveBy(const Offset(0, 40));
      await tester.pump(const Duration(milliseconds: 32));
    }
    await g.up();
    await settle(tester);
    expect(down, isNotEmpty, reason: 'an 80 dp downward drag moved nothing');
    expect(down.single.compareTo('v020'), lessThan(0),
        reason: 'dragging down goes the other way. Got $down');
  });

  testWidgets('the one-entry ladder shows its value, not a dash',
      (tester) async {
    await pumpDial(tester,
        values: const ['1.7'], index: 0, param: ExposureParam.aperture,
        size: const Size(183, kDialHeight));
    expect(find.text('f/1.7'), findsWidgets,
        reason: 'the camera spells an f-number "1.7"; the dial prefixes it once. '
            '"f/f/1.7" is what a doubled prefix looks like and is exactly the '
            'bug this assertion caught');
  });

  testWidgets('a flick that never clears the touch slop does not move the value',
      (tester) async {
    // 16 dp is under the drag recogniser's slop, so this gesture never becomes a
    // drag — and it must not become a *step* either, because a step from a tap
    // that also travelled 16 dp is how a control ends up moving when the user
    // meant to brush past it.
    final spins = await pumpDial(tester, values: ladder(40), index: 20);
    await spinBy(tester, find.byKey(const ValueKey<String>('dial-iso')),
        const [-16, -16, -16]);
    await settle(tester);
    expect(spins.length, lessThanOrEqualTo(1),
        reason: 'sub-slop movement must not accumulate into a spin. Got $spins');
  });

  testWidgets('a slow drag accumulates instead of rounding away to nothing',
      (tester) async {
    // Rounding each drag slice on its own discards everything under half a
    // detent, and a slow finger produces many small slices — so a slow drag would
    // move the value not at all, then jump. The remainder has to carry.
    //
    // The failure this catches is "a slice is dropped", which shows up as **no
    // change at all**. Squares of 24 dp are used rather than 3 dp ones because a
    // slice under the touch slop never reaches the widget in the first place;
    // what is being tested is the dial's arithmetic, not the recogniser's.
    final spins = await pumpDial(tester, values: ladder(40), index: 20);
    await spinBy(tester, find.byKey(const ValueKey<String>('dial-iso')),
        const [-24, -24, -24]);
    await settle(tester);
    expect(spins, isNotEmpty, reason: 'a slow drag moved nothing at all');
    final crossed = int.parse(spins.single.substring(1)) - 20;
    expect(crossed, greaterThan(0),
        reason: '72 dp of slow travel must move the value. Crossed $crossed');
  });

  testWidgets('spinning past either end clamps and sends nothing', (tester) async {
    // Clamping is not an error, it is the end of the list — and the dial must not
    // send a command for a value that did not change. A shutter already at
    // 1/4000 does not need the camera told so.
    final top = await pumpDial(tester, values: ladder(5), index: 4);
    await tester.drag(find.byKey(const ValueKey<String>('dial-iso')),
        const Offset(0, -300), warnIfMissed: false);
    await settle(tester);
    expect(top, isEmpty,
        reason: 'there is nothing above the last value, so nothing changed and '
            'nothing should have been sent. Got $top');
    expect(tester.takeException(), isNull);

    final topInc = tester.widget<IconButton>(
        find.byKey(const ValueKey<String>('dial-iso-increment')));
    expect(topInc.onPressed, isNull, reason: 'and the button must say so');

    final bottom = await pumpDial(tester, values: ladder(5), index: 0);
    await tester.drag(find.byKey(const ValueKey<String>('dial-iso')),
        const Offset(0, 300), warnIfMissed: false);
    await settle(tester);
    expect(bottom, isEmpty, reason: 'same at the bottom. Got $bottom');
    final bottomDec = tester.widget<IconButton>(
        find.byKey(const ValueKey<String>('dial-iso-decrement')));
    expect(bottomDec.onPressed, isNull);
  });

  testWidgets('the dial does not spin while disabled', (tester) async {
    // In `S` mode the camera owns the aperture; a control that looks live and
    // changes nothing is the complaint `AppState.isParamEffective` exists for.
    final spins = await pumpDial(tester,
        values: kFNumbers, index: 3, param: ExposureParam.aperture,
        enabled: false,
        disabledReason: 'S 模式下相机自己决定光圈');
    await tester.drag(find.byKey(const ValueKey<String>('dial-aperture')),
        const Offset(0, -40), warnIfMissed: false);
    await settle(tester);
    expect(spins, isEmpty);

    for (final suffix in ['increment', 'decrement']) {
      final b = tester.widget<IconButton>(
          find.byKey(ValueKey<String>('dial-aperture-$suffix')));
      expect(b.onPressed, isNull,
          reason: 'a disabled control must be disabled, not silently inert');
    }

    // And it must say **why**. A dial that is simply dead is indistinguishable
    // from one that is broken; every vendor that gates exposure by mode shows the
    // reason (Panasonic prints "Camera operation is in progress." and disables the
    // phone's controls; Canon publishes the per-mode table as documentation).
    expect(find.text('S 模式下相机自己决定光圈'), findsOneWidget,
        reason: 'the disabled reason the caller passed must be on screen');
  });

  // -------------------------------------------------------------------------
  // 3. Degenerate ladders — the camera decides these, not us
  // -------------------------------------------------------------------------

  testWidgets('an empty ladder renders without a crash and without a command',
      (tester) async {
    final spins = await pumpDial(tester, values: const [], index: 0);
    expect(tester.takeException(), isNull,
        reason: 'an empty list is what a parameter the camera reports no range '
            'for looks like; it must not throw');
    expect(find.byKey(const ValueKey<String>('dial-iso-empty')), findsOneWidget);

    await tester.drag(find.byKey(const ValueKey<String>('dial-iso')),
        const Offset(0, -40), warnIfMissed: false);
    await settle(tester);
    expect(spins, isEmpty);
  });

  testWidgets('a one-entry ladder renders and sends nothing', (tester) async {
    // The DJI 15mm f/1.7 case: one aperture is not a choice, and a dial that
    // pretends otherwise is worse than no dial.
    final spins = await pumpDial(tester,
        values: const ['1.7'], index: 0, param: ExposureParam.aperture,
        size: const Size(183, kDialHeight));
    expect(tester.takeException(), isNull);
    expect(find.text('f/1.7'), findsWidgets,
        reason: 'the single legal value must still be readable');
    expect(find.byKey(const ValueKey<String>('dial-aperture-empty')),
        findsNothing,
        reason: 'one value is a real value, not an empty ladder — a dial that '
            'shows a dash here is telling the user the camera has no aperture');

    final dec = tester.widget<IconButton>(
        find.byKey(const ValueKey<String>('dial-aperture-decrement')));
    final inc = tester.widget<IconButton>(
        find.byKey(const ValueKey<String>('dial-aperture-increment')));
    expect(dec.onPressed, isNull,
        reason: 'there is nothing below the only value');
    expect(inc.onPressed, isNull,
        reason: 'there is nothing above the only value');
    expect(spins, isEmpty);
  });

  testWidgets('tapping a half steps it to the value **drawn in that half**',
      (tester) async {
    // Tap-to-step is how the control works before the user discovers that it also drags.
    // Asserted on a short ladder where the arithmetic is unambiguous.
    //
    // ## Why the expectations are the way round they are
    //
    // **This check is the one that missed a real defect, so the shape of it matters.**
    // It used to read `['v003']` for the upper half and `['v001']` for the lower, i.e. it
    // asserted the **value direction** (upper = higher value). When the drawn ladder was
    // reversed — larger values now drawn **below** the readout, on the user's instruction
    // that the markings should follow the thumb — that value direction did **not** change,
    // so this test stayed green while the tap zones silently became inverted: tapping the
    // marking above the readout selected the one below it, and missed it by one step.
    // Measured on the real page at ISO 400: upper half -> **800** (drawn below),
    // lower half -> **200** (drawn above).
    //
    // It now asserts the promise a tap actually makes: **the half you tap is the marking
    // it selects.** `v001` is the value drawn above the readout and `v003` the one below,
    // so the upper half must produce `v001` and the lower half `v003`. A reader comparing
    // `? -1 : 1` in `_LadderWindow` against these numbers can see the pair is deliberate.
    const size = Size(183, kDialHeight);
    final spins = await pumpDial(tester,
        values: ladder(5), index: 2, size: size);
    final r = tester.getRect(find.byKey(const ValueKey<String>('dial-iso')));

    // x is well left of the two 32 dp arrow buttons, so this is the readout.
    final x = r.left + 30;
    await tester.tapAt(Offset(x, r.top + 20));
    await settle(tester);
    expect(spins, ['v001'],
        reason: 'the upper half is where the **smaller** neighbour is drawn, so tapping it '
            'has to select that neighbour. `v003` here would mean the tap reached the '
            'marking underneath the one it touched');

    final down = await pumpDial(tester,
        values: ladder(5), index: 2, size: size);
    await tester.tapAt(Offset(x, r.top + 44));
    await settle(tester);
    expect(down, ['v003'],
        reason: 'and the lower half is where the **larger** neighbour is drawn');
  });

  testWidgets('the arrow buttons step one detent each', (tester) async {
    // The buttons are the discoverable, reliable way in — a drag is not
    // discoverable and a tap on a readout is not either. Asserted because a
    // stepper wired to the wrong direction is invisible to every other test here.
    // Tapped at the button's own centre rather than at a coordinate derived from
    // the dial's rect: the buttons are 32 dp at the right-hand end of a 175 dp
    // row, and an x picked from the parent's left edge lands on the wrong one.
    const size = Size(183, kDialHeight);
    final up = await pumpDial(tester,
        values: ladder(5), index: 2, size: size);
    await tester.tap(find.byKey(const ValueKey<String>('dial-iso-increment')));
    await settle(tester);
    expect(up, ['v003'], reason: 'increment goes up. Got $up');

    final down = await pumpDial(tester,
        values: ladder(5), index: 2, size: size);
    await tester.tap(find.byKey(const ValueKey<String>('dial-iso-decrement')));
    await settle(tester);
    expect(down, ['v001'], reason: 'decrement goes down. Got $down');
  });

  testWidgets('the 57-entry shutter ladder is usable at both ends',
      (tester) async {
    expect(kShutterSpeeds.length, greaterThan(50),
        reason: 'the shutter ladder is the long one; if it ever shrinks, the '
            'long-list case stops being covered');

    for (final i in <int>[0, 20, 56]) {
      await pumpDial(tester,
          values: kShutterSpeeds, index: i, param: ExposureParam.shutter);
      expect(tester.takeException(), isNull, reason: 'index $i');
      expect(find.text(shutterLabel(kShutterSpeeds[i])), findsWidgets,
          reason: 'the readout at index $i');
    }
  });

  // -------------------------------------------------------------------------
  // 4. Fit — measured against the real band
  // -------------------------------------------------------------------------

  testWidgets('the dial fits the 183 dp control band at scale 1.0',
      (tester) async {
    await pumpDial(tester,
        values: kShutterSpeeds, index: 40, param: ExposureParam.shutter);
    expect(tester.takeException(), isNull);

    final r =
        tester.getRect(find.byKey(const ValueKey<String>('dial-shutter')));
    expect(r.width, lessThanOrEqualTo(bandWidth),
        reason: 'a dial wider than the band is scaled down by the band\'s '
            'FittedBox, which is how the 68 dp shutter came to be drawn at '
            '34.4 dp (analysis/45)');
    expect(r.height, lessThanOrEqualTo(64.0),
        reason: 'three dials plus the shutter and the navigation row have to fit '
            '411 dp of height');
  });

  testWidgets('no overflow at the longest value, a narrow band, and 2.0 text',
      (tester) async {
    // Three ways this can break at once: the longest string in any pool
    // (`1/4000s`), a band narrower than the reference device's, and the largest
    // system font size `analysis/45` §7 tests at.
    for (final size in <Size>[
      const Size(150, 64),
      const Size(bandWidth, 64),
    ]) {
      for (final scale in <double>[1.0, 1.3, 2.0]) {
        await pumpDial(tester,
            values: kShutterSpeeds, index: 56, param: ExposureParam.shutter,
            size: size, textScale: scale);
        expect(tester.takeException(), isNull,
            reason: 'overflowed at ${size.width}dp x$scale — a RenderFlex '
                'overflow is an error, not a cosmetic warning');
        final r =
            tester.getRect(find.byKey(const ValueKey<String>('dial-shutter')));
        expect(r.width, lessThanOrEqualTo(size.width + 0.5),
            reason: 'painted outside the box it was given, at '
                '${size.width}dp x$scale');
      }
    }
  });

  // -------------------------------------------------------------------------
  // 6. The strip — three dials, one radio
  // -------------------------------------------------------------------------

  testWidgets('the strip stacks the three dials inside the control band',
      (tester) async {
    // The band on the reference device: 183 dp of width, and the height the three
    // dials need. Measured rather than assumed — this is the number
    // `analysis/51` records, and the assertion is what stops it drifting.
    const stackHeight = 3 * kDialHeight + 2 * 4.0;
    final seen = <String>[];
    await tester.binding.setSurfaceSize(const Size(bandWidth, stackHeight));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      home: Scaffold(
        backgroundColor: Colors.black,
        body: ExposureDialStrip(
          values: const {
            ExposureParam.aperture: ['1.7', '2.0', '2.8'],
            ExposureParam.shutter: ['1/60s', '1/125s', '1/250s'],
            ExposureParam.iso: ['100', '200', '400'],
          },
          current: const {
            ExposureParam.aperture: '1.7',
            ExposureParam.shutter: '1/125s',
            ExposureParam.iso: '200',
          },
          codes: const {
            ExposureParam.aperture: 'RCFNSet',
            ExposureParam.shutter: 'RCShutterSpeedSet',
            ExposureParam.iso: 'RCISOSet',
          },
          onSet: (command, value) => seen.add('$command=$value'),
        ),
      ),
    ));
    await tester.pump();

    expect(tester.takeException(), isNull);
    for (final p in ExposureParam.values) {
      final f = find.byKey(ValueKey<String>(p.keyName));
      expect(f, findsOneWidget, reason: '${p.keyName} is missing from the strip');
      final r = tester.getRect(f);
      debugPrint('  ${p.keyName}: ${r.width.toStringAsFixed(1)} x '
          '${r.height.toStringAsFixed(1)} @ y=${r.top.toStringAsFixed(1)}');
      expect(r.width, lessThanOrEqualTo(bandWidth),
          reason: '${p.keyName} is wider than the band it must fit');
      expect(r.height, closeTo(kDialHeight, 0.5));
    }

    // The three must be stacked, not overlapping: each one's top is below the
    // previous one's bottom.
    final rects = [
      for (final p in ExposureParam.values)
        tester.getRect(find.byKey(ValueKey<String>(p.keyName))),
    ];
    for (var i = 1; i < rects.length; i++) {
      expect(rects[i].top, greaterThanOrEqualTo(rects[i - 1].bottom),
          reason: 'dial $i overlaps the one above it');
    }
    expect(rects.last.bottom, lessThanOrEqualTo(stackHeight + 0.5),
        reason: 'the stack is taller than the room the band has');
    expect(stackHeight, lessThanOrEqualTo(230.0),
        reason: 'the shutter bar and the navigation row also live in this 411 dp '
            'band; a stack taller than ~230 dp does not leave them room');
  });

  testWidgets('two dials turned at once still produce one command per window',
      (tester) async {
    // The strip's own reason to exist: the bound is on the **link**, not on a
    // control. Three dials each promising to be quiet is three streams of
    // requests from one radio.
    final seen = <String>[];
    await tester.binding.setSurfaceSize(
        const Size(bandWidth, 3 * kDialHeight + 8));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      home: Scaffold(
        backgroundColor: Colors.black,
        body: ExposureDialStrip(
          window: const Duration(milliseconds: 200),
          values: {
            ExposureParam.aperture: ladder(40),
            ExposureParam.shutter: ladder(40),
            ExposureParam.iso: ladder(40),
          },
          current: const {
            ExposureParam.aperture: 'v020',
            ExposureParam.shutter: 'v020',
            ExposureParam.iso: 'v020',
          },
          codes: const {
            ExposureParam.aperture: 'RCFNSet',
            ExposureParam.shutter: 'RCShutterSpeedSet',
            ExposureParam.iso: 'RCISOSet',
          },
          onSet: (command, value) => seen.add('$command=$value'),
        ),
      ),
    ));
    await tester.pump();

    // A user changing their mind quickly between three parameters.
    for (final key in [
      'dial-aperture-increment',
      'dial-shutter-increment',
      'dial-iso-increment',
      'dial-aperture-increment',
    ]) {
      await tester.tap(find.byKey(ValueKey<String>(key)));
      await tester.pump(const Duration(milliseconds: 30));
    }
    await tester.pump(const Duration(milliseconds: 400));

    expect(seen, isNotEmpty,
        reason: 'the strip must actually send something');
    expect(seen.length, lessThanOrEqualTo(4),
        reason: 'four changes across ~120 ms must not become more than four '
            'requests — and must never become one per detent. Got $seen');
    expect(seen.last, 'RCFNSet=v022',
        reason: 'and the LAST thing the user did must be what the camera ends up '
            'holding — the aperture went up twice from v020, so v022. Got $seen');
    // What the strip adds over three independent dials is not a lower count here
    // (four taps legitimately produce up to four paced commands) but the fact
    // that the count is bounded **per link** rather than per control, and that
    // the last value always survives. Both are asserted above and below.
    expect(seen.toSet().length, seen.length,
        reason: 'no command may be sent twice; got $seen');
  });

  // -------------------------------------------------------------------------
  // 7. Formatting — the readout, not the wire value
  // -------------------------------------------------------------------------

  test('labels are the camera strings made human, never re-spelled values', () {
    // The wire value goes to the camera; the label is what the user reads. These
    // are different strings and must stay different: sending the label would be a
    // protocol change, and `analysis/07` records what a re-spelled parameter
    // costs (the firmware's own `resulotion` is the precedent).
    expect(apertureLabel('1.7'), 'f/1.7');
    expect(apertureLabel('10'), 'f/10');
    expect(shutterLabel('1/125s'), '1/125');
    expect(shutterLabel('1s'), '1"');
    expect(shutterLabel('2s'), '2"');
    expect(shutterLabel('1/1.3s'), '1/1.3');
    expect(shutterLabel('BULB'), 'BULB');
    expect(shutterLabel('TIME'), 'TIME');
    expect(isoLabel('Auto'), 'Auto');
    expect(isoLabel('12800'), '12800');

    // And the round trip: every label maps back to the wire value it came from,
    // so a caller can never accidentally send a label.
    for (final v in kShutterSpeeds) {
      expect(wireForLabel(shutterLabel(v), kShutterSpeeds, ExposureParam.shutter),
          v,
          reason: 'label ${shutterLabel(v)} must round-trip');
    }
    for (final v in kFNumbers) {
      expect(wireForLabel(apertureLabel(v), kFNumbers, ExposureParam.aperture),
          v);
    }
    for (final v in kIsoValues) {
      expect(wireForLabel(isoLabel(v), kIsoValues, ExposureParam.iso), v);
    }
    // A label is not a value: asking for one in the wrong pool finds nothing,
    // which is what stops a caller sending a display string to the camera.
    expect(wireForLabel('f/1.7', kIsoValues, ExposureParam.iso), isNull);
  });
}
