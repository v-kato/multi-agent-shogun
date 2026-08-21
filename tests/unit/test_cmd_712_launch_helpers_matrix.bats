#!/usr/bin/env bats
# cmd_712 Phase C redo1: T1〜T6・T8〜T10の素のPowerShell harness実装
# (設計書 context/cmd_712_launch_ps1_fixes_design.md §3.8)
# T7は別ファイル test_cmd_712_launch_ps1_t7.bats を参照。
#
# ★cmd_718 subtask_718_phase_ab_t9_closed_world_fingerprint_redo1
# (2026-08-21・足軽4号): T9をtop-level statement列の1対1照合方式から
# closed-world token fingerprint照合方式へ全面転換し、redo1でR-3
# (top-level statement包含検査)・region拡大(ファイル先頭〜Step 1
# marker直前)を追加した。詳細はT9セクション(下記)のコメントを参照。
#
# 将軍裁定(2026-08-21・subtask_712_phase_c_redo1): Pester改修(案a)・
# 未実装9項目への個別例外(案b)いずれも却下。将軍が実機で確認済みの
# 以下4技術のみでT1〜T6・T8〜T10を実装する(この4点自体は再調査しない):
#   1. WSL2からpowershell.exeへ直接到達できる
#   2. [System.Management.Automation.Language.Parser]::ParseInputはPester非依存
#      (AST静的解析。CommandAst/IfStatementAst等をFindAllで拾える)
#   3. 関数差替mock: 同名関数を後から定義すれば先の定義を上書きできる(Pester不要)
#   4. Get-Content -Raw + [ScriptBlock]::Create() + dot-source なら、
#      \\wsl.localhost 経由のWSLパスでもExecutionPolicyに一切触れずに読み込める
#
# 本ファイル固有の実装知見(4技術そのものではなく、その適用時に必要だった補助知見。
# 足軽5号が本タスクで実地に踏んだ落とし穴と回避策):
#   - Get-Contentは既定のままだとlaunch.helpers.ps1/launch.ps1内の日本語コメント/
#     文字列でパースが破綻する(Windows PowerShell 5.1が非BOM UTF-8ファイルを
#     既定で正しく認識しないため)。必ず -Encoding UTF8 を明示すること。
#   - AST静的解析は [Parser]::ParseFile ではなく [Parser]::ParseInput を使うこと。
#     ParseFileは上と同種の非BOM UTF-8認識問題を独自に抱え、日本語を含む行の
#     直後でパースエラーになる。ParseInputは文字列を直接受け取るため、
#     Get-Content -Encoding UTF8 で正しく読んだ文字列と組み合わせれば回避できる。
#   - powershell.exeへスクリプトを渡す際、標準入力パイプ+`-Command -`は
#     複数行try/catchブロックを含む入力を逐次(REPL的)に読み違え、tryブロック
#     内の出力が一切表示されないまま静かに終了する(exit code 0のまま)。
#     本ファイルは `-Command "<script全体>"` という1引数渡しに統一し、この
#     問題を回避する(1引数として丸ごと渡す場合はこの問題が起きないことを
#     実地確認済み)。
#   - 実Electron/実CDP接続/実powershell.exe子プロセス起動は一切行わない。
#     全テストはTest-TcpPortOpen/Invoke-PsBridge/Start-PsBridgeProcess/
#     Wait-PsBridgeProcessExitのいずれかを関数差替でmockし、実ネットワーク・
#     実プロセスへは到達しない。

setup() {
    # redo2是正(C712-C-R1-QC-03): 検査対象rootを外部環境変数でoverride可能に
    # する。呼出側が既にexportしていればその値を尊重し、未指定時のみ
    # canonical current treeを既定値として使う。
    export TLC_CMS_WORKTREE="${TLC_CMS_WORKTREE:-/home/kato/dev/tlc-cms}"
    export HELPERS_PS1="$TLC_CMS_WORKTREE/launch.helpers.ps1"
    export LAUNCH_PS1="$TLC_CMS_WORKTREE/launch.ps1"
    HELPERS_WIN="$(wslpath -w "$HELPERS_PS1")"
    LAUNCH_WIN="$(wslpath -w "$LAUNCH_PS1")"
    export HELPERS_WIN LAUNCH_WIN
    # cmd_718 T9用: 承認済みStep 0領域正典(N-1〜N-3で保護)。実際のtlc-cms
    # worktreeではなく本リポジトリ(shogun)側のtests/fixtures/に固定配置する
    # (正典はTLC_CMS_WORKTREEの切替に追従してはならない不変の比較基準のため)。
    export STEP0_CANONICAL_PS1="/home/kato/shogun/tests/fixtures/cmd_718_step0_canonical.ps1"
    STEP0_CANONICAL_WIN="$(wslpath -w "$STEP0_CANONICAL_PS1")"
    export STEP0_CANONICAL_WIN
}

# launch.helpers.ps1をGet-Content(-Encoding UTF8)+ScriptBlock::Create()+dot-source
# で読み込み、tryブロックを開いたままにするpreamble(将軍実測済み技術・
# ExecutionPolicy不変)。呼出し元がbodyを追記した後、必ず `} catch { ... }` で
# 閉じること(run_ps内で行う)。
helpers_preamble() {
    cat <<EOF
\$ErrorActionPreference = 'Stop'
try {
\$__code = Get-Content -Raw -Encoding UTF8 -LiteralPath '${HELPERS_WIN}'
\$__sb = [ScriptBlock]::Create(\$__code)
. \$__sb
EOF
}

# $1: helpers dot-source後に実行するPowerShell本体コード。
# 本体コードの最後で `Write-Output 'RESULT:DONE=1'` を出力する前提。
run_ps() {
    local body="$1"
    local script
    script="$(helpers_preamble)
${body}
} catch {
    Write-Output \"RESULT:ERROR=\$(\$_.Exception.Message)\"
    exit 1
}"
    run powershell.exe -NoProfile -NonInteractive -Command "$script"
}

# T9/T10用: launch.helpers.ps1のdot-sourceを行わず、対象.ps1をParseInputで
# 静的解析するだけのpreamble(実行は一切しない)。
run_ps_ast() {
    local target_win="$1"
    local body="$2"
    local script
    script="\$ErrorActionPreference = 'Stop'
try {
\$src = Get-Content -Raw -Encoding UTF8 -LiteralPath '${target_win}'
\$tokens = \$null
\$errors = \$null
\$ast = [System.Management.Automation.Language.Parser]::ParseInput(\$src, [ref]\$tokens, [ref]\$errors)
\$__step0CanonicalWin = '${STEP0_CANONICAL_WIN}'
${body}
} catch {
    Write-Output \"RESULT:ERROR=\$(\$_.Exception.Message)\"
    exit 1
}"
    run powershell.exe -NoProfile -NonInteractive -Command "$script"
}

assert_done() {
    [[ "$output" == *"RESULT:DONE=1"* ]] || {
        echo "--- RESULT:DONE=1 に到達しなかった。全出力: ---"
        echo "$output"
        return 1
    }
}

assert_contains() {
    [[ "$output" == *"$1"* ]] || {
        echo "--- 期待した部分文字列が見つからない: $1 ---"
        echo "--- 実際の出力: ---"
        echo "$output"
        return 1
    }
}

# ============================================================
# T1/T2: Wait-CdpPortReady (Wait-TcpPortState -TargetState "Open")
# ============================================================

@test "T1: 9222のみlisten→Wait-CdpPortReady -Port 9224 はtimeoutまでfalseのまま(QC-02旧偽陽性の回帰防止)" {
    run_ps "
function Test-TcpPortOpen { param(\$HostName,\$Port) return (\$Port -eq 9222) }
\$result = Wait-CdpPortReady -Port 9224 -TimeoutSeconds 2
Write-Output \"RESULT:Ready=\$result\"
Write-Output 'RESULT:DONE=1'
"
    [ "$status" -eq 0 ]
    assert_done
    assert_contains "RESULT:Ready=False"
}

@test "T2: 9224 listen→Wait-CdpPortReady -Port 9224 はtrueを返す(A-3既存合格部分の回帰防止)" {
    run_ps "
function Test-TcpPortOpen { param(\$HostName,\$Port) return (\$Port -eq 9224) }
\$result = Wait-CdpPortReady -Port 9224 -TimeoutSeconds 90
Write-Output \"RESULT:Ready=\$result\"
Write-Output 'RESULT:DONE=1'
"
    [ "$status" -eq 0 ]
    assert_done
    assert_contains "RESULT:Ready=True"
}

# ============================================================
# T3/T4/T5: Invoke-Step0AShutdown の状態機械(§3.3状態(c)(d)(e))
# ============================================================

@test "T3: Browser.close response成功→ShutdownOk=true,RequiresFailClosedStop=false,Reason=PortClosedAfterSend(QC-02状態(c))" {
    run_ps "
function Test-TcpPortOpen { param(\$HostName,\$Port) return \$true }
function Invoke-PsBridge {
    param(\$PsBridgePath,\$BridgeArgs,\$TimeoutMs=20000)
    if (\$BridgeArgs -contains 'list') {
        \$json = (@(@{ id = 'target-1'; title = 't'; url = 'u'; wsUrl = 'w' }) | ConvertTo-Json -Compress)
        return [PSCustomObject]@{ TimedOut = \$false; ExitCode = 0; StdOut = \$json; StdErr = '' }
    } elseif (\$BridgeArgs -contains 'send') {
        return [PSCustomObject]@{ TimedOut = \$false; ExitCode = 0; StdOut = ''; StdErr = '' }
    }
    throw \"unexpected BridgeArgs: \$BridgeArgs\"
}
function Wait-TcpPortState { param(\$HostName,\$Port,\$TimeoutSeconds,\$TargetState) return \$true }
\$result = Invoke-Step0AShutdown -PsBridgePath 'C:\fake\ps-bridge.ps1' -Port 9224
Write-Output \"RESULT:ShutdownOk=\$(\$result.ShutdownOk)\"
Write-Output \"RESULT:RequiresFailClosedStop=\$(\$result.RequiresFailClosedStop)\"
Write-Output \"RESULT:Reason=\$(\$result.Reason)\"
Write-Output 'RESULT:DONE=1'
"
    [ "$status" -eq 0 ]
    assert_done
    assert_contains "RESULT:ShutdownOk=True"
    assert_contains "RESULT:RequiresFailClosedStop=False"
    assert_contains "RESULT:Reason=PortClosedAfterSend"
}

@test "T4: 送信後disconnect+9224 close→成功・fail-closed非該当(QC-02状態(d)・最重要回帰テスト)" {
    run_ps "
function Test-TcpPortOpen { param(\$HostName,\$Port) return \$true }
function Invoke-PsBridge {
    param(\$PsBridgePath,\$BridgeArgs,\$TimeoutMs=20000)
    if (\$BridgeArgs -contains 'list') {
        \$json = (@(@{ id = 'target-1'; title = 't'; url = 'u'; wsUrl = 'w' }) | ConvertTo-Json -Compress)
        return [PSCustomObject]@{ TimedOut = \$false; ExitCode = 0; StdOut = \$json; StdErr = '' }
    } elseif (\$BridgeArgs -contains 'send') {
        return [PSCustomObject]@{ TimedOut = \$false; ExitCode = 1; StdOut = ''; StdErr = 'connection reset' }
    }
    throw \"unexpected BridgeArgs: \$BridgeArgs\"
}
function Wait-TcpPortState { param(\$HostName,\$Port,\$TimeoutSeconds,\$TargetState) return \$true }
\$result = Invoke-Step0AShutdown -PsBridgePath 'C:\fake\ps-bridge.ps1' -Port 9224
Write-Output \"RESULT:ShutdownOk=\$(\$result.ShutdownOk)\"
Write-Output \"RESULT:RequiresFailClosedStop=\$(\$result.RequiresFailClosedStop)\"
Write-Output \"RESULT:Reason=\$(\$result.Reason)\"
Write-Output 'RESULT:DONE=1'
"
    [ "$status" -eq 0 ]
    assert_done
    assert_contains "RESULT:ShutdownOk=True"
    assert_contains "RESULT:RequiresFailClosedStop=False"
    assert_contains "RESULT:Reason=PortClosedAfterSend"
}

