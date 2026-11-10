import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../core/recipe.dart';
import '../core/crop.dart';
import '../core/renderer.dart';

/// Decides a [Recipe] for one photo. The pixels are always made by the
/// deterministic renderer; the agent only chooses settings.
abstract class DevelopAgent {
  String get name;
  Future<Recipe> develop(Rgba photo, {void Function(String)? log, AgentRun? run, ({int width, int height})? originalSize});

  /// Cheap look before developing: is there a subject whose colors are
  /// worth keeping? Photos that are not wait for a person.
  Future<Verdict> judge(Rgba photo, {AgentRun? run}) async => const Verdict(true);

  /// Change [current] the way the person asks, and nothing else.
  Future<Recipe> revise(Rgba photo, Recipe current, Revision request, {void Function(String)? log, AgentRun? run, ({int width, int height})? originalSize}) =>
      Future.error(AgentError('Ask is not configured. Connect the Google Cloud agent to use it.'));
}

class AgentError implements Exception {
  AgentError(this.message);
  final String message;
  @override
  String toString() => message;
}

enum MarkIntent { keep, remove, picked }

/// A point the person marked on the photo. It stands for the object there,
/// not the pixel.
class Mark {
  const Mark(this.x, this.y, this.intent, {this.color});
  final double x, y;
  final MarkIntent intent;

  /// For [MarkIntent.picked]: the color the person picked there.
  final KeptColor? color;

  /// Whether a keep weight [w] at the mark does what the person asked.
  bool met(double w) => intent == MarkIntent.remove ? w <= 0.15 : w >= 0.6;
}

/// What the person asks the agent to change: words, marks, or both.
class Revision {
  const Revision({this.text, this.marks = const []});
  final String? text;
  final List<Mark> marks;
}

/// Whether a photo goes to the agent, and why not.
class Verdict {
  const Verdict(this.develop, {this.subject, this.reason});
  final bool develop;
  final String? subject;
  final String? reason;
}

/// What a judge model is told, shared by Apple's on-device model and the cloud one.
const judgeInstructions = '''
You screen photos for After Hue. A photo is developed by turning everything black and white except the colors of its subject.
Say yes when there is a clear subject whose own colors would stand out against a black and white rest: a flower, food, a painted wall, a sign, clothing, a car, a lit window at night, autumn leaves.
Say no for screenshots, documents, receipts, whiteboards, blurry or accidental shots, and photos where color is everywhere at once with no subject, or nowhere.
Answer in plain English. subject is 2-5 words. reason is under 8 words, written for the photographer.
''';

/// On-device screen, free: photos with almost no color, or color only as a
/// faint cast over everything, are not worth a model call.
Future<Verdict> screenOnDevice(Rgba photo) => Isolate.run(() => _screen(photo));

Verdict _screen(Rgba photo) {
  final lab = toLab(photo);
  final n = lab.l.length;
  var colored = 0;
  for (var i = 0; i < n; i++) {
    final a = lab.a[i], b = lab.b[i];
    if (a * a + b * b > 0.06 * 0.06) colored++;
  }
  final share = colored / n;
  if (share < 0.015) return const Verdict(false, reason: 'Almost no color');
  final peaks = huePeaks(lab, top: 3);
  if (peaks.isEmpty || peaks.first.meanChroma < 0.055) return const Verdict(false, reason: 'Color too faint');
  return const Verdict(true);
}

/// One agent run that a person can watch and take over. Each tool call
/// publishes the recipe so far; [cancel] stops the run at once.
class AgentRun {
  final _cancel = Completer<void>();
  final _changes = StreamController<Recipe>.broadcast();

  Recipe recipe = Recipe();
  String status = 'Looking';

  bool get cancelled => _cancel.isCompleted;
  Future<void> get whenCancelled => _cancel.future;
  Stream<Recipe> get changes => _changes.stream;

  void cancel() {
    if (!_cancel.isCompleted) _cancel.complete();
    close();
  }

  void emit(Recipe r, String s) {
    recipe = r.copy();
    status = s;
    if (!_changes.isClosed) _changes.add(recipe);
  }

  void close() {
    if (!_changes.isClosed) _changes.close();
  }

  /// For a revision: the settled recipe, a one-line note on what changed,
  /// or why it failed.
  Recipe? result;
  String? note;
  String? requestText;
  Revision? revision;
  String? error;

