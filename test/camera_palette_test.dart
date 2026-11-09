import 'dart:math' as math;

import 'package:afterhue/core/camera_palette.dart';
import 'package:afterhue/core/recipe.dart';
import 'package:afterhue/core/renderer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:afterhue/ui/camera.dart';

Rgba scene(List<KeptColor> colors) {
  const width = 96, height = 96;
  final data = Uint8List(width * height * 4);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final c = colors[x * colors.length ~/ width];
      final rgb = oklabToRgb8(c.l, c.a, c.b);
      final offset = (y * width + x) * 4;
      data.setRange(offset, offset + 4, [...rgb, 255]);
    }
  }
  return Rgba(width, height, data);
}

KeptColor muted(double hue, double l, [double chroma = .022]) => KeptColor(
  l: l,
  a: chroma * math.cos(hue * math.pi / 180),
  b: chroma * math.sin(hue * math.pi / 180),
);
double gap(double a, double b) => ((a - b + 540) % 360 - 180).abs();

void main() {
  test('muted green, blue and brown remain separate camera choices', () {
    final input = [muted(185, .60), muted(255, .32), muted(75, .52)];
    final colors = cameraPalette(scene(input));
    expect(colors.length, greaterThanOrEqualTo(3));
    for (final wanted in input) {
      expect(
        colors.any((c) => gap(c.hue, wanted.hue) < 15),
        isTrue,
        reason: 'Muted hue ${wanted.hue} should not disappear.',
      );
    }
  });
  test(
    'picked muted colors survive development without retaining other hues',
    () {
      final input = [muted(185, .60), muted(255, .32), muted(75, .52)];
      final image = scene(input);
      final colors = cameraPalette(image);
      for (var i = 0; i < input.length; i++) {
        final chosen = colors.firstWhere((c) => gap(c.hue, input[i].hue) < 15);
        final weights = keepWeight(toLab(image), [chosen]);
        for (var j = 0; j < input.length; j++) {
          expect(
            weights[48 * 96 + j * 32 + 16],
            i == j ? greaterThan(.95) : lessThan(.05),
          );
        }
      }
    },
  );

  testWidgets(
    'live camera keeps muted candidates through repeated frames and picks one',
    (tester) async {
      tester.view.physicalSize = const Size(402, 874);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final frame = scene([muted(185, .60), muted(255, .32), muted(75, .52)]);
      const channel = MethodChannel('afterhue/camera');
      final looks = <Map>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        if (call.method == 'start') {
          return {'texture': 1, 'width': 600, 'height': 800};
        }
        if (call.method == 'thumb') {
          return {
            'width': frame.width,
            'height': frame.height,
            'pixels': frame.pixels,
          };
        }
        if (call.method == 'look') looks.add(call.arguments as Map);
        return null;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      await tester.pumpWidget(const MaterialApp(home: CameraScreen()));
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      final candidates = find.byWidgetPredicate(
        (w) => w is GestureDetector && w.key is ValueKey<int>,
      );
      expect(candidates, findsNWidgets(3));
      await tester.tap(candidates.first);
      await tester.pump();
      final colors = looks.last['colors'] as List;
      expect(colors, hasLength(1));
      expect((colors.single as List)[3], lessThan(.02));
      expect(find.byKey(const ValueKey('kept0')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  test('neutral frames do not invent colors', () {
    final colors = cameraPalette(
      scene([muted(80, .9, .001), muted(200, .4, .002)]),
    );
    expect(colors, isEmpty);
  });
}
