import 'dart:ui' show ImageFilter;

import 'package:flutter/gestures.dart';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../core/recipe.dart';
import '../data/photo_source.dart';
import '../data/store.dart';
import 'detail.dart';
import 'activity.dart';
import 'settings.dart';
import 'theme.dart';
import 'widgets/common.dart';
import 'widgets/sweep_selection.dart';
import 'widgets/development_bar.dart';
import 'widgets/confirm_remove.dart';
import 'widgets/agent_work_status.dart';

class PhotosScreen extends StatefulWidget {
  const PhotosScreen({super.key, this.onSelectionChanged});
  final ValueChanged<bool>? onSelectionChanged;

  @override
  State<PhotosScreen> createState() => _PhotosScreenState();
}

class _PhotosScreenState extends State<PhotosScreen> {
  static const _headerExtent = 60.0;
  final s = Store.instance;
  int _columns = 3;
  double _scaleStart = 1;
  final Set<String> _selected = {};
  bool _selecting = false;
  void _setSelecting(bool value, {PhotoItem? first}) {
    _sweep.end();
    setState(() {
      _selecting = value;
      if (!value) _selected.clear();
      if (first != null) _selected.addAll(_members(first).map((it) => it.key));
    });
    widget.onSelectionChanged?.call(value);
  }

  late final _sweep = SweepSelection(
    scroll: _scroll,
    order: () {
      final list = s.galleryItems;
      if (!s.groupByMonth) return list.map((it) => it.key).toList();
      final groups = <String, List<String>>{};
      for (final it in list) {
        groups.putIfAbsent('${it.taken.year}-${it.taken.month}', () => []).add(it.key);
      }
      return groups.values.expand((group) => group).toList();
    },
    selection: () => _selected,
    selectionKeys: (key) {
      final item = s.byKey(key);
      return item == null ? <String>[] : _members(item).map((it) => it.key);
    },
    onChanged: (next) => setState(() { _selected.clear(); _selected.addAll(next); }),
    onStep: Haptics.tick,
    onStart: () {
      if (!_selecting) {
        setState(() => _selecting = true);
        widget.onSelectionChanged?.call(true);
      }
      Haptics.light();
    },
    insets: () {
      final pad = MediaQuery.paddingOf(context);
      return EdgeInsets.only(top: pad.top + _headerExtent, bottom: pad.bottom + 72);
    },
  );

