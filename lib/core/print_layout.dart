import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

enum PrintStyle {
  photo('Photo'), instant('Instant'), fullPhoto('Full photo');

  const PrintStyle(this.label);
  final String label;
}

enum PrintPaper {
  l('L', 89, 127),
  postcard('4 x 6', 101.6, 152.4),
  twoL('2L', 127, 178);

  const PrintPaper(this.label, this.width, this.height);
  final String label;
  final double width, height;
}

/// All dimensions are millimetres. Preview and export use this same painter.
class PrintLayout {
  const PrintLayout({
    this.style = PrintStyle.photo,
    this.paper = PrintPaper.l,
    this.landscape = false,
    this.fill = false,
    this.title = '',
    this.place = '',
    this.date = '',
    this.colors = const [],
    this.showColors = false,
  });

  final PrintStyle style;
  final PrintPaper paper;
  final bool landscape, fill, showColors;
  final String title, place, date;
  final List<Color> colors;

  Size get size => landscape
      ? Size(paper.height, paper.width)
      : Size(paper.width, paper.height);
  bool get hasColors => showColors && colors.isNotEmpty;
  bool get hasTitle => title.trim().isNotEmpty;
  String get caption => [place.trim(), date].where((s) => s.isNotEmpty).join(' / ');
  bool get hasDetails => hasTitle || caption.isNotEmpty || hasColors;
  bool get overlaysPhoto => style == PrintStyle.fullPhoto;
  bool get cropsPhoto => overlaysPhoto || fill;
  double get scale => size.shortestSide / 101.6;
  double get inset => overlaysPhoto ? 0 : (style == PrintStyle.instant ? 6.5 : (hasDetails ? 4 : 0)) * scale;
  double get titleSize => 4.8 * scale;
  double get metadataSize => 3.1 * scale;
  double get titleAdvance => 8.5 * scale;
  double get rowHeight => 6 * scale;
  double get badgeSize => (badgeCount > 4 ? 4.4 : 5.6) * scale;
  double get badgeGap => 1.8 * scale;
  int get badgeCount => hasColors ? math.min(colors.length, 6) : 0;
  double get badgesWidth => badgeCount == 0 ? 0 : badgeCount * badgeSize + (badgeCount - 1) * badgeGap;
  double get detailsHeight =>
      (hasTitle ? titleAdvance : 0) +
      (caption.isNotEmpty || hasColors ? rowHeight : 0);
  double get footer => overlaysPhoto ? 0 : math.max(
    style == PrintStyle.instant ? 29 * scale : 0.0,
    hasDetails ? detailsHeight + 12 * scale : inset,
  );
  Rect get photoRect => Rect.fromLTWH(
    inset, inset, size.width - inset * 2, size.height - inset - footer,
  );

  /// Align the information with the visible photo, including Fit letterboxing.
  Rect visiblePhotoRect(Size source) => cropsPhoto ? photoRect :
      Alignment.center.inscribe(applyBoxFit(BoxFit.contain, source, photoRect.size).destination, photoRect);

  Rect informationRect(Size source) {
    if (overlaysPhoto) {
      final margin = 6.5 * scale;
      return Rect.fromLTWH(margin, size.height - margin - detailsHeight,
          size.width - margin * 2, detailsHeight);
    }
    final photo = visiblePhotoRect(source);
    return Rect.fromLTWH(photo.left, photoRect.bottom + 5.5 * scale, photo.width, detailsHeight);
  }

}

