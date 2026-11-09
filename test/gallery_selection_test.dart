import 'package:afterhue/data/store.dart';
import 'package:afterhue/ui/photos.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('sweep selects a range, reverses, clears, deselects and scrolls', (tester) async {
    tester.view.physicalSize = const Size(402, 874);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final bytes = (await rootBundle.load('assets/samples/lantern.jpg')).buffer.asUint8List();
    const channel = MethodChannel('com.fluttercandies/photo_manager');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async =>
      call.method == 'getThumb' ? bytes : null);
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
    final feedback = <Object?>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') feedback.add(call.arguments);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    final store = Store.instance;
    store.items.clear();
    store.items.addAll(List.generate(72, (i) => PhotoItem(
      id: 'sweep-$i', taken: DateTime(2026, i < 12 ? 11 : 10, 10),
      width: 600, height: 900, state: Develop.manual, picked: true,
    )));
    final modes = <bool>[];
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: PhotosScreen(onSelectionChanged: modes.add))));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Select'));
    await tester.pumpAndSettle();
    Finder tile(int i) => find.byKey(ValueKey('sweep-$i'));
    final first = tester.getCenter(tile(0));
    final third = tester.getCenter(tile(2));
    final fifth = tester.getCenter(tile(4));
    var finger = await tester.startGesture(first);
    await finger.moveTo(third);
    await tester.pump();
    expect(find.text('3 selected'), findsOneWidget);
    final initialFeedback = feedback.length;
    await tester.pump(const Duration(milliseconds: 80));
    await finger.moveTo(fifth);
    await tester.pump();
    expect(find.text('5 selected'), findsOneWidget);
    expect(feedback.length, initialFeedback + 1);
    expect(feedback.last, 'HapticFeedbackType.selectionClick');
    await finger.moveTo(fifth + const Offset(1, 0));
    await tester.pump();
    expect(feedback.length, initialFeedback + 1, reason: 'No feedback while staying on the same photo.');
    await tester.pump(const Duration(milliseconds: 80));
    await finger.moveTo(third);
    await tester.pump();
    expect(find.text('3 selected'), findsOneWidget);
    expect(feedback.length, initialFeedback + 2, reason: 'Shrinking the range also gives selection feedback.');
    await finger.up();
    await tester.pumpAndSettle();
    // Starting on a selected photo removes the whole swept range.
    finger = await tester.startGesture(first);
    await finger.moveTo(third);
    await finger.up();
    await tester.pumpAndSettle();
    expect(find.text('0 selected'), findsOneWidget);
    await tester.tap(tile(0));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Deselect all'));
    await tester.pumpAndSettle();
    expect(find.text('0 selected'), findsOneWidget);
    expect(modes, [true]); // Clearing keeps the user in selection mode.
    // A vertical drag remains a scroll, not a selection gesture.
    final scroll = tester.state<ScrollableState>(find.byType(Scrollable).first);
    await tester.drag(tile(4), const Offset(0, -180));
    await tester.pumpAndSettle();
    expect(scroll.position.pixels, greaterThan(0));
    expect(find.text('0 selected'), findsWidgets);
    scroll.position.jumpTo(0);
    await tester.pumpAndSettle();
    // Holding at the lower edge continues selecting across month groups.
    finger = await tester.startGesture(tester.getCenter(tile(0)));
    await finger.moveTo(tester.getCenter(tile(2)));
    await tester.pump();
    await finger.moveTo(const Offset(330, 810));
    for (var i = 0; i < 130; i++) { await tester.pump(const Duration(milliseconds: 16)); }
    expect(scroll.position.pixels, greaterThan(600));
    await finger.up();
    await tester.pumpAndSettle();
    final count = int.parse(tester.widgetList<Text>(find.textContaining(' selected')).first.data!.split(' ').first);
    expect(count, greaterThan(18));
    final stopped = scroll.position.pixels;
    await tester.pump(const Duration(milliseconds: 500));
    expect(scroll.position.pixels, stopped);
    // The pinned controls remain usable while scrolled down.
    await tester.tap(find.text('Deselect all').last);
    await tester.pumpAndSettle();
    expect(find.text('0 selected'), findsWidgets);
    await tester.tap(find.text('Done').last);
    await tester.pumpAndSettle();
    scroll.position.jumpTo(0);
    await tester.pumpAndSettle();
    // Long press also starts a continuous range from ordinary browsing.
    finger = await tester.startGesture(tester.getCenter(tile(0)));
    await tester.pump(const Duration(milliseconds: 600));
    await finger.moveTo(tester.getCenter(tile(2)));
    await tester.pump();
    expect(find.text('3 selected'), findsOneWidget);
    await finger.cancel();
    await tester.pumpAndSettle();
    expect(modes, [true, false, true]);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
