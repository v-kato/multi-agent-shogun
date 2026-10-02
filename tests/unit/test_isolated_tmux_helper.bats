#!/usr/bin/env bats
# test_isolated_tmux_helper.bats — scripts/isolated_tmux.sh の単体試験
# (cmd_758・隔離tmuxサーバの汎用helper・redo2)
#
# ★本試験は実tmuxサーバを使う(このリポジトリの e2e/unit 試験は既に
#   tmuxの実在を前提としている。tests/e2e/helpers/tmux_helpers.bash 等
#   参照)。ただし★稼働中の agent pane (multiagent/shogun ソケット)には
#   一切触れない。各テストが自分専用の隔離socket(create -Lの結果、
#   毎回新規private socket parent配下に作られる)を使い、本helper自身
#   の teardown で片付ける。
#
# ★D006(Tier1絶対禁止): 本試験ファイルも kill-server/kill-session/
#   kill-pane/kill系コマンドを一切使わない。後始末は helper の
#   teardown、または(handle自体を意図的に壊した試験に限り)対象paneへ
#   直接`exit`キーを送るraw_exit_pane()だけで行う。
#
# ★redo2(本版): G758R1-*-01〜05是正に伴い、以下の構造変更を反映する。
#   (1) SOURCED-RAW-BYPASS-01是正によりsourceは全廃された。旧来
#       source経由で内部関数を直接呼ぶ試験は行えない(そもそも
#       source自体が拒否されるため)。
#   (2) HANDLE-PROVENANCE-02是正により、handle fileは専用領域直下・
#       非symlink・createが実際にinstallした(dev,inode)がregistryに
#       登録済み、の3点を満たさなければ内容の正しさに関わらず拒否
#       される。★そのため、schema検証(exact-schema)だけを単体で
#       試す既存試験は、コピー(cpやmktemp+grep -v等)ではなく
#       TEST_HANDLE自身をin-place編集する形に改めた——コピーは
#       provenance検証で先に(異なるメッセージで)拒否されてしまう
#       ため、schema検証本体まで到達できなくなるからである。
#       in-place書き戻し(既存fileへの`>`によるtruncate上書き・追記)は
#       fileのinode/dev(=registryの鍵)を変えないため、provenance検証を
#       素通りしてschema検証本体へ到達できる。★`sed -i`は使わない——
#       GNU sedの`-i`は一時fileへ書いてrenameする実装であり、この環境
#       では実測でinode/devが変わることを確認した(sed -iで書き換えると
#       provenance検証に先に〈異なるメッセージで〉拒否され、schema検証
#       本体へ到達できなくなる)。sedはパイプで使い、結果は`>`で既存
#       fileへtruncate書き戻す(tamper_handle_field_inplace参照)。
#       TEST_HANDLE自体を壊した試験では、bats標準のteardown()フック
#       (helper経由)がもう使えないため、raw_exit_pane()で実paneへ直接
#       exitを送って後始末する。
#   (3) PREEXISTING-SERVER-ATTACH-03是正により、各createは独立した
#       socket_pathを得る(`-L`名を再利用しても同じsocket_pathには
#       ならない)。そのため既存試験群で `tmux -L "$TEST_SOCK" ...` と
#       直接叩いていた箇所は、handle fileから実際のSOCKET_PATHを
#       読み取って `tmux -S "$SOCKET_PATH" ...` を使う形に改めた。

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    HELPER="$PROJECT_ROOT/scripts/isolated_tmux.sh"
    # ★試験ごとに一意なソケット名(BATS_TEST_NUMBER+PID+RANDOMで衝突回避)。
    #   'cmd758test' を含めても multiagent/shogun/default は含まない。
    TEST_SOCK="cmd758test_${BATS_TEST_NUMBER}_$$_${RANDOM}"
    TEST_HANDLE=""
}

teardown() {
    # ★各試験が自分でteardown済みならこれは冪等に何もしない
    #   (対象paneが既に無ければ何もしない、と helper 自身が保証する)。
    #   ★killは使わない。helperのteardownだけを呼ぶ。
    if [ -n "${TEST_HANDLE:-}" ] && [ -f "$TEST_HANDLE" ]; then
        bash "$HELPER" teardown "$TEST_HANDLE" >/dev/null 2>&1 || true
        rm -f "$TEST_HANDLE"
    fi
}

# handle file から1 fieldの値だけを取り出す。
handle_field() {
    /usr/bin/grep -E "^${2}=" "$1" | cut -d= -f2-
}

# handle file 中の 1 field だけを書き換えたコピーを作る(残りは温存)。
# ★値はどれも英数字・記号少数の識別子/数値/日時であり、sedのメタ文字を
#   含まないことを呼出側で保証する(本試験内でしか使わない小道具)。
# ★注意: コピー先(dest)は provenance 検証(専用領域直下・登録済み
#   inode)を満たさないため、schema検証を単体で試す用途には使えない
#   (redo2以降は tamper_handle_field_inplace を使うこと)。copy自体の
#   拒否を確かめる試験でのみ使う。
tamper_handle_field() {
    local src="$1" key="$2" new_value="$3" dest="$4"
    sed "s|^${key}=.*|${key}=${new_value}|" "$src" > "$dest"
}

# handle file を in-place で書き換える(inode/dev は変わらないため
# provenance検証=registry照合は保たれる。schema/identity検証だけを
# 単体で試すために使う・G758R1-02是正)。
# ★`sed -i`は使わない。GNU sedの`-i`は一時fileへ書いてrenameする実装
#   であり、この環境ではinode/devが変わることを実測で確認した(隔離
#   検証済み・sed -iで書き換えるとprovenance検証に先に〈異なる
#   メッセージで〉拒否されてしまい、schema/identity検証本体へ到達
#   できなくなる)。sedはパイプで使って変換結果だけを変数へ受け取り、
#   既存fileへは`>`でtruncate書き戻す——`>`は既存の directory entry を
#   そのまま使い、O_TRUNCで中身だけを差し替えるためinode/devを保つ。
tamper_handle_field_inplace() {
    local file="$1" key="$2" new_value="$3"
    local content
    content="$(sed "s|^${key}=.*|${key}=${new_value}|" "$file")"
    printf '%s\n' "$content" > "$file"
}

# ★helperを経由せず、既知のsocket_path/pane_idへ直接exitを送るだけの
#   後始末専用関数(killは使わない)。TEST_HANDLE自体を意図的に壊した
#   試験(provenance/schema/identity違反を作る試験)で、実paneを自然
#   終了させるために使う。
raw_exit_pane() {
    local sock_path="$1" pane_id="$2"
    tmux -S "$sock_path" send-keys -t "$pane_id" "exit" Enter 2>/dev/null || true
}

