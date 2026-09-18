import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../protocol/camera_state.dart';
import '../protocol/focus_mapper.dart';
import '../protocol/http_commands.dart';
import '../protocol/settings_menu.dart';
import '../sync/asset_group.dart';
import 'dart:io';

import '../platform/asset_sink.dart';
import '../platform/media_store_bridge.dart';
import '../platform/onboarding_prefs.dart';
import '../platform/thumbnail_cache.dart';
import '../ui/pages/first_run_flow.dart' show syncModeFromId;
import '../protocol/wire_format.dart';
import '../sync/asset_sink_contract.dart';
import '../sync/sync_engine.dart';
import '../sync/file_sync_store.dart';
import '../sync/sync_ledger.dart';
import '../sync/transfer_queue.dart';
import '../sync/ui_prefs.dart';
import '../transport/album.dart';
import '../transport/album_delete.dart';
import '../transport/album_thumbnail_cache.dart';
import '../transport/camera_connection.dart';
import '../transport/camera_request_gate.dart';
import '../transport/capture_guard.dart';
import '../transport/frame_gate.dart';
import '../transport/wifi_join_contract.dart';
import '../transport/http_transport.dart';
import '../transport/liveview.dart';
import '../transport/stream_pause.dart';

/// Application state, shared by the whole UI.
///
/// Deliberately thin: every non-trivial decision lives in the transport and
/// protocol layers, which are verified by `tool/verify_transport.dart` without a
/// Flutter engine.  This class only sequences them and exposes the result to
/// widgets.
///
/// ## Why this watches the app lifecycle
///
/// Joining the camera's access point requires pinning the process to that
/// network, and the pin is **process-wide** — meaning no internet at all while it
/// is in force.  So it is released whenever the app leaves the foreground, and it
/// must be **restored on return**, or the app comes back unable to reach a camera
/// it is still connected to.  That unbind/rebind pairing is the whole reason this
/// class implements [WidgetsBindingObserver].
///
/// ## Why frame delivery is decoupled from repainting
///
/// The camera pushes ~30 frames/second.  Calling `notifyListeners()` per frame
/// rebuilds the whole screen 30 times a second, which on a mid-range phone costs
/// more than decoding the images does — and the rebuild competes with the UDP
/// receive loop, so the stream gets *worse* the harder the UI works.
///
/// So frames land in [frameNotifier], which only the preview widget listens to,
/// and the surrounding chrome (parameters, status, buttons) updates on a 250 ms
/// ticker instead.  [displayedFps] reports what is actually being drawn, which is
/// a different number from the receive rate and is the one the user perceives.
class AppState extends ChangeNotifier with WidgetsBindingObserver {
  final CameraConnection connection;
  late final CaptureGuard captureGuard;

  /// The receiver, optionally replaced by a test's own (bound to a port of its
  /// choosing — see the `testLiveView` argument).
  CameraLiveView? _liveView;

  CameraLiveView get liveView {
    final injected = _liveView;
    if (injected != null) return injected;
    return connection.liveView;
  }

  LinkStatus get link => connection.current;

  /// Newest frame, published separately from [notifyListeners].
  ///
  /// Listen to this for the preview image; listen to the [AppState] itself for
  /// everything else.
  final ValueNotifier<Uint8List?> frameNotifier = ValueNotifier<Uint8List?>(null);

  Uint8List? get frame => frameNotifier.value;

  /// Camera state parsed from the newest frame.  This is the live truth — it
  /// updates with the stream, and it is how a command is confirmed to have
  /// landed (an HTTP 200 alone proves nothing on this firmware).
  CameraState? _cameraState;
  CameraState? get cameraState => _cameraState;

  /// Test seam for stable settings/widget screenshots. Production state still
  /// comes only from live-view frames; tests provide a parsed state without
  /// opening a socket or inventing a second production path.
  void setTestCameraState(CameraState state) {
    _cameraState = state;
    notifyListeners();
  }

  /// Frames per second actually being drawn.
  ///
  /// Deliberately measured at the display side, not the socket: the receive rate
  /// can look healthy while the UI stutters, and it is the stutter the user
  /// reports.
  double _displayedFps = 0;
  int _drawnSinceSample = 0;
  double get displayedFps => _displayedFps;

  /// Live-view statistics straight off the socket.
  LiveViewStats get stats => liveView.stats;

  /// Album, available once connected.
  CameraAlbum? album;

  /// The one serial queue every camera file request goes through.
  ///
  /// ## Why it is owned here rather than by a page
  ///
  /// The camera is a single-threaded HTTP server with no watchdog (`AGENTS.md` §4.6),
  /// and there are three callers that reach `GetFile`: the album grid's serial
  /// thumbnail loop, the sync engine's serial queue, and — since this round — the
  /// photo viewer loading a preview when it opens. Each of the first two is serial
  /// **on its own**, which was enough while there were two of them; three
  /// independently-serial loops make a parallel set between them.
  ///
  /// A gate owned by a page would serialise that page against itself and nothing else,
  /// which is the defect rather than the fix. So it is created once, beside the album
  /// it guards, and handed to every `CameraAlbum` this app builds — including the one
  /// rebuilt on a reconnect.
  final CameraRequestGate cameraGate = CameraRequestGate(
    onLog: (m) => debugPrint('[camera] $m'),
  );

  /// Test-only download seam, handed to [album] when it is created. See the
  /// constructor argument of the same name.
  final Future<Uint8List> Function(AlbumFile, FileResolution)? _testAlbumDownload;

  /// Full-screen mode: the shell hides its own app bar and tab strip so the live view
  /// gets the whole window.
  ///
  /// ## Why it lives here and not in the page
  ///
  /// The bars it hides belong to `HomeShell`, several levels above `LiveViewPage`. A
  /// flag owned by the page would have to be threaded up through widget constructors
  /// and, because the page rebuilds at frame rate, would be re-created constantly. As
  /// a field on the single source of truth the shell rebuilds from the `AnimatedBuilder`
  /// it already has, with nothing passed through.
  ///
  /// This is about the app's **own** chrome, not the OS bars; the caller also asks the
  /// platform for immersive mode so Android's status and navigation bars go too.
  bool get fullScreen => _fullScreen;
  bool _fullScreen = false;
  set fullScreen(bool v) {
    if (_fullScreen == v) return;
    _fullScreen = v;
    notifyListeners();
  }

  /// The durable sync ledger and the transfer engine.
  ///
  /// Created up front rather than on connect, because the ledger must be loaded
  /// before the album is browsed — otherwise previously synced photos look new
  /// and get fetched again.
  final SyncLedger ledger = SyncLedger(store: FileSyncStore());

  /// The durable queue of pending work.
  ///
  /// Also created up front and loaded before the album is browsed: the restore
  /// adds the items the user asked for *last* session, and if the first album
  /// page had already been enqueued the same shots would be inserted twice and
  /// the list would visibly flicker.
  final TransferQueue queue = TransferQueue(store: FileSyncStore.forQueue());

  /// The album grid's thumbnails, kept on disk so opening the album twice does not ask
  /// the camera for the same pictures twice.
  ///
  /// ## Why it lives here and not in the page
  ///
  /// The whole point is that it **outlives the page**, and — reported from the phone as
  /// *"every time I connect the camera and open the album the thumbnails reload"* — it
  /// has to outlive the `CameraAlbum` and the app object as well. A cache owned by
  /// `_AlbumPageState` would be the in-memory map that already exists and already fails
  /// this way.
  ///
  /// It is also the single instance, like the ledger and the queue: several pages (and
  /// several `CameraAlbum`s, one per connect) read and write through it, and its
  /// in-memory byte total has to describe one directory rather than one screen's idea of
  /// it.
  ///
  /// ## Why nothing loads it at startup
  ///
  /// There is no `load()` and none is wanted: a read is one file under one key, so the
  /// launch path gains no work and — the reason the neighbouring stores are injected in
  /// widget tests at all — no new asynchronous gap before the first `notifyListeners()`
  /// (`fakes.dart`, `connectedTestAppState`). The directory is resolved on the first
  /// thumbnail, which is long after the UI is up, and a cache that cannot resolve it
  /// reports a miss instead of throwing.
  ///
  /// `analysis/77-album-thumbnail-cache.md` records the format, the key, the cap and
  /// what invalidates an entry.
  late final AlbumThumbnailCache thumbnailCache = appThumbnailCache();

  /// The durable live-view layout preferences: which settings groups are open,
  /// and which settings tab was last used.
  ///
  /// Layout only, never camera state — see `sync/ui_prefs.dart` for why that
  /// distinction is load-bearing on this firmware.
  ///
  /// **Always injected in a widget test** (`testUiPrefs`), for the reason
  /// [onboardingPrefs] records: the production store reads through `path_provider`, and a
  /// widget test has no channel for it, so `load()` raises `MissingPluginException` — which
  /// is swallowed, correctly — but only **after an asynchronous gap**. `_load()` awaits
  /// both, so two such gaps push `sync.restore()` and the first `notifyListeners()` past a
  /// test's pump budget. That surfaced as `sync_list_control_test` expecting a five-item
  /// queue and finding two, **intermittently**: it passes three times out of three alone
  /// and fails under a full parallel run.
  final UiPrefs uiPrefs;

  /// What the first-run flow asked and remembered: whether it has been seen, and the
  /// sync mode chosen at pairing time. Applied in [_load] — see the note there.
  ///
  /// Injected in tests through `testOnboardingPrefs`, so the wiring that *applies* the
  /// remembered mode can be checked against a store that holds a known answer. Without
  /// that seam the check would have to write to the real preferences file, and the
  /// claim "the answer is remembered" would rest on inspection — which is exactly the
  /// kind of claim that let a never-persisted sync mode pass every in-memory assertion.
  final OnboardingPrefs onboardingPrefs;

  late final SyncEngine sync;

  /// The camera's stream pause, for the sync run and for the UI to read.
  late final HttpStreamPauseController streamPause;

  /// Whether a sync run may pause the live view, straight from §5.3.
  ///
  /// Exposed here rather than only on the engine so the album screen has one
  /// place to read and write it, and so a rebuild triggered by the engine's own
  /// `onChanged` picks up the toggle immediately.
  bool get pauseStreamDuringTransfer => sync.pauseStreamDuringTransfer;
  set pauseStreamDuringTransfer(bool v) {
    if (sync.pauseStreamDuringTransfer == v) return;
    sync.pauseStreamDuringTransfer = v;
    notifyListeners();
  }

  /// Whether the live view pins the screen on while a preview is running.
  ///
  /// Defaults to true, which is the behaviour the app has always had: a camera
  /// controller is held at arm's length with both hands busy, so a screen that
  /// times out mid-composition cannot be recovered without losing the shot. The
  /// toggle exists because it is still the user's battery, and an always-on
  /// screen in a bag is a real cost.
  bool get keepScreenOn => uiPrefs.keepScreenOn;
  set keepScreenOn(bool v) {
    if (uiPrefs.keepScreenOn == v) return;
    uiPrefs.setKeepScreenOn(v);
    notifyListeners();
    unawaited(uiPrefs.save());
  }

  /// Whether a sync should also fetch the RAW half of a RAW+JPEG shot.
  ///
  /// **Off until the user asks**, which is the decision `transport/album.dart`
  /// (`SyncPlan.skipRaw`) documents and which nothing in `lib/` used to implement:
  /// every queue path enqueued `AssetGroup.assets`, RAW included, so one tap queued
  /// ~32 MB where the user's mental model was the measured 4.9 MB (`analysis/79`, finding #2).
  ///
  /// Exposed here rather than read off `uiPrefs` at each call site so the page has one
  /// place to read and write it, and so a rebuild triggered by the engine's own
  /// `onChanged` picks up a flip immediately — the same shape as
  /// [pauseStreamDuringTransfer] above. `UiPrefs.includeRaw` holds the argument for
  /// the default and for remembering the answer.
  bool get includeRaw => uiPrefs.includeRaw;
  set includeRaw(bool v) {
    if (uiPrefs.includeRaw == v) return;
    uiPrefs.setIncludeRaw(v);
    notifyListeners();
    unawaited(uiPrefs.save());
  }

