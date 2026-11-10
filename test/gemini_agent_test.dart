import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:afterhue/agent/agent.dart';
import 'package:afterhue/agent/editing_contract.dart';
import 'package:afterhue/agent/gemini_agent.dart';
import 'package:afterhue/core/recipe.dart';
import 'package:afterhue/core/renderer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Rgba photo() => Rgba(32, 24, Uint8List.fromList(List.generate(32 * 24 * 4, (i) => i % 4 == 3 ? 255 : 150)));
Map<String, dynamic> call(String name, Map<String, dynamic> args, {String? id, String? signature}) => {
  'functionCall': {'name': name, 'args': args, 'id': ?id},
  'thoughtSignature': ?signature,
};
http.Response model(List<Map<String, dynamic>> parts, {String finish = 'STOP'}) => http.Response(jsonEncode({
  'candidates': [{'content': {'role': 'model', 'parts': parts}, 'finishReason': finish}],
}), 200);
GeminiAgent agent({int maxRenders = 4, int maxTurns = 14, SubjectExtractor? extractor, Duration timeout = const Duration(seconds: 120)}) =>
  GeminiAgent(baseUrl: 'https://cloud.test/', tokenProvider: ({forceRefresh = false}) async => 'test-token', maxRenders: maxRenders, maxTurns: maxTurns,
    subjectExtractor: extractor, requestTimeout: timeout);

class WaitingClient extends http.BaseClient {
  final sent = Completer<void>(), aborted = Completer<void>();
  bool closed = false;
  @override Future<http.StreamedResponse> send(http.BaseRequest request) async {
    expect(request, isA<http.AbortableRequest>());
    sent.complete();
    await (request as http.AbortableRequest).abortTrigger;
    aborted.complete();
    throw http.RequestAbortedException(request.url);
  }
  @override void close() { closed = true; }
}