# ★cmd_795: 起動からの経過(ミリ秒)を /proc/uptime から得る。壁時計
#   (date)は段差・巻き戻しがありうるため、経過の計測には使わない。
uptime_ms() {
    local u
    read -r u _ < /proc/uptime
    echo $(( ${u%.*} * 1000 + 10#${u#*.} * 10 ))
}

# ★cmd_795: helperが使うtmuxを差し替えるshim(T-IT-039と同型・PATHの先頭
#   に置き、helperの`command -v tmux`に拾わせる)。shimは$BATS_TEST_TMPDIR
#   (batsが試験ごとに作り、試験後に自ら片付ける)に置くため、本試験は
#   後始末のrmを書かない。
#   mode=nohook     : set-hook(pane-exitedの通知producer設置)だけを、
#                     何も設置せずに成功を装う。他は実tmuxへ通す。
#   mode=stuckwait  : nohookに加え、待受け側の`wait-for <chan>`を、通知が
#                     永久に来ないclient(戻らない待受け)に置き換える。
#                     本日の停滞(serverは消えた/消えかけているのに待受け
#                     clientが戻らない)を、helperから見て同じ形で再現する。
#                     execで置き換えるため、timeout(1)の直接の子はこの
#                     待受けそのものである。
make_tmux_shim() {
    local mode="$1" shim_dir real_tmux
    shim_dir="${BATS_TEST_TMPDIR}/shim_${mode}"
    mkdir -p "$shim_dir"
    real_tmux="$(command -v tmux)"
    cat > "$shim_dir/tmux" <<SHIM
#!/usr/bin/env bash
# helperの呼び方: -S <socket_path> <subcommand> ...
case "\${3:-}" in
    set-hook)
        exit 0
        ;;
    wait-for)
        if [ "$mode" = "stuckwait" ] && [ "\${4:-}" != "-S" ]; then
            exec sleep 30
        fi
        ;;
esac
exec "$real_tmux" "\$@"
SHIM
    chmod +x "$shim_dir/tmux"
    echo "$shim_dir"
}

# ★cmd_795: 指定socketへの待受け(wait-for)clientが何本残っているかを
#   /proc/*/cmdline の読取りだけで数える(何も送らない)。
count_waitfor_clients() {
    local sock_path="$1" f c n=0
    for f in /proc/[0-9]*/cmdline; do
        c="$(tr '\0' ' ' < "$f" 2>/dev/null)" || continue
        case "$c" in
            (*"$sock_path"*"wait-for"*) n=$((n + 1)) ;;
        esac
    done
    echo "$n"
}

# ═══════════════════════════════════════════════════════
# A-2: -L 必須・既定ソケット/multiagent/shogunを含む名の拒否
#      (T-IT-001〜007: 前回redoで合格済み・変更禁止)
# ═══════════════════════════════════════════════════════

@test "T-IT-001: create は -L 未指定だとエラーで終わる(既定ソケット禁止)" {
    run bash "$HELPER" create
    [ "$status" -ne 0 ]
    [[ "$output" == *"必須"* ]]
}

@test "T-IT-002: create は -L に空文字列を渡してもエラーで終わる" {
    run bash "$HELPER" create -L ""
    [ "$status" -ne 0 ]
    [[ "$output" == *"必須"* ]]
}

@test "T-IT-003: create は 'multiagent' を含むソケット名を拒否する" {
    run bash "$HELPER" create -L "multiagent_probe"
    [ "$status" -ne 0 ]
    [[ "$output" == *"含めることはできない"* ]]
}

@test "T-IT-004: create は 'shogun' を含むソケット名を拒否する" {
    run bash "$HELPER" create -L "my_shogun_probe"
    [ "$status" -ne 0 ]
    [[ "$output" == *"含めることはできない"* ]]
}

@test "T-IT-005: create は英数字・_・.・- 以外を含むソケット名を拒否する" {
    run bash "$HELPER" create -L "bad;name"
    [ "$status" -ne 0 ]
    [[ "$output" == *"使える文字"* ]]
}

# ═══════════════════════════════════════════════════════
# A-5: helper本体にD006該当コマンド群の綴りが1つも無いこと
#      (cmd_754のT-PF-100が send-keys 出現数0を検査するのと同型)
# ═══════════════════════════════════════════════════════

@test "T-IT-006: isolated_tmux.sh の実コードに kill 系文字列が1つも無い(大小文字問わず)" {
    run bash -c "/usr/bin/grep -ci 'kill' '$HELPER' || true"
    [ "$output" = "0" ]
}

@test "T-IT-007: isolated_tmux.sh の実コードに busy polling 用の sleep 呼出しが無い(F004・イベント駆動)" {
    # ★コメント中の説明文(「固定sleepは使わない」等)は対象外とし、
    #   コメント行を除いた実コードだけを検査する(T-PF-020と同型)。
    run bash -c "/usr/bin/grep -v '^[[:space:]]*#' '$HELPER' | /usr/bin/grep -c 'sleep' || true"
    [ "$output" = "0" ]
}

# ═══════════════════════════════════════════════════════
# A-3・A-4・A-6・A-7: create→teardown の一連(実tmux)
# ═══════════════════════════════════════════════════════

@test "T-IT-008: create は素のシェルpaneのみを作る(agent CLIは起動しない)" {
    TEST_HANDLE="$(bash "$HELPER" create -L "$TEST_SOCK")"
    [ -f "$TEST_HANDLE" ]
    local sock_path
    sock_path="$(handle_field "$TEST_HANDLE" SOCKET_PATH)"

    run tmux -S "$sock_path" list-panes -a -F '#{pane_current_command}'
    [ "$status" -eq 0 ]
    [ "$output" = "bash" ]
}

@test "T-IT-009: handle file には exact-schema の全 9 field が書き出される(G758-02/04是正)" {
    TEST_HANDLE="$(bash "$HELPER" create -L "$TEST_SOCK")"
    run cat "$TEST_HANDLE"
    [[ "$output" == *"SOCKET=${TEST_SOCK}"* ]]
    [[ "$output" == *"SOCKET_PATH=/"* ]]
    [[ "$output" == *"SESSION="* ]]
    [[ "$output" == *"PANE_ID=%"* ]]
    [[ "$output" == *"SERVER_PID="* ]]
    [[ "$output" == *"SERVER_STARTTIME="* ]]
    [[ "$output" == *"PANE_PID="* ]]
    [[ "$output" == *"PANE_STARTTIME="* ]]
    [[ "$output" == *"CREATED_AT="* ]]
}

@test "T-IT-010: teardown 後、隔離tmuxサーバは自然終了している" {
    TEST_HANDLE="$(bash "$HELPER" create -L "$TEST_SOCK")"
    local sock_path
    sock_path="$(handle_field "$TEST_HANDLE" SOCKET_PATH)"

    run bash "$HELPER" teardown "$TEST_HANDLE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"自然終了した"* ]]

    run tmux -S "$sock_path" has-session
    [ "$status" -ne 0 ]
}