@test "T5: 送信失敗+9224継続→fail-closed停止(QC-02状態(e))" {
    run_ps "
function Test-TcpPortOpen { param(\$HostName,\$Port) return \$true }
function Invoke-PsBridge {
    param(\$PsBridgePath,\$BridgeArgs,\$TimeoutMs=20000)
    if (\$BridgeArgs -contains 'list') {
        \$json = (@(@{ id = 'target-1'; title = 't'; url = 'u'; wsUrl = 'w' }) | ConvertTo-Json -Compress)
        return [PSCustomObject]@{ TimedOut = \$false; ExitCode = 0; StdOut = \$json; StdErr = '' }
    } elseif (\$BridgeArgs -contains 'send') {
        return [PSCustomObject]@{ TimedOut = \$false; ExitCode = 1; StdOut = ''; StdErr = 'connection reset' }
    }
    throw \"unexpected BridgeArgs: \$BridgeArgs\"
}
function Wait-TcpPortState { param(\$HostName,\$Port,\$TimeoutSeconds,\$TargetState) return \$false }
\$result = Invoke-Step0AShutdown -PsBridgePath 'C:\fake\ps-bridge.ps1' -Port 9224
Write-Output \"RESULT:ShutdownOk=\$(\$result.ShutdownOk)\"
Write-Output \"RESULT:RequiresFailClosedStop=\$(\$result.RequiresFailClosedStop)\"
Write-Output \"RESULT:Reason=\$(\$result.Reason)\"
Write-Output 'RESULT:DONE=1'
"
    [ "$status" -eq 0 ]
    assert_done
    assert_contains "RESULT:ShutdownOk=False"
    assert_contains "RESULT:RequiresFailClosedStop=True"
    assert_contains "RESULT:Reason=PortStillOpen"
}

# ============================================================
# T6: 設定/path不備の確定方針(port非listen優先の分岐順序。C712-A-PE-QC-01)
# 設計書は1エントリだが、Pester版同様に3ケース(純粋関数/A/B)へ分けて実装する。
# ============================================================

@test "T6a: Resolve-PsBridgePath -ShogunRootEnvValue '' はnullを返す(純粋関数・mock不要)" {
    run_ps "
\$result = Resolve-PsBridgePath -ShogunRootEnvValue ''
Write-Output \"RESULT:IsNull=\$(\$null -eq \$result)\"
Write-Output 'RESULT:DONE=1'
"
    [ "$status" -eq 0 ]
    assert_done
    assert_contains "RESULT:IsNull=True"
}

@test "T6b: (A)port非listen時はPsBridgePath不備を問わず正常続行しInvoke-PsBridgeを呼ばない" {
    run_ps "
\$script:callCount = 0
function Test-TcpPortOpen { param(\$HostName,\$Port) return \$false }
function Invoke-PsBridge { param(\$PsBridgePath,\$BridgeArgs,\$TimeoutMs=20000) \$script:callCount++; return \$null }
\$result = Invoke-Step0AShutdown -PsBridgePath \$null -Port 9224
Write-Output \"RESULT:ShutdownOk=\$(\$result.ShutdownOk)\"
Write-Output \"RESULT:RequiresFailClosedStop=\$(\$result.RequiresFailClosedStop)\"
Write-Output \"RESULT:Reason=\$(\$result.Reason)\"
Write-Output \"RESULT:InvokePsBridgeCalls=\$script:callCount\"
Write-Output 'RESULT:DONE=1'
"
    [ "$status" -eq 0 ]
    assert_done
    assert_contains "RESULT:ShutdownOk=True"
    assert_contains "RESULT:RequiresFailClosedStop=False"
    assert_contains "RESULT:Reason=PortNotListening"
    assert_contains "RESULT:InvokePsBridgeCalls=0"
}

@test "T6c: (B)port listen時はPsBridgePath不備でfail-closed停止しInvoke-PsBridgeを呼ばない" {
    run_ps "
\$script:callCount = 0
function Test-TcpPortOpen { param(\$HostName,\$Port) return \$true }
function Invoke-PsBridge { param(\$PsBridgePath,\$BridgeArgs,\$TimeoutMs=20000) \$script:callCount++; return \$null }
\$result = Invoke-Step0AShutdown -PsBridgePath \$null -Port 9224
Write-Output \"RESULT:ShutdownOk=\$(\$result.ShutdownOk)\"
Write-Output \"RESULT:RequiresFailClosedStop=\$(\$result.RequiresFailClosedStop)\"
Write-Output \"RESULT:Reason=\$(\$result.Reason)\"
Write-Output \"RESULT:InvokePsBridgeCalls=\$script:callCount\"
Write-Output 'RESULT:DONE=1'
"
    [ "$status" -eq 0 ]
    assert_done
    assert_contains "RESULT:ShutdownOk=False"
    assert_contains "RESULT:RequiresFailClosedStop=True"
    assert_contains "RESULT:Reason=NoPsBridgePath"
    assert_contains "RESULT:InvokePsBridgeCalls=0"
}

# ============================================================
# T8: bridge応答なしタイムアウトの即時再現+no-kill確認(C712-A-R1-QC-01)
# ============================================================

@test "T8: 実プロセス・実待機なしで即時にTimedOut=true,ExitCode=nullを返し、Killを一切呼ばない" {
    run_ps "
\$fakeProcess = [PSCustomObject]@{ HasExited = \$false }
\$fakeHandle = [PSCustomObject]@{
    Process         = \$fakeProcess
    StdOutBuilder   = (New-Object System.Text.StringBuilder)
    StdErrBuilder   = (New-Object System.Text.StringBuilder)
    OutSubscription = \$null
    ErrSubscription = \$null
}
function Start-PsBridgeProcess { param(\$PsBridgePath,\$BridgeArgs) return \$fakeHandle }
function Wait-PsBridgeProcessExit { param(\$Handle,\$TimeoutMs) return \$false }
\$result = Invoke-PsBridge -PsBridgePath 'fake' -BridgeArgs @('-Action','send') -TimeoutMs 20000
Write-Output \"RESULT:TimedOut=\$(\$result.TimedOut)\"
Write-Output \"RESULT:ExitCodeIsNull=\$(\$null -eq \$result.ExitCode)\"
Write-Output 'RESULT:DONE=1'
"
    [ "$status" -eq 0 ]
    assert_done
    assert_contains "RESULT:TimedOut=True"
    assert_contains "RESULT:ExitCodeIsNull=True"
    # $fakeProcessはPSCustomObjectでKill/Disposeメソッドを持たない。実装が
    # .Kill()や無条件Dispose()を呼んでいればメソッド不在で例外になりRESULT:ERROR
    # が出力されexit 1になるため、ここに到達しRESULT:DONE=1が出た時点でKillが
    # 一切呼ばれていないことの間接的だが確実な検知になる(design§3.8 T8と同じ考え方)。
}

