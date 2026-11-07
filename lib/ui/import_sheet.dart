import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

import '../data/photo_source.dart';
import '../data/store.dart';
import 'edit.dart';
import 'theme.dart';
import 'widgets/common.dart';

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

class _ImportSheetState extends State<ImportSheet> {
  static const _pageSize = 120;
  final List<AssetEntity> _assets = [];
  final Set<String> _picked = {};
  int _page = 0;
  bool _loading = false, _end = false, _importing = false;

  @override
  void initState() {
    super.initState();
    _more();
  }

  Future<void> _more() async {
    if (_loading || _end) return;
    _loading = true;
    final next = await PhotoSource.library(page: _page, size: _pageSize);
    if (!mounted) return;
    setState(() {
      _assets.addAll(next);
      _page++;
      _end = next.length < _pageSize;
      _loading = false;
    });
  }

  Future<void> _import() async {
    if (_picked.isEmpty || _importing) return;
    setState(() => _importing = true);
    Haptics.firm();
    final picked = _assets.where((a) => _picked.contains(a.id)).toList();
    final refs = [for (final a in picked) await PhotoSource.refOf(a)];
    final added = await Store.instance.importRefs(refs);
    if (!mounted) return;
    final nav = Navigator.of(context);
    nav.pop();
    // Picked by hand, developed by hand: open the first one in Edit. The rest
    // wait in black and white in the library.
    if (added.isNotEmpty) nav.push(EditRoute(added.first));
  }

  @override
  Widget build(BuildContext context) {
    final n = _picked.length;
    return Column(
      children: [
        const SizedBox(height: 8),
        Container(width: 36, height: 4, decoration: BoxDecoration(color: Neutral.hairline, borderRadius: BorderRadius.circular(2))),
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 0),
          child: Row(
            children: [
              TextAction('Cancel', color: Neutral.secondary, onTap: () => Navigator.of(context).pop()),
              const Spacer(),
              Text('Import', style: Txt.label),
              const Spacer(),
              TextAction(n == 0 ? 'Import' : 'Import $n', onTap: n == 0 || _importing ? null : _import),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text('Choose photos to develop by hand.', style: Txt.mono),
          ),
        ),
        Expanded(
          child: _assets.isEmpty
              ? Center(child: Text(_loading ? '' : 'No photos in your library.', style: Txt.body.copyWith(color: Neutral.secondary)))
              : NotificationListener<ScrollNotification>(
                  onNotification: (n) {
                    if (n.metrics.extentAfter < 600) _more();
                    return false;
                  },
                  child: GridView.builder(
                    padding: EdgeInsets.fromLTRB(20, 0, 20, MediaQuery.paddingOf(context).bottom + 20),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 4,
                      mainAxisSpacing: 3,
                      crossAxisSpacing: 3,
                    ),
                    itemCount: _assets.length,
                    itemBuilder: (context, i) {
                      final a = _assets[i];
                      final already = Store.instance.contains(a.id);
                      final picked = _picked.contains(a.id);
                      return _Thumb(
                        key: ValueKey(a.id),
                        asset: a,
                        already: already,
                        picked: picked,
                        onTap: already
                            ? null
                            : () {
                                Haptics.tick();
                                setState(() => picked ? _picked.remove(a.id) : _picked.add(a.id));
                              },
                      );
                    },
                  ),
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
        curve: Curves.easeOutBack,
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
