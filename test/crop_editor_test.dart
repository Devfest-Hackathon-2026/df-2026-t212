import 'dart:ui' as ui;
import 'package:afterhue/core/crop.dart';
import 'package:afterhue/ui/crop_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('rotated and cropped preview hit tests in original photo coordinates', (tester) async {
    const crop = PhotoCrop(left: .2, top: .1, right: .9, bottom: .8, turns: 1, angle: 12);
    const source = Size(400, 200);
    Offset? picked;
    Size? displayedSource;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Center(child: CroppedPhoto(
      key: const ValueKey('crop'), crop: crop, sourceSize: source, width: 140,
      builder: (size) {
        displayedSource = size;
        return SizedBox.fromSize(size: size, child: GestureDetector(behavior: HitTestBehavior.opaque,
          onTapUp: (d) => picked = Offset(d.localPosition.dx / size.width, d.localPosition.dy / size.height),
          child: const ColoredBox(color: Colors.red)));
      },
    )))));
    final bounds = tester.getRect(find.byKey(const ValueKey('crop')));
    await tester.tapAt(bounds.topLeft + Offset(bounds.width * .4, bounds.height * .6));
    final (x, y) = crop.sourcePoint(.4, .6, 400, 200);
    expect(displayedSource, isNotNull);
    expect(picked, isNotNull);
    expect(picked!.dx, closeTo(x / 400, .001));
    expect(picked!.dy, closeTo(y / 200, .001));
  });

  testWidgets('crop controls rotate, constrain ratio, reset and return a non-destructive crop', (tester) async {
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawRect(const Rect.fromLTWH(0, 0, 400, 200), Paint()..color = Colors.red);
    final picture = recorder.endRecording();
    late ui.Image image;
    await tester.runAsync(() async { image = await picture.toImage(400, 200); });
    PhotoCrop? result;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) => Scaffold(body: TextButton(
      child: const Text('Open'), onPressed: () async {
        result = await Navigator.push(context, MaterialPageRoute<PhotoCrop>(builder: (_) => CropEditor(image: image)));
      },
    )))));
    await tester.tap(find.text('Open')); await tester.pumpAndSettle();
    await tester.tap(find.text('1:1')); await tester.pump();
    await tester.tap(find.text('Rotate 90°')); await tester.pump();
    await tester.tap(find.text('Done')); await tester.pumpAndSettle();
    expect(result!.turns, 1);
    expect(result!.ratio(400, 200), closeTo(1, .001));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    image.dispose(); picture.dispose();
  });
}
