# 出陣やり直し時の Claude 会話 resume(Remote Control の継続)

cmd_785。実測の根拠: `context/cmd_785_resume_poc.md`(Phase 0 PoC・Claude Code 2.1.284)、
`context/cmd_785_phase1b_experiment.md`(Phase 1b 起動時の固定プロンプトの隔離実測・2.1.285)。
実装: `lib/claude_session_resume.sh`(採取・照合・起動直後失敗の復旧経路)・`lib/cli_adapter.sh`(`build_cli_command` の第2引数、
起動時の固定プロンプト `get_claude_startup_token`)・`shutsujin_departure.sh`(STEP 1 の採取と STEP 6 の起動コマンド。
`shutsujin_launch_cmd`)・`scripts/session_start_hook.sh`(毎回変わる1行)。試験: `tests/unit/test_claude_session_resume.bats`。
cmd_796(WSL 再起動・クラッシュ後の前回スナップショットの再利用・別 opt-in)は 8。設計確認(規範):
`context/cmd_796_design_review.md`。

## 1. 何のためか ― 孤児セッション

Remote Control(以下 RC)を全セッションで常時 ON(ユーザー設定 `remoteControlAtStartup: true`)に
すると、Claude Code を起動するたびに Claude アプリの Code タブへ1項目が作られる。出陣
(`shutsujin_departure.sh`)は撤収で全 pane を落として新しく起動し直すため、従来はやり直しの
たびに Claude 系 agent の数だけ新しい項目が増え、前回の項目は二度と繋がらない
**孤児セッション**としてアプリに残った。

Claude Code は `--resume <sessionId>` で会話を再開すると、その会話に記録された RC セッションへ
再接続する。そこで出陣は、撤収の直前に各 agent の会話 ID を採取し、起動時に同じ会話を
再開する。アプリ上では前回の項目がオンラインへ戻り、新しい項目は増えない。

## 2. 有効化(opt-in)

```yaml
# config/settings.yaml
cli:
  claude_session_resume: true   # 未記載・false なら無効(従来どおり毎回新規起動)
```

OSS の既定は無効(キーが無い)。`config/settings.yaml` はローカル設定(git 管理外)。

## 3. 仕組み

1. **採取(STEP 1・撤収の直前に一度だけ)**: `shogun`・`multiagent` セッションの pane のうち
   `@agent_cli` が `claude` のものについて、pane の前景シェル → その直接の子の `claude`
   プロセス → `~/.claude/sessions/<pid>.json` の順に引く。記録の `pid` 欄・`procStart`
   (`/proc/<pid>/stat` 第22欄と一致)・`name`(= `@agent_id`)・`sessionId`(UUID 形式)が
   全て揃ったものだけを、今回の採取 `queue/state/claude_session_snapshot.current.yaml` へ
   一時ファイル+rename で書く。揃わなかった agent は理由付きで `skipped` に残る。
   `queue/state/claude_session_snapshot.yaml`(正本)は「最後の実採取記録」で、撤収前に全対象が
   確実に不在だった時は残し、それ以外は今回の採取で置き換える(cmd_796。8 を見よ)。
   - 名前や sessionId での検索はしない。終了済みプロセスの記録が同じ名前・同じ ID のまま
     残ることがあるため(PoC §5-2)。
   - 採取は読み取りだけ。撤収前に `/clear`・`/exit` を送ることはしない(cmd_754 裁定)。
2. **起動(STEP 6)**: agent ごとに、同じ出陣で採った記録(`run_token` 一致)に ID があり、
   起動 cwd の project dir(`~/.claude/projects/<cwd の英数字以外を - にしたもの>/`)に
   転写 `<sessionId>.jsonl` が実在すれば、`claude --resume <sessionId> --model … --name <agent_id> …`
   で起動する。`build_cli_command` 側でも UUID 形式を再検査する。
3. **従来の新規起動へ落ちる場合**(出陣は止まらない):
   - 無効設定・ライブラリが無い・`--clean` 指定
   - 出陣セッションが無い(PC・WSL 再起動後など。採る相手がいない。別 opt-in の 8 を有効にした時だけ、
     前回の正本を厳しい条件で再利用する)
   - pane に claude の子プロセスが無い/複数ある、記録が無い・壊れている・照合が合わない
   - 転写が無い(存在しない ID を渡すと claude は rc=1 で即終了し pane が空になるため、
     必ず確かめてから付ける)
   - 記録の書込みに失敗した(前回以前の記録は `run_token` が違うので使わない)
   - Codex 系など claude 以外の agent(常に対象外)
   - それでも `--resume` 起動が起動直後に自ら失敗した(→ 4 で**1回だけ**新規起動へ倒す)

## 4. 起動直後の失敗に限る1回だけの新規起動(G785-Q01)

事前の確認(記録・転写の実在)では塞げない失敗がある。転写の破損、確認後の変化、CLI が ID を
拒む将来の変更などである。そこで resume する agent の起動コマンドは次の1行になる
(`claude_resume_launch_cmd`)。pane へ打鍵するのは従来どおりこの1行と Enter の1回だけで、
稼働中の pane へ追加の打鍵はしない。

