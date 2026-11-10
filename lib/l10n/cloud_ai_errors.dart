import 'package:flutter/widgets.dart';
import 'strings.dart';

/// Only show known service messages. Unknown errors may contain private data.
String? cloudAiErrorText(BuildContext context, String? error) {
  if (error == null) return null;
  return switch (error) {
    'Cloud AI has reached its daily service limit. Please try again after the daily reset.' => context.tr(error, 'クラウドAIの本日のサービス利用上限に達しました。日次リセット後にもう一度お試しください。'),
    'You have reached your daily Cloud AI limit. Please try again after the daily reset.' => context.tr(error, 'クラウドAIの本日の利用上限に達しました。日次リセット後にもう一度お試しください。'),
    'Too many Cloud AI requests. Please wait a moment and try again.' => context.tr(error, 'クラウドAIへのリクエストが集中しています。少し待ってからもう一度お試しください。'),
    'Cloud AI cannot check its usage limits. Please try again later; contact the developer if this continues.' => context.tr(error, 'クラウドAIの利用上限を確認できません。時間をおいてお試しください。続く場合は開発者にご連絡ください。'),
    _ => null,
  };
}
