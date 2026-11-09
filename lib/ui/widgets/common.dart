import 'dart:math' as math;
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/recipe.dart';
import '../../core/renderer.dart';
import '../../data/places.dart';
import '../../data/store.dart';
import '../theme.dart';
import 'glyphs.dart';

export 'glyphs.dart';

Color colorOf(KeptColor c) {
  final rgb = oklabToRgb8(c.l, c.a, c.b);
  return Color.fromARGB(255, rgb[0], rgb[1], rgb[2]);
}

/// [c] lifted to at least [minL] lightness, same hue: a dark kept color
/// (navy, deep red) still reads as itself on a dark ground.
Color lightColorOf(KeptColor c, {double minL = 0.74}) {
  if (c.l >= minL) return colorOf(c);
  final rgb = oklabToRgb8(minL, c.a, c.b);
  return Color.fromARGB(255, rgb[0], rgb[1], rgb[2]);
}

/// Frosted layer for things that float over photos and the map.
class Glass extends StatelessWidget {
  const Glass({
    super.key,
    required this.child,
    this.radius = 22,
    this.padding = EdgeInsets.zero,
    this.dark = false,
    this.clear = false,
    this.dock = false,
  });
  final Widget child;
  final double radius;
  final EdgeInsets padding;
  final bool dark;
  final bool dock;

  /// Thinner, for a panel that lies over a photo.
  final bool clear;

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(radius);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: r,
        boxShadow: [
          BoxShadow(
            color: dark ? const Color(0x26000000) : const Color(0x12000000),
            blurRadius: 20,
            offset: const Offset(0, 6),
            spreadRadius: -5,
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: r,
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: dark ? 12 : (dock ? 14 : 24), sigmaY: dark ? 12 : (dock ? 14 : 24)),
          blendMode: BlendMode.src,
          child: Container(
            padding: padding,
            decoration: BoxDecoration(
              borderRadius: r,
              border: Border.all(color: dark ? const Color(0x26FFFFFF) : const Color(0x70FFFFFF), width: 0.6),
              color: dark
                  ? const Color(0x38222224)
                  : clear
                  ? const Color(0x40FFFFFF)
                  : dock ? const Color(0x94FFFFFF) : const Color(0x66FFFFFF),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// A kept color, as a small rounded square. Given the photo it came [from],
/// it is filled with a piece of that photo where the color lives, so it has
/// the photo's own texture; the flat color shows while that piece loads.
class Swatch extends StatelessWidget {
  const Swatch(this.color, {super.key, this.size = 22, this.selected = false, this.onTap, this.onLongPress, this.from, this.texture});
  final KeptColor color;
  final double size;
  final bool selected;
  final VoidCallback? onTap, onLongPress;
  final PhotoItem? from;
  final Widget? texture;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Motion.settle,
        width: size,
        height: size,
        padding: EdgeInsets.all(selected ? 2.5 : 0),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(size * 0.3),
          border: Border.all(color: selected ? Neutral.primary : Colors.transparent, width: 1.2),
        ),
        child: DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(size * (selected ? 0.22 : 0.3)),
            border: Border.all(color: const Color(0x14000000), width: 0.6),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(size * (selected ? 0.22 : 0.3)),
            child: ColoredBox(
              color: colorOf(color),
              child: texture ?? (from == null ? const SizedBox.expand() : PhotoPatch(from!, color)),
            ),
          ),
        ),
      ),
    );
  }
}

/// The piece of [item] where [color] lives, filling its box; nothing until
/// it is ready, then it fades in.
class PhotoPatch extends StatelessWidget {
  const PhotoPatch(this.item, this.color, {super.key});
  final PhotoItem item;
  final KeptColor color;

