import 'dart:math' as math;
import 'dart:typed_data';

import 'recipe.dart';

/// Deterministic selective-color renderer.
///
/// Same math as tools/develop/develop.py. The agent only chooses a [Recipe];
/// this turns it into pixels. Pure Dart so it runs in an isolate.

class Rgba {
  Rgba(this.width, this.height, this.pixels);
  final int width, height;
  final Uint8List pixels; // RGBA, 4 bytes per pixel
}

class Lab {
  Lab(this.width, this.height, this.l, this.a, this.b);
  final int width, height;
  final Float32List l, a, b;
}

class RenderResult {
  RenderResult(this.image, this.weight, this.keptShare);
  final Rgba image;
  final Float32List weight;

  /// Mean weight over the photo, 0..1.
  final double keptShare;
}

// ------------------------------------------------------------ color math

final Float32List _toLinear = () {
  final t = Float32List(256);
  for (var i = 0; i < 256; i++) {
    final c = i / 255;
    t[i] = c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
  }
  return t;
}();

double _cbrt(double x) => x <= 0 ? 0 : math.pow(x, 1 / 3).toDouble();

int _toSrgb8(double c) {
  if (c <= 0) return 0;
  if (c >= 1) return 255;
  final v = c <= 0.0031308 ? c * 12.92 : 1.055 * math.pow(c, 1 / 2.4) - 0.055;
  return (v * 255 + 0.5).toInt();
}

List<double> rgbToOklab(double r, double g, double b) {
  final l = _cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
  final m = _cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
  final s = _cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
  return [
    0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
    1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
    0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
  ];
}

/// Returns linear RGB.
List<double> oklabToLinear(double L, double a, double b) {
  final l_ = L + 0.3963377774 * a + 0.2158037573 * b;
  final m_ = L - 0.1055613458 * a - 0.0638541728 * b;
  final s_ = L - 0.0894841775 * a - 1.2914855480 * b;
  final l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_;
  return [
    4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
    -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
    -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s,
  ];
}

String oklabToHex(double L, double a, double b) {
  final c = oklabToLinear(L, a, b);
  return '#${c.map((v) => _toSrgb8(v).toRadixString(16).padLeft(2, '0')).join()}';
}

/// sRGB 0..255 of an OKLab color, for drawing swatches.
List<int> oklabToRgb8(double L, double a, double b) => oklabToLinear(L, a, b).map(_toSrgb8).toList();

KeptColor? keptColorFromHex(String hex) {
  final h = hex.replaceAll('#', '');
  if (h.length != 6) return null;
  final v = int.tryParse(h, radix: 16);
  if (v == null) return null;
  final lab = rgbToOklab(_toLinear[(v >> 16) & 255], _toLinear[(v >> 8) & 255], _toLinear[v & 255]);
  return KeptColor(l: lab[0], a: lab[1], b: lab[2]);
}

Lab toLab(Rgba img) {
  final n = img.width * img.height;
  final L = Float32List(n), A = Float32List(n), B = Float32List(n);
  final p = img.pixels;
  for (var i = 0; i < n; i++) {
    final o = i * 4;
    final lab = rgbToOklab(_toLinear[p[o]], _toLinear[p[o + 1]], _toLinear[p[o + 2]]);
    L[i] = lab[0];
    A[i] = lab[1];
    B[i] = lab[2];
  }
  return Lab(img.width, img.height, L, A, B);
}

// ------------------------------------------------------------ sampling

/// Median OKLab around a normalized point.
KeptColor sampleColor(Lab lab, double x, double y, {double radiusFrac = 0.008}) {
  final w = lab.width, h = lab.height;
  final cx = (x.clamp(0.0, 1.0) * (w - 1)).round();
  final cy = (y.clamp(0.0, 1.0) * (h - 1)).round();
  final r = math.max(2, (math.min(w, h) * radiusFrac).round());
  final ls = <double>[], as = <double>[], bs = <double>[];
  for (var yy = math.max(0, cy - r); yy <= math.min(h - 1, cy + r); yy++) {
    for (var xx = math.max(0, cx - r); xx <= math.min(w - 1, cx + r); xx++) {
      final i = yy * w + xx;
      ls.add(lab.l[i]);
      as.add(lab.a[i]);
      bs.add(lab.b[i]);
    }
  }
  double med(List<double> v) => (v..sort())[v.length ~/ 2];
  return KeptColor(l: med(ls), a: med(as), b: med(bs));
}

class HuePeak {
  HuePeak(this.from, this.to, this.share, this.area, this.meanChroma, this.meanL, this.center);
  final int from, to;
  final double share, area, meanChroma, meanL;

  /// Normalized centroid of the pixels in this bin.
  final List<double> center;
}

