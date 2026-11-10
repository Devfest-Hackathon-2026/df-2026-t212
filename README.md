# After Hue

After Hueは、写真の中で残したい色を選び、それ以外をモノクロにするアプリです。自分で色や範囲を指定できるほか、Autoで現像を任せたり、Askで「オレンジを除いてピンクを残して」のように編集を頼んだりできます。取り込んだ写真はギャラリーと地図から見返せます。

今回はハッカソンに向けたユーザーテストをお願いしています。コードを書いたり、機能を開発したりしていただく必要はありません。アプリを使ってみて、分かりにくかったところ、期待と違った動き、気に入ったところを教えていただけると助かります。

現在のテスト対象は `first-build` ブランチです。GitHubで読むときも、ソースを取得するときも、このブランチを選んでください。

## どうやって試すか

Androidでは、用意したAI入りのAPKをインストールして試せます。APIキーは設定済みなので、自分で用意する必要はありません。[Androidの案内](docs/testing/android.md)に入手方法と確認してほしい操作をまとめています。Android対応はまだ初期段階で、アプリ内カメラと物体の自動抽出には未対応です。

iPhoneでは、ご本人のMacから手元のiPhoneにインストールして試します。MacにXcodeを入れ、ご本人の無料のAppleアカウントで署名する方法です。有料のApple Developer Programへの登録は不要ですが、無料署名は7日で期限が切れるので、その後も使う場合はMacから再ビルド・再インストールします。この仕組みは[Appleの無料アカウントの案内](https://developer.apple.com/help/account/basics/about-your-developer-account)に説明されています。

セットアップはこのREADMEをLLMに渡して任せられます。AIを使う場合は、ご本人のOpenAI APIキーを使ってください。AI用に他サービスのキーを用意する必要はありません。

今回はカメラでの撮影も試していただきたいので、iPhone実機を使います。TestFlightでの配布はしていません。Macはインストールに使うPCで、macOSネイティブ版はテスト対象ではありません。

## セットアップをLLMに任せる

このリポジトリを読み、手元のターミナルを操作できるLLMに、次の文章を渡してください。リポジトリはPrivateなので、先にGitHubの招待を受け入れ、手元のGitHubアカウントでアクセスできる状態にしておきます。

```text
After Hueのユーザーテストをしたいので、セットアップと起動をお願いします。
リポジトリ: https://github.com/pdHaku0/afterhue
ブランチ: first-build

READMEの「セットアップを担当するLLMへ」を読み、私のPCと端末を確認してから、
アプリを使えるところまで進めてください。iPhoneではカメラも試すので、
Simulatorではなく手元の実機に入れてください。開発やコードの変更は依頼していません。
APIキーやAppleの認証など、本人の操作が必要なところだけ案内してください。
```

OpenAI APIキーは、この依頼文やチャットに貼る必要はありません。LLMに設定ファイルを用意してもらい、キーの値だけ自分で入力できます。

## セットアップを担当するLLMへ

この依頼の目的は、テスターがアプリを使えるようにすることです。機能開発、リファクタリング、リポジトリへのPushは行いません。まずPCのOS、使える端末、既存のFlutter・Xcode・Android SDKを確認し、利用する経路を決めてください。分からない端末情報だけ本人に尋ね、すでに分かっていることを聞き直さないでください。

既存の作業フォルダがある場合は、最初にGitの状態を確認します。本人の変更を消したり、作業中のブランチを強制的に切り替えたりしないでください。新しく取得する場合のコマンドは次のとおりです。

```sh
git clone --branch first-build https://github.com/pdHaku0/afterhue.git
cd afterhue
```

### Android端末で試す場合

まず完成済みのAPKを使う経路を選んでください。[Android test build](https://github.com/pdHaku0/afterhue/actions/workflows/android.yml)の成功した手動実行に、`after-hue-android-ai-debug` というartifactがあります。ダウンロードしてZIPを展開し、中のAPKを端末にインストールします。この方法ならFlutterやAndroid SDKのセットアップは不要です。

`after-hue-android-local-debug` はAPIキーなし版です。手動編集と簡易Autoには使えますが、自然言語のAskは使えません。ユーザーテスト用には、原則として名前に `ai` が入った方を案内してください。artifactは3日で期限切れになります。その場合は所有者に再ビルドを依頼し、本人の意向を確認せずに別のAPIキーを用意させないでください。

ソースから起動する必要がある場合に限り、Flutter 3.47.9、Dart 3.13.7、JDK 17とAndroid SDKを使います。プロジェクトの設定はSDK Platform 36、NDK 28.2.13676358、最低OSはAndroid 7.0（API 24）です。[Flutter公式の手順](https://docs.flutter.dev/platform-integration/android/setup)に沿って環境を確認し、SDKライセンスや端末の接続許可は本人に確認・操作してもらってください。

```sh
flutter pub get
flutter doctor -v
flutter devices
flutter run -d <Androidのdevice-id>
```

このコマンドはキーなしで起動します。ソースからAIを使う場合は、下の「AIの設定」を続けてください。GitHub Secretの値を読み出そうとしたり、APKからキーを抽出したりしてはいけません。

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

続けて、下の「AIの設定」で本人のキーを用意します。その後、次のコマンドで実機にインストールします。`flutter devices` に表示された実機のIDを指定し、Simulatorや `macos` を選ばないでください。普段のテストではMacのデバッガーに接続せず使えるよう、Releaseモードで起動します。初回はSwift Package Managerの依存解決に時間がかかります。

```sh
flutter devices
flutter run --release -d <iPhone実機のdevice-id> --dart-define-from-file=config/development.local.json
```

キーなしで手動編集と撮影だけを試す場合は、`--dart-define-from-file=...` を省いて起動できます。iPhoneに開発元の信頼を求める表示が出たら、設定 → 一般 → VPNとデバイス管理で本人の開発者アカウントを確認・信頼してもらいます。

インストール後はMacとの接続を外し、iPhoneのホーム画面から起動してカメラが使えるところまで確認してください。無料署名が7日で切れたときは、同じTeam・Bundle Identifier・AI設定で上のコマンドを再実行します。アプリを先に削除する必要はありません。削除するとアプリ内のデータも失われるので、期限切れの対処としてアンインストールを案内しないでください。

署名で止まった場合は、選択したTeam、Bundle Identifier、端末の接続状態とXcodeのエラーを確認します。カメラを試す目的なので、本人の了承なくSimulatorに切り替えて完了扱いにしないでください。Simulatorは、本人が別途希望する場合の画面確認にだけ使います。

### AIの設定

手動編集と端末内の簡易Autoは、APIキーなしでも動きます。AskやクラウドAIによる現像にはOpenAI APIキーが必要です。キーには、指定したモデルを利用できる権限とAPIの課金設定が必要です。キーを設定しなくても使える部分と、AIが必要な部分を区別して案内してください。

ローカル設定は `config/development.local.json` に置きます。ファイルがなければ、次のように雛形をコピーしてください。すでに設定済みなら上書きしてはいけません。

```sh
cp config/development.example.json config/development.local.json
```

本人にエディタでファイルを開いてもらい、`OPENAI_API_KEY` の空欄だけ入力してもらいます。キーをチャットに貼らせたり、ターミナルへ表示したり、コマンドの引数に直接埋め込んだりしないでください。このファイルはGit管理対象外です。設定の確認が必要なときも、値を出力せず、空欄かどうかなどの必要な事実だけ確認します。

雛形の `OPENAI_MODEL` と `OPENAI_JUDGE_MODEL` は、開発元で使っているモデルです。本人のAPIプロジェクトでアクセスできない場合は、出ているエラーを確認したうえで、利用できるモデルを本人と決めてください。アプリのソースにモデル名やキーを書き込む必要はありません。

```sh
flutter run -d <対象のdevice-id> --dart-define-from-file=config/development.local.json
```

iPhone実機では、上の実機手順と同じく `--release` を付けて起動してください。キーやモデルの変更はビルド時に読み込まれるため、変更後はホットリロードではなく停止して起動し直します。所有者用の `scripts/run.sh` は1Passwordの個別設定を前提にしているため、テスターの初回セットアップには使わないでください。

AIを使うと写真の縮小版と編集依頼がOpenAIに送られます。最初は本人が選んだ数枚のテスト写真を使い、ライブラリ全体をまとめて処理しないでください。

### 起動したあと

ビルド成功だけで完了にせず、実機でアプリが表示されるところまで確認してください。写真とカメラへのアクセス許可は本人に操作してもらい、取り込み、写真の表示、編集、保存、開き直しの流れを確認します。iPhoneではアプリ内カメラで撮影し、その写真を開けることも確認します。AIの動作確認には、本人が選んだ写真と依頼を使ってください。

Askのレイアウトを見るときは、ソフトウェアキーボードを実際に表示してください。Macのハードウェアキーボードだけでは、入力欄やSendが画面に収まるかを確認できません。

最後に、起動した端末、使ったコマンド、確認できた操作、未確認の機能を短く伝えてください。起動を妨げる不具合があれば、再現手順とエラーを残します。ユーザーテストのセットアップ依頼を、機能開発や大きなコード修正に広げないでください。

## 使ってみて教えてほしいこと

まず数枚の写真を取り込み、色を変えて保存し、もう一度開いてみてください。操作を理解するために迷ったところや、押した結果が予想と違ったところがあれば、その時点の画面を教えてください。AutoやAskを使った場合は、待っている間に何が起きているか分かったか、仕上がりをどう感じたかも知りたいです。

不具合の原因を調べたり、修正案を考えたりする必要はありません。端末の機種とOS、行った操作、実際に起きたことが分かれば十分です。可能ならスクリーンショットか短い録画を添えて、GitHubのIssueか普段の連絡手段で返してください。APIキーそのものは送らないでください。

実装を確認する必要がある場合は、共有UIと編集処理が `lib/`、iOS専用のカメラや物体抽出が `ios/Runner/` にあります。開発元向けの確認コマンドは `flutter analyze --no-fatal-infos` と `flutter test` です。
