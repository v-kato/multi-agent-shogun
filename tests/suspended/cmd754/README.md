# tests/suspended/cmd754/ — cmd_754巻き戻しにより一時退避した試験群

## これは何か

このディレクトリの5ファイル(71件の `@test` ブロック)は、**標準suite外**
である。以下のいずれのコマンドにも含まれない。

- `env -u TMPDIR bats tests/*.bats tests/unit/*.bats` (標準suiteの
  literal command)
- `make test` 等、上記を呼ぶラッパー

理由: これらの `@test` ブロックは cmd_754/cmd_755(送信系の安全化・
自動打鍵の安全集合を空にする変更)を前提として書かれた試験である。
2026-09-10、将軍が `commit 7c59260` により `scripts/inbox_watcher.sh` を
`cmd_754直前(58ed69c^)` の状態へ直接 surgical restore したため、
これらの試験が検査していた前提(「send-keys 等の打鍵経路は1つも
存在しない」)そのものが現行コードと逆になった。

## 経緯(cmd_760)

1. cmd_754巻き戻し後、標準suiteで本71件がFAILする状態になった。
2. 前回subtask(`subtask_760_test_triage_and_fix`)がこの71件を
   (ア)/(イ)に分類し、(ア)71件は「削除せずskip+理由で保存する」形で
   対応した。この技術作業(分類・保存・Tier1不変)自体に瑕疵は無い。
3. しかし、この対応方針(A-3受入条件「skip+理由で保存」)自体が、
   CLAUDE.md Test Rules 1「SKIP=FAIL(SKIP数が1以上なら未完了)」と
   真っ向から衝突していた。これは将軍のA-3受入条件の書き損じであり、
   軍師がPOLICY_BLOCKEDとして止めたのは正しい判断だった。
4. 将軍が2026-09-10 15:19に裁定
   (`queue/shogun_to_karo.yaml` の `shogun_ruling_20260910_skip_conflict`
   に記録)。軍師案A(標準suite外へ保存 + 現行契約の正の試験を別途置く)
   を採用。案B(SKIP=FAIL規則への例外新設)・案C(71件削除)はいずれも
   却下した。
5. 本ディレクトリはその裁定のU-1(「(ア)71件の `@test` ブロックを
   原文のまま `tests/suspended/cmd754/` へ移す」)の実施結果である。

## 各ファイルの中身

`@test` ブロックは元ファイルから **原文のまま**(内容改変なし)切り出して
いる。各ブロックの直前に出所ヘッダ(コメント)を付けてあり、元ファイル名・
元 `@test` ブロック名・移動元行番号(除去前・参考情報)・由来コミット
(`58ed69c`)を記載している。ファイルごとの由来と件数は以下の通り
(移動元は全て `58ed69c`(cmd_754+cmd_755で追加された試験)):

| suspended側ファイル | 移動元(標準suite側) | 件数 |
|---|---|---|
| `agent_selfwatch.bats` | `tests/agent_selfwatch.bats` | 6 |
| `test_inbox_lock.bats` | `tests/test_inbox_lock.bats` | 1 |
| `test_clear_send_gate.bats` | `tests/unit/test_clear_send_gate.bats` | 1 |
| `test_send_keys_preflight.bats` | `tests/unit/test_send_keys_preflight.bats` | 30 |
| `test_send_wakeup.bats` | `tests/unit/test_send_wakeup.bats` | 33 |
| 合計 | | **71** |

## 実行してはいけない、実行しても構わないが結果の意味を誤解しないこと

- 本ディレクトリのファイルには **setup()/teardown()等のscaffoldingを
  意図的に含めていない**(元ファイル側にしかない)。そのため単独で
  `bats tests/suspended/cmd754/*.bats` のように実行すると、多くのテストは
  変数未定義・helper関数未定義に起因するエラーで失敗する。これは
  「意味のあるFAIL」以前の、scaffolding欠落による失敗である。
- 仮にscaffoldingを補って正しく実行できたとしても、**現watcher
  (`commit 7c59260`)に対してはFAILするのが正しい**。つまり
  「有効化して実行すればFAILする、それが正しい状態である」——このFAILは
  回帰ではなく、cmd_754前提が現在は成立していないことの正しい反映である。
- `bats --recursive tests` のように標準suiteの literal command
  (`env -u TMPDIR bats tests/*.bats tests/unit/*.bats`)以外の方法で
  このディレクトリを再帰的に拾ってしまった場合も、上記と同じ理由で
  FAIL(またはscaffolding欠落によるエラー)が出るのが正しい。慌てて
  「回帰した」と早合点せず、本READMEを読むこと。
- 標準suiteの literal command は次の通りであり、本ディレクトリは
  この glob には一致しない(`tests/*.bats` と `tests/unit/*.bats` のみを
  対象とし、`tests/suspended/cmd754/*.bats` は対象外):

  ```
  env -u TMPDIR bats tests/*.bats tests/unit/*.bats
  ```

## 復帰させるタイミング

`cmd_757②`(送信経路の再結線)が完了し、cmd_754が意図した安全化が
再び現行契約になった時点で、本ディレクトリの `@test` ブロックを
元ファイルへ書き戻して復帰させる。復帰作業は「suspended側のブロックを
そのまま実行できるようにする」のではなく、「元ファイル(scaffoldingが
現にある場所)へ内容を統合し直す」形で行うことを想定している
(scaffoldingを本ディレクトリ側へ複製しなかったのはこのため——複製すると
復帰時に二重のscaffoldingが乖離するリスクがある)。

復帰時は、tests/unit/test_cmd760_current_contract.bats
(cmd_760 U-2で新設した「現行契約の正の試験」)が前提としていた
契約(送信経路の安全化前の状態)がその時点でどう変わるかも合わせて
見直すこと。
