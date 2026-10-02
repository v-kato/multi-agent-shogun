#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# scripts/isolated_tmux.sh — 隔離tmuxサーバの汎用helper (cmd_758・redo3)
# ═══════════════════════════════════════════════════════════════
#
# ★背景: cmd_757②redo3作業中、隔離検証目的で自分専用ソケットに対して
#   D006(Tier1絶対禁止)の対象コマンドを直接実行してしまった事案
#   (2026-09-09)を受け、将軍が本helperを発令した。軍師のRCA: 正しい
#   後始末の型(素のシェルpaneへexit入力・自然終了を待つ)は違反の
#   3分前にRead済みだった——知識不足ではなく実行規律の欠落。
#   ゆえに本cmdは「手順を文書ではなく道具へ埋める」——隔離tmuxサーバの
#   作成・後始末を、D006対象コマンドを構造的に持たない審査済みhelper
#   へ閉じ込める。
#
# ★redo2(本版): redo1が軍師QCでREDO_REQUIRED(5件blocking・
#   north_star_alignment: misaligned 2回連続)となり、個別の穴埋めでは
#   なく軍師の再設計案に沿った構造的な作り直しを行った。G758R1-*-01〜05
#   是正の要旨:
#
#   (1) SOURCED-RAW-BYPASS-01: 「先頭underscoreは規約にすぎず、source
#       すれば任意の内部関数を検査無しで呼べる」という指摘を受け、
#       ★sourceそのものを先頭で拒否する。sourceされた場合、本ファイルは
#       エラーを出して即座に戻るだけであり、以後の関数定義は一切
#       実行されない——source後に定義される関数は0件である(列挙試験
#       T-IT-017・018で固定)。他scriptからの再利用はcreate/teardownの
#       二口(サブプロセスとしての直接実行)のみに限る。
#
#   (2) HANDLE-PROVENANCE-02: handle fileの内容(9 fieldの値)がどれだけ
#       正しくとも、それだけでは「createが実際に発行したfileそのもの」
#       の証明にならない(cpによる複製・手書きの完全形はいずれも内容が
#       正しいだけで通ってしまう)。★内容の自己参照(fileが自分自身の
#       inodeを名乗る形)は、同じfileへ上書きすればinodeを変えずに
#       中身だけ書き換えられるため、知識のある者には偽造可能——ゆえに
#       ★内容には一切頼らず、handle領域とは別の専用registry
#       ディレクトリに「(dev,inode)がcreate自身のinstallによって実際に
#       発行されたものか」を記録する。inode番号はOSが割り当てるもので
#       あり呼出側が選べないため、cp(新しいinodeを得る)・手書きの
#       完全な新規file(registryに記録の無いinode)は構造的に拒否
#       される(T-IT-031〜034で実証済み)。★ただし、この検証が証明する
#       のは「file実体がcreateの発行物であること」だけであり、「発行後
#       に内容が書き換えられていないこと」は証明しない——既に登録済み
#       の(=正規の)inodeへ後から内容を上書きする改竄(同一inode内容
#       差替え)は、この検証だけでは検知できない(redo3で実証・下記
#       「★脅威モデル」節を見よ)。この検証は非敵対的な取り違え
#       (cpした複製の誤用・手書きの試行錯誤)を防ぐものであり、意図的な
#       改竄からの保護ではない。
#
#   (3) PREEXISTING-SERVER-ATTACH-03: 「socket名が既存でないことを
#       事前確認してから使う」という check-then-act 方式はTOCTOUが残る
#       (確認と使用の間に別プロセスが割り込める)。★各createは
#       `mktemp -d`で直前に作った未使用の専用ディレクトリの中に
#       socket file を置く(`tmux -S <path>`で直接絶対pathを指定し、
#       `-L <name>`(共有namespaceに解決される)は使わない)。作られた
#       ばかりの空ディレクトリの中に既存serverが先に潜んでいることは
#       構造的にあり得ないため、確認という手順そのものが不要になる。
#
#   (4) EVENT-WAIT-HANG-04: `pane-exited` hookを`-t <pane>`(対象範囲の
#       session側)へ設定すると、対象window/session自体が消滅する
#       瞬間にhookの保存先も一緒に消え、通知が発火しないことがある
#       (実機再現: 二session構成で最大74秒以上解除されず、本redo2の
#       検証でも同条件でwait-forがtimeout(rc=124)することを確認した)。
#       ★hookを`-g`(global)スコープで設定する——サーバ生存中は
#       残るglobalスコープに置くことで、対象pane/window/sessionの
#       消滅と同時にhookの保存先も消える、という競合を無くす。
#       (3)の是正により本helperのserverは一sessionしか持たないため、
#       globalスコープにしても他sessionのpane消滅と混同する余地はない。
#       同条件で`-g`により有限時間(実測: 即座)に解除されることを
#       確認済み。
#
#   (5) HANDLE-INSTALL-BOUNDARY-05: handle領域が`${TMPDIR:-/tmp}`を
#       基点としていたため、呼出側が`TMPDIR`を書き換えれば保存先を
#       誘導できた。★本プロジェクト作業木内の固定絶対path
#       (`$ITMUX_PROJECT_ROOT/tmp/isolated_tmux_handles`)へ変更し、
#       いかなる環境変数にも依存しない。この領域は★tmuxセッションを
#       作る前に安全確定する(所有者・パーミッション・非symlinkを検査、
#       無ければmode 700で新規作成)——失敗すればtmuxには一切触れずに
#       終わる。★セッション作成後、メタデータ取得やhandle installが
#       失敗した場合は、既に作った素shellへ`exit`を送って自然終了を
#       待つ後始末(failure injection試験で確認)を経てから die する。
#
# ★redo3(本版・cmd_758将軍裁定によるscope縮小): redo2が軍師代替
#   (足軽7号・Claude系)QCでREDO_REQUIRED(blocking 2件・
#   north_star_alignment misaligned 3回連続)となった。将軍は「helperの
#   脅威モデルが暗黙に敵対者(同一ユーザーがhelper自身を書き換える者)を
#   含んでいたこと」を真因と裁定し、脅威モデルを「非敵対・手癖・
#   うっかり」に明文化した上でscope縮小のredo3を1回のみ認可した
#   (詳細は下記「★脅威モデル」節)。是正の要旨:
#
#   (6) G758R2-B1-TEARDOWN-FALSE-NEGATIVE是正: create後0.5秒以上
#       経ってからのteardownは、最終paneのexitでserverがexit-emptyに
#       より自然終了する際に`tmux wait-for`自身が「server exited
#       unexpectedly」で切断され、100%の再現率でrc!=0(偽陰性)を
#       報告していた——paneは実際には正常に自然終了しているにも関わらず
#       「失敗した」と誤報し、呼出側を手癖の強制終了コマンドへ誘導する
#       危険があった(north_starへの直接的な逆行)。★teardownの成否を
#       `wait-for`のrcで決めるのをやめ、最終判定を既存の
#       has-session確認(server消滅=成功)へ一本化した。「fail-closed」
#       の語は「exit送信前の失敗(何も送っていない)」にのみ用い、
#       「送信後の待ちが確定できなかった」場合には使わない——両者を
#       混同させないためである。
#
#   (7) G758R2-B2-HANDLE-CONTENT-SWAP是正(★(ii)のみ・(i)は実装しない):
#       正規handle(provenance検証を通る)の中身を`>`によるinode保持
#       上書きで別serverの値へ差し替えると、SOCKET_PATHの領域検証が
#       無かったため専用sockparent領域外のserverへexitが届いた。
#       provenance検証は「file実体がcreateの発行物であること」しか
#       証明せず「発行後に内容が書き換えられていないこと」は証明
#       しない。★内容が何であれ、SOCKET_PATHが
#       `$_ITMUX_SOCKPARENT_ROOT/sp.*/`の直下(1階層のみ)であることを
#       構造検証し、これを満たさなければ内容の他の整合性に関わらず
#       fail-closedで拒否する(handle_read内・いかなるtmuxコマンド
#       発行前に働く・実在しないpathに対しても一貫して働く)。同一inode
#       内容差替え自体を検知する内容hash照合(軍師仮説・B2(i)相当)は
#       ★実装しない(下記「★脅威モデル」節)。
#
# ★脅威モデル(redo3で明文化・cmd_758将軍裁定): 本helperが防ぐのは
#   非敵対的な手癖・うっかりに限る——handleの取り違え、古い(失効した)
#   handleの使い回し、cpして生まれた複製handleの誤用、sourceして内部
#   関数を不用意に呼んでしまう手癖、の4種である。★同一ユーザーが本
#   helper自身の実行結果(handle file・registry)を意図的に書き換える
#   改竄は、本helperの防御対象外である。改竄する意思のある者は、
#   そもそも`tmux`の強制終了コマンド(D006が禁止する対象そのもの)を
#   直接打てる——道具は手癖を止めるものであり、意思を止めるものでは
#   ない(cmd_758 north_star)。
#
#   ★以下は具体的に防御対象外と確認済みであり、受容した根拠を残す
#   (足軽7号report・queue/reports/ashigaru7_report.yaml
#   task_id: qc_subtask_758_isolated_tmux_helper_redo2_ashigaru の
#   blocking_findings/major_findingsより。詳細な再現手順は同reportを
#   正とする):
#   - 同一inode内容差替え(G758R2-B2-HANDLE-CONTENT-SWAP・B2(i)相当):
#     正規handleの中身を`>`でinodeを保ったまま別serverの値へ上書き
#     すると、provenance検証(=file実体の同一性の証明)を通過して
#     しまう(blocking_findings参照)。対策(内容sha256等のhash照合)は
#     実装しない。
#   - registry marker手書き登録(G758R2-M2-REGISTRY-MARKER-FORGERY):
#     `: > .registry/<dev>.<inode>`で任意fileを事後的に登録できる
#     (同一ユーザー書込領域のため。major_findings参照)。対策
#     (署名・別領域での保護)は実装しない。
#   - inode再利用による偽陽性(G758R2-M1-INODE-REUSE-FALSE-POSITIVE):
#     handle削除後、同ディレクトリのmktempが同一(dev,inode)を再取得
#     しうる(足軽7号実測: 1回目で再現。major_findings参照。redo3の
#     検証中にも自ら再現した——短時間に多数のcreate/teardownを
#     繰り返す検証負荷の下では、T-IT-031〜034のような「cpした複製・
#     手書き完全形はregistryに記録が無く拒否される」はずの負試験が
#     偶発的に偽PASS〈=teardownが誤って受理〉することがある)。
#     registryが「過去に発行した全inode」の単調増加集合であるため、
#     古いmarkerが新fileを誤って正当化しうる。対策(marker削除・
#     世代番号付与等)は実装しない。
#   - `$0`偽装によるsource拒否迂回(G758R2-M3-SOURCE-REJECT-ARGV0-SPOOF):
#     `bash -c '. isolated_tmux.sh create -L x' isolated_tmux.sh`の
#     ように第2引数で`$0`をfile名に一致させると、
#     `BASH_SOURCE[0]!=$0`検査を通過し、13関数全てが呼出側shellへ
#     漏洩する(足軽7号実測。major_findings参照)。対策
#     (`(return 0 2>/dev/null)`によるsource文脈検知)は実装しない。
#
#   ★一方、SOCKET_PATH領域の構造検証(S-2・上記(7))は脅威モデルに
#   依らず実装している。これは「同一ユーザーの意図的改竄」への防御
#   ではなく、「内容が何であれ隔離領域の外を対象化できない」という
#   構造的境界であり、非敵対的な事故(例: handle内容の何らかの偶発的
#   破損)に対しても意味のある安全側の保証だからである。
#
#   ★偽の安心について: 上記いずれの項目についても、本ファイル中に
#   「拒否される」とだけ読める記述を残さないこと。本helperが実際に
#   保証するのは「非敵対的な取り違え・うっかりでは、隔離領域外や
#   他serverのpaneを誤って終了させない」ことまでであり、「意図的な
#   改竄からの保護」ではない。
#
# ★cmd_795(本版・teardown の待ちに上限): 負荷下で teardown が無期限に
#   止まる事象が1日に27件観測された(うち2件は33分を超えても自然には
#   解けなかった)。/proc の読取りでは、いずれも「隔離serverは子なし・
#   sessionなし・sleeping、接続は待受けと本helperの`wait-for`clientの
#   2本のみ」であり、同じsocketへ読取りの`list-sessions`を1回送ると
#   即座にserverが終わりwait-forが戻った(全件)。tmux 3.4で「sessionが
#   消えた後にwait-forが繋がると、次のイベントまで処理が進まない」通知の
#   取りこぼしと推論している(tmux内部は未確認)。(6)でwait-forのrcを
#   最終判定に使わない設計は既に採っていたが、wait-for自体に上限が
#   無かった。是正の要旨:
#
#   (8) wait-forをtimeout(1)で包み、上限を設ける。上限は環境変数
#       `ITMUX_WAIT_LIMIT_SEC`(1〜99999の整数秒・未設定/空なら既定60秒)
#       で上書きでき、試験ではこれで短縮する。不正値とtimeout(1)の
#       不在は、create/teardownの冒頭(tmuxに一切触れる前)で拒否する。
#       上限に達しても最終判定は(6)と同じhas-sessionに一本化したまま:
#       - session不在(server消滅)=成功(rc 0)。stdoutに「通知取りこぼし
#         後に has-session で確定」と明記する。has-sessionの接続そのものが
#         止まったserverを起こし、その場で自然終了させる見込みである
#         (上記list-sessionsと同じ働き・推論)。
#       - session残存=失敗(rc 1)。以後は何も送らず、何も終了させず、
#         handle fileも残す(teardownは元々handleを消さない)。人が確認
#         した後、同じhandleでteardownを再試行できる。cmd_795の受入条件
#         が「fail-closed」と呼ぶのはこの安全側の失敗である。ただし本
#         ファイルの用語法((6)・「fail-closed」はexit送信前の失敗にのみ
#         用いる)とはexitを既に送った点で異なるため、本ファイルでは
#         「安全側の失敗」と呼ぶ。
#
#   ★上限到達時にtimeout(1)が終了要求(SIGTERM)を送る相手は、timeout
#     自身がその場で起動した待受けclient(`tmux wait-for`のclient
#     process)1本だけである。`--foreground`を必ず付ける——付けないと
#     timeoutは自分のprocess group全体へも同じ信号を送る(GNU coreutils
#     の実装)。付けた場合の宛先は、forkの戻り値で得た直接の子のPID
#     1つだけであり、その子をwaitで回収する前に送る(strace実測:
#     wait4(WNOHANG)=0 の直後に当該PIDへの1回のみ・process group宛て
#     0回)。つまりCLAUDE.md D006-E1 Branch 1の条件(直接起動した子・
#     起動時の戻り値で得た識別子・未回収・単一PID)を、timeout(1)の
#     構造がそのまま満たす(T-IT-046が`--foreground`の付与を検査する)。
#     ★隔離server・session・paneへ送るのは従来どおり`exit`の打鍵だけで
#     あり、上限到達を理由に何かを止めることはしない——「止める」の
#     ではなく「判定して返す」。D006が禁止する強制終了系のコマンドは
#     引き続き一切呼ばない(T-IT-006)。実tmuxの待受けclientが上限到達で
#     確かに終わり、残らないことはT-IT-044で確かめている。
#   ★時計: timeout(1)の上限は相対タイマである(strace実測:
#     timer_create(CLOCK_REALTIME)+timer_settimeのflags=0・絶対時刻指定
#     無し)。POSIXは相対タイマが時計の設定変更の影響を受けないと定め、
#     Linuxは相対のCLOCK_REALTIMEタイマを単調時計の基底で動かすため、
#     壁時計の段差・巻き戻しで上限が伸び縮みしない。試験の経過計測も
#     /proc/uptime(起動からの経過)を使い、壁時計に依存しない。
#   ★上限を設けたのはwait-forだけである。他のtmux呼出し(set-hook・
#     send-keys・display-message・has-session等)は単発の要求応答であり、
#     観測された停滞27件はいずれもwait-forだった。
#   ★脅威モデル(cmd_795): 本是正が止めるのは「通知の取りこぼしで
#     teardownが待ち続けること」のみである。同一ユーザーによる意図的な
#     改竄・迂回(上限を極端な値にする・待受けを別途妨げる・本ファイルを
#     書き換える等)は対象外・所見止まりとする(上記cmd_758の脅威モデル
#     と同じ立場)。上限値はどう設定しても待つ時間を変えるだけであり、
#     送る先・最終判定の基準は変えない。
#
# ★★D006(Tier1絶対禁止)について: 本ファイルは D006 が禁止する
#   「対象を強制的に終了させるコマンド」を一切呼ばない。teardownが
#   行うのは「対象paneへ`exit`という文字列を打鍵として送り、当のpane
#   が自分で終了するのを待つ」ことだけである。以下の試験
#   (tests/unit/test_isolated_tmux_helper.bats・T-IT-006)が、本ファイル
#   の実コードにD006該当コマンド群の綴りが1つも現れないことを検査する。
#
# ─── 提供コマンド(この二口だけに閉じる。他の入口は無い) ───
#
#   isolated_tmux.sh create -L <socket_name>
#       隔離ソケットに素のシェルpane(agent CLIは起動しない)を1つ作り、
#       teardownに要る識別子をexact-schemaでhandle fileへ書き出す。
#       handle fileはhelper管理下の専用領域に自身のmktempで排他的・
#       原子的に作成する(呼出側が保存先pathを指定する口は無い)。
#       handle_fileのpathをstdoutへ出す。
#
#   isolated_tmux.sh teardown <handle_file>
#       handle_fileの由来(専用領域直下・非symlink・createが発行した
#       file実体そのものであることをregistryで照合)を検証し、閉じた
#       schemaで内容を検証し(SOCKET_PATHが専用sockparent領域の直下
#       であることも内容非依存で構造検証する・S-2/G758R2-B2(ii)是正)、
#       送信直前にserver/session/pane instance identityと
#       pane_current_command=bashを肯定形で再照合したうえで、
#       対象paneへ`exit`を入力し、pane-exited hook(globalスコープ) +
#       `tmux wait-for`のblocking waitで自然終了をイベント駆動で待つ
#       (固定sleep・busy pollingは使わない)。wait-forには上限がある
#       (既定60秒・`ITMUX_WAIT_LIMIT_SEC`で上書き・cmd_795)。一つでも
#       不一致・不正・欠落・失敗があればfail-closedで何も送らない。
#       送信後の成否は、上限に達した場合も含め、`wait-for`のrcではなく
#       最終的なhas-session確認(server消滅=成功・残存=安全側の失敗)で
#       判定する(S-1/G758R2-B1是正・cmd_795)。
#       ソケットファイル・専用ディレクトリの残骸は消さない(D002域・
#       害なし。理由は下記「ソケット残骸について」節を見よ)。
#
# ★raw source APIは全廃した(redo2): 本ファイルはsourceそのものを
#   拒否する。他script側の再利用が必要な場合(A-8で試みた共通化)は、
#   本ファイルの `create`/`teardown` の二口(サブプロセスとして直接
#   実行・検査を必ず通る)を経由するか、局所実装を維持すること。
#   tests/verify_cmd_757_pane_rebind_isolated.sh は create(pane1つのみ)/
#   teardown(全paneを一括終了)のどちらの型にも合わない検証固有の手順
#   (同一window内の2pane操作)を要するため、局所実装を維持している——
#   「A-8は完全移行不可」と記録する(redo1からの継続)。
#
# ─── ソケット残骸・専用ディレクトリ残骸について (A-7・G758R1-03) ───
#
#   teardown後もsocket file自体、およびcreateがmktemp -dで作った
#   専用の親ディレクトリは削除しない。tmuxサーバが自然終了すれば、
#   そのsocket fileはただの残骸(誰もlistenしていないfile)であり、
#   放置しても害はない。専用の親ディレクトリはcreate呼出しごとに
#   新規作成されるため、繰り返し使うほど残骸ディレクトリが増えるが、
#   いずれも空のsocket file 1つだけを含む微小なものであり、削除する
#   操作自体がD002域(プロジェクト作業木の外の削除ではないが、
#   「作成した本人しか安全に消せない」という原則を保つため)へ踏み込む
#   理由にならない。handle領域・registry領域(下記)も同様に消さない。
#
# ═══════════════════════════════════════════════════════════════
set -uo pipefail

