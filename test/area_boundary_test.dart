import 'dart:typed_data';
import 'package:afterhue/agent/agent.dart';
import 'package:afterhue/core/recipe.dart';
import 'package:afterhue/core/renderer.dart';
import 'package:flutter_test/flutter_test.dart';

Area square({double edge = 0.1}) => Area(polygons: [[[0.3, 0.3], [0.7, 0.3], [0.7, 0.7], [0.3, 0.7]]], edge: edge);

void main() {
  test('feather begins outside the fully opaque drawn area', () {
    final m = areaMask(100, 100, square());
    double at(int x) => m[50 * 100 + x];
    expect(at(30), 1);
    expect(at(69), 1);
    expect(at(29), inExclusiveRange(0.9, 1));
    expect(at(25), inExclusiveRange(0.4, 0.7));
    expect(at(19), 0);
  });
  test('boundary moves the full-opacity contour before feathering', () {
    final area = square();
    area.boundary = 0.05;
    final expanded = areaMask(100, 100, area);
    expect(expanded[5025], 1);
    expect(expanded[5020], inExclusiveRange(0.4, 0.7));
    area.boundary = -0.05;
    final contracted = areaMask(100, 100, area);
    expect(contracted[5035], 1);
    expect(contracted[5030], inExclusiveRange(0.4, 0.7));
    expect(contracted[5025], lessThan(0.02));
    area.edge = 0;
    expect(areaMask(100, 100, area)[5034], 0);
    area.boundary = 0;
    expect(areaMask(100, 100, area), areaMask(100, 100, square(edge: 0)));
  });

  test('boundary offsets unions and erased holes as one mask', () {
    final area = square(edge: 0)..strokes = [Stroke(points: [[0.5, 0.5]], radius: 0.06, erase: true)];
    final base = areaMask(100, 100, area);
    area.boundary = 0.03;
    final expanded = areaMask(100, 100, area);
    area.boundary = -0.03;
    final contracted = areaMask(100, 100, area);
    expect(base[5054], 0);
    expect(expanded[5054], 1);
    expect(expanded[5050], 0);
    for (var i = 0; i < base.length; i++) {
      expect(expanded[i], greaterThanOrEqualTo(base[i]));
      expect(contracted[i], lessThanOrEqualTo(base[i]));
    }
  });

  test('empty masks stay empty and explicit full masks can contract', () {
    final erased = Area(strokes: [Stroke(points: [[0.5, 0.5]], radius: 2, erase: true)], boundary: 0.2);
    expect(areaMask(40, 40, erased).every((v) => v == 0), isTrue);
    final full = Area(polygons: [[[0,0], [1,0], [1,1], [0,1]]], edge: 0, boundary: -0.1);
    final mask = areaMask(40, 40, full);
    expect(mask[20 * 40 + 3], 0);
    expect(mask[20 * 40 + 4], 1);
    expect(areaMask(40, 40, null).every((v) => v == 1), isTrue);
  });

  test('boundary and feather scale with preview and export resolution', () {
    final area = square()..boundary = -0.02;
    final small = areaMask(100, 100, area), large = areaMask(400, 400, area);
    for (var x = 10; x < 90; x++) {
      expect(small[50 * 100 + x], closeTo(large[202 * 400 + 4 * x + 2], 0.03));
    }
  });

  test('rendering does not blur the area boundary a second time', () {
    final rgb = oklabToRgb8(0.7, 0.1, 0.08);
    final bytes = Uint8List(100 * 100 * 4);
    for (var i = 0; i < bytes.length; i += 4) { bytes.setRange(i, i + 4, [...rgb, 255]); }
    final photo = Rgba(100, 100, bytes);
    final c = sampleColor(toLab(photo), 0.5, 0.5);
    final recipe = Recipe(colors: [c], area: square(), ambience: 0);
    final result = render(photo, recipe);
    expect(result.weight[5030], closeTo(1, 0.00001));
    expect(result.weight[5025], inExclusiveRange(0.4, 0.7));
  });

  test('agent boundary changes preserve shapes and support persistence and undo', () {
    final area = square()..strokes = [Stroke(points: [[0.5, 0.5]], radius: 0.04)];
    final source = Rgba(4, 4, Uint8List(64));
    final session = EditSession(source, start: Recipe(area: area));
    final before = session.recipe.copy();
    expect(session.execute('adjust_area', {'boundary': 0.05, 'edge': 0.08}), startsWith('ok;'));
    expect(session.recipe.area!.polygons, before.area!.polygons);
    expect(session.recipe.area!.strokes.single.radius, 0.04);
    expect(session.recipe.area!.boundary, 0.05);
    expect(before.area!.boundary, 0);
    final saved = Recipe.fromJson(session.recipe.toJson());
    expect(saved.area!.boundary, 0.05);
    expect(saved.area!.edge, 0.08);
    expect(session.execute('adjust_area', {'boundary': 2}), startsWith('error:'));
    expect(session.recipe.area!.boundary, 0.05);
    expect(Area.fromJson({'polygons': area.polygons}).boundary, 0);
    expect(session.recipe.signature, isNot(before.signature));
  });

  test('agent pixel adjustments use original dimensions, not preview dimensions', () {
    final session = EditSession(Rgba(30, 40, Uint8List(30 * 40 * 4)),
      start: Recipe(area: square()), originalSize: (width: 3000, height: 4000));
    expect(session.execute('adjust_area', {'boundary_px': -20, 'feather_px': 30}),
      'ok; Boundary -20.0 px; Feather 30.0 px (original photo)');
    expect(session.recipe.area!.boundary, closeTo(-20 / 3000, 1e-12));
    expect(session.recipe.area!.edge, 0.01);
    expect(session.execute('adjust_area', {'boundary': 0.1, 'boundary_px': 10}), startsWith('error:'));
    expect(session.recipe.area!.boundary, closeTo(-20 / 3000, 1e-12));
  });

}
