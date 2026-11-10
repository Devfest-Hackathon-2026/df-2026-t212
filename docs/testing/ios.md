# MacでAfter HueのiOS版を試す

After Hueは、写真の中で残したい色を選んで現像するアプリです。iOS版では、手動編集やAIへの編集依頼に加え、カメラのライブ現像と物体の自動抽出も実装しています。

この手順ではMacを開発用のPCとして使い、iPhoneのSimulatorか実機でアプリを起動します。macOSネイティブ版はまだテスト対象ではありません。GitHubのAndroid用APKもiPhoneにはインストールできません。

## まずSimulatorで起動する

現在の開発ブランチは `first-build` です。開発元ではFlutter 3.47.9、Dart 3.13.7、Xcode 27.2を使用し、iOS 26.4.1のSimulatorとiOS 27.2のiPhoneで起動を確認しています。まずこの構成に合わせると、環境差による問題を減らせます。

XcodeにはiOS 27向けのFoundationModels APIを使うコードが含まれます。アプリを動かせるiOSのバージョンと、ビルドに必要なXcodeのバージョンは別です。古いXcodeでのビルドはまだ確認していません。

```sh
git clone --branch first-build https://github.com/pdHaku0/afterhue.git
cd afterhue
flutter pub get
flutter doctor -v
```

XcodeのDevice HubまたはSimulatorでiPhoneを起動してから、次を実行してください。

```sh
flutter devices
flutter run -d <iPhone-Simulatorのdevice-id>
```

`flutter devices` に出てくる `macos` ではなく、iPhone SimulatorのIDを選びます。初回はSwift Package Managerの依存解決に時間がかかります。Simulatorへのインストールには、実機用の署名設定は必要ありません。

Simulatorの写真ライブラリが空なら、テスト用の写真を追加します。次のコマンドは、起動中のSimulatorに指定した写真を入れます。

```sh
xcrun simctl addmedia booted /absolute/path/to/photo.jpg
```

アプリのオンボーディングで写真へのアクセスを許可し、画面下の `+` から取り込んでください。

## AIを使うための設定

APIキーなしでも手動編集と、端末内の色選択による簡易Autoは動きます。自然言語で編集を頼むAskには、AI設定が必要です。

ローカルでAIを使うキーは、リポジトリとは別に受け取ります。`config/development.example.json` を `config/development.local.json` にコピーして、`OPENAI_API_KEY` に受け取った値を入れてください。設定ファイルはGit管理対象外なので、コミットする必要はありません。

```sh
cp config/development.example.json config/development.local.json
# development.local.json の OPENAI_API_KEY を設定する
flutter run -d <iPhone-Simulatorのdevice-id> --dart-define-from-file=config/development.local.json
```

キーを設定する前にアプリを起動していた場合は、一度停止してからこのコマンドで起動し直します。ホットリロードだけではビルド時の設定は変わりません。

所有者のキーを共有する場合は、1Passwordなどの共有リンクを別途受け取る方法を想定しています。GitHub Secretに登録された値を、GitHub画面からコピーして使うことはできません。キーを使うと、写真の縮小版と編集依頼がOpenAIに送られます。テストには共有してよい写真を使ってください。

## iPhone実機で試す

実機で起動する場合は、`ios/Runner.xcworkspace` をXcodeで開き、RunnerのSigning & Capabilitiesで自分のTeamを指定します。リポジトリには開発元の署名設定があるため、そのままでは他の開発者の環境で署名できるとは限りません。必要なら自分のTeamで使えるBundle Identifierに変更してください。個人用に変えた署名設定はコミットしないでください。

実機が `flutter devices` に表示されたら、起動コマンドのdevice-idを実機のものに置き換えます。

カメラのないSimulatorでは、ライブラリの写真をプレビューの代わりに使う場合があります。実際のレンズ切り替え、露出、シャッターの動きはiPhoneで確認してください。

## 確認してほしい操作

最初は写真を3枚ほど取り込み、1枚を編集して保存し、開き直すところまで試してください。KeepとExcludeの色、Areaの手描きと物体抽出、Cropや回転、彩度、UndoとRedoを触ってみてください。Areaの操作中にピンチしても、意図しない範囲が追加されないことも確認したい点です。

Askはソフトウェアキーボードを実際に表示して確認してください。空欄から入力を始める、日本語を変換する、複数行を書く、キーボードを閉じてもう一度入力する、という流れで、写真とSendが見えるかを見ます。Macのハードウェアキーボードだけで操作すると、iPhoneで起こるレイアウトの問題を見落とします。

送信後はDoneで編集画面を離れてみてください。エージェントの処理は続き、ギャラリーに処理中の表示が出ます。完了後にActivityから結果へ戻れることを確認します。

そのほか、起動時のサムネイル表示、写真を開いたときのちらつき、Remove直後に写真が消えるかも見てください。写真アプリで原本を編集した場合は、After Hueの保存済みの見た目が勝手に変わらず、更新を確認して適用・取り消しできることを確認したいと考えています。

不具合は[共通の報告テンプレート](android.md#不具合を見つけたら)を使ってIssueに書いてください。iPhoneの機種とOS、再現手順、画面録画があると調査しやすくなります。