  /// [f], unless the run is cancelled first.
  Future<T> guard<T>(Future<T> f) {
    if (cancelled) throw AgentCancelled();
    return Future.any([f, _cancel.future.then<T>((_) => throw AgentCancelled())]);
  }
}

class AgentCancelled implements Exception {
  @override
  String toString() => 'cancelled';
}

/// Optional platform capability. CLI tools retain the same deterministic core.
typedef SubjectExtractor = Future<List<List<List<double>>>?> Function(Rgba photo, double x, double y);

/// The tools the agent works with. The human Edit screen changes the same
/// fields, so anything the agent does, a person can redo or undo.
class EditSession {
  EditSession(this.photo, {Recipe? start, this.marks = const [], this.originalSize})
      : lab = toLab(photo),
        recipe = start?.copy() ?? Recipe();

  final Rgba photo;
  SubjectExtractor? subjectExtractor;
  final ({int width, int height})? originalSize;
  int get originalShortSide => math.max(1, math.min(originalSize?.width ?? photo.width, originalSize?.height ?? photo.height));
  String get sizeDescription => 'Preview ${photo.width}x${photo.height}; original photo '
      '${originalSize?.width ?? photo.width}x${originalSize?.height ?? photo.height}. '
      'Boundary and Feather pixel values refer to the original photo, not the preview.';
  final Lab lab;
  final Recipe recipe;
  final List<Mark> marks;
  int renders = 0;
  RenderResult? last;
  bool finished = false;

  /// For a revision: what the agent says it changed.
  String? change;

  /// Renders off the UI thread.
  Future<String> renderAsync({bool count = true}) async {
    if (count) renders++;
    last = await _render(photo, recipe.copy(), lab);
    return rendered();
  }

  static Future<RenderResult> _render(Rgba p, Recipe r, Lab l) => Isolate.run(() => render(p, r, lab: l));

  String rendered() {
    final s = 'rendered. kept color covers ${(last!.keptShare * 100).toStringAsFixed(1)}% of the photo. '
        'The result and its keep-weight map (white = color kept) follow.';
    return marks.isEmpty ? s : '$s\nmarks: ${markReport()}';
  }

  /// Each mark's keep weight and whether it does what was asked:
  /// "#1 keep 0.92 ok, #2 remove 0.41 NOT YET".
  String markReport() => [
        for (var k = 0; k < marks.length; k++)
          () {
            final m = marks[k], w = weightAt(m.x, m.y);
            return '#${k + 1} ${m.intent.name} ${w.toStringAsFixed(2)} ${m.met(w) ? 'ok' : 'NOT YET'}';
          }(),
      ].join(', ');

  bool get marksMet => last != null && marks.every((m) => m.met(weightAt(m.x, m.y)));

  /// Mean keep weight in a small patch around a normalized point.
  double weightAt(double x, double y) {
    final r = last;
    if (r == null) return 0;
    final w = photo.width, h = photo.height;
    final rad = math.max(2, (math.min(w, h) * 0.012).round());
    final cx = (x * w).round().clamp(0, w - 1), cy = (y * h).round().clamp(0, h - 1);
    var sum = 0.0, n = 0;
    for (var yy = math.max(0, cy - rad); yy <= math.min(h - 1, cy + rad); yy++) {
      for (var xx = math.max(0, cx - rad); xx <= math.min(w - 1, cx + rad); xx++) {
        sum += r.weight[yy * w + xx];
        n++;
      }
    }
    return n == 0 ? 0 : sum / n;
  }

  /// Uses exactly the native object extraction called by a human Area tap.
  Future<String> selectSubject(Map<String, dynamic> args) async {
    final x = (args['x'] as num?)?.toDouble(), y = (args['y'] as num?)?.toDouble();
    final mode = args['mode'] as String? ?? 'replace';
    if (x == null || y == null || !x.isFinite || !y.isFinite || x < 0 || x > 1 || y < 0 || y > 1) {
      return 'error: x and y must be normalized photo coordinates from 0 to 1.';
    }
    if (mode != 'replace' && mode != 'add') return 'error: mode must be replace or add.';
    final polygons = await subjectExtractor?.call(photo, x, y);
    if (polygons == null) return 'error: on-device object extraction is unavailable. Area was not changed. Use set_area if needed.';
    if (polygons.isEmpty) return 'error: no object found at that point. Area was not changed. Try a point inside the subject or use set_area.';
    final area = recipe.area?.copy() ?? Area(edge: Area.defaultEdgeFor(originalShortSide));
    if (mode == 'replace') { area.polygons = []; area.ellipses = []; area.strokes = []; }
    area.polygons = [...area.polygons, ...polygons];
    recipe.area = area;
    return 'ok; extracted ${polygons.length} object contours using the on-device Area tool. Boundary and Feather were preserved. Render to inspect; adjust_area can refine the edges.';
  }

