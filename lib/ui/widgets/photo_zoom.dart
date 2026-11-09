import 'dart:math' as math;
import 'package:flutter/widgets.dart';

/// Keeps the fitted photo as the minimum zoom, centered on any axis where
/// it is smaller than the viewport. Both Area and InteractiveViewer use it.
class PhotoZoomController extends TransformationController {
  static const maxScale = 16.0;
  Size _viewport = Size.zero;
  Rect _photo = Rect.zero;

  void setGeometry(Size viewport, Rect photo) {
    _viewport = viewport;
    _photo = photo;
  }

  void settle() => value = value;

  @override
  set value(Matrix4 next) {
    // Use the actual image plane: getMaxScaleOnAxis also includes Z = 1,
    // which can hide a matrix that has shrunk below the fitted size.
    final planarScale = math.sqrt(next.entry(0, 0) * next.entry(0, 0) + next.entry(1, 0) * next.entry(1, 0));
    final scale = planarScale.isFinite ? planarScale.clamp(1.0, maxScale) : 1.0;
    final matrix = Matrix4.diagonal3Values(scale, scale, 1);
    if (scale > 1 && !_viewport.isEmpty) {
      double position(double offset, double viewport, double start, double extent) {
        if (extent * scale <= viewport) return viewport * (1 - scale) / 2;
        return offset.clamp(viewport - (start + extent) * scale, -start * scale);
      }
      final offset = next.getTranslation();
      matrix.setTranslationRaw(
        position(offset.x, _viewport.width, _photo.left, _photo.width),
        position(offset.y, _viewport.height, _photo.top, _photo.height),
        0,
      );
    }
    if (matrix != super.value) super.value = matrix;
  }
}
