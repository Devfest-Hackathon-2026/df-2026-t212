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
/// One stroke of the area brush: a line of [points] with a round tip.
class Stroke {
  Stroke({required this.points, required this.radius, this.erase = false});

  /// [[x, y], ...] in 0..1 of the photo.
  List<List<double>> points;

  /// Half the line's thickness, as a fraction of the photo's short side.
  double radius;

  /// Takes the area away where it passes, instead of adding to it.
  bool erase;

  Stroke copy() => Stroke(points: points.map((q) => List.of(q)).toList(), radius: radius, erase: erase);

  Map<String, dynamic> toJson() => {'points': points, 'radius': radius, if (erase) 'erase': true};

  static Stroke? fromJson(Object? j) {
    if (j is! Map) return null;
    final pts = ((j['points'] as List?) ?? [])
        .whereType<List>()
        .where((q) => q.length >= 2 && q.every((e) => e is num))
        .map((q) => q.cast<num>().take(2).map((e) => e.toDouble()).toList())
        .toList();
    final r = (j['radius'] as num?)?.toDouble();
    if (pts.isEmpty || r == null || r <= 0) return null;
    return Stroke(points: pts, radius: r, erase: j['erase'] == true);
  }
}

class Area {
  static const defaultFeatherPixels = 10.0;
  static double defaultEdgeFor(num shortSide) => (defaultFeatherPixels / math.max(1, shortSide)).clamp(0.0, 1.0);
  Area({this.polygons = const [], this.ellipses = const [], this.strokes = const [], this.edge = 0.03, this.boundary = 0});

  /// Each polygon is a flat list of points: [[x, y], ...].
  List<List<List<double>>> polygons;

  /// Each ellipse is [cx, cy, rx, ry].
  List<List<double>> ellipses;

  /// Paint over the shapes, in the order it was laid down.
  List<Stroke> strokes;

  /// Outward fade from full opacity to zero, as a fraction of the short side.
  double edge;

  /// Offset of the full-opacity boundary from the drawn mask, in short-side
  /// fractions. Positive expands; negative contracts; zero preserves its inside.
  double boundary;

  bool get isEmpty => polygons.isEmpty && ellipses.isEmpty && strokes.isEmpty;

  /// Erasing before anything was kept starts from the whole photo.
  bool get startsWhole => polygons.isEmpty && ellipses.isEmpty && strokes.isNotEmpty && strokes.first.erase;

  Area copy() => Area(
        polygons: polygons.map((p) => p.map((q) => List.of(q)).toList()).toList(),
        ellipses: ellipses.map((e) => List.of(e)).toList(),
        strokes: strokes.map((s) => s.copy()).toList(),
        edge: edge,
        boundary: boundary,
      );

  Map<String, dynamic> toJson() => {
        'polygons': polygons,
        'ellipses': ellipses,
        if (strokes.isNotEmpty) 'strokes': strokes.map((s) => s.toJson()).toList(),
        'edge': edge,
        if (boundary != 0) 'boundary': boundary,
      };

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
        strokes: ((j['strokes'] as List?) ?? []).map(Stroke.fromJson).whereType<Stroke>().toList(),
        edge: (j['edge'] as num?)?.toDouble() ?? 0.03,
        boundary: ((j['boundary'] as num?)?.toDouble() ?? 0).clamp(-1.0, 1.0),
      );
}

/// A non-destructive edit. The original photo is never rewritten.
class Recipe {
  Recipe({
    List<KeptColor>? colors,
    List<KeptColor>? excludedColors,
    this.area,
    this.contrast = 0.1,
    this.ambience = defaultAmbience,
    this.vignette = 0,
    this.vignetteRadius = defaultVignetteRadius,
    this.subject,
    this.why,
    this.focus,
  })
      : colors = colors ?? [],
        excludedColors = excludedColors ?? [];

  List<KeptColor> colors;

  /// Unwanted hues subtracted from the kept range. Distinct kept samples
  /// protect their nearer hues; exclusion wins for the same hue.
  List<KeptColor> excludedColors;
  static const defaultExcludeWidth = 4.0;
  static const defaultExcludeSoftness = 4.0;
  Area? area;

  /// Tone of the black-and-white part.
  double contrast;

  /// How much of the light's color the black-and-white part keeps, 0-1.
  /// 0 is pure grey; higher keeps the warmth of a sunset or the blue of
  /// dusk as a faint tint, so the mono part still feels like the place.
  double ambience;
  static const defaultAmbience = 0.2;

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
        excludedColors: excludedColors.map((c) => c.copy()).toList(),
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
  String get signature {
    final data = toJson().toString();
    // Refresh cached exclusions after introducing relative hue separation.
    final hue = excludedColors.isEmpty ? '' : 'hue-separation-v2:';
    final mask = area == null || area!.isEmpty ? '' : 'outward-feather-v1:';
    return '$hue$mask$data'.hashCode.toRadixString(16);
  }

  Map<String, dynamic> toJson() => {
        'colors': colors.map((c) => c.toJson()).toList(),
        if (excludedColors.isNotEmpty) 'excludedColors': excludedColors.map((c) => c.toJson()).toList(),
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
        excludedColors: ((j['excludedColors'] as List?) ?? []).map((c) => KeptColor.fromJson(c as Map<String, dynamic>)).toList(),
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
