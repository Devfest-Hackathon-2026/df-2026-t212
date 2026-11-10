import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pdf/pdf.dart';

import 'package:afterhue/core/print_layout.dart';
import 'package:afterhue/data/print_export.dart';
import 'package:afterhue/ui/print.dart';
import 'package:afterhue/ui/theme.dart';

Future<ui.Image> decode(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  codec.dispose();
  return frame.image;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Optional local capture with a real system font; CI still runs all layout
  // and export assertions without depending on a host-specific font path.
  setUpAll(() async {
    final path = Platform.environment['AFTER_HUE_REVIEW_FONT'];
    if (path == null) return;
    await (FontLoader('Helvetica Neue')
      ..addFont(File(path).readAsBytes().then((b) => ByteData.sublistView(b)))).load();
    await (FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  test('all paper/layout choices keep optional details below the photo', () {
    for (final paper in PrintPaper.values) {
      for (final style in PrintStyle.values) {
        for (final landscape in [true, false]) {
          final layout = PrintLayout(paper: paper, style: style, landscape: landscape,
            title: 'A moment to keep', place: 'Tokyo', date: '2026.11.10',
            colors: List.filled(6, Colors.orange), showColors: true);
          expect(layout.photoRect.height, greaterThan(25));
          expect(layout.photoRect.bottom + 4 + layout.detailsHeight, lessThanOrEqualTo(layout.size.height));
        }
      }
    }
  });

  testWidgets('export preserves all image edges by default and fill deliberately crops', (tester) async {
    await tester.runAsync(() async {
      final source = img.Image(width: 300, height: 100);
      img.fill(source, color: img.ColorRgb8(0, 180, 0));
      img.fillRect(source, x1: 0, y1: 0, x2: 29, y2: 99, color: img.ColorRgb8(255, 0, 0));
      img.fillRect(source, x1: 270, y1: 0, x2: 299, y2: 99, color: img.ColorRgb8(0, 0, 255));
      final photo = await decode(Uint8List.fromList(img.encodePng(source)));
      final whole = img.decodeJpg(await exportPrintImage(photo, const PrintLayout(), dpi: 72))!;
      final filled = img.decodeJpg(await exportPrintImage(photo, const PrintLayout(fill: true), dpi: 72))!;
      expect(whole.getPixel(5, whole.height ~/ 2).r, greaterThan(200));
      expect(whole.getPixel(whole.width - 6, whole.height ~/ 2).b, greaterThan(200));
      expect(filled.getPixel(5, filled.height ~/ 2).g, greaterThan(140));
      final instantBytes = await exportPrintImage(photo, const PrintLayout(style: PrintStyle.instant));
      final instant = img.decodeJpg(instantBytes)!;
      expect(instant.width, (89 / 25.4 * 300).round());
      expect(instant.height, (127 / 25.4 * 300).round());
      expect(instant.getPixel(instant.width ~/ 2, instant.height - 20).r, greaterThan(245));
      final pdf = await printPdf(instantBytes, PdfPageFormat.a4);
      expect(String.fromCharCodes(pdf.take(5)), '%PDF-');
      photo.dispose();
    });
  });

  for (final entry in {
    'phone': const Size(393, 852),
    'landscape': const Size(852, 393),
    'small-phone': const Size(320, 568),
  }.entries) {
    testWidgets('print controls and details fit ${entry.key}', (tester) async {
      tester.view.physicalSize = entry.value;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final boundary = GlobalKey();
      await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: RepaintBoundary(
        key: boundary,
        child: PrintScreen(loadPhoto: () async => (await rootBundle.load('assets/samples/lantern.jpg')).buffer.asUint8List(),
          colors: const [Color(0xffad261d), Color(0xffdd9939), Color(0xff2a4340)], taken: DateTime(2026, 11, 10)),
      )));
      await tester.runAsync(() async { await Future<void>.delayed(const Duration(milliseconds: 200)); });
      await tester.pumpAndSettle();
      expect(find.byType(CustomPaint), findsWidgets);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Instant'));
      await tester.pumpAndSettle();
      final paper = find.byWidgetPredicate((w) => w is CustomPaint && w.painter is PrintPainter);
      final previewSize = tester.getSize(paper);
      await tester.tap(find.text('Add details'));
      await tester.pumpAndSettle();
      expect(tester.getSize(paper).width, lessThanOrEqualTo(previewSize.width));
      expect(tester.getSize(paper).height, lessThanOrEqualTo(previewSize.height));
      await tester.enterText(find.byType(TextField), 'Evening in Tokyo');
      await tester.tap(find.text('Place'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Asakusa');
      await tester.ensureVisible(find.text('Colors'));
      await tester.tap(find.text('Colors'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Done'));
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Edit details'), findsOneWidget);
      await tester.runAsync(() async {
        final image = await (boundary.currentContext!.findRenderObject() as RenderRepaintBoundary).toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final directory = Directory('/tmp/afterhue-print-review')..createSync(recursive: true);
        File('${directory.path}/${entry.key}.png').writeAsBytesSync(bytes!.buffer.asUint8List());
        image.dispose();
      });
    });
  }

  testWidgets('unavailable original offers retry and never enables output', (tester) async {
    var attempts = 0;
    await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: PrintScreen(
      loadPhoto: () async { attempts++; throw StateError('unavailable'); }, colors: const [], taken: DateTime(2026),
    )));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNull);
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(attempts, 2);
  });
}
