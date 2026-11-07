import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../core/recipe.dart';
import '../data/photo_source.dart';
import '../data/store.dart';
import 'detail.dart';
import 'edit.dart';
import 'settings.dart';
import 'theme.dart';
import 'widgets/common.dart';

class PhotosScreen extends StatefulWidget {
  const PhotosScreen({super.key});

  @override
  State<PhotosScreen> createState() => _PhotosScreenState();
}

class _PhotosScreenState extends State<PhotosScreen> {
  final s = Store.instance;
  int _columns = 3;
  double _scaleStart = 1;
  final Set<String> _selected = {};
  bool get _selecting => _selected.isNotEmpty;

  /// Photos that already played their color-return this session.
  static final Set<String> _played = {};

  final _scroll = ScrollController();
  final _offset = ValueNotifier(0.0);

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() => _offset.value = _scroll.offset);
  }

  @override
  void dispose() {
    _scroll.dispose();
    _offset.dispose();
    super.dispose();
  }

  void _open(PhotoItem it, List<PhotoItem> all) {
    if (it.state != Develop.done && !_selecting) {
      // Not developed yet: open it in Edit. If the agent is on it, its work
      // shows live there and the first change takes over.
      Haptics.light();
      Navigator.of(context).push(EditRoute(it));
      return;
    }
    final list = all.where((e) => e.state == Develop.done).toList();
    if (_selecting) {
      setState(() => _selected.contains(it.key) ? _selected.remove(it.key) : _selected.add(it.key));
      Haptics.tick();
      return;
    }
    s.markSeen(it);
    Navigator.of(context).push(DetailRoute(items: list, index: list.indexOf(it)));
  }

  void _onScaleEnd() {
    // Pinch: 3 <-> 5 columns, or 1 column to look closely.
    const steps = [1, 3, 5];
    final i = steps.indexOf(_columns);
    if (_scaleStart > 1.25 && i > 0) {
      setState(() => _columns = steps[i - 1]);
      Haptics.tick();
    } else if (_scaleStart < 0.8 && i < steps.length - 1) {
      setState(() => _columns = steps[i + 1]);
      Haptics.tick();
    }
    _scaleStart = 1;
  }

  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.paddingOf(context);
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        final list = s.visible;
        return Stack(
          children: [
            GestureDetector(
              onScaleUpdate: (d) => _scaleStart = d.scale,
              onScaleEnd: (_) => _onScaleEnd(),
              child: CustomScrollView(
                controller: _scroll,
                slivers: [
                  SliverToBoxAdapter(child: SizedBox(height: pad.top + 10)),
                  SliverToBoxAdapter(child: _header()),
                  SliverToBoxAdapter(child: _status()),
                  if (s.palette.isNotEmpty) SliverToBoxAdapter(child: _paletteRow()),
                  if (list.isEmpty)
                    SliverFillRemaining(hasScrollBody: false, child: _empty())
                  else if (s.sort == SortMode.time)
                    ..._byMonth(list)
                  else
                    _grid(list, list),
                  SliverToBoxAdapter(child: SizedBox(height: pad.bottom + 96)),
                ],
              ),
            ),
            _topBar(pad),
            if (_selecting) _selectionBar(pad),
          ],
        );
      },
    );
  }

  /// Once the large title scrolls away, a glass bar keeps the place, and the
  /// photos pass underneath it.
  Widget _topBar(EdgeInsets pad) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: ValueListenableBuilder<double>(
        valueListenable: _offset,
        builder: (context, o, _) {
          final t = ((o - 36) / 28).clamp(0.0, 1.0);
          if (t == 0) return const SizedBox.shrink();
          return IgnorePointer(
            child: Opacity(
              opacity: t,
              child: ClipRect(
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 26, sigmaY: 26),
                  child: Container(
                    height: pad.top + 44,
                    padding: EdgeInsets.only(top: pad.top),
                    alignment: Alignment.center,
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Color(0xE6F6F6F5), Color(0xB3F3F3F2)],
                      ),
                      border: Border(bottom: BorderSide(color: Color(0x14000000), width: 0.5)),
                    ),
                    child: Text(_selecting ? '${_selected.length} selected' : 'Photos', style: Txt.label),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 10, 4),
      child: Row(
        children: [
          Text(_selecting ? '${_selected.length} selected' : 'Photos', style: Txt.display),
          const Spacer(),
          if (_selecting)
            TextAction('Done', onTap: () => setState(_selected.clear))
          else ...[
            _SortSwitch(value: s.sort, onChanged: s.setSort),
            TextAction(
              'Settings',
              color: Neutral.secondary,
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
            ),
          ],
        ],
      ),
    );
  }

  Widget _status() {
    String? text;
    if (s.access == Access.limited) text = 'Showing selected photos only';
    if (s.developing) text = 'Developing ${s.doneCount + 1} of ${s.doneCount + s.pendingCount}';
    return AnimatedSize(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
      child: text == null
          ? const SizedBox(width: double.infinity)
          : Padding(
              padding: const EdgeInsets.fromLTRB(20, 2, 20, 10),
              child: Row(
                children: [
                  if (s.developing) ...[const _Pulse(), const SizedBox(width: 8)],
                  Text(text, style: Txt.mono),
                  if (s.access == Access.limited && !s.developing) ...[
                    const Spacer(),
                    GestureDetector(
                      onTap: () async {
                        await PhotoSource.presentLimitedPicker();
                        s.refresh();
                      },
                      child: Text('Add photos', style: Txt.mono.copyWith(color: Neutral.primary)),
                    ),
                  ],
                ],
              ),
            ),
    );
  }

  Widget _paletteRow() {
    final pal = s.palette;
    final filtering = s.paletteFilter.isNotEmpty;
    return SizedBox(
      height: 52,
      child: Row(
        children: [
          Expanded(
            // Edges fade, so a cut-off swatch reads as "there is more this way".
            child: ShaderMask(
              blendMode: BlendMode.dstIn,
              shaderCallback: (r) => const LinearGradient(
                colors: [Color(0x00000000), Color(0xFF000000), Color(0xFF000000), Color(0x00000000)],
                stops: [0, 0.05, 0.84, 1],
              ).createShader(r),
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(20, 8, 28, 14),
                itemCount: pal.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (context, i) => Swatch(
                  pal[i].color,
                  size: 30,
                  selected: s.paletteFilter.contains(i),
                  onTap: () {
                    Haptics.tick();
                    s.togglePalette(i);
                  },
                ),
              ),
            ),
          ),
          // Clear stays put; it never scrolls away with the swatches.
          AnimatedSize(
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
            child: filtering
                ? GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      Haptics.tick();
                      s.clearPalette();
                    },
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(6, 0, 20, 6),
                      child: Text('Clear', style: Txt.mono.copyWith(color: Neutral.primary)),
                    ),
                  )
                : const SizedBox(height: 1),
          ),
        ],
      ),
    );
  }

  List<Widget> _byMonth(List<PhotoItem> list) {
    final groups = <String, List<PhotoItem>>{};
    for (final it in list) {
      groups.putIfAbsent('${it.taken.year}-${it.taken.month}', () => []).add(it);
    }
    final now = DateTime.now();
    return [
      for (final g in groups.values) ...[
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 10),
            child: Row(
              children: [
                Text(
                  g.first.taken.year == now.year
                      ? months[g.first.taken.month - 1]
                      : '${months[g.first.taken.month - 1]} ${g.first.taken.year}',
                  style: Txt.label,
                ),
                const SizedBox(width: 12),
                // The colors collected that month.
                ..._monthColors(g)
                    .map((c) => Padding(padding: const EdgeInsets.only(right: 4), child: Swatch(c, size: 10))),
              ],
            ),
          ),
        ),
        _grid(g, list),
      ],
    ];
  }

  List<KeptColor> _monthColors(List<PhotoItem> g) {
    final pal = s.palette;
    final keys = g.map((e) => e.key).toSet();
    return pal.where((p) => p.keys.any(keys.contains)).map((p) => p.color).take(12).toList();
  }

  Widget _grid(List<PhotoItem> items, List<PhotoItem> all) {
    final gap = switch (_columns) {
      1 => 14.0,
      3 => 4.0,
      _ => 3.0,
    };
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      sliver: SliverGrid(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: _columns,
          mainAxisSpacing: gap,
          crossAxisSpacing: gap,
          childAspectRatio: _columns == 1 ? 4 / 5 : 1,
        ),
        delegate: SliverChildBuilderDelegate((context, i) {
          final it = items[i];
          final done = it.state == Develop.done;
          final play = done && !_played.contains(it.key) && !it.seen;
          if (done) _played.add(it.key);
          return _Tile(
            key: ValueKey(it.key),
            item: it,
            play: play,
            size: _columns == 1 ? 1000 : (_columns == 3 ? 420 : 260),
            radius: switch (_columns) {
              1 => 14.0,
              3 => 6.0,
              _ => 4.0,
            },
            selected: _selected.contains(it.key),
            onTap: () => _open(it, all),
            onLongPress: () {
              if (it.state != Develop.done) return;
              Haptics.light();
              setState(() => _selected.add(it.key));
            },
          );
        }, childCount: items.length),
      ),
    );
  }

  Widget _empty() {
    final none = s.items.isEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 60, 20, 120),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            s.paletteFilter.isNotEmpty
                ? 'No photos with these colors.'
                : (s.developing || (!none && s.doneCount == 0) ? 'Developing your first photo.' : 'No photos yet.'),
            style: Txt.body.copyWith(color: Neutral.secondary),
          ),
          if (none && !s.developing) ...[
            const SizedBox(height: 18),
            TextAction(
              'Choose Photos',
              onTap: () async {
                await s.requestAccess();
                await PhotoSource.presentLimitedPicker();
                s.refresh();
              },
            ),
          ],
        ],
      ),
    );
  }

  Widget _selectionBar(EdgeInsets pad) {
    final sel = _selected.map(s.byKey).whereType<PhotoItem>().toList();
    return Positioned(
      left: 20,
      right: 20,
      bottom: pad.bottom + 78,
      child: Glass(
        radius: 22,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            TextAction(
              'Paste Edit',
              onTap: s.clipboard == null
                  ? null
                  : () {
                      s.pasteEdit(sel);
                      setState(_selected.clear);
                    },
            ),
            TextAction(
              'Share',
              onTap: () async {
                final files = <XFile>[];
                for (final it in sel) {
                  final f = await s.rendered(it, 2048);
                  if (f != null) files.add(XFile(f.path));
                }
                await SharePlus.instance.share(ShareParams(files: files));
              },
            ),
            TextAction(
              'Remove',
              onTap: () {
                for (final it in sel) {
                  s.remove(it);
                }
                setState(_selected.clear);
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    super.key,
    required this.item,
    required this.play,
    required this.size,
    required this.onTap,
    required this.onLongPress,
    this.selected = false,
    this.radius = 0,
  });
  final PhotoItem item;
  final bool play, selected;
  final double radius;
  final int size;
  final VoidCallback onTap, onLongPress;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: AnimatedScale(
        scale: selected ? 0.9 : 1,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutBack,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius),
            boxShadow: radius > 0
                ? const [BoxShadow(color: Color(0x1A000000), blurRadius: 10, offset: Offset(0, 3), spreadRadius: -2)]
                : null,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(selected ? radius + 4 : radius),
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (item.state == Develop.done)
                  Hero(
                    tag: 'photo-${item.key}',
                    child: ColorReturnOnce(
                      play: play,
                      child: DevelopedImage(
                        item,
                        size: size,
                        placeholder: OriginalImage(item, size: size),
                      ),
                    ),
                  )
                else ...[
                  OriginalImage(item, size: size),
                  if (item.state != Develop.manual) const _Breathing(),
                ],
                if (!item.seen && item.state == Develop.done)
                  Positioned(
                    top: 7,
                    right: 7,
                    child: Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: Neutral.surface,
                        shape: BoxShape.circle,
                        boxShadow: const [BoxShadow(color: Color(0x40000000), blurRadius: 3)],
                      ),
                    ),
                  ),
                if (selected)
                  Positioned(
                    bottom: 7,
                    right: 7,
                    child: Container(
                      width: 18,
                      height: 18,
                      decoration: BoxDecoration(
                        color: Neutral.primary,
                        shape: BoxShape.circle,
                        border: Border.all(color: Neutral.surface, width: 1.5),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SortSwitch extends StatelessWidget {
  const _SortSwitch({required this.value, required this.onChanged});
  final SortMode value;
  final ValueChanged<SortMode> onChanged;

  @override
  Widget build(BuildContext context) {
    Widget opt(String t, SortMode m) => GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        if (value != m) Haptics.tick();
        onChanged(m);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
        child: AnimatedDefaultTextStyle(
          duration: const Duration(milliseconds: 180),
          style: Txt.label.copyWith(color: value == m ? Neutral.primary : Neutral.tertiary),
          child: Text(t),
        ),
      ),
    );
    return Row(children: [opt('Time', SortMode.time), opt('Hue', SortMode.hue)]);
  }
}

/// Quiet breathing dot for background work.
class _Pulse extends StatefulWidget {
  const _Pulse();
  @override
  State<_Pulse> createState() => _PulseState();
}

class _PulseState extends State<_Pulse> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))
    ..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: Tween(begin: 0.25, end: 1.0).animate(CurvedAnimation(parent: _c, curve: Curves.easeInOut)),
    child: Container(
      width: 6,
      height: 6,
      decoration: const BoxDecoration(color: Neutral.primary, shape: BoxShape.circle),
    ),
  );
}

/// A slow light passing over a photo that is still developing.
class _Breathing extends StatefulWidget {
  const _Breathing();

  @override
  State<_Breathing> createState() => _BreathingState();
}

class _BreathingState extends State<_Breathing> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800))
    ..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: CurvedAnimation(parent: _c, curve: Curves.easeInOutSine),
    child: const ColoredBox(color: Color(0x2EFFFFFF), child: SizedBox.expand()),
  );
}
