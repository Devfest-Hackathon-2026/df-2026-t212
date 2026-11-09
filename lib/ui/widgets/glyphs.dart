import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// After Hue's own icons. Each is drawn on a 24-unit grid with one line
/// weight, round ends and round corners, and placed by its visual mass
/// rather than its box, so a heart, a cross and three dots sit level.
enum G {
  heart,
  heartFill,
  close,
  more,
  share,
  trash,
  edit,
  options,
  timer,
  timerOff,
  grid,
  gridOff,
  flash,
  flashOff,
  flashAuto,
  flip,
  back,
  up,
  camera,
  plus,

  /// Close up: the ultra wide, focusing near.
  macro,
  macroOff,
}

/// Draws [g] centered on [at], for painters that place glyphs themselves.
void paintGlyph(Canvas canvas, G g, Offset at, double size, Color color, {double weight = 1.6}) {
  canvas.save();
  canvas.translate(at.dx - size / 2, at.dy - size / 2);
  _GlyphPainter(g, color, weight).paint(canvas, Size.square(size));
  canvas.restore();
}

class Glyph extends StatelessWidget {
  const Glyph(this.g, {super.key, this.size = 24, this.color = const Color(0xFF111111), this.weight = 1.6});
  final G g;
  final double size;
  final Color color;

  /// Line weight on screen, the same at any [size].
  final double weight;

  @override
  Widget build(BuildContext context) => SizedBox.square(
        dimension: size,
        child: CustomPaint(painter: _GlyphPainter(g, color, weight)),
      );
}

class _GlyphPainter extends CustomPainter {
  _GlyphPainter(this.g, this.color, this.weight);
  final G g;
  final Color color;
  final double weight;

  /// Nudges set by eye with the glyphs side by side, so a row reads level.
  static const _optical = <G, Offset>{
    G.heart: Offset(0, 0.35),
    G.heartFill: Offset(0, 0.35),
    G.share: Offset(0, -0.5),
    G.up: Offset(0, 0.6),
    G.camera: Offset(0, -0.3),
    G.flashAuto: Offset(0.4, -0.6),
    G.back: Offset(0.5, 0),
    G.timer: Offset(-0.25, 0),
  };

