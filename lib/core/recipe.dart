import 'dart:math' as math;

/// One kept color. Stored in OKLab so it renders the same everywhere.
class KeptColor {
  KeptColor({
    required this.l,
    required this.a,
    required this.b,
    this.width = 16,
    this.softness = 20,
    this.chromaMin = 0.03,
    this.lightness,
  });

  double l, a, b;

  /// Hue degrees kept at full strength on each side.
  double width;

  /// Extra hue degrees over which the color fades to mono.
  double softness;

  /// Below this chroma, hue is unreliable, so the color fades in with chroma.
  double chromaMin;

  /// Optional [low, high] OKLab lightness gate.
  List<double>? lightness;

  double get chroma => math.sqrt(a * a + b * b);
  double get hue => (math.atan2(b, a) * 180 / math.pi + 360) % 360;

  KeptColor copy() => KeptColor(
        l: l,
        a: a,
        b: b,
        width: width,
        softness: softness,
        chromaMin: chromaMin,
        lightness: lightness == null ? null : List.of(lightness!),
      );

  Map<String, dynamic> toJson() => {
        'lab': [l, a, b],
        'width': width,
        'softness': softness,
        'chromaMin': chromaMin,
        if (lightness != null) 'lightness': lightness,
      };

  factory KeptColor.fromJson(Map<String, dynamic> j) {
    final lab = (j['lab'] as List).cast<num>();
    return KeptColor(
      l: lab[0].toDouble(),
      a: lab[1].toDouble(),
      b: lab[2].toDouble(),
      width: (j['width'] as num).toDouble(),
      softness: (j['softness'] as num).toDouble(),
      chromaMin: (j['chromaMin'] as num?)?.toDouble() ?? 0.03,
      lightness: (j['lightness'] as List?)?.cast<num>().map((e) => e.toDouble()).toList(),
    );
  }
}

/// Where color may stay. Coordinates are normalized to the photo (0..1).
class Area {
  Area({this.polygons = const [], this.ellipses = const [], this.edge = 0.03});

  /// Each polygon is a flat list of points: [[x, y], ...].
  List<List<List<double>>> polygons;

  /// Each ellipse is [cx, cy, rx, ry].
  List<List<double>> ellipses;

  /// Feather, as a fraction of the photo's short side.
  double edge;

  bool get isEmpty => polygons.isEmpty && ellipses.isEmpty;

  Area copy() => Area(
        polygons: polygons.map((p) => p.map((q) => List.of(q)).toList()).toList(),
        ellipses: ellipses.map((e) => List.of(e)).toList(),
        edge: edge,
      );

  Map<String, dynamic> toJson() => {'polygons': polygons, 'ellipses': ellipses, 'edge': edge};

  factory Area.fromJson(Map<String, dynamic> j) => Area(
        // Models sometimes send short or stray arrays; keep only well-formed shapes.
        polygons: ((j['polygons'] as List?) ?? [])
            .whereType<List>()
            .map((p) => p
                .whereType<List>()
                .where((q) => q.length >= 2 && q.every((e) => e is num))
                .map((q) => q.cast<num>().take(2).map((e) => e.toDouble()).toList())
                .toList())
            .where((p) => p.length >= 3)
            .toList(),
        ellipses: ((j['ellipses'] as List?) ?? [])
            .whereType<List>()
            .where((e) => e.length >= 4 && e.every((v) => v is num))
            .map((e) => e.cast<num>().take(4).map((v) => v.toDouble()).toList())
            .toList(),
        edge: (j['edge'] as num?)?.toDouble() ?? 0.03,
      );
}

/// A non-destructive edit. The original photo is never rewritten.
class Recipe {
  Recipe({
    List<KeptColor>? colors,
    this.area,
    this.contrast = 0.1,
    this.ambience = defaultAmbience,
    this.vignette = 0,
    this.vignetteRadius = defaultVignetteRadius,
    this.subject,
    this.why,
    this.focus,
  })
      : colors = colors ?? [];

  List<KeptColor> colors;
  Area? area;

  /// Tone of the black-and-white part.
  double contrast;

  /// How much of the light's color the black-and-white part keeps, 0-1.
  /// 0 is pure grey; higher keeps the warmth of a sunset or the blue of
  /// dusk as a faint tint, so the mono part still feels like the place.
  double ambience;
  static const defaultAmbience = 0.4;

  /// Darkening toward the edges, as in Photos: strength 0-1, and the radius
  /// where it is half way, in units of the half-diagonal (corners are 1).
  double vignette;
  double vignetteRadius;
  static const defaultVignetteRadius = 0.8;

  /// Short description of the subject, from the agent. Used for search.
  String? subject;

  /// The agent's reasoning, shown in "Why this color?".
  String? why;

  /// Normalized subject center, used to crop square thumbnails.
  List<double>? focus;

  static const maxColors = 3;

  Recipe copy() => Recipe(
        colors: colors.map((c) => c.copy()).toList(),
        area: area?.copy(),
        contrast: contrast,
        ambience: ambience,
        vignette: vignette,
        vignetteRadius: vignetteRadius,
        subject: subject,
        why: why,
        focus: focus == null ? null : List.of(focus!),
      );

  /// Stable key for render caching.
  String get signature => toJson().toString().hashCode.toRadixString(16);

  Map<String, dynamic> toJson() => {
        'colors': colors.map((c) => c.toJson()).toList(),
        if (area != null) 'area': area!.toJson(),
        'contrast': contrast,
        'ambience': ambience,
        if (vignette > 0) 'vignette': vignette,
        if (vignette > 0) 'vignetteRadius': vignetteRadius,
        if (subject != null) 'subject': subject,
        if (why != null) 'why': why,
        if (focus != null) 'focus': focus,
      };

  factory Recipe.fromJson(Map<String, dynamic> j) => Recipe(
        colors: ((j['colors'] as List?) ?? []).map((c) => KeptColor.fromJson(c as Map<String, dynamic>)).toList(),
        area: j['area'] == null ? null : Area.fromJson(j['area'] as Map<String, dynamic>),
        contrast: (j['contrast'] as num?)?.toDouble() ?? 0.1,
        ambience: (j['ambience'] as num?)?.toDouble() ?? defaultAmbience,
        vignette: (j['vignette'] as num?)?.toDouble() ?? 0,
        vignetteRadius: (j['vignetteRadius'] as num?)?.toDouble() ?? defaultVignetteRadius,
        subject: j['subject'] as String?,
        why: j['why'] as String?,
        focus: (j['focus'] as List?)?.cast<num>().map((e) => e.toDouble()).toList(),
      );
}
