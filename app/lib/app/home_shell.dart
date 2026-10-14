import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show SchedulerBinding, SchedulerPhase;

import '../l10n/l10n.dart';
import '../platform/file_pairing_store.dart';
import '../platform/onboarding_prefs.dart';
import '../state/app_state.dart';
import '../sync/sync_mode.dart';
import '../transport/camera_connection.dart';
import '../ui/licences.dart';
import '../features/album/presentation/album_page.dart';
import '../features/onboarding/presentation/first_run_flow.dart';
import '../features/live_view/presentation/live_view_page.dart';
import '../features/video/presentation/video_page.dart';
import 'dependencies.dart';
import 'presentation_state.dart';
import 'startup_error_view.dart';

class HomeShell extends StatefulWidget {
  /// A ready-made state, for tests.
  ///
  /// `initState` builds the real dependencies — a plugin-backed BLE transport and a
  /// file-backed pairing store — which a widget test cannot supply. This is the same
  /// seam the rest of the project uses (`AppState(testHttp:, testIdentity:)`), lifted
  /// one level so the *shell* can be exercised: the build stamp lives in its app bar,
  /// and asserting it is worth more than asserting the app bar exists.
  final AppState? testApp;

  /// The first-run preferences, injected so a test can supply an in-memory store.
  ///
  /// Production passes nothing and gets the file-backed one. The seam exists because
  /// the **gate** below reads two files before it can decide whether to show the
  /// flow, and a widget test has no documents directory of its own.
  final OnboardingPrefs? onboardingPrefs;

  /// Force the flow on or off, for a test that wants to look at it.
  ///
  /// Null — the production default — means "let the shell decide", which is what the
  /// tests that verify the decision (`first_run_gate_test.dart`) need: they inject a
  /// prefs store and a pairing record and check what the shell does with them.
  ///
  /// A test that injects an [AppState] but **not** this gets the flow suppressed. Not
  /// a shortcut: the shell's decision is two file reads, and a widget test's fake-async
  /// zone never completes real I/O (`analysis/41` §7.9), so a shell test that awaits
  /// the decision hangs instead of failing. `testApp` already means "this state is
  /// supplied", and that extends to "the first run is done".
  final bool? showOnboarding;

  /// Optional observer for recorded sync modes, used by tests.
  ///
  /// Called with one of [kSyncModeIds] when the flow records an answer. The shell
  /// also applies the mode to its shared engine in [_HomeShellState._onSyncModeRecorded];
  /// production does not need to provide this observer for the answer to take effect.
  final void Function(String modeId)? onSyncModeRecorded;

  const HomeShell({
    super.key,
    this.testApp,
    this.onboardingPrefs,
    this.showOnboarding,
    this.onSyncModeRecorded,
  });

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  AppState? _app;
  String? _startupError;
  int _tab = 0;

  /// The durable first-run answers — the mode the user chose, and whether they have
  /// been through the flow at all.
  late final OnboardingPrefs _prefs;

  /// False until the gate has read its two files.
  ///
  /// The gate's question — *has this person paired before, and have they seen the
  /// flow* — is answered by two files, and **neither answer may be guessed**: showing
  /// the introduction to a returning user is the complaint this feature exists to
  /// avoid, and skipping it for a first-time user leaves them exactly where they
  /// were. So the first frame waits for the read rather than drawing a default.
  ///
  /// It is one `await` on two small local files, and what is on screen meanwhile is
  /// the app's own background colour — the same thing the frame after it shows.
  /// `test/first_run_gate_test.dart` asserts the flow appears when nothing is on
  /// file, which is the case that would break if this wait silently never finished.
  bool _booted = false;

  /// Whether the first-run flow should be on screen.
  bool _showOnboarding = false;