  @override
  Widget build(BuildContext context) {
    final store = Store.instance;
    final ready = store.patchReady(item, color);
    return FutureBuilder<ui.Image?>(
      initialData: ready?.image,
      future: store.patch(item, color),
      builder: (_, snap) => AnimatedOpacity(
        opacity: snap.data == null ? 0 : 1,
        duration: const Duration(milliseconds: 200),
        curve: Motion.settle,
        child: snap.data == null
            ? const SizedBox.expand()
            : RawImage(image: snap.data, fit: BoxFit.cover, width: double.infinity, height: double.infinity),
      ),
    );
  }
}

/// The soft shadow under marks drawn on a photo tile (heart, palette).
/// For an [AnimatedSwitcher]: the new content settles up into place as it
/// fades in, and the old one sinks a little as it goes.
Widget softSwitch(Widget child, Animation<double> a) => FadeTransition(
  opacity: a,
  child: SlideTransition(
    position: Tween(begin: const Offset(0, 0.12), end: Offset.zero).animate(a),
    child: child,
  ),
);

const tileShadow = BoxShadow(color: Color(0x2E000000), blurRadius: 6, offset: Offset(0, 0.5));

/// The favorite mark on a tile: white, with a soft shadow so it reads on any
/// photo. The tile's palette carries the color.
class TileHeart extends StatelessWidget {
  const TileHeart({super.key, this.size = 16});
  final double size;

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        Transform.translate(
          offset: tileShadow.offset,
          child: ImageFiltered(
            imageFilter: ui.ImageFilter.blur(sigmaX: tileShadow.blurSigma, sigmaY: tileShadow.blurSigma),
            child: Glyph(G.heartFill, size: size, color: tileShadow.color, weight: 1),
          ),
        ),
        Glyph(G.heartFill, size: size, color: Colors.white, weight: 1),
      ],
    );
  }
}

/// The signature motion: a photo appears in black and white and its kept
/// colors come back. [t] goes 0 -> 1.
class ColorReturn extends StatelessWidget {
  const ColorReturn({super.key, required this.t, required this.child});
  final double t;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (t >= 1) return child;
    final s = Curves.easeInOutCubic.transform(t.clamp(0, 1));
    const lr = 0.2126, lg = 0.7152, lb = 0.0722;
    final m = <double>[
      lr + (1 - lr) * s,
      lg - lg * s,
      lb - lb * s,
      0,
      0,
      lr - lr * s,
      lg + (1 - lg) * s,
      lb - lb * s,
      0,
      0,
      lr - lr * s,
      lg - lg * s,
      lb + (1 - lb) * s,
      0,
      0,
      0,
      0,
      0,
      1,
      0,
    ];
    return ColorFiltered(colorFilter: ColorFilter.matrix(m), child: child);
  }
}

/// Plays [ColorReturn] once when first built.
class ColorReturnOnce extends StatefulWidget {
  const ColorReturnOnce({
    super.key,
    required this.child,
    this.play = true,
    this.duration = const Duration(milliseconds: 1400),
    this.delay = Duration.zero,
  });
  final Widget child;
  final bool play;
  final Duration duration, delay;

  @override
  State<ColorReturnOnce> createState() => _ColorReturnOnceState();
}

class _ColorReturnOnceState extends State<ColorReturnOnce> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: widget.duration,
    value: widget.play ? 0 : 1,
  );

  @override
  void initState() {
    super.initState();
    if (widget.play) {
      Future.delayed(widget.delay, () => mounted ? _c.forward() : null);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _c,
    builder: (_, child) => ColorReturn(t: _c.value, child: child!),
    child: widget.child,
  );
}

/// A developed photo from the render cache.
class DevelopedImage extends StatefulWidget {
  const DevelopedImage(
    this.item, {
    super.key,
    this.size = 480,
    this.fit = BoxFit.cover,
    this.recipe,
    this.alignment,
    this.placeholder,
  });
  final PhotoItem item;
  final Widget? placeholder;
  final int size;
  final BoxFit fit;
  final Recipe? recipe;
  final Alignment? alignment;

  @override
  State<DevelopedImage> createState() => _DevelopedImageState();
}