```sh
_csr_u=; read -r _csr_u _csr_x 2>/dev/null < /proc/uptime; _csr_t0=${_csr_u%%.*}; claude --resume <id> <従来引数>; _csr_rc=$?; _csr_u=; read -r _csr_u _csr_x 2>/dev/null < /proc/uptime; _csr_t1=${_csr_u%%.*}; _csr_dt=; [ "$_csr_t0" -ge 0 ] 2>/dev/null && [ "$_csr_t1" -ge "$_csr_t0" ] 2>/dev/null && _csr_dt=$(( _csr_t1 - _csr_t0 )); if [ "$_csr_rc" -ge 1 ] && [ "$_csr_rc" -le 127 ] && [ -n "$_csr_dt" ] && [ "$_csr_dt" -lt 30 ]; then echo "[shutsujin] claude --resume が起動直後に終了 (…)。従来の新規起動へ切り替える (1回のみ)"; claude <従来引数>; elif [ "$_csr_rc" -ge 1 ] && [ "$_csr_rc" -le 127 ] && [ -z "$_csr_dt" ]; then echo "[shutsujin] claude --resume が rc=… で終了したが、経過秒を単調時計 (/proc/uptime) で測れないため新規起動へ切り替えない" >&2; fi
```

| resume 起動の終わり方 | 新規起動(`--resume` 無し・同じ従来引数) |
|---|---|
| 起動から **30秒未満** に rc **1〜127** で終了(起動失敗。PoC では存在しない ID で約2秒・rc=1) | **1回だけ**する |
| 30秒以上動いた後の終了(通常のクラッシュ・`/exit`・殿の操作) | しない |
| rc=0(起動直後の `/exit` など) | しない |
| rc≥128(signal による終了・停止: 撤収の SIGHUP、Ctrl-Z による停止=148 など) | しない |
| 新規起動もまた失敗した | 何もしない(2回目以降の自動再起動は無い。ループしない) |
| 経過を測れなかった(`/proc/uptime` が読めない等。下記「30秒の測り方」) | しない(rc 1〜127 なら理由を stderr に1行) |

- resume しない起動(記録なし・opt-in 無効・`--clean`・Codex 系)には付けない。従来のコマンドそのもの。
- 広い `claude --resume … || claude …` は採らない。作業中の通常のクラッシュの後にも新規起動が
  立ち上がってしまうため。経過秒と rc で「起動失敗」だけを識別する。
- **上限30秒の根拠**: 起動失敗の実測は約2秒(PoC E)。現存最大の転写(57MB)の JSON 解析は
  0.42 秒(読み取りのみで計測)で、転写の読込を含めても起動失敗は数秒で出る。出陣は Claude 系を
  最大9本ほぼ同時に起こすので、負荷による遅れへ約10倍の余裕を取った。resume 後の agent は入力が
  来るまで作業を始めない。短すぎれば復旧を取り逃して pane が空のまま残り、長すぎても余分に
  起こるのは高々1回の新規起動である。この非対称から例示幅(15〜30秒)の上端を採った。
  値は `lib/claude_session_resume.sh` の定数 `CLAUDE_RESUME_FALLBACK_WINDOW_SEC`(環境変数では変えない)。
- **rc≥128 を除く理由**: signal による終了・停止は起動失敗ではない。特に Ctrl-Z で止めた時は
  bash が 128+SIGTSTP=148 を返して一覧の続きへ進み得る(bash の挙動からの推論。実測はしていない)。
  そこで新規起動すると、止まった claude の横に2つ目の claude が並び、次の撤収前の採取も
  (子 claude が複数で)判定できなくなる。
