import 'dart:convert';
import 'dart:io';
import 'package:afterhue/data/store.dart';
import 'package:afterhue/ui/widgets/development_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('automatic intake labels waiting and completed progress in the bottom bar', (tester) async {
    final folder = Directory.systemTemp.createTempSync('afterhue-auto-status-');
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(paths, (_) async => folder.path);
    final fixtures = [for (var i = 0; i < 3; i++) PhotoItem(id: 'automatic-$i',
      taken: DateTime(2026, 1, i + 1), width: 600, height: 900,
      state: i == 0 ? Develop.done : Develop.pending)];
    File('${folder.path}/state.json').writeAsStringSync(jsonEncode({
      'items': fixtures.map((it) => it.toJson()).toList(),
      'automaticBatch': fixtures.map((it) => it.key).toList(), 'groupSimilarPhotos': false,
    }));
    final store = Store.instance;
    await tester.runAsync(store.init);
    Widget bar(int version) => MaterialApp(home: Scaffold(body: DevelopmentBar(key: ValueKey(version))));
    await tester.pumpWidget(bar(0));
    expect(find.text('Auto · 2 queued'), findsOneWidget);
    store.byKey('automatic-1')!.state = Develop.developing;
    await tester.pumpWidget(bar(1));
    expect(find.text('Auto · 1 / 3 processed'), findsOneWidget);
    store.byKey('automatic-1')!.state = Develop.done;
    store.byKey('automatic-2')!.state = Develop.done;
    await tester.pumpWidget(bar(2));
    expect(find.textContaining('Auto ·'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(paths, null);
    folder.deleteSync(recursive: true);
  });
}
