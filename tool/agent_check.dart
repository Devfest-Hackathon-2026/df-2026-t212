// Runs the OpenAI agent on one image, headless.
// op run --env-file .env.op -- dart run tool/agent_check.dart tools/develop/samples/piano.jpg out.jpg
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:afterhue/agent/openai_agent.dart';
import 'package:afterhue/core/renderer.dart';
import 'package:image/image.dart' as img;

Future<void> main(List<String> args) async {
  var im = img.decodeImage(File(args[0]).readAsBytesSync())!;
  final side = int.tryParse(Platform.environment['SIDE'] ?? '') ?? 768;
  if (math.max(im.width, im.height) > side) {
    im = im.width >= im.height ? img.copyResize(im, width: side) : img.copyResize(im, height: side);
  }
  final src = Rgba(im.width, im.height, im.convert(numChannels: 4).getBytes(order: img.ChannelOrder.rgba));
  final agent = OpenAIAgent(
    apiKey: Platform.environment['OPENAI_API_KEY']!,
    model: Platform.environment['OPENAI_MODEL'] ?? 'gpt-6.1-terra',
  );
  final sw = Stopwatch()..start();
  final recipe = await agent.develop(src, log: (s) => stdout.writeln('  ${sw.elapsed.inSeconds}s $s'));
  stdout.writeln('done in ${sw.elapsed.inSeconds}s');
  stdout.writeln(const JsonEncoder.withIndent('  ').convert(recipe.toJson()));
  if (args.length > 1) {
    // Recipes use normalized coordinates, so render the output at any size.
    final outSide = int.tryParse(Platform.environment['OUT_SIDE'] ?? '') ?? side;
    var big = img.decodeImage(File(args[0]).readAsBytesSync())!;
    if (math.max(big.width, big.height) > outSide) {
      big = big.width >= big.height ? img.copyResize(big, width: outSide) : img.copyResize(big, height: outSide);
    }
    final full = Rgba(big.width, big.height, big.convert(numChannels: 4).getBytes(order: img.ChannelOrder.rgba));
    final r = render(full, recipe);
    final out = img.Image.fromBytes(width: r.image.width, height: r.image.height, bytes: r.image.pixels.buffer, numChannels: 4);
    File(args[1]).writeAsBytesSync(img.encodeJpg(out.convert(numChannels: 3), quality: 88));
  }
}
