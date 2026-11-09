// Contact sheet of the ambience setting: each photo at 0, 0.4 and 0.8.
// dart run tool/ambience_check.dart out.jpg photo.jpg...
import 'dart:io';

import 'package:afterhue/agent/agent.dart';
import 'package:afterhue/core/renderer.dart';
import 'package:image/image.dart' as img;

Future<void> main(List<String> args) async {
  const levels = [0.0, 0.5, 1.0];
  const cell = 360;
  final photos = args.skip(1).toList();
  final sheet = img.Image(width: cell * levels.length, height: cell * photos.length);
  img.fill(sheet, color: img.ColorRgb8(255, 255, 255));
  for (var row = 0; row < photos.length; row++) {
    final d = img.copyResize(img.decodeJpg(File(photos[row]).readAsBytesSync())!, width: 600);
    final src = Rgba(d.width, d.height, d.convert(numChannels: 4).getBytes(order: img.ChannelOrder.rgba));
    final lab = toLab(src);
    final recipe = await LocalAgent().develop(src);
    for (var col = 0; col < levels.length; col++) {
      final r = recipe.copy()..vignette = levels[col];
      final res = render(src, r, lab: lab);
      var im = img.Image.fromBytes(width: src.width, height: src.height, bytes: res.image.pixels.buffer, numChannels: 4);
      im = img.copyResizeCropSquare(im, size: cell - 6);
      img.compositeImage(sheet, im, dstX: col * cell + 3, dstY: row * cell + 3);
    }
  }
  File(args[0]).writeAsBytesSync(img.encodeJpg(sheet, quality: 85));
}
