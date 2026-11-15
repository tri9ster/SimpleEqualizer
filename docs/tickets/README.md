# tickets（大きな更新のチケット）

複数の作業に分かれる更新を、1つのフォルダにまとめて管理します。

```
tickets/
  YYYYMMDD_<テーマ>/                      例: 20260914_node-upgrade-v26/
    README.md                             チケット一覧、作業順序、進捗
    TICKET-001-<主な作業内容>.md          例: TICKET-001-react19-upgrade.md
    TICKET-002-<主な作業内容>.md
```

- 日付は着手日。連番は3桁で、そのフォルダの中で通し番号にする。
- ひな形は [_template/](_template/)。新しい更新を始めるときは、これをもとに Claude がフォルダを作ります。
- 1件終わるごとに、チケットの「ステータス」「実施結果」と、一覧の「進捗」を更新します。
- 終わった更新(完了したもの、取りやめたもの)のフォルダは、[../archive/tickets/](../archive/tickets/) へ移します(消さない)。
  一覧には残し、リンクだけを移した先に向けます。

## 更新の一覧

| フォルダ | 内容 | 状態 |
| --- | --- | --- |
| [20261012_prototype/](../archive/tickets/20261012_prototype/) | 試作。案A(Core Audio のプロセスタップ)が実機で成り立つかを確かめる | 完了(2026-10-12)。案A のまま段階2 へ進む |
| [20261012_stage2-volume/](../archive/tickets/20261012_stage2-volume/) | 段階2(音量)。メニューバー常駐、音量、消音、状態の保存、コールバックを C へ、アイコン | 完了(2026-10-12)。長時間の確認は 2026-10-13 に済んだ |
| [20261012_stage3-equalizer/](../archive/tickets/20261012_stage3-equalizer/) | 段階3(イコライザー)。10 バンドのイコライザー、ラウドネス、リミッター、イコライザーのウィンドウ | 完了(2026-10-13) |
| [20261013_stage4-presets/](../archive/tickets/20261013_stage4-presets/) | 段階4(プリセット)。保存、呼び出し、上書き、名前の変更、削除、書き出しと読み込み | 完了(2026-10-13) |
| [20261013_stage5-finishing/](../archive/tickets/20261013_stage5-finishing/) | 段階5(仕上げ)。いまの出力先を加工する、音量キー、設定のウィンドウ、ログイン時の起動 | 完了(2026-10-16) |
| [20261018_distribution/](../archive/tickets/20261018_distribution/) | GitHub での配布。点検、利用許諾、Release のビルド、英語対応、署名と配布物、README、公開 | 完了(2026-11-15)。v0.1 をリリースした |
| [20261107_popup-confirm/](../archive/tickets/20261107_popup-confirm/) | ポップアップの操作から出る確かめる画面を、ポップアップの中に出す | 完了(2026-11-07) |
| [20261107_quit-confirm/](../archive/tickets/20261107_quit-confirm/) | 終了するときの確かめの条件を見直す | 取りやめ(2026-11-08) |
| [20261108_homepage/](../archive/tickets/20261108_homepage/) | GitHub Pages で、アプリのホームページ(紹介とダウンロードの案内)を作る | 完了(2026-11-15) |
