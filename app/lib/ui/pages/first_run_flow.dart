import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../l10n/message_text.dart';
import '../../platform/onboarding_prefs.dart';
import '../../state/app_state.dart';
import '../../sync/sync_engine.dart';
import '../../transport/camera_connection.dart';

/// Below this height the flow switches to its compact layout.
///
/// **Measured, not chosen.** A 914x411 landscape window has ~411 dp of height, of
/// which the header and the footer take ~176 dp — so the body gets roughly 235 dp for
/// six lines of pairing steps, a status card and an explanation. The emulator showed
/// the result before this existed: the status card was cut through the middle of a
/// sentence and the last paragraph was entirely off screen. 520 dp is the same
/// threshold the album's sync bar uses for the same reason, so the two screens change
/// shape together on the same device.
///
/// The decision is made from the **box the flow is actually laid out in**
/// (`LayoutBuilder`), not from `MediaQuery`: the same choice `LiveViewPage` makes, and
/// for a reason this change ran into — a widget test's `MediaQuery` reported the
/// binding's default 800x600 while the flow was really being laid out at 914x411, so a
/// `MediaQuery`-based decision was silently never taken and the landscape checks were
/// measuring the portrait layout.
const double kFirstRunCompactBelow = 520;

/// The first-run and pairing flow: three steps, skippable, and never a wall.
///
/// ## Why the app needed one
///
/// The app used to open straight into a **disconnected Capture page**. Everything
/// that matters — the connect button, the press on the camera body, the access point
/// that admits one client — had to be discovered. A user who could not connect had
/// no way to tell whether the app was broken, the camera was off, or a PC was still
/// holding the camera's only pairing.
///
/// ## What it is allowed to be
///
/// * **Three steps, once.** What the app does; how photos should come across; pair
///   now. The step indicator is asserted by number in
///   `test/first_run_flow_test.dart`, so the flow cannot quietly grow — an
///   onboarding screen that grows is one people dismiss without reading.
/// * **Skippable, and the skip is recorded.** A returning user must not be asked
///   again, and [OnboardingPrefs.onboardingDone] is set by skipping as well as by
///   finishing. Skipping still records a sync mode (the engine's own default), so
///   no state is left half-answered.
/// * **Re-openable.** From the app bar's `btn-first-run-guide`, at any link state:
///   the sync mode is a decision people change their minds about, and a flow that
///   can only be seen once is a trap the moment they do.
///
/// ## What it deliberately does not do
///
/// * It does not drive the connection itself. It calls [AppState.connect] — the same
///   call the Capture page's button makes — and renders
///   [LinkStatus.message], the app's own sentence about where the sequence has got
///   to. A second implementation of the sequence would be a second thing to keep in
///   step with the BLE and Wi-Fi behaviour that was expensive to get right.
/// * It does not show a spinner while a human is required. On this camera, pairing
///   waits for somebody to press **Accept** on the body within about ten seconds;
///   [LinkStage.awaitingUserConfirm] is the app saying so, and an animation there
///   would be the app claiming to be busy while the next move belongs to the user.
///   `test/first_run_flow_test.dart` fails if a progress indicator appears in that
///   state, and has a negative control proving the check can tell the difference.
///
/// ## The one thing it cannot finish
///
/// Recording the mode is not applying it. `SyncEngine.mode` lives in the sync layer
/// and is set by the album screen's dropdown; this flow writes the preference and
/// hands it over. The one-line wiring the owner must add is named in
/// `analysis/56-first-run-and-pairing.md` §6 and asserted absent-or-present by
/// nothing, because it is a fact about another file — see that section for why the
/// preference is still worth recording without it.
enum FirstRunEntry {
  /// The app has never been through this. Exiting is a **skip**, and is recorded.
  firstRun,

  /// The user came back on purpose. Exiting just closes; nothing is decided for
  /// them.
  revisit,
}

/// Push the flow. The single entry point, so every caller gets the same wiring.
void openFirstRunFlow(
  BuildContext context, {
  required AppState app,
  required OnboardingPrefs prefs,
  FirstRunEntry entry = FirstRunEntry.firstRun,
  void Function(String modeId)? onModeChosen,
  VoidCallback? onFinished,
  VoidCallback? onExited,
}) {
  Navigator.of(context).push(MaterialPageRoute<void>(
    fullscreenDialog: entry == FirstRunEntry.firstRun,
    builder: (_) => FirstRunFlow(
      app: app,
      prefs: prefs,
      entry: entry,
      onModeChosen: onModeChosen,
      onFinished: onFinished,
      onExited: onExited,
    ),
  ));
}

/// The steps, in order, in the language the reader is using. Three, and the count is
/// asserted.
///
/// A function of [AppLocalizations] rather than a `const` list, because the titles are
/// prose and everything else on the step is now prose in the same language. The **count**
/// is read from this list — by the "Step n of m" line and by the clamp in
/// [_FirstRunFlowState._goTo] — so the titles and the number of steps cannot drift
/// apart.
List<String> firstRunStepTitles(AppLocalizations l) => <String>[
      l.firstRunStepWhatItDoes,
      l.firstRunStepHowPhotosCome,
      l.firstRunStepPair,
    ];

