import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:image/image.dart' as img;
import 'package:pdf/pdf.dart';

import 'package:afterhue/core/print_layout.dart';
import 'package:afterhue/core/crop.dart';
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
          if (!layout.supportsDetails) {
            expect(layout.hasDetails, isFalse);
            expect(layout.photoRect, Offset.zero & layout.size);
          } else if (layout.overlaysPhoto) {
            expect(layout.photoRect, Offset.zero & layout.size);
            expect(info.top, lessThan(layout.photoRect.bottom));
          } else {
            expect(info.top, greaterThan(layout.photoRect.bottom));
          }
        }
      }
    }
  });

  test('very narrow crops retain a readable caption on portrait paper', () {
    const layout = PrintLayout(style: PrintStyle.instant, title: 'A narrow detail',
      place: 'Asakusa', date: '2026.11.10', colors: [Colors.red, Colors.black], showColors: true);
    final photo = layout.visiblePhotoRect(const Size(40, 1200));
    final info = layout.informationRect(const Size(40, 1200));
    expect(info.width, greaterThan(photo.width));
    expect(info.width, greaterThanOrEqualTo(70));
    expect(info.left, greaterThanOrEqualTo(layout.inset));
    expect(info.right, lessThanOrEqualTo(layout.size.width - layout.inset));
    expect(info.top - photo.bottom, closeTo(5.5 * layout.scale, .001));
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

  testWidgets('real cropped photos fit portrait and landscape paper across all styles', (tester) async {
    await tester.runAsync(() async {
      final content = await sampleContent();
      final decoded = img.decodeImage(content.photo)!.convert(numChannels: 4);
      final source = renderer.Rgba(decoded.width, decoded.height, decoded.getBytes());
      final textures = await Future.wait(content.textures.map((b) async => b == null ? null : await decode(b)));
      for (final shape in {
        'portrait': const PhotoCrop(),
        'landscape': const PhotoCrop(top: .25, bottom: .65),
        'square': const PhotoCrop(top: 1 / 6, bottom: 5 / 6),
      }.entries) {
        final cropped = renderer.cropImage(source, shape.value);
        final photo = await decode(Uint8List.fromList(img.encodePng(img.Image.fromBytes(
          width: cropped.width, height: cropped.height, bytes: cropped.pixels.buffer, numChannels: 4))));
        for (final landscape in [false, true]) {
          for (final style in PrintStyle.values) {
            final layout = PrintLayout(style: style, landscape: landscape,
              title: 'Everything in Tokyo', place: 'Asakusa', date: '2026.11.10',
              colors: content.colors, showColors: true);
            expect(layout.size, landscape ? const Size(127, 89) : const Size(89, 127));
            final info = layout.informationRect(Size(cropped.width.toDouble(), cropped.height.toDouble()));
            expect(info.bottom, lessThanOrEqualTo(layout.size.height));
            expect(info.left, greaterThanOrEqualTo(0));
            expect(info.right, lessThanOrEqualTo(layout.size.width));
            final bytes = await exportPrintImage(photo, layout, textures: textures, fontFamily: uiFamily, dpi: 120);
            final rendered = img.decodeJpg(bytes)!;
            expect(rendered.width, (layout.size.width / 25.4 * 120).round());
            expect(rendered.height, (layout.size.height / 25.4 * 120).round());
            if (Platform.environment['AFTER_HUE_REVIEW_FONT'] != null) {
              final folder = Directory('/tmp/afterhue-print-review/matrix')..createSync(recursive: true);
              File('${folder.path}/${shape.key}-${landscape ? 'landscape' : 'portrait'}-${style.name}.jpg').writeAsBytesSync(bytes);
            }
          }
        }
        if (shape.key == 'portrait' && Platform.environment['AFTER_HUE_REVIEW_FONT'] != null) {
          final narrow = renderer.cropImage(source, const PhotoCrop(left: .4, right: .6));
          final narrowPhoto = await decode(Uint8List.fromList(img.encodePng(img.Image.fromBytes(
            width: narrow.width, height: narrow.height, bytes: narrow.pixels.buffer, numChannels: 4))));
          final narrowBytes = await exportPrintImage(narrowPhoto, PrintLayout(style: PrintStyle.instant,
            title: 'Everything in Tokyo', place: 'Asakusa', date: '2026.11.10', colors: [...content.colors, ...content.colors.take(2)], showColors: true),
            textures: [...textures, ...textures.take(2)], fontFamily: uiFamily, dpi: 150);
          final narrowFolder = Directory('/tmp/afterhue-print-review/matrix')..createSync(recursive: true);
          File('${narrowFolder.path}/edge-instant-narrow-portrait.jpg').writeAsBytesSync(narrowBytes);
          narrowPhoto.dispose();
          final folder = Directory('/tmp/afterhue-print-review/matrix')..createSync(recursive: true);
          for (final style in [PrintStyle.instant, PrintStyle.fullPhoto]) {
            for (final variant in ['six-badges', 'long-title', 'long-place', 'no-badges', 'title-only', 'metadata-only']) {
              final layout = PrintLayout(style: style, landscape: true,
                title: variant == 'metadata-only' ? '' : variant == 'long-title'
                  ? 'A very long title about an afternoon walking through old Tokyo' : 'Everything in Tokyo',
                place: variant == 'title-only' ? '' : variant == 'long-place'
                  ? 'Tokyo, Taito City, Asakusa, around the temple and narrow streets' : 'Asakusa',
                date: variant == 'title-only' ? '' : '2026.11.10',
                colors: [...content.colors, ...content.colors.take(2)],
                showColors: variant != 'no-badges' && variant != 'title-only');
              final bytes = await exportPrintImage(photo, layout, textures: [...textures, ...textures.take(2)], fontFamily: uiFamily, dpi: 150);
              File('${folder.path}/edge-${style.name}-$variant.jpg').writeAsBytesSync(bytes);
            }
          }
        }
        photo.dispose();
      }
      for (final texture in textures) { texture?.dispose(); }
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
      expect(tester.getTopLeft(find.text('Paper')).dy, lessThan(tester.getTopLeft(find.text('Instant')).dy));
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
      await tester.tap(find.text('Photo'));
      await tester.pumpAndSettle();
      final plain = tester.widget<CustomPaint>(paper).painter! as PrintPainter;
      expect(plain.layout.hasDetails, isFalse);
      expect(plain.layout.photoRect, Offset.zero & plain.layout.size);
      expect(find.text('Edit details'), findsNothing);
      expect(find.text('Add details'), findsNothing);
      if (capture) { await tester.runAsync(() async {
        final image = await (boundary.currentContext!.findRenderObject() as RenderRepaintBoundary).toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        File('/tmp/afterhue-print-review/${entry.key}-photo-only.png').writeAsBytesSync(bytes!.buffer.asUint8List());
        image.dispose();
      }); }
      await tester.tap(find.text('Instant'));
      await tester.pumpAndSettle();
      expect((tester.widget<CustomPaint>(paper).painter! as PrintPainter).layout.title, 'Everything in Tokyo');
      expect(find.text('Fit'), findsOneWidget);
      debugDisableShadows = true;
    });
  }

  testWidgets('Japanese print controls remain usable on a small phone', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final boundary = GlobalKey();
    late PrintContent content;
    await tester.runAsync(() async { content = await sampleContent(); });
    await tester.pumpWidget(MaterialApp(theme: buildTheme(), locale: const Locale('ja'),
      supportedLocales: const [Locale('en'), Locale('ja')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: RepaintBoundary(key: boundary, child: PrintScreen(loadContent: () async => content, taken: DateTime(2026, 11, 10)))));
    for (var i = 0; i < 20 && find.byType(CircularProgressIndicator).evaluate().isNotEmpty; i++) {
      await tester.runAsync(() async { await Future<void>.delayed(const Duration(milliseconds: 50)); });
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(find.text('用紙'), findsOneWidget);
    await tester.tap(find.text('文字・バッジを追加'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '浅草の午後');
    await tester.tap(find.text('場所'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '東京・浅草');
    await tester.tap(find.text('完了'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('写真のみ'));
    await tester.pumpAndSettle();
    expect(find.text('文字・バッジを編集'), findsNothing);
    expect(tester.takeException(), isNull);
    if (Platform.environment['AFTER_HUE_REVIEW_FONT'] != null) {
      await tester.runAsync(() async {
        final image = await (boundary.currentContext!.findRenderObject() as RenderRepaintBoundary).toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final folder = Directory('/tmp/afterhue-print-review')..createSync(recursive: true);
        File('${folder.path}/japanese-small-phone.png').writeAsBytesSync(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
  });

  testWidgets('Photo exports contain only the photo even after adding details in another style', (tester) async {
    await tester.runAsync(() async {
      final content = await sampleContent();
      final photo = await decode(content.photo);
      final clean = await exportPrintImage(photo, const PrintLayout(style: PrintStyle.photo), dpi: 72);
      final retained = await exportPrintImage(photo, PrintLayout(style: PrintStyle.photo,
        title: 'Must not appear', place: 'Tokyo', date: '2026.11.10', colors: content.colors,
        showColors: true), dpi: 72);
      expect(retained, orderedEquals(clean), reason: 'Photo means no caption, swatches, shading or decorative footer');
      photo.dispose();
    });
  });

  for (final entry in {
    'landscape crop': const PhotoCrop(bottom: .5),
    'portrait crop': const PhotoCrop(left: .25, right: .75, turns: 1),
    'square crop': const PhotoCrop(left: .25, right: .75),
  }.entries) {
    testWidgets('print uses the rendered ${entry.key} but keeps explicit paper dimensions', (tester) async {
      late Uint8List croppedBytes;
      late Size croppedSize;
      await tester.runAsync(() async {
        final source = img.Image(width: 400, height: 200);
        img.fill(source, color: img.ColorRgb8(0, 160, 100));
        final cropped = renderer.cropImage(renderer.Rgba(source.width, source.height,
          source.convert(numChannels: 4).getBytes()), entry.value);
        croppedSize = Size(cropped.width.toDouble(), cropped.height.toDouble());
        croppedBytes = Uint8List.fromList(img.encodePng(img.Image.fromBytes(
          width: cropped.width, height: cropped.height, bytes: cropped.pixels.buffer, numChannels: 4)));
        final photo = await decode(croppedBytes);
        for (final paper in PrintPaper.values) {
          final landscape = cropped.width > cropped.height;
          final layout = PrintLayout(style: PrintStyle.photo, paper: paper, landscape: landscape);
          final expected = landscape ? Size(paper.height, paper.width) : Size(paper.width, paper.height);
          expect(layout.size, expected);
          expect(layout.visiblePhotoRect(croppedSize).size.aspectRatio, closeTo(croppedSize.aspectRatio, .0001));
          final jpeg = await exportPrintImage(photo, layout, dpi: 72);
          final exported = img.decodeJpg(jpeg)!;
          expect(exported.width, (expected.width / 25.4 * 72).round());
          expect(exported.height, (expected.height / 25.4 * 72).round());
          final pdf = await printPdf(jpeg, PdfPageFormat(expected.width * PdfPageFormat.mm, expected.height * PdfPageFormat.mm));
          final box = RegExp(r'/MediaBox\s*\[([^\]]+)\]').firstMatch(String.fromCharCodes(pdf));
          expect(box, isNotNull);
          final values = box!.group(1)!.trim().split(RegExp(r'\s+')).map(double.parse).toList();
          expect(values[2], closeTo(expected.width * PdfPageFormat.mm, .01));
          expect(values[3], closeTo(expected.height * PdfPageFormat.mm, .01));
        }
        photo.dispose();
      });
      await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: PrintScreen(
        loadContent: () async => PrintContent(photo: croppedBytes), taken: DateTime(2026),
      )));
      for (var i = 0; i < 20 && find.byType(CircularProgressIndicator).evaluate().isNotEmpty; i++) {
        await tester.runAsync(() async { await Future<void>.delayed(const Duration(milliseconds: 50)); });
        await tester.pump();
      }
      await tester.pumpAndSettle();
      final landscape = croppedSize.width > croppedSize.height;
      expect(find.byTooltip(landscape ? 'Use portrait paper' : 'Use landscape paper'), findsOneWidget);
      expect(find.text(landscape ? 'L  /  127 x 89 mm' : 'L  /  89 x 127 mm'), findsOneWidget);
      expect(tester.takeException(), isNull);
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
