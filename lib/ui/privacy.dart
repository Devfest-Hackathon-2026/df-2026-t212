import 'package:flutter/material.dart';

import '../l10n/strings.dart';
import 'theme.dart';
import 'widgets/common.dart';

/// Keep this explanation aligned with docs/privacy.md and the shipped AI route.
class PrivacyScreen extends StatelessWidget {
  const PrivacyScreen({super.key});

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
          Text(context.tr('Privacy', 'プライバシー'), style: Txt.display),
          const SizedBox(height: 12),
          Text(
            context.tr(
              'Updated November 10, 2026 · Test version',
              '2026年11月10日更新・テスト版',
            ),
            style: Txt.small,
          ),
          const SizedBox(height: 24),
          _section(
            context,
            'Your photos and cloud AI',
            '写真とクラウドAI',
            'After Hue keeps your library and edits on your device. When you use cloud AI for Auto or Ask, a reduced-size photo, your instructions, marks, and edit settings are sent over HTTPS to our Google Cloud Run service and Gemini on Vertex AI. The agent may also send preview images while refining an edit. If automatic developing is enabled, this can happen for newly found photos without a separate tap for each photo.',
            'After Hueのライブラリと編集内容は端末に保存します。AutoやAskでクラウドAIを使うと、縮小した写真、入力した指示、写真上のマーク、編集設定をHTTPSでGoogle Cloud Run上のサービスへ送り、Vertex AIのGeminiで処理します。編集を調整する途中のプレビュー画像も送ることがあります。自動現像がオンの場合、新しく見つかった写真ごとに操作しなくても送信されることがあります。',
          ),
          _section(
            context,
            'What stays on your device',
            '端末で行うこと',
            'Color rendering, manual editing, and preparation of print files run on your device. The app does not publish your photos to a social feed. Sharing, exporting, and printing send data to the destination you choose; that destination has its own data practices.',
            '色を残す画像処理、手動編集、印刷用ファイルの作成は端末で行います。この版には写真をSNSへ公開する機能はありません。共有・書き出し・印刷では、選んだ送信先にデータが渡り、そのサービスの取り扱いが適用されます。',
          ),
          _section(
            context,
            'Storage and service logs',
            '保存とサービスの記録',
            'Our AI relay does not save photos, prompts, or model responses to an application database or write them into application logs. Cloud Run can retain connection records such as IP addresses, request times, and status codes for service operation and security. Google may retain AI inputs and outputs for abuse monitoring or service caching under its policies. This is not a zero-retention service. Google states that it does not train or fine-tune models with this data without permission or instruction.',
            'AI中継サーバーは写真・指示・AIの応答をアプリ用データベースに保存せず、アプリのログにも書き込みません。一方、サービスの運用と安全性のため、Cloud RunにはIPアドレス、通信時刻、応答コードなどの接続記録が残ることがあります。Google側では、不正利用の監視やサービスのキャッシュのためにAIの入力・出力が保持される場合があります。保存が一切ないサービスではありません。Googleは、許可や指示なしにこれらのデータをモデルの学習・調整に使わないと説明しています。',
          ),
          _section(
            context,
            'An anonymous service identity',
            'サービス用の匿名ID',
            'Firebase Authentication creates an anonymous account so the AI service can authenticate requests and limit usage. No name or email is requested for this account. A refresh token is kept in the device’s secure storage. The service uses the account ID and IP address to control request rates. Anonymous authentication does not make network requests untraceable. To enforce shared usage limits, Firestore stores the date, request counts, and a hash derived from the date and anonymous account ID. These records do not contain photos or prompts.',
            'AIへのアクセス認証と利用量の制御のため、Firebase Authenticationで匿名アカウントを作ります。このアカウントに氏名やメールアドレスの入力は求めません。再認証用のトークンは端末の安全なストレージに保存します。サービスはアカウントIDとIPアドレスをリクエスト数の制御に使います。匿名認証は、通信の記録が残らないという意味ではありません。利用上限をサービス全体で管理するため、日付・利用回数・日付と匿名IDから作ったハッシュ値をFirestoreに保存します。この記録には写真や入力文を含めません。',
          ),
          _section(
            context,
            'Photos, camera, and maps',
            '写真・カメラ・地図',
            'Photo-library and camera access follow your device permissions. Photo dates and locations are used for your timeline and map. Map tiles and fonts are fetched from OpenFreeMap; the provider receives network requests for the displayed map area, including your IP address. Photo pixels are not sent to the map provider.',
            '写真ライブラリとカメラには、端末で許可された範囲でアクセスします。写真の日時・位置情報は、時系列表示や地図に使います。地図タイルと地図用フォントはOpenFreeMapから取得するため、表示する地図範囲へのリクエストとIPアドレスが提供元に渡ります。写真の画像自体は地図提供元へ送りません。',
          ),
          _section(
            context,
            'Your choices and deletion',
            '利用の選択と削除',
            'You can turn off cloud AI or automatic developing in Settings and continue manual editing. Camera and photo access can be changed in your device settings. Removing a photo from After Hue removes its entry and edits from this app, not the original in Photos. It does not delete Firebase authentication records, usage records, service logs, or data already handled by Google. This test version does not include an in-app account-deletion feature. For data handling or deletion requests, contact the developer through the channel used to invite you to this test.',
            '設定でクラウドAIへの送信や自動現像をオフにでき、手動編集は引き続き使えます。カメラや写真へのアクセスは端末の設定で変更できます。After Hueから写真を削除すると、このアプリ内の登録と編集内容が削除されます。写真アプリの原本は削除しません。この操作ではFirebaseの認証記録、利用回数の記録、サービスのログ、Googleですでに処理されたデータは削除されません。テスト版にはアプリ内のアカウント削除機能がありません。データの取り扱いや削除については、配布時に使った連絡先から開発者へご連絡ください。',
          ),
          _section(
            context,
            'Developer',
            '開発者',
            'After Hue developer · GitHub @pdHaku0. The profile below identifies the developer. This policy describes the test version and will be revised if the data flow changes.',
            'After Hue開発者・GitHub @pdHaku0。開発者のプロフィールは下記です。この説明はテスト版を対象としており、データの取り扱いが変わる場合は更新します。',
          ),
          _url('https://github.com/pdHaku0'),
          const SizedBox(height: 24),
          Text(
            context.tr('Service policies and references', 'サービスの方針と参考資料'),
            style: Txt.label,
          ),
          const SizedBox(height: 12),
          _url(
            'https://cloud.google.com/vertex-ai/generative-ai/docs/data-governance',
          ),
          _url(
            'https://cloud.google.com/vertex-ai/generative-ai/docs/learn/abuse-monitoring',
          ),
          _url('https://firebase.google.com/support/privacy'),
          _url('https://openfreemap.org/privacy/'),
        ],
      ),
    );
  }

  Widget _section(
    BuildContext context,
    String titleEn,
    String titleJa,
    String bodyEn,
    String bodyJa,
  ) => Padding(
    padding: const EdgeInsets.only(bottom: 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(context.tr(titleEn, titleJa), style: Txt.label),
        const SizedBox(height: 8),
        SelectableText(
          context.tr(bodyEn, bodyJa),
          style: Txt.small.copyWith(color: Neutral.primary, height: 1.65),
        ),
      ],
    ),
  );

  Widget _url(String url) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: SelectableText(
      url,
      style: Txt.small.copyWith(color: Neutral.primary),
    ),
  );
}
