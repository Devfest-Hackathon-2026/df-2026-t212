import 'dart:io';
import 'package:afterhue/data/android_source_snapshot.dart';
import 'package:afterhue/data/photo_source.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_manager/photo_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('Android requests photos and media metadata, not videos', () {
    final option = PhotoSource.permissionOption.androidPermission;
    expect(option.type, RequestType.image);
    expect(option.mediaLocation, isTrue);
  });

  test('Android snapshots read fresh versions and reject changes during capture', () async {
    final folder = Directory.systemTemp.createTempSync('afterhue-android-source-');
    final file = File('${folder.path}/42.jpg');
    await file.writeAsBytes([1, 2, 3, 4]);
    const channel = MethodChannel('com.fluttercandies/photo_manager');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var modified = 100;
    var changeDuringRead = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'fetchEntityProperties') {
        expect(call.arguments['id'], '42');
        return {'id': '42', 'type': 1, 'width': 600, 'height': 900, 'modifiedDt': modified};
      }
      if (call.method == 'getFullFile') {
        if (changeDuringRead) modified++;
        return file.path;
      }
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      folder.deleteSync(recursive: true);
    });
    expect(await AndroidSourceSnapshot.version('42'), 100000);
    final first = await AndroidSourceSnapshot.capture('42');
    expect(first!['bytes'], [1, 2, 3, 4]);
    expect(first['modified'], 100000);
    expect([first['width'], first['height']], [600, 900]);
    modified++;
    await file.writeAsBytes([5, 6]);
    final second = await AndroidSourceSnapshot.capture('42');
    expect(second!['modified'], 101000);
    expect(second['bytes'], [5, 6]);
    expect(first['bytes'], [1, 2, 3, 4]);
    changeDuringRead = true;
    expect(await AndroidSourceSnapshot.capture('42'), isNull);
  });
}