  @override
  void initState() {
    super.initState();
    // Every dependency is constructed here rather than in `main`, so a failure
    // lands inside the widget tree where it can be shown instead of before
    // `runApp`, where it leaves the splash screen up forever with no explanation.
    //
    // That is not hypothetical: this app hung on launch once already, because
    // `PaintingBinding.instance` was touched before any binding existed.
    // Constructing a plugin-backed transport is the same class of risk.
    //
    // The injected test state is also the only path allowed to skip the boot wait.
    // A widget test's fake-async zone never completes real file I/O
    // (`analysis/41` §7.9), and `testApp` means the test has already said which
    // state it wants — so asking the disk again would hang every existing shell
    // test for a fact the test has already provided.
    if (widget.testApp != null) {
      _app = widget.testApp;
      _bindLocale(_app!);
      _prefs = widget.onboardingPrefs ?? OnboardingPrefs();
      // A shell test that injects a state is not asked to sit through the gate's two
      // file reads — see [HomeShell.showOnboarding]. A test that *is* about the
      // decision passes `showOnboarding` explicitly and gets it.
      _showOnboarding = widget.showOnboarding ?? false;
      _booted = true;
      return;
    }
    try {
      final dependencies = createAppDependencies(
        onboardingPrefs: widget.onboardingPrefs,
      );
      _app = dependencies.state;
      _prefs = dependencies.onboardingPrefs;
      _bindLocale(_app!);
      unawaited(_decide(dependencies.pairing));
    } on Object catch (e, s) {
      debugPrint('AppState construction failed: $e\n$s');
      _startupError = '$e';
      // A failed construction must not leave the shell on its boot frame forever:
      // `StartupErrorView` is the screen that explains what happened, and it is drawn
      // from `_app == null` below.
      _prefs = widget.onboardingPrefs ?? OnboardingPrefs();
      _booted = true;
    }
  }

  /// Keep [appPresentation.localeTag] — and through it `MaterialApp.locale` — in step with the state.
  ///
  /// A listener rather than a read inside `build`: the tag changes when the *user*
  /// changes it in Settings, which is not a rebuild of this widget, and reading it
  /// during a build would leave the `MaterialApp` one frame behind the button press.
  /// The first assignment is the file's remembered answer, applied before the shell
  /// has drawn anything in the wrong language.
  void _bindLocale(AppState app) {
    app.addListener(_syncLocale);
    _syncLocale();
  }