@test "T-IT-011: teardown は同じ handle file に対して冪等である(2回目は何もしない)" {
    TEST_HANDLE="$(bash "$HELPER" create -L "$TEST_SOCK")"
    bash "$HELPER" teardown "$TEST_HANDLE"

    run bash "$HELPER" teardown "$TEST_HANDLE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"既に存在しない"* ]]
}

@test "T-IT-012: teardown は存在しない handle file に対してエラーで終わる" {
    run bash "$HELPER" teardown "/tmp/nonexistent_handle_for_cmd758_test_${RANDOM}"
    [ "$status" -ne 0 ]
    [[ "$output" == *"存在しない"* ]]
}

@test "T-IT-013: teardown は引数無しだと使い方を示してエラーで終わる(手で組んだ識別子を渡す経路が無い)" {
    run bash "$HELPER" teardown
    [ "$status" -ne 0 ]
    [[ "$output" == *"使い方"* ]]
}

@test "T-IT-014: teardown は handle file の SOCKET が不正な形式なら fail-closed で拒否する" {
    TEST_HANDLE="$(bash "$HELPER" create -L "$TEST_SOCK")"
    local sock_path pane_id
    sock_path="$(handle_field "$TEST_HANDLE" SOCKET_PATH)"
    pane_id="$(handle_field "$TEST_HANDLE" PANE_ID)"
    # ★provenance検証(専用領域直下・登録済みinode)を保ったまま
    #   schema検証だけを単体で試すため、コピーではなくTEST_HANDLE
    #   自身をin-place編集する(G758R1-02是正)。
    tamper_handle_field_inplace "$TEST_HANDLE" "SOCKET" "my_shogun_hand_edited"

    run bash "$HELPER" teardown "$TEST_HANDLE"
    [ "$status" -ne 0 ]
    [[ "$output" == *"SOCKET が不正"* ]]

    # ★TEST_HANDLEの内容を壊したためhelper経由の後始末は使えない。
    #   実paneへ直接exitを送って片付ける(helper未経由・kill不使用)。
    raw_exit_pane "$sock_path" "$pane_id"
}

@test "T-IT-015: teardown は handle file の PANE_ID が閉じた形式(%数字)でなければ拒否する" {
    TEST_HANDLE="$(bash "$HELPER" create -L "$TEST_SOCK")"
    local sock_path pane_id
    sock_path="$(handle_field "$TEST_HANDLE" SOCKET_PATH)"
    pane_id="$(handle_field "$TEST_HANDLE" PANE_ID)"
    tamper_handle_field_inplace "$TEST_HANDLE" "PANE_ID" "not_a_pane_id"

    run bash "$HELPER" teardown "$TEST_HANDLE"
    [ "$status" -ne 0 ]
    [[ "$output" == *"PANE_ID が不正"* ]]

    raw_exit_pane "$sock_path" "$pane_id"
}

# ═══════════════════════════════════════════════════════
# G758R1-SOURCED-RAW-BYPASS-01是正: sourceの完全拒否
# ═══════════════════════════════════════════════════════

@test "T-IT-016: isolated_tmux.sh は source すると即座に拒否される(rc!=0・エラーメッセージ)" {
    run bash <<SCRIPT
source "$HELPER"
SCRIPT
    [ "$status" -ne 0 ]
    [[ "$output" == *"sourceして使うことはできない"* ]]
}

@test "T-IT-017: source前後でdeclare -Fの件数が増えない(sourceが1つも関数を定義しないことの証明)" {
    # ★bats自体が環境へ関数をexportしている(実測: 何も source しない
    #   状態でも nested bash の declare -F | wc -l は 1 である)ため、
    #   絶対値0との比較はbatsの実行環境に依存し誤検出する。source前後の
    #   差分(before/after)を取ることで、この環境由来の漏れ件数を
    #   打ち消し、helperのsourceが正味で何個の関数を追加したかだけを見る。
    run bash <<SCRIPT
before=\$(declare -F | wc -l)
source "$HELPER" 2>/dev/null
after=\$(declare -F | wc -l)
echo "\$((after - before))"
SCRIPT
    [ "$status" -eq 0 ]
    [ "$output" -eq 0 ]
}

@test "T-IT-018: source後、tmuxを呼べる関数を名指しで列挙しても1つも定義されていない(列挙試験・G758R1-SOURCED-RAW-BYPASS-01是正)" {
    run bash <<SCRIPT
source "$HELPER" >/dev/null 2>&1
leaked=0
for fn in _itmux_wait_for_pane_exit _itmux_cmd_create _itmux_cmd_teardown \
          _itmux_reverify_identity _itmux_handle_install _itmux_handle_read \
          _itmux_handle_verify_provenance _itmux_create_failure_cleanup \
          _itmux_create_fail _itmux_secure_dir_ensure \
          _itmux_main itmux_validate_socket_name _itmux_proc_starttime \
          _itmux_resolve_wait_limit; do
    if declare -F "\$fn" >/dev/null 2>&1; then
        echo "LEAKED:\${fn}"
        leaked=1
    fi
done
[ "\$leaked" -eq 0 ] && echo ALL_CLEAR
SCRIPT
    [ "$status" -eq 0 ]
    [[ "$output" == "ALL_CLEAR" ]]
}

# ═══════════════════════════════════════════════════════
# G758-01是正: 'default' の明示拒否(既定socketへの到達経路を塞ぐ)
# ═══════════════════════════════════════════════════════

@test "T-IT-019: create -L default はエラーで終わり、tmuxセッションは一切作られない" {
    run bash "$HELPER" create -L "default"
    [ "$status" -ne 0 ]
    [[ "$output" == *"含めることはできない"* ]]
}

@test "T-IT-020: create -L my_default_probe (defaultを部分文字列に含む名)も拒否する" {
    run bash "$HELPER" create -L "my_default_probe"
    [ "$status" -ne 0 ]
    [[ "$output" == *"含めることはできない"* ]]
}

@test "T-IT-021: teardown は SOCKET=default へ改竄されたhandleを、実tmux呼出し無しに fail-closed で拒否する" {
    TEST_HANDLE="$(bash "$HELPER" create -L "$TEST_SOCK")"
    local sock_path pane_id
    sock_path="$(handle_field "$TEST_HANDLE" SOCKET_PATH)"
    pane_id="$(handle_field "$TEST_HANDLE" PANE_ID)"
    # ★provenanceを保ったままSOCKETのschema検証を単体で試すため、
    #   TEST_HANDLE自身をin-place編集する。_itmux_handle_readはSOCKET
    #   検査で先にdieするため、この改竄handleを渡しても本番default
    #   socketへtmuxコマンドは発行されない。
    tamper_handle_field_inplace "$TEST_HANDLE" "SOCKET" "default"

    run bash "$HELPER" teardown "$TEST_HANDLE"
    [ "$status" -ne 0 ]
    [[ "$output" == *"SOCKET が不正"* ]]

    raw_exit_pane "$sock_path" "$pane_id"
}

