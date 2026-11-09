import 'dart:convert';
import 'dart:typed_data';
import 'package:afterhue/agent/agent.dart';
import 'package:afterhue/agent/openai_agent.dart';
import 'package:afterhue/core/recipe.dart';
import 'package:afterhue/core/renderer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('revision advertises and executes new edit tools through the API loop', () async {
    var turn = 0;
    Map<String, dynamic> call(String name, Map<String, dynamic> args) => {
      'type': 'function_call', 'name': name, 'arguments': jsonEncode(args), 'call_id': '$turn-$name',
    };
    final client = MockClient((request) async {
      final body = jsonDecode(request.body) as Map;
      final instructions = body['instructions'] as String;
      expect(instructions, contains('At boundary 0 all drawn-mask interior stays fully opaque'));
      expect(instructions, contains('boundary_px and feather_px'));
      expect(instructions, contains('nearby unwanted hues'));
      final tools = {for (final tool in body['tools'] as List) tool['name']: tool};
      expect(tools.values.every((tool) => tool['strict'] == false), isTrue);
      expect(tools['adjust_area']['parameters']['required'], isEmpty);
      for (final name in ['exclude_color', 'set_excluded_color', 'remove_excluded_color', 'adjust_area']) {
        expect(tools.containsKey(name), isTrue);
      }
      expect(tools['set_area']['parameters']['properties'], contains('strokes'));
      expect(tools['adjust_area']['parameters']['properties'], contains('boundary_px'));
      final input = body['input'] as List;
      if (turn == 0) {
        final description = input.first['content'].first['text'] as String;
        expect(description, contains('original photo 3000x4000'));
        expect(description, contains('Current settings:'));
      } else {
        final results = input.where((x) => x['type'] == 'function_call_output').toList();
        expect(results.any((x) => x['output'].toString().contains('Boundary -20.0 px; Feather 30.0 px')), isTrue);
        expect(results.every((x) => !x['output'].toString().startsWith('error:')), isTrue);
        expect(input.any((x) => x['role'] == 'user' && x['content'].length == 3), isTrue);
      }
      final output = turn++ == 0 ? [
        call('exclude_color', {'hex': '#D88B65'}),
        call('set_excluded_color', {'index': 0, 'width': 3, 'softness': 5}),
        call('adjust_area', {'boundary_px': -20, 'feather_px': 30}),
        call('render', {}),
      ] : [call('finish', {'subject': 'Pink subject', 'why': 'Kept pink and excluded orange.', 'change': 'Excluded orange and adjusted the boundary.'})];
      return http.Response(jsonEncode({'id': 'test-$turn', 'output': output}), 200);
    });
    final bytes = Uint8List.fromList(List.generate(32 * 24 * 4, (i) => i % 4 == 3 ? 255 : 150));
    final current = Recipe(colors: [keptColorFromHex('#E8A0B0')!], area: Area(ellipses: [[0.5, 0.5, 0.3, 0.3]],
      strokes: [Stroke(points: [[0.5, 0.5]], radius: 0.02)]));
    final agent = OpenAIAgent(apiKey: 'test-only', model: 'test-only');
    final result = await http.runWithClient(() => agent.revise(Rgba(32, 24, bytes), current,
      const Revision(text: 'Exclude orange, Boundary -20 px and Feather 30 px.'),
      originalSize: (width: 3000, height: 4000)), () => client);
    expect(turn, 2);
    expect(result.excludedColors.single.width, 3);
    expect(result.area!.boundary, closeTo(-20 / 3000, 1e-12));
    expect(result.area!.edge, 0.01);
    expect(result.area!.strokes.single.radius, 0.02);
    expect(current.excludedColors, isEmpty);
  });
  test('an unfinished tool loop never returns a completed recipe', () async {
    var requests = 0;
    final client = MockClient((_) async => http.Response(jsonEncode({
      'id': 'unfinished-${requests++}',
      'output': [{'type': 'function_call', 'call_id': 'probe-$requests', 'name': 'probe', 'arguments': '{"points":[[0.5,0.5]]}'}],
    }), 200));
    final agent = OpenAIAgent(apiKey: 'test-only', model: 'test-only', maxTurns: 2);
    final photo = Rgba(16, 16, Uint8List(16 * 16 * 4));
    await expectLater(http.runWithClient(() => agent.revise(photo, Recipe(colors: [keptColorFromHex('#E8A0B0')!]),
      const Revision(text: 'Adjust the boundary.')), () => client), throwsA(isA<AgentError>()));
    expect(requests, 2);
  });

}
