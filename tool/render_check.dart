// Renders a tools/develop recipe with the Dart renderer, for parity checks.
// dart run tool/render_check.dart tools/develop/recipes/piano.json out.jpg
import 'dart:convert';
import 'dart:io';
import 'package:afterhue/core/recipe.dart';
import 'package:afterhue/core/renderer.dart';
import 'package:image/image.dart' as img;

void main(List<String> args) {
  final j = jsonDecode(File(args[0]).readAsStringSync()) as Map<String, dynamic>;
  final decoded = img.decodeJpg(File('tools/develop/${j['image']}').readAsBytesSync())!;
  final src = Rgba(decoded.width, decoded.height, decoded.convert(numChannels: 4).getBytes(order: img.ChannelOrder.rgba));
  final sw = Stopwatch()..start();
  final lab = toLab(src);
  final colors = <KeptColor>[];
  for (final c in (j['colors'] as List).cast<Map<String, dynamic>>()) {
    final k = c.containsKey('hex') ? keptColorFromHex(c['hex'])! : sampleColor(lab, (c['at'][0] as num).toDouble(), (c['at'][1] as num).toDouble());
    k.width = ((c['width'] ?? j['width'] ?? 16) as num).toDouble();
    k.softness = ((c['softness'] ?? j['softness'] ?? 24) as num).toDouble();
    k.chromaMin = ((c['chroma_min'] ?? 0.03) as num).toDouble();
    if (c['lightness'] != null) k.lightness = (c['lightness'] as List).cast<num>().map((e) => e.toDouble()).toList();
    colors.add(k);
  }
  final a = j['area'] as Map<String, dynamic>?;
  final area = a == null ? null : Area(
    polygons: [if (a['polygon'] != null) a['polygon'], ...?a['polygons']].map((p) => (p as List).map((q) => (q as List).cast<num>().map((e) => e.toDouble()).toList()).toList()).toList(),
    ellipses: [...?a['ellipses']].map((e) => (e as List).cast<num>().map((v) => v.toDouble()).toList()).toList(),
    edge: (a['edge'] as num).toDouble());
  final res = render(src, Recipe(colors: colors, area: area, contrast: 0.1), lab: lab);
  print('rendered ${src.width}x${src.height} in ${sw.elapsedMilliseconds} ms, kept ${(res.keptShare * 100).toStringAsFixed(1)}%');
  final out = img.Image.fromBytes(width: src.width, height: src.height, bytes: res.image.pixels.buffer, numChannels: 4);
  File(args[1]).writeAsBytesSync(img.encodeJpg(out, quality: 90));
}
