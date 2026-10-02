# Tooling Pitfalls and Editing Guardrails (cmd_735)

殿のご下命(2026-09-01)による。cmd_732/cmd_734で顕在化した4件の「道具の
盲点」を、実行ルールとして集約する。要点はCLAUDE.md本体(全エージェント
常時読込)に記載済み。本節はその詳細・実測根拠・経緯である。

## ①②共通の病根: gitignoreされたものは道具から消える

将軍実測(2026-09-01・再調査不要):

```
type grep  →  grep is a function     (ugrep系ラッパ)
同一検索: 関数版26ファイル / 実体(/usr/bin/grep)413ファイル
内訳(実体): tmp/ 311 + skills/ 74 + tests/ 27
内訳(関数): tests/ 25のみ  ← tmp/とskills/が丸ごと見えない
```

`find`も同様にシェル関数(`bfs`ラッパ)だが、この実測では件数が一致した
(10,995同値)。gitignore領域の見落としはgrep固有の問題として扱う。

これがD002-E1欠陥(cmd_687)の真因である。cmd_687で将軍が数えた
「21ファイル・37箇所」は`skills/`を一度も見ていなかった。軍師がcmd_727
QCで数えた「77箇所/74ファイル」はまさにその`skills/`分である。軍師77・
家老32+・将軍33と三者が食い違ったのは、それぞれ違う盲点を持つ道具で
数えていたからである。単純な「どちらかが誤り」という見方では収束
しない。

安心してよい点: cmd_732 Phase Aの棚卸し(144箇所)は`skills/`を見ており
健全である。新文言は正しい数の上に立っている。やり直しは不要。

### ① grep自体の対処

- 網羅性が問われる検索・棚卸しでは `/usr/bin/grep` をフルパスで呼ぶ
  (シェル関数版はCLAUDE Code起動時に `--ignore-files --hidden` 付きの
  ugrepへ差し替えられており、gitignore対象を素通りする)。
- 件数を報告するときは必ず見たディレクトリの内訳を示す。総数だけでは
  盲点に気づけない。専用ツール `scripts/count_by_dir.sh` を使うこと
  (常にディレクトリ別内訳を出す設計。使用例は同スクリプトの
  `--help` 参照)。
- 二人以上の計数結果が食い違ったら、どちらかが誤りだと即断しない。
  「両方が違う部分を見ている」を先に疑うこと。

### ② skills/配下の差分・影響分析はprivategitでしか見えない

通常のgit(`.git/`)では `skills/<privategit専用skill>/` 等がgitignore
対象であり、`codd impact` や `git diff` が空振りする(changed files 0)。
「差分0だから影響なし」と読めてしまう点が危険である。①と②は同じ病
——gitignoreされているものは道具から消える——なので一体として扱う。

```bash
GIT_DIR=$HOME/.shogun-private.git GIT_WORK_TREE=/home/kato/shogun git diff
```

privategitの日常運用ルール(commit/push手順)は
[[feedback-privategit-workflow]] を参照。本節が扱うのは「差分確認の
盲点」であり、運用SOPそのものではない。

## ③ CRLF/LF混在ファイルの安全な部分編集

3回発生している(cmd_732 redo1・cmd_734 redo2・cmd_753 scope変更版)。
別々の編集経路で起きているため、個人の不注意ではなく環境要因
(このリポジトリにCRLF/LF混在ファイルが実在すること)として扱う。

- Editツールの部分置換も、対象外の既存行をファイル全体の支配的EOLへ
  巻き込んで正規化することがある(cmd_735内で2回実例: 原subtaskでの
  CLAUDE.md追記時・redo1での.gitignore編集時、いずれも触れていない
  はずのLF行がCRLFへ変わった)。混在ファイルではPythonで `open(...,
  newline='')` を指定し、読み込んだ行末をそのまま書き戻すbyte保持
  経路を優先する。
- 自己確認手順: 編集後に `git diff --numstat` と `git diff
  --ignore-space-at-eol --numstat` を突き合わせる。両者の増減行数が
  一致しなければ、改行コード由来の水増しが混入している。
- 実例3件目(cmd_753 scope変更版・G753-GITIGNORE-EOL-REDO2-02):
  redo2作業中の`.gitignore`編集(`!scripts/rm_rf_d002e1_checker.py`
  1行追加)で、既存のLF専用行19行が巻き込まれてCRLF化した
  (`git diff --numstat`は20/19だが`--ignore-space-at-eol --numstat`
  は1/0——両者の不一致が上記自己確認手順どおりに機能し、軍師が
  この乖離を捕まえて是正させた)。是正はPythonでHEAD版と現行版を
  行単位byte比較し、内容が同一でEOLだけが変わった行のみをHEADの
  EOLへ戻すことで、意図した1行追加だけを残した。★この事例は
  「自己確認手順が実際に効いた」実例でもある——手順を踏んだ結果
  として乖離を検知でき、範囲を特定して復元できた。