  String execute(String name, Map<String, dynamic> args) {
    double? d(String k) => (args[k] as num?)?.toDouble();
    int? i(String k) => (args[k] as num?)?.toInt();
    KeptColor? at(int? index) =>
        index != null && index >= 0 && index < recipe.colors.length ? recipe.colors[index] : null;

    KeptColor? excludedAt(int? index) => index != null && index >= 0 && index < recipe.excludedColors.length
        ? recipe.excludedColors[index] : null;
    KeptColor? pickedColor() {
      if (args['hex'] is String) {
        final color = keptColorFromHex(args['hex'] as String);
        if (color != null) return color;
      }
      final x = d('x'), y = d('y');
      return x == null || y == null ? null : sampleColor(lab, x.clamp(0, 1), y.clamp(0, 1));
    }

    switch (name) {
      case 'exclude_color':
        if (recipe.excludedColors.length >= Recipe.maxColors) return 'error: already ${Recipe.maxColors} exclusions';
        final c = pickedColor();
        if (c == null) return 'error: give x,y or hex';
        c
          ..width = (d('width') ?? Recipe.defaultExcludeWidth).clamp(0, 60)
          ..softness = (d('softness') ?? Recipe.defaultExcludeSoftness).clamp(0, 60);
        recipe.excludedColors.add(c);
        return 'excluded color ${recipe.excludedColors.length - 1}: ${oklabToHex(c.l, c.a, c.b)}';
      case 'set_excluded_color':
        final old = excludedAt(i('index'));
        if (old == null) return 'error: no such excluded color';
        if (args.containsKey('hex') || args.containsKey('x') || args.containsKey('y')) {
          final c = pickedColor();
          if (c == null) return 'error: give x,y or hex';
          old..l = c.l..a = c.a..b = c.b..references = c.references;
        }
        if (d('width') case final width?) old.width = width.clamp(0, 60);
        if (d('softness') case final softness?) old.softness = softness.clamp(0, 60);
        return 'ok';
      case 'remove_excluded_color':
        final c = excludedAt(i('index'));
        if (c == null) return 'error: no such excluded color';
        recipe.excludedColors.remove(c);
        return 'ok';
      case 'probe':
        final pts = (args['points'] as List? ?? []).cast<List>();
        return pts.map((p) {
          final x = (p[0] as num).toDouble(), y = (p[1] as num).toDouble();
          final c = sampleColor(lab, x, y);
          return '${x.toStringAsFixed(2)},${y.toStringAsFixed(2)}  ${oklabToHex(c.l, c.a, c.b)}  '
              'L=${c.l.toStringAsFixed(2)} C=${c.chroma.toStringAsFixed(3)} H=${c.hue.round()}';
        }).join('\n');
      case 'hue_histogram':
        return huePeaks(lab).map((p) {
          return 'H ${p.from}-${p.to}  share ${(p.share * 100).toStringAsFixed(1)}%  '
              'area ${(p.area * 100).toStringAsFixed(1)}%  meanC ${p.meanChroma.toStringAsFixed(3)}  '
              'meanL ${p.meanL.toStringAsFixed(2)}  centroid ${p.center.map((v) => v.toStringAsFixed(2)).join(',')}';
        }).join('\n');
      case 'add_color':
        if (recipe.colors.length >= Recipe.maxColors) return 'error: already ${Recipe.maxColors} colors';
        KeptColor? c;
        if (args['hex'] is String) c = keptColorFromHex(args['hex'] as String);
        if (c == null && args['x'] != null) c = sampleColor(lab, d('x')!, d('y')!);
        if (c == null) return 'error: give x,y or hex';
        c
          ..width = d('width') ?? 14
          ..softness = d('softness') ?? 16
          ..chromaMin = d('chroma_min') ?? 0.03;
        c.lightness = _range(args['lightness']);
        recipe.colors.add(c);
        return 'color ${recipe.colors.length - 1}: ${oklabToHex(c.l, c.a, c.b)} '
            'L=${c.l.toStringAsFixed(2)} C=${c.chroma.toStringAsFixed(3)} H=${c.hue.round()}';
      case 'remove_color':
        final c = at(i('index'));
        if (c == null) return 'error: no such color';
        recipe.colors.remove(c);
        return 'removed';
      case 'set_width':
        final c = at(i('index'));
        if (c == null) return 'error: no such color';
        c.width = d('value')!.clamp(0, 90);
        return 'ok';
      case 'set_softness':
        final c = at(i('index'));
        if (c == null) return 'error: no such color';
        c.softness = d('value')!.clamp(0, 90);
        return 'ok';
      case 'set_gate':
        final c = at(i('index'));
        if (c == null) return 'error: no such color';
        if (args['chroma_min'] != null) c.chromaMin = d('chroma_min')!;
        if (args.containsKey('lightness')) {
          c.lightness = _range(args['lightness']);
        }
        return 'ok';
      case 'set_area':
        final a = Area.fromJson({...args, 'edge': args['edge'] ?? recipe.area?.edge ?? Area.defaultEdgeFor(originalShortSide),
          'boundary': args['boundary'] ?? recipe.area?.boundary ?? 0});
        recipe.area = a.isEmpty ? null : a;
        return a.isEmpty ? 'area cleared' : 'ok';
      case 'adjust_area':
        if ((d('boundary') != null && d('boundary_px') != null) ||
            (d('edge') != null && d('feather_px') != null)) {
          return 'error: use either fractional or pixel units for each adjustment';
        }
        final boundary = d('boundary') ?? (d('boundary_px') == null ? null : d('boundary_px')! / originalShortSide);
        final edge = d('edge') ?? (d('feather_px') == null ? null : d('feather_px')! / originalShortSide);
        if ((boundary == null && edge == null) ||
            (boundary != null && (!boundary.isFinite || boundary.abs() > 1)) ||
            (edge != null && (!edge.isFinite || edge < 0 || edge > 1))) {
          return 'error: boundary must be -1..1 and edge 0..1 (or equivalent original-photo pixels); give at least one';
        }
        final area = recipe.area ??= Area(edge: Area.defaultEdgeFor(originalShortSide));
        if (boundary != null) area.boundary = boundary;
        if (edge != null) area.edge = edge;
        return 'ok; Boundary ${(area.boundary * originalShortSide).toStringAsFixed(1)} px; '
            'Feather ${(area.edge * originalShortSide).toStringAsFixed(1)} px (original photo)';
      case 'set_crop':
        try {
          recipe.crop = args['reset'] == true ? null : PhotoCrop.fromJson({...?recipe.crop?.toJson(), ...args});
          return 'ok; selections stay in original source coordinates';
        } on FormatException catch (e) { return 'error: ${e.message}'; }
      case 'set_saturation':
        final value = d('value');
        if (value == null || !value.isFinite || value < 0 || value > 2) return 'error: value must be 0..2; 1 preserves source saturation';
        recipe.saturation = value;
        return 'ok';
      case 'set_mono_tone':
        if (args['contrast'] != null) recipe.contrast = d('contrast')!.clamp(-0.3, 0.4);
        if (args['atmosphere'] != null) recipe.ambience = d('atmosphere')!.clamp(0.0, 1.0);
        if (args['vignette'] != null) recipe.vignette = d('vignette')!.clamp(0.0, 1.0);
        if (args['vignette_radius'] != null) recipe.vignetteRadius = d('vignette_radius')!.clamp(0.3, 1.3);
        return 'ok';
      case 'render':
        renders++;
        last = render(photo, recipe, lab: lab);
        return rendered();
      case 'finish':
        recipe.subject = args['subject'] as String? ?? recipe.subject;
        recipe.why = args['why'] as String? ?? recipe.why;
        change = args['change'] as String?;
        if (args['focus'] is List) {
          recipe.focus = (args['focus'] as List).cast<num>().map((e) => e.toDouble()).toList();
        }
        finished = true;
        return 'done';
    }
    return 'error: unknown tool $name';
  }
}

