# After Hue

写真から残したい色を選び、それ以外をモノクロにするFlutterアプリです。
写真の取り込み、手動編集、Auto現像、AIへの編集依頼、地図、Activityを実装しています。

現在の開発ブランチは **`first-build`** です。iOSを中心に開発しており、Androidは初期テスト段階です。

## Androidで試す

[Androidテスト手順・対応状況](docs/testing/android.md) に、セットアップ、APIキーなしでの起動、AI設定、確認項目をまとめています。

```sh
git clone --branch first-build https://github.com/pdHaku0/afterhue.git
cd afterhue
flutter pub get
flutter devices
flutter run -d <Androidのdevice-id>
```

Flutter **3.47.9** / Dart **3.13.7** を使用しています。Android SDKのセットアップは別途必要です。
APIキーなしでも手動編集と端末内の色選択によるAutoを試せます。自然言語のAskにはAI設定が必要です。

[Android test build](https://github.com/pdHaku0/afterhue/actions/workflows/android.yml) はテストとAPKビルドを実行し、成功時にAPIキーを含まないデバッグAPKを保存します。

## 開発用チェック

```sh
flutter analyze --no-fatal-infos
flutter test
```

`docs/design/` に編集・原本更新などの設計メモがあります。ネイティブ実装は `ios/Runner/`、共有UI・編集処理は `lib/` です。
