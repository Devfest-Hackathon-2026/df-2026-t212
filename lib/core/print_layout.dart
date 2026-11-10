import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

enum PrintStyle { photo, instant }

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
  String get caption => [if (!hasTitle) place.trim(), date].where((s) => s.isNotEmpty).join(' / ');
  bool get hasDetails => hasTitle || caption.isNotEmpty || hasColors;
  double get inset => style == PrintStyle.instant ? 6 : (hasDetails ? 4 : 0);
  static const badgeSize = 3.8, badgeGap = 1.8;
  int get badgeCount => hasColors ? math.min(colors.length, 6) : 0;
  double get badgesWidth => badgeCount == 0 ? 0 : badgeCount * badgeSize + (badgeCount - 1) * badgeGap;
  double get detailsHeight =>
      (hasTitle ? 6 : 0) +
      (caption.isNotEmpty || hasColors ? 4.5 : 0);
  double get footer => math.max(
    style == PrintStyle.instant ? 22.0 : 0.0,
    hasDetails ? detailsHeight + 7 : inset,
  );
  Rect get photoRect => Rect.fromLTWH(
    inset, inset, size.width - inset * 2, size.height - inset - footer,
  );

}

class PrintPainter extends CustomPainter {
  PrintPainter({required this.photo, required this.layout, this.fontFamily});
  final ui.Image photo;
  final PrintLayout layout;
  final String? fontFamily;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / layout.size.width, size.height / layout.size.height);
    canvas.drawRect(Offset.zero & layout.size, Paint()..color = Colors.white);
    paintImage(
      canvas: canvas,
      rect: layout.photoRect,
      image: photo,
      fit: layout.fill ? BoxFit.cover : BoxFit.contain,
      filterQuality: FilterQuality.high,
    );

    var y = layout.photoRect.bottom + 4;
    final x = layout.inset;
    final width = layout.size.width - x * 2;
    void text(String value, double fontSize, {FontWeight weight = FontWeight.w400}) {
      final painter = TextPainter(
        text: TextSpan(text: value, style: TextStyle(
          color: const Color(0xff161616), fontFamily: fontFamily,
          fontSize: fontSize, fontWeight: weight, height: 1.1,
        )),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '\u2026',
      )..layout(maxWidth: width - (layout.hasColors ? layout.badgesWidth + 3 : 0));
      painter.paint(canvas, Offset(x, y));
      painter.dispose();
    }

    if (layout.hasTitle) {
      final place = layout.place.trim();
      final placePainter = place.isEmpty ? null : (TextPainter(
        text: TextSpan(text: '- $place', style: TextStyle(
          color: const Color(0xff161616), fontFamily: fontFamily, fontSize: 2.5, height: 1.1,
        )),
        textDirection: TextDirection.ltr, maxLines: 1, ellipsis: '\u2026',
      )..layout(maxWidth: width * .35));
      final titlePainter = TextPainter(
        text: TextSpan(text: layout.title.trim(), style: TextStyle(
          color: const Color(0xff161616), fontFamily: fontFamily, fontSize: 3.5,
          fontWeight: FontWeight.w500, height: 1.1,
        )),
        textDirection: TextDirection.ltr, maxLines: 1, ellipsis: '\u2026',
      )..layout(maxWidth: width - (placePainter == null ? 0 : placePainter.width + 1.5));
      titlePainter.paint(canvas, Offset(x, y));
      if (placePainter != null) {
        final baseline = titlePainter.computeDistanceToActualBaseline(TextBaseline.alphabetic);
        final placeBaseline = placePainter.computeDistanceToActualBaseline(TextBaseline.alphabetic);
        placePainter.paint(canvas, Offset(x + titlePainter.width + 1.5, y + baseline - placeBaseline));
        placePainter.dispose();
      }
      titlePainter.dispose();
      y += 6;
    }
    if (layout.caption.isNotEmpty) {
      text(layout.caption, 2.5);
    }
    if (layout.hasColors) {
      for (var i = 0; i < layout.badgeCount; i++) {
        final point = Offset(x + width - layout.badgesWidth + i * (PrintLayout.badgeSize + PrintLayout.badgeGap), y);
        canvas.drawRRect(
          RRect.fromRectAndRadius(point & const Size(PrintLayout.badgeSize, PrintLayout.badgeSize), const Radius.circular(1.1)),
          Paint()..color = layout.colors[i],
        );
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(PrintPainter oldDelegate) =>
      photo != oldDelegate.photo || layout != oldDelegate.layout || fontFamily != oldDelegate.fontFamily;
}
