#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""D002-E1(rm -rf 例外)適合性を機械判定する静的検査器 (cmd_753・
scope変更版=closed grammar化・本redoでパス軸もリテラル/tmp根へ閉じた)。

## 目的
実行系コード(.sh/.bash/.bats/.py)中の `rm -rf`/`rm -fr` 出現を全件走査し、
CLAUDE.md「Tier 1」D002-E1 の四条件——
  (a) mktemp -d 由来か  (b) 使用直前まで再代入されていないか
  (c) 対象がそれ自身か(親・glob・連結でないか)
  (d) 綴りが許容4形式か・絶対パスが証明できるか
に照らして判定する。証明できないものは PASS にしない(fail-closed)。

## ★設計変更の経緯(cmd_753 scope変更・将軍裁定・redo3ではない)
初版・redo1・redo2は「開いた shell 文法(mktemp 呼出しの任意のオプション
追加・複合command・redirect等)を広く受理しつつ、危険な形だけを個別に
blocklist で潰す」という設計だった。この設計は新パターンが見つかる
たびに穴を塞ぐ対応を繰り返すことになり(初版→redo1→redo2で計8種の
実穴を是正)、「開いたshell文法を受理しながら漏れ0を証明する」という
課題自体が有限でなかった。

将軍が実行系(.sh/.bats/.py・tmp/と.venv除く)の mktemp 呼出しを全数
実測した結果、実在する生成形は実質2種類(`mktemp -d`単独、および
`mktemp -d`+絶対リテラルtemplate)のみで、それ以外は検査器自身の
否定試験fixtureとコメントだけだった。そこで本redoでは方針を転換し、
「実在する canonical form だけを正規表現で完全一致(`^...$`)認証し、
一致しない入力は理由を問わず即座に不許可とする」閉じた文法へ書き
換えた。個々のトークンを消費しながら危険な区切り文字を denylist で
潰す旧方式(mktemp_info の token consumer)は全廃し、置き換えた。

## ★本redo(scope縮小・パス軸のclosed grammar化)の経緯
redo1・redo2はoption軸・trailing token軸を閉じたが、パス軸(template/
parent引数の「絶対パスであること」)は開いたまま残っていた。この結果、
WSL保護パス(`/mnt/c/Windows`等)のような、絶対パスではあるが実在形の
根(`/tmp`)ではない値がABS-CONSTRUCTとして誤ってPASS適格になり得る
穴があった(redo2で顕在化)。「毎回別次元の反例」が続くこと自体が、
軸を閉じ切っていない証拠であるとの将軍裁定に基づき、本redoではパス軸
そのものを閉じる。

将軍が実行系(.sh/.bats/.py・tmp/と.venv除く)のmktemp呼出しの
template/親指定を全数実測した結果、`/mnt/`を根に持つもの・`$HOME`を
根に持つもの・相対のものは0件で、全て`/tmp`を根としていた(内訳:
`mktemp -d /tmp/....XXXXXX`系12件、`.../owned.XXXXXX`系8件、
`-p /tmp`8件、`--tmpdir=/tmp`3件、`--tmpdir /tmp`2件、
`/tmp/test_*_XXXXXX`系多数、裸`mktemp -d`149件)。

裁定内容(C-1〜C-3・そのまま採用・`TMP_LITERAL_ROOT_RE`/`DOTDOT_RE`と
して実装。★cmd_753完了処理(対応3・軍師非blocking観察是正)で追記:
`TMP_LITERAL_ROOT_RE`は下記「本redo1」でネスト/symlink迂回排除の
ため`TMP_DIRECT_TEMPLATE_RE`/`TMP_PARENT_EXACT_RE`の2つへ分割済みで
あり、現行コードに`TMP_LITERAL_ROOT_RE`という名のregexは存在しない
——本節はこの分割"前"の裁定内容を経緯として記録したものと読め):
  - **C-1.** template・`-p`・`--tmpdir`の根は★リテラル`/tmp`という
    文字列そのものであるもののみ受理する。「絶対パスであること」
    (先頭が`/`)では判定しない——`SAFE_LITERAL_PATH_RE`(絶対パス
    全般を受理)を`TMP_LITERAL_ROOT_RE`(`/tmp`単体、または`/tmp/`
    以下に安全な文字集合のみが続く形)へ置き換えた。
  - **C-2.** operand(template/parent引数)に`..`を含むものは受理
    しない(別名表記による`/tmp`根の迂回遮断)。`TMP_LITERAL_ROOT_RE`
    の文字集合は`.`自体を許可するため`/tmp/../etc`が字面上マッチ
    し得る——`DOTDOT_RE`で独立に検査し、含む場合はPASS対象から外す。
  - **C-3.** 受理集合(`/tmp`根・`..`なし)の外は全て「判定不能ゆえ
    不許可」(FORMAT_ONLY)とする。危険と断ずる必要はない——制御演算子/
    コマンド置換の埋め込みを検出した場合のみ従来どおりDANGERとする
    (UNSAFE_CHARS_REは変更なし)。

これにより、WSL保護パス・`/tmp/../mnt/c/Windows`のような別名表記・
symlink越しの迂回・大小文字違い(`/TMP/...`)・UNC風パス等——絶対パス
ではあるが実在形の根ではない形全てが、個別に潰すことなく一括して
FORMAT_ONLYへ落ちる(入口を塞ぐ設計。B-1(iii)のtrailing token
(`classify_trailing_template_token()`)にも同じ`DOTDOT_RE`を適用し、
親が`/tmp`根であっても迂回できないようにした)。

## ★本redo1(問題1・問題2是正: ネスト/symlink迂回排除・連続X必須化)の経緯
上記redoでC-1〜C-3によりパス軸を「リテラル/tmp」へ閉じたが、実装した
`TMP_LITERAL_ROOT_RE`(`^/tmp(?:/[A-Za-z0-9._/-]*)?$`)は文字集合に`/`
自体を含んでいたため、根こそ`/tmp`であっても任意階層のネスト
(`/tmp/link/out.XXXXXX`)・連続slash(`/tmp//double.XXXXXX`)・
dotセグメント(`/tmp/./dot.XXXXXX`)が字面上マッチする**開集合**の
ままだった(軍師が独立fixtureで確認・G753-TMP-NESTED-SYMLINK-ESCAPE-01)。
中間セグメント(例: `/tmp/link`)が保護mount配下を指すsymlinkであれば、
静的判定器が確認できるのは字面が`/tmp`根であることのみであり、mktempが
実際に作る実体・`rm -rf`の作用先が保護mount配下となることを排除
できない。将軍が実行系の実測(本ファイル冒頭参照)で確認した直接
template形は例外なく「`/tmp`直下のbasename1個(ネストなし)」であり、
`-p`/`--tmpdir`の親指定形も例外なく「`/tmp`単体」だったため、本redo1
では両者を実測どおりの形へ正確に閉じた(`TMP_DIRECT_TEMPLATE_RE`/
`TMP_PARENT_EXACT_RE`)。直接template形のbasename部分は`/`を文字集合
から除外することで、ネスト・重複slash・dotセグメントを構造的に
(個別potentialパターンを都度潰すのではなく)排除する。親指定形は
「リテラル`/tmp`または`/tmp/`」への完全一致のみを受理し、それ以外
(親の下にさらに階層を持つ形を含む)は一律FORMAT_ONLYへ落とす。

併せて、mktempのtemplateに必須の「末尾連続X」(mktempがこの部分だけを
実際にランダム文字へ置換してディレクトリを作成する)を一切要求して
いなかった穴も是正した(G753-NONCREATING-MKTEMP-TEMPLATE-PASS-02)。
連続Xが無いtemplateは、mktempが実際にはディレクトリ作成に失敗するか、
置換箇所が無いため予測可能な固定名になる形であり、いずれもD002-E1(a)
(mktemp -dが実際にそのディレクトリを作成した、という所有単位の前提)
を満たさない。★cmd_753完了処理(対応3・軍師非blocking観察是正):
GNU mktempの一般仕様上の最低要求数は連続X3個であり、6個は「mktempが
要求する最低数」ではない。将軍が実測した実行系全体のtemplateが例外
なく連続6個の`X`で終わっていたため、本検査器はこの実測canonical形
どおりの6個を意図的な閾値として採用し機械的に必須化した
(`REQUIRED_TRAILING_X_RE`として実装)——「mktempの一般仕様上の要求」
ではなく「本検査器が実測集合から意図的に選んだ値」である。この要求は
直接template形(B-1(ii))・親指定形のtrailing template(B-1(iii)の
第2引数)の両方に適用する——親指定単独形(trailingなし、mktempの
既定template`tmp.XXXXXXXXXX`に委ねる形)には適用しない(将軍実測
どおり実在し、mktemp自身が連続Xを保証する)。

★併せて正直に記す(allowlistの射程・cmd_753完了処理で実測値を追記・
将軍の見積り「約460件がD002-E1(d)に適合しリテラルで20種ほどに収まる」
は実測1桁違いだったため、以後は概算ではなく実測値のみを記す):
本検査器のPASS判定は、settings.local.jsonのallowlistへ列挙する候補と
してのみ機能する。allowlistはコマンド"文字列"を照合する道具であり、
確認プロンプトが不要になるのはPASS判定かつ複合コマンドでない単純形
(`mktemp -d`単文+`rm -rf "$VAR"`のような単一行の組)に限られる——
2026-09-08時点の実測で、リテラルコマンド文字列として重複排除した
allow_entriesは★5種、その出現箇所(PASS判定hit)は★17箇所である
(`python3 scripts/rm_rf_d002e1_checker.py --root <repo>`実行時の
`allow_entries`一覧・PASS件数としてそのまま再現できる)。
残る★132箇所(FORMAT_ONLY)の内訳は、素の`mktemp -d`(テンプレートなし・
B-1(i))由来120件、`$TMPDIR`/`$BATS_TMPDIR`等TMPDIR系変数を起点とする
templateに由来12件(以上ABS-TMPDIR-COND、1 hitに2 operandを含む例が
1件あるため合計132 operand・131 hit)——いずれも絶対性が実行時のTMPDIR
値に依存し静的に証明できないため、allowlistの有無にかかわらず確認は
出続ける。加えて、python heredocを含む複合コマンドのような複合形は
harnessが静的解析できず(「Contains shell syntax (string) that cannot
be statically analyzed」)、allowlistが一致しないため同じく確認
プロンプトが出続ける。★cmd_753完了処理redo1で追記: 残る1件は
LITERAL-RELATIVE-UNPROVEN(shutsujin_departure.shの`./`相対パスリテラル
1箇所・CWD/symlink未証明)であり、旧実装ではINELIGIBLE_IN_TREEという
独立tagに数えていたが、本redo1でFORMAT_ONLYへ統合したため合計は
131件から132件(133 operand)へ変わった(2026-09-08時点の実測。
`python3 scripts/rm_rf_d002e1_checker.py --root <repo>`実行時の
`FORMAT_ONLY`件数・`--json`出力のoperand kind内訳としてそのまま
再現できる)。「allowlistで確認が消える」という主張はしない——消える
範囲は上記5種・17箇所のみであり、残る132箇所・複合形は消えないことを
具体的な数字で明記する。