  Widget _clearSelection() => TextAction(
    'Deselect all',
    onTap: _selected.isEmpty ? null : () {
      _sweep.end();
      setState(_selected.clear);
      Haptics.tick();
    },
  );

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
    _sweep.end();
    _scroll.dispose();
    _offset.dispose();
    super.dispose();
  }

  List<PhotoItem> _members(PhotoItem item) {
    final group = s.groupFor(item);
    return group == null ? [item] : s.groupItems(group);
  }

  void _selectGroup(PhotoItem item) {
    _sweep.end();
    final members = _members(item);
    final keys = members.map((it) => it.key).toSet();
    Navigator.push(context, MaterialPageRoute<void>(builder: (_) => _GroupSelectionScreen(
      members: members,
      selected: _selected.intersection(keys),
      onChanged: (next) {
        if (!mounted) return;
        setState(() { _selected.removeAll(keys); _selected.addAll(next); });
      },
    )));
  }

  void _open(PhotoItem it, List<PhotoItem> all) {
    // Every photo opens to be looked at first; Edit is one tap from there.
    final list = all;
    if (_selecting) {
      final keys = _members(it).map((photo) => photo.key).toSet();
      setState(() => keys.every(_selected.contains) ? _selected.removeAll(keys) : _selected.addAll(keys));
      Haptics.tick();
      return;
    }
    s.markSeen(it);
    final group = s.groupFor(it);
    final viewing = group == null ? list : s.groupItems(group);
    Navigator.of(context).push(DetailRoute(items: viewing, index: viewing.indexOf(it), groupId: group?.id));
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
        final list = s.galleryItems;
        final visibleKeys = list.map((it) => it.key).toSet();
        _sweep.retainKeys(visibleKeys);
        _selected.removeWhere((key) => s.byKey(key)?.shown != true);
        final hasDevelopment = s.items.any((it) => it.shown && (it.isUndeveloped || (it.state == Develop.pending || it.state == Develop.developing)));
        return Stack(
          key: _sweep.viewportKey,
          children: [
            GestureDetector(
              dragStartBehavior: DragStartBehavior.down,
              onScaleUpdate: _selecting ? null : (d) => _scaleStart = d.scale,
              onScaleEnd: _selecting ? null : (_) => _onScaleEnd(),
              onHorizontalDragStart: _selecting ? (d) => _sweep.begin(d.globalPosition) : null,
              onHorizontalDragUpdate: _selecting ? (d) => _sweep.move(d.globalPosition) : null,
              onHorizontalDragEnd: _selecting ? (_) => _sweep.end() : null,
              onHorizontalDragCancel: _selecting ? _sweep.end : null,
              onLongPressStart: (d) => _sweep.begin(d.globalPosition),
              onLongPressMoveUpdate: (d) => _sweep.move(d.globalPosition),
              onLongPressEnd: (_) => _sweep.end(),
              onLongPressCancel: _sweep.end,
              child: CustomScrollView(
                controller: _scroll,
                slivers: [
                  SliverToBoxAdapter(child: SizedBox(height: pad.top + _headerExtent)),
                  SliverToBoxAdapter(child: _status()),
                  if (s.palette.isNotEmpty) SliverToBoxAdapter(child: _paletteRow()),
                  if (list.isEmpty)
                    SliverFillRemaining(hasScrollBody: false, child: _empty())
                  else if (s.groupByMonth)
                    ..._byMonth(list)
                  else
                    _grid(list, list),
                  if (list.isNotEmpty) SliverToBoxAdapter(child: _more()),
                  SliverToBoxAdapter(child: SizedBox(height: pad.bottom + (hasDevelopment ? 156 : 96))),
                ],
              ),
            ),
            _topBar(pad),
            if (!_selecting)
              Positioned(
                left: 20, right: 20, bottom: pad.bottom + 78,
                child: DevelopmentBar(onReview: (items) {
                  Navigator.of(context).push(DetailRoute(items: items, index: 0, developmentBatch: true));
                }),
              ),
            if (_selecting) _selectionBar(pad),
          ],
        );
      },
    );
  }

  /// Keep the same title and actions in place while photos pass underneath.
  Widget _topBar(EdgeInsets pad) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: ClipRect(
        child: ValueListenableBuilder<double>(
          valueListenable: _offset,
          child: Padding(
            padding: EdgeInsets.only(top: pad.top),
            child: _header(),
          ),
          builder: (context, offset, header) {
            final glass = (offset / 24).clamp(0.0, 1.0);
            return BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 14 * glass, sigmaY: 14 * glass),
              child: ColoredBox(
                color: Neutral.bg.withValues(alpha: 0.86 * glass),
                child: header,
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 10, 4),
      child: Column(children: [
        SizedBox(height: 48, child: Row(children: [
          Expanded(child: Text(_selecting ? '${_selected.length} selected' : 'Photos', style: _selecting ? Txt.label : Txt.display)),
          if (_selecting) ...[
            _clearSelection(),
            TextAction('Done', onTap: () => _setSelecting(false)),
          ] else ...[
            TextAction('Select', color: Neutral.secondary, onTap: () => _setSelecting(true)),
            Semantics(excludeSemantics: true, label: 'Activity${s.unreadActivity > 0 ? ', ${s.unreadActivity} unread' : ''}', button: true,
              child: IconButton(tooltip: 'Activity', onPressed: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const ActivityScreen())),
                icon: Badge(isLabelVisible: s.unreadActivity > 0, backgroundColor: Neutral.primary,
                  child: const Glyph(G.bell, size: 21, color: Neutral.secondary)))),
            IconButton(tooltip: 'Settings', icon: const Glyph(G.settings, size: 21, color: Neutral.secondary),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsScreen()))),
          ],
        ])),
      ]),
    );
  }

  Widget _status() {
    String? text;
    if (s.access == Access.limited) text = 'Showing selected photos only';

    return AnimatedSize(
      duration: const Duration(milliseconds: 300),
      curve: Motion.settle,
      child: text == null
          ? const SizedBox(width: double.infinity)
          : Padding(
              padding: const EdgeInsets.fromLTRB(20, 2, 20, 10),
              child: Row(
                children: [
                  Text(text, style: Txt.mono),
                  if (s.access == Access.limited) ...[
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
            child: ClipRect(child: ShaderMask(
              blendMode: BlendMode.dstIn,
              shaderCallback: (r) {
                // Reach zero before the clip edge, including its antialiased pixel.
                final fade = (32 / r.width).clamp(0.0, 0.45);
                final clear = (2 / r.width).clamp(0.0, 0.04);
                return LinearGradient(
                  colors: const [Colors.transparent, Colors.black, Colors.black, Colors.transparent, Colors.transparent],
                  stops: [0, fade / 2, 1 - fade, 1 - clear, 1],
                ).createShader(r);
              },
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(20, 8, 28, 14),
                itemCount: pal.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (context, i) => Swatch(
                  pal[i].color,
                  size: 30,
                  from: pal[i].source,
                  selected: s.paletteFilter.contains(i),
                  onTap: () {
                    Haptics.tick();
                    s.togglePalette(i);
                  },
                ),
              ),
            )),
          ),
          // Clear stays put; it never scrolls away with the swatches.
          AnimatedSize(
            duration: const Duration(milliseconds: 260),
            curve: Motion.settle,
            child: filtering
                ? GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      Haptics.tick();
                      s.clearPalette();
                    },
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(6, 0, 20, 6),
                      child: Text('Clear', style: Txt.label.copyWith(color: Neutral.secondary)),
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
          final members = _members(it);
          final selectedCount = members.where((photo) => _selected.contains(photo.key)).length;
          final done = it.state == Develop.done;
          final play = done && !_played.contains(it.key) && !it.seen;
          if (done) _played.add(it.key);
          return KeyedSubtree(
            key: _sweep.keyFor(it.key),
            child: _Tile(
            key: ValueKey(it.key),
            item: it,
            groupCount: members.length,
            onGroupTap: _selecting && members.length > 1 ? () => _selectGroup(it) : null,
            play: play,
            size: _columns == 1 ? 1000 : (_columns == 3 ? 420 : 260),
            radius: switch (_columns) {
              1 => 14.0,
              3 => 6.0,
              _ => 4.0,
            },
            selected: selectedCount == members.length,
            partiallySelected: selectedCount > 0 && selectedCount < members.length,
            selecting: _selecting,
            onTap: () => _open(it, all),
            ),
          );
        }, childCount: items.length),
      ),
    );
  }

  /// After the oldest developed photo: hand the agent the next older ones.
  Widget _more() {
    final n = s.unlookedCount;
    if (n == 0 || s.developing || s.paletteFilter.isNotEmpty) return const SizedBox.shrink();
    final batch = n < Store.moreBatch ? n : Store.moreBatch;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 28, 20, 0),
      child: Column(
        children: [
          TextAction(
            batch == 1 ? 'Develop 1 older photo' : 'Develop $batch older photos',
            onTap: () {
              Haptics.tick();
              s.developMore();
            },
          ),
          const SizedBox(height: 6),
          Text('$n not looked at yet', style: Txt.mono),
        ],
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
          if (!none && s.paletteFilter.isEmpty) _more(),
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

  final _selectionMoreKey = GlobalKey();

  Widget _selectionBar(EdgeInsets pad) {
    final sel = _selected.map(s.byKey).whereType<PhotoItem>().toList();
    final canAuto = sel.any((it) => it.isUndeveloped);
    final canShare = sel.isNotEmpty && sel.every((it) => it.edit != null);
    return Positioned(
      left: 20, right: 20, bottom: pad.bottom + 10,
      child: Glass(
        dock: true,
        radius: 28,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
          TextAction('Auto', onTap: !canAuto ? null : () {
            s.autoDevelopUndeveloped(sel);
            _setSelecting(false);
          }),
          TextAction('Share', onTap: !canShare ? null : () async {
            final files = <XFile>[];
            for (final it in sel) {
              final f = await s.rendered(it, 2048);
              if (f != null) files.add(XFile(f.path));
            }
            if (files.isNotEmpty) await SharePlus.instance.share(ShareParams(files: files));
          }),
          if (s.clipboard == null)
            TextAction('Group', onTap: sel.length < 2 ? null : () {
              s.groupPhotos(sel); Haptics.light(); _setSelecting(false);
            })
          else
            KeyedSubtree(key: _selectionMoreKey, child: TextAction('More', onTap: () {
              final box = _selectionMoreKey.currentContext!.findRenderObject() as RenderBox;
              showPopMenu(context, from: box.localToGlobal(Offset.zero) & box.size, items: [
                PopItem('Group photos', sel.length < 2 ? null : () { s.groupPhotos(sel); _setSelecting(false); }),
                PopItem('Paste Edit', sel.isEmpty ? null : () { s.pasteEdit(sel); _setSelecting(false); }),
              ]);
            })),
          TextAction('Remove', onTap: sel.isEmpty ? null : () async {
            if (!await confirmRemovePhotos(context, sel.length) || !mounted) return;
            for (final it in sel) { s.remove(it); }
            _setSelecting(false);
          }),
        ].map((action) => Expanded(child: Center(child: action))).toList()),
      ),
    );
  }

}