  void _syncLocale() {
    final app = _app;
    if (app == null) return;
    if (appPresentation.localeTag.value == app.localeTag) return;
    // `_bindLocale` runs from `initState`, which is inside the build phase — and
    // `ValueNotifier.value =` marks the `ValueListenableBuilder` above this widget
    // dirty, which the framework rejects mid-build
    // (`setState() or markNeedsBuild() called during build`). Deferring to the end of
    // the frame is the fix rather than a workaround: the tag is applied before the
    // next frame is composited either way, and the only thing that would be lost by
    // reading it a frame earlier is nothing at all — the remembered preference arrives
    // from an async file read and cannot be known during `initState` anyway.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final a = _app;
        if (a != null && appPresentation.localeTag.value != a.localeTag) {
          appPresentation.localeTag.value = a.localeTag;
        }
      });
      return;
    }
    appPresentation.localeTag.value = app.localeTag;
  }

  /// Decide whether to run the first-run flow, then let the shell draw.
  ///
  /// Two independent reasons to skip it, and both are needed:
  ///
  /// 1. **The user has been through it** — [OnboardingPrefs.onboardingDone], set by
  ///    finishing *and* by skipping.
  /// 2. **The user has paired before.** This is the one that matters for anybody
  ///    upgrading from a build that had no onboarding at all: they have no
  ///    preference file, so reason 1 says "first run", and only the stored pairing
  ///    record can tell the truth. Walking a returning user through the
  ///    introduction would be a regression introduced by *adding* a feature.
  ///
  /// The pairing record's test is `hasWifiCredentials` rather than
  /// `canReuseSession`: a session token can be forgotten deliberately (the
  /// connection layer drops one the camera refused), while the stored SSID and
  /// passkey are the marks of a pairing that actually happened.
  Future<void> _decide(FilePairingStore pairing) async {
    var seen = false;
    var paired = false;
    try {
      await _prefs.load();
      seen = _prefs.onboardingDone;
      paired = PairingRecord.fromMap(await pairing.load()).hasWifiCredentials;
    } on Object catch (e) {
      // Neither file is worth a failed launch, and the safe default is the one that
      // does not put a new screen in front of somebody who was trying to reach the
      // camera — the app worked without onboarding for its whole life until now.
      debugPrint('first-run gate: unreadable state ($e); not showing the flow');
      seen = true;
    }
    if (!mounted) return;
    setState(() {
      _showOnboarding = widget.showOnboarding ?? (!seen && !paired);
      _booted = true;
    });
    debugPrint('first-run gate: seen=$seen paired=$paired '
        'show=$_showOnboarding');
  }

  /// Record an answer from the flow and hand it on.
  ///
  /// The write happens inside the flow (`OnboardingPrefs.save`), because it owns the
  /// preference; what happens here is the hand-over, which is the part the app shell
  /// is the only place for.
  /// Hand the recorded mode to the running engine.
  ///
  /// ## Why this is not just a log line
  ///
  /// It was: `_onSyncModeRecorded` printed the choice and called an optional callback that
  /// **nothing ever supplied** — `HomeShell()` is constructed without arguments — so the
  /// preference was written correctly and read correctly at the *next* launch, and did
  /// nothing at all in the session where the user actually chose it. Pick "Manual — only
  /// what I pick", open the Sync tab, and the dropdown still shows the default. That is the
  /// same shape as the defect this round is about: a value recorded in one place and never
  /// reaching the thing that acts on it.
  ///
  /// The engine is set directly rather than through `AppState.setSyncMode`, which takes the
  /// listed files so it can re-derive the queue. There is nothing to re-derive here: the
  /// first run happens before any listing exists. The plain setter notifies, so every
  /// listener sees the choice immediately.
  void _onSyncModeRecorded(String modeId) {
    widget.onSyncModeRecorded?.call(modeId);
    _app?.sync.mode = syncModeFromId(modeId);
    debugPrint('first-run: sync mode recorded as $modeId');
  }

  void _finishOnboarding() {
    if (!_showOnboarding) return;
    setState(() => _showOnboarding = false);
  }

  /// Push the flow again, from the app bar.
  void _openGuide() {
    final app = _app;
    if (app == null) return;
    openFirstRunFlow(
      context,
      app: app,
      prefs: _prefs,
      // A revisit decides nothing on the user's behalf: they came back to change one
      // answer or to read the pairing steps, and leaving without touching anything
      // must leave everything as it was.
      entry: FirstRunEntry.revisit,
      onModeChosen: _onSyncModeRecorded,
      onExited: () => debugPrint('first-run: guide closed'),
    );
  }

  @override
  void dispose() {
    _app?.removeListener(_syncLocale);
    _app?.dispose();
    super.dispose();
  }

  Future<void> _confirmDisconnect(BuildContext context) async {
    final l = l10nOf(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.disconnectTitle),
        content: Text(l.disconnectBody),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(l.cancel)),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(l.disconnect)),
        ],
      ),
    );
    if (ok == true) await _app?.disconnect();
  }

  @override
  Widget build(BuildContext context) {
    final app = _app;
    if (app == null) {
      return StartupErrorView(
          _startupError ?? l10nOf(context).startupUnknownError);
    }
    if (!_booted) {
      // The frame or two between launch and the gate's answer. Deliberately the same
      // colour as the shell's own background: the alternative — guessing — either
      // shows a returning user an introduction they have already dismissed or shows
      // a first-time user nothing at all, and both are worse than two blank frames.
      return const Scaffold(
        key: ValueKey<String>('first-run-boot'),
        backgroundColor: Color(0xFF0E0E0E),
        body: SizedBox.expand(),
      );
    }
    return Stack(
      children: [
        Positioned.fill(child: _shell(app)),
        // The first-run flow, when it is the gate's answer.
        //
        // A `Stack` sibling rather than a route: it is not a place the user navigated
        // to, and the back gesture must not dismiss it into a state where the app has
        // been "seen" without the user ever having seen it. The flow's own Skip button
        // is the only way past it, which is what makes the recorded decision honest.
        //
        // `_showOnboarding` is set only after the gate has read both files, so this
        // branch cannot flash an introduction at a returning user for a frame.
        if (_showOnboarding)
          Positioned.fill(
            child: FirstRunFlow(
              app: app,
              prefs: _prefs,
              entry: FirstRunEntry.firstRun,
              onModeChosen: _onSyncModeRecorded,
              onFinished: _finishOnboarding,
            ),
          ),
      ],
    );
  }

  Widget _shell(AppState app) {
    return AnimatedBuilder(
      animation: app,
      builder: (context, _) {
        final l = l10nOf(context);
        return Scaffold(
          key: const ValueKey<String>('nav-shell'),
          // Hidden in full-screen mode so the live view gets the whole window — the
          // point of the mode is that the status strip, the picture and the controls are
          // not squeezed by the shell's own chrome. `null` rather than a zero-height
          // `AppBar`, which would still reserve its status-bar inset.
          appBar: app.fullScreen
              ? null
              : AppBar(
                  backgroundColor: const Color(0xFF151515),
                  foregroundColor: Colors.white,
                  // Scaled down rather than allowed to overflow.
                  //
                  // The title holds the app name, the firmware badge and the build stamp, and on
                  // a 411dp phone that row wanted 352dp inside a 283dp box —
                  // `A RenderFlex overflowed by 69 pixels on the right`, found by
                  // `test/build_stamp_test.dart` as soon as the stamp was added.
                  //
                  // `scaleDown` is the same mechanism the live view uses for its bands: it only
                  // ever shrinks, and only when the row genuinely does not fit, so a wide phone
                  // or a short firmware string is unaffected.
                  title: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Row(
                      children: [
                        Text(l.appTitle, style: const TextStyle(fontSize: 16)),
                        const SizedBox(width: 10),
                        _FirmwareBadge(app: app),
                        const SizedBox(width: 8),
                        const _BuildStamp(),
                      ],
                    ),
                  ),
                  actions: [
                    // The way back into the first-run flow, at **every** link state.
                    //
                    // A flow the user cannot re-open is a trap the moment they change their
                    // mind, and the one answer it records — the sync mode — is exactly the
                    // kind of choice people revise. It is not hidden while connected either:
                    // the sync mode is a decision about the app, not about the current link,
                    // and a help entry that disappears as soon as the app works is the
                    // discoverability defect `AGENTS.md` §7.1 describes.
                    //
                    // An `IconButton` rather than a `PopupMenuButton` on purpose. The title
                    // row above already needed `scaleDown` because it wanted 352dp in a 283dp
                    // box; a popup menu reserves an intrinsic 48dp plus an 8dp arrow and is
                    // laid out **at its natural size** rather than scaled, so on the 411dp
                    // body it is what would overflow next.
                    IconButton(
                      key: const ValueKey<String>('btn-first-run-guide'),
                      tooltip: l.guideTooltip,
                      onPressed: _openGuide,
                      icon: const Icon(Icons.help_outline),
                    ),
                    // Manual disconnect. The camera's access point costs it battery and
                    // admits one client, so leaving it up because the app was backgrounded
                    // is rude to the hardware.
                    if (app.link.isReady || app.link.isLost)
                      IconButton(
                        key: const ValueKey<String>('btn-disconnect-camera'),
                        tooltip: l.disconnectTooltip,
                        onPressed: () => _confirmDisconnect(context),
                        icon: const Icon(Icons.link_off),
                      ),
                    IconButton(
                      key: const ValueKey<String>('btn-check-camera'),
                      tooltip: l.checkCameraTooltip,
                      onPressed: app.link.isReady
                          ? () async {
                              final ok = await app.verifyAlive();
                              if (!context.mounted) return;
                              ScaffoldMessenger.of(context)
                                  .showSnackBar(SnackBar(
                                content: Text(
                                    ok ? l.cameraResponding : l.cameraSilent),
                                duration: const Duration(seconds: 2),
                              ));
                            }
                          : null,
                      icon: const Icon(Icons.wifi_tethering),
                    ),
                    // Licences and the "who made this" statement: the app bundles
                    // Apache-2.0, MIT and BSD-3-Clause code, and a licence page is how those
                    // notices reach someone who installed an APK rather than a tarball
                    // (`analysis/63` §7.2). Reachable at every link state, like the guide
                    // button above — the licence does not depend on the camera being on.
                    IconButton(
                      key: const ValueKey<String>('btn-licences'),
                      tooltip: l.licencesTooltip,
                      onPressed: () => showAppLicences(context),
                      icon: const Icon(Icons.info_outline),
                    ),
                  ],
                ),
          body: IndexedStack(
            index: _tab,
            children: [
              LiveViewPage(
                app: app,
                onOpenAlbum: (context) => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => AlbumPage(app: app)),
                ),
                onOpenVideo: (context) => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => VideoPage(app: app)),
                ),
              ),
              AlbumPage(app: app),
            ],
          ),
          bottomNavigationBar: app.fullScreen
              ? null
              : NavigationBar(
                  selectedIndex: _tab,
                  onDestinationSelected: (i) => setState(() => _tab = i),
                  height: 58,
                  labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
                  destinations: [
                    NavigationDestination(
                      key: const ValueKey<String>('btn-nav-capture'),
                      icon: const Icon(Icons.camera_outlined),
                      selectedIcon: const Icon(Icons.camera),
                      label: l.navCapture,
                    ),
                    NavigationDestination(
                      key: const ValueKey<String>('btn-nav-sync'),
                      icon: const Icon(Icons.photo_library_outlined),
                      selectedIcon: const Icon(Icons.photo_library),
                      label: l.navSync,
                    ),
                  ],
                ),
        );
      },
    );
  }
}

