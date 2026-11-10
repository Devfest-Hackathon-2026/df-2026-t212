import 'package:flutter/cupertino.dart';
import '../../l10n/strings.dart';

Future<bool> confirmRemovePhotos(BuildContext context, int count) async {
  return await showCupertinoDialog<bool>(
    context: context,
    builder: (context) => CupertinoAlertDialog(
      title: Text(context.tr(count == 1 ? 'Remove this photo?' : 'Remove $count photos?', '$count枚の写真を削除しますか？')),
      content: Text(context.tr('Remove from After Hue. Your originals stay in Photos.', 'After Hueから削除します。元の写真は「写真」に残ります。')),
      actions: [
        CupertinoDialogAction(
          isDefaultAction: true,
          onPressed: () => Navigator.pop(context, false),
          child: Text(context.tr('Cancel', 'キャンセル')),
        ),
        CupertinoDialogAction(
          isDestructiveAction: true,
          onPressed: () => Navigator.pop(context, true),
          child: Text(context.tr('Remove', '削除')),
        ),
      ],
    ),
  ) ?? false;
}
