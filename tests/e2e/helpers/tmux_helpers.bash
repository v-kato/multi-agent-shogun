#!/usr/bin/env bash
# tmux_helpers.bash — tmux pane interaction helpers for E2E tests

# ─── send_to_pane ───
# Send text to a tmux pane (text and Enter separated, 0.3s gap).
# Usage: send_to_pane <pane_target> <text>
#
# ★何を模しているか (cmd_754 E-1 / 2026-09-08):
#   inbox_watcher からの自動打鍵は★全廃した。`inboxN` の nudge も
#   `/clear`・`/new` も、watcher は一つも送らない。ゆえに E2E 各所の
#   `send_to_pane` は★試験ハーネスが人の手を模して打つものであり、
#   watcher の挙動ではない。各試験が確かめているのは「入力が届いた後、
#   mock が正しく処理するか」であって「watcher が入力を届けるか」ではない。
#   ★本関数が触れてよいのは E2E 専用の隔離 tmux session の pane だけである。
#   稼働中の agent pane へは決して用いてはならぬ。
#   実配送は claude=Stop hook のみ、他CLIは人経路。正本:
#   docs/delivery_channels.md
send_to_pane() {
    local pane="$1" text="$2"
    tmux send-keys -t "$pane" "$text"
    sleep 0.3
    tmux send-keys -t "$pane" Enter
}

# ─── capture_pane ───
# Capture the full visible content of a tmux pane.
# Usage: capture_pane <pane_target>
capture_pane() {
    local pane="$1"
    tmux capture-pane -t "$pane" -p 2>/dev/null
}

# ─── pane_target ───
# Get the tmux pane target string for a given agent index.
# Usage: pane_target <pane_index>
pane_target() {
    local idx="$1"
    echo "${E2E_SESSION}:agents.${idx}"
}

# ─── pane_is_idle ───
# Check if a pane shows an idle prompt ($ or ?).
# Returns 0 if idle, 1 if busy.
# Usage: pane_is_idle <pane_target>
pane_is_idle() {
    local pane="$1"
    local content
    content=$(tmux capture-pane -t "$pane" -p 2>/dev/null | tail -5)
    if echo "$content" | grep -qE '^\$\s*$'; then
        return 0
    fi
    if echo "$content" | grep -qE '\? for shortcuts'; then
        return 0
    fi
    return 1
}

# ─── wait_for_pane_idle ───
# Wait until a pane shows an idle prompt.
# Usage: wait_for_pane_idle <pane_target> [timeout_sec]
wait_for_pane_idle() {
    local pane="$1" timeout="${2:-30}"
    local elapsed=0
    while [ "$elapsed" -lt "$timeout" ]; do
        if pane_is_idle "$pane"; then
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    echo "TIMEOUT: pane $pane not idle after ${timeout}s" >&2
    capture_pane "$pane" >&2
    return 1
}

# ─── dump_pane_for_debug ───
# Print pane content for debugging (use in test failures).
# Usage: dump_pane_for_debug <pane_target> <label>
dump_pane_for_debug() {
    local pane="$1" label="${2:-pane}"
    echo "=== DEBUG: $label ($pane) ===" >&2
    tmux capture-pane -t "$pane" -p 2>/dev/null >&2 || echo "(capture failed)" >&2
    echo "=== END: $label ===" >&2
}
