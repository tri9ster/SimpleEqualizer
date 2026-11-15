# TICKET-005: GitHub Pages を有効にして確かめる

## 概要

リポジトリを公開したあと、GitHub Pages を有効にし、公開されたページを確かめる。
GitHub の設定を変える操作なので、利用者が行う(Claude が行うときは、その都度、許可を得る)。

## ステータス

- [x] 作業中
- [x] 動作確認済み
- [x] 完了

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

- [x] 英語と日本語のページが開ける。
- [x] ダウンロードのボタンから、最新のリリースへ行ける。
- [x] 画像とアイコンが表示される。
- [x] リポジトリの About から、ページへ行ける。
- [x] README(英語と日本語)のリンクから、ページへ行ける。

## 実施結果

2026-11-15 に行った。

- 利用者が、Settings → Pages の Source を「GitHub Actions」にし、Actions からワークフローを手動で動かした。成功した。
  公開した最初の push のときの実行は、Pages を有効にする前だったので失敗した(予想どおり)。
- ページのアドレスは `https://tri9ster.github.io/SimpleEqualizer/`(日本語は `ja/`)。Claude が、どちらもログインしないで開ける(200)ことを確かめた。
- 利用者が、About の Website にページのアドレスを入れた。README のリンクは、公開のコミットに入れてある(TICKET-004)。
- 利用者が、ログインしていない状態で、ページ、画像、ダウンロードのボタンからリリースへ行けることを確かめた。
