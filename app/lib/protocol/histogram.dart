import 'dart:typed_data';

/// A luminance histogram computed from a decoded frame.
///
/// ## Why compute it client-side
///
/// The camera has no histogram command, and nothing in its 45-command table
/// exposes exposure metering. But the live-view stream already delivers a full
/// 800x600 JPEG ~30 times a second, so the data is sitting there. Computing it on
/// the phone costs a decode and a pass over the pixels — no extra bandwidth, no
/// extra camera work, and no round trip, which matters because the camera's own
/// HTTP server is single-threaded.
///
/// ## Why this is in `protocol/` rather than in a widget
///
/// It is pure computation over bytes with no Flutter dependency, so it can be
/// checked offline — and the failure mode of a histogram is subtle (a wrong
/// stride still looks like a plausible shape), which makes it worth a test.
class LumaHistogram {
  /// 256 buckets, one per luminance level.
  final List<int> buckets;

  /// Total pixels counted.
  final int samples;

  /// Fraction of pixels at or above [highlightClip] / at or below [shadowClip].
  ///
  /// These are the "blown highlight" and "crushed shadow" indicators, which is
  /// the whole reason a photographer wants a histogram while framing.
  final double clippedHighlights;
  final double clippedShadows;

  const LumaHistogram({
    required this.buckets,
    required this.samples,
    required this.clippedHighlights,
    required this.clippedShadows,
  });

  /// Level above which a pixel is treated as clipped. 250 rather than 255, so a
  /// channel that is *effectively* blown is reported as such.
  static const int highlightClip = 250;

  /// Level below which a pixel is treated as crushed.
  static const int shadowClip = 5;

  int operator [](int level) => buckets[level.clamp(0, 255)];

  /// The largest bucket count, for scaling a plot.
  int get peak => buckets.fold(0, (a, b) => a > b ? a : b);

  /// Mean luminance, 0..255.
  double get mean {
    if (samples == 0) return 0;
    var sum = 0;
    for (var i = 0; i < 256; i++) {
      sum += i * buckets[i];
    }
    return sum / samples;
  }

  /// Build a histogram from raw RGB bytes.
  ///
  /// [rgb] is interleaved 8-bit RGB, as produced by decoding a JPEG. [stride] is
  /// the byte distance between consecutive pixels (3 for RGB, 4 for RGBA) —
  /// **getting this wrong is the subtle failure this class exists to avoid**: the
  /// resulting shape still looks like a histogram, just a wrong one, so the
  /// default is asserted to be one of the two values actually in use.
  ///
  /// [sampleStep] skips pixels to bound the cost. A 800x600 frame is 480k pixels;
  /// stepping by 4 still gives 120k samples, which is far more than the 256
  /// buckets need, and keeps the per-frame cost low enough to run at stream rate.
  factory LumaHistogram.fromRgb(
    Uint8List rgb, {
    int stride = 3,
    int sampleStep = 4,
  }) {
    assert(stride == 3 || stride == 4, 'stride must be RGB (3) or RGBA (4)');
    assert(sampleStep >= 1);

    final buckets = List<int>.filled(256, 0);
    var samples = 0;
    var high = 0;
    var low = 0;

    final usable = rgb.length - (stride - 1);
    for (var i = 0; i + 2 < usable; i += stride * sampleStep) {
      final r = rgb[i];
      final g = rgb[i + 1];
      final b = rgb[i + 2];
      // Rec. 601 luma, integer arithmetic: the same weighting the camera's own
      // metering is based on, and cheap enough to run per frame.
      final y = ((r * 299) + (g * 587) + (b * 114)) ~/ 1000;
      final level = y.clamp(0, 255);
      buckets[level]++;
      samples++;
      if (level >= highlightClip) high++;
      if (level <= shadowClip) low++;
    }

    return LumaHistogram(
      buckets: buckets,
      samples: samples,
      clippedHighlights: samples == 0 ? 0 : high / samples,
      clippedShadows: samples == 0 ? 0 : low / samples,
    );
  }

  /// An empty histogram, for before the first frame arrives.
  static const empty = LumaHistogram(
    buckets: <int>[],
    samples: 0,
    clippedHighlights: 0,
    clippedShadows: 0,
  );

  @override
  String toString() => 'LumaHistogram(samples=$samples, '
      'mean=${mean.toStringAsFixed(1)}, '
      'clip=${(clippedHighlights * 100).toStringAsFixed(1)}%/'
      '${(clippedShadows * 100).toStringAsFixed(1)}%)';
}
