import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../core/recipe.dart';
import '../core/renderer.dart';

/// Decides a [Recipe] for one photo. The pixels are always made by the
/// deterministic renderer; the agent only chooses settings.
abstract class DevelopAgent {
  String get name;
  Future<Recipe> develop(Rgba photo, {void Function(String)? log, AgentRun? run});
}

/// One agent run that a person can watch and take over. Each tool call
/// publishes the recipe so far; [cancel] stops the run at once.
class AgentRun {
  final _cancel = Completer<void>();
  final _changes = StreamController<Recipe>.broadcast();

  Recipe recipe = Recipe();
  String status = 'Looking';

  bool get cancelled => _cancel.isCompleted;
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

/// The tools the agent works with. The human Edit screen changes the same
/// fields, so anything the agent does, a person can redo or undo.
class EditSession {
  EditSession(this.photo) : lab = toLab(photo);

  final Rgba photo;
  final Lab lab;
  final Recipe recipe = Recipe();
  int renders = 0;
  RenderResult? last;
  bool finished = false;

  /// Renders off the UI thread.
  Future<String> renderAsync() async {
    renders++;
    last = await _render(photo, recipe.copy(), lab);
    return rendered();
  }

  static Future<RenderResult> _render(Rgba p, Recipe r, Lab l) => Isolate.run(() => render(p, r, lab: l));

  String rendered() => 'rendered. kept color covers ${(last!.keptShare * 100).toStringAsFixed(1)}% of the photo. '
      'The result and its keep-weight map (white = color kept) follow.';

  String execute(String name, Map<String, dynamic> args) {
    double? d(String k) => (args[k] as num?)?.toDouble();
    int? i(String k) => (args[k] as num?)?.toInt();
    KeptColor? at(int? index) =>
        index != null && index >= 0 && index < recipe.colors.length ? recipe.colors[index] : null;

    switch (name) {
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
        final a = Area.fromJson(args);
        recipe.area = a.isEmpty ? null : a;
        return a.isEmpty ? 'area cleared' : 'ok';
      case 'set_mono_tone':
        recipe.contrast = (d('contrast') ?? 0.1).clamp(-0.3, 0.4);
        return 'ok';
      case 'render':
        renders++;
        last = render(photo, recipe, lab: lab);
        return rendered();
      case 'finish':
        recipe.subject = args['subject'] as String?;
        recipe.why = args['why'] as String?;
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
class LocalAgent implements DevelopAgent {
  @override
  String get name => 'on-device';

  @override
  Future<Recipe> develop(Rgba photo, {void Function(String)? log, AgentRun? run}) async {
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

/// JPEG with a 10% coordinate grid, so the model can point at things.
Future<Uint8List> gridJpeg(Rgba photo) => Isolate.run(() {
      final im = _toImage(photo);
      final yellow = img.ColorRgb8(255, 230, 0);
      for (var k = 1; k < 10; k++) {
        final x = (im.width * k / 10).round(), y = (im.height * k / 10).round();
        img.drawLine(im, x1: x, y1: 0, x2: x, y2: im.height - 1, color: yellow);
        img.drawLine(im, x1: 0, y1: y, x2: im.width - 1, y2: y, color: yellow);
        img.drawString(im, (k / 10).toStringAsFixed(1), font: img.arial14, x: x + 3, y: 2, color: yellow);
        img.drawString(im, (k / 10).toStringAsFixed(1), font: img.arial14, x: 3, y: y + 2, color: yellow);
      }
      return Uint8List.fromList(img.encodeJpg(im, quality: 80));
    });

Future<Uint8List> plainJpeg(Rgba photo) => Isolate.run(() => Uint8List.fromList(img.encodeJpg(_toImage(photo), quality: 80)));

img.Image _toImage(Rgba p) =>
    img.Image.fromBytes(width: p.width, height: p.height, bytes: p.pixels.buffer, numChannels: 4).convert(numChannels: 3);

String dataUrl(Uint8List jpeg) => 'data:image/jpeg;base64,${base64Encode(jpeg)}';
