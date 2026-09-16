/// Live-view receiver: the camera's 800x600 preview stream over UDP 54321.
///
/// ## The wire format (verified against the real camera)
///
/// **Every datagram is one complete frame.** There is no reassembly to do.  The
/// community proof-of-concept assumed a multi-packet frame with a
/// `2048 parameter bytes + JPEG` layout, and that model is wrong — following it
/// means never decoding an image.  The measured truth is:
///
/// ```
/// +0    u32be  frameIndex    increments by 1 per datagram
/// +4    u32be  timestamp     increments by 3003 per datagram (semantics unknown)
/// +8    u32be  0x79CE4283    session constant
/// +12   ...    state block, ~2272 bytes — carries a PLAINTEXT JSON snapshot of
///               the whole camera state (see [CameraState])
/// +2284 ...    JPEG          SOI here, EOI at the end of the datagram
/// ```
///
/// Measured: 800x600 baseline JPEG, ~30 datagrams/second, 14.7-20.0 KB each.
///
/// The state block's JSON is the reason the client never has to poll for camera
/// settings: exposure, ISO, white balance, aperture range, battery and remaining
/// shots all ride along with the preview at no extra bandwidth.
///
/// ## Why this shape is friendly
///
/// Because a frame never spans datagrams, **packet loss costs you a frame and
/// nothing else** — there is no window to reassemble and no corruption to detect.
/// The receiver therefore just drops malformed datagrams and keeps going.
///
/// dart:io only, so this runs from the plain Dart VM as well as on device.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import '../protocol/camera_state.dart';

/// Fixed offset of the JPEG's start-of-image marker within a datagram.
///
/// This is a measured constant: 40 consecutive datagrams all had their SOI
/// marker at exactly this offset.
const int kJpegOffset = 2284;

/// The 3-word header that precedes the parameter block.
const int kHeaderSize = 12;

/// The session constant found at offset +8.
const int kSessionMarker = 0x79CE4283;

/// One decoded frame off the wire.
class LiveViewFrame {
  /// Monotonic frame counter reported by the camera.
  final int frameIndex;

  /// The camera's second counter. Semantics not established; do not use it as a
  /// clock.
  final int timestamp;

  /// A complete JPEG, ready to hand to an image decoder.
  final Uint8List jpeg;

  /// The raw bytes between the header and the JPEG, when this frame carries them.
  ///
  /// The region holds a **plaintext JSON snapshot of the whole camera state** —
  /// see [state].  It is `null` on frames where the state was deliberately not
  /// decoded, because re-parsing it 30 times a second would spend the CPU budget
  /// on a value that changes at human speed.
  final Uint8List? parameters;

  CameraState? _state;
  bool _stateDecoded = false;

  LiveViewFrame({
    required this.frameIndex,
    required this.timestamp,
    required this.jpeg,
    this.parameters,
  });

  /// The camera's complete state as of this frame, or `null` when this frame did
  /// not carry it.
  ///
  /// Decoded lazily: most consumers only want the image.
  CameraState? get state {
    if (!_stateDecoded) {
      final p = parameters;
      _state = p == null ? null : CameraState.fromParameterBlock(p);
      _stateDecoded = true;
    }
    return _state;
  }

  @override
  String toString() => 'LiveViewFrame(#$frameIndex, ${jpeg.length}B jpeg'
      '${parameters == null ? '' : ', ${parameters!.length}B params'})';
}

/// Statistics, so the UI can show link quality instead of guessing.
class LiveViewStats {
  int received = 0;
  int malformed = 0;
  int dropped = 0;
  int lastFrameIndex = -1;
  final Stopwatch _since = Stopwatch()..start();

  /// Arrival times (ms on [_since]) inside the recent window, oldest first.
  final ListQueue<int> _arrivals = ListQueue<int>();

  /// The window [recentFps] is measured over.
  ///
  /// Two seconds is long enough to average out the jitter of a 30 Hz stream over
  /// Wi-Fi and short enough that a stall is visible almost immediately. A longer
  /// window hides the first seconds of the very thing it exists to show.
  static const int recentWindowMs = 2000;

  /// The last datagram's arrival, or null when none has arrived yet.
  int? _lastArrivalMs;

  /// Frames per second over the **whole session**.
  ///
  /// ## Why this is not the number to judge a stall by
  ///
  /// It is `received / elapsed`, so it is a *session average*: after a minute at
  /// 30 fps it decays slowly toward zero and **never reaches it**. A stream that
  /// stops dead still reads as a healthy ~20 fps for the next half minute, so the
  /// UI's "no frames" badge could never fire on a real stall — the one indicator
  /// that answers "did the camera stop sending?" was silent exactly when it
  /// mattered. Use [recentFps] or [isStalled] to answer that question.
  double get fps {
    final s = _since.elapsedMilliseconds / 1000.0;
    return s <= 0 ? 0 : received / s;
  }

  /// Frames per second over the last [recentWindowMs], i.e. **now**.
  ///
  /// This is the number that falls to zero when the camera stops sending, which
  /// is what makes a stall observable from the client at all.
  double get recentFps {
    if (_arrivals.isEmpty) return 0;
    final now = _since.elapsedMilliseconds;
    final window = (now - _arrivals.first).clamp(1, recentWindowMs);
    return _arrivals.length * 1000.0 / window;
  }

