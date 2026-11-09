import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:photo_manager/photo_manager.dart';

import '../core/renderer.dart';

enum Access { unknown, denied, limited, full }

class PhotoRef {
  PhotoRef({required this.id, required this.taken, this.lat, this.lng, required this.width, required this.height});
  final String id;
  final DateTime taken;
  final double? lat, lng;
  final int width, height;
}

/// Reads the OS photo library. Originals are never modified.
class PhotoSource {
  static Future<Access> access({bool request = false}) async {
    final state = request
        ? await PhotoManager.requestPermissionExtend()
        : await PhotoManager.getPermissionState(requestOption: const PermissionRequestOption());
    switch (state) {
      case PermissionState.authorized:
        return Access.full;
      case PermissionState.limited:
        return Access.limited;
      case PermissionState.denied:
      case PermissionState.restricted:
        return Access.denied;
      case PermissionState.notDetermined:
        return Access.unknown;
    }
  }

  static Future<void> presentLimitedPicker() => PhotoManager.presentLimited();

  /// Deletes photos from the library. iOS asks the person first, and the
  /// photos go to Recently Deleted. Returns the ids that were deleted.
  static Future<Set<String>> delete(List<String> ids) async {
    if (ids.isEmpty) return {};
    try {
      return (await PhotoManager.editor.deleteWithIds(ids)).toSet();
    } catch (_) {
      return {};
    }
  }

  /// Photos taken in the last [months], newest first.
  static Future<List<PhotoRef>> recent({int months = 12, bool skipScreenshots = true}) async {
    final since = DateTime.now().subtract(Duration(days: 30 * months));
    final filter = FilterOptionGroup(
      imageOption: const FilterOption(sizeConstraint: SizeConstraint(minWidth: 400, minHeight: 400)),
      createTimeCond: DateTimeCond(min: since, max: DateTime.now().add(const Duration(days: 1))),
      orders: [const OrderOption(type: OrderOptionType.createDate, asc: false)],
    );
    final paths = await PhotoManager.getAssetPathList(type: RequestType.image, onlyAll: true, filterOption: filter);
    if (paths.isEmpty) return [];
    final all = paths.first;
    final count = await all.assetCountAsync;
    final out = <PhotoRef>[];
    final shots = skipScreenshots ? await screenshotIds() : const <String>{};
    const page = 200;
    for (var p = 0; p * page < count; p++) {
      final assets = await all.getAssetListPaged(page: p, size: page);
      for (final a in assets) {
        if (skipScreenshots && (shots.contains(a.id) || isScreenshot(a))) continue;
        out.add(await refOf(a));
      }
    }
    return out;
  }

  static Future<PhotoRef> refOf(AssetEntity a) async {
    double? lat = a.latitude, lng = a.longitude;
    if (lat == null || lng == null || (lat == 0 && lng == 0)) {
      final ll = await a.latlngAsync();
      lat = ll?.latitude;
      lng = ll?.longitude;
    }
    final hasLoc = lat != null && lng != null && !(lat == 0 && lng == 0);
    return PhotoRef(
      id: a.id,
      taken: a.createDateTime,
      lat: hasLoc ? lat : null,
      lng: hasLoc ? lng : null,
      width: a.orientatedWidth,
      height: a.orientatedHeight,
    );
  }

  /// The whole library, newest first, for picking photos by hand.
  static Future<List<AssetEntity>> library({int page = 0, int size = 120}) async {
    final paths = await PhotoManager.getAssetPathList(
      type: RequestType.image,
      onlyAll: true,
      filterOption: FilterOptionGroup(orders: [const OrderOption(type: OrderOptionType.createDate, asc: false)]),
    );
    if (paths.isEmpty) return [];
    return paths.first.getAssetListPaged(page: page, size: size);
  }

  static Future<Uint8List?> thumb(AssetEntity a, {int side = 240}) =>
      a.thumbnailDataWithSize(ThumbnailSize.square(side));

