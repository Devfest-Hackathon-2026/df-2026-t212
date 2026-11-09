import 'dart:convert';
import 'package:afterhue/agent/agent.dart';
import 'package:afterhue/agent/openai_agent.dart';
import 'package:afterhue/core/recipe.dart';
import 'package:afterhue/core/renderer.dart';
import 'package:flutter/services.dart';
import 'package:afterhue/data/subject.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('agent invokes the human Area extraction channel, preserving edge settings', () async {
    const channel = MethodChannel('afterhue/subject');
    var extracts = 0;
    final polygon = [[.2, .2], [.8, .2], [.5, .9]];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      extracts++;
      expect(call.method, 'outline');
      expect(call.arguments['x'], .5);
      return [polygon];
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
    var turn = 0;
    final client = MockClient((request) async {
      final body = jsonDecode(request.body);
      expect((body['tools'] as List).any((tool) => tool['name'] == 'select_subject'), isTrue);
      expect(body['instructions'], contains('same on-device tool as a human Area tap'));
      final name = turn++ == 0 ? 'select_subject' : 'finish';
      return http.Response(jsonEncode({'id': '$turn', 'output': [{
        'type': 'function_call', 'name': name, 'call_id': '$turn',
        'arguments': jsonEncode(name == 'select_subject' ? {'x': .5, 'y': .5, 'mode': 'replace'} : {'subject': 'Object'}),
      }]}), 200);
    });
    final px = Rgba(16, 16, Uint8List.fromList(List.generate(1024, (i) => i % 4 == 3 ? 255 : 160)));
    final start = Recipe(colors: [keptColorFromHex('#CC3355')!], area: Area(boundary: -.01, edge: .03, ellipses: [[.5, .5, .2, .2]]));
    final result = await http.runWithClient(() => OpenAIAgent(apiKey: 'test', model: 'test', subjectExtractor: (photo, x, y) => Subject.outline(photo, Offset(x, y))).revise(px, start,
      const Revision(text: 'Select the object')),
      () => client);
    expect(extracts, 1);
    expect(result.area!.polygons, [polygon]);
    expect(result.area!.ellipses, isEmpty);
    expect(result.area!.boundary, -.01);
    expect(result.area!.edge, .03);
    final fresh = EditSession(px, originalSize: (width: 4000, height: 3000))
      ..subjectExtractor = (photo, x, y) => Subject.outline(photo, Offset(x, y));
    await fresh.selectSubject({'x': .5, 'y': .5});
    expect(fresh.recipe.area!.edge * 3000, 10, reason: 'New extraction uses 10 original-photo pixels of feather.');
    final session = EditSession(px, start: result)..subjectExtractor = (photo, x, y) => Subject.outline(photo, Offset(x, y));
    final before = session.recipe.area!.toJson();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (_) async => []);
    expect(await session.selectSubject({'x': .5, 'y': .5}), startsWith('error: no object'));
    expect(session.recipe.area!.toJson(), before);
    expect(await session.selectSubject({'x': -1, 'y': .5}), startsWith('error:'));
  });
}
