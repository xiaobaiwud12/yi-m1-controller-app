import 'dart:async';
import 'dart:typed_data';

import '../transport/album.dart';
import '../transport/http_transport.dart';
import 'asset_sink_contract.dart';
import 'exif_wall_clock.dart';
import 'stream_pause_contract.dart';
import 'sync_ledger.dart';
import 'transfer_queue.dart';

/// The ARB keys behind [SyncStage.label].
///
/// Declared next to the enum rather than in the UI so the two cannot drift: the
/// switch in [SyncStage.labelCode] is exhaustive over the enum, and
/// `test/l10n_message_codes_test.dart` asserts this set equals the set of keys the
/// resolver in `lib/l10n/message_text.dart` handles.
///
/// `linkStageFailed` is absent deliberately — see the comment on that branch.
abstract final class SyncStageCodes {
  static const queued = 'stageQueued';
  static const downloadingPreview = 'stagePreview';
  static const downloadingOriginal = 'stageDownloading';
  static const stalled = 'stageStalled';
  static const pausedNoCamera = 'stagePausedNoCamera';
  static const pausedByUser = 'stagePausedByUser';
  static const pausedLowBattery = 'stagePausedLowBattery';
  static const done = 'stageDone';

  static const Set<String> all = {
    queued,
    downloadingPreview,
    downloadingOriginal,
    stalled,
    pausedNoCamera,
    pausedByUser,
    pausedLowBattery,
    done,
  };
}

/// The ARB keys for the engine's run-level notes and its stream-pause reason.
///
/// Separate from [SyncStageCodes] because these are sentences about the *run*, not
/// about one item: `syncNoteCameraAway` says why the whole queue stopped, and
/// `syncStreamPauseReason` is what the live view draws over a still frame. Both are
/// rendered by the UI (`SyncEngine.summary.note`, `streamPauseReason`), so both need
/// a code for the same reason — see `lib/l10n/message_text.dart`.
abstract final class SyncNoteCodes {
  static const cameraAway = 'syncNoteCameraAway';
  static const pausedByUser = 'syncNotePausedByUser';
  static const streamPauseReason = 'syncStreamPauseReason';

  static const Set<String> all = {
    cameraAway,
    pausedByUser,
    streamPauseReason,
  };
}

/// Per-item transfer state.
///
/// The design guide is emphatic that **naming every state** is what separates a
/// trustworthy sync from an untrustworthy one (§5.6): "paused (Wi-Fi lost)",
/// "stalled (retrying)" and "failed" are three different things, and collapsing
/// them into a spinner is the classic silent-stall failure mode.
enum SyncStage {
  queued,
  downloadingPreview,
  downloadingOriginal,
  stalled,
  pausedNoCamera,
  pausedByUser,
  pausedLowBattery,
  failed,
  done;

  String get label => switch (this) {
        SyncStage.queued => 'Queued',
        SyncStage.downloadingPreview => 'Preview',
        SyncStage.downloadingOriginal => 'Downloading',
        SyncStage.stalled => 'Stalled, retrying',
        SyncStage.pausedNoCamera => 'Paused, camera away',
        SyncStage.pausedByUser => 'Paused by you',
        SyncStage.pausedLowBattery => 'Paused, camera battery low',
        SyncStage.failed => 'Failed',
        SyncStage.done => 'Saved',
      };

  /// The ARB key for [label], or null for a stage with no wording of its own.
  ///
  /// The same shape as `LinkCodes` in `lib/transport/camera_connection.dart` and for
  /// the same reason: `AGENTS.md` §4.1 keeps this file free of `package:flutter`, so
  /// the sentence stays here — `label` is what a log prints and what the UI falls
  /// back to — and the *code* is what the UI resolves against the ARB. `this.name`
  /// would be a tempting shortcut and is deliberately not used: the enum's Dart
  /// spelling is not a translation key, and renaming a constant would then silently
  /// change which strings the UI looks up.
  String? get labelCode => switch (this) {
        SyncStage.queued => SyncStageCodes.queued,
        SyncStage.downloadingPreview => SyncStageCodes.downloadingPreview,
        SyncStage.downloadingOriginal => SyncStageCodes.downloadingOriginal,
        SyncStage.stalled => SyncStageCodes.stalled,
        SyncStage.pausedNoCamera => SyncStageCodes.pausedNoCamera,
        SyncStage.pausedByUser => SyncStageCodes.pausedByUser,
        SyncStage.pausedLowBattery => SyncStageCodes.pausedLowBattery,
        // `failed` has no code on purpose: its sentence is not this enum's — see
        // `SyncItem.note`, which carries the actual reason the camera gave, and
        // which is what the list appends to the stage label.
        SyncStage.failed => null,
        SyncStage.done => SyncStageCodes.done,
      };

  bool get isTerminal => this == SyncStage.done || this == SyncStage.failed;
  bool get isPaused =>
      this == SyncStage.pausedNoCamera ||
      this == SyncStage.pausedByUser ||
      this == SyncStage.pausedLowBattery;
  bool get isActive =>
      this == SyncStage.downloadingPreview ||
      this == SyncStage.downloadingOriginal ||
      this == SyncStage.stalled;
}

/// One unit of work: a camera asset to bring to the phone.
class SyncItem {
  final AlbumFile file;
  final AssetId id;

  SyncStage stage;
  int bytesReceived;
  int expectedBytes;

  /// The rendition currently on disk for this item, if any.
  AssetQuality quality;

  String? error;
  int attempts;

  /// Set when the user struck this item out of the queue while it was in flight.
  ///
  /// ## Why cancelling does not abort the request
  ///
  /// A `GetFile` already on the wire cannot be recalled without sending another
  /// command, and the only command that would abort it (`PauseMovieStream`) has
  /// never been accepted by a real YI M1 and this camera has **no watchdog**
  /// (`AGENTS.md` §4.6). So the honest cancellation is: let the current request
  /// finish, then **throw its bytes away** — never publish, never record it as
  /// saved, and never let it come back at the next launch. The user gets what they
  /// asked for (the file does not appear) at the cost of the bytes already in
  /// flight, which are lost either way.
  bool removed = false;

  SyncItem({
    required this.file,
    required this.id,
    this.stage = SyncStage.queued,
    this.bytesReceived = 0,
    this.expectedBytes = 0,
    this.quality = AssetQuality.none,
    this.error,
    this.attempts = 0,
  });

  String get name => file.fileName;

  /// 0..1, or null when the size is not known.
  ///
  /// `GetFile` sends no `Content-Length` we can rely on, so progress is
  /// estimated from the album listing's reported size when there is one and is
  /// otherwise reported as bytes rather than a fake percentage.
  double? get progress {
    if (expectedBytes > 0) return (bytesReceived / expectedBytes).clamp(0.0, 1.0);
    return null;
  }