/// Individual selection stays scoped to the opened group, keeping the gallery
/// layout and scroll position intact behind this route.
class _GroupSelectionScreen extends StatefulWidget {
  const _GroupSelectionScreen({required this.members, required this.selected, required this.onChanged});
  final List<PhotoItem> members;
  final Set<String> selected;
  final ValueChanged<Set<String>> onChanged;

  @override
  State<_GroupSelectionScreen> createState() => _GroupSelectionScreenState();
}

class _GroupSelectionScreenState extends State<_GroupSelectionScreen> {
  final _scroll = ScrollController();
  late final Set<String> _selected = Set.of(widget.selected);
  List<PhotoItem> get _members => widget.members.where((it) => Store.instance.byKey(it.key)?.shown == true).toList();
  late final _sweep = SweepSelection(
    scroll: _scroll,
    order: () => _members.map((it) => it.key).toList(),
    selection: () => _selected,
    onChanged: _change,
    onStart: Haptics.light,
    onStep: Haptics.tick,
  );

  void _change(Set<String> next) {
    setState(() { _selected.clear(); _selected.addAll(next); });
    widget.onChanged(Set.of(_selected));
  }

  @override
  void dispose() {
    _sweep.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(child: ListenableBuilder(
      listenable: Store.instance,
      builder: (context, _) {
        final members = _members;
        final keys = members.map((it) => it.key).toSet();
        _selected.retainAll(keys);
        _sweep.retainKeys(keys);
        return Column(children: [
          Padding(padding: const EdgeInsets.fromLTRB(20, 8, 10, 0), child: Row(children: [
            Expanded(child: Text('Group', style: Txt.display)),
            TextAction('Done', onTap: () => Navigator.pop(context)),
          ])),
          Padding(padding: const EdgeInsets.fromLTRB(20, 4, 10, 8), child: Row(children: [
            Expanded(child: Text('${_selected.length} of ${members.length} selected', style: Txt.small)),
            TextAction(_selected.length == members.length ? 'Deselect all' : 'Select all', onTap: members.isEmpty ? null : () {
              _sweep.end(); Haptics.tick();
              _change(_selected.length == members.length ? {} : keys);
            }),
          ])),
          Expanded(child: GestureDetector(
            key: _sweep.viewportKey,
            dragStartBehavior: DragStartBehavior.down,
            onHorizontalDragStart: (d) => _sweep.begin(d.globalPosition),
            onHorizontalDragUpdate: (d) => _sweep.move(d.globalPosition),
            onHorizontalDragEnd: (_) => _sweep.end(),
            onHorizontalDragCancel: _sweep.end,
            onLongPressStart: (d) => _sweep.begin(d.globalPosition),
            onLongPressMoveUpdate: (d) => _sweep.move(d.globalPosition),
            onLongPressEnd: (_) => _sweep.end(),
            onLongPressCancel: _sweep.end,
            child: HeroMode(enabled: false, child: GridView.builder(
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3, crossAxisSpacing: 4, mainAxisSpacing: 4),
              itemCount: members.length,
              itemBuilder: (context, i) {
                final item = members[i];
                return KeyedSubtree(key: _sweep.keyFor(item.key), child: _Tile(
                  key: ValueKey('group-selection-${item.key}'),
                  item: item, play: false, size: 420, radius: 6,
                  selecting: true, selected: _selected.contains(item.key),
                  onTap: () {
                    final next = Set<String>.of(_selected);
                    if (!next.remove(item.key)) next.add(item.key);
                    Haptics.tick(); _change(next);
                  },
                ));
              },
            )),
          )),
        ]);
      },
    )),
  );
}

