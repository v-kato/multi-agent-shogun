#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# tests/stress_isolated_tmux_teardown.sh — scripts/isolated_tmux.sh の
#   create/teardown を並行して多数回連続させる負荷再現器 (cmd_795 AC②)
# ═══════════════════════════════════════════════════════════════
#
# 目的: 負荷下で teardown の `tmux wait-for` が通知を取りこぼし、無期限に
#   止まる事象(cmd_791(B) で1日27件観測)が、上限(cmd_795)によって「停滞
#   0」になったことを確かめる。1回の走行で workers 本の worker が並行し、
#   各 worker が iterations 回 create→teardown を連続させる。
#
# 使い方:
#   bash tests/stress_isolated_tmux_teardown.sh [-w workers] [-n iterations] [-o outdir]
#     既定: workers=10, iterations=30(1走行 300 回)。outdir 既定は
#     tmp/cmd_795_stress/run_<起動からの経過秒>。
#   上限は helper の既定(60秒)。ITMUX_WAIT_LIMIT_SEC を設定すればその値が
#   helper へそのまま渡る(判定の「停滞」閾値もその値に合わせる)。
#
# 判定(1走行):
#   - 停滞: teardown が「上限+30秒」を越えて戻らなかったもの。0 件で合格。
#     (上限が働かなければ teardown は戻らず、本走行自体が終わらない——
#     その場合は人が見て判断する。本器は何も終了させない。)
#   - teardown rc!=0(残存=安全側の失敗を含む)も 0 件で合格。
#   - 上限到達(「通知取りこぼし後に has-session で確定」)は件数を数えて
#     出すだけで、合否には使わない(取りこぼしは起きてよい・上限で確定
#     できればよい)。
#   経過は /proc/uptime(起動からの経過)で測り、壁時計に依存しない。
#
# ★D006: kill 系のコマンドは一切使わない。背景 worker は wait で回収する。
#   残存した隔離server(teardown rc!=0)は終了させず、件数と handle を
#   出力して人の確認へ渡すだけである。
# ★後始末の rm は書かない。handle file・socket 残骸は helper の方針どおり
#   残す(tmp/ 配下・gitignore 対象・害なし)。
# ═══════════════════════════════════════════════════════════════
set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$PROJECT_ROOT/scripts/isolated_tmux.sh"

workers=10
iterations=30
outdir=""
while getopts ":w:n:o:" opt; do
    case "$opt" in
        w) workers="$OPTARG" ;;
        n) iterations="$OPTARG" ;;
        o) outdir="$OPTARG" ;;
        *) echo "使い方: $0 [-w workers] [-n iterations] [-o outdir]" >&2; exit 2 ;;
    esac
done
[[ "$workers" =~ ^[1-9][0-9]*$ ]] || { echo "workers は正の整数: ${workers}" >&2; exit 2; }
[[ "$iterations" =~ ^[1-9][0-9]*$ ]] || { echo "iterations は正の整数: ${iterations}" >&2; exit 2; }

limit_sec="${ITMUX_WAIT_LIMIT_SEC:-60}"
[[ "$limit_sec" =~ ^[1-9][0-9]{0,4}$ ]] || { echo "ITMUX_WAIT_LIMIT_SEC が不正: ${limit_sec}" >&2; exit 2; }
stall_ms=$(( (limit_sec + 30) * 1000 ))

uptime_ms() {
    local u
    read -r u _ < /proc/uptime
    echo $(( ${u%.*} * 1000 + 10#${u#*.} * 10 ))
}

if [ -z "$outdir" ]; then
    outdir="$PROJECT_ROOT/tmp/cmd_795_stress/run_$(( $(uptime_ms) / 1000 ))"
fi
mkdir -p "$outdir"

# worker <k>: 1行1回で TSV を書く。
#   idx  create_rc  teardown_rc  teardown_ms  kind  handle
#   kind: normal(通知どおり) / limit_ok(上限到達→has-sessionで消滅確定) /
#         residual(残存=安全側の失敗) / create_fail / other
worker() {
    local k="$1" i h crc trc t0 t1 out kind
    local tsv="$outdir/worker_${k}.tsv"
    : > "$tsv"
    for (( i = 1; i <= iterations; i++ )); do
        h="$(bash "$HELPER" create -L "stress795_w${k}_i${i}_$$" 2>/dev/null)"
        crc=$?
        if [ "$crc" -ne 0 ] || [ ! -f "$h" ]; then
            printf '%s\t%s\t-\t-\tcreate_fail\t%s\n' "$i" "$crc" "${h:--}" >> "$tsv"
            continue
        fi
        t0="$(uptime_ms)"
        out="$(bash "$HELPER" teardown "$h" 2>&1)"
        trc=$?
        t1="$(uptime_ms)"
        case "$out" in
            (*"通知取りこぼし後に has-session で確定"*) kind=limit_ok ;;
            (*"隔離セッションが残っている"*) kind=residual ;;
            (*"自然終了した"*) kind=normal ;;
            (*) kind=other ;;
        esac
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$i" "$crc" "$trc" "$((t1 - t0))" "$kind" "$h" >> "$tsv"
    done
}

echo "走行開始: workers=${workers} iterations=${iterations} 上限=${limit_sec}秒 停滞閾値=$((stall_ms / 1000))秒 outdir=${outdir}"
echo "開始時 loadavg: $(cat /proc/loadavg)"
run_t0="$(uptime_ms)"

pids=()
for (( k = 1; k <= workers; k++ )); do
    worker "$k" &
    pids+=("$!")
done
for p in "${pids[@]}"; do
    wait "$p"
done

run_t1="$(uptime_ms)"
echo "終了時 loadavg: $(cat /proc/loadavg)"

cat "$outdir"/worker_*.tsv > "$outdir/all.tsv"
awk -F'\t' -v stall_ms="$stall_ms" -v wall_ms="$((run_t1 - run_t0))" '
    {
        total++
        if ($5 == "create_fail") { cfail++; next }
        if ($3 != 0) trc_ng++
        kinds[$5]++
        if ($4 + 0 > max_ms) max_ms = $4 + 0
        if ($4 + 0 > stall_ms) stall++
        if ($5 == "limit_ok") limit_list = limit_list sprintf("  上限到達→消滅確定: %s ms %s\n", $4, $6)
        if ($5 == "residual" || $5 == "other" || $3 != 0) ng_list = ng_list sprintf("  要確認: rc=%s kind=%s %s ms %s\n", $3, $5, $4, $6)
    }
    END {
        printf "総数=%d create失敗=%d teardown rc!=0=%d 停滞(閾値超)=%d 最大teardown=%d ms 走行全体=%d ms\n", total, cfail, trc_ng, stall, max_ms, wall_ms
        printf "内訳: normal=%d limit_ok=%d residual=%d other=%d\n", kinds["normal"], kinds["limit_ok"], kinds["residual"], kinds["other"]
        printf "%s%s", limit_list, ng_list
        verdict = (cfail == 0 && trc_ng == 0 && stall == 0 && kinds["residual"] == 0 && kinds["other"] == 0) ? "PASS" : "FAIL"
        printf "判定=%s\n", verdict
        exit (verdict == "PASS" ? 0 : 1)
    }
' "$outdir/all.tsv" | tee "$outdir/summary.txt"
exit "${PIPESTATUS[0]}"