# ═══════════════════════════════════════════════════════
# G758-04是正: 任意path上書き(-o)の廃止
# ═══════════════════════════════════════════════════════

@test "T-IT-022: create は -o オプションを受け付けない(任意path上書きの廃止)" {
    run bash "$HELPER" create -L "$TEST_SOCK" -o "/tmp/cmd758_should_not_be_used_${RANDOM}"
    [ "$status" -ne 0 ]
}

# ═══════════════════════════════════════════════════════
# G758-02是正: handleのexact-schema(未知行・重複key・欠落key)
# ═══════════════════════════════════════════════════════

@test "T-IT-023: teardown は必須keyが1つでも欠落したhandleを拒否する(exact-schema)" {
    TEST_HANDLE="$(bash "$HELPER" create -L "$TEST_SOCK")"
    local sock_path pane_id
    sock_path="$(handle_field "$TEST_HANDLE" SOCKET_PATH)"
    pane_id="$(handle_field "$TEST_HANDLE" PANE_ID)"
    # ★sed -i は使わない(inode/devが変わりprovenance検証で先に拒否
    #   されてしまう・tamper_handle_field_inplace冒頭コメント参照)。
    #   sedはパイプで使い、`>`で既存fileへtruncate書き戻す。
    local content
    content="$(sed '/^SERVER_PID=/d' "$TEST_HANDLE")"
    printf '%s\n' "$content" > "$TEST_HANDLE"

    run bash "$HELPER" teardown "$TEST_HANDLE"
    [ "$status" -ne 0 ]
    [[ "$output" == *"必須keyが欠落している"* ]]
    [[ "$output" == *"SERVER_PID"* ]]

    raw_exit_pane "$sock_path" "$pane_id"
}

@test "T-IT-024: teardown はkeyが重複したhandleを拒否する(exact-schema)" {
    TEST_HANDLE="$(bash "$HELPER" create -L "$TEST_SOCK")"
    local sock_path pane_id
    sock_path="$(handle_field "$TEST_HANDLE" SOCKET_PATH)"
    pane_id="$(handle_field "$TEST_HANDLE" PANE_ID)"
    echo "SESSION=other_session" >> "$TEST_HANDLE"

    run bash "$HELPER" teardown "$TEST_HANDLE"
    [ "$status" -ne 0 ]
    [[ "$output" == *"重複がある"* ]]

    raw_exit_pane "$sock_path" "$pane_id"
}

@test "T-IT-025: teardown は閉じた列挙に無いkeyを含むhandleを拒否する(exact-schema・未知行を無視しない)" {
    TEST_HANDLE="$(bash "$HELPER" create -L "$TEST_SOCK")"
    local sock_path pane_id
    sock_path="$(handle_field "$TEST_HANDLE" SOCKET_PATH)"
    pane_id="$(handle_field "$TEST_HANDLE" PANE_ID)"
    echo "EXTRA_FIELD=whatever" >> "$TEST_HANDLE"

    run bash "$HELPER" teardown "$TEST_HANDLE"
    [ "$status" -ne 0 ]
    [[ "$output" == *"未知のkeyがある"* ]]

    raw_exit_pane "$sock_path" "$pane_id"
}

@test "T-IT-026: teardown はKEY=VALUE形式でない生行を含むhandleを拒否する(exact-schema)" {
    TEST_HANDLE="$(bash "$HELPER" create -L "$TEST_SOCK")"
    local sock_path pane_id
    sock_path="$(handle_field "$TEST_HANDLE" SOCKET_PATH)"
    pane_id="$(handle_field "$TEST_HANDLE" PANE_ID)"
    echo "THIS IS NOT KEY VALUE" >> "$TEST_HANDLE"

    run bash "$HELPER" teardown "$TEST_HANDLE"
    [ "$status" -ne 0 ]
    [[ "$output" == *"未知形式の行がある"* ]]

    raw_exit_pane "$sock_path" "$pane_id"
}

# ═══════════════════════════════════════════════════════
# G758-02是正: 送信直前の instance identity 再照合 (fail-closed)
# ═══════════════════════════════════════════════════════

@test "T-IT-027: teardown は PANE_PID が記録と不一致なら拒否し、実pane には何も送らない" {
    TEST_HANDLE="$(bash "$HELPER" create -L "$TEST_SOCK")"
    local sock_path pane_id
    sock_path="$(handle_field "$TEST_HANDLE" SOCKET_PATH)"
    pane_id="$(handle_field "$TEST_HANDLE" PANE_ID)"
    tamper_handle_field_inplace "$TEST_HANDLE" "PANE_PID" "999999"

    run bash "$HELPER" teardown "$TEST_HANDLE"
    [ "$status" -ne 0 ]
    [[ "$output" == *"pane pidが記録と不一致"* ]]

    # ★実paneは無傷で生き残っている(fail-closedで何も送っていない証拠)。
    run tmux -S "$sock_path" list-panes -a -F '#{pane_current_command}'
    [ "$status" -eq 0 ]
    [ "$output" = "bash" ]

    raw_exit_pane "$sock_path" "$pane_id"
}

@test "T-IT-028: teardown は SERVER_PID が記録と不一致なら拒否し、実paneには何も送らない" {
    TEST_HANDLE="$(bash "$HELPER" create -L "$TEST_SOCK")"
    local sock_path pane_id
    sock_path="$(handle_field "$TEST_HANDLE" SOCKET_PATH)"
    pane_id="$(handle_field "$TEST_HANDLE" PANE_ID)"
    tamper_handle_field_inplace "$TEST_HANDLE" "SERVER_PID" "999999"

    run bash "$HELPER" teardown "$TEST_HANDLE"
    [ "$status" -ne 0 ]
    [[ "$output" == *"server pidが記録と不一致"* ]]

    run tmux -S "$sock_path" list-panes -a -F '#{pane_current_command}'
    [ "$status" -eq 0 ]
    [ "$output" = "bash" ]

    raw_exit_pane "$sock_path" "$pane_id"
}

@test "T-IT-029: 同一socket_pathが後発serverに再利用されても、旧handleでは新paneにexitを送れない(G758-02最重要シナリオ・private socket parent配下でも維持)" {
    # ① 1台目のserverを作りteardownで自然終了させる(socket_pathの
    #    file自体は残骸として残る)。
    HANDLE1="$(bash "$HELPER" create -L "$TEST_SOCK")"
    local sock_path1
    sock_path1="$(handle_field "$HANDLE1" SOCKET_PATH)"
    run bash "$HELPER" teardown "$HANDLE1"
    [ "$status" -eq 0 ]

    # ② ★G758R1-03是正後はcreateが自然に同一socket_pathへ衝突する
    #    ことは無いため、このscenario(同一pathに後発serverが立つ)は
    #    raw tmuxで意図的に再現する(旧1台目の残骸socket file上に
    #    新serverを直接立てる)。
    tmux -S "$sock_path1" new-session -d -s iso -n w0 bash
    local pane_id2
    pane_id2="$(tmux -S "$sock_path1" display-message -t iso:w0.0 -p '#{pane_id}')"

    # ③ 失効したHANDLE1を使ってteardownしようとしても拒否される
    #    (server pid/starttimeが記録=1台目・現在=2台目で不一致になるため)。
    run bash "$HELPER" teardown "$HANDLE1"
    [ "$status" -ne 0 ]
    [[ "$output" == *"不一致"* ]]

    # ★2台目のpaneは無傷(旧handleが2台目を誤って終わらせていない証拠)。
    run tmux -S "$sock_path1" list-panes -a -F '#{pane_current_command}'
    [ "$status" -eq 0 ]
    [ "$output" = "bash" ]

    raw_exit_pane "$sock_path1" "$pane_id2"
}

