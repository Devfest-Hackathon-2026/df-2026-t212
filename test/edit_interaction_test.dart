import 'package:afterhue/core/recipe.dart';
import 'package:afterhue/data/store.dart';
import 'package:afterhue/ui/edit.dart';
import 'package:afterhue/ui/theme.dart';
import 'package:afterhue/ui/widgets/photo_zoom.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Finder get areaPainting => find.byWidgetPredicate((w) => w is CustomPaint && w.painter.runtimeType.toString() == '_AreaPainter');
Area? areaOf(WidgetTester tester) => (tester.widget<CustomPaint>(areaPainting).painter as dynamic).area as Area?;

Future<void> openEditor(WidgetTester tester) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  const channel = MethodChannel('com.fluttercandies/photo_manager');
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async => switch (call.method) {
    'fetchEntityProperties' => {'id': 'gesture-fixture', 'type': 1, 'width': 600, 'height': 900},
    _ => null,
  });
  addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
  await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: EditScreen(item: PhotoItem(
    id: 'gesture-fixture', taken: DateTime(2026), width: 600, height: 900,
    state: Develop.done,
  ))));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Area'));
  await tester.pumpAndSettle();
}

Future<void> pinch(WidgetTester tester, {bool firstFingerMoves = false, bool firstUp = false}) async {
  final center = tester.getCenter(areaPainting);
  final one = await tester.startGesture(center - const Offset(40, 0), pointer: 1);
  if (firstFingerMoves) await one.moveBy(const Offset(-25, 0));
  final two = await tester.startGesture(center + const Offset(40, 0), pointer: 2);
  await one.moveBy(const Offset(-30, 0));
  await two.moveBy(const Offset(30, 0));
  await tester.pump();
  if (firstUp) {
    await one.up();
    await two.moveBy(const Offset(12, 10));
    await two.up();
  } else {
    await two.up();
    await one.moveBy(const Offset(-12, 10));
    await one.up();
  }
  await tester.pumpAndSettle();
}

void main() {
  test('zoom rejects undersized transforms and centers letterboxed axes', () {
    final zoom = PhotoZoomController();
    zoom.setGeometry(const Size(390, 500), const Rect.fromLTWH(45, 25, 300, 450));
    zoom.value = Matrix4.diagonal3Values(.12, .12, 1)..setTranslationRaw(15, 10, 0);
    expect(zoom.value, Matrix4.identity());
    zoom.value = Matrix4.diagonal3Values(1.2, 1.2, 1)..setTranslationRaw(-100, -100, 0);
    expect(zoom.value.entry(0, 3), closeTo(-39, .001));
    expect(zoom.value.entry(1, 3), closeTo(-70, .001));
    zoom.dispose();
  });
  testWidgets('pinch cancellation keeps existing strokes and redo history', (tester) async {
    await openEditor(tester);
    final center = tester.getCenter(areaPainting);
    await tester.dragFrom(center, const Offset(35, 10));
    await tester.pumpAndSettle();
    expect(areaOf(tester)?.strokes.length, 1);
    await tester.tap(find.bySemanticsLabel('Undo'));
    await tester.pumpAndSettle();
    expect(areaOf(tester), isNull);
    await pinch(tester, firstFingerMoves: true);
    await tester.tap(find.bySemanticsLabel('Redo'));
    await tester.pumpAndSettle();
    expect(areaOf(tester)?.strokes.length, 1);
    final before = areaOf(tester)!.toJson();
    final point = tester.getCenter(areaPainting);
    final one = await tester.startGesture(point, pointer: 1);
    await one.moveBy(const Offset(25, 10));
    final two = await tester.startGesture(point + const Offset(45, 0), pointer: 2);
    await two.cancel();
    await one.up();
    await tester.pumpAndSettle();
    expect(areaOf(tester)!.toJson(), before);
  });
  testWidgets('Ask keeps photo above keyboard and keeps marking reachable while typing', (tester) async {
    await openEditor(tester);
    await tester.tap(find.text('Ask'));
    await tester.pumpAndSettle();
    expect(find.text('Only the subject'), findsOneWidget);
    expect(find.text('Mark photo'), findsOneWidget);
    await tester.tap(find.byType(TextField));
    tester.view.viewInsets = const FakeViewPadding(bottom: 346);
    addTearDown(tester.view.resetViewInsets);
    await tester.enterText(find.byType(TextField), 'オレンジを除外して、ピンクを残してほしい');
    await tester.pumpAndSettle();
    expect(find.text('Only the subject'), findsNothing);
    expect(find.text('Mark photo'), findsOneWidget);
    final photo = tester.getRect(find.byType(Hero));
    final field = tester.getRect(find.byType(TextField));
    expect(photo.bottom, lessThan(field.top));
    expect(photo.height, greaterThan(150));
    expect(field.bottom, lessThan(844 - 346));
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('Close Ask'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    expect(find.text('Area'), findsOneWidget);
  });
  for (final moved in [false, true]) {
    for (final firstUp in [false, true]) {
      testWidgets('pinch leaves no Area stroke (moved=$moved, firstUp=$firstUp)', (tester) async {
        await openEditor(tester);
        await pinch(tester, firstFingerMoves: moved, firstUp: firstUp);
        expect(areaOf(tester)?.strokes ?? [], isEmpty);
        final viewer = tester.widget<InteractiveViewer>(find.byType(InteractiveViewer));
        expect(viewer.transformationController!.value.entry(0, 0), greaterThanOrEqualTo(1));
        // A fresh one-finger gesture must still paint after all pinch fingers lift.
        final from = tester.getCenter(areaPainting);
        await tester.dragFrom(from, const Offset(40, 30));
        await tester.pumpAndSettle();
        expect(areaOf(tester)?.strokes.length, 1);
      });
    }
  }
  testWidgets('repeated zoom returns to fitted size and center across tools', (tester) async {
    await openEditor(tester);
    for (var i = 0; i < 3; i++) {
      final viewer = tester.widget<InteractiveViewer>(find.byType(InteractiveViewer));
      final center = tester.getCenter(find.byType(InteractiveViewer));
      final one = await tester.startGesture(center - const Offset(65, 0), pointer: 1);
      final two = await tester.startGesture(center + const Offset(65, 0), pointer: 2);
      for (var step = 0; step < 4; step++) {
        await one.moveBy(const Offset(-12, 0));
        await two.moveBy(const Offset(12, 0));
        await tester.pump();
      }
      for (var step = 0; step < 10; step++) {
        await one.moveBy(const Offset(10, 0));
        await two.moveBy(const Offset(-10, 0));
        await tester.pump();
      }
      await one.up(); await two.up(); await tester.pumpAndSettle();
      final matrix = viewer.transformationController!.value;
      expect(matrix.entry(0, 0), closeTo(1, .001));
      expect(matrix.entry(1, 1), closeTo(1, .001));
      expect(matrix.getTranslation().length, closeTo(0, .001));
      await tester.tap(find.text(i.isEven ? 'Color' : 'Area')); await tester.pumpAndSettle();
    }
  });
}
