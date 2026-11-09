import 'dart:math' as math;
import 'dart:typed_data';

import 'package:afterhue/core/recipe.dart';
import 'package:afterhue/agent/agent.dart';
import 'package:afterhue/core/renderer.dart';
import 'package:flutter_test/flutter_test.dart';

KeptColor color(double hue, {double width = 8, double edge = 8}) => KeptColor(
  l: 0.7, a: 0.13 * math.cos(hue * math.pi / 180), b: 0.13 * math.sin(hue * math.pi / 180),
  width: width, softness: edge,
);

Rgba strips(List<KeptColor> colors) {
  final bytes = Uint8List(96 * 32 * 4);
  for (var y = 0; y < 32; y++) {
    for (var x = 0; x < 96; x++) {
      final c = colors[x * colors.length ~/ 96];
      final rgb = oklabToRgb8(c.l, c.a, c.b);
      final offset = (y * 96 + x) * 4;
      bytes.setRange(offset, offset + 4, [...rgb, 255]);
    }
  }
  return Rgba(96, 32, bytes);
}

void main() {
  test('exclusion removes orange while retaining pink in an overlapping keep range', () {
    final pink = color(350, width: 60), orange = color(40);
    final source = strips([pink, orange]);
    final recipe = Recipe(colors: [pink], ambience: 0);
    final before = render(source, recipe);
    recipe.excludedColors.add(orange);
    final after = render(source, recipe);
    const pinkPixel = 16 * 96 + 24, orangePixel = 16 * 96 + 72;
    expect(before.weight[pinkPixel], greaterThan(0.99));
    expect(before.weight[orangePixel], greaterThan(0.99));
    expect(after.weight[pinkPixel], greaterThan(0.99));
    expect(after.weight[orangePixel], lessThan(0.001));
    final p = orangePixel * 4;
    expect((after.image.pixels[p] - after.image.pixels[p + 1]).abs(), lessThanOrEqualTo(1));
    expect((after.image.pixels[p + 1] - after.image.pixels[p + 2]).abs(), lessThanOrEqualTo(1));
    recipe.excludedColors.clear();
    expect(render(source, recipe).image.pixels, before.image.pixels);
  });

  test('nearby exclusion protects the kept pink sample and its close shades', () {
    // The wisteria edit has kept hue centers near 14 and 33 degrees.
    // Its warm pink and an orange ten degrees away used to overlap heavily.
    final pink = color(33, width: 32, edge: 31);
    final orange = color(43);
    final source = strips([color(33), color(35), orange]);
    final recipe = Recipe(colors: [color(14, width: 32), pink], excludedColors: [orange]);
    final weight = render(source, recipe).weight;
    expect(weight[16 * 96 + 16], greaterThan(0.98));
    expect(weight[16 * 96 + 48], greaterThan(0.95));
    expect(weight[16 * 96 + 80], lessThan(0.001));
  });

  test('exclusions win over multiple keeps and never add color outside an area', () {
    final orange = color(40);
    final source = strips([orange, orange]);
    final recipe = Recipe(
      colors: [orange.copy(), color(350, width: 60)],
      excludedColors: [orange.copy()],
      area: Area(ellipses: [[0.25, 0.5, 0.2, 0.3]]),
    );
    expect(render(source, recipe).weight.every((w) => w < 0.001), isTrue);
  });

  test('soft exclusion has a gradual edge across the hue wrap', () {
    final recipe = Recipe(colors: [color(0, width: 60)], excludedColors: [color(0, width: 5, edge: 20)]);
    final source = strips([color(359), color(15), color(30)]);
    final weight = render(source, recipe).weight;
    expect(weight[16 * 96 + 16], lessThan(0.001));
    expect(weight[16 * 96 + 48], inExclusiveRange(0.2, 0.8));
    expect(weight[16 * 96 + 80], greaterThan(0.99));
  });

  test('close hues separate smoothly across zero degrees', () {
    final source = strips([color(355), color(357), color(0), color(3), color(5)]);
    final recipe = Recipe(colors: [color(355, width: 40)], excludedColors: [color(5)]);
    final weight = render(source, recipe).weight;
    final samples = [for (final x in [9, 28, 48, 67, 86]) weight[16 * 96 + x]];
    expect(samples.first, greaterThan(0.99));
    expect(samples[1], greaterThan(0.95));
    expect(samples[2], inExclusiveRange(0.2, 0.8));
    expect(samples[3], lessThan(0.05));
    expect(samples.last, lessThan(0.001));
    for (var i = 1; i < samples.length; i++) { expect(samples[i], lessThanOrEqualTo(samples[i - 1])); }
  });

  test('hue protection works for pale pink and multiple exclusions', () {
    final pink = color(33, width: 40);
    final pale = pink.copy()..l = 0.87..a *= 0.45..b *= 0.45;
    final orange = color(43), red = color(23);
    final source = strips([pale, orange, red]);
    final recipe = Recipe(colors: [pink], excludedColors: [orange, red]);
    final weight = render(source, recipe).weight;
    expect(weight[16 * 96 + 16], greaterThan(0.98));
    expect(weight[16 * 96 + 48], lessThan(0.001));
    expect(weight[16 * 96 + 80], lessThan(0.001));
  });

  test('the agent can add, replace, adjust and remove the same exclusions', () {
    final source = strips([color(350), color(40)]);
    final session = EditSession(source, start: Recipe(colors: [color(350, width: 60)]));
    expect(session.execute('exclude_color', {'x': 0.75, 'y': 0.5, 'hex': ''}), startsWith('excluded color 0'));
    final excluded = session.recipe.excludedColors.single;
    expect(excluded.width, Recipe.defaultExcludeWidth);
    expect(render(source, session.recipe).weight[16 * 96 + 72], lessThan(0.001));
    expect(session.execute('set_excluded_color', {'index': 0, 'width': 4, 'softness': 6}), 'ok');
    expect(excluded.width, 4);
    expect(excluded.softness, 6);
    expect(session.execute('set_excluded_color', {'index': 0, 'x': 0.25, 'y': 0.5}), 'ok');
    expect(excluded.hue, closeTo(350, 1));
    expect(excluded.width, 4);
    expect(session.execute('remove_excluded_color', {'index': 0}), 'ok');
    expect(session.recipe.excludedColors, isEmpty);
    expect(session.recipe.colors, hasLength(1));
    expect(session.execute('set_excluded_color', {'index': 0}), startsWith('error:'));
  });

  test('saved exclusions and history copies stay independent; old recipes remain compatible', () {
    final original = Recipe(colors: [color(350)]);
    final legacy = original.toJson();
    expect(legacy.containsKey('excludedColors'), isFalse);
    expect(Recipe.fromJson(legacy).excludedColors, isEmpty);
    final edited = original.copy()..excludedColors.add(color(40));
    expect(original.excludedColors, isEmpty);
    expect(edited.signature, isNot(original.signature));
    final saved = Recipe.fromJson(edited.toJson());
    expect(saved.excludedColors.single.hue, closeTo(40, 0.001));
    expect(saved.signature, isNot(saved.toJson().toString().hashCode.toRadixString(16)));
    expect(original.signature, original.toJson().toString().hashCode.toRadixString(16));
    final undo = saved.copy();
    saved.excludedColors.single.width = 25;
    expect(undo.excludedColors.single.width, 8);
    expect(saved.colors.single.hue, closeTo(350, 0.001));
  });
}
