#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""crlf_diff_check.py — CRLF/LF 混在ファイルの編集後健全性チェッカ(読み取り専用・cmd_800)。

## 何を止めるか
CRLF と LF が混在するファイルを部分編集すると、編集道具が触れていない行まで
ファイル全体の支配的な行末へ巻き込んで書き換えることがある。見た目の差分は
数行でも、行末だけが変わった行が大量に混ざる(改行由来の水増し)。この道具は
編集後のファイルを参照版(git の rev)と byte 単位で突き合わせ、次を判定する:

  - 内容が変わっていない行は、行末まで含めて参照版と byte 一致すること
  - `git diff --numstat` と `git diff --ignore-space-at-eol --numstat` の
    増減行数が一致すること(不一致なら行末の差だけで行数が膨らんでいる)

どちらかが崩れていれば非 0 で終わる。判定するだけで直さない(行末を書き換えない)。

## 行の対応の取り方
まず行末を除いた本文だけで参照版と現在の行を対応させ、本文が同じ行どうしの
行末を比べる。ただし同じ本文の行(空行など)が複数あると、byte 一致のまま
残っている既存行ではなく、新しく挿入した別の行末の行を対応させてしまい、
挿入しただけの編集を「行末だけが変わった」と誤認する(cmd_800 G800-01)。
そこで本文だけの対応で行末変化が出たときは、byte 一致する行を先に対応させ、
残りを本文で対応させた対応も作り、次の両方を満たすときだけ後者で判定する:

  - 行末だけが変わった行が本文だけの対応より少ない
  - 内容不変として対応した行数が本文だけの対応より減らない

二つ目の条件により、対応する行を減らして(削除・追加として扱って)行末変化を
見逃すことはない。どちらかを満たさなければ本文だけの対応で判定する。

## 出力(対象ファイルごと)
  - CRLF 行数・LF 行数・改行なしの行数(現在と参照版)
  - LF のみの行の行番号(現在と参照版・連続は範囲で縮める)
  - 参照版との最初の差分位置(行・桁・byte offset と、内容の差か行末の差か)
  - 内容不変の行のうち byte 一致した行数と、行末だけが変わった行の一覧
  - 内容が変わった行の行末内訳
  - 二つの numstat の値と一致・不一致
最後に対象ファイル数と OK/NG/エラーの内訳を出す。

## 参照版の内容
参照版は `git cat-file --filters <rev>:<path>` で取り出す。これは checkout が
作業木へ書き出す内容(.gitattributes の eol・core.autocrlf などの変換後)であり、
「編集前に作業木にあった姿」に当たる。blob の生の内容と変換後とで行末が
異なる場合は、その旨を注記する。

## 終了コード
  0  全対象が健全(参照版と同一の場合も 0。その旨を表示する)
  1  1 本以上が不健全(行末だけが変わった行がある・numstat が一致しない)
  2  使い方誤り・実行失敗。沈黙して 0 を返さないため、次はすべて 2 とする:
     対象が 0 本・rev が解決できない・参照版にファイルが無い・ファイルが無い・
     git の管理下にない・バイナリ・git の実行失敗
  エラーが 1 本でもあれば、他の対象の判定にかかわらず 2 で終わる。

## 読み取り専用
対象ファイルは読むだけで書き換えない。git は GIT_OPTIONAL_LOCKS=0 で呼び、
index の stat 情報の更新も行わせない。GIT_DIR / GIT_WORK_TREE を設定して
呼べば、その repository を参照版の取り出し元にする。

