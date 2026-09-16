import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../l10n/message_text.dart';
import '../../protocol/camera_state.dart';
import '../../protocol/http_params.dart';
import '../../state/app_state.dart';
import '../../transport/http_transport.dart';

/// Remote video recording: the capability the official app does not have.
///
/// The firmware dispatches **14 video commands** and the official YI app sends
/// none of them — it can only take stills from the phone, which is the single
/// largest gap this project exists to close (`analysis/ce-app-competitive-spec.md`
/// §1.6, §D5). Everything on this page is one of those commands.
///
/// ## What the camera can and cannot tell us
///
/// Every live-view frame carries a JSON snapshot of the camera state, and that
/// snapshot includes `VideoFormat`, `VASwitch`, `VAVol`, `VANR` and `VideoEis`.
/// It does **not** include whether a recording is in progress. So:
///
/// * the five video settings are rendered **from the stream**, never from the
///   value the user just picked. This firmware answers `200` to commands it
///   silently ignores, so a local optimistic update would show a setting the
///   camera never took;
/// * **recording is tracked locally**, because there is nowhere else to track
///   it. That is an honest approximation and is labelled as one on screen. It
///   also means the app forgets a running recording when this page is closed:
///   the camera keeps recording, and the next open shows Idle until the next
///   start, which is why the state is presented as the app's own observation
///   rather than as the camera's.
///
/// ## Why every control is serialised
///
/// The camera has **no watchdog**. A command it does not expect can wedge it
/// until the battery is pulled, and the observed precursor is a burst of
/// requests, not a single one. So one control action is in flight at a time, and
/// the rest of the page is disabled until the camera has answered.
///
/// ## Why the caution is not optional
///
/// `VideoRecordingStart`/`Stop` and `RCVideoFormatSet` were accepted by a real
/// camera, but the project's checklist still has the **SD-card write** awaiting
/// manual confirmation (`app/docs/HARDWARE-VERIFICATION.md:14`). The four video
/// *quality* commands were verified only structurally, from the firmware's
/// dispatch table — and a pool read that way once listed `720P_120`, which the
/// hardware answered with a 404. A user has to be told that before they trip over
/// it, not after, so the page opens on an acknowledgement and keeps the warning
/// on screen until it has been given.
class VideoPage extends StatefulWidget {
  final AppState app;
  const VideoPage({super.key, required this.app});

