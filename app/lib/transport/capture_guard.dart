/// Client-side interlock for remote capture.
///
/// ## Why this exists
///
/// The camera's capture state machine has a firmware defect that hangs the whole
/// device until the battery is pulled.  The root cause is now understood (see
/// `analysis/09-firmware-mod-tiers.md` §0 and
/// `analysis/re-imaging-and-hang-rootcause.md`):
///
/// A two-phase rendezvous uses two flag bytes in the capture-state block.  They
/// are cleared only on the "ready" branch of the capture callback.  When a
/// second capture request arrives while the first is still in flight, readiness
/// is already clear, so the handler takes the **not-ready** branch, replies
/// `{"code":1000,"data":"photo fail"}`, and returns **without clearing the
/// flags**.  The stranded flags then make the next asynchronous state-machine
/// pass zero the status word mid-capture, so the preview/EVF resume never runs
/// (grey overlay + garbled pixels), the encoder starves (~30 fps -> ~3 fps), and
/// the HTTP task blocks forever.
///
/// That is why a **single** shot is safe but several rapid shots are not: you
/// need one rejected request to strand the flags.
///
/// The user's own hypothesis was right — this correlates with **SD card speed**.
/// A slow card blocks the write longer, widening the window in which the next
/// request arrives mid-capture.
///
/// ## What this class does about it
///
/// It cannot repair the firmware, but it can avoid *provoking* the bug:
///
/// 1. never issue two captures at once;
/// 2. enforce a minimum interval between them;
/// 3. treat `photo fail` as a **danger signal**, not merely a failure — after it,
///    refuse further captures until a health probe passes;
/// 4. the health probe requires **both** HTTP to answer **and** the preview
///    stream to be back at a sane rate, because HTTP can survive while the
///    preview pipeline is still broken.
///
/// With the firmware patch from §1.4 applied this guard is belt-and-braces;
/// without it, this is the only protection available.
library;

import 'dart:async';

import 'http_transport.dart';
import 'liveview.dart';

/// How a capture attempt ended.
enum CaptureOutcome {
  /// The camera accepted it and the shot was taken.
  ok,

  /// The camera answered `{"code":1000,"data":"photo fail"}`.
  ///
  /// On its own this is survivable, but it is the **precursor** of the hang: it
  /// means the flags may now be stranded.  The guard treats it as a quarantine
  /// trigger.
  rejected,

  /// The guard refused to send anything (cool-down, quarantine, or a capture
  /// already in flight).
  blocked,

  /// The request failed at the transport level.
  transportError,
}

/// Result of a guarded capture.
class CaptureResult {
  final CaptureOutcome outcome;
  final CameraResponse? response;
  final String? reason;

  const CaptureResult(this.outcome, {this.response, this.reason});

  bool get tookPhoto => outcome == CaptureOutcome.ok;

  @override
  String toString() => 'CaptureResult($outcome${reason == null ? '' : ': $reason'})';
}

/// Serialises and rate-limits remote captures, and quarantines the camera after
/// a rejection until it proves healthy again.
class CaptureGuard {
  /// The firmware's "photo fail" code.
  static const int codePhotoFail = 1000;

  /// Minimum spacing between captures.
  ///
  /// The defect needs a request to land *while another is in flight*, so the gap
  /// only has to exceed a full capture cycle.  A single capture takes ~3.3 s end
  /// to end on the tested hardware, so 2 s is deliberately conservative rather
  /// than tight — an occasional extra second of latency is a much better trade
  /// than a camera that needs its battery pulled.
  final Duration minInterval;

  /// How long to refuse captures after a rejection.
  final Duration quarantine;

  /// The preview rate the health probe requires before releasing quarantine.
  final double healthyFps;