- **30秒の測り方(単調時計・cmd_794)**: 経過は `/proc/uptime` の先頭の値(起動からの秒。
  Linux の CLOCK_BOOTTIME)の整数部を、resume 起動の直前と直後に読んだ差で測る。bash・dash とも
  組込みの `read` だけで読め、外部コマンドを起こさない。
  - **負の経過は起こり得ない**: CLOCK_BOOTTIME は時刻の設定(`date -s` など)や時刻同期の段差補正で
    値が飛ばず、起動後に減ることが無い。したがって直後の値は直前の値以上で、差は 0 以上になる。
    それでも直後の値が直前より小さく読めた時は、読取りの異常として「測れない」側に扱う(下記)。
  - **測れない時は倒さない(fail-closed)**: 読取りの失敗(ファイルが無い・読めない)・空・数値でない・
    直後 < 直前 のどれかなら経過を空のままにし、新規起動へ倒さない。現実時計(`date`)の差へは
    倒さない。rc 1〜127 で終わった時だけ、倒さなかった理由を stderr へ1行出す
    (`[shutsujin] claude --resume が rc=N で終了したが、経過秒を単調時計 (/proc/uptime) で測れないため新規起動へ切り替えない`)。
    rc 0・rc≥128 はもともと倒さないので、測れなくても何も出さない。
  - 読む前に変数を空にするので、pane の対話シェルに前回の値が残っていても使われない。
  - 整数部の差なので、単調時計が測る経過との差は(小数部の切り捨てによる)1秒未満(例: 29.01 秒を 30 と測ることがある)。境界付近の
    ±1 秒は上限の余裕(約10倍)に比べて小さい。
  - **なぜ現実時計をやめたか(cmd_791 の所見)**: 2026-09-30、当機の WSL2 ではゲスト時計がホストより
    約10%速く進み、systemd-timesyncd が約30秒ごとに約2.9秒巻き戻していた(20秒の sleep で現実時計は
    17.07秒・単調時計は20.000秒)。旧版の `date +%s` の差では、起動失敗(約2秒)の最中に段差が入ると
    経過が負になって倒さず pane が空のまま残り(失敗1回あたり約6%と推定)、逆に約31〜33秒動いた後の
    失敗が28〜30秒と測られて余計な新規起動が足され得た。段差を判定区間へ狙って落とす実測(偽 claude・
    cmd_794)では、旧版は7回中7回を誤り(1.5秒の失敗を経過 −1/−2 秒として倒さず、31.5秒動いた後の
    失敗を28/29秒として倒した)、単調時計の版は7回とも正しく判定した。時計ずれそのもの(環境側)の
    是正は別件(WSL の再起動など)で、本仕組みの範囲外。
- resume 起動も新規起動も pane のシェルの**直接の子**として走る(隔離 tmux で確認)。次の撤収前の
  採取が「pane の直接の子の claude」を引く前提は崩れない。