class PrintPainter extends CustomPainter {
  PrintPainter({required this.photo, required this.layout, this.fontFamily, this.textures = const []});
  final ui.Image photo;
  final PrintLayout layout;
  final String? fontFamily;
  final List<ui.Image?> textures;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / layout.size.width, size.height / layout.size.height);
    canvas.drawRect(Offset.zero & layout.size, Paint()..color = Colors.white);
    paintImage(
      canvas: canvas,
      rect: layout.photoRect,
      image: photo,
      fit: layout.cropsPhoto ? BoxFit.cover : BoxFit.contain,
      filterQuality: FilterQuality.high,
    );

    final info = layout.informationRect(Size(photo.width.toDouble(), photo.height.toDouble()));
    if (layout.overlaysPhoto && layout.hasDetails) {
      // Fade only behind the caption; preserve the photo above it.
      final shade = Rect.fromLTRB(0, math.max(0, info.top - 16 * layout.scale),
          layout.size.width, layout.size.height);
      canvas.drawRect(shade, Paint()..shader = ui.Gradient.linear(
        shade.topCenter, shade.bottomCenter,
        const [Colors.transparent, Color(0xa3000000), Color(0xb3000000)],
        [0, (info.top - shade.top) / shade.height, 1],
      ));
    }
    final foreground = layout.overlaysPhoto ? Colors.white : const Color(0xff161616);
    var y = info.top;
    final x = info.left, width = info.width;
    TextPainter text(String value, double fontSize, double maxWidth, {Color? color, String? family}) => TextPainter(
        text: TextSpan(text: value, style: TextStyle(
          color: color ?? foreground, fontFamily: family ?? fontFamily,
          fontSize: fontSize, fontWeight: FontWeight.w400, height: 1.1,
        )),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '\u2026',
      )..layout(maxWidth: math.max(0, maxWidth));

    if (layout.hasTitle) {
      final titlePainter = text(layout.title.trim(), layout.titleSize, width);
      titlePainter.paint(canvas, Offset(x, y));
      titlePainter.dispose();
      y += layout.titleAdvance;
    }
    // Metadata and texture badges share one calm baseline beneath the title.
    // On extremely narrow prints, scale the badge row within its own space.
    final badgeScale = layout.hasColors ? math.min(1.0, width * (layout.caption.isEmpty ? 1 : .46) / layout.badgesWidth) : 1.0;
    final badgeWidth = layout.badgesWidth * badgeScale;
    final unit = layout.scale;
    final metaWidth = math.max(0.0, width - (layout.hasColors ? badgeWidth + 3 * unit : 0));
    final secondary = layout.overlaysPhoto ? const Color(0xffeeeeee) : const Color(0xff666666);
    if (layout.caption.isNotEmpty) {
      final hasPlace = layout.place.trim().isNotEmpty;
      final date = text(layout.date, layout.metadataSize, metaWidth, color: secondary);
      final both = hasPlace && layout.date.isNotEmpty;
      final placeWidth = math.max(0.0, metaWidth - (both ? date.width + 5 * unit : 0));
      var cursor = x;
      if (hasPlace && placeWidth > 4 * unit) {
        final pin = text(String.fromCharCode(Icons.location_on.codePoint), 3.5 * unit, 3.5 * unit, color: secondary, family: Icons.location_on.fontFamily);
        pin.paint(canvas, Offset(cursor, y + unit));
        pin.dispose();
        cursor += 4 * unit;
        final place = text(layout.place.trim(), layout.metadataSize, placeWidth - 4 * unit, color: secondary);
        place.paint(canvas, Offset(cursor, y + (layout.rowHeight - place.height) / 2));
        cursor += place.width;
        place.dispose();
        if (both) {
          cursor += 2.5 * unit;
          canvas.drawLine(Offset(cursor, y + unit), Offset(cursor, y + 5 * unit), Paint()..color = (layout.overlaysPhoto ? const Color(0x66ffffff) : const Color(0xffbbbbbb))..strokeWidth = .12 * unit);
          cursor += 2.5 * unit;
        }
      }
      if (layout.date.isNotEmpty) date.paint(canvas, Offset(cursor, y + (layout.rowHeight - date.height) / 2));
      date.dispose();
    }
    if (layout.hasColors) {
      for (var i = 0; i < layout.badgeCount; i++) {
        final side = layout.badgeSize * badgeScale;
        final point = Offset(x + width - badgeWidth + i * (layout.badgeSize + layout.badgeGap) * badgeScale, y + (layout.rowHeight - side) / 2);
        final rect = point & Size.square(side);
        final shape = RRect.fromRectAndRadius(rect, Radius.circular(side * .28));
        canvas.drawRRect(
          shape,
          Paint()..color = layout.colors[i],
        );
        final texture = i < textures.length ? textures[i] : null;
        if (texture != null) {
          canvas.save();
          canvas.clipRRect(shape);
          paintImage(canvas: canvas, rect: rect, image: texture, fit: BoxFit.cover, filterQuality: FilterQuality.high);
          canvas.restore();
        }
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(PrintPainter oldDelegate) =>
      photo != oldDelegate.photo || layout != oldDelegate.layout || fontFamily != oldDelegate.fontFamily || textures != oldDelegate.textures;
}
