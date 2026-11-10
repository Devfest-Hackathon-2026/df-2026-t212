# Androidで試す

[GitHub Releases](https://github.com/Devfest-Hackathon-2026/df-2026-t212/releases) から `after-hue.apk` を端末に取得して開くと、インストールできます。提出時点のソースから、同梱の公開接続設定（`config/cloud.public.json`）でビルドしたものです。AIの秘密キーやGoogle Cloudの設定は不要です。インストール時に「提供元不明のアプリ」の許可を求められた場合は、端末の表示に従って許可してください。

Android版では、撮影はOSのカメラアプリ経由になります。タップでの物体の切り抜き（iOSのApple Visionを使う機能）は未対応で、範囲はブラシで指定します。それ以外の取り込み、色と範囲の編集、Auto/Ask、ギャラリー・地図はiOSと同じです。

ソースから起動する場合は、[READMEのAndroid手順](../../README.md#android端末で試す場合)を参照してください。
