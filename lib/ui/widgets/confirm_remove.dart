import 'package:flutter/cupertino.dart';

Future<bool> confirmRemovePhotos(BuildContext context, int count) async {
  return await showCupertinoDialog<bool>(
    context: context,
    builder: (context) => CupertinoAlertDialog(
      title: Text(count == 1 ? 'Remove this photo?' : 'Remove $count photos?'),
      content: const Text('Remove from After Hue. Your originals stay in Photos.'),
      actions: [
        CupertinoDialogAction(
          isDefaultAction: true,
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        CupertinoDialogAction(
          isDestructiveAction: true,
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Remove'),
        ),
      ],
    ),
  ) ?? false;
}