  /// Resolves the HTTP client **at the moment of use**, not at construction.
  ///
  /// ## The bug this signature exists to prevent
  ///
  /// This was `final CameraHttpClient http`, and `AppState` passed `_liveHttp` — a
  /// getter that answers `connection.http` when the link is ready and a detached stub
  /// that throws `"not connected to the camera"` when it is not. Passing a getter to a
  /// value parameter evaluates it **once**, and `AppState` is constructed at startup,
  /// before any link exists. So the guard held the stub for the life of the process:
  /// every capture threw before touching the network, the shutter never worked, and the
  /// camera was blamed for refusing a command it never received.
  ///
  /// Reported from hardware exactly that way — the shutter did nothing while parameter
  /// changes and the preview worked, because those go to `connection.http` directly and
  /// only the capture interlock went through the frozen reference. The line next to it,
  /// `HttpStreamPauseController(http: () => _liveHttp)`, had been written correctly;
  /// this one had not.
  final CameraHttpClient Function() http;
  final CameraLiveView? liveView;

  /// Measures current preview frames per second.
  ///
  /// Injectable so the interlock can be tested without sleeping through a real
  /// sampling window.  The default samples [CameraLiveView.stats] over
  /// [probeWindow].
  final Future<double> Function()? measureFps;
  final Duration probeWindow;

  DateTime? _lastAttempt;
  DateTime? _quarantinedAt;
  bool _inFlight = false;

  /// When the current capture attempt started, or null when none is running.
  ///
  /// Needed because "a capture is in flight" and "a capture has been in flight
  /// since before this app could still be talking to the camera" are different
  /// claims, and only the first one justifies refusing to send anything.  Without
  /// the timestamp there is no way to tell them apart, and a reservation that is
  /// never released reads to the user as a shutter button that stopped working.
  DateTime? _inFlightSince;

  /// Injectable clock, so a stale reservation can be tested without sleeping.
  final DateTime Function() now;

  /// How long an attempt must have been in flight before [forceRelease] will
  /// treat it as lost rather than live.
  ///
  /// Set generously on purpose.  [CameraHttpClient.send] gives up after
  /// `timeout` per attempt, so a request cannot really still be on the wire
  /// after that; the extra margin covers a slow DNS-less connect, a retry, and
  /// the difference between "the socket errored" and "the future completed".
  /// Dropping the reservation too early would let a second `RCDoShooting` out
  /// alongside one that is genuinely in flight — the exact overlap that strands
  /// the firmware's capture flags and needs a battery pull.
  final Duration staleAfter;

  /// Drive modes this app must not shoot in, because it cannot stop the burst.
  ///
  /// `Continuous` is the reported one; `2SDelay`/`10SDelay` are refused for the same
  /// structural reason — they hand the timing to the camera, so a second command would
  /// arrive while the first is still being carried out, which is the overlap the guard
  /// exists to prevent. `Single` is the only mode where one request means one frame.
  static const Set<String> _burstDriveModes = {
    'Continuous',
    '2SDelay',
    '10SDelay',
  };

  /// Reads the camera's current drive mode, or null when it is not known.
  final String Function()? driveMode;

  /// Where to report what the shutter actually does, or null to say nothing.
  ///
  /// A sink rather than `debugPrint` so this file keeps its freedom from
  /// `package:flutter`; the app passes one that prints, tests pass one that records.
  final void Function(String)? log;
  void Function(String)? _log;

  CaptureGuard({
    required this.http,
    this.liveView,
    this.driveMode,
    this.minInterval = const Duration(seconds: 2),
    this.quarantine = const Duration(seconds: 8),
    this.healthyFps = 10.0,
    this.measureFps,
    this.probeWindow = const Duration(seconds: 2),
    this.staleAfter = const Duration(seconds: 30),
    this.log,
    this.burstStartCommand,
    this.maxBurst = const Duration(seconds: 4),
    DateTime Function()? clock,
  }) : now = clock ?? DateTime.now {
    _log = log;
  }

  bool get isQuarantined => _quarantinedAt != null;
  bool get isBusy => _inFlight;

  /// How long the current attempt has been running, or null when none is.
  Duration? get inFlightFor =>
      _inFlightSince == null ? null : now().difference(_inFlightSince!);

  /// True when a reservation has outlived [staleAfter] and is therefore assumed
  /// lost rather than on the wire.
  ///
  /// A stuck reservation is the one interlock state the user cannot escape by
  /// waiting: [shoot] answers `blocked` before it touches the network, so no
  /// amount of patience makes the shutter work again.  It is also reachable from
  /// a single unexpected throw out of [http], which is why the check exists at
  /// all rather than being dismissed as impossible.
  bool get isStale => isBusy && inFlightFor! >= staleAfter;