class _Tile extends StatelessWidget {
  const _Tile({
    super.key,
    required this.item,
    required this.play,
    required this.size,
    required this.onTap,
    this.selected = false,
    this.partiallySelected = false,
    this.selecting = false,
    this.onGroupTap,
    this.groupCount = 1,
    this.radius = 0,
  });
  final PhotoItem item;
  final bool play, selected, partiallySelected, selecting;
  final VoidCallback? onGroupTap;
  final double radius;
  final int size;
  final int groupCount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final store = Store.instance;
    final group = store.groupFor(item);
    final run = store.runFor(item) ?? (group == null ? null :
      store.groupItems(group).map(store.runFor).where((run) => run != null && !run.cancelled).firstOrNull);
    final agentEditing = run != null && !run.cancelled;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedScale(
        scale: selected || partiallySelected ? 0.9 : 1,
        duration: const Duration(milliseconds: 220),
        curve: Motion.settle,
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
                    createRectTween: straightRect,
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
                  if (item.state == Develop.developing)
                    const Center(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          boxShadow: [BoxShadow(color: Color(0x40000000), blurRadius: 12)],
                        ),
                        child: CupertinoActivityIndicator(radius: 10, color: Neutral.surface),
                      ),
                    ),
                ],
                if (item.isUndeveloped || item.state == Develop.pending || item.state == Develop.developing)
                  Positioned(
                    top: groupCount > 1 ? null : 6,
                    bottom: groupCount > 1 ? 6 : null,
                    left: groupCount > 1 ? 6 : null,
                    right: groupCount > 1 && selecting ? 30 : 6,
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: const Color(0xB31C1C1C),
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
                          child: Text(item.state == Develop.pending ? 'Queued' : item.state == Develop.developing ? 'Developing' : 'Undeveloped', maxLines: 1, overflow: TextOverflow.ellipsis, style: Txt.mono.copyWith(fontSize: 9, color: Colors.white)),
                        ),
                      ),
                    ),
                  ),
                if (!item.seen && item.state == Develop.done && !agentEditing)
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
                if (!selecting && (item.favorite || (item.state == Develop.done && item.hues.isNotEmpty))) ...[
                  // The bottom darkens a little so the heart and the palette
                  // read on any photo.
                  const Positioned.fill(
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.bottomCenter,
                            end: Alignment(0, 0.25),
                            colors: [Color(0x66000000), Color(0x00000000)],
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (item.favorite) Positioned(left: 6, bottom: 5, child: const TileHeart(size: 15)),
                  if (item.state == Develop.done && item.hues.isNotEmpty)
                    Positioned(
                      right: 6,
                      bottom: 7,
                      child: IgnorePointer(
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (final c in item.hues)
                              Padding(
                                padding: const EdgeInsets.only(left: 3),
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(4),
                                    boxShadow: const [tileShadow],
                                  ),
                                  child: Swatch(c, size: 12, from: item),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                ],
                if (agentEditing)
                  Positioned(left: 6, right: 6, bottom: 27,
                    child: IgnorePointer(child: Align(alignment: Alignment.centerLeft,
                      child: AgentWorkStatus(run: run, compact: true)))),
                if (groupCount > 1)
                  Positioned(
                    left: 0, top: 0,
                    child: Semantics(
                      excludeSemantics: true,
                      label: onGroupTap == null ? '$groupCount grouped photos' : 'Choose photos in group of $groupCount',
                      value: selecting ? (partiallySelected ? 'Partially selected' : selected ? 'Selected' : 'Not selected') : null,
                      button: onGroupTap != null,
                      onTap: onGroupTap,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: onGroupTap,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                          child: Align(alignment: Alignment.topLeft, widthFactor: 1, heightFactor: 1,
                            child: Container(
                              margin: const EdgeInsets.all(6),
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                              decoration: BoxDecoration(color: const Color(0x99000000), borderRadius: BorderRadius.circular(5)),
                              child: Row(mainAxisSize: MainAxisSize.min, children: [
                                const Icon(Icons.photo_library_outlined, size: 12, color: Colors.white),
                                const SizedBox(width: 4),
                                Text('$groupCount', style: Txt.small.copyWith(fontSize: 11, color: Colors.white)),
                                if (onGroupTap != null) const Icon(Icons.chevron_right, size: 12, color: Colors.white),
                              ]),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                if (selecting)
                  Positioned(
                    bottom: 7,
                    right: 7,
                    child: Container(
                      width: 18,
                      height: 18,
                      decoration: BoxDecoration(
                        color: selected || partiallySelected ? Neutral.primary : const Color(0x40000000),
                        shape: BoxShape.circle,
                        border: Border.all(color: Neutral.surface, width: 1.5),
                      ),
                      child: partiallySelected
                          ? const Center(child: SizedBox(width: 8, height: 2, child: ColoredBox(color: Neutral.surface)))
                          : selected ? const Center(child: Glyph(G.check, size: 11, color: Neutral.surface)) : null,
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