/// One sync mode, as the flow presents it.
///
/// The trade-off is the reason to ask at all, so each mode carries its own sentence
/// about cost rather than a shared footnote: a preview is small and appears in
/// seconds, a full size is several megabytes over a slow radio, and manual moves
/// nothing until the user picks it.
class SyncModeChoice {
  /// The name [OnboardingPrefs] persists. **Never shown and never translated**: it is
  /// in the preference file, so a reworded id would orphan an answer already given.
  final String id;

  /// The one-line answer, resolved in the reader's language when the tile is built.
  final String Function(AppLocalizations l) title;

  /// What that answer costs. A lookup for the same reason as [title].
  final String Function(AppLocalizations l) tradeoff;

  const SyncModeChoice(this.id, this.title, this.tradeoff);
}

/// The prose each mode shows, as lookups rather than as stored strings.
///
/// The ids below are data the preference file holds; the words are not, and they have to
/// follow the reader's language. Naming the ARB getters through top-level functions —
/// rather than storing the sentences here — is also what keeps [kSyncModeChoices] `const`,
/// since a tear-off of a top-level function is a constant expression.
String _autoPreviewTitle(AppLocalizations l) => l.firstRunSyncAutoPreviewTitle;
String _autoPreviewTradeoff(AppLocalizations l) => l.firstRunSyncAutoPreviewBody;
String _autoOriginalTitle(AppLocalizations l) => l.firstRunSyncAutoOriginalTitle;
String _autoOriginalTradeoff(AppLocalizations l) => l.firstRunSyncAutoOriginalBody;
String _manualTitle(AppLocalizations l) => l.firstRunSyncManualTitle;
String _manualTradeoff(AppLocalizations l) => l.firstRunSyncManualBody;

/// The three modes, keyed by the names [OnboardingPrefs] persists.
///
/// Written out rather than derived from `SyncMode`, because the enum carries no
/// user-facing prose and this screen's whole job is the prose. The **ids** are
/// checked against the engine in `test/onboarding_prefs_test.dart`, which is where
/// drift would show up.
const List<SyncModeChoice> kSyncModeChoices = <SyncModeChoice>[
  SyncModeChoice(
    'autoPreviewThenOriginal',
    _autoPreviewTitle,
    _autoPreviewTradeoff,
  ),
  SyncModeChoice(
    'autoOriginalOnly',
    _autoOriginalTitle,
    _autoOriginalTradeoff,
  ),
  SyncModeChoice(
    'manualOnly',
    _manualTitle,
    _manualTradeoff,
  ),
];

/// The three steps, skippable, over whatever route pushed it.
class FirstRunFlow extends StatefulWidget {
  final AppState app;
  final OnboardingPrefs prefs;
  final FirstRunEntry entry;
  final void Function(String modeId)? onModeChosen;
  final VoidCallback? onFinished;
  final VoidCallback? onExited;

  const FirstRunFlow({
    super.key,
    required this.app,
    required this.prefs,
    this.entry = FirstRunEntry.firstRun,
    this.onModeChosen,
    this.onFinished,
    this.onExited,
  });

  @override
  State<FirstRunFlow> createState() => _FirstRunFlowState();
}

class _FirstRunFlowState extends State<FirstRunFlow> {
  int _at = 0;

  /// True once the pairing step has asked the app to connect.
  ///
  /// It **latches**, and that is all it does now: it is what tells the status card the
  /// difference between "nothing has been tried yet" and "an attempt has ended". It
  /// used to gate the button as well, which is how a failed attempt became a dead end —
  /// see [_starting] and [_startPairing].
  bool _pairingStarted = false;

  /// True while a sequence this screen started is still running.
  ///
  /// ## Why this is not just `app.link.isBusy`
  ///
  /// Between the press and the first stage the connection emits there is a window —
  /// `CameraConnection.connect` loads its pairing record before it says anything — in
  /// which the link still describes the **previous** attempt, i.e. `failed`. A guard
  /// that read only the link would let a second press inside that window start a second
  /// connect on a camera whose control path is single-threaded (`analysis/04`). This
  /// flag is set synchronously in the tap handler and cleared when the sequence's own
  /// future completes, so it cannot lag the press it belongs to.
  bool _starting = false;

  @override
  void didUpdateWidget(FirstRunFlow old) {
    super.didUpdateWidget(old);
    // A different `OnboardingPrefs` instance is a different question, and its stored
    // answer has to reach the radios. Without this the step would draw the *previous*
    // object's answer — the same stale-selection defect as below, with the preference
    // swapped out from under it.
    //
    // All that is needed is a rebuild: the answer itself is read at build time. A
    // swap of the preference object is **not** an answer, so nothing is recorded here.
    if (!identical(old.prefs, widget.prefs)) {
      setState(() {});
    }
  }

  bool get _isFirstRun => widget.entry == FirstRunEntry.firstRun;

