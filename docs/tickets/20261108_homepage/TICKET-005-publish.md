# TICKET-005: GitHub Pages を有効にして確かめる

## 概要

リポジトリを公開したあと、GitHub Pages を有効にし、公開されたページを確かめる。
GitHub の設定を変える操作なので、利用者が行う(Claude が行うときは、その都度、許可を得る)。

## ステータス

- [ ] 作業中
- [ ] 動作確認済み
- [ ] 完了

## 依存関係

TICKET-002、TICKET-004、配布の TICKET-009(リポジトリの公開)

## 現状

2026-11-08 時点。リポジトリは非公開。

## 対応方針・作業手順

1. 公開したリポジトリの Settings → Pages → Build and deployment の Source で「GitHub Actions」を選ぶ。
2. Actions のタブで、ワークフローを手動で動かす(または `site/` を変えて `main` に入れる)。
3. `https://tri9ster.github.io/SimpleEqualizer/` と `.../ja/` を、ログインしていない状態で開いて確かめてもらう。
4. ページのアドレスを確かめる。Settings → Pages の上に出る「Your site is live at …」、
   Actions の実行結果の deploy の欄、`gh api repos/<所有者>/<リポジトリ>/pages --jq .html_url` のどれかで分かる。
   形は `https://<所有者(小文字)>.github.io/<リポジトリの名前>/` なので、公開するリポジトリの名前が変われば、アドレスも変わる。
5. `README.md` と `README.ja.md` の先頭近くに、ページへのリンクを足す(両方を同じ内容に直す。2026-11-08、利用者の指示で公開と同時に足す)。
6. リポジトリのトップの About(歯車)の Website に、ページのアドレスを入れる。

## 影響ファイル

- `README.md`、`README.ja.md`(ページへのリンク)、`docs/`(結果の記録)

## 動作確認項目

- [ ] 英語と日本語のページが開ける。
- [ ] ダウンロードのボタンから、最新のリリースへ行ける。
- [ ] 画像とアイコンが表示される。
- [ ] リポジトリの About から、ページへ行ける。
- [ ] README(英語と日本語)のリンクから、ページへ行ける。

## 実施結果

未着手。
