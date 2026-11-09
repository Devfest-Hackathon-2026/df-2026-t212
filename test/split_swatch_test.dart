import 'package:afterhue/core/recipe.dart';
import 'package:afterhue/ui/widgets/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('map swatch gives every color a visible area', (tester) async {
    final colors = [KeptColor(l: 0.6, a: 0.15, b: 0.05), KeptColor(l: 0.6, a: -0.1, b: 0.1)];
    await tester.pumpWidget(MaterialApp(home: Center(child: SplitSwatch(colors, size: 20))));
    for (final color in colors) {
      final finder = find.byWidgetPredicate((w) => w is ColoredBox && w.color == colorOf(color));
      expect(tester.getSize(finder).height, 16);
      expect(tester.getSize(finder).width, 8);
    }
  });
}
