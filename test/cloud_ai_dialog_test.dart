import 'dart:io';
import 'package:afterhue/data/store.dart';
import 'package:afterhue/ui/cloud_ai_consent.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('decline is remembered and a later explicit request can enable cloud AI', (tester) async {
    final dir = Directory.systemTemp.createTempSync('afterhue-consent-dialog-');
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(paths, (_) async => dir.path);
    final store = Store.instance;
    await tester.runAsync(store.init);
    Widget app(int key) => MaterialApp(home: CloudAiConsentGate(key: ValueKey(key),
      child: Scaffold(body: Builder(builder: (context) => TextButton(
        onPressed: () => requestCloudAiConsent(context), child: const Text('Ask'))))));
    await tester.pumpWidget(app(1));
    await tester.pumpAndSettle();
    expect(find.text('Use Cloud AI?'), findsOneWidget);
    await tester.tap(find.text('Not now')); await tester.pumpAndSettle();
    expect(store.cloudAiConsent, false);
    expect(store.cloudAiConsentPromptSeen, true);
    await tester.pumpWidget(app(2)); await tester.pumpAndSettle();
    expect(find.text('Use Cloud AI?'), findsNothing);
    await tester.tap(find.text('Ask')); await tester.pumpAndSettle();
    await tester.tap(find.text('Use Cloud AI')); await tester.pumpAndSettle();
    expect(store.cloudAiConsent, true);
    expect(File('${dir.path}/cloud-ai-consent.json').readAsStringSync(), contains('"granted":true'));
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    // Store is a singleton for this isolated test process.

    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(paths, null);
    dir.deleteSync(recursive: true);
  }, skip: const String.fromEnvironment('AFTER_HUE_AI_URL').isEmpty);
}