  /// Everything in the system Screenshots album. The asset's own subtype
  /// flag and title are often empty on iOS, so the album is the reliable test.
  static Future<Set<String>> screenshotIds() async {
    try {
      final paths = await PhotoManager.getAssetPathList(
        type: RequestType.image,
        hasAll: false,
        pathFilterOption: const PMPathFilter(
          darwin: PMDarwinPathFilter(
            type: [PMDarwinAssetCollectionType.smartAlbum],
            subType: [PMDarwinAssetCollectionSubtype.smartAlbumScreenshots],
          ),
        ),
      );
      final ids = <String>{};
      // Only the Screenshots album itself, in case the filter is ignored.
      for (final p in paths.where((p) => p.albumTypeEx?.darwin?.subtype == PMDarwinAssetCollectionSubtype.smartAlbumScreenshots)) {
        final n = await p.assetCountAsync;
        for (var i = 0; i < n; i += 500) {
          for (final a in await p.getAssetListRange(start: i, end: i + 500 > n ? n : i + 500)) {
            ids.add(a.id);
          }
        }
      }
      return ids;
    } catch (_) {
      return {};
    }
  }

  static bool isScreenshot(AssetEntity a) {
    final t = a.title?.toLowerCase() ?? '';
    return t.startsWith('screenshot') || t.contains('screen shot') || (a.subtype & 4) != 0;
  }

  static final _entities = <String, AssetEntity>{};

  static Future<AssetEntity?> _entity(String id) async =>
      _entities[id] ??= (await AssetEntity.fromId(id))!;

  /// JPEG bytes of the photo, long side at most [maxSide].
  static Future<Uint8List?> jpeg(String id, int maxSide) async {
    try {
      final e = await _entity(id);
      return await e!.thumbnailDataWithSize(ThumbnailSize.square(maxSide), quality: 92);
    } catch (_) {
      return null;
    }
  }

  // Shared across badge colors and render requests. A bounded decoded cache
  // avoids repeated native reads without retaining the whole photo library.
  static final _pixels = <String, Rgba>{};
  static final _loadingPixels = <String, Future<Rgba?>>{};
  static int _pixelBytes = 0;
  static const _pixelBudget = 24 * 1024 * 1024;

  static Future<Rgba?> pixels(String id, int maxSide) {
    final key = '$id@$maxSide';
    final hit = _pixels.remove(key);
    if (hit != null) {
      _pixels[key] = hit;
      return Future.value(hit);
    }
    return _loadingPixels.putIfAbsent(key, () => _decodePhoto(id, maxSide, key)
        .whenComplete(() { _loadingPixels.remove(key); }));
  }

  static Future<Rgba?> _decodePhoto(String id, int maxSide, String key) async {
    final bytes = await jpeg(id, maxSide);
    if (bytes == null) return null;
    final pixels = await decodeRgba(bytes, maxSide: maxSide);
    _pixels[key] = pixels;
    _pixelBytes += pixels.pixels.lengthInBytes;
    while (_pixelBytes > _pixelBudget && _pixels.isNotEmpty) {
      _pixelBytes -= _pixels.remove(_pixels.keys.first)!.pixels.lengthInBytes;
    }
    return pixels;
  }

  /// The original file, for sharing.
  static Future<String?> originalPath(String id) async {
    final e = await _entity(id);
    return (await e?.file)?.path;
  }
}

Future<Rgba> decodeRgba(Uint8List bytes, {int? maxSide}) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  final desc = await ui.ImageDescriptor.encoded(buffer);
  int? tw, th;
  if (maxSide != null && (desc.width > desc.height ? desc.width : desc.height) > maxSide) {
    if (desc.width >= desc.height) {
      tw = maxSide;
    } else {
      th = maxSide;
    }
  }
  final codec = await desc.instantiateCodec(targetWidth: tw, targetHeight: th);
  final frame = await codec.getNextFrame();
  final img = frame.image;
  final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
  final out = Rgba(img.width, img.height, data!.buffer.asUint8List());
  img.dispose();
  codec.dispose();
  desc.dispose();
  buffer.dispose();
  return out;
}