  @override
  String toString() => 'SyncItem(${file.path}, $stage, ${quality.name})';
}

/// How the user wants photos brought across.
enum SyncMode {
  /// Sync automatically when the camera connects, at preview quality first.
  autoPreviewThenOriginal,

  /// Sync automatically, originals only.  Slower to show anything, but nothing
  /// lands on the phone that is not the real file.
  autoOriginalOnly,

  /// Nothing happens until the user picks items.
  manualOnly,
}

/// What the engine is doing overall.
class SyncSummary {
  final int total;
  final int done;
  final int previews;
  final int originals;
  final int failed;
  final int pending;
  final int bytes;
  final bool running;

  /// The engine's one-line note, in English — the fallback the album bar shows when
  /// [noteCode] is null or unknown. See [SyncNoteCodes].
  final String? note;

  /// The ARB key naming [note], or null when the sentence came from somewhere else.
  final String? noteCode;

  /// True while a bulk run is holding the live-view stream paused (§5.3).
  final bool streamPausedForTransfer;

  /// Why the stream is held, in words a user can act on.  Null when it is not.
  final String? streamPauseReason;

  /// The ARB key naming [streamPauseReason], or null when there is no reason.
  final String? streamPauseReasonCode;

  const SyncSummary({
    this.total = 0,
    this.done = 0,
    this.previews = 0,
    this.originals = 0,
    this.failed = 0,
    this.pending = 0,
    this.bytes = 0,
    this.running = false,
    this.note,
    this.noteCode,
    this.streamPausedForTransfer = false,
    this.streamPauseReason,
    this.streamPauseReasonCode,
  });

  bool get isComplete => total > 0 && pending == 0;

  @override
  String toString() => '$done of $total — $originals originals, '
      '$previews previews${failed > 0 ? ', $failed failed' : ''}';
}

/// The sync engine.
///
/// ## Design decisions taken from the project's own design guide
///
/// * **One request in flight, never parallel** (§5.3). The camera runs a small
///   single-threaded httpd; parallel `GetFile` calls do not go faster and
///   increase stall probability.
/// * **Preview first, then upgrade in place** (§D2) — the differentiator no
///   major app can copy, because it needs three resolutions of the same *path*.
/// * **Atomic commits** (§5.5). Range support is unverified, so a transfer
///   either completes or nothing is recorded.
/// * **JPEG integrity by EOI marker.** A truncated response is the most likely
///   corruption mode and the check is two bytes.
/// * **Never silently downgrade** (§5.2). A failed `Original` is retried and
///   reported; the preview already on disk stays visible but is *labelled* as a
///   preview.
/// * **Losing the camera is a pause, not a failure** (§5.6.5). The single most
///   likely interruption is the camera going to sleep or being switched off, and
///   resuming on reconnect is the whole point of the durable queue.
/// * **Pause the stream for a bulk run, don't fight it** (§5.3). The preview and a
///   full-resolution download share one 802.11n link, so a run holds the stream
///   paused and releases it in a `finally`, on a watchdog, and through a count so
///   overlapping holders cannot resume each other's pause.
class SyncEngine {
  final CameraAlbum Function() album;
  final SyncLedger ledger;
  final AssetSink sink;

  /// The durable queue, when there is one.
  ///
  /// Optional so the offline checks can drive the engine without a store, and so
  /// a caller that only wants the in-memory behaviour is not forced to opt in.
  /// When it is present the engine keeps it in step with the items: it is *the*
  /// record of what is still to come, which is what makes an app kill cost a
  /// queue reload instead of an album re-list (§5.5).
  final TransferQueue? queue;

  /// Called after the engine has changed the queue's contents, so the host can
  /// decide when to write it out.
  final void Function()? onQueueChanged;

  /// Extra callbacks, so the UI can show state without this class knowing about
  /// widgets.
  final void Function(String message)? onLog;

  /// Called whenever the queue or its items change, so the UI can repaint.
  ///
  /// A callback rather than `ChangeNotifier`, because this file must stay free of
  /// Flutter so `tool/verify_sync.dart` can drive it in the plain Dart VM.  It is
  /// mutable so a screen can attach and detach without the engine holding a
  /// reference to a disposed widget.
  void Function()? onChanged;

  SyncEngine({
    required this.album,
    required this.ledger,
    required this.sink,
    this.queue,
    this.onQueueChanged,
    this.streamPause,
    this.streamPauseWatchdog = const Duration(minutes: 2),
    this.onLog,
    this.onChanged,
  });

  // ------------------------------------------------------- stream control

  /// Pauses and resumes the camera's live-view stream.
  ///
  /// Injected, and nullable, because the engine must be drivable without a
  /// camera — `tool/verify_sync.dart` runs in the plain Dart VM — and because a
  /// host with no stream to pause (a headless sync, a NAS target) should be able
  /// to say so by passing nothing at all.
  final StreamPauseController? streamPause;

  /// Whether a bulk run may pause the stream at all.
  ///
  /// The design guide's recommendation (§5.3) is to pause, because on this
  /// hardware the stream and a full-resolution download genuinely compete for
  /// **one** 802.11n link. Measured on the real body, both are in the same league:
  /// the live view runs at **~52–57 KB per datagram at ~30 per second, about
  /// 12–14 Mbit/s** (48 697 datagrams / 2.56 GB, counted by
  /// `tools/camera_bridge.py`), and a `GetFile` runs at ~13.5 Mbit/s. An earlier
  /// version of this comment put the stream at ~4.2 Mbit/s; that number came from a
  /// 40-frame sample of a *flat* scene and understated it about threefold — **the
  /// contention is real, the arithmetic was wrong**. But a user who wants to keep
  /// framing a shot while a backlog drains is making a legitimate choice, and a
  /// preview that freezes with no way to opt out reads as a bug. So it is a
  /// setting, not hard-coded behaviour.
  // PauseMovieStream/ResumeMovieStream are structurally known but have never
  // been accepted by a real YI M1. Sending an unverified command immediately
  // before GetFile can wedge this watchdog-less camera, so the safe default is
  // off. Users can explicitly opt into the experiment after the basic transfer
  // path is proven on their body.
  bool _pauseStreamDuringTransfer = false;
  bool get pauseStreamDuringTransfer => _pauseStreamDuringTransfer;
  set pauseStreamDuringTransfer(bool v) {
    if (_pauseStreamDuringTransfer == v) return;
    _pauseStreamDuringTransfer = v;
    _log('pause the preview during a transfer: ${v ? 'on' : 'off'}');
    onChanged?.call();
  }

