import 'dart:async';
import 'dart:io';

import 'package:afterhue/data/store.dart';
import 'package:afterhue/ui/detail.dart';
import 'package:afterhue/ui/import_sheet.dart';
import 'package:afterhue/ui/photos.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('the viewer shows a manual import before editing', (
    tester,
  ) async {
    final bytes = (await rootBundle.load('assets/samples/lantern.jpg')).buffer
        .asUint8List();
    const channel = MethodChannel('com.fluttercandies/photo_manager');
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      return switch (call.method) {
        'fetchEntityProperties' => {
          'id': (call.arguments as Map)['id'],
          'type': 1,
          'width': 600,
          'height': 900,
        },
        'getThumb' => bytes,
        _ => null,
      };
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final photo = PhotoItem(
      id: 'manual-import-fixture',
      taken: DateTime(2026, 11, 10),
      width: 600,
      height: 900,
      state: Develop.manual,
      picked: true,
    );
    await tester.pumpWidget(
      MaterialApp(home: DetailScreen(items: [photo], index: 0)),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();

    final photos = tester.widgetList<Image>(
      find.descendant(of: find.byType(Hero), matching: find.byType(Image)),
    );
    expect(
      photos.any(
        (image) => image.image is MemoryImage && image.fit == BoxFit.contain,
      ),
      isTrue,
    );
  });
  testWidgets(
    'manual batches can be reviewed and both Auto actions queue every photo',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync(
        'after-hue-import-test',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final bytes = (await rootBundle.load('assets/samples/lantern.jpg')).buffer
          .asUint8List();
      const photos = MethodChannel('com.fluttercandies/photo_manager');
      const paths = MethodChannel('plugins.flutter.io/path_provider');
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(paths, (_) async => directory.path);
      final assets = [
        for (var i = 0; i < 4; i++)
          {
            'id': 'batch-fixture-$i',
            'type': 1,
            'width': 600,
            'height': 900,
            'createDt': 1794272400 - i,
            'lat': 35.7,
            'lng': 139.7,
          },
      ];
      final development = Completer<Uint8List?>();
      messenger.setMockMethodCallHandler(photos, (call) async {
        final args = call.arguments as Map;
        return switch (call.method) {
          'getAssetPathList' => {
            'data': args['onlyAll'] == true
                ? [
                    {
                      'id': 'all',
                      'name': 'All',
                      'isAll': true,
                      'assetCount': assets.length,
                    },
                  ]
                : [],
          },
          'getAssetListPaged' => {'data': assets},
          'fetchEntityProperties' => assets.firstWhere(
            (a) => a['id'] == args['id'],
          ),
          'getThumb' =>
            args['option']['width'] == 768 ? development.future : bytes,
          _ => null,
        };
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(paths, null);
        messenger.setMockMethodCallHandler(photos, null);
      });
      final store = Store.instance;
      await tester.runAsync(store.init);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: const PhotosScreen(),
            floatingActionButtonLocation: FloatingActionButtonLocation.centerTop,
            floatingActionButton: Builder(
              builder: (context) => TextButton(
                onPressed: () => ImportSheet.show(context),
                child: const Text('Open import'),
              ),
            ),
          ),
        ),
      );
      expect(find.textContaining('undeveloped photo'), findsNothing);

      Future<void> pick(int first) async {
        await tester.tap(find.text('Open import'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        await tester.tap(find.byKey(ValueKey('batch-fixture-$first')));
        await tester.tap(find.byKey(ValueKey('batch-fixture-${first + 1}')));
        await tester.pump();
      }

      await pick(0);
      await tester.tap(find.text('Edit manually'));
      await tester.pumpAndSettle();
      final viewer = tester.widget<DetailScreen>(find.byType(DetailScreen));
      expect(viewer.items.map((it) => it.id), [
        'batch-fixture-0',
        'batch-fixture-1',
      ]);
      expect(
        viewer.items.every(
          (it) => it.state == Develop.manual && it.edit == null,
        ),
        isTrue,
      );

      await tester.state<NavigatorState>(find.byType(Navigator)).maybePop();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Select'));
      await tester.pumpAndSettle();
      expect(find.text('0 selected'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('batch-fixture-0')));
      await tester.pumpAndSettle();
      expect(find.text('1 selected'), findsOneWidget);
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      expect(find.text('Remove this photo?'), findsOneWidget);
      expect(store.byKey('batch-fixture-0'), isNotNull);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(store.byKey('batch-fixture-0'), isNotNull);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(find.text('2 undeveloped'), findsOneWidget);
      await tester.tap(find.text('2 undeveloped'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<DetailScreen>(find.byType(DetailScreen)).items,
        viewer.items,
      );
      await tester.state<NavigatorState>(find.byType(Navigator)).maybePop();
      await tester.pumpAndSettle();
      store.autoDevelopUndeveloped([viewer.items.first]);
      expect(viewer.items.last.isUndeveloped, isTrue);
      await tester.pump();
      await tester.tap(find.text('Auto all'));
      await tester.pump();
      expect(find.text('2 undeveloped'), findsNothing);
      expect(
        viewer.items.every((it) => it.state == Develop.developing),
        isTrue,
      );
      await pick(2);
      await tester.tap(find.text('Auto develop 2'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(DetailScreen), findsNothing);
      expect(
        store.items
            .where((it) => it.state == Develop.pending && it.asked)
            .map((it) => it.id),
        unorderedEquals(['batch-fixture-2', 'batch-fixture-3']),
      );
      expect(store.developmentProgress().total, 4);
      expect(find.text('Queued'), findsWidgets);
      final removed = viewer.items.first;
      final run = store.runFor(removed)!;
      store.remove(removed);
      await tester.pump();
      await tester.pump();
      expect(run.cancelled, isTrue);
      expect(store.byKey(removed.key), isNull);
      expect(store.byKey('batch-fixture-2')!.state, Develop.developing);
      expect(store.developmentProgress().total, 3);
      final pending = store.byKey('batch-fixture-3')!;
      store.remove(pending);
      store.remove(viewer.items.last);
      await tester.pump();
      expect(store.runFor(pending), isNull);
      expect(store.developmentProgress().total, 1);
      await tester.pump(const Duration(seconds: 4));
    },
  );
}