# ============================================================
# T9: launch.ps1本体Step 0 bounded regionのclosed-world token fingerprint照合
# (cmd_718: C712-A-R1-QC-02のseam終端。redo2までの「性質検査」matcherを全廃)
# 実行は一切しない。ParseInputによる静的解析のみ。
#
# subtask_717(redo1・redo2)・cmd_718に至るまでの経緯(5世代):
#   1) cmd_712 redo2   : 部分指標の集合(container型チェーン+テキスト部分一致)
#                        → 三重mutant(i)(ii)(iii)が素通り
#   2) cmd_712 postesc : +Exit-Script位置条件               → mutant(A)(B)が素通り
#   3) cmd_717初回     : 正規pairを型で厳密照合              → mutant(X)(Y)が素通り
#   4) cmd_717 redo1   : +周辺をliteral command名countで検査 → mutant(Z)(W)(動的呼出し)が素通り
#   5) cmd_717 redo2   : +top-level 7文と各位置の外殻を型照合 → mutant(K)(L)
#                        (既存Write-Hostの展開式$(...)内部への埋込)が理論上素通りする
#                        (redo2実装をcmd_718で置換したため実測はしていないが、
#                        redo2のPos0Ok/Pos6Ok等は文字列の外殻(単一Write-Host
#                        pipelineであること)のみを見ており、展開式の中身を
#                        一切検査しない設計だったため理屈の上で素通りする)
#
# ★将軍裁定(cmd_718): 5世代とも同じ形で破られた——「コードが性質Pを持つか」を
# 検査するmatcherを書き、Pが精緻になるたび覆われぬ部分が移動しただけである
# (top-levelの隙間→statementの内部→展開式の内部→次は引数の内部)。Pをどれだけ
# 精緻にしても終わらない。★Pという形そのものを廃し、
#   「これまで: コードが性質Pを持つか」→「これから: コードが『これ』と同一か」
# へ転換する。性質を検査する条件は一つも残さない。「動的呼出しdetector」の類も
# 追加しない(将軍により明示的に禁止)。
#
# ## 新方式: closed-world token fingerprint照合
#
# tests/fixtures/cmd_718_step0_canonical.ps1に、Step 0 bounded regionの
# 承認済み正典(canonical source)を独立に固定して持つ。実物(launch.ps1)と
# 正典の両方をGet-Content -Raw -Encoding UTF8 + [Parser]::ParseInputでparseし、
# 両方ともparse error 0であることをfail-closedでassertする(壊れたASTを
# 物差しに使わない。0でなければ以降の照合を一切行わずFAIL)。
#
# 双方についてStep 0 bounded regionのtoken列fingerprint(Kind・TokenFlags・
# Text・順序。trivia=NewLine・Commentは除外)を抽出し、完全一致することのみを
# 見る。「性質」は存在しない——region全体がwhitelistでさえなく、正典という
# 単一の実例そのものである。動的呼出しかliteralか、展開式の内部か引数の内部か
# statementの内部かを一切問わない。期待token列と1つでも異なるtokenがあれば
# (種類・flags・テキストのいずれであれ)、その理由を個別に列挙せずとも
# TokenSequenceMatch=Falseとして機械的に検出される。
#
# ## R-1/R-2: 領域切り出しのfail-closed化
#
# 開始marker'# Step 0: shutdown existing Electron'・終了marker
# '# Step 1: git fetch'が実物・正典それぞれの中でちょうど1回ずつ見つかることを
# 要求する(R-1)。0回でも2回以上でもFAIL——markerを複製してregion境界を
# ずらす攻撃を塞ぐ。判定はraw文字列上のsubstringカウントのみで行い、
# comment token等AST/token側の情報には依存しない(R-2)。実物・正典に
# 同一の抽出関数を対称に適用する(特別扱いをしない)。
#
# ## N-1/N-2/N-3: 正典という新たな攻撃面の保護
#
# 正典そのものが新たな攻撃面になる——正典を書き換えればtoken比較は無力化する。
#   N-1) tests/fixtures/cmd_718_step0_canonical.ps1冒頭に、本ファイルが
#        安全上重要な資産でありproductionと同等の変更検討を要する旨を明記
#        (fixtureファイル自身のヘッダコメントを参照)。
#   N-2) 正典自体にもT7相当(Get-Process/Stop-Process/.Kill(不在)をassertする
#        (CanonHasGetProcess/CanonHasStopProcess/CanonHasKill)。正典が汚染
#        されれば実物との一致比較だけでは汚染を見逃すため、正典側は独立に検証する。
#   N-3) 正典ファイルのSHA256を本ファイル側に定数(EXPECTED_STEP0_CANONICAL_
#        SHA256相当・下記PSBODY内)として別途固定し、実測hashと照合する
#        二段構え(CanonHashMatch)。正典ファイルのみを書き換えてこの定数を
#        同時に更新しなければ、T9はhash不一致で即FAILする。これは「実物と
#        正典を同一改変してlaunderする」攻撃(token比較単体では一致してしまう
#        攻撃)に対する唯一の防御であり、T9-canonical-tamper(B-5)testで実証する。
#
# ## R-3・region拡大(redo1・cmd_718): 「容器で包む」攻撃と「region外での
# 名前再束縛」攻撃への追加防御
#
# 足軽7号の独立QC(subtask_718_phase_ab_qc)がREDO_REQUIREDと判定した。
# 是正前matcher(R-1/R-2のみ)は、markerで挟んだ[start,end)のoffset範囲に
# 入るtokenだけをfingerprint化し、その範囲が「ASTのどこに位置するか」を
# 一切見ていなかった。軍師発見の変異M(functionで包む)は、region内のtoken
# を1つも変えずにregion外に`function 名 {`と`}`を置くだけでT9Verdict=PASSを
# すり抜けた(是正前matcherでの実測: PASS←誤り)。
#
# **R-3**: markerで挟んだ領域が、真のtop-level statement列であることを
# 追加で要求する。`$ast.EndBlock.Statements`のうちextentの開始offsetが
# region内にあるものを集め、region内の非trivia token全件が、その
# statement群のextentに包含されることを要求する(包含されないtokenが
# 1つでもあればFAIL。`$ast.EndBlock`が`$null`の場合もfail-closedでFAIL)。
# ★性質検査Pの再導入ではない——コードが何をするかを一切見ず、R-1と同じ族
# (構造的事実のみを見る)。実物・正典の双方へ対称に適用する。
#
# **region拡大(将軍追加裁定・2026-08-21 16:08)**: 足軽7号のQCで、region外
# (Step 0 marker以前)での名前再束縛攻撃——P1: `Exit-Script`をno-op化、
# P2: `Invoke-Step0AShutdown`を常時成功スタブ化——は、R-3を足しても原理的に
# 検知できないと判明した(実測: TopLevelStmts=7・Covered=58/58のまま素通り。
# 旧regionがそもそもこれらの再定義文を視野に入れていなかったため)。将軍は
# 3択(照合範囲をlaunch.ps1全文へ拡大/性質検査追加/照合範囲をファイル
# 先頭へ拡大)を検討し、3つ目を採用した——全文拡大は「Step 1以降の正当な
# 変更のたびT9が落ち正典が日常的に更新される」ため、性質検査追加は将軍が
# 5世代にわたり禁じた「Pの再導入」そのものであるため、いずれも却下した。
# 方式(closed-world token fingerprint照合)は変えていない。範囲を
# ファイル先頭(top-level statement index 0)〜Step 1 marker直前へ広げた
# だけである。regionのStartはfile offset 0固定になった(旧:
# startMarkerの位置)。startMarkerのちょうど1回チェック自体は維持する
# (このcommentはComment tokenとしてfingerprintから除外されるため、
# token比較単体では複製/削除を検知できず、独立の存在・一意性保証として
# 引き続き意味を持つ)。
#
# ★正直に書き残す限界(将軍指示「保証しないことを書かない検査は読む者に
# 過大な安心を与える」に基づく): region拡大とR-3を組み合わせた結果、
# region.Startがfile offset 0になったことで、変異M/P3(容器で包む攻撃)の
# 「容器を開くtoken」は、旧regionではregion外(=R-1/R-2/token
# fingerprintでは検知不能でR-3のみが検知できた)だったが、拡大後のregion
# では常にregion内に位置することになった。このため実測上、拡大後のregion
# ではM/P3はR-3(CoverageOk)ではなく、既存のR-1/R-2+token fingerprint
# 比較(TokenCountMatch)によって検出される(`TopLevelStmtsReal`は容器を
# 開くfunction/if文自体を1つのtop-level statementとして数えるため、
# `CoverageOkReal`は`True`のまま——容器のextentがregion内の残り全tokenを
# 覆うため)。★本redo1のmutation catalog全件(既存14変異+M/P3/P1/P2)を
# 実測で確認したところ、R-3(CoverageOk=False)が単独の決め手としてFAILに
# 寄与するケースは現時点で1件も無い——いずれもTokenCountMatch=Falseまたは
# TokenSequenceMatch=Falseで先に検出される。それでもR-3を実装・維持する
# のは、(1)将軍がredo1で明示的に指示した是正であること、(2)regionが
# 将来再び狭められた場合(Step 1 marker位置の変更や別の設計判断)に即座に
# 元の防御力(旧matcherでMをすり抜けさせた欠陥への対策)を取り戻す多層防御
# であること、(3)「region内は真にtop-levelか」という構造的事実を独立に
# 保証すること自体に価値があること、の3点による。「R-3のおかげでPASSが
# FAILに変わった」という誤解を招く書き方はしない。
#
# ## T9が保証すること・保証しないこと(将軍指示・必須の明記)
#
# | test | 保証すること |
# |---|---|
# | T9 | ファイル先頭からStep 1 marker直前まで(拡大後の範囲)が正典とtoken同一であること。R-1/R-2でregion境界の複製・移動を、R-3で「region内は真にtop-level」を、N-1〜N-3で正典自体の改竄を防ぐ |
# | T3〜T6・T8 | `Invoke-Step0AShutdown`の振る舞いが正しいこと(常時成功スタブはT6cで落ちる。★実測確認済み——本redo1でlaunch.helpers.ps1の`Invoke-Step0AShutdown`定義の直後に常時成功スタブを追記して上書きし、T6cが期待する`RequiresFailClosedStop=True`の代わりに`RequiresFailClosedStop=False`・`Reason=StubbedAlwaysSuccess`が返ることをpowershell.exeで直接実測した) |
# | T7 | 両ファイルに終了系の危険文字列(Get-Process/Stop-Process/.Kill()が無いこと |
# | T10 | launch.helpers.ps1にtop-level副作用が無いこと |
#
# **T9が保証しないこと(限界)**: `launch.helpers.ps1`側の関数の**中身**の
# 差し替えはT9では捕捉できない。launch.ps1本体からのdot-source*文*自体
# (1行)は拡大後regionに含まれるためtoken比較の対象になるが、dot-source
# 先ファイルである`launch.helpers.ps1`自身の内容はT9のtoken比較対象では
# ない(`$HELPERS_PS1`と`$LAUNCH_PS1`は別ファイルであり、T9は`$LAUNCH_PS1`
# のみをparseする)。この攻撃面はT3〜T6・T8(`Invoke-Step0AShutdown`等の
# 実際の振る舞いを直接検証する)が担う——上表・直上の実測のとおりT6cが
# これを検知する。また、region拡大後も「region外だがStep 1より後」の
# 攻撃面は対象外のまま(将軍裁定により全文拡大は意図的に採らなかった。
# 理由は前述のとおり日常変更による正典陳腐化を避けるため)。
#
# ## fail-closed precondition
#
# $errors.Count(実物)・$errorsCanon.Count(正典)がいずれも0であることを
# 最初に確認する。launch.ps1はBOM無しUTF-8で日本語コメントを含むため、
# 既定Get-ContentやParseFileでは誤検出しうる(将軍実測: token総数535・
# top-level 48・Comment 19・NewLine 135。本ファイルはGet-Content -Raw
# -Encoding UTF8 + [Parser]::ParseInputで一貫して読み、region内token数58を
# 実測確認済み)。
#
# ## mutation catalog
#
# B-1で要求された11変異(三重mutant(i)(ii)(iii)+A+B+X+Y+Z+W+K+L)を恒久
# negative fixtureとして維持・新規追加する。旧世代でfalse greenだった
# G/H/I/J(足軽4号考案)も回帰防止のため引き続き維持する。B-2として
# A+B合成・K+L合成も維持・追加する。B-4として本cmd_718で新たに考案した
# M-arg(引数内部埋込・必須)・M-reduce(statement削減・必須)・
# M-third(順序入替)の3変異を追加する。B-5として正典改竄検知
# (T9-canonical-tamper)を追加する。redo1(cmd_718)でさらに、軍師発見の
# 変異M(functionで包む)・足軽7号考案の変異P3(if ($env:SKIP_STEP0 -ne '1')
# という環境変数バックドアで包む。Mの容器違い)・将軍追加裁定によるP1
# (region外でExit-Scriptをno-op再定義)・P2(region外でInvoke-Step0AShutdown
# を常時成功スタブへ再定義)の4変異を追加する。いずれも同一のt9_check_ps_body
# (DRY)を実行し、最終的にT9Verdict=FAILとなることのみを見る——
# 「どの位置が」「どの型が」という個別診断は行わない(性質検査の再導入を防ぐ)。
# ============================================================

