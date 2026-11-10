import 'package:photo_manager/photo_manager.dart';

/// Android uses MediaStore through photo_manager; the iOS snapshot channel is
/// not registered there. Read fresh metadata, never the thumbnail/entity cache.
class AndroidSourceSnapshot {
  static Future<int?> version(String id) async =>
      (await AssetEntity.fromId(id))?.modifiedDateTime.millisecondsSinceEpoch;

  static Future<Map<String, dynamic>?> capture(String id) async {
    final asset = await AssetEntity.fromId(id);
    if (asset == null) return null;
    final modified = asset.modifiedDateTime.millisecondsSinceEpoch;
    final file = await asset.file;
    if (file == null) return null;
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty || await version(id) != modified) return null;
    // PhotoSource copies these bytes into its content-addressed private store.
    // A concurrent library edit is retried instead of assigning the wrong version.
    return {
      'bytes': bytes,
      'modified': modified,
      'width': asset.orientatedWidth,
      'height': asset.orientatedHeight,
    };
  }
}
