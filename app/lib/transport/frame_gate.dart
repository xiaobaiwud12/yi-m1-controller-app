/// Deciding whether arriving preview frames are worth decoding.
///
/// ## The defect this exists for
///
/// `HomeShell` keeps both tabs alive in an `IndexedStack`, so `LiveViewPage`
/// stays mounted while the album is on screen.  Its frame subscription was
/// therefore still running, and every frame was still being handed to a page
/// nobody could see — 800x600 JPEGs, ~30 a second.
///
/// Measured with the album tab displayed: the host-side bridge moved **46 906
/// datagrams / 2.47 GB** for pictures no one could look at.
///
/// ## What the justification is, and what it is not
///
/// An earlier version of this note quoted the app's CPU during that run.  **That
/// figure has been withdrawn**: it was taken on an emulator with no GPU (software
/// GL, `ro.hardware.egl = emulation`), no hardware codec, and a debug/JIT build.
/// A controlled A/B on the same emulator measured 103–169 % with the preview on
/// and 0 % with it off, and roughly half of that is rasterisation a real GPU does
/// for free.  It cannot support any claim about a real phone, so it supports
/// nothing here.
///
/// The honest reason is narrower and needs no number: with the preview covered,
/// the app pulls and decodes ~30 frames a second whose output **nobody can see**.
/// That is wasted work by construction — real battery and real thermal budget on
/// a real phone, whatever the emulator exaggerates — not an optimisation that
/// earns its place with a benchmark.
///
/// ## What this does, and what it deliberately does not
///
/// It drops frames client-side.  It **never** touches the stream: no
/// `PauseMovieStream`, no `RCStopMovieStream`, no `RCStopRemoteCtl`.  Those are
/// unverified on this hardware and are forbidden by default (`AGENTS.md` §4.6,
/// `analysis/37`–`39`), so "stop decoding" must not degenerate into "stop the
/// camera".  Nothing in this file sends anything at all, which is why it can be
/// checked in a plain Dart VM.
///
/// ## The frames it does *not* drop, which is the important half
///
/// The user has a standing rule: **the client does not skip frames.**  It was
/// implemented once, to halve the cost, and removed on request — it buys CPU the
/// user cannot see and pays with smoothness the user can.
///
/// This gate drops frames that are **hidden**, so nothing visible is lost.  That
/// is a different thing, but it is adjacent enough that it must not be left to
/// intent: **while visible, this is a straight wire — one frame in, one frame
/// out, in order, with no coalescing and no rate limiting.**  There is no code
/// path here that could do otherwise, and `test/hidden_live_view_test.dart` pins
/// it, so a future "let us smooth out bursts while we are here" turns red
/// instead of shipping.
///
/// ## Why there is no arrival counter here
///
/// [LiveViewStats.isStalled] is a real feature — it is the only thing on screen
/// that can answer "did the camera stop sending?" — and it is derived from
/// *datagram arrival*, which `CameraLiveView` records for **every** datagram it
/// parses, whether or not anybody is listening.  So it keeps working while the
/// gate is shut, with nothing to do here, and a hidden tab cannot be mistaken for
/// a dead camera.  A counter on this side would have been a second, weaker copy
/// of a number the receiver already owns.
///
/// Deliberately free of `package:flutter`: this must run under the plain Dart
/// VM so the gate can be driven by a stream the test owns, with no widget tree,
/// no socket and no camera involved.
library;

import 'dart:async';

import 'liveview.dart';

/// A switch in front of the preview frame stream.
///
/// Visibility is the page's business — it is the page that knows whether it is
/// on screen — and the state JSON riding along with the frames must keep being
/// folded into `AppState`, so this is not a filter that can be bolted onto the
/// stream from outside: it has to sit *around* the subscription, so a hidden
/// page opens no work at all.
class FrameGate {
  /// The frames to gate.
  final Stream<LiveViewFrame> frames;

  /// Called for each frame that is worth decoding.
  final void Function(LiveViewFrame frame) onFrame;

  bool _visible;
  StreamSubscription<LiveViewFrame>? _sub;

  /// Whether [start] has ever been called: without it, a page that reports
  /// itself hidden before the preview starts would subscribe early.
  bool _everStarted = false;
  bool _stopped = false;

  FrameGate({
    required this.frames,
    required this.onFrame,
    bool visible = true,
  }) : _visible = visible;

  /// Whether arriving frames are currently being handed to [onFrame].
  bool get isDelivering => _visible && _sub != null;

  /// Whether the gate is following the stream at all, visible or not.
  bool get isRunning => _sub != null;

  /// Subscribe, if anybody can see the result.
  ///
  /// Idempotent, so a repeated call cannot produce two subscriptions and
  /// deliver every frame twice.
  void start() {
    if (_stopped) return;
    _everStarted = true;
    if (_sub != null) return;
    if (!_visible) return;
    _sub = frames.listen(onFrame);
  }

  /// Tell the gate whether anybody can see the result.
  ///
  /// The subscription is genuinely **cancelled** while hidden, not paused: a
  /// paused subscription buffers, and a subscription that buffered is one that
  /// replays the whole time the album was open the moment the user comes back.
  /// A frame is only worth showing at the moment it arrives.
  ///
  /// Cancelling costs nothing on the receive side — `CameraLiveView` drains its
  /// socket whether or not anybody is listening, and `LiveViewStats` is fed by
  /// the receiver, not by a subscriber.
  void setVisible(bool visible) {
    if (_visible == visible) return;
    _visible = visible;
    if (_stopped || !_everStarted) return;
    if (visible) {
      _sub ??= frames.listen(onFrame);
    } else {
      _sub?.cancel();
      _sub = null;
    }
  }

  /// Stop following the stream entirely — the link went away, or the preview
  /// was stopped.  Distinct from [setVisible]: this is for "there is nothing to
  /// gate any more", not "nobody is looking".
  ///
  /// A gate that has been stopped is finished; bringing the preview back builds
  /// a new one.  Restartable state here would be a second lifecycle to keep
  /// correct for no gain.
  void stop() {
    _stopped = true;
    _sub?.cancel();
    _sub = null;
  }

  /// Release and refuse further work.
  void dispose() => stop();
}