- 判定の道具(cmd_800): `python3 scripts/crlf_diff_check.py --rev <編集前の
  rev> <file>...`(`--rev` 省略時は HEAD)。読み取り専用で、判定するだけで
  直さない。上の numstat の突き合わせに加え、内容が変わっていない行が参照版
  (checkout 変換後の内容)と行末まで byte 一致することを確かめ、CRLF/LF の
  行数・LF のみの行の行番号・最初の差分位置を出す。終了コードは 0=健全 /
  1=行末だけ変わった行がある・numstat が一致しない / 2=対象 0 本・rev 未解決・
  参照版にファイルが無い等(沈黙して 0 を返さない)。`.gitattributes` の eol
  変換などで git の numstat が行末の差を見ない場合も、byte 比較で捕まえる。

## ④ 使い捨てディレクトリは mktemp -d を既定とする

cmd_732のprobe2自己申告違反の原因は、CLAUDE.mdの条文の不備ではなく、
「scratchpadは使い捨て」と思った瞬間に `mktemp -d` を用いる発想が
浮かばなかったことだった。CLAUDE.md D002-E1は「`mktemp -d` で作った
ディレクトリ」しか安全な削除を認めていないため、最初の作成手順を
誤ると、後で安全に消す手段が無くなる。

- 使い捨てディレクトリ(scratchpad含む)は、作成する時点で必ず
  `mktemp -d` を使う。自己流の命名規則やタイムスタンプ付きパスの
  「代用」は行わない(D002-E1の対象外になり、後で削除できなくなる)。
- 本節は足軽向けの実行ルールである。`instructions/` は足軽の常時
  読込経路ではないため、CLAUDE.md本体側の簡潔な1節が一次情報である。
  本ファイルは詳細・経緯の補足に位置づける。
- Bats は `bash scripts/bats_tmpdir_guard.sh <bats の引数>` 経由で起動する
  (cmd_800)。TMPDIR が未設定か `/` で始まる時だけ bats を起動し、引数は
  そのまま渡す。相対の TMPDIR(空文字を含む)なら bats を起動せず、理由を
  出して終了コード 2 で止まる。template 無しの `mktemp -d` は TMPDIR の下に
  作るため、相対の TMPDIR では相対パスを返し、teardown の `rm -rf` が
  D002-E1(d) の外へ落ちる。試験のコード側で TMPDIR に依らず絶対パスに
  したいときは、`mktemp -d /tmp/<名前>.XXXXXX` のように絶対リテラルの
  template を与える。

## ⑤ D007(mount/umount絶対禁止)下でのマウント状況確認手段

CLAUDE.md Tier 1 D007は`mount`・`umount`(および`mkfs`・`dd if=`・
`fdisk`)の実行を無例外で禁ずる。以下はD007の例外
ではない。D007の禁止対象にそもそも含まれない、別のコマンドの案内で
ある。マウント状況を読み取り専用で確認したい場合であっても、
`mount`・`umount`コマンド自体を実行してよいという意味では一切ない。
マウント状況を確認する必要があるときは、代わりに次のいずれかを
用いること(いずれもD007の禁止対象ではない):

- `cat /proc/mounts` — `mount`コマンドと同じ内容が取得できる
- `findmnt` — 実在コマンド(`/usr/bin/findmnt`)
- `lsblk` — 実在コマンド(`/usr/bin/lsblk`)

背景: 将軍自身が殿のumountご下問調査で`mount | /usr/bin/grep -E
"drvfs|9p|drive"`(mountコマンドそのものの実行)を行った後、cmd_750で
足軽へ「mount/umountを実行するな」と指示しており、将軍自身が先に犯した
違反を後から足軽に禁じる形になっていた(将軍裁定により、足軽4号にも
家老にも落ち度はなく将軍の落ち度と明言されている)。D007自体には
例外を設けず、上記の代替コマンドへの案内をここに記録する。

## ⑥ D006(kill-server/kill-session絶対禁止)下での隔離tmuxサーバの後始末

知っていても、隔離環境だからと油断し手癖で`kill`系コマンドを打って
しまった実例がある。読んだだけでは足りない。

- 隔離サーバを起動する前に、後始末として使う`exit`入力コマンドを
  先に書いておくこと(pre-declare)。起動後に書く順序では、稼働中に
  手癖で`kill`系コマンドへ流れやすい。
