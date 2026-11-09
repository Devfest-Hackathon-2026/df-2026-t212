import 'package:flutter/services.dart';

import '../core/recipe.dart';
import '../core/renderer.dart';

/// What the camera started with: the texture to show and its size, upright,
/// and what the lens in use can do.
class LiveFeed {
  LiveFeed(this.texture, this.width, this.height);

  factory LiveFeed.from(Map<String, Object?> r) {
    final f = LiveFeed(r['texture'] as int, (r['width'] as num).round(), (r['height'] as num).round())
      ..front = r['front'] as bool? ?? false
      ..flash = r['flash'] as bool? ?? false
      ..maxBias = (r['bias'] as num?)?.toDouble() ?? 0
      ..resolutions = [for (final m in (r['resolutions'] as List?) ?? const []) (m as num).toInt()];
    final z = r['zoom'] as Map?;
    if (z != null) {
      f
        ..live = true
        ..stops = [for (final s in z['stops'] as List) (s as num).toDouble()]
        ..minZoom = (z['min'] as num).toDouble()
        ..maxZoom = (z['max'] as num).toDouble()
        ..zoom = (z['now'] as num).toDouble();
    }
    return f;
  }

  final int texture;
  final int width, height;
  double get aspect => width / height;

  /// A real camera, not a photo standing in for one.
  bool live = false;
  bool front = false;

  /// Whether this lens has a flash.
  bool flash = false;

  /// The zoom factors shown as buttons (0.5, 1, 2, 3…), and the range, as
  /// the system camera counts them.
  List<double> stops = const [1];
  double minZoom = 1, maxZoom = 1, zoom = 1;

  /// How far exposure can be pushed either way, in stops.
  double maxBias = 0;

  /// The photo sizes on offer, in megapixels.
  List<int> resolutions = const [];
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
    return LiveFeed.from(r!);
  }

  /// What the camera says unasked: `shutter` (a volume button), `focusReset`
  /// (the scene moved on from a tapped point), `orientation` (degrees the
  /// photo will be turned: 90 upright, 0 or 180 on its side).
  static void listen(void Function(String event, Object? args)? on) {
    _ch.setMethodCallHandler(on == null ? null : (call) async => on(call.method, call.arguments));
  }

  /// Zooms to [factor] as shown (0.5, 1, 2…); smoothly when [ramp]. Returns
  /// the factor reached.
  static Future<double?> zoom(double factor, {bool ramp = false}) =>
      _ch.invokeMethod<double>('zoom', {'factor': factor, 'ramp': ramp});

  /// Focuses and exposes for a normalized point of the view.
  static Future<void> focus(double x, double y) => _ch.invokeMethod('focus', {'x': x, 'y': y});

  /// Holds the view on the frame it shows, or lets it run again.
  static Future<void> freeze(bool on) => _ch.invokeMethod('freeze', {'on': on});

  /// Holds focus and exposure where they are.
  static Future<void> lock(bool on) => _ch.invokeMethod('lock', {'on': on});

  /// Brighter or darker than the meter, in stops.
  static Future<double?> bias(double ev) => _ch.invokeMethod<double>('bias', {'ev': ev});

  /// `off`, `auto` or `on`.
  static Future<void> flash(String mode) => _ch.invokeMethod('flash', {'mode': mode});

  /// The photo size in megapixels; 0 for the largest.
  static Future<void> resolution(int mp) => _ch.invokeMethod('resolution', {'mp': mp});

  /// Lets the phone go to the ultra wide by itself close up, or keeps it on
  /// the main lens.
  static Future<void> macro(bool on) => _ch.invokeMethod('macro', {'on': on});

  /// To the camera on the other side.
  static Future<LiveFeed> flip() async => LiveFeed.from((await _ch.invokeMapMethod<String, Object?>('flip'))!);

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
