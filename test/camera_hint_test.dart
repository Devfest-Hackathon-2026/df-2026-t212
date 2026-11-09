import 'package:afterhue/ui/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('color picking guidance stays visible in both landscape directions', (tester) async {
    tester.view.physicalSize = const Size(402, 874);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const channel = MethodChannel('afterhue/camera');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'start') return {'texture': 1, 'width': 600, 'height': 800};
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const MaterialApp(home: CameraScreen()));
    await tester.pumpAndSettle();
    final hint = find.text('Touch and hold a color in the preview to keep it');
    for (final degrees in [90, 0, 180, 90]) {
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        'afterhue/camera', const StandardMethodCodec().encodeMethodCall(MethodCall('orientation', degrees)), (_) {});
      await tester.pumpAndSettle();
      expect(hint, findsOneWidget);
      final opacity = tester.widget<AnimatedOpacity>(find.ancestor(of: hint, matching: find.byType(AnimatedOpacity)).first);
      expect(opacity.opacity, 1, reason: 'Hint must remain visible at $degrees degrees.');
      final rect = tester.getRect(hint);
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(402));
      expect(rect.top, greaterThanOrEqualTo(0));
      expect(rect.bottom, lessThanOrEqualTo(874));
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
}
