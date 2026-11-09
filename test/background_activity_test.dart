import 'dart:async';
import 'dart:io';
import 'package:afterhue/agent/agent.dart';
import 'package:afterhue/core/recipe.dart';
import 'package:afterhue/core/renderer.dart';
import 'package:afterhue/data/activity.dart';
import 'package:afterhue/data/photo_source.dart';
import 'package:afterhue/data/store.dart';
import 'package:afterhue/ui/detail.dart';
import 'package:afterhue/ui/activity.dart';
import 'package:afterhue/ui/edit.dart';
import 'package:afterhue/ui/photos.dart';
import 'package:afterhue/ui/widgets/agent_work_status.dart';
import 'package:afterhue/ui/widgets/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class PendingAgent extends DevelopAgent {
  final started = Completer<void>();
  final result = Completer<Recipe>();
  @override String get name => 'Fixture';
  @override Future<Recipe> develop(Rgba photo, {void Function(String)? log, AgentRun? run, ({int width, int height})? originalSize}) => result.future;
  @override Future<Recipe> revise(Rgba photo, Recipe current, Revision request, {void Function(String)? log, AgentRun? run, ({int width, int height})? originalSize}) {
    started.complete();
    return run!.guard(result.future);
  }
}

void main() {
  testWidgets('Done lets the revision finish, save and create a linked activity', (tester) async {
    final folder = Directory.systemTemp.createTempSync('afterhue-background-');
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    const channel = MethodChannel('com.fluttercandies/photo_manager');
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(paths, (_) async => folder.path);
    final bytes = (await rootBundle.load('assets/samples/lantern.jpg')).buffer.asUint8List();
    messenger.setMockMethodCallHandler(channel, (call) async => switch(call.method) {
      'fetchEntityProperties' => {'id': 'background-photo', 'type': 1, 'width': 600, 'height': 900},
      'getThumb' => call.arguments['option']['width'] == 768 ? bytes : null,
      _ => null,
    });
    final store = Store.instance;
    final agent = PendingAgent();
    store.agentForTesting = agent;
    await tester.runAsync(store.init);
    final imported = await store.importRefs([PhotoRef(id: 'background-photo', taken: DateTime(2026), width: 600, height: 900)]);
    final item = imported.single;
    final before = Recipe(colors: [keptColorFromHex('#CC3355')!]);
    store.setEdit(item, before);
    late AgentRun run;
    await tester.runAsync(() async {
      run = store.reviseNow(item, before, const Revision(text: 'Keep the flower'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    expect(agent.started.isCompleted, isTrue);
    final finished = Completer<void>();
    run.changes.listen((_) {}, onDone: finished.complete);
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) => Scaffold(body: TextButton(
      onPressed: () => Navigator.push(context, EditRoute(item)), child: const Text('Open edit'))))));
    await tester.tap(find.text('Open edit'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.byType(EditScreen), findsNothing);
    expect(run.cancelled, isFalse);
    final entry = store.activity.first;
    expect(entry.kind, ActivityKind.editRequest);
    expect(entry.complete, isFalse);
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: PhotosScreen())));
    await tester.pump();
    expect(find.text('Agent editing'), findsOneWidget);
    await tester.tap(find.byKey(ValueKey(item.key)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Agent is looking…'), findsOneWidget);
    run.emit(before, 'select_subject');
    await tester.pump();
    expect(find.text('Agent is selecting the subject…'), findsOneWidget);
    await tester.runAsync(() async {
      agent.result.complete(Recipe(colors: [keptColorFromHex('#FF8822')!], ambience: .31));
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byType(AgentWorkStatus), findsNothing);
    expect(finished.isCompleted, isTrue);
    expect(item.edit!.ambience, .31);
    expect(entry.complete, isTrue);
    expect(entry.count(ActivityOutcome.developed), 1);
    expect(entry.keys, [item.key]);
    expect(entry.read, isFalse);
    store.readActivity(entry);
    expect(entry.read, isTrue);
    await tester.pumpWidget(const SizedBox());
    final lateAgent = PendingAgent();
    store.agentForTesting = lateAgent;
    late AgentRun removedRun;
    await tester.runAsync(() async {
      removedRun = store.reviseNow(item, item.edit!, const Revision(text: 'Another change'));
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pump();
    expect(lateAgent.started.isCompleted, isTrue);
    store.continueEditing(item, removedRun);
    final count = store.activity.length;
    store.continueEditing(item, removedRun);
    expect(store.activity.length, count, reason: 'Reopening and pressing Done must not duplicate the operation.');
    final removedEntry = store.activity.first;
    store.remove(item);
    await tester.runAsync(() async {
      lateAgent.result.complete(Recipe(colors: [keptColorFromHex('#FF8822')!], ambience: .9));
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pump();
    expect(removedRun.cancelled, isTrue);
    expect(store.byKey(item.key), isNull);
    expect(removedEntry.count(ActivityOutcome.removed), 1);
    expect(item.edit!.ambience, .31, reason: 'A late result must not overwrite the removed photo.');
    await tester.pump(const Duration(seconds: 4));
    await tester.runAsync(() async { await Future<void>.delayed(const Duration(milliseconds: 20)); });
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(paths, null);
    folder.deleteSync(recursive: true);
  });

  testWidgets('confirmed Remove swaps the visible photo without waiting for an exit animation', (tester) async {
    final folder = Directory.systemTemp.createTempSync('afterhue-remove-');
    const photos = MethodChannel('com.fluttercandies/photo_manager');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(photos, (_) async => null);
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(photos, null));
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(paths, (_) async => folder.path);
    final store = Store.instance;
    await tester.runAsync(store.init);
    final items = await store.importRefs([
      PhotoRef(id: 'remove-one', taken: DateTime(2026, 1, 1), width: 600, height: 900),
      PhotoRef(id: 'remove-two', taken: DateTime(2026, 1, 2), width: 600, height: 900),
    ]);
    await tester.pumpWidget(MaterialApp(home: DetailScreen(items: items, index: 0)));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove from After Hue'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove'));
    await tester.pump();
    await tester.pump();
    expect(store.byKey(items.first.key), isNull);
    expect(find.byWidgetPredicate((w) => w is OriginalImage && w.item.key == items.first.key), findsNothing);
    expect(find.text('1 / 1'), findsOneWidget);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpWidget(const MaterialApp(home: ActivityScreen()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('View 1 photo').first);
    await tester.pumpAndSettle();
    expect(tester.widget<DetailScreen>(find.byType(DetailScreen)).items.map((it) => it.key), [items.last.key]);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async { await Future<void>.delayed(const Duration(milliseconds: 20)); });
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(paths, null);
    folder.deleteSync(recursive: true);
  });
}
