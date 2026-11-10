import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:image/image.dart' as img;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../core/print_layout.dart';
import '../core/renderer.dart';
import 'store.dart';

/// Capture the current source/edit once; later background edits cannot change
/// the photo halfway through previewing and exporting a print.
Future<Uint8List> loadPrintPhoto(PhotoItem item) async {
  await Store.instance.ensureSource(item);
  final snapshot = PhotoItem.fromJson(item.toJson());
  final pixels = await Store.instance.sourcePixels(snapshot, 2600);
  if (pixels == null) throw StateError('The original photo is unavailable.');
  final recipe = snapshot.edit;
  return Isolate.run(() {
    final output = recipe == null ? pixels : render(pixels, recipe).image;
    final image = img.Image.fromBytes(width: output.width, height: output.height,
      bytes: output.pixels.buffer, numChannels: 4);
    return Uint8List.fromList(img.encodePng(image));
  });
}

Future<Uint8List> exportPrintImage(ui.Image photo, PrintLayout layout, {String? fontFamily, double dpi = 300}) async {
  final width = (layout.size.width / 25.4 * dpi).round();
  final height = (layout.size.height / 25.4 * dpi).round();
  final recorder = ui.PictureRecorder();
  PrintPainter(photo: photo, layout: layout, fontFamily: fontFamily)
      .paint(ui.Canvas(recorder), ui.Size(width.toDouble(), height.toDouble()));
  final picture = recorder.endRecording();
  final raster = await picture.toImage(width, height);
  picture.dispose();
  final data = await raster.toByteData(format: ui.ImageByteFormat.png);
  raster.dispose();
  if (data == null) throw StateError('Could not prepare the print image.');
  final bytes = data.buffer.asUint8List();
  return Isolate.run(() {
    final image = img.decodePng(bytes)!;
    return Uint8List.fromList(img.encodeJpg(image, quality: 96));
  });
}

/// Honour the printer's actual printable area. Keep the complete design even
/// when its paper differs from the selected photo size.
Future<Uint8List> printPdf(Uint8List jpeg, PdfPageFormat format) async {
  final document = pw.Document();
  document.addPage(pw.Page(pageFormat: format, build: (_) => pw.Center(
    child: pw.Image(pw.MemoryImage(jpeg), fit: pw.BoxFit.contain),
  )));
  return document.save();
}
