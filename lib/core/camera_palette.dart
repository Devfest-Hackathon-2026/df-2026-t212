import 'dart:math' as math;

import 'recipe.dart';
import 'renderer.dart';

/// Distinct colors available to pick from the unprocessed camera frame.
List<KeptColor> cameraPalette(Rgba px) {
  final lab = toLab(px);
  // Muted cloth, foliage and wood still have useful hue below the analysis
  // histogram's default .04 cutoff. Require visible area to reject speckles.
  final peaks = huePeaks(
    lab,
    top: 18,
    minChroma: 0.012,
  ).where((p) => p.share > 0.006 && p.area > 0.003).toList();
  double score(HuePeak p) {
    final d = math.sqrt(
      math.pow(p.center[0] - 0.5, 2) + math.pow(p.center[1] - 0.5, 2),
    );
    return p.share *
        (1 - 0.8 * (d / 0.71).clamp(0.0, 1.0)) *
        (0.5 + p.meanChroma * 4);
  }

  // Six of as many hues as the view holds: each one taken makes those
  // near it in hue count for much less, so a wide skin or a wall cannot
  // fill the row by itself while the denim and the leaves wait.
  double mid(HuePeak p) => (p.from + p.to) / 2;
  double gap(double x, double y) => ((x - y + 540) % 360 - 180).abs();
  final left = [...peaks];
  final chosen = <HuePeak>[];
  while (chosen.length < 6 && left.isNotEmpty) {
    HuePeak? best;
    var bestS = 0.0;
    for (final p in left) {
      var s = score(p);
      for (final c in chosen) {
        final g = gap(mid(p), mid(c));
        s *= 1 - 0.9 * math.exp(-math.pow(g / 28, 2));
      }
      if (best == null || s > bestS) {
        best = p;
        bestS = s;
      }
    }
    chosen.add(best!);
    left.remove(best);
  }
  peaks
    ..clear()
    ..addAll(chosen);
  KeptColor color(HuePeak p) {
    final h = (p.from + p.to) / 2 * math.pi / 180;
    return KeptColor(
      l: p.meanL,
      a: p.meanChroma * math.cos(h),
      b: p.meanChroma * math.sin(h),
      chromaMin: (p.meanChroma * 0.6).clamp(0.006, 0.03),
    );
  }

  return peaks.take(6).map(color).toList();
}