  /// How many transfers currently hold the stream paused.
  ///
  /// **Counted, not a flag.** Two runs can overlap — the durable queue resumes a
  /// transfer that a reconnect restarted — and with a boolean the first run to
  /// finish would resume a stream the second one still needs paused, which puts
  /// the two back in competition and is exactly the state this feature exists to
  /// prevent. The count means the stream is resumed by the **last** holder and
  /// nobody else. It is also what makes the pause idempotent: a second holder
  /// does not re-send `PauseMovieStream`, because the camera's stream state
  /// cannot be read back and a redundant command to a device with no watchdog is
  /// a risk taken for nothing.
  ///
  /// The hold is acquired even when the camera refuses or never answers the
  /// pause, so the accounting always stays balanced and the resume is still sent.
  /// That is what makes a refused pause invisible to the transfer: it proceeds at
  /// full speed with the stream still running — slow, but correct — instead of
  /// failing.
  int _streamHoldDepth = 0;

  /// True while some transfer holds the pause.  Read by the UI.
  bool get streamPausedForTransfer => _streamHoldDepth > 0;

  String? _streamPauseReason;

  /// Why the stream is held, in words the UI can show.  Null when it is not.
  String? get streamPauseReason => _streamPauseReason;

  /// Watchdog: the longest a pause may be held before it is released anyway.
  ///
  /// A `try`/`finally` is not sufficient on its own. This firmware has **no
  /// watchdog**, so a command it does not expect can wedge it until the battery
  /// is pulled — and if the transfer's future then never completes, the `finally`
  /// never runs and the user is left with the exact outcome the design guide
  /// warns about: a client that paused the stream and never resumed, i.e. a
  /// preview frozen on its last frame, which is indistinguishable from a crash.
  /// So the release is armed on a timer as well, and fires whether or not the
  /// transfer ever returns.
  ///
  /// The value is a compromise. Too short and a legitimate 9 MB transfer on a
  /// slow link trips it, which puts the stream back into competition with the
  /// transfer it was paused for; too long and a genuinely wedged run leaves the
  /// preview frozen for that long. Two minutes is more than an order of magnitude
  /// longer than a healthy full-resolution transfer (9.4 MB measured in 5.6 s on
  /// an idle link) and short enough that a stuck run does not look like a hang
  /// forever. It costs nothing when things work: every normal exit cancels it.
  final Duration streamPauseWatchdog;

  Timer? _streamWatchdog;

  /// The timer's own generation, so a watchdog that already fired cannot release
  /// a hold acquired later.  Without it, a stale timer firing during the next
  /// run's pause would resume a stream that run is relying on being paused.
  int _streamWatchdogEpoch = 0;

  /// Hold the stream paused for the duration of a bulk run.
  ///
  /// Public because the count is the feature: it is only meaningful across
  /// *overlapping* runs, and the only way to exercise that offline is to open two
  /// holds without two live transfers. `tool/verify_sync.dart` does exactly that.
  ///
  /// Returns immediately when there is nothing to pause, when the user has opted
  /// out, or when a previous holder already has it — in which case the stream is
  /// already quiet and the only thing that happens is the count going up.
  Future<void> beginStreamHold() async {
    if (streamPause == null || !_pauseStreamDuringTransfer) return;
    _streamHoldDepth++;
    _streamPauseReason ??=
        'Preview paused while photos transfer — the live view and a '
        'full-resolution download share one Wi-Fi link, so they slow each other '
        'down. It comes back as soon as the transfer finishes.';
    if (_streamHoldDepth == 1) {
      // One attempt, and **every** failure mode is swallowed on purpose: a
      // refused, unanswered or throwing `PauseMovieStream` must cost bandwidth,
      // never the transfer. The command is structurally verified but has never
      // run on real hardware, so "the camera said no" is an expected outcome
      // rather than a fault — and the throw is covered by the offline checks,
      // because letting it escape here aborts the whole run before a single file
      // has moved. Degrading to a slow sync beats a sync that refuses to start.
      try {
        final paused = await streamPause!.pause();
        if (!paused) {
          _log('the camera did not accept PauseMovieStream; the transfer runs '
              'with the preview still up');
        }
      } on Object catch (e) {
        _log('pausing the stream failed ($e); the transfer runs with the preview '
            'still up');
      }
    }
    _armStreamWatchdog();
    onChanged?.call();
  }

  /// Release one hold; the stream resumes when the count reaches zero.
  Future<void> endStreamHold() async {
    if (_streamHoldDepth == 0) return;
    _streamHoldDepth--;
    if (_streamHoldDepth > 0) {
      // Another run is still transferring. Resuming here would put the stream
      // back into competition with it — the whole failure this count prevents.
      onChanged?.call();
      return;
    }
    _cancelStreamWatchdog();
    _streamPauseReason = null;
    onChanged?.call();

    final controller = streamPause;
    if (controller == null) return;
    try {
      if (!await controller.resume()) {
        _log('ResumeMovieStream was not confirmed. If the preview stays frozen, '
            'stop and start it to rebind the stream.');
      }
    } on Object catch (e) {
      // Belt and braces: the contract says implementations report rather than
      // throw, but this is the one call whose failure leaves a frozen view, so it
      // is never allowed to escape into the run's own error handling.
      _log('resuming the stream threw ($e)');
    }
  }

  /// Drop every stream hold at once, resuming the preview immediately.
  ///
  /// Exists because the user asked for it: turning [pauseStreamDuringTransfer]
  /// off only stops *future* transfers from pausing. A transfer already running
  /// still holds the stream, so the setting appeared to do nothing to the frozen
  /// preview the user was looking at — and the banner offering "keep the preview
  /// running" therefore could not actually deliver that.
  ///
  /// Deliberately not routed through [endStreamHold] in a loop: that resumes on
  /// the last decrement, which is the same outcome with more awaits in between,
  /// and the in-flight transfer's own `endStreamHold` must become a no-op rather
  /// than driving the depth negative. Zeroing the depth is what makes it a no-op.
  Future<void> releaseAllStreamHolds() async {
    if (_streamHoldDepth == 0) return;
    _streamHoldDepth = 0;
    _cancelStreamWatchdog();
    _streamPauseReason = null;
    onChanged?.call();

    final controller = streamPause;
    if (controller == null) return;
    try {
      if (!await controller.resume()) {
        _log('ResumeMovieStream was not confirmed after the user turned the '
            'pause off. If the preview stays frozen, stop and start it.');
      }
    } on Object catch (e) {
      _log('resuming the stream threw ($e)');
    }
  }

