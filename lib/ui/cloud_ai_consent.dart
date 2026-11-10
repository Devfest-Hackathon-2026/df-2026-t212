import 'package:flutter/material.dart';

import '../data/store.dart';
import '../l10n/strings.dart';
import 'privacy.dart';

/// Explain the data flow before enabling Cloud AI, both at first use and when
/// a person later enables it in Settings. A decline is remembered.
Future<bool> requestCloudAiConsent(BuildContext context) async {
  final enabled = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(dialogContext.tr('Use Cloud AI?', 'クラウド AI を使いますか？')),
      content: SingleChildScrollView(child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(dialogContext.tr(
            'To suggest and revise edits, After Hue sends a resized photo, your instructions and any marks to Google Cloud. The AI returns editing settings and a description. When automatic developing is on, eligible photos may be sent automatically.',
            '編集の提案や修正のために、縮小した写真、入力した指示、写真上の印を Google Cloud に送信します。AI は編集設定と説明を返します。自動現像がオンの場合、対象の写真は自動で送信されることがあります。',
          )),
          const SizedBox(height: 12),
          Text(dialogContext.tr(
            'The photo sent for AI does not include GPS or EXIF metadata. Google may retain data according to its terms; anonymous authentication and service logs are also used.',
            'AI に送る写真には GPS や EXIF のメタデータを含めません。Google の規約に従ってデータが保持される場合があります。匿名認証とサービスのログも利用します。',
          )),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).push(MaterialPageRoute(builder: (_) => const PrivacyScreen())),
            child: Text(dialogContext.tr('Privacy details', 'プライバシーの詳細')),
          ),
        ],
      )),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dialogContext, false),
          child: Text(dialogContext.tr('Not now', '今は使わない'))),
        TextButton(onPressed: () => Navigator.pop(dialogContext, true),
          child: Text(dialogContext.tr('Use Cloud AI', 'クラウド AI を使う'))),
      ],
    ),
  );
  if (enabled == true) {
    final saved = Store.instance.setCloudAiConsent(true);
    if (!saved && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.tr(
        'Could not save your choice. Cloud AI remains off.',
        '選択を保存できなかったため、クラウド AI はオフのままです。',
      ))));
    }
    return saved;
  }
  Store.instance.dismissCloudAiConsent();
  return false;
}

class CloudAiConsentGate extends StatefulWidget {
  const CloudAiConsentGate({super.key, required this.child});
  final Widget child;
  @override State<CloudAiConsentGate> createState() => _CloudAiConsentGateState();
}

class _CloudAiConsentGateState extends State<CloudAiConsentGate> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final store = Store.instance;
      if (mounted && store.cloudAiConfigured && !store.cloudAiConsentPromptSeen) {
        requestCloudAiConsent(context);
      }
    });
  }
  @override Widget build(BuildContext context) => widget.child;
}