  /// How many steps the flow has.
  ///
  /// Read from [firstRunStepTitles] rather than kept as a second number beside it: the
  /// titles are a function of the localizations now, and the clamp in [_goTo] and the
  /// "Step n of m" line have to agree with the list they are walking through.
  int get _stepCount => firstRunStepTitles(l10nOf(context)).length;

  /// Record the answer and tell the callback, without rebuilding anything.
  ///
  /// ## Who is allowed to call this
  ///
  /// **Only a user action.** It used to be called from `initState` as well — a brand
  /// new install had the default mode recorded, handed to the running engine and
  /// written to the preference file *before the question was on screen*. On hardware
  /// that is the two `logcat` lines six milliseconds apart:
  ///
  /// ```
  /// first-run gate: seen=false paired=false show=true
  /// first-run: sync mode recorded as autoPreviewThenOriginal
  /// ```
  ///
  /// The value is the default because that is exactly what a step writing its own
  /// default produces. The harm is not cosmetic: the flow exists to ask this **once**,
  /// `askedSyncMode` is set by the write, so the question arrives already answered and
  /// every later launch finds an answer the user never gave. Pre-*selecting* the
  /// default is a different thing and is still done — `_SyncModeStep` draws
  /// `prefs.syncMode ?? kDefaultSyncModeId` — because the app would default to it
  /// anyway and the flow promises that pressing Next changes nothing. Drawing it is
  /// not recording it.
  ///
  /// [persist] false is for the one caller that is about to write the same file again
  /// with more in it ([_finish], which also records that the flow has been seen): two
  /// fire-and-forget writes to one file can land in either order, and the loser of that
  /// race is the one that says the flow has not been seen.
  void _recordMode(String modeId, {bool persist = true}) {
    widget.prefs.setSyncMode(modeId);
    widget.onModeChosen?.call(modeId);
    // Fire and forget on purpose: the answer is in memory immediately and this
    // widget is disposed as soon as the user leaves, so an await here would tie a
    // preference write to a screen's lifetime.
    if (persist) widget.prefs.save();
  }

  /// The user tapped an option: record it **and repaint the step**.
  ///
  /// ## Why the `setState` is the whole fix
  ///
  /// `OnboardingPrefs` is a plain object, not a `ChangeNotifier`, and the selected
  /// option on step 2 is read during this widget's build:
  ///
  /// ```dart
  /// selected: widget.prefs.syncMode ?? kDefaultSyncModeId
  /// ```
  ///
  /// so recording the answer and stopping there updated the preference, left the
  /// `RadioGroup`'s `groupValue` at the previous value, and left the screen showing
  /// the old choice — the reported defect, "choosing a mode does not show in the UI
  /// until you go back a step and return". The `Radio` widgets paint from the group
  /// value they are given, not from the preference, so nothing short of rebuilding
  /// this state can move the tick.
  ///
  /// `setState` is legal here: `RadioGroup.onChanged` runs from the tile's tap
  /// handler, never during a build.
  void _rememberMode(String modeId) {
    _recordMode(modeId);
    setState(() {});
  }

  /// Move to a step.
  ///
  /// ## Why this is an integer and not a `PageView`
  ///
  /// The first version used a `PageView` with `NeverScrollableScrollPhysics` and
  /// drove it with `animateToPage`. **The page never moved.** The controller
  /// reported `hasClients == true` and `page == 0.0`, the step counter advanced to
  /// "Step 2 of 3", and the body went on rendering step 1 — while the same call on a
  /// bare `PageView` worked, which is what made it look like the flow's own bug for
  /// three debugging rounds. `PageView` wraps the physics it is handed in an internal
  /// `_ForceImplicitScrollPhysics`, and `NeverScrollableScrollPhysics` carries
  /// `shouldAcceptUserOffset == false`, which is what swallows the programmatic
  /// animation.
  ///
  /// Not using a `PageView` removes both halves of that: a screen whose only job is
  /// to show three things in order no longer depends on invisible viewport
  /// behaviour, and the swipe it would have allowed — the accidental way past a step
  /// that turns "asked once" into "never read" — cannot happen.
  ///
  /// The step counter and the body are driven by the same integer, so they cannot
  /// disagree, and `first_run_flow_test.dart` asserts that exactly one step is
  /// mounted at a time: the check that would have caught the `PageView` version
  /// immediately.
  void _goTo(int index) {
    final clamped = index.clamp(0, _stepCount - 1);
    if (clamped == _at) return;
    setState(() => _at = clamped);
  }

  void _finish() {
    // The one place a **skip** still records an answer, and the reason the flow can be
    // dismissed without leaving the app half-answered: a user who presses Skip or Done
    // without touching the radios has chosen "whatever the app does anyway", which is
    // the default. What it must not be is a write on *mount* — see [_recordMode].
    //
    // `persist: false` because the two lines below write the same file; this call only
    // fills in the mode, the save underneath writes the mode and the "seen" flag
    // together.
    if (!widget.prefs.askedSyncMode) {
      _recordMode(kDefaultSyncModeId, persist: false);
    }
    widget.prefs.setOnboardingDone(true);
    widget.prefs.save();
    widget.onFinished?.call();
    if (mounted) Navigator.of(context).maybePop();
  }

