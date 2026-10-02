#!/usr/bin/env bash
# bats_tmpdir_guard.sh — TMPDIR が未設定または絶対パスの時だけ bats を起動する
# wrapper(cmd_800)。
#
# 背景: 試験の setup で `mktemp -d` が返したパスを、teardown で `rm -rf` に渡す
# 形は、そのパスが絶対パスである時に限り、作ったディレクトリそのものを指すと
# 言える(CLAUDE.md D002-E1(d))。`mktemp -d` は template を与えなければ TMPDIR
# の下に作り、TMPDIR が相対(例: TMPDIR=tmp)なら相対パス(tmp/tmp.XXXXXX)を返す。
# bats も BATS_TMPDIR="${TMPDIR:-/tmp}" と TMPDIR を引き継ぐ。どちらも試験の
# コードからは防げず、起動する側の環境で決まる。この wrapper は起動の手前で
# TMPDIR を確かめ、相対なら bats を起動しない(fail-closed)。
#
# 使い方: bats の代わりにこれを呼ぶ。引数は一切解釈せず、そのまま bats へ渡す
#   (--help なども bats 自身へ渡る)。
#     bash scripts/bats_tmpdir_guard.sh tests/unit/
#     bash scripts/bats_tmpdir_guard.sh --timing tests/unit/test_foo.bats
#
# 判定:
#   TMPDIR 未設定           → bats を起動する
#   TMPDIR が / で始まる    → bats を起動する(値は書き換えない)
#   それ以外(空文字を含む) → bats を起動せず、理由を stderr に出して終了コード 2
#     ※空文字は bats や mktemp の多くの実装では /tmp 扱いになるが、「未設定」でも
#       「絶対パス」でもないため通さない。unset TMPDIR で外してから呼べ。
#   bats が PATH に無い     → 終了コード 127
# bats を起動した場合の終了コードは bats のものがそのまま返る(exec で置き換える)。
#
# 範囲: 確かめるのは TMPDIR だけである。bats の --tempdir など引数側の指定や、
# TMPDIR が指す場所の実在・権限は確かめない。
#
# 判定の if 文の行末には `# judge:tmpdir-absolute` を付けてある。試験はこの行の
# 条件を外した変異体で、試験が判定の欠落を検出できることを確かめる。
set -u

if [[ "${TMPDIR+set}" == set && "${TMPDIR}" != /* ]]; then  # judge:tmpdir-absolute
    printf 'エラー: TMPDIR が絶対パスではない(TMPDIR=%q)。bats を起動しない。\n' "$TMPDIR" >&2
    cat >&2 <<'EOF'
  相対の TMPDIR の下では mktemp -d が相対パスを返し、試験の後始末(rm -rf "$dir")が
  実行時の作業ディレクトリ次第の場所を指してしまう(CLAUDE.md D002-E1(d) の対象外)。
  TMPDIR を外す(unset TMPDIR)か、絶対パスにして(例: export TMPDIR=/tmp)再実行せよ。
EOF
    exit 2
fi

if ! command -v bats >/dev/null 2>&1; then
    echo "エラー: bats が PATH に見つからない" >&2
    exit 127
fi

exec bats "$@"