@test "T-IT-030: pane が exec で bash から置換された後は teardown が拒否する(PID/starttimeは保たれるがpane_current_commandが変わる)" {
    TEST_HANDLE="$(bash "$HELPER" create -L "$TEST_SOCK")"
    local sock_path pane_id
    sock_path="$(handle_field "$TEST_HANDLE" SOCKET_PATH)"
    pane_id="$(handle_field "$TEST_HANDLE" PANE_ID)"

    tmux -S "$sock_path" send-keys -t "$pane_id" "exec sleep 5" Enter

    # ★execによる置換の反映を待つ(pane_current_commandがsleepになるまで)。
    #   本試験ファイル固有の同期用ポーリングであり、helper本体(T-IT-007
    #   検査対象)には含まれない。上限3秒。
    local_cmd=""
    for _ in $(seq 1 30); do
        local_cmd="$(tmux -S "$sock_path" display-message -t "$pane_id" -p '#{pane_current_command}' 2>/dev/null)"
        [ "$local_cmd" = "sleep" ] && break
        sleep 0.1
    done
    [ "$local_cmd" = "sleep" ]

    run bash "$HELPER" teardown "$TEST_HANDLE"
    [ "$status" -ne 0 ]
    [[ "$output" == *"pane_current_commandがbashでない"* ]]

    # ★後始末はteardown()フックに委ねる(TEST_HANDLE自体は改竄していない)。
    #   paneはsleepの自然終了(最大5秒)後にexec元のbashが無いため自動的に
    #   閉じ、session/serverも既定のexit-emptyで連鎖して自然終了する。
    #   フック側のteardown再試行はpane状態次第で失敗しうるが`|| true`で
    #   許容済みであり、killは一切使わない。
}

# ═══════════════════════════════════════════════════════
# G758R1-HANDLE-PROVENANCE-02是正: handle file の由来検証
#   (正規handleのcopyと手書き完全形の両方を負試験に加える)
# ═══════════════════════════════════════════════════════

@test "T-IT-031: teardown は正規handleを別pathへcpした複製を拒否する(G758R1-02是正)" {
    TEST_HANDLE="$(bash "$HELPER" create -L "$TEST_SOCK")"
    local sock_path copy
    sock_path="$(handle_field "$TEST_HANDLE" SOCKET_PATH)"
    copy="$(mktemp)"
    cp "$TEST_HANDLE" "$copy"

    run bash "$HELPER" teardown "$copy"
    [ "$status" -ne 0 ]
    [[ "$output" == *"専用領域の直下にない"* ]]

    # ★実paneは無傷(複製handleでは終了できていない証拠)。
    run tmux -S "$sock_path" list-panes -a -F '#{pane_current_command}'
    [ "$status" -eq 0 ]
    [ "$output" = "bash" ]

    rm -f "$copy"
    # 本物のpaneはTEST_HANDLE(未改竄)経由でteardown()フックが片付ける。
}

@test "T-IT-032: teardown は正規handleを専用領域の直下へcpした複製も拒否する(場所ではなくfile実体そのものを見る・G758R1-02是正)" {
    TEST_HANDLE="$(bash "$HELPER" create -L "$TEST_SOCK")"
    local sock_path copy
    sock_path="$(handle_field "$TEST_HANDLE" SOCKET_PATH)"
    # ★専用領域の直下(コンテナ条件は満たす)でも、cpは新しいinodeを
    #   得るためregistryに記録が無く拒否されるはずである。
    copy="$(mktemp "$(dirname "$TEST_HANDLE")/handle.XXXXXX")"
    cp "$TEST_HANDLE" "$copy"

    run bash "$HELPER" teardown "$copy"
    [ "$status" -ne 0 ]
    [[ "$output" == *"由来を確認できない"* ]]

    run tmux -S "$sock_path" list-panes -a -F '#{pane_current_command}'
    [ "$status" -eq 0 ]
    [ "$output" = "bash" ]

    rm -f "$copy"
}

@test "T-IT-033: teardown は9 fieldの値を手書きで完全に再現したhandleも拒否する(内容の正しさに依存しない検証・G758R1-02是正)" {
    TEST_HANDLE="$(bash "$HELPER" create -L "$TEST_SOCK")"
    local sock_path forged
    sock_path="$(handle_field "$TEST_HANDLE" SOCKET_PATH)"
    # ★9 field全てを本物と一字一句同じ値で書く(内容は完全に正しい)。
    #   専用領域の直下に置いても、file実体そのものはcreateのinstallを
    #   経ていないためregistryに記録が無い。
    forged="$(mktemp "$(dirname "$TEST_HANDLE")/handle.XXXXXX")"
    {
        echo "SOCKET=$(handle_field "$TEST_HANDLE" SOCKET)"
        echo "SOCKET_PATH=$(handle_field "$TEST_HANDLE" SOCKET_PATH)"
        echo "SESSION=$(handle_field "$TEST_HANDLE" SESSION)"
        echo "PANE_ID=$(handle_field "$TEST_HANDLE" PANE_ID)"
        echo "SERVER_PID=$(handle_field "$TEST_HANDLE" SERVER_PID)"
        echo "SERVER_STARTTIME=$(handle_field "$TEST_HANDLE" SERVER_STARTTIME)"
        echo "PANE_PID=$(handle_field "$TEST_HANDLE" PANE_PID)"
        echo "PANE_STARTTIME=$(handle_field "$TEST_HANDLE" PANE_STARTTIME)"
        echo "CREATED_AT=$(handle_field "$TEST_HANDLE" CREATED_AT)"
    } > "$forged"

    run bash "$HELPER" teardown "$forged"
    [ "$status" -ne 0 ]
    [[ "$output" == *"由来を確認できない"* ]]

    run tmux -S "$sock_path" list-panes -a -F '#{pane_current_command}'
    [ "$status" -eq 0 ]
    [ "$output" = "bash" ]

    rm -f "$forged"
}

