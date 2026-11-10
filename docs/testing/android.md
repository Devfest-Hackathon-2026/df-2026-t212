# Androidテスト引き継ぎ

対象ブランチ: `first-build`。まず写真の取り込みから編集・共有までを実機で試すための準備です。Android全機能の移植完了を意味しません。

## 招待されたテスターがまず使うもの

このPrivateリポジトリの招待を受け入れたら、[Android test build](https://github.com/pdHaku0/afterhue/actions/workflows/android.yml) の成功した手動実行から **`after-hue-android-ai-debug`** artifactをダウンロードし、ZIP内のAPKを端末にインストールしてください。所有者と同じAI設定を組み込んであるため、APIキーの用意は不要です。

最新版を作る場合は **Run workflow → Branch: first-build → with_aiを有効 → Run workflow**。通常のPush/PRではキーなしAPKを作ります。artifactは3日で失効しますが、ダウンロードしたAPK自体は期限切れになりません。

GitHub Secret `AFTER_HUE_TEST_DEFINES` はビルド時だけ読み出し、ソースには入れません。**APKからキーを取り出すことは可能**なので、AI入りAPKは招待したテスターだけで使用し、公開・再配布しないでください。AIビルドはPrivateリポジトリでのみ動くようにしています。

ソースから `flutter run` して開発する場合は以下の手順です。ローカルのキーなし実行と、AI入りAPKのテストを併用できます。

## 1. 環境

- Flutter **3.47.9** / Dart **3.13.7**（このリポジトリの開発・CIと同じバージョン）
- Android Studio / Android SDK。`flutter doctor -v` のAndroid toolchainを通す
- JDK **17**、SDK Platform **36**。NDKはFlutter指定の **28.2.13676358**
- Android **7.0 / API 24以上**。最初はAndroid 13または14以降の実機を推奨
- USBデバッグを有効にし、PCの接続を端末で許可

環境構築は[Flutter公式のAndroidセットアップ](https://docs.flutter.dev/platform-integration/android/setup)を参照。SDKライセンスが未確認の場合は `flutter doctor --android-licenses` を実行して内容を確認してください。

```sh
git clone --branch first-build https://github.com/pdHaku0/afterhue.git
cd afterhue
flutter pub get
flutter doctor -v
flutter devices
flutter run -d <Androidのdevice-id>
```

初回のGradle/SDKダウンロードには時間がかかります。`android/local.properties` は各PC用に生成されるため共有しません。

## 2. APIキーなしで試せる範囲

- オンボーディング、写真のアクセス許可、複数インポート
- ギャラリー、選択・グループ、詳細表示、Remove、Activity
- Keep / Excludeの色選択、Areaの手描き、Boundary / Feather
- Tone、彩度、Crop、回転、Undo/Redo、保存、共有
- Auto（端末内の色の強さを使う簡易現像。AIの被写体判断とは異なる）
- GPS付き写真のMap表示（位置情報がない写真は地図に出ません）

自然言語の **AskはAPIキーなしでは使えません**。この状態でのAskエラーはAndroid固有の不具合ではありません。SettingsのModelが `on-device` ならキーなしの状態です。

## 3. AIも試す場合

`config/development.example.json` を `config/development.local.json` にコピーし、`OPENAI_API_KEY` に自分のテスト用キーを入れてください。`.local.json` はGit管理対象外です。

`OPENAI_MODEL` / `OPENAI_JUDGE_MODEL` はこのプロジェクトで使用している設定です。キーの所属プロジェクトで利用できるモデルに応じて変更できます。キー変更後はホットリロードではなく、停止して再ビルドしてください。

```sh
flutter run -d <Androidのdevice-id> --dart-define-from-file=config/development.local.json
```

この開発構成では写真の縮小版と編集依頼がOpenAIに送られ、API料金が発生します。キーはアプリに組み込まれます。自分のキーでビルドしたAPKも公開しないでください。所有者のキーを使う場合は、上記の手動AIビルドを利用してください。

`AFTER_HUE_DEMO_TOOLS=true` にするとSettingsに確認付きの初期化が出ます。After Hueの編集・設定・履歴を消してオンボーディングに戻します。端末の写真は削除しません。

## 4. Androidで未対応・要確認の点

| 項目 | 状態 |
| --- | --- |
| アプリ内カメラ・ライブ現像 | iOS専用。Androidでは案内を表示。端末のカメラで撮影してから `+` で取り込む |
| タップした物体の自動抽出 | iOS Vision専用。AndroidではAreaを手描きする。AIも抽出できない場合は多角形を使う |
| Appleの端末内採用判定 | Androidでは利用しない。端末内の色判定＋設定したクラウドモデルを使用 |
| 原本の保持・更新 | Android用に写真ライブラリから内容をコピーして保持。更新検出はMediaStoreの更新日時による。外部編集アプリが別の写真として保存した場合は別写真となる |
| 写真の位置 | 写真アクセスに加え、メディア位置情報の権限と写真自体のGPSが必要。ライブの端末位置は取得しない |
| Android実機の描画・戻る・キーボード | 今回の重点確認対象。実機での動作保証はまだしない |

写真権限は画像のみを要求します。Android 13以降の画像権限と14以降の限定アクセスは[photo_managerの公式手順](https://pub.dev/packages/photo_manager)に沿って設定しています。

## 5. 最初の10分の確認

1. 写真アクセスを拒否しても固まらず、再許可できるか。Android 14以降では「選択した写真のみ」も試す。
2. `+` から3枚を手動インポートし、未現像のまま全部表示されるか。複数選択とスワイプ選択も試す。
3. 1枚を開き、色のKeep/Exclude、手描きArea、彩度、Cropと回転を変更。Done→再度開く→アプリを終了して再起動しても保持されるか。
4. 3枚をAutoに入れ、Queued/進捗/完了を確認。処理中の1枚をRemoveし、残りが進むか。
5. 共有先アプリに加工済み画像が渡るか。端末の原本が変わっていないか。
6. AI設定ありならAskで日本語入力。ソフトウェアキーボードを出したまま写真とSendが見えるか。処理中にDone→Activity→結果へ戻れるか。
7. Map、画面回転、Androidのシステム戻る、ナビゲーションバーとの重なりを確認。
8. 外部アプリで原本を上書き編集し、After Hueに戻る。元の見た目が勝手に変わらず、更新の確認ができるか。

## 6. APKと不具合報告

GitHub Actionsの **Android test build** が成功すると `after-hue-android-local-debug`（通常実行）または `after-hue-android-ai-debug`（手動AI実行）artifactからAPKを取得できます。どちらも初期化オプションありのテスト用です。リリース署名・ストア配布向けではありません。

手元でAPKを作る場合:

```sh
flutter build apk --debug --dart-define=AFTER_HUE_DEMO_TOOLS=true
# build/app/outputs/flutter-apk/app-debug.apk
```

報告には次を添えてください。

```text
コミット:
端末 / Androidバージョン:
APIキー設定: なし / あり（値は書かない）
写真権限: 全件 / 限定 / 拒否
再現手順:
期待した動き:
実際の動き:
スクリーンショット・録画・該当エラーログ:
```

`flutter run` のエラー部分があると調査しやすいです。ログに含まれる編集依頼文や写真情報は、共有してよい範囲だけ添付してください。