  /// The queue policy the RAW opt-in implies — what every queue action reads.
  ///
  /// One definition, so the album page's four queue paths (a selection, the mode
  /// selector, the viewer's save button, the automatic browse that fills the queue as
  /// the card is paged through) cannot drift apart. Before this existed, `SyncPlan` was
  /// constructed **nowhere in `lib/`** while all four enqueued `AssetGroup.assets`, RAW
  /// included — so the documented default ("the capability ships off") was contradicted
  /// by the queue with nothing on screen to say so (`analysis/79`, finding #2).
  ///
  /// [SyncPlan.forQueue] says why a queue action applies no *other* filter;
  /// `plannedQueue` (`sync/asset_group.dart`) is its only reader.
  SyncPlan get queuePlan => SyncPlan.forQueue(includeRaw: includeRaw);

  /// True while a transfer is holding the preview paused.
  ///
  /// The live-view screen reads this to explain a still frame instead of leaving
  /// the user to conclude the app has hung.
  bool get streamPausedForTransfer => sync.streamPausedForTransfer;

  /// Which language the interface is drawn in: [kLocaleSystem], or a locale tag.
  ///
  /// Read by the app shell, which turns it into the `Locale?` `MaterialApp` takes.
  /// Stored through the same [UiPrefs] file as the panel arrangement and the screen
  /// pin — deliberately the *existing* preference seam rather than a third one, so
  /// there is one place where "what the user chose and the app remembered" lives and
  /// one codec whose failure modes are already exercised in the plain Dart VM.
  String get localeTag => uiPrefs.localeTag;

  /// Choose the interface language. Persisted immediately, like the screen pin.
  ///
  /// No confirmation and no restart: the shell rebuilds on [notifyListeners], so the
  /// next frame is already in the chosen language.
  set localeTag(String tag) {
    if (uiPrefs.localeTag == tag) return;
    uiPrefs.setLocaleTag(tag);
    notifyListeners();
    unawaited(uiPrefs.save());
  }

  /// Release a stream pause that is already in force, resuming the preview.
  ///
  /// Needed because clearing `sync.pauseStreamDuringTransfer` only stops *future*
  /// transfers from pausing: a run already in flight keeps its hold, so the
  /// setting appeared to do nothing to the frozen preview the user was looking
  /// at. The banner's "keep the preview running" action therefore could not
  /// deliver what it offered — reported from a device screenshot.
  Future<void> resumePreviewAfterPause() => sync.releaseAllStreamHolds();

