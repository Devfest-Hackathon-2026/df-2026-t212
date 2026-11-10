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
class PrintContent {
  const PrintContent({required this.photo, this.colors = const [], this.textures = const []});
  final Uint8List photo;
  final List<ui.Color> colors;
  final List<Uint8List?> textures;
}

Future<PrintContent> loadPrintContent(PhotoItem item) async {
  await Store.instance.ensureSource(item);
  final snapshot = PhotoItem.fromJson(item.toJson());
  final pixels = await Store.instance.sourcePixels(snapshot, 2600);
  if (pixels == null) throw StateError('The original photo is unavailable.');
  final recipe = snapshot.edit;
  final photo = await Isolate.run(() {
    final output = recipe == null ? pixels : render(pixels, recipe).image;
    final image = img.Image.fromBytes(width: output.width, height: output.height,
      bytes: output.pixels.buffer, numChannels: 4);
    return Uint8List.fromList(img.encodePng(image));
  });
  final hues = snapshot.hues.take(6).toList();
  final textures = await Future.wait(hues.map((color) async {
    try {
      final patch = await Store.instance.printPatch(snapshot, color);
      return (await patch?.toByteData(format: ui.ImageByteFormat.png))?.buffer.asUint8List();
    } catch (_) {
      // A missing patch must not prevent printing an otherwise available photo.
      return null;
    }
  }));
  return PrintContent(photo: photo, textures: textures, colors: hues.map((color) {
    final rgb = oklabToRgb8(color.l, color.a, color.b);
    return ui.Color.fromARGB(255, rgb[0], rgb[1], rgb[2]);
  }).toList());
}

Future<Uint8List> exportPrintImage(ui.Image photo, PrintLayout layout, {String? fontFamily, List<ui.Image?> textures = const [], double dpi = 300}) async {
  final width = (layout.size.width / 25.4 * dpi).round();
  final height = (layout.size.height / 25.4 * dpi).round();
  final recorder = ui.PictureRecorder();
  PrintPainter(photo: photo, layout: layout, fontFamily: fontFamily, textures: textures)
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
