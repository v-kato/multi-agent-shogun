#!/usr/bin/env bats
# test_headless_claude_argv.bats — headless claude 起動箇所の argv 回帰ガード (cmd_799 ②)
#
# 背景: headless の `claude -p` / `claude --print` は cwd の project 設定
#   (CLAUDE.md・hooks)と pane の $TMUX_PANE を継承し、親 agent を騙って
#   記録や家老通知を作る(cmd_779 実発生・cmd_780 Phase C で実測)。
#   処方は `--tools ""` と `--setting-sources ""` の★両方を付けること。
#
# 本ファイルは、リポジトリ内で headless claude を起動する箇所(スクリプト・
# 設定・skills 配下のコード)がその両方を持つことを静的に検査する。
#   T-HCA-001〜008: 検査器(下記 scanner)自身の判定境界。fixture に欠落を
#                   仕込んだとき必ず検出し、正しい形は通すこと(変異試験)。
#   T-HCA-009:      実ツリーで欠落が 0 件であること。
#   T-HCA-010:      実ツリーで起動箇所が 1 件以上見つかること(★検査器が
#                   何も見ずに 0 を返す「沈黙の合格」を許さない)。
#
# 検査対象の範囲: scripts/ lib/ config/ ルート直下の *.sh tests/*.sh と、
#   skills/ 配下のコード・設定(tests/・docs/ 配下を除く)。.md の説明文・
#   queue/・logs/・memory/・context/・tmp/・generated/ は対象外
#   (実行されない記録・生成物。生成物は正本を直して再生成する)。
# 意図して旧形を再現する行(陽性対照等)は、同じ行に `headless-audit-exempt`
#   を書くことで検査から外す。
#
# ★後始末の rm -rf は書かない(bats の BATS_TEST_TMPDIR は bats 自身が管理する)。

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    SCANNER="$BATS_TEST_TMPDIR/scan_headless_claude.py"
    cat > "$SCANNER" <<'PYEOF'
import re, sys, pathlib

# usage: scan_headless_claude.py <root>
# stdout: 1 行 1 件 "OK|NG<TAB>相対パス<TAB>行番号<TAB>欠落(なければ -)"
EXT = {'.sh', '.py', '.yaml', '.yml', '.json', '.js', '.ts', '.toml'}
SKIP_DIRS = {'node_modules', '.venv', '.git', 'tmp', 'queue', 'logs', 'memory',
             'context', 'generated', '.opencode', '.pytest_cache', '__pycache__',
             'test_helper', 'docs', 'references', 'projects', 'backups', 'archive'}
# 「claude」の後ろ、同じ文の中(; | & と改行で切れる。行継続は越える)に -p / --print がある
LAUNCH = re.compile(r'(?<![\w.-])claude\w*(?:[^;|&\n]|\\\n){0,160}?(?<![\w-])(?:--print|-p)(?![\w-])')
EMPTY = r'''['"]?[,\s]*(?:\\?"\\?"|'')'''
NEED = {'--tools': re.compile(r'--tools' + EMPTY),
        '--setting-sources': re.compile(r'--setting-sources' + EMPTY)}
EXEMPT = 'headless-audit-exempt'

def statement(txt, pos):
    """起動位置を含む行の先頭から、文の終わり(括弧が閉じた最初の改行、または ])まで"""
    start = txt.rfind('\n', 0, pos) + 1
    depth = 0
    i = start
    while i < len(txt):
        c = txt[i]
        if c == '[':
            depth += 1
        elif c == ']':
            depth -= 1
            if depth <= 0:
                return txt[start:i + 1]
        elif c == '\n' and depth <= 0 and txt[i - 1] != '\\':
            return txt[start:i]
        i += 1
    return txt[start:]

def in_scope(rel):
    parts = rel.parts
    if any(x in SKIP_DIRS for x in parts[:-1]):
        return False
    if rel.suffix not in EXT:
        return False
    top = parts[0]
    if len(parts) == 1:
        return rel.suffix == '.sh'
    if top in ('scripts', 'lib', 'config'):
        return True
    if top == 'tests':
        return len(parts) == 2 and rel.suffix == '.sh'
    if top == 'skills':
        return 'tests' not in parts[:-1]
    return False

root = pathlib.Path(sys.argv[1])
for p in sorted(root.rglob('*')):
    if not p.is_file():
        continue
    rel = p.relative_to(root)
    if not in_scope(rel):
        continue
    txt = p.read_text(encoding='utf-8', errors='replace')
    for m in LAUNCH.finditer(txt):
        stmt = statement(txt, m.start())
        if EXEMPT in stmt:
            continue
        miss = [k for k, rx in NEED.items() if not rx.search(stmt)]
        ln = txt.count('\n', 0, m.start()) + 1
        print('%s\t%s\t%d\t%s' % ('NG' if miss else 'OK', rel, ln, ','.join(miss) or '-'))