  /// How long since the last datagram, or null when none has ever arrived.
  Duration? get sinceLastFrame {
    final last = _lastArrivalMs;
    return last == null ? null : Duration(milliseconds: _since.elapsedMilliseconds - last);
  }

  /// Whether the stream has gone quiet while somebody believes it is running.
  ///
  /// Deliberately relative to a *running* receiver: the caller checks that. An
  /// idle receiver that was never started is not stalled, it is off.
  ///
  /// The threshold is generous on purpose. Frames arrive at ~30 Hz, so a fifth of
  /// a second already means several were missed; the margin absorbs the scheduler
  /// jitter of a phone that is simultaneously decoding and drawing, which would
  /// otherwise flicker the warning on a healthy link.
  bool get isStalled {
    final gap = sinceLastFrame;
    return gap != null && gap.inMilliseconds > stallAfterMs;
  }

  /// How long without a datagram counts as stalled.
  static const int stallAfterMs = 700;

  /// Note that a datagram arrived. Called for **every** datagram, including ones
  /// that later fail validation: the point is whether the link is delivering.
  void noteArrival() {
    final now = _since.elapsedMilliseconds;
    _lastArrivalMs = now;
    _arrivals.addLast(now);
    final cutoff = now - recentWindowMs;
    while (_arrivals.isNotEmpty && _arrivals.first < cutoff) {
      _arrivals.removeFirst();
    }
  }

  /// Frames the camera sent that never arrived, inferred from gaps in
  /// `frameIndex`.  A useful health signal on a congested 2.4 GHz link.
  double get lossRatio {
    final total = received + dropped;
    return total == 0 ? 0 : dropped / total;
  }

  void reset() {
    received = 0;
    malformed = 0;
    dropped = 0;
    lastFrameIndex = -1;
    _arrivals.clear();
    _lastArrivalMs = null;
    _since
      ..reset()
      ..start();
  }

  @override
  String toString() => 'received=$received malformed=$malformed dropped=$dropped '
      'fps=${fps.toStringAsFixed(1)} recent=${recentFps.toStringAsFixed(1)} '
      'loss=${(lossRatio * 100).toStringAsFixed(1)}%';
}

/// Receives the camera's preview stream.
///
/// Usage:
///
/// ```dart
/// final lv = CameraLiveView();
/// await lv.start();                   // binds BEFORE remote mode is enabled
/// await camera.startRemoteControl();  // frames begin arriving
/// await for (final frame in lv.frames) { render(frame.jpeg); }
/// ```
///
/// **Bind before enabling remote control.**  Frames start the moment the camera
/// enters the mode, so binding afterwards silently loses the first ones.
class CameraLiveView {
  /// The camera broadcasts here; it is shared with other YI Home devices.
  static const int defaultPort = 54321;

  final int port;
  final LiveViewStats stats;

  RawDatagramSocket? _socket;
  StreamSubscription<RawSocketEvent>? _sub;
  final StreamController<LiveViewFrame> _frames =
      StreamController<LiveViewFrame>.broadcast();

  /// Completed JPEGs.
  Stream<LiveViewFrame> get frames => _frames.stream;

  bool get isRunning => _socket != null;

  CameraLiveView({this.port = defaultPort, LiveViewStats? stats})
      : stats = stats ?? LiveViewStats();

  /// Bind the port.  Safe to call before the camera is in remote-control mode.
  ///
  /// Callable twice without harm: a second concurrent call would otherwise get
  /// past the `_socket != null` guard while the first is still binding (the guard
  /// is only set once the bind completes), and `reuseAddress: true` lets the
  /// second bind *succeed* — so the loser's socket stayed bound, kept receiving,
  /// and fed the same frame controller.  Closing the loser is what makes [stop]
  /// actually stop the stream.
  Future<void> start() async {
    if (_socket != null) return;

    final socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      port,
      reuseAddress: true,
    );
    // Deliberately no SO_RCVBUF tuning: Dart exposes socket options only through
    // the raw platform-dependent `setRawOption`, and the value differs between
    // Windows and Linux. It is not worth it — frames do not span datagrams, so a
    // small kernel buffer costs a few frames and never corrupts one. A large
    // default plus prompt draining (below) is sufficient at ~30 datagrams/s.

    if (_socket != null) {
      // Another start() won the race; this socket is a duplicate receiver.
      socket.close();
      return;
    }

