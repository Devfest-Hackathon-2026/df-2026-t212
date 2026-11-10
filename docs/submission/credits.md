# 著作物・外部技術の利用

この一覧は、[指定の著作物利用シート](https://docs.google.com/spreadsheets/d/1oU3kmE6v9MR_1e0Exetiy8hVZ4ToiR2dpzwBiFSuL3I/edit)へ転記するための作業版です。アプリに同梱する素材、デモだけで使う写真、外部から取得する地図、ソフトウェアの依存関係を分けています。出典が未確定の項目を、確認済みとして扱ってはいません。

## 写真と画面素材

| 対象 | 使用箇所 | 確認できる出典・制作記録 | 残る確認 |
|---|---|---|---|
| `assets/samples/lantern.jpg`、`hydrangea.jpg`、`taxi.jpg` | オンボーディング、テスト、印刷表示例 | リポジトリに同梱。対応する被写体の生成指示が[生成用プロンプト](../../tools/develop/gen/PROMPT.md)にある | 各同梱ファイルと元出力の対応、使用した生成サービス・モデル・日付を最終制作記録で照合する |
| `tools/develop/photos/`の16枚 | 開発・デモ用の入力写真 | [生成用プロンプト](../../tools/develop/gen/PROMPT.md)、[EXIF付与スクリプト](../../tools/develop/tag_photos.py) | 最終動画で実際に使用したファイルを列挙し、生成サービスと利用条件の確認記録を添える |
| 実機の写真ライブラリ内の写真 | 実機デモ・検証 | 写真の所有者が選択した素材。リポジトリだけでは撮影者・公開許可を特定できない | 最終動画で見せる写真の撮影者、公開可否、写り込みを確認する |
| 印刷レイアウトの生成案 | 開発中の比較、採用案の検討 | 画像生成モデルの案を参考にし、実際のUIと書き出し処理はFlutterで実装 | 提出資料に生成案そのものを載せる場合、生成サービス・モデルを制作記録から記入する |
| アプリアイコン | ホーム画面・配布物 | `ios/Runner/Assets.xcassets/AppIcon.appiconset/`に同梱 | 元デザインの制作者と制作方法を確定する |

生成した16枚には、デモのための撮影日時・GPS・機種名をスクリプトで付けています。これらは実際の撮影履歴ではありません。動画や説明資料では「生成写真によるデモデータ」と明示し、撮影場所・日時に関する実績として扱いません。

写真由来の色バッジは、その写真から抽出したテクスチャを使います。バッジだけ別のストック素材を利用する仕組みではありません。

## 地図

地図の表示にはMapLibreを使い、OpenFreeMapのタイルとフォントを取得しています。元データにはOpenStreetMap、スキーマにはOpenMapTilesが使われています。接続先とアトリビューションは[地図スタイル](../../assets/map/style.json)に記載しています。

OpenStreetMapのデータはODbL、OpenMapTilesのスキーマはCC BY 4.0で公開されており、それぞれ出典の表示が必要です。[OpenStreetMapの案内](https://www.openstreetmap.org/copyright)と[OpenMapTilesのアトリビューション案内](https://openmaptiles.org/docs/terminology/attribution/)を確認先とします。タイルの提供元は[OpenFreeMap](https://openfreemap.org/)です。

現在の地図画面には `© OpenMapTiles © OpenStreetMap` のテキストがあります。最終提出前に、提供元の表記、ライセンスへの導線、スクリーンショット・動画内での見え方まで確認します。この資料に出典を書いたことだけを、アプリ内の表示要件を満たした証拠にはしません。

## 主なソフトウェア

実際に解決されたバージョンは`pubspec.lock`とローカルのパッケージ構成から取得し、ライセンス名は各パッケージに同梱されたLICENSEを確認しました。以下は直接利用する主な依存です。表だけでは、依存先が含む第三者の権利表示すべてを置き換えられません。

| 技術 | 確認した版 | 主な用途 | 同梱LICENSE |
|---|---|---|---|
| Flutter / Dart SDK | Flutter 3.47.9 / Dart 3.13.7（開発環境） | 共通UIとアプリ処理 | FlutterのBSD-3-Clause。SDKに含まれる第三者の表示はSDK側の通知を参照 |
| [crypto](https://pub.dev/packages/crypto) | 3.0.8 | 同一ファイルのハッシュ確認 | BSD-3-Clause |
| [http](https://pub.dev/packages/http) | 1.6.0 | API通信 | BSD-3-Clause |
| [image](https://pub.dev/packages/image) | 4.12.0 | 画像の読み書きと変換 | MIT |
| [maplibre](https://pub.dev/packages/maplibre) | 0.3.7+1 | 地図表示 | BSD-3-Clause |
| [path_provider](https://pub.dev/packages/path_provider) | 2.1.6 | 端末内の保存先取得 | BSD-3-Clause |
| [photo_manager](https://pub.dev/packages/photo_manager) | 3.12.0 | OSの写真ライブラリ連携 | Apache-2.0 |
| [share_plus](https://pub.dev/packages/share_plus) | 13.3.1 | OSの共有画面 | BSD-3-Clause |
| [printing](https://pub.dev/packages/printing) | 5.15.1 | OSの印刷画面への受け渡し | Apache-2.0 |
| [pdf](https://pub.dev/packages/pdf) | 3.13.1 | 印刷用PDF | Apache-2.0 |

解決済みDartパッケージから収集したライセンス本文は[第三者ライセンス通知](third-party-notices.txt)に保存しています。対象と収集できなかった項目は[依存ライセンス一覧](dependency-licenses.md)に記載しています。開発用・他プラットフォーム用のパッケージも含むため、これは最終バイナリの全依存を解析したSBOMではありません。

iOSのMapLibre Nativeは、Swift Packageの固定ファイルで6.29.0を参照しています。ネイティブのバイナリに含まれる全ライセンスの収集と最終配布物での表示は、この一覧とは別に確認が必要です。Appleのカメラ・写真・物体抽出等はOS APIを利用しています。

## フォントとアイコン

iOSの本文は端末のHelvetica Neue、等幅表示はMenloを指定しています。これらのフォントファイルを独自にアプリへ同梱する実装ではありません。他プラットフォームでは標準フォントへ切り替えます。画面にはFlutterに含まれるMaterial Iconsと、アプリ独自の描画アイコンがあります。

地図用フォントはOpenFreeMapの配信元を利用します。最終配布物に別途フォントファイルを追加した場合は、そのファイルの出典とライセンスも一覧へ追加します。

## 外部AIサービスと開発支援

プロダクト内のクラウドAIには、現時点ではOpenAI APIを使用しています。サービスから返された編集設定を使い、画像自体の描画は端末で行います。APIの利用を、第三者画像の出典や公開許可の代わりにはしません。

開発では、AIによる実装支援と画像生成を使っています。最終の著作物利用シートには、利用した各サービス、生成した素材、採用範囲を制作記録に合わせて記入します。現在のリポジトリから確認できないモデル名や利用条件は、この作業版では確定していません。

## 指定シートへ転記する際の不足

指定様式の列は「著作物の名称」「種類」「入手元URL」「権利者名（著作者名）」「ライセンス形態」「改変の有無」です。上の一覧から転記する際は、写真ごとの制作者と生成記録、アプリアイコンの出典、改変の内容を補います。パッケージ名だけで権利者名を置き換えず、収集したLICENSEの著作権表示を確認します。

別シートにはチーム名とメンバーの確認欄、記載の正確さ・第三者の権利・トラブル時の責任に関する確認があります。これは各メンバーが実際の利用内容を確認して記入する欄です。この資料の作成をもって、確認や同意が完了したことにはしません。

## Exploreを提出に含める場合

Exploreブランチでは、Node.jsのバックエンドに `express`、`firebase-admin`、`@google-cloud/vision`、`sharp` を追加しています。また、Cloud Run、Firestore、Cloud Storage、Firebase Authentication、Cloud Vision SafeSearchを使用する構成です。現時点では未デプロイであり、既存アプリのライセンス収集には、これらの追加依存を含めていません。

Exploreを採用する場合は、そのブランチのロックファイルと実際のLICENSEから、追加依存とネイティブ画像ライブラリの通知を収集します。Googleの各サービスも「API」として利用条件を確認し、指定シートへ記載します。単にGCPプロジェクトを作成したことを、これらのサービスの利用・審査適合の証拠にはしません。
