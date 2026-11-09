import 'package:flutter/services.dart';

import '../core/recipe.dart';
import '../core/renderer.dart';

/// What the camera started with: the texture to show and its size, upright.
class LiveFeed {
  LiveFeed(this.texture, this.width, this.height);
  final int texture;
  final int width, height;
  double get aspect => width / height;
}

/// A photo the shutter saved to the library.
class Shot {
  Shot(this.id, this.taken, this.width, this.height, this.lat, this.lng);
  final String id;
  final DateTime taken;
  final int width, height;
  final double? lat, lng;
}

/// The native camera (ios/Runner/LiveCamera.swift). Its viewfinder is
/// developed on the GPU with the look given to [look]; the shutter saves the
/// untouched original.
class LiveCamera {
  static const _ch = MethodChannel('afterhue/camera');

  /// [still] is a photo to stand in for the feed where there is no camera.
  static Future<LiveFeed> start({String? still}) async {
    final r = await _ch.invokeMapMethod<String, Object?>('start', {'still': ?still});
    return LiveFeed(r!['texture'] as int, (r['width'] as num).round(), (r['height'] as num).round());
  }

  static Future<void> stop() => _ch.invokeMethod('stop');

  /// Everything of [r] but its area, which a live view cannot follow.
  static Future<void> look(Recipe r) => _ch.invokeMethod('look', {
    'colors': [
      for (final c in r.colors)
        [
          c.hue,
          c.width,
          c.softness,
          c.chromaMin,
          c.lightness?[0] ?? 0,
          c.lightness?[1] ?? 1,
          c.lightness == null ? 0 : 1,
        ],
    ],
    'contrast': r.contrast,
    'ambience': r.ambience,
    'vignette': r.vignette,
    'vignetteRadius': r.vignetteRadius,
  });

  /// The color at a normalized point of the view.
  static Future<KeptColor?> sample(double x, double y) async {
    final v = await _ch.invokeListMethod<double>('sample', {'x': x, 'y': y});
    if (v == null) return null;
    return KeptColor(l: v[0], a: v[1], b: v[2]);
  }

  /// A small copy of what the camera sees now.
  static Future<Rgba?> thumb({int width = 96}) async {
    final r = await _ch.invokeMapMethod<String, Object?>('thumb', {'width': width});
    if (r == null) return null;
    return Rgba(r['width'] as int, r['height'] as int, r['pixels'] as Uint8List);
  }

  /// The original, uncolored by the look, in a square of [side] frame
  /// pixels around a normalized point, and the color at its middle.
  static Future<({int side, Uint8List pixels, KeptColor color})?> loupe(double x, double y, {int side = 96}) async {
    final r = await _ch.invokeMapMethod<String, Object?>('loupe', {'x': x, 'y': y, 'side': side});
    if (r == null) return null;
    final lab = (r['lab'] as List).cast<num>();
    return (
      side: r['side'] as int,
      pixels: r['pixels'] as Uint8List,
      color: KeptColor(l: lab[0].toDouble(), a: lab[1].toDouble(), b: lab[2].toDouble()),
    );
  }

  static Future<Shot> capture() async {
    final r = (await _ch.invokeMapMethod<String, Object?>('capture'))!;
    return Shot(
      r['id'] as String,
      DateTime.fromMillisecondsSinceEpoch(r['taken'] as int),
      r['width'] as int,
      r['height'] as int,
      (r['lat'] as num?)?.toDouble(),
      (r['lng'] as num?)?.toDouble(),
    );
  }
}
