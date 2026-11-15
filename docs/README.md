# docs（SimpleEqualizer の開発者向け資料）

保守・改修をする人（自分と Claude）向けの資料です。利用者向けの説明は、リポジトリの直下の README(英語の `README.md`、日本語の `README.ja.md`)にあります。
ここには「なぜそう作ったか」「どこでつまずいたか」を残します。

このプロジェクトでは、作業する場所を2つに分けています。

- `../private/`: **人間**が作業する場所。実現したいこと、参考データ、メモ、後で検討すること(`TODO.md`)を置く。Git に入れない(公開しない)。
- `docs/`（このフォルダ）: **Claude** が作業する場所。仕様、調査、記録を書く。

| ファイル | 内容 |
| --- | --- |
| [specification.md](specification.md) | 仕様書（外部から見た動作と変更履歴） |
| [architecture.md](architecture.md) | 技術解説（構成、処理の流れ、設計判断） |
| [dev-log.md](dev-log.md) | 開発記録（新しいものが上） |
| [failures.md](failures.md) | 失敗・つまずきの記録（症状、原因、対処、教訓） |
| [research/](research/) | 作る前の調査（1テーマ1ファイル、`<対象>_<種類>.md`） |
| [research/Prototype_PreCheck.md](research/Prototype_PreCheck.md) | 試作の前の確認(開発環境、API、出力装置)とその結果 |
| [research/Prototype_Result.md](research/Prototype_Result.md) | 試作の結果のまとめと、次の段階へ進むための判断材料 |
| [research/AVAudioEngine_Tap.md](research/AVAudioEngine_Tap.md) | タップで取り出した音を AVAudioEngine に通す方法 |
| [research/Distribution_Signing.md](research/Distribution_Signing.md) | 登録なしでの配布と署名の調査(署名の方式、許可が残るか、開くときの警告、識別子) |
| [research/OutputDevices_Survey.md](research/OutputDevices_Survey.md) | 出力先まわりの調査(この Mac の出力先、音量を変えられるかの見分け方、切り替えのときに起きること) |
| [tickets/](tickets/) | 大きな更新のチケット（`YYYYMMDD_<テーマ>/`） |
| [archive/](archive/) | 終わった計画・古い資料 |
| [archive/20261012_prototype/](archive/20261012_prototype/) | 試作の音声のコード(Swift だけで書いたもの。ビルドの対象外) |
| [archive/tickets/](archive/tickets/) | 終わったチケット(完了したもの、取りやめたもの) |
| [archive/tickets/20261012_prototype/](archive/tickets/20261012_prototype/) | 試作のチケット(5件) |
| [archive/tickets/20261012_stage2-volume/](archive/tickets/20261012_stage2-volume/) | 段階2(音量)のチケット(8件) |
| [archive/tickets/20261012_stage3-equalizer/](archive/tickets/20261012_stage3-equalizer/) | 段階3(イコライザー)のチケット(7件) |
| [archive/tickets/20261013_stage4-presets/](archive/tickets/20261013_stage4-presets/) | 段階4(プリセット)のチケット(6件) |
| [archive/tickets/20261013_stage5-finishing/](archive/tickets/20261013_stage5-finishing/) | 段階5(仕上げ)のチケット(8件) |
| [archive/tickets/20261107_popup-confirm/](archive/tickets/20261107_popup-confirm/) | ポップアップの中の確かめる画面のチケット(4件) |
| [archive/tickets/20261107_quit-confirm/](archive/tickets/20261107_quit-confirm/) | 終了するときの確かめの条件のチケット(3件。取りやめ) |
| [archive/tickets/20261018_distribution/](archive/tickets/20261018_distribution/) | GitHub での配布のチケット(9件) |
| [archive/tickets/20261108_homepage/](archive/tickets/20261108_homepage/) | GitHub Pages のホームページのチケット(5件) |
| [archive/20261016_specification_v0.30.md](archive/20261016_specification_v0.30.md) | 清書する前の仕様書(版 0.30 の草案。決めるまでの経過と、途中の変更履歴) |

## 使い方

1. **実現したいことを書く（人間）**: `../private/` に Markdown などで書く。
2. **参考データを置く（人間）**: 参考になる資料やデータを `../private/` に保存する。
3. **仕様を作る（AI チャット）**: `../private/` をもとに、Claude に `specification.md` を作らせる。
   調べたことは、必要に応じて `research/` に書かせる。
4. **大きな更新はチケットに分ける（AI チャット）**: `tickets/YYYYMMDD_<テーマ>/` に一覧とチケットを作らせ、確認してから着手させる。
5. **実装する（AI チャット）**: コミットのたびに、Claude が下記のルールで docs を更新する。

入力情報は、別のフォルダで管理したりチャットにだけ残したりしても構いません。`../private/` は、残しておきたいときに使う場所です。

## このフォルダの更新について

`docs/` 配下のファイルは、[../CLAUDE.md](../CLAUDE.md) の「docs の更新（コミット前に必須）」に従って、
Claude が機能追加・修正のコミットと同時に作成・更新します。手作業で書き足す必要は基本的にありません。
内容を直したいときは、手で編集しても、Claude に修正を頼んでも構いません。

**`../private/` はこの対象外です。** 人間が管理し、Claude は読むだけで、頼まれない限り作成・変更・削除しません。
例外は `../private/TODO.md`(後で検討すること)で、Claude も書き足したり消したりします。