@test "T-IT-034: teardown は正規handleへのsymlinkを拒否する(非symlink要件・G758R1-02是正)" {
    TEST_HANDLE="$(bash "$HELPER" create -L "$TEST_SOCK")"
    local sock_path link
    sock_path="$(handle_field "$TEST_HANDLE" SOCKET_PATH)"
    link="$(mktemp -u)"
    ln -s "$TEST_HANDLE" "$link"

    run bash "$HELPER" teardown "$link"
    [ "$status" -ne 0 ]
    [[ "$output" == *"symlinkである"* ]]

    run tmux -S "$sock_path" list-panes -a -F '#{pane_current_command}'
    [ "$status" -eq 0 ]
    [ "$output" = "bash" ]

    rm -f "$link"
}

# ═══════════════════════════════════════════════════════
# G758R1-PREEXISTING-SERVER-ATTACH-03是正: 新規private socket parent
# ═══════════════════════════════════════════════════════

@test "T-IT-035: 同じ -L 名で2回createしても、それぞれ別のsocket_path(別のprivate socket parent)を得て互いに独立している" {
    HANDLE_A="$(bash "$HELPER" create -L "$TEST_SOCK")"
    HANDLE_B="$(bash "$HELPER" create -L "$TEST_SOCK")"
    local path_a path_b
    path_a="$(handle_field "$HANDLE_A" SOCKET_PATH)"
    path_b="$(handle_field "$HANDLE_B" SOCKET_PATH)"

    [ "$path_a" != "$path_b" ]

    # ★両方とも独立して生きている(既存serverへの追加接続ではない証拠)。
    run tmux -S "$path_a" list-sessions -F '#{session_name}'
    [ "$status" -eq 0 ]
    [ "$output" = "iso" ]
    run tmux -S "$path_b" list-sessions -F '#{session_name}'
    [ "$status" -eq 0 ]
    [ "$output" = "iso" ]

    bash "$HELPER" teardown "$HANDLE_A" >/dev/null 2>&1
    bash "$HELPER" teardown "$HANDLE_B" >/dev/null 2>&1
    rm -f "$HANDLE_A" "$HANDLE_B"
}

@test "T-IT-036: create が使うsocket親ディレクトリは自分専用(mode 700)の新規ディレクトリである" {
    TEST_HANDLE="$(bash "$HELPER" create -L "$TEST_SOCK")"
    local sock_path sockparent mode
    sock_path="$(handle_field "$TEST_HANDLE" SOCKET_PATH)"
    sockparent="$(dirname "$sock_path")"
    mode="$(stat -c '%a' "$sockparent")"
    [ "$mode" = "700" ]
}

# ═══════════════════════════════════════════════════════
# G758R1-EVENT-WAIT-HANG-04是正: 二session構成でも有限時間で解除
# ═══════════════════════════════════════════════════════

@test "T-IT-037: 同一serverに他sessionが存在してもteardownのwait-forは有限時間(15秒以内)で解除される(実機・G758R1-04是正)" {
    TEST_HANDLE="$(bash "$HELPER" create -L "$TEST_SOCK")"
    local sock_path
    sock_path="$(handle_field "$TEST_HANDLE" SOCKET_PATH)"

    # ★対象serverへ、本helperを経由せず直接raw tmuxで第2sessionを
    #   追加する(create経由ではこの構成は作れないため、hookの
    #   robustness自体を検証するために手動で再現する)。
    tmux -S "$sock_path" new-session -d -s extra_session -n w1 bash

    # ★timeoutで包む: 修正前は-t scope(session側)のhookが対象session
    #   消滅と同時に失われ、wait-forが最低74秒解除されなかった実測が
    #   ある(本redo2の検証でも同条件でtimeout・rc=124を再現済み)。
    #   ここでtimeout超過(rc=124)すれば回帰を検知できる。
    run timeout 15 bash "$HELPER" teardown "$TEST_HANDLE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"自然終了した"* ]]

    # ★他sessionは無傷。
    run tmux -S "$sock_path" list-sessions -F '#{session_name}'
    [ "$status" -eq 0 ]
    [ "$output" = "extra_session" ]

    # 後始末: 手動で追加したextra_sessionを直接exitで片付ける(kill不使用)。
    local extra_pane
    extra_pane="$(tmux -S "$sock_path" display-message -t extra_session:w1.0 -p '#{pane_id}' 2>/dev/null)"
    tmux -S "$sock_path" send-keys -t "$extra_pane" "exit" Enter 2>/dev/null || true
}

# ═══════════════════════════════════════════════════════
# G758R1-HANDLE-INSTALL-BOUNDARY-05是正
# ═══════════════════════════════════════════════════════

@test "T-IT-038: handle領域はTMPDIRを書き換えても呼出側からredirectできない(固定絶対path)" {
    local fake_tmpdir="/tmp/cmd758_should_be_ignored_$$_${RANDOM}"
    TEST_HANDLE="$(TMPDIR="$fake_tmpdir" bash "$HELPER" create -L "$TEST_SOCK")"
    [ -f "$TEST_HANDLE" ]
    [[ "$TEST_HANDLE" == "${PROJECT_ROOT}/tmp/isolated_tmux_handles/"* ]]
    [ ! -e "$fake_tmpdir" ]
}

@test "T-IT-039: create はsession作成後の失敗時、既に作ったpaneへexitを送って片付けてからdieする(failure injection・G758R1-05是正)" {
    local shim_dir call_log real_tmux
    shim_dir="$(mktemp -d)"
    call_log="$shim_dir/calls.log"
    real_tmux="$(command -v tmux)"
    cat > "$shim_dir/tmux" <<SHIM
#!/usr/bin/env bash
echo "\$@" >> "$call_log"
# ★pane_id取得のdisplay-message呼出しだけを失敗させる(post-session
#   失敗を注入する)。new-session等それ以外の呼出しは実tmuxへ通す。
case "\$*" in
    *":w0.0 -p #{pane_id}"*)
        exit 1
        ;;
esac
exec "$real_tmux" "\$@"
SHIM
    chmod +x "$shim_dir/tmux"

    run env PATH="$shim_dir:$PATH" bash "$HELPER" create -L "$TEST_SOCK"
    [ "$status" -ne 0 ]
    [[ "$output" == *"pane_id を取得できなかった"* ]]

    # ★shimの呼出しログ(先頭行=new-session呼出し)からsocket_pathを
    #   復元し、失敗時cleanupにより隔離serverのsessionが既に自然終了
    #   していることを確認する(exit入力+イベント駆動待ちが実際に
    #   動いた証拠。放置されたままのオーファンではない)。
    local sock_path
    sock_path="$(head -1 "$call_log" | /usr/bin/grep -oE -- '-S [^ ]+' | cut -d' ' -f2)"
    [ -n "$sock_path" ]

    run tmux -S "$sock_path" has-session -t iso
    [ "$status" -ne 0 ]

    rm -rf "$shim_dir"
}