  void _armStreamWatchdog() {
    _cancelStreamWatchdog();
    final epoch = ++_streamWatchdogEpoch;
    _streamWatchdog = Timer(streamPauseWatchdog, () {
      // Only the timer belonging to the current hold may fire. A cancelled timer
      // that already queued its callback would otherwise resume a stream a newer
      // hold is deliberately keeping paused.
      if (epoch != _streamWatchdogEpoch) return;
      if (_streamHoldDepth == 0) return;
      _log('the pause has been held for ${streamPauseWatchdog.inSeconds}s, which '
          'is longer than any healthy transfer; resuming the preview now rather '
          'than leaving it frozen.');
      _streamHoldDepth = 1;
      unawaited(endStreamHold());
    });
  }

  void _cancelStreamWatchdog() {
    // Bumping the epoch disarms a callback that has already been queued but not
    // yet run, which cancel() alone does not do.
    _streamWatchdogEpoch++;
    _streamWatchdog?.cancel();
    _streamWatchdog = null;
  }

  /// Whether a run would actually transfer something.
  ///
  /// Used to avoid pausing the stream for a run that has nothing to do, because
  /// pausing and immediately resuming would blink the preview for no reason —
  /// and every command sent to this camera is a small risk it does not need.
  bool get _hasPendingWork =>
      _items.any((i) => !i.stage.isTerminal && i.stage != SyncStage.pausedByUser);

  final List<SyncItem> _items = [];
  List<SyncItem> get items => List.unmodifiable(_items);

  SyncMode _mode = SyncMode.autoPreviewThenOriginal;
  SyncMode get mode => _mode;
  set mode(SyncMode m) {
    if (_mode == m) return;
    _mode = m;
    _log('sync mode: ${m.name}');
    onChanged?.call();
  }

  bool _paused = false;
  bool get paused => _paused;

  bool _cameraPresent = false;
  String? _note;

  /// The ARB key naming [_note]. Kept in step with it at every assignment — a stale
  /// code would make the UI translate a sentence that is no longer on screen.
  String? _noteCode;

  /// True while the engine holds the queue.
  bool _running = false;

  SyncSummary get summary {
    var done = 0, previews = 0, originals = 0, failed = 0, pending = 0, bytes = 0;
    for (final i in _items) {
      bytes += i.bytesReceived;
      switch (i.stage) {
        case SyncStage.done:
          done++;
          if (i.quality.isOriginal) {
            originals++;
          } else {
            previews++;
          }
        case SyncStage.failed:
          failed++;
        default:
          pending++;
      }
    }
    return SyncSummary(
      total: _items.length,
      done: done,
      previews: previews,
      originals: originals,
      failed: failed,
      pending: pending,
      bytes: bytes,
      running: _running,
      note: _note,
      noteCode: _noteCode,
      streamPausedForTransfer: _streamHoldDepth > 0,
      streamPauseReason: _streamPauseReason,
      streamPauseReasonCode:
          _streamPauseReason == null ? null : SyncNoteCodes.streamPauseReason,
    );
  }

  void _log(String m) => onLog?.call('[sync] $m');

  /// Called when the camera link comes up.
  ///
  /// "On connect" is the highest-value trigger: the user has already taken the
  /// action of connecting, so the cost is zero and the behaviour is predictable.
  void cameraConnected({Object? state}) {
    _cameraPresent = true;
    _note = null;
    _noteCode = null;
    // Resume anything that was paused waiting for it.
    for (final i in _items) {
      if (i.stage == SyncStage.pausedNoCamera) i.stage = SyncStage.queued;
    }
    onChanged?.call();
  }

  /// Called when the link drops.
  ///
  /// This is a **pause**, not a failure.  The design guide notes that DJI treats
  /// "the camera just disappeared" as a sync trigger because the end of a shoot
  /// is exactly when the user wants the files; here it at least must not lose
  /// the queue.
  void cameraLost() {
    _cameraPresent = false;
    for (final i in _items) {
      if (!i.stage.isTerminal && i.stage != SyncStage.pausedByUser) {
        i.stage = SyncStage.pausedNoCamera;
      }
    }
    _note = 'The camera went away. Sync resumes when it is back.';
    _noteCode = SyncNoteCodes.cameraAway;
    onChanged?.call();
  }

  void pause() {
    _paused = true;
    _note = 'Paused by you.';
    _noteCode = SyncNoteCodes.pausedByUser;
    onChanged?.call();
  }

  void resume() {
    _paused = false;
    _note = null;
    _noteCode = null;
    unawaited(run());
  }

  /// Enqueue everything a browsed album page contains.
  ///
  /// This is the **automatic** path: the user opened the album and the engine
  /// infers that these shots are candidates. It is therefore the path the sync
  /// mode governs, and in [SyncMode.manualOnly] it must add nothing at all.
  ///
  /// That was the reported defect: browsing called [enqueue] unconditionally, so
  /// every photo on the card entered the queue and the durable record no matter
  /// which mode was selected — including "Manual — only what I pick", whose whole
  /// promise is that nothing moves until the user chooses it. Selecting a
  /// different mode changed nothing visible, because the queue had already been
  /// filled by the act of looking.
  int enqueueBrowsed(List<AlbumFile> files) {
    if (_mode == SyncMode.manualOnly) {
      _log('manual mode: browsing queues nothing');
      return 0;
    }
    return enqueue(files);
  }

  /// Enqueue the results of one album page.
  ///
  /// Returns how many new items were added, so the caller can decide whether to
  /// keep paging.
  int enqueue(List<AlbumFile> files, {bool onlyNew = true}) {
    var added = 0;
    var queuedNew = false;
    for (final f in files) {
      final id = AssetId(
        path: f.path,
        dateSeconds: f.captureTime?.millisecondsSinceEpoch != null
            ? f.captureTime!.millisecondsSinceEpoch ~/ 1000
            : 0,
      );
      // Deduplicate against what is already queued here. The test is a *path*
      // match, or a shot match between two assets of the same kind: a RAW+JPEG
      // exposure is one durable record but two items in the engine, and its two
      // files must not be collapsed into one just because they share a shot key.
      // A page browsed twice, or browsed again after a restore, then adds
      // nothing at all.
      if (_items.any((i) =>
          i.file.path == f.path ||
          (i.file.fileType == f.fileType &&
              TransferQueue.shotKey(i.id.path, i.id.dateSeconds) ==
                  TransferQueue.shotKey(id.path, id.dateSeconds)))) {
        continue;
      }
      // The ledger decides whether this is new work, and it is asked *before* the
      // queue is written: automatic browsing must not put an already-transferred
      // file back into the durable queue, or the next launch restores work that
      // is already finished on disk. An explicit choice arrives with onlyNew:false
      // and is queued regardless, because the ledger can be wrong about a file
      // the user has since deleted from the phone.
      if (onlyNew && ledger.has(id, atLeast: AssetQuality.original)) continue;
      queuedNew = (queue?.add(f) ?? false) || queuedNew;

      final already = ledger.qualityOf(id);
      _items.add(SyncItem(
        file: f,
        id: id,
        quality: already,
        // Something already on disk at preview quality only needs the upgrade.
        stage: SyncStage.queued,
      ));
      added++;
    }
    if (added > 0) {
      _log('queued $added item(s)');
      onChanged?.call();
    }
    if (queuedNew) onQueueChanged?.call();
    return added;
  }