/// Chroma-weighted hue histogram, strongest bins first.
List<HuePeak> huePeaks(Lab lab, {int bins = 36, int top = 8}) {
  final hist = List<double>.filled(bins, 0), count = List<int>.filled(bins, 0);
  final sumC = List<double>.filled(bins, 0), sumL = List<double>.filled(bins, 0);
  final sx = List<double>.filled(bins, 0), sy = List<double>.filled(bins, 0);
  final n = lab.l.length;
  var total = 0.0;
  for (var i = 0; i < n; i++) {
    final a = lab.a[i], b = lab.b[i];
    final c = math.sqrt(a * a + b * b);
    if (c <= 0.04) continue;
    final hdeg = (math.atan2(b, a) * 180 / math.pi + 360) % 360;
    final k = (hdeg / (360 / bins)).floor() % bins;
    hist[k] += c;
    total += c;
    count[k]++;
    sumC[k] += c;
    sumL[k] += lab.l[i];
    sx[k] += (i % lab.width) / lab.width;
    sy[k] += (i ~/ lab.width) / lab.height;
  }
  final order = List.generate(bins, (i) => i)..sort((x, y) => hist[y].compareTo(hist[x]));
  final step = 360 ~/ bins;
  return [
    for (final k in order.take(top))
      if (count[k] > 0)
        HuePeak(k * step, (k + 1) * step, hist[k] / total, count[k] / n, sumC[k] / count[k], sumL[k] / count[k],
            [sx[k] / count[k], sy[k] / count[k]]),
  ];
}

// ------------------------------------------------------------ filters

/// Separable box blur with radius r, in place via a scratch buffer.
void _boxBlur(Float32List src, int w, int h, int r, Float32List tmp) {
  if (r < 1) return;
  final d = 2 * r + 1;
  for (var y = 0; y < h; y++) {
    final row = y * w;
    var acc = 0.0;
    for (var x = -r; x <= r; x++) {
      acc += src[row + x.clamp(0, w - 1)];
    }
    for (var x = 0; x < w; x++) {
      tmp[row + x] = acc / d;
      acc += src[row + (x + r + 1).clamp(0, w - 1)] - src[row + (x - r).clamp(0, w - 1)];
    }
  }
  for (var x = 0; x < w; x++) {
    var acc = 0.0;
    for (var y = -r; y <= r; y++) {
      acc += tmp[y.clamp(0, h - 1) * w + x];
    }
    for (var y = 0; y < h; y++) {
      src[y * w + x] = acc / d;
      acc += tmp[(y + r + 1).clamp(0, h - 1) * w + x] - tmp[(y - r).clamp(0, h - 1) * w + x];
    }
  }
}

Float32List _mean(Float32List src, int w, int h, int r, Float32List tmp) {
  final out = Float32List.fromList(src);
  _boxBlur(out, w, h, r, tmp);
  return out;
}

/// He et al. guided filter: smooths [src] while following edges in [guide].
Float32List guidedFilter(Float32List guide, Float32List src, int w, int h, int r, double eps) {
  final n = w * h;
  final tmp = Float32List(n);
  final gi = Float32List(n), gg = Float32List(n);
  for (var i = 0; i < n; i++) {
    gi[i] = guide[i] * src[i];
    gg[i] = guide[i] * guide[i];
  }
  final mI = _mean(guide, w, h, r, tmp);
  final mp = _mean(src, w, h, r, tmp);
  final mIp = _mean(gi, w, h, r, tmp);
  final mII = _mean(gg, w, h, r, tmp);
  final a = Float32List(n), b = Float32List(n);
  for (var i = 0; i < n; i++) {
    final cov = mIp[i] - mI[i] * mp[i];
    final v = mII[i] - mI[i] * mI[i];
    a[i] = cov / (v + eps);
    b[i] = mp[i] - a[i] * mI[i];
  }
  _boxBlur(a, w, h, r, tmp);
  _boxBlur(b, w, h, r, tmp);
  final out = Float32List(n);
  for (var i = 0; i < n; i++) {
    out[i] = (a[i] * guide[i] + b[i]).clamp(0.0, 1.0);
  }
  return out;
}