  @override
  State<VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<VideoPage> {
  /// The firmware's keys are *not* uniform between commands, which is why the
  /// key is stored next to the command rather than derived from its name:
  /// `RCVideoFormatSet` takes `Resolution`, `RCVAVolSet` takes `Vol`, and the
  /// three switch commands take `Operation`.
  ///
  /// Evidence (each key seen as a literal next to its handler):
  /// * `Resolution` — `analysis/10-handler-request-params.md:86`, and
  ///   `analysis/http_param_values.json` lists it in the firmware pool that
  ///   `app/lib/transport/http_transport.dart:180` already uses.
  /// * `Operation` — inline in the `RCVASwitchSet` handler,
  ///   `analysis/handler_args.json:362-365`, corroborated by
  ///   `analysis/10-handler-request-params.md:101`.
  /// * `Vol` — `analysis/handler_params.json:882-892` (the `RCVAVolSet` handler's
  ///   own pool) and `analysis/10-handler-request-params.md:99`.
  ///
  /// `Operation` and `Vol` are **single-source** for `RCVANoiseReduceSet`,
  /// `RCEisSwitchSet` and `RCVAVolSet`; that is exactly why the whole family is
  /// behind the acknowledgement gate below.
  static const Map<String, String> videoParamKeys = {
    'RCVideoFormatSet': 'Resolution',
    'RCEisSwitchSet': 'Operation',
    'RCVANoiseReduceSet': 'Operation',
    'RCVASwitchSet': 'Operation',
    'RCVAVolSet': 'Vol',
  };

  /// The two audio-switch values the firmware's own capability table carries:
  /// `ON` and `OFF` sit immediately after the `VASwitch` name at
  /// `text:0x1520E4`-`0x1520F4` (`analysis/mod-research-video.md:268-293`), and the
  /// live-view snapshot renders the field the way it was set — the reference
  /// dump has `"VASwitch":"ON"` (`app/capture_test/lv_state.json`).
  static const String _on = 'ON';
  static const String _off = 'OFF';

  /// Recording formats, transcribed from the firmware's **literal pool**
  /// (`analysis/http_param_values.json`, `firmware_literal_values`) rather than
  /// invented here, and cross-listed in `analysis/ce-app-competitive-spec.md:183`
  /// and `analysis/MOD-PROPOSAL.md:49`.
  ///
  /// Two facts this list carries, both learned the hard way:
  ///
  /// * `720P_120` is deliberately **absent**. It is not in the firmware pool at
  ///   all, and a real camera answered it with a 404
  ///   (`build/verify_http3.txt:29`). A value that is not in the pool is not a
  ///   format the camera has, however plausible it looks.
  /// * The pool is shared across bodies, so acceptance is only *observed* for
  ///   the entries marked [VideoFormatOption.observed] — those returned
  ///   `{"code":200}` from a real M1 (`build/verify_http3.txt:21-31`). The rest
  ///   stay in the list but are labelled, because a 200 on this firmware proves
  ///   only that the value parsed: the stream's `VideoFormat` field is what
  ///   finally settles whether the camera adopted it.
  static const List<VideoFormatOption> kVideoFormats = [
    VideoFormatOption('4K_30', observed: true),
    VideoFormatOption('4K_24', observed: true),
    VideoFormatOption('4K_30_LOW', observed: true),
    VideoFormatOption('2K_30', observed: true),
    VideoFormatOption('2880_24', observed: true),
    VideoFormatOption('1920_24'),
    VideoFormatOption('FHD_60', observed: true),
    VideoFormatOption('FHD_30', observed: true),
    VideoFormatOption('FHD_24'),
    VideoFormatOption('720P_60', observed: true),
    VideoFormatOption('720P_30'),
    VideoFormatOption('720P_24'),
    VideoFormatOption('VGA_240', observed: true),
  ];

  /// True while a command is in flight.
  ///
  /// The camera is single-threaded and has no watchdog, so the next request is
  /// not sent until the previous one has been answered.
  bool _busy = false;

  /// The last command failure, surfaced in [_MessageStrip].
  ///
  /// `AppState.send` keeps its own `lastError`, but it cannot be used here: the
  /// commands this page needs are the ones the transport layer already models
  /// with their correct parameter keys and values (`videoStart`, `videoStop`,
  /// `setVideoFormat`), and going around those wrappers to hand-build the same
  /// JSON is how a key gets spelled wrong and silently becomes a 404. So the page
  /// calls the wrappers and reports their failures itself.
  String? _error;

  /// Recording state, tracked locally because the stream does not carry it.
  bool _recording = false;
  Timer? _recordingTicker;
  int _recordingSeconds = 0;

  /// The format the user last asked for, and the value the camera was reporting
  /// when they asked.
  ///
  /// The second one is what makes an *unconfirmed* change detectable at all. The
  /// stream carries no request id and no pending flag: the only way to know that
  /// `RCVideoFormatSet` was ignored is that `VideoFormat` still reads what it
  /// read before the request. Comparing against a stored baseline also survives
  /// the case that defeats a naive "requested != reported" test — changing away
  /// and back, where the camera's value ends up equal to the request while the
  /// request was never applied.
  String? _formatRequested;
  String? _formatWasReported;

  /// True while the camera has not shown the requested format.
  bool get formatPending {
    final requested = _formatRequested;
    if (requested == null) return false;
    return state?.videoFormat == _formatWasReported;
  }

  /// The user has seen the hardware caveat and asked to continue.
  bool _acknowledged = false;

  /// The caveat has been put on screen once, whichever button was pressed.
  ///
  /// ## The bug this fixes
  ///
  /// Auto-showing was guarded by `!_acknowledged`, and "Not now" leaves
  /// `_acknowledged` false — deliberately, because it is not an acknowledgement. The
  /// result was that popping the dialog rebuilt the page, the guard passed again, and
  /// the dialog was **immediately re-shown**. To the user "Not now" did nothing at
  /// all: the dialog was still there.
  ///
  /// Dismissing and acknowledging are different decisions and need different flags.
  /// "Not now" means "do not put this in front of me again"; the app bar's
  /// "What is verified?" button is how it is deliberately re-read, which is what the
  /// comment below has always claimed.
  bool _cautionShown = false;

  AppState get app => widget.app;

  CameraState? get state => app.cameraState;

  @override
  void dispose() {
    _recordingTicker?.cancel();
    super.dispose();
  }

  /// Whether remote commands will be accepted at all.
  ///
  /// `RCStartRemoteCtl` is what puts the camera in remote mode, and a command
  /// sent outside it is refused with `{"code":1000}`. The link's own
  /// `previewRunning` flag is the only reliable statement that remote mode is
  /// live, so it gates the whole page rather than being discovered by failure.
  ///
  /// Takes the strings rather than a `BuildContext`: it is read from `build`,
  /// which already holds [l], and a `get` on a `State` that reached for
  /// `context` on its own would be the same value fetched twice.
  String? blockedReason(AppLocalizations l) {
    if (!app.link.isReady) return l.videoNotConnected;
    if (!app.link.previewRunning) {
      return l.videoStartPreviewFirst;
    }
    return null;
  }

  // ----------------------------------------------------------------- commands

  /// Send one command and report the outcome in the page.
  ///
  /// Success is **not** inferred from a 200: this firmware answers 200 to
  /// commands it ignores, so the stream's state JSON is the real confirmation
  /// and the readout at the top of the page is where it shows up.
  ///
  /// [l] is the strings the caller is displaying, so the failure it writes is in
  /// the language the page is in; [label] is the command's own name (or the
  /// action's, for the two recording commands) and is interpolated verbatim.
  Future<bool> _request(AppLocalizations l, String label,
      Future<CameraResponse> Function() run) async {
    try {
      final r = await run();
      if (!r.ok) {
        setState(() {
          _error = r.code == 1000
              // The camera's own words for "not in remote mode": it refuses the
              // whole RC surface with 1000, and the fix is to restart the preview
              // rather than to retry the command.
              ? l.videoRefusedNotRemote(label)
              : l.videoFailed(label, '${r.data ?? r.raw}');
        });
        return false;
      }
      return true;
    } on CameraHttpException catch (e) {
      setState(() {
        _error = e.isBadParameters
            ? l.videoRejected404(label)
            : l.videoFailed(label, e.message);
      });
      return false;
    } on Object catch (e) {
      // Anything the transport did not wrap still has to surface here: an
      // uncaught error in a button callback leaves the control looking pressed
      // and dead, which is the failure this page exists to avoid.
      if (mounted) setState(() => _error = l.videoFailed(label, '$e'));
      return false;
    }
  }

  /// Record start/stop, through the transport's own wrappers.
  ///
  /// The camera refuses a recording outside remote mode and can lose remote mode
  /// without saying so, so a refusal is reported rather than swallowed.
  Future<bool> _setRecording(bool start, AppLocalizations l) => _serialised(
        () => start
            ? _request(l, l.videoStartRecording, app.connection.http.videoStart)
            : _request(l, l.videoStopRecording, app.connection.http.videoStop),
      );

  /// The four video parameters, each with the firmware's own key for it.
  Future<bool> _sendParam(String command, String value, AppLocalizations l) {
    final key = videoParamKeys[command];
    if (key == null) {
      // A programming error, not a user-facing failure: inventing a key would
      // make the camera answer 404 for a command that does exist.
      throw ArgumentError('$command is not a video parameter command');
    }
    return _serialised(
      () => _request(
          // The label stays the command's own name: it is a wire identifier, not
          // prose, so there is nothing to translate — and a failure that names the
          // command is the one a bug report can act on.
          l,
          command,
          () => app.connection.http
              .send(command, <String, Object>{key: value})),
    );
  }

  /// Run one command at a time.
  ///
  /// Serialisation is not politeness: the observed way to strand this firmware's
  /// capture state machine is to send it a second request while it is still
  /// working on the first, and there is no watchdog to recover it.
  Future<bool> _serialised(Future<bool> Function() run) async {
    if (_busy) return false;
    setState(() => _busy = true);
    try {
      return await run();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Format changes are refused outright while recording.
  ///
  /// The camera answers with the format it is currently encoding, so a mid-clip
  /// change either does nothing or produces a clip the user did not ask for.
  /// Refusing is the only honest option, and the reason is shown on the control
  /// rather than left to be guessed.
  Future<void> _setFormat(String format, AppLocalizations l) async {
    final was = state?.videoFormat ?? '';
    final ok = await _serialised(
      () => _request(l, l.videoChangeFormat,
          () => app.connection.http.setVideoFormat(format)),
    );
    if (!mounted || !ok) return;
    setState(() {
      _formatRequested = format;
      _formatWasReported = was;
    });
  }

  Future<void> _toggleRecording(AppLocalizations l) async {
    final start = !_recording;
    final ok = await _setRecording(start, l);
    if (!mounted) return;

    // The recording flag flips only on the camera's own acknowledgement. A
    // refused start leaves the button in its idle state and the error strip
    // explains why — claiming to record when the camera said no is the worst
    // possible outcome for a control whose whole purpose is to be trusted.
    if (!ok) return;
    setState(() {
      _recording = start;
      _recordingSeconds = 0;
    });
    _recordingTicker?.cancel();
    if (start) {
      // A local clock, because the camera reports nothing about recording. If
      // the app loses the link mid-clip this keeps running, so it is presented
      // as elapsed time since the last acknowledged start, not as the camera's
      // own timer.
      _recordingTicker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() => _recordingSeconds++);
      });
    } else {
      _recordingTicker = null;
    }
  }