PYEOF
    FX="$BATS_TEST_TMPDIR/fx"
    mkdir -p "$FX/scripts" "$FX/docs" "$FX/tests" "$FX/skills/s/codd"
}

scan() { python3 "$SCANNER" "$1"; }

# ── 検査器の判定境界(変異試験) ─────────────────────────

@test "T-HCA-001: 両引数あり(shell)は OK" {
    printf '%s\n' 'claude -p --tools "" --setting-sources "" --model haiku' > "$FX/scripts/a.sh"
    run scan "$FX"
    [ "$status" -eq 0 ]
    [[ "$output" == $'OK\tscripts/a.sh\t1\t-' ]]
}

@test "T-HCA-002: --setting-sources 欠落は NG(shell)" {
    printf '%s\n' 'claude -p --tools "" --model haiku' > "$FX/scripts/a.sh"
    run scan "$FX"
    [[ "$output" == $'NG\tscripts/a.sh\t1\t--setting-sources' ]]
}

@test "T-HCA-003: --tools \"\" 欠落は NG(shell)" {
    printf '%s\n' 'claude --print --setting-sources "" --model haiku' > "$FX/scripts/a.sh"
    run scan "$FX"
    [[ "$output" == $'NG\tscripts/a.sh\t1\t--tools' ]]
}

@test "T-HCA-004: --tools に空でない値(default)は NG — 両引数ありに見えても通さない" {
    printf '%s\n' 'claude -p --tools "default" --setting-sources ""' > "$FX/scripts/a.sh"
    run scan "$FX"
    [[ "$output" == $'NG\tscripts/a.sh\t1\t--tools' ]]
}

@test "T-HCA-005: python の複数行 argv list — 両あり OK / 片方欠落 NG" {
    cat > "$FX/scripts/ok.py" <<'EOF'
r = subprocess.run(
    ['claude', '-p', '--tools', '', '--setting-sources', '',
     '--model', model],
    input=prompt)
EOF
    cat > "$FX/scripts/ng.py" <<'EOF'
r = subprocess.run(
    ['claude', '-p', '--tools', '',
     '--model', model],
    input=prompt)
EOF
    run scan "$FX"
    [[ "$output" == *$'OK\tscripts/ok.py\t2\t-'* ]]
    [[ "$output" == *$'NG\tscripts/ng.py\t2\t--setting-sources'* ]]
}

@test "T-HCA-006: 変数に入れた claude パス(claude_cmd)の argv list も拾う" {
    printf '%s\n' "x = subprocess.run([claude_cmd, '--model', m, '-p', prompt])" > "$FX/tests/b.sh"
    run scan "$FX"
    [[ "$output" == $'NG\ttests/b.sh\t1\t--tools,--setting-sources' ]]
}

@test "T-HCA-007: yaml の ai_command(エスケープされた空文字)は両あり OK / 欠落 NG" {
    printf '%s\n' 'ai_command: "claude --print --model opus --tools \"\" --setting-sources \"\""' > "$FX/skills/s/codd/ok.yaml"
    printf '%s\n' 'ai_command: "claude --print --model opus --tools \"\""' > "$FX/skills/s/codd/ng.yaml"
    run scan "$FX"
    [[ "$output" == *$'OK\tskills/s/codd/ok.yaml\t1\t-'* ]]
    [[ "$output" == *$'NG\tskills/s/codd/ng.yaml\t1\t--setting-sources'* ]]
}

@test "T-HCA-008: 起動でない行は拾わない(別 CLI・mkdir -p・説明文・対象外ディレクトリ・exempt 行)" {
    {
        echo 'kimi --print --quiet'
        echo 'if [ "$cli" = "claude" ]; then mkdir -p /x; fi'
        echo 'echo claude; tmux display-message -p x'
        echo 'claude -p --model x  # headless-audit-exempt: 陽性対照'
    } > "$FX/scripts/n.sh"
    printf '%s\n' 'claude -p --model x' > "$FX/docs/d.sh"
    printf '%s\n' 'claude -p --model x' > "$FX/scripts/readme.md"
    run scan "$FX"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ── 実ツリー ────────────────────────────────────────────

@test "T-HCA-009: 実ツリーに --tools \"\" / --setting-sources \"\" 欠落の起動箇所が無い" {
    run scan "$PROJECT_ROOT"
    [ "$status" -eq 0 ]
    ng="$(printf '%s\n' "$output" | /usr/bin/grep -c '^NG' || true)"
    if [ "${ng:-0}" != "0" ]; then
        echo "欠落あり:" >&2
        printf '%s\n' "$output" | /usr/bin/grep '^NG' >&2
    fi
    [ "${ng:-0}" = "0" ]
}

@test "T-HCA-010: 実ツリーで起動箇所が 1 件以上見つかる(検査器が何も見ずに合格しない)" {
    run scan "$PROJECT_ROOT"
    [ "$status" -eq 0 ]
    n="$(printf '%s\n' "$output" | /usr/bin/grep -c '^OK' || true)"
    [ "${n:-0}" -ge 1 ]
}
