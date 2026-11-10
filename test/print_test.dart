import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pdf/pdf.dart';

import 'package:afterhue/core/print_layout.dart';
import 'package:afterhue/core/renderer.dart' as renderer;
import 'package:afterhue/data/print_export.dart';
import 'package:afterhue/ui/print.dart';
import 'package:afterhue/ui/theme.dart';

Future<ui.Image> decode(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  codec.dispose();
  return frame.image;
}

Future<PrintContent> sampleContent() async {
  final bytes = (await rootBundle.load('assets/samples/lantern.jpg')).buffer.asUint8List();
  final source = img.decodeJpg(bytes)!.convert(numChannels: 4);
  final pixels = renderer.Rgba(source.width, source.height, source.getBytes());
  const colors = [Color(0xff242424), Color(0xffbc2924), Color(0xffb99043), Color(0xffbdbdb8)];
  final textures = colors.map((color) {
    final hex = '#${(color.toARGB32() & 0xffffff).toRadixString(16).padLeft(6, '0')}';
    final patch = renderer.colorPatch(pixels, renderer.keptColorFromHex(hex)!);
    return patch == null ? null : Uint8List.fromList(img.encodePng(img.Image.fromBytes(
      width: patch.width, height: patch.height, bytes: patch.pixels.buffer, numChannels: 4)));
  }).toList();
  return PrintContent(photo: bytes, colors: colors, textures: textures);
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

  test('all paper/layout choices reserve readable space for optional details', () {
    for (final paper in PrintPaper.values) {
      for (final style in PrintStyle.values) {
        for (final landscape in [true, false]) {
          final layout = PrintLayout(paper: paper, style: style, landscape: landscape,
            title: 'A moment to keep', place: 'Tokyo', date: '2026.11.10',
            colors: List.filled(6, Colors.orange), showColors: true);
          expect(layout.photoRect.height, greaterThan(25));
          final info = layout.informationRect(const Size(800, 1200));
          expect(info.bottom, lessThanOrEqualTo(layout.size.height));
          expect(info.left, greaterThanOrEqualTo(0));
          if (layout.overlaysPhoto) {
            expect(layout.photoRect, Offset.zero & layout.size);
            expect(info.top, lessThan(layout.photoRect.bottom));
          } else {
            expect(info.top, greaterThan(layout.photoRect.bottom));
          }
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

  testWidgets('texture badges survive export and metadata stays outside the photo', (tester) async {
    await tester.runAsync(() async {
      final content = await sampleContent();
      expect(content.textures.whereType<Uint8List>().length, 4);
      final photo = await decode(content.photo);
      final textures = await Future.wait(content.textures.map((b) async => b == null ? null : await decode(b)));
      final layout = PrintLayout(style: PrintStyle.instant, paper: PrintPaper.postcard,
        title: 'Everything in Tokyo', place: 'Asakusa', date: '2026.11.10', colors: content.colors, showColors: true);
      final textured = await exportPrintImage(photo, layout, textures: textures, fontFamily: uiFamily, dpi: 180);
      final flat = await exportPrintImage(photo, layout, fontFamily: uiFamily, dpi: 180);
      expect(textured, isNot(orderedEquals(flat)), reason: 'Saved and printed output must use the real patch pixels');
      final output = img.decodeJpg(textured)!;
      final info = layout.informationRect(Size(photo.width.toDouble(), photo.height.toDouble()));
      expect(info.left, layout.visiblePhotoRect(Size(photo.width.toDouble(), photo.height.toDouble())).left);
      expect(info.top, greaterThan(layout.photoRect.bottom));
      expect(info.bottom, lessThan(layout.size.height));
      expect(output.getPixel(0, 0).r, greaterThan(250));
      if (Platform.environment['AFTER_HUE_REVIEW_FONT'] != null) {
        final folder = Directory('/tmp/afterhue-print-review')..createSync(recursive: true);
        File('${folder.path}/concept1-print.jpg').writeAsBytesSync(textured);
        final fullPhoto = await exportPrintImage(photo, PrintLayout(
          style: PrintStyle.fullPhoto, paper: PrintPaper.postcard,
          title: layout.title, place: layout.place, date: layout.date,
          colors: content.colors, showColors: true),
          textures: textures, fontFamily: uiFamily, dpi: 180);
        File('${folder.path}/full-photo-print.jpg').writeAsBytesSync(fullPhoto);
      }
      for (final texture in textures) { texture?.dispose(); }
      photo.dispose();
    });
  });

  testWidgets('full photo shades only the caption region and leaves no paper border', (tester) async {
    await tester.runAsync(() async {
      final source = img.Image(width: 100, height: 100);
      img.fill(source, color: img.ColorRgb8(255, 255, 255));
      final photo = await decode(Uint8List.fromList(img.encodePng(source)));
      final empty = img.decodeJpg(await exportPrintImage(photo,
        const PrintLayout(style: PrintStyle.fullPhoto), dpi: 72))!;
      final captioned = img.decodeJpg(await exportPrintImage(photo,
        const PrintLayout(style: PrintStyle.fullPhoto, title: 'Evening walk', place: 'Tokyo'), dpi: 72))!;
      expect(empty.getPixel(0, empty.height - 1).r, greaterThan(250));
      expect(captioned.getPixel(0, 0).r, greaterThan(250));
      expect(captioned.getPixel(0, captioned.height ~/ 3).r, greaterThan(250));
      expect(captioned.getPixel(0, captioned.height - 1).r, lessThan(100));
      const layout = PrintLayout(style: PrintStyle.fullPhoto, title: 'Evening walk', place: 'Tokyo');
      final titleY = (layout.informationRect(const Size(100, 100)).top / layout.size.height * captioned.height).ceil();
      expect(captioned.getPixel(0, titleY).r, lessThan(100),
        reason: 'Even a white photo needs sufficient contrast behind the first line');
      photo.dispose();
    });
  });

  for (final entry in {
    'phone': const Size(393, 852),
    'landscape': const Size(852, 393),
    'small-phone': const Size(320, 568),
    'large-text': const Size(393, 852),
  }.entries) {
    testWidgets('print controls and details fit ${entry.key}', (tester) async {
      final capture = Platform.environment['AFTER_HUE_REVIEW_FONT'] != null;
      if (capture) debugDisableShadows = false;
      addTearDown(() => debugDisableShadows = true);
      tester.view.physicalSize = entry.value;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      late PrintContent content;
      await tester.runAsync(() async { content = await sampleContent(); });
      final boundary = GlobalKey();
      await tester.pumpWidget(MaterialApp(debugShowCheckedModeBanner: false, theme: buildTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: entry.key == 'large-text'
            ? TextScaler.linear(1.5) : TextScaler.noScaling), child: child!),
        home: RepaintBoundary(
        key: boundary,
        child: PrintScreen(loadContent: () async => content, taken: DateTime(2026, 11, 10)),
      )));
      for (var i = 0; i < 20 && find.byType(CircularProgressIndicator).evaluate().isNotEmpty; i++) {
        await tester.runAsync(() async { await Future<void>.delayed(const Duration(milliseconds: 50)); });
        await tester.pump();
      }
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
      await tester.enterText(find.byType(TextField), 'Everything in Tokyo');
      await tester.tap(find.text('Place'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Asakusa');
      await tester.ensureVisible(find.text('Colors'));
      await tester.tap(find.text('Colors'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Date'));
      await tester.pumpAndSettle();
      if (entry.key == 'phone') {
        tester.view.viewInsets = const FakeViewPadding(bottom: 300);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(tester.getSize(paper).width, lessThanOrEqualTo(previewSize.width));
        tester.view.resetViewInsets();
        await tester.pumpAndSettle();
      }
      await tester.ensureVisible(find.text('Done'));
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Edit details'), findsOneWidget);
      if (capture) { await tester.runAsync(() async {
        final image = await (boundary.currentContext!.findRenderObject() as RenderRepaintBoundary).toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final directory = Directory('/tmp/afterhue-print-review')..createSync(recursive: true);
        File('${directory.path}/${entry.key}.png').writeAsBytesSync(bytes!.buffer.asUint8List());
        image.dispose();
      }); }
      await tester.tap(find.text('Full photo'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final overlay = tester.widget<CustomPaint>(paper).painter! as PrintPainter;
      expect(overlay.layout.overlaysPhoto, isTrue);
      expect(overlay.layout.title, 'Everything in Tokyo');
      expect(overlay.layout.place, 'Asakusa');
      expect(overlay.layout.hasColors, isTrue);
      expect(find.text('Fit'), findsNothing);
      if (capture) { await tester.runAsync(() async {
        final image = await (boundary.currentContext!.findRenderObject() as RenderRepaintBoundary).toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        File('/tmp/afterhue-print-review/${entry.key}-full-photo.png').writeAsBytesSync(bytes!.buffer.asUint8List());
        image.dispose();
      }); }
      await tester.tap(find.text('Instant'));
      await tester.pumpAndSettle();
      expect((tester.widget<CustomPaint>(paper).painter! as PrintPainter).layout.title, 'Everything in Tokyo');
      expect(find.text('Fit'), findsOneWidget);
      debugDisableShadows = true;
    });
  }

  testWidgets('loading preserves a paper orientation chosen by the user', (tester) async {
    late PrintContent content;
    await tester.runAsync(() async { content = await sampleContent(); });
    final ready = Completer<PrintContent>();
    await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: PrintScreen(
      loadContent: () => ready.future, taken: DateTime(2026),
    )));
    await tester.tap(find.byTooltip('Use landscape paper'));
    await tester.pump();
    expect(find.byTooltip('Use portrait paper'), findsOneWidget);
    ready.complete(content);
    for (var i = 0; i < 20 && find.byType(CircularProgressIndicator).evaluate().isNotEmpty; i++) {
      await tester.runAsync(() async { await Future<void>.delayed(const Duration(milliseconds: 50)); });
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(find.byTooltip('Use portrait paper'), findsOneWidget,
      reason: 'The source aspect ratio is only a default, not an override of a user choice');
  });

  testWidgets('unavailable original offers retry and never enables output', (tester) async {
    var attempts = 0;
    await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: PrintScreen(
      loadContent: () async { attempts++; throw StateError('unavailable'); }, taken: DateTime(2026),
    )));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNull);
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(attempts, 2);
  });
}