/// A [low, high] pair, or null for anything malformed.
List<double>? _range(Object? v) {
  if (v is! List || v.length < 2 || v.take(2).any((e) => e is! num)) return null;
  final lo = (v[0] as num).toDouble(), hi = (v[1] as num).toDouble();
  return [math.min(lo, hi), math.max(lo, hi)];
}

// ------------------------------------------------------------ on-device fallback

/// Used when no model is configured. Picks the strongest color near the center.
class LocalAgent extends DevelopAgent {
  @override
  String get name => 'on-device';

  @override
  Future<Recipe> develop(Rgba photo, {void Function(String)? log, AgentRun? run, ({int width, int height})? originalSize}) async {
    final r = await (run?.guard(_pickAsync(photo)) ?? _pickAsync(photo));
    run?.emit(r, 'finish');
    return r;
  }

  static Future<Recipe> _pickAsync(Rgba photo) => Isolate.run(() => _pick(photo));

  static Recipe _pick(Rgba photo) {
    final lab = toLab(photo);
    final peaks = huePeaks(lab, top: 12);
    if (peaks.isEmpty) return Recipe(subject: 'no color', why: 'The photo has almost no color.');
    double score(HuePeak p) {
      final dx = p.center[0] - 0.5, dy = p.center[1] - 0.5;
      final central = 1 - math.min(1, math.sqrt(dx * dx + dy * dy) * 1.4);
      return p.share * (0.5 + central) * (0.6 + p.meanChroma * 4);
    }

    peaks.sort((a, b) => score(b).compareTo(score(a)));
    KeptColor fromPeak(HuePeak p) {
      final h = (p.from + p.to) / 2 * math.pi / 180;
      return KeptColor(l: p.meanL, a: p.meanChroma * math.cos(h), b: p.meanChroma * math.sin(h), width: 12, softness: 14);
    }

    final first = peaks.first;
    final colors = [fromPeak(first)];
    for (final p in peaks.skip(1)) {
      final dh = ((p.from - first.from + 540) % 360 - 180).abs();
      if (dh > 60 && score(p) > score(first) * 0.6) {
        colors.add(fromPeak(p));
        break;
      }
    }
    return Recipe(
      colors: colors,
      focus: first.center,
      subject: null,
      why: 'Picked on this device: the strongest color near the center of the photo.',
    );
  }
}

