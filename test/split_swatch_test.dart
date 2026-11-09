import 'package:afterhue/core/recipe.dart';
import 'package:afterhue/ui/widgets/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('map swatch gives every color its own slice', (tester) async {
    final colors = [
      KeptColor(l: 0.6, a: 0.15, b: 0.05),
      KeptColor(l: 0.6, a: -0.1, b: 0.1),
    ];
    await tester.pumpWidget(
      MaterialApp(home: Center(child: SplitSwatch(colors, size: 20))),
    );
    final paint = tester.widget<CustomPaint>(
      find.byWidgetPredicate(
        (w) => w is CustomPaint && w.painter is PiePainter,
      ),
    );
    expect((paint.painter! as PiePainter).colors, [
      for (final c in colors) colorOf(c),
    ]);
    expect(tester.getSize(find.byWidget(paint)), const Size(16, 16));
  });
}
