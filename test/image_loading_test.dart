import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:afterhue/core/recipe.dart';
import 'package:afterhue/data/store.dart';
import 'package:afterhue/data/photo_patch_cache.dart';
import 'package:afterhue/ui/widgets/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  setUp(() async {
    directory = Directory.systemTemp.createTempSync('afterhue-images-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'), (_) async => directory.path,
    );
    await Store.instance.init();
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'), null,
    );
    directory.deleteSync(recursive: true);
  });

  testWidgets('keep decoded thumbnail visible until larger image has decoded', (tester) async {
    final recipe = Recipe();
    final item = PhotoItem(id: 'upgrade-fixture', taken: DateTime(2026), width: 600, height: 900,
      edit: recipe, state: Develop.done);
    final bytes = (await rootBundle.load('assets/samples/lantern.jpg')).buffer.asUint8List();
    final low = File('${directory.path}/renders/${item.id}_${recipe.signature}_480.jpg');
    final high = File('${directory.path}/renders/${item.id}_${recipe.signature}_1600.jpg');
    low.writeAsBytesSync(bytes);
    high.writeAsBytesSync(bytes);
    final capture = GlobalKey();
    Widget photo(int size, {Key? key}) => MaterialApp(home: Center(child: RepaintBoundary(key: capture,
      child: SizedBox(width: 200, height: 300, child: DevelopedImage(item, key: key, size: size)))));
    Future<Uint8List> frame() async => (await tester.runAsync(() async {
      final image = await (capture.currentContext!.findRenderObject() as RenderRepaintBoundary).toImage();
      final pixels = (await image.toByteData())!.buffer.asUint8List();
      image.dispose();
      return pixels;
    }))!;
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.runAsync(() async {
      await Store.instance.rendered(item, 480);
      await Store.instance.rendered(item, 1600);
      await precacheImage(FileImage(low), tester.element(find.byType(SizedBox)));
    });
    await tester.pumpWidget(photo(480));
    await tester.pumpAndSettle();
    await tester.runAsync(() async { await Future<void>.delayed(const Duration(milliseconds: 30)); });
    await tester.pumpAndSettle();
    final lowImage = tester.widgetList<RawImage>(find.byType(RawImage)).map((w) => w.image).whereType<ui.Image>().first.clone();
    final before = await frame();
    final pending = Completer<ImageInfo>();
    tester.binding.imageCache.putIfAbsent(FileImage(high), () => OneFrameImageStreamCompleter(pending.future));
    await tester.pumpWidget(photo(1600));

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    // Another viewer may mount while the higher-resolution file is pending.
    await tester.pumpWidget(photo(1600, key: const ValueKey('destination')));
    await tester.pump();
    expect(await frame(), before, reason: 'The visible photo must not flash while the higher resolution is decoding.');
    final visibleImages = tester.widgetList<RawImage>(find.byType(RawImage)).map((w) => w.image).whereType<ui.Image>();
    expect(visibleImages.any((image) => image.isCloneOf(lowImage)), isTrue,
      reason: 'Do not replace the thumbnail with the still-undecoded high-resolution file.');
    pending.complete(ImageInfo(image: lowImage.clone()));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    tester.binding.imageCache.clear();
    tester.binding.imageCache.clearLiveImages();
    lowImage.dispose();
  });

  test('concurrent badges from one photo share source decoding', () async {
    final bytes = (await rootBundle.load('assets/samples/lantern.jpg')).buffer.asUint8List();
    var reads = 0;
    const photos = MethodChannel('com.fluttercandies/photo_manager');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(photos, (call) async => switch(call.method) {
      'fetchEntityProperties' => {'id': 'badge-fixture', 'type': 1, 'width': 600, 'height': 900},
      'getThumb' => () { reads++; return bytes; }(),
      _ => null,
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(photos, null));
    final item = PhotoItem(id: 'badge-fixture', taken: DateTime(2026), width: 600, height: 900);
    final colors = [KeptColor(l: .60, a: .18, b: .08), KeptColor(l: .65, a: .16, b: .09), KeptColor(l: .7, a: .1, b: .08)];
    final watch = Stopwatch()..start();
    await Future.wait([for (final c in colors) Store.instance.patch(item, c)]);
    // A repeat in the same session is already expected to hit memory.
    await Future.wait([for (final c in colors) Store.instance.patch(item, c)]);
    debugPrint('Cold badge load: $reads source requests, ${watch.elapsedMilliseconds} ms');
    expect(reads, 1);
    final cold = watch.elapsedMilliseconds;
    // A fresh cache instance simulates relaunch; no photo fetch or extraction.
    final relaunched = PhotoPatchCache(Directory('${directory.path}/patches'));
    watch.reset();
    await Future.wait([for (final color in colors) relaunched.get(item.id, color)]);
    expect(reads, 1);
    expect(relaunched.ready(item.id, colors.first), isNotNull);
    debugPrint('Disk badge reload: ${watch.elapsedMilliseconds} ms (cold: $cold ms)');
  });
}
