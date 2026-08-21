<#
    ★★★ セキュリティ上重要な正典ファイル (N-1・cmd_718・redo1で範囲拡大) ★★★

    本ファイルはTLC-cms launch.ps1の「ファイル先頭(top-level statement
    index 0)からStep 1 marker直前まで」の領域について将軍が承認した正典
    (canonical source)である。tests/unit/test_cmd_712_launch_helpers_matrix.bats
    のT9は、launch.ps1の実ソースと本ファイルをトークン列レベルで同一性
    照合し、一致しなければ即FAILとする(closed-world token fingerprint
    照合。「性質を持つか」ではなく「これと同一か」のみを見る)。

    ★redo1(cmd_718)での範囲拡大: 当初はStep 0 marker(`# Step 0: shutdown
    existing Electron`)からStep 1 marker直前までのみを対象としていたが、
    region外(Step 0 marker以前)での`Exit-Script`/`Invoke-Step0AShutdown`
    再定義による名前再束縛攻撃(P1/P2)は、R-3を追加しても原理的に検知
    できないと判明した(region内のtoken・top-level statement構造は一切
    変わらないため)。将軍裁定により、対象範囲をファイル先頭(top-level
    statement index 0)まで拡大した。方式(closed-world token fingerprint
    照合)そのものは変えていない。範囲を広げただけであり、性質を見る
    条件は一つも追加していない。

    本ファイルの変更はproductionコードの変更と同等の設計レビュー・
    軍師によるQCを要する。変更する場合は、必ず
    test_cmd_712_launch_helpers_matrix.bats内の
    EXPECTED_STEP0_CANONICAL_SHA256定数も同時に更新すること(N-3・
    二段構え)。本ファイルのみを書き換えてhash定数を更新しなければ、
    T9はhash不一致により位置照合を待たず即FAILする(正典を書き換える
    ことでtestそのものを無力化する攻撃を防止するための機構)。

    以下はlaunch.ps1(feature/cmd-712-launch-ps1-fixesブランチ)の
    ファイル先頭からStep 1 marker直前までの領域から、将軍確認済みの
    内容をそのまま転記したものである(cmd_718・2026-08-21・機械抽出に
    よりtypoを排除。redo1でP1/P2対応のため前段16文を追加転記)。
#>

#Requires -Version 5.1
# launch.ps1 - TLC-cms launcher (cmd_473 Phase C)

Set-StrictMode -Version 3.0
$ErrorActionPreference = "Continue"

$ScriptDir = $PSScriptRoot
if (-not $ScriptDir) { $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
Set-Location $ScriptDir

# Log rotation
$Log = Join-Path $ScriptDir "launch.log"
if (Test-Path "$Log.4") {
    if (Test-Path "$Log.5") { Remove-Item "$Log.5" -Force }
    Rename-Item "$Log.4" "$Log.5"
}
if (Test-Path "$Log.3") { Rename-Item "$Log.3" "$Log.4" }
if (Test-Path "$Log.2") { Rename-Item "$Log.2" "$Log.3" }
if (Test-Path "$Log.1") { Rename-Item "$Log.1" "$Log.2" }
if (Test-Path $Log) { Rename-Item $Log "$Log.1" }

Start-Transcript -Path $Log

function Get-Ts { Get-Date -Format "yyyy-MM-dd HH:mm:ss" }

Write-Host "[$(Get-Ts)] TLC-cms launch.ps1 start"

function Exit-Script {
    param([int]$Code)
    Stop-Transcript
    exit $Code
}

. (Join-Path $ScriptDir "launch.helpers.ps1")   # 唯一のdot-source行。Step 0より前に置く。

# Step 0: shutdown existing Electron
Write-Host "[$(Get-Ts)] [Step 0] Shutting down Electron..."
# 所要時間目安とログ沈黙区間の告知。list最大20秒+send最大20秒+port close待ち最大10秒の
# 直列最悪経路を過小評価しない。
Write-Host "[$(Get-Ts)] [Step 0-A] 前回起動の終了確認を行います。通常は数秒で完了しますが、最大目安は約50秒(list待ち最大20秒+send待ち最大20秒+ポートclose待ち最大10秒)+若干の起動/接続時間です。この間、最大20秒単位でログ出力が止まる区間がありますが異常ではありません。"

# Step 0-A: CDP graceful shutdown (launch.ps1からps-bridge.ps1を直接呼出し。wsl.exe非経由)
$winPort = 9224
$psBridge = Resolve-PsBridgePath -ShogunRootEnvValue $env:SHOGUN_REPO_WIN_ROOT
$step0aResult = Invoke-Step0AShutdown -PsBridgePath $psBridge -Port $winPort

if ($step0aResult.RequiresFailClosedStop) {
    if ($step0aResult.Reason -eq "NoPsBridgePath") {
        Write-Host "[$(Get-Ts)] [Step 0-A] [FATAL] SHOGUN_REPO_WIN_ROOT 未設定、または解決先に ps-bridge.ps1 が実在しません。"
        Write-Host "[$(Get-Ts)] [Step 0-A] [FATAL] 対処: Windowsユーザ環境変数 SHOGUN_REPO_WIN_ROOT に shogun リポジトリの Windows 可視ルート(例: \\wsl.localhost\Ubuntu\home\kato\shogun)を設定してください。"
        Exit-Script 3   # Step 0-Bへ自然フォールバックせず、ここで起動を停止する
    } else {
        # 前回インスタンスは存在するがCDP経由で終了できない場合の殿向けメッセージ
        Write-Host "[$(Get-Ts)] [Step 0-A] [FATAL] 前回起動したTLC-cmsが残っている可能性がありますが、CDP経由の正常終了要求に応答しないため、自動終了は行わず起動を停止しました(理由: $($step0aResult.Reason))。"
        Write-Host "[$(Get-Ts)] [Step 0-A] [FATAL] 対処: タスクマネージャ等で「electron.exe」(TLC-cms)のプロセスを手動で終了させた後、再度 launch.vbs を実行してください。"
        Write-Host "[$(Get-Ts)] [Step 0-A] [FATAL] このまま放置しても害はありません。安全に停止しているだけで、二重起動などは発生しません。待機や再試行は行わず、直ちに終了します。"
        Write-Host "[$(Get-Ts)] [Step 0-A] [FATAL] このスクリプトは終了コード4で終了します。自動化・監視から本事象を機械的に判定する場合は終了コード4を使用してください。"
        Exit-Script 4   # 前回インスタンス終了不能によるfail-closed停止(NoPsBridgePathのExit-Script 3とは別コード)
    }
}

# ここに到達するのは $step0aResult.ShutdownOk -eq $true の場合のみ(§3.3.1の(i))。
# 旧Step 0-B(プロセス列挙+強制終了によるフォールバック)は将軍裁定により
# 完全に撤去した。フォールバック先はもう存在しない。
Write-Host "[$(Get-Ts)] [Step 0-A] result=$($step0aResult.Reason) shutdownOk=$($step0aResult.ShutdownOk)"

# Step 1: git fetch + pull
