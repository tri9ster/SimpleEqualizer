#!/bin/bash
# 配布物(dmg)を作る。
#
# 1. Release でビルドする(生成物は、いつもの DerivedData に出る)。
# 2. できたアプリを build/release/stage/ に写し、自己署名の証明書で署名し直す。
#    開発用の証明書の署名には、個人の情報が入るので、そのまま配らない(docs/research/Distribution_Signing.md)。
# 3. アプリと、アプリケーションのフォルダへのショートカットと、開き方の案内(tools/dmg-guide.txt)を、dmg にまとめる。
# 4. 写したアプリを消し、macOS の登録からも外す。途中で失敗しても必ず行う
#    (同じ識別子のアプリが、macOS に余分に登録されないようにする。docs/failures.md)。
#
# 証明書の名前は、Config/Signing.xcconfig の RELEASE_SIGN_IDENTITY に書く。
# 使い方: tools/make-release.sh [xcodebuild に渡すビルドの設定 ...]
#   例: tools/make-release.sh CURRENT_PROJECT_VERSION=2
set -euo pipefail

cd "$(dirname "$0")/.."

fail() {
    echo "$1" >&2
    exit 1
}

# xcconfig から値を読む(前後の空白と、行の終わりの // のコメントを除く。最後に書いたものを使う)。
read_setting() {
    local file="$1" key="$2"
    [[ -f "$file" ]] || return 0
    sed -n "s/^[[:space:]]*$key[[:space:]]*=[[:space:]]*//p" "$file" \
        | sed -e 's/\r$//' -e 's://.*$::' -e 's/[[:space:]]*$//' | tail -n 1
}

identity=$(read_setting Config/Signing.xcconfig RELEASE_SIGN_IDENTITY)
[[ -n "$identity" ]] || fail "Config/Signing.xcconfig に RELEASE_SIGN_IDENTITY(配布物の署名に使う証明書の名前)がありません。"

# 署名に使える証明書の一覧(信頼されていて、期限の切れていないものだけ)。
identities=$(security find-identity -v -p codesigning)
matches=$(grep -cF "\"$identity\"" <<<"$identities" || true)
[[ "$matches" -ge 1 ]] || fail "キーチェーンに、署名に使える証明書「$identity」が見つかりません(信頼の設定と、期限を確かめてください)。"
[[ "$matches" -eq 1 ]] || fail "キーチェーンに、証明書「$identity」が $matches 個あります。1 個にしてください。"

# 配ってよい識別子。Signing.xcconfig に古い識別子(個人の情報を含む)が残っていると上書きされるので、ビルドの結果と比べる。
public_id=$(read_setting Config/Project.xcconfig PRODUCT_BUNDLE_IDENTIFIER)
[[ -n "$public_id" ]] || fail "Config/Project.xcconfig に PRODUCT_BUNDLE_IDENTIFIER がありません。"

project=SimpleEqualizer.xcodeproj
scheme=SimpleEqualizer

settings=$(xcodebuild -project "$project" -scheme "$scheme" -configuration Release -showBuildSettings "$@")
setting() { sed -n "s/^ *$1 = //p" <<<"$settings" | head -n 1; }
products_dir=$(setting BUILT_PRODUCTS_DIR)
version=$(setting MARKETING_VERSION)
bundle_id=$(setting PRODUCT_BUNDLE_IDENTIFIER)
[[ -n "$products_dir" && -n "$version" ]] || fail "ビルドの設定(BUILT_PRODUCTS_DIR、MARKETING_VERSION)を読めませんでした。"
[[ "$bundle_id" == "$public_id" ]] || fail "アプリの識別子が、Config/Project.xcconfig の値と違います。Config/Signing.xcconfig に PRODUCT_BUNDLE_IDENTIFIER が残っていないか確かめてください。"

out_dir="build/release"
stage="$out_dir/stage"
dmg="$out_dir/SimpleEqualizer-$version.dmg"
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# 写したアプリを消し、macOS の登録からも外す。途中で失敗したときも行う。
cleanup() {
    if [[ -d "$stage/SimpleEqualizer.app" ]]; then
        "$lsregister" -u "$stage/SimpleEqualizer.app" 2>/dev/null || true
    fi
    rm -rf "$stage"
}
trap cleanup EXIT

echo "== Release でビルドする"
xcodebuild -project "$project" -scheme "$scheme" -configuration Release build -quiet "$@"

rm -rf "$stage" "$dmg"
mkdir -p "$stage"

echo "== 写して、自己署名の証明書で署名し直す"
ditto "$products_dir/SimpleEqualizer.app" "$stage/SimpleEqualizer.app"
# ファイルについた拡張属性を外してから署名する。
# macOS が管理する出どころの印(com.apple.provenance)は、dmg にまとめるときに付け直される。中身は番号だけで、個人の情報は入らない。
xattr -cr "$stage/SimpleEqualizer.app"
codesign --force --sign "$identity" --timestamp=none "$stage/SimpleEqualizer.app"
codesign --verify --strict "$stage/SimpleEqualizer.app"

signed_id=$(codesign -dv "$stage/SimpleEqualizer.app" 2>&1 | sed -n 's/^Identifier=//p')
[[ "$signed_id" == "$public_id" ]] || fail "署名したアプリの識別子が、配ってよい値と違います。"

echo "== 署名の中身(個人の情報が入っていないかを確かめる)"
codesign -dvv "$stage/SimpleEqualizer.app" 2>&1 | grep -E "^(Identifier|Authority|TeamIdentifier)="
codesign -d -r- "$stage/SimpleEqualizer.app" 2>&1 | grep "designated"

echo "== dmg にまとめる"
ln -s /Applications "$stage/Applications"
# 公証を受けていないので、開くときに macOS に止められる。開き方を、dmg を開いた人の目に入る場所に置く。
cp tools/dmg-guide.txt "$stage/はじめにお読みください - Read me first.txt"
hdiutil create -volname "SimpleEqualizer $version" -srcfolder "$stage" -ov -format UDZO "$dmg" -quiet

echo "== できた: $dmg"
