#!/bin/bash
# ホームページ(site/)に、README の画像(assets/)を合わせて、公開する形にまとめる。
#
# 画像は README と同じものを使うので、site/ には写さず、ここで build/site/assets/ に入れる。
# GitHub Actions(.github/workflows/pages.yml)も、このスクリプトでまとめてから公開する。
# 手元で見るときは、まとめたあとで build/site/index.html をブラウザで開く。
# 使い方: tools/build-site.sh [出力先(既定: build/site)]
set -euo pipefail

cd "$(dirname "$0")/.."

out="${1:-build/site}"

# 消してから作り直すので、決まった置き場所だけを受け付ける(site/ やリポジトリを消さないため)。
case "$out" in
    build/site | build/site/* | _site) ;;
    *) echo "出力先は build/site(の下)か _site にしてください: $out" >&2; exit 1 ;;
esac

rm -rf "$out"
mkdir -p "$out/assets"
cp -R site/. "$out/"
cp -R assets/readme "$out/assets/"
cp assets/main_window.png "$out/assets/"

echo "$out にまとめました。"