class _DevelopedImageState extends State<DevelopedImage> {
  // Only publish files after their first frame has decoded. In particular,
  // another Hero/destination must never choose an undecoded upgrade as its
  // own fallback. Keep the small version available if a large image is evicted.
  static final _ready = <String, File>{};
  static final _thumbnails = <String, ({File file, int size})>{};
  File? _display;
  String? _sig, _base;
  int _request = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _load();
  }

  @override
  void didUpdateWidget(DevelopedImage old) {
    super.didUpdateWidget(old);
    _load();
  }

  void _load() {
    final recipe = widget.recipe ?? widget.item.edit;
    final base = '${widget.item.id}|${recipe?.signature}';
    final sig = '$base@${widget.size}';
    if (_sig == sig) return;
    final samePhoto = _base == base;
    _sig = sig;
    _base = base;
    final request = ++_request;
    if (!samePhoto) _display = _thumbnails[base]?.file;
    if (recipe == null) { _display = null; return; }
    final cached = _ready.remove(sig);
    if (cached != null) _ready[sig] = cached;
    final size = widget.size;
    (cached == null ? Store.instance.rendered(widget.item, size, recipe: recipe) : SynchronousFuture<File?>(cached))
        .then((file) async {
      if (file == null || !mounted || request != _request) return;
      var decoded = true;
      await precacheImage(FileImage(file), context, onError: (_, _) => decoded = false);
      if (!decoded || !mounted || request != _request) return;
      _ready[sig] = file;
      if ((_thumbnails[base]?.size ?? size + 1) >= size) {
        _thumbnails.remove(base);
        _thumbnails[base] = (file: file, size: size);
      }
      while (_ready.length > 256) { _ready.remove(_ready.keys.first); }
      while (_thumbnails.length > 256) { _thumbnails.remove(_thumbnails.keys.first); }
      setState(() => _display = file);
    }).catchError((Object _) {
      // Keep the already visible thumbnail if a larger render is unavailable.
    });
  }

  @override
  Widget build(BuildContext context) {
    final file = _display;
    if (file == null) return widget.placeholder ?? const ColoredBox(color: Neutral.hairline, child: SizedBox.expand());
    return Image.file(
      file,
      // A new photo must never inherit a previous photo's decoded frame.
      key: ValueKey(_base),
      fit: widget.fit,
      alignment: widget.alignment ?? focusAlignment(widget.item),
      width: double.infinity,
      height: double.infinity,
      gaplessPlayback: true,
    );
  }
}

/// A Hero's way from one place to the other: straight, not the arc
/// Material draws.
RectTween straightRect(Rect? begin, Rect? end) => RectTween(begin: begin, end: end);

/// The untouched photo, in black and white while it waits to be developed.
class OriginalImage extends StatefulWidget {
  const OriginalImage(this.item, {super.key, this.size = 420, this.mono = true, this.fit = BoxFit.cover});
  final PhotoItem item;
  final int size;
  final bool mono;
  final BoxFit fit;

  @override
  State<OriginalImage> createState() => _OriginalImageState();
}

class _OriginalImageState extends State<OriginalImage> {
  static final Map<String, Future<Uint8List?>> _cache = {};
  late Future<Uint8List?> _f = _load();

  Future<Uint8List?> _load() =>
      _cache['${widget.item.id}_${widget.size}'] ??= Store.instance.original(widget.item, widget.size);

  @override
  void didUpdateWidget(OriginalImage old) {
    super.didUpdateWidget(old);
    if (old.item.id != widget.item.id || old.size != widget.size) _f = _load();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: _f,
      builder: (context, snap) {
        final b = snap.data;
        if (b == null) {
          return const ColoredBox(color: Neutral.hairline, child: SizedBox.expand());
        }
        final image = Image.memory(
          b,
          fit: widget.fit,
          width: double.infinity,
          height: double.infinity,
          gaplessPlayback: true,
        );
        return widget.mono ? ColorReturn(t: 0, child: image) : image;
      },
    );
  }
}