# ═══════════════════════════════════════════════════════
# G758R2-B1-TEARDOWN-FALSE-NEGATIVE是正 (S-1・cmd_758 redo3)
# ═══════════════════════════════════════════════════════
# ★足軽7号QC(qc_subtask_758_isolated_tmux_helper_redo2_ashigaru)実測:
#   create後0.5秒以上経ってからのteardownは、最終paneのexitでserverが
#   exit-emptyにより自然終了する際に`tmux wait-for`自身が「server
#   exited unexpectedly」で切断され、100%の再現率でrc=1(偽陰性)を
#   報告していた。全39件がcreate直後teardownのため構造的に未検出
#   だった(同型の盲点を繰り返さないため、本試験は先に書きFAILする
#   ことを確認してからS-1を実装する・redo3進め方1)。

@test "T-IT-040: create後1秒以上待ってからteardownしても自然終了と正しく判定される(一session構成・G758R2-B1回帰・S-1是正)" {
    TEST_HANDLE="$(bash "$HELPER" create -L "$TEST_SOCK")"
    local sock_path
    sock_path="$(handle_field "$TEST_HANDLE" SOCKET_PATH)"

    # ★このsleepは試験固有の再現条件(create直後ではなく実運用に近い
    #   タイミングでteardownする)であり、helper本体(T-IT-007検査対象)
    #   には含まれない。T-IT-030・037と同種の試験固有の待ちである。
    sleep 1

    run bash "$HELPER" teardown "$TEST_HANDLE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"自然終了した"* ]]

    run tmux -S "$sock_path" has-session
    [ "$status" -ne 0 ]
}

# ═══════════════════════════════════════════════════════
# G758R2-B2-HANDLE-CONTENT-SWAP是正(ii)のみ (S-2・cmd_758 redo3)
# ═══════════════════════════════════════════════════════
# ★足軽7号QC実測(b'-2): 正規handle(provenance検証を通る)のSOCKET_PATH
#   を専用sockparent領域外のraw serverへ`>`のin-place上書きで差し替える
#   と、領域検証が無かったため受理されexitが届いた。★本試験はS-2の
#   実装前に追加し、現状でFAILすることを先に確認してから実装する
#   (S-1と同じ赤→緑の順序を適用)。★B2(i)内容ハッシュ照合・M1・M2・M3
#   は将軍裁定によりscope外(受容)であり、本試験もSOCKET_PATH領域検証
#   (S-2)のみを対象とする——他フィールドは改竄しない。
# ★実在するraw serverではなく実在しないpathへ差し替える構成にした
#   (設計変更・当初は専用領域外に別raw serverを立てる構成だったが、
#   多数のagentが並行稼働するこの環境で共有ディレクトリ
#   〈tmp/isolated_tmux_sockets〉配下への同時アクセスが絡んだためか、
#   検証プロセスが応答しなくなる事象が実際に発生し、そのserver・
#   検証processは「失敗した隔離serverはkillで片付けず残して報告する」
#   の規定どおりkillせず放置した——詳細は完了報告を見よ)。★S-2の検証は
#   構造(path文字列の形)だけで働き実在確認より前に拒否するため、
#   実在しないpathでも検証の意味は変わらない。むしろ実在に依存しない
#   ことをより強く示せる。

@test "T-IT-041: teardown は SOCKET_PATH が専用sockparent領域外を指すhandleを内容非依存で拒否する(実在の有無に関わらず・G758R2-B2(ii)是正・S-2のみ)" {
    TEST_HANDLE="$(bash "$HELPER" create -L "$TEST_SOCK")"
    local sock_path pane_id
    sock_path="$(handle_field "$TEST_HANDLE" SOCKET_PATH)"
    pane_id="$(handle_field "$TEST_HANDLE" PANE_ID)"

    # ★TEST_HANDLE自身のSOCKET_PATHだけをin-place書き換える(inode/dev
    #   は保たれるためprovenance検証は通過する。他8 fieldは元の正規値の
    #   ままであり、schema検証にも自然に通る——SOCKET_PATH領域検証だけが
    #   これを拒否できることを確認する試験である)。実在しないpathを使う
    #   (S-2は存在確認ではなく構造検証であり、実在しない値でも拒否
    #   できることを確認する)。
    local outside_path="/tmp/cmd758_redo3_s2_outside_domain_$$_${RANDOM}.sock"
    tamper_handle_field_inplace "$TEST_HANDLE" "SOCKET_PATH" "$outside_path"

    run timeout 10 bash "$HELPER" teardown "$TEST_HANDLE"
    [ "$status" -ne 0 ]
    [[ "$output" == *"sockparent領域"* ]]

    # ★本物のpaneは無傷(S-2がいかなるtmuxコマンド発行前に拒否した証拠)。
    run tmux -S "$sock_path" list-panes -a -F '#{pane_current_command}'
    [ "$status" -eq 0 ]
    [ "$output" = "bash" ]

    raw_exit_pane "$sock_path" "$pane_id"
}

# ═══════════════════════════════════════════════════════
# cmd_795: teardown の wait-for に上限(負荷下の無期限停滞の是正)
# ═══════════════════════════════════════════════════════
# ★事実(足軽7号の所見・cmd_791(B)): 負荷下で teardown が無期限に止まる
#   事象を1日に27件観測(うち2件は33分超)。隔離serverは子なし・session
#   なしで、接続は待受けとhelperのwait-for clientの2本のみ。読取りの
#   list-sessions 1回で全件解けた(tmux 3.4 の通知取りこぼしと推論)。
# ★本節の試験は「通知が来ない」条件を、wait-for の通知producer(pane-exited
#   hook)を意図的に設置しない shim(make_tmux_shim)で作る。上限は
#   ITMUX_WAIT_LIMIT_SEC で短縮する。経過は /proc/uptime で測る(壁時計に
#   依存しない)。いずれも後始末は helper の teardown か、自分で作った
#   隔離paneへの打鍵だけで行う(kill不使用)。

@test "T-IT-042: 通知producerを設置しなくても teardown は上限内に返り、server消滅なら成功する(cmd_795)" {
    TEST_HANDLE="$(bash "$HELPER" create -L "$TEST_SOCK")"
    local sock_path shim_dir t0 t1
    sock_path="$(handle_field "$TEST_HANDLE" SOCKET_PATH)"
    shim_dir="$(make_tmux_shim nohook)"

    t0="$(uptime_ms)"
    run env PATH="$shim_dir:$PATH" ITMUX_WAIT_LIMIT_SEC=3 bash "$HELPER" teardown "$TEST_HANDLE"
    t1="$(uptime_ms)"
    [ "$status" -eq 0 ]
    [[ "$output" == *"自然終了した"* ]]
    # 上限3秒+余裕7秒以内に返っている(無期限に待ち続けていない)。
    [ $((t1 - t0)) -lt 10000 ]

    run tmux -S "$sock_path" has-session
    [ "$status" -ne 0 ]
}

