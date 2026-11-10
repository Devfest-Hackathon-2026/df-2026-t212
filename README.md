# After Hue

After Hueは、写真の中で残したい色を選び、それ以外をモノクロにするアプリです。自分で色や範囲を指定できるほか、Autoで現像を任せたり、Askで「オレンジを除いてピンクを残して」のように編集を頼んだりできます。取り込んだ写真はギャラリーと地図から見返せます。

今回はハッカソンに向けたユーザーテストをお願いしています。コードを書いたり、機能を開発したりしていただく必要はありません。アプリを使ってみて、分かりにくかったところ、期待と違った動き、気に入ったところを教えていただけると助かります。

審査用のソースは、運営リポジトリの提出版を使います。既存テスター向けの開発リポジトリを使う場合は、配布時に案内されたブランチを選んでください。

## どうやって試すか

Androidでは、用意したAI入りのAPKをインストールして試せます。Google Cloudへの接続設定が入っているので、自分でAIのAPIキーを用意する必要はありません。[Androidの案内](docs/testing/android.md)に入手方法と確認してほしい操作をまとめています。Android対応はまだ初期段階で、アプリ内カメラと物体の自動抽出には未対応です。

iPhoneでは、ご本人のMacから手元のiPhoneにインストールして試します。MacにXcodeを入れ、ご本人の無料のAppleアカウントで署名する方法です。有料のApple Developer Programへの登録は不要ですが、無料署名は7日で期限が切れるので、その後も使う場合はMacから再ビルド・再インストールします。この仕組みは[Appleの無料アカウントの案内](https://developer.apple.com/help/account/basics/about-your-developer-account)に説明されています。

セットアップはこのREADMEをLLMに渡して任せられます。iPhoneでも、自分のAI APIキーや課金アカウントは不要です。ソースからビルドする場合は、同梱の `config/cloud.public.json` をそのまま使います。

今回はカメラでの撮影も試していただきたいので、iPhone実機を使います。TestFlightでの配布はしていません。Macはインストールに使うPCで、macOSネイティブ版はテスト対象ではありません。

## セットアップをLLMに任せる

このリポジトリを読み、手元のターミナルを操作できるLLMに、次の文章を渡してください。運営の提出リポジトリは公開です。既存テスター向けのPrivateリポジトリから取得する場合だけ、先にGitHubの招待を受け入れてください。

```text
After Hueのユーザーテストをしたいので、セットアップと起動をお願いします。
リポジトリ: https://github.com/Devfest-Hackathon-2026/df-2026-t212
ブランチ: main

READMEの「セットアップを担当するLLMへ」を読み、私のPCと端末を確認してから、
アプリを使えるところまで進めてください。iPhoneではカメラも試すので、
Simulatorではなく手元の実機に入れてください。開発やコードの変更は依頼していません。
AIの秘密キーは用意しません。同梱のconfig/cloud.public.jsonを使い、Appleの認証など、
本人の操作が必要なところだけ案内してください。
```

AIの接続設定はリポジトリに同梱しています。ご自身でGoogle CloudやAIサービスの課金設定をする必要はありません。

## セットアップを担当するLLMへ

この依頼の目的は、テスターがアプリを使えるようにすることです。機能開発、リファクタリング、リポジトリへのPushは行いません。まずPCのOS、使える端末、既存のFlutter・Xcode・Android SDKを確認し、利用する経路を決めてください。分からない端末情報だけ本人に尋ね、すでに分かっていることを聞き直さないでください。

既存の作業フォルダがある場合は、最初にGitの状態を確認します。本人の変更を消したり、作業中のブランチを強制的に切り替えたりしないでください。新しく取得する場合のコマンドは次のとおりです。

```sh
git clone https://github.com/Devfest-Hackathon-2026/df-2026-t212.git
cd df-2026-t212
```

### Android端末で試す場合

APKが配布されている場合は、[提出リポジトリのReleases](https://github.com/Devfest-Hackathon-2026/df-2026-t212/releases)に添付されたAPKを使います。端末へコピーして開くとインストールできます。この方法ならFlutterやAndroid SDKのセットアップは不要です。APKが未掲載の場合も、以下の手順でソースから実行できます。

ソースから起動する必要がある場合に限り、Flutter 3.47.9、Dart 3.13.7、JDK 17とAndroid SDKを使います。プロジェクトの設定はSDK Platform 36、NDK 28.2.13676358、最低OSはAndroid 7.0（API 24）です。[Flutter公式の手順](https://docs.flutter.dev/platform-integration/android/setup)に沿って環境を確認し、SDKライセンスや端末の接続許可は本人に確認・操作してもらってください。

```sh
flutter pub get
flutter doctor -v
flutter devices
flutter run --release -d <Androidのdevice-id> --dart-define-from-file=config/cloud.public.json
```

このコマンドは同梱の公開接続設定で起動します。AIモデルの認証情報はサーバー側にあり、端末へコピーする必要はありません。

### MacからiPhone実機にインストールする場合

開発元で使っているのはFlutter 3.47.9、Dart 3.13.7、Xcode 27.2です。iOS 27.2のiPhone実機で起動を確認しています。iOS 27向けのFoundationModels APIを含むため、古いXcodeでもビルドできるとは限りません。MacのOS、Xcode、接続するiPhoneのOSを確認し、ビルドと端末接続に対応する環境を用意してください。

必要なツールがすでに入っていれば、その環境を使います。Flutterのバージョンが合わない場合も、他のプロジェクトの環境を壊す更新はせず、このアプリ用に分けてください。Xcodeの初回起動、利用規約、追加コンポーネントのインストール、Appleアカウントの認証は本人に操作を案内します。

```sh
flutter pub get
flutter doctor -v
open ios/Runner.xcworkspace
```

実機用の署名と接続は、次の順で設定します。

1. XcodeのSettings → Apple Accountsで、本人のAppleアカウントにサインインします。有料登録をしていないアカウントはPersonal Teamとして使えます。
2. iPhoneをケーブルでMacに接続し、ロックを解除します。「このコンピュータを信頼しますか？」が出たら本人に確認してもらいます。XcodeのDevice Hubなどの端末管理画面で、接続したiPhoneが認識されることを確認してください。
3. iPhoneの設定 → プライバシーとセキュリティ → デベロッパモードを有効にします。再起動後の確認とパスコード入力も本人にお願いします。項目がまだ出ない場合は、先にXcodeとのペアリングを開始します。
4. XcodeでRunnerターゲットのSigning & Capabilitiesを開き、Automatically manage signingを有効にします。Teamを本人のPersonal Teamに変更し、Bundle Identifierも本人用の一意な値にします。例えば `com.yourname.afterhue.usertest` の `yourname` を本人の識別名に置き換えます。開発元のTeamやBundle Identifierをそのまま使わないでください。
5. 実行先に接続したiPhoneを選び、署名エラーが解消したことを確認します。署名用の設定変更はローカルにとどめ、コミットやPushはしません。アプリ本体のコードを変更する必要はありません。

詳細は[Appleの実機実行ガイド](https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices)と[デベロッパモードの有効化手順](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)を参照してください。

同梱の公開接続設定を使い、次のコマンドで実機にインストールします。`flutter devices` に表示された実機のIDを指定し、Simulatorや `macos` を選ばないでください。普段のテストではMacのデバッガーに接続せず使えるよう、Releaseモードで起動します。初回はSwift Package Managerの依存解決に時間がかかります。

```sh
flutter devices
flutter run --release -d <iPhone実機のdevice-id> --dart-define-from-file=config/cloud.public.json
```

クラウドAIを設定せず手動編集と撮影だけを試す場合は、`--dart-define-from-file=...` を省いて起動できます。iPhoneに開発元の信頼を求める表示が出たら、設定 → 一般 → VPNとデバイス管理で本人の開発者アカウントを確認・信頼してもらいます。

インストール後はMacとの接続を外し、iPhoneのホーム画面から起動してカメラが使えるところまで確認してください。無料署名が7日で切れたときは、同じTeam・Bundle Identifier・AI設定で上のコマンドを再実行します。アプリを先に削除する必要はありません。削除するとアプリ内のデータも失われるので、期限切れの対処としてアンインストールを案内しないでください。

署名で止まった場合は、選択したTeam、Bundle Identifier、端末の接続状態とXcodeのエラーを確認します。カメラを試す目的なので、本人の了承なくSimulatorに切り替えて完了扱いにしないでください。Simulatorは、本人が別途希望する場合の画面確認にだけ使います。

### AIの接続設定

クラウドAIは、After HueのGoogle Cloud Runサービスを経由してVertex AIのGeminiを使います。テスターがOpenAIやGeminiの秘密キーを用意する必要はありません。認証にはFirebaseの匿名アカウントを使い、氏名やメールアドレスでの登録も不要です。

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

接続設定はビルド時に読み込むため、変更後はホットリロードではなく停止して起動し直します。`AFTER_HUE_DEMO_TOOLS` は開発者向けの任意項目で、通常のユーザーテストには不要です。`scripts/run.sh` でも起動できます。このスクリプトは接続設定の3項目と開発用フラグだけをビルドに渡します。

### AIの初回確認と料金

初回のクラウドAI利用前に、写真と指示の送信について確認画面が出ます。内容を読んで、利用するかをご本人に選んでもらってください。承諾すると、縮小した写真、編集の指示やマークなどがGoogle Cloudへ送られます。自動現像をオンにすると、対象の新しい写真が自動で送られることがあります。設定からクラウドAIをオフにでき、手動編集は引き続き使えます。

今回のアルファ版ではAIを無料で試せます。利用者ごととサービス全体に上限があり、上限に達するとAIが一時的に利用できない場合があります。時間を置いても解消しなければ、配布時の連絡先へお知らせください。利用者へ自動で料金を請求することはありません。[プライバシーの説明](docs/privacy.md)と[テスト版の利用について](docs/terms.md)は、アプリの設定画面からも読めます。

### 起動したあと

初回案内に出る写真は説明用です。編集用ギャラリーには追加されないので、手元の写真を数枚許可し、画面下の `+` から取り込んで試してください。自動取り込みは、起動時などに写真ライブラリを読み込む際に新しい写真を検出します。アプリが終了している間も常時監視・現像する機能ではありません。

ビルド成功だけで完了にせず、実機でアプリが表示されるところまで確認してください。アプリの表示は端末の言語にかかわらず英語です。Askへの依頼文は日本語でも入力できます。日本語の入力・変換を試す場合は、日本語キーボードを使ってください。写真とカメラへのアクセス許可は本人に操作してもらい、取り込み、写真の表示、編集、保存、開き直しの流れを確認します。iPhoneではアプリ内カメラで撮影し、その写真を開けることも確認します。AIの動作確認には、本人が選んだ写真と依頼を使ってください。

Askのレイアウトを見るときは、ソフトウェアキーボードを実際に表示してください。Macのハードウェアキーボードだけでは、入力欄やSendが画面に収まるかを確認できません。

最後に、起動した端末、使ったコマンド、確認できた操作、未確認の機能を短く伝えてください。起動を妨げる不具合があれば、再現手順とエラーを残します。ユーザーテストのセットアップ依頼を、機能開発や大きなコード修正に広げないでください。

## 使ってみて教えてほしいこと

まず数枚の写真を取り込み、色を変えて保存し、もう一度開いてみてください。操作を理解するために迷ったところや、押した結果が予想と違ったところがあれば、その時点の画面を教えてください。AutoやAskを使った場合は、待っている間に何が起きているか分かったか、仕上がりをどう感じたかも知りたいです。

不具合の原因を調べたり、修正案を考えたりする必要はありません。端末の機種とOS、行った操作、実際に起きたことが分かれば十分です。可能ならスクリーンショットか短い録画を添えて、GitHubのIssueか普段の連絡手段で返してください。認証トークンや個人情報は送らないでください。

実装を確認する必要がある場合は、共有UIと編集処理が `lib/`、iOS専用のカメラや物体抽出が `ios/Runner/` にあります。開発元向けの確認コマンドは `flutter analyze --no-fatal-infos` と `flutter test` です。

## 今回の対象と資料

今回の対象は、撮影・取り込み、色と範囲の編集、Auto/Ask、ギャラリー・地図、印刷用レイアウトです。Exploreの投稿・閲覧機能と端末間同期は今回のテストに含みません。

審査用の説明は[提出資料](docs/submission/README.md)にまとめています。クラウドAIのサーバー構成と運用設定は[server/ai/README.md](server/ai/README.md)にあります。サーバーの構築は開発者が行うため、ユーザーテストで実行する必要はありません。