/// Crop squares around the subject, not the center.
Alignment focusAlignment(PhotoItem it) {
  final f = it.edit?.focus;
  if (f == null || f.length < 2) return Alignment.center;
  return Alignment((f[0].clamp(0.0, 1.0) * 2 - 1), (f[1].clamp(0.0, 1.0) * 2 - 1));
}

/// Text-only button, achromatic.
class TextAction extends StatelessWidget {
  const TextAction(this.label, {super.key, this.onTap, this.color, this.style});
  final String label;
  final VoidCallback? onTap;
  final Color? color;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap == null
          ? null
          : () {
              Haptics.tick();
              onTap!();
            },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        child: Text(
          label,
          style: (style ?? Txt.label).copyWith(
            color: (color ?? Neutral.primary).withValues(alpha: (color ?? Neutral.primary).a * (onTap == null ? 0.35 : 1)),
          ),
        ),
      ),
    );
  }
}

/// An icon action for states a word cannot show at a glance (favorite on or off).
class IconAction extends StatelessWidget {
  const IconAction(
    this.icon, {
    super.key,
    required this.label,
    this.onTap,
    this.activeIcon,
    this.active = false,
    this.busy = false,
  });
  final G icon;
  final G? activeIcon;
  final bool active;

  /// Turns while the work behind the tap is under way, so the press does
  /// not look unanswered; taps wait until it is done.
  final bool busy;

  /// For screen readers.
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      selected: activeIcon == null ? null : active,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap == null || busy
            ? null
            : () {
                Haptics.tick();
                onTap!();
              },
        child: SizedBox(
          width: 44,
          height: 44,
          child: Center(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              transitionBuilder: (c, a) => ScaleTransition(
                scale: Tween(begin: 0.6, end: 1.0).animate(CurvedAnimation(parent: a, curve: Motion.settle)),
                child: FadeTransition(opacity: a, child: c),
              ),
              child: busy
                  ? const SizedBox(
                      key: ValueKey('busy'),
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 1.8, color: Neutral.primary),
                    )
                  : Glyph(
                      active && activeIcon != null ? activeIcon! : icon,
                      key: ValueKey(active),
                      size: 24,
                      color: onTap == null ? Neutral.tertiary : Neutral.primary,
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

class PrimaryButton extends StatelessWidget {
  const PrimaryButton(this.label, {super.key, required this.onTap, this.secondary = false});
  final String label;
  final VoidCallback onTap;
  final bool secondary;

  @override
  Widget build(BuildContext context) {
    return _Pressable(
      onTap: () {
        Haptics.light();
        onTap();
      },
      child: Container(
        height: 52,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: secondary ? Colors.transparent : Neutral.primary,
          borderRadius: BorderRadius.circular(16),
          border: secondary ? Border.all(color: Neutral.hairline) : null,
        ),
        child: Text(label, style: Txt.label.copyWith(color: secondary ? Neutral.primary : Neutral.surface)),
      ),
    );
  }
}

/// Shrinks a little under the finger, springs back.
class _Pressable extends StatefulWidget {
  const _Pressable({required this.child, required this.onTap});
  final Widget child;
  final VoidCallback onTap;

  @override
  State<_Pressable> createState() => _PressableState();
}

class _PressableState extends State<_Pressable> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _down = true),
      onTapCancel: () => setState(() => _down = false),
      onTapUp: (_) => setState(() => _down = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _down ? 0.97 : 1,
        duration: const Duration(milliseconds: 140),
        curve: Motion.settle,
        child: widget.child,
      ),
    );
  }
}

/// Small monospace line like "2026-10-14 17:42 · 35.6581 N 139.7017 E".
String metaLine(PhotoItem it) {
  final t = it.taken;
  String two(int v) => v.toString().padLeft(2, '0');
  final date = '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  if (!it.hasLocation) return date;
  // A name reads better than numbers; numbers only where no name is known.
  if (placeNear(it.lat, it.lng) case final name?) return '$date  ·  $name';
  final lat = '${it.lat!.abs().toStringAsFixed(4)} ${it.lat! >= 0 ? 'N' : 'S'}';
  final lng = '${it.lng!.abs().toStringAsFixed(4)} ${it.lng! >= 0 ? 'E' : 'W'}';
  return '$date  ·  $lat $lng';
}