Float32List areaMask(int w, int h, Area? area) {
  final m = Float32List(w * h);
  if (area == null || area.isEmpty) {
    m.fillRange(0, m.length, 1);
    return m;
  }
  for (final poly in area.polygons) {
    if (poly.length < 3) continue;
    final xs = poly.map((p) => p[0] * w).toList(), ys = poly.map((p) => p[1] * h).toList();
    final minY = ys.reduce(math.min).floor().clamp(0, h - 1), maxY = ys.reduce(math.max).ceil().clamp(0, h - 1);
    for (var y = minY; y <= maxY; y++) {
      final py = y + 0.5;
      final cross = <double>[];
      for (var i = 0, j = poly.length - 1; i < poly.length; j = i++) {
        if ((ys[i] > py) != (ys[j] > py)) {
          cross.add(xs[i] + (py - ys[i]) / (ys[j] - ys[i]) * (xs[j] - xs[i]));
        }
      }
      cross.sort();
      for (var k = 0; k + 1 < cross.length; k += 2) {
        final x0 = cross[k].round().clamp(0, w), x1 = cross[k + 1].round().clamp(0, w);
        for (var x = x0; x < x1; x++) {
          m[y * w + x] = 1;
        }
      }
    }
  }
  for (final e in area.ellipses) {
    final cx = e[0] * w, cy = e[1] * h, rx = math.max(1.0, e[2] * w), ry = math.max(1.0, e[3] * h);
    final y0 = (cy - ry).floor().clamp(0, h - 1), y1 = (cy + ry).ceil().clamp(0, h - 1);
    final x0 = (cx - rx).floor().clamp(0, w - 1), x1 = (cx + rx).ceil().clamp(0, w - 1);
    for (var y = y0; y <= y1; y++) {
      for (var x = x0; x <= x1; x++) {
        final dx = (x + 0.5 - cx) / rx, dy = (y + 0.5 - cy) / ry;
        if (dx * dx + dy * dy <= 1) m[y * w + x] = 1;
      }
    }
  }
  final sigma = area.edge * math.min(w, h) / 2;
  final r = sigma.round();
  if (r >= 1) {
    final tmp = Float32List(w * h);
    for (var pass = 0; pass < 3; pass++) {
      _boxBlur(m, w, h, r, tmp);
    }
  }
  return m;
}

// ------------------------------------------------------------ render

double _smoothstep(double e0, double e1, double x) {
  final t = ((x - e0) / math.max(e1 - e0, 1e-9)).clamp(0.0, 1.0);
  return t * t * (3 - 2 * t);
}

Float32List keepWeight(Lab lab, List<KeptColor> colors) {
  final n = lab.l.length;
  final w = Float32List(n);
  if (colors.isEmpty) return w;
  final hues = colors.map((c) => c.hue).toList();
  for (var i = 0; i < n; i++) {
    final a = lab.a[i], b = lab.b[i], L = lab.l[i];
    final C = math.sqrt(a * a + b * b);
    final H = (math.atan2(b, a) * 180 / math.pi + 360) % 360;
    var best = 0.0;
    for (var k = 0; k < colors.length; k++) {
      final c = colors[k];
      final dh = ((H - hues[k] + 540) % 360 - 180).abs();
      final t = ((dh - c.width) / math.max(c.softness, 1e-6)).clamp(0.0, 1.0);
      final wh = 0.5 * (1 + math.cos(math.pi * t));
      if (wh <= 0) continue;
      final wc = _smoothstep(c.chromaMin * 0.5, c.chromaMin * 1.5, C);
      var wl = 1.0;
      final lg = c.lightness;
      if (lg != null) {
        wl = _smoothstep(lg[0] - 0.08, lg[0], L) * (1 - _smoothstep(lg[1], lg[1] + 0.08, L));
      }
      final v = wh * wc * wl;
      if (v > best) best = v;
    }
    w[i] = best;
  }
  return w;
}

double _tone(double L, double contrast) {
  if (contrast == 0) return L;
  final x = L.clamp(0.0, 1.0);
  // An S-curve around middle grey. Slope 1 + 2.4·contrast·cos(..) stays
  // positive over the whole range (|contrast| <= 0.4), so tones never invert.
  return (x + 2.4 * contrast * math.sin(2 * math.pi * (x - 0.5)) / (2 * math.pi)).clamp(0.0, 1.0);
}

RenderResult render(Rgba src, Recipe recipe, {Lab? lab}) {
  final w = src.width, h = src.height, n = w * h;
  lab ??= toLab(src);
  final raw = keepWeight(lab, recipe.colors);
  final mask = areaMask(w, h, recipe.area);
  for (var i = 0; i < n; i++) {
    raw[i] *= mask[i];
  }
  final r = math.max(2, (math.min(w, h) * 0.006).round());
  final weight = recipe.colors.isEmpty ? raw : guidedFilter(lab.l, raw, w, h, r, 2e-3);

  final out = Uint8List(n * 4);
  var sum = 0.0;
  for (var i = 0; i < n; i++) {
    final k = weight[i];
    sum += k;
    final rgb = oklabToLinear(_tone(lab.l[i], recipe.contrast), lab.a[i] * k, lab.b[i] * k);
    final o = i * 4;
    out[o] = _toSrgb8(rgb[0]);
    out[o + 1] = _toSrgb8(rgb[1]);
    out[o + 2] = _toSrgb8(rgb[2]);
    out[o + 3] = 255;
  }
  return RenderResult(Rgba(w, h, out), weight, sum / n);
}

/// Grayscale image of the weight map, for the agent's self-check.
Rgba weightImage(Float32List weight, int w, int h) {
  final out = Uint8List(w * h * 4);
  for (var i = 0; i < w * h; i++) {
    final v = (weight[i] * 255).round().clamp(0, 255);
    out[i * 4] = v;
    out[i * 4 + 1] = v;
    out[i * 4 + 2] = v;
    out[i * 4 + 3] = 255;
  }
  return Rgba(w, h, out);
}