  /// Enqueue explicit user choices, ignoring the "already synced" filter.
  int enqueueSelected(List<AlbumFile> files) => enqueue(files, onlyNew: false);

  /// Rebuild the pending queue from its durable record.
  ///
  /// Called **before the album is first browsed**, so a restore cannot race the
  /// initial enqueue: the two would otherwise both add the same shots, and the
  /// user would watch a duplicate row appear and vanish.
  ///
  /// Returns how many items were restored.
  int restore() {
    final q = queue;
    if (q == null || q.isEmpty) return 0;

    var restored = 0;
    for (final r in q.pending) {
      // ## Which source is authoritative for "already have it"
      //
      // The **ledger**. The queue is a statement of intent — what the user asked
      // for — and it cannot know what is on the phone: files get deleted from the
      // gallery, an upgrade can land after the queue last wrote, and a legacy
      // queue may predate the ledger entirely. The ledger is the record of what
      // actually arrived, so where the two disagree about quality the ledger
      // wins, and [AssetQuality.none] answers for a queue-only item rather than
      // re-asking the camera.
      //
      // Items the ledger already holds at original quality are therefore skipped
      // even though the queue still lists them; they are also what `clearFinished`
      // and the prune below exist to remove, so a done item is never resurrected
      // as pending work.
      for (final a in r.assets) {
        if (ledger.has(a.assetId, atLeast: AssetQuality.original)) continue;
        final file = a.toAlbumFile();
        // The restored item has no listing, so it has no thumbnail and its
        // progress bar fills on bytes alone; both are cosmetic and neither is
        // worth a `GetFileList` round trip.
        final item = SyncItem(
          file: file,
          id: a.assetId,
          quality: _bestOf(a.quality, ledger.qualityOf(a.assetId)),
          stage: SyncStage.queued,
        );
        if (_merge(item)) restored++;
      }
    }
    if (restored > 0) {
      _log('restored $restored pending item(s) from the durable queue');
      onChanged?.call();
    }
    return restored;
  }

  static AssetQuality _bestOf(AssetQuality a, AssetQuality b) =>
      a.index >= b.index ? a : b;

  bool _merge(SyncItem item) {
    final shot = TransferQueue.shotKey(item.id.path, item.id.dateSeconds);
    final at = _items.indexWhere(
        (i) => TransferQueue.shotKey(i.id.path, i.id.dateSeconds) == shot);
    if (at < 0) {
      _items.add(item);
      return true;
    }
    // Already present, e.g. its page was browsed before the restore ran: take
    // whichever quality is higher, and never inflate the queue with a duplicate.
    final existing = _items[at];
    if (item.quality.index > existing.quality.index) {
      existing.quality = item.quality;
    }
    return false;
  }

  void clearFinished() {
    final removed = _items.where((i) => i.stage == SyncStage.done).toList();
    _items.removeWhere((i) => i.stage == SyncStage.done);
    for (final i in removed) {
      queue?.markDone(i.id.path, i.id.dateSeconds);
    }
    if (removed.isNotEmpty) onQueueChanged?.call();
    onChanged?.call();
  }

  void clearAll() {
    _items.clear();
    queue?.clear();
    onQueueChanged?.call();
    onChanged?.call();
  }

  // -------------------------------------------------- cancelling queued work

  /// True when a run would still fetch something for this item.
  ///
  /// The honest question behind the count the queue list shows: an item already
  /// saved is history, and an item the user paused deliberately is not work this
  /// run will do either.
  static bool _isOutstanding(SyncItem i) =>
      !i.stage.isTerminal && i.stage != SyncStage.pausedByUser;

  /// How many shots a run would still fetch.
  int get pendingCount => _items.where(_isOutstanding).length;

  /// Drop one shot the user struck out of the list.
  ///
  /// ## What "cancel" can and cannot mean here
  ///
  /// There are three candidate behaviours for an item that is *in flight*, and only
  /// one of them is honest on this hardware:
  ///
  /// * abort the request — needs `PauseMovieStream`, which has **never** been
  ///   accepted by a real YI M1 and which this camera, with no watchdog, may answer
  ///   by wedging (`AGENTS.md` §4.6). Refused.
  /// * let the request finish and **keep** the bytes because they arrived anyway —
  ///   that is not a cancellation at all: the user asked for the photo not to be
  ///   saved, and it appears in their gallery regardless.
  /// * let the request finish and **discard** the reply, which is what this does. It
  ///   costs the bytes already on the wire, which are lost either way, and it sends
  ///   the camera not one command more than it had already been sent.
  ///
  /// A queued (not yet started) item is dropped immediately and fetches nothing.
  ///
  /// Returns the paths that left the queue, so the caller can say what happened.
  List<String> removeItem(SyncItem item) {
    // Already gone: a second tap must not report a second removal, and must not
    // touch a queue record that a later `clearPending` has already dealt with.
    if (item.removed) return const [];
    item.removed = true;
    if (!item.stage.isActive) _items.remove(item);
    queue?.removeAsset(item.file.path, item.id.dateSeconds);
    onQueueChanged?.call();
    onChanged?.call();
    return [item.file.path];
  }

  /// Drop every shot still waiting, in one action.
  ///
  /// **What this is not:** it does not delete anything on the camera, and it does
  /// not forget anything already on the phone. It empties the job list — the answer
  /// to "I queued the whole card by accident and I am not waiting for 900 MB over
  /// this link". Re-queueing is one tap away: the automatic modes queue what is
  /// listed when the album is browsed again, or when the mode is re-selected.
  ///
  /// Items already saved are left alone. They are history, and the ledger — not
  /// this list — is what says a photo is on the phone.
  ///
  /// Returns how many shots were dropped.
  int clearPending() {
    final doomed = _items.where(_isOutstanding).toList();
    for (final i in doomed) {
      removeItem(i);
    }
    if (doomed.isNotEmpty) {
      _log('dropped ${doomed.length} queued shot(s) at the user\'s request');
    }
    return doomed.length;
  }

