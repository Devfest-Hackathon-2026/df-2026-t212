import 'dart:io';
import 'dart:convert';
import 'package:afterhue/core/recipe.dart';
import 'package:afterhue/core/renderer.dart';
import 'package:afterhue/data/photo_source.dart';
import 'package:afterhue/data/store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'source_tracking_test.dart' as fixture;

void main() {
  testWidgets('source versions stay frozen, update locally, persist and undo without AI', (tester) async {
    final folder = Directory.systemTemp.createTempSync('afterhue-source-');
    final messenger = tester.binding.defaultBinaryMessenger;
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    const native = MethodChannel('afterhue/source_snapshot');
    var version = 1, captures = 0;
    Uint8List encode(Rgba px) => Uint8List.fromList(img.encodePng(img.Image.fromBytes(
      width: px.width, height: px.height, bytes: px.pixels.buffer, numChannels: 4)));
    var bytes = encode(fixture.scene());
    messenger.setMockMethodCallHandler(paths, (_) async => folder.path);
    messenger.setMockMethodCallHandler(native, (call) async {
      if (call.method == 'version') return version;
      captures++;
      return {'bytes': bytes, 'modified': version, 'width': 96, 'height': 96};
    });
    final store = Store.instance;
    await tester.runAsync(() async {
      await store.init();
      final photos = await store.importRefs([PhotoRef(id: 'source-photo', taken: DateTime(2026), width: 96, height: 96)]);
      final item = photos.single;
      final first = await store.sourcePixels(item, 192);
      expect(first, isNotNull);
      final baseline = item.sourceRevision;
      expect(item.sourceSize, [96, 96]);
      store.setEdit(item, fixture.recipe(first!));
      await Future<void>.delayed(const Duration(milliseconds: 80));
      bytes = encode(fixture.scene(shift: 35)); version++;
      final frozen = await store.sourcePixels(item, 192);
      expect(frozen!.pixels, first.pixels);
      await store.checkSourceChanges();
      expect(item.sourceRevision, baseline);
      expect(item.pendingSource, isNotNull);
      expect(item.pendingEdit, isNotNull, reason: item.sourceReview);
      expect(store.activity.first.title, 'Originals updated · review');
      final pending = item.pendingSource;
      expect(store.applySourceUpdate(item), isTrue);
      expect(item.sourceRevision, pending);
      expect(item.previousSource, baseline);
      expect((await store.sourcePixels(item, 192))!.pixels, isNot(first.pixels));
      await Future<void>.delayed(const Duration(milliseconds: 900));
      final saved = jsonDecode(await File('${folder.path}/state.json').readAsString()) as Map;
      final restored = PhotoItem.fromJson(Map<String, dynamic>.from((saved['items'] as List).single));
      expect(restored.sourceRevision, pending);
      expect(restored.previousSource, baseline);
      expect(restored.previousEdit, isNotNull);
      expect(store.undoSourceUpdate(item), isTrue);
      expect(item.sourceRevision, baseline);
      expect((await store.sourcePixels(item, 192))!.pixels, first.pixels);
      final count = captures;
      await store.checkSourceChanges();
      expect(captures, count, reason: 'The acknowledged version must not be proposed repeatedly');

      store.setFollowSourceChanges(true);
      store.openPhotoViews = 1;
      bytes = encode(fixture.scene(shift: 25)); version++;
      await store.checkSourceChanges();
      expect(item.sourceRevision, baseline, reason: 'Never swap the photo being viewed');
      expect(item.pendingEdit, isNotNull);
      store.openPhotoViews = 0;
      store.keepSource(item);
      bytes = encode(fixture.scene(shift: 30)); version++;
      await store.checkSourceChanges();
      expect(item.sourceRevision, isNot(baseline));
      expect(item.pendingSource, isNull);
      expect(store.activity.first.title, 'Originals updated');

      final snapshot = Recipe.fromJson(item.edit!.toJson());
      bytes = encode(fixture.scene(shift: 45, split: true)); version++;
      await store.checkSourceChanges();
      expect(item.pendingEdit, isNull);
      expect(item.sourceReview, isNotNull);
      expect(item.edit!.signature, snapshot.signature);
      await store.resetForDemo();
    });
    await tester.pump();
    messenger.setMockMethodCallHandler(native, null);
    messenger.setMockMethodCallHandler(paths, null);
    folder.deleteSync(recursive: true);
  });
}