# ─── raw source APIの全廃 (G758R1-SOURCED-RAW-BYPASS-01是正) ───
# sourceされた場合はここで即座に戻る。以後のいかなる関数定義も
# 実行されないため、source後にtmuxを呼べる関数は1つも存在しない
# (tests/unit/test_isolated_tmux_helper.bats T-IT-017/018で列挙確認)。
if [ "${BASH_SOURCE[0]}" != "${0}" ]; then
    echo "エラー: isolated_tmux.sh はsourceして使うことはできない(直接実行のみ)。create/teardownの二口以外に入口は無い。" >&2
    return 1
fi

ITMUX_PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ITMUX_BIN="$(command -v tmux)"
# ★cmd_795: wait-forの上限に使う(下記「wait-forの上限」節)。
ITMUX_TIMEOUT_BIN="$(command -v timeout)"

# ─── 使い方 ───

_itmux_usage() {
    cat >&2 <<'USAGE'
使い方:
  isolated_tmux.sh create -L <socket_name>
      隔離tmuxソケットに素のシェルpaneを1つ作り、識別子をexact-schemaで
      handle fileへ書き出す。handle_fileのpathをstdoutへ出す。

  isolated_tmux.sh teardown <handle_file>
      handle_fileが指す隔離paneへ`exit`を入力し、送信直前に由来と身元を
      再照合したうえで自然終了をイベント駆動(pane-exited hook +
      wait-for)で待つ。ソケット・専用ディレクトリの残骸は消さない
      (D002域・害なし)。
USAGE
}