## 受理集合(closed grammar・B-1・★成果物として必ず明示)
inner文字列(`$(...)`または`` `...` ``の中身)全体が、以下3形式の
いずれかに完全一致する場合のみ「mktemp -d 由来」と認証する:

  (i)   `mktemp -d`                                      (operandなし)
  (ii)  `mktemp -d <リテラル/tmp直下basename・末尾連続X必須>` (例: `/tmp/foo.XXXXXX`)
  (iii) `mktemp -d (-p|--tmpdir[=]) <リテラル/tmpまたは/tmp/> [<template>]`

★(ii)の`<template>`は「`/tmp/`」に続く**basename1個のみ**(スラッシュを
一切含まない)に限り受理する(★本redo1・G753-TMP-NESTED-SYMLINK-
ESCAPE-01是正)。`/tmp/link/out.XXXXXX`のような多段ネスト・
`/tmp//double.XXXXXX`のような連続slash・`/tmp/./dot.XXXXXX`のような
dotセグメントは、中間segmentがsymlinkであった場合に実際の作用先を
保証できないため一切一致せずFORMAT_ONLYへ落ちる。basenameの末尾は
mktempが実際に置換する連続X(6個以上)を要求する(★本redo1・
G753-NONCREATING-MKTEMP-TEMPLATE-PASS-02是正)——連続Xを欠く
template(`/tmp/no_required_x`等)はmktempが実際にはディレクトリを
作成しない、または固定名になる形であり、D002-E1(a)の前提を満たさない。

★(iii)の`<parent>`は「リテラル`/tmp`」または「リテラル`/tmp/`」への
完全一致のみを受理する(★本redo1・G753-TMP-NESTED-SYMLINK-ESCAPE-01
是正)。`/tmp`配下にさらに階層を持つ親指定(将軍実測に実例なし)は
一致せずFORMAT_ONLYへ落ちる。

★bare mktemp(`-d`を伴わないファイルモード)は上記いずれにも一致せず、
受理しない(D002-E1(a)はディレクトリ作成を要求するため)。

★(i)は「テンプレートなし」であり、生成先はTMPDIR配下(TMPDIR未設定時
のみ/tmp)。TMPDIRが相対パスのとき絶対性を満たさない(B-4)。これは
静的解析では証明できない環境依存事実であり、「今のTMPDIRがどうか」に
依存してPASS/不許可を決めることはしない——常にFORMAT_ONLY止まりとし、
PASSにはしない。同じ理由で、絶対リテラルでなくTMPDIR系変数
(`$TMPDIR`・`$BATS_TMPDIR`等)を起点とするtemplateも同様にFORMAT_ONLY
止まりとする(実在するテスト teardown 慣用句であり、危険とは断定
しない)。

★(iii)の`[<template>]`(trailing token・任意)は、親(parent)が絶対
リテラル(ABS-CONSTRUCT)であり、かつtrailing自体が安全なリテラル
template文法(`classify_trailing_template_token()`・先頭が英数字で
`[A-Za-z0-9._-]`のみから成る相対ファイル名・★本redo1で追加: 末尾に
mktempが実際に置換する連続X(6個以上)を要求)に完全一致する場合に
限り、親と合わせてABS-CONSTRUCT(信頼済み)を維持する(★本redo是正・
G753-PARENT-VALID-TEMPLATE-REDO1-01・連続X要求は本redo1・
G753-NONCREATING-MKTEMP-TEMPLATE-PASS-02で追加)。将軍実測により
実在する親指定形は`parent`単独、または`parent`+安全なリテラル
template(例: `x.XXXXXX`)の2種であり、将軍裁定B-1(iii)はこの2種を
受理形として明示列挙している。

それ以外のtrailing——非生成option(`-u`/`--dry-run`/`--help`/
`--version`)・変数展開由来(`$OPT`・`$BATS_TMPDIR/x.XXXXXX`等)・
親がTMPDIR系変数由来(ABS-TMPDIR-COND)の場合のtrailing——は、redo1
是正(G753-PARENT-TRAILING-OPTION-CLOSED-GRAMMAR-01)のとおり内容を
問わずFORMAT_ONLYへ落とす(判定不能ゆえ不許可)。trailingに制御演算子/
コマンド置換を検出した場合はDANGER_TEMPLATEのまま変わらない。

★redo1の是正は、trailingが**存在するだけで**一律FORMAT_ONLYへ落とす
実装になっており、将軍裁定B-1(iii)が受理形として明示列挙している
「親が絶対リテラルで、templateも安全なリテラル」な正当な形まで
PASSしなくなっていた(軍師が独立に3/3全てFORMAT_ONLYと確認・
過剰修正)。是正後は`classify_trailing_template_token()`でtrailingを
専用の閉じた文法へ照合し、親のkindがABS_CONSTRUCTかつtrailingが
PASS_KINDの場合のみABS_CONSTRUCTを維持する——parentの分類結果のみで
kindを決定していた旧々実装の穴(危険文字を含まないoption形/変数展開
由来trailingの誤PASS)は、redo1が是正した状態のまま変えない。

★上記3形式に一致しない入力(オプション追加・`-t PREFIX`形式・部分
一致・複合command・redirect等)は、実在形に基づかないため本検査器の
文法に含めない。一致しなければ理由を問わず即座に不許可(FORMAT_ONLY)
に倒す——「判定不能ゆえ不許可」であり、危険と断定はしない(B-2)。
ただし、mktemp呼出しのtemplate/parent引数の中に、単一トークン内へ
埋め込まれた制御演算子やコマンド置換記号(`;`・`&`・`|`・`<`・`>`・
バッククォート・`$(` )を検出した場合に限り、DANGER として明示的に
扱う——これは「単一トークンに見えて実は複数commandへ分割される」
injection パターンであり(★本redoで新たに発見・是正した実装上の
穴。詳細は下記「新たに発見した実装上の穴」参照)、「認証しないだけ」
では済まない実害(意図しないcommand実行)を伴うため区別する。

閉じた文法の外にある入力について、genuinely危険な operand
(起源不明・非mktemp再代入・リテラル直書き・変数の連結・綴り不適合)
は従来どおり DANGER のままとする。両者(判定不能/FORMAT_ONLYと、
危険/DANGER)を成果物・reasonで必ず分けて報告する(QC重点(c))。

## 分類 (cmd_732 の教訓: 「真に危険」と「書式のみ不足」は扱いが正反対)
  - PASS         : 閉じた文法(ii)/(iii)に完全一致・絶対リテラル起点・
                    綴り適合の全条件を静的に証明できた。allowlist化候補。
  - FORMAT_ONLY  : mktemp由来・再代入なし・対象一致は確認できたが、
                    (1)絶対パスが環境依存(TMPDIR/BATS_TMPDIR起点)で
                    証明できない、(2)綴りが4形式に合致しない、
                    (3)closed grammar((i)(ii)(iii))の外にある呼出し形、
                    または(4)★cmd_753完了処理redo1で追加: 全operandが
                    変数参照ではない'./'相対パスリテラル(絶対パスでも
                    '..'によるescapeでもない)である場合
                    (LITERAL-RELATIVE-UNPROVEN・詳細は下記「★cmd_753完了
                    処理redo1(INELIGIBLE_IN_TREE誤分類是正)」節)
                    (判定不能ゆえ不許可。危険とは断定しない)。
  - DANGER       : 起源不明・再代入あり・リテラルoperand直書き・
                    変数の連結、またはmktemp呼出しのtemplate/parent
                    引数に単一トークン内へ埋め込まれた制御演算子/
                    コマンド置換を検出した場合(捕捉値の由来を保証
                    できない)。
  - EXCLUDED_FP  : コメント行/文字列リテラル内の記述で、実行文でない
                    (対象外だが黙って捨てず件数・一覧を必ず報告する)。

## ★cmd_753完了処理redo1(INELIGIBLE_IN_TREE誤分類是正)の経緯
cmd_753完了処理(対応1・非blocking)では、mktemp -d由来でない純粋な
リテラルoperandのうち、'./'で始まり'..'を含まない相対パスだけを
`INELIGIBLE_IN_TREE`という独立の第3区分へ分け、「字面上プロジェクト
作業木の外へは出ないためD002(禁止対象は「作業木の外」へのrm -rf)自体
には抵触しない」と結論していた。

