import 'dart:convert';
import 'dart:io';
import 'package:afterhue/data/activity.dart';
import 'package:afterhue/data/photo_source.dart';
import 'package:afterhue/data/store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('only identical original bytes are excluded; unknown and similar files stay', () async {
    final folder = Directory.systemTemp.createTempSync('afterhue-exact-');
    final original = File('${folder.path}/original.jpg')..writeAsBytesSync([1, 2, 3, 4, 5]);
    final identical = File('${folder.path}/identical.jpg')..writeAsBytesSync([1, 2, 3, 4, 5]);
    final similar = File('${folder.path}/similar.jpg')..writeAsBytesSync([1, 2, 3, 4, 6]);
    final files = {'exact-original': original.path, 'exact-copy': identical.path,
      'exact-similar': similar.path, 'exact-reimport': identical.path};
    final reads = <String>[];
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    const photos = MethodChannel('com.fluttercandies/photo_manager');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(paths, (_) async => folder.path);
    messenger.setMockMethodCallHandler(photos, (call) async {
      final id = call.arguments['id'] as String?;
      switch (call.method) {
        case 'fetchEntityProperties': return {'id': id, 'type': 1, 'width': 600, 'height': 900};
        case 'isLocallyAvailable':
          expect(call.arguments['isOrigin'], isTrue);
          return files.containsKey(id);
        case 'getFullFile':
          expect(call.arguments['isOrigin'], isTrue);
          reads.add(id!);
          return files[id];
        default: return null;
      }
    });
    final store = Store.instance;
    await store.init();
    PhotoRef ref(String id) => PhotoRef(id: id, taken: DateTime(2026), width: 600, height: 900);
    final imported = await store.importRefs([
      ref('exact-original'), ref('exact-copy'), ref('exact-similar'), ref('exact-cloud'),
    ]);
    expect(imported.map((it) => it.id), ['exact-original', 'exact-similar', 'exact-cloud']);
    final first = store.byKey('exact-original')!, copy = store.byKey('exact-copy')!;
    expect(copy.exactDuplicateOf, first.key);
    expect(copy.shown, isFalse);
    expect(store.byKey('exact-similar')!.originalSha256, isNot(first.originalSha256));
    expect(store.byKey('exact-cloud')!.shown, isTrue);
    final expectedReads = ['exact-original', 'exact-copy', 'exact-similar',
      // On Android (and Linux CI), photo_manager reports local availability
      // unconditionally; a missing source is then discovered by the file read.
      if (!Platform.isIOS && !Platform.isMacOS) 'exact-cloud'];
    expect(reads, expectedReads);
    expect(store.activity.first.count(ActivityOutcome.skipped), 1);
    expect(store.activity.first.count(ActivityOutcome.added), 3);
    expect(await PhotoSource.originalHash(first.id), first.originalSha256);
    expect(reads, expectedReads, reason: 'Hashes are reused, not recomputed for every import.');
    expect(await store.importRefs([ref('exact-copy')], autoDevelop: true), isEmpty);
    expect(store.runFor(copy), isNull, reason: 'An exact duplicate must not consume AI processing.');
    expect(store.pendingCount, 0);
    final editedCopy = store.duplicate(first);
    expect(editedCopy.shown, isTrue, reason: 'Intentional After Hue edit copies remain available.');
    store.remove(editedCopy);
    store.remove(first);
    expect(await store.importRefs([ref('exact-reimport')]), hasLength(1),
      reason: 'An explicit reimport after removal is still allowed.');
    await store.regroupSimilarPhotos();
    await Future<void>.delayed(const Duration(milliseconds: 550));
    final saved = jsonDecode(File('${folder.path}/state.json').readAsStringSync());
    expect((saved['items'] as List).any((it) => it['originalSha256'] != null), isTrue);
    messenger.setMockMethodCallHandler(paths, null);
    messenger.setMockMethodCallHandler(photos, null);
    folder.deleteSync(recursive: true);
  });
}