@test "T-IT-043: 待受けclientが戻らない(通知取りこぼし)とき、上限到達後に has-session で消滅を確定し成功する(cmd_795)" {
    TEST_HANDLE="$(bash "$HELPER" create -L "$TEST_SOCK")"
    local sock_path shim_dir t0 t1
    sock_path="$(handle_field "$TEST_HANDLE" SOCKET_PATH)"
    shim_dir="$(make_tmux_shim stuckwait)"

    t0="$(uptime_ms)"
    run env PATH="$shim_dir:$PATH" ITMUX_WAIT_LIMIT_SEC=2 bash "$HELPER" teardown "$TEST_HANDLE"
    t1="$(uptime_ms)"
    [ "$status" -eq 0 ]
    [[ "$output" == *"上限2秒に達した"* ]]
    [[ "$output" == *"通知取りこぼし後に has-session で確定"* ]]
    [[ "$output" == *"自然終了した"* ]]
    # 上限(2秒)までは待ち、上限+余裕6秒以内に返る。
    [ $((t1 - t0)) -ge 1900 ]
    [ $((t1 - t0)) -lt 8000 ]

    run tmux -S "$sock_path" has-session
    [ "$status" -ne 0 ]
}

@test "T-IT-044: 上限到達後も隔離セッションが残るなら安全側の失敗(rc!=0・何も終了させない・handleは残す)で返り、同じhandleで再試行できる(cmd_795)" {
    TEST_HANDLE="$(bash "$HELPER" create -L "$TEST_SOCK")"
    local sock_path pane_id shim_dir marker t0 t1
    sock_path="$(handle_field "$TEST_HANDLE" SOCKET_PATH)"
    pane_id="$(handle_field "$TEST_HANDLE" PANE_ID)"
    shim_dir="$(make_tmux_shim nohook)"

    # ★自分で作った隔離paneのbashに、`exit`を無視する関数を定義する
    #   (pane_current_commandはbashのまま=身元再照合は通る・exitを受けても
    #   paneが閉じない=「残存」の再現)。定義の反映はmarker fileで確かめる
    #   (試験固有の同期待ち・上限5秒・T-IT-030と同種)。
    marker="${BATS_TEST_TMPDIR}/exit_overridden"
    tmux -S "$sock_path" send-keys -t "$pane_id" "exit() { :; }; : > '$marker'" Enter
    for _ in $(seq 1 50); do
        [ -e "$marker" ] && break
        sleep 0.1
    done
    [ -e "$marker" ]

    t0="$(uptime_ms)"
    run env PATH="$shim_dir:$PATH" ITMUX_WAIT_LIMIT_SEC=2 bash "$HELPER" teardown "$TEST_HANDLE"
    t1="$(uptime_ms)"
    [ "$status" -ne 0 ]
    [[ "$output" == *"上限2秒に達し"* ]]
    [[ "$output" == *"隔離セッションが残っている"* ]]
    [[ "$output" == *"安全側の失敗"* ]]
    [ $((t1 - t0)) -lt 8000 ]

    # handleは残る(同じhandleで再試行できる)。
    [ -f "$TEST_HANDLE" ]
    # server・paneには何も終了させていない(paneはbashのまま生きている)。
    run tmux -S "$sock_path" list-panes -a -F '#{pane_id} #{pane_current_command}'
    [ "$status" -eq 0 ]
    [ "$output" = "${pane_id} bash" ]
    # 実tmuxの待受けclientは上限到達で終わり、残っていない
    #   (timeout(1)が終わらせたのは自身の直接の子=待受けclientだけ)。
    [ "$(count_waitfor_clients "$sock_path")" -eq 0 ]

    # 後始末: 関数を外し、同じhandleでshim無し・既定上限のteardownを再試行する。
    tmux -S "$sock_path" send-keys -t "$pane_id" "unset -f exit" Enter
    run bash "$HELPER" teardown "$TEST_HANDLE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"自然終了した"* ]]
    run tmux -S "$sock_path" has-session
    [ "$status" -ne 0 ]
}

@test "T-IT-045: 不正な ITMUX_WAIT_LIMIT_SEC は create/teardown の冒頭で拒否し、tmuxには一切触れない(cmd_795)" {
    local v
    for v in 0 -1 abc 1.5 007 100000 " 5" "5 "; do
        run env ITMUX_WAIT_LIMIT_SEC="$v" bash "$HELPER" create -L "$TEST_SOCK"
        # ★回帰でcreateが成功してしまった場合も隔離serverを残さない
        #   (teardown()フックに片付けさせる)。残すとserverがbatsのfd 3を
        #   握り続け、bats全体が終わらなくなる(cmd_795赤試験で実測)。
        if [ "$status" -eq 0 ] && [ -f "$output" ]; then
            TEST_HANDLE="$output"
        fi
        [ "$status" -ne 0 ]
        [[ "$output" == *"ITMUX_WAIT_LIMIT_SEC"* ]]
        [[ "$output" != *"isolated_tmux_handles/handle."* ]]
    done

    TEST_HANDLE="$(bash "$HELPER" create -L "$TEST_SOCK")"
    local sock_path
    sock_path="$(handle_field "$TEST_HANDLE" SOCKET_PATH)"
    run env ITMUX_WAIT_LIMIT_SEC=0 bash "$HELPER" teardown "$TEST_HANDLE"
    [ "$status" -ne 0 ]
    [[ "$output" == *"ITMUX_WAIT_LIMIT_SEC"* ]]
    # ★paneは無傷(exitを送る前に拒否した証拠)。後始末はteardown()フック。
    run tmux -S "$sock_path" list-panes -a -F '#{pane_current_command}'
    [ "$status" -eq 0 ]
    [ "$output" = "bash" ]
}

@test "T-IT-046: wait-for の上限は timeout(1) の --foreground 付き呼出しだけで設け、既定は60秒である(process group宛て送信の禁止・cmd_795)" {
    # ★コメント行を除いた実コードで、timeout(1)の呼出し行を全て拾う
    #   (存在確認の`[ -z "$ITMUX_TIMEOUT_BIN" ]`だけは呼出しではないので除く)。
    run bash -c "/usr/bin/grep -v '^[[:space:]]*#' '$HELPER' | /usr/bin/grep -F '\"\$ITMUX_TIMEOUT_BIN\"' | /usr/bin/grep -vF '[ -z \"\$ITMUX_TIMEOUT_BIN\" ]'"
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -ge 1 ]
    local line
    for line in "${lines[@]}"; do
        [[ "$line" == *'"$ITMUX_TIMEOUT_BIN" --foreground '* ]]
    done
    # timeout の名を直接呼ぶ経路(変数を経ない呼出し)も無い。
    run bash -c "/usr/bin/grep -v '^[[:space:]]*#' '$HELPER' | /usr/bin/grep -E '(^|[[:space:];|&])timeout[[:space:]]' || true"
    [ -z "$output" ]

    run /usr/bin/grep -c '^_ITMUX_WAIT_LIMIT_DEFAULT_SEC=60$' "$HELPER"
    [ "$output" = "1" ]
}
