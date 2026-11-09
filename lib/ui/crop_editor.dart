import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../core/crop.dart';
import 'theme.dart';
import 'widgets/common.dart';
import 'widgets/controls.dart';

/// Transform the complete source widget, including hit testing and overlays.
/// Thus picking, brushing and agent marks all retain original-photo coordinates.
class CroppedPhoto extends StatelessWidget {
  const CroppedPhoto({super.key, required this.crop, required this.sourceSize, required this.width, required this.builder});
  final PhotoCrop crop;
  final Size sourceSize;
  final double width;
  final Widget Function(Size size) builder;
  static Matrix4 matrix(PhotoCrop crop, Size source, double scale) => Matrix4.identity()
    ..translateByDouble((.5 - crop.left) * crop.rotatedWidth(source.width, source.height) * scale,
        (.5 - crop.top) * crop.rotatedHeight(source.width, source.height) * scale, 0, 1)
    ..rotateZ(crop.radians)
    ..scaleByDouble(crop.zoom(source.width, source.height), crop.zoom(source.width, source.height), 1, 1)
    ..translateByDouble(-source.width * scale / 2, -source.height * scale / 2, 0, 1);
  @override
  Widget build(BuildContext context) {
    final scale = width / (crop.rotatedWidth(sourceSize.width, sourceSize.height) * crop.width);
    final size = sourceSize * scale;
    return SizedBox(width: width, height: width / crop.ratio(sourceSize.width, sourceSize.height), child: ClipRect(
      child: OverflowBox(alignment: Alignment.topLeft, minWidth: size.width, maxWidth: size.width,
        minHeight: size.height, maxHeight: size.height,
        child: Transform(alignment: Alignment.topLeft, transform: matrix(crop, sourceSize, scale), child: builder(size))),
    ));
  }
}

class CropEditor extends StatefulWidget {
  const CropEditor({super.key, required this.image, this.initial});
  final ui.Image image;
  final PhotoCrop? initial;
  @override
  State<CropEditor> createState() => _CropEditorState();
}

class _CropEditorState extends State<CropEditor> {
  late PhotoCrop crop = widget.initial ?? const PhotoCrop();
  double? ratio;
  Rect? _start;
  Offset? _focal;
  Rect get rect => Rect.fromLTRB(crop.left, crop.top, crop.right, crop.bottom);
  Size get source => Size(widget.image.width.toDouble(), widget.image.height.toDouble());
  void setRect(Rect r) => setState(() => crop = PhotoCrop(left: r.left, top: r.top, right: r.right,
    bottom: r.bottom, turns: crop.turns, angle: crop.angle));

  void _ratio(double? next) {
    setState(() => ratio = next);
    if (next == null) return;
    final frame = crop.rotatedWidth(source.width, source.height) / crop.rotatedHeight(source.width, source.height);
    final nw = math.min(1.0, next / frame), nh = math.min(1.0, frame / next);
    setRect(Rect.fromCenter(center: const Offset(.5, .5), width: nw, height: nh));
  }

