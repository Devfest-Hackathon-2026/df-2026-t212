import 'dart:typed_data';
import 'package:afterhue/core/crop.dart';
import 'package:afterhue/core/recipe.dart';
import 'package:afterhue/core/renderer.dart';
import 'package:afterhue/agent/agent.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('rotation and crop use source coordinates and reset is lossless', () {
    final photo = Rgba(4, 2, Uint8List.fromList([for (var i = 0; i < 8; i++) ...[i * 25, 0, 0, 255]]));
    final full = cropImage(photo, const PhotoCrop());
    expect(full.pixels, photo.pixels);
    final rotated = cropImage(photo, const PhotoCrop(turns: 1));
    expect((rotated.width, rotated.height), (2, 4));
    expect(rotated.pixels[0], photo.pixels[4 * 4]);
    expect(rotated.pixels[4], photo.pixels[0]);
    final cropped = cropImage(photo, const PhotoCrop(left: .5));
    expect((cropped.width, cropped.height), (2, 2));
    expect(cropped.pixels[0], photo.pixels[8]);
    final straightened = cropImage(photo, const PhotoCrop(angle: 30));
    expect([for (var i = 3; i < straightened.pixels.length; i += 4) straightened.pixels[i]].every((v) => v == 255), isTrue);
  });

  test('saturation changes kept colors without changing their mask or mono region', () {
    final source = Rgba(20, 10, Uint8List.fromList([for (var i = 0; i < 200; i++) ...(i % 20 < 10 ? [200, 50, 60, 255] : [30, 90, 210, 255])]));
    final recipe = Recipe(colors: [sampleColor(toLab(source), .2, .5)], ambience: 0, contrast: 0);
    final before = render(source, recipe);
    recipe.saturation = 0;
    final after = render(source, recipe);
    expect(after.weight, before.weight);
    expect(after.image.pixels[4 * 15], before.image.pixels[4 * 15]);
    expect((after.image.pixels[0] - after.image.pixels[1]).abs(), lessThanOrEqualTo(1));
    final session = EditSession(source, start: recipe);
    expect(session.execute('set_saturation', {'value': 1.5}), 'ok');
    expect(session.recipe.saturation, 1.5);
    expect(session.execute('set_saturation', {'value': double.nan}), startsWith('error:'));
    expect(session.execute('set_crop', {'rect': [.1, .1, .9, .9], 'turns': 1, 'angle': 5}), startsWith('ok'));
    session.execute('set_crop', {'angle': 5});
    expect(session.recipe.crop!.left, .1);
    final restored = Recipe.fromJson(session.recipe.toJson());
    expect(restored.crop!.angle, 5);
    expect(restored.saturation, 1.5);
    expect(session.execute('set_crop', {'rect': [.9, 0, .1, 1]}), startsWith('error:'));
    expect(session.execute('set_crop', {'turns': double.nan}), startsWith('error:'));
    session.execute('set_crop', {'reset': true});
    expect(session.recipe.crop, isNull);
  });
}