_itmux_die() {
    echo "エラー: $*" >&2
    exit 1
}

# ─── ソケット名(人が読む label)の検査 (A-2・G758-01是正) ───
# 既定ソケット(未指定・'default'を含む名)、および 'multiagent'/'shogun'を
# 含む名は拒否する。'default' はcase文であってもsubstring一致で拒否する
# (例: 'my_default_probe' も拒否)——本番tmux serverの既定socket名
# そのものを部分的にでも名乗らせないため。
itmux_validate_socket_name() {
    local name="${1:-}"
    if [ -z "$name" ]; then
        echo "-L <socket_name> は必須である(既定ソケットは使えない)" >&2
        return 1
    fi
    case "$name" in
        *multiagent*|*shogun*|*default*)
            echo "ソケット名に稼働中/既定サーバの名を含めることはできない: ${name}" >&2
            return 1
            ;;
    esac
    case "$name" in
        *[!A-Za-z0-9_.-]*)
            echo "ソケット名に使える文字は英数字・_・.・- のみである: ${name}" >&2
            return 1
            ;;
    esac
    return 0
}

_itmux_validate_pane_id() {
    case "${1:-}" in
        (%*)
            case "${1#%}" in
                (''|*[!0-9]*) return 1 ;;
                (*) return 0 ;;
            esac
            ;;
        (*) return 1 ;;
    esac
}