  /// Try to take a photo.
  ///
  /// Returns [CaptureOutcome.blocked] with a [CaptureResult.reason] when the
  /// guard declines, so the UI can explain itself rather than appearing broken.
  Future<CaptureResult> shoot() async {
    // ## Continuous drive is refused outright, and this is a safety interlock
    //
    // Reported from hardware, 2026-09-15: with the drive mode set to **Continuous**, a
    // **brief tap** of the shutter — not even a long press — made the camera burst
    // immediately and keep bursting until it locked up and had to be recovered by
    // pulling the battery.
    //
    // The mechanism is now understood from the official app's own sources, and it is
    // ours, not the camera's:
    //
    //   * `LiveViewFragment.onTouch` (line 1387) treats the shutter as a **hold**, not a
    //     tap. `ACTION_DOWN` only focuses (`m16752f`), and for Continuous/Bulb/Time it
    //     returns without shooting at all; `ACTION_UP` (`m16767s`) is what fires.
    //   * A burst is ended with a **separate command**. `m16767s` sends
    //     `RCCancelShooting` (`C3701b.m17028g`, 10 s timeout) or, for long exposures,
    //     `RCCancelShooting1` (`m17031h`, 60 s).
    //
    // This app sends `RCDoShooting` and **has never sent either cancel command**. So in
    // Continuous it starts something it has no way to stop, and the camera keeps going
    // until it strands. `RCCancelShooting` and `RCCancelShooting1` are already in the
    // command table (`http_commands.dart`) — nothing was missing but the use of them.
    //
    // Until the hold-to-burst model is implemented **and verified on hardware**, the
    // honest thing is to decline with a reason rather than start a burst that can only
    // be stopped by removing the battery from the user's camera.
    final drive = driveMode?.call() ?? '';
    if (_burstDriveModes.contains(drive)) {
      _log?.call('refused: drive mode is $drive and this app cannot stop a burst');
      return CaptureResult(CaptureOutcome.blocked,
          reason: 'The camera is in $drive drive. A single command starts a burst that '
              'this app has no way to stop — the camera keeps shooting until it locks '
              'up and needs its battery removed. Set the drive mode to Single, or use '
              'the camera itself.');
    }

    if (_inFlight) {
      return const CaptureResult(CaptureOutcome.blocked,
          reason: 'a capture is already in progress');
    }

    // Taken **before the first `await` below**, and that placement is the whole
    // point of the flag.  An earlier revision set it after the cool-down wait, so
    // two presses inside that window both passed the check above, both woke up,
    // and both sent `RCDoShooting` — the exact overlapping pair of requests that
    // strands the capture-state flags and needs a battery pull.  A guard that
    // reserves the slot asynchronously guards nothing.
    _inFlight = true;
    _inFlightSince = now();
    try {
      if (_quarantinedAt != null) {
        final healthy = await _probeHealthy();
        if (!healthy) {
          final waited = now().difference(_quarantinedAt!);
          return CaptureResult(CaptureOutcome.blocked,
              reason: 'camera is recovering from a rejected capture '
                  '(${waited.inSeconds}s ago) and the preview has not returned '
                  'to a healthy rate yet');
        }
        _quarantinedAt = null;
      }

      final last = _lastAttempt;
      if (last != null) {
        final elapsed = now().difference(last);
        if (elapsed < minInterval) {
          final wait = minInterval - elapsed;
          await Future<void>.delayed(wait);
        }
      }

      _lastAttempt = now();
      // Report the moment the command leaves and the reply that comes back.
      //
      // Whether the shutter reaches the camera at all was the open question in a bug
      // report — "the app misjudged the state and never sent the command" — and it
      // cannot be settled from the UI, where a gate that declines and a camera that
      // refuses look identical. These two lines settle it.
      //
      // Through an injected sink rather than `debugPrint`, because this file must stay
      // free of `package:flutter`: that is what lets the transport layer be driven in a
      // pure Dart VM, which is what makes the 328 assertions here run in seconds.
      _log?.call('-> RCDoShooting');
      final r = await http().send('RCDoShooting');
      _log?.call('<- code=${r.code} raw=${r.raw.trim()}');
      if (r.code == codePhotoFail) {
        // Not just a failure: the observed precursor of the hang.
        _quarantinedAt = now();
        return CaptureResult(CaptureOutcome.rejected,
            response: r,
            reason: '"photo fail" means the capture-state flags may be stranded; '
                'captures are paused until the camera proves healthy');
      }
      if (!r.ok) {
        return CaptureResult(CaptureOutcome.transportError, response: r);
      }
      return CaptureResult(CaptureOutcome.ok, response: r);
    } on CameraHttpException catch (e) {
      // A dead transport is the hang itself, not a preview of it.
      _quarantinedAt = now();
      _log?.call('x transport failed: ${e.message}');
      return CaptureResult(CaptureOutcome.transportError, reason: e.message);
    } on Object catch (e) {
      // Anything that is not a `CameraHttpException`: the HTTP client wraps its
      // own failures, so this is an injected seam, a test double, or a future
      // defect — and the one thing it must never do is leave `_inFlight` set.
      // That reservation is what makes the shutter permanently unusable, and it
      // outlives the page, the link and the camera, so the cost of catching
      // broadly here is zero and the cost of not catching is a dead button.
      return CaptureResult(CaptureOutcome.transportError,
          reason: 'the capture attempt failed unexpectedly: $e');
    } finally {
      _inFlight = false;
      _inFlightSince = null;
    }
  }

