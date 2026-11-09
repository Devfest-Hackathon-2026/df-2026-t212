import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/recipe.dart';
import '../../core/renderer.dart';
import '../../data/places.dart';
import '../../data/store.dart';
import '../theme.dart';

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
  });
  final Widget child;
  final double radius;
  final EdgeInsets padding;
  final bool dark;

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
          filter: ui.ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          blendMode: BlendMode.src,
          child: Container(
            padding: padding,
            decoration: BoxDecoration(
              borderRadius: r,
              border: Border.all(
                color: dark ? const Color(0x26FFFFFF) : const Color(0x70FFFFFF),
                width: 0.6,
              ),
              color: dark
                  ? const Color(0x38222224)
                  : clear
                  ? const Color(0x40FFFFFF)
                  : const Color(0x66FFFFFF),
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
  const Swatch(
    this.color, {
    super.key,
    this.size = 22,
    this.selected = false,
    this.onTap,
    this.onLongPress,
    this.from,
  });
  final KeptColor color;
  final double size;
  final bool selected;
  final VoidCallback? onTap, onLongPress;
  final PhotoItem? from;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        width: size,
        height: size,
        padding: EdgeInsets.all(selected ? 2.5 : 0),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(size * 0.3),
          border: Border.all(
            color: selected ? Neutral.primary : Colors.transparent,
            width: 1.2,
          ),
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
              child: from == null
                  ? const SizedBox.expand()
                  : PhotoPatch(from!, color),
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
    return FutureBuilder<ui.Image?>(
      future: Store.instance.patch(item, color),
      builder: (_, snap) => AnimatedOpacity(
        opacity: snap.data == null ? 0 : 1,
        duration: const Duration(milliseconds: 200),
        child: snap.data == null
            ? const SizedBox.expand()
            : RawImage(
                image: snap.data,
                fit: BoxFit.cover,
                width: double.infinity,
                height: double.infinity,
              ),
      ),
    );
  }
}

/// The soft shadow under marks drawn on a photo tile (heart, palette).
const tileShadow = BoxShadow(
  color: Color(0x2E000000),
  blurRadius: 6,
  offset: Offset(0, 0.5),
);

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
            imageFilter: ui.ImageFilter.blur(
              sigmaX: tileShadow.blurSigma,
              sigmaY: tileShadow.blurSigma,
            ),
            child: Icon(
              Icons.favorite_rounded,
              size: size,
              color: tileShadow.color,
            ),
          ),
        ),
        Icon(Icons.favorite_rounded, size: size, color: Colors.white),
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

class _ColorReturnOnceState extends State<ColorReturnOnce>
    with SingleTickerProviderStateMixin {
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
  Future<File?>? _f;
  String? _sig;

  void _load() {
    final r = widget.recipe ?? widget.item.edit;
    final sig = '${widget.item.key}${r?.signature}${widget.size}';
    if (sig == _sig) return;
    _sig = sig;
    _f = Store.instance.rendered(widget.item, widget.size, recipe: r);
  }

  @override
  Widget build(BuildContext context) {
    _load();
    return FutureBuilder<File?>(
      future: _f,
      builder: (context, snap) {
        final f = snap.data;
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          child: f == null
              ? KeyedSubtree(
                  key: const ValueKey('empty'),
                  child:
                      widget.placeholder ??
                      const ColoredBox(
                        color: Neutral.hairline,
                        child: SizedBox.expand(),
                      ),
                )
              : Image.file(
                  f,
                  key: ValueKey(f.path),
                  fit: widget.fit,
                  alignment: widget.alignment ?? focusAlignment(widget.item),
                  width: double.infinity,
                  height: double.infinity,
                  gaplessPlayback: true,
                ),
        );
      },
    );
  }
}

/// The untouched photo, in black and white while it waits to be developed.
class OriginalImage extends StatefulWidget {
  const OriginalImage(
    this.item, {
    super.key,
    this.size = 420,
    this.mono = true,
  });
  final PhotoItem item;
  final int size;
  final bool mono;

  @override
  State<OriginalImage> createState() => _OriginalImageState();
}

class _OriginalImageState extends State<OriginalImage> {
  static final Map<String, Future<Uint8List?>> _cache = {};
  late Future<Uint8List?> _f = _load();

  Future<Uint8List?> _load() => _cache['${widget.item.id}_${widget.size}'] ??=
      Store.instance.original(widget.item, widget.size);

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
          return const ColoredBox(
            color: Neutral.hairline,
            child: SizedBox.expand(),
          );
        }
        final image = Image.memory(
          b,
          fit: BoxFit.cover,
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
  return Alignment(
    (f[0].clamp(0.0, 1.0) * 2 - 1),
    (f[1].clamp(0.0, 1.0) * 2 - 1),
  );
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
            color: onTap == null
                ? Neutral.tertiary
                : (color ?? Neutral.primary),
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
  });
  final IconData icon;
  final IconData? activeIcon;
  final bool active;

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
        onTap: onTap == null
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
                scale: Tween(begin: 0.6, end: 1.0).animate(
                  CurvedAnimation(parent: a, curve: Curves.easeOutBack),
                ),
                child: FadeTransition(opacity: a, child: c),
              ),
              child: Icon(
                active && activeIcon != null ? activeIcon : icon,
                key: ValueKey(active),
                size: 23,
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
  const PrimaryButton(
    this.label, {
    super.key,
    required this.onTap,
    this.secondary = false,
  });
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
        child: Text(
          label,
          style: Txt.label.copyWith(
            color: secondary ? Neutral.primary : Neutral.surface,
          ),
        ),
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
        curve: Curves.easeOutCubic,
        child: widget.child,
      ),
    );
  }
}

/// Small monospace line like "2026-10-14 17:42 · 35.6581 N 139.7017 E".
String metaLine(PhotoItem it) {
  final t = it.taken;
  String two(int v) => v.toString().padLeft(2, '0');
  final date =
      '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
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
const monthsShort = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// Hairline divider.
class Hairline extends StatelessWidget {
  const Hairline({super.key});
  @override
  Widget build(BuildContext context) =>
      Container(height: 0.6, color: Neutral.hairline);
}

/// A split swatch for photos with several kept colors (map markers, grid dots).
class SplitSwatch extends StatelessWidget {
  const SplitSwatch(this.colors, {super.key, this.size = 18, this.border = 2});
  final List<KeptColor> colors;
  final double size, border;

  @override
  Widget build(BuildContext context) {
    final r = size * 0.32;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Neutral.surface,
        borderRadius: BorderRadius.circular(r),
        boxShadow: const [
          BoxShadow(
            color: Color(0x26000000),
            blurRadius: 6,
            offset: Offset(0, 1.5),
          ),
        ],
      ),
      padding: EdgeInsets.all(border),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(math.max(0, r - border)),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final c in colors)
              Expanded(child: ColoredBox(color: colorOf(c))),
          ],
        ),
      ),
    );
  }
}
