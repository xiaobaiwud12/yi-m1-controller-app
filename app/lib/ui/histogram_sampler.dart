import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../protocol/histogram.dart';

/// Decodes live-view JPEGs and computes a luminance histogram, off the critical
/// path.
///
/// ## Why this is rate-limited rather than per-frame
///
/// Getting pixels out of a JPEG requires a full decode plus a GPU read-back
/// (`toByteData`), which is far more expensive than the decode the preview
/// already does. Doing that thirty times a second would be exactly the kind of
/// "optimisation" this project has already rejected once: it would trade visible
/// smoothness for a number the user reads at human speed.
///
/// So it decodes on its own timer, at a rate a person can actually use, and it
/// **drops frames rather than queueing them** — a stale histogram is worthless,
/// and a backlog would lag further behind the longer the app ran.
///
/// ## Why the work is isolated here
///
/// A histogram that stalls the preview is worse than no histogram. Keeping the
/// decode and the arithmetic in one small class means the cost is visible and the
/// cadence is the only knob.
class HistogramSampler {
  /// How often to recompute. Roughly 4 Hz: fast enough to track a lighting
  /// change as the camera is moved, slow enough that the decode cost is a few
  /// percent of the preview's rather than a multiple of it.
  final Duration interval;

  /// Guard against overlapping work if a decode takes longer than [interval].
  bool _busy = false;

  Timer? _timer;
  Uint8List? _pendingFrame;
  bool _running = false;

  /// The newest histogram, or [LumaHistogram.empty] before the first sample.
  final ValueNotifier<LumaHistogram> value =
      ValueNotifier<LumaHistogram>(LumaHistogram.empty);

  /// Set when decoding fails, so the UI can say the histogram is unavailable
  /// rather than showing a flat line that looks like a real reading.
  final ValueNotifier<String?> error = ValueNotifier<String?>(null);

  HistogramSampler({this.interval = const Duration(milliseconds: 250)});

  /// Feed the newest frame.  Only the most recent one is kept: a queue of stale
  /// frames would produce a histogram of the past.
  void offer(Uint8List jpeg) {
    if (!_running) return;
    _pendingFrame = jpeg;
  }

  void start() {
    if (_running) return;
    _running = true;
    _timer = Timer.periodic(interval, (_) => unawaited(_tick()));
  }

  void stop() {
    _running = false;
    _timer?.cancel();
    _timer = null;
    _pendingFrame = null;
  }

  Future<void> _tick() async {
    final frame = _pendingFrame;
    if (frame == null || _busy) return;
    _pendingFrame = null;
    _busy = true;
    try {
      final codec = await ui.instantiateImageCodec(frame);
      final img = (await codec.getNextFrame()).image;
      final raw = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
      img.dispose();
      if (raw == null) {
        error.value = 'the frame could not be read back';
        return;
      }
      // Stride 4 because `rawRgba` is RGBA. Passing 3 here is the silent failure
      // the histogram's own documentation warns about: the shape still looks like
      // a histogram, just a wrong one.
      value.value = LumaHistogram.fromRgb(
        raw.buffer.asUint8List(),
        stride: 4,
        sampleStep: 8,
      );
      error.value = null;
    } on Object catch (e) {
      // A torn or truncated frame is expected occasionally on this link; say so
      // rather than freezing the last reading as if it were current.
      error.value = '$e';
    } finally {
      _busy = false;
    }
  }

  void dispose() {
    stop();
    value.dispose();
    error.dispose();
  }
}
