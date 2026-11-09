// Swatch cutouts: for each photo, its hue-peak colors as flat squares and,
// under each, the piece of the photo colorPatch picks for it.
// dart run tool/patch_check.dart out.jpg photo.jpg...
import 'dart:io';
import 'dart:math' as math;

import 'package:afterhue/core/recipe.dart';
import 'package:afterhue/core/renderer.dart';
import 'package:image/image.dart' as img;

void main(List<String> args) {
  const cell = 120, cols = 6;
  final photos = args.skip(1).toList();
  final sheet = img.Image(width: cell * cols, height: cell * 2 * photos.length);
  img.fill(sheet, color: img.ColorRgb8(255, 255, 255));
  for (var p = 0; p < photos.length; p++) {
    final d = img.copyResize(img.decodeJpg(File(photos[p]).readAsBytesSync())!, width: 1024);
    final src = Rgba(d.width, d.height, d.convert(numChannels: 4).getBytes(order: img.ChannelOrder.rgba));
    final lab = toLab(src);
    final cands = huePeaks(lab, top: 8).where((e) => e.meanChroma > 0.04).map((e) {
      final h = (e.from + e.to) / 2 * math.pi / 180;
      return KeptColor(l: e.meanL, a: e.meanChroma * math.cos(h), b: e.meanChroma * math.sin(h));
    }).take(cols).toList();
    for (var i = 0; i < cands.length; i++) {
      final rgb = oklabToRgb8(cands[i].l, cands[i].a, cands[i].b);
      img.fillRect(sheet, x1: i * cell + 4, y1: p * 2 * cell + 4, x2: (i + 1) * cell - 4, y2: p * 2 * cell + cell - 4, color: img.ColorRgb8(rgb[0], rgb[1], rgb[2]));
      final patch = colorPatch(src, cands[i]);
      if (patch == null) continue;
      var im = img.Image.fromBytes(width: patch.width, height: patch.height, bytes: patch.pixels.buffer, numChannels: 4);
      im = img.copyResize(im, width: cell - 8, height: cell - 8);
      img.compositeImage(sheet, im, dstX: i * cell + 4, dstY: (p * 2 + 1) * cell + 4);
    }
  }
  File(args[0]).writeAsBytesSync(img.encodeJpg(sheet, quality: 88));
}
