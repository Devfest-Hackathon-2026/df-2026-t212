import 'dart:async';
import 'dart:typed_data';

import 'package:afterhue/agent/agent.dart';
import 'package:afterhue/agent/openai_agent.dart';
import 'package:afterhue/core/renderer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

class _WaitingClient extends http.BaseClient {
  final sent = Completer<void>();
  final aborted = Completer<void>();
  bool closed = false;
  int requests = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests++;
    expect(request, isA<http.AbortableRequest>());
    final abort = (request as http.AbortableRequest).abortTrigger;
    expect(abort, isNotNull);
    sent.complete();
    await abort;
    aborted.complete();
    throw http.RequestAbortedException(request.url);
  }

  @override
  void close() => closed = true;
}

void main() {
  for (final judge in [false, true]) {
    test('cancelling ${judge ? 'judging' : 'development'} aborts the HTTP request', () async {
      final client = _WaitingClient();
      final run = AgentRun();
      final agent = OpenAIAgent(apiKey: 'test-only', model: 'test-only');
      final photo = Rgba(16, 16, Uint8List.fromList(List.generate(16 * 16 * 4, (i) => i % 4 == 3 ? 255 : 100)));
      final operation = http.runWithClient(
        () => judge ? agent.judge(photo, run: run) : agent.develop(photo, run: run),
        () => client,
      );
      final cancelled = expectLater(operation, throwsA(isA<AgentCancelled>()));
      await client.sent.future.timeout(const Duration(seconds: 10));
      run.cancel();
      await cancelled;
      await client.aborted.future.timeout(const Duration(seconds: 1));
      expect(client.closed, isTrue);
      expect(client.requests, 1);
    });
  }
}