軍師QCがこれを誤った一般化(false-safe)と判定した(REDO_REQUIRED)。
`^\./[A-Za-z0-9][A-Za-z0-9._/-]*$`という正規表現は operand の★字面
だけを見ており、`./queue/inbox`・`./queue/inbox/victim`・
`./link/victim`・`./queue/./inbox`のいずれも区別なく同じ
`INELIGIBLE_IN_TREE`に分類してしまう。しかし
`shutsujin_departure.sh`の`rm -rf ./queue/inbox`について、operandの字面
から安全性を導くことはできない。同ファイル16-17行目の`SCRIPT_DIR`解決と
`cd`は、★直接の標準起動であり中間componentが非symlinkである場合に限り
CWDを作業木内へ固定する。★これは実装が無条件に保証する事実ではなく、
本検査器も静的には確認できない(詳細は同ファイルの該当行直前コメント)。
本検査器はファイル単位のテキスト解析であり(下記「既知の限界1」参照)、
別ディレクトリへ`cd`した後の`rm -rf ./victim`や、作業木内の中間symlink
を経て外部を指す`./link/victim`が、実行時にCWD/symlinkのどちらの状態に
あるかを静的に確認する手段を持たない。したがって「'./'で始まる相対
パスは安全」という一般的な推論は成立せず、A-1原則(証明できないものを
通さない)およびA-2原則(「真に危険」と「単に書式が足りない・判定不能」
を正しく分ける)の両方に反していた。

是正内容(軍師required_fixのとおり採用):
  1. 「'./'相対パスからD002非抵触を推論する」分類ロジック自体を撤回
     した。kind定数を`LITERAL_INTREE_KIND`
     (`LITERAL-INTREE-RELATIVE`)から`LITERAL_RELATIVE_UNPROVEN_KIND`
     (`LITERAL-RELATIVE-UNPROVEN`)へ改名し、reasonから「D002自体には
     抵触しない」という断定を削除、「実行時のCWDが作業木内に固定されて
     いる保証、および中間pathがsymlinkでない保証を本検査器は静的に
     確認できない(CWD/symlink未証明・要人手確認)」と明記した。
  2. 独立した第3区分(トップレベルtag `INELIGIBLE_IN_TREE`)は廃止し、
     既存の「判定不能ゆえ不許可」区分である`FORMAT_ONLY`へ統合した
     (classify_hit()。DANGERへは寄せていない——このoperandは絶対パス
     でも'..'によるescapeでもなく、mktemp再代入や起源不明の変数とも
     性質が異なるため、「genuinely危険」と断定する根拠はなく、
     引き続き非blocking(exit codeに影響しない)区分として扱う)。
  3. `shutsujin_departure.sh`の`rm -rf ./queue/inbox`の1行について、
     ★「実際に安全である」という無条件の断定は本検査器のどこにも
     書かない。CWD固定と中間非symlinkがどの条件下で成り立つのか(と、
     実装がそれを保証していないこと)は、同ファイル内の該当行直前に
     条件つきのコード内コメントとして記録した。本検査器の汎用tagおよび
     reasonテキストへは一切混ぜない(判定は FORMAT_ONLY=未証明のまま)。
  4. 反例test(`cd`後の`./path`・中間symlinkを経由しうる`./link/child`
     形)をtests/unit/test_rm_rf_d002e1_checker.batsへ追加し、いずれも
     「安全」と断定されずFORMAT_ONLYへ倒れることを確認した——本検査器は
     ファイル単位のテキスト解析であり`cd`やsymlinkの実行時状態を
     追跡しないため、これらの反例は元の`./queue/inbox`と同一の
     classify_operand()経路(LITERAL_RELATIVE_UNPROVEN_KIND)を通り、
     字面が同型である限り常に同じ判定(FORMAT_ONLY)になる。

## 新たに発見した実装上の穴(★本redoで発見・是正。正直に記す)
旧設計から新設計へ切り替える過程で、`mktemp -d <template>` の
`<template>` を単一の空白区切りトークンとして正規表現(非空白1文字以上)で
素朴に捕捉するだけでは、`;`・`&`・`|`・`<`・`>` 等のshellメタ文字が
**空白を挟まずに** トークン内へ埋め込まれるケース
(例: `mktemp -d /tmp/foo.XXXXXX;touch>x`)を見逃すことに気づいた。
このケースは実際のbash実行時には空白の有無に関わらず `;` の前後で
2つの別々のcommandへ分割され(`mktemp -d /tmp/foo.XXXXXX` の実行後、
別途 `touch>x` が実行される)、mktempの捕捉値自体は無事でも、
テンプレート引数を装った箇所に無関係なcommand実行が紛れ込む
(★安全な文字集合のみを許可するallowlist方式で対処。詳細は
`classify_template_token()`/`UNSAFE_CHARS_RE` を参照)。この穴は
実コードには実例がなく(将軍実測どおり実在形は2種類のみ)、本検査器
自身の設計レビュー中に発見した理論上の穴である。

## 既知の限界(★正直に記す。誤読を防ぐため要約は書かない)
  1. ファイル単位のテキスト解析であり、bash の関数スコープ・サブシェル・
     source 先ファイルをまたぐ代入・実行時の制御フローは追跡しない。
     「使用行より前の最後の代入」を安全側の近似として用いる。
  2. 文字列リテラル/コメント除外は、.py は標準ライブラリ `tokenize` で
     STRING/COMMENT トークンの実位置を求める厳密な方式、.sh/.bash/.bats
     は「一致位置より前のダブルクォート文字数の偶奇」という字句
     ヒューリスティック(複雑な入れ子は正しく扱えない場合がある)を
     用いる。tokenize が失敗した.pyファイル(構文エラー等)はヒューリ
     スティックへ自動的にフォールバックする。判定に自信が持てない場合
     は EXCLUDED_FP ではなく通常の分類に残す設計とし、除外した行は
     必ず一覧で報告する(黙って捨てない)。
  2b. .sh/.bash/.bats の heredoc 本体(`<<DELIM` 〜 終端DELIM行)は、
     生成先の別ファイルへ書き込まれる文字列であり、本ファイル自身の
     実行文ではないため、代入追跡・rm -rf 走査の両方から除外する
     (実例: tests/unit/test_idle_flag.bats の heredoc 内
     `export IDLE_FLAG_DIR="$IDLE_FLAG_DIR"` を実際の再代入と誤認し、
     同一行の `rm -rf "$IDLE_FLAG_DIR" ...` を誤って DANGER 判定した
     不具合を修正した)。終端DELIM行の検出は字句一致であり、ネストした
     heredoc等の複雑な構造は正しく扱えない場合がある。
     ★終端DELIM行の比較はCRLF(`\r`)を無視して行う(redo1・
     G753-FAILCLOSED-CRLF-01是正)。CRLFファイルで `\r` を無視せずに
     比較すると終端行が常に不一致となり、以後EOFまでの全行が
     heredoc本体として誤って除外される(実例: tests/unit/
     test_dynamic_model_routing.bats:382 の実行可能な teardown
     `rm -rf "$TEST_TMP"` が誤って EXCLUDED_FP に分類されていた)。
     ★終端DELIM行がEOFまで見つからない場合(未終端heredoc)は、
     以降の行を黙って本体扱い(EXCLUDED_FP)で除外しない(redo1)。
     ★redo2で以下を追加是正(G753-UNTERMINATED-ALLOW-REDO1-02):
     開始行以降を「通常走査に残す」だけでは、区間内に正当な
     `V=$(mktemp -d ...)` 代入と `rm -rf "$V"` が偶然置かれていた
     場合に判定不能が「証明できたPASS」へ化けてしまう(軍師が独立
     再現)。是正後は開始行以降を代入追跡からも除外したうえで、
     区間内の `rm -rf` 出現は operand 判定を行わず無条件で
     DANGER(判定不能)とする。「未終端heredoc検出」として別途も
     報告し、fail-closedで exit code 1 を返す。
  2c. heredoc **開始**記法(`<<DELIM`)自体の検出は 2b 同様の字句一致
     であり、限界1のような「コメント/文字列リテラル内か」の判定は
     行わない。したがって、コメント中でheredoc構文を説明している
     行(実例: scripts/shogun_to_karo_lock.sh:10 の
     `` `cat >> ... <<EOF ... EOF` `` というコメント中の例示)や、
     heredoc本来体(`<<`)ではないヒアストリング(`<<<`)がコメント中の
     使用例として現れる行(実例: tests/test_helper/bats-assert/src/
     {assert_output,refute_output}.bash の `<<< hello` / `<<< world`
     ——`<<<`の2文字目3文字目が`<<IDENT`として誤って部分一致する)を、
     実在しない heredoc の開始と誤認することがある。この誤検出は
     2bのfail-closed設計により「未終端heredoc検出」として可視化される
     ため、対象ファイルにその誤検出点より後で真の `rm -rf` が存在
     しない限り安全側(DANGERへの誤判定なし)に倒れるが、人手レビュー
     の手間は生じる。開始側の字句一致をコメント/文字列除外つきに
     強化することは本redoのスコープ外とし、次回以降の課題とする。
  3. Python の `subprocess.run(["rm", "-rf", var])` のようなリスト引数
     形式は、`rm -rf` という連続したテキストにならないため検出できない
     (本検査器はテキスト上の `rm -rf`/`rm -fr` 連続出現のみを走査する)。
     同様に `rm -r -f`(分離フラグ)や `rm --recursive --force` も走査
     対象外(現行コードには実例なし。将軍実測・本検査器のディレクトリ
     別内訳との照合で確認済み)。
  4. allowlist はコマンド文字列を照合するのみで、変数の中身は語らない。
     **安全を担保するのは allowlist ではなく本検査器の側である。**
     「allowlistが安全を保証する」という主張はしない。
  5. 閉じた文法は「実在形+B-1明記の3形式」のみを対象とする。CLAUDE.md
     自体が適格と認める `-t PREFIX` 形式(macOS流)は、実行系コードに
     実例が無いため本検査器の受理集合には含めない。将来使われた場合は
     FORMAT_ONLY(判定不能ゆえ不許可)として人手確認を要求する——
     安全側に倒れるだけで、退行はしない。

## 使い方
    python3 scripts/rm_rf_d002e1_checker.py [--root DIR] [--json OUT.json]
    python3 scripts/rm_rf_d002e1_checker.py --allowlist-out OUT.txt

Exit code: 0 = DANGER 0件・未終端heredoc 0件 (FORMAT_ONLY/EXCLUDED_FPは
           残っていてもよい) /
           1 = DANGER 1件以上、または未終端heredoc 1件以上(要人手レビュー。
           限界2b/2c参照)。
