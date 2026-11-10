import 'dart:async';
import 'dart:io';
import 'package:afterhue/agent/agent.dart';
import 'package:afterhue/core/recipe.dart';
import 'package:afterhue/core/renderer.dart';
import 'package:afterhue/data/photo_source.dart';
import 'package:afterhue/data/store.dart';
import 'package:afterhue/ui/edit.dart';
import 'package:afterhue/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class RequestAgent extends DevelopAgent {
  final requests = <Revision>[];
  final runs = <AgentRun>[];
  final results = <Completer<Recipe>>[];
  @override String get name => 'Fixture';
  @override Future<Recipe> develop(Rgba photo, {void Function(String)? log, AgentRun? run, ({int width, int height})? originalSize}) => throw UnimplementedError();
  @override Future<Recipe> revise(Rgba photo, Recipe current, Revision request, {void Function(String)? log, AgentRun? run, ({int width, int height})? originalSize}) {
    requests.add(request); runs.add(run!);
    final result = Completer<Recipe>(); results.add(result);
    return run.guard(result.future);
  }
}

Future<void> until(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 150 && !ready(); i++) {
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
  }
  await tester.pump();
  expect(ready(), isTrue);
}

Future<(PhotoItem, Future<void> Function())> setup(WidgetTester tester, RequestAgent agent) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  final folder = Directory.systemTemp.createTempSync('afterhue-ask-');
  final messenger = tester.binding.defaultBinaryMessenger;
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  const photos = MethodChannel('com.fluttercandies/photo_manager');
  messenger.setMockMethodCallHandler(paths, (_) async => folder.path);
  final bytes = (await rootBundle.load('assets/samples/lantern.jpg')).buffer.asUint8List();
  messenger.setMockMethodCallHandler(photos, (call) async => switch(call.method) {
    'fetchEntityProperties' => {'id': 'ask-photo', 'type': 1, 'width': 600, 'height': 900},
    'getThumb' => call.arguments['option']['width'] == 768 ? bytes : null,
    _ => null,
  });
  final store = Store.instance;
  store.agentForTesting = agent;
  late PhotoItem item;
  await tester.runAsync(() async {
    await store.init();
    item = (await store.importRefs([PhotoRef(id: 'ask-photo', taken: DateTime(2026), width: 600, height: 900)])).single;
    store.setEdit(item, Recipe(colors: [keptColorFromHex('#DD3322')!], ambience: .2));
  });
  await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: Builder(builder: (context) => Scaffold(body: TextButton(
    onPressed: () => Navigator.push(context, EditRoute(item)), child: const Text('Open edit'))))));
  await tester.tap(find.text('Open edit')); await tester.pumpAndSettle();
  return (item, () async {
    await tester.pumpWidget(const SizedBox());
    // Flush filesystem continuations created in the fake-async widget zone.
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    await tester.runAsync(store.resetForDemo);
    messenger.setMockMethodCallHandler(photos, null);
    messenger.setMockMethodCallHandler(paths, null);
    tester.view.resetPhysicalSize(); tester.view.resetDevicePixelRatio(); tester.view.resetViewInsets();
    folder.deleteSync(recursive: true);
  });
}

