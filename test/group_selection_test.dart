import 'dart:io';
import 'package:afterhue/data/photo_source.dart';
import 'package:afterhue/data/store.dart';
import 'package:afterhue/ui/photos.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('collapsed groups support whole, partial, sweep selection and exact removal', (tester) async {
    tester.view.physicalSize = const Size(402, 874);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final folder = Directory.systemTemp.createTempSync('afterhue-group-select-');
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    const photos = MethodChannel('com.fluttercandies/photo_manager');
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(paths, (_) async => folder.path);
    final bytes = (await rootBundle.load('assets/samples/lantern.jpg')).buffer.asUint8List();
    messenger.setMockMethodCallHandler(photos, (call) async => call.method == 'getThumb' ? bytes : null);
    addTearDown(() {
      messenger.setMockMethodCallHandler(paths, null);
      messenger.setMockMethodCallHandler(photos, null);
      folder.deleteSync(recursive: true);
    });
    final store = Store.instance;
    await tester.runAsync(store.init);
    final items = await store.importRefs(List.generate(5, (i) => PhotoRef(
      id: 'group-select-$i', taken: DateTime(2026, 11, 10), width: 600, height: 900,
    )));
    store.groupPhotos(items.take(3));
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: PhotosScreen())));
    await tester.pumpAndSettle();
    Finder tile(int i) => find.byKey(ValueKey(items[i].key));
    final before = tester.getRect(tile(3));
    await tester.tap(find.text('Select'));
    await tester.pumpAndSettle();
    expect(tester.getRect(tile(3)), before, reason: 'Entering selection must not rearrange the gallery.');
    expect(tile(1), findsNothing);
    expect(tile(2), findsNothing);
    await tester.tap(tile(0));
    await tester.pumpAndSettle();
    expect(find.text('3 selected'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Choose photos in group of 3'));
    await tester.pumpAndSettle();
    expect(find.text('3 of 3 selected'), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('group-selection-${items[1].key}')));
    await tester.pumpAndSettle();
    expect(find.text('2 of 3 selected'), findsOneWidget);
    await tester.tap(find.text('Done').last);
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsOneWidget);
    expect(find.descendant(of: tile(0), matching: find.text('2')), findsOneWidget);
    expect(tile(1), findsNothing);
    expect(tester.getRect(tile(3)), before);
    // A sweep starting at a partially selected bundle adds every member.
    var finger = await tester.startGesture(tester.getCenter(tile(0)));
    await finger.moveTo(tester.getCenter(tile(3)));
    await tester.pump();
    expect(find.text('4 selected'), findsOneWidget);
    await finger.moveTo(tester.getCenter(tile(0)));
    await tester.pump();
    expect(find.text('3 selected'), findsOneWidget);
    await finger.up();
    await tester.pumpAndSettle();
    // A sweep starting at a fully selected bundle removes every member.
    finger = await tester.startGesture(tester.getCenter(tile(0)));
    await finger.moveTo(tester.getCenter(tile(3)));
    await finger.up();
    await tester.pumpAndSettle();
    expect(find.text('0 selected'), findsOneWidget);
    await tester.tap(tile(0));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    expect(find.text('Remove 3 photos?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(store.items.length, 5);
    // Removal of a partial selection must leave the unselected group member.
    await tester.tap(find.bySemanticsLabel('Choose photos in group of 3'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('group-selection-${items[1].key}')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    expect(find.text('Remove 2 photos?'), findsOneWidget);
    await tester.tap(find.text('Remove').last);
    await tester.pumpAndSettle();
    expect(store.byKey(items[0].key), isNull);
    expect(store.byKey(items[2].key), isNull);
    expect(store.byKey(items[1].key), isNotNull);
    expect(store.galleryItems.length, 3);
    expect(find.text('Select'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(() async { await Future<void>.delayed(const Duration(milliseconds: 30)); });
  });
}
