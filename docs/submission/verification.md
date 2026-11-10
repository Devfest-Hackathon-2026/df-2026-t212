# 実接続の確認記録

2026年11月10日、配置済みのCloud RunサービスとアプリのGeminiクライアントを使い、写真の選別、現像、追加の編集依頼、端末側の画像処理までを通して確認しました。確認用の一枚で成功した記録であり、すべての写真・端末での品質や、実機UI全体の動作を保証するものではありません。

## 接続先と認証

接続先は `https://after-hue-ai-675070172838.asia-northeast1.run.app` です。ヘルスチェックは200、未認証のAIリクエストは401でした。Firebase匿名認証を通したリクエストは受理され、Firestoreへのクライアント直接アクセスは403で拒否されました。AIの認証情報を利用者の端末へ配布する方式ではありません。

## 一枚の写真で確認した流れ

写真の選別は `develop=true` を返しました。その後、現像エージェントは色の分布を調べ、写真の座標から採色し、残す色を二つ追加しました。途中結果を二度描画して確認し、色の幅を調整して完了しました。

続く編集依頼では、色の一つを除外し、モノクロ部分のトーンを変更しました。変更後の画像を描画してから完了し、残す色は一つになりました。出力画像は開発環境で目視確認しています。

記録された主要な操作は次のとおりです。

```text
judge: develop=true
develop: hue_histogram → probe → add_color × 2 → render
         → probe → set_width → render → finish
result: 2 kept colors
revise: probe → remove_color → set_mono_tone → render → finish
result: 1 kept color
local render: succeeded
```

この確認では、AIがツールを呼び、端末側で作った途中画像を再び読み、追加の編集を行う往復が成立しました。APIへ一度接続できただけの確認とは区別しています。アプリ内でのギャラリー保存、バックグラウンド実行、実機の権限表示は、それぞれ別の検証です。

## 運用設定

Cloud Runは東京リージョン `asia-northeast1` に配置しています。モデルは現像・修正用のGemini 3.8 Flashと選別用のGemini 3.5 Flash-Liteです。Cloud Runのリージョンだけを根拠に、Vertex AIを含む全処理が日本国内だけで行われるとは説明していません。

FirestoreでUTCの日付ごとに利用回数を管理し、全体1,000回、利用者ごと300回のAPI呼び出しを上限にしています。推論開始前に回数を予約するため、失敗やキャンセルも消費に含まれます。一枚の現像で複数回呼び出すので、写真枚数の上限ではありません。3,000円の予算通知も設定済みですが、これは請求額の強制停止ではありません。

この記録の元ログは開発環境の `/tmp/afterhue-cloud-smoke.log`、出力は `/tmp/afterhue-cloud-smoke.jpg` です。再確認する場合は[AIクライアント](../../lib/agent/gemini_agent.dart)と[サーバーの運用手順](../../server/ai/README.md)を参照してください。接続には公開設定に加えてFirebase認証が必要です。