  /// Health probe.
  ///
  /// The camera must have served its cool-down **and** must be demonstrably
  /// talking to us again.
  ///
  /// ## Why this does not use an absolute frame rate
  ///
  /// An earlier revision required the preview to reach a fixed fps, and that was
  /// a trap: if the link is merely *slow* — which is the normal state on this
  /// camera, and the very condition that produces the "photo fail" in the first
  /// place — the threshold is never reached, so quarantine never lifts and the
  /// shutter is disabled permanently.  A recovery check that can never pass is
  /// worse than no check at all.
  ///
  /// So the test is **progress**, not speed: HTTP must answer, and either the
  /// preview is not running (nothing to judge, and the shutter is separately
  /// gated on it) or the camera's own frame counter must have advanced.  A
  /// genuinely wedged pipeline stops producing frames entirely, which this
  /// catches; a healthy-but-slow link keeps producing them, which this allows.
  ///
  /// The cool-down floor is what makes this safe to bypass with [force].
  ///
  /// [requireCooldown] is the only difference between the automatic probe and the
  /// one [forceRelease] runs: the user overriding the interlock skips the timer
  /// (that is what "release" means, and they may be looking at a camera they just
  /// power-cycled) but still gets the truthful HTTP-plus-progress answer.  It must
  /// **not** skip the probe, or the button would re-arm a shutter pointed at a
  /// camera that is still wedged.
  Future<bool> _probeHealthy({bool requireCooldown = true}) async {
    // ## A probe must not run while a burst is running
    //
    // Measured, and it is the second half of the incident this class exists for. A burst
    // occupies the camera's single-threaded HTTP server, and **a request arriving while a
    // capture is in flight answers `{"code":1000,"data":"photo fail"}` and skips the reset
    // of the capture-state flags** (`analysis/04`, `analysis/43`). The flags then stay set
    // until the battery comes out.
    //
    // The first controlled experiment stranded the user's camera exactly this way: it
    // started a burst and polled `GetCameraStatus` every 0.7 s "to watch it". The same
    // delay with **no** polling left the camera working. So this is not a precaution
    // against a hypothetical — it is the reproduction that produced the fault.
    if (_burstActive) {
      _log?.call('probe skipped: a burst is running and talking to it strands the camera');
      return false;
    }

    final q = _quarantinedAt;
    if (requireCooldown && q != null && now().difference(q) < quarantine) {
      return false;
    }

    try {
      final s = await http().status();
      if (!s.ok) return false;
    } on CameraHttpException {
      return false;
    }

    // Injected probe wins (used by tests and by callers with a better signal).
    final reader = measureFps;
    if (reader != null) {
      try {
        return await reader() >= healthyFps;
      } on Object {
        return false;
      }
    }

    final lv = liveView;
    if (lv == null || !lv.isRunning) {
      // No stream to judge.  The shutter is independently gated on the preview
      // running, so this is not a hole.
      return true;
    }

    return lv.isAdvancing(within: probeWindow);
  }

