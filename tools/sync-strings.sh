#!/bin/bash
# 文字列カタログ(*.xcstrings)の見出しを、コードの文言に合わせる。
#
# 1. Core とアプリをビルドする(ビルドのときに、コードから文言が取り出される。生成物は、いつもの場所に出る)。
# 2. 取り出した文言を、カタログに足す。コードからなくなった見出しには、使われていない印(stale)がつく。
# 3. 英語の訳がない見出しと、日本語の値がない見出しを出す。
#
# 訳は、出てきた見出しに、Xcode のカタログの画面か、手で書き足す。
# 日本語の値も、見出しと同じものを入れる(入れないと、日本語の表が作られない。docs/architecture.md の「画面の言語」)。
# 足し終えたら、swift test --package-path Core で、抜けがないことを確かめる。
# 使い方: tools/sync-strings.sh
set -euo pipefail

cd "$(dirname "$0")/.."

swift build --package-path Core >/dev/null
xcodebuild -project SimpleEqualizer.xcodeproj -scheme SimpleEqualizer -configuration Debug build >/dev/null

objroot=$(xcodebuild -project SimpleEqualizer.xcodeproj -scheme SimpleEqualizer -configuration Debug -showBuildSettings 2>/dev/null \
    | sed -n 's/^[[:space:]]*OBJROOT = //p')

# カタログ、取り出した文言のあるフォルダ。
sync() {
    local catalog="$1" directory="$2"
    local files=()
    while IFS= read -r file; do
        files+=("$file")
    done < <(find "$directory" -name '*.stringsdata' ! -name 'GeneratedAssetSymbols.stringsdata' ! -name 'ExtractedAppShortcutsMetadata.stringsdata')
    [[ ${#files[@]} -gt 0 ]] || { echo "取り出した文言が見つかりません: $directory" >&2; exit 1; }
    xcrun xcstringstool sync "$catalog" --stringsdata "${files[@]}"
}

core_build=Core/.build/out/Intermediates.noindex/SimpleEqualizerCore.build/Debug
sync Core/Sources/SimpleEqualizerCore/Resources/Localizable.xcstrings "$core_build/SimpleEqualizerCore-t.build"
sync Core/Sources/SimpleEqualizerEngine/Resources/Localizable.xcstrings "$core_build/SimpleEqualizerEngine-t.build"
sync SimpleEqualizer/Localizable.xcstrings "$objroot/SimpleEqualizer.build/Debug/SimpleEqualizer.build"

python3 -I - Core/Sources/SimpleEqualizerCore/Resources/Localizable.xcstrings \
    Core/Sources/SimpleEqualizerEngine/Resources/Localizable.xcstrings SimpleEqualizer/Localizable.xcstrings <<'EOF'
import json
import sys

for path in sys.argv[1:]:
    with open(path, encoding="utf-8") as f:
        strings = json.load(f)["strings"]
    for key, entry in strings.items():
        if entry.get("shouldTranslate") is False:
            continue
        localizations = entry.get("localizations", {})
        missing = [language for language in ("en", "ja") if language not in localizations]
        stale = entry.get("extractionState") == "stale"
        if missing or stale:
            notes = ([f"{'・'.join(missing)} がない"] if missing else []) + (["コードで使われていない"] if stale else [])
            print(f"{path}: {json.dumps(key, ensure_ascii=False)}({'、'.join(notes)})")
EOF