## 判定箇所の目印
判定の if 文には行末に `# judge:<名前>` を付けてある。試験はこの行の条件を
外した変異体を作り、試験がそれを検出できることを確かめる。目印を消したり
動かしたりするときは試験も直すこと。
"""

import argparse
import difflib
import os
import subprocess
import sys

EXIT_OK = 0
EXIT_NG = 1
EXIT_ERROR = 2

CRLF = "CRLF"
LF = "LF"
NONE = "改行なし"

# 行末の差分を一覧表示する件数の上限(行番号の範囲表示は全件出す)。
DETAIL_LIMIT = 10


class CheckError(Exception):
    """対象 1 本の判定を続けられない失敗(終了コード 2 に繋がる)。"""


def git_env():
    env = dict(os.environ)
    env["GIT_OPTIONAL_LOCKS"] = "0"
    env["GIT_LITERAL_PATHSPECS"] = "1"
    env["LC_ALL"] = "C"
    return env


def run_git(args, cwd):
    try:
        proc = subprocess.run(
            ["git", *args],
            cwd=cwd,
            env=git_env(),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    except OSError as exc:
        raise CheckError("git を起動できない: {}".format(exc))
    return proc


def git_stderr(proc):
    return proc.stderr.decode("utf-8", "replace").strip()


def split_lines(data):
    """\\n で区切り、行末を付けたまま返す(git と同じく \\n だけを区切りとみなす)。"""
    parts = data.split(b"\n")
    lines = [part + b"\n" for part in parts[:-1]]
    if parts[-1]:
        lines.append(parts[-1])
    return lines


def eol_of(line):
    if line.endswith(b"\r\n"):
        return CRLF
    if line.endswith(b"\n"):
        return LF
    return NONE


def body_of(line):
    if line.endswith(b"\r\n"):
        return line[:-2]
    if line.endswith(b"\n"):
        return line[:-1]
    return line


def eol_counts(lines):
    counts = {CRLF: 0, LF: 0, NONE: 0}
    for line in lines:
        counts[eol_of(line)] += 1
    return counts


def format_counts(lines):
    counts = eol_counts(lines)
    return "{}行(CRLF {} / LF {} / 改行なし {})".format(
        len(lines), counts[CRLF], counts[LF], counts[NONE]
    )


def format_ranges(numbers):
    if not numbers:
        return "(なし)"
    out = []
    start = prev = numbers[0]
    for num in numbers[1:]:
        if num == prev + 1:
            prev = num
            continue
        out.append(str(start) if start == prev else "{}-{}".format(start, prev))
        start = prev = num
    out.append(str(start) if start == prev else "{}-{}".format(start, prev))
    return ",".join(out)


def lf_only_line_numbers(lines):
    return [idx + 1 for idx, line in enumerate(lines) if eol_of(line) == LF]


def first_difference(ref, cur, ref_lines, cur_lines):
    """最初に異なる byte の位置を (説明文字列) で返す。同一なら None。"""
    if ref == cur:
        return None
    limit = min(len(ref), len(cur))
    offset = 0
    while offset < limit and ref[offset] == cur[offset]:
        offset += 1
    # 共通の接頭部は両者で同じなので、行・桁はどちらで数えても同じ。
    line_no = cur.count(b"\n", 0, offset) + 1
    col = offset - (cur.rfind(b"\n", 0, offset) + 1) + 1
    idx = line_no - 1
    if idx < len(ref_lines) and idx < len(cur_lines):
        if body_of(ref_lines[idx]) == body_of(cur_lines[idx]):
            kind = "行末の差({}→{})".format(
                eol_of(ref_lines[idx]), eol_of(cur_lines[idx])
            )
        else:
            kind = "内容の差"
    elif idx < len(cur_lines):
        kind = "現在の側にだけ行がある"
    else:
        kind = "参照版の側にだけ行がある"
    return "行{} 桁{}(byte offset {}・{})".format(line_no, col, offset, kind)


class Alignment:
    """参照版と現在の行の対応 1 通りと、そこから数えた判定材料。"""

    def __init__(self):
        self.identical = 0
        self.eol_changed = []  # (現在の行番号, 参照版の行番号, 参照の行末, 現在の行末)
        self.removed = 0
        self.added_lines = []
        self.ws_only = 0

    @property
    def matched(self):
        """内容不変として対応した行数(byte 一致 + 行末のみ変化)。"""
        return self.identical + len(self.eol_changed)


def align_bodies(ref_lines, cur_lines, i_lo, i_hi, j_lo, j_hi, result):
    """ref_lines[i_lo:i_hi] と cur_lines[j_lo:j_hi] を本文で対応させ result へ足す。"""
    matcher = difflib.SequenceMatcher(
        None,
        [body_of(line) for line in ref_lines[i_lo:i_hi]],
        [body_of(line) for line in cur_lines[j_lo:j_hi]],
        autojunk=False,
    )
    for tag, i1, i2, j1, j2 in matcher.get_opcodes():
        i1, i2, j1, j2 = i1 + i_lo, i2 + i_lo, j1 + j_lo, j2 + j_lo
        if tag == "equal":
            for offset in range(i2 - i1):
                ref_line = ref_lines[i1 + offset]
                cur_line = cur_lines[j1 + offset]
                if ref_line == cur_line:
                    result.identical += 1
                else:
                    result.eol_changed.append(
                        (j1 + offset + 1, i1 + offset + 1, eol_of(ref_line), eol_of(cur_line))
                    )
            continue
        result.removed += i2 - i1
        result.added_lines.extend(cur_lines[j1:j2])
        if tag == "replace" and i2 - i1 == j2 - j1:
            for offset in range(i2 - i1):
                ref_body = body_of(ref_lines[i1 + offset]).rstrip(b" \t\r\f\v")
                cur_body = body_of(cur_lines[j1 + offset]).rstrip(b" \t\r\f\v")
                if ref_body == cur_body:
                    result.ws_only += 1


def align_by_body(ref_lines, cur_lines):
    """行末を除いた本文だけで対応させる。"""
    result = Alignment()
    align_bodies(ref_lines, cur_lines, 0, len(ref_lines), 0, len(cur_lines), result)
    return result


def align_by_bytes_first(ref_lines, cur_lines):
    """行末まで byte 一致する行を先に対応させ、その間に残った行を本文で対応させる。"""
    result = Alignment()
    matcher = difflib.SequenceMatcher(None, ref_lines, cur_lines, autojunk=False)
    for tag, i1, i2, j1, j2 in matcher.get_opcodes():
        if tag == "equal":
            result.identical += i2 - i1
        else:
            align_bodies(ref_lines, cur_lines, i1, i2, j1, j2, result)
    return result


def choose_alignment(ref_lines, cur_lines):
    """判定に使う対応を (対応, 本文だけの対応) で返す(選び方は冒頭の説明を参照)。"""
    by_body = align_by_body(ref_lines, cur_lines)
    if not by_body.eol_changed:
        return by_body, by_body
    by_bytes = align_by_bytes_first(ref_lines, cur_lines)
    chosen = by_body
    if len(by_bytes.eol_changed) < len(by_body.eol_changed):  # judge:prefer-byte-match
        chosen = by_bytes
    if chosen.matched < by_body.matched:  # judge:keep-matched-lines
        chosen = by_body
    return chosen, by_body


def parse_numstat(proc, label):
    if proc.returncode != 0:
        raise CheckError("{} が失敗した: {}".format(label, git_stderr(proc)))
    text = proc.stdout.decode("utf-8", "replace").strip()
    if not text:
        return (0, 0)
    fields = text.splitlines()[0].split("\t")
    if len(fields) < 3 or fields[0] == "-" or fields[1] == "-":
        raise CheckError("{} が数値を返さない(バイナリ扱い?): {!r}".format(label, text))
    try:
        return (int(fields[0]), int(fields[1]))
    except ValueError:
        raise CheckError("{} の出力を解釈できない: {!r}".format(label, text))


def resolve_target(path, rev):
    """対象の (作業木の top, top からの相対パス, 解決済み commit) を返す。"""
    if not os.path.lexists(path):
        raise CheckError("ファイルが無い")
    if os.path.islink(path):
        raise CheckError("シンボリックリンクは対象外(リンク先を直接指定せよ)")
    if not os.path.isfile(path):
        raise CheckError("通常ファイルではない")
    abs_path = os.path.abspath(path)
    parent = os.path.realpath(os.path.dirname(abs_path))
    proc = run_git(["rev-parse", "--show-toplevel"], parent)
    if proc.returncode != 0:
        raise CheckError("git の作業木の外にある: {}".format(git_stderr(proc)))
    top = os.path.realpath(proc.stdout.decode("utf-8", "replace").strip())
    rel = os.path.relpath(os.path.join(parent, os.path.basename(abs_path)), top)
    if rel == os.curdir or rel.startswith(os.pardir + os.sep) or rel == os.pardir:
        raise CheckError("作業木 {} の外にある".format(top))
    if rev.startswith("-"):
        raise CheckError("rev が - で始まる: {!r}".format(rev))
    proc = run_git(["rev-parse", "--verify", "--quiet", rev + "^{commit}"], top)
    commit = proc.stdout.decode("utf-8", "replace").strip()
    if proc.returncode != 0 or not commit:  # judge:rev-unresolved
        raise CheckError("rev {!r} を commit に解決できない".format(rev))
    return top, rel, commit


def read_reference(top, rel, commit):
    spec = "{}:{}".format(commit, rel)
    proc = run_git(["cat-file", "-e", spec], top)
    if proc.returncode != 0:
        raise CheckError("参照版 {} にこのファイルが無い".format(commit[:12]))
    filtered = run_git(["cat-file", "--filters", spec], top)
    if filtered.returncode != 0:
        raise CheckError("参照版を取り出せない: {}".format(git_stderr(filtered)))
    raw = run_git(["cat-file", "blob", spec], top)
    if raw.returncode != 0:
        raise CheckError("参照版の blob を取り出せない: {}".format(git_stderr(raw)))
    return filtered.stdout, raw.stdout


def check_file(path, rev, out):
    """1 本を判定して "OK" / "NG" を返す。続けられなければ CheckError。"""
    top, rel, commit = resolve_target(path, rev)
    ref, raw_blob = read_reference(top, rel, commit)
    with open(os.path.join(top, rel), "rb") as handle:
        cur = handle.read()
    if b"\0" in cur or b"\0" in ref:
        raise CheckError("バイナリ(NUL を含む)は対象外")

    ref_lines = split_lines(ref)
    cur_lines = split_lines(cur)

    out.append("参照版: {} ({})".format(rev, commit[:12]))
    if eol_counts(split_lines(raw_blob)) != eol_counts(ref_lines):
        out.append(
            "  注記: blob の生の内容と checkout 変換後とで行末が異なる"
            "(.gitattributes / core.autocrlf)。変換後の内容と比べる"
        )
    out.append("行数: 現在 {}".format(format_counts(cur_lines)))
    out.append("      参照 {}".format(format_counts(ref_lines)))
    out.append("LFのみの行: 現在 {}".format(format_ranges(lf_only_line_numbers(cur_lines))))
    out.append("            参照 {}".format(format_ranges(lf_only_line_numbers(ref_lines))))

    first = first_difference(ref, cur, ref_lines, cur_lines)
    out.append("最初の差分: {}".format(first if first else "なし(参照版と byte 一致)"))

    # 本文で対応を取り、内容が同じ行どうしの行末を比べる(対応の選び方は冒頭)。
    alignment, by_body = choose_alignment(ref_lines, cur_lines)
    identical = alignment.identical
    eol_changed = alignment.eol_changed
    removed = alignment.removed
    added_lines = alignment.added_lines
    ws_only = alignment.ws_only
    if alignment is not by_body:
        out.append(
            "  注記: 本文だけで対応させると行末のみ変化 {}行と出るが、byte 一致の行を"
            "優先して対応させると {}行(内容不変として対応した行 {}→{}行)。後者で判定する".format(
                len(by_body.eol_changed), len(eol_changed), by_body.matched, alignment.matched
            )
        )

    out.append(
        "内容不変の行: {}行(byte一致 {} / 行末のみ変化 {})".format(
            identical + len(eol_changed), identical, len(eol_changed)
        )
    )
    added_counts = eol_counts(added_lines)
    out.append(
        "内容が変わった行: 参照から -{} / 現在へ +{}(追加・変更行の行末: CRLF {} / LF {} / 改行なし {})".format(
            removed, len(added_lines), added_counts[CRLF], added_counts[LF], added_counts[NONE]
        )
    )

    plain = parse_numstat(
        run_git(
            ["diff", "--no-ext-diff", "--no-textconv", "--no-renames", "--numstat",
             commit, "--", rel],
            top,
        ),
        "git diff --numstat",
    )
    ignore_eol = parse_numstat(
        run_git(
            ["diff", "--no-ext-diff", "--no-textconv", "--no-renames", "--numstat",
             "--ignore-space-at-eol", commit, "--", rel],
            top,
        ),
        "git diff --ignore-space-at-eol --numstat",
    )
    numstat_match = plain == ignore_eol
    out.append(
        "numstat: git diff +{} -{} / --ignore-space-at-eol +{} -{} → {}".format(
            plain[0], plain[1], ignore_eol[0], ignore_eol[1],
            "一致" if numstat_match else "不一致",
        )
    )

    problems = []
    if eol_changed:  # judge:eol-change
        transitions = {}
        for _, _, before, after in eol_changed:
            key = "{}→{}".format(before, after)
            transitions[key] = transitions.get(key, 0) + 1
        summary = "・".join("{} {}行".format(k, v) for k, v in sorted(transitions.items()))
        problems.append(
            "内容が変わっていないのに行末だけが変わった行が {} 行ある({}): 現在の行番号 {}".format(
                len(eol_changed), summary, format_ranges([row[0] for row in eol_changed])
            )
        )
        for cur_no, ref_no, before, after in eol_changed[:DETAIL_LIMIT]:
            problems.append("    行{}(参照 行{}): {}→{}".format(cur_no, ref_no, before, after))
        if len(eol_changed) > DETAIL_LIMIT:
            problems.append("    …ほか {} 行".format(len(eol_changed) - DETAIL_LIMIT))
    if not numstat_match:  # judge:numstat-mismatch
        detail = "行末(改行・行末空白)の差だけで git diff の行数が膨らんでいる"
        if ws_only:
            detail += "。行末空白だけを変えた行が {} 行ある".format(ws_only)
        problems.append(
            "numstat 不一致(+{} -{} 対 +{} -{}): {}".format(
                plain[0], plain[1], ignore_eol[0], ignore_eol[1], detail
            )
        )

    if problems:
        out.append("判定: NG")
        out.extend("  - " + line if not line.startswith("    ") else line for line in problems)
        return "NG"
    if first is None:
        out.append("判定: OK(注意: 参照版と同一。編集前の版を --rev に指定したか確かめよ)")
    else:
        out.append("判定: OK")
    return "OK"


def build_parser():
    parser = argparse.ArgumentParser(
        prog="crlf_diff_check.py",
        description=(
            "CRLF/LF 混在ファイルを編集した後、内容を変えていない行の行末が変わって"
            "いないこと(改行由来の水増しが無いこと)を参照版と byte 単位で突き合わせて"
            "判定する。読み取り専用・判定のみ(直さない)。"
        ),
        epilog=(
            "終了コード: 0=健全 / 1=不健全 / 2=使い方誤り・実行失敗"
            "(対象 0 本・rev 未解決・参照版にファイルが無い等も 2)。"
            "例: python3 scripts/crlf_diff_check.py --rev HEAD CLAUDE.md"
        ),
    )
    parser.add_argument(
        "--rev",
        default="HEAD",
        help="参照版にする git の rev(既定: HEAD)。編集前の版を指す rev を与える",
    )
    parser.add_argument("files", nargs="*", metavar="FILE", help="判定するファイル(1 本以上)")
    return parser


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)
    if not args.files:  # judge:no-target
        print("エラー: 対象ファイルが 0 本。判定するファイルを 1 本以上指定せよ", file=sys.stderr)
        parser.print_usage(sys.stderr)
        return EXIT_ERROR

    results = {"OK": 0, "NG": 0, "エラー": 0}
    for path in args.files:
        out = []
        print("=== {} ===".format(path))
        try:
            verdict = check_file(path, args.rev, out)
        except CheckError as exc:
            verdict = "エラー"
            for line in out:
                print(line)
            print("判定: エラー — {}".format(exc))
            print("エラー: {}: {}".format(path, exc), file=sys.stderr)
        else:
            for line in out:
                print(line)
        results[verdict] += 1
        print()

    total = sum(results.values())
    print("=== 集計 ===")
    print(
        "対象ファイル数: {}(OK {} / NG {} / エラー {})".format(
            total, results["OK"], results["NG"], results["エラー"]
        )
    )
    if results["エラー"]:
        return EXIT_ERROR
    if results["NG"]:
        return EXIT_NG
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