  /// Forget everything, because the camera this guard was judging is gone.
  ///
  /// ## Why this is needed
  ///
  /// The quarantine means "**this camera session's** capture state is suspect". The
  /// guard never heard about link changes, so it had no idea a session had ended — and
  /// a quarantine therefore outlived the camera it was about.
  ///
  /// That is exactly backwards for the one recovery that works. The stranding is cleared
  /// by a power cycle, and a power cycle drops the camera's access point, so the app
  /// reconnects to a **fresh** camera while still holding a verdict about the old one.
  /// Reported from hardware as: the shutter is stuck, "Release anyway" changes nothing,
  /// and the interface says the state is stuck — on a camera that had just been
  /// restarted.
  ///
  /// This is the one place the guard is allowed to forget without a health probe, and it
  /// is safe because the link genuinely went away: there is no capture in flight over a
  /// link that no longer exists, so the reservation goes too.
  ///
  /// A burst, however, must be **stopped** before it is forgotten — see [stopBurst]: a
  /// camera left bursting is the fault this whole class exists to avoid, and losing the
  /// link is not a reason to stop trying to end it. That send is attempted, and its
  /// failure is reported rather than hidden, because after a link loss it will usually
  /// fail — but the alternative is to not try at all.
  /// The name the camera uses to end a capture in progress.
  ///
  /// From the official app's own sources: its shutter is a **hold**, not a tap
  /// (`LiveViewFragment.onTouch`, line 1387 — `ACTION_DOWN` focuses and, for
  /// Continuous/Bulb/Time, returns without shooting; `ACTION_UP` is what fires). A capture
  /// is then ended with `RCCancelShooting` (`C3701b.m17028g`, 10 s timeout) or, for long
  /// exposures, `RCCancelShooting1` (`m17031h`, 60 s). Both names are already in
  /// `http_commands.dart`.
  ///
  /// ## One thing about this that is NOT established — read before relying on it
  ///
  /// `RCCancelShooting` is sent from `m16767s`, which sits on the **fire** path, while its
  /// name reads like "stop". So it is **not known** whether it starts a capture, ends one,
  /// or cancels a self-timer countdown so that the shot happens at once. [H] — the
  /// official app is the only source and it does not disambiguate.
  ///
  /// That uncertainty is why [stopBurst] sends it **unconditionally and repeatedly is
  /// avoided** rather than being folded into [shoot]: whatever else it does, "end the
  /// capture now" is the only reading under which a burst can be made safe, and a command
  /// that is idempotent when nothing is running costs one request.
  static const String cancelShootingCommand = 'RCCancelShooting';

  /// How long a burst may run before the guard ends it on its own.
  ///
  /// ## Why a watchdog is not optional here
  ///
  /// With the drive mode in Continuous, one `RCDoShooting` starts a burst and **nothing the
  /// camera does will end it** — measured: eight seconds of silence and the frames kept
  /// coming, seven arriving at once when the cancel finally went out. The only stop is the
  /// `RCCancelShooting` this app sends when the user lets go.
  ///
  /// So the release is load-bearing. If it never arrives — the app is killed mid-press, the
  /// gesture is cancelled, the link drops between press and release — the camera keeps
  /// shooting on its own until it strands, which is the incident that started this: the
  /// user's camera ran to 26 frames and had to have its battery pulled.
  ///
  /// Four seconds is longer than any deliberate hold and far shorter than the run that
  /// stranded a camera. A slower card makes the stranding **more likely rather than
  /// quicker** — the state machine is the constraint, not the clock — so the limit is
  /// about not leaving the thing running, not about beating a deadline.
  final Duration maxBurst;