void main() {
  test('judge uses native Gemini JSON and app bearer only', () async {
    final client = MockClient((r) async {
      expect(r.url.toString(), 'https://cloud.test/v1/generate');
      expect(r.headers['Authorization'], 'Bearer test-token');
      final body = jsonDecode(r.body) as Map;
      expect(body['purpose'], 'judge'); expect(body.containsKey('model'), false);
      expect(body.containsKey('input'), false);
      expect(body['generationConfig']['responseMimeType'], 'application/json');
      expect(body['contents'][0]['parts'][0]['inlineData']['mimeType'], 'image/jpeg');
      return model([{'text': '{"develop":true,"subject":"Pink flowers","reason":"Clear subject"}'}]);
    });
    final result = await http.runWithClient(() => agent().judge(photo()), () => client);
    expect(result.develop, true); expect(result.subject, 'Pink flowers');
  });

  test('revision keeps complete signed model parts and executes shared advanced tools', () async {
    var turn = 0, extracted = 0;
    final signedParts = <Map<String, dynamic>>[
      {'thought': true, 'text': 'opaque model part', 'thoughtSignature': 'text-signature'},
      call('exclude_color', {'hex': '#D88B65'}, id: 'first', signature: 'function-signature'),
      call('set_excluded_color', {'index': 0, 'width': 3, 'softness': 5}),
      call('select_subject', {'x': .5, 'y': .5}),
      call('adjust_area', {'boundary_px': -20, 'feather_px': 30}),
      call('set_saturation', {'value': 1.2}),
      call('set_crop', {'rect': [.1, .1, .9, .9], 'turns': 1}),
      call('render', {}),
    ];
    final client = MockClient((r) async {
      final body = jsonDecode(r.body) as Map;
      expect(body['purpose'], 'develop');
      final declarations = body['tools'][0]['functionDeclarations'] as List;
      expect(declarations.map((d) => d['name']).toList(), editingTools.map((t) => t['name']).toList());
      expect(declarations.first['parametersJsonSchema'], editingTools.first['parameters']);
      final contents = body['contents'] as List;
      if (turn++ == 0) {
        expect(contents.first['parts'].length, 3);
        expect(contents.first['parts'][0]['text'], contains('original photo 3000x4000'));
        expect(contents.first['parts'][0]['text'], contains('Current settings:'));
        return model(signedParts);
      }
      // Both thought and function signatures, their ordering and arbitrary
      // fields survive exactly; do not synthesize a replacement model message.
      expect(contents[1], {'role': 'model', 'parts': signedParts});
      final results = (contents[2]['parts'] as List).where((p) => p['functionResponse'] != null).toList();
      expect(results.length, 7);
      expect(results.first['functionResponse']['id'], 'first');
      expect(results.map((p) => p['functionResponse']['name']).toList(), signedParts.skip(1).map((p) => p['functionCall']['name']).toList());
      expect(results.any((p) => p['functionResponse']['response']['result'].toString().contains('Boundary -20.0 px; Feather 30.0 px')), true);
      expect((contents[2]['parts'] as List).every((p) => p['functionResponse'] != null), true,
        reason: 'Vertex rejects tool responses mixed with preview image parts');
      expect(contents[3]['role'], 'user');
      expect((contents[3]['parts'] as List).where((p) => p['inlineData'] != null).length, 2);
      expect((contents[3]['parts'] as List).any((p) => p['functionResponse'] != null), false);
      return model([call('finish', {'subject': 'Pink flowers', 'why': 'Kept pink.', 'change': 'Excluded orange and refined the area.'})]);
    });
    final run = AgentRun();
    final statuses = <String>[];
    final sub = run.changes.listen((_) => statuses.add(run.status));
    final current = Recipe(colors: [keptColorFromHex('#E8A0B0')!]);
    final result = await http.runWithClient(() => agent(extractor: (p, x, y) async {
      extracted++; return [[[.2, .2], [.8, .2], [.8, .8], [.2, .8]]];
    }).revise(photo(), current, const Revision(text: 'Exclude orange and refine the edges'),
      originalSize: (width: 3000, height: 4000), run: run), () => client);
    expect(turn, 2); expect(extracted, 1);
    expect(result.excludedColors.single.width, 3);
    expect(result.area!.boundary, closeTo(-20 / 3000, 1e-12));
    expect(result.area!.edge, .01); expect(result.saturation, 1.2);
    expect(result.crop!.turns, 1);
    expect(current.excludedColors, isEmpty);
    expect(run.note, 'Excluded orange and refined the area.');
    await Future<void>.delayed(Duration.zero);
    expect(statuses, contains('render')); run.close(); await sub.cancel();
  });

  test('render budget is enforced and malformed tool arguments can be corrected', () async {
    var turn = 0;
    final client = MockClient((r) async {
      final body = jsonDecode(r.body) as Map;
      if (turn++ == 0) { return model([
        call('add_color', {'hex': '#E8A0B0'}), call('set_saturation', {'value': 'bad'}),
        call('render', {}), call('render', {}),
      ]); }
      final parts = (body['contents'] as List)[2]['parts'] as List;
      final outputs = parts.where((p) => p['functionResponse'] != null).map((p) => p['functionResponse']['response']['result']).toList();
      expect(outputs[1], startsWith('error:'));
      expect(outputs[3], contains('render limit reached'));
      return model([call('finish', {'subject': 'Pink', 'why': 'Pink stands out.'})]);
    });
    final result = await http.runWithClient(() => agent(maxRenders: 1).develop(photo()), () => client);
    expect(result.colors.length, 1); expect(turn, 2);
  });

  test('plain text cannot be reported as a successful edit', () async {
    var calls = 0;
    final client = MockClient((_) async { calls++; return model([{'text': 'Done.'}]); });
    await expectLater(http.runWithClient(() => agent(maxTurns: 2).develop(photo()), () => client), throwsA(isA<AgentError>()));
    expect(calls, 2);
  });
  test('upstream errors are useful without echoing tokens or private response bodies', () async {
    final client = MockClient((_) async => http.Response('secret-token: private upstream trace', 503));
    await expectLater(http.runWithClient(() => agent().judge(photo()), () => client),
      throwsA(isA<AgentError>().having((e) => e.message, 'message', allOf(contains('temporarily unavailable'), isNot(contains('secret-token'))))));
  });
  test('401 refreshes once and retries the identical request', () async {
    var count = 0, refreshes = 0;
    String? firstBody;
    final client = MockClient((request) async {
      count++;
      if (count == 1) {
        expect(request.headers['Authorization'], 'Bearer old');
        firstBody = request.body;
        return http.Response('expired', 401);
      }
      expect(request.headers['Authorization'], 'Bearer new');
      expect(request.body, firstBody);
      return model([{'text': '{"develop":true,"subject":"Pink","reason":"Clear"}'}]);
    });
    final instance = GeminiAgent(baseUrl: 'https://cloud.test', tokenProvider: ({forceRefresh = false}) async {
      if (forceRefresh) refreshes++;
      return forceRefresh ? 'new' : 'old';
    });
    final result = await http.runWithClient(() => instance.judge(photo()), () => client);
    expect(result.develop, true); expect(count, 2); expect(refreshes, 1);
  });
  test('a second 401 stops without another refresh or leaking the response', () async {
    var requests = 0, refreshes = 0;
    final instance = GeminiAgent(baseUrl: 'https://cloud.test', tokenProvider: ({forceRefresh = false}) async {
      if (forceRefresh) refreshes++;
      return 'id-token';
    });
    final client = MockClient((_) async { requests++; return http.Response('private credentials', 401); });
    await expectLater(http.runWithClient(() => instance.judge(photo()), () => client),
      throwsA(isA<AgentError>().having((e) => e.message, 'message',
        allOf(contains('authorize'), isNot(contains('private credentials'))))));
    expect(requests, 2); expect(refreshes, 1);
  });
  test('cancelling while authentication is pending does not send a photo', () async {
    final started = Completer<void>(), pending = Completer<String>();
    var sent = false;
    final run = AgentRun();
    final instance = GeminiAgent(baseUrl: 'https://cloud.test', tokenProvider: ({forceRefresh = false}) {
      started.complete(); return pending.future;
    });
    final operation = http.runWithClient(() => instance.judge(photo(), run: run),
      () => MockClient((_) async { sent = true; return http.Response('', 200); }));
    final failure = expectLater(operation, throwsA(isA<AgentCancelled>()));
    await started.future.timeout(const Duration(seconds: 10)); run.cancel();
    await failure; expect(sent, false);
    pending.complete('token');
    run.close();
  });
  test('revoking consent while authentication is pending blocks the request', () async {
    final started = Completer<void>(), pending = Completer<String>();
    var allowed = true, sent = false;
    final instance = GeminiAgent(baseUrl: 'https://cloud.test', allowed: () => allowed,
      tokenProvider: ({forceRefresh = false}) { started.complete(); return pending.future; });
    final operation = http.runWithClient(() => instance.judge(photo()),
      () => MockClient((_) async { sent = true; return http.Response('', 200); }));
    final failure = expectLater(operation, throwsA(isA<AgentError>()));
    await started.future.timeout(const Duration(seconds: 10));
    allowed = false; pending.complete('token');
    await failure; expect(sent, false);
  });
  for (final (status, code, expected) in [
    (429, 'daily_limit_reached', 'daily service limit'),
    (429, 'user_daily_limit_reached', 'your daily Cloud AI limit'),
    (429, 'rate_limited', 'Too many Cloud AI requests'),
    (503, 'quota_unavailable', 'cannot check its usage limits'),
  ]) {
    test('shows useful $code without exposing server messages', () async {
      final client = MockClient((_) async => http.Response(jsonEncode({
        'error': {'code': code, 'message': 'private upstream information'},
      }), status));
      await expectLater(http.runWithClient(() => agent().judge(photo()), () => client),
        throwsA(isA<AgentError>().having((e) => e.message, 'message',
          allOf(contains(expected), isNot(contains('private upstream information'))))));
    });
  }
  test('malformed or oversized error response uses safe status fallback', () async {
    for (final body in ['{bad', 'x' * 9000]) {
      final client = MockClient((_) async => http.Response(body, 429));
      await expectLater(http.runWithClient(() => agent().judge(photo()), () => client),
        throwsA(isA<AgentError>().having((e) => e.message, 'message', contains('busy'))));
    }
  });
  test('a blocked response fails explicitly', () async {
    final client = MockClient((_) async => http.Response('{"promptFeedback":{"blockReason":"SAFETY"}}', 200));
    await expectLater(http.runWithClient(() => agent().judge(photo()), () => client), throwsA(isA<AgentError>()));
  });
  for (final judge in [false, true]) {
    test('cancelling ${judge ? 'judge' : 'develop'} aborts transport immediately', () async {
      final client = WaitingClient(), run = AgentRun();
      final operation = http.runWithClient(() => judge ? agent().judge(photo(), run: run) : agent().develop(photo(), run: run), () => client);
      final failure = expectLater(operation, throwsA(isA<AgentCancelled>()));
      await client.sent.future.timeout(const Duration(seconds: 10)); run.cancel();
      await failure; await client.aborted.future.timeout(const Duration(seconds: 1));
      expect(client.closed, true);
    });
  }
  test('timeout includes header wait and aborts the underlying request', () async {
    final client = WaitingClient();
    await expectLater(http.runWithClient(() => agent(timeout: const Duration(milliseconds: 20)).judge(photo()), () => client),
      throwsA(isA<AgentError>().having((e) => e.message, 'message', contains('timed out'))));
    await client.aborted.future.timeout(const Duration(seconds: 1)); expect(client.closed, true);
  });
}