# T9本体の照合ロジック(run_ps_astの第2引数としてそのまま渡す。$src/$tokens/
# $errors/$astはrun_ps_ast側のpreambleで定義済みの実物側の値)。実際のT9
# テストと下記mutant回帰テスト全件で共有する(DRY)。正典側は$__step0CanonicalWin
# から本関数内で独自にGet-Content+ParseInputする。$__step0CanonicalWinは
# run_ps_ast側のpreambleでbash変数$STEP0_CANONICAL_WIN(setup()でexport済み。
# B-5 testでは一時的に上書きされる)をscript文字列へ直接埋め込んで定義する
# (WSL→Windows境界を越えるpowershell.exeプロセスにはWSLENV未登録のbash
# export変数は$env:経由で到達しないため、$env:参照は使わない。将軍実測で
# 判明した落とし穴)。ヘルパー関数はいずれも値を返すのみでWrite-Outputを行わない
# (関数呼出し結果を変数へ代入すると、関数内のWrite-Output出力までその変数へ
# 捕捉されてしまいコンソールに出力されないというPowerShellの仕様を踏まえた設計。
# 診断用のRESULT:行はすべてtop-levelで一括出力する)。
t9_check_ps_body() {
    cat <<'PSBODY'
$hasParseErrorsReal = ($errors.Count -ne 0)

$srcCanon = Get-Content -Raw -Encoding UTF8 -LiteralPath $__step0CanonicalWin
$tokensCanon = $null
$errorsCanon = $null
$astCanon = [System.Management.Automation.Language.Parser]::ParseInput($srcCanon, [ref]$tokensCanon, [ref]$errorsCanon)
$hasParseErrorsCanon = ($errorsCanon.Count -ne 0)
$failClosedParseError = ($hasParseErrorsReal -or $hasParseErrorsCanon)

# fail-closed既定値: 以降のいずれかの検査が実施できなければFalse/不一致の
# ままT9Verdictへ進む(壊れたASTや欠損した正典を物差しに使わない)。
$regionOkReal = $false
$regionOkCanon = $false
$tokenCountMatch = $false
$tokenSequenceMatch = $false
$realTokenCount = -1
$canonTokenCount = -1
$firstMismatchIndex = -1
$canonHasGetProcess = $true
$canonHasStopProcess = $true
$canonHasKill = $true
$canonHashMatch = $false
$endBlockOkReal = $false
$endBlockOkCanon = $false
$topLevelStmtsReal = -1
$topLevelStmtsCanon = -1
$coverageOkReal = $false
$coverageOkCanon = $false

# N-3: 正典ファイルの承認済みSHA256(cmd_718策定時点でsha256sum実測・本テスト
# ファイル側に固定)。正典ファイルのみを書き換えてこの定数を同時に更新しなければ、
# 以降のtoken比較結果に関わらずT9はここでFAILする(正典改竄によるtest無力化への対抗)。
$expectedCanonicalHash = 'BFC200DB532F668AAF95FE07C46A7BC4B93FFC944DECA280C784B04A11A5D62D'

$startMarker = '# Step 0: shutdown existing Electron'
$endMarker = '# Step 1: git fetch'

# R-1: 開始・終了markerがそれぞれちょうど1回見つかることを要求する(0回でも
# 2回以上でもFAIL。markerを複製してregion境界をずらす攻撃を塞ぐ)。R-2:
# 判定はraw文字列上のsubstringカウントのみで行い、comment token等AST/token側
# の情報には依存しない。実物・正典に同一の関数を対称に適用する。
#
# ★redo1(cmd_718)での範囲拡大: regionのStartはもはやstartMarkerの位置では
# なくファイル先頭(offset 0)固定である。region外(Step 0 marker以前)での
# `Exit-Script`/`Invoke-Step0AShutdown`再定義による名前再束縛攻撃(P1/P2)は、
# 旧region(Step 0 marker〜Step 1 marker)の外側で起きるためR-3を足しても
# 原理的に検知できないと判明した(将軍実測)。将軍裁定により対象範囲を
# ファイル先頭まで拡大した——方式(closed-world token fingerprint照合)は
# 変えていない。startMarkerのちょうど1回チェック自体は、境界計算には
# もう使わないが、このcomment(Comment tokenとしてfingerprintから除外される
# ため token比較単体では複製/削除を検知できない)の存在・一意性を独立に
# 保証する意味を持つため維持する。
function Get-BoundedRegion($src) {
    $startCount = ([regex]::Matches($src, [regex]::Escape($startMarker))).Count
    $endCount = ([regex]::Matches($src, [regex]::Escape($endMarker))).Count
    if ($startCount -ne 1 -or $endCount -ne 1) { return $null }
    $s1 = $src.IndexOf($endMarker)
    if ($s1 -le 0) { return $null }
    return [PSCustomObject]@{ Start = 0; End = $s1 }
}

# R-3(redo1・cmd_718で追加): markerで挟んだ領域が真のtop-level statement列で
# あることを追加で要求する。★性質検査Pの再導入ではない——コードが何をするか
# を一切見ず、R-1と同じ族(構造的事実のみを見る)。$ast.EndBlockが$nullの
# 場合もfail-closedでFAILとする。
function Get-TopLevelStatementsInRegion($astValue, $region) {
    if ($null -eq $astValue.EndBlock) { return $null }
    $stmts = @($astValue.EndBlock.Statements | Where-Object {
        $_.Extent.StartOffset -ge $region.Start -and $_.Extent.StartOffset -lt $region.End
    })
    return ,$stmts
}

# region内の非trivia token(NewLine・Commentを除く。Get-RegionTokenFingerprint
# と同じtrivia定義)全件が、渡されたstatement群いずれかのextentに包含される
# ことを要求する。包含されないtokenが1つでもあれば$false(fail-closed)。
function Test-RegionTokensCoveredByStatements($tokens, $region, $stmts) {
    if ($null -eq $stmts) { return $false }
    foreach ($t in $tokens) {
        if ($t.Extent.StartOffset -lt $region.Start -or $t.Extent.StartOffset -ge $region.End) { continue }
        if ($t.Kind -eq [System.Management.Automation.Language.TokenKind]::NewLine) { continue }
        if ($t.Kind -eq [System.Management.Automation.Language.TokenKind]::Comment) { continue }
        $covered = $false
        foreach ($s in $stmts) {
            if ($t.Extent.StartOffset -ge $s.Extent.StartOffset -and $t.Extent.EndOffset -le $s.Extent.EndOffset) {
                $covered = $true
                break
            }
        }
        if (-not $covered) { return $false }
    }
    return $true
}

# region境界内(trivia=NewLine・Commentを除く)のtokenを「Kind|TokenFlags|Text」
# の順序付き配列として返す。性質を判定する条件は一切無い——tokenそのものの
# 複製にすぎない(「これと同一か」の「これ」を構成する材料)。
function Get-RegionTokenFingerprint($tokens, $region) {
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($t in $tokens) {
        if ($t.Extent.StartOffset -lt $region.Start -or $t.Extent.StartOffset -ge $region.End) { continue }
        if ($t.Kind -eq [System.Management.Automation.Language.TokenKind]::NewLine) { continue }
        if ($t.Kind -eq [System.Management.Automation.Language.TokenKind]::Comment) { continue }
        [void]$list.Add("$($t.Kind)|$($t.TokenFlags)|$($t.Text)")
    }
    return ,$list.ToArray()
}

if (-not $failClosedParseError) {
    $regionReal = Get-BoundedRegion $src
    $regionCanon = Get-BoundedRegion $srcCanon
    $regionOkReal = ($null -ne $regionReal)
    $regionOkCanon = ($null -ne $regionCanon)

    if ($regionOkReal -and $regionOkCanon) {
        $fpReal = Get-RegionTokenFingerprint $tokens $regionReal
        $fpCanon = Get-RegionTokenFingerprint $tokensCanon $regionCanon
        $realTokenCount = $fpReal.Count
        $canonTokenCount = $fpCanon.Count
        $tokenCountMatch = ($realTokenCount -eq $canonTokenCount)
        if ($tokenCountMatch) {
            $mismatch = $false
            for ($i = 0; $i -lt $fpReal.Count; $i++) {
                if ($fpReal[$i] -cne $fpCanon[$i]) {
                    $mismatch = $true
                    if ($firstMismatchIndex -lt 0) { $firstMismatchIndex = $i }
                }
            }
            $tokenSequenceMatch = (-not $mismatch)
        }

        # R-3: region内の非trivia token全件が、regionで開始するtop-level
        # statementのextentに包含されることを要求する(実物・正典に対称適用)。
        $stmtsReal = Get-TopLevelStatementsInRegion $ast $regionReal
        $endBlockOkReal = ($null -ne $ast.EndBlock)
        $topLevelStmtsReal = if ($null -ne $stmtsReal) { $stmtsReal.Count } else { 0 }
        $coverageOkReal = Test-RegionTokensCoveredByStatements $tokens $regionReal $stmtsReal

        $stmtsCanon = Get-TopLevelStatementsInRegion $astCanon $regionCanon
        $endBlockOkCanon = ($null -ne $astCanon.EndBlock)
        $topLevelStmtsCanon = if ($null -ne $stmtsCanon) { $stmtsCanon.Count } else { 0 }
        $coverageOkCanon = Test-RegionTokensCoveredByStatements $tokensCanon $regionCanon $stmtsCanon
    }

    # N-2: 正典自体にT7相当(危険command不在)をassertする。実物との一致比較
    # だけでは正典自身の汚染を見逃すため、正典側は独立に検証する。
    $canonHasGetProcess = [bool]($srcCanon -match 'Get-Process')
    $canonHasStopProcess = [bool]($srcCanon -match 'Stop-Process')
    $canonHasKill = [bool]($srcCanon -match '\.Kill\(')

    # N-3: 正典ファイルの実測hashをtest側定数と照合する。
    $canonHashActual = (Get-FileHash -LiteralPath $__step0CanonicalWin -Algorithm SHA256).Hash
    $canonHashMatch = ($canonHashActual -ceq $expectedCanonicalHash)
}

Write-Output "RESULT:ParseErrorsReal=$($errors.Count)"
Write-Output "RESULT:ParseErrorsCanon=$($errorsCanon.Count)"
Write-Output "RESULT:FailClosedParseError=$failClosedParseError"
Write-Output "RESULT:RegionExtractionOkReal=$regionOkReal"
Write-Output "RESULT:RegionExtractionOkCanon=$regionOkCanon"
Write-Output "RESULT:RealTokenCount=$realTokenCount"
Write-Output "RESULT:CanonTokenCount=$canonTokenCount"
Write-Output "RESULT:TokenCountMatch=$tokenCountMatch"
Write-Output "RESULT:TokenSequenceMatch=$tokenSequenceMatch"
Write-Output "RESULT:FirstMismatchIndex=$firstMismatchIndex"
Write-Output "RESULT:CanonHasGetProcess=$canonHasGetProcess"
Write-Output "RESULT:CanonHasStopProcess=$canonHasStopProcess"
Write-Output "RESULT:CanonHasKill=$canonHasKill"
Write-Output "RESULT:CanonHashMatch=$canonHashMatch"
Write-Output "RESULT:EndBlockOkReal=$endBlockOkReal"
Write-Output "RESULT:EndBlockOkCanon=$endBlockOkCanon"
Write-Output "RESULT:TopLevelStmtsReal=$topLevelStmtsReal"
Write-Output "RESULT:TopLevelStmtsCanon=$topLevelStmtsCanon"
Write-Output "RESULT:CoverageOkReal=$coverageOkReal"
Write-Output "RESULT:CoverageOkCanon=$coverageOkCanon"

$overallOk = (-not $failClosedParseError) -and $regionOkReal -and $regionOkCanon -and $tokenCountMatch -and $tokenSequenceMatch -and (-not $canonHasGetProcess) -and (-not $canonHasStopProcess) -and (-not $canonHasKill) -and $canonHashMatch -and $endBlockOkReal -and $endBlockOkCanon -and $coverageOkReal -and $coverageOkCanon
Write-Output "RESULT:T9Verdict=$(if ($overallOk) { 'PASS' } else { 'FAIL' })"

Write-Output 'RESULT:DONE=1'
PSBODY
}

@test "T9: launch.ps1本体Step 0 bounded regionのclosed-world token fingerprint照合(cmd_718: 正典との同一性のみを見る。性質検査は一切行わない。B-3)" {
    run_ps_ast "$LAUNCH_WIN" "$(t9_check_ps_body)"
    [ "$status" -eq 0 ]
    assert_done
    assert_contains "RESULT:ParseErrorsReal=0"
    assert_contains "RESULT:ParseErrorsCanon=0"
    assert_contains "RESULT:FailClosedParseError=False"
    assert_contains "RESULT:RegionExtractionOkReal=True"
    assert_contains "RESULT:RegionExtractionOkCanon=True"
    assert_contains "RESULT:RealTokenCount=182"
    assert_contains "RESULT:CanonTokenCount=182"
    assert_contains "RESULT:TokenCountMatch=True"
    assert_contains "RESULT:TokenSequenceMatch=True"
    assert_contains "RESULT:CanonHasGetProcess=False"
    assert_contains "RESULT:CanonHasStopProcess=False"
    assert_contains "RESULT:CanonHasKill=False"
    assert_contains "RESULT:CanonHashMatch=True"
    assert_contains "RESULT:EndBlockOkReal=True"
    assert_contains "RESULT:EndBlockOkCanon=True"
    assert_contains "RESULT:TopLevelStmtsReal=23"
    assert_contains "RESULT:TopLevelStmtsCanon=23"
    assert_contains "RESULT:CoverageOkReal=True"
    assert_contains "RESULT:CoverageOkCanon=True"
    assert_contains "RESULT:T9Verdict=PASS"
}

# ============================================================
# T9-mutant(i)/(ii)/(iii): 軍師発見の三重mutant(subtask_712_phase_c_redo2_qc)を
# 恒久negative fixtureとして継続する(B-1)。cmd_718の新matcher(closed-world
# token fingerprint)でも引き続き単独でFAILすることを示す。判定はいずれも
# 「region内のtoken列が正典と一致しない」という単一の仕組みによる
# (TokenCountMatch/TokenSequenceMatchいずれかがFalseになる)。
# ============================================================

@test "T9-mutant(i): Invoke-Step0AShutdown呼出しをtop-level if内へ埋め込むとTokenCountMatchが崩れ検出される" {
    local mutant_dir
    mutant_dir="$(mktemp -d)"
    cp "$LAUNCH_PS1" "$mutant_dir/launch.ps1"
    sed -i '/Invoke-Step0AShutdown -PsBridgePath/i if ($true) {' "$mutant_dir/launch.ps1"
    sed -i '/Invoke-Step0AShutdown -PsBridgePath/a }' "$mutant_dir/launch.ps1"
    local mutant_win
    mutant_win="$(wslpath -w "$mutant_dir/launch.ps1")"
    run_ps_ast "$mutant_win" "$(t9_check_ps_body)"
    rm -rf -- "${mutant_dir:?}"
    [ "$status" -eq 0 ]
    assert_done
    assert_contains "RESULT:TokenCountMatch=False"
    assert_contains "RESULT:TokenSequenceMatch=False"
    assert_contains "RESULT:T9Verdict=FAIL"
}

@test "T9-mutant(ii): Reason比較の対象文字列を改変するとTokenCountMatchは変わらずTokenSequenceMatchが崩れ検出される" {
    local mutant_dir
    mutant_dir="$(mktemp -d)"
    cp "$LAUNCH_PS1" "$mutant_dir/launch.ps1"
    sed -i 's/\$step0aResult\.Reason -eq "NoPsBridgePath"/$step0aResult.NotReason -eq "DefinitelyNotNoPsBridgePathSuffix"/' "$mutant_dir/launch.ps1"
    local mutant_win
    mutant_win="$(wslpath -w "$mutant_dir/launch.ps1")"
    run_ps_ast "$mutant_win" "$(t9_check_ps_body)"
    rm -rf -- "${mutant_dir:?}"
    [ "$status" -eq 0 ]
    assert_done
    assert_contains "RESULT:TokenCountMatch=True"
    assert_contains "RESULT:TokenSequenceMatch=False"
    assert_contains "RESULT:T9Verdict=FAIL"
}