  Timer? _burstWatchdog;

  /// True while a burst started by [startBurst] is believed to be running.
  bool get burstActive => _burstActive;
  bool _burstActive = false;

  /// Begin a continuous burst. **Only** valid in a drive mode that bursts.
  ///
  /// Refused in `Single`: there is nothing to hold, and a stray second request is the
  /// overlap this guard exists to prevent.
  Future<CaptureResult> startBurst() async {
    if (_burstActive) {
      return const CaptureResult(CaptureOutcome.blocked,
          reason: 'a burst is already running');
    }
    if (_inFlight) {
      return const CaptureResult(CaptureOutcome.blocked,
          reason: 'a capture is already in progress');
    }
    final drive = driveMode?.call() ?? '';
    if (!_burstDriveModes.contains(drive)) {
      return CaptureResult(CaptureOutcome.blocked,
          reason: 'the camera is in $drive drive, which takes one frame per request — '
              'hold-to-burst only applies to Continuous');
    }

    _inFlight = true;
    _inFlightSince = now();
    try {
      _log?.call('-> ${burstStartCommand ?? 'RCDoShooting'} (burst start)');
      final r = await http().send(burstStartCommand ?? 'RCDoShooting');
      _log?.call('<- code=${r.code} raw=${r.raw.trim()}');
      if (!r.ok) {
        return CaptureResult(CaptureOutcome.transportError, response: r);
      }
      // Marked running **only after the camera acknowledged**, so a refused start does
      // not leave the UI claiming a burst that never began and a release sending a
      // cancel for it.
      _burstActive = true;
      // Armed here, not at the press: a watchdog for a burst that never started would
      // fire a cancel into nothing. See [maxBurst] for why it exists at all.
      _burstWatchdog?.cancel();
      _burstWatchdog = Timer(maxBurst, () {
        if (!_burstActive) return;
        _log?.call('burst watchdog fired after ${maxBurst.inMilliseconds} ms — the '
            'release never arrived');
        // Unawaited by design: this runs from a timer, and `stopBurst` reports its own
        // failure through `lastBurstStopError` rather than by throwing.
        stopBurst();
      });
      return CaptureResult(CaptureOutcome.ok, response: r);
    } on CameraHttpException catch (e) {
      _log?.call('x burst start failed: ${e.message}');
      return CaptureResult(CaptureOutcome.transportError, reason: e.message);
    } finally {
      _inFlight = false;
      _inFlightSince = null;
    // (no change notifier here: `AppState` polls `burstActive`)
    }
  }

  /// End a burst. **Never refuses, and never queues behind the interlock.**
  ///
  /// This is the one send in this class that must not be gated. Every other path exists
  /// to stop the app doing something to the camera; this one exists to stop the camera
  /// doing something to itself, and a camera left bursting strands its capture state and
  /// needs its battery pulled — which is what happened on hardware when a brief tap in
  /// Continuous started a burst nothing could end.
  ///
  /// So: no cool-down, no health probe, no quarantine, and it runs even while another
  /// capture is in flight. It is safe to call when no burst is running (it sends anyway —
  /// see [cancelShootingCommand] for why the command's exact effect is not established),
  /// and safe to call twice.
  Future<void> stopBurst() async {
    final wasActive = _burstActive;
    _burstActive = false;
    _burstWatchdog?.cancel();
    _burstWatchdog = null;
    // Counted **before** the await, because this is attempts and not completions. A stop
    // issued from `onLinkLost` is deliberately not awaited — the send may never finish over
    // a link that has gone away — and a counter incremented after the await would read zero
    // for exactly the case that matters most: the link dropped while the camera was
    // bursting.
    _burstStopAttempts++;
    _log?.call('-> $cancelShootingCommand (burst stop${wasActive ? '' : ', no burst active'})');
    try {
      final r = await http().send(cancelShootingCommand);
      _log?.call('<- code=${r.code} raw=${r.raw.trim()}');
    } on Object catch (e) {
      // Reported, not swallowed: after a link loss this will fail, and the user needs to
      // know the burst may still be running rather than believe it stopped.
      _log?.call('x burst stop failed: $e');
      lastBurstStopError = '$e';
    }
  }

