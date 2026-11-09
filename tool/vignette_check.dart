// Vignette check. With no photos, compares vignetteGain against values
// measured from CIVignetteEffect (1200x800, radius 300 px, softness 0.5).
// With photos: dart run tool/vignette_check.dart out.jpg photo.jpg...
// writes a strength x radius grid per photo.
import 'dart:io';
import 'dart:math' as math;

import 'package:afterhue/agent/agent.dart';
import 'package:afterhue/core/renderer.dart';
import 'package:image/image.dart' as img;

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    const ci = [1.000, 0.988, 0.920, 0.779, 0.585, 0.382, 0.212, 0.098, 0.036, 0.010, 0.002, 0.000];
    final hd = math.sqrt(600 * 600 + 400 * 400);
    for (var k = 0; k < ci.length; k++) {
      print('x=${k * 50}  ci=${ci[k].toStringAsFixed(3)}  ours=${vignetteGain(k * 50 / hd, 1, 300 / hd).toStringAsFixed(3)}');
    }
    return;
  }
  const strengths = [0.3, 0.6, 1.0];
  const radii = [0.5, 0.8, 1.1];
  const cell = 300;
  final photos = args.skip(1).toList();
  final sheet = img.Image(width: cell * radii.length, height: cell * strengths.length * photos.length);
  img.fill(sheet, color: img.ColorRgb8(255, 255, 255));
  for (var p = 0; p < photos.length; p++) {
    final d = img.copyResize(img.decodeJpg(File(photos[p]).readAsBytesSync())!, width: 600);
    final src = Rgba(d.width, d.height, d.convert(numChannels: 4).getBytes(order: img.ChannelOrder.rgba));
    final lab = toLab(src);
    final recipe = await LocalAgent().develop(src);
    for (var si = 0; si < strengths.length; si++) {
      for (var ri = 0; ri < radii.length; ri++) {
        final r = recipe.copy()
          ..vignette = strengths[si]
          ..vignetteRadius = radii[ri];
        final res = render(src, r, lab: lab);
        var im = img.Image.fromBytes(width: src.width, height: src.height, bytes: res.image.pixels.buffer, numChannels: 4);
        im = img.copyResize(im, width: cell - 6);
        img.compositeImage(sheet, im, dstX: ri * cell + 3, dstY: (p * strengths.length + si) * cell + 3);
      }
    }
  }
  File(args[0]).writeAsBytesSync(img.encodeJpg(sheet, quality: 85));
}