"""
import argparse
import io
import json
import os
import re
import sys
import tokenize
from collections import Counter, OrderedDict

SCAN_EXTS = (".sh", ".bash", ".bats", ".py")
PRUNE_ALWAYS = {".git", "node_modules"}
# A-5: tmp/ と .venv/ は enforcement 対象から外すが、件数は別枠で報告する
ENFORCEMENT_EXCLUDE = {"tmp", ".venv"}

RM_RF_TAIL_RE = re.compile(r'\brm\s+-(?:rf|fr)\b(.*)$')

ASSIGN_RE = re.compile(
    r'^\s*(?:export\s+|local\s+|declare\s+(?:-\w+\s+)*)?'
    r'([A-Za-z_][A-Za-z0-9_]*)=(.*)$')

# rhs 全体が「$( ... )」または「`...`」で丸ごと囲まれたコマンド置換で
# あることをアンカーで要求する(G753-FAILCLOSED-MKTEMP-02由来・維持)。
# 部分一致(例: notmktemp)や、置換の外側に文字列が残る形は一切対象外。
MKTEMP_CMDSUB_RE = re.compile(r'^\$\((.*)\)$|^`(.*)`$', re.DOTALL)

# D002-E1(d) が許容する4綴りのみ("$var" / "${var}" / "${var:?}" /
# "${var:?message}")。中括弧の開閉を独立オプショナルにすると
# `"${var"` のような不整合綴りまで誤って許容してしまうため、
# 4形式を alternation で明示的に書き分ける(★fail-closedの要)。
OP_SPELL_RE = re.compile(
    r'^"\$(?:'
    r'([A-Za-z_][A-Za-z0-9_]*)'                # (1) $var
    r'|\{([A-Za-z_][A-Za-z0-9_]*)\}'           # (2) ${var}
    r'|\{([A-Za-z_][A-Za-z0-9_]*):\?\}'        # (3) ${var:?}
    r'|\{([A-Za-z_][A-Za-z0-9_]*):\?[^}]*\}'   # (4) ${var:?message}
    r')"$')
# 未クォート $VAR 等、変数参照ではあるが綴りが不正なものを拾うための緩い版
# (PASS判定には使わない。起源追跡用の変数名抽出のみに用いる)
OP_VARREF_RE = re.compile(r'^\$(?:([A-Za-z_][A-Za-z0-9_]*)|\{([A-Za-z_][A-Za-z0-9_]*)(?::\?[^}]*)?\})$')

TMPDIR_ROOTED = ("TMPDIR", "BATS_TMPDIR", "BATS_TEST_TMPDIR",
                 "BATS_RUN_TMPDIR", "BATS_FILE_TMPDIR", "BATS_SUITE_TMPDIR")

# ------------------------------------------------------- kind定数(operand側)
ABS_CONSTRUCT = "ABS-CONSTRUCT"      # 絶対リテラル起点。環境非依存に絶対
ABS_TMPDIR_COND = "ABS-TMPDIR-COND"  # TMPDIR系変数起点。TMPDIR未設定/絶対時のみ絶対
FORMAT_ONLY_FORM = "FORMAT-ONLY-FORM"  # closed grammar外の呼出し形(判定不能)
DANGER_TEMPLATE = "DANGER-TEMPLATE"  # template/parent内に制御演算子等を検出
NON_MKTEMP = "NON-MKTEMP"            # mktemp由来と確認できない(起源不明/非mktemp再代入)
LITERAL_KIND = "LITERAL"             # operand自体が変数参照でない(リテラル/連結)
# ★cmd_753完了処理redo1(INELIGIBLE_IN_TREE誤分類是正): LITERAL_KINDの
# うち「絶対パスでも'..'によるescapeでもない相対パスリテラル」だけを
# 分ける専用kind。mktemp由来でないためD002-E1(a)の所有単位の前提は
# 満たせずPASS適格にはならない。★旧実装(対応1)はここで「字面上作業木の
# 外へは出ないためD002自体には抵触しない」とまで断定し、独立の第3区分
# (INELIGIBLE_IN_TREE)へ分けていたが、これは軍師QCがfalse-safeと判定した
# 誤った一般化である(operandの字面だけでは、実行時にCWDが別ディレクトリへ
# `cd`されていないこと・中間pathがsymlinkでないことを保証できない。
# 詳細は本ファイル冒頭docstring「★cmd_753完了処理redo1
# (INELIGIBLE_IN_TREE誤分類是正)の経緯」参照)。本redo1で「D002には
# 抵触しない」という断定は撤回し、classify_hit()での判定先も既存の
# FORMAT_ONLY(判定不能ゆえ不許可)へ統合した——DANGERへは寄せていない
# (genuinely危険と断定する根拠が無いため、非blocking区分のままとする)。
LITERAL_RELATIVE_UNPROVEN_KIND = "LITERAL-RELATIVE-UNPROVEN"


# --------------------------------------------------------------- 走査(ファイル)

def scan_target_files(root):
    """enforcement 対象ファイルと、tmp/.venv 配下ファイル数を分けて返す."""
    enforced = []
    for dirpath, dirnames, filenames in os.walk(root):
        rel_dir = os.path.relpath(dirpath, root)
        top = "(root)" if rel_dir == "." else rel_dir.split(os.sep)[0]
        dirnames[:] = [d for d in dirnames if d not in PRUNE_ALWAYS
                       and d not in ENFORCEMENT_EXCLUDE]
        for fn in filenames:
            if fn.endswith(SCAN_EXTS):
                rel = fn if rel_dir == "." else os.path.join(rel_dir, fn)
                enforced.append(rel.replace(os.sep, "/"))
    return sorted(enforced)


def count_excluded_files(root):
    """A-5: tmp/ と .venv/ 配下の対象拡張子ファイル数(ディレクトリ別)."""
    counts = OrderedDict()
    for topdir in sorted(ENFORCEMENT_EXCLUDE):
        base = os.path.join(root, topdir)
        n = 0
        if os.path.isdir(base):
            for dirpath, dirnames, filenames in os.walk(base):
                dirnames[:] = [d for d in dirnames if d not in PRUNE_ALWAYS]
                for fn in filenames:
                    if fn.endswith(SCAN_EXTS):
                        n += 1
        counts[topdir] = n
    return counts


def dir_breakdown(paths):
    """ディレクトリ別内訳(総数のみ禁止の方針を踏襲)."""
    c = Counter()
    for p in paths:
        top = "(root)" if "/" not in p else p.split("/", 1)[0]
        c[top] += 1
    return c


# --------------------------------------------------------------- heredoc 除外

HEREDOC_START_RE = re.compile(r'<<(-?)\s*([\'"]?)([A-Za-z_][A-Za-z0-9_]*)\2')


def compute_heredoc_body_lines(lines):
    """heredoc 本体の行番号集合(1-indexed)と、未終端heredoc一覧を返す
    (★限界2b参照)。

    戻り値: (body_lines, unterminated)
      body_lines   : 本体として除外してよい行番号の集合。
      unterminated : 終端DELIM行がEOFまで見つからなかったheredocの
                     [(start_lineno, delim), ...] (fail-closed;
                     G753-FAILCLOSED-CRLF-01是正)。

    ★CRLF対応: 本関数へ渡される lines は "\n" のみで split された
    ものであり、CRLFファイルでは各行末に "\r" が残る。終端DELIM行の
    比較で "\r" を無視しないと、CRLFファイルの終端行が常に不一致と
    なり、以後EOFまでの全行が誤って heredoc 本体(除外対象)に落ちる
    (実例: tests/unit/test_dynamic_model_routing.bats:382 の
    実行可能な teardown `rm -rf "$TEST_TMP"` が誤って EXCLUDED_FP に
    分類されていた)。

    ★未終端heredoc対応: 終端DELIM行がEOFまで見つからない場合、
    それ以降の行を黙って本体(除外対象)に含めない。証明できない
    ものは通さない(fail-closed) — 該当行は通常の走査に残し、
    unterminated として別途報告する。
    """
    body_lines = set()
    unterminated = []
    i = 0
    n = len(lines)
    while i < n:
        m = HEREDOC_START_RE.search(lines[i])
        if m:
            dash = bool(m.group(1))
            delim = m.group(3)
            candidate_lines = []
            j = i + 1
            terminated = False
            while j < n:
                raw = lines[j].rstrip("\r\n")
                cmp_line = raw.lstrip("\t") if dash else raw
                if cmp_line == delim:
                    terminated = True
                    break
                candidate_lines.append(j + 1)
                j += 1
            if terminated:
                body_lines.update(candidate_lines)
            else:
                unterminated.append((i + 1, delim))
            i = j + 1
        else:
            i += 1
    return body_lines, unterminated


# --------------------------------------------------------------- mktemp 追跡

def find_assignments(lines, skip_lines=frozenset()):
    """var -> [(lineno, rhs), ...] (1-indexed, ファイル内出現順).

    skip_lines (heredoc本体行) は代入追跡から除外する。
    """
    by_var = {}
    for i, line in enumerate(lines, 1):
        if i in skip_lines:
            continue
        m = ASSIGN_RE.match(line)
        if m:
            by_var.setdefault(m.group(1), []).append((i, m.group(2)))
    return by_var


def last_assignment_before(assignments_by_var, var, before_line):
    """D002-E1(a)+(b) の静的近似: `before_line` より前の最後の代入を返す.

    これより後(before_line 直前まで)に再代入が無いことは、呼び出し側が
    「使用行より前の最後の代入」を採用すること自体で保証される——再代入が
    あれば、その再代入こそが「最後の代入」として拾われ、mktemp 由来性の
    再検査にかかるため。
    """
    items = assignments_by_var.get(var, [])
    candidates = [it for it in items if it[0] < before_line]
    if not candidates:
        return None
    return max(candidates, key=lambda x: x[0])


# --------------------------------------------------- 閉じた文法(B-1・closed grammar)
#
# ★設計方針: inner文字列(mktemp呼出し全体)を、少数の完全一致
# (`^...$`)正規表現へ照合するだけにする。旧実装のようにトークンを
# 1個ずつ消費しながら危険な区切り文字をdenylistで潰す処理は行わない
# ——複合command・redirect・単一&等は、いずれも「捕捉した文字列全体を
# 消費しきれない」ため、以下のいずれの正規表現にも一致せず、
# 自動的に不一致(=不許可)になる。個別パターンを都度追加する必要が
# ない(有限・証明可能)。

MKTEMP_WORD_RE = re.compile(r'^mktemp\b')

# (i) `mktemp -d` — operandなし。
MKTEMP_BARE_RE = re.compile(r'^mktemp\s+-d$')

# (ii) `mktemp -d <template>` — templateは空白を含まない1トークン
# (ダブルクォートで囲われていてもよい)。中身の絶対性判定は
# classify_template_token() に委ねる。
MKTEMP_TEMPLATE_SHAPE_RE = re.compile(r'^mktemp\s+-d\s+("[^"]*"|\S+)$')

# (iii) `mktemp -d -p <parent> [<template>]` /
#       `mktemp -d --tmpdir <parent> [<template>]`
MKTEMP_PARENT_SHAPE_RE = re.compile(
    r'^mktemp\s+-d\s+(?:-p|--tmpdir)\s+("[^"]*"|\S+)(?:\s+("[^"]*"|\S+))?$')
# (iii)の`--tmpdir=`(等号)形式
MKTEMP_PARENT_EQ_SHAPE_RE = re.compile(
    r'^mktemp\s+-d\s+--tmpdir=("[^"]*"|\S+)(?:\s+("[^"]*"|\S+))?$')

# ★cmd_753 scope縮小(将軍裁定C-1): 根は「絶対パスであること」では判定
# しない。★リテラル`/tmp`という文字列そのもので判定する(将軍が実測した
# 全実在形——12+8+8+3+2+149件——の根が例外なく`/tmp`であったため)。
# `/mnt/c/...`・`$HOME`・大小文字違い(`/TMP/...`)・UNC風パス等、
# `/tmp`を字面上の根に持たない形は、絶対パスであっても一致せず
# FORMAT_ONLYへ落ちる(WSL保護パスのfail-open再発防止・C-3)。
#
# ★本redo1(G753-TMP-NESTED-SYMLINK-ESCAPE-01是正): 旧
# `TMP_LITERAL_ROOT_RE`(`^/tmp(?:/[A-Za-z0-9._/-]*)?$`)は文字集合に
# `/`自体を含んでいたため、根が`/tmp`であっても任意階層のネスト・
# 連続slash・dotセグメントが字面上マッチする開集合のままだった。
# 直接template形(B-1(ii))と親指定形(B-1(iii))とで実在する構文が
# 異なる(将軍実測: 前者は`/tmp`直下のbasename1個のみ、後者は`/tmp`
# 単体のみ)ため、1つの正規表現を共用せず、それぞれを専用の正規表現で
# 個別に閉じる。
#
# 直接template形(B-1(ii)): `/tmp/`に続くbasenameは`/`を一切含まない
# (=ネスト・連続slash・dotセグメントを構造的に排除する)1トークンの
# みを受理する。
TMP_DIRECT_TEMPLATE_RE = re.compile(r'^/tmp/([A-Za-z0-9._-]+)$')

# 親指定形(B-1(iii)の-p/--tmpdir引数): リテラル`/tmp`またはリテラル
# `/tmp/`(末尾slashのみ)への完全一致のみを受理する。将軍実測どおり、
# 実在する親指定形は`/tmp`単体のみであり、`/tmp`配下にさらに階層を
# 持つ親指定の実例は無い。
TMP_PARENT_EXACT_RE = re.compile(r'^/tmp/?$')

# ★本redo1(G753-NONCREATING-MKTEMP-TEMPLATE-PASS-02是正): mktempは
# templateの末尾の連続Xだけを実際にランダム文字へ置換してディレクトリ
# を作成する。連続Xが無いtemplateは、mktempが実際にはディレクトリ
# 作成に失敗するか、置換箇所が無いため予測可能な固定名になる形であり、
# D002-E1(a)(mktemp -dが実際にそのディレクトリを作成した、という
# 所有単位の前提)を満たさない。
# ★cmd_753完了処理(対応3・軍師非blocking観察是正): 下の"6"は
# 「mktempが要求する最低数」ではない——GNU mktempの一般仕様上の最低
# 要求数は連続X3個である。将軍が実測した実行系全体のtemplateが例外
# なく連続6個の`X`(大文字)で終わっていたため、本検査器が実測
# canonical形どおりの6個を意図的な閾値として選び機械的に必須化した。
REQUIRED_TRAILING_X_RE = re.compile(r'X{6,}$')

# ★C-2(将軍裁定): operand(mktemp呼出しのtemplate/parent引数)に`..`を
# 含むものは、上記2正規表現の文字集合だけでは構造的に排除できない
# (`.`はpath構成要素の安全な文字として許可しているため、例えば
# `/tmp/..XXXXXX`のようなbasenameが字面上マッチしてしまう)。`..`
# という部分文字列の有無を独立に検査し、含む場合は理由を問わずPASS
# 対象から外す(別名表記による`/tmp`根の迂回を遮断)。危険と断定は
# しない——受理集合の外として扱う(B-2/C-3)。
DOTDOT_RE = re.compile(r'\.\.')

# TMPDIR系変数起点のtemplate(実在する慣用句。B-4の環境依存対象)。
TMPDIR_VAR_TEMPLATE_RE = re.compile(
    r'^\$\{?(%s)\}?(?:/[A-Za-z0-9._/-]+)?$' % '|'.join(TMPDIR_ROOTED))

# B-1(iii)のtrailing token(親指定形の第2引数=template)専用の安全な
# リテラル文法(★本redo新設)。parentは既に絶対性を保証済みのため、
# trailingは絶対パスである必要はない——`x.XXXXXX`のような親相対の
# ファイル名リテラルのみを認証する。先頭文字を英数字に限定することで
# `-u`/`--dry-run`/`--help`/`--version`のような非生成option形(先頭が
# `-`)を構造的に排除する(TMP_DIRECT_TEMPLATE_RE/TMP_PARENT_EXACT_RE
# とは別文法——あちらは直接template形/親指定形の絶対パス専用であり、
# trailingの実在形(親相対のファイル名)には一致しない)。★本redo1で
# 末尾連続X要求(REQUIRED_TRAILING_X_RE)を追加適用する
# (classify_trailing_template_token参照)。
SAFE_LITERAL_TEMPLATE_RE = re.compile(r'^[A-Za-z0-9][A-Za-z0-9._-]*$')

# 単一トークン内に埋め込まれた制御演算子/コマンド置換記号。空白を挟まず
# 隣接していても bash はこれらを別command境界として解釈するため、
# `\S+` だけでは見逃す(★新発見の穴の核心)。
UNSAFE_CHARS_RE = re.compile(r'[;&|<>`\n]|\$\(')


def _strip_quotes(tok):
    if len(tok) >= 2 and tok[0] == '"' and tok[-1] == '"':
        return tok[1:-1]
    return tok


def classify_template_token(raw_token):
    """B-1(ii)の直接templateトークン1個を分類する(allowlist方式)。

    ★本redo1(G753-TMP-NESTED-SYMLINK-ESCAPE-01/
    G753-NONCREATING-MKTEMP-TEMPLATE-PASS-02是正): `/tmp/`直下の
    basename1個(スラッシュなし)かつ末尾連続X(6個以上)を要求する
    TMP_DIRECT_TEMPLATE_RE/REQUIRED_TRAILING_X_REへ置き換えた
    (旧TMP_LITERAL_ROOT_REはネスト・連続slash・dotセグメントを
    構造的に排除できておらず、末尾X要求も無かった)。

    戻り値: (tag, kind_or_None, reason)
      tag は "PASS_KIND" / "DANGER_KIND" / "FORMAT_ONLY_KIND" のいずれか。
    """
    tok = _strip_quotes(raw_token)
    m_direct = TMP_DIRECT_TEMPLATE_RE.match(tok)
    if (m_direct and not DOTDOT_RE.search(tok)
            and REQUIRED_TRAILING_X_RE.search(m_direct.group(1))):
        return ("PASS_KIND", ABS_CONSTRUCT,
                "literal /tmp 直下basename1個(ネストなし)・末尾連続X・"
                "'..'なしの絶対パス: %s" % tok)
    m = TMPDIR_VAR_TEMPLATE_RE.match(tok)
    if m:
        var = m.group(1)
        if var == "TMPDIR":
            why = ("$TMPDIR起点。POSIXはTMPDIRの絶対性を保証しない。"
                   "TMPDIRが相対パスのとき絶対性を満たさない(B-4・環境依存)")
        else:
            why = ("$%s起点。bats-coreは%s=\"${TMPDIR:-/tmp}\"と定義する"
                   "のみで絶対化しない。TMPDIRが相対パスのとき絶対性を"
                   "満たさない(B-4・環境依存)" % (var, var))
        return ("PASS_KIND", ABS_TMPDIR_COND, why)
    if UNSAFE_CHARS_RE.search(tok):
        return ("DANGER_KIND", None,
                "template/parent引数に制御演算子/コマンド置換とみられる"
                "文字を検出(単一トークン内へのinjection): %r" % tok)
    return ("FORMAT_ONLY_KIND", None,
            "literal /tmp直下basename1個(ネストなし・末尾連続X)でも"
            "TMPDIR系変数起点でもない、または'..'を含む(多段ネスト・"
            "連続slash・dotセグメント・別名表記による/tmp根の迂回・"
            "連続X不足・未知の変数参照。closed grammar(B-1)外・"
            "C-1/C-2): %r" % tok)


def classify_parent_token(raw_token):
    """B-1(iii)の-p/--tmpdir親引数1個を分類する(allowlist方式)。

    ★本redo1新設(G753-TMP-NESTED-SYMLINK-ESCAPE-01是正): 親指定形の
    受理は「リテラル`/tmp`または`/tmp/`への完全一致」のみとする
    (classify_template_token()の直接template形とは受理文法が異なる
    ため、専用関数として分離した)。

    戻り値: (tag, kind_or_None, reason)
      tag は "PASS_KIND" / "DANGER_KIND" / "FORMAT_ONLY_KIND" のいずれか。
    """
    tok = _strip_quotes(raw_token)
    if TMP_PARENT_EXACT_RE.match(tok):
        return ("PASS_KIND", ABS_CONSTRUCT,
                "literal /tmp または /tmp/ の完全一致: %s" % tok)
    m = TMPDIR_VAR_TEMPLATE_RE.match(tok)
    if m:
        var = m.group(1)
        if var == "TMPDIR":
            why = ("$TMPDIR起点。POSIXはTMPDIRの絶対性を保証しない。"
                   "TMPDIRが相対パスのとき絶対性を満たさない(B-4・環境依存)")
        else:
            why = ("$%s起点。bats-coreは%s=\"${TMPDIR:-/tmp}\"と定義する"
                   "のみで絶対化しない。TMPDIRが相対パスのとき絶対性を"
                   "満たさない(B-4・環境依存)" % (var, var))
        return ("PASS_KIND", ABS_TMPDIR_COND, why)
    if UNSAFE_CHARS_RE.search(tok):
        return ("DANGER_KIND", None,
                "template/parent引数に制御演算子/コマンド置換とみられる"
                "文字を検出(単一トークン内へのinjection): %r" % tok)
    return ("FORMAT_ONLY_KIND", None,
            "literal /tmp または /tmp/ への完全一致でもTMPDIR系変数"
            "起点でもない(/tmp配下にさらに階層を持つ親指定・別名表記に"
            "よる/tmp根の迂回・未知の変数参照。closed grammar(B-1)外・"
            "C-1/C-2): %r" % tok)


def classify_trailing_template_token(raw_token):
    """B-1(iii)のtrailing token(親指定形の第2引数=template)を分類する
    (★本redo新設・classify_template_token()とは別文法)。

    親側(parent)とは異なり絶対性を問わない——親が既に絶対リテラル
    (ABS_CONSTRUCT)であることを呼び出し側(mktemp_info)が保証している
    場合にのみ、この関数のPASS_KINDが意味を持つ。安全なリテラル
    template(SAFE_LITERAL_TEMPLATE_RE)かつ末尾連続X(★本redo1・
    G753-NONCREATING-MKTEMP-TEMPLATE-PASS-02是正・REQUIRED_TRAILING_X_RE)
    を満たす場合のみPASS_KINDとし、それ以外(非生成option形・変数展開
    由来・連続X不足・未知の形)はFORMAT_ONLY_KINDへ倒す(redo1是正
    G753-PARENT-TRAILING-OPTION-CLOSED-GRAMMAR-01はここでも維持する)。
    制御演算子/コマンド置換の検出はDANGER_KINDとし、
    classify_template_token()と同じUNSAFE_CHARS_REを共用する。

    戻り値: (tag, kind_or_None, reason)
      tag は "PASS_KIND" / "DANGER_KIND" / "FORMAT_ONLY_KIND" のいずれか。
    """
    tok = _strip_quotes(raw_token)
    if UNSAFE_CHARS_RE.search(tok):
        return ("DANGER_KIND", None,
                "template/parent引数に制御演算子/コマンド置換とみられる"
                "文字を検出(単一トークン内へのinjection): %r" % tok)
    if (SAFE_LITERAL_TEMPLATE_RE.match(tok) and not DOTDOT_RE.search(tok)
            and REQUIRED_TRAILING_X_RE.search(tok)):
        return ("PASS_KIND", ABS_CONSTRUCT,
                "安全なリテラルtemplate(親相対・先頭が英数字・末尾連続X・"
                "'..'なし): %s" % tok)
    return ("FORMAT_ONLY_KIND", None,
            "安全なリテラルtemplate文法(先頭が英数字で"
            "[A-Za-z0-9._-]のみから成り末尾連続X〈6個以上〉を持ち"
            "'..'を含まない)に一致しない(非生成option形/変数展開由来/"
            "連続X不足/未知の形。closed grammar(B-1)外): %r" % tok)


def mktemp_info(rhs):
    """rhs が closed grammar(B-1の(i)(ii)(iii))へ完全一致する mktemp -d
    呼出しかどうかを判定する(cmd_753 scope変更版)。

    戻り値:
      dict {"kind": ABS_CONSTRUCT|ABS_TMPDIR_COND, "reason": str}
        — 認証された形((i)(ii)(iii)のいずれか)。kindがABS_CONSTRUCTの
          ときのみPASS適格。
      "FORMAT_ONLY"
        — mktemp呼出しらしいが closed grammar のいずれにも一致しない
          (判定不能ゆえ不許可。危険とは断定しない)。
      "DANGER_TEMPLATE"
        — template/parent引数に単一トークン内へ埋め込まれた制御演算子/
          コマンド置換を検出した(捕捉値の由来を保証できない)。
      None
        — rhs自体がmktemp呼出し(コマンド置換で丸ごと囲まれ、中身が
          "mktemp"で始まる)ですらない。
    """
    stripped = rhs.strip()
    if len(stripped) >= 2 and stripped[0] == '"' and stripped[-1] == '"':
        stripped = stripped[1:-1]
    m_sub = MKTEMP_CMDSUB_RE.match(stripped)
    if not m_sub:
        return None
    inner = (m_sub.group(1) if m_sub.group(1) is not None else m_sub.group(2)) or ""
    inner = inner.strip()
    if not MKTEMP_WORD_RE.match(inner):
        return None

    if MKTEMP_BARE_RE.match(inner):
        return {"kind": ABS_TMPDIR_COND,
                "reason": ("テンプレートなし(B-1(i))。生成先はTMPDIR配下"
                           "(TMPDIR未設定時のみ/tmp)。TMPDIRが相対パスの"
                           "とき絶対性を満たさない(B-4・環境依存)")}

    m = MKTEMP_PARENT_SHAPE_RE.match(inner) or MKTEMP_PARENT_EQ_SHAPE_RE.match(inner)
    if m:
        parent_raw, trailing_raw = m.group(1), m.group(2)
        tag, kind, reason = classify_parent_token(parent_raw)
        if tag == "DANGER_KIND":
            return "DANGER_TEMPLATE"
        if tag == "FORMAT_ONLY_KIND":
            return "FORMAT_ONLY"
        if trailing_raw is not None:
            # ★本redo是正(G753-PARENT-VALID-TEMPLATE-REDO1-01):
            # trailing token(親指定形の第2引数=template)を専用の閉じた
            # 文法(classify_trailing_template_token)で解析する。危険
            # 文字を検出すれば従来通りDANGER_TEMPLATE。それ以外は、
            # 親がABS_CONSTRUCT(絶対リテラル)かつtrailing自体が安全な
            # リテラルtemplateである場合に限りABS_CONSTRUCTを維持する
            # (将軍裁定B-1(iii)が受理形として明示する「親=絶対リテラル・
            # template=安全なリテラル」の正当な形をPASSさせるため)。
            # 親がABS_TMPDIR_COND(TMPDIR系変数起点)の場合や、trailingが
            # option形/変数展開由来/未知の形の場合は、redo1是正
            # (G753-PARENT-TRAILING-OPTION-CLOSED-GRAMMAR-01)のとおり
            # 内容を問わずFORMAT_ONLYへ落とす(判定不能ゆえ不許可)。
            t_tag, _t_kind, t_reason = classify_trailing_template_token(trailing_raw)
            if t_tag == "DANGER_KIND":
                return "DANGER_TEMPLATE"
            if t_tag == "PASS_KIND" and kind == ABS_CONSTRUCT:
                return {"kind": ABS_CONSTRUCT,
                        "reason": ("B-1(iii) -p/--tmpdir、親=%s、"
                                   "template=%s" % (reason, t_reason))}
            return "FORMAT_ONLY"
        return {"kind": kind, "reason": "B-1(iii) -p/--tmpdir、親=%s" % reason}

    m = MKTEMP_TEMPLATE_SHAPE_RE.match(inner)
    if m:
        tag, kind, reason = classify_template_token(m.group(1))
        if tag == "DANGER_KIND":
            return "DANGER_TEMPLATE"
        if tag == "FORMAT_ONLY_KIND":
            return "FORMAT_ONLY"
        return {"kind": kind, "reason": "B-1(ii) template、%s" % reason}

    return "FORMAT_ONLY"


# --------------------------------------------------------------- operand 判定

def operands_of(tail):
    """`rm -rf` 以降の文字列から operand トークン列を返す(クォート考慮)."""
    tail = re.split(r"\s(?:&&|\|\||;|\||#)\s|\s#", tail)[0].rstrip()
    toks = re.findall(r'"[^"]*"|\'[^\']*\'|\S+', tail)
    return [t for t in toks if t != "--"]


# ★cmd_753完了処理redo1(INELIGIBLE_IN_TREE誤分類是正): mktemp由来では
# ない“純粋なリテラル”operandのうち、`./`で始まり'..'を含まない相対
# パスだけを識別するための文法(TMP_DIRECT_TEMPLATE_RE等と同じ設計方針
# で、実測した実例(`./queue/inbox`)の形に閉じる)。★この正規表現は
# 「operandの見た目の形」を識別するだけであり、それ以上の意味(D002へ
# の抵触有無)は持たせない——旧実装(対応1)はここから「字面上作業木の
# 外へは出ないためD002自体には抵触しない」という結論まで導いていたが、
# それは実行時のCWD/中間symlinkの状態を確認せずに行われた誤った一般化
# だった(詳細は本ファイル冒頭docstring参照)。'..'を含む場合は別途
# DOTDOT_REで排除する(別名表記によるescapeの恐れがあるため)。
LITERAL_RELATIVE_UNPROVEN_RE = re.compile(r'^\./[A-Za-z0-9][A-Za-z0-9._/-]*$')


def classify_operand(op, assignments_by_var, use_line):
    """1つの operand を判定する.

    戻り値: (kind, var_or_None, spelling_ok, reason)
    """
    m = OP_SPELL_RE.match(op)
    spelling_ok = bool(m)
    if not m:
        m = OP_VARREF_RE.match(op) if op.startswith("$") else None
    if not m:
        if (not op.startswith("$") and LITERAL_RELATIVE_UNPROVEN_RE.match(op)
                and not DOTDOT_RE.search(op)):
            return (LITERAL_RELATIVE_UNPROVEN_KIND, None, False,
                    "変数参照ではないoperandだが、'./'始まりの相対パス"
                    "リテラルであり('..'なし)。ただし実行時のCWDが作業木"
                    "内に固定されている保証、および中間pathがsymlinkで"
                    "ないことの保証を本検査器は静的に確認できない"
                    "(CWD/symlink未証明・要人手確認): %r" % op)
        return (LITERAL_KIND, None, False,
                "変数参照ではない operand(リテラル/不正クォート/連結): %r" % op)
    var = next(g for g in m.groups() if g is not None)
    last = last_assignment_before(assignments_by_var, var, use_line)
    if last is None:
        return (NON_MKTEMP, var, spelling_ok,
                "変数 %s: 使用行より前に代入が無い(起源不明)" % var)
    use_ln, rhs = last
    info = mktemp_info(rhs)
    if info is None:
        return (NON_MKTEMP, var, spelling_ok,
                "変数 %s: 使用直前の代入(%d行目)がmktemp呼出しでない"
                % (var, use_ln))
    if info == "FORMAT_ONLY":
        return (FORMAT_ONLY_FORM, var, spelling_ok,
                "変数 %s: mktemp呼出しではあるが閉じた文法(B-1 (i)(ii)(iii))"
                "外の形——判定不能ゆえ不許可(危険とは断定しない)" % var)
    if info == "DANGER_TEMPLATE":
        return (DANGER_TEMPLATE, var, spelling_ok,
                "変数 %s: 使用直前の代入(%d行目)のmktemp呼出しの"
                "template/parent引数に制御演算子/コマンド置換を検出"
                "(捕捉値の由来を保証できない)" % (var, use_ln))
    return (info["kind"], var, spelling_ok,
            "変数 %s は mktemp -d 由来(%s)" % (var, info["reason"]))


def classify_hit(op_results):
    """operand 判定結果の集合から、この rm -rf 呼出し全体の判定を返す."""
    if not op_results:
        return "DANGER", "operand を抽出できない(行継続等。fail-closed)"
    kinds = [r[0] for r in op_results]
    if any(k in (LITERAL_KIND, NON_MKTEMP, DANGER_TEMPLATE) for k in kinds):
        return "DANGER", ("mktemp -d由来と確認できない、または捕捉値の由来を"
                           "保証できないoperandを含む")
    # ★cmd_753完了処理redo1(INELIGIBLE_IN_TREE誤分類是正): 全operandが
    # LITERAL_RELATIVE_UNPROVEN_KIND(絶対パスでも'..'によるescapeでも
    # ない相対パスリテラル)である場合のみ、この専用分岐を通す。他の
    # kindが1つでも混在する場合はこのブロックを通過させず(all()が
    # 偽になる)、以降の既存分岐(fail-closedのFORMAT_ONLY等)へ委ねる
    # ——判定挙動を広げない。★旧実装(対応1)はここで独立tag
    # `INELIGIBLE_IN_TREE`(「D002自体には抵触しない」という断定つき)を
    # 返していたが、operandの字面だけでは実行時のCWD/中間symlinkの状態
    # を保証できず、軍師QCがfalse-safeと判定した(詳細は本ファイル冒頭
    # docstring参照)。本redo1では独立tagを廃止し、既存のFORMAT_ONLY
    # (判定不能ゆえ不許可)へ統合する——genuinely危険と断定する根拠は
    # 無いためDANGERへは寄せず、非blocking区分のままとする。
    if kinds and all(k == LITERAL_RELATIVE_UNPROVEN_KIND for k in kinds):
        return "FORMAT_ONLY", (
            "全operandが変数参照ではない'./'相対パスリテラルであり"
            "('..'なし)、mktemp -d由来でもないためD002-E1(a)の所有単位の"
            "前提を満たせない。実行時のCWDが作業木内に固定されている保証、"
            "および中間pathがsymlinkでない保証を本検査器は静的に確認"
            "できないため、'D002自体には抵触しない'とは断定しない——"
            "CWD/symlink未証明・要人手確認(判定不能ゆえ不許可。危険と"
            "断定はしない)")
    if any(not r[2] for r in op_results):
        return "FORMAT_ONLY", ("D002-E1(d)の4形式(\"$var\"/\"${var}\"/"
                                "\"${var:?}\"/\"${var:?msg}\")に合致しない"
                                "綴りのoperandを含む")
    if any(k in (ABS_TMPDIR_COND, FORMAT_ONLY_FORM) for k in kinds):
        return "FORMAT_ONLY", ("mktemp呼出し由来ではあるが、絶対性を静的に"
                                "証明できない、または閉じた文法(B-1)外の形の"
                                "operandを含む(判定不能ゆえ不許可)")
    if all(k == ABS_CONSTRUCT for k in kinds):
        return "PASS", "全operandがmktemp -d由来・絶対リテラル起点(B-1(ii)/(iii))・綴り適合"
    return "FORMAT_ONLY", "分類不能な残余(fail-closedでFORMAT_ONLY)"


# --------------------------------------------------------------- FP 除外

_PY_STRING_COMMENT_TYPES = {tokenize.STRING, tokenize.COMMENT}
for _name in ("FSTRING_START", "FSTRING_MIDDLE", "FSTRING_END"):
    if hasattr(tokenize, _name):
        _PY_STRING_COMMENT_TYPES.add(getattr(tokenize, _name))


def py_string_comment_spans(text):
    """.py ファイル本文から STRING/COMMENT トークンの位置範囲を求める.

    tokenize が失敗した場合(構文エラー等)は None を返し、呼び出し側で
    行ベースのヒューリスティックへフォールバックさせる。
    """
    spans = []
    try:
        for tok in tokenize.generate_tokens(io.StringIO(text).readline):
            if tok.type in _PY_STRING_COMMENT_TYPES:
                spans.append((tok.start[0], tok.start[1], tok.end[0], tok.end[1]))
    except (tokenize.TokenizeError, IndentationError, SyntaxError, ValueError):
        return None
    return spans


def pos_in_spans(lineno, col, spans):
    for (sl, sc, el, ec) in spans:
        if sl <= lineno <= el:
            if sl == el:
                if sc <= col < ec:
                    return True
            elif lineno == sl:
                if col >= sc:
                    return True
            elif lineno == el:
                if col < ec:
                    return True
            else:
                return True
    return False


def is_excluded_fp_heuristic(line, match_start):
    """コメント行/文字列リテラル内の `rm -rf` を実行文でないとして除外するか
    (行ベースの字句ヒューリスティック。.sh/.bash/.bats、および.pyの
    tokenizeフォールバック用)。

    ★限界1に明記: 行頭コメントは即除外。それ以外は一致位置より前の
    シングル/ダブルクォート文字数それぞれの偶奇で「文字列内か」を推定
    する(いずれかが奇数=文字列内)。複数行文字列やheredocの内部は
    正しく扱えない場合がある。判定根拠は reason として必ず残す。
    """
    stripped = line.lstrip()
    if stripped.startswith("#"):
        return True, "コメント行"
    prefix = line[:match_start]
    dq = prefix.count('"')
    sq = prefix.count("'")
    if dq % 2 == 1:
        return True, "一致位置より前のダブルクォート数が奇数(文字列リテラル内と推定)"
    if sq % 2 == 1:
        return True, "一致位置より前のシングルクォート数が奇数(文字列リテラル内と推定)"
    return False, ""


# --------------------------------------------------------------- 本体

def analyze_file(root, relpath):
    """1ファイルを解析し、hit のリストを返す."""
    abspath = os.path.join(root, relpath)
    try:
        # newline="" + "\n" 分割固定: str.splitlines() は U+2028 等の
        # 追加の行区切りも分割対象にしてしまい、grep -n /エディタが数える
        # 行番号とズレる恐れがある(cmd_735 CRLF教訓と同種の罠)。
        with open(abspath, encoding="utf-8", errors="replace", newline="") as fh:
            text = fh.read()
    except OSError:
        return [], []
    lines = text.split("\n")
    is_shell = relpath.endswith((".sh", ".bash", ".bats"))
    if is_shell:
        heredoc_lines, unterminated = compute_heredoc_body_lines(lines)
    else:
        heredoc_lines, unterminated = frozenset(), []

    # ★redo2是正(G753-UNTERMINATED-ALLOW-REDO1-02): 終端DELIM行が
    # EOFまで見つからないheredocが1件でもあれば、その開始行以降の
    # ファイル内容は構文的に信頼できない(本体がどこまで続くか本検査器
    # には確定できない)。従来はこの区間の行を「heredoc本体としては
    # 除外しないが通常走査には残す」設計であったため、区間内に正当な
    # `V=$(mktemp -d ...)` 代入と `rm -rf "$V"` を置いた合成fixtureで
    # 判定不能が「証明できたPASS」に化けてしまっていた(軍師が独立
    # 再現・そのまま信用してよい)。是正: 最初の未終端heredoc開始行
    # 以降(開始行自身を含む)を「poisoned」区間とし、(a) この区間の
    # 行は代入追跡からも除外し(heredoc本体行と同じ理由——区間内の
    # 見かけ上の代入がheredoc本体テキストの一部である可能性を排除
    # できない)、(b) この区間内に現れる `rm -rf` はoperand判定を行わず
    # 無条件でDANGER(判定不能・fail-closed)とする。
    poisoned_from = min((u[0] for u in unterminated), default=None)
    skip_for_assign = set(heredoc_lines)
    if poisoned_from is not None:
        skip_for_assign.update(range(poisoned_from, len(lines) + 1))
    assignments_by_var = find_assignments(lines, skip_lines=skip_for_assign)

    py_spans = py_string_comment_spans(text) if relpath.endswith(".py") else None

    hits = []
    for lineno, line in enumerate(lines, 1):
        for m in re.finditer(r'rm\s+-(?:rf|fr)\b', line):
            if lineno in heredoc_lines:
                excluded, reason = True, "heredoc本体(生成先ファイルへの書込み内容。本ファイルの実行文でない)"
            elif poisoned_from is not None and lineno >= poisoned_from:
                raw = line.rstrip("\n")
                hits.append({
                    "file": relpath, "line": lineno, "raw": raw,
                    "tag": "DANGER",
                    "reason": ("未終端heredoc(%d行目開始)以降のため構文的に信頼できず、"
                               "operand判定を行わずfail-closedでDANGERとする"
                               % poisoned_from),
                    "operands": [],
                })
                continue
            elif py_spans is not None:
                if pos_in_spans(lineno, m.start(), py_spans):
                    excluded, reason = True, "tokenize: STRING/COMMENTトークン内"
                else:
                    excluded, reason = False, ""
            else:
                excluded, reason = is_excluded_fp_heuristic(line, m.start())
            raw = line.rstrip("\n")
            if excluded:
                hits.append({
                    "file": relpath, "line": lineno, "raw": raw,
                    "tag": "EXCLUDED_FP", "reason": reason, "operands": [],
                })
                continue
            tailm = RM_RF_TAIL_RE.search(line[m.start():])
            tail = tailm.group(1) if tailm else ""
            ops = operands_of(tail)
            op_results = [classify_operand(op, assignments_by_var, lineno)
                          for op in ops]
            tag, hit_reason = classify_hit(op_results)
            hits.append({
                "file": relpath, "line": lineno, "raw": raw, "tag": tag,
                "reason": hit_reason,
                "operands": [
                    {"token": op, "kind": r[0], "var": r[1],
                     "spelling_ok": r[2], "detail": r[3]}
                    for op, r in zip(ops, op_results)
                ],
            })
    unterminated_reports = [
        {"file": relpath, "line": start_lineno, "delim": delim}
        for start_lineno, delim in unterminated
    ]
    return hits, unterminated_reports


def literal_allow_entries(hits):
    """PASS 判定 hit から、settings.local.json allow へ列挙すべき
    リテラルコマンド文字列の集合を返す(重複排除・決定的順序)."""
    seen = OrderedDict()
    for h in hits:
        if h["tag"] != "PASS":
            continue
        m = RM_RF_TAIL_RE.search(h["raw"])
        if not m:
            continue
        cmd = "rm -rf" + m.group(1)
        cmd = re.split(r"\s(?:&&|\|\||;|\||#)\s|\s#", cmd)[0].rstrip()
        cmd = cmd.strip()
        seen[cmd] = True
    return list(seen.keys())


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                  formatter_class=argparse.RawDescriptionHelpFormatter)
    here = os.path.dirname(os.path.abspath(__file__))
    ap.add_argument("--root", default=os.path.dirname(here),
                     help="走査するリポジトリ root (既定: 本ファイルの親の親)")
    ap.add_argument("--json", default=None, help="全hit詳細をJSONで出力する path")
    ap.add_argument("--allowlist-out", default=None,
                     help="PASS判定のリテラルコマンド文字列一覧を出力する path")
    args = ap.parse_args(argv)

    root = os.path.abspath(args.root)
    files = scan_target_files(root)
    excluded_counts = count_excluded_files(root)

    all_hits = []
    all_unterminated = []
    for relpath in files:
        hits, unterminated = analyze_file(root, relpath)
        all_hits.extend(hits)
        all_unterminated.extend(unterminated)

    tag_counts = Counter(h["tag"] for h in all_hits)
    dirs = dir_breakdown(files)

    print("=== D002-E1 rm -rf 適合性検査 (cmd_753・パス軸closed grammar redo1版) ===")
    print("--- 受理集合(closed grammar・B-1・列挙外は一切PASSしない) ---")
    print("  (i)   mktemp -d")
    print("  (ii)  mktemp -d <リテラル/tmp直下basename1個・末尾連続X必須>")
    print("        例: mktemp -d /tmp/foo.XXXXXX")
    print("  (iii) mktemp -d (-p|--tmpdir[=]) <リテラル/tmpまたは/tmp/> [<template>]")
    print("  ★(i)はTMPDIR環境依存(B-4)のためPASSにはしない(FORMAT_ONLY止まり)。")
    print("  ★PASSは(ii)(iii)が根=リテラル/tmp(絶対パス一般ではない・C-1)")
    print("    かつ'..'を含まず(C-2)、綴り適合の場合のみ。")
    print("  ★(ii)のtemplateは/tmp直下のbasename1個のみ(多段ネスト・連続")
    print("    slash・dotセグメントは中間symlink迂回の恐れがあり不許可・")
    print("    G753-TMP-NESTED-SYMLINK-ESCAPE-01)。かつ末尾に連続X(6個以上)")
    print("    を要求する(連続Xを欠くtemplateはmktempが実際にはディレクトリ")
    print("    作成に失敗するか固定名になり得るため・")
    print("    G753-NONCREATING-MKTEMP-TEMPLATE-PASS-02)。")
    print("  ★(iii)の<parent>はリテラル/tmpまたは/tmp/への完全一致のみ。")
    print("    [<template>]は省略可。省略時、または親=/tmp根かつtemplateが")
    print("    安全なリテラル・末尾連続X(例: x.XXXXXX)の場合のみPASS対象。")
    print("  ★/mnt/c等のWSL保護パス・$HOME・大小文字違い・UNC風パス・")
    print("    '..'による別名表記は根が/tmpでないため一括不許可(C-3)。")
    print("  ★bareファイルモードmktemp・-t形式・オプション追加・複合command・")
    print("    redirect・部分一致は上記に一致せず、理由を問わず不許可")
    print("    (判定不能=FORMAT_ONLY。危険とは断定しない。B-2)。")
    print("  ★ただしtemplate/parent引数内に制御演算子/コマンド置換を検出した")
    print("    場合のみDANGERとする(捕捉値の由来を保証できないため)。")
    print("走査対象ファイル数(enforcement対象): %d" % len(files))
    print("--- ディレクトリ別内訳(enforcement対象) ---")
    for d, n in sorted(dirs.items(), key=lambda x: (-x[1], x[0])):
        print("  %-40s %d" % (d, n))
    print("--- enforcement対象外(A-5): 件数のみ別枠報告 ---")
    for d, n in excluded_counts.items():
        print("  %-40s %d" % (d, n))
    print("--- rm -rf/-fr 出現 判定内訳 ---")
    # ★cmd_753完了処理(対応1): 既存test(tests/unit/test_rm_rf_d002e1_
    # checker.bats)が"PASS           1"のような%-14s由来の厳密な部分
    # 一致で出力を検証しているため、幅14は変更しない。
    for tag in ("PASS", "FORMAT_ONLY", "DANGER", "EXCLUDED_FP"):
        print("  %-14s %d" % (tag, tag_counts.get(tag, 0)))
    print("  %-14s %d" % ("TOTAL", len(all_hits)))

    danger_hits = [h for h in all_hits if h["tag"] == "DANGER"]
    if danger_hits:
        print("--- DANGER 一覧 ---")
        for h in danger_hits:
            print("  %s:%d: %s  [%s]" % (h["file"], h["line"], h["raw"].strip(), h["reason"]))

    # ★cmd_753完了処理redo1(INELIGIBLE_IN_TREE誤分類是正): 旧実装は
    # 独立tag `INELIGIBLE_IN_TREE`として別枠表示していたが、「D002自体
    # には抵触しない」という断定を撤回しFORMAT_ONLYへ統合したため
    # (詳細は本ファイル冒頭docstring参照)、専用のtop-level tagとしては
    # 表示しない。監査用に、FORMAT_ONLY中でこの'./'相対パス未証明kindに
    # 該当するhitのみを個別に一覧表示する(汎用のFORMAT_ONLY一覧へ
    # 埋没させない・kindフィールドで判定するためreason文字列の変更に
    # 影響されない)。
    unproven_relative_hits = [
        h for h in all_hits
        if h["tag"] == "FORMAT_ONLY"
        and any(op["kind"] == LITERAL_RELATIVE_UNPROVEN_KIND for op in h["operands"])
    ]
    if unproven_relative_hits:
        print("--- FORMAT_ONLY中の'./'相対パス未証明一覧"
              "(CWD/symlink未証明・要人手確認・非blocking) ---")
        for h in unproven_relative_hits:
            print("  %s:%d: %s  [%s]" % (h["file"], h["line"], h["raw"].strip(), h["reason"]))

    if all_unterminated:
        print("--- 未終端heredoc検出(fail-closed: 要人手確認・DANGER相当) ---")
        print("  %d 件。終端DELIM行がEOFまで見つからなかったため、"
              "以降を本体扱いで黙って除外せず通常走査に残した。" % len(all_unterminated))
        for u in all_unterminated:
            print("  %s:%d: <<%s の終端未検出" % (u["file"], u["line"], u["delim"]))

    allow_entries = literal_allow_entries(all_hits)
    if args.allowlist_out:
        with open(args.allowlist_out, "w", encoding="utf-8") as fh:
            for e in allow_entries:
                fh.write(e + "\n")
        print("--- allowlist候補(PASS由来・リテラル・重複排除): %d 件 → %s ---"
              % (len(allow_entries), args.allowlist_out))
    else:
        print("--- allowlist候補(PASS由来・リテラル・重複排除): %d 件 ---"
              % len(allow_entries))
        for e in allow_entries:
            print("  %s" % e)

    if args.json:
        report = {
            "root": root,
            "files_enforced": len(files),
            "dir_breakdown_enforced": dict(dirs),
            "excluded_dir_counts": dict(excluded_counts),
            "tag_counts": dict(tag_counts),
            "allow_entries": allow_entries,
            "hits": all_hits,
            "unterminated_heredocs": all_unterminated,
        }
        with open(args.json, "w", encoding="utf-8") as fh:
            json.dump(report, fh, ensure_ascii=False, indent=2)
        print("--- 全hit詳細JSON: %s ---" % args.json)

    return 1 if (danger_hits or all_unterminated) else 0


if __name__ == "__main__":
    sys.exit(main())
