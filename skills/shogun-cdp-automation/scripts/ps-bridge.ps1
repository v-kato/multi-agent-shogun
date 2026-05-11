<#
.SYNOPSIS
  CDP (Chrome DevTools Protocol) bridge for WSL2 → Windows Edge communication.

.DESCRIPTION
  WSL2からWindows Edge/ChromeへのCDP WebSocket通信を仲介するPowerShellブリッジ。
  Python側はbase64エンコードしたJSONコマンドをsubprocess経由で渡し、
  このスクリプトがWindows側でWebSocket接続を確立してCDPコマンドを送受信する。

.PARAMETER Action
  start   : EdgeをCDPモードで起動
  list    : 利用可能なCDPターゲット一覧を表示
  send    : CDPコマンドを送信 (PayloadBase64必須)

.PARAMETER Host
  CDPホスト (default: localhost)

.PARAMETER Port
  CDPポート番号 (default: 9223)

.PARAMETER TargetId
  ターゲットID。空の場合は最初のタブを使用。

.PARAMETER PayloadBase64
  Base64エンコードされたCDPコマンドJSON文字列。

.EXAMPLE
  # Edge起動
  .\ps-bridge.ps1 -Action start

  # ターゲット一覧
  .\ps-bridge.ps1 -Action list

  # JS実行
  $payload = '{"id":1,"method":"Runtime.evaluate","params":{"expression":"document.title"}}'
  $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload))
  .\ps-bridge.ps1 -Action send -PayloadBase64 $b64
#>

param(
    [Parameter(Mandatory=$false)]
    [ValidateSet("start", "list", "send")]
    [string]$Action = "list",

    [string]$CdpHost = "localhost",
    [int]$Port = 9223,
    [string]$TargetId = "",
    [string]$PayloadBase64 = "",
    [int]$TimeoutMs = 10000
)

$ErrorActionPreference = "Stop"

# --- Action: start ---
if ($Action -eq "start") {
    $edgePaths = @(
        "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
        "C:\Program Files\Microsoft\Edge\Application\msedge.exe"
    )
    $edgePath = $edgePaths | Where-Object { Test-Path $_ } | Select-Object -First 1

    if (-not $edgePath) {
        Write-Error "Edge not found. Checked: $($edgePaths -join ', ')"
        exit 1
    }

    $args = @(
        "--remote-debugging-port=$Port",
        "--remote-debugging-address=0.0.0.0",
        "--no-first-run",
        "--no-default-browser-check"
    )
    Start-Process -FilePath $edgePath -ArgumentList $args -PassThru | Out-Null
    Write-Output "Edge started with CDP on port $Port"
    exit 0
}

# --- Fetch targets via HTTP ---
try {
    $targetsJson = Invoke-RestMethod -Uri "http://${CdpHost}:${Port}/json" -TimeoutSec 5
} catch {
    Write-Error "Cannot connect to CDP at http://${CdpHost}:${Port}/json - Is Edge running with --remote-debugging-port=${Port}?"
    exit 1
}

# Filter to page type only
$pageTargets = $targetsJson | Where-Object { $_.type -eq "page" }

if ($pageTargets.Count -eq 0) {
    Write-Error "No page targets found. Available targets: $($targetsJson.Count)"
    exit 1
}

# --- Action: list ---
if ($Action -eq "list") {
    $pageTargets | ForEach-Object {
        [PSCustomObject]@{
            id    = $_.id
            title = $_.title
            url   = $_.url
            wsUrl = $_.webSocketDebuggerUrl
        }
    } | ConvertTo-Json
    exit 0
}

# --- Action: send ---
if (-not $PayloadBase64) {
    Write-Error "-PayloadBase64 is required for -Action send"
    exit 1
}

# Select target
$target = if ($TargetId) {
    $pageTargets | Where-Object { $_.id -eq $TargetId } | Select-Object -First 1
} else {
    $pageTargets | Select-Object -First 1
}

if (-not $target) {
    Write-Error "Target not found: '$TargetId'"
    exit 1
}

$wsUrl = $target.webSocketDebuggerUrl

# Decode payload
$payloadBytes = [System.Convert]::FromBase64String($PayloadBase64)
$payload = [System.Text.Encoding]::UTF8.GetString($payloadBytes)

# WebSocket connection
$ws = [System.Net.WebSockets.ClientWebSocket]::new()
$ct = [System.Threading.CancellationToken]::None

try {
    $wsUri = [System.Uri]$wsUrl
    $connectTask = $ws.ConnectAsync($wsUri, $ct)
    if (-not $connectTask.Wait($TimeoutMs)) {
        Write-Error "WebSocket connection timeout"
        exit 1
    }

    # Send command
    $sendBytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
    $sendSegment = [System.ArraySegment[byte]]::new($sendBytes)
    $ws.SendAsync($sendSegment, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $ct).Wait()

    # Receive response (accumulate until EndOfMessage)
    $recvBuffer = [byte[]]::new(64 * 1024)  # 64KB chunks
    $resultBuilder = [System.Text.StringBuilder]::new()
    $endOfMessage = $false

    while (-not $endOfMessage) {
        $segment = [System.ArraySegment[byte]]::new($recvBuffer)
        $recvTask = $ws.ReceiveAsync($segment, $ct)
        if (-not $recvTask.Wait($TimeoutMs)) {
            Write-Error "WebSocket receive timeout"
            exit 1
        }
        $result = $recvTask.Result
        $chunk = [System.Text.Encoding]::UTF8.GetString($recvBuffer, 0, $result.Count)
        $resultBuilder.Append($chunk) | Out-Null
        $endOfMessage = $result.EndOfMessage
    }

    Write-Output $resultBuilder.ToString()

} finally {
    if ($ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
        $ws.CloseAsync(
            [System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure,
            "Done", $ct
        ).Wait(3000) | Out-Null
    }
    $ws.Dispose()
}
