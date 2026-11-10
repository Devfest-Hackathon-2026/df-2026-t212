# After Hueのプライバシーについて

2026年11月10日更新。招待されたテスターと審査員向けのアルファ版を対象とします。

## 写真とクラウドAI

After Hueのライブラリと編集内容は端末に保存します。AutoやAskでクラウドAIを使うと、縮小した写真、入力した指示、写真上のマーク、編集設定をHTTPSでGoogle Cloud Run上のサービスへ送り、Vertex AIのGeminiで処理します。編集を調整する途中のプレビュー画像も送ることがあります。自動現像がオンの場合、新しく見つかった写真ごとに操作しなくても送信されることがあります。

色を残す画像処理、手動編集、印刷用ファイルの作成は端末で行います。この版には写真をSNSへ公開する機能はありません。共有・書き出し・印刷では、選んだ送信先にデータが渡り、そのサービスの取り扱いが適用されます。

## 保存とサービスの記録

AI中継サーバーは写真・指示・AIの応答をアプリ用データベースに保存せず、アプリのログにも書き込みません。一方、サービスの運用と安全性のため、Cloud RunにはIPアドレス、通信時刻、応答コードなどの接続記録が残ることがあります。[Cloud Runのログ](https://cloud.google.com/run/docs/logging)、[通信ログの項目](https://cloud.google.com/logging/docs/reference/v2/rest/v2/LogEntry#HttpRequest)

Google側では、不正利用の監視やサービスのキャッシュのためにAIの入力・出力が保持される場合があります。保存が一切ないサービスではありません。Googleは、許可や指示なしにこれらのデータをモデルの学習・調整に使わないと説明しています。[Google Cloudのデータ管理](https://cloud.google.com/vertex-ai/generative-ai/docs/data-governance)、[不正利用の監視](https://cloud.google.com/vertex-ai/generative-ai/docs/learn/abuse-monitoring)

## サービス用の匿名ID

AIへのアクセス認証と利用量の制御のため、Firebase Authenticationで匿名アカウントを作ります。このアカウントに氏名やメールアドレスの入力は求めません。再認証用のトークンは端末の安全なストレージに保存します。サービスはアカウントIDとIPアドレスをリクエスト数の制御に使います。匿名認証は、通信の記録が残らないという意味ではありません。

利用上限をサービス全体で管理するため、日付・利用回数・日付と匿名IDから作ったハッシュ値をFirestoreに保存します。この記録には写真や入力文を含めません。

Firebaseは認証時のIPアドレスなどを不正利用防止にも使います。Googleの説明では、認証に関するその他の情報は開発者がアカウントの削除を開始するまで保持されます。[Firebaseのプライバシー情報](https://firebase.google.com/support/privacy)

## 写真・カメラ・地図

写真ライブラリとカメラには、端末で許可された範囲でアクセスします。写真の日時・位置情報は、時系列表示や地図に使います。

地図タイルと地図用フォントはOpenFreeMapから取得するため、表示する地図範囲へのリクエストとIPアドレスが提供元に渡ります。写真の画像自体は地図提供元へ送りません。提供元は通常のアクセスログにIPアドレスを保存しないと説明していますが、エラーやセキュリティ上の問題がある場合の保存についても定めています。[OpenFreeMapのプライバシーポリシー](https://openfreemap.org/privacy/)

## 利用の選択と削除

設定でクラウドAIへの送信や自動現像をオフにでき、手動編集は引き続き使えます。カメラや写真へのアクセスは端末の設定で変更できます。

After Hueから写真を削除すると、このアプリ内の登録と編集内容が削除されます。写真アプリの原本は削除しません。この操作ではFirebaseの認証記録、利用回数の記録、サービスのログ、Googleですでに処理されたデータは削除されません。テスト版にはアプリ内のアカウント削除機能がありません。データの取り扱いや削除については、アプリの配布時に使った連絡先から開発者へご連絡ください。

## 開発者と変更

運営者はAfter Hue開発者（[GitHub @pdHaku0](https://github.com/pdHaku0)）です。この説明はテスト版を対象としており、データの取り扱いが変わる場合は更新します。

---

## English

After Hue keeps your library and edits on your device. When you use cloud AI for Auto or Ask, reduced-size photos, your instructions, marks, edit settings, and preview images may be sent over HTTPS to our Google Cloud Run service and Gemini on Vertex AI. With automatic developing enabled, newly found photos can be sent without a separate action for each photo.

Color rendering, manual editing, and preparation of print files run locally. This version has no social publishing feature. Sharing, exporting, and printing send data to your chosen destination under that destination's practices.

Our AI relay does not persist photos, prompts, or responses to an application database or application logs. Cloud Run can retain connection records including IP addresses, request times, and response status for operation and security. Google may retain AI inputs and outputs for abuse monitoring or caching under the policies linked above. This is not a zero-retention service. Google states that it does not train or fine-tune models with this data without permission or instruction.

Firebase Authentication creates an anonymous service identity for authentication and usage limits, without requesting your name or email. Its refresh token is stored in device secure storage. The service uses the account ID and IP address for rate limits. Firebase also processes authentication connection information under its privacy policy. Anonymous authentication does not make requests untraceable. To enforce shared usage limits, Firestore stores the date, request counts, and a hash derived from the date and anonymous account ID. These records do not contain photos or prompts.

Photo and camera access follow device permissions. Photo dates and locations support timeline and map views. OpenFreeMap receives map-area and font requests, including the network IP address; it does not receive your photo pixels. Its own privacy policy applies.

You can disable cloud AI or automatic developing in Settings and continue manual editing. Removing a photo from After Hue removes the app entry and edits, not the original photo, Firebase records, usage records, service logs, or data already handled by Google. This test version has no in-app account-deletion feature. For data handling or deletion requests, contact the After Hue developer through the channel used to invite you to this test. Developer profile: [GitHub @pdHaku0](https://github.com/pdHaku0).
