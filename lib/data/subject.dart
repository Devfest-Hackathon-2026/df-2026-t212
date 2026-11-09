import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/renderer.dart';

/// The outline of the thing under a tap, found on the device.
class Subject {
  static const _ch = MethodChannel('afterhue/subject');

  /// Polygons in 0..1 of [px] around what lies at [at]; empty when nothing
  /// stands out there, null when the phone cannot look.
  static Future<List<List<List<double>>>?> outline(Rgba px, Offset at) async {
    try {
      final r = await _ch.invokeMethod<List<Object?>>('outline', {
        'rgba': px.pixels,
        'w': px.width,
        'h': px.height,
        'x': at.dx,
        'y': at.dy,
      });
      return (r ?? const [])
          .whereType<List>()
          .map((p) => p.whereType<List>().map((q) => q.cast<num>().map((v) => v.toDouble()).toList()).toList())
          .where((p) => p.length >= 3)
          .toList();
    } catch (e) {
      debugPrint('subject: $e');
      return null;
    }
  }
}