  // ---------------------------------------------------- re-deriving the list

  /// Change the sync mode, and bring the job list into line with what it means.
  ///
  /// ## Why the list is re-derived rather than inherited
  ///
  /// [SyncMode] is not a setting about *future* items: it is the rule that decides
  /// whether a preview is fetched before the full size, and the job list is exactly
  /// the set of renditions still to fetch. So a list built under one mode and
  /// carried into another **silently means something other than what the selector
  /// above it says** — the reported defect, seen from the other side of the manual
  /// fix: leaving `manualOnly` re-queued, but moving between the two automatic modes
  /// left the old list untouched.
  ///
  /// ## Why not offer the choice
  ///
  /// The alternative was to ask ("inherit the old list, or rebuild it?") and it was
  /// rejected on three grounds:
  ///
  /// * the mode dropdown is a **selector, not a destructive action** — a dialog in
  ///   front of a control the user may try three times in a row teaches people to
  ///   dismiss dialogs without reading them;
  /// * this page's own rule is that sync is never modal (§5.6); the one dialog here
  ///   guards the one action the app **cannot undo** (deleting from the card), and
  ///   changing a mode is undone by changing it back;
  /// * there is a better answer than either option the question offers — the list
  ///   shows what the mode means, the List button says what each row is, and
  ///   [clearPending] is one tap away if the user disagrees.
  ///
  /// What it does **not** do is throw away explicit picks or forget a finished file.
  /// [listed] is the listing the page is showing; only items still waiting are
  /// reconsidered, and of those only the ones the new mode would never fetch.
  ///
  /// Returns a sentence describing what changed, or null when the mode was already
  /// the one asked for.
  String? reinterpret(SyncMode m, List<AlbumFile> listed) {
    final was = _mode;
    if (was == m) return null;
    mode = m;

    // --- an automatic mode delivers the listing
    //
    // `onlyNew: false` on purpose: the ledger filter would skip a shot whose
    // *original* is already here, which is right for a browse and wrong for a mode
    // change, because the JPEG of a RAW+JPEG shot and the RAW of it are separate
    // assets with separate fates, and an item whose only outstanding asset is the
    // RAW must not be skipped. It costs nothing when it is wrong: `_process`
    // settles an item whose original is already on the phone without a request.
    var added = 0;
    if (m != SyncMode.manualOnly) added = enqueue(listed, onlyNew: false);

    // --- "full size only" means the preview pass is not this list's job
    //
    // These items are not lost work: a preview is already on the phone, so the shot
    // is still viewable and shareable, and switching back re-derives them.
    var dropped = 0;
    if (m == SyncMode.autoOriginalOnly) {
      final previewOnly =
          _items.where((i) => _isOutstanding(i) && !i.quality.isOriginal).toList();
      for (final i in previewOnly) {
        if (i.file.isRaw) continue; // a RAW is always fetched at full size
        if (!i.quality.isAtLeastPreview) continue; // still needs its first fetch
        removeItem(i);
        dropped++;
      }
    }

    if (added > 0 || dropped > 0) {
      onQueueChanged?.call();
      onChanged?.call();
    }

    final parts = <String>[
      if (added > 0) 'queued $added more',
      if (dropped > 0) 'dropped $dropped already previewed',
    ];
    final what = parts.isEmpty ? 'the list is unchanged' : parts.join(', ');
    _log('mode ${was.name} -> ${m.name}: $what');
    return 'Sync mode set to ${_modeLabel(m)} — $what.';
  }

  static String _modeLabel(SyncMode m) => switch (m) {
        SyncMode.autoPreviewThenOriginal => 'preview first, then full size',
        SyncMode.autoOriginalOnly => 'full size only',
        SyncMode.manualOnly => 'manual',
      };

  /// Forget queued work for files that are no longer on the card.
  ///
  /// Called after a delete on the camera (T17). Every remaining form of that
  /// item now fails: `GetFile` on a deleted path answers with an error the engine
  /// can only classify as a stall, so the item would burn three retries and three
  /// backoffs and then sit in the queue as `failed` — a permanent error row for a
  /// photo the user deliberately removed. The queue record goes with it, or the
  /// same item comes back on the next launch.
  ///
  /// Returns how many items were dropped.
  int dropPaths(Set<String> paths) {
    if (paths.isEmpty) return 0;
    final removed = _items.where((i) => paths.contains(i.file.path)).toList();
    if (removed.isEmpty) return 0;
    _items.removeWhere((i) => paths.contains(i.file.path));
    for (final i in removed) {
      // The *whole record*, not just the named asset: a RAW+JPEG shot is one
      // record, and deleting the JPEG on the camera deletes its RAW too, so
      // retiring only the JPEG would leave the RAW queued as work that can never
      // succeed.
      queue?.drop(i.id.path, i.id.dateSeconds);
    }
    _log('dropped ${removed.length} queued item(s) that were deleted on the camera');
    onQueueChanged?.call();
    onChanged?.call();
    return removed.length;
  }

  /// Run the queue to completion, or until paused or the camera leaves.
  ///
  /// Safe to call repeatedly: a run already in progress is not duplicated.
  Future<void> run() async {
    if (_running || _paused || !_cameraPresent) return;
    _running = true;
    onChanged?.call();

    try {
      // --- pause the preview for the whole bulk run (§5.3)
      //
      // Before the *first* transfer and released after the *last*, rather than
      // per file: a pause/resume pair per photo would put the stream back into
      // competition between every item, which is most of the cost of having it
      // running at all. Nothing is paused when there is nothing to transfer, so a
      // run that finds the queue already drained cannot blink the preview.
      if (_hasPendingWork) await beginStreamHold();

      try {
        var index = 0;
        while (index < _items.length) {
          if (_paused) break;
          if (!_cameraPresent) break;

          final item = _items[index];
          // A shot the user struck out of the queue is done with, whatever its
          // stage says: it is skipped rather than processed, and this is the
          // backstop for the in-flight case, where `_process` is already running
          // for an item the user has since removed. The backoff below is skipped
          // with it — there is nothing to wait for.
          if (item.removed) {
            _items.removeAt(index);
            continue;
          }
          if (item.stage.isTerminal) {
            index++;
            continue;
          }

          final ok = await _process(item);
          // Persist the *terminal* outcome of every item, not just at the end of
          // the run: a swipe-away or an OS kill lands in the middle of a 200-shot
          // backlog, and an outcome held only in memory until the queue drains is
          // exactly the loss the durable queue exists to prevent. Progress within
          // an item is not written per item, because the queue is bounded but a
          // 1290-file card is not: that would be a full rewrite of the file per
          // file, in the middle of the transfer path, for a record the ledger
          // already carries.
          if (item.stage.isTerminal) await queue?.save();
          // A stalled or failed item is retried up to a bounded number of times,
          // then surfaced. Infinite invisible retries are how a queue silently
          // never finishes.
          if (ok || item.attempts >= 3) {
            index++;
          } else {
            await Future<void>.delayed(_backoff(item.attempts));
          }
        }
      } finally {
        // `finally`, not a happy-path resume, because every way out of the loop
        // above — a throw from a transfer, a pause, the camera vanishing, or the
        // whole future being abandoned — has to put the preview back. This is the
        // register the design guide warns about: a client that pauses the stream
        // and never resumes has left its own user with a frozen view.
        await endStreamHold();
      }
    } finally {
      _running = false;
      await _syncQueue();
      await ledger.save();
      onChanged?.call();
    }
  }

