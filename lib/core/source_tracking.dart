import 'dart:math' as math;
import 'dart:isolate';

import 'recipe.dart';
import 'renderer.dart';

// Keep isolate closures outside Store/UI methods: they must not capture a run,
// a stream, or a pending filesystem write through a shared closure context.
Future<Recipe> withColorReferencesAsync(Rgba source, Recipe recipe) =>
    Isolate.run(() => withColorReferences(source, recipe));
Future<SourceTrackingResult> trackSourceAsync(Rgba before, Rgba after, Recipe recipe) =>
    Isolate.run(() => trackSource(before, after, recipe));

/// Reconstruct evidence for both sampled and HEX/palette colors. A spatial grid
/// keeps repeated colors represented rather than trusting one guessed object.
Recipe withColorReferences(Rgba source, Recipe recipe) {
  final result = recipe.copy();
  final lab = toLab(source);
  final area = areaMask(lab.width, lab.height, result.area);
  void attach(KeptColor color, bool exclude) {
    final refs = <List<double>>[];
    // Preserve an explicit pick if it still refers to this source color.
    for (final point in color.references.take(1)) {
      final c = sampleColor(lab, point[0], point[1]);
      if (_distance(c.l, c.a, c.b, point[2], point[3], point[4]) < .015) {
        refs.add([point[0], point[1], c.l, c.a, c.b]);
      }
    }
    for (var gy = 0; gy < 4; gy++) {
      for (var gx = 0; gx < 4; gx++) {
        var best = .065;
        int? index;
        for (var y = gy * lab.height ~/ 4; y < (gy + 1) * lab.height ~/ 4; y += 2) {
          for (var x = gx * lab.width ~/ 4; x < (gx + 1) * lab.width ~/ 4; x += 2) {
            final i = y * lab.width + x;
            if (!exclude && area[i] < .9) continue;
            final distance = _distance(lab.l[i], lab.a[i], lab.b[i], color.l, color.a, color.b);
            if (distance < best) { best = distance; index = i; }
          }
        }
        if (index == null) continue;
        final x = (index % lab.width) / math.max(1, lab.width - 1);
        final y = (index ~/ lab.width) / math.max(1, lab.height - 1);
        final c = sampleColor(lab, x, y);
        if (_distance(c.l, c.a, c.b, color.l, color.a, color.b) > .065) continue;
        refs.add([x, y, c.l, c.a, c.b]);
      }
    }
    color.references = refs;
  }
  for (final color in result.colors) { attach(color, false); }
  for (final color in result.excludedColors) { attach(color, true); }
  return result;
}

double _distance(double l, double a, double b, double ll, double aa, double bb) =>
    math.sqrt(.2 * (l - ll) * (l - ll) + (a - aa) * (a - aa) + (b - bb) * (b - bb));
double _median(List<double> values) => (values..sort())[values.length ~/ 2];

class SourceTrackingResult {
  const SourceTrackingResult(this.recipe, this.reason);
  final Recipe? recipe;
  final String? reason;
  bool get canApply => recipe != null;
}

/// Pure on-device migration. Geometry changes are held for review until their
/// correspondence can be established; dimensions alone never prove alignment.
SourceTrackingResult trackSource(Rgba before, Rgba after, Recipe recipe) {
  SourceTrackingResult review(String why) => SourceTrackingResult(null, why);
  if ((before.width / before.height - after.width / after.height).abs() > .002) {
    return review('The framing changed. Review the crop and area.');
  }
  final oldLab = toLab(before), newLab = toLab(after);
  // Compare normalized structure independently of global exposure/contrast.
  final oldL = <double>[], newL = <double>[];
  for (var y = 0; y < 24; y++) {
    for (var x = 0; x < 24; x++) {
      oldL.add(oldLab.l[((y + .5) * oldLab.height / 24).floor() * oldLab.width + ((x + .5) * oldLab.width / 24).floor()]);
      newL.add(newLab.l[((y + .5) * newLab.height / 24).floor() * newLab.width + ((x + .5) * newLab.width / 24).floor()]);
    }
  }
  final om = oldL.reduce((a, b) => a + b) / oldL.length;
  final nm = newL.reduce((a, b) => a + b) / newL.length;
  var oo = 0.0, nn = 0.0, on = 0.0;
  for (var i = 0; i < oldL.length; i++) {
    final a = oldL[i] - om, b = newL[i] - nm;
    oo += a * a; nn += b * b; on += a * b;
  }
  if (oo < .01 || nn < .01 || on / math.sqrt(oo * nn) < .985) {
    return review('Could not reliably match the same parts of the photo.');
  }
  final result = withColorReferences(before, recipe);
  for (final c in [...result.colors, ...result.excludedColors]) {
    if (c.references.length < 3) return review('Not enough reliable color references.');
    final dl = <double>[], da = <double>[], db = <double>[];
    for (final p in c.references) {
      final next = sampleColor(newLab, p[0], p[1]);
      if (next.chroma < .012) return review('A selected color became too neutral to track.');
      dl.add(next.l - p[2]); da.add(next.a - p[3]); db.add(next.b - p[4]);
    }
    final l = _median(List.of(dl)), a = _median(List.of(da)), b = _median(List.of(db));
    // One color becoming multiple different colors must not silently choose one.
    for (var i = 0; i < da.length; i++) {
      if (_distance(dl[i], da[i], db[i], l, a, b) > .025) {
        return review('Different parts of the selected color changed differently.');
      }
    }
    final previousChroma = c.chroma;
    c..l = (c.l + l).clamp(0, 1)..a += a..b += b;
    c.chromaMin = (c.chromaMin * c.chroma / math.max(.001, previousChroma)).clamp(0, .3);
    if (c.lightness != null) c.lightness = c.lightness!.map((v) => (v + l).clamp(0.0, 1.0)).toList();
  }
  // Compare actual keep/exclude selections, not just the hue difference.
  final oldWeight = render(before, recipe, lab: oldLab).weight;
  final newWeight = render(after, result, lab: newLab).weight;
  var intersection = 0.0, union = 0.0;
  for (var y = 0; y < 48; y++) {
    for (var x = 0; x < 48; x++) {
      final a = oldWeight[((y + .5) * before.height / 48).floor() * before.width + ((x + .5) * before.width / 48).floor()];
      final b = newWeight[((y + .5) * after.height / 48).floor() * after.width + ((x + .5) * after.width / 48).floor()];
      intersection += math.min(a, b); union += math.max(a, b);
    }
  }
  if (union > .01 && intersection / union < .90) return review('The area keeping color changed too much.');
  return SourceTrackingResult(withColorReferences(after, result), null);
}