    _socket = socket;
    _sub = socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      // Drain everything currently queued before returning to the event loop.
      for (Datagram? dg = socket.receive(); dg != null; dg = socket.receive()) {
        _handle(dg.data);
      }
    });
  }

  /// Frame counter used to decide when to decode the state JSON.
  int _stateDecodeStride = 4;
  int _sinceStateDecode = 0;

  /// How often to decode the embedded camera-state JSON.
  ///
  /// The state changes at human speed (a dial turn, a half-press) while frames
  /// arrive at 30 Hz, so parsing it every frame spends most of the CPU budget
  /// re-deriving a value that did not move — on the same isolate that must keep
  /// draining the socket. Set to 1 to decode every frame.
  set stateDecodeStride(int n) => _stateDecodeStride = n < 1 ? 1 : n;

  void _handle(Uint8List data) {
    stats.received++;
    // Before any validation: the question this answers is "is the link
    // delivering?", and a malformed datagram still proves it is.
    stats.noteArrival();
    if (data.length < kJpegOffset + 4) {
      stats.malformed++;
      return;
    }

    final bd = ByteData.sublistView(data);
    final frameIndex = bd.getUint32(0, Endian.big);
    final timestamp = bd.getUint32(4, Endian.big);

    // Track loss via gaps in the camera's own counter.
    if (stats.lastFrameIndex >= 0 && frameIndex > stats.lastFrameIndex + 1) {
      stats.dropped += frameIndex - stats.lastFrameIndex - 1;
    }
    stats.lastFrameIndex = frameIndex;

    // Locate the image. The offset is a measured constant, but verifying the
    // marker before trusting it costs two comparisons, whereas a scan of 2272
    // bytes costs far more — and this runs 30 times a second. The scan is kept
    // only as a fallback for a firmware that shifts the layout.
    var soi = -1;
    if (data[kJpegOffset] == 0xFF &&
        data[kJpegOffset + 1] == 0xD8 &&
        data[kJpegOffset + 2] == 0xFF) {
      soi = kJpegOffset;
    } else {
      soi = _findJpegStart(data, kHeaderSize);
    }
    if (soi < 0) {
      stats.malformed++;
      return;
    }

    // The end-of-image marker is documented as the last two bytes of the
    // datagram, so check there first rather than walking backwards.
    var eoi = data.length - 2;
    if (!(data[eoi] == 0xFF && data[eoi + 1] == 0xD9)) {
      eoi = -1;
      for (var i = data.length - 2; i > soi; i--) {
        if (data[i] == 0xFF && data[i + 1] == 0xD9) {
          eoi = i;
          break;
        }
      }
    }
    if (eoi <= soi) {
      stats.malformed++;
      return;
    }

    // Decoding the state JSON is the single most expensive thing in this loop,
    // and the value it produces changes at human speed. Do it on a stride.
    final wantState = _sinceStateDecode == 0;
    _sinceStateDecode = (_sinceStateDecode + 1) % _stateDecodeStride;

    _frames.add(LiveViewFrame(
      frameIndex: frameIndex,
      timestamp: timestamp,
      jpeg: Uint8List.sublistView(data, soi, eoi + 2),
      parameters: wantState
          ? Uint8List.sublistView(data, kHeaderSize, soi)
          : null,
    ));
  }

  /// Look for `FF D8 FF` starting at [from].
  static int _findJpegStart(Uint8List d, int from) {
    for (var i = from; i + 2 < d.length; i++) {
      if (d[i] == 0xFF && d[i + 1] == 0xD8 && d[i + 2] == 0xFF) return i;
    }
    return -1;
  }

  /// Hand one datagram to the receiver as if the camera had sent it.
  ///
  /// ## Why this is a public seam
  ///
  /// The frame subscription is what the hidden-tab defect lives in, and the
  /// only way to check it is to make frames *arrive* during a test.  Binding
  /// UDP 54321 to do that is not an option: the app under test is often running
  /// in an emulator on the same machine with that port forwarded to the real
  /// camera, and a test would either fail to bind or take the camera's stream.
  ///
  /// This goes through [_handle] — **the same code the socket feeds** — rather
  /// than pushing onto [frames] directly, so a test exercises the real header
  /// and JPEG-marker validation.  A shortcut straight to the stream would let a
  /// fixture that the receiver rejects make an assertion pass with nothing ever
  /// reaching the consumer, which is the fixture trap `AGENTS.md` §8 names.
  ///
  /// Refuses when the socket is not bound, so this cannot be mistaken for a way
  /// to run a receiver without one.
  void feedLiveViewDatagram(Uint8List datagram) {
    if (_socket == null) {
      throw StateError('CameraLiveView is not running; call start() first — '
          'this seam exists to feed a bound receiver, not to replace it');
    }
    _handle(datagram);
  }

  /// Whether frames are still arriving.
  ///
  /// Compares the camera's own frame counter rather than the receive count, so a
  /// stream that has stopped is distinguishable from one that is merely slow —
  /// and, unlike counting datagrams, the answer cannot be inflated by the
  /// statistics being sampled over a different window than the caller expects.
  ///
  /// Used as the recovery test for the capture interlock, where an absolute
  /// frame-rate threshold would never be met on a slow-but-working link and would
  /// therefore disable the shutter forever.
  Future<bool> isAdvancing({Duration within = const Duration(milliseconds: 700)}) async {
    if (_socket == null) return false;
    final before = stats.lastFrameIndex;
    await Future<void>.delayed(within);
    return stats.lastFrameIndex > before;
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    _socket?.close();
    _socket = null;
  }

  Future<void> dispose() async {
    await stop();
    await _frames.close();
  }
}
