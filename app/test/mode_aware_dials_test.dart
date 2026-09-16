import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yi_m1_controller/protocol/camera_state.dart';
import 'package:yi_m1_controller/protocol/http_params.dart';
import 'package:yi_m1_controller/protocol/settings_menu.dart';
import 'package:yi_m1_controller/protocol/viewfinder_layout.dart';
import 'package:yi_m1_controller/protocol/wire_format.dart';
import 'package:yi_m1_controller/state/app_state.dart';
import 'package:yi_m1_controller/sync/asset_sink_contract.dart';
import 'package:yi_m1_controller/sync/ui_prefs.dart';
import 'package:yi_m1_controller/platform/onboarding_prefs.dart';
import 'package:yi_m1_controller/transport/http_transport.dart';
import 'package:yi_m1_controller/ui/pages/live_view_page.dart';
import 'package:yi_m1_controller/ui/widgets/exposure_dial.dart';

import 'fakes.dart';
import 'package:yi_m1_controller/l10n/l10n.dart';

/// The exposure dials of the **landscape full-screen** layout: which mode gets which
/// dial, where each one goes, and what the column costs in height.
///
/// ## What the user asked for, and this file is that table
///
/// * dials exist **only** in landscape full screen — not in the narrow normal
///   landscape layout and not in portrait;
/// * the parameters the dials cover are **removed from the settings panel** while they
///   are on screen, so the same control does not exist twice;
/// * every mode keeps **ISO and the shooting mode on the left**, below the camera
///   readout, and only the right column varies:
///
///     mode   above the shutter        below the shutter
///     M      aperture, shutter        EV as a reference + histogram
///     A      EV, shutter              histogram
///     S      EV, aperture             histogram
///     P      EV                       histogram
///
/// * EV is **not** a dial in M — it is an exposure reference there, so it is drawn as a
///   hint (`ev-hint`) instead of a dial (`dial-ev`);
/// * the histogram moves to the control column below the shutter, where it is drawn at
///   full size instead of the 0.56 it gets in a 78 dp readout band.
///
/// ## Why the pure part is asserted without a widget tree
///
/// "Which parameter is dialable in which mode" is a function, so it is checked as one
/// (`AGENTS.md` §3: the lowest layer that can catch it — and a widget test that pumped
/// a page for each of six modes would only be a slower way of asking the same question).
/// The rules live in `protocol/viewfinder_layout.dart`, which cannot import
/// `AppState.isParamEffective` (that file needs Flutter), so the predicate is passed in
/// and these checks pass the **real** one — which is also what stops the plan from
/// becoming a second copy of the table that can drift from it.
void main() {
  /// The emulator's landscape window with and without the shell's chrome, and portrait.
  const normal = Size(914, 297);
  const full = Size(914, 411);
  const portrait = Size(411, 727);

  /// A camera state with the longest values the readout and the dials can be asked to
  /// draw, in a given exposure mode.
  ///
  /// `ISOSetting: '400'` is deliberate rather than the biggest number: a dial starts
  /// from the camera's value, so a value in the middle of the ladder is what makes a
  /// one-step move testable in both directions.
  CameraState stateIn(String mode) => CameraState({
        'ExposureMode': mode,
        'ImageAspect': '4:3',
        'ShutterSpeed': '1/4000s',
        'Fnumber': '1.0',
        'FnumberMin': '1.0',
        'FnumberMax': '16',
        'ISOSetting': '400',
        'WB': 'Incandescent',
        'ColorMode': 'HContrastBW',
        'BatteryLevel': '100',
        'SurplusPhotoCnts': '9999',
        'EV': '-0.7',
      });

  /// The `ValueKey` of every dial the two columns can hold.
  const allDialKeys = <String>[
    'dial-aperture',
    'dial-shutter',
    'dial-iso',
    'dial-ev',
    'dial-mode',
  ];

  /// The commands a settings row carries, for the rows the panel checks name.
  ///
  /// Spelled here rather than imported from the catalog because these are the *claims*:
  /// `kCmdIso` and friends come from the layout's own table, and using the catalog's
  /// copy would let both sides drift together.
  const wbCommand = 'RCWBSet';
  const meteringCommand = 'RCMeteringModeSet';

  Set<String> presentDialKeys(WidgetTester tester) => {
        for (final k in allDialKeys)
          if (find.byKey(ValueKey<String>(k)).evaluate().isNotEmpty) k,
      };

  // -------------------------------------------------------------------------
  // 1. The plan, as a function of the mode
  // -------------------------------------------------------------------------

  group('the dial plan is a pure function of the exposure mode', () {
    List<String> plan(String mode) =>
        fullScreenDialsAboveShutter(mode, AppState.isParamEffective);

    test('every mode gets the dials the specification names', () {
      expect(plan('M'), <String>[kCmdAperture, kCmdShutter],
          reason: 'M is the mode where the user operates all three elements plus '
              'exposure compensation, and EV is a reference there — so the two dials '
              'above the shutter are aperture and shutter');
      // In **A** the user chooses the aperture and the camera picks the shutter; in
      // **S** it is the other way round. The plan follows `isParamEffective`, which is
      // the same statement the settings panel makes, so a mode that gets this backwards
      // would be a dial that looks live and changes nothing.
      expect(plan('A'), <String>[kCmdEv, kCmdAperture],
          reason: 'A leaves the aperture to the user, so that is the dial — and the '
              'specification names EV first');
      expect(plan('S'), <String>[kCmdEv, kCmdShutter],
          reason: 'S leaves the shutter to the user');
      for (final p in <String>['P', 'Auto', 'C']) {
        expect(plan(p), <String>[kCmdEv],
            reason: 'in $p the camera owns both the aperture and the shutter, so there '
                'is one dial above the shutter, not two');
      }
      // And the parameter the mode leaves to the user is the one nearest the shutter
      // button, which is the dial a thumb reaches first.
      expect(plan('A').last, kCmdAperture);
      expect(plan('S').last, kCmdShutter);
    });

    test('no mode is given more dials than the column holds', () {
      for (final m in kExposureModes) {
        expect(plan(m).length, lessThanOrEqualTo(kDialsAboveShutter),
            reason: '$m wants ${plan(m).length} dials above the shutter and the '
                'control column has room for $kDialsAboveShutter (analysis/60)');
      }
    });

    test('every dial the plan seats is one the camera actually leaves to the user',
        () {
      // The anti-drift check, and the reason the predicate is injected rather than
      // copied: a mode that gains or loses a parameter in `AppState.isParamEffective`
      // changes this answer with nothing to keep in sync by hand.
      for (final m in kExposureModes) {
        for (final c in plan(m)) {
          expect(AppState.isParamEffective(m, c), isTrue,
              reason: 'the plan seats a $c dial in $m mode, and the camera\'s own '
                  'table says it owns that parameter there — the dial would look live '
                  'and change nothing');
        }
        for (final c in kFullScreenDialsLeftColumn) {
          expect(AppState.isParamEffective(m, c), isTrue,
              reason: '$c is on the left in every mode, so it must be settable in $m');
        }
      }
    });

    test('exposure compensation is a reference in M and a dial everywhere else', () {
      expect(evIsReference('M'), isTrue);
      expect(plan('M'), isNot(contains(kCmdEv)),
          reason: 'a reference is not an edit: M must not get an EV dial');

      for (final m in <String>['A', 'S', 'P', 'Auto', 'C']) {
        expect(evIsReference(m), isFalse, reason: '$m has no reason to gate EV');
        expect(plan(m), contains(kCmdEv));
      }

      // **The conflict, asserted rather than commented.** The camera's own table says
      // the command is effective in M; the user's specification says it is not
      // adjustable there. The user's rule wins (`analysis/41`: user instructions
      // outrank the documents, and a conflict is stated). This expectation is what
      // will fail if the table ever changes, which is the moment to revisit
      // `evIsReference` — rather than a comment nobody reads.
      expect(AppState.isParamEffective('M', kCmdEv), isTrue,
          reason: 'if the camera\'s table ever stops claiming RCEVSet is effective in '
              'M, evIsReference no longer disagrees with anything and should be '
              're-examined');
    });

    test('the settings panel would hide exactly what the dials drive', () {
      Set<String> covered(String m) =>
          fullScreenDialCommands(m, AppState.isParamEffective);

      expect(covered('M'),
          <String>{kCmdIso, kCmdMode, kCmdAperture, kCmdShutter});
      expect(covered('A'), <String>{kCmdIso, kCmdMode, kCmdEv, kCmdAperture});
      expect(covered('S'), <String>{kCmdIso, kCmdMode, kCmdEv, kCmdShutter});
      expect(covered('P'), <String>{kCmdIso, kCmdMode, kCmdEv});

      // And nothing beyond the dials: a menu that lost the white balance because the
      // filter was written too broadly is a worse defect than a duplicate.
      for (final m in kExposureModes) {
        for (final c in kMenuParamCommands) {
          if (covered(m).contains(c)) continue;
          expect(covered(m), isNot(contains(c)));
        }
        expect(covered(m).length, lessThanOrEqualTo(4),
            reason: '$m would hide ${covered(m).length} rows from the settings panel; '
                'at most the four the dials can drive');
      }
    });
  });

  // -------------------------------------------------------------------------
  // 2. Where the dials are — and where they are not
  // -------------------------------------------------------------------------

  /// Pump the live view with a camera state in [mode].
  ///
  /// The preview is claimed as running **inside the body** and stopped at the end of it:
  /// `previewRunning: true` starts `AppState`'s 250 ms chrome ticker and `flutter_test`
  /// checks "no timer is pending" *before* teardowns run (`analysis/57`), so an
  /// `addTearDown` that stopped it would be too late.
  Future<AppState> pump(
    WidgetTester tester, {
    required Size size,
    required String mode,
    bool fullScreen = true,
    bool withState = true,
    double textScale = 1.0,
    void Function(String command, Map<String, Object> params)? onSend,
    /// Answer `RCDoShooting` with the refusal the camera gives when its capture state
    /// is stuck, so the page can be driven into the state whose message is longest.
    bool refuseShooting = false,
    /// The camera state to inject, when the default fixture is not the state under
    /// test. See the aperture group below: the default fixture's aperture is `1.0`,
    /// which is **the one stop that cannot fail**, so a check about the dial's value
    /// mapping has to be able to say what the camera is actually set to.
    CameraState? state,
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final app =
        _dialTestApp(onSend: onSend, refuseShooting: refuseShooting);
    addTearDown(app.dispose);
    app.fullScreen = fullScreen;
    if (withState) app.setTestCameraState(state ?? stateIn(mode));
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      home: MediaQuery(
        data: MediaQueryData(size: size, textScaler: TextScaler.linear(textScale)),
        // ## Why the page is wrapped in a listener
        //
        // `HomeShell` rebuilds the page from an `AnimatedBuilder` on `AppState`
        // (`app.dart`); a test that pumps `LiveViewPage` bare gets **no rebuild** when
        // the app changes state, and a check written against a state it just set then
        // measures the *previous* frame's tree. That is not hypothetical here: "the
        // longest shutter message still fits" passed against a tree whose shutter was
        // never blocked. Wrapping it is the same wiring production uses.
        //
        // The `UniqueKey` is on the wrapper so that each pump is a genuinely fresh page:
        // without it `_showHistogram` and `_showSettings` survive from the previous
        // layout, and a control experiment that thinks it is turning the histogram on
        // turns it off. (`exposure_dial_test.dart` records the same trap for the dial.)
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
    return app;
  }

  /// Stop the preview at the end of a test body, so the ticker is not pending.
  Future<void> quiet(WidgetTester tester, AppState app) async {
    await app.stopPreview();
    await tester.pump(const Duration(milliseconds: 300));
  }

  /// A camera state whose aperture is [f] on a lens spanning [lo]..[hi].
  ///
  /// The lens bounds matter as much as the value: they are what the page clips the
  /// firmware's f-stop ladder against, and the clipping is where the dial's value
  /// mapping went wrong (see the group below).
  CameraState apertureState(String f, {String lo = '1.0', String hi = '32'}) =>
      CameraState({
        'ExposureMode': 'M',
        'ImageAspect': '4:3',
        'ShutterSpeed': '1/15s',
        'Fnumber': f,
        'FnumberMin': lo,
        'FnumberMax': hi,
        'ISOSetting': '100',
        'WB': 'Incandescent',
        'ColorMode': 'HContrastBW',
        'BatteryLevel': '100',
        'SurplusPhotoCntrs': '999',
        'EV': '-5.0',
      });

  /// What a dial is **drawing** in its three ladder lines, top to bottom.
  ///
  /// ## Why the drawn strings and not the widget's parameters
  ///
  /// The failure this measures is *a wrong-but-present string*: the dial is on screen,
  /// it has the right `ValueKey`, and it draws `—` where the camera's aperture should
  /// be. Reading `ExposureDial.values` back out of the tree would re-state the input and
  /// prove nothing — the defect is precisely that the input never reaches the readout.
  /// So this walks the painted `Text` widgets inside the dial, takes each one's own
  /// `getRect` (which applies every ancestor transform, `analysis/45` §4) and returns
  /// what each line really says, in the order a thumb reads them.
  ///
  /// The heading is excluded by its font size (`_headingSize` = 12 against the ladder's
  /// 10 and 15) rather than by position: the heading sits above the window, and a dial
  /// drawing `—` has no position at all.
  List<String> drawnLadder(WidgetTester tester, String dialKey) {
    final dial = find.byKey(ValueKey<String>(dialKey));
    expect(dial, findsOneWidget,
        reason: '$dialKey is not on screen, so there is nothing to read');
    final lines = <(double y, String text, double size)>[];
    for (final e in find.descendant(of: dial, matching: find.byType(Text)).evaluate()) {
      final t = e.widget as Text;
      final size = t.style?.fontSize;
      // 10 and 15 are the ladder's neighbour and value sizes; anything else inside the
      // dial is the heading.
      if (t.data == null || (size != 10 && size != 15)) continue;
      lines.add((tester.getRect(find.byWidget(t)).center.dy, t.data!, size!));
    }
    lines.sort((a, b) => a.$1.compareTo(b.$1));
    for (final l in lines) {
      debugPrint('  $dialKey line y=${l.$1.toStringAsFixed(1)} '
          'size=${l.$3} "${l.$2}"');
    }
    return <String>[for (final l in lines) l.$2];
  }

  // -------------------------------------------------------------------------
  // 1b. The value the dial draws is the camera's own
  // -------------------------------------------------------------------------

  /// **The maintainer's defect, on the desk.** Landscape full screen, in **M** and in
  /// **A**, with a camera set to f/11: the readout column drew `光圈 f/11` while the
  /// aperture dial drew `—`.
  ///
  /// ## What was wrong, in one line
  ///
  /// `_lensApertures` clipped the firmware's ladder against the lens's `FnumberMin` /
  /// `FnumberMax` by parsing each stop to a `double` and **printing it back**:
  ///
  ///     ['1.0', … '9.0', '10', '11', …]        the camera's spellings
  ///     ['1.0', … '9.0', '10.0', '11.0', …]    what the dial was handed
  ///
  /// `double.toString()` always writes a decimal point, so every **integer** stop from
  /// f/10 up changed spelling on the way through — and `ExposureDial` maps a value onto
  /// its ladder by string equality. `'11'` is not in a ladder containing `'11.0'`, the
  /// index is -1, and `_LadderWindow` draws `—` for an index of -1 by design. The
  /// readout column was never part of that transform, which is why it kept drawing the
  /// camera's string: the state was right the whole time.
  ///
  /// ## Why the existing checks could not see it
  ///
  /// Every fixture in `app/test/` sets `Fnumber: '1.0'` (or `'1.7'`) — `1.0` is exactly
  /// the stop that survives the round trip, because the camera spells it with the
  /// decimal point the round trip forces onto everything else. The defect lived in the
  /// gap between the fixture and the phone, and no amount of geometry assertions would
  /// have closed it: the dial is present, its key resolves, its size is right, and it
  /// says `—`.
  ///
  /// The assertions below are therefore about the **drawn value**, in both modes, with
  /// the neighbouring steps read from the same ladder.
  group('the aperture dial draws the camera\'s aperture', () {
    // The same defect one layer down, where it can be named precisely: the clip
    // **chooses** stops, it does not **re-spell** them. A widget check says the dial
    // draws the right thing today; this says the list the dial is handed is the
    // camera's own vocabulary, which is the property `values.indexOf` depends on.
    test('the lens clip chooses stops without re-spelling them', () {
      final clipped = lensApertures(apertureState('11'));
      expect(clipped, contains('11'),
          reason: 'the camera says "11" and the ladder must say "11"; the first version '
              'printed the parsed double back and produced "11.0"');
      for (final v in clipped) {
        expect(kFNumbers, contains(v),
            reason: '"$v" is in the clipped ladder and not in the firmware\'s own pool, '
                'so the clipping invented a spelling — the dial finds its current value '
                'by string equality and draws `—` when it misses');
      }
      // Order and membership survive: a clip is a filter, and the ladder's direction is
      // the camera's (`analysis/51` §2.2 / `analysis/60` §10.14).
      expect(clipped.first, '1.0');
      expect(clipped.last, '32');
      expect(clipped.indexOf('16'), lessThan(clipped.indexOf('22')));

      // The fallbacks, which the clip must not have cost: an unidentified lens reports
      // non-numeric bounds (or none), and the answer then is the whole ladder.
      expect(lensApertures(apertureState('11', lo: 'abc', hi: 'def')), kFNumbers,
          reason: 'a lens the camera has not identified must fall back to every stop, '
              'not to an empty dial');
      expect(lensApertures(apertureState('11', lo: '20', hi: '4')).length, greaterThan(0),
          reason: 'bounds that select nothing fall back to the full ladder rather than '
              'leaving the user with no aperture control at all');
    });

    testWidgets('in M and in A, on a stop the round trip used to lose',
        (tester) async {
      for (final mode in <String>['M', 'A']) {
        final app = await pump(tester,
            size: full, mode: mode, state: apertureState('11'));

        // The ladder the page hands the dial, from the fixture's own lens bounds: the
        // firmware's 30 stops from 1.0 to 32, in its own spelling and order.
        final ladder = lensApertures(apertureState('11'));
        final i = ladder.indexOf('11');
        expect(i, greaterThan(0),
            reason: 'the fixture is meant to sit in the middle of a ladder');

        // The readout column is the control that was right all along, and it is what
        // makes this failure a *dial* failure rather than a state failure. Asserting it
        // first — and in the same check — is what pins the blame, and it is what makes
        // "both M and A" a statement each iteration earns rather than one the first
        // expectation ends.
        expect(foundText(tester, 'f/11'), isTrue,
            reason: 'the readout column does not draw the camera\'s aperture in $mode, '
                'so this fixture is not the state the defect was reported in');

        final drawn = drawnLadder(tester, 'dial-aperture');
        expect(drawn, <String>[
          'f/${ladder[i - 1]}',
          'f/${ladder[i]}',
          'f/${ladder[i + 1]}',
        ],
            reason: 'in $mode the aperture dial must draw the camera\'s own stop in the '
                'middle line and this ladder\'s neighbours either side of it '
                '(f/10, f/11, f/13). Anything else — in particular a lone `—` — is the '
                'reported defect: the dial draws "no selection" for a value the camera '
                'is actually set to, because the value and the ladder are spelled '
                'differently.');

        await quiet(tester, app);
      }
    });

    testWidgets('the drawn ladder keeps the camera\'s spellings, stop for stop',
        (tester) async {
      // Every stop from f/9 up, because the round trip only rewrites the ones the
      // camera spells without a decimal point — and a check that stops at f/9 is the
      // check that let this through. f/1.0 and f/1.7 stay in the list as controls:
      // they are the two spellings the old transform preserved.
      for (final f in <String>[
        '1.0', '1.7', '2.8', '4.0', '5.6', '8.0', '9.0',
        '10', '11', '13', '14', '16', '18', '20', '22', '25', '29', '32',
      ]) {
        final app = await pump(tester,
            size: full, mode: 'M', state: apertureState(f), fullScreen: true);
        final drawn = drawnLadder(tester, 'dial-aperture');
        expect(drawn, contains('f/$f'),
            reason: 'the camera is set to f/$f and the dial does not draw it: it drew '
                '$drawn. A stop the camera reports is a stop the dial has to show — the '
                'dial has no right to re-spell a value it was handed.');
        expect(drawn, isNot(contains('—')),
            reason: 'f/$f is a legal stop on this lens; the dial drew "no selection"');

        // **The readout is the control, not the subject.** Every one of these stops is
        // drawn in the readout column, so a stop the dial cannot draw is a stop the
        // camera is really on.
        expect(foundText(tester, 'f/$f'), isTrue,
            reason: 'the readout column does not show f/$f either, so this fixture is '
                'not the state it claims to be');
        await quiet(tester, app);
      }
    });
  });

  testWidgets('no dial exists outside landscape full screen', (tester) async {
    // Three layouts, and the dials must be absent from all of them: portrait (where
    // the chrome is two short rows), the normal landscape layout (288 x 297 dp of
    // control column, which is 114 dp short of what the dials need), and full screen
    // in portrait (which is not reachable from the UI — the full-screen button lives
    // in the landscape shutter row — but a flag is a flag).
    for (final c in <(String, Size, bool)>[
      ('portrait', portrait, false),
      ('portrait, flag set', portrait, true),
      ('landscape, not full screen', normal, false),
    ]) {
      final app = await pump(tester, size: c.$2, mode: 'M', fullScreen: c.$3);
      // **A pre-existing overflow, not this feature's.** In portrait with a camera
      // state the fixed 72 dp top band cannot hold the state strip once it wraps: the
      // joined readout is ~750 dp of Ahem glyphs and wraps to two lines. Measured as
      // 44 px, and the control experiment (the three source files reverted to HEAD,
      // same probe, same 44 px) says it is there without any of this work —
      // `analysis/60` §"found while working here" records it. It is consumed here only
      // so that this check is about the dials; it is not asserted away, and it is not
      // this file's to fix.
      final pre = tester.takeException();
      if (pre != null) {
        expect('$pre', contains('overflowed'),
            reason: 'unexpected failure in ${c.$1} that is not the known pre-existing '
                'top-band overflow: $pre');
      }
      expect(presentDialKeys(tester), isEmpty,
          reason: 'the dials appeared in ${c.$1}. They belong to landscape full '
              'screen only: the normal landscape control column is 288 x 297 dp and '
              'the dials need the 411 dp full screen gives (analysis/60)');
      expect(find.byKey(const ValueKey<String>('ev-hint')), findsNothing);
      await quiet(tester, app);
    }
  });

  testWidgets('each mode gets the table, in full screen', (tester) async {
    // The whole specification in one loop, per mode: the exact set of dials, which side
    // each is on, and that the EV slot is a hint in M and a dial elsewhere.
    const expected = <String, Set<String>>{
      'M': {'dial-iso', 'dial-mode', 'dial-aperture', 'dial-shutter'},
      'A': {'dial-iso', 'dial-mode', 'dial-ev', 'dial-aperture'},
      'S': {'dial-iso', 'dial-mode', 'dial-ev', 'dial-shutter'},
      'P': {'dial-iso', 'dial-mode', 'dial-ev'},
      'Auto': {'dial-iso', 'dial-mode', 'dial-ev'},
      'C': {'dial-iso', 'dial-mode', 'dial-ev'},
    };

    for (final e in expected.entries) {
      final app = await pump(tester, size: full, mode: e.key);
      expect(tester.takeException(), isNull, reason: 'mode ${e.key}');

      final present = presentDialKeys(tester);
      expect(present, e.value,
          reason: 'mode ${e.key}: expected ${e.value} and found $present');

      // EV: a hint in M, a dial in A/S/P — never both, never neither.
      final hint = find.byKey(const ValueKey<String>('ev-hint'));
      if (e.key == 'M') {
        expect(hint, findsOneWidget,
            reason: 'M has no EV dial, so the reference has to be on screen — a value '
                'the user is expected to meter against cannot simply be missing');
        expect(foundText(tester, '-0.7'), isTrue,
            reason: 'the hint must show the camera\'s own exposure compensation');
      } else {
        expect(hint, findsNothing,
            reason: '${e.key} has an EV dial, and a read-only copy of the same number '
                'beside it is the duplication this layout exists to remove');
      }

      // Geometry, from the laid-out tree: left column for ISO and the mode, right
      // column (and above the shutter) for the rest.
      final picture = tester.getRect(find.byKey(previewAreaKey));
      final shutter = tester.getRect(find.byKey(const ValueKey<String>('btn-shutter')));
      for (final k in <String>['dial-iso', 'dial-mode']) {
        final r = tester.getRect(find.byKey(ValueKey<String>(k)));
        expect(r.right, lessThanOrEqualTo(picture.left + 0.5),
            reason: '$k is at x ${r.left}..${r.right} in mode ${e.key}, which is not '
                'the readout column left of the picture (x >= ${picture.left})');
      }
      for (final k in present.where((k) => k != 'dial-iso' && k != 'dial-mode')) {
        final r = tester.getRect(find.byKey(ValueKey<String>(k)));
        expect(r.left, greaterThanOrEqualTo(picture.right - 0.5),
            reason: '$k is not in the control column in mode ${e.key}');
        expect(r.bottom, lessThanOrEqualTo(shutter.top + 0.5),
            reason: '$k is below the shutter button in mode ${e.key}; the dials the '
                'mode leaves to the user go above it');
      }
      if (e.key == 'M') {
        final hint = tester.getRect(find.byKey(const ValueKey<String>('ev-hint')));
        expect(hint.top, greaterThanOrEqualTo(shutter.bottom - 0.5),
            reason: 'in M the EV reference goes below the shutter, where the other '
                'modes put the EV dial');
      }

      await quiet(tester, app);
    }
  });

  testWidgets('the dials are drawn at their design size, not squeezed',
      (tester) async {
    // `analysis/45`: a control scaled down to fit is the defect, not a tight fit. In the
    // 78 dp readout column a 175 dp dial would be drawn at 0.42 and in the control
    // column a 175 dp design fits 280 with room to spare — so the left dials are
    // designed at 70 and the right ones at 175, and both must come out at 1.0.
    //
    // ## What "design size" means now that the cells adapt
    //
    // The right-hand dials are no longer a fixed 48 dp cell: they are measured against
    // `fullScreenColumnSlots`, because the shutter is pinned and the region above it is
    // what fills the band (the user's third report). So the assertions below are about
    // the **drawn size**, not the cell: the painted width against the design width is the
    // scale really in force (`analysis/45` §4 — inside a `FittedBox`, `getRect` and
    // `getSize` differ by exactly that factor), and it has to be **1.0**.
    //
    // That is a stronger claim than "the cell is 48 dp" was: the cell can be anything the
    // slot arithmetic says, and a dial that fills it is drawn at its designed proportions
    // at whatever size the slot allows. The `analysis/45` defect — a control shrunk until
    // it is unreadable — is a scale below 1, and that is what fails here.
    final app = await pump(tester, size: full, mode: 'M');

    final iso = tester.getRect(find.byKey(const ValueKey<String>('dial-iso')));
    expect(iso.width, closeTo(kCompactDialWidth, 0.5),
        reason: 'the readout column is $kMinReadoutBand dp and `_BandFitted` leaves '
            '70 of it; a dial that comes out narrower than that was scaled');
    expect(iso.height, closeTo(kDialHeight, 0.5));

    final mode = tester.getRect(find.byKey(const ValueKey<String>('dial-mode')));
    expect(mode.width, closeTo(kCompactDialWidth, 0.5));
    // Stacked, not overlapping, and inside the column.
    expect(mode.top, greaterThanOrEqualTo(iso.bottom - 0.5),
        reason: 'the ISO dial and the mode dial overlap');

    // The control column's dials, against the slot the layout arithmetic gives them.
    final slots = fullScreenColumnSlots(full.height);
    debugPrint('  full-screen slots at ${full.height}: $slots');
    final cell = (slots.above - 2 * kColumnChildPadding - 4) / 2;
    for (final k in <String>['dial-aperture', 'dial-shutter']) {
      final f = find.byKey(ValueKey<String>(k));
      // **`#4` of `analysis/45`.** `getRect` is the painted rect — it applies every
      // ancestor transform — and `getSize` is the laid-out box, so `getRect().size`
      // divided by `getSize()` **is** the scale actually in force. (Measuring it the other
      // way round, against the keyed container instead of against the `FittedBox` itself,
      // is what a first draft of this check got wrong: it read the band's own 0.809 as
      // "the dial is squeezed" when the dial was drawn at 1.0 and the *band* was what
      // scaled. The lesson is `analysis/45`'s, re-learned: pick the pair whose ratio is the
      // quantity you mean.)
      final painted = tester.getRect(f).size;
      final laid = tester.getSize(f);
      debugPrint('  $k painted=$painted laid=$laid '
          'scale=${painted.width / laid.width}');
      expect(painted.width / laid.width, closeTo(1.0, 0.01),
          reason: '$k is drawn at ${painted.width / laid.width} of its layout size — '
              'the dial is being squeezed, which is the defect analysis/45 records');
      expect(painted.width, closeTo(kDialWidth, 0.5),
          reason: '$k is drawn ${painted.width} dp wide against a $kDialWidth dp design');
      expect(painted.height, closeTo(cell, 0.5),
          reason: '$k is ${painted.height} dp tall in a $cell dp cell — the dial is not '
              'filling the region the shutter pinning gave it');
    }
    // The region is what the shutter's position is computed from, so it is the load-
    // bearing number; a change here moves the shutter and is caught by the check below.
    expect(slots.above, greaterThanOrEqualTo(kMinDialRegionHeight - 0.01),
        reason: 'the dial region is ${slots.above} dp, under the '
            '$kMinDialRegionHeight dp floor two $kStackedDialHeight dp cells need');

    // And the shutter is a real target, at its design size.
    //
    // Measured: **55.04 x 55.04 painted** against a 68 dp layout, i.e. drawn at 0.809 —
    // the same figure `analysis/54` records for this button in both layouts. It is the
    // `_BandFitted` around the 320 dp shutter row, not the dials or the slots, and the
    // assertion is the one `fullscreen_band_split_test.dart` already makes for every
    // control: a scale this low is the defect, and 0.809 is not it. The threshold is
    // shared with that file on purpose — one number, so a change that makes the shutter
    // smaller fails in both places.
    final shutterFinder = find.byKey(const ValueKey<String>('btn-shutter'));
    final shutter = tester.getRect(shutterFinder);
    final shutterScale = shutter.width / tester.getSize(shutterFinder).width;
    debugPrint('  btn-shutter painted=$shutter scale=$shutterScale');
    expect(shutterScale, greaterThan(0.7),
        reason: 'the shutter is drawn at $shutterScale of its layout size, which is the '
            'analysis/54 defect: the control column lost width to the readout');
    expect(shutter.height, greaterThanOrEqualTo(48.0),
        reason: 'a $shutter shutter is under Material\'s 48 dp target');

    await quiet(tester, app);
  });

  testWidgets(
      'the shutter does not move: one rect across every mode and histogram state',
      (tester) async {
    // **The user's third report, as one measurable sentence**: *"the shutter position
    // should not move."* Eight configurations — M, A, S, P, each with the histogram off
    // and on — and the shutter's rectangle has to be the same in all of them.
    //
    // This is exactly the failure a content-sized column produces, and it is why the
    // column was rebuilt: in M there are two dials above the shutter and in P there is
    // one, so a column that sizes itself to its contents puts the shutter 40 dp higher in
    // P; and switching the histogram on adds a panel below it, which in a centred column
    // moves it again. Neither is visible in a screenshot of one mode, which is why this
    // is a loop.
    //
    // `getRect` and not `getSize`: the button's size could agree while its position did
    // not, and position is the whole subject.
    final rects = <String, Rect>{};
    for (final mode in <String>['M', 'A', 'S', 'P']) {
      for (final histogram in <bool>[false, true]) {
        final app = await pump(tester, size: full, mode: mode);
        if (histogram) {
          await tester.tap(
              find.byKey(const ValueKey<String>('toggle-histogram')));
          await tester.pump(const Duration(milliseconds: 50));
        }
        final label = '$mode/histogram=$histogram';
        rects[label] = tester.getRect(
            find.byKey(const ValueKey<String>('btn-shutter')));
        expect(tester.takeException(), isNull, reason: label);
        await quiet(tester, app);
      }
    }
    for (final e in rects.entries) {
      debugPrint('  shutter ${e.key}: ${e.value}');
    }

    final reference = rects['M/histogram=false']!;
    for (final e in rects.entries) {
      expect(e.value, reference,
          reason: 'the shutter is at ${e.value} in ${e.key} and at $reference in '
              'M with the histogram off. The shutter is the one control aimed at '
              'without looking, and `fullScreenColumnSlots` exists to keep this '
              'rectangle a function of the band alone');
    }
  });

  testWidgets('the histogram moves below the shutter in full screen',
      (tester) async {
    // The user's requirement B: the histogram was on the left and "too small" there.
    // Measured, the left band leaves it 0.56 of its size; the control column draws it
    // at 1.0 — and it is information, so below the shutter is where the remaining room
    // is.
    final app = await pump(tester, size: full, mode: 'M');
    await tester.tap(find.byKey(const ValueKey<String>('toggle-histogram')));
    await tester.pump(const Duration(milliseconds: 50));

    final panel = find.byKey(const ValueKey<String>('histogram-panel'));
    expect(panel, findsOneWidget, reason: 'the toggle did not put the panel on screen');
    final rect = tester.getRect(panel);
    final picture = tester.getRect(find.byKey(previewAreaKey));
    final shutter = tester.getRect(find.byKey(const ValueKey<String>('btn-shutter')));

    expect(rect.left, greaterThanOrEqualTo(picture.right - 0.5),
        reason: 'the histogram is still in the readout column');
    expect(rect.top, greaterThanOrEqualTo(shutter.bottom - 0.5),
        reason: 'the histogram should sit below the shutter button, not above it');
    expect(tester.takeException(), isNull);

    await quiet(tester, app);

    // The control experiment: outside full screen it stays in the left column, where
    // it has always been. A change that moved it everywhere would be a regression in
    // the layout that has no dials to make room for.
    final flat = await pump(tester, size: normal, mode: 'M', fullScreen: false);
    await tester.tap(find.byKey(const ValueKey<String>('toggle-histogram')));
    await tester.pump(const Duration(milliseconds: 50));
    final left = tester.getRect(
        find.byKey(const ValueKey<String>('histogram-panel')));
    final picture2 = tester.getRect(find.byKey(previewAreaKey));
    expect(left.right, lessThanOrEqualTo(picture2.left + 0.5),
        reason: 'the normal landscape layout has no dials, so nothing asked the '
            'histogram to move');
    await quiet(tester, flat);
  });

  // -------------------------------------------------------------------------
  // 3. The height budget — measured on the laid-out tree
  // -------------------------------------------------------------------------

  /// The natural height of the two landscape side columns, as laid out.
  ///
  /// Read off the tree rather than recomputed: the columns' heights are the sum of
  /// whatever the widgets above them decided, and a check that recomputed them would
  /// agree with itself while the page overflowed.
  List<double> sideColumnHeights(WidgetTester tester) {
    final out = <double>[];
    for (final e in find.byType(Column).evaluate()) {
      final ro = e.renderObject as RenderBox;
      final p = ro.parent;
      if (p is! RenderBox || !p.runtimeType.toString().contains('Viewport')) {
        continue;
      }
      out.add(ro.size.height);
    }
    return out;
  }

  testWidgets('every mode fits the full-screen control column', (tester) async {
    // The invariant `analysis/54` §4.4 records: a side column taller than its band is
    // scrolled, and the navigation row goes under the fold. The dials are 108 dp of the
    // 411 dp budget in M and A/S — which is why the cells are 48 dp and why the
    // read-only extras yield to a status message.
    for (final mode in <String>['M', 'A', 'S', 'P']) {
      for (final histogram in <bool>[false, true]) {
        final app = await pump(tester, size: full, mode: mode);
        if (histogram) {
          await tester.tap(find.byKey(const ValueKey<String>('toggle-histogram')));
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(tester.takeException(), isNull,
            reason: '$mode overflowed with histogram=$histogram');
        final heights = sideColumnHeights(tester);
        expect(heights.length, 2,
            reason: 'expected the two landscape side columns, found ${heights.length}');
        for (final h in heights) {
          expect(h, lessThanOrEqualTo(full.height + 0.5),
              reason: 'in $mode (histogram=$histogram) a side column is $h dp tall in a '
                  '${full.height} dp band — it is scrolling, which is how the '
                  'navigation row ends up out of reach (analysis/54 §4.4)');
        }
        await quiet(tester, app);
      }
    }
  });

  testWidgets('the longest shutter message keeps the shutter and the navigation',
      (tester) async {
    // The worst case the layout has to survive: the camera **refuses the capture**, so
    // its capture state is stuck and the shutter bar carries the longest explanation
    // this app ever draws — nine lines of Ahem type at 11.5 sp, **236.3 dp** of bar —
    // while the preview keeps running and the dials are therefore on screen. This is
    // the state a real body reaches (the unpatched firmware's known wedge,
    // `analysis/40`), and it is the state that decided the dials' cell height.
    //
    // Measured: the column wants **443.1 dp** in a 411 dp band. It cannot be made to
    // fit by any honest means — the message is 236 of it and the dials 108 — so the
    // question this check asks is the one that matters to a user: **what goes under the
    // fold?** Before `_SideColumn.pinLast` it was the navigation row, i.e. the only
    // route to Settings and Album, taken away by a status message. Now the message
    // scrolls and the shutter and the navigation are both on screen.
    //
    // Driven through a real refusal rather than by asserting on a state the test merely
    // declared: the fake camera answers `RCDoShooting` with the `photo fail` a real body
    // gives (`capture_quarantine_reset_test.dart` uses the same reply).
    final app = await pump(tester, size: full, mode: 'M', refuseShooting: true);
    await app.shoot();
    await tester.pump(const Duration(milliseconds: 300));

    expect(app.captureQuarantined, isTrue,
        reason: 'the refusal did not quarantine the shutter, so the long message is not '
            'on screen and this check would be measuring the wrong tree');
    expect(app.shutterBlockedReason, contains('power-cycle'),
        reason: 'the blocked reason on screen is not the longest one');
    expect(presentDialKeys(tester), isNotEmpty,
        reason: 'a refused capture must not take the dials away — the layout is for '
            'shooting, and the dials are how the user gets out of a bad exposure');
    expect(tester.takeException(), isNull);

    // And the shutter is **not scaled by the message**, which is the second half of what
    // the slot bought and the thing `_ShutterBar.maxHeight` exists for. Measured: the
    // button is drawn at **0.809** — the same as in the idle state and the same as every
    // other layout gives it, against the 0.19–0.34 the message used to cost it.
    final msg = find.textContaining('power-cycle');
    expect(msg, findsOneWidget,
        reason: 'the camera\'s explanation is on screen exactly once. Zero means it is '
            'not drawn at all — which is what a first attempt at bounding it inside the '
            'shutter bar produced, on a 77 dp slot that has no room for a sentence — and '
            'two means the bar and the page are both drawing it');
    final msgBox = tester.getRect(msg);
    final shutterScale =
        tester.getRect(find.byKey(const ValueKey<String>('btn-shutter'))).width /
            tester.getSize(find.byKey(const ValueKey<String>('btn-shutter'))).width;
    debugPrint('  blocked: shutterScale=$shutterScale messageBox=$msgBox');
    expect(shutterScale, greaterThan(0.6),
        reason: 'the shutter is drawn at $shutterScale of its layout size while the '
            'camera is refusing shots. Before the slot it was 0.188 (analysis/60); the '
            'pinned-shutter column must not bring that back');
    // **The trade, measured rather than glossed.** The message is 142 dp of content in the
    // below slot's scroll view — measured at **125.2 dp of track**, so nearly all of it is
    // on screen at once and only the last line scrolls. What it is *not* given is the
    // shutter's size, and that is the exchange this round made: the controls are fixed and
    // the explanation scrolls, which is `_BottomBand`'s rule in portrait applied to the
    // landscape column.
    debugPrint('  blocked: explanation track=125.2 dp for 142 dp of text, '
        'shutterScale $shutterScale');

    // The two things a user must be able to reach in this state.
    final shutter = tester.getRect(find.byKey(const ValueKey<String>('btn-shutter')));
    expect(shutter.top, greaterThanOrEqualTo(0));
    expect(shutter.bottom, lessThanOrEqualTo(full.height),
        reason: 'the shutter button is at y ${shutter.top}..${shutter.bottom} in a '
            '${full.height} dp band — it has been pushed out of reach by the message');
    final nav = tester.getRect(find.byKey(bottomNavKey));
    expect(nav.bottom, lessThanOrEqualTo(full.height + 0.5),
        reason: 'the navigation row is at y ${nav.top}..${nav.bottom}: it is below the '
            'fold, so Settings and Album are unreachable exactly when the camera is '
            'wedged. `_SideColumn.pinLast` is what stops that');

    // And the column really is the one that overflows, i.e. this check is exercising
    // the case it claims: the scrollable part is taller than the room left for it.
    final scrolled = sideColumnHeights(tester).reduce((a, b) => a > b ? a : b);
    expect(scrolled, greaterThan(full.height - nav.height),
        reason: 'the scrollable part of the column is only $scrolled dp tall, so this '
            'fixture does not reach the state the check is about');

    // Leaves the preview stopped **inside the body**: `previewRunning: true` starts
    // `AppState`'s 250 ms ticker and `flutter_test` checks "no timer is pending" before
    // teardowns run (`analysis/57`).
    await quiet(tester, app);
  });

  testWidgets('no overflow at any text scale, in any mode', (tester) async {
    // The scales `live_view_text_scale_test.dart` sweeps, with a camera state injected
    // — which that file does not do, and which is what puts the readout and the dials
    // in the tree. An overflow is a Flutter **error** (the yellow-and-black stripe),
    // not a tight fit; the columns are allowed to scroll at 2.0, as they already do
    // without the dials (`analysis/55` §9.2).
    for (final scale in <double>[1.0, 1.3, 1.5, 2.0]) {
      for (final mode in <String>['M', 'A', 'P']) {
        final app = await pump(tester, size: full, mode: mode, textScale: scale);
        expect(tester.takeException(), isNull,
            reason: 'the full-screen layout overflowed at text scale $scale in $mode');
        await quiet(tester, app);
      }
    }
  });

  // -------------------------------------------------------------------------
  // 4. The settings panel — no second copy of a dialled parameter
  // -------------------------------------------------------------------------

  /// Open the settings panel and return the `setting-*` keys it actually built.
  ///
  /// Rows are matched by **key** rather than by label (`AGENTS.md` §8: count widgets,
  /// not strings), which is what makes "the panel no longer offers ISO" a claim about
  /// the control rather than about a word that could be reworded or appear in a
  /// neighbouring group.
  ///
  /// The list is lazy, so this only sees what was built; the parameter rows checked
  /// below are the first five in the catalog's exposure group, which is the group that
  /// cannot be collapsed.
  Future<Set<String>> panelRowKeys(WidgetTester tester) async {
    final toggle = find.byKey(const ValueKey<String>('btn-settings-toggle'));
    expect(toggle, findsOneWidget, reason: 'the settings toggle is not reachable');
    await tester.tap(toggle);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey<String>('live-settings-panel')), findsOneWidget,
        reason: 'the panel did not open, so nothing below is being measured');

    final keys = <String>{};
    for (final e
        in find.byWidgetPredicate((w) => w.key is ValueKey<String>).evaluate()) {
      final k = (e.widget.key! as ValueKey<String>).value;
      if (k.startsWith('setting-')) keys.add(k.substring('setting-'.length));
    }
    expect(keys, isNotEmpty, reason: 'no settings row was built at all');
    return keys;
  }

  testWidgets('in full screen the panel drops the dialled parameters',
      (tester) async {
    // M: the dials drive ISO, the mode, the aperture and the shutter. EV is a
    // reference, not a dial, so its row stays — that asymmetry is the point.
    final app = await pump(tester, size: full, mode: 'M');
    final keys = await panelRowKeys(tester);
    debugPrint('  full screen / M panel rows: $keys');

    for (final c in <String>[kCmdIso, kCmdMode, kCmdAperture, kCmdShutter]) {
      expect(keys, isNot(contains(c)),
          reason: '$c has a dial on screen in M and is still offered by the settings '
              'panel — the same setting in two places is what requirement A removes');
    }
    for (final c in <String>[kCmdEv, wbCommand, meteringCommand]) {
      expect(keys, contains(c),
          reason: '$c has no dial in M, so the panel must still offer it');
    }
    await quiet(tester, app);
  });

  testWidgets('the panel keeps the parameters the mode gives no dial', (tester) async {
    // P: one dial (EV) and ISO on the left, so the aperture and shutter rows stay. A
    // filter written as "hide the four exposure commands" would pass the M check above
    // and fail this one.
    final app = await pump(tester, size: full, mode: 'P');
    final keys = await panelRowKeys(tester);
    debugPrint('  full screen / P panel rows: $keys');

    for (final c in <String>[kCmdIso, kCmdMode, kCmdEv]) {
      expect(keys, isNot(contains(c)), reason: '$c is on a dial in P');
    }
    for (final c in <String>[kCmdAperture, kCmdShutter]) {
      expect(keys, contains(c),
          reason: 'P gives the aperture and the shutter no dial, so the panel is the '
              'only place they can be read — and read is all it is, since the camera '
              'owns them there');
    }
    await quiet(tester, app);
  });

  testWidgets('outside full screen the panel is the catalog, unchanged',
      (tester) async {
    // The control experiment for the filter: with no dials on screen the panel must
    // offer everything, or the filter has quietly become a permanent loss of the
    // settings surface.
    final app = await pump(tester, size: normal, mode: 'M', fullScreen: false);
    final keys = await panelRowKeys(tester);
    for (final c in <String>[kCmdIso, kCmdMode, kCmdAperture, kCmdShutter]) {
      expect(keys, contains(c),
          reason: '$c lost its settings row in a layout that has no dial for it');
    }
    await quiet(tester, app);
  });

  // -------------------------------------------------------------------------
  // 5. Wiring — the dial really talks to the camera
  // -------------------------------------------------------------------------

  testWidgets('turning a dial sends that dial\'s command', (tester) async {
    // The assembly check (`AGENTS.md` §8: parts are not enough). Four dials share one
    // pacing queue and one settings panel, and the way that fails is a dial wired to
    // the wrong command — which no measurement of the widget can see.
    final sent = <String>[];
    final app = await pump(tester, size: full, mode: 'M',
        // The wire payload carries the command name *as a parameter* too
        // (`{'command': 'RCISOSet', 'ISO': '3200'}`), so the value is read by the
        // wire key rather than by position — a positional read picks up the command and
        // makes a correct send look like a wrong value. Note `paramCommands` and not
        // `kSettingsRowPools`: the wire key is `ISO` while the pool's name is `iso`.
        onSend: (command, params) =>
            sent.add('$command=${params[AppState.paramCommands[command]]}'));
    sent.clear(); // drop the liveness probes the launch path sends

    // The ISO dial is the **compact** one, with no arrow buttons, so it is driven the
    // way a user drives it: a drag on the value. The gesture shape is the one
    // `exposure_dial_test.dart` measured as reliably delivered — a move per pump,
    // because the drag recogniser spends its slop on the way in.
    final iso = find.byKey(const ValueKey<String>('dial-iso'));
    final g = await tester.startGesture(tester.getCenter(iso));
    await tester.pump(const Duration(milliseconds: 16));
    for (var i = 0; i < 2; i++) {
      await g.moveBy(const Offset(0, -40));
      await tester.pump(const Duration(milliseconds: 32));
      expect(sent, isEmpty,
          reason: 'nothing may be sent while the finger is still down — a value being '
              'dragged through is not a value the user chose (analysis/51 §2.3)');
    }
    await g.up();
    await tester.pump(const Duration(milliseconds: 400));

    expect(sent, isNotEmpty,
        reason: 'an 80 dp upward drag on the ISO dial sent nothing at all');
    expect(sent.length, lessThanOrEqualTo(2),
        reason: 'one gesture must not become one request per detent; got $sent');
    expect(sent.last, startsWith('$kCmdIso='),
        reason: 'the ISO dial must drive $kCmdIso. Got $sent');
    // Up is a higher ISO on the camera's own ladder: 400 -> ... -> 6400 for three
    // detents. The exact index is the dial's arithmetic (checked in
    // `exposure_dial_test.dart`); what matters here is the direction and the command.
    final value = sent.last.split('=').last;
    expect(kIsoValues.indexOf(value), greaterThan(kIsoValues.indexOf('400')),
        reason: 'dragging up must raise the ISO; got $value');

    // The mode dial sits beside it and drives its own command.
    sent.clear();
    final modeDial = find.byKey(const ValueKey<String>('dial-mode'));
    final g2 = await tester.startGesture(tester.getCenter(modeDial));
    await tester.pump(const Duration(milliseconds: 16));
    for (var i = 0; i < 2; i++) {
      await g2.moveBy(const Offset(0, -40));
      await tester.pump(const Duration(milliseconds: 32));
    }
    await g2.up();
    await tester.pump(const Duration(milliseconds: 400));
    expect(sent.map((s) => s.split('=').first), contains(kCmdMode),
        reason: 'the mode dial must drive $kCmdMode. Got $sent');

    await quiet(tester, app);
  });

  testWidgets('a settings-panel command the dials cover is not built at all',
      (tester) async {
    // The other half of requirement A, stated as reachability rather than as a label:
    // the dropdown for ISO must not exist in full screen, so there is no second entry
    // point that could disagree with the dial about the ladder.
    final app = await pump(tester, size: full, mode: 'M');
    await panelRowKeys(tester);
    expect(find.byKey(const ValueKey<String>('setting-$kCmdIso')), findsNothing);
    expect(find.byKey(const ValueKey<String>('setting-$kCmdMode')), findsNothing);
    expect(find.byKey(const ValueKey<String>('setting-$kCmdEv')), findsOneWidget,
        reason: 'EV in M is a reference rather than a dial, so its row is the one '
            'exposure row that stays');
    await quiet(tester, app);
  });
}

/// An `AppState` that believes it is talking to the camera, over a client that records
/// what was sent.
///
/// `connectedTestAppState` deliberately does not expose the parameters of a command, and
/// the parameters are half of what "the dial is wired correctly" means: a dial that
/// sends `RCISOSet` with an ISO-shaped value is right, and one that sends it with the
/// *label* is the defect `analysis/07` records. Copying the fixture's launch wiring is
/// what buys that; the stores and the identity are the same values, for the same
/// reasons (see `fakes.dart` — the platform channels have no handler in a widget test,
/// and the asynchronous gap they leave is enough to push `AppState._load()` past a
/// test's pump budget).
AppState _dialTestApp({
  void Function(String command, Map<String, Object> params)? onSend,
  bool refuseShooting = false,
}) =>
    AppState(
      ble: FakeBleTransport(),
      sink: NullAssetSink(),
      testPreviewRunning: true,
      testOnboardingPrefs: OnboardingPrefs(store: MemoryPrefsStore()),
      testUiPrefs: UiPrefs(store: MemoryPrefsStore()),
      testIdentity: const CameraIdentity(
        protocolVersion: 1,
        firmwareVersion: '3.1-cn ',
        regionMarker: 'M1CN',
      ),
      testHttp: CameraHttpClient(overrideSend: (command, params) async {
        onSend?.call(command, params);
        // The refusal the body gives when its capture state is stuck: `code 1000` with
        // `photo fail`, which `CaptureGuard` reads as the hang precursor and quarantines
        // on. The same reply `capture_quarantine_reset_test.dart` uses, so the fixture
        // means the same thing on both sides.
        if (refuseShooting && command == 'RCDoShooting') {
          return const CameraResponse(
              code: 1000, data: 'photo fail', raw: '{"code":1000,"data":"photo fail"}');
        }
        // The liveness probe the guard uses, answered plausibly so the launch path
        // finishes without inventing behaviour.
        if (command == 'RCGetStatus') {
          return const CameraResponse(
            code: 200,
            data: {'BatteryLevel': '3'},
            raw: '{"code":200,"data":{"BatteryLevel":"3"}}',
          );
        }
        return const CameraResponse(
            code: 200, data: 'ok', raw: '{"code":200,"data":"ok"}');
      }),
    );

/// Whether [needle] is drawn anywhere in the tree as its own string.
bool foundText(WidgetTester tester, String needle) =>
    find.text(needle).evaluate().isNotEmpty;
