# After Hue

**DevFest GDGoC Japan Hackathon 2026 提出作品**（チーム: Hakumei Iro no Wasureji／東京会場／カテゴリ: エンターテインメント）

After Hueは、写真の中で残したい色だけを選び、それ以外をモノクロにするカメラ・写真アプリです。色や範囲は自分で指定できます。Autoで現像を任せることも、Askで「オレンジを除いてピンクを残して」のように言葉で頼むこともできます。AIは画像を描き直すのではなく、人が触るのと同じ編集設定（色・幅・境界・範囲）を動かします。そのため、AIの結果をそのまま手で微調整できます。

- iOS（主対象）: Flutter製。アプリ内カメラと、タップでの物体の切り抜き（Apple Vision）に対応
- Android: 撮影はOSのカメラ経由。物体の切り抜きは未対応
- AI: Google Cloud Run 上の中継サービス → Vertex AI の Gemini。Firebase 匿名認証と、Firestore での利用回数管理を使います

## 審査の方へ：試し方

| 方法 | 必要なもの | 手順 |
| --- | --- | --- |
| Android 実機 | Android 7.0 以上 | [Releases](https://github.com/Devfest-Hackathon-2026/df-2026-t212/releases) の `after-hue.apk` をインストール |
| iPhone 実機 | Mac・Xcode・無料のAppleアカウント | 下の「MacからiPhone実機にインストールする場合」 |

iOSアプリは署名なしのIPAを配布できないため、提出ルール3.1③に従い、ビルドと実行の手順をこのREADMEに記載しています。AIの秘密キーは不要です。同梱の `config/cloud.public.json`（Cloud RunのURLとFirebaseの公開設定）だけでクラウドAIに接続します。

このリポジトリを取得するコマンドは次のとおりです。

```sh
git clone https://github.com/Devfest-Hackathon-2026/df-2026-t212.git
cd df-2026-t212
```

### Android端末で試す場合

このリポジトリの [GitHub Releases](https://github.com/Devfest-Hackathon-2026/df-2026-t212/releases) にある `after-hue.apk` を端末へコピーして開くと、インストールできます。クラウドAIの公開接続設定を含めてビルドしてあり、FlutterやAndroid SDKは不要です。

ソースから起動する場合は、Flutter 3.47.9、Dart 3.13.7、JDK 17とAndroid SDKを使います。プロジェクトの設定はSDK Platform 36、NDK 28.2.13676358、最低OSはAndroid 7.0（API 24）です。[Flutter公式の手順](https://docs.flutter.dev/platform-integration/android/setup)に沿って環境を確認し、SDKライセンスや端末の接続許可は操作する方に確認・操作してもらってください。

```sh
flutter pub get
flutter doctor -v
flutter devices
flutter run --release -d <Androidのdevice-id> --dart-define-from-file=config/cloud.public.json
```

このコマンドは同梱の公開接続設定で起動します。AIモデルの認証情報はサーバー側にあり、端末へコピーする必要はありません。

### MacからiPhone実機にインストールする場合

開発元で使っているのはFlutter 3.47.9、Dart 3.13.7、Xcode 27.2です。iOS 27.2のiPhone実機で起動を確認しています。iOS 27向けのFoundationModels APIを含むため、古いXcodeでもビルドできるとは限りません。MacのOS、Xcode、接続するiPhoneのOSを確認し、ビルドと端末接続に対応する環境を用意してください。

必要なツールがすでに入っていれば、その環境を使います。Flutterのバージョンが合わない場合も、他のプロジェクトの環境を壊す更新はせず、このアプリ用に分けてください。Xcodeの初回起動、利用規約、追加コンポーネントのインストール、Appleアカウントの認証は操作する方に操作を案内します。

```sh
flutter pub get
flutter doctor -v
open ios/Runner.xcworkspace
```

実機用の署名と接続は、次の順で設定します。

1. XcodeのSettings → Apple Accountsで、操作する方のAppleアカウントにサインインします。有料登録をしていないアカウントはPersonal Teamとして使えます。
2. iPhoneをケーブルでMacに接続し、ロックを解除します。「このコンピュータを信頼しますか？」が出たら操作する方に確認してもらいます。XcodeのDevice Hubなどの端末管理画面で、接続したiPhoneが認識されることを確認してください。
3. iPhoneの設定 → プライバシーとセキュリティ → デベロッパモードを有効にします。再起動後の確認とパスコード入力も操作する方にお願いします。項目がまだ出ない場合は、先にXcodeとのペアリングを開始します。
4. XcodeでRunnerターゲットのSigning & Capabilitiesを開き、Automatically manage signingを有効にします。Teamを操作する方のPersonal Teamに変更し、Bundle Identifierも操作する方用の一意な値にします。例えば `com.yourname.afterhue.usertest` の `yourname` を操作する方の識別名に置き換えます。開発元のTeamやBundle Identifierをそのまま使わないでください。
5. 実行先に接続したiPhoneを選び、署名エラーが解消したことを確認します。署名用の設定変更はローカルにとどめ、コミットやPushはしません。アプリ本体のコードを変更する必要はありません。

詳細は[Appleの実機実行ガイド](https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices)と[デベロッパモードの有効化手順](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)を参照してください。

同梱の公開接続設定を使い、次のコマンドで実機にインストールします。`flutter devices` に表示された実機のIDを指定し、Simulatorや `macos` を選ばないでください。普段のテストではMacのデバッガーに接続せず使えるよう、Releaseモードで起動します。初回はSwift Package Managerの依存解決に時間がかかります。

```sh
flutter devices
flutter run --release -d <iPhone実機のdevice-id> --dart-define-from-file=config/cloud.public.json
```

クラウドAIを設定せず手動編集と撮影だけを試す場合は、`--dart-define-from-file=...` を省いて起動できます。iPhoneに開発元の信頼を求める表示が出たら、設定 → 一般 → VPNとデバイス管理で操作する方の開発者アカウントを確認・信頼してもらいます。

インストール後はMacとの接続を外し、iPhoneのホーム画面から起動してカメラが使えるところまで確認してください。無料署名が7日で切れたときは、同じTeam・Bundle Identifier・AI設定で上のコマンドを再実行します。アプリを先に削除する必要はありません。削除するとアプリ内のデータも失われるので、期限切れの対処としてアンインストールを案内しないでください。

署名で止まった場合は、選択したTeam、Bundle Identifier、端末の接続状態とXcodeのエラーを確認します。カメラを試す目的なので、操作する方の了承なくSimulatorに切り替えて完了扱いにしないでください。Simulatorは、操作する方が別途希望する場合の画面確認にだけ使います。

### AIの接続設定

クラウドAIは、After HueのGoogle Cloud Runサービスを経由してVertex AIのGeminiを使います。審査する方がAIの秘密キーやGoogle Cloudの課金設定を用意する必要はありません。認証にはFirebaseの匿名アカウントを使い、氏名やメールアドレスでの登録も不要です。

通常は同梱の `config/cloud.public.json` を変更せずに使います。接続情報を別途受け取る手順は不要です。独自の接続先を使う場合だけ、次のようにローカル設定へコピーして変更してください。既存ファイルは上書きしません。

```sh
cp -n config/cloud.public.json config/development.local.json
```

| 項目 | 設定するもの |
| --- | --- |
| `AFTER_HUE_AI_URL` | 配布されたCloud RunのHTTPS URL。末尾に `/v1/generate` は付けません |
| `FIREBASE_WEB_API_KEY` | 配布されたFirebase認証用の公開APIキー |
| `FIREBASE_PROJECT_ID` | 配布されたFirebaseプロジェクトID |

同梱の公開設定には、この3項目だけが入っています。独自設定用の `config/development.example.json` は空欄の雛形です。3項目が揃わないビルドではクラウドAIに接続せず、手動編集と端末内の簡易Autoを使います。自然言語のAskにはクラウドAIの設定が必要です。

Firebase認証用APIキーは接続するプロジェクトを識別する公開設定で、AIモデルを呼ぶ秘密キーではありません。Firebase関連APIだけに制限された配布用の値を使います。サービスアカウントのJSON、Vertex AIのアクセストークン、個人のAI APIキーをこのファイルへ入れないでください。この区別は[Firebaseの公式説明](https://firebase.google.com/docs/projects/api-keys)にも示されています。

```sh
flutter run --release -d <実機のdevice-id> --dart-define-from-file=config/cloud.public.json
```

独自の接続設定を作った場合だけ、上の `config/cloud.public.json` を `config/development.local.json` に置き換えます。

接続設定はビルド時に読み込むため、変更後はホットリロードではなく停止して起動し直します。`AFTER_HUE_DEMO_TOOLS` は開発者向けの任意項目で、通常の動作確認には不要です。`scripts/run.sh` でも起動できます。このスクリプトは接続設定の3項目と開発用フラグだけをビルドに渡します。

### AIの初回確認と料金

初回のクラウドAI利用前に、写真と指示の送信について確認画面が出ます。内容を読んで、利用するかを操作する方に選んでもらってください。承諾すると、縮小した写真、編集の指示やマークなどがGoogle Cloudへ送られます。自動現像をオンにすると、対象の新しい写真が自動で送られることがあります。設定からクラウドAIをオフにでき、手動編集は引き続き使えます。

審査期間中（2026年11月14日終了まで）、AIは無料で試せます。利用者ごととサービス全体に上限があり、上限に達するとAIが一時的に利用できない場合があります。時間を置いても解消しなければ、運営経由でお知らせください。利用者へ自動で料金を請求することはありません。[プライバシーの説明](docs/privacy.md)と[テスト版の利用について](docs/terms.md)は、アプリの設定画面からも読めます。

### 起動したあと

初回案内に出る写真は説明用です。手元の写真を数枚許可して、画面下の `+` から取り込むか、アプリ内カメラで撮影してください。写真を開いて Edit を押すと、残す色、範囲（タップで物を切り抜く／ブラシで塗る）、トーンを編集できます。AutoやAskを使うと、AIが同じ編集設定を動かします。アプリの表示は英語ですが、Askには日本語でも依頼できます。

## 資料

- [提出資料の目次](docs/submission/README.md)
- [技術構成とGoogle Cloudの使い方](docs/submission/architecture.md)
- [クラウドAIサーバーの構成と運用](server/ai/README.md)
- [プライバシーの説明](docs/privacy.md)

## 公開している設定について

`config/cloud.public.json` の `FIREBASE_WEB_API_KEY` は、接続するFirebaseプロジェクトを識別する公開設定です。AIモデルを呼ぶ秘密キーではありません。AIへのリクエストは、Cloud RunがFirebaseのIDトークンの署名・発行元・有効期限を検証し、Firestoreで利用回数を予約してから、サーバー側の認証情報でVertex AIへ渡します。サービスアカウントの鍵やAIのAPIキーは、このリポジトリにも端末にも含めていません（[Firebaseの公式説明](https://firebase.google.com/docs/projects/api-keys)）。

開発者向けの確認コマンドは `flutter analyze --no-fatal-infos` と `flutter test` です。共有UIと編集処理は `lib/`、iOS専用のカメラや物体抽出は `ios/Runner/`、AI中継サーバーは `server/ai/` にあります。