/// Which build this is, in the app bar.
///
/// ## Why this exists
///
/// A release APK was installed on hardware and reported as not containing UI fixes that
/// had been verified on the emulator. Checking the shipped binary showed the fixes
/// **were** in it — but there was no way for either side to say *which build* was
/// running, so the report could not be settled by looking. That is the gap this closes.
///
/// It is deliberately in the app bar rather than behind a diagnostics sheet: the
/// question "is this the build I just made" is asked while looking at the screen, and an
/// answer that needs three taps is an answer nobody gets.
///
/// The value comes from `--dart-define=BUILD_STAMP=...`, which `tools/task.ps1 build`
/// fills with the short commit and the build time. It reads `dev` for a `flutter run`,
/// which is itself useful: it says the binary came from a working tree rather than from
/// a stamped build.
class _BuildStamp extends StatelessWidget {
  const _BuildStamp();

  /// `String.fromEnvironment` resolves at **compile time**, so a release build with no
  /// stamp carries the literal `dev` and nothing else — the value cannot be changed by
  /// anything at runtime, including a file on the device.
  static const String stamp =
      String.fromEnvironment('BUILD_STAMP', defaultValue: 'dev');

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey<String>('build-stamp'),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.white10,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        stamp,
        style:
            const TextStyle(fontSize: 10.5, color: Colors.white54, height: 1.3),
      ),
    );
  }
}

/// Shows which firmware behaviour the app is talking to.///
/// The app works fully against a **stock** camera: live view, capture, parameters
/// and full-resolution album download were all verified on unmodified firmware.
/// The badge exists so that when a patched camera *is* present the user can see
/// the app noticed — and so a limitation is attributed to the right place.
class _FirmwareBadge extends StatelessWidget {
  final AppState app;
  const _FirmwareBadge({required this.app});

  @override
  Widget build(BuildContext context) {
    final id = app.link.identity;
    if (id == null) {
      return _Badge(text: l10nOf(context).firmwareNotConnected, muted: true);
    }
    return _Badge(text: id.firmwareVersion.trim(), muted: false);
  }
}

class _Badge extends StatelessWidget {
  final String text;
  final bool muted;
  const _Badge({required this.text, required this.muted});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: muted ? Colors.white12 : Colors.blueGrey.shade700,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(text,
          style: const TextStyle(
              fontSize: 11, color: Colors.white70, height: 1.4)),
    );
  }
}
