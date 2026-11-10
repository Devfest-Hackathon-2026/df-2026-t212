import 'dart:convert';
import 'dart:io';

import 'package:afterhue/agent/agent.dart';
import 'package:afterhue/core/renderer.dart';
import 'package:afterhue/data/store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('cloud AI is blocked before consent, does not consume queue, and persists revocation', (tester) async {
    final dir = Directory.systemTemp.createTempSync('afterhue-consent-');
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(paths, (_) async => dir.path);
    final item = PhotoItem(id: 'photo', taken: DateTime(2026), width: 10, height: 10,
      state: Develop.manual);
    File('${dir.path}/state.json').writeAsStringSync(jsonEncode({'items': [item.toJson()]}));
    final store = Store.instance;
    await tester.runAsync(store.init);
    expect(store.cloudAiConfigured, true, reason: 'Run this test with the three Cloud AI dart-defines.');
    expect(store.cloudAiBlocked, true);
    expect(store.cloudAiConsentPromptSeen, false);
    final photo = Rgba(1, 1, Uint8List.fromList([0, 0, 0, 255]));
    await expectLater(store.agent.develop(photo), throwsA(isA<AgentError>()));
    store.developMore();
    expect(store.byKey('photo')!.state, Develop.pending);
    expect(store.developing, false);
    expect(store.byKey('photo')!.attempts, 0);
    // Avoid starting a real photo job while exercising persistence.
    store.byKey('photo')!.state = Develop.manual;
    await tester.runAsync(() async {
      store.setCloudAiConsent(true);
      expect(store.cloudAiBlocked, false);
      store.setCloudAiConsent(false);
      final immediate = jsonDecode(File('${dir.path}/cloud-ai-consent.json').readAsStringSync()) as Map;
      expect(immediate['granted'], false);
      expect(store.cloudAiBlocked, true);
      expect(store.cloudAiConsentPromptSeen, true);
      await Future<void>.delayed(const Duration(milliseconds: 700));
    });
    final saved = jsonDecode(File('${dir.path}/state.json').readAsStringSync()) as Map;
    expect(saved['cloudAiConsent'], false);
    expect(saved['cloudAiConsentPromptSeen'], true);
    await tester.runAsync(store.resetForDemo);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(paths, null);
    dir.deleteSync(recursive: true);
  }, skip: const String.fromEnvironment('AFTER_HUE_AI_URL').isEmpty);

}
