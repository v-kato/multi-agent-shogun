# cmd_754 redo3 — 実 pane capture 一式(カーソル位置つき)

2026-09-08 14:07 (JST) に、稼働中の10 pane から採取した実画面である。
★読み取りのみで採取しており、打鍵は一切送っていない。

採取コマンド(再現手順):

```bash
D=tests/fixtures/cmd_754_live_panes
printf '# agent_id\tcli\tcursor_y\tcursor_flag\tpane_in_mode\tcapture_lines\n' > "$D/cursors.tsv"
for p in $(tmux list-panes -a -F '#{pane_id}'); do
    aid=$(tmux display-message -t "$p" -p '#{@agent_id}')
    cli=$(tmux show-options -p -t "$p" -v @agent_cli)
    meta=$(tmux display-message -t "$p" -p '#{cursor_y}	#{cursor_flag}	#{pane_in_mode}')
    tmux capture-pane -t "$p" -p > "$D/${aid}.txt"
    printf '%s\t%s\t%s\t%s\n' "$aid" "$cli" "$meta" "$(wc -l < "$D/${aid}.txt")" >> "$D/cursors.tsv"
done
```

## なぜカーソル位置を併記するのか (cmd_754 redo3)

安全状態の判定は「chrome の形」と「端末カーソルの居場所」の★連言である
(`lib/pane_preflight.sh` 冒頭の有限列挙 E1〜E3 × C1〜C3)。
形だけでは「入力枠の上に未知の overlay が併存している画面」を区別できない
——枠の上に在るのは transcript であり、任意の文字列だからである。
そこで「打鍵がどこへ行くか」を端末そのものに問う。`#{cursor_y}` は画面
文字列ではなく端末の状態であり、推論ではなく事実である。

★capture のテキストだけを保存しても、この連言は再現できない。よって
`cursors.tsv` を成果物として同梱する。

## 採取時の状態と期待する分類

| ファイル | @agent_cli | cursor_y | 採取時の状態 | 期待する分類 |
|----------|-----------|----------|--------------|--------------|
| ashigaru1.txt | codex | 13 | 待機中 | `ok:bordered_input_frame` |
| ashigaru2.txt | codex | 13 | 待機中 | `ok:bordered_input_frame` |
| ashigaru3.txt | claude | 19 | 待機中 | `ok:bordered_input_frame` |
| ashigaru4.txt | claude | 13 | 待機中 | `ok:bordered_input_frame` |
| ashigaru5.txt | claude | 13 | 待機中(枠の直上が非空行 `new task? /clear …`) | `ok:bordered_input_frame` |
| ashigaru6.txt | claude | 19 | 待機中 | `ok:bordered_input_frame` |
| ashigaru7.txt | claude | 13 | 待機中 | `ok:bordered_input_frame` |
| gunshi.txt | codex | 13 | 待機中(上辺が `─ Worked for … ───`) | `ok:bordered_input_frame` |
| shogun.txt | claude | 54 | 待機中(上辺に `将軍` のラベル入り) | `ok:bordered_input_frame` |
| karo.txt | claude | 18 | ★作業中(footer に `esc to interrupt`) | `busy_or_processing` |

採取した10 pane すべてで cursor_flag=1・pane_in_mode=0 であり、カーソルは
★入力行そのもの(`❯ ` の行 / `› Ask Codex to do anything` の行)に在った。

## 用途は3つある

1. **過剰抑止の回帰防止** — 有限列挙を狭めた結果、実画面が一枚でも抑止側へ
   落ちれば、その agent は永久に打鍵を受け取れなくなる。T-PF-075 が全枚を
   照合する。
2. **稼働中除外の実例** — karo.txt は「入力枠は描かれているが footer に
   `esc to interrupt` がある」実物であり、最終行だけを見る判定では `ok` に
   なってしまう形である(G754-WORKING-STATE-AUTH-REDO1-03)。
3. **★カーソル条件が効いていることの実画面固定** — T-PF-075 は同じ実画面に
   対しカーソルを1行ずらした場合も試し、★どの pane も `ok` にならぬことを
   確かめる。「入力枠が描けている」ことではなく「カーソルがそこに在る」ことが
   許可の根拠である、という設計(D-4)を実画面で固定するためである。
   ashigaru5.txt は入力枠の直上が非空行であり、「枠の上に何か書いてあれば
   危険」という規則を採れないことの実例でもある。
