import 'dart:async';
import 'dart:convert';

import 'package:afterhue/agent/agent.dart';
import 'package:afterhue/agent/cloud_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class MemoryTokens implements CloudRefreshStore {
  String? value;
  @override Future<String?> read() async => value;
  @override Future<void> write(String token) async { value = token; }
}

void main() {
  test('signup is single flight, saved before use and refreshes the same identity', () async {
    final store = MemoryTokens();
    var signup = 0, refresh = 0;
    final wait = Completer<void>();
    final client = MockClient((request) async {
      if (request.url.host == 'identitytoolkit.googleapis.com') {
        signup++;
        expect(jsonDecode(request.body)['returnSecureToken'], true);
        await wait.future;
        return http.Response(jsonEncode({'refreshToken': 'refresh-1', 'idToken': 'id-1', 'expiresIn': '3600'}), 200);
      }
      refresh++;
      expect(request.url.host, 'securetoken.googleapis.com');
      expect(request.bodyFields['refresh_token'], 'refresh-1');
      return http.Response(jsonEncode({'refresh_token': 'refresh-2', 'id_token': 'id-2', 'expires_in': '3600'}), 200);
    });
    final auth = CloudAuth(apiKey: 'web-key', store: store, client: client);
    final a = auth.token(), b = auth.token();
    await Future<void>.delayed(Duration.zero);
    expect(signup, 1);
    wait.complete();
    expect(await a, 'id-1'); expect(await b, 'id-1');
    expect(store.value, 'refresh-1');
    expect(await auth.token(), 'id-1');
    expect(await auth.token(forceRefresh: true), 'id-2');
    expect(refresh, 1); expect(store.value, 'refresh-2');
  });

  test('failed refresh retains identity and never falls back to signup', () async {
    final store = MemoryTokens()..value = 'saved';
    var signup = 0;
    final auth = CloudAuth(apiKey: 'web-key', store: store, client: MockClient((r) async {
      if (r.url.host == 'identitytoolkit.googleapis.com') signup++;
      return http.Response('private error with saved token', 503);
    }));
    await expectLater(auth.token(), throwsA(isA<AgentError>().having((e) => e.message, 'message', isNot(contains('saved token')))));
    expect(store.value, 'saved'); expect(signup, 0);
  });

  test('cannot use a newly created identity when secure persistence fails', () async {
    final auth = CloudAuth(apiKey: 'web-key', store: FailingTokens(), client: MockClient((_) async =>
        http.Response(jsonEncode({'refreshToken': 'r', 'idToken': 'id', 'expiresIn': '3600'}), 200)));
    await expectLater(auth.token(), throwsA(isA<AgentError>()));
  });
}

class FailingTokens implements CloudRefreshStore {
  @override Future<String?> read() async => null;
  @override Future<void> write(String token) async => throw StateError('cannot store');
}
