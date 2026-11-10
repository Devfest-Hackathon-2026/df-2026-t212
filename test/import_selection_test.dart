import 'dart:convert';
import 'dart:io';

import 'package:afterhue/data/store.dart';
import 'package:afterhue/ui/import_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_manager/photo_manager.dart';

void main() {
  testWidgets('import requests access and reloads after selected photos are allowed in Settings', (tester) async {
    const photos = MethodChannel('com.fluttercandies/photo_manager');
    final messenger = tester.binding.defaultBinaryMessenger;
    var access = PermissionState.denied;
    final requests = <MethodCall>[];
    var libraryReads = 0;
    var settingsOpened = false;
    messenger.setMockMethodCallHandler(photos, (call) async {
      switch (call.method) {
        case 'getPermissionState':
          return access.index;
        case 'requestPermissionExtend':
          requests.add(call);
          return access.index;
        case 'openSetting':
          settingsOpened = true;
          return 1;
        case 'getAssetPathList':
          libraryReads++;
          return {'data': []};
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(photos, null));
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: ImportSheet())));
    await tester.pumpAndSettle();
    expect(requests, hasLength(1));
    expect(requests.single.arguments['androidPermission']['type'], RequestType.image.value);
    expect(libraryReads, 0);
    expect(find.text('Allow photo access to choose photos to import.'), findsOneWidget);
    await tester.tap(find.text('Open Settings'));
    await tester.pumpAndSettle();
    expect(settingsOpened, isTrue);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    access = PermissionState.limited;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(libraryReads, greaterThan(0));
    expect(requests, hasLength(1));
    expect(find.text('Open Settings'), findsNothing);
    expect(find.text('No photos in your library.'), findsOneWidget);
  });

  testWidgets('import sweep skips Added, reverses and continues into the next page', (tester) async {
    tester.view.physicalSize = const Size(402, 874);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final directory = Directory.systemTemp.createTempSync('after-hue-sweep-test');
    addTearDown(() => directory.deleteSync(recursive: true));
    final already = PhotoItem(id: 'import-1', taken: DateTime(2026, 11, 10), width: 600, height: 900, state: Develop.manual, picked: true);
    File('${directory.path}/state.json').writeAsStringSync(jsonEncode({'items': [already.toJson()]}));
    final bytes = (await rootBundle.load('assets/samples/lantern.jpg')).buffer.asUint8List();
    const photos = MethodChannel('com.fluttercandies/photo_manager');
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(paths, (_) async => directory.path);
    final assets = [for (var i = 0; i < 124; i++) {
      'id': 'import-$i', 'type': 1, 'width': 600, 'height': 900, 'createDt': 1794272400 - i,
    }];
    final pages = <int>[];
    messenger.setMockMethodCallHandler(photos, (call) async {
      final args = call.arguments as Map;
      if (call.method == 'getAssetListPaged') {
        final page = args['page'] as int;
        pages.add(page);
        return {'data': page == 0 ? assets.take(120).toList() : assets.skip(120).toList()};
      }
      return switch (call.method) {
        'getPermissionState' => PermissionState.authorized.index,
        'getAssetPathList' => {'data': args['onlyAll'] == true ? [{'id': 'all', 'name': 'All', 'isAll': true, 'assetCount': 124}] : []},
        'getThumb' => bytes,
        _ => null,
      };
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(paths, null);
      messenger.setMockMethodCallHandler(photos, null);
    });
    await tester.runAsync(Store.instance.init);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (context) => TextButton(
      onPressed: () => ImportSheet.show(context), child: const Text('Import'),
    )))));
    await tester.tap(find.text('Import'));
    await tester.pumpAndSettle();
    Finder tile(int i) => find.byKey(ValueKey('import-$i'));
    final first = tester.getCenter(tile(0)), fourth = tester.getCenter(tile(3));
    var finger = await tester.startGesture(first);
    await finger.moveTo(fourth);
    await tester.pump();
    expect(find.text('3 selected'), findsOneWidget);
    await finger.moveTo(tester.getCenter(tile(2)));
    await tester.pump();
    expect(find.text('2 selected'), findsOneWidget);
    await finger.up();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Deselect all'));
    await tester.pumpAndSettle();
    expect(find.text('Select photos to develop'), findsOneWidget);
    // A sweep cannot start from an already imported photo.
    finger = await tester.startGesture(tester.getCenter(tile(1)));
    await finger.moveTo(fourth);
    await finger.up();
    await tester.pumpAndSettle();
    expect(find.text('Select photos to develop'), findsOneWidget);
    finger = await tester.startGesture(first);
    await finger.moveTo(fourth);
    await tester.pump();
    final grid = find.byType(GridView);
    await finger.moveTo(Offset(fourth.dx, tester.getBottomRight(grid).dy - 2));
    for (var i = 0; i < 480; i++) { await tester.pump(const Duration(milliseconds: 16)); }
    await finger.up();
    await tester.pumpAndSettle();
    expect(pages, contains(1));
    expect(find.text('123 selected'), findsOneWidget);
    await tester.tap(find.text('Deselect all'));
    await tester.pumpAndSettle();
    expect(find.text('Select photos to develop'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(ImportSheet), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