- 包む前に、ID の UUID 形式・resume 側が新規側へ ` --resume <id>` を1つ足しただけの形であること・
  コマンドに構造を変え得る文字(改行・`;`・`&`・`|`・`#`・`$`・`` ` ``・`<`・`>`・`\`・`!`・引用符)が
  無いことを確かめる。満たさなければ resume を諦めて従来の新規起動だけを打つ(理由は stderr)。
  `build_cli_command` が組む claude の起動コマンドはどれも満たす。
- 構文は POSIX sh の範囲(bash・dash で試験)。zsh は当環境に無く未実測。

**残る限界(正直に記す)**:

- 30秒以内に rc 1〜127 で終わる操作は、人の操作であっても1回だけ新規起動になる。
- `/proc/uptime` の無い環境(Linux 以外。例: macOS)では経過を測れないため、起動直後に失敗しても
  新規起動へ倒れない(fail-closed。上記の理由が stderr に出る)。resume の事前照合はそのまま働く。
- 単調時計が除くのは段差(巻き戻し)だけで、時計そのものの進みの狂いは除かない。当機(2026-09-30)の
  WSL2 ではゲストの単調時計がホストより約10%速く(cmd_791 の実測で比 1.1004)、上限30秒は実時間で
  約27秒にあたる。起動失敗(約2秒)に対する余裕は十分で、段差と違って経過が負になることも、
  倒す・倒さないの取り違えが段差の位置で変わることも無い。
- 新規起動へ倒れた agent は前回の会話を引き継がず、Claude アプリには新しい項目が1件でき、前回の
  項目は孤児になる(手作業アーカイブの対象)。
- 本物の claude が破損した転写・0 byte の転写でどう終わるかは未実測。rc 1〜127 で30秒以内に
  終われば倒れるが、起動したまま画面上のエラーで止まり rc を返さない場合は倒れない。

素の `--resume`・`--resume <name>`・`--continue` は使わない。名前指定は同名の会話が複数あると
対話 picker が開いて起動が止まる(`/clear` は名前を新しい会話へ引き継ぐので同名は常態)。
`--continue` は同じ cwd の agent 全員が同じ会話を掴む。

## 5. 起動時の固定プロンプト(転写を作る・cmd_785 Phase 1b)

**なぜ**: Claude は起動しても、最初の入力が来るまで会話の転写(`<sessionId>.jsonl`)を作らない。
一方 RC の項目は起動から約2秒で作られる。そのため一度も入力を受けずに撤収された agent は
「項目はあるが転写が無い」状態になり、次の出陣では 3 の「転写が無い」で resume できず新規起動になり、
前回の項目が孤児になる(2026-09-30 の足軽3号。隔離実測: `context/cmd_785_phase1b_experiment.md` §3-3)。

**何をするか**: opt-in(`cli.claude_session_resume: true`)の時、Claude 系の起動コマンドの末尾へ固定の
1語 `run-session-start-procedure` を付ける。Claude はこれを初期プロンプトとして受け取り、起動と同時に
転写を作る(実測で起動から約1.5秒・最初の応答より前。RC の記録もその直後、応答より前に転写へ入る)。

```sh
claude [--resume <id>] --model … --name <agent_id> --dangerously-skip-permissions run-session-start-procedure
```

- **手順を始める合図に限る**。別の権限やタスクは与えない。何をするかは SessionStart hook が注入する
  Session Start 手順と CLAUDE.md に従う(足軽は task YAML の status が assigned なら実行、idle・done なら
  待機し、再報告しない)。
- **付ける起動**: resume 起動と新規起動の両方に、同じ形で1回ずつ。記録なし・転写なし・`--clean`・4 で倒した
  先の新規起動・`scripts/switch_cli.sh` による CLI 切替後の起動も含む(どれも `build_cli_command` を通る)。
  **付けない起動**: opt-in 無効、Codex 系など Claude 以外(従来と完全に同じ)。`lib/cli_adapter.sh` を
  読めない時も付けない(その時は resume 自体も無効)。
- **反映箇所**: `lib/cli_adapter.sh` の `get_claude_startup_token` → `get_startup_prompt_arg` →
  `build_cli_command`(将軍・将軍 thinking 上書き・家老・平時の足軽・軍師)。決戦の陣の手組み起動も、同じ
  `get_startup_prompt_arg` を従来コマンドの末尾へ足してから resume 側を組む。
- **定数と検査**: role・task・環境変数を差し込まない定数。引用符の要らない語に限り、許可リスト(小文字英数字の
  語を `-` で3語以上つないだもの。1〜2語は `rm`・`update` 等の claude のサブコマンドと取り違え得る)で
  検査する。合わなければ付けずに従来の起動にする(理由は stderr)。引用符の要らない語なので、4 の照合
  (resume 側 = 新規側 + ` --resume <id>`)と危険文字検査を**緩めずに**そのまま通る(空白入りの引用文を
  付けると、危険文字検査に落ちて全 agent の resume が新規起動へ倒れる。実測)。
- **語の直前は真偽値フラグ**(`--dangerously-skip-permissions`)。`--tools`・`--add-dir` 等の可変長の値を取る
  オプションを直前に置くと、語を値として飲み込む。起動コマンドの末尾にそれらを置かないこと。
- 初期プロンプトのある resume では、「Resume from summary」等の対話画面の判定そのものが呼ばれない
  (2.1.285 の静的確認。出現そのものは未再現)。7 の注意は、プロンプトの無い手動 resume に残る。
- `inbox_watcher.sh` が `/clear` 後に打鍵する文面(`get_startup_prompt`)は変えていない。
- Claude アプリの各項目には、起動のたびにユーザー発言 `run-session-start-procedure` が1件ずつ表示される
  (仕様どおり)。

**resume 時の SessionStart hook**: hook の出力がその会話に既にある注入と同一だと、resume の時は会話へ
加わらない(隔離実測 2/2。出力が違えば加わり、モデルにも見える 2/2)。本番の hook は固定文だったため、
resume 時の新しい合図が初期プロンプトの1語だけになり、モデルが YAML を読み直さずに記憶で答えた例が
あった(1/2)。そこで `scripts/session_start_hook.sh` の Claude 版の出力末尾へ、呼ばれるたびに変わる1行
(`起動時刻: <時刻>(毎回変わる行。resume 時も、記憶に頼らず上記の手順を今あらためて実行せよ)`)を足した。
Codex 版の出力と、agent 不明(個人利用)時の無出力は変えていない。変更後の本物の hook で、resume 時にも
注入が転写へ記録され、モデルが手順を再実行することを隔離で確かめた(`context/cmd_785_phase1b_impl.md` §3)。

**費用**: 起動のたびに各 Claude 系 agent が1ターン(Session Start 手順の分)動く。resume のたびに会話へ
ユーザー発言が1件ずつ積もる(将軍・家老も同じ)。キャッシュが冷えた会話では最初のターンで会話全体が
キャッシュへ書き込まれる(プロンプトが無くても最初の nudge で同じことが起きる。増えるのは、出陣後に
nudge を受けず待機するはずだった agent の分)。本番モデルでの1ターンの費用は未実測。

### 種まき回と検証回

転写が無いまま撤収された agent(2026-09-30 時点の足軽3号相当)は、本機能を入れた後の**次の出陣**でも
まず「転写が無い」→ 新規起動になり、そこで初めて固定の1語により転写ができる(**種まき回**)。
その agent の分だけアプリに新しい項目が1件増え、前回の項目は孤児になる。**その次の出陣**で全 Claude 系
agent が resume でき、新しい項目0件を確かめられる(**検証回**)。出陣前に各 agent の転写の有無を確かめ、
種まき回を「新規0件」と報告しないこと。

## 6. resume 後の agent

- SessionStart hook は resume 経路でも発火し(`source: "resume"`)、Session Start 手順を注入する
  (出力末尾の毎回変わる1行により、resume のたびに会話へ加わる。5)。
- permission mode は復元されないため、従来どおり起動引数(`--dangerously-skip-permissions` 等)で
  指定する。model も `config/settings.yaml` の値が起動引数で優先される。
- context は無対処(殿確定 2026-09-29)。将軍・家老は会話を引き継ぎ、必要なら本人が
  `/compact`・`/clear` を行う。足軽は task_assigned 時の context reset に委ねる。
  `/clear` しても RC 接続は切れず、`/clear` 後の会話 ID で resume しても同じ項目へ戻る(PoC (ii))。

## 7. 運用上の注意

- **統合後1回目の出陣**: 既存の会話に RC の記録が無い agent は、resume した時点で新しい項目が
  1件ずつ作られる。2回目以降の出陣では同じ項目へ戻り、増えない。
- **転写がまだ無い agent は新規起動になる**: 起動後に一度も入力を受けていない agent 等は、記録に ID が
  あっても転写が未生成で 3 の「転写が無い」に弾かれ、新規起動になる(アプリに新項目が1件できる。設計どおり。
  2026-09-30 の出陣やり直しで足軽3号が該当)。`/clear` 後に発言が無いだけなら転写は `/clear` の時点で作られて
  おり、該当しない(PoC (ii)・同日の足軽6号)。5 の固定プロンプトの後は、出陣・CLI 切替で起動した agent は
  起動と同時に転写を作るので、該当するのは固定プロンプト以前に起動した agent と、手で起動した agent に限られる。
- **既存の孤児はアプリ側で手作業アーカイブする**。★ただし現役 agent の項目はアーカイブしても、
  次の出陣の resume で**アーカイブが解除されて戻ってくる**(再接続は unarchive してから行われる)。
  アーカイブするのは、もう resume されない孤児だけにすること。
- **再接続に失敗した時**: 「Previous session is unavailable — run /remote-control to start a new one」
  と表示され、ローカルの agent は RC 無しで動き続ける。アプリから見えなくなるだけで作業は止まらない。
  必要ならその pane で `/remote-control` を実行する。
- **agent で `/remote-control` を切り替えない**: 接続するたびに新しい項目が作られ、切断すると会話の
  RC 記録が空になって次の resume は新規項目になる。
- **手動で再開する時は ID を指定する**: `claude --resume <sessionId> --name <agent_id> …`。
  claude が終了時に表示する `claude --resume "<name>"` の案内は、同名が多い本環境では picker を開く。
- **出陣は通常のターミナルから行う**: Claude のセッション内から tmux server を新たに起こすと、
  pane が親セッションの `CLAUDE_CODE_SESSION_ID`・messaging socket 等の環境変数を継承する。
- **「Resume from summary」ダイアログ**: 長時間放置した大きな会話を resume すると、最初の入力前に
  選択ダイアログが出ることがある(条件は PoC (iii))。選択肢部品は数字キーで即確定するため、inbox
  nudge の `inboxN` の N がその番号を選び得る(`inbox3` = 「Don't ask me again」=
  `~/.claude.json` の `resumeReturnDismissed: true`)。扱いは殿の判断事項として上申済み。出陣の resume は
  5 の固定プロンプト付きなので、この判定は呼ばれない(2.1.285 の静的確認)。プロンプトの無い手動 resume では残る。

## 8. WSL 再起動・クラッシュ後の前回スナップショットの再利用(cmd_796・別 opt-in)

**なぜ**: 1〜7 の仕組みは「同じ出陣で撤収の直前に採った記録」しか使わない(`run_token` 完全一致)。
WSL 再起動(時計ずれの是正などで必要)やクラッシュの後の出陣では、撤収前に採る相手(稼働中の claude)が
いないので、全 Claude 系 agent が新規起動になり、Remote Control 項目がその数だけ孤児になる。
そこで、撤収前に**確実に不在だった** agent に限り、前回の出陣で採った正本の ID を、下記の全条件を
通した時だけ再利用する。正規の設計確認(規範)は `context/cmd_796_design_review.md`。

### 8-1. 有効化(別 opt-in・既定 OFF)

```yaml
# config/settings.yaml
cli:
  claude_session_resume: true                     # 1〜7 の通常 resume(必須)
  claude_session_resume_previous_snapshot: true   # 前回スナップショットの再利用(既定 OFF)
```

- 両方が真の時だけ働く。真と読む値は通常 resume と同じ(`true`・`True`・`yes`・`on`・`1`)。未記載・偽・
  設定を読めない時は OFF。
- `--clean` は両 switch に優先し、全員新規。さらに正本へ「再利用不可」の記録(`invalidated: true`)を
  書く(resume の switch が OFF でも)。clean を挟んだ後の再起動で clean 前の会話を復活させない。
- Codex 等 Claude 以外の agent は対象外で、起動コマンドは変わらない。
- 出陣の排他(`flock`)を取れない環境(`flock` コマンドが無い)と、`/proc` の無い環境(macOS など)では
  働かない(fail-closed)。通常 resume(1〜7)はそのまま動く。

### 8-2. cmd_785 の安全設計(同一 run_token 限定)との関係

同一 run の照合(`claude_resume_lookup`。`run_token` 完全一致・UUID・転写の実在)は**変えない**。
古い token を今回の値へ書き替えて通す設計も採らない。前回の再利用は別の専用関数(`claude_resume_plan`)が
下の全条件で検査し、起動計画に `source: previous_snapshot` と**元の** `run_token`・採取時刻を記す。
前回由来の ID が今回の実採取になったと偽装しない。

| ファイル(`queue/state/`) | 役割 |
|---|---|
| `claude_session_snapshot.current.yaml` | 今回の採取(撤収前の観測つき)。同じ出陣の照合はこれを読む |
| `claude_session_snapshot.yaml`(正本) | 最後の実採取記録。前回の再利用はこれを読む(今回の採取で置換する**前**に読む) |
| `claude_session_plan.yaml` | 出陣1回分の起動計画(`run_token`・agent ごとの由来・ID・bridge・理由) |
| `shutsujin.lock` | 出陣の排他(`flock`)。中身は空 |

**正本の保存方針**: 撤収前に全対象が確実に不在(absent)なら、正本を byte 単位で残す(再起動後の出陣を
繰り返しても候補を消さない)。稼働対象がいた・観測できなかった(unknown)なら、今回の**実採取結果**で
置き換える(失敗した agent の穴へ前回の ID を混ぜない。全件採取 NG なら空の agents と理由を持つ記録になり、
旧記録を再利用可能なままにしない)。採取そのものに失敗した時は正本を「再利用不可」にし、そのrunは全員新規。
書込みは一時ファイル+fsync+rename+親 dir の fsync。

### 8-3. 「採れなかった」と「いなかった」を分ける(撤収前の観測・三値)

各対象 agent について、撤収前に次のどれかを current へ記録する(`observations`)。

| 観測 | 意味 | 前回の再利用 |
|---|---|---|
| `present` | 対象 pane の直接の子に claude が1つあり、記録の照合が通った | 使わない(通常の同一 run 照合) |
| `absent` | tmux が「server/セッションが無い」と明言したか pane が素のシェル(子の探索が成功して claude が0件)で、**かつ** `/proc` の観測が完了して同じ実行ユーザーの生存 Claude にその役名がいない | 条件付きで使う |
| `unknown` | 子の探索の失敗(出力の無い非0終了・0件を `/proc` で裏取りできない時を含む)・複数の子・記録が無い/壊れた/照合不一致、tmux の他の失敗、別の所に同じ役名の Claude、記録を検証できない生存 Claude が1つでもいる | 使わない |

- tmux の非0や空の出力だけで absent を作らない。「無い」と認めるのは tmux の文面
  (`can't find session`・`no server running on`・`error connecting to … (No such file or directory)`)の時だけ。
- 子の探索(`claude_resume_child_claude_scan`)は ps の終了コードを捨てない。rc=0 は `pid comm` の形の行だけが
  出た時にその内容で判定する。rc=1(ps は0件と失敗のどちらにも1を返す)は、何も出ず、かつ
  `/proc/<pane_pid>/task/*/children` が全て読めて空の時だけ 0件とする。それ以外の rc(2 以上・signal 相当)、
  形の崩れた行、行の無い rc=0 は探索失敗(unknown)。
- 撤収前に unknown だった agent を、撤収後に PID が消えたことを理由に absent へ格上げしない。
- 現生存 Claude の観測(`claude_resume_live_observe`)は `/proc` から同じ実行ユーザーのプロセスを列挙し、
  comm が `claude` のもの(と、判別できる別の起動形式)について、そのプロセスの環境の `CLAUDE_CONFIG_DIR`
  (無ければ `HOME/.claude`)の `sessions/<pid>.json` を2回読み、pid・procStart(現 starttime)・sessionId が
  一致して安定した時だけ「使用者」として数える。記録が無い・壊れた・照合不一致・読めない生存 Claude は
  「判定不能」で、前回経路を閉じる。死んだ PID の残存記録は数えない。zombie は外す。
  名前で先に絞らない(別の name・cwd の生存記録に同じ ID があれば拒否)。

### 8-4. 前回候補の全条件(全て通った agent だけ)

1. 両 switch が真・非 clean・今回の CLI が Claude・出陣の排他を取れた・撤収前の観測が `absent`。
2. 正本を今回の採取で置換する前に読んだ内容に、その agent のエントリがある。YAML は mapping・重複キー拒否・
   `run_token` 非空・`captured_at` は timezone 付きの有効日時・`agents` は mapping・ID は小文字 UUID。
   複数世代へ遡らない。未知のキーのある新形式・無効化記録は拒否。
3. agent 名は今回の対象一覧(settings の CLI が claude の役)に1回だけ現れる。pane 番号は診断情報で、
   pane の並びが変わっても役名が同じなら使える。名前の変更・廃止・重複は使わない。
4. 転写は**今回の起動 cwd の project dir にある同じ ID の1ファイル**(通常ファイル・symlink 不可・可読・
   非空・全行が JSON)。別 project・名前・mtime での探索はしない。新形式は採取時の cwd・設定 dir が今回と一致。
5. 鮮度(上限 604800 秒=7日。ちょうど7日は許可、超過・未来・不正値は拒否)。8-5。
6. 正本の bridge が有効で、転写の**最後の** `bridge-session` 記録と一致する(`session_…`/`cse_…` の接頭辞差だけ
   正規化)。bridge 無し・明示切断(空)・別 bridge・記録の sessionId 不一致は拒否。
7. 現生存 Claude にその ID の使用者がいない。同じ bridge を別 ID(`/clear` で ID だけ替わったプロセス等)が
   使っていない。同じ役名の Claude がいない。生存 Claude に判定不能がいない。
8. 計画全体で ID・bridge が一意。前回候補同士の重複は双方拒否、今回の採取(current)と衝突した前回は拒否、
   current 同士の重複も双方拒否。先着で1つだけ採ることはしない。
9. pane が起動する直前の再確認(8-6)も通る。

落ちた agent は理由を出陣のログ(`会話resume: <agent> は前回記録を使わない(<理由>)`)と計画に残し、新規起動する。

### 8-5. 時計と鮮度

- **同じ boot**(正本の `boot_id` が今の `/proc/sys/kernel/random/boot_id` と同じ・新形式): 年齢は
  `/proc/uptime` の差(単調時計)。現実時計の段差に左右されない。値の不正・逆行・読めない時は拒否し、
  都合のよい現実時計の差へ切り替えない。
- **別の boot・旧形式**(boot_id・uptime の無い cmd_785 の形): timezone 付き `captured_at` と現在の現実時計の差。
  前 boot の uptime を引かない。旧形式は計画とログに `basis=wallclock_legacy` を残す。
- 転写の mtime も未来でなく7日以内であること。mtime の新しい転写を探して ID を選ばない。転写が最近更新された
  ことを理由に正本の7日を延ばさない(mtime が採取時刻より後なのは同じ会話を続けた結果で、拒否理由ではない)。
- 秒未満は延命側へ丸めない(採取時刻は秒未満を切り捨てて記録し、年齢は小数のまま上限と比べる)。
- **残る限界**: 跨 boot では信頼できる永続の単調時計が無い。現実時計が大きく巻き戻って古い記録が7日以内に
  見える誤りは検出できない。WSL の時計補正で過去の時刻が未来に見える時は使わない(時計が落ち着いてから
  出陣し直せる。agent は OS の時計を操作しない)。7日は運用上限であり、真の実時間7日の保証ではない。

### 8-6. 二重 resume の防止(計画・直前確認・排他)

- **出陣の排他**: resume 有効時は、採取の前から全 CLI の起動送出まで `queue/state/shutsujin.lock` を `flock` で
  持つ。取れない2本目は**撤収の前に**理由を出して終了する(新規で続行して他の出陣を壊さない)。lock の FD 9 は
  `tmux new-session … 9>&-` で tmux server へ継承させず、常駐プロセス(inbox_watcher・ntfy リスナー)を起こす前に
  解く。
- **計画は1回だけ**: 起動計画は採取の直後に1回作り、全起動分岐(将軍・将軍 thinking 上書き・家老・平時の足軽・
  決戦の足軽・軍師)はそれを読むだけ。同じ agent に起動 ID を1回だけ発行する。
- **前回由来の起動だけ、直前に再確認**: pane へ打鍵する1行は次の形。
  ```sh
  if bash <作業木>/lib/claude_session_resume.sh --check-previous <plan> <run_token> <agent> <id>; then <4 の1行(resume・起動直後失敗なら新規1回)>; else echo "[shutsujin] 前回記録の直前確認で拒否されたため、従来の新規起動にする (1回のみ)"; <従来の新規起動>; fi
  ```
  直前確認は plan の当該 agent が同じ ID・同じ `run_token` の `previous_snapshot` であることと、8-4 の 7 を
  本物の `/proc` で確かめる。差し替えの口(環境変数・引数)は無く、Python は作業木の venv に固定。claude は
  従来どおり pane のシェルの**直接の子**として起動する。値は形式を検査した引数として渡し、評価しない。
  別 run の遅れて実行された起動は token 不一致で拒否される(その pane は次の出陣の撤収でも消える)。
- **起動直後の窓**: 前回由来の起動が後に残っている間は、起動を送るたびにその claude の記録が出るまで最大
  `CLAUDE_RESUME_SETTLE_SEC`(20)秒待つ(記録の無い起動直後の claude を、後続の直前確認が判定不能として
  拒否しないため)。前回由来の起動で記録を確かめられなかった agent は、排他を解く前に正本から外す
  (`withdrawn`。元の token・時刻は書き換えない)。次の出陣はその agent に前回を使わない。
- **保証の範囲**: 本システムの1回の出陣の中の重複・出陣の同時実行・既にいる使用者・選択後に現れた使用者
  (直前確認)を防ぐ。CLI 自体は変えないので、直前確認の直後に**人が手で**同じ ID を起動する競合までは原子的に
  防げない。自動出陣と同時に別の端末から同じ ID を手で再開しないこと。確認の範囲は同じ Linux ユーザー・見える
  PID namespace で、別ユーザー・別ホストの Claude まで未使用とは言わない。

### 8-7. 既知の限界・運用

- **部分採取の限界**: 生存中の一部だけ採れた出陣では、正本は今回の実採取で置き換わり、採れなかった agent の
  前回 ID は正本から消える(その回の計画では救えても、直後の別のクラッシュでは救えない場合がある)。
- **判定不能があると候補は失われる**: 撤収前の観測に unknown が1つでもあれば正本は今回の採取(空を含む)で
  置き換わる。再起動後の出陣の前に、同じユーザーで手動の claude を起こしていないこと(記録の無い claude が
  いると全員が判定不能になる)。
- **保存後の /clear・会話切替**: 正本の後に `/clear` 等で ID が替わると、再起動後は正本の(古い)会話へ戻る。
  再起動前に下の採取専用の呼出しで取り直す。
- **役名の再利用**: 役を別用途へ変えた時は前回 reuse を OFF にするか `--clean` で無効化する。
- **resume を OFF にして出陣した期間がある時**: その間の会話は正本に載らない。7日以内に ON へ戻して再起動すると、
  OFF 前の会話へ戻り得る。気になる時は `--clean` を一度挟む。
- **bridge 側の保持**: ローカルの条件だけでは、サーバ側で bridge が終わっている・別アカウント・接続失敗を
  直せない。実 WSL 再起動後の同じ bridge への復帰は殿の目視(8-8)で確かめる。
- Linux の `/proc`・`flock` 依存。無い環境では前回の再利用は動かない(通常 resume と 4 の既知の制限は別)。

### 8-8. 実証の手順(AC④・殿手番)

1. 実装の QC・公開リポジトリの gate の後、AC④ を殿の手番として載せる(実証の前に cmd 全体を完了にしない)。
2. 再起動の直前に、Claude 7役の**現生存 PID → 検証済み記録 → sessionId → 指定転写 → 最後の bridge** を受動照合し、
   正本の各値と一致する表を保存する。全員の転写が可読・非空、7つの bridge が正本と一致、鮮度内、両 switch ON、
   非 clean を確かめる。Code タブの現7項目は殿が控える。
3. `/clear`・会話切替で現 ID が正本と違う時は、そのまま再起動せず、**採取専用の呼出し**で取り直す
   (出陣本体・撤収・打鍵・signal を呼ばず、書くのは `queue/state/` だけ):
   ```sh
   cd <作業木> && bash -c 'source lib/cli_adapter.sh && source lib/claude_session_resume.sh \
     && t=$(for a in shogun karo $(get_ashigaru_ids) gunshi; do [ "$(get_cli_type "$a")" = claude ] && printf "%s " "$a"; done; true) \
     && tok=$(claude_resume_new_token) \
     && claude_resume_snapshot queue/state/claude_session_snapshot.current.yaml "$tok" "$t" \
     && claude_resume_commit_canonical queue/state/claude_session_snapshot.yaml queue/state/claude_session_snapshot.current.yaml "$t"'
   ```
   (対象は settings の CLI が claude の役。全員 present なら `replaced` と出て、正本は新形式の実採取で置き換わる。
   取り直した後は ID が変わる操作を挟まない。)
4. **殿**が WSL を再起動する。再起動の後、家老は Claude の不在(`/proc` に claude 無し)・正本と7転写の残存・
   時刻が明らかに未来でないことを受動確認する。
5. 殿の通常の出陣1回。ログの `会話resume: <agent> は前回記録の候補(basis=… age=… token=… at=…)` と
   `前回の記録から会話を再開` で、7役すべてが前回候補を使い、ID が事前の表と同じこと、新規への切替が
   起きていないことを確かめる。Codex 系は従来の起動。
6. 起動後、現 PID・starttime・name と sessionId・bridge を再照合し、**7役全て前回 bridge と一致+殿の Code タブで
   新規0件/同じ7項目がオンライン**を同じ検証回の証跡として残す。1件でも新 bridge・null・新規起動・目視の欠落が
   あれば合格にしない。復帰しない時も agent で `/remote-control` を切り替えず、rc・経過・拒否理由・転写の最後の
   bridge・前後の ID を保存して家老へ報告する。

### 8-9. 試験

`tests/unit/test_claude_session_resume.bats` の P796-01〜15(設計確認 §8 の有限集合。英字の枝番は同じ項目の
別観点)。tmux・子プロセス探索・現生存 Claude の観測・時計は試験の中でだけ関数を定義し直して固定し、lib に
差し替えの口を作らない。本物の `/proc` を読む試験(P796-05a・P796-06a・P796-12e)は試験自身の偽 claude だけを
判定する(同じユーザーの生存 Claude の記録を読み取りだけで読む)。隔離 tmux(`scripts/isolated_tmux.sh`)で、
排他の FD が tmux server へ漏れないこと(P796-12b)と、直前確認の後の claude が pane の直接の子であること
(P796-14a)を確かめる。子の探索の失敗の境界(出力の無い非0終了・0件の裏取り)は、探索関数を本物のまま ps
だけを試験側の関数で固定して確かめる(P796-06・P796-06a)。実 WSL 再起動・Anthropic 側の bridge 保持・Code タブの項目数は代替試験では実証できない。
