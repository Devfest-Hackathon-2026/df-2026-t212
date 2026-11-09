import 'dart:math' as math;
import 'dart:typed_data';
import 'package:afterhue/core/recipe.dart';
import 'package:afterhue/core/renderer.dart';
import 'package:afterhue/core/source_tracking.dart';
import 'package:flutter_test/flutter_test.dart';

Rgba scene({double shift = 0, bool split = false, bool moved = false}) {
  const w = 96, h = 96;
  final bytes = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final hue = (x < w ~/ 2 ? 350 : 45) + (split && y < h ~/ 2 ? -shift : shift);
      final l = .5 + .2 * (moved ? (x + 30) % w : x) / w + .08 * math.sin(y * .13);
      final rgb = oklabToRgb8(l, .1 * math.cos(hue * math.pi / 180), .1 * math.sin(hue * math.pi / 180));
      bytes.setRange((y * w + x) * 4, (y * w + x) * 4 + 4, [...rgb, 255]);
    }
  }
  return Rgba(w, h, bytes);
}

Recipe recipe(Rgba source) => Recipe(colors: [sampleColor(toLab(source), .25, .5)..width = 12],
  excludedColors: [sampleColor(toLab(source), .75, .5)..width = 4], ambience: 0);

void main() {
  test('legacy and HEX colors gain spatial evidence without changing output or cache key', () {
    final photo = scene(), original = recipe(scene());
    for (final c in [...original.colors, ...original.excludedColors]) { c.references = []; }
    final enriched = withColorReferences(photo, original);
    expect(enriched.colors.single.references.length, greaterThan(3));
    expect(enriched.excludedColors.single.references.length, greaterThan(3));
    expect(original.colors.single.references, isEmpty);
    expect(enriched.signature, original.signature);
    expect(render(photo, enriched).image.pixels, render(photo, original).image.pixels);
    final restored = Recipe.fromJson(enriched.toJson());
    expect(restored.colors.single.references, enriched.colors.single.references);
    restored.colors.single.references[0][0] = .9;
    expect(enriched.copy().colors.single.references.first[0], isNot(.9));
  });

  test('kept and excluded colors track a global hue change without an agent', () {
    final before = scene(), after = scene(shift: 35), original = recipe(scene());
    final result = trackSource(before, after, original);
    expect(result.canApply, isTrue, reason: result.reason);
    final hueShift = (result.recipe!.colors.single.hue - original.colors.single.hue + 360) % 360;
    expect(hueShift, closeTo(35, 3));
    expect(result.recipe!.colors.single.width, original.colors.single.width);
    final weight = render(after, result.recipe!).weight;
    expect(weight[48 * 96 + 24], greaterThan(.95));
    expect(weight[48 * 96 + 72], lessThan(.05));
  });

  test('different changes to the same selected color require review', () {
    final result = trackSource(scene(), scene(shift: 40, split: true), recipe(scene()));
    expect(result.canApply, isFalse);
  });

  test('same dimensions do not make a shifted structure safe', () {
    final result = trackSource(scene(), scene(moved: true), recipe(scene()));
    expect(result.canApply, isFalse);
  });
}
