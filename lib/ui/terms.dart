import 'package:flutter/material.dart';

import '../l10n/strings.dart';
import 'privacy.dart';
import 'theme.dart';
import 'widgets/common.dart';

class TermsScreen extends StatelessWidget {
  const TermsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.paddingOf(context);
    return Scaffold(
      body: ListView(
        padding: EdgeInsets.fromLTRB(20, pad.top + 4, 20, pad.bottom + 40),
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: TextAction(
              context.tr('Back', '戻る'),
              color: Neutral.secondary,
              onTap: () => Navigator.pop(context),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            context.tr('About this test', 'テスト版の利用について'),
            style: Txt.display.copyWith(fontSize: 28),
          ),
          const SizedBox(height: 12),
          Text(
            context.tr('Updated November 10, 2026', '2026年11月10日更新'),
            style: Txt.small,
          ),
          const SizedBox(height: 24),
          _paragraph(
            context.tr(
              'After Hue is an alpha for invited testers and reviewers. Features and results are still in development; unexpected behavior and temporary interruptions may occur. Keep important originals in Photos or another safe location.',
              'After Hueは、招待されたテスターと審査員に提供するアルファ版です。機能や仕上がりは開発中で、予期しない動作や一時的な停止が起きることがあります。大切な写真の原本は写真アプリなどで保管してください。',
            ),
          ),
          _paragraph(
            context.tr(
              'AI is free during this test. Per-user and service-wide usage limits control the developer’s costs. AI may become temporarily unavailable when a limit is reached. If it remains unavailable after waiting, contact the developer through your invitation channel. This app does not automatically charge you.',
              'AI機能は、このテスト期間中は無料でお試しいただけます。開発者が負担する費用を管理するため、利用者ごと、およびサービス全体に利用量の上限を設けています。上限に達すると、AIが一時的に使えなくなることがあります。時間を置いても利用できない場合は、配布時に使った連絡先から開発者へお知らせください。このアプリが利用者に自動で料金を請求することはありません。',
            ),
          ),
          _paragraph(
            context.tr(
              'AI may misunderstand your subject or intended colors. Review results before saving, sharing, or printing. Use photos you have the right or permission to process, and respect other people’s privacy and rights when sharing.',
              'AIの提案は、意図した対象や色を正しく捉えない場合があります。保存・共有・印刷の前に仕上がりをご確認ください。ご自身で扱う権利や必要な許可のある写真を使い、共有する場合は写っている人のプライバシーや第三者の権利にも配慮してください。',
            ),
          ),
          _paragraph(
            context.tr(
              'Our privacy explanation describes what is sent to cloud AI and how it is handled. Manual editing can be used without cloud AI.',
              'クラウドAIに送られる内容や保存の扱いは、プライバシーの説明をご覧ください。クラウドAIを使わずに、端末内で手動編集することもできます。',
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const PrivacyScreen()),
              ),
              child: Text(
                context.tr('Read privacy information', 'プライバシーについて読む'),
              ),
            ),
          ),
          const SizedBox(height: 16),
          _paragraph(
            context.tr(
              'The operator is the After Hue developer, GitHub @pdHaku0. Contact the developer through your invitation channel about bugs or data handling. Continued availability and a public release are not guaranteed; the test may end.',
              '運営者はAfter Hue開発者（GitHub @pdHaku0）です。不具合やデータの取り扱いに関するご連絡は、配布時に使った連絡先へお願いします。継続提供や将来の正式公開を約束するものではなく、テストの状況に応じて提供を終了する場合があります。',
            ),
          ),
          SelectableText(
            'https://github.com/pdHaku0',
            style: Txt.small.copyWith(color: Neutral.primary),
          ),
        ],
      ),
    );
  }

  Widget _paragraph(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 22),
    child: SelectableText(
      text,
      style: Txt.small.copyWith(color: Neutral.primary, height: 1.65),
    ),
  );
}
