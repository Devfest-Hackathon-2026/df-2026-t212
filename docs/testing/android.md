# AndroidでAfter Hueを試す

After Hueは、写真の一部の色を残して現像するアプリです。今回見てほしいのは、写真を取り込んで編集し、保存した結果を見返すまでの操作です。Androidは初期対応なので、まずこの流れが実際の端末で使えるかを確認したいと考えています。

ソースをビルドしなくても、GitHubからテスト用APKを取得できます。AI入りのAPKには所有者のAPI設定が入っているため、自分のAPIキーやOpenAIアカウントを用意する必要はありません。

## APKを入手して起動する

リポジトリへの招待を受け入れたら、[Android test build](https://github.com/pdHaku0/afterhue/actions/workflows/android.yml)を開いてください。成功した手動実行を選び、Artifactsにある `after-hue-android-ai-debug` をダウンロードします。ZIPを展開するとAPKが入っているので、Android端末にコピーして開き、インストールします。

新しいAPKが必要なときは、同じ画面のRun workflowからブランチに `first-build` を選び、`with_ai` を有効にして実行します。完了するまではAPKを取得できません。artifactの保存期間は3日です。期間を過ぎたら作り直せますが、すでにインストールしたアプリはそのまま使えます。

`after-hue-android-local-debug` という名前のAPKはキーなし版です。手動編集と簡易Autoには使えますが、自然言語のAskは使えません。AIを試すときは名前に `ai` が入った方を選んでください。

AI入りAPKは招待したテスターだけで使用してください。キーはソースには含めていませんが、ビルド済みアプリから取り出すことは可能です。APKを公開したり、他の人に再配布したりしないでください。AIを使うと、写真の縮小版と編集依頼がOpenAIに送られ、所有者のAPI利用料が発生します。

## 最初に試してほしい操作

起動すると写真へのアクセスを求められます。まずテスト用の写真を許可し、画面下の `+` から3枚ほど手動で取り込んでください。未現像の写真がすべて表示されるか、複数選択やスワイプ選択ができるかを確認します。Android 14以降なら、写真をすべて許可する場合と、選んだ写真だけを許可する場合の両方を試せると助かります。

次に1枚を開き、編集画面でKeepとExcludeの色、手描きのArea、彩度、Cropや回転を変えてください。Doneで保存したあと、写真を開き直して変更が残るかを見ます。アプリを終了して再起動したときも、同じ状態に戻れるかを確認してください。共有した画像に加工が反映され、端末の写真ライブラリにある原本が変わっていなければ、この流れは正常です。

Autoは複数枚で試してください。待機中のQueued、処理中の進捗、完了が分かるかを見ます。処理中の1枚をAfter HueからRemoveしたとき、その写真の処理が止まり、残りの写真が進むかも確認したい点です。

AI入りAPKでは、Askに日本語で編集を頼んでください。ソフトウェアキーボードを出した状態で写真とSendが見えるか、変換や複数行の入力ができるかを見ます。送信後にDoneで編集画面を離れても、処理は続きます。ギャラリーで処理中だと分かり、Activityから結果へ戻れることを確認してください。

そのほか、Androidのシステム戻る、画面回転、画面下のナビゲーションバーとの重なりも確認対象です。GPS付きの写真はMapにも表示されます。位置情報のない写真がMapに出ないのは想定どおりです。

外部の写真編集アプリで原本を上書きした場合、After Hueの保存済みの見た目は勝手に変わらず、更新を確認して適用する流れになります。別の写真として保存した場合は、新しい写真として扱います。外部アプリによって保存方法や更新日時の扱いが異なるため、ここも実機で確認したい箇所です。

## まだAndroidではできないこと

アプリ内カメラとライブ現像はiOS専用です。Androidではカメラボタンに案内が出ます。端末のカメラで撮影してから、After Hueの `+` で取り込んでください。

Areaでタップした物体を自動で切り抜く機能も、現在はiOS専用です。Androidでは手描きで範囲を指定できます。AIが物体抽出を使えない場合は、多角形で範囲を指定します。

Appleの端末内モデルもAndroidでは使いません。キーなし版のAutoは端末内で色の強さをもとに選び、AI入り版は設定したクラウドモデルを使います。この違いは不具合ではありません。

このテストAPKはデバッグ用です。Android実機での描画や速度はまだ検証途中なので、iOS版との性能比較には使わず、まず操作が成立するかを見てください。

## ソースから起動する場合

開発ブランチは `first-build` です。Flutter 3.47.9、Dart 3.13.7、JDK 17を用意し、[Flutter公式のAndroidセットアップ](https://docs.flutter.dev/platform-integration/android/setup)に沿ってAndroid SDKを設定してください。このプロジェクトではSDK Platform 36とNDK 28.2.13676358を使います。端末の最低OSはAndroid 7.0（API 24）です。

```sh
git clone --branch first-build https://github.com/pdHaku0/afterhue.git
cd afterhue
flutter pub get
flutter doctor -v
flutter devices
flutter run -d <Androidのdevice-id>
```

`flutter doctor -v` でAndroid toolchainの問題を解消してから起動します。SDKライセンスの確認が必要な場合は `flutter doctor --android-licenses` を実行してください。実機ではUSBデバッグを有効にし、PCの接続を端末で許可します。初回はGradleやSDKのダウンロードに時間がかかります。

このコマンドではキーなしで起動します。手元のビルドでもAIを使う場合は、`config/development.example.json` を `config/development.local.json` にコピーし、別途受け取ったキーを `OPENAI_API_KEY` に設定してください。`.local.json` はGit管理対象外です。

```sh
flutter run -d <Androidのdevice-id> --dart-define-from-file=config/development.local.json
```

キーやモデルの設定を変えたら、ホットリロードではなくアプリを停止して再ビルドします。モデルへのアクセス権が違うキーを使う場合は、`OPENAI_MODEL` と `OPENAI_JUDGE_MODEL` も利用できるモデルに合わせます。

`AFTER_HUE_DEMO_TOOLS=true` のビルドでは、SettingsからAfter Hueの編集・設定・履歴を初期化して、オンボーディングに戻せます。確認ダイアログを経て実行され、端末の写真は削除しません。

写真権限は画像だけを要求しています。GPSを読むには写真自体の位置情報とメディア位置情報の権限が必要です。設定の根拠は[photo_managerの公式手順](https://pub.dev/packages/photo_manager)にあります。現在地を追跡する権限は要求しません。

## 不具合を見つけたら

リポジトリのIssueに、どの端末で何をしたときに起きたかを書いてください。次の形なら調査を始めやすくなります。画面録画や `flutter run` のエラー部分もあると助かります。

```text
コミット、またはAPKのActions実行URL:
端末とOSバージョン:
使用したビルド: AI入り / キーなし / 自分でビルド
写真の許可: 全件 / 選択した写真のみ / 拒否
再現する操作:
期待した動き:
実際の動き:
```

APIキーそのものは書かないでください。ログには編集依頼文や写真情報が含まれることがあるので、共有してよい部分だけ添付してください。
