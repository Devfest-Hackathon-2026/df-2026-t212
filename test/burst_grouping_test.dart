import 'dart:convert';
import 'dart:io';
import 'package:afterhue/core/burst_similarity.dart';
import 'package:afterhue/core/renderer.dart';
import 'package:afterhue/data/photo_source.dart';
import 'package:afterhue/data/store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List pattern({int light = 0, bool flip = false}) => Uint8List.fromList(List.generate(768, (i) {
  final cell = i ~/ 3, x = cell % 16, y = cell ~/ 16;
  return (((flip ? 15-x : x) * 11 + y * 4 + (i % 3) * 8) + light).clamp(0, 255);
}));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('conservative composition matching rejects different and featureless photos', () {
    expect(similarBurst(pattern(), pattern(light: 4)), isTrue);
    expect(similarBurst(pattern(), pattern(flip: true)), isFalse);
    expect(similarBurst(Uint8List(768), Uint8List(768)), isFalse);
    final pixels = Uint8List.fromList(List.generate(32 * 32 * 4, (i) => i % 4 == 3 ? 255 : (i ~/ 4 % 32) * 7));
    expect(burstSignature(Rgba(32, 32, pixels)).length, 768);
  });
  test('groups are bounded by time, editable, optional and persisted', () async {
    final folder = Directory.systemTemp.createTempSync('afterhue-groups-');
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(paths, (_) async => folder.path);
    final store = Store.instance;
    await store.init();
    final origin = DateTime(2026, 11, 10, 10);
    final photos = await store.importRefs([
      for (final (index, second) in [(0, 0), (1, 5), (2, 10), (3, 40)])
        PhotoRef(id: 'group-fixture-$index', taken: origin.add(Duration(seconds: second)), width: 600, height: 900),
    ]);
    for (var i = 0; i < photos.length; i++) {
      photos[i].burstPrint = pattern(light: i == 1 ? 3 : 0, flip: i == 2);
    }
    await store.regroupSimilarPhotos();
    expect(store.photoGroups.length, 1);
    final group = store.photoGroups.single;
    expect(group.members, unorderedEquals([photos[0].key, photos[1].key]));
    expect(store.galleryItems.length, 3);
    store.setGroupCover(photos[0]);
    expect(group.cover, photos[0].key);
    store.setGroupSimilarPhotos(false);
    expect(store.galleryItems.length, 4);
    store.setGroupSimilarPhotos(true);
    store.removeFromGroup(photos[0]);
    await store.regroupSimilarPhotos();
    expect(store.photoGroups, isEmpty);
    store.groupPhotos([photos[0], photos[2]]);
    expect(store.photoGroups.single.manual, isTrue);
    expect(store.photoGroups.single.members.length, 2);
    store.ungroupPhotos(store.photoGroups.single);
    await store.regroupSimilarPhotos();
    expect(store.photoGroups, isEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final saved = jsonDecode(File('${folder.path}/state.json').readAsStringSync());
    expect(saved['keepSeparate'], containsAll([photos[0].key, photos[2].key]));
    expect(saved['activity'].length, 1);
    expect(saved['activity'][0]['keys'].length, 4);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(paths, null);
    folder.deleteSync(recursive: true);
  });
  test('library refresh retains same-second bursts for composition grouping', () async {
    final folder = Directory.systemTemp.createTempSync('afterhue-burst-intake-');
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    const photos = MethodChannel('com.fluttercandies/photo_manager');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(paths, (_) async => folder.path);
    final now = DateTime.now();
    final assets = [for (var i = 0; i < 2; i++) {
      'id': 'same-second-$i', 'type': 1, 'width': 600, 'height': 900,
      'createDt': now.millisecondsSinceEpoch ~/ 1000, 'lat': 35.7, 'lng': 139.7,
    }];
    messenger.setMockMethodCallHandler(photos, (call) async => switch (call.method) {
      'getAssetPathList' => {'data': [{'id': 'all', 'name': 'All', 'isAll': true, 'assetCount': 2}]},
      'getAssetCountFromPath' => 2,
      'getAssetListPaged' => {'data': assets},
      _ => null,
    });
    final store = Store.instance;
    await store.init();
    store.access = Access.full;
    store.autoDevelop = true;
    store.skipScreenshots = false;
    for (var i = 0; i < 2; i++) {
      store.hold(PhotoItem(id: 'same-second-$i', taken: now, width: 600, height: 900));
    }
    await store.refresh();
    final first = store.byKey('same-second-0')!, second = store.byKey('same-second-1')!;
    expect([first.state, second.state], [Develop.pending, Develop.pending]);
    expect([first.note, second.note], [null, null]);
    first.burstPrint = pattern();
    second.burstPrint = pattern(light: 2);
    await store.regroupSimilarPhotos();
    expect(store.groupFor(first)!.members, contains(second.key));
    await Future<void>.delayed(const Duration(milliseconds: 500));
    messenger.setMockMethodCallHandler(paths, null);
    messenger.setMockMethodCallHandler(photos, null);
    folder.deleteSync(recursive: true);
  });

}