  void _exit() {
    if (_isFirstRun) {
      // Backing out of a first run **is** the skip: the decision is recorded either
      // way, or the flow returns on the next launch and the button was a lie.
      _finish();
      return;
    }
    widget.prefs.save();
    widget.onExited?.call();
    Navigator.of(context).maybePop();
  }

  void _startPairing() {
    // ## The guard, and what it is not
    //
    // It is "no sequence from this screen is running", **not** "this screen has never
    // asked". The latch version made the first press final: the button went dead for
    // the life of the page, so an attempt that failed could not be retried from inside
    // the flow at all and the user had to leave it and start again — the reported
    // defect, and something the plain Capture page's connect button never did.
    //
    // It is still a guard, though, and the reason has not changed: two connect
    // sequences at once is the known wedge precondition on a camera whose control path
    // is single-threaded (`analysis/04`). So a retry is possible **only after** the
    // previous attempt has ended, which makes the user the rate limit.
    if (_starting) return;
    setState(() {
      _starting = true;
      _pairingStarted = true;
    });
    // Not awaited: the sequence takes tens of seconds and the screen reports its
    // progress through `app.link`, which is where the truth already lives. Awaiting
    // it here would only decide when this widget may repaint. `whenComplete` is what
    // brings the guard down when the attempt really is over — including the failure
    // paths, which is the state the retry exists for.
    widget.app.connect().whenComplete(() {
      if (mounted) setState(() => _starting = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const ValueKey<String>('first-run-flow'),
      backgroundColor: const Color(0xFF0E0E0E),
      body: SafeArea(
        // The layout decision comes from the real box — see [kFirstRunCompactBelow].
        child: LayoutBuilder(
          builder: (context, box) {
            final compact = box.maxHeight < kFirstRunCompactBelow;
            return Column(
              children: [
                _Header(
                  entry: widget.entry,
                  step: _at,
                  onExit: _exit,
                  compact: compact,
                ),
                Expanded(
                  // One step mounted at a time, each with its own key so a check can
                  // count them. The step counter above and this body read the same
                  // `_at`, so they cannot disagree — see [_goTo] for the `PageView`
                  // that could, and did.
                  child: KeyedSubtree(
                    key: ValueKey<String>('onboarding-step-$_at'),
                    child: switch (_at) {
                      0 => _WelcomeStep(compact: compact),
                      1 => _SyncModeStep(
                          // The **object**, not a snapshot of its answer. A string
                          // captured here is a value read once and cached into a
                          // widget field, which is precisely how the selection went
                          // stale: the preference moved and this argument did not.
                          prefs: widget.prefs,
                          onChosen: _rememberMode,
                          compact: compact,
                        ),
                      _ => _PairingStep(
                          app: widget.app,
                          started: _pairingStarted,
                          compact: compact,
                        ),
                    },
                  ),
                ),
                // ## Why the footer is wrapped in an `AnimatedBuilder`
                //
                // This button is the way **back into** a pairing attempt that failed, so
                // whether it is usable is a fact about `app.link` — and the link changes
                // without this widget rebuilding. `_PairingStep` already listens for the
                // same reason (it draws the app's own status sentence); without this the
                // step would say "the camera did not confirm the pairing" while the
                // button that fixes it stayed greyed out until something else happened
                // to rebuild the page.
                AnimatedBuilder(
                  animation: widget.app,
                  // The pairing action lives in the footer rather than on the page, so
                  // it is in the same place on every step and cannot be scrolled out
                  // of reach — a 914x411 landscape window with a large text scale has
                  // very little room above the footer.
                  builder: (context, _) => _Footer(
                    step: _at,
                    last: _stepCount - 1,
                    onBack: _at == 0 ? null : () => _goTo(_at - 1),
                    onNext: () => _goTo(_at + 1),
                    onFinish: _exit,
                    onPair: _startPairing,
                    pairingStarted: _pairingStarted,
                    // A sequence is on the wire: one this screen started, or one the
                    // link already reports (`_starting` covers the window before the
                    // connection emits its first stage).
                    pairingInFlight: _starting || widget.app.link.isBusy,
                    link: widget.app.link,
                    compact: compact,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- chrome

class _Header extends StatelessWidget {
  final FirstRunEntry entry;
  final int step;
  final VoidCallback onExit;
  final bool compact;

  const _Header({
    required this.entry,
    required this.step,
    required this.onExit,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final firstRun = entry == FirstRunEntry.firstRun;
    return Padding(
      // Compact drops the app name and the vertical slack. The step count is the part
      // that has to survive — it is what tells the user this is three screens and not
      // an endless one — and in a 411 dp-tall window every line the header keeps is a
      // line the explanation loses.
      padding: compact
          ? const EdgeInsets.fromLTRB(16, 0, 8, 0)
          : const EdgeInsets.fromLTRB(16, 8, 8, 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!compact) ...[
                  Text(l.appTitle,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                ],
                Text(
                  firstRun
                      ? l.firstRunStepOf(step + 1, firstRunStepTitles(l).length)
                      : l.firstRunTitle,
                  style: TextStyle(
                      color: Colors.white54, fontSize: compact ? 11.5 : 12),
                ),
              ],
            ),
          ),
          // The way out, before anything has been asked. Named "Skip" on a first run
          // because that is what it does — it records that the flow has been seen —
          // and "Close" on a revisit, where nothing is being decided.
          TextButton(
            key: const ValueKey<String>('btn-onboarding-exit'),
            onPressed: onExit,
            child: Text(firstRun ? l.firstRunSkip : l.firstRunClose),
          ),
        ],
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  final int step;
  final int last;
  final VoidCallback? onBack;
  final VoidCallback onNext;
  final VoidCallback onFinish;

  /// Asks the app to start the pairing sequence. Only reachable on the last step.
  final VoidCallback onPair;

  /// True once the sequence has been asked for.
  ///
  /// On its own this is a **latch**, and it used to disable [onPair] for the life of
  /// the page. That was right while an attempt was running and wrong the moment one
  /// ended: the flow wraps the app's connect button, the wrapper could not be pressed
  /// twice, and a failed attempt left the user with no way back in — they had to leave
  /// the flow and start it again. It is kept for the wording (whether an attempt has
  /// been made at all); [pairingInFlight] is what gates the button.
  final bool pairingStarted;

  /// True while a pairing sequence is running, whoever started it.
  final bool pairingInFlight;

  /// The app's own link state, so the button can go live again after an attempt ends.
  final LinkStatus link;

  /// Passed down from the flow's own layout decision, so the footer trims its
  /// padding in the same box the steps compact themselves in.
  final bool compact;

  const _Footer({
    required this.step,
    required this.last,
    required this.onBack,
    required this.onNext,
    required this.onFinish,
    required this.onPair,
    required this.pairingStarted,
    required this.pairingInFlight,
    required this.link,
    this.compact = false,
  });

  /// True when the last attempt ended **without** connecting — the state the retry
  /// exists for, and so the state that decides the **wording**.
  ///
  /// It does not gate the button; [pairingInFlight] does. The two *are* both true in
  /// the window between a retry's press and the first stage the connection emits, where
  /// the link still describes the attempt that failed before it: the button is dead
  /// there (which is what stops a double press) while the label already reads as a
  /// retry, which is what the press is.
  bool get _attemptEnded =>
      pairingStarted &&
      (link.stage == LinkStage.failed || link.stage == LinkStage.lost);

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final atEnd = step >= last;
    // Compact trims the vertical padding, which is 16 dp of a 235 dp body — more than
    // a whole line of explanation.
    final compactPad = compact;
    final padding = EdgeInsets.fromLTRB(16, 8, 16, compactPad ? 2 : 12);
    if (!atEnd) {
      return Padding(
        padding: padding,
        child: Row(
          children: [
            if (onBack != null)
              TextButton(
                key: const ValueKey<String>('btn-onboarding-back'),
                onPressed: onBack,
                child: Text(l.firstRunBack),
              ),
            const Spacer(),
            FilledButton(
              key: const ValueKey<String>('btn-onboarding-next'),
              onPressed: onNext,
              child: Text(l.firstRunNext),
            ),
          ],
        ),
      );
    }

    // The last step carries two actions, and they do **not** fit side by side on a
    // narrow phone: at 320 dp the pair overflowed by 130 px, which is an error in
    // Flutter rather than a cosmetic warning. So they stack, with the one that does
    // something on its own row — a "Done" squeezed to the width of a word is also
    // the control a user misses when they want out.
    return Padding(
      padding: padding,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (onBack != null)
                TextButton(
                  key: const ValueKey<String>('btn-onboarding-back'),
                  onPressed: onBack,
                  child: Text(l.firstRunBack),
                ),
              const Spacer(),
              Flexible(
                child: FilledButton.icon(
                  key: const ValueKey<String>('btn-onboarding-pair'),
                  // ## The retry, and why there is only ever one request in flight
                  //
                  // Pressing this starts `AppState.connect()` — the same call the
                  // Capture page's connect button makes. Before the first press it is
                  // the way in; **while an attempt is running it is dead**, because two
                  // connect sequences at once is the known wedge precondition on a
                  // camera whose control path is single-threaded (`analysis/04`); and
                  // once an attempt has settled it is live again, whether it succeeded
                  // or failed.
                  //
                  // That last clause is the fix. Before it, `pairingStarted` latched
                  // the button off for the life of the page, so a failed attempt could
                  // not be retried from inside the flow at all — the user had to leave
                  // and re-enter, which is the behaviour the plain Capture page never
                  // had. The button is **not** re-enabled *while* an attempt runs, so
                  // the camera can never be asked to confirm twice at once.
                  //
                  // Nothing here retries by itself, deliberately: every attempt needs a
                  // human to press Accept on the camera body within a few seconds
                  // (`firstRunAcceptOnCameraDetail`), so an automatic retry would spend
                  // the camera's one pairing slot on a request nobody is standing at
                  // the camera for — and on this camera a newer client silently
                  // replaces an existing pairing (`AGENTS.md` §5), so a retry the user
                  // did not ask for can take the turn of the one they are confirming.
                  // The user decides when the ten seconds start.
                  onPressed: pairingInFlight ? null : onPair,
                  icon: Icon(
                      _attemptEnded ? Icons.refresh : Icons.bluetooth_searching,
                      size: 18),
                  label: Text(
                      _attemptEnded
                          ? l.firstRunPairTryAgain
                          : l.firstRunStartPairing,
                      overflow: TextOverflow.ellipsis),
                ),
              ),
            ],
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              key: const ValueKey<String>('btn-onboarding-done'),
              onPressed: onFinish,
              style: compactPad
                  ? TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      minimumSize: const Size(64, 32),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    )
                  : null,
              child: Text(l.firstRunDone),
            ),
          ),
        ],
      ),
    );
  }
}

/// A scrollable step body.
///
/// Scrollable rather than a fixed layout because the flow is read at a large text
/// scale as often as at a small one, and a step whose explanation is clipped is a
/// step nobody read. The scroll view is what keeps a 914x411 landscape window with
/// 1.5x text from becoming an overflow — which is an error in Flutter, not a
/// cosmetic warning.
class _StepBody extends StatelessWidget {
  final List<Widget> children;
  final bool compact;
  const _StepBody({required this.children, this.compact = false});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: compact
          ? const EdgeInsets.fromLTRB(20, 0, 20, 4)
          : const EdgeInsets.fromLTRB(20, 4, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }
}

class _StepTitle extends StatelessWidget {
  final String text;
  final bool compact;
  const _StepTitle(this.text, {this.compact = false});

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.only(bottom: compact ? 2 : 6),
        child: Text(text,
            style: TextStyle(
                color: Colors.white,
                fontSize: compact ? 16 : 19,
                fontWeight: FontWeight.w600)),
      );
}

class _Body extends StatelessWidget {
  final String text;
  final bool compact;
  const _Body(this.text, {this.compact = false});

  @override
  Widget build(BuildContext context) => Text(text,
      style: TextStyle(
          color: Colors.white70,
          fontSize: compact ? 12 : 13.5,
          height: compact ? 1.3 : 1.45));
}

/// One of the two facts worth stating before anything else.
class _SurpriseCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String detail;
  final bool compact;

  const _SurpriseCard({
    required this.icon,
    required this.title,
    required this.detail,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: EdgeInsets.only(bottom: compact ? 6 : 10),
      padding: EdgeInsets.all(compact ? 8 : 12),
      decoration: BoxDecoration(
        color: const Color(0xFF171717),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: compact ? 16 : 20, color: Colors.lightBlueAccent),
          SizedBox(width: compact ? 8 : 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: compact ? 12 : 13.5,
                        fontWeight: FontWeight.w600)),
                SizedBox(height: compact ? 1 : 3),
                Text(detail,
                    style: TextStyle(
                        color: Colors.white60,
                        fontSize: compact ? 11 : 12.5,
                        height: compact ? 1.25 : 1.4)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- step 1

class _WelcomeStep extends StatelessWidget {
  final bool compact;
  const _WelcomeStep({this.compact = false});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    return _StepBody(compact: compact, children: [
      _StepTitle(l.firstRunStepWhatItDoes, compact: compact),
      _Body(l.firstRunIntro, compact: compact),
      SizedBox(height: compact ? 8 : 14),
      // The two facts. Both were learned expensively and neither is discoverable
      // from the app: one is why connecting from a PC locks the phone out, the
      // other is why pairing looks frozen for ten seconds.
      _SurpriseCard(
        compact: compact,
        icon: Icons.wifi_tethering,
        title: l.firstRunWifiOneDeviceTitle,
        detail: l.firstRunWifiOneDeviceDetail,
      ),
      _SurpriseCard(
        compact: compact,
        icon: Icons.touch_app,
        title: l.firstRunAcceptOnCameraTitle,
        detail: l.firstRunAcceptOnCameraDetail,
      ),
    ]);
  }
}

// ---------------------------------------------------------------- step 2

class _SyncModeStep extends StatelessWidget {
  /// The answers, read **at build time**.
  ///
  /// The object rather than the selected id, deliberately: see [_FirstRunFlowState
  /// ._rememberMode]. A `String selected` argument is a value read once and held in a
  /// widget field, and a widget field cannot notice that the preference behind it
  /// changed. Reading `prefs.syncMode` here means every rebuild sees the current
  /// answer, and the only remaining requirement is that a rebuild happens at all —
  /// which is what `setState` in `_rememberMode` provides.
  final OnboardingPrefs prefs;
  final void Function(String modeId) onChosen;
  final bool compact;

  const _SyncModeStep({
    required this.prefs,
    required this.onChosen,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final selected = prefs.syncMode ?? kDefaultSyncModeId;
    return _StepBody(compact: compact, children: [
      _StepTitle(l.firstRunStepHowPhotosCome, compact: compact),
      _Body(l.firstRunSyncIntro, compact: compact),
      SizedBox(height: compact ? 4 : 10),
      RadioGroup<String>(
        key: const ValueKey<String>('onboarding-sync-mode'),
        groupValue: selected,
        onChanged: (v) {
          if (v != null) onChosen(v);
        },
        child: Column(
          children: [
            for (final choice in kSyncModeChoices)
              RadioListTile<String>(
                key: ValueKey<String>('btn-sync-mode-${choice.id}'),
                value: choice.id,
                dense: true,
                contentPadding: EdgeInsets.zero,
                visualDensity: compact ? VisualDensity.compact : null,
                title: Text(choice.title(l),
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: compact ? 12.5 : 13.5,
                        height: 1.3)),
                subtitle: Padding(
                  padding: EdgeInsets.only(top: compact ? 1 : 3),
                  child: Text(choice.tradeoff(l),
                      style: TextStyle(
                          color: Colors.white60,
                          fontSize: compact ? 11 : 12.5,
                          height: compact ? 1.25 : 1.4)),
                ),
              ),
          ],
        ),
      ),
      SizedBox(height: compact ? 2 : 6),
      _Body(l.firstRunSyncFoot, compact: compact),
    ]);
  }
}

// ---------------------------------------------------------------- step 3

/// The pairing guide, rendered from the states the app is really in.
///
/// It owns no progress of its own: every line about where the sequence has got to
/// comes from [LinkStatus], which is the same source the Capture page's connect bar
/// reads. That is what keeps this screen honest — it cannot say "connecting" while
/// the app is waiting for a person, because those are different [LinkStage]s.
class _PairingStep extends StatelessWidget {
  final AppState app;
  final bool started;
  final bool compact;

  const _PairingStep({
    required this.app,
    required this.started,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    return AnimatedBuilder(
      // Rebuilt from the app rather than from a timer: `AppState` notifies on every
      // link change and on its own 250 ms chrome ticker, so the status text below
      // follows the sequence without this widget polling anything.
      animation: app,
      builder: (context, _) {
        final link = app.link;
        if (compact) {
          // The wide, short arrangement. Three decisions, all of them about the same
          // 235 dp of body a 914x411 window leaves after the header and the footer:
          //
          // * the checklist and the status share a row — width is what this window has
          //   spare, and the two blocks are independent;
          // * the closing note sits beside the status rather than under it, for the
          //   same reason;
          // * "Four things happen, in this order:" is gone. It is scaffolding for a
          //   portrait reader; the numbered ticks say the same thing without a line.
          //
          // **Measured**: with these, the step's content is 74 px shorter than the
          // space it has, so nothing is below the fold. The first attempt at this
          // layout left 74 px of content off screen, which
          // `first_run_flow_test.dart` now fails on by name.
          return _StepBody(compact: true, children: [
            _StepTitle(l.firstRunStepPair, compact: true),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: _PairingProgress(link: link, compact: true)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _StatusCard(
                          link: link, started: started, compact: true),
                      const SizedBox(height: 4),
                      _Body(l.firstRunKeepAwake, compact: true),
                    ],
                  ),
                ),
              ],
            ),
          ]);
        }
        return _StepBody(children: [
          _StepTitle(l.firstRunStepPair, compact: compact),
          _Body(l.firstRunFourThings, compact: compact),
          SizedBox(height: compact ? 4 : 8),
          _PairingProgress(link: link, compact: compact),
          SizedBox(height: compact ? 6 : 12),
          _StatusCard(link: link, started: started, compact: compact),
          SizedBox(height: compact ? 4 : 10),
          // The portrait sentence, which is *not* the compact one: this layout puts the
          // button under the paragraph, so "after you ask to pair" is what tells the
          // reader when the ten seconds start. Hence two keys rather than one — the
          // wording difference is deliberate and is why `firstRunKeepAwake` is not
          // reused here.
          _Body(l.firstRunKeepAwakeAfterAsk, compact: compact),
        ]);
      },
    );
  }
}

/// The four steps, with the ones the app has completed ticked off.
///
/// Derived from [LinkStage] rather than from a step counter, because the stage is
/// what the app actually knows. `awaitingUserConfirm` is deliberately *in progress*
/// and not complete: the app is waiting for a person, and marking it done would be
/// the same lie as a spinner.
class _PairingProgress extends StatelessWidget {
  final LinkStatus link;
  final bool compact;
  const _PairingProgress({required this.link, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final done = _completed(link.stage);
    final waitingOnHuman = link.stage == LinkStage.awaitingUserConfirm;

    Widget row(int index, String label) {
      final isDone = index < done;
      final isNow = index == done && link.isBusy;
      return Padding(
        padding: EdgeInsets.only(bottom: compact ? 2 : 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              isDone
                  ? Icons.check_circle
                  : (isNow ? Icons.radio_button_checked : Icons.circle_outlined),
              size: compact ? 14 : 16,
              color: isDone
                  ? Colors.lightGreenAccent
                  : (isNow ? Colors.lightBlueAccent : Colors.white24),
            ),
            SizedBox(width: compact ? 6 : 8),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: isDone ? Colors.white70 : Colors.white54,
                  fontSize: compact ? 11.5 : 12.5,
                  height: compact ? 1.25 : 1.3,
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        row(0, l.firstRunPairFind),
        // The step that needs the user. The wording is deliberately not "Waiting…":
        // it names what has to happen, and where.
        row(1, waitingOnHuman ? l.firstRunPairAccept : l.firstRunPairConfirm),
        row(2, l.firstRunPairReadCredentials),
        row(3, l.firstRunPairJoin),
      ],
    );
  }

  /// How many of the four steps are behind us.
  ///
  /// A total function of the stage, so a stage added later shows up as "not yet"
  /// rather than as a silently wrong count.
  static int _completed(LinkStage stage) => switch (stage) {
        LinkStage.idle => 0,
        LinkStage.scanning => 0,
        LinkStage.connecting => 0,
        LinkStage.readingIdentity => 1,
        LinkStage.pairing => 1,
        LinkStage.awaitingUserConfirm => 1,
        LinkStage.startingSession => 2,
        LinkStage.enablingWifi => 2,
        LinkStage.readingCredentials => 2,
        LinkStage.waitingForWifi => 3,
        LinkStage.ready => 4,
        LinkStage.failed => 4,
        LinkStage.lost => 4,
      };
}

/// What the app is doing right now — its own words, or an honest absence of them.
class _StatusCard extends StatelessWidget {
  final LinkStatus link;
  final bool started;
  final bool compact;
  const _StatusCard({
    required this.link,
    required this.started,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final failed = link.stage == LinkStage.failed;
    final ready = link.isReady;

    /// The last attempt is over and it did not connect.
    ///
    /// **This is where "what do I do now" belongs.** The app's own sentence for a
    /// failure says what went wrong — `linkPairingNotConfirmed` names the ten-second
    /// window, `linkNotFound` asks whether the camera is on — and none of them could
    /// say what to press, because until this round there was nothing to press: the
    /// button that started the attempt was disabled for good. Now there is, so the
    /// card names it. Gated on [started] because the sentence points at that button.
    final canTryAgain = started &&
        (link.stage == LinkStage.failed || link.stage == LinkStage.lost);

    final String text;
    if (!started && link.stage == LinkStage.idle) {
      text = l.firstRunNotConnected;
    } else if (ready) {
      text = l.firstRunConnected;
    } else {
      // The app's own sentence. Not paraphrased, and not embellished: this string
      // carries the refId, the SSID and the passkey when they are the missing piece,
      // and a second wording here would drift from the one the Capture page shows.
      //
      // `linkStatusText` resolves the status's own message code against the ARB and
      // falls back to exactly this `link.message` when there is no code — which is
      // what keeps the promise above: the transport layer still owns the sentence
      // (`AGENTS.md` §4.1), and this is where it becomes the reader's language.
      text = linkStatusText(l, link);
    }

    return Container(
      padding: EdgeInsets.all(compact ? 8 : 12),
      decoration: BoxDecoration(
        color: failed ? const Color(0xFF2A1414) : const Color(0xFF141A22),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: failed ? Colors.redAccent : Colors.white12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            ready
                ? Icons.check_circle_outline
                : (failed ? Icons.error_outline : Icons.info_outline),
            size: compact ? 15 : 18,
            color: ready
                ? Colors.lightGreenAccent
                : (failed ? Colors.redAccent : Colors.lightBlueAccent),
          ),
          SizedBox(width: compact ? 7 : 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  text,
                  style: TextStyle(
                    color: failed ? Colors.redAccent : Colors.white70,
                    fontSize: compact ? 11.5 : 12.5,
                    height: compact ? 1.3 : 1.4,
                  ),
                ),
                // What to do about it, under what went wrong. Only after a failure the
                // user can actually answer: the sentence names the button, so it is
                // drawn only where that button is live ([canTryAgain]).
                if (canTryAgain) ...[
                  SizedBox(height: compact ? 4 : 6),
                  Text(
                    l.firstRunPairFailedHelp,
                    style: TextStyle(
                      color: Colors.white54,
                      fontSize: compact ? 10.5 : 11.5,
                      height: compact ? 1.25 : 1.35,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Kept so `SyncMode` remains the single authority on what the names mean.
///
/// [kSyncModeChoices] stores the *names* the preference file holds; this maps them
/// back for anyone who needs the enum, and it is the reason the ids above are not
/// invented strings. `analysis/56` §6 names the call the sync owner has to add.
SyncMode syncModeFromId(String id) => switch (id) {
      'autoOriginalOnly' => SyncMode.autoOriginalOnly,
      'manualOnly' => SyncMode.manualOnly,
      _ => SyncMode.autoPreviewThenOriginal,
    };