  /// Write the engine's items back into the durable queue.
  ///
  /// An asset the engine has finished is **removed from its record**: it is done,
  /// so keeping it would grow the queue file without bound and would re-offer
  /// finished work at the next launch. Its RAW sibling stays behind, because in a
  /// pair the JPEG lands first (§5.4) and the RAW is still outstanding.
  Future<void> _syncQueue() async {
    final q = queue;
    if (q == null) return;

    var changed = false;
    for (final i in _items) {
      // Removed items are not written back at all. Without this the user's
      // cancellation is **undone a moment later**: appending the item is exactly
      // what this method is for, so a record the user deleted would be re-created
      // by the engine's own bookkeeping and be waiting at the next launch.
      // `removeItem` has already taken it out of the queue.
      if (i.removed) continue;
      if (i.stage == SyncStage.done) {
        changed = q.markDone(i.id.path, i.id.dateSeconds) || changed;
        continue;
      }
      // Failed items are deliberately left queued: the card is still the only
      // copy, and a failed item that vanished at the next launch would lose the
      // user's intent silently. Keeping it costs one bounded record.
      changed = q.mergeQuality(i.id.path, i.id.dateSeconds, i.quality) || changed;
    }
    if (changed) onQueueChanged?.call();
    await q.save();
  }

  Duration _backoff(int attempt) =>
      Duration(milliseconds: (500 * (1 << attempt)).clamp(500, 8000));

  /// Bring one item to the quality its stage calls for.
  ///
  /// Returns true when the item reached a terminal state.
  Future<bool> _process(SyncItem item) async {
    final a = album();

    // --- already have it, so nothing is left to fetch
    //
    // Settled **before** any request, because the whole point of the durable ledger
    // is that a file already on the phone is never fetched again. A re-derived list
    // puts these back in front of the engine on purpose — a mode change has to be
    // able to show the user what it means, and the answer for an already-saved shot
    // is "nothing", which must be reached without asking the camera.
    if (item.quality.isOriginal) {
      item.stage = SyncStage.done;
      item.error = null;
      onChanged?.call();
      return true;
    }

    // --- preview pass
    //
    // Three reasons it does not run, and each has its own paragraph:
    //
    // 1. **Never for a RAW.** Measured against the real camera (`analysis/50`): a
    //    `.DNG` answers `204` with a zero-byte body at `Thumbnail` and **`404`** at
    //    `MidThumb` — those are "I cannot produce that resolution", not "no such
    //    file". A `404` is classified as a stall, so a RAW given a preview pass
    //    would burn its retries and never reach the file itself. `Original` answers
    //    `200` with the full ~32 MB DNG, so a RAW is fetched exactly once and at
    //    full size. That is also the right shape for the user: a RAW is not a
    //    picture anyone previews, and in a RAW+JPEG shot the JPEG half is what
    //    appears first, which is the ordering the pair is designed around.
    // 2. **Not in full-size-only mode**, which says the only thing a run produces is
    //    the real file.
    // 3. **Not when the phone already has the preview** — same reason as the ledger
    //    guard above: it is already there, and re-fetching it would be the double
    //    download the preview-first design exists to avoid.
    final wantsPreview =
        _mode == SyncMode.autoPreviewThenOriginal && !item.file.isRaw;

    if (wantsPreview && !item.quality.isAtLeastPreview) {
      item.stage = SyncStage.downloadingPreview;
      item.bytesReceived = 0;
      onChanged?.call();

      final preview = await _fetch(item, FileResolution.midThumb, a);
      if (preview == null) return false;

      // The user struck this shot out of the queue while the request was on the
      // wire. The bytes are in memory and are **dropped here**: nothing is
      // published, the ledger records nothing, and the item does not come back on
      // the next launch. The request is allowed to finish because recalling it would
      // mean sending another command to a camera with no watchdog — see
      // `SyncItem.removed`.
      if (item.removed) {
        item.stage = SyncStage.queued;
        onChanged?.call();
        return false;
      }

      final String previewUri;
      try {
        previewUri = await sink.store(
          assetKey: item.id.key,
          fileName: item.file.fileName,
          bytes: _forGallery(preview, item.file.captureTime),
          capturedAt: item.file.captureTime,
          quality: AssetQuality.preview,
        );
      } on Object catch (e) {
        item.error = 'could not publish preview to the phone gallery: $e';
        item.stage = item.attempts >= 3 ? SyncStage.failed : SyncStage.queued;
        onChanged?.call();
        return false;
      }
      item.quality = AssetQuality.preview;
      // Record *where* it went, not just that it arrived. Without the local
      // identifier the album can display a photo it cannot open or share, which
      // is how the share feature was missing entirely.
      ledger.recordLocal(item.id, AssetQuality.preview, previewUri);
      // Persist straight away: the whole promise of preview-first is that the
      // user sees everything within seconds, and that is worthless if a crash
      // loses the record and re-downloads it all. The queue is written with it,
      // so a preview that is already on the phone is never re-fetched — that
      // re-fetch is the expensive, most visible failure of a lost queue.
      await ledger.save();
      await _syncQueue();
      onChanged?.call();
    }

    // --- original pass
    item.stage = SyncStage.downloadingOriginal;
    item.bytesReceived = 0;
    onChanged?.call();

    final original = await _fetch(item, FileResolution.original, a);
    if (item.removed) {
      // Same rule as the preview: the reply is discarded rather than published.
      // Checked before the null test on purpose — a removed item that also failed is
      // not a retry candidate, it is gone.
      item.stage = SyncStage.queued;
      onChanged?.call();
      return false;
    }
    if (original == null) {
      // Never silently downgrade: the preview stays, but the item is not
      // "done" and the failure is visible.
      item.stage = item.attempts >= 3 ? SyncStage.failed : SyncStage.queued;
      onChanged?.call();
      return false;
    }

    final String originalUri;
    try {
      final published = stampExifWallClock(original, item.file.captureTime);
      if (!published.changed &&
          item.file.captureTime != null &&
          _looksLikeJpeg(item.file)) {
        // The one failure of this step that is otherwise **invisible**: the app's
        // own grid, the ledger and the MediaStore columns all look right whether
        // the capture instant survived into the file or not, and only a gallery
        // reading the photo's metadata can tell. Same reasoning as the sink's
        // `[media]` line, and the same class of silence that let the eight-hour
        // offset ship: `asset_sink.dart` keeps that line for exactly this.
        _log('${item.name}: ${published.note} — a gallery will date this from the '
            'row, not from the file');
      }
      originalUri = await sink.store(
        assetKey: item.id.key,
        fileName: item.file.fileName,
        bytes: published.bytes,
        capturedAt: item.file.captureTime,
        quality: AssetQuality.original,
      );
    } on Object catch (e) {
      item.error = 'could not publish to the phone gallery: $e';
      item.stage = item.attempts >= 3 ? SyncStage.failed : SyncStage.queued;
      onChanged?.call();
      return false;
    }
    item.quality = AssetQuality.original;
    item.stage = SyncStage.done;
    item.error = null;
    ledger.recordLocal(item.id, AssetQuality.original, originalUri);
    await ledger.save();
    // The item is done, so it leaves the queue here rather than at the end of
    // the run: an app kill immediately after this transfer must not bring it
    // back as pending work.
    await _syncQueue();
    onChanged?.call();
    return true;
  }

