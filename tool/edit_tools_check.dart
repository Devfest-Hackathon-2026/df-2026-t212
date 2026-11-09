// A small live-model check of the same revision path used by Ask in Edit.
// op run --env-file .env.op -- dart run tool/edit_tools_check.dart
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:afterhue/agent/agent.dart';
import 'package:afterhue/agent/openai_agent.dart';
import 'package:afterhue/core/recipe.dart';
import 'package:afterhue/core/renderer.dart';

Future<void> main() async {
  KeptColor color(double hue) => KeptColor(l: 0.7, a: 0.13 * math.cos(hue * math.pi / 180),
    b: 0.13 * math.sin(hue * math.pi / 180), width: 32, softness: 31);
  final pink = color(14), warmPink = color(33), orange = color(43);
  final bytes = Uint8List(320 * 240 * 4);
  for (var y = 0; y < 240; y++) {
    for (var x = 0; x < 320; x++) {
      final c = x >= 160 ? orange : y < 120 ? pink : warmPink;
      bytes.setRange((y * 320 + x) * 4, (y * 320 + x) * 4 + 4, [...oklabToRgb8(c.l, c.a, c.b), 255]);
    }
  }
  final source = Rgba(320, 240, bytes);
  final current = Recipe(colors: [pink, warmPink], ambience: 0,
    area: Area(polygons: [[[0.1,0.1], [0.9,0.1], [0.9,0.9], [0.1,0.9]]], edge: 0.015));
  final agent = OpenAIAgent(apiKey: Platform.environment['OPENAI_API_KEY']!,
    model: Platform.environment['OPENAI_MODEL'] ?? 'gpt-6.1-terra', maxTurns: 6, maxRenders: 3);
  final actions = <String>[];
  final result = await agent.revise(source, current,
    const Revision(text: '左側のピンク（上のピンクと下の暖かいピンク）は残し、右側のオレンジだけを除外して。今のAreaの形はそのままで、Boundaryを-20px、Featherを30pxにして。他の設定は変えないで。'),
    originalSize: (width: 4000, height: 3000),
    log: (line) { actions.add(line.split(' ').first); stdout.writeln(line); });
  final rendered = render(source, result);
  final pinkWeight = rendered.weight[60 * 320 + 80];
  final warmWeight = rendered.weight[180 * 320 + 80];
  final orangeWeight = rendered.weight[120 * 320 + 240];
  final boundary = (result.area?.boundary ?? double.nan) * 3000;
  final feather = (result.area?.edge ?? double.nan) * 3000;
  final passed = result.excludedColors.isNotEmpty && actions.contains('adjust_area') &&
    (boundary + 20).abs() < 0.001 && (feather - 30).abs() < 0.001 &&
    pinkWeight > 0.95 && warmWeight > 0.95 && orangeWeight < 0.05 &&
    result.area!.polygons.toString() == current.area!.polygons.toString();
  stdout.writeln('Live check: ${passed ? 'PASS' : 'FAIL'}; '
    'pink=${pinkWeight.toStringAsFixed(3)}, warm pink=${warmWeight.toStringAsFixed(3)}, orange=${orangeWeight.toStringAsFixed(3)}; '
    'Boundary=$boundary px; Feather=$feather px');
  if (!passed) exitCode = 1;
}