  /// The acknowledgement gate.
  ///
  /// What this page sends is *not* uniformly verified, and the split matters to
  /// the person pressing the button:
  ///
  /// * `VideoRecordingStart`/`Stop` and `RCVideoFormatSet` were sent to a real
  ///   camera and came back `code:200` (`app/docs/HARDWARE-VERIFICATION.md:14`),
  ///   but the project's own checklist still has the **SD-card write** as
  ///   awaiting manual confirmation — so "the camera accepted it" is not the same
  ///   claim as "there is a clip on the card";
  /// * the four video-quality commands were only verified *structurally*, from
  ///   the firmware's dispatch table, and this project has already been wrong
  ///   once in exactly that way: a value pool listed `720P_120`, and the real
  ///   camera answered 404.
  ///
  /// The gate names that split, and warns about the failure mode the user would
  /// otherwise blame on the app.
  Future<void> _showCaution() async {
    // Read before the first `await`, while this `State`'s `context` is certainly
    // still in the tree: the dialog outlives the synchronous part of this method.
    final l = l10nOf(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.videoCautionTitle),
        // `scrollable` because the warning is longer than a landscape window.
        //
        // Without it the third paragraph was **cut off mid-sentence** on a 914x411
        // screen — "…until the battery is" and no more — with no way to scroll to the
        // rest. A disclosure whose whole purpose is to state the battery-pull risk
        // before the user sends unverified commands to a camera with no watchdog must
        // be readable in every orientation; a clipped one is worse than none, because
        // it looks like it said everything.
        scrollable: true,
        content: Text(l.videoCautionBody),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(l.videoNotNow)),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(l.videoUnderstandContinue)),
        ],
      ),
    );
    if (!mounted) return;
    setState(() => _acknowledged = confirmed == true);
  }

  // -------------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final blocked = blockedReason(l);

    // Asked once, on the first frame in which the gear is usable, rather than in
    // initState: until the link is ready there is nothing to warn about, and a
    // dialog racing the connect flow would be dismissed before it was read.
    //
    // `_cautionShown`, not `_acknowledged` — see the field. Guarding on the
    // acknowledgement is what made "Not now" a no-op.
    if (blocked == null && !_cautionShown && !_cautionPending) {
      _cautionPending = true;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        _cautionPending = false;
        if (!mounted || _cautionShown) return;
        // Set **before** awaiting, so the rebuild that the dialog's own appearance
        // triggers cannot queue a second copy of it.
        _cautionShown = true;
        await _showCaution();
      });
    }

    return Scaffold(
      backgroundColor: const Color(0xFF0E0E0E),
      appBar: AppBar(
        backgroundColor: const Color(0xFF151515),
        foregroundColor: Colors.white,
        title: Text(l.videoPageTitle, style: const TextStyle(fontSize: 16)),
        actions: [
          // Always re-readable: the caveat is a fact about the hardware, so a
          // user who dismissed it and then sees something strange must be able
          // to get it back without restarting the app.
          IconButton(
            tooltip: l.videoWhatIsVerified,
            onPressed: _showCaution,
            icon: const Icon(Icons.report_gmailerrorred),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          if (!_acknowledged)
            const KeyedSubtree(
              key: ValueKey<String>('banner-video-caution'),
              child: _CautionBanner(),
            ),
          _MessageStrip(error: _error, app: app),
          _StateReadout(
            state: state,
            requestedFormat: formatPending ? _formatRequested : null,
          ),
          if (blocked != null)
            _BlockedNotice(reason: blocked)
          else
            _RecordPanel(
              recording: _recording,
              busy: _busy,
              seconds: _recordingSeconds,
              onToggle: () => _toggleRecording(l),
            ),
          const Divider(height: 1, color: Colors.white12),
          _SectionLabel(
            l.videoRecordingFormat,
            note: l.videoFormatBlockedNote,
          ),
          _FormatPicker(
            state: state,
            requested: formatPending ? _formatRequested : null,
            // No reason to expose the picker before remote mode: the command
            // would be refused, and a control that cannot work is worse than an
            // absent one.
            enabled: blocked == null && !_recording && !_busy,
            disabledReason: blocked != null
                ? l.videoUnavailableUntilPreview
                : _recording
                    ? l.videoStopRecordingFirst
                    : null,
            onChanged: (f) => _setFormat(f, l),
          ),
          const Divider(height: 1, color: Colors.white12),
          _SectionLabel(l.videoVideoQuality),
          _SwitchRow(
            label: l.videoElectronicStabilisation,
            command: 'RCEisSwitchSet',
            reported: state?.videoEis ?? '',
            busy: _busy,
            enabled: blocked == null,
            onSet: (on) => _sendParam('RCEisSwitchSet', on ? _on : _off, l),
          ),
          _SwitchRow(
            label: l.videoNoiseReduction,
            command: 'RCVANoiseReduceSet',
            reported: state?.videoNoiseReduction ?? '',
            busy: _busy,
            enabled: blocked == null,
            onSet: (on) => _sendParam('RCVANoiseReduceSet', on ? _on : _off, l),
          ),
          const Divider(height: 1, color: Colors.white12),
          _SectionLabel(l.videoAudio),
          _SwitchRow(
            label: l.videoRecordAudio,
            command: 'RCVASwitchSet',
            reported: state?.videoAudioSwitch ?? '',
            busy: _busy,
            enabled: blocked == null,
            onSet: (on) => _sendParam('RCVASwitchSet', on ? _on : _off, l),
          ),
          _VolumeRow(
            reported: state?.videoAudioVolume ?? '',
            busy: _busy,
            enabled: blocked == null,
            onSet: (v) => _sendParam('RCVAVolSet', '$v', l),
          ),
        ],
      ),
    );
  }

  /// Guards against pushing the caution dialog more than once; a rebuild
  /// happened between the tap and the dialog's own frame.
  bool _cautionPending = false;
}