  @override
  void paint(Canvas canvas, Size size) {
    final k = size.width / 24;
    canvas.scale(k);
    final o = _optical[g];
    if (o != null) canvas.translate(o.dx, o.dy);
    final line = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = weight / k
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;
    final fill = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;

    void seg(double x1, double y1, double x2, double y2) => canvas.drawLine(Offset(x1, y1), Offset(x2, y2), line);

    // A slash through a glyph, with a clear gap either side so the two
    // never blur together.
    void slashed(void Function() draw) {
      canvas.saveLayer(Offset.zero & const Size(24, 24), Paint());
      draw();
      canvas.drawLine(
        const Offset(4.2, 4.2),
        const Offset(19.8, 19.8),
        Paint()
          ..blendMode = BlendMode.clear
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = line.strokeWidth + 1.2,
      );
      canvas.drawLine(const Offset(4.2, 4.2), const Offset(19.8, 19.8), line);
      canvas.restore();
    }

    Path heart() => Path()
      ..moveTo(12.0, 19.47)
      ..cubicTo(7.14, 16.14, 4.08, 13.17, 4.08, 9.48)
      ..cubicTo(4.08, 6.96, 5.97, 5.16, 8.22, 5.16)
      ..cubicTo(9.84, 5.16, 11.19, 6.06, 12.0, 7.5)
      ..cubicTo(12.81, 6.06, 14.16, 5.16, 15.78, 5.16)
      ..cubicTo(18.03, 5.16, 19.92, 6.96, 19.92, 9.48)
      ..cubicTo(19.92, 13.17, 16.86, 16.14, 12.0, 19.47)
      ..close();

    Path bolt(double dx) => Path()
      ..moveTo(13.4 + dx, 3)
      ..lineTo(6.4 + dx, 13.2)
      ..lineTo(11.4 + dx, 13.2)
      ..lineTo(10.4 + dx, 21)
      ..lineTo(17.4 + dx, 10.8)
      ..lineTo(12.4 + dx, 10.8)
      ..close();

    // The thirds alone, without a frame: the view is the frame.
    void gridShape() {
      for (final v in [9.2, 14.8]) {
        seg(v, 3.8, v, 20.2);
        seg(3.8, v, 20.2, v);
      }
    }

    void timerShape() {
      canvas.drawCircle(const Offset(12, 13.4), 7.2, line);
      seg(12, 13.4, 12, 9.6);
      seg(10, 3.4, 14, 3.4);
      seg(17.6, 6.9, 18.7, 5.8);
    }

    // A tulip, as close-up focus is drawn everywhere.
    void tulip() {
      canvas.drawPath(
        Path()
          ..moveTo(12, 13.2)
          ..cubicTo(8.4, 13.2, 6.9, 10.4, 7.1, 5.4)
          ..lineTo(9.7, 7.3)
          ..lineTo(12, 4.2)
          ..lineTo(14.3, 7.3)
          ..lineTo(16.9, 5.4)
          ..cubicTo(17.1, 10.4, 15.6, 13.2, 12, 13.2)
          ..close(),
        line,
      );
      seg(12, 13.2, 12, 20.4);
      for (final d in [-1.0, 1.0]) {
        canvas.drawPath(
          Path()
            ..moveTo(12, 20.4)
            ..cubicTo(12 + d * -2.6, 20.4, 12 + d * -5.6, 19, 12 + d * -6.4, 15.6)
            ..cubicTo(12 + d * -3.4, 15.8, 12 + d * -1.2, 17.4, 12, 20.4),
          line,
        );
      }
    }

    switch (g) {
      case G.macro:
        tulip();
      case G.macroOff:
        slashed(tulip);
      case G.heart:
        canvas.drawPath(heart(), line);
      case G.heartFill:
        canvas.drawPath(heart(), fill);
        canvas.drawPath(heart(), line);
      case G.close:
        seg(5.6, 5.6, 18.4, 18.4);
        seg(18.4, 5.6, 5.6, 18.4);
      case G.more:
        for (final x in [5.0, 12.0, 19.0]) {
          canvas.drawCircle(Offset(x, 12), 2.05, fill);
        }
      case G.share:
        seg(12, 3.4, 12, 14.4);
        canvas.drawPath(
          Path()
            ..moveTo(8.3, 7.1)
            ..lineTo(12, 3.4)
            ..lineTo(15.7, 7.1),
          line,
        );
        canvas.drawPath(
          Path()
            ..moveTo(8.6, 10)
            ..lineTo(7.2, 10)
            ..arcToPoint(const Offset(5.2, 12), radius: const Radius.circular(2), clockwise: false)
            ..lineTo(5.2, 18.9)
            ..arcToPoint(const Offset(7.2, 20.9), radius: const Radius.circular(2), clockwise: false)
            ..lineTo(16.8, 20.9)
            ..arcToPoint(const Offset(18.8, 18.9), radius: const Radius.circular(2), clockwise: false)
            ..lineTo(18.8, 12)
            ..arcToPoint(const Offset(16.8, 10), radius: const Radius.circular(2), clockwise: false)
            ..lineTo(15.4, 10),
          line,
        );
      case G.trash:
        seg(4.2, 6.6, 19.8, 6.6);
        canvas.drawPath(
          Path()
            ..moveTo(9.4, 6.6)
            ..lineTo(9.4, 4.9)
            ..arcToPoint(const Offset(10.7, 3.6), radius: const Radius.circular(1.3))
            ..lineTo(13.3, 3.6)
            ..arcToPoint(const Offset(14.6, 4.9), radius: const Radius.circular(1.3))
            ..lineTo(14.6, 6.6),
          line,
        );
        canvas.drawPath(
          Path()
            ..moveTo(6.1, 6.6)
            ..lineTo(7, 18.9)
            ..arcToPoint(const Offset(9, 20.8), radius: const Radius.circular(2), clockwise: false)
            ..lineTo(15, 20.8)
            ..arcToPoint(const Offset(17, 18.9), radius: const Radius.circular(2), clockwise: false)
            ..lineTo(17.9, 6.6),
          line,
        );
        seg(10.3, 10.4, 10.3, 16.8);
        seg(13.7, 10.4, 13.7, 16.8);
      case G.edit:
        // Three upright sliders, knobs at different heights.
        for (final (x, y) in [(5.6, 14.6), (12.0, 8.8), (18.4, 13.2)]) {
          seg(x, 4, x, y - 2.1);
          canvas.drawCircle(Offset(x, y), 2.1, line);
          seg(x, y + 2.1, x, 20);
        }
      case G.options:
        for (final (y, x) in [(8.4, 8.8), (15.6, 15.2)]) {
          seg(4, y, x - 2.3, y);
          canvas.drawCircle(Offset(x, y), 2.3, line);
          seg(x + 2.3, y, 20, y);
        }
      case G.timer:
        timerShape();
      case G.timerOff:
        slashed(timerShape);
      case G.grid:
        gridShape();
      case G.gridOff:
        slashed(gridShape);
      case G.flash:
        canvas.drawPath(bolt(0), line);
      case G.flashOff:
        slashed(() => canvas.drawPath(bolt(0), line));
      case G.flashAuto:
        canvas.drawPath(bolt(-2.4), line);
        canvas.drawPath(
          Path()
            ..moveTo(15.9, 20.6)
            ..lineTo(18.2, 14.6)
            ..lineTo(20.5, 20.6),
          line,
        );
        seg(16.8, 18.6, 19.6, 18.6);
      case G.flip:
        // Two arcs chasing each other round.
        const c = Offset(12, 12);
        const r = 7.4;
        for (final start in [math.pi * 1.1, math.pi * 0.1]) {
          const sweep = math.pi * 0.68;
          canvas.drawArc(Rect.fromCircle(center: c, radius: r), start, sweep, false, line);
          final a = start + sweep;
          final p = c + Offset(math.cos(a), math.sin(a)) * r;
          final t = Offset(-math.sin(a), math.cos(a));
          Offset turn(Offset v, double th) =>
              Offset(v.dx * math.cos(th) - v.dy * math.sin(th), v.dx * math.sin(th) + v.dy * math.cos(th));
          canvas.drawPath(
            Path()
              ..moveTo(p.dx - turn(t, 0.8).dx * 3.8, p.dy - turn(t, 0.8).dy * 3.8)
              ..lineTo(p.dx, p.dy)
              ..lineTo(p.dx - turn(t, -0.8).dx * 3.8, p.dy - turn(t, -0.8).dy * 3.8),
            line,
          );
        }
      case G.back:
        canvas.drawPath(
          Path()
            ..moveTo(15, 4.6)
            ..lineTo(7.6, 12)
            ..lineTo(15, 19.4),
          line,
        );
      case G.up:
        seg(12, 19, 12, 5.4);
        canvas.drawPath(
          Path()
            ..moveTo(6.6, 10.8)
            ..lineTo(12, 5.4)
            ..lineTo(17.4, 10.8),
          line,
        );
      case G.camera:
        canvas.drawPath(
          Path()
            ..moveTo(4.2, 7.4)
            ..lineTo(7.9, 7.4)
            ..lineTo(9.5, 4.8)
            ..lineTo(14.5, 4.8)
            ..lineTo(16.1, 7.4)
            ..lineTo(19.8, 7.4)
            ..arcToPoint(const Offset(21.8, 9.4), radius: const Radius.circular(2))
            ..lineTo(21.8, 18.2)
            ..arcToPoint(const Offset(19.8, 20.2), radius: const Radius.circular(2))
            ..lineTo(4.2, 20.2)
            ..arcToPoint(const Offset(2.2, 18.2), radius: const Radius.circular(2))
            ..lineTo(2.2, 9.4)
            ..arcToPoint(const Offset(4.2, 7.4), radius: const Radius.circular(2))
            ..close(),
          line,
        );
        canvas.drawCircle(const Offset(12, 13.8), 3.9, line);
      case G.plus:
        seg(12, 3.5, 12, 20.5);
        seg(3.5, 12, 20.5, 12);
    }
  }

  @override
  bool shouldRepaint(_GlyphPainter o) => o.g != g || o.color != color || o.weight != weight;
}
