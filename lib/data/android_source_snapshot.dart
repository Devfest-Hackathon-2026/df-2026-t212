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
    // Read through the plugin directly: the AssetEntity originBytes wrapper
    // falls back to a file on Android 10. That file getter may
    // return a cached copy whose name does not include the modified version.
    final bytes = await PhotoManager.plugin.getOriginBytes(id);
    if (bytes == null || bytes.isEmpty || await version(id) != modified) return null;
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
