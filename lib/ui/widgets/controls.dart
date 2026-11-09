import 'package:flutter/material.dart';

import '../theme.dart';

/// The empty color slot: a dashed outline, with a plus where a color can be
/// added.
class DashedSlot extends CustomPainter {
  DashedSlot({required this.plus, required this.strong});
  final bool plus, strong;

  @override
  void paint(Canvas canvas, Size s) {
    final p = Paint()
      ..color = strong ? Neutral.secondary : Neutral.hairline
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(Offset.zero & s, const Radius.circular(11)),
      );
    for (final m in path.computeMetrics()) {
      for (var d = 0.0; d < m.length; d += 7) {
        canvas.drawPath(m.extractPath(d, d + 3.5), p);
      }
    }
    if (plus) {
      final c = s.center(Offset.zero);
      final q = Paint()
        ..color = strong ? Neutral.primary : Neutral.tertiary
        ..strokeWidth = 1.4
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(c - const Offset(6, 0), c + const Offset(6, 0), q);
      canvas.drawLine(c - const Offset(0, 6), c + const Offset(0, 6), q);
    }
  }

  @override
  bool shouldRepaint(DashedSlot o) => o.plus != plus || o.strong != strong;
}

/// A labelled [ThinSlider], with its value shown in detail mode.
class SliderRow extends StatelessWidget {
  const SliderRow({
    super.key,
    this.height = 52,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.defaultValue,
    required this.onChanged,
    required this.onStart,
    required this.onEnd,
    this.advanced = false,
    this.detail,
  });
  final String label;
  final double value, min, max, defaultValue;
  final ValueChanged<double> onChanged;
  final VoidCallback onStart, onEnd;
  final bool advanced;
  final String? detail;
  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: Row(
        children: [
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: Txt.small.copyWith(color: Neutral.primary),
            ),
          ),
          Expanded(
            child: ThinSlider(
              value: value,
              min: min,
              max: max,
              defaultValue: defaultValue,
              onChanged: onChanged,
              onStart: onStart,
              onEnd: onEnd,
            ),
          ),
          if (advanced)
            SizedBox(
              width: 92,
              child: Text(
                detail == null
                    ? value.toStringAsFixed(1)
                    : '${value.round()}  $detail',
                textAlign: TextAlign.right,
                style: Txt.mono.copyWith(fontSize: 10),
              ),
            ),
        ],
      ),
    );
  }
}

/// A quiet slider: hairline track, small thumb, a tick when passing default.
class ThinSlider extends StatefulWidget {
  const ThinSlider({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    required this.defaultValue,
    required this.onChanged,
    required this.onStart,
    required this.onEnd,
  });
  final double value, min, max, defaultValue;
  final ValueChanged<double> onChanged;
  final VoidCallback onStart, onEnd;

  @override
  State<ThinSlider> createState() => _ThinSliderState();
}

class _ThinSliderState extends State<ThinSlider> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final w = box.maxWidth;
        double t(double v) =>
            ((v - widget.min) / (widget.max - widget.min)).clamp(0, 1);
        void set(double dx) {
          final v =
              widget.min + (dx / w).clamp(0.0, 1.0) * (widget.max - widget.min);
          final before = widget.value, d = widget.defaultValue;
          if ((before - d).sign != (v - d).sign) Haptics.tick();
          widget.onChanged(v);
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: (d) {
            widget.onStart();
            setState(() => _down = true);
          },
          onHorizontalDragUpdate: (d) => set(d.localPosition.dx),
          onHorizontalDragEnd: (_) {
            setState(() => _down = false);
            widget.onEnd();
          },
          onHorizontalDragCancel: () {
            setState(() => _down = false);
            widget.onEnd();
          },
          onTapUp: (d) {
            widget.onStart();
            set(d.localPosition.dx);
            Future.delayed(const Duration(milliseconds: 500), widget.onEnd);
          },
          child: CustomPaint(
            size: Size(w, 44),
            painter: _SliderPainter(
              t(widget.value),
              t(widget.defaultValue),
              _down,
            ),
          ),
        );
      },
    );
  }
}

class _SliderPainter extends CustomPainter {
  _SliderPainter(this.t, this.def, this.down);
  final double t, def;
  final bool down;

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height / 2;
    final track = Paint()
      ..color = Neutral.hairline
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(0, y), Offset(size.width, y), track);
    canvas.drawLine(
      Offset(0, y),
      Offset(size.width * t, y),
      track..color = Neutral.primary,
    );
    canvas.drawCircle(
      Offset(size.width * def, y),
      1.6,
      Paint()..color = Neutral.tertiary,
    );
    final r = down ? 9.0 : 7.0;
    canvas.drawCircle(
      Offset(size.width * t, y + 1),
      r + 0.5,
      Paint()..color = const Color(0x22000000),
    );
    canvas.drawCircle(
      Offset(size.width * t, y),
      r,
      Paint()..color = Neutral.surface,
    );
    canvas.drawCircle(
      Offset(size.width * t, y),
      r,
      Paint()
        ..color = Neutral.primary
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4,
    );
  }

  @override
  bool shouldRepaint(_SliderPainter o) => o.t != t || o.down != down;
}
