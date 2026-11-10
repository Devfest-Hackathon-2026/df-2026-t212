import 'dart:convert';
import 'dart:io';
import 'package:afterhue/core/recipe.dart';
import 'package:afterhue/core/renderer.dart';
import 'package:afterhue/data/android_photo_location.dart';
import 'package:afterhue/data/photo_source.dart';
import 'package:afterhue/data/store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_manager/photo_manager.dart';

class MetadataAsset extends AssetEntity {
  MetadataAsset(this.metadata, {this.denied = false}) : super(id: 'photo', typeInt: 1,
    width: 600, height: 900, createDateSecond: 1700000000);
  final LatLng? metadata;
  final bool denied;
  @override Future<LatLng?> latlngAsync() async {
    if (denied) throw PlatformException(code: 'permission');
    return metadata;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('photo EXIF permission is checked independently from library access', () async {
    final calls = <String>[];
    var allowed = false;
    const channel = MethodChannel('afterhue/photo_location');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'request') allowed = true;
      return allowed;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    expect(await AndroidPhotoLocation.granted(), false);
    expect(await AndroidPhotoLocation.request(), true);
    expect(await AndroidPhotoLocation.granted(), true);
    expect(calls, ['granted', 'request', 'granted']);
    final manifest = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    expect(manifest, contains('android.permission.ACCESS_MEDIA_LOCATION'));
    expect(manifest, isNot(contains('android.permission.ACCESS_FINE_LOCATION')));
    expect(manifest, isNot(contains('android.permission.ACCESS_COARSE_LOCATION')));
  });
  test('async EXIF replaces absent indexed location; denied/missing metadata still imports', () async {
    final geo = await PhotoSource.refOf(MetadataAsset(LatLng.fromValues(latitude: 35.7148, longitude: 139.7967)));
    expect(geo.lat, 35.7148); expect(geo.lng, 139.7967);
    expect([geo.width, geo.height], [600, 900]);
    final denied = await PhotoSource.refOf(MetadataAsset(null, denied: true));
    expect(denied.id, 'photo'); expect(denied.lat, isNull); expect(denied.lng, isNull);
    final redacted = await PhotoSource.refOf(MetadataAsset(LatLng.fromValues(latitude: 0, longitude: 0)));
    expect(redacted.lat, isNull); expect(redacted.lng, isNull);
    final invalid = await PhotoSource.refOf(MetadataAsset(LatLng.fromValues(latitude: double.nan, longitude: 200)));
    expect(invalid.lat, isNull); expect(invalid.lng, isNull);
    final equator = await PhotoSource.refOf(MetadataAsset(LatLng.fromValues(latitude: 0, longitude: 15)));
    expect(equator.lat, 0); expect(equator.lng, 15);
  });
  testWidgets('later GPS metadata fills existing imports and copies without changing edits or duplicating photos', (tester) async {
    final directory = Directory.systemTemp.createTempSync('afterhue-location-');
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(paths, (_) async => directory.path);
    await tester.runAsync(() async {
      final store = Store.instance;
      await store.init();
      final ref = PhotoRef(id: 'geo-photo', taken: DateTime(2026), width: 600, height: 900);
      final original = (await store.importRefs([ref])).single;
      final recipe = Recipe(colors: [keptColorFromHex('#cc3322')!]);
      original.edit = recipe; original.state = Develop.done; original.favorite = true;
      final copy = PhotoItem(id: ref.id, copyOf: 'test-copy', taken: ref.taken,
        width: 600, height: 900, edit: recipe.copy(), state: Develop.done);
      store.items.add(copy);
      final metadata = PhotoRef(id: ref.id, taken: ref.taken, width: 600, height: 900, lat: 35.7, lng: 139.8);
      // This used to skip an already-visible item before applying its metadata.
      final added = await store.importRefs([metadata]);
      expect(added, isEmpty); expect(store.items, hasLength(2));
      expect(original.hasLocation, true); expect(copy.hasLocation, true);
      expect(original.lat, 35.7); expect(original.lng, 139.8);
      expect(original.edit!.signature, recipe.signature); expect(original.favorite, true);
      expect(original.state, Develop.done);
      store.updatePhotoLocations([PhotoRef(id: ref.id, taken: ref.taken, width: 600, height: 900, lat: 40, lng: 10)]);
      expect(original.lat, 35.7, reason: 'Existing photo location must not be silently replaced');
      await Future<void>.delayed(const Duration(milliseconds: 900));
      final state = jsonDecode(await File('${directory.path}/state.json').readAsString()) as Map;
      final restored = PhotoItem.fromJson(Map<String, dynamic>.from((state['items'] as List).first));
      expect(restored.lat, 35.7); expect(restored.lng, 139.8);
      await store.resetForDemo();
    });
    await tester.pump();
    messenger.setMockMethodCallHandler(paths, null);
    directory.deleteSync(recursive: true);
  });
}
