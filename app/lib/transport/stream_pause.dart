/// The real stream-pause controller: `PauseMovieStream` / `ResumeMovieStream`
/// over the camera's HTTP control endpoint.
///
/// ## What is and is not known about these commands
///
/// * Both names are in the firmware's 45-entry dispatch table
///   (`protocol/http_commands.dart`), and both are in the set the official app
///   never used. They are **structurally verified** — the dispatch table, the
///   format strings and the cross-references are all present — but they have
///   **never been exercised against a real camera**, by this project or any
///   other.
/// * The camera has **no watchdog**. A command it does not expect can wedge it
///   until the battery is pulled, which is why nothing here is allowed to fail
///   loudly: the caller degrades to a slow-but-working transfer.
/// * Commands only take effect in remote-control mode (`RCStartRemoteCtl`), so a
///   pause attempted while the preview is stopped is meaningless. The caller
///   checks that; this class does not, because it has no view of the link.
///
/// ## Why this lives in `transport/` and not in `sync/`
///
/// It speaks HTTP, so it needs `dart:io` through [CameraHttpClient]. The engine
/// only needs the contract in `sync/stream_pause_contract.dart`, which keeps
/// `sync/` loadable by `tool/verify_sync.dart` in the plain Dart VM.
library;

import 'dart:async';

import '../protocol/http_commands.dart';
import '../sync/stream_pause_contract.dart';
import 'http_transport.dart';

/// Pauses the live-view stream by talking to the camera.
class HttpStreamPauseController implements StreamPauseController {
  /// Supplies the client for the *current* connection.
  ///
  /// A function rather than a client, for the same reason the capture interlock
  /// takes one: the camera's client only exists once the link is ready, and the
  /// connection is rebuilt on every reconnect. A captured client would be a
  /// detached one that always fails — or worse, one bound to a dead socket that
  /// silently swallows the resume.
  final CameraHttpClient Function() http;

  /// Where diagnostics go.  Injected so this file needs no logging framework.
  final void Function(String message)? onLog;

  /// Whether there is a stream worth pausing right now.
  ///
  /// `PauseMovieStream` only means anything while the camera is in
  /// remote-control mode, and only the host knows whether it is — this class has
  /// no view of the link. A `false` here is reported exactly like a refusal, so
  /// nothing downstream needs to distinguish "there was no stream" from "the
  /// camera would not pause it": in both cases the transfer simply proceeds.
  final bool Function()? isAvailable;

  /// How long to wait before retrying a resume that failed.
  ///
  /// A failed resume is the one outcome that leaves the user with a frozen
  /// preview, so it is retried once rather than dropped. One retry, not a loop:
  /// if the link is genuinely gone the retry cannot help, and hammering a
  /// watchdog-less camera with commands it is not answering is how a recoverable
  /// hang becomes an unrecoverable one.
  final Duration resumeRetryDelay;

  HttpStreamPauseController({
    required this.http,
    this.isAvailable,
    this.onLog,
    this.resumeRetryDelay = const Duration(milliseconds: 750),
  });

  /// True after a pause the camera confirmed, false again after a resume.
  ///
  /// Diagnostic only — the engine keeps its own count, because only the engine
  /// knows how many overlapping transfers are holding the pause.
  bool _paused = false;
  bool get isPaused => _paused;

  @override
  Future<bool> pause() async {
    if (_paused) return true;
    if (isAvailable != null && !isAvailable!()) {
      // No preview is running, so there is nothing to pause and no reason to
      // send an untested command to a camera that cannot be reasoned with.
      _log('no preview is running, so there is nothing to pause');
      return false;
    }
    if (!isKnownCommand('PauseMovieStream')) {
      // Defensive and dead in practice: the name is asserted present in the
      // dispatch table. Sending an unknown name gets a 404, and a 404 on this
      // firmware is indistinguishable from "the parameters were wrong", so the
      // check turns a confusing log line into an obvious one.
      _log('PauseMovieStream is not in the command table; not sending it');
      return false;
    }
    try {
      final r = await http().send('PauseMovieStream');
      if (!r.ok) {
        // A 200 is not proof of anything on this firmware, but a non-200 is
        // proof of refusal, and a refusal must not stop the transfer.
        _log('PauseMovieStream refused (code ${r.code}: ${r.raw}); the transfer '
            'will run with the stream still up');
        return false;
      }
      _paused = true;
      _log('stream paused for the transfer');
      return true;
    } on Object catch (e) {
      // Transport failure: the link is unhappy, and the transfer itself will
      // discover that on its own terms. Do not convert it into a sync failure.
      _log('PauseMovieStream did not reach the camera ($e); continuing');
      return false;
    }
  }

  @override
  Future<bool> resume() async {
    final wasPaused = _paused;
    _paused = false;
    // Sent even when we do not believe we paused: the camera's stream state is
    // not something this app can read back, and a redundant resume is harmless
    // whereas a skipped one leaves a frozen view.
    final ok = await _sendResume();
    if (ok) {
      if (wasPaused) _log('stream resumed');
      return true;
    }
    // One retry after a short pause: the resume usually fails because the link
    // was briefly busy with the transfer that just ended, which is exactly the
    // condition that clears by itself.
    unawaited(Future<void>.delayed(resumeRetryDelay).then((_) async {
      try {
        if (await _sendResume()) {
          _log('stream resumed on the retry');
        } else {
          _log('ResumeMovieStream failed twice. Stop and start the preview to '
              'get the stream back.');
        }
      } on Object catch (e) {
        _log('ResumeMovieStream retry threw ($e)');
      }
    }));
    return false;
  }

  Future<bool> _sendResume() async {
    try {
      final r = await http().send('ResumeMovieStream');
      if (!r.ok) {
        _log('ResumeMovieStream refused (code ${r.code}: ${r.raw})');
        return false;
      }
      return true;
    } on Object catch (e) {
      _log('ResumeMovieStream did not reach the camera ($e)');
      return false;
    }
  }

  void _log(String m) => onLog?.call('[stream] $m');
}
