# After Hue 提出資料

After Hueは、写真の中で残したい色を選び、それ以外をモノクロにするアプリです。撮影や取り込みから、編集、色と地図による振り返り、印刷用画像の作成までをつなぎます。

初めて読む方は、[プロダクト説明](product.md)からご覧ください。[審査基準への応答](judging.md)には、各評価項目に関係する実装と、確認できる場所をまとめています。[技術構成](architecture.md)では、端末と外部サービスの役割を分けて説明しています。

この資料は、2026年11月10日のコードフリーズ時点のコードと実接続確認に基づく提出版です。Cloud Run、Firebase Authentication、Firestore、Vertex AIを使う編集エージェントを配置済みです。認証、写真の選別、現像、追加の編集依頼、端末側の描画まで実接続で確認しました。確認範囲は[実接続の記録](verification.md)にまとめています。Exploreは延期し、別ブランチの試作を今回の成果に含めていません。

| 資料 | 読む目的 |
|---|---|
| [プロダクト説明](product.md) | 誰の何を助け、どのように使うアプリなのかを理解する |
| [取り組む課題](problem.md) | 課題設定、実装との対応、現段階で主張できる範囲を見る |
| [審査基準への応答](judging.md) | 評価項目ごとに、主張と実装の根拠を確認する |
| [技術構成](architecture.md) | AI・画像処理・保存・外部サービスの境界を確認する |
| [デモの構成](demo.md) | 一本の利用体験として機能を見せる |
| [著作物・外部技術の利用](credits.md) | 画像、地図、ライブラリの出典と未確認事項を見る |
| [提出前の確認事項](submission-checklist.md) | 未完了の提出条件を整理する。運営側で使う作業メモ |

稼働URLは https://after-hue-ai-675070172838.asia-northeast1.run.app （Cloud Run、asia-northeast1）です。端末で試す手順は[リポジトリのREADME](../../README.md)にあります。

## 執筆中の提出資料と提出先

現在の提出原稿は、チーム名「Hakumei Iro no Wasureji」、会場「東京」、メンバー「上野直哉」、カテゴリ「エンターテインメント」です。アプリの画面表示は英語のみで、日本語の説明資料とは区別します。

提出用の説明資料の正本は、[現在執筆中のGoogleドキュメント](https://docs.google.com/document/d/1N_kToYy6w76DLoCJwP6Jp0mKYGWv4LDW-A_BxHptTvA/edit)です。このリポジトリの資料は、技術事実や確認先を整理する補助資料です。

運営指定のリポジトリは [Devfest-Hackathon-2026/df-2026-t212](https://github.com/Devfest-Hackathon-2026/df-2026-t212) です。提出版のソース一式とREADMEをmainに置いています。GitHub ActionsとPagesは利用できないため、AndroidのAPKは別の環境でビルドし、このリポジトリのReleasesに添付しています。

説明文は[プロダクト説明ドキュメントの指定テンプレート](https://docs.google.com/document/d/1IyBQ-jN5msTSeRQDQU4Bm3mb_ZJOH8spJXrsp0MwDJ8/edit)、著作物の一覧は[著作物利用シートの指定テンプレート](https://docs.google.com/spreadsheets/d/1oU3kmE6v9MR_1e0Exetiy8hVZ4ToiR2dpzwBiFSuL3I/edit)へ転記します。提出物の一覧は[提出前の確認事項](submission-checklist.md)にまとめています。