@test "T9-mutant(iii): 外側guardのfalse経路へExit-Script 9を追加するとTokenCountMatchが崩れ検出される" {
    local mutant_dir
    mutant_dir="$(mktemp -d)"
    cp "$LAUNCH_PS1" "$mutant_dir/launch.ps1"
    local exit4_line outer_close_line
    exit4_line="$(grep -n 'Exit-Script 4' "$mutant_dir/launch.ps1" | head -1 | cut -d: -f1)"
    [ -n "$exit4_line" ]
    outer_close_line=$((exit4_line + 2))
    sed -i "${outer_close_line}s/^}\$/} else {\n    Exit-Script 9\n}/" "$mutant_dir/launch.ps1"
    local mutant_win
    mutant_win="$(wslpath -w "$mutant_dir/launch.ps1")"
    run_ps_ast "$mutant_win" "$(t9_check_ps_body)"
    rm -rf -- "${mutant_dir:?}"
    [ "$status" -eq 0 ]
    assert_done
    assert_contains "RESULT:TokenCountMatch=False"
    assert_contains "RESULT:TokenSequenceMatch=False"
    assert_contains "RESULT:T9Verdict=FAIL"
}

# ============================================================
# T9-mutant(A)/(B)/(A+B): postescalation_closeで将軍が発見した二重mutant
# (旧matcherをすり抜けてPASSした実績あり)を恒久negative fixtureとして
# 維持する(B-1・B-2)。cmd_718の新matcherでも引き続き検出することを示す。
# ============================================================

@test "T9-mutant(A): Invoke-Step0AShutdown呼出しをtop-level ifのcondition式へ埋め込む(代入文が消える)とTokenCountMatchが崩れ検出される" {
    local mutant_dir
    mutant_dir="$(mktemp -d)"
    cp "$LAUNCH_PS1" "$mutant_dir/launch.ps1"
    python3 - "$mutant_dir/launch.ps1" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    text = f.read()
old = '''$step0aResult = Invoke-Step0AShutdown -PsBridgePath $psBridge -Port $winPort

if ($step0aResult.RequiresFailClosedStop) {'''
new = '''if (($step0aResult = Invoke-Step0AShutdown -PsBridgePath $psBridge -Port $winPort).RequiresFailClosedStop) {'''
assert old in text, "T9-mutant(A) fixture: expected block not found"
text = text.replace(old, new, 1)
with open(path, "w", encoding="utf-8") as f:
    f.write(text)
PYEOF
    local mutant_win
    mutant_win="$(wslpath -w "$mutant_dir/launch.ps1")"
    run_ps_ast "$mutant_win" "$(t9_check_ps_body)"
    rm -rf -- "${mutant_dir:?}"
    [ "$status" -eq 0 ]
    assert_done
    assert_contains "RESULT:TokenCountMatch=False"
    assert_contains "RESULT:TokenSequenceMatch=False"
    assert_contains "RESULT:T9Verdict=FAIL"
}

@test "T9-mutant(B): outer guardを-not RequiresFailClosedStopへ極性反転するとTokenCountMatchが崩れ検出される" {
    local mutant_dir
    mutant_dir="$(mktemp -d)"
    cp "$LAUNCH_PS1" "$mutant_dir/launch.ps1"
    python3 - "$mutant_dir/launch.ps1" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    text = f.read()
old = '''if ($step0aResult.RequiresFailClosedStop) {
    if ($step0aResult.Reason -eq "NoPsBridgePath") {'''
new = '''if (-not $step0aResult.RequiresFailClosedStop) {
    # mutant B: 極性反転。falseのときは何もせずStep1へ通過する(元then節相当は空)
} else {
    if ($step0aResult.Reason -eq "NoPsBridgePath") {'''
assert old in text, "T9-mutant(B) fixture: expected block not found"
text = text.replace(old, new, 1)
with open(path, "w", encoding="utf-8") as f:
    f.write(text)
PYEOF
    local mutant_win
    mutant_win="$(wslpath -w "$mutant_dir/launch.ps1")"
    run_ps_ast "$mutant_win" "$(t9_check_ps_body)"
    rm -rf -- "${mutant_dir:?}"
    [ "$status" -eq 0 ]
    assert_done
    assert_contains "RESULT:TokenCountMatch=False"
    assert_contains "RESULT:TokenSequenceMatch=False"
    assert_contains "RESULT:T9Verdict=FAIL"
}

@test "T9-mutant(A+B合成・B-2): condition式埋め込み+極性反転を同時適用してもTokenCountMatchが崩れ検出される(単独で落ちても合成で通る例への回帰防止)" {
    local mutant_dir
    mutant_dir="$(mktemp -d)"
    cp "$LAUNCH_PS1" "$mutant_dir/launch.ps1"
    python3 - "$mutant_dir/launch.ps1" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    text = f.read()
old = '''$step0aResult = Invoke-Step0AShutdown -PsBridgePath $psBridge -Port $winPort

if ($step0aResult.RequiresFailClosedStop) {
    if ($step0aResult.Reason -eq "NoPsBridgePath") {'''
new = '''if (-not ($step0aResult = Invoke-Step0AShutdown -PsBridgePath $psBridge -Port $winPort).RequiresFailClosedStop) {
    # mutant A+B合成: 呼出しをcondition式に埋め込み、かつ極性反転
} else {
    if ($step0aResult.Reason -eq "NoPsBridgePath") {'''
assert old in text, "T9-mutant(A+B) fixture: expected block not found"
text = text.replace(old, new, 1)
with open(path, "w", encoding="utf-8") as f:
    f.write(text)
PYEOF
    local mutant_win
    mutant_win="$(wslpath -w "$mutant_dir/launch.ps1")"
    run_ps_ast "$mutant_win" "$(t9_check_ps_body)"
    rm -rf -- "${mutant_dir:?}"
    [ "$status" -eq 0 ]
    assert_done
    assert_contains "RESULT:TokenCountMatch=False"
    assert_contains "RESULT:TokenSequenceMatch=False"
    assert_contains "RESULT:T9Verdict=FAIL"
}

# ============================================================
# T9-mutant(G)/(H): 足軽4号がsubtask_717実装過程で新規考案したmutant。初回
# matcher(default-allow)へ実際に通し見逃すことを実測確認済み(初回matcher
# のソース自体はredo1で置換済み)。cmd_718の新matcherがこの2件を落とすことを
# 継続的に保証する(回帰防止)。
# ============================================================

@test "T9-mutant(G・足軽4号考案): 呼出しを無関係なダミーtop-level if文のcondition式へこっそり埋め込むとTokenCountMatchが崩れ検出される" {
    local mutant_dir
    mutant_dir="$(mktemp -d)"
    cp "$LAUNCH_PS1" "$mutant_dir/launch.ps1"
    python3 - "$mutant_dir/launch.ps1" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    text = f.read()
old = '''$step0aResult = Invoke-Step0AShutdown -PsBridgePath $psBridge -Port $winPort

if ($step0aResult.RequiresFailClosedStop) {'''
new = '''if (($step0aResult = Invoke-Step0AShutdown -PsBridgePath $psBridge -Port $winPort).ShutdownOk -or $true) {
    Write-Host "dummy no-op wrapper"
}

if ($step0aResult.RequiresFailClosedStop) {'''
assert old in text, "T9-mutant(G) fixture: expected block not found"
text = text.replace(old, new, 1)
with open(path, "w", encoding="utf-8") as f:
    f.write(text)
PYEOF
    local mutant_win
    mutant_win="$(wslpath -w "$mutant_dir/launch.ps1")"
    run_ps_ast "$mutant_win" "$(t9_check_ps_body)"
    rm -rf -- "${mutant_dir:?}"
    [ "$status" -eq 0 ]
    assert_done
    assert_contains "RESULT:TokenCountMatch=False"
    assert_contains "RESULT:TokenSequenceMatch=False"
    assert_contains "RESULT:T9Verdict=FAIL"
}

@test "T9-mutant(H・足軽4号考案): outer ifへelseif抜け道を追加しfalse経路でExit-Script 9を呼ぶとTokenCountMatchが崩れ検出される" {
    local mutant_dir
    mutant_dir="$(mktemp -d)"
    cp "$LAUNCH_PS1" "$mutant_dir/launch.ps1"
    python3 - "$mutant_dir/launch.ps1" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    text = f.read()
old = '''        Exit-Script 4   # 前回インスタンス終了不能によるfail-closed停止(NoPsBridgePathのExit-Script 3とは別コード)
    }
}'''
new = '''        Exit-Script 4   # 前回インスタンス終了不能によるfail-closed停止(NoPsBridgePathのExit-Script 3とは別コード)
    }
} elseif ($true) {
    # mutant H: false経路をelseifの抜け道で塞ぎ、ElseClauseベースのチェックを回避する
    Exit-Script 9
}'''
assert old in text, "T9-mutant(H) fixture: expected block not found"
text = text.replace(old, new, 1)
with open(path, "w", encoding="utf-8") as f:
    f.write(text)
PYEOF
    local mutant_win
    mutant_win="$(wslpath -w "$mutant_dir/launch.ps1")"
    run_ps_ast "$mutant_win" "$(t9_check_ps_body)"
    rm -rf -- "${mutant_dir:?}"
    [ "$status" -eq 0 ]
    assert_done
    assert_contains "RESULT:TokenCountMatch=False"
    assert_contains "RESULT:TokenSequenceMatch=False"
    assert_contains "RESULT:T9Verdict=FAIL"
}

# ============================================================
# T9-mutant(X)/(Y): 軍師発見の二重mutant(subtask_717_phase_ab_t9_rewrite_qc)を
# 恒久negative fixtureとして維持する(B-1)。
# T9-mutant(Z)/(W): redo1 QCで軍師が発見した動的呼出し系の二重mutant
# (false green実績あり)を恒久negative fixtureとして維持する(B-1)。
#
# X/Y/Z/WはいずれもbotStep 0 bounded region内へ余分なtop-level statementを
# 追加する変異である。呼出しがliteralであるか(X・Y)Get-Command/変数経由の
# 動的解決であるか(Z・W)を、新matcherは一切区別しない——region内のtoken数
# そのものが正典と一致しなくなるという単一の仕組みで、いずれも同じく検出する。
# ============================================================

@test "T9-mutant(X・軍師発見): outer guard閉じ括弧直後・Step1手前へtop-level Exit-Script 9を追加するとTokenCountMatchが崩れ検出される" {
    local mutant_dir
    mutant_dir="$(mktemp -d)"
    cp "$LAUNCH_PS1" "$mutant_dir/launch.ps1"
    python3 - "$mutant_dir/launch.ps1" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    text = f.read()
old = '''}

# ここに到達するのは $step0aResult.ShutdownOk -eq $true の場合のみ(§3.3.1の(i))。'''
new = '''}
Exit-Script 9

# ここに到達するのは $step0aResult.ShutdownOk -eq $true の場合のみ(§3.3.1の(i))。'''
assert old in text, "T9-mutant(X) fixture: expected block not found"
assert text.count(old) == 1, "T9-mutant(X) fixture: expected block not unique"
text = text.replace(old, new, 1)
with open(path, "w", encoding="utf-8") as f:
    f.write(text)
PYEOF
    local mutant_win
    mutant_win="$(wslpath -w "$mutant_dir/launch.ps1")"
    run_ps_ast "$mutant_win" "$(t9_check_ps_body)"
    rm -rf -- "${mutant_dir:?}"
    [ "$status" -eq 0 ]
    assert_done
    assert_contains "RESULT:TokenCountMatch=False"
    assert_contains "RESULT:TokenSequenceMatch=False"
    assert_contains "RESULT:T9Verdict=FAIL"
}

