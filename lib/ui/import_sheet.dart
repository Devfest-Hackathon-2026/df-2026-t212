import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:photo_manager/photo_manager.dart';

import '../data/photo_source.dart';
import '../data/store.dart';
import 'detail.dart';
import 'theme.dart';
import 'widgets/common.dart';
import 'widgets/sweep_selection.dart';

/// Pick photos from any date to develop. Photos already in After Hue are
/// shown faded and cannot be picked again.
class ImportSheet extends StatefulWidget {
  const ImportSheet({super.key});

  static Future<void> show(BuildContext context) => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        backgroundColor: Neutral.surface,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
        builder: (_) => const FractionallySizedBox(heightFactor: 0.94, child: ImportSheet()),
      );

  @override
  State<ImportSheet> createState() => _ImportSheetState();
}

class _ImportSheetState extends State<ImportSheet> with WidgetsBindingObserver {
  static const _pageSize = 120;
  final List<AssetEntity> _assets = [];
  final Set<String> _picked = {};
  int _page = 0;
  bool _loading = false, _end = false, _importing = false;
  Access _access = Access.unknown;
  bool _checkingAccess = true, _returningFromSettings = false, _loadFailed = false;
  Set<String>? _shots;
  final _scroll = ScrollController();
  late final _sweep = SweepSelection(
    scroll: _scroll,
    order: () => _assets.map((a) => a.id).toList(),
    selection: () => _picked,
    canSelect: (id) => !_importing && !Store.instance.inLibrary(id),
    onChanged: (next) => setState(() { _picked.clear(); _picked.addAll(next); }),
    onStart: Haptics.light,
    onStep: Haptics.tick,
  );

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sweep.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_checkAccess(requestIfNeeded: true));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || !_returningFromSettings) return;
    _returningFromSettings = false;
    unawaited(_checkAccess());
  }

  bool get _canRead => _access == Access.full || _access == Access.limited;

  Future<void> _checkAccess({bool requestIfNeeded = false}) async {
    setState(() {
      _checkingAccess = true;
      _loadFailed = false;
    });
    try {
      final store = Store.instance;
      var access = await store.updatePhotoAccess();
      if (!mounted) return;
      if (requestIfNeeded && (access == Access.unknown || access == Access.denied)) {
        access = await store.requestAccess();
      }
      if (!mounted) return;
      setState(() {
        _access = access;
        _checkingAccess = false;
      });
      if (_canRead) await _more();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _checkingAccess = false;
        _loadFailed = true;
      });
    }
  }

  Future<void> _openPhotoSettings() async {
    _returningFromSettings = true;
    try {
      await PhotoManager.openSetting();
    } catch (_) {
      _returningFromSettings = false;
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Open After Hue in Settings to allow photo access.')),
      );
    }
  }

  Future<void> _more() async {
    if (!_canRead || _loading || _end || _loadFailed) return;
    _loading = true;
    try {
      final next = await PhotoSource.library(page: _page, size: _pageSize);
      if (!mounted) return;
      final skip = Store.instance.skipScreenshots;
      final shots = _shots ??= skip ? await PhotoSource.screenshotIds() : const <String>{};
      if (!mounted) return;
      setState(() {
        _assets.addAll(skip ? next.where((a) => !shots.contains(a.id) && !PhotoSource.isScreenshot(a)) : next);
        _page++;
        _end = next.length < _pageSize;
        _loading = false;
      });
      // A page of nothing but screenshots: keep going.
      if (skip && !_end && _assets.length < 40) unawaited(_more());
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadFailed = true;
      });
    }
  }

  Widget _emptyLibrary() {
    if (_checkingAccess || _loading) return const SizedBox.shrink();
    final message = _loadFailed
        ? 'Could not load your photos.'
        : _canRead
            ? 'No photos in your library.'
            : 'Allow photo access to choose photos to import.';
    return Center(child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(message, textAlign: TextAlign.center, style: Txt.body.copyWith(color: Neutral.secondary)),
        if (_loadFailed)
          TextAction('Try again', onTap: () => _checkAccess(requestIfNeeded: true))
        else if (!_canRead)
          TextAction('Open Settings', onTap: _openPhotoSettings),
      ]),
    ));
  }

  Future<void> _import({required bool autoDevelop}) async {
    if (_picked.isEmpty || _importing) return;
    _sweep.end();
    setState(() => _importing = true);
    Haptics.firm();
    final picked = _assets.where((a) => _picked.contains(a.id)).toList();
    late final List<PhotoItem> added;
    try {
      final refs = [for (final a in picked) await PhotoSource.refOf(a)];
      if (!mounted) return;
      added = await Store.instance.importRefs(refs, autoDevelop: autoDevelop);
    } catch (_) {
      if (!mounted) return;
      setState(() => _importing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not import the selected photos.')),
      );
      return;
    }
    if (!mounted) return;
    final nav = Navigator.of(context);
    nav.pop();
    if (autoDevelop || added.isEmpty) return;
    nav.push(DetailRoute(items: added, index: 0, developmentBatch: true));
  }

  @override
  Widget build(BuildContext context) {
    final n = _picked.length;
    return Column(
      children: [
        const SizedBox(height: 8),
        Container(width: 36, height: 4, decoration: BoxDecoration(color: Neutral.hairline, borderRadius: BorderRadius.circular(2))),
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 20, 12),
          child: Row(children: [
            TextAction('Cancel', color: Neutral.secondary, onTap: _importing ? null : () => Navigator.of(context).pop()),
            Expanded(child: Text('Choose photos', textAlign: TextAlign.center, style: Txt.label)),
            TextAction('Deselect all', color: Neutral.secondary, onTap: n == 0 || _importing ? null : () {
              _sweep.end();
              setState(_picked.clear);
            }),
          ]),
        ),
        Expanded(
          child: _assets.isEmpty
              ? _emptyLibrary()
              : NotificationListener<ScrollNotification>(
                  onNotification: (n) {
                    if (n.metrics.extentAfter < 600) _more();
                    return false;
                  },
                  child: GestureDetector(
                    key: _sweep.viewportKey,
                    dragStartBehavior: DragStartBehavior.down,
                    onHorizontalDragStart: _importing ? null : (d) => _sweep.begin(d.globalPosition),
                    onHorizontalDragUpdate: _importing ? null : (d) => _sweep.move(d.globalPosition),
                    onHorizontalDragEnd: _importing ? null : (_) => _sweep.end(),
                    onHorizontalDragCancel: _sweep.end,
                    onLongPressStart: _importing ? null : (d) => _sweep.begin(d.globalPosition),
                    onLongPressMoveUpdate: _importing ? null : (d) => _sweep.move(d.globalPosition),
                    onLongPressEnd: (_) => _sweep.end(),
                    onLongPressCancel: _sweep.end,
                    child: GridView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 4,
                      mainAxisSpacing: 3,
                      crossAxisSpacing: 3,
                    ),
                    itemCount: _assets.length,
                    itemBuilder: (context, i) {
                      final a = _assets[i];
                      final already = Store.instance.inLibrary(a.id);
                      final picked = _picked.contains(a.id);
                      return KeyedSubtree(
                        key: _sweep.keyFor(a.id),
                        child: _Thumb(
                        key: ValueKey(a.id),
                        asset: a,
                        already: already,
                        picked: picked,
                        onTap: already || _importing
                            ? null
                            : () {
                                Haptics.tick();
                                setState(() => picked ? _picked.remove(a.id) : _picked.add(a.id));
                              },
                        ),
                      );
                    },
                    ),
                  ),
                ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (_loadFailed && _assets.isNotEmpty)
                TextAction('Retry loading more photos', onTap: () => _checkAccess())
              else
                Text(_importing ? 'Importing $n photos…' : n == 0 ? 'Select photos to develop' : '$n selected', style: Txt.small),
              const SizedBox(height: 6),
              Wrap(alignment: WrapAlignment.spaceBetween, children: [
                TextAction('Edit manually', color: Neutral.secondary,
                  onTap: n == 0 || _importing ? null : () => _import(autoDevelop: false)),
                TextAction(n == 0 ? 'Auto develop' : 'Auto develop $n',
                  onTap: n == 0 || _importing ? null : () => _import(autoDevelop: true)),
              ]),
            ]),
          ),
        ),
      ],
    );
  }
}