  @override
  Widget build(BuildContext context) => Scaffold(body: SafeArea(child: Column(children: [
    Padding(padding: const EdgeInsets.symmetric(horizontal: 10), child: Row(children: [
      TextAction('Cancel', onTap: () => Navigator.pop(context)), const Spacer(), Text('Crop', style: Txt.label),
      const Spacer(), TextAction('Done', onTap: () => Navigator.pop(context, crop)),
    ])),
    Expanded(child: LayoutBuilder(builder: (context, bounds) {
      final full = PhotoCrop(turns: crop.turns, angle: crop.angle);
      final w = math.min(bounds.maxWidth - 32, (bounds.maxHeight - 32) * full.ratio(source.width, source.height));
      final h = w / full.ratio(source.width, source.height);
      final selection = Rect.fromLTRB(rect.left * w, rect.top * h, rect.right * w, rect.bottom * h);
      return Center(child: SizedBox(width: w, height: h, child: Stack(clipBehavior: Clip.none, children: [
        CroppedPhoto(crop: full, sourceSize: source, width: w,
          builder: (size) => SizedBox.fromSize(size: size, child: RawImage(image: widget.image, fit: BoxFit.fill))),
        Positioned.fill(child: IgnorePointer(child: CustomPaint(painter: _CropLines(selection)))),
        Positioned.fromRect(rect: selection, child: GestureDetector(behavior: HitTestBehavior.opaque,
          onScaleStart: (d) { _start = rect; _focal = d.focalPoint; },
          onScaleUpdate: (d) {
            final start = _start!;
            final width = (start.width / d.scale).clamp(.05, 1.0), height = (start.height / d.scale).clamp(.05, 1.0);
            final delta = d.focalPoint - _focal!;
            final center = start.center + Offset(delta.dx / w, delta.dy / h);
            setRect(Rect.fromCenter(center: Offset(center.dx.clamp(width / 2, 1 - width / 2), center.dy.clamp(height / 2, 1 - height / 2)), width: width, height: height));
          }, child: const SizedBox.expand())),
        for (final corner in [const Offset(0, 0), const Offset(1, 0), const Offset(0, 1), const Offset(1, 1)])
          Positioned(left: (corner.dx == 0 ? selection.left : selection.right) - 22,
            top: (corner.dy == 0 ? selection.top : selection.bottom) - 22,
            child: Semantics(label: 'Resize crop corner', child: GestureDetector(behavior: HitTestBehavior.opaque,
              onPanUpdate: (d) {
                var left = rect.left, right = rect.right, top = rect.top, bottom = rect.bottom;
                if (corner.dx == 0) { left = (left + d.delta.dx / w).clamp(0, right - .05); }
                else { right = (right + d.delta.dx / w).clamp(left + .05, 1); }
                if (corner.dy == 0) { top = (top + d.delta.dy / h).clamp(0, bottom - .05); }
                else { bottom = (bottom + d.delta.dy / h).clamp(top + .05, 1); }
                if (ratio != null) {
                  final target = ratio! / (w / h);
                  var width = right - left, height = width / target;
                  final anchor = Offset(corner.dx == 0 ? rect.right : rect.left, corner.dy == 0 ? rect.bottom : rect.top);
                  final maxHeight = corner.dy == 0 ? anchor.dy : 1 - anchor.dy;
                  if (height > maxHeight) { height = maxHeight; width = height * target; }
                  if (width < .05 || height < .05) return;
                  left = corner.dx == 0 ? anchor.dx - width : anchor.dx; right = left + width;
                  top = corner.dy == 0 ? anchor.dy - height : anchor.dy; bottom = top + height;
                }
                setRect(Rect.fromLTRB(left, top, right, bottom));
              }, child: const SizedBox(width: 44, height: 44)))),
      ])));
    })),
    Padding(padding: const EdgeInsets.symmetric(horizontal: 20), child: SliderRow(label: 'Straighten', value: crop.angle,
      min: -45, max: 45, defaultValue: 0, advanced: true, onStart: () {}, onEnd: () {},
      onChanged: (v) => setState(() => crop = PhotoCrop(left: crop.left, top: crop.top, right: crop.right,
        bottom: crop.bottom, turns: crop.turns, angle: v)))),
    SingleChildScrollView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 10), child: Row(children: [
      for (final option in <String, double?>{'Free': null, 'Original': source.aspectRatio, '1:1': 1, '4:3': 4 / 3, '3:2': 1.5, '16:9': 16 / 9}.entries)
        TextAction(option.key, color: ratio == option.value ? Neutral.primary : Neutral.secondary, onTap: () => _ratio(option.value)),
    ])),
    Padding(padding: const EdgeInsets.fromLTRB(10, 4, 10, 16), child: Row(children: [
      TextAction('Rotate 90°', onTap: () => setState(() {
        ratio = ratio == null ? null : 1 / ratio!;
        crop = PhotoCrop(left: 1 - crop.bottom, top: crop.left, right: 1 - crop.top,
          bottom: crop.right, turns: (crop.turns + 1) % 4, angle: crop.angle);
      })), const Spacer(), TextAction('Reset', onTap: () => setState(() { crop = const PhotoCrop(); ratio = null; })),
    ])),
  ])));
}

class _CropLines extends CustomPainter {
  _CropLines(this.rect);
  final Rect rect;
  @override
  void paint(Canvas canvas, Size size) {
    final outside = Path()..fillType = PathFillType.evenOdd..addRect(Offset.zero & size)..addRect(rect);
    canvas.drawPath(outside, Paint()..color = const Color(0x88000000));
    canvas.drawRect(rect, Paint()..color = Colors.white..style = PaintingStyle.stroke..strokeWidth = 1.5);
    final grid = Paint()..color = const Color(0x88FFFFFF)..strokeWidth = .5;
    for (var i = 1; i < 3; i++) {
      canvas.drawLine(Offset(rect.left + rect.width * i / 3, rect.top), Offset(rect.left + rect.width * i / 3, rect.bottom), grid);
      canvas.drawLine(Offset(rect.left, rect.top + rect.height * i / 3), Offset(rect.right, rect.top + rect.height * i / 3), grid);
    }
    final handle = Paint()..color = Colors.white..strokeWidth = 3..strokeCap = StrokeCap.round;
    for (final p in [rect.topLeft, rect.topRight, rect.bottomLeft, rect.bottomRight]) {
      final dx = p.dx == rect.left ? 14.0 : -14.0, dy = p.dy == rect.top ? 14.0 : -14.0;
      canvas.drawLine(p, p + Offset(dx, 0), handle); canvas.drawLine(p, p + Offset(0, dy), handle);
    }
  }
  @override
  bool shouldRepaint(_CropLines old) => old.rect != rect;
}
