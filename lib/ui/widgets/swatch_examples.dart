import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;

import '../../core/recipe.dart';
import '../../core/renderer.dart';
import '../../data/photo_source.dart';
import '../../data/store.dart';
import 'common.dart';

/// The gallery palette in its original order, filled to three with samples.
/// Cuts and softening use the same renderer as the gallery swatches.
class SwatchExamples extends StatelessWidget {
  const SwatchExamples({super.key, required this.style});
  final SwatchStyle style;
  static final Future<List<_Example>> _examples = _load();

  static Uint8List _png(Rgba p) => img.encodePng(img.Image.fromBytes(
    width: p.width, height: p.height, bytes: p.pixels.buffer, numChannels: 4,
  ));

  static Future<List<_Example>> _load() async {
    return Future.wait(['lantern', 'hydrangea', 'taxi'].map((name) async {
      final bytes = (await rootBundle.load('assets/samples/$name.jpg')).buffer.asUint8List();
      final photo = await decodeRgba(bytes, maxSide: 512);
      return Isolate.run(() {
        final peak = huePeaks(toLab(photo), top: 8).firstWhere((p) => p.meanChroma > .04);
        final hue = (peak.from + peak.to) / 2 * math.pi / 180;
        final color = KeptColor(l: peak.meanL, a: peak.meanChroma * math.cos(hue), b: peak.meanChroma * math.sin(hue));
        final patch = colorPatch(photo, color);
        return _Example(color,
          patch == null ? null : _png(patch),
          patch == null ? null : _png(boxBlur(patch, math.max(1, patch.width ~/ 10), passes: 3)),
        );
      });
    }));
  }

  Widget _strip(List<PaletteEntry> palette, List<_Example> examples) => SizedBox(
    height: 40,
    child: ListView.separated(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.only(right: 8, top: 4, bottom: 6),
      itemCount: math.max(3, palette.length),
      separatorBuilder: (_, _) => const SizedBox(width: 8),
      itemBuilder: (_, index) {
        if (index < palette.length) {
          final entry = palette[index];
          return Swatch(entry.color, size: 30, from: entry.source);
        }
        final i = index - palette.length;
        final example = i < examples.length ? examples[i] : null;
        final color = example?.color ?? keptColorFromHex(const ['#DA392E', '#558EC9', '#F4C442'][i])!;
        return Swatch(color, size: 30, texture: switch (style) {
          SwatchStyle.flat => null,
          SwatchStyle.photo => example?.photo == null ? null : Image.memory(example!.photo!, fit: BoxFit.cover, gaplessPlayback: true),
          SwatchStyle.soft => example?.soft == null ? null : Image.memory(example!.soft!, fit: BoxFit.cover, gaplessPlayback: true),
        });
      },
    ),
  );

  @override
  Widget build(BuildContext context) => ExcludeSemantics(child: ListenableBuilder(
    listenable: Store.instance,
    builder: (_, _) {
      final palette = Store.instance.palette;
      if (palette.length >= 3) return _strip(palette, const []);
      return FutureBuilder<List<_Example>>(
        future: _examples,
        builder: (_, snapshot) => _strip(palette, snapshot.data ?? const []),
      );
    },
  ));

}

class _Example {
  const _Example(this.color, this.photo, this.soft);
  final KeptColor color;
  final Uint8List? photo, soft;
}
