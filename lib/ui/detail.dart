import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../data/store.dart';
import 'edit.dart';
import 'theme.dart';
import 'widgets/common.dart';

class DetailRoute extends PageRouteBuilder<void> {
  DetailRoute({required List<PhotoItem> items, required int index, bool review = false})
    : super(
        opaque: false,
        transitionDuration: const Duration(milliseconds: 420),
        reverseTransitionDuration: const Duration(milliseconds: 320),
        pageBuilder: (_, _, _) => DetailScreen(items: items, index: index, review: review),
        transitionsBuilder: (_, a, _, child) => FadeTransition(
          opacity: CurvedAnimation(parent: a, curve: Curves.easeOut),
          child: child,
        ),
      );
}

/// One job: look at one photo, and compare it with the original.
class DetailScreen extends StatefulWidget {
  const DetailScreen({super.key, required this.items, required this.index, this.review = false});
  final List<PhotoItem> items;
  final int index;

  /// Opened from the camera to look back over what was just taken. Only
  /// here is there a trash button, and it always deletes the shot itself,
  /// from the iPhone too: a failed shot is thrown away and taken again.
  final bool review;

  @override
  State<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends State<DetailScreen> with TickerProviderStateMixin {
  final s = Store.instance;
  late final List<PhotoItem> _items = [...widget.items];
  late final PageController _page = PageController(initialPage: widget.index);
  late int _index = widget.index;

  /// A deleted photo sinks away, and the next one rises into its place.
  late final AnimationController _gone = AnimationController(vsync: this);
  bool _rising = false;
  bool _deleting = false;
  double _drag = 0;
  bool _showOriginal = false;
  static bool _hintShown = false;
  bool _hint = false;

  /// One tap on the photo hides everything else, on black, as in Photos.
  late final AnimationController _bare = AnimationController(vsync: this, duration: const Duration(milliseconds: 240));

  void _toggleBare() {
    final on = _bare.value < 0.5;
    if (on) {
      _bare.forward();
      _hint = false;
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: []);
    } else {
      _bare.reverse();
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
  }

  @override
  void dispose() {
    if (_bare.value > 0) SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _bare.dispose();
    _gone.dispose();
    _page.dispose();
    super.dispose();
  }

  PhotoItem get item => _items[_index];

  Future<void> _delete() async {
    if (_deleting) return;
    _deleting = true;
    final gone = await s.delete([item]);
    _deleting = false;
    if (!mounted || gone.isEmpty) return;
    Haptics.firm();
    await _leave();
  }

  /// The current photo is no longer here: show the next, or close when
  /// there is none.
  Future<void> _leave() async {
    _rising = false;
    await _gone.animateTo(1, duration: const Duration(milliseconds: 200), curve: Curves.easeInCubic);
    if (!mounted) return;
    final was = item;
    setState(() {
      _items.remove(was);
      if (_items.isNotEmpty) _index = _index.clamp(0, _items.length - 1);
      _rising = true;
    });
    if (_items.isEmpty) {
      Navigator.pop(context);
      return;
    }
    if (_page.hasClients && _page.page?.round() != _index) _page.jumpToPage(_index);
    s.markSeen(item);
    _gone.value = 1;
    await _gone.animateTo(0, duration: const Duration(milliseconds: 380), curve: Motion.settle);
    _rising = false;
  }

  @override
  void initState() {
    super.initState();
    if (!_hintShown) {
      _hintShown = true;
      _hint = true;
      Future.delayed(const Duration(milliseconds: 3200), () => mounted ? setState(() => _hint = false) : null);
    }
  }

  bool _sharing = false;

  Future<void> _share() async {
    if (_sharing) return;
    setState(() => _sharing = true);
    try {
      final f = await s.rendered(item, 2048);
      if (f == null) return;
      // The button turns until the sheet is up, not until it is closed.
      final shown = SharePlus.instance.share(ShareParams(files: [XFile(f.path)]));
      await Future.any([shown, Future.delayed(const Duration(milliseconds: 450))]);
      if (mounted) setState(() => _sharing = false);
      await shown;
    } finally {
      if (mounted && _sharing) setState(() => _sharing = false);
    }
  }

  void _more() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Neutral.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) {
        Widget row(String label, VoidCallback? onTap, {bool quiet = false}) => GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap == null
              ? null
              : () {
                  Haptics.tick();
                  Navigator.pop(ctx);
                  onTap();
                },
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 15),
            child: Text(
              label,
              style: Txt.label.copyWith(
                color: onTap == null ? Neutral.tertiary : (quiet ? Neutral.secondary : Neutral.primary),
              ),
            ),
          ),
        );
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                row('Duplicate', () {
                  s.duplicate(item);
                  _toast('Duplicated');
                }),
                row('Copy Edit', () {
                  s.copyEdit(item);
                  _toast('Edit copied');
                }),
                row('Paste Edit', s.clipboard == null ? null : () => s.pasteEdit([item])),
                row('Why this color?', _why),
                if (!widget.review) ...[
                  const Hairline(),
                  row('Remove from After Hue', () {
                    s.remove(item);
                    _leave();
                  }, quiet: true),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  void _why() {
    final r = item.edit;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Neutral.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 22, 24, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (r?.subject != null) Text(_cap(r!.subject!), style: Txt.title),
              const SizedBox(height: 10),
              Row(
                children: [
                  for (final c in item.hues)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Swatch(c, size: 22, from: item),
                    ),
                ],
              ),
              const SizedBox(height: 14),
              Text(
                r?.why ?? 'No reason was recorded for this photo.',
                style: Txt.body.copyWith(color: Neutral.secondary),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _cap(String t) => t.isEmpty ? t : t[0].toUpperCase() + t.substring(1);

  void _toast(String t) => ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      behavior: SnackBarBehavior.floating,
      duration: const Duration(milliseconds: 1400),
      backgroundColor: Neutral.primary,
      content: Text(t, style: Txt.small.copyWith(color: Neutral.surface)),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.paddingOf(context);
    final fade = (1 - (_drag.abs() / 400)).clamp(0.0, 1.0);
    return ListenableBuilder(
      listenable: Listenable.merge([s, _bare]),
      builder: (context, _) {
        if (_items.isEmpty) return const SizedBox();
        final bare = Curves.easeInOut.transform(_bare.value);
        // Bars fold away so the photo grows into the whole screen.
        Widget fold(Widget child, Alignment from) => ClipRect(
          child: Align(
            alignment: from,
            heightFactor: 1 - bare,
            child: IgnorePointer(
              ignoring: bare > 0,
              child: Opacity(opacity: 1 - bare, child: child),
            ),
          ),
        );
        return Scaffold(
          backgroundColor: Color.lerp(Neutral.bg, Colors.black, bare)!.withValues(alpha: fade),
          body: Column(
            children: [
              fold(
                Column(
                  children: [
                    SizedBox(height: pad.top + 4),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Row(
                        children: [
                          IconAction(G.close, label: 'Close', onTap: () => Navigator.pop(context)),
                          Expanded(
                            child: Opacity(
                              opacity: fade,
                              child: Text(
                                '${_index + 1} / ${_items.length}',
                                style: Txt.mono,
                                textAlign: TextAlign.center,
                              ),
                            ),
                          ),
                          IconAction(G.more, label: 'More', onTap: _more),
                        ],
                      ),
                    ),
                  ],
                ),
                Alignment.bottomCenter,
              ),
              Expanded(
                child: GestureDetector(
                  onTap: _toggleBare,
                  onVerticalDragUpdate: (d) => setState(() => _drag += d.delta.dy),
                  onVerticalDragEnd: (d) {
                    if (_drag > 120 || d.velocity.pixelsPerSecond.dy > 800) {
                      Navigator.pop(context);
                    } else {
                      setState(() => _drag = 0);
                    }
                  },
                  onLongPressStart: (_) {
                    Haptics.light();
                    setState(() {
                      _showOriginal = true;
                      _hint = false;
                    });
                  },
                  onLongPressEnd: (_) => setState(() => _showOriginal = false),
                  child: Transform.translate(
                    offset: Offset(0, _drag),
                    child: Transform.scale(
                      scale: 1 - (_drag.abs() / 2000),
                      child: PageView.builder(
                        controller: _page,
                        itemCount: _items.length,
                        onPageChanged: (i) {
                          setState(() => _index = i);
                          s.markSeen(_items[i]);
                        },
                        itemBuilder: (context, i) {
                          final it = _items[i];
                          final page = Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            child: Center(
                              child: AspectRatio(
                                aspectRatio: it.width / it.height,
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    Hero(
                                      createRectTween: straightRect,
                                      tag: 'photo-${it.key}',
                                      child: DevelopedImage(
                                        it,
                                        size: 1600,
                                        fit: BoxFit.contain,
                                        alignment: Alignment.center,
                                      ),
                                    ),
                                    if (i == _index)
                                      AnimatedOpacity(
                                        opacity: _showOriginal ? 1 : 0,
                                        duration: const Duration(milliseconds: 180),
                                        curve: Motion.settle,
                                        child: _Original(it),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          );
                          if (i != _index) return page;
                          return AnimatedBuilder(
                            animation: _gone,
                            builder: (_, child) {
                              final t = _gone.value;
                              return Opacity(
                                opacity: (1 - t).clamp(0.0, 1.0),
                                child: Transform.scale(scale: _rising ? 1 - 0.04 * t : 1 - 0.14 * t, child: child),
                              );
                            },
                            child: page,
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
              fold(
                Opacity(
                  opacity: fade,
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(20, 14, 20, pad.bottom + 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 200),
                          switchInCurve: Motion.settle,
                          switchOutCurve: Curves.easeInCubic,
                          transitionBuilder: softSwitch,
                          child: Row(
                            key: ValueKey('${item.key}$_hint$_showOriginal'),
                            children: _hint
                                ? [
                                    Text(
                                      'Press and hold to see the original',
                                      style: Txt.mono.copyWith(color: Neutral.primary),
                                    ),
                                  ]
                                : _showOriginal
                                ? [Text('Original', style: Txt.mono.copyWith(color: Neutral.primary))]
                                : [
                                    for (final c in item.hues)
                                      Padding(
                                        padding: const EdgeInsets.only(right: 8),
                                        child: Swatch(c, size: 24, from: item, onTap: () => _similar(c)),
                                      ),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: Text(metaLine(item), style: Txt.mono, overflow: TextOverflow.ellipsis),
                                    ),
                                  ],
                          ),
                        ),
                        const SizedBox(height: 14),
                        // Three places, the weight in the middle: Edit is
                        // what this screen leads to.
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 28),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              IconAction(G.share, label: 'Share', busy: _sharing, onTap: _share),
                              _EditButton(onTap: () => Navigator.of(context).push(EditRoute(item))),
                              widget.review
                                  ? IconAction(G.trash, label: 'Delete', onTap: _delete)
                                  : IconAction(
                                      G.heart,
                                      activeIcon: G.heartFill,
                                      active: item.favorite,
                                      label: 'Favorite',
                                      onTap: () {
                                        Haptics.light();
                                        s.toggleFavorite(item);
                                      },
                                    ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Alignment.topCenter,
              ),
            ],
          ),
        );
      },
    );
  }

  /// Tapping a kept color shows photos with similar colors.
  void _similar(dynamic c) {
    final pal = s.palette;
    for (var i = 0; i < pal.length; i++) {
      if (pal[i].keys.contains(item.key) && (pal[i].color.hue - c.hue).abs() < 25) {
        s.paletteFilter
          ..clear()
          ..add(i);
        s.setSort(s.sort);
        Navigator.pop(context);
        return;
      }
    }
  }
}

/// The one filled control on the screen, so the eye lands on it.
class _EditButton extends StatefulWidget {
  const _EditButton({required this.onTap});
  final VoidCallback onTap;

  @override
  State<_EditButton> createState() => _EditButtonState();
}

class _EditButtonState extends State<_EditButton> {
  bool _down = false;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: 'Edit',
        child: GestureDetector(
          onTapDown: (_) => setState(() => _down = true),
          onTapCancel: () => setState(() => _down = false),
          onTapUp: (_) => setState(() => _down = false),
          onTap: () {
            Haptics.light();
            widget.onTap();
          },
          child: AnimatedScale(
            scale: _down ? 0.92 : 1,
            duration: const Duration(milliseconds: 160),
            curve: Motion.settle,
            child: Container(
              width: 58,
              height: 58,
              decoration: const BoxDecoration(
                color: Neutral.primary,
                shape: BoxShape.circle,
                boxShadow: [BoxShadow(color: Color(0x26000000), blurRadius: 12, offset: Offset(0, 4))],
              ),
              child: const Center(child: Glyph(G.edit, size: 24, color: Neutral.surface)),
            ),
          ),
        ),
      );
}

class _Original extends StatelessWidget {
  const _Original(this.item);
  final PhotoItem item;

  static final Map<String, Future<Uint8List?>> _cache = {};

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: _cache[item.id] ??= Store.instance.original(item, 1600),
      builder: (_, snap) =>
          snap.data == null ? const SizedBox() : Image.memory(snap.data!, fit: BoxFit.contain, gaplessPlayback: true),
    );
  }
}
