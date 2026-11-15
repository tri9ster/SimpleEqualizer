# TICKET-004: 公開の仕組み(GitHub Actions)と README からの案内

## 概要

`main` に入ったときに `site/` を GitHub Pages へ公開する仕組みを足し、README からホームページへ案内する。

## ステータス

- [x] 作業中
- [x] 動作確認済み
- [x] 完了

## 依存関係

TICKET-003

## 現状

2026-11-08 時点。`.github/` はない。

## 対応方針・作業手順

1. `.github/workflows/pages.yml` を足す。
   - きっかけ: `main` への push のうち `site/` が変わったとき、と手動(`workflow_dispatch`)。
   - 中身: `actions/checkout`、`actions/configure-pages`、`actions/upload-pages-artifact`(`path: site`)、`actions/deploy-pages`。
   - 権限は `pages: write`、`id-token: write`、`contents: read` だけにする。
   - 使うアクションは、版を固定する。
2. 非公開の間は GitHub Pages を有効にしないので、この仕組みは動かない(動いても失敗するだけ)。そのことを architecture.md に書く。
3. `README.md` と `README.ja.md` の先頭近くに、ホームページへのリンクを足す(両方を同じ内容に直す)。
   公開の前にリンクが切れていてもよいかは、利用者に確かめる(公開と同時に足す、という手もある)。

## 影響ファイル

- `.github/workflows/pages.yml`、`README.md`、`README.ja.md`
- `docs/architecture.md`、`docs/dev-log.md`

## 動作確認項目

- [x] ワークフローの書き方に誤りがない(公開したあと、手動の実行が成功した。2026-11-15)。
- [x] README の英語と日本語が、同じ内容になっている(リンクの行だけを足した。英語は英語のページ、日本語は日本語のページを指す)。

## 実施結果

2026-11-08 に `.github/workflows/pages.yml` を作った。

- `site/` をそのまま公開するのではなく、`tools/build-site.sh _site` で README の画像と合わせてから公開する(TICKET-003 で変えた)。
  そのため、きっかけの変更に `assets/**` と `tools/build-site.sh` も入れた。
- 使うアクションは、主な版(`@v4` など)で固定した。
- `_site/` を `.gitignore` に足した(手元で同じコマンドを動かしたときに、コミットしてしまわないように)。
- 確かめたこと: YAML として読めること(`actionlint` は入っていない)。動くかどうかは、公開してから確かめる(TICKET-005)。
- README からのリンクは、公開と同時に足すことにした(2026-11-08、利用者の指示。公開の前に足すとリンクが切れるため)。TICKET-005 で行う。
- 2026-11-15: `README.md` と `README.ja.md` の言語の切り替えの下に、ホームページへのリンクを足した(英語は `/`、日本語は `/ja/`)。
  公開する最初のコミットに入れるので、リンクが切れている期間は、Pages を有効にするまでの間だけになる。
