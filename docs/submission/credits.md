# 著作物・外部技術の利用

[提出用の著作物利用シート](https://docs.google.com/spreadsheets/d/1wk7X1BCCcsC_cjzC0afQX61JET1EKskeTsUgyKShMGM/edit)に、素材、地図、ソフトウェア、外部 API の35項目を記入しました。以下は、その出典と確認方法を補う記録です。本人の確認・宣誓欄は未選択のまま残しています。

## 写真と画面素材

オンボーディングに同梱した `lantern.jpg`、`hydrangea.jpg`、`taxi.jpg` は、上野直哉の指示による OpenAI Codex 画像生成の出力を After Hue で現像したものです。3枚とも JPEG に保存し、taxi は縦長にトリミングしています。元出力と制作履歴を照合しました。生成出力は OpenAI 利用規約に基づいて利用します。

開発用の `tools/develop/photos/` にある16枚も、同じ画像生成ツールで制作した写真風サンプルです。同梱3枚の生成元を含みます。生成した PNG を JPEG に変換し、テスト用の日時・GPS・機種名を[スクリプト](../../tools/develop/tag_photos.py)で付与しています。これらは実際の撮影履歴ではありません。[生成用プロンプト](../../tools/develop/gen/PROMPT.md)に制作指示があります。

提出動画・資料の写真は、本人撮影の素材と今回の AI 生成素材のみであることを本人に確認しました。第三者の BGM は使っていません。本人撮影分は上野直哉の自作素材として記載し、生成素材と分けています。

現行の iOS / Android アプリアイコンは Flutter SDK テンプレートの標準 Flutter ロゴです。iOS の1024px画像と Android の全5サイズを SDK テンプレートと照合しました。独自制作のアイコンではありません。SDK のコードライセンスとは別に、[Flutter ブランドガイドライン](https://flutter.dev/brand)の対象です。

構成図の Google Cloud 製品アイコンは[運営提供サンプル](https://drive.google.com/file/d/1QMchEcmUG8vhI6u9WXF7sODtFKDgFscd/view)から抜粋し、縮小して配置しています。権利者は Google LLC、利用条件は [Google Cloud 製品アイコンの案内](https://cloud.google.com/icons)を参照します。

写真由来の色バッジは、その写真から抽出したテクスチャを使います。

## 地図

地図の表示にはMapLibreを使い、OpenFreeMapのタイルとフォントを取得しています。元データにはOpenStreetMap、スキーマにはOpenMapTilesが使われています。接続先とアトリビューションは[地図スタイル](../../assets/map/style.json)に記載しています。

OpenStreetMapのデータはODbL、OpenMapTilesのスキーマはCC BY 4.0で公開されており、それぞれ出典の表示が必要です。[OpenStreetMapの案内](https://www.openstreetmap.org/copyright)と[OpenMapTilesのアトリビューション案内](https://openmaptiles.org/docs/terminology/attribution/)を確認先とします。タイルの提供元は[OpenFreeMap](https://openfreemap.org/)です。

地図スタイルは OpenFreeMap Positron の構造を参照し、アプリ用に配色と表示レイヤーを調整して作成しました。参照元の[ライセンス通知](https://github.com/hyperknot/openfreemap-styles/blob/main/LICENSE.md)では、Positron のコードが BSD-3-Clause、デザインが CC BY 4.0、元の CartoDB Basemaps のデザインが CC BY 3.0 とされています。この参照関係と調整内容を提出シートにも記載しました。

## 主なソフトウェア

実際に解決されたバージョンは`pubspec.lock`とローカルのパッケージ構成から取得し、ライセンス名は各パッケージに同梱されたLICENSEを確認しました。以下は直接利用する主な依存です。表だけでは、依存先が含む第三者の権利表示すべてを置き換えられません。

| 技術 | 確認した版 | 主な用途 | 同梱LICENSE |
|---|---|---|---|
| Flutter / Dart SDK | Flutter 3.47.9 / Dart 3.13.7（開発環境） | 共通UIとアプリ処理 | FlutterのBSD-3-Clause。SDKに含まれる第三者の表示はSDK側の通知を参照 |
| [crypto](https://pub.dev/packages/crypto) | 3.0.8 | 同一ファイルのハッシュ確認 | BSD-3-Clause |
| [flutter_secure_storage](https://pub.dev/packages/flutter_secure_storage) | 11.2.0 | 匿名認証の再認証トークンを安全に保存 | BSD-3-Clause |
| [http](https://pub.dev/packages/http) | 1.6.0 | API通信 | BSD-3-Clause |
| [image](https://pub.dev/packages/image) | 4.12.0 | 画像の読み書きと変換 | MIT |
| [maplibre](https://pub.dev/packages/maplibre) | 0.3.7+1 | 地図表示 | BSD-3-Clause |
| [path_provider](https://pub.dev/packages/path_provider) | 2.1.6 | 端末内の保存先取得 | BSD-3-Clause |
| [photo_manager](https://pub.dev/packages/photo_manager) | 3.12.0 | OSの写真ライブラリ連携 | Apache-2.0 |
| [share_plus](https://pub.dev/packages/share_plus) | 13.3.1 | OSの共有画面 | BSD-3-Clause |
| [printing](https://pub.dev/packages/printing) | 5.15.1 | OSの印刷画面への受け渡し | Apache-2.0 |
| [pdf](https://pub.dev/packages/pdf) | 3.13.1 | 印刷用PDF | Apache-2.0 |

解決済みDartパッケージから収集したライセンス本文は[第三者ライセンス通知](third-party-notices.txt)に保存しています。対象と収集できなかった項目は[依存ライセンス一覧](dependency-licenses.md)に記載しています。開発用・他プラットフォーム用のパッケージも含むため、これは最終バイナリの全依存を解析したSBOMではありません。

iOSのMapLibre Nativeは、Swift Packageの固定ファイルで6.29.0を参照しています。この固定版のバイナリに同梱されたLICENSE原文は、アプリの「Settings → Licenses」から読めるよう収録しました。ネイティブの推移的依存すべてのライセンス収集を完了したという意味ではありません。Appleのカメラ・写真・物体抽出等はOS APIを利用しています。

## フォントとアイコン

iOSの本文は端末のHelvetica Neue、等幅表示はMenloを指定しています。これらのフォントファイルを独自にアプリへ同梱する実装ではありません。他プラットフォームでは標準フォントへ切り替えます。画面にはFlutterに含まれるMaterial Iconsと、アプリ独自の描画アイコンがあります。Material Iconsは使用SDKに添付されたライセンス原文を[追加ライセンス](../../lib/data/bundled_licenses.dart)に収録し、Flutterが集めたパッケージライセンスとともに設定画面から表示します。

地図用フォントはOpenFreeMapの配信元を利用します。最終配布物に別途フォントファイルを追加した場合は、そのファイルの出典とライセンスも一覧へ追加します。

## 外部AIサービスと開発支援

プロダクト内のクラウドAIには、Cloud Runを経由したVertex AIのGeminiを使用します。Firebase Authenticationで匿名認証を行い、Firestoreに利用回数を記録します。サービスから返された編集設定を使い、画像自体の描画は端末で行います。APIの利用を、第三者画像の出典や公開許可の代わりにはしません。

開発では AI による実装支援と画像生成を使いました。素材制作に使用した画像モデルの具体名は記録から確定できないため、サービス名を OpenAI Codex 画像生成として記載しています。

## 提出シートの確認欄

著作物の35行は記入・読み戻し確認済みです。別タブのチーム名は Hakumei Iro no Wasureji、メンバー名は上野直哉です。記載内容、第三者の権利、トラブル時の責任に関する本人の確認欄は、本人が内容を確認して選択するため未選択にしています。

## クラウドAIサーバーの依存

今回のAIサーバーはNode.js上で動き、Express 5.3.0、google-auth-library 11.3.4、firebase-admin 14.5.0を直接利用します。HTTP API、Google Cloudの実行用認証、Firebase認証とFirestoreの操作を担います。

`server/ai/package-lock.json` とインストールされた各パッケージから、212パッケージの宣言とLICENSE/NOTICE類を確認しました。[サーバー依存一覧](backend-dependency-licenses.md)と[収集した原文](backend-third-party-notices.txt)にまとめています。15パッケージはトップレベルの通知ファイルを収集できていません。コンテナのOSとNode.jsランタイム全体を含むSBOMではなく、未収集の扱いは一覧に残しています。

Google Cloud Run、Vertex AI、Firestore、Firebase Authenticationは外部サービスとして利用します。サービス利用条件は、ソースコードのライセンスと分けて指定シートに記載します。Exploreの追加依存やCloud Vision SafeSearchは今回の提出対象に含めません。
