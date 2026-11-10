import 'dart:convert';
import 'dart:io';

import 'package:afterhue/agent/agent.dart';
import 'package:afterhue/core/recipe.dart';
import 'package:afterhue/core/renderer.dart';
import 'package:afterhue/data/photo_source.dart';
import 'package:flutter/services.dart';

import 'package:afterhue/data/activity.dart';
import 'package:afterhue/data/store.dart';
import 'package:afterhue/ui/activity.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

class LimitAgent extends DevelopAgent {
  int calls = 0;
  @override String get name => 'Limit fixture';
  @override Future<Recipe> develop(Rgba photo, {void Function(String)? log, AgentRun? run, ({int width, int height})? originalSize}) async {
    calls++;
    throw AgentError(ActivityFailureReason.dailyLimit.message);
  }
}

void main() {
  test('only known failure categories are persisted and old or unknown values are ignored', () {
    for (final reason in ActivityFailureReason.values) {
      final entry = ActivityEntry(id: '1', kind: ActivityKind.developBatch,
        keys: ['photo'], started: DateTime(2026));
      entry.finish('photo', ActivityOutcome.failed, error: reason.message);
      final restored = ActivityEntry.fromJson(jsonDecode(jsonEncode(entry.toJson())) as Map<String, dynamic>);
      expect(restored.failureReason, reason);
      expect(restored.count(ActivityOutcome.failed), 1);
      expect(jsonEncode(entry.toJson()), isNot(contains(reason.message)));
    }
    final entry = ActivityEntry(id: '2', kind: ActivityKind.developBatch,
      keys: ['photo'], started: DateTime(2026));
    entry.finish('photo', ActivityOutcome.failed, error: 'private exception details');
    expect(entry.failureReason, isNull);
    expect(jsonEncode(entry.toJson()), isNot(contains('private exception details')));
    final json = entry.toJson();
    json['failureReason'] = 'unknown-new-category';
    expect(ActivityEntry.fromJson(json).failureReason, isNull);
    json.remove('failureReason');
    expect(ActivityEntry.fromJson(json).failureReason, isNull);
  });

  testWidgets('batch failure saves the known reason after the existing retries', (tester) async {
    final folder = Directory.systemTemp.createTempSync('afterhue-limit-');
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    const photos = MethodChannel('com.fluttercandies/photo_manager');
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(paths, (_) async => folder.path);
    final image = (await rootBundle.load('assets/samples/lantern.jpg')).buffer.asUint8List();
    messenger.setMockMethodCallHandler(photos, (call) async => switch (call.method) {
      'fetchEntityProperties' => {'id': 'limit-photo', 'type': 1, 'width': 600, 'height': 900},
      'getThumb' => image,
      _ => null,
    });
    final store = Store.instance;
    final agent = LimitAgent();
    await tester.runAsync(() async {
      await store.init();
      store.agentForTesting = agent;
      final items = await store.importRefs([PhotoRef(id: 'limit-photo', taken: DateTime(2026), width: 600, height: 900)]);
      store.autoDevelopUndeveloped(items);
      for (var i = 0; i < 250 && !store.activity.first.complete; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    final entry = store.activity.first;
    expect(entry.complete, isTrue);
    expect(agent.calls, 3);
    expect(entry.failureReason, ActivityFailureReason.dailyLimit);
    await tester.runAsync(() async { await Future<void>.delayed(const Duration(milliseconds: 800)); });
    await tester.pump();
    final saved = jsonDecode(File('${folder.path}/state.json').readAsStringSync()) as Map<String, dynamic>;
    final restored = ActivityEntry.fromJson((saved['activity'] as List).first as Map<String, dynamic>);
    expect(restored.failureReason, ActivityFailureReason.dailyLimit);
    await tester.runAsync(store.resetForDemo);
    messenger.setMockMethodCallHandler(paths, null);
    messenger.setMockMethodCallHandler(photos, null);
    folder.deleteSync(recursive: true);
  });

  testWidgets('saved reason is shown in the current language', (tester) async {
    final store = Store.instance;
    final before = List<ActivityEntry>.of(store.activity);
    addTearDown(() { store.activity..clear()..addAll(before); });
    final entry = ActivityEntry(id: '1', kind: ActivityKind.developBatch,
      keys: ['photo'], started: DateTime(2026));
    entry.finish('photo', ActivityOutcome.failed, error: ActivityFailureReason.userDailyLimit.message);
    store.activity..clear()..add(ActivityEntry.fromJson(jsonDecode(jsonEncode(entry.toJson())) as Map<String, dynamic>));
    Widget screen(Locale locale) => MaterialApp(
      locale: locale,
      supportedLocales: const [Locale('en'), Locale('ja')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: const ActivityScreen(),
    );
    await tester.pumpWidget(screen(const Locale('ja')));
    expect(find.textContaining('本日の利用上限'), findsOneWidget);
    await tester.pumpWidget(screen(const Locale('en')));
    expect(find.text(ActivityFailureReason.userDailyLimit.message), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