@test "T9-mutant(Y・軍師発見): 同位置へ二つ目のInvoke-Step0AShutdownと極性反転guard+Exit-Script 9を追加するとTokenCountMatchが崩れ検出される" {
    local mutant_dir
    mutant_dir="$(mktemp -d)"
    cp "$LAUNCH_PS1" "$mutant_dir/launch.ps1"
    python3 - "$mutant_dir/launch.ps1" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    text = f.read()
old = '''}

# ここに到達するのは $step0aResult.ShutdownOk -eq $true の場合のみ(§3.3.1の(i))。'''
new = '''}
$step0aResultDup = Invoke-Step0AShutdown -PsBridgePath $psBridge -Port $winPort
if (-not $step0aResultDup.RequiresFailClosedStop) { Exit-Script 9 }

# ここに到達するのは $step0aResult.ShutdownOk -eq $true の場合のみ(§3.3.1の(i))。'''
assert old in text, "T9-mutant(Y) fixture: expected block not found"
assert text.count(old) == 1, "T9-mutant(Y) fixture: expected block not unique"
text = text.replace(old, new, 1)
with open(path, "w", encoding="utf-8") as f:
    f.write(text)
PYEOF
    local mutant_win
    mutant_win="$(wslpath -w "$mutant_dir/launch.ps1")"
    run_ps_ast "$mutant_win" "$(t9_check_ps_body)"
    rm -rf -- "${mutant_dir:?}"
    [ "$status" -eq 0 ]
    assert_done
    assert_contains "RESULT:TokenCountMatch=False"
    assert_contains "RESULT:TokenSequenceMatch=False"
    assert_contains "RESULT:T9Verdict=FAIL"
}

@test "T9-mutant(Z・軍師発見・redo1 QCでfalse green実績): Get-Command動的解決経由でExit-Script 9を追加するとTokenCountMatchが崩れ検出される(literal名一致countには非依存)" {
    local mutant_dir
    mutant_dir="$(mktemp -d)"
    cp "$LAUNCH_PS1" "$mutant_dir/launch.ps1"
    python3 - "$mutant_dir/launch.ps1" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    text = f.read()
old = '''}

# ここに到達するのは $step0aResult.ShutdownOk -eq $true の場合のみ(§3.3.1の(i))。'''
new = '''}
& (Get-Command ('Exit-' + 'Script')) 9

# ここに到達するのは $step0aResult.ShutdownOk -eq $true の場合のみ(§3.3.1の(i))。'''
assert old in text, "T9-mutant(Z) fixture: expected block not found"
assert text.count(old) == 1, "T9-mutant(Z) fixture: expected block not unique"
text = text.replace(old, new, 1)
with open(path, "w", encoding="utf-8") as f:
    f.write(text)
PYEOF
    local mutant_win
    mutant_win="$(wslpath -w "$mutant_dir/launch.ps1")"
    run_ps_ast "$mutant_win" "$(t9_check_ps_body)"
    rm -rf -- "${mutant_dir:?}"
    [ "$status" -eq 0 ]
    assert_done
    assert_contains "RESULT:TokenCountMatch=False"
    assert_contains "RESULT:TokenSequenceMatch=False"
    assert_contains "RESULT:T9Verdict=FAIL"
}

@test "T9-mutant(W・軍師発見・redo1 QCでfalse green実績): 変数経由の動的call operatorで二つ目のInvoke-Step0AShutdownを追加するとTokenCountMatchが崩れ検出される(一意呼出し名countには非依存)" {
    local mutant_dir
    mutant_dir="$(mktemp -d)"
    cp "$LAUNCH_PS1" "$mutant_dir/launch.ps1"
    python3 - "$mutant_dir/launch.ps1" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    text = f.read()
old = '''}

# ここに到達するのは $step0aResult.ShutdownOk -eq $true の場合のみ(§3.3.1の(i))。'''
new = '''}
$qcShutdownCommand = 'Invoke-' + 'Step0AShutdown'
$qcDuplicateResult = & $qcShutdownCommand -PsBridgePath $psBridge -Port $winPort

# ここに到達するのは $step0aResult.ShutdownOk -eq $true の場合のみ(§3.3.1の(i))。'''
assert old in text, "T9-mutant(W) fixture: expected block not found"
assert text.count(old) == 1, "T9-mutant(W) fixture: expected block not unique"
text = text.replace(old, new, 1)
with open(path, "w", encoding="utf-8") as f:
    f.write(text)
PYEOF
    local mutant_win
    mutant_win="$(wslpath -w "$mutant_dir/launch.ps1")"
    run_ps_ast "$mutant_win" "$(t9_check_ps_body)"
    rm -rf -- "${mutant_dir:?}"
    [ "$status" -eq 0 ]
    assert_done
    assert_contains "RESULT:TokenCountMatch=False"
    assert_contains "RESULT:TokenSequenceMatch=False"
    assert_contains "RESULT:T9Verdict=FAIL"
}

# ============================================================
# T9-mutant(I)/(J): 足軽4号がsubtask_717 redo2で新規考案したmutant。
# 「呼出し名と一切無関係な統計statementの追加」(I)と「既存statementの削除」
# (J)という異なる2方向を考案し、いずれも同じ仕組みで必然的に落ちることを
# 示す(回帰防止)。
# ============================================================

@test "T9-mutant(I・足軽4号考案・追加型): Invoke-Step0AShutdown/Exit-Scriptと一切無関係なGet-Date呼出しを追加してもTokenCountMatchが崩れ検出される" {
    local mutant_dir
    mutant_dir="$(mktemp -d)"
    cp "$LAUNCH_PS1" "$mutant_dir/launch.ps1"
    python3 - "$mutant_dir/launch.ps1" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    text = f.read()
old = '''$psBridge = Resolve-PsBridgePath -ShogunRootEnvValue $env:SHOGUN_REPO_WIN_ROOT
$step0aResult = Invoke-Step0AShutdown -PsBridgePath $psBridge -Port $winPort'''
new = '''$psBridge = Resolve-PsBridgePath -ShogunRootEnvValue $env:SHOGUN_REPO_WIN_ROOT
Get-Date | Out-Null
$step0aResult = Invoke-Step0AShutdown -PsBridgePath $psBridge -Port $winPort'''
assert old in text, "T9-mutant(I) fixture: expected block not found"
assert text.count(old) == 1, "T9-mutant(I) fixture: expected block not unique"
text = text.replace(old, new, 1)
with open(path, "w", encoding="utf-8") as f:
    f.write(text)
PYEOF
    local mutant_win
    mutant_win="$(wslpath -w "$mutant_dir/launch.ps1")"
    run_ps_ast "$mutant_win" "$(t9_check_ps_body)"
    rm -rf -- "${mutant_dir:?}"
    [ "$status" -eq 0 ]
    assert_done
    assert_contains "RESULT:TokenCountMatch=False"
    assert_contains "RESULT:TokenSequenceMatch=False"
    assert_contains "RESULT:T9Verdict=FAIL"
}

@test "T9-mutant(J・足軽4号考案・削除型): \$psBridge代入statementを削除してもTokenCountMatchが崩れ検出される" {
    local mutant_dir
    mutant_dir="$(mktemp -d)"
    cp "$LAUNCH_PS1" "$mutant_dir/launch.ps1"
    python3 - "$mutant_dir/launch.ps1" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    text = f.read()
old = '''$psBridge = Resolve-PsBridgePath -ShogunRootEnvValue $env:SHOGUN_REPO_WIN_ROOT
$step0aResult = Invoke-Step0AShutdown -PsBridgePath $psBridge -Port $winPort'''
new = '''$step0aResult = Invoke-Step0AShutdown -PsBridgePath $psBridge -Port $winPort'''
assert old in text, "T9-mutant(J) fixture: expected block not found"
assert text.count(old) == 1, "T9-mutant(J) fixture: expected block not unique"
text = text.replace(old, new, 1)
with open(path, "w", encoding="utf-8") as f:
    f.write(text)
PYEOF
    local mutant_win
    mutant_win="$(wslpath -w "$mutant_dir/launch.ps1")"
    run_ps_ast "$mutant_win" "$(t9_check_ps_body)"
    rm -rf -- "${mutant_dir:?}"
    [ "$status" -eq 0 ]
    assert_done
    assert_contains "RESULT:TokenCountMatch=False"
    assert_contains "RESULT:TokenSequenceMatch=False"
    assert_contains "RESULT:T9Verdict=FAIL"
}

# ============================================================
# T9-mutant(K)/(L)/(K+L合成): cmd_718新規追加(B-1で明示的に要求された最後の
# 2変異)。redo2までのmatcherは「statementの外殻(型・個数・位置)」のみを
# 見ており、Write-Host文字列の展開式$(...)の中身を一切検査していなかった。
# K・Lは既存のWrite-Host文そのものは変えず、その展開式の内部にのみ副作用文を
# 埋め込む——旧matcherのPos0Ok/Pos6Ok的な「単一Write-Host pipelineである
# こと」だけを見る検査は、これを理論上素通りさせる。
#
# closed-world token fingerprintがこれを塞ぐ理由: PowerShellの展開可能文字列
# ("...$(...)..."`)はtokenizer上1個のStringExpandable token(Text=ソース片
# そのもの)として扱われる(将軍実測・本ファイル内で機械確認済み)。展開式の
# 内部に文を追加すればこのtoken 1個のTextがソース片ごと変化し、
# Kind|TokenFlags|Textの組が正典と一致しなくなる。ネストしたtokenを個別に
# 辿る必要はない——外側token自身のTextが変化の全体を包含するため、token数
# (TokenCountMatch)は変わらずとも内容(TokenSequenceMatch)で必ず検出される。
# ============================================================

@test "T9-mutant(K・cmd_718新規): 既存Write-Host「[Step 0]」見出しの展開式\$(Get-Ts)内部へ埋め込むとTokenCountMatchは変わらずTokenSequenceMatchが崩れ検出される" {
    local mutant_dir
    mutant_dir="$(mktemp -d)"
    cp "$LAUNCH_PS1" "$mutant_dir/launch.ps1"
    python3 - "$mutant_dir/launch.ps1" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    text = f.read()
old = 'Write-Host "[$(Get-Ts)] [Step 0] Shutting down Electron..."'
new = "Write-Host \"[$(Get-Ts; Write-Host 'K-leak')] [Step 0] Shutting down Electron...\""
assert text.count(old) == 1, "T9-mutant(K) fixture: expected line not found"
text = text.replace(old, new, 1)
with open(path, "w", encoding="utf-8") as f:
    f.write(text)
PYEOF
    local mutant_win
    mutant_win="$(wslpath -w "$mutant_dir/launch.ps1")"
    run_ps_ast "$mutant_win" "$(t9_check_ps_body)"
    rm -rf -- "${mutant_dir:?}"
    [ "$status" -eq 0 ]
    assert_done
    assert_contains "RESULT:TokenCountMatch=True"
    assert_contains "RESULT:TokenSequenceMatch=False"
    assert_contains "RESULT:T9Verdict=FAIL"
}

@test "T9-mutant(L・cmd_718新規): 既存Write-Host「result=」の展開式\$(\$step0aResult.Reason)内部へ埋め込むとTokenCountMatchは変わらずTokenSequenceMatchが崩れ検出される" {
    local mutant_dir
    mutant_dir="$(mktemp -d)"
    cp "$LAUNCH_PS1" "$mutant_dir/launch.ps1"
    python3 - "$mutant_dir/launch.ps1" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    text = f.read()
old = 'Write-Host "[$(Get-Ts)] [Step 0-A] result=$($step0aResult.Reason) shutdownOk=$($step0aResult.ShutdownOk)"'
new = "Write-Host \"[$(Get-Ts)] [Step 0-A] result=$($step0aResult.Reason; Write-Host 'L-leak') shutdownOk=$($step0aResult.ShutdownOk)\""
assert text.count(old) == 1, "T9-mutant(L) fixture: expected line not found"
text = text.replace(old, new, 1)
with open(path, "w", encoding="utf-8") as f:
    f.write(text)
PYEOF
    local mutant_win
    mutant_win="$(wslpath -w "$mutant_dir/launch.ps1")"
    run_ps_ast "$mutant_win" "$(t9_check_ps_body)"
    rm -rf -- "${mutant_dir:?}"
    [ "$status" -eq 0 ]
    assert_done
    assert_contains "RESULT:TokenCountMatch=True"
    assert_contains "RESULT:TokenSequenceMatch=False"
    assert_contains "RESULT:T9Verdict=FAIL"
}

