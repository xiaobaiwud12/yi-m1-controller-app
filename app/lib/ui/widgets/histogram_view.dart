import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../protocol/histogram.dart';

/// A luminance histogram, drawn as a filled curve.
///
/// The camera exposes no histogram and cannot be asked for one, but every frame
/// already carries a full 800x600 image — so the data is sitting there and
/// computing it on the phone costs no bandwidth and no camera work. That matters
/// on a device whose HTTP server is single-threaded and whose preview encoder is
/// easily starved.
///
/// The two clipping indicators are the reason a photographer wants this at all:
/// a shape tells you the exposure is plausible, but "3.1% of pixels are blown"
/// tells you to stop down.
class HistogramView extends StatelessWidget {
  final LumaHistogram histogram;
  final double height;
  final bool showClipping;

  /// Drawn in the shadow/highlight bands when clipping is present.
  final Color clipColour;

  const HistogramView({
    super.key,
    required this.histogram,
    this.height = 44,
    this.showClipping = true,
    this.clipColour = Colors.redAccent,
  });

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    if (histogram.samples == 0) {
      return SizedBox(
        height: height,
        child: Center(
          child: Text(l.histogramNoData,
              style: const TextStyle(color: Colors.white24, fontSize: 10)),
        ),
      );
    }

    return SizedBox(
      height: height,
      child: CustomPaint(
        painter: _HistogramPainter(
          histogram: histogram,
          clipColour: clipColour,
          showClipping: showClipping,
        ),
        size: Size.infinite,
      ),
    );
  }
}

class _HistogramPainter extends CustomPainter {
  final LumaHistogram histogram;
  final Color clipColour;
  final bool showClipping;

  _HistogramPainter({
    required this.histogram,
    required this.clipColour,
    required this.showClipping,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final peak = histogram.peak;
    if (peak <= 0) return;

    // The tallest bucket is usually a spike of near-black or near-white from a
    // small uniform region, and letting it set the scale flattens the midtones
    // into an unreadable smear. Clamping the scale to a high percentile instead
    // keeps the informative part of the curve legible; the clipping indicators
    // below are unaffected because they are computed from pixel counts, not from
    // this scale.
    final sorted = List<int>.from(histogram.buckets)..sort();
    final p99 = sorted[(sorted.length * 0.99).floor().clamp(0, sorted.length - 1)];
    final scale = (p99 > 0 ? p99 : peak).toDouble();

    final path = Path()..moveTo(0, size.height);
    for (var i = 0; i < 256; i++) {
      final x = size.width * i / 255;
      final v = (histogram[i] / scale).clamp(0.0, 1.0);
      path.lineTo(x, size.height - v * size.height);
    }
    path
      ..lineTo(size.width, size.height)
      ..close();

    canvas.drawPath(
      path,
      Paint()..color = Colors.white.withValues(alpha: 0.55),
    );

    if (!showClipping) return;

    // Draw the clipped *depth* rather than a fixed-width band, so a small amount
    // of clipping is visible without looking like a disaster.
    final shadowFrac = histogram.clippedShadows.clamp(0.0, 1.0);
    final highFrac = histogram.clippedHighlights.clamp(0.0, 1.0);
    if (shadowFrac > 0.001) {
      canvas.drawRect(
        Rect.fromLTWH(0, 0, size.width * shadowFrac.clamp(0.0, 0.25) * 4, size.height),
        Paint()..color = clipColour.withValues(alpha: 0.30),
      );
    }
    if (highFrac > 0.001) {
      final w = size.width * highFrac.clamp(0.0, 0.25) * 4;
      canvas.drawRect(
        Rect.fromLTWH(size.width - w, 0, w, size.height),
        Paint()..color = clipColour.withValues(alpha: 0.30),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _HistogramPainter old) =>
      old.histogram.samples != histogram.samples ||
      old.histogram.clippedHighlights != histogram.clippedHighlights ||
      old.histogram.clippedShadows != histogram.clippedShadows ||
      old.showClipping != showClipping;
}

/// The readout that goes with the curve.
///
/// Numbers beside a shape, because "is that spike a problem?" is not answerable
/// from the shape alone.
class HistogramReadout extends StatelessWidget {
  final LumaHistogram histogram;
  const HistogramReadout({super.key, required this.histogram});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    if (histogram.samples == 0) return const SizedBox.shrink();
    final hi = histogram.clippedHighlights * 100;
    final lo = histogram.clippedShadows * 100;
    return Text(
      // The two clipping tails are their own messages: a locale that puts the
      // percentage before the word needs to be able to move it, so they are
      // looked up rather than concatenated here. `''` is the documented way to
      // say "this tail is below the threshold and must not be shown at all".
      l.histogramStats(
        histogram.mean.toStringAsFixed(0),
        hi >= 0.5 ? l.histogramBlown(hi.toStringAsFixed(1)) : '',
        lo >= 0.5 ? l.histogramCrushed(lo.toStringAsFixed(1)) : '',
      ),
      style: TextStyle(
        // Colour only when there is something to act on: an always-red readout
        // trains the user to ignore it.
        color: (hi >= 5 || lo >= 5) ? Colors.orangeAccent : Colors.white54,
        fontSize: 10.5,
        height: 1.3,
      ),
    );
  }
}