class _Thumb extends StatefulWidget {
  const _Thumb({super.key, required this.asset, required this.already, required this.picked, this.onTap});
  final AssetEntity asset;
  final bool already, picked;
  final VoidCallback? onTap;

  @override
  State<_Thumb> createState() => _ThumbState();
}

class _ThumbState extends State<_Thumb> {
  late final Future<Uint8List?> _f = PhotoSource.thumb(widget.asset);

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: widget.picked ? 0.9 : 1,
        duration: const Duration(milliseconds: 220),
        curve: Motion.settle,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(widget.picked ? 8 : 4),
          child: Stack(
            fit: StackFit.expand,
            children: [
              FutureBuilder<Uint8List?>(
                future: _f,
                builder: (context, snap) => snap.data == null
                    ? const ColoredBox(color: Neutral.hairline)
                    : Image.memory(snap.data!, fit: BoxFit.cover, gaplessPlayback: true),
              ),
              if (widget.already) const ColoredBox(color: Color(0xA6FAFAF9)),
              if (widget.already)
                Positioned(
                  left: 6,
                  bottom: 5,
                  child: Text('Added', style: Txt.small.copyWith(color: Neutral.secondary, fontSize: 10.5)),
                ),
              if (widget.picked)
                Positioned(
                  bottom: 6,
                  right: 6,
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
    );
  }
}