const months = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];
const monthsShort = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// Hairline divider.
class Hairline extends StatelessWidget {
  const Hairline({super.key});
  @override
  Widget build(BuildContext context) => Container(height: 0.6, color: Neutral.hairline);
}

/// A split swatch for photos with several kept colors (map markers, grid dots).
/// Given the photo each color came [from], every slice is a piece of that
/// photo, as a [Swatch] is; flat colors show while the pieces are cut.
class SplitSwatch extends StatelessWidget {
  const SplitSwatch(this.colors, {super.key, this.size = 18, this.border = 2, this.from})
    : assert(from == null || from.length == colors.length);
  final List<KeptColor> colors;
  final double size, border;
  final List<PhotoItem>? from;

  @override
  Widget build(BuildContext context) {
    // A dot, not a tile: a place on a map is a point. Its colors are cut
    // like a pie from twelve o'clock, so each one keeps an equal share.
    return Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(
        color: Neutral.surface,
        shape: BoxShape.circle,
        boxShadow: [BoxShadow(color: Color(0x26000000), blurRadius: 6, offset: Offset(0, 1.5))],
      ),
      padding: EdgeInsets.all(border),
      child: from == null
          ? CustomPaint(size: Size.square(size - border * 2), painter: PiePainter([for (final c in colors) colorOf(c)]))
          : _PhotoPie(colors, from!, size: size - border * 2),
    );
  }
}

/// A pie whose slices are pieces of their photos. The pieces are cut once
/// and kept, so a marker redrawn every frame of playback never waits on them.
class _PhotoPie extends StatefulWidget {
  const _PhotoPie(this.colors, this.from, {required this.size});
  final List<KeptColor> colors;
  final List<PhotoItem> from;
  final double size;

  @override
  State<_PhotoPie> createState() => _PhotoPieState();
}

class _PhotoPieState extends State<_PhotoPie> {
  bool _asked = false;

  @override
  void didUpdateWidget(_PhotoPie old) {
    super.didUpdateWidget(old);
    if (!listEquals(old.from, widget.from) || !listEquals(old.colors, widget.colors)) {
      _asked = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = Store.instance;
    final ready = [for (var i = 0; i < widget.colors.length; i++) store.patchReady(widget.from[i], widget.colors[i])];
    if (!_asked && ready.contains(null)) {
      _asked = true;
      Future.wait([for (var i = 0; i < widget.colors.length; i++) store.patch(widget.from[i], widget.colors[i])])
          .then((_) {
            if (mounted) setState(() {});
          });
    }
    final flat = [for (final c in widget.colors) colorOf(c)];
    final images = [for (final r in ready) r?.image];
    final textured = ready.every((r) => r != null) && images.any((i) => i != null);
    return SizedBox.square(
      dimension: widget.size,
      child: Stack(
        fit: StackFit.expand,
        children: [
          CustomPaint(painter: PiePainter(flat)),
          AnimatedOpacity(
            opacity: textured ? 1 : 0,
            duration: const Duration(milliseconds: 200),
            curve: Motion.settle,
            child: CustomPaint(painter: PiePainter(flat, images: images)),
          ),
        ],
      ),
    );
  }
}

class PiePainter extends CustomPainter {
  PiePainter(this.colors, {this.images});
  final List<Color> colors;

  /// A piece of the photo for each slice, where there is one.
  final List<ui.Image?>? images;

