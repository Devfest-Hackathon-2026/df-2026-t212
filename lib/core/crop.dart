import 'dart:math' as math;

/// Crop bounds are normalized in the upright, rotated frame. Selection masks
/// always remain in source coordinates; cropping never rewrites their geometry.
class PhotoCrop {
  const PhotoCrop({this.left = 0, this.top = 0, this.right = 1, this.bottom = 1,
    this.turns = 0, this.angle = 0});
  final double left, top, right, bottom, angle;
  final int turns;
  double get width => right - left;
  double get height => bottom - top;
  double rotatedWidth(num w, num h) => (turns.isOdd ? h : w).toDouble();
  double rotatedHeight(num w, num h) => (turns.isOdd ? w : h).toDouble();
  double ratio(num w, num h) => rotatedWidth(w, h) * width / (rotatedHeight(w, h) * height);
  double get radians => (turns * 90 + angle) * math.pi / 180;
  double zoom(num w, num h) {
    final rw = rotatedWidth(w, h), rh = rotatedHeight(w, h);
    final c = math.cos(angle * math.pi / 180).abs(), s = math.sin(angle * math.pi / 180).abs();
    return math.max((rw * c + rh * s) / rw, (rh * c + rw * s) / rh);
  }
  /// Inverse mapping from cropped normalized coordinates to source pixels.
  (double, double) sourcePoint(double x, double y, int w, int h) {
    final rw = rotatedWidth(w, h), rh = rotatedHeight(w, h), z = zoom(w, h);
    final dx = ((left + x * width) * rw - rw / 2) / z;
    final dy = ((top + y * height) * rh - rh / 2) / z;
    final c = math.cos(radians), s = math.sin(radians);
    return (c * dx + s * dy + w / 2, -s * dx + c * dy + h / 2);
  }
  (double, double) outputPoint(double x, double y, int w, int h) {
    final rw = rotatedWidth(w, h), rh = rotatedHeight(w, h), z = zoom(w, h);
    final dx = (x - .5) * w, dy = (y - .5) * h;
    final c = math.cos(radians), s = math.sin(radians);
    return (((c * dx - s * dy) * z / rw + .5 - left) / width,
      ((s * dx + c * dy) * z / rh + .5 - top) / height);
  }
  Map<String, dynamic> toJson() => {'rect': [left, top, right, bottom], 'turns': turns, 'angle': angle};
  factory PhotoCrop.fromJson(Map<String, dynamic> json) {
    final rect = ((json['rect'] as List?) ?? [0, 0, 1, 1]).cast<num>();
    if (rect.length != 4 || rect.any((v) => !v.isFinite) || rect[0] < 0 || rect[1] < 0 ||
        rect[2] > 1 || rect[3] > 1 || rect[2] - rect[0] < .05 || rect[3] - rect[1] < .05) {
      throw const FormatException('Crop must be a normalized rectangle at least 5% wide and high.');
    }
    final angle = (json['angle'] as num?)?.toDouble() ?? 0;
    if (!angle.isFinite || angle.abs() > 45) throw const FormatException('Angle must be -45..45 degrees.');
    final turns = (json['turns'] as num?) ?? 0;
    if (!turns.isFinite || turns != turns.roundToDouble() || turns < 0 || turns > 3) {
      throw const FormatException('Quarter turns must be an integer from 0 to 3.');
    }
    return PhotoCrop(left: rect[0].toDouble(), top: rect[1].toDouble(), right: rect[2].toDouble(),
      bottom: rect[3].toDouble(), turns: turns.toInt(), angle: angle);
  }
}