- `tmux -L <name> new-session …`で作った隔離サーバは、自分で作った
  素のシェルpaneへ`exit`を入力して閉じる。最後のpaneが閉じればサーバ
  は自然終了する。
- `tmux kill-server`/`kill-session`は隔離ソケットでも禁止(D006・
  例外なし)。
- ソケットファイル(`/tmp/tmux-1000/<name>`)は終了後も残骸として
  残る。害は無い。消しに行くな(D002域・再起動で片付く)。
- 隔離サーバへの`exit`入力は、agentがtmux send-keysを直接呼んでは
  ならないという原則(CLAUDE.md「Mailbox System」節)には該当しない
  ——対象は自分が作った素のシェルpaneであり、他agentが動くagent CLI
  paneではない。
  後始末の型は散文で示す: 隔離サーバを起動→自分が開いた素のシェル
  paneへ`exit`を入力→最後のpaneが閉じてサーバが自然終了、という
  手順を守ればよく、特定のtask固有scriptの呼出しをここで指定する
  ものではない。task固有の隔離tmux検証scriptを本ファイルのような
  恒久文書から参照するには、軍師QC済みであることを要件とする
  (未QCのscriptを恒久文書の参照先として指定してはならない)。
- 「read-onlyならkillを使ってよい」と読める書き方をするな。一行
  たりとも。
- 上記の手作業手順を汎用化した審査済みhelperとして`scripts/
  isolated_tmux.sh`がある(create/teardownの二口のみ・kill系文字列
  0・軍師相当QC済み〈cmd_758〉)。隔離tmuxサーバの生成・後始末が
  必要な場合はこれを使え。★防ぐのは手癖・うっかり(handleの取り違え・
  古いhandle・cpしたhandle・sourceの手癖)であり、同一ユーザーの
  意図的な改竄(同一inode内容差替え等)は防御対象外——詳細と受容根拠
  は同script冒頭の「★脅威モデル」節を見よ。
- `isolated_tmux.sh teardown`の待ち(`tmux wait-for`)には上限がある
  (既定60秒・環境変数`ITMUX_WAIT_LIMIT_SEC`で上書き・cmd_795)。負荷下で
  通知が取りこぼされ、teardownが無期限に止まる事象が1日27件あったため
  である。
  - 最終判定: 上限に達しても成否は`has-session`で確定する。server消滅
    なら成功(rc 0・「通知取りこぼし後に has-session で確定」と出る)、
    残存なら非0で返る。残存のときは何も終了させず、handleも残す——人が
    確かめてから同じhandleでteardownを再試行せよ。
  - `kill`系は使わない: 上限到達を理由に、隔離server・session・paneへ
    何かを送って止めることはしない。上限到達時にtimeout(1)が終了要求を
    送る相手は、helper自身がその場で起動した待受けclient 1本だけである
    (`--foreground`・直接の子のPIDのみ・CLAUDE.md D006-E1 Branch 1の形)。
    これは手で`kill`系を打ってよい理由にはならない。非0で返った後も
    `kill`系へ流れるな——残った隔離serverは、自分で作った素のシェル
    paneへ`exit`を入力して閉じるか、上へ報告して判断を仰げ。
  - 脅威モデル: この上限が止めるのは「通知の取りこぼしで待ち続ける
    こと」のみである。同一ユーザーの意図的な改竄・迂回は対象外(所見
    止まり)。詳細は同script冒頭の「★cmd_795」節を見よ。

## ⑦ 使い捨て検証に後始末を書くな

タスク中に手で叩く検証・確認コマンドに、後始末の`rm -rf`を書かない。
`/tmp`の使い捨ては再起動で片付く。書かなければパーミッション確認が
出ず、殿の手を煩わせない。規則の回避ではなく、不要な操作をしない
だけである。

★ただしテストのteardown・常設スクリプトは別——繰り返し走るものには
後始末が要る。使い捨ての一度きりの検証コマンドと、繰り返し実行される
テストのteardown・常設スクリプトとを混同しないこと。後者では後始末
そのものはむしろ必須だが、手段をrm -rfに限定するものではなく、
rm -rfを用いる場合はTier 1・D002-E1への個別適合が必要である。

## ⑧ 出自は後から再構成できない

一時ディレクトリを消す予定があるなら、`mktemp -d`の時点で変数へ
捕まえよ。後から`ls`やglobで取り直した値はD002-E1(b)を満たさず、
そのディレクトリは二度と消せなくなる。

本節は④(使い捨てディレクトリは`mktemp -d`を既定とする)の直接の
帰結である。④で`mktemp -d`を使っても、その戻り値を専用変数へ即座に
捕まえ、以後書き換えずに`rm -rf`の被演算子として使い続けるという
規律が伴わなければ、D002-E1(b)(出自の追跡可能性)を満たせず、削除
そのものが実行できなくなる。