void main() {
  testWidgets('Ask keeps its native input, draft and explicit mark intent across keyboard/layout changes', (tester) async {
    final agent = RequestAgent();
    final (_, cleanup) = await setup(tester, agent);
    await tester.tap(find.text('Ask')); await tester.pump(); await tester.pump();
    final input = tester.state<EditableTextState>(find.byType(EditableText));
    await tester.tap(find.byType(TextField)); await tester.pump(); await tester.pump();
    expect(identical(tester.state<EditableTextState>(find.byType(EditableText)), input), isTrue,
      reason: 'Focusing must not replace the native text input client');
    expect(tester.testTextInput.isVisible, isTrue);
    expect(tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus, isTrue);
    expect(find.text('Describe your edit'), findsNothing);
    expect(find.text('Only the subject'), findsNothing);
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('ask-send'))).onPressed, isNull);
    await tester.enterText(find.byType(TextField), 'オレンジだけを除きたい'); await tester.pump();
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pump();
    expect(identical(tester.state<EditableTextState>(find.byType(EditableText)), input), isTrue);
    tester.view.physicalSize = const Size(844, 390);
    tester.view.viewInsets = const FakeViewPadding(bottom: 180);
    await tester.pump();
    expect(identical(tester.state<EditableTextState>(find.byType(EditableText)), input), isTrue);
    expect(tester.takeException(), isNull);
    tester.view.physicalSize = const Size(390, 844); tester.view.resetViewInsets(); await tester.pump();
    await tester.tap(find.byTooltip('View photo')); await tester.pump();
    await tester.tap(find.byTooltip('Close Ask')); await tester.pump();
    await tester.tap(find.text('Ask')); await tester.pump(); await tester.pump();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'オレンジだけを除きたい');
    await tester.tap(find.byTooltip('View photo')); await tester.pump();
    await tester.tap(find.text('Mark photo')); await tester.pump();
    await tester.tap(find.text('Remove color')); await tester.pump();
    await tester.tap(find.byKey(const ValueKey('edit-photo-gesture'))); await tester.pump();
    expect(find.text('Clear marks'), findsOneWidget);
    await tester.tap(find.text('Send')); await tester.pump();
    await until(tester, () => agent.requests.isNotEmpty);
    expect(agent.requests.single.text, 'オレンジだけを除きたい');
    expect(agent.requests.single.marks.single.intent, MarkIntent.remove);
    await tester.tap(find.text('Stop')); await tester.pump();
    expect(agent.runs.single.cancelled, isTrue);
    agent.results.single.complete(Recipe());
    await cleanup();
  });

  testWidgets('failed requests can retry; success can undo; stopping discards partial work', (tester) async {
    final agent = RequestAgent();
    final (item, cleanup) = await setup(tester, agent);
    await tester.tap(find.text('Ask')); await tester.pump(); await tester.pump();
    await tester.enterText(find.byType(TextField), 'Keep only the flowers'); await tester.pump();
    await tester.tap(find.text('Send')); await tester.pump();
    await until(tester, () => agent.requests.length == 1);
    expect(find.text('Editing your photo'), findsOneWidget);
    expect(find.text('You can tap Done. Find the result in Activity.'), findsOneWidget);
    agent.runs.first.emit(item.edit!.copy()..saturation = .7, 'set_saturation'); await tester.pump();
    expect(find.text('Agent is adjusting saturation…'), findsOneWidget);
    agent.results.first.completeError(AgentError('Too many Cloud AI requests. Please wait a moment and try again.'));
    await until(tester, () => find.text('Couldn’t finish this edit').evaluate().isNotEmpty);
    expect(find.text('Too many Cloud AI requests. Please wait a moment and try again.'), findsOneWidget);
    await tester.tap(find.text('Edit request')); await tester.pump(); await tester.pump();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'Keep only the flowers');
    await tester.tap(find.byTooltip('View photo')); await tester.pump();
    await tester.tap(find.byTooltip('Close Ask')); await tester.pump();
    await tester.tap(find.text('Retry')); await tester.pump();
    await until(tester, () => agent.requests.length == 2);
    agent.results[1].complete(item.edit!.copy()..ambience = .7);
    await until(tester, () => find.text('Edit ready').evaluate().isNotEmpty);
    expect(find.text('Hold to compare'), findsOneWidget);
    await tester.tap(find.text('Undo edit')); await tester.pump();
    await tester.tap(find.text('Ask')); await tester.pump(); await tester.pump();
    await tester.enterText(find.byType(TextField), 'More mood'); await tester.pump();
    await tester.tap(find.text('Send')); await tester.pump();
    await until(tester, () => agent.requests.length == 3);
    agent.runs[2].emit(item.edit!.copy()..ambience = .9, 'set_mono_tone'); await tester.pump();
    await tester.tap(find.text('Stop')); await tester.pump();
    expect(find.text('Editing stopped'), findsOneWidget);
    expect(agent.runs[2].cancelled, isTrue);
    agent.results[2].complete(item.edit!.copy()..ambience = 1);
    await tester.tap(find.text('Done')); await tester.pumpAndSettle();
    expect(item.edit!.ambience, .2, reason: 'Neither an undone result nor stopped partial work may leak into Done');
    await cleanup();
  });
}
