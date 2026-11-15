# TICKET-001: Xcode のプロジェクトの作成

## 概要

Xcode のプロジェクトを作り、何もしない空のアプリが `xcodebuild` でビルドでき、起動できる状態にする。
macOS の許可は `.app` と署名にひもづくので、音を扱う前に、アプリの識別子(Bundle ID)と署名を決める。

## ステータス

- [x] 作業中
- [x] 動作確認済み
- [x] 完了

## 依存関係

- 利用者による Xcode の初回セットアップ(`sudo xcodebuild -runFirstLaunch`)。

## 現状

2026-10-12 時点。

- コードもプロジェクトもない。
- `xcode-select` は Xcode 本体を向いている。Xcode 27.0、macOS 27.0 の開発キット。
- Xcode の初回セットアップは終わっていない(`xcodebuild -checkFirstLaunchStatus` が 69 で終了)。
- 署名に使える「Apple Development」の証明書が1つある。Xcode に Apple のアカウントが登録されているかは未確認。

## 対応方針・作業手順

### 着手前に決めること(利用者)

2026-10-12 に両方とも決まった。識別子の値は Git 管理外の `Config/Signing.xcconfig` にあり、ここには書かない。
証明書は「Apple Development」のものを使う。以下は、決める前に書いた説明である。

1. **アプリの識別子(Bundle ID)**: 一度決めたら変えない。形は `<逆順のドメイン>.SimpleEqualizer`。
   自分のドメインがなければ `local.<任意の名前>.SimpleEqualizer` のような形でよい(配布しないため)。
2. **署名に使う証明書**: 「Apple Development」の証明書を使ってよいか。
   仕様書 7章は「その場かぎりの署名」と書いているが、その署名はビルドのたびに変わり、許可を毎回出し直すことになる。
   証明書で署名する形に改め、仕様書 7章も直す。

### 手順

1. `xcodebuild -checkFirstLaunchStatus` で、初回セットアップが終わっていることを確かめる。
2. プロジェクトを作る。外部のツール(XcodeGen など)は使わない。
   プロジェクトのファイル(`project.pbxproj`)は Claude が直接書く。
   うまくいかないときは、利用者に Xcode の画面でひな形を作ってもらう形に切り替える。
3. アプリの設定:
   - macOS のアプリ、SwiftUI、対象は macOS 27。
   - `Info.plist` に `NSAudioCaptureUsageDescription`(システム音声の録音を使う理由。日本語)を入れる。
   - サンドボックスは無効にする(配布しないため。タップと音量キーの扱いを単純にする)。
   - 証明書の名前や識別子は、Git に入るファイルに書かない。
     Git 管理外の設定ファイル(`.xcconfig`)に分け、`.gitignore` に足す。
4. 画面は、ウィンドウ1つに文字を出すだけにする。メニューバー常駐は段階2で行う。
5. `xcodebuild` でビルドする。ビルドの生成物はプロジェクトの外(Xcode の既定の場所)に出す。
6. `CLAUDE.md` の「構成」と「確認方法」に、実際のフォルダ構成とビルドのコマンドを書く。
7. `docs/architecture.md` の「構成」を実際の内容に書き換える。

## 影響ファイル

- `SimpleEqualizer.xcodeproj/project.pbxproj`(新規)
- `SimpleEqualizer/SimpleEqualizerApp.swift`、`ContentView.swift`(新規)
- `SimpleEqualizer/Info.plist`(新規)
- 署名の設定ファイル(新規、Git 管理外)とその見本(Git に入れる)
- `.gitignore`
- `CLAUDE.md`、`docs/architecture.md`、`docs/specification.md`(7章)、`docs/dev-log.md`、`docs/TODO.md`

## 動作確認項目

Claude が行う:

- [x] `xcodebuild` のビルドが成功する。
- [x] できた `.app` の署名が、決めた証明書になっている(`codesign -dv`)。
- [x] 2回続けてビルドしても、署名の識別情報が変わらない。

利用者に頼む:

- [x] `.app` を起動すると、ウィンドウが1つ開く。
- [x] 終了できる。

## 実施結果

2026-10-12 に実施。

行ったこと:

- 利用者の決定を受けた: アプリの識別子、「Apple Development」の証明書を使うこと。
- プロジェクトのファイルを手で書いた。Xcode の画面でひな形を作ってもらう必要はなかった。
- 手順からの変更点:
  - アプリの識別子に名前が入るので、識別子も証明書と同じ Git 管理外のファイル(`Config/Signing.xcconfig`)に置いた。
  - `Info.plist` は `SimpleEqualizer/` ではなく `Config/` に置いた。
    `SimpleEqualizer/` は中身を自動で取り込むフォルダで、そこに置くとアプリの中へ余分に写されるため。
  - ハードンドランタイムは無効のままにした(`TODO.md` に記載)。

確認できたこと(Claude):

- `xcodebuild` のビルドが成功した。
- 署名の検証(`codesign --verify --strict`)が通った。署名は「Apple Development」の証明書になっている。
- ソースを書き換えて2回ビルドし、署名の識別情報と、アプリを見分ける条件(designated requirement)が同じだった。
- できた `Info.plist` に `NSAudioCaptureUsageDescription` が入っている。サンドボックスの設定は入っていない。
- 識別子、証明書の持ち主、チームの番号が、Git に入るファイルに含まれていない。

確認できたこと(利用者、2026-10-12):

- `.app` を起動するとウィンドウが1つ開いた。Command + Q で終了できた。

はまりどころ: なし。

見直し(`/code-review`): コミットの前に実施。指摘はなかった。
