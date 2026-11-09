import 'dart:io';
import 'package:afterhue/data/photo_source.dart';
import 'package:afterhue/data/store.dart';
import 'package:afterhue/ui/widgets/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'source_tracking_test.dart' as fixture;

void main() {
  testWidgets('cached gallery never captures originals; freezing preserves its cache', (tester) async {
    final folder = Directory.systemTemp.createTempSync('afterhue-startup-');
    final messenger = tester.binding.defaultBinaryMessenger;
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    const native = MethodChannel('afterhue/source_snapshot');
    final px = fixture.scene();
    final bytes = Uint8List.fromList(img.encodePng(img.Image.fromBytes(
      width: px.width, height: px.height, bytes: px.pixels.buffer, numChannels: 4)));
    var captures = 0;
    messenger.setMockMethodCallHandler(paths, (_) async => folder.path);
    messenger.setMockMethodCallHandler(native, (call) async {
      if (call.method == 'version') return 1;
      captures++;
      return {'bytes': bytes, 'modified': 1, 'width': 96, 'height': 96};
    });
    final store = Store.instance;
    late PhotoItem item;
    late File cached;
    await tester.runAsync(() async {
      await store.init();
      item = (await store.importRefs([PhotoRef(id: 'cached-photo', taken: DateTime(2026), width: 96, height: 96)])).single;
      store.setEdit(item, fixture.recipe(px));
      cached = File('${folder.path}/renders/${item.id}_${item.edit!.signature}_480.jpg');
      await cached.writeAsBytes(bytes);
      await File(cached.path.replaceAll("_480.jpg", "_240.jpg")).writeAsBytes(bytes);
    });
    await tester.pumpWidget(MaterialApp(home: SizedBox(width: 100, height: 100,
      child: DevelopedImage(item, placeholder: OriginalImage(item)))));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
    await tester.pump();
    expect(captures, 0, reason: 'A disk hit must not load the full-size original as its placeholder');
    await tester.runAsync(() async {
      await store.ensureSource(item);
      expect(captures, 1);
      final restored = PhotoItem.fromJson(item.toJson());
      expect((await store.rendered(restored, 240))!.path, cached.path.replaceAll("_480.jpg", "_240.jpg"),
        reason: 'Creating the baseline must not invalidate an unchanged rendered photo');
      restored.pendingSource = 'b' * 64;
      restored.pendingEdit = restored.edit!.copy();
      // Version identity must change when the source actually changes.
      restored.sourceRevision = restored.pendingSource;
      expect(restored.sourceCacheId, isNot(item.sourceCacheId));
    });
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(store.resetForDemo);
    await tester.pump();
    messenger.setMockMethodCallHandler(native, null);
    messenger.setMockMethodCallHandler(paths, null);
    folder.deleteSync(recursive: true);
  });
}