  @override
  void paint(Canvas canvas, Size s) {
    if (colors.isEmpty) return;
    final rect = Offset.zero & s;
    final sweep = 2 * 3.141592653589793 / colors.length;
    final p = Paint()..isAntiAlias = true;
    for (var i = 0; i < colors.length; i++) {
      p.color = colors[i];
      p.shader = null;
      final image = images?[i];
      if (image != null) {
        // The piece covers the whole dot, as a photo fills its frame.
        final k = math.max(s.width / image.width, s.height / image.height);
        final m = Matrix4.identity()
          ..translateByDouble((s.width - image.width * k) / 2, (s.height - image.height * k) / 2, 0, 1)
          ..scaleByDouble(k, k, 1, 1);
        p.shader = ImageShader(image, TileMode.clamp, TileMode.clamp, m.storage, filterQuality: FilterQuality.medium);
      }
      // Overlap a hair so no seam of white shows between slices.
      canvas.drawArc(rect, -3.141592653589793 / 2 + sweep * i, sweep + (i == colors.length - 1 ? 0 : 0.02), true, p);
    }
  }

  @override
  bool shouldRepaint(PiePainter old) => !listEquals(old.colors, colors) || !listEquals(old.images, images);
}

/// One row of a [showPopMenu].
class PopItem {
  const PopItem(this.label, this.onTap, {this.quiet = false, this.divided = false});
  final String label;

  /// Null greys the row out.
  final VoidCallback? onTap;

  /// Said softer: for the row that takes something away.
  final bool quiet;

  /// A hairline above this row.
  final bool divided;
}

/// A small menu that grows out of the control at [from], top right to top
/// right, instead of rising from the bottom of the screen.
Future<void> showPopMenu(BuildContext context, {required Rect from, required List<PopItem> items}) {
  return Navigator.of(context).push(_PopRoute(from, items));
}

class _PopRoute extends PopupRoute<void> {
  _PopRoute(this.from, this.items);
  final Rect from;
  final List<PopItem> items;

  @override
  Color? get barrierColor => const Color(0x14000000);
  @override
  bool get barrierDismissible => true;
  @override
  String? get barrierLabel => 'Close menu';
  @override
  Duration get transitionDuration => const Duration(milliseconds: 240);
  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 160);

  @override
  Widget buildPage(BuildContext context, Animation<double> a, Animation<double> b) {
    final size = MediaQuery.sizeOf(context);
    return Stack(
      children: [
        Positioned(
          top: from.bottom + 2 + items.length * 52 < size.height - MediaQuery.paddingOf(context).bottom
              ? from.bottom + 2 : null,
          bottom: from.bottom + 2 + items.length * 52 < size.height - MediaQuery.paddingOf(context).bottom
              ? null : size.height - from.top + 2,
          right: math.max(12, size.width - from.right + 4),
          child: FadeTransition(
            opacity: CurvedAnimation(parent: a, curve: Motion.settle, reverseCurve: Curves.easeInCubic),
            child: ScaleTransition(
              alignment: Alignment.topRight,
              scale: Tween(
                begin: 0.86,
                end: 1.0,
              ).animate(CurvedAnimation(parent: a, curve: Motion.settle, reverseCurve: Curves.easeInCubic)),
              child: _PopCard(items: items),
            ),
          ),
        ),
      ],
    );
  }
}

class _PopCard extends StatelessWidget {
  const _PopCard({required this.items});
  final List<PopItem> items;

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: Container(
        width: 232,
        padding: const EdgeInsets.symmetric(vertical: 6),
        decoration: BoxDecoration(
          color: Neutral.surface,
          borderRadius: BorderRadius.circular(18),
          boxShadow: const [
            BoxShadow(color: Color(0x1F000000), blurRadius: 30, offset: Offset(0, 10)),
            BoxShadow(color: Color(0x0F000000), blurRadius: 3, offset: Offset(0, 1)),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final it in items) ...[
              if (it.divided)
                const Padding(padding: EdgeInsets.symmetric(vertical: 4, horizontal: 18), child: Hairline()),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: it.onTap == null
                    ? null
                    : () {
                        Haptics.tick();
                        Navigator.pop(context);
                        it.onTap!();
                      },
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                  child: Text(
                    it.label,
                    style: Txt.label.copyWith(
                      color: it.onTap == null ? Neutral.tertiary : (it.quiet ? Neutral.secondary : Neutral.primary),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