/// One recording format from the firmware's pool.
class VideoFormatOption {
  final String value;

  /// True when this project has seen a real M1 answer `200` for it
  /// (`build/verify_http3.txt`), as opposed to the value merely existing in the
  /// shared firmware pool. A 200 is not proof the camera *adopted* it — that is
  /// what the stream readout is for — but it does rule out a 404.
  final bool observed;

  const VideoFormatOption(this.value, {this.observed = false});
}

// ---------------------------------------------------------------------------

/// The five video fields, straight out of the live-view stream.
///
/// This block is the reason the page can be trusted at all: the firmware answers
/// `200` to commands it ignores, so "the camera is now in 4K_30" is only ever a
/// claim the *stream* can make. Where a value the user just set has not appeared
/// yet, the row says so instead of showing the requested value.
class _StateReadout extends StatelessWidget {
  final CameraState? state;

  /// The format a failed-by-silence change asked for, or null when the camera
  /// has confirmed everything the user asked of it.
  final String? requestedFormat;
  const _StateReadout({required this.state, required this.requestedFormat});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final s = state;
    if (s == null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Text(
          l.videoNoStateYet,
          style: const TextStyle(
              color: Colors.white54, fontSize: 12, height: 1.4),
        ),
      );
    }

    final pending = requestedFormat != null;

    return Container(
      color: const Color(0xFF141414),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l.videoReportedByCamera,
              style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 12,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          _row(l.videoRowFormat, s.videoFormat, pending: pending),
          _row(l.videoRowAudio, s.videoAudioSwitch),
          _row(l.videoRowVolume, s.videoAudioVolume),
          _row(l.videoRowNoiseReduction, s.videoNoiseReduction),
          _row(l.videoRowStabilisation, s.videoEis),
          if (pending)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                l.videoRequestedNotReported(requestedFormat!),
                style: const TextStyle(
                    color: Colors.orangeAccent, fontSize: 11.5, height: 1.35),
              ),
            ),
        ],
      ),
    );
  }

  Widget _row(String label, String value, {bool pending = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        children: [
          SizedBox(
            width: 130,
            child: Text(label,
                style: const TextStyle(color: Colors.white54, fontSize: 12.5)),
          ),
          Expanded(
            child: Text(
              value.isEmpty ? '—' : value,
              style: TextStyle(
                color: pending ? Colors.white38 : Colors.white,
                fontSize: 12.5,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The record button, its state, and its own local clock.
class _RecordPanel extends StatelessWidget {
  final bool recording;
  final bool busy;
  final int seconds;
  final Future<void> Function() onToggle;

  const _RecordPanel({
    required this.recording,
    required this.busy,
    required this.seconds,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);

    return Container(
      color: Colors.black,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      child: Column(
        children: [
          Row(
            children: [
              Icon(
                recording ? Icons.fiber_manual_record : Icons.videocam_outlined,
                color: recording ? Colors.redAccent : Colors.white54,
                size: 18,
              ),
              const SizedBox(width: 8),
              Text(
                recording ? l.videoRecordingIndicator : l.videoIdle,
                style: TextStyle(
                  color: recording ? Colors.redAccent : Colors.white70,
                  fontWeight: FontWeight.w700,
                  letterSpacing: recording ? 1.2 : 0,
                  fontSize: 13,
                ),
              ),
              const Spacer(),
              Text(
                _clock(seconds),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              key: const ValueKey<String>('btn-video-record'),
              onPressed: busy ? null : onToggle,
              icon: busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white54),
                    )
                  : Icon(recording ? Icons.stop : Icons.fiber_manual_record),
              label: Text(recording ? l.videoStopRecording : l.videoStartRecording),
              style: FilledButton.styleFrom(
                backgroundColor:
                    recording ? Colors.redAccent.shade700 : Colors.white,
                foregroundColor: recording ? Colors.white : Colors.black,
                disabledBackgroundColor: Colors.grey.shade800,
                disabledForegroundColor: Colors.white38,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            l.videoTimerNote,
            textAlign: TextAlign.center,
            style: const TextStyle(
                color: Colors.white38, fontSize: 11, height: 1.35),
          ),
        ],
      ),
    );
  }

  static String _clock(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    final mm = m.toString().padLeft(2, '0');
    final ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }
}

/// The format picker.
///
/// The selected value is the camera's, with the requested one shown separately
/// until the stream confirms it — a dropdown that jumps to the tapped value
/// would be lying about a setting the camera may have ignored.
class _FormatPicker extends StatelessWidget {
  final CameraState? state;
  final String? requested;
  final bool enabled;
  final String? disabledReason;
  final Future<void> Function(String) onChanged;

  const _FormatPicker({
    required this.state,
    required this.requested,
    required this.enabled,
    required this.disabledReason,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final current = state?.videoFormat ?? '';
    final known = _VideoPageState.kVideoFormats;
    final has = known.any((f) => f.value == current);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DropdownButton<String>(
            // The camera's value, with the requested one as a separate line
            // below rather than as the selection: a dropdown that jumps to the
            // tapped value would claim a setting the camera may have ignored.
            value: has ? current : null,
            isExpanded: true,
            hint: Text(current.isEmpty ? l.videoUnknown : current,
                style: const TextStyle(color: Colors.white)),
            dropdownColor: const Color(0xFF1E1E1E),
            style: TextStyle(
                color: enabled ? Colors.white : Colors.white38, fontSize: 13),
            key: const ValueKey<String>('btn-video-format'),
            onChanged: enabled
                ? (v) {
                    if (v != null && v != current) onChanged(v);
                  }
                : null,
            items: [
              // A format the camera reports that this list does not know is
              // still shown, so the control never claims a setting the camera is
              // not in.
              if (!has && current.isNotEmpty)
                DropdownMenuItem(value: current, child: Text(current)),
              ...known.map((f) => DropdownMenuItem(
                    value: f.value,
                    child: Row(
                      children: [
                        Text(f.value),
                        if (!f.observed) ...[
                          const SizedBox(width: 8),
                          Text(l.videoUnconfirmed,
                              style: const TextStyle(
                                  color: Colors.white38, fontSize: 10.5)),
                        ],
                      ],
                    ),
                  )),
            ],
          ),
          if (requested != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(l.videoRequestedWaiting(requested!),
                  style: const TextStyle(
                      color: Colors.orangeAccent, fontSize: 11.5)),
            ),
          if (disabledReason != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(disabledReason!,
                  style: const TextStyle(
                      color: Colors.orangeAccent, fontSize: 11.5, height: 1.35)),
            ),
          const SizedBox(height: 4),
          Text(
            l.videoFormatPoolNote,
            style: const TextStyle(
                color: Colors.white38, fontSize: 11, height: 1.35),
          ),
        ],
      ),
    );
  }
}

/// One on/off video flag.
///
/// The switch position comes from the **stream's** value, never from the tap, so
/// the control cannot show a state the camera never adopted. When the stream has
/// not reported the field at all the position is genuinely unknown, and the
/// subtitle says so instead of letting the switch's resting position imply
/// "off" — the flag is still settable in that state, because refusing to set a
/// value the camera has not echoed yet would leave the user with no way to turn
/// it on.
class _SwitchRow extends StatelessWidget {
  final String label;
  final String command;
  final String reported;
  final bool busy;
  final bool enabled;
  final Future<bool> Function(bool on) onSet;

  const _SwitchRow({
    required this.label,
    required this.command,
    required this.reported,
    required this.busy,
    required this.enabled,
    required this.onSet,
  });

  bool? get _value => switch (reported) {
        'ON' => true,
        'OFF' => false,
        _ => null,
      };

  /// The camera's echo of a two-state flag, in the reader's language.
  ///
  /// `ON`/`OFF` are **wire tokens**: they are what is sent (`_VideoPageState._on`
  /// / `_off`), what [_value] parses, and what the stream carries back. What the
  /// switch *shows* is prose about the camera — "开" under a translated label is
  /// readable, "ON" is not — so only the display goes through the lookup. A value
  /// that is neither token is shown exactly as the camera sent it, which is the
  /// same rule the format field follows.
  String _report(AppLocalizations l, String reported) => switch (reported) {
        _VideoPageState._on => l.videoOn,
        _VideoPageState._off => l.videoOff,
        _ => reported,
      };

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final v = _value;
    final canTap = enabled && !busy;

    return SwitchListTile(
      key: ValueKey<String>('toggle-video-${command.toLowerCase()}'),
      dense: true,
      value: v ?? false,
      onChanged: canTap ? (next) => onSet(next) : null,
      activeThumbColor: Colors.white,
      title: Text(label,
          style: TextStyle(
              color: canTap ? Colors.white70 : Colors.white38, fontSize: 13)),
      subtitle: Text(
        // The stream has not carried this field, which is not the same thing as
        // the flag being off — so it is said, not implied.
        reported.isEmpty
            ? l.videoStateNotReported
            : busy
                ? l.videoSending(command)
                : _report(l, reported),
        style: const TextStyle(color: Colors.white38, fontSize: 10.5),
      ),
    );
  }
}

/// The audio volume stepper.
class _VolumeRow extends StatelessWidget {
  final String reported;
  final bool busy;
  final bool enabled;
  final Future<bool> Function(int) onSet;

  const _VolumeRow({
    required this.reported,
    required this.busy,
    required this.enabled,
    required this.onSet,
  });

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final current = int.tryParse(reported);
    final canTap = enabled && !busy;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 130,
                child: Text(l.videoVolume,
                    style: const TextStyle(
                        color: Colors.white54, fontSize: 13)),
              ),
              Expanded(
                child: Wrap(
                  spacing: 8,
                  children: [
                    for (final v in kAudioVolumes)
                      ChoiceChip(
                        key: ValueKey<String>('chip-video-vol-$v'),
                        label: Text('$v'),
                        selected: current == v,
                        onSelected: canTap ? (_) => onSet(v) : null,
                        labelStyle: const TextStyle(fontSize: 12),
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            current == null
                ? l.videoNoVolumeYet
                : l.videoCameraReports('$current') +
                    (busy ? l.videoChangeInFlight : ''),
            style: const TextStyle(color: Colors.white38, fontSize: 10.5),
          ),
        ],
      ),
    );
  }
}

/// Shown when the page cannot command anything, with the reason.
///
/// The page is still worth opening in this state — it explains what it needs and
/// reads the camera's video fields — so it is a notice rather than an empty
/// screen.
class _BlockedNotice extends StatelessWidget {
  final String reason;
  const _BlockedNotice({required this.reason});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black,
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          const Icon(Icons.info_outline, color: Colors.orangeAccent, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(reason,
                style: const TextStyle(
                    color: Colors.orangeAccent, fontSize: 12, height: 1.35)),
          ),
        ],
      ),
    );
  }
}