// ------------------------------------------------------------ image helpers for models

/// JPEG with a 10% coordinate grid, so the model can point at things, and
/// the person's [marks] as numbered rings: green keep, red remove, cyan picked.
Future<Uint8List> gridJpeg(Rgba photo, {List<Mark> marks = const []}) => Isolate.run(() {
      final im = _toImage(photo);
      final yellow = img.ColorRgb8(255, 230, 0);
      for (var k = 1; k < 10; k++) {
        final x = (im.width * k / 10).round(), y = (im.height * k / 10).round();
        img.drawLine(im, x1: x, y1: 0, x2: x, y2: im.height - 1, color: yellow);
        img.drawLine(im, x1: 0, y1: y, x2: im.width - 1, y2: y, color: yellow);
        img.drawString(im, (k / 10).toStringAsFixed(1), font: img.arial14, x: x + 3, y: 2, color: yellow);
        img.drawString(im, (k / 10).toStringAsFixed(1), font: img.arial14, x: 3, y: y + 2, color: yellow);
      }
      final r = math.max(8, (math.min(im.width, im.height) * 0.025).round());
      final black = img.ColorRgb8(0, 0, 0);
      for (var k = 0; k < marks.length; k++) {
        final m = marks[k];
        final c = switch (m.intent) {
          MarkIntent.keep => img.ColorRgb8(0, 230, 90),
          MarkIntent.remove => img.ColorRgb8(255, 50, 50),
          MarkIntent.picked => img.ColorRgb8(0, 210, 255),
        };
        final x = (m.x * im.width).round(), y = (m.y * im.height).round();
        img.drawCircle(im, x: x, y: y, radius: r + 2, color: black);
        for (var t = -1; t <= 1; t++) {
          img.drawCircle(im, x: x, y: y, radius: r + t, color: c);
        }
        img.fillCircle(im, x: x, y: y, radius: 2, color: c);
        img.drawString(im, '#${k + 1}', font: img.arial24, x: x + r + 4, y: y - 12, color: c);
      }
      return Uint8List.fromList(img.encodeJpg(im, quality: 80));
    });

Future<Uint8List> plainJpeg(Rgba photo) => Isolate.run(() => Uint8List.fromList(img.encodeJpg(_toImage(photo), quality: 80)));

img.Image _toImage(Rgba p) =>
    img.Image.fromBytes(width: p.width, height: p.height, bytes: p.pixels.buffer, numChannels: 4).convert(numChannels: 3);

String dataUrl(Uint8List jpeg) => 'data:image/jpeg;base64,${base64Encode(jpeg)}';