_itmux_validate_session_name() {
    case "${1:-}" in
        (''|*[!A-Za-z0-9_.-]*) return 1 ;;
        (*) return 0 ;;
    esac
}

_itmux_validate_pid() {
    [[ "${1:-}" =~ ^[1-9][0-9]*$ ]]
}

_itmux_validate_starttime() {
    [[ "${1:-}" =~ ^[0-9]+$ ]]
}

_itmux_validate_created_at() {
    [[ "${1:-}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{4}$ ]]
}

_itmux_validate_absolute_path() {
    case "${1:-}" in
        (/*) return 0 ;;
        (*) return 1 ;;
    esac
}

# ─── /proc からのプロセス身元確認 (G758-02是正) ───
# starttime(起動時刻・monotonic clock tick単位)はPID再利用を検知する
# ためだけに使う識別子であり、PIDと組で「同一プロセスか」を判定する。
# execveで書き換わらない(execはPIDもstarttimeも保つ)ため、
# pane_current_command の再確認と組にして初めて「置換されていない
# 素shellそのもの」を証明できる。
_itmux_proc_starttime() {
    local pid="$1" stat rest starttime
    stat="$(cat "/proc/${pid}/stat" 2>/dev/null)" || return 1
    [ -n "$stat" ] || return 1
    # comm(2番目のfield)は括弧で括られ空白を含みうるため、最後の
    # ") " より後ろだけを空白区切りfieldとして扱う。
    rest="${stat##*) }"
    set -- $rest
    starttime="${20:-}"
    _itmux_validate_starttime "$starttime" || return 1
    echo "$starttime"
}

# ═══════════════════════════════════════════════════════
# wait-forの上限 (cmd_795)
# ═══════════════════════════════════════════════════════
# 既定60秒。`ITMUX_WAIT_LIMIT_SEC`(1〜99999の整数秒)で上書きできる
# (試験ではこれで短縮する)。未設定・空なら既定値を使う。不正値・
# timeout(1)の不在は、_itmux_mainがcreate/teardownへ入る前(tmuxに
# 一切触れる前)に拒否する——create失敗時の後始末も同じ上限で待つため、
# createでも先に確定させる。
_ITMUX_WAIT_LIMIT_DEFAULT_SEC=60
_ITMUX_WAIT_LIMIT_SEC=""

_itmux_resolve_wait_limit() {
    local v="${ITMUX_WAIT_LIMIT_SEC-}"
    [ -n "$v" ] || v="$_ITMUX_WAIT_LIMIT_DEFAULT_SEC"
    if ! [[ "$v" =~ ^[1-9][0-9]{0,4}$ ]]; then
        echo "エラー: ITMUX_WAIT_LIMIT_SEC は 1〜99999 の整数秒で指定せよ(現在=${v}・未設定なら既定${_ITMUX_WAIT_LIMIT_DEFAULT_SEC}秒)。tmuxには一切触れていない。" >&2
        return 1
    fi
    if [ -z "$ITMUX_TIMEOUT_BIN" ]; then
        echo "エラー: timeout(1) が見つからない(wait-forに上限を設けられない)。tmuxには一切触れていない。" >&2
        return 1
    fi
    _ITMUX_WAIT_LIMIT_SEC="$v"
    return 0
}

# ═══════════════════════════════════════════════════════
# 固定・呼出側入力非依存の専用領域 (G758R1-HANDLE-INSTALL-BOUNDARY-05是正)
# ═══════════════════════════════════════════════════════
# ★`${TMPDIR:-/tmp}`のような呼出側が制御できる環境変数には一切
#   依存しない。本プロジェクト作業木内の固定絶対pathであり、
#   `ITMUX_PROJECT_ROOT`はBASH_SOURCEから導出される(呼出側からの
#   注入経路が無い)。
_ITMUX_HANDLE_DIR="${ITMUX_PROJECT_ROOT}/tmp/isolated_tmux_handles"
_ITMUX_HANDLE_REGISTRY_DIR="${_ITMUX_HANDLE_DIR}/.registry"
_ITMUX_SOCKPARENT_ROOT="${ITMUX_PROJECT_ROOT}/tmp/isolated_tmux_sockets"

_ITMUX_HANDLE_REQUIRED_KEYS="SOCKET SOCKET_PATH SESSION PANE_ID SERVER_PID SERVER_STARTTIME PANE_PID PANE_STARTTIME CREATED_AT"

# _itmux_secure_dir_ensure <dir>
# 専用領域を安全に確定する。既存なら非symlink・自分所有・mode 700を
# 検査する(1つでも満たさなければfail-closedで拒否)。存在しなければ
# mode 700で新規作成する。呼出側入力には一切依存しない固定pathに
# しか使わない。
_itmux_secure_dir_ensure() {
    local dir="$1"
    if [ -L "$dir" ]; then
        echo "エラー: 専用領域がsymlinkである(拒否): ${dir}" >&2
        return 1
    fi
    if [ -e "$dir" ]; then
        if [ ! -d "$dir" ]; then
            echo "エラー: 専用領域がディレクトリでない: ${dir}" >&2
            return 1
        fi
        local owner mode
        owner="$(stat -c '%u' "$dir" 2>/dev/null)" || return 1
        mode="$(stat -c '%a' "$dir" 2>/dev/null)" || return 1
        if [ "$owner" != "$(id -u)" ]; then
            echo "エラー: 専用領域の所有者が自分でない: ${dir}" >&2
            return 1
        fi
        if [ "$mode" != "700" ]; then
            echo "エラー: 専用領域のパーミッションが700でない(現在=${mode}): ${dir}" >&2
            return 1
        fi
    else
        mkdir -p "$dir" 2>/dev/null && chmod 700 "$dir" 2>/dev/null || {
            echo "エラー: 専用領域の作成に失敗した: ${dir}" >&2
            return 1
        }
    fi
    return 0
}

# _itmux_handle_install <socket_name> <socket_path> <session> <pane_id>
#     <server_pid> <server_starttime> <pane_pid> <pane_starttime>
# 専用領域へ一時fileへ書き込み→renameの二段で原子的にhandleを設置し、
# 続けてregistry(下記provenance検証節)へ(dev,inode)を記録する。
# 途中のいずれかの失敗もrcで検知し、成功時のみhandle pathをstdoutへ出す
# (失敗を無視して成功終了することは無い)。
_itmux_handle_install() {
    local socket="$1" socket_path="$2" session="$3" pane_id="$4" \
        server_pid="$5" server_starttime="$6" pane_pid="$7" pane_starttime="$8"

    _itmux_secure_dir_ensure "$_ITMUX_HANDLE_DIR" || return 1
    _itmux_secure_dir_ensure "$_ITMUX_HANDLE_REGISTRY_DIR" || return 1

    local final tmp
    final="$(mktemp "${_ITMUX_HANDLE_DIR}/handle.XXXXXX")" || return 1
    tmp="$(mktemp "${_ITMUX_HANDLE_DIR}/.handle.tmp.XXXXXX")" || {
        rm -f "$final"
        return 1
    }

    {
        echo "# isolated_tmux.sh handle file — 機械生成。手で編集するな。"
        echo "SOCKET=${socket}"
        echo "SOCKET_PATH=${socket_path}"
        echo "SESSION=${session}"
        echo "PANE_ID=${pane_id}"
        echo "SERVER_PID=${server_pid}"
        echo "SERVER_STARTTIME=${server_starttime}"
        echo "PANE_PID=${pane_pid}"
        echo "PANE_STARTTIME=${pane_starttime}"
        echo "CREATED_AT=$(date '+%Y-%m-%dT%H:%M:%S%z')"
    } > "$tmp"
    if [ $? -ne 0 ]; then
        rm -f "$tmp" "$final"
        return 1
    fi

    if ! mv -f "$tmp" "$final"; then
        rm -f "$tmp" "$final"
        return 1
    fi

    # ★G758R1-HANDLE-PROVENANCE-02是正: (dev,inode)は呼出側が選べない
    #   OS割当ての値であり、これをregistryへ記録することで「このfile
    #   実体はcreate自身がinstallしたものである」という、内容の複製
    #   (cp)や手書きでは再現できない証跡になる。
    local dev inode
    dev="$(stat -c '%d' "$final" 2>/dev/null)" || { rm -f "$final"; return 1; }
    inode="$(stat -c '%i' "$final" 2>/dev/null)" || { rm -f "$final"; return 1; }
    if ! : > "${_ITMUX_HANDLE_REGISTRY_DIR}/${dev}.${inode}" 2>/dev/null; then
        rm -f "$final"
        return 1
    fi

    echo "$final"
    return 0
}

# ═══════════════════════════════════════════════════════
# _itmux_handle_verify_provenance <handle_file> (G758R1-HANDLE-PROVENANCE-02是正)
# ═══════════════════════════════════════════════════════
# handle fileの内容を読む前に、file実体そのものの由来を検証する。
# ★非symlink・専用領域の直下(canonical path)・createが実際に
#   installした(dev,inode)がregistryに記録されている、の3点すべてを
#   満たさなければfail-closedで拒否する。
# ★cpによる複製は新しいinodeを得るためregistryに記録が無く拒否される。
#   手書きで9 field全てを正しく再現した完全形も、そのfile自体の
#   (dev,inode)がcreateのinstallを経ていない限り同様に拒否される
#   (内容の正しさに一切依存しない検証である)。
_itmux_handle_verify_provenance() {
    local handle_file="$1"

    if [ -L "$handle_file" ]; then
        echo "エラー: handle file がsymlinkである(拒否): ${handle_file}" >&2
        return 1
    fi
    if [ ! -f "$handle_file" ]; then
        echo "エラー: handle file が存在しない: ${handle_file}" >&2
        return 1
    fi

    local real dir_real
    real="$(realpath -e "$handle_file" 2>/dev/null)" || {
        echo "エラー: handle file の実体を解決できない: ${handle_file}" >&2
        return 1
    }
    dir_real="$(realpath -e "$_ITMUX_HANDLE_DIR" 2>/dev/null)" || {
        echo "エラー: handle領域を解決できない: ${_ITMUX_HANDLE_DIR}" >&2
        return 1
    }
    if [ "$(dirname "$real")" != "$dir_real" ]; then
        echo "エラー: handle file が専用領域の直下にない(拒否): ${handle_file}" >&2
        return 1
    fi

    local dev inode
    dev="$(stat -c '%d' "$real" 2>/dev/null)" || {
        echo "エラー: handle file のstatに失敗した: ${handle_file}" >&2
        return 1
    }
    inode="$(stat -c '%i' "$real" 2>/dev/null)" || {
        echo "エラー: handle file のstatに失敗した: ${handle_file}" >&2
        return 1
    }
    if [ ! -e "${_ITMUX_HANDLE_REGISTRY_DIR}/${dev}.${inode}" ]; then
        echo "エラー: handle file の由来を確認できない(createが発行したfileと同一でない・拒否): ${handle_file}" >&2
        return 1
    fi
    return 0
}

# ═══════════════════════════════════════════════════════
# _itmux_validate_socket_path_domain <socket_path>
#   (G758R2-B2-HANDLE-CONTENT-SWAP是正(ii)のみ・S-2・cmd_758 redo3)
# ═══════════════════════════════════════════════════════
# ★SOCKET_PATHが専用socket親領域($_ITMUX_SOCKPARENT_ROOT配下の
#   `sp.*`ディレクトリ)の直下(1階層のみ)であることを構造検証する。
#   由来検証(_itmux_handle_verify_provenance)がhandle file実体の同一性
#   を証明するのに対し、これはfieldの値そのもの(文字列の形)だけを見る
#   ——handle内容の他フィールドが何であれ(改竄・破損・実在しない値を
#   問わず)、この検証だけは通らない。realpath等の実在解決には頼らない
#   (symlink解決・実在確認も行わない)ため、まだ存在しない/既に消えた
#   socket_pathに対しても一貫して働く。呼出元(_itmux_handle_read)は
#   いかなるtmuxコマンドを発行する前にこれを呼ぶ。
_itmux_validate_socket_path_domain() {
    local path="${1:-}" prefix rest sp_seg sock_seg
    prefix="${_ITMUX_SOCKPARENT_ROOT}/"
    case "$path" in
        ("$prefix"*) : ;;
        (*) return 1 ;;
    esac
    rest="${path#"$prefix"}"
    # ★ちょうど2 segment(sp.*/socket名)のみ許可する。0個・2個以上の
    #   "/"を含む経路("sp.X/../../etc/passwd"のような".."混入で"/"が
    #   増える経路を含む)はここで拒否される。
    case "$rest" in
        (*/*/*) return 1 ;;
        (*/*) : ;;
        (*) return 1 ;;
    esac
    sp_seg="${rest%%/*}"
    sock_seg="${rest#*/}"
    case "$sp_seg" in
        (sp.?*) : ;;
        (*) return 1 ;;
    esac
    case "$sock_seg" in
        (''|'.'|'..') return 1 ;;
    esac
    return 0
}

# _itmux_handle_read <file>
# 閉じたschemaを満たさない行が1つでもあれば全体をfail-closedで拒否する。
# 全fieldの個別形式検査も通す。結果は ITMUX_HANDLE_* へ格納する。
# ★provenance検証(上記)を通った後にのみ呼ぶこと。
_itmux_handle_read() {
    local file="$1"
    [ -f "$file" ] || _itmux_die "handle file が存在しない: ${file}"

    local line key value
    local -A seen=()
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            (''|'#'*) continue ;;
        esac
        case "$line" in
            (*=*) key="${line%%=*}"; value="${line#*=}" ;;
            (*) _itmux_die "handle fileに未知形式の行がある(exact-schema違反): ${file}" ;;
        esac
        case " ${_ITMUX_HANDLE_REQUIRED_KEYS} " in
            (*" ${key} "*) : ;;
            (*) _itmux_die "handle fileに未知のkeyがある(exact-schema違反): ${key}" ;;
        esac
        if [ -n "${seen[$key]+x}" ]; then
            _itmux_die "handle fileにkeyの重複がある(exact-schema違反): ${key}"
        fi
        seen["$key"]="$value"
    done < "$file"

    local k
    for k in $_ITMUX_HANDLE_REQUIRED_KEYS; do
        if [ -z "${seen[$k]+x}" ]; then
            _itmux_die "handle fileに必須keyが欠落している(exact-schema違反): ${k}"
        fi
    done

    ITMUX_HANDLE_SOCKET="${seen[SOCKET]}"
    ITMUX_HANDLE_SOCKET_PATH="${seen[SOCKET_PATH]}"
    ITMUX_HANDLE_SESSION="${seen[SESSION]}"
    ITMUX_HANDLE_PANE_ID="${seen[PANE_ID]}"
    ITMUX_HANDLE_SERVER_PID="${seen[SERVER_PID]}"
    ITMUX_HANDLE_SERVER_STARTTIME="${seen[SERVER_STARTTIME]}"
    ITMUX_HANDLE_PANE_PID="${seen[PANE_PID]}"
    ITMUX_HANDLE_PANE_STARTTIME="${seen[PANE_STARTTIME]}"
    ITMUX_HANDLE_CREATED_AT="${seen[CREATED_AT]}"

    itmux_validate_socket_name "$ITMUX_HANDLE_SOCKET" \
        || _itmux_die "handle file の SOCKET が不正: ${file}"
    _itmux_validate_absolute_path "$ITMUX_HANDLE_SOCKET_PATH" \
        || _itmux_die "handle file の SOCKET_PATH が不正(絶対pathでない): ${file}"
    _itmux_validate_socket_path_domain "$ITMUX_HANDLE_SOCKET_PATH" \
        || _itmux_die "handle file の SOCKET_PATH が専用sockparent領域(\${_ITMUX_SOCKPARENT_ROOT}/sp.*/)の直下にない(内容非依存の構造検証・拒否・G758R2-B2(ii)是正): ${file}"
    _itmux_validate_session_name "$ITMUX_HANDLE_SESSION" \
        || _itmux_die "handle file の SESSION が不正: ${file}"
    _itmux_validate_pane_id "$ITMUX_HANDLE_PANE_ID" \
        || _itmux_die "handle file の PANE_ID が不正: ${file}"
    _itmux_validate_pid "$ITMUX_HANDLE_SERVER_PID" \
        || _itmux_die "handle file の SERVER_PID が不正: ${file}"
    _itmux_validate_starttime "$ITMUX_HANDLE_SERVER_STARTTIME" \
        || _itmux_die "handle file の SERVER_STARTTIME が不正: ${file}"
    _itmux_validate_pid "$ITMUX_HANDLE_PANE_PID" \
        || _itmux_die "handle file の PANE_PID が不正: ${file}"
    _itmux_validate_starttime "$ITMUX_HANDLE_PANE_STARTTIME" \
        || _itmux_die "handle file の PANE_STARTTIME が不正: ${file}"
    _itmux_validate_created_at "$ITMUX_HANDLE_CREATED_AT" \
        || _itmux_die "handle file の CREATED_AT が不正: ${file}"
}

# ═══════════════════════════════════════════════════════
# _itmux_wait_for_pane_exit <socket_path> <pane_id> (A-4・G758-03・
#                                                      G758R1-EVENT-WAIT-HANG-04是正)
# ═══════════════════════════════════════════════════════
#
# ★内部専用(non-public)。呼出元は _itmux_cmd_teardown と、create失敗時
#   のbest-effort後始末のみであり、検査・身元再照合を済ませた値だけが
#   ここへ渡る。他scriptからのsource再利用は提供しない(上記ヘッダ参照)。
#
# ★対象paneへ`exit`という文字列を打鍵として送り、当のpaneが自分で
#   終了するのを待つ。tmuxの`pane-exited` hookを先に仕込んでから
#   `exit`キーを送ることで、「exitが先に処理されhookが間に合わない」
#   窓を作らない(順序が要である)。終了通知は`tmux wait-for`の
#   blocking waitで受け取る — 固定sleep・busy pollingは一切使わない
#   (F004)。
#
# ★G758-03是正: set-hook・send-keys それぞれのrcを確認し、失敗したら
#   即座にfail-closedで返る(wait-forへは入らない)。通知producerが
#   設置されないままwait-forへ入って永久blockする経路を塞ぐ。
#
# ★G758R1-04是正: hookを`-g`(global)スコープで設定する。`-t <pane>`
#   のみ(session-scope)だと、対象window/session自体が消滅する瞬間に
#   hookの保存先も一緒に消え、通知が発火しないことが実機で確認された
#   (二session構成でwait-forがtimeoutするケース)。`-g`はサーバ生存中
#   残るglobalスコープに保存されるため、対象の消滅と保存先の消滅が
#   同時に起きない。本helperのserverはcreateごとに新規private socket
#   parent配下の一回限りのもの(A-3・G758R1-03是正)であり、他sessionの
#   pane-exitedと混同する余地は無い。
#
# ★S-1是正(G758R2-B1-TEARDOWN-FALSE-NEGATIVE・cmd_758 redo3): 戻り値は
#   3種を区別する——0(wait-for成功)・1(exit送信は完了済みだが、その後の
#   waitが確定応答を得られなかった)・2(送信そのものに失敗・真に
#   fail-closed)。rc=2のときのみ「何も送っていない」ため、呼出元
#   (_itmux_cmd_teardown)はここでdieしてよい。rc=1は「送信済み」で
#   あり、fail-closedではない——足軽7号QC実測: create後0.5秒以上
#   経ってからのteardownは、最終paneのexitでserverがexit-emptyにより
#   自然終了する際に`tmux wait-for`自身が「server exited
#   unexpectedly」で切断され、100%の再現率でrc!=0を返す。paneは実際
#   には正常に自然終了しているため、これは失敗ではなく成功の一形態で
#   ありうる。呼出元はrc=1を理由にdieせず、最終的な成否をhas-session
#   (server消滅=成功)で判定する。
#
# ★cmd_795: wait-forをtimeout(1)で包み、上限(_ITMUX_WAIT_LIMIT_SEC秒)
#   を設けた。上限に達したときは第4の戻り値3(exit送信は完了済み・
#   上限内に通知が来なかった=通知取りこぼしの疑い)を返す。rc=3も
#   rc=1と同じく送信済みであり、呼出元はdieせず、has-sessionで成否を
#   確定する(ヘッダ(8)参照)。`--foreground`は外さないこと——外すと
#   timeoutが自分のprocess group全体へも終了要求を送る(ヘッダ(8)の
#   ★参照・T-IT-046)。
_itmux_wait_for_pane_exit() {
    local socket_path="$1" pane_id="$2"
    local chan="itmux_exit_$$_${RANDOM}"

    if ! "$ITMUX_BIN" -S "$socket_path" set-hook -g -t "$pane_id" pane-exited \
            "run-shell -b '${ITMUX_BIN} -S ${socket_path} wait-for -S ${chan}'" 2>/dev/null; then
        echo "エラー: pane-exited hookの設置に失敗した(送信前の失敗・fail-closed・何も送っていない・通知不能のためwaitへ入らない): socket_path=${socket_path} pane=${pane_id}" >&2
        return 2
    fi

    if ! "$ITMUX_BIN" -S "$socket_path" send-keys -t "$pane_id" "exit" Enter 2>/dev/null; then
        echo "エラー: exit打鍵の送信に失敗した(送信前の失敗・fail-closed・何も送っていない・waitへ入らない): socket_path=${socket_path} pane=${pane_id}" >&2
        return 2
    fi

    "$ITMUX_TIMEOUT_BIN" --foreground "$_ITMUX_WAIT_LIMIT_SEC" "$ITMUX_BIN" -S "$socket_path" wait-for "$chan" 2>/dev/null
    local wait_rc=$?
    if [ "$wait_rc" -eq 124 ]; then
        echo "注記: exit送信後のwait-forが上限${_ITMUX_WAIT_LIMIT_SEC}秒に達した(通知取りこぼしの疑い・送信は完了済み・待受けclientのみ終了・最終判定はhas-sessionで行う): socket_path=${socket_path} pane=${pane_id}" >&2
        return 3
    fi
    if [ "$wait_rc" -ne 0 ]; then
        echo "注記: exit送信後のwait-forが確定応答を得られなかった(送信は完了済み・fail-closedではない・最終判定はhas-sessionで行う): socket_path=${socket_path} pane=${pane_id}" >&2
        return 1
    fi

    return 0
}

# ═══════════════════════════════════════════════════════
# _itmux_reverify_identity (G758-02是正)
# ═══════════════════════════════════════════════════════
# teardown が exit を送る直前に、handle が指す server/session/pane が
# 「create 時に自分が作ったものと同一instanceか」を肯定形で全項目
# 再照合する。1つでも不一致・取得失敗があれば理由をstderrへ出し
# rc!=0で返る(呼出側はここで何も送らずfail-closedにする)。
#
# ★G758R1-03是正後は各serverが private socket parent 配下の一回限り
#   のものになったため、server再起動でsocket_pathが使い回されるのは
#   稀だが、SERVER_PID/SERVER_STARTTIMEの不一致検知は引き続き行う
#   (念のための多重防御・G758-02の最重要シナリオ)。
# ★execveで置換されたpane(PID/starttimeは保たれる)は
#   pane_current_command=bash の再確認で検知する。
_itmux_reverify_identity() {
    local socket_path="$1" session="$2" pane_id="$3" \
        want_server_pid="$4" want_server_starttime="$5" \
        want_pane_pid="$6" want_pane_starttime="$7"

    local cur_server_pid
    cur_server_pid="$("$ITMUX_BIN" -S "$socket_path" display-message -p '#{pid}' 2>/dev/null)"
    if ! _itmux_validate_pid "$cur_server_pid"; then
        echo "現在のserver pidを取得できない" >&2
        return 1
    fi
    if [ "$cur_server_pid" != "$want_server_pid" ]; then
        echo "server pidが記録と不一致(server再起動の疑い): 記録=${want_server_pid} 現在=${cur_server_pid}" >&2
        return 1
    fi

    local cur_server_starttime
    cur_server_starttime="$(_itmux_proc_starttime "$cur_server_pid")" || {
        echo "現在のserver starttimeを取得できない" >&2
        return 1
    }
    if [ "$cur_server_starttime" != "$want_server_starttime" ]; then
        echo "server starttimeが記録と不一致(pid再利用の疑い): 記録=${want_server_starttime} 現在=${cur_server_starttime}" >&2
        return 1
    fi

    if ! "$ITMUX_BIN" -S "$socket_path" has-session -t "$session" 2>/dev/null; then
        echo "対象sessionが存在しない: session=${session}" >&2
        return 1
    fi

    if ! "$ITMUX_BIN" -S "$socket_path" list-panes -t "$session" -F '#{pane_id}' 2>/dev/null \
            | grep -qx -- "$pane_id"; then
        echo "対象paneは記録されたsessionに所属していない: session=${session} pane=${pane_id}" >&2
        return 1
    fi

    local cur_pane_pid
    cur_pane_pid="$("$ITMUX_BIN" -S "$socket_path" display-message -t "$pane_id" -p '#{pane_pid}' 2>/dev/null)"
    if ! _itmux_validate_pid "$cur_pane_pid"; then
        echo "現在のpane pidを取得できない" >&2
        return 1
    fi
    if [ "$cur_pane_pid" != "$want_pane_pid" ]; then
        echo "pane pidが記録と不一致: 記録=${want_pane_pid} 現在=${cur_pane_pid}" >&2
        return 1
    fi

    local cur_pane_starttime
    cur_pane_starttime="$(_itmux_proc_starttime "$cur_pane_pid")" || {
        echo "現在のpane starttimeを取得できない" >&2
        return 1
    }
    if [ "$cur_pane_starttime" != "$want_pane_starttime" ]; then
        echo "pane starttimeが記録と不一致: 記録=${want_pane_starttime} 現在=${cur_pane_starttime}" >&2
        return 1
    fi

    local cur_pane_cmd
    cur_pane_cmd="$("$ITMUX_BIN" -S "$socket_path" display-message -t "$pane_id" -p '#{pane_current_command}' 2>/dev/null)"
    if [ "$cur_pane_cmd" != "bash" ]; then
        echo "pane_current_commandがbashでない(置換の疑い): ${cur_pane_cmd}" >&2
        return 1
    fi

    return 0
}

# ═══════════════════════════════════════════════════════
# create失敗時のbest-effort後始末 (G758R1-HANDLE-INSTALL-BOUNDARY-05是正)
# ═══════════════════════════════════════════════════════
# ★セッション作成に成功した後、メタデータ取得やhandle installなど
#   後続のいずれかの手順が失敗した場合、既に作った素shellを放置せず、
#   exit入力+イベント駆動待ちで畳んでからdieする。強制終了コマンドは
#   使わない。まだ他の誰にもhandleを渡していない自分専用の直後の資源であり、
#   身元の厳密な再照合(_itmux_reverify_identity)は要しない
#   (作成直後で取り違えの余地が無いため)。
_itmux_create_failure_cleanup() {
    local socket_path="$1" session="$2"
    if "$ITMUX_BIN" -S "$socket_path" has-session -t "$session" 2>/dev/null; then
        local p
        for p in $("$ITMUX_BIN" -S "$socket_path" list-panes -t "$session" -F '#{pane_id}' 2>/dev/null); do
            _itmux_wait_for_pane_exit "$socket_path" "$p" 2>/dev/null || true
        done
    fi
}

_itmux_create_fail() {
    local socket_path="$1" session="$2"
    shift 2
    _itmux_create_failure_cleanup "$socket_path" "$session"
    _itmux_die "$@"
}

# ═══════════════════════════════════════════════════════
# create (A-1〜A-3・A-6・G758-01/02/04・G758R1-03/05是正)
# ═══════════════════════════════════════════════════════
_itmux_cmd_create() {
    local socket_name=""
    local OPTIND=1 opt
    # ★G758-04是正: 旧`-o <handle_file>`(呼出側が保存先pathを指定できる
    #   口)は削除した。-Lのみを受け付ける。
    while getopts ":L:" opt; do
        case "$opt" in
            L) socket_name="$OPTARG" ;;
            :) _itmux_die "-${OPTARG} には引数が要る" ;;
            *) _itmux_usage; exit 1 ;;
        esac
    done

    itmux_validate_socket_name "$socket_name" || exit 1

    # ★G758R1-05是正: handle領域・socket親領域は、tmuxセッションを
    #   作る前に安全確定する。ここで失敗すればtmuxには一切触れずに
    #   終わる(失敗時の後始末そのものが不要になる)。
    _itmux_secure_dir_ensure "$_ITMUX_HANDLE_DIR" \
        || _itmux_die "handle領域の事前確定に失敗した: ${_ITMUX_HANDLE_DIR}"
    _itmux_secure_dir_ensure "$_ITMUX_HANDLE_REGISTRY_DIR" \
        || _itmux_die "handle registry領域の事前確定に失敗した: ${_ITMUX_HANDLE_REGISTRY_DIR}"
    _itmux_secure_dir_ensure "$_ITMUX_SOCKPARENT_ROOT" \
        || _itmux_die "socket親領域の事前確定に失敗した: ${_ITMUX_SOCKPARENT_ROOT}"

    # ★G758R1-03是正: 各createに新規private socket parentを割り当てる。
    #   mktemp -dで直前に作られた未使用ディレクトリ配下にsocketを
    #   置き、`-S <絶対path>`で直接指定する(`-L <name>`の共有namespace
    #   解決は使わない)ため、既存serverが同じpathで待ち受けている
    #   可能性は構造的に排除される(TOCTOUの余地無し)。
    local sockparent
    sockparent="$(mktemp -d "${_ITMUX_SOCKPARENT_ROOT}/sp.XXXXXX")" \
        || _itmux_die "socket親領域の作成に失敗した"

    local socket_path="${sockparent}/${socket_name}.sock"

    local session="iso"
    # ★A-3: 素のシェルpaneのみを作る。agent CLIは起動しない。
    "$ITMUX_BIN" -S "$socket_path" new-session -d -s "$session" -n w0 bash \
        || _itmux_die "隔離tmuxセッションの作成に失敗した(socket_path=${socket_path})"

    # ★以降の失敗は、既に作った素shellをexit+イベント駆動待ちで
    #   畳んでからdieする(G758R1-05是正)。

    local cur_socket_path
    cur_socket_path="$("$ITMUX_BIN" -S "$socket_path" display-message -p '#{socket_path}' 2>/dev/null)"
    if [ "$cur_socket_path" != "$socket_path" ]; then
        _itmux_create_fail "$socket_path" "$session" \
            "socket_pathが期待値と不一致(想定=${socket_path} 実際=${cur_socket_path})"
    fi

    local pane_id
    pane_id="$("$ITMUX_BIN" -S "$socket_path" display-message -t "${session}:w0.0" \
        -p '#{pane_id}' 2>/dev/null)"
    _itmux_validate_pane_id "$pane_id" \
        || _itmux_create_fail "$socket_path" "$session" "作成した pane の pane_id を取得できなかった"

    local server_pid
    server_pid="$("$ITMUX_BIN" -S "$socket_path" display-message -p '#{pid}' 2>/dev/null)"
    _itmux_validate_pid "$server_pid" \
        || _itmux_create_fail "$socket_path" "$session" "server pid の取得に失敗した"

    local server_starttime
    server_starttime="$(_itmux_proc_starttime "$server_pid")" \
        || _itmux_create_fail "$socket_path" "$session" "server starttime の取得に失敗した(pid=${server_pid})"

    local pane_pid
    pane_pid="$("$ITMUX_BIN" -S "$socket_path" display-message -t "$pane_id" -p '#{pane_pid}' 2>/dev/null)"
    _itmux_validate_pid "$pane_pid" \
        || _itmux_create_fail "$socket_path" "$session" "pane pid の取得に失敗した"

    local pane_starttime
    pane_starttime="$(_itmux_proc_starttime "$pane_pid")" \
        || _itmux_create_fail "$socket_path" "$session" "pane starttime の取得に失敗した(pid=${pane_pid})"

    local handle_file
    handle_file="$(_itmux_handle_install "$socket_name" "$socket_path" "$session" "$pane_id" \
        "$server_pid" "$server_starttime" "$pane_pid" "$pane_starttime")" \
        || _itmux_create_fail "$socket_path" "$session" "handle fileの原子的installに失敗した"

    echo "$handle_file"
}

