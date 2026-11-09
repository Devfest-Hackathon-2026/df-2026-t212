import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../core/recipe.dart';
import '../core/renderer.dart';

enum PreviewView { result, mask }

/// A long-lived isolate that holds the photo and its Lab planes, so a change
/// costs one render instead of a copy of the whole photo.
///
/// Requests are answered at full size, the newest first, as fast as the
/// worker turns them out. Only where a full render is too slow to follow a
/// finger does a drag show a small proxy, with the full size once the
/// person pauses. Old answers are dropped.
class PreviewWorker {
  PreviewWorker._(this._send, this._recv, this._isolate);

  final SendPort _send;
  final ReceivePort _recv;
  final Isolate _isolate;
  final _out = StreamController<ui.Image>.broadcast();

  int _id = 0;
  int _shown = -1;
  bool _busy = false;
  (Recipe, PreviewView, bool)? _next;
  Timer? _full;

  /// How long a full render takes here, smoothed; until known, assumed fast.
  double _fullMs = 0;

  /// Slower than this, a drag is followed at the proxy's size instead.
  static const _followMs = 120.0;

  Stream<ui.Image> get images => _out.stream;

  static Future<PreviewWorker> start(Rgba photo) async {
    final recv = ReceivePort();
    final iso = await Isolate.spawn(_main, (recv.sendPort, photo));
    final ready = Completer<PreviewWorker>();
    PreviewWorker? worker;
    recv.listen((m) {
      if (m is SendPort) {
        ready.complete(worker = PreviewWorker._(m, recv, iso));
      } else if (m is (int, bool, int, int, int, TransferableTypedData)) {
        worker?._got(m);
      }
    });
    return ready.future;
  }

  /// Ask for [r]: at full size as soon as the worker is free, or, where
  /// that is too slow to follow, the proxy now and the full size after
  /// [settle] without further requests.
  void request(Recipe r, {PreviewView view = PreviewView.result, Duration settle = const Duration(milliseconds: 180)}) {
    final copy = r.copy();
    final proxy = _fullMs > _followMs;
    _full?.cancel();
    if (_busy) {
      _next = (copy, view, proxy);
    } else {
      _ask(copy, view, proxy: proxy);
    }
    if (proxy) _full = Timer(settle, () => _queue(copy, view));
  }

  void _queue(Recipe r, PreviewView view) {
    if (_busy) {
      _next = (r, view, false);
    } else {
      _ask(r, view, proxy: false);
    }
  }

  void _ask(Recipe r, PreviewView view, {required bool proxy}) {
    final id = ++_id;
    _busy = true;
    _send.send((id, proxy, view.index, r));
  }

  Future<void> _got((int, bool, int, int, int, TransferableTypedData) m) async {
    final (id, proxy, w, h, ms, data) = m;
    if (!proxy) _fullMs = _fullMs == 0 ? ms.toDouble() : _fullMs * 0.7 + ms * 0.3;
    _busy = false;
    final next = _next;
    _next = null;
    if (next != null) _ask(next.$1, next.$2, proxy: next.$3);
    // Drop anything older than what is on screen. A proxy shows even while
    // the next one is queued: that is what makes a drag feel live.
    if (id < _shown) return;
    final bytes = data.materialize().asUint8List();
    final c = Completer<ui.Image>();
    ui.decodeImageFromPixels(bytes, w, h, ui.PixelFormat.rgba8888, c.complete);
    final im = await c.future;
    if (id < _shown) {
      im.dispose();
      return;
    }
    _shown = id;
    if (!_out.isClosed) _out.add(im);
  }

  void dispose() {
    _full?.cancel();
    _send.send(null);
    _recv.close();
    _isolate.kill(priority: Isolate.beforeNextEvent);
    _out.close();
  }

  // ------------------------------------------------------------ isolate side

  static void _main((SendPort, Rgba) init) {
    final (reply, full) = init;
    final fullLab = toLab(full);
    final small = _shrink(full, 3);
    final smallLab = toLab(small);
    final port = ReceivePort();
    reply.send(port.sendPort);
    port.listen((m) {
      if (m == null) {
        port.close();
        return;
      }
      final (id, proxy, view, r) = m as (int, bool, int, Recipe);
      final watch = Stopwatch()..start();
      final src = proxy ? small : full;
      final lab = proxy ? smallLab : fullLab;
      final res = render(src, r, lab: lab);
      final out = view == PreviewView.mask.index ? _maskImage(res, src) : res.image;
      reply.send((
        id,
        proxy,
        out.width,
        out.height,
        watch.elapsedMilliseconds,
        TransferableTypedData.fromList([out.pixels]),
      ));
    });
  }

  /// Box-filtered copy, [f] times smaller.
  static Rgba _shrink(Rgba p, int f) {
    final w = math.max(1, p.width ~/ f), h = math.max(1, p.height ~/ f);
    final out = Uint8List(w * h * 4);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        var r = 0, g = 0, b = 0;
        for (var dy = 0; dy < f; dy++) {
          for (var dx = 0; dx < f; dx++) {
            final i = ((y * f + dy) * p.width + x * f + dx) * 4;
            r += p.pixels[i];
            g += p.pixels[i + 1];
            b += p.pixels[i + 2];
          }
        }
        final o = (y * w + x) * 4, n = f * f;
        out[o] = r ~/ n;
        out[o + 1] = g ~/ n;
        out[o + 2] = b ~/ n;
        out[o + 3] = 255;
      }
    }
    return Rgba(w, h, out);
  }

  /// Where color is kept, lifted and in the photo's own color; the rest
  /// dimmed grey. Lifting makes dark kept colors (leaves in shade) readable.
  static Rgba _maskImage(RenderResult res, Rgba src) {
    final n = src.width * src.height;
    final out = Uint8List(n * 4);
    for (var i = 0; i < n; i++) {
      final k = res.weight[i];
      final o = i * 4;
      final r = src.pixels[o], g = src.pixels[o + 1], b = src.pixels[o + 2];
      final y = (r * 0.2126 + g * 0.7152 + b * 0.0722) * 0.2;
      out[o] = (y + (70 + r * 0.75 - y) * k).round().clamp(0, 255);
      out[o + 1] = (y + (70 + g * 0.75 - y) * k).round().clamp(0, 255);
      out[o + 2] = (y + (70 + b * 0.75 - y) * k).round().clamp(0, 255);
      out[o + 3] = 255;
    }
    return Rgba(src.width, src.height, out);
  }
}