  /// Switch sync mode, and bring the job list into line with what it now means.
  ///
  /// The engine owns the rule (`SyncEngine.reinterpret` explains why the list is
  /// re-derived rather than inherited); this is the one place the album page and the
  /// tests change a mode, so the two cannot drift apart.
  ///
  /// ## Why the notification is deferred, and only when it is needed
  ///
  /// The sync bar calls this from the mode dropdown's `onChanged`, which runs
  /// **inside the build phase**. Notifying listeners from there reaches the shell's
  /// `AnimatedBuilder` while it is already building, and the framework asserts:
  /// `setState() or markNeedsBuild() called during build`. Every other route into
  /// the engine is asynchronous — a tap handler, a completed transfer — so this is
  /// the one call site that needs it; see [setLiveViewVisible], which hit the same
  /// wall from `didChangeDependencies`.
  ///
  /// Returns what changed, in words fit to show the user, or null when the mode was
  /// already the one asked for.
  String? setSyncMode(SyncMode m, List<AlbumFile> listed) {
    final note = sync.reinterpret(m, listed);
    if (note == null) return null;
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.persistentCallbacks) {
      // One frame later: soon enough that the list and the selector never appear to
      // disagree, late enough to be a legal rebuild.
      SchedulerBinding.instance.addPostFrameCallback((_) => notifyListeners());
    } else {
      notifyListeners();
    }
    return note;
  }

  /// Set when a control command fails, so the UI can show it once.
  ///
  /// ## The sentence, a code, and the values it interpolates
  ///
  /// These two lines are the last producer of user-visible prose in the app that had
  /// no way to reach a translation. The sentence cannot move up into the UI — it is
  /// written in the branch that *decides* it, and `errShutterHealthCheckFailed`
  /// interpolates `captureGuard.describe()` while the guard is in hand — so it stays
  /// here as the English **fallback**, exactly as `lib/transport/` and `lib/sync/`
  /// keep theirs, and [AppNoticeCodes] names each one. The UI resolves the code
  /// through `lib/l10n/message_text.dart` ([appErrorText] / [appNoticeText]) and falls
  /// back to the sentence below when the code is null or unknown; that file's library
  /// comment argues the shape.
  ///
  /// A **null** code is the deliberate pass-through case, and each such assignment
  /// says so: the text was not written in this file (a `LinkStatus` message, an
  /// `AlbumException`, the capture guard's own reason, a `DeleteReport` summary), so
  /// it is the caller's own string and must be drawn as given. Inventing a code for
  /// it would replace a true diagnostic with a plausible false one — the same reason
  /// `CameraConnection.connect`'s bare `catch` attaches none.
  ///
  /// `lastErrorParams` is read only by the case whose code just set it, so a message
  /// that interpolates nothing needs no map of its own.
  String? lastError;
  String? lastErrorCode;
  Map<String, Object?> lastErrorParams = const {};
  String? lastNotice;
  String? lastNoticeCode;
  Map<String, Object?> lastNoticeParams = const {};

  /// Report that a settings row is on screen but has nothing behind it.
  ///
  /// The menu is built from a catalog, so a row can be declared without its
  /// handler being written yet. A tap that silently does nothing is the defect
  /// the capability audit exists to catch, so the row says so instead of
  /// swallowing the tap — a message is a far better failure than a dead control.
  void noteUnwiredRow(String label) {
    lastNotice = 'Nothing is wired to "$label" yet.';
    lastNoticeCode = AppNoticeCodes.noticeUnwiredRow;
    lastNoticeParams = {'label': label};
    notifyListeners();
  }

  /// True while a capture request is outstanding.
  ///
  /// The shutter is disabled for the duration so the user cannot queue a second
  /// shot into a camera that is still writing the first — which is precisely the
  /// pattern that strands the firmware's capture state machine.
  bool capturePending = false;

  /// True while a focus command is outstanding, including the settle window.
  ///
  /// ## Why this is a shared gate rather than focus's private business
  ///
  /// The firmware defect is not "two captures" — it is **two commands**.  The
  /// capture state machine's two-phase rendezvous flags are cleared only on the
  /// "ready" branch of its callback, so a request that arrives while another is
  /// being processed takes the not-ready branch, replies `{"code":1000,...}` and
  /// returns without clearing them.  The stranded flags then zero the status word
  /// mid-capture, the preview/EVF resume never runs, the encoder starves and the
  /// HTTP task blocks forever — with **no watchdog**, so the battery is the only
  /// way back (see `analysis/04-camera-hang-bug.md` and
  /// `analysis/re-imaging-and-hang-rootcause.md`).
  ///
  /// `focusAt` used to serialise against *itself* only: a 350 ms debounce, a
  /// 250 ms gap, and an `_focusInFlight` flag that the shutter neither read nor
  /// set.  So a shutter press landing during a focus round trip put two commands
  /// on the camera's single-threaded control path at once — the exact
  /// precondition of the permanent wedge, reachable with two ordinary taps.
  ///
  /// [focusInFlight] and [capturePending] are therefore one mutual-exclusion
  /// pair: each is set before the first `await` of its operation and cleared
  /// after the last one, and neither operation may start while the other holds
  /// the bus.
  bool get focusInFlight => _focusInFlight;

  /// True when any camera command that can wedge the device is outstanding.
  bool get cameraCommandInFlight => capturePending || _focusInFlight;

  /// True when the last capture was refused — the hang precursor.
  bool get captureQuarantined => captureGuard.isQuarantined;

  /// Drive modes in which one `RCDoShooting` starts a burst this app cannot stop.
  ///
  /// ## Why this is written out here instead of imported from the guard
  ///
  /// `CaptureGuard` holds the same three names privately (`_burstDriveModes`), and a
  /// second copy is a drift risk — so the copy is **checked against the guard** by a
  /// test that builds a real guard per mode and asserts it refuses exactly these three
  /// and nothing else. A rename on either side fails that check; two independent
  /// spellings of a safety list would otherwise diverge silently, and the divergence
  /// would show up as a shutter that looks disabled on a camera that is willing to
  /// burst.
  ///
  /// The guard remains the **enforcement** — it is what actually stops the command
  /// after the first `await` of a tap. This list exists only so the UI can say so
  /// *before* the user presses anything. See [shutterBlockedReason].
  static const Set<String> kBurstDriveModes = <String>{
    'Continuous',
    '2SDelay',
    '10SDelay',
  };

  /// The drive mode that makes a shot unsafe, or null when it is safe.
  ///
  /// An unknown or absent mode is **not** unsafe: the status JSON may not have arrived
  /// yet, and refusing then would make the shutter unusable for the first moments after
  /// connecting. The guard takes the same position for the same reason.
  String? get _unsafeDriveMode {
    final drive = cameraState?.driveMode ?? '';
    return kBurstDriveModes.contains(drive) ? drive : null;
  }

  /// Whether the drive mode is one where a single command starts an unstoppable burst.
  ///
  /// Public because the capture screen tints the shutter differently for a refusal it
  /// cannot recover from, and it is the same fact [shutterBlockedReason] reports.
  bool get driveModeBlocksCapture => _unsafeDriveMode != null;

  /// Why the shutter is unavailable, or null when it is available.
  ///
  /// A disabled control that does not say why reads as a broken app, so the
  /// reason is computed here rather than left to the widget.
  ///
  /// The four sentences that explain a *failure* also carry a code — see
  /// [shutterBlockedReasonCode] — resolved by `shutterBlockedText` in
  /// `lib/l10n/message_text.dart`, the same decision [lastError] records.
  String? get shutterBlockedReason => _shutterBlock()?.text;

  /// The ARB key naming [shutterBlockedReason], or null when the shutter is fine.
  ///
  /// Null in two cases, deliberately: the shutter is available, or it is merely busy
  /// (`Capturing...` / `Focusing — …`) — neither is a failure to explain, and no ARB
  /// key was written for them, so the resolver falls back to the English above.
  String? get shutterBlockedReasonCode => _shutterBlock()?.code;

  /// The values [shutterBlockedReason] interpolates.
  ///
  /// `{'drive': …}` for the burst gate, empty for every other gate and for no gate.
  /// The value is the firmware's own wire word; its display label is applied by the
  /// resolver through `paramLabel`, never here, because the wire value is what gets
  /// sent and must not be translated in place.
  Map<String, Object?> get shutterBlockedReasonParams =>
      _shutterBlock()?.params ?? const {};

  /// The gates, evaluated once, so the sentence and its code cannot disagree about
  /// *which* gate is holding the shutter.
  ({String text, String? code, Map<String, Object?> params})? _shutterBlock() {
    if (!link.isReady) {
      return (
        text: 'Not connected to the camera.',
        code: AppNoticeCodes.shutterBlockedNotConnected,
        params: const {},
      );
    }
    if (!link.previewRunning) {
      // The message names the button, not just the problem.  A refusal or a
      // timeout is recorded as a lost link with `previewRunning: false`, and
      // nothing restores it on its own — so this is the state a user lands in
      // after a failed shot, and "start the preview first" left them to work out
      // that the fix button below does exactly that.
      return (
        text: 'The camera is not in remote mode, so it will not accept a shot. '
            'Start the preview — or press "Fix the shutter" below to do it.',
        code: AppNoticeCodes.shutterBlockedNotRemote,
        params: const {},
      );
    }
    final drive = _unsafeDriveMode;
    if (drive != null && !burstHoldAvailable) {
      // ## Why this is a *gate* and not only the guard's refusal
      //
      // The guard refuses the command — verified on the real body, where a tap in
      // `Continuous` logged `refused: drive mode is Continuous …` and the camera took
      // no frame. That is the safety half, and it is the half that must never move.
      // What it cannot do is tell the user **before** they press: the shutter was drawn
      // as pressable, and the refusal arrived afterwards as a message. A control that
      // looks live and explains itself only once it has been used is the shape this
      // project keeps having to correct — the user's own words for an earlier case were
      // that a button which does nothing reads as broken.
      //
      // So the gate is here, and the wording is the guard's own sentence rather than a
      // second phrasing of the same fact (`CaptureGuard.shoot`). If one is reworded the
      // other has to be too, which is the point: they are the same claim.
      return (
        text: 'The camera is in $drive drive. A single command starts a burst that '
            'this app has no way to stop — the camera keeps shooting until it locks '
            'up and needs its battery removed. Set the drive mode to Single, or use '
            'the camera itself.',
        code: AppNoticeCodes.shutterBlockedBurst,
        params: {'drive': drive},
      );
    }
    if (captureQuarantined) {
      // **Names the power cycle, because nothing else works.**
      //
      // This used to say "further shots are paused until the preview proves it has
      // recovered", which reads as "wait and it will come back". It will not. The
      // firmware clears the capture-state flags only on the *ready* branch, and the
      // not-ready branch returns "photo fail" without touching them, so once they are
      // set every later capture is refused for good (`analysis/40`, `analysis/43` §1).
      // Waiting, re-entering remote mode and "Release anyway" all leave the camera
      // exactly as it was; a power cycle is the only recovery, and the patched firmware
      // is the only prevention.
      //
      // Telling a user to wait for something that cannot happen is worse than telling
      // them nothing: it is the difference between a camera they power-cycle and one
      // they conclude is broken.
      return (
        text: 'The camera refused the last capture and its capture state is now stuck '
            '— this is the fault the patched firmware fixes. Waiting will not clear '
            'it: power-cycle the camera, then reconnect.',
        code: AppNoticeCodes.shutterBlockedQuarantined,
        params: const {},
      );
    }
    if (capturePending) {
      return (text: 'Capturing...', code: null, params: const {});
    }
    // Two commands in flight is the proven wedge precondition, so the shutter
    // waits for focus to settle rather than racing it.
    if (_focusInFlight) {
      return (
        text: 'Focusing — the shutter waits for it to settle.',
        code: null,
        params: const {},
      );
    }
    return null;
  }

  StreamSubscription<LinkStatus>? _links;
  Timer? _uiTicker;

  /// The switch in front of the preview frame stream.
  ///
  /// Owned by `AppState` rather than by `LiveViewPage`, because the page does
  /// **not** own the subscription: the frames also carry the camera-state JSON
  /// that `AppState` folds into [cameraState], and the ticker that drives
  /// [displayedFps] lives here.  A page that cancelled its own listener could
  /// not stop any of that — it would only stop drawing, while the decode it is
  /// complaining about carried on.
  ///
  /// What the page owns is the **fact** it is the only one that can know: is it
  /// on screen.  See [setLiveViewVisible].
  late FrameGate frameFeed;

  /// Whether frames are being decoded *and* somebody can see them.
  ///
  /// The honest gate for any "is the picture alive" verdict.  `link.previewRunning`
  /// alone is a statement about the camera; a page that is not on screen has no
  /// business reporting that its picture has stalled.
  bool get framesLive =>
      frameFeed.isDelivering && link.isReady && link.previewRunning;

  /// Tell the app whether the live view is on screen.
  ///
  /// Called by `LiveViewPage` from `didChangeDependencies`, which is where both
  /// of the things that decide it are readable and where Flutter re-runs the
  /// call when either changes:
  ///
  /// * `Visibility.of(context)` — `IndexedStack` reports non-selected children as
  ///   hidden (and rebuilds them when that flips). This is the tab switch;
  /// * `ModalRoute.isCurrentOf(context)` — false once another route covers this
  ///   one, which is what opening the album or the video page from the live view
  ///   does.
  ///
  /// Dropping the frames is purely a client-side decision.  **The camera's
  /// stream is not touched**: `PauseMovieStream`, `RCStopMovieStream` and
  /// `RCStopRemoteCtl` are unverified on this hardware and forbidden by default
  /// (`AGENTS.md` §4.6), so "stop decoding" must not become "stop the camera".
  ///
  /// ## Why the notification is deferred
  ///
  /// `didChangeDependencies` runs **inside** the build phase, and notifying
  /// listeners from there reaches the shell's `AnimatedBuilder` while it is
  /// already building:
  ///
  /// ```
  /// setState() or markNeedsBuild() called during build.
  /// The widget on which setState() or markNeedsBuild() was called was:
  ///   AnimatedBuilder
  /// ```
  ///
  /// A post-frame callback lands after that build finishes: soon enough to be
  /// invisible, late enough to be legal.  `SchedulerBinding` rather than
  /// `addPostFrameCallback` on a context, because the caller is a page that may
  /// be on its way out.
  void setLiveViewVisible(bool visible) {
    if (_liveViewOnScreen == visible) return;
    _liveViewOnScreen = visible;
    _applyFrameWiring();
    // The frame-rate readout is a claim about what is being drawn, and nothing
    // is being drawn while it is hidden.  Left alone it would report the rate
    // from before the tab was switched, which looks like a working preview.
    if (!visible) {
      _drawnSinceSample = 0;
      _displayedFps = 0;
    }
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!_disposed) notifyListeners();
    });
  }

  /// Starts **false**, and that default is load-bearing.
  ///
  /// Nobody has reported being on screen yet, so nothing is drawn and there is
  /// nothing to refresh.  It also keeps the periodic chrome ticker from being
  /// started by a mere `AppState` construction: `flutter_test` verifies "no timer
  /// is pending" *before* `addTearDown` callbacks run, so a timer started because
  /// an injected connection claims the preview is running outlives the test body
  /// and fails it — reporting timers rather than anything the test was checking.
  /// `LiveViewPage` reports itself visible from `didChangeDependencies`, so the
  /// ticker starts when a page is actually there to read it.
  bool _liveViewOnScreen = false;
  bool _disposed = false;

  AppState({
    required BleTransport ble,
    PairingStore? store,
    AssetSink? sink,
    WifiJoinDelegate? wifiJoin,
    // Test-only pass-through to `CameraConnection`: puts the link straight into its
    // ready state so the screens that only exist while connected can be rendered
    // and measured. An Android emulator has no Bluetooth adapter, so the real
    // sequence cannot be shortened any other way — see the note on the same
    // argument in `CameraConnection`.
    CameraHttpClient? testHttp,
    CameraIdentity? testIdentity,
    bool testPreviewRunning = false,
    Future<bool> Function()? testPreviewStarter,
    // Test-only. A receiver bound to a port the test chose, so a test can feed
    // frames without competing with the real camera's forwarded 54321.
    CameraLiveView? testLiveView,    // Test-only. The album downloads through raw HTTP (its body *is* the file),
    // which a widget test has no server for. Supplying this lets the album grid
    // and the viewer render real bytes on a desk — see `FAKE_CAMERA` in
    // `app.dart`. Production never passes it.
    Future<Uint8List> Function(AlbumFile, FileResolution)? testAlbumDownload,
    // Test-only. Supplies the remembered first-run answers, so the launch path that
    // applies them can be driven from a store with a known mode in it.
    OnboardingPrefs? testOnboardingPrefs,
    // Test-only, same reason as `testOnboardingPrefs`: keeps the launch path off the
    // platform channel so _load() does not gain an asynchronous gap under it.
    UiPrefs? testUiPrefs,
  }) : connection = CameraConnection(
          ble: ble,
          store: store ?? MemoryPairingStore(),
          // Must be supplied in production: the default answers "no" to every
          // join request, which silently disables Wi-Fi auto-join and leaves the
          // user typing an 8-digit passkey by hand.  Exactly that happened once,
          // which is why `tools/audit_app_capabilities.py` now checks for it.
          wifiJoin: wifiJoin ?? NoopWifiJoinDelegate(),
          testHttp: testHttp,
          testIdentity: testIdentity,
          testPreviewRunning: testPreviewRunning,
        ),
        _testAlbumDownload = testAlbumDownload,
        uiPrefs = testUiPrefs ??
            UiPrefs(store: FileSyncStore.forUiPrefs(), onLog: (m) => debugPrint(m)),
        onboardingPrefs = testOnboardingPrefs ??
            OnboardingPrefs(store: PrefsStore(), onLog: (m) => debugPrint(m)) {
    if (testLiveView != null) _liveView = testLiveView;
    // Watch the app lifecycle, or the network pin is never released.
    //
    // `didChangeAppLifecycleState` below unbinds the process from the camera's
    // access point when the app leaves the foreground — a process-wide binding
    // means **no internet at all** while it is in force — and re-binds on return.
    // Neither runs without this line, and its absence is invisible: the app works,
    // it just quietly keeps the phone offline in the background and comes back
    // unable to reach a camera it never disconnected from.
    //
    // `removeObserver` in `dispose` was present from the start, which made the
    // omission look like it was handled.
    WidgetsBinding.instance.addObserver(this);

    testStartPreview = testPreviewStarter;

    // The gate is built here, not on connect: it is a plain object wrapping the
    // receiver's frame stream, and the stream exists from the moment the view
    // does. Building it lazily would mean the first frames after a reconnect
    // were delivered by a gate nobody had wired a subscriber to.
    frameFeed = FrameGate(
      frames: liveView.frames,
      onFrame: _onFrame,
    );

    // The guard must talk to the *live* client, and that client only exists once
    // the link is ready.  Passing a snapshot here would hand it a detached
    // client that always fails, so it gets a function instead.
    captureGuard = CaptureGuard(
      // A closure, not `_liveHttp`. The guard outlives the link's readiness, and this
      // line previously evaluated the getter once at construction — while the app was
      // still disconnected — so the guard held the "not connected" stub forever and
      // every capture threw before reaching the camera. See `CaptureGuard.http`.
      http: () => _liveHttp,
      liveView: liveView,
      // The burst interlock reads the camera's own drive mode. Reported from hardware:
      // in Continuous a single RCDoShooting starts a burst this app cannot stop.
      driveMode: () => cameraState?.driveMode ?? '',
      // Printed here rather than inside the guard, which must stay free of
      // `package:flutter` so the transport layer keeps running in a pure Dart VM.
      log: (m) => debugPrint('[capture] $m'),
    );

    // §5.3: the preview and a bulk transfer share one 802.11n link, so a sync run
    // holds the stream paused for its duration and hands it back afterwards.
    //
    // Gated on `previewRunning`, because `PauseMovieStream` only means anything
    // while the camera is in remote-control mode: with the preview stopped there
    // is nothing to pause and the command would be sent to a camera that has no
    // reason to expect it — which is a risk not worth taking on a device with no
    // watchdog. A skipped pause costs nothing, because the stream is already off.
    streamPause = HttpStreamPauseController(
      http: () => _liveHttp,
      isAvailable: () => link.previewRunning,
      onLog: (m) => debugPrint(m),
    );

    sync = SyncEngine(
      album: () {
        final a = album;
        if (a == null) {
          throw const AlbumException(
              'not connected to the camera, so the album is unavailable');
        }
        return a;
      },
      ledger: ledger,
      sink: sink ?? MediaStoreSink(),
      queue: queue,
      streamPause: streamPause,
      // The queue is written on the engine's own schedule — after a preview
      // lands, after an item finishes, at the end of a run — rather than through
      // a getter, so that the file always reflects the last thing that actually
      // happened rather than the last time a screen was built.
      onQueueChanged: () => unawaited(queue.save()),
      // The engine is deliberately Flutter-free — it is verified offline by
      // tool/verify_sync.dart — so it reports changes through a callback rather
      // than a ChangeNotifier.
      onChanged: notifyListeners,
      onLog: (m) => debugPrint(m),
    );

    // Both halves of the durable state must be ready before anything is
    // enqueued, and the queue restore must come *after* the ledger has loaded:
    // the restore consults the ledger to drop work that is already on the phone,
    // so a restore racing the ledger would re-offer finished files.
    unawaited(loadDurableState());

    _links = connection.status.listen(_onLinkStatus);
    // Apply the status the connection is **already** in.
    //
    // A broadcast stream delivers only what happens after subscription, so a link
    // that reached `ready` before this line — which is exactly what the injected
    // connection does, and what any future "restore the last session" path would do
    // — never fired the listener. The visible result was a contradiction: the
    // header and the shutter read "connected" while the album tab said "Not
    // connected. Connect to the camera first.", because `album` was still null. It
    // cost a debugging round on the verification harness before being traced here,
    // and the harness was right to fail: the same gap would swallow a real restore.
    _onLinkStatus(connection.current);
  }

  /// One place that reacts to the link changing state.
  ///
  /// Extracted from the constructor's `listen` callback so the current status can be
  /// applied through the same path — two call sites that must agree about what
  /// "ready" and "lost" mean is how they drift apart.
  void _onLinkStatus(LinkStatus s) {
    // The frame pipeline follows the link, from here rather than from the
    // constructor or from `startPreview` alone.
    //
    // `CameraConnection.startPreview` emits a `ready` status with
    // `previewRunning: true`, so this covers the production path; it also covers
    // the injected `ready` state, which arrives before any page exists.  Tying it
    // to the link rather than to the constructor matters: a ticker started at
    // construction is a periodic timer running for an app that has not been told
    // to preview anything, and in a widget test that timer is still pending when
    // the test body ends — which the binding reports as a failure of the test,
    // not of the widget.
    _applyFrameWiring();
    if (s.stage == LinkStage.ready) {
      album ??= CameraAlbum(connection.http,
          overrideDownload: _testAlbumDownload, gate: cameraGate);
      sync.cameraConnected();
      // Do not auto-start a transfer merely because BLE/Wi-Fi reached ready.
      // The camera exposes one small HTTP server; starting GetFile traffic here
      // can race the user's first RCStartRemoteCtl and wedge the camera. Album
      // browsing and an explicit sync action are the safe, user-visible triggers.
      // Keep cameraConnected() for queue state restoration, but defer run().
    } else if (s.stage == LinkStage.lost || s.stage == LinkStage.idle) {
      // A pause, not a failure: the camera going away is the most likely
      // interruption, and the queue must survive it.
      sync.cameraLost();
      // The capture interlock does **not** survive it.
      //
      // Its quarantine is a verdict about a particular camera session, and the one
      // recovery that works — a power cycle — begins by dropping the access point. So
      // the app reconnects to a fresh camera while holding a judgement about the old
      // one, and the shutter stays stuck with "the capture state is stuck, power-cycle
      // it" on a camera that was just power-cycled. Reported from hardware exactly
      // that way.
      captureGuard.onLinkLost();
    }
    if (s.stage == LinkStage.failed || s.stage == LinkStage.idle) {
      _stopFrameSubscription();
    }
    notifyListeners();
  }

  /// Load the ledger and then rebuild the pending queue from disk.
  ///
  /// Exposed and idempotent so a screen that is about to browse the album can
  /// `await` it first; the constructor already starts it, because a sync can also
  /// begin from the link coming up without anyone opening the album.
  Future<void> loadDurableState() async {
    if (_durableStateLoaded) return _loading;
    _durableStateLoaded = true;
    _loading = _load();
    return _loading;
  }

  bool _durableStateLoaded = false;
  late Future<void> _loading;

  Future<void> _load() async {
    await ledger.load();
    await queue.load();
    // Read before the first build that can open the settings panel, so the user's
    // arrangement is the one they see rather than a default that visibly
    // corrects itself a frame later.
    await uiPrefs.load();
    // The sync mode the first-run flow asked for, applied **here and not in the
    // constructor**: `sync` is built well before this point, so reading the preference
    // there would read an instance nothing has loaded yet and silently take the
    // default. A remembered answer that is not applied is worse than not asking — the
    // user picks "full size only", is asked nothing next launch, and gets the default.
    await onboardingPrefs.load();
    sync.mode = syncModeFromId(onboardingPrefs.effectiveSyncMode);
    sync.restore();
    // Writing back immediately normalises the file and, more importantly, drops
    // anything the ledger already holds — a queue that is only ever appended to
    // is the unbounded file the bound exists to prevent.
    await queue.save();
    notifyListeners();
  }

  // -------------------------------------------------- live-view layout prefs

  /// Whether a settings group is open, honouring the group's own default when
  /// the user has never touched it.
  bool isSettingsGroupOpen(String groupId) => uiPrefs.isGroupOpen(
        groupId,
        fallback: kSettingsGroupById(groupId)?.openByDefault ?? false,
      );

  /// Open or close one group and remember it across launches.
  ///
  /// Saved on every toggle rather than at shutdown: this app is killed by the
  /// system during a transfer, and a preference written only on exit would be
  /// the one that never lands.
  void setSettingsGroupOpen(String groupId, bool open) {
    uiPrefs.setGroupOpen(groupId, open);
    notifyListeners();
    unawaited(uiPrefs.save());
  }

  void toggleSettingsGroup(String groupId) =>
      setSettingsGroupOpen(groupId, !isSettingsGroupOpen(groupId));

  /// The last settings tab the user was on, falling back to the first.
  String get settingsTab {
    final saved = uiPrefs.lastTab;
    if (saved != null && kSettingsTabs.any((t) => t.id == saved)) return saved;
    return kSettingsTabs.first.id;
  }

  set settingsTab(String tabId) {
    if (tabId == uiPrefs.lastTab) return;
    uiPrefs.setLastTab(tabId);
    notifyListeners();
    unawaited(uiPrefs.save());
  }

  // The menu's structure itself lives in `protocol/settings_menu.dart`: it is a
  // claim about the UI that `tool/verify_transport.dart` checks in the plain Dart
  // VM, which cannot import this file because of Flutter. What belongs here is
  // only the part that needs the preferences — reading and writing it.

  /// A client bound to the current connection.
  ///
  /// Before the link is ready this returns a detached client, which the guard
  /// only ever uses for a health probe it will treat as a failure — the safe
  /// direction.
  CameraHttpClient get _liveHttp => connection.isReady
      ? connection.http
      : CameraHttpClient(overrideSend: _unreachable);

  /// Re-read the platform's Wi-Fi permission state, measured just now.
  ///
  /// Used by the Wi-Fi diagnostics sheet. Nothing here is inferred from the
  /// Android version: every field is read from the running platform, because
  /// guessing is what produced a false "grant this permission" instruction twice.
  Future<WifiPermissionReport> readPermissionReport() =>
      connection.readPermissionReport();

  /// Open the system Wi-Fi surface for the manual fallback.
  Future<bool> openWifiPanel() => connection.openWifiPanel();

  /// Open this app's own permission screen.
  Future<bool> openPermissionSettings() => connection.openPermissionSettings();

  static Future<CameraResponse> _unreachable(
          String command, Map<String, Object> p) async =>
      throw const CameraHttpException('not connected to the camera');

  // ---------------------------------------------------------------- lifecycle

  /// Start transferring, after making sure the phone will let us store the result.
  ///
  /// Every entry point that resumes the queue goes through here rather than calling
  /// `sync.resume()` directly, because on Android 9 and older the shared photo
  /// library needs `WRITE_EXTERNAL_STORAGE` **granted** — and a sync that starts
  /// without it fails on every single file with a permission-shaped error, which is
  /// a confusing way to learn about a missing prompt. It is also the kind of gap
  /// that stays invisible: the app installs, the sync runs, and nothing arrives.
  ///
  /// On Android 10+ the call answers immediately without showing anything, so this
  /// costs nothing there.
  ///
  /// Returns whether storage is usable. The sync is **still started** when it is
  /// not: the ledger then records each failure with its reason, which tells the user
  /// more than a queue that silently refuses to move.
  Future<bool> beginTransfer() async {
    if (!Platform.isAndroid) {
      resumeSync();
      return true;
    }
    final ok = await MediaStoreBridge.requestLegacyStorage();
    if (!ok) {
      lastError = 'Android will not let the app write to the photo library, so '
          'nothing can be saved. Grant the storage permission to this app, then '
          'start the sync again.';
      lastErrorCode = AppNoticeCodes.errStorageDenied;
      notifyListeners();
    }
    resumeSync();
    return ok;
  }

  /// Un-pause the sync, and make sure the screen hears about it.
  ///
  /// ## Why this is not just `sync.resume()`
  ///
  /// `SyncEngine.resume()` clears its own `paused` flag, logs, and hands over to
  /// `run()` — and **`run()` returns before it notifies anything** in two ordinary
  /// cases: a run is already in flight (`_running`), or the camera is away
  /// (`!_cameraPresent`, which is exactly the state after a lost link). Nothing else
  /// in `resume()` reports the change. So the engine really did change — it is no
  /// longer paused — while every listener it has stays uninformed, and the sync bar
  /// goes on offering **Resume** on an engine that is not paused. Tapping it again
  /// changes nothing, because the second call takes the same silent path.
  ///
  /// Reported as part of the same symptom as [setSyncMode]'s: the sync screen's
  /// controls not moving in real time.
  ///
  /// The notification is unconditional rather than conditional on something having
  /// changed. `ChangeNotifier` de-duplicates nothing, but it also costs nothing here:
  /// this is a tap handler, not a per-frame path, and a spurious `notifyListeners()`
  /// rebuilds the same tree the following frame would have rebuilt anyway. What it
  /// buys is that the one place the app resumes a paused sync cannot leave the UI
  /// describing a state the engine has left.
  void resumeSync() {
    sync.resume();
    notifyListeners();
  }

  Future<void> connect({void Function()? onPairingRequested}) async {
    lastError = null;
    lastErrorCode = null;
    lastErrorParams = const {};
    final ok = await connection.connect(onPairingRequested: onPairingRequested);
    if (!ok) {
      // The status carries its own code, and it is carried **through** rather than
      // stripped: `appErrorText` resolves a `LinkCodes` value as happily as an
      // `AppNoticeCodes` one, and this line used to clear it on the theory that the
      // text had "already been resolved at its own source". It had not — the strip
      // that draws `lastError` never calls `linkStatusText` — so a failed connect put
      // English on a Chinese screen. See `lib/l10n/message_text.dart`.
      lastError = connection.current.message;
      lastErrorCode = connection.current.messageCode;
      lastErrorParams = connection.current.messageParams;
    }
    notifyListeners();
  }

  /// Disconnect deliberately.
  ///
  /// Stops the preview before tearing the link down, because leaving the camera
  /// in remote mode with nobody listening keeps it encoding and burning battery.
  ///
  /// ## Where the outcome is reported, and why not here
  ///
  /// [CameraConnection.disconnect] answers whether the phone left the camera's
  /// network and whether the camera's radio was switched off, and it puts both
  /// into the [LinkStatus] it emits (`LinkCodes.disconnectedRadioOff` /
  /// `disconnectedRadioLeftOn`, with the reason in `messageParams`). That status is
  /// drawn at two sites in `lib/ui/pages/live_view_page.dart` — including the
  /// connect bar this call leaves the user standing on — so it is already in front
  /// of them, and it already resolves through the ARB.
  ///
  /// It is deliberately **not** copied into `lastNotice` as well. Only the album
  /// page reads that field, so a copy would be invisible on the screen the user is
  /// actually looking at, and it would be a second, independently-worded claim
  /// about the same fact — the shape of defect this round is about.
  Future<void> disconnect() async {
    await stopPreview();
    await connection.disconnect();
    album = null;
    notifyListeners();
  }

  /// Ask the camera whether it is still there.
  ///
  /// The link can die without any socket error surfacing — the camera drops its
  /// access point, or the phone silently roams to another network — and then the
  /// app looks connected while nothing works.  This is the cheap check that turns
  /// that into a visible state.
  ///
  /// It also runs in the **opposite** direction, which is what makes a loss
  /// recoverable: from [LinkStage.lost] a successful probe restores the link and
  /// re-pins the process to the camera's network. The guard is
  /// `CameraConnection.canProbe` rather than `isReady` on purpose — measuring
  /// "ready" would refuse to probe the very state the probe exists to repair, and
  /// since a loss clears the ready flag, `lost` would be terminal. It was.
  Future<bool> verifyAlive() async {
    // The lost state has no network pin (reporting a loss releases it), so a probe
    // from there can fail with a socket error that says nothing about the camera.
    // Trying anyway is still right: it is the only way back, and a probe that fails
    // costs one timeout.
    if (!connection.canProbe) return false;
    try {
      final r = await connection.http.status().timeout(const Duration(seconds: 5));
      if (r.ok) {
        if (link.stage == LinkStage.lost) {
          await _emitRecovered();
          // A recovered link must resume the frame subscription the loss tore
          // down, or the preview stays black while the app claims to be connected.
          if (link.isReady && link.previewRunning) _applyFrameWiring();
          return link.isReady;
        }
        return true;
      }
    } on Object {
      // fall through to the failure report
    }
    _emitLost();
    return false;
  }

  void _emitLost() {
    // Reuse the connection's own status stream so the UI has one source of truth.
    //
    // The sentence is this layer's — it knows what it was doing when the camera stopped
    // answering — and the code travels with it so the UI can draw it in the reader's
    // language rather than falling back to this English.
    connection.reportLost(
        'Lost contact with the camera. It may have been switched off, or the '
        'phone may have left the camera\'s Wi-Fi network.',
        code: LinkCodes.lostContact);
    _stopFrameSubscription();
    notifyListeners();
  }

  Future<void> _emitRecovered() async {
    await connection.clearLost();
    notifyListeners();
  }

  /// Start the preview.  Binds UDP before commanding the camera, because frames
  /// begin the moment remote mode is entered.
  ///
  /// ## Why there is a test seam here and nowhere else
  ///
  /// `CameraConnection.startPreview` opens a real `RawDatagramSocket` on UDP
  /// 54321 before it sends anything, and a real socket completion **never
  /// arrives inside a widget test's fake clock**: the future simply never
  /// resolves, so a test that reaches this method hangs instead of failing —
  /// which it did, twice, for ten minutes a run.  That makes the "link up,
  /// preview stopped" state, the one [forceReleaseCapture] exists for,
  /// unreachable from a socket-free test through the production path.
  ///
  /// So the socket half is injectable.  Production never sets it; the one
  /// behaviour that matters is preserved either way, because the seam's contract
  /// is "send `RCStartRemoteCtl` and report whether it was accepted".
  Future<void> startPreview() async {
    if (link.previewRunning) return;
    lastError = null;
    lastErrorCode = null;
    lastErrorParams = const {};
    final injected = testStartPreview;
    if (injected != null) {
      final ok = await injected();
      if (ok) {
        _applyFrameWiring();
      } else {
        lastError = 'the camera refused to start the preview';
        lastErrorCode = AppNoticeCodes.errPreviewRefused;
      }
      notifyListeners();
      return;
    }
    final ok = await connection.startPreview();

    // Push the clock only after the remote mode was accepted. Sending BLE/HTTP
    // side work while RCStartRemoteCtl is still in flight can overload the
    // camera's single control path and obscure the real failure.
    if (ok) unawaited(connection.syncTime());

    if (ok) {
      _applyFrameWiring();
    } else {
      lastError = 'the camera refused to start the preview';
      lastErrorCode = AppNoticeCodes.errPreviewRefused;
    }
    notifyListeners();
  }

  /// See [startPreview].  Null in production; wired by `test/focus_shutter_ui_test.dart`
  /// through the `testPreviewStarter` constructor argument.
  Future<bool> Function()? testStartPreview;

  /// Bring the frame pipeline and the chrome ticker into line with the link and
  /// the page's visibility.
  ///
  /// One method rather than two because the two halves have to agree: the gate
  /// decides whether frames are decoded, the ticker decides whether anything is
  /// redrawn, and a state where one is on and the other off is either a
  /// decoding page nobody repaints or a repainting page with nothing to draw.
  ///
  /// Everything here is idempotent — it is called from the link watcher, from
  /// [startPreview], from [stopPreview] and from [setLiveViewVisible], and those
  /// genuinely overlap.
  ///
  /// ## Why the ticker needs a *visible* page as well
  ///
  /// The ticker exists to keep the chrome — fps, loss, the state strip — moving
  /// on a screen somebody is reading.  With the live view off screen there is
  /// nothing to keep moving, and a periodic timer that rebuilds the whole shell
  /// for a hidden page is the same class of waste as decoding frames for it.
  ///
  /// It is also the difference between a legal and an illegal widget test.
  /// `flutter_test` verifies "no timer is pending" **before** `addTearDown`
  /// callbacks run, so a periodic timer started merely because the injected
  /// connection claims the preview is running outlives the test body and fails
  /// it — with a message about timers, saying nothing about what was being
  /// checked.
  void _applyFrameWiring() {
    final wantFrames = link.isReady && link.previewRunning;

    if (wantFrames) {
      // `start()` first, then the visibility: `start()` subscribes when the
      // current visibility allows it, and `setVisible` is a no-op when the value
      // has not changed — which it has not, on the `ready` path where the page
      // has already reported itself visible.  Doing it the other way round left
      // the gate started but never subscribed.
      frameFeed.start();
      frameFeed.setVisible(_liveViewOnScreen);
    } else {
      _stopFrameSubscription();
    }

    // Separate from `wantFrames`, so that hiding and showing the tab neither
    // restarts the gate nor leaves a timer behind.
    if (wantFrames && _liveViewOnScreen) {
      // The chrome refreshes on a ticker rather than per frame.  This also keeps
      // fps and loss figures moving even when frames have stopped arriving, which
      // is exactly when the user needs to see that they have stopped.
      _uiTicker ??= Timer.periodic(const Duration(milliseconds: 250), (_) {
        _displayedFps = _drawnSinceSample * 4.0;
        _drawnSinceSample = 0;
        notifyListeners();
      });
    } else {
      _uiTicker?.cancel();
      _uiTicker = null;
    }
  }

  void _stopFrameSubscription() {
    _uiTicker?.cancel();
    _uiTicker = null;
    // A stopped gate is finished: `start()` refuses afterwards, which is what
    // makes "the preview stopped" different from "the tab is hidden".  The next
    // preview start builds a fresh one — the same shape the old code had, where
    // the cancelled subscription was replaced rather than resumed.
    frameFeed.dispose();
    frameFeed = FrameGate(
      frames: liveView.frames,
      onFrame: _onFrame,
      visible: _liveViewOnScreen,
    );
    _displayedFps = 0;
  }

  void _onFrame(LiveViewFrame f) {
    frameNotifier.value = f.jpeg;
    _drawnSinceSample++;
    final s = f.state;
    if (s != null) _cameraState = s;
  }

  // A frame-skipping render was tried here and **deliberately removed**.
  //
  // The reasoning was that decoding 800x600 JPEGs at 30 fps competes with the UDP
  // receive loop, so drawing every other frame would halve the cost. That trade is
  // wrong for this product: it buys CPU the user cannot see and pays with
  // smoothness the user can. And the measured evidence points elsewhere anyway —
  // when the camera itself starves its preview encoder during a capture, the
  // datagram rate falls from 29.7/s to 2.8/s, so a client that renders only half
  // of what arrives is optimising the wrong half of the problem.
  //
  // What *was* kept is the work that costs nothing visible: decoding straight to
  // the drawn size (`cacheWidth` in the active view) and bounding the image cache
  // so 30 new byte arrays a second cannot churn it. Both remove waste rather than
  // removing frames.

  Future<void> stopPreview() async {
    _stopFrameSubscription();
    await connection.stopPreview();
    frameNotifier.value = null;
    _cameraState = null;
    notifyListeners();
  }

  // ------------------------------------------------------------------ delete

  /// Delete shots from the camera's card, one request at a time.
  ///
  /// [groups] is a selection from the album, so a RAW+JPEG pair arrives as one
  /// item and `planDelete` keeps it that way. Nothing is sent before the plan has
  /// decided what it will refuse and why, and the outcome for every path comes
  /// back for the caller to display: this firmware answers `200` to work it did
  /// not do, so `FileDeleter` re-lists the album and reports what it can and
  /// cannot confirm (see `transport/album_delete.dart`).
  ///
  /// ## Why sync is paused for the duration
  ///
  /// The camera serves one request at a time and treats an unexpected command
  /// badly — it has no watchdog, so a stall means the battery comes out. A delete
  /// that overlapped a bulk transfer would be exactly that. The pause is restored
  /// to whatever it was: a sync the *user* paused must not silently start again
  /// because they deleted some photos.
  ///
  // ------------------------------------------------------------- share / open

  /// The local identifiers of the assets in [groups] that are on this phone.
  ///
  /// Only the ones the ledger knows about: an asset still queued has nothing to
  /// share, and inventing a path for it would produce a share sheet that attaches
  /// a broken file. The original is preferred over a preview because sharing a
  /// 1440×1080 stand-in while the full-resolution copy sits on the phone is a
  /// silent downgrade — the exact thing the sync design forbids.
  List<String> localIdsFor(List<AssetGroup> groups) {
    final out = <String>[];
    final seen = <String>{};
    for (final g in groups) {
      // A group is one shutter press but can contain JPEG and RAW assets. Check
      // every rendition: a RAW-only group, or a group whose JPEG upgrade failed,
      // must not be reported as absent when another rendition is on the phone.
      for (final asset in g.assets) {
        final id = sync.ledger.localIdOf(AssetId(
          path: asset.path,
          dateSeconds: asset.captureTime?.millisecondsSinceEpoch != null
              ? asset.captureTime!.millisecondsSinceEpoch ~/ 1000
              : 0,
        ));
        if (id != null && id.isNotEmpty && seen.add(id)) out.add(id);
      }
    }
    return out;
  }

  /// Hand the selected shots to the system share sheet (spec T20–T24).
  ///
  /// Answers how many items were shared, so the UI can distinguish "nothing to
  /// share yet" from "the share sheet could not be opened" — they look identical
  /// to a user staring at a sheet that never appeared.
  Future<int> shareGroups(List<AssetGroup> groups, {String? title}) async {
    final ids = localIdsFor(groups);
    if (ids.isEmpty) {
      lastNotice = 'Those shots are not on this phone yet. Sync them first, or '
          'share from the camera by syncing and then sharing.';
      lastNoticeCode = AppNoticeCodes.noticeShotsNotOnPhone;
      notifyListeners();
      return 0;
    }
    final sink = sync.sink;
    if (sink is! MediaStoreSink) {
      lastError = 'sharing is only implemented on Android.';
      lastErrorCode = AppNoticeCodes.errShareAndroidOnly;
      notifyListeners();
      return 0;
    }
    final ok = await sink.share(ids, title: title);
    if (!ok) {
      lastError = 'Android would not open a share sheet for those files.';
      lastErrorCode = AppNoticeCodes.errShareSheetRefused;
      notifyListeners();
      return 0;
    }
    final missing = groups.length - ids.length;
    lastNotice = missing > 0
        ? 'Shared $missing of ${groups.length}; the rest are still syncing.'
        : null;
    if (missing > 0) {
      lastNoticeCode = AppNoticeCodes.noticeSharedPartially;
      lastNoticeParams = {'missing': missing, 'total': groups.length};
    } else {
      lastNoticeCode = null;
      lastNoticeParams = const {};
    }
    notifyListeners();
    return ids.length;
  }

  /// Open one shot in whatever app the phone has for it.
  Future<bool> openGroup(AssetGroup group) async {
    final id = sync.ledger.localIdOf(group.id);
    if (id == null || id.isEmpty) {
      lastNotice = 'That shot is not on this phone yet.';
      lastNoticeCode = AppNoticeCodes.noticeShotNotOnPhone;
      notifyListeners();
      return false;
    }
    final sink = sync.sink;
    if (sink is! MediaStoreSink) return false;
    final ok = await sink.open(id);
    if (!ok) {
      lastError = 'No app on this phone would open that file.';
      lastErrorCode = AppNoticeCodes.errNoViewerApp;
      notifyListeners();
    }
    return ok;
  }

  /// Delete the phone's copy of a shot, leaving the camera's alone.
  ///
  /// Offered by the album grid's long-press menu, because "remove from my phone"
  /// is what a user wants after a mistaken sync, and the only other way to do it
  /// was to find the file in the system gallery by hand.
  Future<bool> removeLocalCopy(AssetGroup group) async {
    final id = sync.ledger.localIdOf(group.id);
    if (id == null || id.isEmpty) return false;
    final sink = sync.sink;
    if (sink is! MediaStoreSink) return false;
    final ok = await sink.remove(id);
    if (ok) {
      // The ledger must forget it too, or the app keeps claiming the file is on
      // the phone and a later sync decides there is nothing to fetch.
      sync.ledger.forgetLocal(group.id);
      await sync.ledger.save();
      notifyListeners();
    } else {
      lastError = 'Could not remove the phone\'s copy.';
      lastErrorCode = AppNoticeCodes.errRemoveCopyFailed;
      notifyListeners();
    }
    return ok;
  }

  /// Returns null when there is nothing deletable, or when there is no camera.
  Future<DeleteReport?> deleteFiles(    List<AssetGroup> groups, {
    void Function(DeleteBatch batch, int index, int total)? onBatch,
  }) async {
    final a = album;
    if (a == null) {
      lastError = 'not connected to the camera, so there is nothing to delete.';
      lastErrorCode = AppNoticeCodes.errDeleteNotConnected;
      notifyListeners();
      return null;
    }

    final plan = planDelete(groups);
    if (plan.isEmpty) {
      lastNotice = plan.hasRefusals
          ? 'Nothing was sent: every selected shot is one the app will not '
              'delete. See the reasons listed.'
          : 'Nothing to delete.';
      lastNoticeCode = plan.hasRefusals
          ? AppNoticeCodes.noticeNothingSentAllRefused
          : AppNoticeCodes.noticeNothingToDelete;
      notifyListeners();
      return null;
    }

    final wasPaused = sync.paused;
    sync.pause();
    try {
      final report = await FileDeleter(
        album: a,
        onBatch: onBatch,
        onLog: (m) => debugPrint(m),
      ).submit(plan);

      // Anything the card no longer has must leave the transfer queue as well,
      // or the next sync run retries a path that cannot be fetched and files the
      // photo the user just deleted under "failed".
      sync.dropPaths({
        for (final o in report.of(DeleteVerdict.confirmedGone)) o.path,
      });
      // The text is `DeleteReport.summary`, written by the transport's own deleter
      // and already final prose; there is no code for it here.
      lastNotice = report.summary;
      lastNoticeCode = null;
      lastNoticeParams = const {};
      lastError = null;
      lastErrorCode = null;
      lastErrorParams = const {};
      return report;
    } on Object catch (e) {
      lastError = 'the delete could not be carried out: $e';
      lastErrorCode = AppNoticeCodes.errDeleteFailed;
      lastErrorParams = {'detail': '$e'};
      return null;
    } finally {
      if (!wasPaused) sync.resume();
      notifyListeners();
    }
  }

  // ----------------------------------------------------------------- commands

  /// Send a command and surface the outcome.
  ///
  /// Success is **not** inferred from HTTP 200: this firmware answers 200 to
  /// commands it silently ignored.  The stream's state JSON is the real
  /// confirmation, so the UI reads [cameraState] a moment later.
  ///
  /// `Map<String, Object>` rather than `Map<String, String>` because
  /// `DeleteFile`'s `file_list` is a JSON *array* of paths; every other caller
  /// still passes strings.  Deletion does not run through here: it needs the same
  /// "200 is not proof" reasoning this method applies, and it gets it in
  /// [deleteFiles] by re-listing the album afterwards.
  Future<bool> send(String command, [Map<String, Object> params = const {}]) async {
    if (!connection.isReady) {
      lastError = 'not connected';
      lastErrorCode = AppNoticeCodes.errNotConnectedShort;
      notifyListeners();
      return false;
    }
    try {
      final r = await connection.http.send(command, params);
      if (!r.ok) {
        lastError = '$command failed: ${r.data ?? r.raw}';
        lastErrorCode = AppNoticeCodes.errCommandFailed;
        lastErrorParams = {
          'command': command,
          'detail': '${r.data ?? r.raw}',
        };
        notifyListeners();
        return false;
      }
      return true;
    } on CameraHttpException catch (e) {
      if (e.isBadParameters) {
        lastError = '$command was rejected — the camera answered 404, which on '
            'this firmware means the parameters were wrong';
        lastErrorCode = AppNoticeCodes.errCommandRejected404;
        lastErrorParams = {'command': command};
      } else {
        lastError = '$command failed: ${e.message}';
        lastErrorCode = AppNoticeCodes.errCommandFailed;
        lastErrorParams = {'command': command, 'detail': e.message};
        // A dead transport is the strongest signal that the link is gone, so it
        // is worth confirming rather than leaving the UI claiming to be live.
        unawaited(verifyAlive());
      }
      notifyListeners();
      return false;
    }
  }

  /// Make the shutter work again, without waiting out the cool-down.
  ///
  /// The probe cannot tell "the link is slow" from "the camera is wedged", and
  /// the user may have information it lacks — they might have power-cycled the
  /// camera, reseated the battery, or reconnected the Wi-Fi.  A safety feature
  /// that cannot be overridden becomes a dead end, so this exists.
  ///
  /// ## Why this is more than "clear the flag"
  ///
  /// Clearing the interlock alone left the shutter dead in the case the user
  /// actually reported.  [shutterBlockedReason] has three gates and the interlock
  /// is only one of them; [forceReleaseCapture] did nothing about the other two,
  /// so the button appeared to work, the quarantine really was lifted, and the
  /// shutter stayed grey with no way forward.  The one that bites is the preview:
  ///
  /// * the camera refusing a capture, or the HTTP probe timing out after one, is
  ///   treated as a lost link;
  /// * a lost link is recorded with `previewRunning: false` — the stream really
  ///   has stopped — and nothing ever sets it back, because the app deliberately
  ///   does not auto-start work on a recovered link;
  /// * so even after the camera answers again, the shutter reports "start the
  ///   preview first" and the user has no reason to connect the two.
  ///
  /// `RCStartRemoteCtl` is the one command this app is willing to re-send
  /// unattended (it is idempotent and the preview keeps running — see
  /// [_reassertRemoteMode]), and re-entering remote mode is exactly what the
  /// shutter needs.  It is also the only one sent here: no capture is ever issued
  /// on the user's behalf, because a camera that is genuinely wedged must not be
  /// poked with the one command that can strand its capture flags.
  Future<void> forceReleaseCapture() async {
    // Nothing here may escape as an exception.
    //
    // The button calls this with `unawaited(...)`, so a throw would be swallowed by the
    // zone and the user would see **absolutely nothing** — the exact report that
    // "Release anyway does nothing". Whatever goes wrong, it ends as a message on
    // screen.
    try {
      releaseInFlight = true;
      await _forceReleaseCapture();
    } on Object catch (e) {
      lastError = 'The shutter could not be released: $e. If the camera has stopped '
          'answering, it needs a power cycle.';
      lastErrorCode = AppNoticeCodes.errShutterReleaseFailed;
      lastErrorParams = {'detail': '$e'};
    } finally {
      releaseInFlight = false;
    }
  }

  /// True while a release is being attempted.
  ///
  /// The release does a health probe with the cool-down lifted, and against a camera
  /// that has stopped answering that probe runs to its timeout. Without this the
  /// button looked inert for the whole of it — "clicking it does nothing" — when it was
  /// in fact waiting on the network.
  bool get releaseInFlight => _releaseInFlight;
  bool _releaseInFlight = false;
  set releaseInFlight(bool v) {
    if (_releaseInFlight == v) return;
    _releaseInFlight = v;
    notifyListeners();
  }

  Future<void> _forceReleaseCapture() async {
    final linkWasReady = link.isReady;
    final released = await captureGuard.forceRelease();

    // Re-enter remote mode when the link is up but the preview is not, which is
    // the state a refusal or a timeout leaves behind.
    //
    // Deliberately **not** awaited.  `startPreview` binds a UDP socket before it
    // commands the camera, and a bind is exactly the kind of call that can sit
    // there without ever completing on a phone whose network has just moved out
    // from under the app.  Awaiting it here would make the recovery control
    // itself hang in the very situation it exists for.  Firing it off and reading
    // the resulting state below is the honest version: the command goes out, and
    // whether it worked is reported from `link.previewRunning` a moment later.
    var previewAttempted = false;
    if (linkWasReady && !link.previewRunning) {
      previewAttempted = true;
      unawaited(startPreview());
    }
    if (link.previewRunning) _applyFrameWiring();

    final stillBlocked = shutterBlockedReason;
    if (!released) {
      lastError = 'The camera did not answer the health check, so the shutter '
          'stays locked: ${captureGuard.describe()}. If it was frozen, it needs '
          'a power cycle.';
      lastErrorCode = AppNoticeCodes.errShutterHealthCheckFailed;
      // The same description the sentence above interpolates; `describe()` reads
      // in-memory guard state and writes nothing.
      lastErrorParams = {'detail': captureGuard.describe()};
    } else if (stillBlocked != null) {
      // Deliberately **not** `($stillBlocked)`.
      //
      // `shutterBlockedReason` is a full sentence written for the capture screen,
      // where it sits next to the shutter: "…Start the preview — or press \"Fix the
      // shutter\" below to do it." Interpolating it here produced a run-on that told
      // the reader to press a button that is not on the page they are looking at —
      // visible on the video screen, where this banner appears with no shutter in
      // sight. The capture screen still shows the reason in full, in the one place
      // the instruction is true.
      lastError = previewAttempted
          ? 'The interlock was released, but the camera did not re-enter remote '
              'mode. Power-cycle it if it was frozen.'
          : 'The interlock was released, but the shutter is still blocked.';
      lastErrorCode = previewAttempted
          ? AppNoticeCodes.errInterlockReleasedNoRemote
          : AppNoticeCodes.errInterlockReleasedStillBlocked;
    } else {
      lastError = null;
      lastErrorCode = null;
      lastErrorParams = const {};
      lastNotice = 'Capture interlock released — the shutter is ready again.';
      lastNoticeCode = AppNoticeCodes.noticeInterlockReleased;
    }
    notifyListeners();
  }

  /// Whether press-and-hold is wired up for a bursting drive mode.
  ///
  /// ## This flag is the safety switch, and it is deliberately a constant
  ///
  /// While it is false, a bursting drive mode **disables the shutter entirely**
  /// ([shutterBlockedReason]) — the answer that was correct before the hold existed and is
  /// still the correct answer if the hold is ever unwired. While it is true, the shutter is
  /// live in those modes and safety rests on three things instead, each of which has
  /// hardware evidence behind it:
  ///
  /// 1. the press sends `RCDoShooting` and **nothing else is sent while the burst runs**
  ///    (`CaptureGuard._probeHealthy` refuses during a burst — polling mid-burst is what
  ///    stranded the camera in the first controlled experiment);
  /// 2. the release sends `RCCancelShooting` (an eight-second burst cancelled this way left
  ///    the camera working);
  /// 3. a watchdog sends it anyway if the release never arrives.
  ///
  /// It is a named constant rather than an inline `true` so that flipping it back is one
  /// edit in one place, and so that a reader can see which of the two designs is in force.
  static const bool burstHoldAvailable = true;

  /// Whether a plain tap should shoot — i.e. the camera is in a mode where one request means
  /// one frame.
  ///
  /// The shutter reads this to decide whether `onPressed` does anything. In a bursting mode
  /// the hold path owns the button and a tap is simply a very short hold, so `onPressed` is
  /// null there; a tap that reliably produced a refusal message would be worse than one that
  /// does nothing.
  bool get singleShotOnly => !driveModeBlocksCapture;

  /// True while a held burst is running.
  /// The UI reads this to show the shutter as held — and the rest of this class uses it to
  /// keep **everything else off the wire**, which is the other half of the incident that
  /// produced [CaptureGuard]'s burst interlock. A burst occupies the camera's
  /// single-threaded server, and a request arriving while a capture is in flight answers
  /// `photo fail` and **skips the reset** of the capture-state flags, stranding them until
  /// the battery comes out. The first controlled experiment reproduced that exactly by
  /// polling during a burst; the same delay with no polling left the camera fine.
  bool get burstActive => captureGuard.burstActive;

  /// Begin a held burst. Only does anything in a drive mode that bursts.
  Future<CaptureResult> startBurst() => captureGuard.startBurst();

  /// Let go. **Always sends the stop**, whatever state the guard is in — a burst that
  /// nothing ends is the fault, not a risk of one.
  Future<void> stopBurst() => captureGuard.stopBurst();

  /// Remote shutter, routed through the interlock.
  ///
  /// The camera refuses a capture outright when it is not in remote mode
  /// (`{"code":1000,"data":"photo fail"}`), and remote mode can end without the
  /// app being told.  So a refusal triggers a re-check of the mode and a clear
  /// message, rather than a shutter that silently does nothing.
  ///
  /// Refused outright while a focus command is outstanding: see [focusInFlight]
  /// for why two commands at once is the precondition of the permanent wedge, and
  /// not merely impolite.
  Future<CaptureResult> shoot() async {
    // Every gate says so out loud.
    //
    // A shutter press can be refused by five different conditions, and four of them
    // refuse **before anything reaches the network** — which is indistinguishable, from
    // the outside, from a camera that rejected the shot. Reported from hardware as "the
    // shutter does nothing, and I suspect the app misjudged the state and never sent the
    // command"; there was no way to confirm or refute that from the app.
    //
    // `[capture]` matches the existing `[sync]` / `[ble]` / `[media]` prefixes, so the
    // next report can quote the line that fired.
    if (capturePending) {
      debugPrint('[capture] refused: a capture is already in flight');
      return const CaptureResult(CaptureOutcome.blocked,
          reason: 'a capture is already in flight');
    }
    if (_focusInFlight) {
      debugPrint('[capture] refused: a focus command is still settling');
      return const CaptureResult(CaptureOutcome.blocked,
          reason: 'a focus command is still settling; the shutter waits for it '
              'so the camera never sees two commands at once');
    }
    final gate = shutterBlockedReason;
    if (gate != null) {
      debugPrint('[capture] refused before sending: $gate');
    } else {
      debugPrint('[capture] sending RCDoShooting');
    }
    capturePending = true;
    notifyListeners();

    try {
      final r = await captureGuard.shoot();

      switch (r.outcome) {
        case CaptureOutcome.rejected:
          // Quote the camera's own reply.
          //
          // "photo fail" has two very different causes — remote mode really has
          // exited, or the capture-state flags are stranded — and they need opposite
          // responses: re-enter the mode, or power-cycle. The sentence above cannot
          // tell them apart, and neither could anyone reading a bug report that quotes
          // it. The raw reply can, and it costs one line.
          //
          // `{"code":1000,"data":"photo fail"}` is the stranded case. Anything else is
          // worth seeing before acting on it.
          final raw = r.response?.raw.trim();
          lastError = raw == null || raw.isEmpty
              ? 'The camera refused the shot ("photo fail"). That means it is not '
                  'in remote mode, or the previous shot is still being written to the '
                  'card.'
              : 'The camera refused the shot: $raw';
          if (raw == null || raw.isEmpty) {
            lastErrorCode = AppNoticeCodes.errPhotoFail;
          } else {
            // The camera's own reply, quoted verbatim; no code, because the text is
            // the firmware's and not this app's.
            lastErrorCode = null;
            lastErrorParams = const {};
          }
          // Re-entering remote mode is idempotent and cheap; do it so the next
          // press can work.
          unawaited(_reassertRemoteMode());
        case CaptureOutcome.blocked:
          // The refusal sentence comes from the capture guard, or from this file's own
          // pre-flight gates in [shoot]; neither carries a code, so it is drawn as
          // written — the same rule as `r.reason` below.
          lastNotice = r.reason;
          lastNoticeCode = null;
          lastNoticeParams = const {};
        case CaptureOutcome.transportError:
          lastError = r.reason ?? 'the capture did not reach the camera';
          if (r.reason == null) {
            lastErrorCode = AppNoticeCodes.errCaptureNotReached;
          } else {
            // Again the guard's own sentence, not this file's.
            lastErrorCode = null;
            lastErrorParams = const {};
          }
          unawaited(verifyAlive());
        case CaptureOutcome.ok:
          lastError = null;
          lastErrorCode = null;
          lastErrorParams = const {};
      }
      return r;
    } finally {
      // Always released, otherwise the shutter sticks in its pressed state -
      // which is exactly the symptom of a button that never returns.
      capturePending = false;
      notifyListeners();
    }
  }

  /// Make sure the camera is in remote mode.
  ///
  /// `RCStartRemoteCtl` is safe to repeat; the preview keeps running.
  Future<void> _reassertRemoteMode() async {
    if (!connection.isReady) return;
    try {
      await connection.http.startRemoteControl();
    } on Object {
      // verified separately by verifyAlive()
    }
  }

  /// The pending tap.  Only the coordinates now: the reply is no longer used to
  /// place anything, so there is no geometry to carry with the request.
  ({int x, int y})? _pendingFocus;
  bool _focusInFlight = false;

  /// Tap-to-focus.
  ///
  /// [x] and [y] are in the camera's own focus-plane coordinates, **not** the
  /// preview's 800x600 pixel space — [FocusMapper] converts a tap into them.
  /// Verified on hardware that `Mode` accepts exactly `Manual` and `Auto`;
  /// anything else (including `Mode=1`) is rejected with a 404, so a wrong value
  /// fails loudly rather than silently.
  ///
  /// ## `Mode` is `Manual`, which is what the official app sends
  ///
  /// `LiveViewFragment.java:697-717` is the `FocusView` touch callback, and it
  /// reads:
  ///
  /// ```java
  /// CameraSettingParams.f13979r = CameraSettingParams.DoFocusValue.Manual;
  /// C3570t.m16421a().m16427a(CameraSettingParams.f13979r, i, i2);
  /// ```
  ///
  /// `Auto` belongs to a **different entry point** (`LiveViewFragment:639/641`),
  /// not to a tap on the preview.
  ///
  /// This is not a cosmetic difference on this firmware.  Measured from a PC
  /// against the real camera:
  ///
  /// | `Mode`   | requested      | camera replied |
  /// |----------|----------------|----------------|
  /// | `Manual` | (642, 91)      | (642, 91)      |
  /// | `Manual` | (100, 500)     | (100, 500)     |
  /// | `Auto`   | (642, 91)      | (360, 240)     |
  /// | `Auto`   | (100, 500)     | (360, 240)     |
  /// | `Auto`   | (800, 600)     | (360, 240)     |
  /// | `Auto`   | (0, 0)         | (360, 240)     |
  ///
  /// `Manual` echoes the request — the point is honoured end to end.  `Auto` is
  /// a hard-coded constant, and its value is not arbitrary: `360 = 640/2 + 40`
  /// and `240 = 480/2` is the **centre of the 4:3 focus plane**, which is also
  /// the official app's own out-of-bounds fallback (`FocusView.java:241-244`).
  /// Moving the AF point elsewhere with `Manual` first does not change it.
  ///
  /// ## The reply is not treated as a focus position
  ///
  /// This used to answer with a `FocusConfirmation` built from `Posx`/`Posy`,
  /// on the assumption that the reply named where the AF system settled.  The
  /// table above falsifies that: `Manual` only echoes and `Auto` only ever names
  /// the plane centre, so there is nothing in the reply that is not already
  /// known.  The official app consults it in the `Auto` path only
  /// (`C3570t.java:539-561`) — the touch path takes the tapped point:
  ///
  /// ```java
  /// if (doFocusValue == DoFocusValue.Auto) { b = Posx; c = Posy; }
  /// else                                   { b = i;    c = i2;   }
  /// ```
  ///
  /// Hence the whole `confirm`/`parseEcho`/`FocusConfirmation` surface is gone
  /// rather than kept with a special case, `Posx`/`Posy` are not parsed here at
  /// all, and the marker belongs where the tap was — see
  /// `LiveViewPage._handleTap`.
  ///
  /// Returns whether the camera accepted the command, which is the only claim
  /// the reply supports.
  ///
  /// Focus requests are **serialised**: the camera takes a moment to settle, and
  /// a second request arriving mid-adjustment is answered inconsistently — which
  /// is why a burst of taps appears to "sometimes not focus". Only the latest
  /// pending point is kept, so dragging does not queue work.
  ///
  /// ## Deferring to a capture that is already running
  ///
  /// Focus and capture are the two commands that can wedge this camera, and they
  /// now share one gate.  A tap that arrives while a capture is in flight is
  /// **dropped and reported**, not queued: the capture it would race is already
  /// writing to the card, and stacking a focus request behind it buys nothing
  /// except a second command in the camera's queue.  The shutter does the mirror
  /// image of this via [focusInFlight].
  Future<bool> focusAt(int x, int y, {String mode = 'Manual'}) async {
    if (capturePending) {
      lastNotice = 'A shot is being taken, so the focus point was not sent.';
      lastNoticeCode = AppNoticeCodes.noticeFocusSkippedForShot;
      notifyListeners();
      return false;
    }
    _pendingFocus = (x: x, y: y);
    // A tap that lands while a request is settling is not lost: it replaces the
    // pending point, and the loop below picks the newest one up.  The return
    // value is the *previous* request's, so a caller must not read it as this
    // tap's verdict — the page draws the marker from the tap itself and does not
    // ask.
    if (_focusInFlight) return true;
    _focusInFlight = true;
    // Per-request, not read off `lastError` at the end: an unrelated failure
    // from earlier in the session is still sitting in `lastError`, and reporting
    // it as this command's verdict would be a claim about a call that answered
    // 200.
    var accepted = true;
    notifyListeners();
    try {
      while (_pendingFocus != null) {
        final p = _pendingFocus!;
        _pendingFocus = null;
        if (!connection.isReady) {
          lastError = 'not connected';
          lastErrorCode = AppNoticeCodes.errNotConnectedShort;
          accepted = false;
          notifyListeners();
          // Nothing to settle: there is no command on the wire.
          break;
        }
        try {
          final r = await connection.http
              .send('RCDoFocus', {'Mode': mode, 'Posx': '${p.x}', 'Posy': '${p.y}'});
          if (!r.ok) {
            lastError = 'RCDoFocus failed: ${r.data ?? r.raw}';
            lastErrorCode = AppNoticeCodes.errFocusFailed;
            lastErrorParams = {'detail': '${r.data ?? r.raw}'};
            accepted = false;
          } else {
            lastError = null;
            lastErrorCode = null;
            lastErrorParams = const {};
          }
        } on CameraHttpException catch (e) {
          lastError = e.isBadParameters
              ? 'RCDoFocus was rejected — the camera answered 404, which on '
                  'this firmware means the parameters were wrong'
              : 'RCDoFocus failed: ${e.message}';
          lastErrorCode = e.isBadParameters
              ? AppNoticeCodes.errFocusRejected404
              : AppNoticeCodes.errFocusFailed;
          lastErrorParams = e.isBadParameters ? const {} : {'detail': e.message};
          accepted = false;
        }
        notifyListeners();
        // Give the AF system time to finish before accepting the next point.
        // The gate stays shut across this window on purpose: the reply arrives
        // before the lens has settled, so clearing `_focusInFlight` here would
        // reopen the door to exactly the overlap it exists to prevent.
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    } finally {
      _focusInFlight = false;
      notifyListeners();
    }
    return accepted;
  }

  /// Every settable parameter, as `command -> parameter key`, so the UI can
  /// build controls without hard-coding them in each widget.
  static const Map<String, String> paramCommands = {
    'RCSwitchDialMode': 'DialMode',
    'RCMeteringModeSet': 'MeteringMode',
    'RCFocusModeSet': 'FocusMode',
    'RCImageQualitySet': 'ImageQuality',
    'RCImageAspect': 'ImageAspect',
    'RCFileFormatSet': 'FileFormat',
    'RCDriveModeSet': 'DriveMode',
    'RCFNSet': 'Fnumber',
    'RCShutterSpeedSet': 'ShutterSpeed',
    'RCEVSet': 'EV',
    'RCISOSet': 'ISO',
    'RCWBSet': 'WB',
    'RCChooseColorMode': 'ColorMode',
  };

  /// Which parameters actually take effect in each exposure mode.
  ///
  /// In `A` the camera owns the shutter, in `S` it owns the aperture, and in `P`
  /// it owns both — so offering those controls there produces a slider that
  /// appears to work and changes nothing.  Verified behaviour: the camera
  /// answers `200` to a `RCShutterSpeedSet` in `A` mode and then ignores it,
  /// which is exactly the "UI is adjustable but has no effect" complaint.
  static bool isParamEffective(String exposureMode, String command) {
    switch (exposureMode) {
      case 'A':
        return command != 'RCShutterSpeedSet';
      case 'S':
        return command != 'RCFNSet';
      case 'P':
      case 'Auto':
      case 'C':
        return command != 'RCShutterSpeedSet' && command != 'RCFNSet';
      default: // M and anything unknown: everything is the user's
        return true;
    }
  }

  /// Set one parameter by its command.
  Future<bool> setParam(String command, String value) {
    final key = paramCommands[command];
    if (key == null) {
      lastError = 'unknown parameter command $command';
      lastErrorCode = AppNoticeCodes.errUnknownParamCommand;
      lastErrorParams = {'command': command};
      notifyListeners();
      return Future.value(false);
    }
    if (!isKnownCommand(command)) {
      lastError = '$command is not in the firmware command table';
      lastErrorCode = AppNoticeCodes.errCommandNotInTable;
      lastErrorParams = {'command': command};
      notifyListeners();
      return Future.value(false);
    }
    final mode = _cameraState?.exposureMode ?? '';
    if (!isParamEffective(mode, command)) {
      lastNotice = 'In $mode mode the camera sets this itself, so the change was '
          'not applied. Switch to M to control it directly.';
      lastNoticeCode = AppNoticeCodes.noticeParamSetByCamera;
      lastNoticeParams = {'mode': mode};
    }
    return send(command, {key: value});
  }

  /// Commands the official app never used — the CE app's differentiators.
  ///
  /// Held behind a dev flag in the UI because they are structurally verified but
  /// not all hardware-tested, and this camera hangs rather than erroring when a
  /// command surprises it.
  static const List<String> experimentalCommands = [
    'VideoRecordingStart',
    'VideoRecordingStop',
    'RCVideoFormatSet',
    'RCEisSwitchSet',
    'RCVANoiseReduceSet',
    'RCVASwitchSet',
    'RCVAVolSet',
    'StartMovieStream',
    'StopMovieStream',
    'PauseMovieStream',
    'ResumeMovieStream',
  ];

  /// BLE diagnostics from the transport.
  ///
  /// Surfaced in the UI because a BLE failure here is nearly always
  /// environmental — a property mismatch, a missing runtime permission, a link
  /// that reported success and dropped — and this log is the only place the
  /// camera's *actual* characteristic properties appear.
  List<String> get bleLog => connection.ble.log;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        // The native side released the process-wide network pin on pause, so
        // restore it — otherwise the app is back in front but cannot reach a
        // camera it never disconnected from.
        if (connection.isReady) unawaited(connection.rebindCameraNetwork());
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        // Release the pin so the rest of the phone (and the rest of this app)
        // has internet while the user is elsewhere.
        unawaited(connection.releaseCameraNetwork());
      case AppLifecycleState.inactive:
        break;
    }
  }

  // ------------------------------------------------------------- messaging

  /// Clear the two one-shot messages after the UI has shown them.
  ///
  /// Needed because they are plain fields read during a rebuild: without an
  /// explicit clear, an unrelated `setState` re-displays a stale "could not share"
  /// next to a later, successful action. Notifies so the rebuild actually happens
  /// while the snackbar is still on screen.
  void clearMessages() {
    lastError = null;
    lastErrorCode = null;
    lastErrorParams = const {};
    lastNotice = null;
    lastNoticeCode = null;
    lastNoticeParams = const {};
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _stopFrameSubscription();
    _links?.cancel();
    frameNotifier.dispose();
    connection.dispose();
    super.dispose();
  }
}

