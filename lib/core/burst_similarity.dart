import 'dart:math' as math;
import 'dart:typed_data';
import 'renderer.dart';

/// A small spatial RGB signature: both composition and color must match.
Uint8List burstSignature(Rgba image) {
  const side = 16;
  final out = Uint8List(side * side * 3);
  for (var y = 0; y < side; y++) {
    for (var x = 0; x < side; x++) {
      final x0 = x * image.width ~/ side, y0 = y * image.height ~/ side;
      final x1 = math.max(x0 + 1, (x + 1) * image.width ~/ side);
      final y1 = math.max(y0 + 1, (y + 1) * image.height ~/ side);
      final sum = [0, 0, 0];
      var count = 0;
      for (var py = y0; py < y1; py++) {
        for (var px = x0; px < x1; px++) {
          final i = (py * image.width + px) * 4;
          for (var c = 0; c < 3; c++) { sum[c] += image.pixels[i + c]; }
          count++;
        }
      }
      for (var c = 0; c < 3; c++) { out[(y * side + x) * 3 + c] = sum[c] ~/ count; }
    }
  }
  return out;
}

/// Deliberately conservative. Plain walls/black frames lack enough structure
/// to establish that two photos show the same thing, so leave them separate.
bool similarBurst(Uint8List a, Uint8List b) {
  if (a.length != 768 || b.length != a.length) return false;
  var colorDifference = 0.0, meanA = 0.0, meanB = 0.0;
  final ya = <double>[], yb = <double>[];
  for (var i = 0; i < a.length; i += 3) {
    for (var c = 0; c < 3; c++) { colorDifference += (a[i+c] - b[i+c]).abs(); }
    ya.add(a[i] * .299 + a[i+1] * .587 + a[i+2] * .114);
    yb.add(b[i] * .299 + b[i+1] * .587 + b[i+2] * .114);
    meanA += ya.last; meanB += yb.last;
  }
  if (colorDifference / a.length > 9) return false;
  meanA /= ya.length; meanB /= yb.length;
  var varianceA = 0.0, varianceB = 0.0, covariance = 0.0;
  for (var i = 0; i < ya.length; i++) {
    final da = ya[i] - meanA, db = yb[i] - meanB;
    varianceA += da * da; varianceB += db * db; covariance += da * db;
  }
  if (varianceA / ya.length < 144 || varianceB / yb.length < 144) return false;
  return covariance / math.sqrt(varianceA * varianceB) >= .97;
}

class PhotoGroup {
  PhotoGroup({required this.id, required this.cover, required this.members, this.manual = false});
  final String id;
  String cover;
  final List<String> members;
  bool manual;
  Map<String, dynamic> toJson() => {'id': id, 'cover': cover, 'members': members, 'manual': manual};
  factory PhotoGroup.fromJson(Map<String, dynamic> j) => PhotoGroup(id: j['id'] as String,
    cover: j['cover'] as String, members: (j['members'] as List).cast<String>(), manual: j['manual'] == true);
}