@test "T9-mutant(K+L合成・B-2): 2つの展開式内部埋め込みを同時適用してもTokenSequenceMatchが崩れ検出される(単独で落ちても合成で通る例への回帰防止)" {
    local mutant_dir
    mutant_dir="$(mktemp -d)"
    cp "$LAUNCH_PS1" "$mutant_dir/launch.ps1"
    python3 - "$mutant_dir/launch.ps1" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    text = f.read()
old_k = 'Write-Host "[$(Get-Ts)] [Step 0] Shutting down Electron..."'
new_k = "Write-Host \"[$(Get-Ts; Write-Host 'K-leak')] [Step 0] Shutting down Electron...\""
assert text.count(old_k) == 1, "T9-mutant(K+L) fixture: K block not found"
text = text.replace(old_k, new_k, 1)
old_l = 'Write-Host "[$(Get-Ts)] [Step 0-A] result=$($step0aResult.Reason) shutdownOk=$($step0aResult.ShutdownOk)"'
new_l = "Write-Host \"[$(Get-Ts)] [Step 0-A] result=$($step0aResult.Reason; Write-Host 'L-leak') shutdownOk=$($step0aResult.ShutdownOk)\""
assert text.count(old_l) == 1, "T9-mutant(K+L) fixture: L block not found"
text = text.replace(old_l, new_l, 1)
with open(path, "w", encoding="utf-8") as f:
    f.write(text)
PYEOF
    local mutant_win
    mutant_win="$(wslpath -w "$mutant_dir/launch.ps1")"
    run_ps_ast "$mutant_win" "$(t9_check_ps_body)"
    rm -rf -- "${mutant_dir:?}"
    [ "$status" -eq 0 ]
    assert_done
    assert_contains "RESULT:TokenCountMatch=True"
    assert_contains "RESULT:TokenSequenceMatch=False"
    assert_contains "RESULT:T9Verdict=FAIL"
}

# ============================================================
# T9-mutant(M-arg)/(M-reduce)/(M-third): 足軽4号がcmd_718で新規考案した
# mutant(B-4)。K・Lで展開式$(...)の内部を塞いだことで、次に想定される
# 攻撃面の移動先は「引数そのものの内部」(文字列補間を経由しない、
# コマンド呼出しの引数値としての$(...))である。M-argはこれを先取りして
# 塞ぐ。M-reduceは「statementを減らす」方向、M-thirdは「個数を変えずに
# 順序だけを入れ替える」方向で、いずれもM-argとは異なる角度から新matcherの
# 頑健性を検証する(B-4要求の3件)。
# ============================================================

@test "T9-mutant(M-arg・足軽4号cmd_718考案・B-4①引数内部埋込): Exit-Script 3の引数を\$(...)埋め込みへ置換するとTokenCountMatchが崩れ検出される(次の攻撃面『引数の内部』を先取りして塞ぐ)" {
    # なぜ考案したか: 5世代の変異は「top-levelの隙間→statementの内部→展開式
    # $()の内部」と移動してきた(K・Lで展開式の内部を塞いだ)。次に想定される
    # 移動先は「引数そのものの内部」——文字列補間を経由せず、コマンド呼出しの
    # 引数値として直接$(...)を渡す形である。本変異は`Exit-Script 3`の引数
    # `3`を`$(Write-Host 'M-arg leak'; 3)`へ置換し、見た目の実行結果
    # (Exit-Script呼出しに3が渡ること)を保ちながら副作用文を1つ密輸する。
    # なぜ同一性照合では必然的に落ちるか: token列比較は「statementの型」や
    # 「引数の個数」ではなく、region内の全tokenをKind|TokenFlags|Textの
    # 順序列としてそのまま比較する。引数を定数`3`から`$(...)`部分式に
    # 置換すれば、定数token 1個が「(・Write-Host・'M-arg leak'・;・3・)」と
    # いう複数tokenへ展開され、RealTokenCountがCanonTokenCountと一致しなく
    # なる(実測: 63 vs 58)。引数内部か展開式内部かを問わず、token列という
    # 同一の物差しで機械的に検出される。
    local mutant_dir
    mutant_dir="$(mktemp -d)"
    cp "$LAUNCH_PS1" "$mutant_dir/launch.ps1"
    python3 - "$mutant_dir/launch.ps1" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    text = f.read()
old = "Exit-Script 3   # Step 0-Bへ自然フォールバックせず、ここで起動を停止する"
new = "Exit-Script $(Write-Host 'M-arg leak'; 3)   # Step 0-Bへ自然フォールバックせず、ここで起動を停止する"
assert text.count(old) == 1, "T9-mutant(M-arg) fixture: expected line not found"
text = text.replace(old, new, 1)
with open(path, "w", encoding="utf-8") as f:
    f.write(text)
PYEOF
    local mutant_win
    mutant_win="$(wslpath -w "$mutant_dir/launch.ps1")"
    run_ps_ast "$mutant_win" "$(t9_check_ps_body)"
    rm -rf -- "${mutant_dir:?}"
    [ "$status" -eq 0 ]
    assert_done
    assert_contains "RESULT:TokenCountMatch=False"
    assert_contains "RESULT:TokenSequenceMatch=False"
    assert_contains "RESULT:T9Verdict=FAIL"
}

@test "T9-mutant(M-reduce・足軽4号cmd_718考案・B-4②statement削減): Step 0-A告知Write-Host文を1つ丸ごと削除するとTokenCountMatchが崩れ検出される" {
    # なぜ考案したか: 既存mutant(J)は\$psBridge代入statementの削除だったが、
    # 「削除すれば必ず落ちる」がstatement全般に一般化されることを示すため、
    # 削除対象を意図的に変えた第2の削減例を用意する(位置1のadvisory
    # Write-Host文を丸ごと削除)。
    # なぜ同一性照合では必然的に落ちるか: token列比較はregion内のtoken総数を
    # 数える前段(TokenCountMatch)を含む。statementを1つ削除すればそのstatement
    # が持っていたtoken(Write-Hostコマンド名token+文字列token=2個)がまるごと
    # 消え、RealTokenCountが58から56へ減る(実測)。どのstatementを削っても、
    # 「正典が持つtoken集合の一部が実物に存在しない」という一点で機械的に
    # 検出される。
    local mutant_dir
    mutant_dir="$(mktemp -d)"
    cp "$LAUNCH_PS1" "$mutant_dir/launch.ps1"
    python3 - "$mutant_dir/launch.ps1" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    text = f.read()
old = 'Write-Host "[$(Get-Ts)] [Step 0-A] 前回起動の終了確認を行います。通常は数秒で完了しますが、最大目安は約50秒(list待ち最大20秒+send待ち最大20秒+ポートclose待ち最大10秒)+若干の起動/接続時間です。この間、最大20秒単位でログ出力が止まる区間がありますが異常ではありません。"\n'
assert text.count(old) == 1, "T9-mutant(M-reduce) fixture: expected line not found"
text = text.replace(old, "", 1)
with open(path, "w", encoding="utf-8") as f:
    f.write(text)
PYEOF
    local mutant_win
    mutant_win="$(wslpath -w "$mutant_dir/launch.ps1")"
    run_ps_ast "$mutant_win" "$(t9_check_ps_body)"
    rm -rf -- "${mutant_dir:?}"
    [ "$status" -eq 0 ]
    assert_done
    assert_contains "RESULT:TokenCountMatch=False"
    assert_contains "RESULT:TokenSequenceMatch=False"
    assert_contains "RESULT:T9Verdict=FAIL"
}

@test "T9-mutant(M-third・足軽4号cmd_718考案・B-4③順序入替): Step 0冒頭2つのWrite-Host文の順序を入れ替えるとTokenCountMatchは変わらずTokenSequenceMatchが崩れ検出される" {
    # なぜ考案したか: M-arg/M-reduceはいずれもtoken「個数」が変わる変異
    # だった。個数さえ揃えれば同一性照合を回避できるのではないか、という
    # 疑問に答えるため、個数を一切変えず順序だけを入れ替える変異を考案した。
    # なぜ同一性照合では必然的に落ちるか: token列比較はKind|TokenFlags|Text
    # を「順序を保ったまま」index単位で比較する。2つのstatementを入れ替えれば
    # 個数(58)は不変のまま、入れ替えた範囲のtoken内容が前後で入れ替わり、
    # 同じindexで比較すれば正典側と一致しなくなる(実測: index 1・3で
    # mismatch)。「集合として同じ要素を持つか」ではなく「列として同じか」を
    # 見ているため、並び替えだけの変異にも頑健である。
    local mutant_dir
    mutant_dir="$(mktemp -d)"
    cp "$LAUNCH_PS1" "$mutant_dir/launch.ps1"
    python3 - "$mutant_dir/launch.ps1" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    text = f.read()
line_a = 'Write-Host "[$(Get-Ts)] [Step 0] Shutting down Electron..."'
line_b = 'Write-Host "[$(Get-Ts)] [Step 0-A] 前回起動の終了確認を行います。通常は数秒で完了しますが、最大目安は約50秒(list待ち最大20秒+send待ち最大20秒+ポートclose待ち最大10秒)+若干の起動/接続時間です。この間、最大20秒単位でログ出力が止まる区間がありますが異常ではありません。"'
comment = "# 所要時間目安とログ沈黙区間の告知。list最大20秒+send最大20秒+port close待ち最大10秒の\n# 直列最悪経路を過小評価しない。"
old = line_a + "\n" + comment + "\n" + line_b
new = line_b + "\n" + comment + "\n" + line_a
assert text.count(old) == 1, "T9-mutant(M-third) fixture: expected block not found"
text = text.replace(old, new, 1)
with open(path, "w", encoding="utf-8") as f:
    f.write(text)
PYEOF
    local mutant_win
    mutant_win="$(wslpath -w "$mutant_dir/launch.ps1")"
    run_ps_ast "$mutant_win" "$(t9_check_ps_body)"
    rm -rf -- "${mutant_dir:?}"
    [ "$status" -eq 0 ]
    assert_done
    assert_contains "RESULT:TokenCountMatch=True"
    assert_contains "RESULT:TokenSequenceMatch=False"
    assert_contains "RESULT:T9Verdict=FAIL"
}

# ============================================================
# T9-mutant(M)/(P3): 足軽7号の独立QC(subtask_718_phase_ab_qc)がREDO_REQUIRED
# と判定した「容器で包む」攻撃をredo1で恒久negative fixture化する(B-1)。
# 軍師発見の変異M(functionで包む)は、markerで挟んだ[start,end)のoffset範囲に
# 入るtokenだけをfingerprint化していた旧matcherでは、region内のtokenを1つも
# 変えずに(58個のまま完全一致)region外に`function 名 {`と`}`を置くだけで
# T9Verdict=PASSをすり抜けていた(是正前matcherでの実測: T9Verdict=PASS←誤り)。
# R-3(markerで挟んだ領域が真のtop-level statement列であることを要求する)を
# 追加することでこれを塞ぐ。P3(足軽7号考案)はMの容器違い(環境変数
# バックドアによる実行可能なif文で包む形)であり、同じ攻撃族に対する
# R-3の頑健性を別角度から示す。
# ★判定は既存方針どおりT9Verdict=FAILのみを見る。どの位置が・どの型がと
# いう個別診断は書かない(性質検査の再導入を防ぐため)。
# ============================================================