  /// The last failure from [stopBurst], or null when it last succeeded.
  ///
  /// Exposed because "the burst may still be running" is something the UI has to be able
  /// to say. A silent failure here is a camera that keeps shooting.
  String? lastBurstStopError;

  /// How many times [stopBurst] has been called, successful or not.
  ///
  /// Counted so a check can assert the release path really fires — the defect being
  /// guarded against is a burst that nothing ends.
  int get burstStopAttempts => _burstStopAttempts;
  int _burstStopAttempts = 0;

  /// The command [startBurst] sends, overridable so a test can watch for it.
  final String? burstStartCommand;

  void onLinkLost() {
    // A burst outlives the link that started it: the camera does not need the link to keep
    // shooting. So the stop is attempted *before* the session is forgotten, even though
    // over a link that has just gone away it will usually fail — the alternative is not
    // trying, and a camera left bursting needs its battery pulled.
    if (_burstActive) {
      // Not awaited on purpose: this is a synchronous notification path and the send is
      // best-effort by design. `burstStopAttempts` and `lastBurstStopError` are how a
      // caller finds out what happened.
      stopBurst();
    }
    _quarantinedAt = null;
    _lastAttempt = null;
    _inFlight = false;
    _inFlightSince = null;
  }

  /// Release quarantine without waiting, for when the user knows better.
  ///
  /// The app cannot see everything: the user can power-cycle the camera, swap
  /// its battery, or reconnect its Wi-Fi, none of which the health probe can
  /// distinguish from a slow link.  Refusing to accept that would turn a safety
  /// feature into a dead end.
  ///
  /// ## What this does and does not release
  ///
  /// It runs the health probe with the cool-down floor lifted, because the floor
  /// exists to stop the *app* retrying too eagerly and the user has just said
  /// "now".  If the camera answers and the preview is moving, the interlock opens
  /// and the next press reaches the camera; if it does not, quarantine stands and
  /// the reason says so, which is a far better answer than a button that appears
  /// to do nothing.
  ///
  /// It deliberately does **not** clear the in-flight reservation while that
  /// reservation is live: "the camera is fine again" is not the same claim as "no
  /// capture is running", and clearing it here would let a second `RCDoShooting`
  /// out while the first is still on the wire — the very overlap this class exists
  /// to prevent.  An attempt that has outlived [staleAfter] is a different matter:
  /// it cannot still be on the wire, and leaving the reservation set is precisely
  /// the state in which no press can ever work again, so a stale one is dropped.
  ///
  /// Returns whether the interlock is open afterwards, so the caller can tell the
  /// user the truth rather than promising a shutter that is still blocked.
  Future<bool> forceRelease() async {
    final wasStale = isStale;
    if (wasStale) {
      _inFlight = false;
      _inFlightSince = null;
    }

    // The cool-down floor has to come off before the probe, or it answers
    // "not yet" on the timer alone and the release silently does nothing.
    final probe = _probeHealthy(requireCooldown: false);
    _quarantinedAt = null;
    _lastAttempt = null;
    final healthy = await probe;
    if (!healthy) {
      // Re-arm the quarantine: the camera did not prove itself, and the next
      // press must go back through the same check rather than straight out.
      _quarantinedAt = now();
    }
    return !isQuarantined;
  }

  /// Human-readable status for the UI.
  String describe() {
    if (_inFlight) {
      final d = inFlightFor;
      return isStale
          ? 'a capture request has been outstanding for ${d!.inSeconds}s, which '
              'is longer than any reply can take — it is stuck, not running'
          : 'capturing';
    }
    if (_quarantinedAt != null) {
      final s = now().difference(_quarantinedAt!).inSeconds;
      return 'recovering (${s}s) — the camera rejected a capture, so further '
          'shots wait until the preview moves again';
    }
    return 'ready';
  }
}

/// Values that must never be sent for `RCDriveModeSet` while the hang is
/// unpatched, because burst mode is the quickest way to strand the flags.
const Set<String> kUnsafeDriveModes = <String>{
  'Continuous',
};