/// Every ARB key [AppState.lastErrorCode] / [AppState.lastNoticeCode] can carry,
/// plus the ones [AppState.shutterBlockedReasonCode] names.
///
/// The shutter's block reasons are in here rather than in a second class because they
/// are the same decision, raised by the same class and resolved by the same file: the
/// English stays in the branch that decides it and a code travels beside it. They are
/// kept as one set so the pairing check has one list to compare, and because a second
/// set with four members would only add a place for the pairing to drift.
///
/// ## Why the codes live here
///
/// The same reason `LinkCodes` lives in `lib/transport/camera_connection.dart` and
/// `SyncStageCodes` in `lib/sync/sync_engine.dart`: the code is declared next to the
/// sentence it stands for, so the two cannot drift. Each member is named for its ARB
/// key — unlike [LinkCodes], which strips the `link` prefix — because these keys are
/// already the shortest true names for the branch that raises them, and the resolver
/// in `lib/l10n/message_text.dart` reads as one line per member either way.
///
/// [all] is what makes the pairing checkable rather than merely intended:
/// `test/l10n_message_codes_test.dart` compares it, in both directions, against the
/// codes [appErrorText] and [appNoticeText] handle. A code with no case there renders
/// the English fallback — correct, and invisible — which is exactly the failure the
/// check exists to catch.
///
/// Codes whose sentence interpolates nothing carry no parameters; [AppState] writes
/// `lastErrorParams` / `lastNoticeParams` only where the sentence has a placeholder,
/// and the resolver reads only the keys its own case names.
abstract final class AppNoticeCodes {
  static const noticeUnwiredRow = 'noticeUnwiredRow';
  static const errStorageDenied = 'errStorageDenied';
  static const errPreviewRefused = 'errPreviewRefused';
  static const noticeShotsNotOnPhone = 'noticeShotsNotOnPhone';
  static const errShareAndroidOnly = 'errShareAndroidOnly';
  static const errShareSheetRefused = 'errShareSheetRefused';
  static const noticeSharedPartially = 'noticeSharedPartially';
  static const noticeShotNotOnPhone = 'noticeShotNotOnPhone';
  static const errNoViewerApp = 'errNoViewerApp';
  static const errRemoveCopyFailed = 'errRemoveCopyFailed';
  static const errDeleteNotConnected = 'errDeleteNotConnected';
  static const noticeNothingSentAllRefused = 'noticeNothingSentAllRefused';
  static const noticeNothingToDelete = 'noticeNothingToDelete';
  static const errDeleteFailed = 'errDeleteFailed';
  static const errNotConnectedShort = 'errNotConnectedShort';
  static const errCommandFailed = 'errCommandFailed';
  static const errCommandRejected404 = 'errCommandRejected404';
  static const errShutterReleaseFailed = 'errShutterReleaseFailed';
  static const errShutterHealthCheckFailed = 'errShutterHealthCheckFailed';
  static const errInterlockReleasedNoRemote = 'errInterlockReleasedNoRemote';
  static const errInterlockReleasedStillBlocked =
      'errInterlockReleasedStillBlocked';
  static const noticeInterlockReleased = 'noticeInterlockReleased';
  static const errPhotoFail = 'errPhotoFail';
  static const errCaptureNotReached = 'errCaptureNotReached';
  static const noticeFocusSkippedForShot = 'noticeFocusSkippedForShot';
  static const errFocusFailed = 'errFocusFailed';
  static const errFocusRejected404 = 'errFocusRejected404';
  static const errUnknownParamCommand = 'errUnknownParamCommand';
  static const errCommandNotInTable = 'errCommandNotInTable';
  static const noticeParamSetByCamera = 'noticeParamSetByCamera';
  static const shutterBlockedNotConnected = 'shutterBlockedNotConnected';
  static const shutterBlockedNotRemote = 'shutterBlockedNotRemote';
  static const shutterBlockedBurst = 'shutterBlockedBurst';
  static const shutterBlockedQuarantined = 'shutterBlockedQuarantined';

  /// Every code above, for the check that compares this class against the resolvers
  /// in `lib/l10n/message_text.dart`.
  static const Set<String> all = {
    noticeUnwiredRow,
    errStorageDenied,
    errPreviewRefused,
    noticeShotsNotOnPhone,
    errShareAndroidOnly,
    errShareSheetRefused,
    noticeSharedPartially,
    noticeShotNotOnPhone,
    errNoViewerApp,
    errRemoveCopyFailed,
    errDeleteNotConnected,
    noticeNothingSentAllRefused,
    noticeNothingToDelete,
    errDeleteFailed,
    errNotConnectedShort,
    errCommandFailed,
    errCommandRejected404,
    errShutterReleaseFailed,
    errShutterHealthCheckFailed,
    errInterlockReleasedNoRemote,
    errInterlockReleasedStillBlocked,
    noticeInterlockReleased,
    errPhotoFail,
    errCaptureNotReached,
    noticeFocusSkippedForShot,
    errFocusFailed,
    errFocusRejected404,
    errUnknownParamCommand,
    errCommandNotInTable,
    noticeParamSetByCamera,
    shutterBlockedNotConnected,
    shutterBlockedNotRemote,
    shutterBlockedBurst,
    shutterBlockedQuarantined,
  };
}