## ⑨ `.claude/settings.json` の hook `command` は絶対パスで書け(cwd起動経路の欠陥)

Claude Code の hook は「cwd follows Claude」で実行される——hook の
`command` は、それを起動する agent の Bash tool の**現在の cwd**で
起動される(セッション開始時に固定されるのではない)。

- `.claude/settings.json` の hook `command` を新設・変更するときは、
  必ず `bash "${CLAUDE_PROJECT_DIR}/scripts/<script>"`(絶対パス)形式を
  使うこと。相対パス形式(`bash scripts/<script>`)は、hook を起動する
  agent の cwd が project root と異なる場合(例: `skills/` 配下での
  作業)、hook 起動そのものが `bash: scripts/<script>: No such file or
  directory` でエラー通知なくサイレントに失敗する——hook の中身(ロジック)
  は無関係で、プロセスが一度も起動しない。
- 実例(2026-09-17・cmd_775): 足軽3号がプロジェクト直下でない skill
  ディレクトリ `skills/<skill>/` 配下で作業中、PermissionRequest hook が
  起動できず素の確認モーダルへ
  落ち、記録ファイルも家老通知も無いまま長時間停止した。同時刻
  cwd=project root だった足軽6号では同じ相対パス形式でも問題が起きず、
  hook の中身ではなく起動経路そのものが真因だと判明した。
- 詳細・是正の経緯・隔離試験による実証は `docs/delivery_channels.md`
  §12(「hookコマンドは絶対パスで書け — cwd起動経路の欠陥 (cmd_775)」)を
  見よ。regression 試験は `tests/unit/test_hook_cwd_launch.bats`(動的・
  隔離tmux実機・相対失敗/絶対成功の対比)と `tests/unit/
  test_permission_request_hook_settings.bats` の T-PRHS-003(静的・
  settings.json の command 文字列を直接検査)。

## ⑩ 公開originへのpushは `oss_publish.sh` から——引数なし `git push` の手癖(cmd_798)

公開originへ載せる経路は、専用の公開道具(`skills/shogun-oss-publish/
scripts/oss_publish.sh`)を通すものだけである。mainの集約は `prepare`、
上流向けPRは `prepare-pr` →それぞれ殿承認→`push`。手書きの
`git push` で公開originへ送らない。developはローカルの作業幹で、
originにdevelopは無い(F007・`instructions/common/forbidden_actions.md`)。

- 事故類型1(引数なし `git push`): developがorigin/developを追跡して
  いた頃、歯止めの無い状態で引数なしの `git push` を打つと、生の
  develop先端がそのままorigin/developへ載った(cmd_798の偽originで
  実測・rc=0)。gitは送り先も送るbranchも確かめず、何も言わずに
  成功する。手癖の一打で生の履歴が公開される。
- 事故類型2(予行の中の強制push): cmd_797では、偽origin(`mktemp -d`
  のローカルbare repo)に対する予行のスクリプトが、巻き戻しの段で
  lease付きの強制pushを使っており、「force系を書かず実行せず」の
  指示に反して1回実行された(実originには繋がっておらず、本人が
  申告した)。送り先が偽物でも、force系を書いた道具は走らせない。
  走らせる前にスクリプトの中身を読んで確かめる。
- 今は道具が止める: `push.default=nothing`(引数なしpushをgitが拒否)、
  upstreamのpushurlの無効化、pre-push hook(送り先・名前・内容・
  ticketの検査)。止める対象は手癖と取り違えであり、意図的に外す操作
  (`--no-verify`・`core.hooksPath`の書換え等)は止めない。止まる
  ことを当てにして試さない。
- 道具は黙る: hookが無いとgitは素通しにする。実行bitが無い場合も、
  hintを出すだけでpushは止めない。`oss_guard_install.sh --check` を、
  集約公開の前と完了SOPの③bの前に通す(`oss_publish.sh` は内部で通す)。
- 詳細(規則R0〜R5・限界・設置と巻き戻し)は同skillの SKILL.md を見よ。

## 関連

- [[feedback-privategit-workflow]] — privategit運用SOP(add/commit/push)
- [[feedback_cmd687_d002_d006_narrow_exceptions]] — D002-E1/D006-E1
  そのものの追加経緯
- [[feedback_tier1_wording_inventory_discipline]] — cmd_687棚卸しで
  起きたもう1つの誤り(危険性判断と文言適合判断の取り違え)。①のgrep
  盲点とは原因が別だが、同じ棚卸し作業内で併発していた