  /// Fetch one rendition, with stall detection and integrity checking.
  ///
  /// Returns null on failure, having recorded a named stage on [item].
  /// The byte count at the last progress notification, or -1 when none has gone out.
  ///
  /// **A local inside [_fetch], reached through a closure, and deliberately not a field.**
  Future<Uint8List?> _fetch(
      SyncItem item, FileResolution res, CameraAlbum a) async {
    item.attempts++;
    item.error = null;
    // A local, reached by the closure below.
    //
    // **Not a field**, and that is not a style choice: the engine explicitly supports two
    // runs overlapping — `_streamHoldDepth` is counted *because* "the durable queue resumes
    // a transfer that a reconnect restarted". A field shared across transfers would make
    // the second item's first `onProgress` compute its delta against the first item's final
    // byte count, and report **nothing** until it had caught up. Caught in review rather
    // than by a test: `tool/verify_sync.dart`'s download override reports its size once per
    // call, so the throttled branch is not reached from a desk test at all.
    //
    // Reset per attempt, so a resumed fetch does not inherit the previous attempt's count.
    int lastReported = -1;

    try {
      final bytes = await a.download(
        item.file,
        resolution: res,
        onProgress: (n) {
          item.bytesReceived = n;
          // Throttle notifications: a 9 MB file arrives in many chunks and repainting per
          // chunk is wasted work.
          //
          // ## The condition this replaced, and what it actually did
          //
          // It was `if (n % (256 * 1024) < 8192) onChanged?.call();` — a **modulo** test,
          // not a delta. That fires only when the byte count happens to land inside an
          // 8 KB window at each 256 KB boundary, which means:
          //
          //   * nothing is reported for the **first 256 KB**, so a slow link shows a
          //     progress bar that has not moved at all — reported by the user as "the
          //     progress bar does not update";
          //   * and it depends on the chunk sizes the camera happens to use, so a
          //     connection whose chunks never land in the window reports **nothing at
          //     all**, for the whole transfer.
          //
          // The intent was "no more than one notification per 256 KB". That is a delta
          // between successive reports, which is what this now compares — and the first
          // report always goes out, so progress is visible from the first chunk.
          final since = n - lastReported;
          if (lastReported < 0 || since >= 256 * 1024) {
            lastReported = n;
            onChanged?.call();
          }
        },
      );

      if (bytes.isEmpty) {
        item.error = 'the camera sent no data';
        item.stage = SyncStage.stalled;
        return null;
      }

      // Cheap integrity check that actually catches this camera's most likely
      // corruption: a truncated response. Every JPEG must end with EOI.
      if (_looksLikeJpeg(item.file) && !_endsWithEoi(bytes)) {
        item.error = 'truncated image (missing end-of-image marker)';
        item.stage = SyncStage.stalled;
        _log('${item.name}: ${item.error} — retrying');
        return null;
      }

      return bytes;
    } on CameraHttpException catch (e) {
      item.error = e.message;
      item.stage = e.isBadParameters ? SyncStage.failed : SyncStage.stalled;
      return null;
    } on AlbumException catch (e) {
      item.error = e.message;
      // A path the firmware cannot accept will never succeed; do not burn
      // retries on it.
      item.stage =
          item.file.isPathTooLong ? SyncStage.failed : SyncStage.stalled;
      return null;
    } on Object catch (e) {
      item.error = '$e';
      item.stage = SyncStage.stalled;
      return null;
    }
  }

  static bool _looksLikeJpeg(AlbumFile f) {
    final p = f.path.toUpperCase();
    return p.endsWith('.JPG') || p.endsWith('.JPEG');
  }

  /// The bytes to hand the sink for one rendition.
  ///
  /// Everything the app publishes to the phone's gallery goes through here, so that
  /// *every* rendition of a shot carries the same capture instant — the preview and
  /// the full-size file both appear in the gallery, and two files for one shutter
  /// press that disagree about when it happened is its own defect.
  ///
  /// What it corrects is the date **inside the file**: the camera writes a naive
  /// local wall clock with no zone, from a clock that has no zone either, and a
  /// gallery reads it in the zone of the phone. The capture instant the app
  /// displays is the reference, so the file is made to agree with it. The full
  /// account, the evidence, and the bounds on what may be overwritten are in
  /// `exif_wall_clock.dart` — this call site deliberately holds none of it.
  ///
  /// The bytes are otherwise the camera's own, byte for byte: nothing is decoded,
  /// re-encoded or resized, and the transform cannot change the file's length.
  static Uint8List _forGallery(Uint8List bytes, DateTime? capturedAt) =>
      stampExifWallClock(bytes, capturedAt).bytes;

  /// Every JPEG ends with `FF D9`.  Two bytes, and it catches the failure mode
  /// that matters: a truncated response.
  static bool _endsWithEoi(Uint8List b) =>
      b.length >= 2 && b[b.length - 2] == 0xFF && b[b.length - 1] == 0xD9;
}
