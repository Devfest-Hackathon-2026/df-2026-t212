import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import '../core/recipe.dart';
import '../core/renderer.dart';
import 'photo_source.dart';

/// Small persistent swatches. Disk hits never need the original photo; new
/// patches share source decoding and only two extraction jobs run at once.
class PhotoPatchCache {
  PhotoPatchCache(this.directory);
  final Directory directory;
  final _ready = <String, ui.Image?>{};
  final _pending = <String, Future<ui.Image?>>{};
  final _waiting = Queue<Completer<void>>();
  int _running = 0;

  String _key(String id, KeptColor c, bool soft, bool light) => base64Url.encode(utf8.encode(
    '$id|${c.l.toStringAsFixed(3)},${c.a.toStringAsFixed(3)},${c.b.toStringAsFixed(3)}|$soft|$light',
  )).replaceAll('=', '');

  ({ui.Image? image})? ready(String id, KeptColor c, {bool soft = false, bool light = false}) {
    final key = _key(id, c, soft, light);
    if (!_ready.containsKey(key)) return null;
    final image = _ready.remove(key);
    _ready[key] = image;
    return (image: image);
  }

  Future<ui.Image?> get(String id, KeptColor color, {String? sourceId, bool soft = false, bool light = false}) {
    final key = _key(id, color, soft, light);
    final hit = ready(id, color, soft: soft, light: light);
    if (hit != null) return SynchronousFuture(hit.image);
    return _pending.putIfAbsent(key, () => _load(key, sourceId ?? id, color.copy(), soft, light).whenComplete(() { _pending.remove(key); }));
  }

  Future<ui.Image?> _load(String key, String id, KeptColor color, bool soft, bool light) async {
    final file = File('${directory.path}/v1-$key.png');
    try {
      if (await file.exists()) {
        final bytes = await file.readAsBytes();
        final image = bytes.isEmpty ? null : await _decode(bytes);
        _remember(key, image);
        return image;
      }
    } catch (_) { /* A corrupt or evicted cache entry is regenerated. */ }
    if (_running >= 2) {
      final slot = Completer<void>();
      _waiting.add(slot);
      await slot.future;
    } else {
      _running++;
    }
    try {
      final pixels = await PhotoSource.pixels(id, 1024);
      // Missing/iCloud-unavailable photos can be retried later.
      if (pixels == null) return null;
      final bytes = await Isolate.run(() {
        var patch = colorPatch(pixels, color);
        if (patch == null) return Uint8List(0);
        if (soft) patch = boxBlur(patch, math.max(1, patch.width ~/ 10), passes: 3);
        if (light) patch = liftPatch(patch, .8);
        return img.encodePng(img.Image.fromBytes(width: patch.width, height: patch.height,
          bytes: patch.pixels.buffer, numChannels: 4));
      });
      final image = bytes.isEmpty ? null : await _decode(bytes);
      _remember(key, image);
      try {
        await directory.create(recursive: true);
        final temp = File('${file.path}.tmp');
        await temp.writeAsBytes(bytes, flush: true);
        await temp.rename(file.path);
      } on FileSystemException { /* Memory caching still works if disk is full. */ }
      return image;
    } finally {
      if (_waiting.isNotEmpty) {
        _waiting.removeFirst().complete();
      } else {
        _running--;
      }
    }
  }

  void _remember(String key, ui.Image? image) {
    _ready.remove(key);
    _ready[key] = image;
    // Drop cache references; active RawImages may still own these handles.
    while (_ready.length > 256) { _ready.remove(_ready.keys.first); }
  }

  static Future<ui.Image> _decode(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    try { return (await codec.getNextFrame()).image; }
    finally { codec.dispose(); }
  }
}
