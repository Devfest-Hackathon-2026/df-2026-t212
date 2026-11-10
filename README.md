# After Hue

After Hueは、写真の中で残したい色を選び、それ以外をモノクロにするアプリです。自分で色や範囲を指定できるほか、Autoで現像を任せたり、Askで「オレンジを除いてピンクを残して」のように編集を頼んだりできます。取り込んだ写真はギャラリーと地図から見返せます。

このリポジトリは開発中のアプリを友人に試してもらうために共有しています。現在の開発版は `first-build` ブランチです。GitHubで読むときも、ソースを取得するときも、このブランチを選んでください。

## アプリを試す

Androidでは、GitHub Actionsで作ったAPKをインストールできます。AI入りのテストAPKには所有者の設定が入っているため、テスターがAPIキーを用意する必要はありません。[Androidのテスト手順](docs/testing/android.md)に、APKの入手から確認してほしい操作までをまとめています。

iPhoneでは、MacとXcodeを使ってソースから起動します。Simulatorなら実機の署名設定をせずにUIを確認できます。[iOSのテスト手順](docs/testing/ios.md)を参照してください。Macはここでは開発用のPCを指し、macOSネイティブ版はまだテスト対象にしていません。

両方とも、まず写真を取り込み、編集して保存し、もう一度開くところまで試してください。Androidは初期対応の段階なので、アプリ内カメラと物体の自動抽出には未対応です。使える範囲と代わりの操作はAndroidの手順書に記載しています。

## ソースを取得する

```sh
git clone --branch first-build https://github.com/pdHaku0/afterhue.git
cd afterhue
flutter pub get
```

開発にはFlutter 3.47.9とDart 3.13.7を使っています。起動するには、これに加えてAndroid SDKまたはXcodeが必要です。OSごとの準備と起動コマンドは、それぞれのテスト手順にあります。

APIキーなしでも、手動編集と端末内の色選択による簡易Autoは動きます。自然言語のAskにはAI設定が必要です。ローカルの設定ファイルや受け取ったAPIキーはコミットしないでください。

## 開発時の確認

```sh
flutter analyze --no-fatal-infos
flutter test
```

共有UIと編集処理は `lib/`、iOS専用のカメラや物体抽出は `ios/Runner/` にあります。編集や原本更新の考え方は `docs/design/` にまとめています。

[Android test build](https://github.com/pdHaku0/afterhue/actions/workflows/android.yml)はテストとAPKのビルドを実行します。通常のPushやPRではキーなしのAPKを作り、手動実行で `with_ai` を有効にしたときだけAI入りAPKを作ります。
