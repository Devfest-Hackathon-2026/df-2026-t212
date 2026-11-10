import 'package:flutter/material.dart';

import '../l10n/strings.dart';
import '../data/store.dart';
import '../core/recipe.dart';
import 'edit.dart';
import 'theme.dart';
import 'widgets/common.dart';

class SourceUpdatesScreen extends StatefulWidget {
  const SourceUpdatesScreen({super.key, this.keys});
  final List<String>? keys;
  @override
  State<SourceUpdatesScreen> createState() => _SourceUpdatesScreenState();
}

class _SourceUpdatesScreenState extends State<SourceUpdatesScreen> {
  final store = Store.instance;
  bool _checking = false;

  Future<void> _edit(PhotoItem item) async {
    final pendingSize = item.pendingSize;
    final pending = item.pendingSource, candidate = item.pendingEdit, reason = item.sourceReview;
    if (pending == null) return;
    // Use the editor's existing cancel/done contract for uncertain correspondence.
    item.pendingEdit ??= item.edit?.copy() ?? Recipe();
    if (!store.applySourceUpdate(item) || !mounted) return;
    var saved = false;
    await Navigator.push(context, MaterialPageRoute<void>(builder: (_) => EditScreen(item: item, onSaved: () => saved = true)));
    if (!saved && store.byKey(item.key) == item) {
      store.takeOver(item);
      store.undoSourceUpdate(item);
      item.pendingSource = pending; item.pendingSize = pendingSize; item.pendingEdit = candidate; item.sourceReview = reason;
      store.saveSourceReview();
    }
  }


  Future<void> _undo(List<PhotoItem> items) async {
    final yes = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: Text(context.tr('Restore the previous versions?', '更新前に戻しますか？')),
      content: Text(context.tr('This restores the photos and edits from before their last original update, including any edits made afterward.', '元の写真を更新する前の状態に戻します。更新後に行った編集も戻ります。')),
      actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: Text(context.tr('Cancel', 'キャンセル'))),
        TextButton(onPressed: () => Navigator.pop(context, true), child: Text(context.tr('Restore', '元に戻す')))],
    ));
    if (yes == true) { for (final item in items) { store.undoSourceUpdate(item); } }
  }

  @override
  Widget build(BuildContext context) => Scaffold(body: SafeArea(child: ListenableBuilder(
    listenable: store,
    builder: (context, _) {
      final items = store.items.where((it) => (widget.keys == null || widget.keys!.contains(it.key)) &&
          (it.pendingSource != null || it.previousSource != null)).toList();
      final ready = items.where((it) => it.pendingEdit != null && it.pendingSource != null).toList();
      final undoable = items.where((it) => it.previousSource != null).toList();
      return ListView(padding: const EdgeInsets.fromLTRB(20, 4, 20, 32), children: [
        Align(alignment: Alignment.centerLeft, child: TextAction(context.tr('Back', '戻る'), onTap: () => Navigator.pop(context))),
        const SizedBox(height: 8), Text(context.tr('Original updates', '元の写真の更新'), style: Txt.display),
        const SizedBox(height: 12), Text(context.tr('Your current photos stay as they are until an update is applied. Color matching runs on this device.', '更新を適用するまで、現在の写真はそのままです。色の照合はこの端末で行います。'), style: Txt.small),
        const SizedBox(height: 16),
        Wrap(spacing: 8, children: [
          TextAction(_checking ? context.tr('Checking…', '確認中…') : context.tr('Check Photos', '写真を確認'), onTap: _checking ? () {} : () async {
            setState(() => _checking = true);
            try { await store.checkSourceChanges(); } finally { if (mounted) setState(() => _checking = false); }
          }),
          if (ready.isNotEmpty) TextAction(context.tr('Update ${ready.length} ready', '${ready.length}枚を更新'), onTap: () { for (final it in ready) { store.applySourceUpdate(it); } }),
          if (undoable.isNotEmpty) TextAction(context.tr('Restore previous', '更新前に戻す'), onTap: () => _undo(undoable)),
        ]),
        if (items.isEmpty) Padding(padding: const EdgeInsets.symmetric(vertical: 40), child: Text(context.tr('No original updates to review.', '確認する更新はありません。'), style: Txt.body)),
        for (final item in items) ...[
          const SizedBox(height: 20),
          Text('${item.taken.year}-${item.taken.month.toString().padLeft(2, '0')}-${item.taken.day.toString().padLeft(2, '0')}', style: Txt.small),
          const SizedBox(height: 10),
          if (item.pendingSource != null) Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: _preview(item, context.tr('Current', '現在'))),
            const SizedBox(width: 12),
            Expanded(child: _preview(PhotoItem.fromJson({...item.toJson(),
              'sourceRevision': item.pendingSource, 'sourceSize': item.pendingSize, 'edit': item.pendingEdit?.toJson()}), item.pendingEdit != null ? context.tr('Updated', '更新後') : context.tr('New original', '新しい元写真'))),
          ]) else Align(alignment: Alignment.centerLeft, child: SizedBox(width: 160, child: _preview(item, context.tr('Updated', '更新後')))),
          if (item.sourceReview != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(item.sourceReview!, style: Txt.small)),
          Wrap(spacing: 8, children: [
            if (item.pendingSource != null) ...[
              if (item.pendingEdit != null) TextAction(context.tr('Update', '更新'), onTap: () => store.applySourceUpdate(item)),
              TextAction(context.tr('Edit updated photo', '更新した写真を編集'), onTap: () => _edit(item)),
              TextAction(context.tr('Keep current', '現在のまま'), color: Neutral.secondary, onTap: () => store.keepSource(item)),
            ] else if (item.previousSource != null) TextAction(context.tr('Restore previous', '更新前に戻す'), onTap: () => _undo([item])),
          ]),
          const Hairline(),
        ],
      ]);
    },
  )));

  Widget _preview(PhotoItem item, String label) => Column(mainAxisSize: MainAxisSize.min, children: [
    AspectRatio(aspectRatio: 1, child: ClipRRect(borderRadius: BorderRadius.circular(8), child:
      item.edit == null ? OriginalImage(item, size: 480, mono: false) : DevelopedImage(item, size: 480))),
    const SizedBox(height: 6), Text(label, style: Txt.small),
  ]);
}