# ═══════════════════════════════════════════════════════
# teardown (A-4・A-6・A-7・G758-02/03・G758R1-02/04是正)
# ═══════════════════════════════════════════════════════
_itmux_cmd_teardown() {
    local handle_file="${1:-}"
    [ -n "$handle_file" ] || { _itmux_usage; exit 1; }

    # ★G758R1-HANDLE-PROVENANCE-02是正: 内容を読む前に、file実体
    #   そのものの由来(非symlink・専用領域直下・createが実際に
    #   installしたregistry登録済みの(dev,inode))を検証する。
    _itmux_handle_verify_provenance "$handle_file" \
        || _itmux_die "handle file の由来検証に失敗した(fail-closed): ${handle_file}"

    _itmux_handle_read "$handle_file"
    local socket_path="$ITMUX_HANDLE_SOCKET_PATH" \
        session="$ITMUX_HANDLE_SESSION" pane_id="$ITMUX_HANDLE_PANE_ID"

    # 対象paneが既に存在しなければ何もしない(冪等)。
    if ! "$ITMUX_BIN" -S "$socket_path" list-panes -a -F '#{pane_id}' 2>/dev/null \
            | grep -qx -- "$pane_id"; then
        echo "対象paneは既に存在しない(冪等・何もしない): socket_path=${socket_path} pane=${pane_id}"
        return 0
    fi

    # ★G758-02是正: 送信直前にserver/session/pane instance identityと
    #   pane_current_command=bashを肯定形で全項目再照合する。1つでも
    #   不一致ならfail-closedで何も送らない。
    if ! _itmux_reverify_identity "$socket_path" "$session" "$pane_id" \
            "$ITMUX_HANDLE_SERVER_PID" "$ITMUX_HANDLE_SERVER_STARTTIME" \
            "$ITMUX_HANDLE_PANE_PID" "$ITMUX_HANDLE_PANE_STARTTIME"; then
        _itmux_die "身元の再照合に失敗した(fail-closed・何も送らない): socket_path=${socket_path} pane=${pane_id}"
    fi

    # ★S-1是正(G758R2-B1-TEARDOWN-FALSE-NEGATIVE): _itmux_wait_for_pane_exit
    #   のrcだけで成否を決めない。rc=2(送信前の失敗・真にfail-closed・
    #   何も送っていない)のときのみここでdieする。rc=0/1(いずれも
    #   exitは既に送信済み)は死なずに次へ進み、最終判定を下の
    #   has-session確認(server消滅=成功)へ一本化する。
    # ★cmd_795: rc=3(wait-forが上限に達した・送信済み)も同様に
    #   has-sessionで確定する。残存なら安全側の失敗(rc 1・以後何も
    #   送らず何も終了させない・handleは残す)、不在なら成功(rc 0)。
    _itmux_wait_for_pane_exit "$socket_path" "$pane_id"
    local wait_rc=$?
    if [ "$wait_rc" -eq 2 ]; then
        _itmux_die "exit送信前に失敗した(fail-closed・何も送っていない): socket_path=${socket_path} pane=${pane_id}"
    fi

    if "$ITMUX_BIN" -S "$socket_path" has-session -t "$session" 2>/dev/null; then
        if [ "$wait_rc" -eq 3 ]; then
            echo "警告: wait-forが上限${_ITMUX_WAIT_LIMIT_SEC}秒に達し、has-sessionでも隔離セッションが残っている(安全側の失敗・以後何も送らず何も終了させない・handleは残す: ${handle_file})。人が確認されたし: socket_path=${socket_path} session=${session}"
        else
            echo "警告: 隔離セッションが残っている。人が確認されたし: socket_path=${socket_path} session=${session}"
        fi
        return 1
    fi
    if [ "$wait_rc" -eq 3 ]; then
        echo "隔離セッションは自然終了した(通知取りこぼし後に has-session で確定・wait-forは上限${_ITMUX_WAIT_LIMIT_SEC}秒に到達)(socket_path=${socket_path})。ソケット・専用ディレクトリの残骸は消さない(D002域・害なし)。"
    else
        echo "隔離セッションは自然終了した(socket_path=${socket_path})。ソケット・専用ディレクトリの残骸は消さない(D002域・害なし)。"
    fi
    return 0
}

# ═══════════════════════════════════════════════════════
_itmux_main() {
    local cmd="${1:-}"
    [ -n "$cmd" ] || { _itmux_usage; exit 1; }
    shift
    case "$cmd" in
        create|teardown)
            # ★cmd_795: 上限はtmuxに一切触れる前に確定する。
            _itmux_resolve_wait_limit || exit 1
            ;;
    esac
    case "$cmd" in
        create) _itmux_cmd_create "$@" ;;
        teardown) _itmux_cmd_teardown "$@" ;;
        *) _itmux_usage; exit 1 ;;
    esac
}

_itmux_main "$@"