@test "T9-mutant(M・軍師発見・redo1): Step 0正典ブロックをfunctionで包み、外側にExit-Script 9を追加する(容器で包む攻撃)" {
    local mutant_dir
    mutant_dir="$(mktemp -d)"
    cp "$LAUNCH_PS1" "$mutant_dir/launch.ps1"
    python3 - "$mutant_dir/launch.ps1" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    text = f.read()
old = '''# Step 0: shutdown existing Electron'''
new = '''function Invoke-MutantMWrapper {
# Step 0: shutdown existing Electron'''
assert text.count(old) == 1, "T9-mutant(M) fixture: start anchor not found"
text = text.replace(old, new, 1)

old2 = '''# Step 1: git fetch + pull'''
new2 = '''# Step 1: git fetch + pull
}
Exit-Script 9'''
assert text.count(old2) == 1, "T9-mutant(M) fixture: end anchor not found"
text = text.replace(old2, new2, 1)
with open(path, "w", encoding="utf-8") as f:
    f.write(text)
PYEOF
    local mutant_win
    mutant_win="$(wslpath -w "$mutant_dir/launch.ps1")"
    run_ps_ast "$mutant_win" "$(t9_check_ps_body)"
    rm -rf -- "${mutant_dir:?}"
    [ "$status" -eq 0 ]
    assert_done
    assert_contains "RESULT:T9Verdict=FAIL"
}

@test "T9-mutant(P3・足軽7号考案・redo1): Step 0正典ブロックをif (\$env:SKIP_STEP0 -ne '1') { }で包む(環境変数バックドア。Mの容器違い)" {
    local mutant_dir
    mutant_dir="$(mktemp -d)"
    cp "$LAUNCH_PS1" "$mutant_dir/launch.ps1"
    python3 - "$mutant_dir/launch.ps1" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    text = f.read()
old = '''# Step 0: shutdown existing Electron'''
new = '''if ($env:SKIP_STEP0 -ne '1') {
# Step 0: shutdown existing Electron'''
assert text.count(old) == 1, "T9-mutant(P3) fixture: start anchor not found"
text = text.replace(old, new, 1)

old2 = '''# Step 1: git fetch + pull'''
new2 = '''# Step 1: git fetch + pull
}
Exit-Script 9'''
assert text.count(old2) == 1, "T9-mutant(P3) fixture: end anchor not found"
text = text.replace(old2, new2, 1)
with open(path, "w", encoding="utf-8") as f:
    f.write(text)
PYEOF
    local mutant_win
    mutant_win="$(wslpath -w "$mutant_dir/launch.ps1")"
    run_ps_ast "$mutant_win" "$(t9_check_ps_body)"
    rm -rf -- "${mutant_dir:?}"
    [ "$status" -eq 0 ]
    assert_done
    assert_contains "RESULT:T9Verdict=FAIL"
}

# ============================================================
# T9-mutant(P1)/(P2): 将軍追加裁定(2026-08-21 16:08・本redo1へ範囲拡大が
# 追加された)によるnegative fixture。足軽7号のQCで、region外(Step 0 marker
# 以前)での名前再束縛攻撃——P1: `Exit-Script`をno-op化、P2:
# `Invoke-Step0AShutdown`を常時成功スタブ化——は、R-3を足しても原理的に
# 検知できないと判明した(実測: TopLevelStmts=7・Covered=58/58のまま素通り。
# 旧region=Step 0 marker〜Step 1 marker自体がこれらの再定義文を最初から
# 視野に入れていなかったため)。将軍は照合範囲をファイル先頭(top-level
# statement index 0)〜Step 1 marker直前へ拡大する案を採用した(全文拡大・
# 性質検査追加はいずれも却下)。方式(closed-world token fingerprint照合)は
# 変えていない。P1/P2はこの拡大後の範囲でFAILすることを実証する
# negative fixtureである。
# ★判定は既存方針どおりT9Verdict=FAILのみを見る。どの位置が・どの型がと
# いう個別診断は書かない(性質検査の再導入を防ぐため)。
# ============================================================

@test "T9-mutant(P1・足軽7号考案・将軍追加裁定・redo1): region外(Step 0 marker以前)でExit-Scriptをno-op再定義する名前再束縛攻撃(範囲拡大で検出)" {
    local mutant_dir
    mutant_dir="$(mktemp -d)"
    cp "$LAUNCH_PS1" "$mutant_dir/launch.ps1"
    python3 - "$mutant_dir/launch.ps1" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    text = f.read()
old = '''. (Join-Path $ScriptDir "launch.helpers.ps1")   # 唯一のdot-source行。Step 0より前に置く。'''
new = old + '''
function Exit-Script {
    param([int]$Code)
    # P1: no-op化。Stop-Transcript/exitを一切呼ばず、Exit-Scriptを無害化する
}'''
assert text.count(old) == 1, "T9-mutant(P1) fixture: anchor not found"
text = text.replace(old, new, 1)
with open(path, "w", encoding="utf-8") as f:
    f.write(text)
PYEOF
    local mutant_win
    mutant_win="$(wslpath -w "$mutant_dir/launch.ps1")"
    run_ps_ast "$mutant_win" "$(t9_check_ps_body)"
    rm -rf -- "${mutant_dir:?}"
    [ "$status" -eq 0 ]
    assert_done
    assert_contains "RESULT:T9Verdict=FAIL"
}

@test "T9-mutant(P2・足軽7号考案・将軍追加裁定・redo1): region外(Step 0 marker以前)でInvoke-Step0AShutdownを常時成功スタブへ再定義する名前再束縛攻撃(範囲拡大で検出)" {
    local mutant_dir
    mutant_dir="$(mktemp -d)"
    cp "$LAUNCH_PS1" "$mutant_dir/launch.ps1"
    python3 - "$mutant_dir/launch.ps1" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    text = f.read()
old = '''. (Join-Path $ScriptDir "launch.helpers.ps1")   # 唯一のdot-source行。Step 0より前に置く。'''
new = old + '''
function Invoke-Step0AShutdown {
    param($PsBridgePath, $Port)
    # P2: 常時成功スタブ化。実際のport状態を一切見ずShutdownOk=$trueを返す
    return [PSCustomObject]@{ ShutdownOk = $true; RequiresFailClosedStop = $false; Reason = "StubbedAlwaysSuccess" }
}'''
assert text.count(old) == 1, "T9-mutant(P2) fixture: anchor not found"
text = text.replace(old, new, 1)
with open(path, "w", encoding="utf-8") as f:
    f.write(text)
PYEOF
    local mutant_win
    mutant_win="$(wslpath -w "$mutant_dir/launch.ps1")"
    run_ps_ast "$mutant_win" "$(t9_check_ps_body)"
    rm -rf -- "${mutant_dir:?}"
    [ "$status" -eq 0 ]
    assert_done
    assert_contains "RESULT:T9Verdict=FAIL"
}

# ============================================================
# T9-canonical-tamper(B-5・N-3実証): 正典という攻撃面そのものへの防御を実証
# する。正典の内容だけを不正に書き換えても、実物側が元のまま(正しい)で
# あれば従来通りtoken不一致で検出される。真に危険なのは「実物と正典を
# 同時に同じ形へ書き換える」launder攻撃であり、この場合token列は両者で
# 一致してしまうためTokenSequenceMatch単体では検出できない。N-3のhash
# 二段構えは、正典のhashを本テストファイル側に独立して固定することで、
# 正典ファイルそのものへのいかなる書き換えも——実物と揃えていても——
# 検出できることを本testで示す。
# ============================================================

@test "T9-canonical-tamper(B-5): 実物と正典を同一改変(outer guard直後へExit-Script 9追加)してもTokenSequenceMatch=Trueとなる一方、CanonHashMatch=FalseによりT9VerdictはFAILする(正典を書き換えてtestを無力化する攻撃への対抗)" {
    local mutant_dir
    mutant_dir="$(mktemp -d)"
    cp "$LAUNCH_PS1" "$mutant_dir/launch_bad.ps1"
    cp "$STEP0_CANONICAL_PS1" "$mutant_dir/canon_bad.ps1"
    python3 - "$mutant_dir/launch_bad.ps1" "$mutant_dir/canon_bad.ps1" <<'PYEOF'
import sys
old = '''}

# ここに到達するのは $step0aResult.ShutdownOk -eq $true の場合のみ(§3.3.1の(i))。'''
new = '''}
Exit-Script 9

# ここに到達するのは $step0aResult.ShutdownOk -eq $true の場合のみ(§3.3.1の(i))。'''
for path in sys.argv[1:]:
    with open(path, encoding="utf-8") as f:
        text = f.read()
    assert text.count(old) == 1, path + ": fixture block not found"
    text = text.replace(old, new, 1)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)
PYEOF
    local bad_real_win bad_canon_win orig_canon_win
    bad_real_win="$(wslpath -w "$mutant_dir/launch_bad.ps1")"
    bad_canon_win="$(wslpath -w "$mutant_dir/canon_bad.ps1")"
    orig_canon_win="$STEP0_CANONICAL_WIN"
    export STEP0_CANONICAL_WIN="$bad_canon_win"
    run_ps_ast "$bad_real_win" "$(t9_check_ps_body)"
    export STEP0_CANONICAL_WIN="$orig_canon_win"
    rm -rf -- "${mutant_dir:?}"
    [ "$status" -eq 0 ]
    assert_done
    assert_contains "RESULT:ParseErrorsReal=0"
    assert_contains "RESULT:ParseErrorsCanon=0"
    assert_contains "RESULT:TokenCountMatch=True"
    assert_contains "RESULT:TokenSequenceMatch=True"
    assert_contains "RESULT:CanonHashMatch=False"
    assert_contains "RESULT:T9Verdict=FAIL"
}

# ============================================================
# T9-fail-closed-precondition: fail-closed precondition(parse error数0の
# 事前assert)そのものを検証する、上記mutantとは独立の追加テスト。文字列
# リテラルを未終端にしてtokenizer段階でparse errorを確実に誘発し、
# FailClosedParseError=Trueとなって以降のtoken比較へ一切進まないこと、
# T9Verdictも必ずFAILになることを確認する。
# ============================================================

@test "T9-fail-closed-precondition: 文字列リテラル未終端でparse errorを誘発するとFailClosedParseError=Trueとなり、token比較をスキップしたままT9VerdictがFAILになる" {
    local mutant_dir
    mutant_dir="$(mktemp -d)"
    cp "$LAUNCH_PS1" "$mutant_dir/launch.ps1"
    python3 - "$mutant_dir/launch.ps1" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    text = f.read()
old = 'Write-Host "[$(Get-Ts)] [Step 0] Shutting down Electron..."'
new = 'Write-Host "[$(Get-Ts)] [Step 0] Shutting down Electron...'
assert text.count(old) == 1, "T9-fail-closed fixture: expected line not unique"
text = text.replace(old, new, 1)
with open(path, "w", encoding="utf-8") as f:
    f.write(text)
PYEOF
    local mutant_win
    mutant_win="$(wslpath -w "$mutant_dir/launch.ps1")"
    run_ps_ast "$mutant_win" "$(t9_check_ps_body)"
    rm -rf -- "${mutant_dir:?}"
    [ "$status" -eq 0 ]
    assert_done
    assert_contains "RESULT:FailClosedParseError=True"
    assert_contains "RESULT:TokenSequenceMatch=False"
    assert_contains "RESULT:T9Verdict=FAIL"
}

# ============================================================
# T10: launch.helpers.ps1のtop-level非実行性の機械照合(C712-A-R1-QC-02のseam土台)
# 実行は一切しない。ParseInputによる静的解析のみ。
# ============================================================

@test "T10: launch.helpers.ps1のtop-levelのstatementはすべてFunctionDefinitionAstである" {
    run_ps_ast "$HELPERS_WIN" "
Write-Output \"RESULT:ParseErrors=\$(\$errors.Count)\"
\$nonFunc = \$ast.EndBlock.Statements | Where-Object { \$_ -isnot [System.Management.Automation.Language.FunctionDefinitionAst] }
Write-Output \"RESULT:NonFunctionTopLevelCount=\$(\$nonFunc.Count)\"
Write-Output \"RESULT:TopLevelStatementCount=\$(\$ast.EndBlock.Statements.Count)\"
Write-Output 'RESULT:DONE=1'
"
    [ "$status" -eq 0 ]
    assert_done
    assert_contains "RESULT:ParseErrors=0"
    assert_contains "RESULT:NonFunctionTopLevelCount=0"
}