/// The durable form of the acknowledgement.
///
/// A modal that can be dismissed is easy to forget; the banner stays until the
/// caution has been acknowledged, so the warning is still on screen during the
/// same visit in which a switch command is first pressed.
///
/// Its wording matches the dialog's rather than sharpening it: the stable,
/// always-true part of the caveat is that not *all* of these commands have been
/// verified, and a banner that overstated it would train the user to ignore the
/// one control that is genuinely unverified.
class _CautionBanner extends StatelessWidget {
  const _CautionBanner();

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);

    return Container(
      color: const Color(0x33B3261E),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.warning_amber, color: Colors.orangeAccent, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              l.videoCautionFoot,
              style: const TextStyle(
                  color: Colors.orangeAccent, fontSize: 11.5, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}

/// Errors and notices, one place, dismissible.
///
/// Two sources feed it: this page's own transport failures ([error]) and
/// anything the shared state layer already recorded (`lastError`, `lastNotice`)
/// — for instance a lost link clearing the camera state.
class _MessageStrip extends StatefulWidget {
  final String? error;
  final AppState app;
  const _MessageStrip({required this.error, required this.app});

  @override
  State<_MessageStrip> createState() => _MessageStripState();
}

class _MessageStripState extends State<_MessageStrip> {
  /// Dismissal is local: the strip may be showing a message that belongs to
  /// shared state, and hiding our copy of it must not clear a message another
  /// screen has not read yet.
  bool _dismissed = false;

  @override
  void didUpdateWidget(_MessageStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A new message is new information, so it re-opens a dismissed strip.
    if (widget.error != oldWidget.error && widget.error != null) {
      _dismissed = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_dismissed) return const SizedBox.shrink();
    final l = l10nOf(context);
    // `AppState`'s two lines keep their English as the fallback and travel with a
    // code, so the language is chosen here; `widget.error` is this page's own
    // transport text and is already final. See `lib/l10n/message_text.dart`.
    final appError = appErrorText(l, widget.app);
    final message = widget.error ?? appError ?? appNoticeText(l, widget.app);
    if (message == null) return const SizedBox.shrink();
    final isError = widget.error != null || appError != null;

    return Container(
      color: isError ? const Color(0x33B3261E) : const Color(0x33265235),
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                color: isError ? Colors.redAccent : Colors.lightGreen,
                fontSize: 11.5,
                height: 1.35,
              ),
            ),
          ),
          IconButton(
            tooltip: l.dismiss,
            onPressed: () => setState(() => _dismissed = true),
            icon: const Icon(Icons.close, size: 16, color: Colors.white38),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  final String? note;
  const _SectionLabel(this.text, {this.note});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(text,
              style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 12,
                  fontWeight: FontWeight.w600)),
          if (note != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(note!,
                  style: const TextStyle(
                      color: Colors.white38, fontSize: 10.5, height: 1.3)),
            ),
        ],
      ),
    );
  }
}
