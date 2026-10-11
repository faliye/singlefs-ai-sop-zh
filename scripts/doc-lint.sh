#!/usr/bin/env bash
# admission: always 判的是此刻全仓的文本，几秒跑完；每一轮门禁都现判，上一轮的结论不替这一轮作保
# run-condition: command git gawk
# 文档铁律的自动检查。rules/writing-discipline.md 和它分出去的 design-doc、kb 两篇靠这个脚本强制，不靠自觉。
#
#   bash scripts/doc-lint.sh [项目根]
#   bash scripts/doc-lint.sh --not-impl    只报本语言没实现的检查，一行一条，退 0（gate.sh 收进汇总的未实现清单）
#   DOC_LINT_LANG=<语言>    只给 scripts/selftest.sh 用，设了就自报（见「语言」一段）
#   DOC_LINT_VERBOSE=1      逐份报结果，列出跳过的文件与编号引用的全量清单
# 退出码：0 通过；1 判红或判不了。
#
# 检查 A–M（判据与堵过的绕法写在各段代码旁）：
#   A   正文（「## 历史版本」之前）的历史陈述与就地废弃标注
#   A2  围栏配对；「## 历史版本」之后不许再开节——任一不成立，其后内容躲开全部扫描
#   B   CLAUDE.md、rules/*.md 不留历史节；B2 agents/*.md 同样不留，且 frontmatter 的 name 与文件名一致、有 description
#   B3  GLOSSARY.md 的说明列三语并列（zh<br>en<br>ja）
#   C   kb/*.md 以「## 历史版本」收尾；有 .claude/history-carriers 时只判登记的，没登记的不许有这一节。INDEX.md 不判
#   D   kb 与规范文本（CLAUDE.md、rules/、agents/、skills/*/SKILL.md）的 D-1 位置指代、D-2 自指称呼；D-3 kb 的时间指代
#   E   kb 引用的不变量编号（I-<类>.<号>）要有定义；F 编号只许一处登记位；G 引用带简称且与登记位一致；H 反复出现（≥3 次）的编号形状要登记
#   I   给人读的 .md 里翻译腔、古风腔、过度解释的固定构式
#   J   .claude/doc-lint-exclude 的排除项带理由、指向真实目录、真排到了东西
#   K   rules/*.md 与 @ 引用逐项相等
#   L   .claude/warnings/ 的警告记录：文件名 YYYY-MM-DD.md，每个 ## 小节四项齐全
#   M   历史条目的 `### 日期` 与「实测（日期）」不许是编的
# A、D、I 是词表型，只在有词表的语言上跑（日文另有 D-1、D-2），别的报未实现。围栏里的内容不查（那是示例）。
#
# 文件头 5 行内独占一行的两张牌：
#   <!-- doc-lint:rule-definition -->   规则定义文件：正文照查，只把反引号与「」里的举例在比对词表前挖掉
#   <!-- doc-lint:history-registry -->  kb 里全篇是历史登记的文件（一条一节、节内就是完整历史）：A、D-1、D-2、I 从第一个 `## ` 起不判，
#                                       等于把 body_of 的停机点从历史节挪到第一个 `## `；D-3、C、E–H、A2 照判，它们不读 body_of 的输出

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight "${BASH_SOURCE[0]}" "$@"; set -- ${PREFLIGHT_ARGUMENTS[@]+"${PREFLIGHT_ARGUMENTS[@]}"}

# `--not-impl` 要在解析项目根之前认出来，不然它被当成项目根拒掉；ROOT 换成本包目录，这一支跑不到扫描。
NOT_IMPL_ONLY=0
if [[ "${1:-}" == --not-impl ]]; then
  NOT_IMPL_ONLY=1
  set -- "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

ROOT="${1:-$(project_root)}"
[[ -d "$ROOT" ]] || die "找不到项目根：$ROOT" \
  "把项目根作为第一个参数传进来： bash scripts/doc-lint.sh <项目根>"
# 削掉末尾斜杠：带 `/` 时 EXCL 里的 `$ROOT//<目录>/*` 一个都匹配不上，排除静默失效，输出看不出区别。
if [[ "$ROOT" != "/" ]]; then ROOT="${ROOT%/}"; fi

tmpd="$(mktemp -d)"; trap 'rm -rf "$tmpd"' EXIT

# 日期下界取被查项目第一个提交，拿不到（样本目录、没有 .git 的副本、浅克隆）用本包的；判据在 lib.sh 的 date_out_of_range。
PROJECT_START_DATE="$(project_start_date "$ROOT")"; PROJECT_START_DATE="${PROJECT_START_DATE:-$SOP_START_DATE}"
require_date_arithmetic

# 不扫 $ROOT/scripts/fixtures/（故意写坏的样本，selftest.sh 拿去证明检查会红）与 $ROOT/.claude/<族名>/
# （装进来的副本，由上游门禁管；项目侧再扫会与项目 kb 的编号撞成假红）。
# 两条都写成相对本次 ROOT 的路径：写成 */…/* 的话 selftest 拿样本目录当 ROOT 跑时样本全被跳过，自证成了摆设，
# 扫描范围也会随包所在的路径变。
EXCL=(-not -path "$ROOT/scripts/fixtures/*")
DOC_LINT_FAMILY="$(sed -n 's/^family=//p' "$(dirname "${BASH_SOURCE[0]}")/../I18N" 2>/dev/null || true)"
EXCL+=(-not -path "$ROOT/.claude/${DOC_LINT_FAMILY:-singlefs-ai-sop}/*")

# ── kb 目录登记（rules/kb-discipline.md）────────────────
# 项目把 kb 文本（不变量、决策、实验这类）挪出 .claude/kb/ 时，登记项目根的 .claude/kb-directories（kb_directories，lib.sh）：
# 一行一条，相对项目根，`#` 后写理由；没有这份文件时，kb 文件按路径认：任何 */kb/*.md。登记的目录指向不存在的路径判红。
KB_DIRS=()
kb_dirs_text="$(kb_directories "$ROOT")"
if [[ -n "$kb_dirs_text" ]]; then mapfile -t KB_DIRS <<< "$kb_dirs_text"; fi
is_kb_path() { # is_kb_path <路径> → 0 表示它在 kb 范围内（不管后缀）；登记了就按登记的目录判，没登记按 */kb/* 的老规矩
  local path="$1"
  if ((${#KB_DIRS[@]})); then
    local dir
    for dir in "${KB_DIRS[@]}"; do
      [[ "$path" == "$dir"/* || "$path" == "$dir" ]] && return 0
    done
    return 1
  fi
  [[ "$path" == */kb/* ]]
}
is_kb_markdown() { [[ "$1" == *.md ]] && is_kb_path "$1"; } # is_kb_markdown <路径> → 0 表示它是 kb 范围内的 .md
kb_markdown_files() { # kb 范围内全部 .md 的绝对路径，排除表与 fixtures/副本照旧挡在外面
  if ((${#KB_DIRS[@]})); then
    local dir
    for dir in "${KB_DIRS[@]}"; do
      find "$dir" -name '*.md' -not -path '*/.git/*' "${EXCL[@]}"
    done | sort
  else
    find "$ROOT" -path '*/kb/*.md' -not -path '*/.git/*' "${EXCL[@]}" | sort
  fi
}

# ── 语言 ────────────────────────────────────────────────
# 判据（历史陈述的词、历史节标题、指代词表）全是语言相关的字面量，按本包 I18N 的 this= 取，读不到按 zh。
# 没有词表的语言，词表型检查显式报未实现，不静默通过（rules/show-me-test.md「门禁不许假装通过」）：照翻词表会误拒，误拒比漏检更糟。
# DOC_LINT_LANG 只给 scripts/selftest.sh 用：样本是中文写的、逐字节复制进每个语言仓，样本的语言是样本的属性，不是仓的属性。
# 拿它跑真实项目等于换判据，所以设了就打印出来。
# `|| true`：I18N 不在时 sed 退 2，set -e 会当场把脚本带走、一个字都不打。
PKG_LANG="$(sed -n 's/^this=//p' "$(dirname "${BASH_SOURCE[0]}")/../I18N" 2>/dev/null | head -1 || true)"
LANG_FORCED=0
DOC_LANG="$PKG_LANG"
if [[ -n "${DOC_LINT_LANG:-}" ]]; then DOC_LANG="$DOC_LINT_LANG"; LANG_FORCED=1; fi
[[ -n "$DOC_LANG" ]] || DOC_LANG=zh

# 警告记录的四个项名也按语言取：认的是固定项名，是结构型判据，三种语言都跑，不进 WORDLIST。
case "$DOC_LANG" in
  zh) HIST_HEAD='## 历史版本'
      W_ITEMS=('**提议**' '**异议**' '**已知风险**' '**结果**') ;;
  en) HIST_HEAD='## Revision history'
      W_ITEMS=('**Proposal**' '**Objection**' '**Known risk**' '**Outcome**') ;;
  ja) HIST_HEAD='## 改訂履歴'
      W_ITEMS=('**提案**' '**異議**' '**既知のリスク**' '**結末**') ;;
  *)  HIST_HEAD='## 历史版本'
      W_ITEMS=('**提议**' '**异议**' '**已知风险**' '**结果**') ;;
esac

# 词表型检查（A、D、I）只有中文词表，不给别的语言硬造：这类判据拿字形黑名单判语义，中文这套是按撞到的假红逐个补出来的，
# 再造两套等于假红面乘三。结构型检查（围栏、历史节的有无与位置、编号治理）所有语言照跑。
WORDLIST=0
[[ "$DOC_LANG" == zh ]] && WORDLIST=1
# 位置指代与自称（D-1、D-2）另算一档：日文指文档位置的是「上記」「前述」「本節」这类专用词，平常说话不这么用，
# 照中文的收法（左边只认句首、标点与助词）换几个词就判得了；英文的 above / below / this section 满篇都是正常用法，照翻就是假红，没有这一档。
REFERENCE_WORDLIST=0
case "$DOC_LANG" in zh|ja) REFERENCE_WORDLIST=1 ;; esac

# --not-impl：哪几条依赖词表只在这一处判，gate.sh 不再自己判语言。
if [[ $NOT_IMPL_ONLY -eq 1 ]]; then
  if [[ $WORDLIST -eq 1 ]]; then exit 0; fi
  if [[ $REFERENCE_WORDLIST -eq 1 ]]; then
    printf '%s\n' "文档铁律的词表型检查（$DOC_LANG）：历史陈述、kb 的时间指代、文风——本语言没有词表"
  else
    printf '%s\n' "文档铁律的词表型检查（$DOC_LANG）：历史陈述、kb 的指代与自称、文风——本语言没有词表"
  fi
  exit 0
fi

# 违规模式：正则 → 为什么违规
# ⚠️ 每条模式的 why 都要不一样：共用一句的话，样本一条 want 就盖住几条，删掉其中任一条都不会红。
# ⚠️ 方括号集合里不许用 \] \[ 转义：POSIX 里括号内的反斜杠是字面量，'[〕】\]]' 从来不命中。
#    要收进 ] 就放在集合首位 '[]〕】]'，要收进 [ 直接写 '[[〔【]'；fixtures/doc-lint/histstate 盯着它。
PATTERNS=(
  '~~[^~]'                    '正文不许用删除线标注废弃，直接删掉并写进「历史版本」'
  '[[〔【]已废弃[]〕】]'         '正文不许用方括号就地标注（〔已废弃〕这类），删掉旧内容并写进「历史版本」'
  '[（〔【(]已废弃'              '正文不许用圆括号就地标注（（已废弃…这类），删掉旧内容并写进「历史版本」'
  '[（(][[:space:]]*原为'        '正文不许写"（原为 X）"，直接改成现行值'
  '[^还复恢化]原先[^前]'         '正文不许写"原先 X"，直接改成现行值'
  '以前[叫是][^否]'              '正文不许写"以前叫/是 X"，直接改成现行值'
  '之前[叫][^否]'                '正文不许写"之前叫 X"，直接改成现行值'
  '曾经[叫是]'                   '"曾经叫/是"只能出现在「历史版本」节内'
  # 前缀只认本 SOP 的编号（D 决策 / E 实验 / C 欠检查 / I 不变量 / A 前提 / O oracle）：写成 [A-Z]… 的话
  # 「已被 U9 覆盖」这种讲盘上字节被写掉的句子也中，两个义项只能靠「被覆盖的是不是一条编号条款」分开。
  '已被[[:space:]]*[DECIAO][0-9]\{1,3\}[^，。；]\{0,4\}覆盖'  '正文不许就地标注被某条覆盖，删掉并写进「历史版本」'
  # 「此前」一族只认「此前写的是 X」这类回述，不认「此前没有」「此前只量了两样」：那是至今仍成立的缺口，不是历史；
  # 不分的话命中里假红压倒真红。
  '此前写的是'                   '正文不许写"此前写的是 X"，直接改成现行值'
  '此前写着'                     '正文不许写"此前写着 X"，直接改成现行值'
  '正文此前写'                   '正文不许回述自己此前写过什么，改成现行值'
  '本决策此前'                   '正文不许回述某条决策此前怎么写，改成现行值'
  '此前从未写'                   '"此前从未写"是历史陈述，写进「历史版本」'
  '此前没有写过'                 '"此前没有写过"是历史陈述，写进「历史版本」'
  '此前没写过'                   '"此前没写过"是历史陈述，写进「历史版本」'
  '此前不存在'                   '"此前不存在"是历史陈述，写进「历史版本」'
  '曾经写作'                     '"曾经写作"只能出现在「历史版本」节内'
  '曾经写着'                     '"曾经写着"只能出现在「历史版本」节内'
  '原先写的是'                   '正文不许写"原先写的是 X"，直接改成现行值'
  '已经不是现行'                 '"已经不是现行"是历史陈述，把现行值写出来'
)

# ── I. 文风：翻译腔与古风腔的固定构式（rules/writing-discipline.md「文风要简单自然」）──────
# 只查词表里的固定说法。句子顺不顺、解释啰不啰嗦机器判不了，词表全绿只代表没踩到最明显的几个坑。
STYLE=(
  '在[^，。；：]\{0,10\}的情况下'   '翻译腔：「在……的情况下」→ 直接说「……的时候」，或者整句重写'
  '对[^，。；：]\{1,10\}而言'       '翻译腔：「对……而言」→「对……来说」'
  '就[^，。；：]\{1,10\}来说'       '翻译腔：「就……来说」→「对……来说」，或者删掉'
  '使得[^到以]'                    '翻译腔：「使得」→「让」'
  '\(^\|[^不未别]\)\(进行\|予以\|加以\)..'  '翻译腔：「进行/予以/加以 + 动词」→ 直接用那个动词'
  '\(此乃\|实乃\|是故[^意]\|然则\|殊为\|不失为\)'  '古风腔：直接说这是什么、所以怎样'
  '\(众所周知\|毋庸置疑\|不言而喻\|无可厚非\)'  '过度解释：这几个词说了等于没说，删掉'
  '诚然[^，。]\{0,12\}[，。]'      '不必要的转折：「诚然……但是」多半两边不冲突，只留你真想说的那半'
)

fails=0; skipped=0; checked=0

# 输出正文：截到「## 历史版本」之前（$2 = 1 时截到第一个「## 」之前，history-registry 那张牌），剔除围栏代码块。
body_of() {
  awk -v HIST="$HIST_HEAD" -v REGISTRY="${2:-0}" '
    # 标题按「去掉行尾空白之后相等」认：行尾多一个空格时正文扫描不在历史节停，kb 还被报缺历史节。
    $0 ~ ("^" HIST "[ \t]*$") { exit }
    REGISTRY == 1 && /^## / { exit }
    /^[ \t]*```/ { infence = !infence; next }
    { if (!infence) print NR "\t" $0; else print NR "\t" }
  ' "$1"
}

head1 "文档铁律检查"

if [[ $LANG_FORCED -eq 1 ]]; then
  warn "语言由 DOC_LINT_LANG 指定为 $DOC_LANG（本包是 ${PKG_LANG:-zh}）——这个变量只给门禁自证用"
  howto "跑真实项目不要设它：判据换成别的语言，等于自己给自己改判据。" \
        "要让本包换语言，改 I18N 的 this=，别在命令行上盖。"
fi

# ── 原样保存的证据：扫描要绕开 ──────────────────────────
# 原样存下的提示与原始输出，事后改一个字就对不上产物（rules/evidence-discipline.md「原样保存的证据不许事后改」），
# 由项目登记进 $ROOT/.claude/doc-lint-exclude 绕开扫描，一行一条 `<相对目录>  # 为什么`。
# 理由不许省：排除范围会被照抄，抄的人得看得见为什么。排除项一律报出来：静悄悄少扫一批文件，和没实现长得一样。
EXFILE="$ROOT/.claude/doc-lint-exclude"
exfails=0; expaths=(); exwhys=(); exns=(); exskipped=0
if [[ -f "$EXFILE" ]]; then
  exline=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    exline=$((exline+1))
    [[ -z "${line//[[:space:]]/}" || "${line#"${line%%[![:space:]]*}"}" == \#* ]] && continue
    if [[ "$line" != *\#* ]]; then
      bad ".claude/doc-lint-exclude:$exline  这一条没写理由：$line"
      howto "每条排除都要写清为什么，格式： research/prompts/  # 原样发给模型的提示，改了产物就对不上输入" \
            "排除范围会被后来人照抄，抄的人得看得见当初为什么排。"
      exfails=$((exfails+1)); continue
    fi
    expath="${line%%#*}"; exwhy="${line#*#}"
    expath="${expath#"${expath%%[![:space:]]*}"}"; expath="${expath%"${expath##*[![:space:]]}"}"
    exwhy="${exwhy#"${exwhy%%[![:space:]]*}"}";   exwhy="${exwhy%"${exwhy##*[![:space:]]}"}"
    expath="${expath%/}"
    if [[ -z "$exwhy" ]]; then
      bad ".claude/doc-lint-exclude:$exline  # 后面是空的，等于没写理由"
      howto "在 # 后面写清为什么这批文件不许事后改，例：原样发给模型的提示，改了产物就对不上输入。"
      exfails=$((exfails+1)); continue
    fi
    # 只收 ROOT 之下的子目录：收 `.` 或绝对路径的话，一行就能把整棵树排掉而门禁照绿。
    if [[ -z "$expath" || "$expath" == "." || "$expath" == /* || "$expath" == *..* ]]; then
      bad ".claude/doc-lint-exclude:$exline  路径不合法：「$expath」"
      howto "只收 ROOT 之下的相对子目录，例： research/prompts/" \
            "不收 . 、绝对路径、含 .. 的路径——那些一行就能把整棵树排掉。"
      exfails=$((exfails+1)); continue
    fi
    if [[ ! -d "$ROOT/$expath" ]]; then
      bad ".claude/doc-lint-exclude:$exline  目录不存在：$expath"
      howto "排除项烂掉了：要么路径拼错，要么那批文件已经挪走或删了。" \
            "改成现在的路径，或者把这一行删掉——留着的排除项会让人以为还有东西在被绕开。"
      exfails=$((exfails+1)); continue
    fi
    exn="$(find "$ROOT/$expath" -name '*.md' -not -path '*/.git/*' | wc -l)"
    if [[ "$exn" -eq 0 ]]; then
      bad ".claude/doc-lint-exclude:$exline  $expath 下一个 .md 都没有，这条排除没有作用"
      howto "删掉这一行。不起作用的排除项只会让人以为这批文件被绕开了，" \
            "而真正该排的那个目录还在被扫。"
      exfails=$((exfails+1)); continue
    fi
    EXCL+=(-not -path "$ROOT/$expath/*")
    expaths+=("$expath"); exwhys+=("$exwhy"); exns+=("$exn")
    exskipped=$((exskipped+1))
  done < "$EXFILE"
fi
if [[ ${#expaths[@]} -gt 0 ]]; then
  n=0; for i in "${!expaths[@]}"; do n=$((n+exns[i])); done
  warn "按 .claude/doc-lint-exclude 绕开 $n 个 .md —— 原样保存的证据，改了就断证据链："
  for i in "${!expaths[@]}"; do warn "  ${expaths[$i]}/  （${exns[$i]} 个）—— ${exwhys[$i]}"; done
fi

# ── C 的登记表：哪些 kb 文件带「## 历史版本」 ──────────────────────────
# $ROOT/.claude/history-carriers：一行一条 `<相对 ROOT 的目录或文件>  # 为什么`，判法同 doc-lint-exclude；C 的判据见文件头。
CARRIERS_FILE="$ROOT/.claude/history-carriers"
carrierfails=0; carriers=(); carriers_registered=0
if [[ -f "$CARRIERS_FILE" ]]; then
  carriers_registered=1
  cline=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    cline=$((cline+1))
    [[ -z "${line//[[:space:]]/}" || "${line#"${line%%[![:space:]]*}"}" == \#* ]] && continue
    if [[ "$line" != *\#* ]]; then
      bad ".claude/history-carriers:$cline  这一条没写理由：$line"
      howto "每条登记都要写清为什么这份文件带历史，格式： kb/decisions/  # 决策的历史住在这里"
      carrierfails=$((carrierfails+1)); continue
    fi
    cpath="${line%%#*}"; cwhy="${line#*#}"
    cpath="${cpath#"${cpath%%[![:space:]]*}"}"; cpath="${cpath%"${cpath##*[![:space:]]}"}"
    cwhy="${cwhy#"${cwhy%%[![:space:]]*}"}";   cwhy="${cwhy%"${cwhy##*[![:space:]]}"}"
    cpath="${cpath%/}"
    if [[ -z "$cwhy" ]]; then
      bad ".claude/history-carriers:$cline  # 后面是空的，等于没写理由"
      howto "在 # 后面写清为什么这份文件带历史。"
      carrierfails=$((carrierfails+1)); continue
    fi
    if [[ -z "$cpath" || "$cpath" == "." || "$cpath" == /* || "$cpath" == *..* ]]; then
      bad ".claude/history-carriers:$cline  路径不合法：「$cpath」"
      howto "只收 ROOT 之下的相对目录或文件，例： kb/decisions/ ；不收 . 、绝对路径、含 .. 的路径。"
      carrierfails=$((carrierfails+1)); continue
    fi
    if [[ ! -e "$ROOT/$cpath" ]]; then
      bad ".claude/history-carriers:$cline  路径不存在：$cpath"
      howto "登记项烂掉了：改成现在的路径，或者把这一行删掉。"
      carrierfails=$((carrierfails+1)); continue
    fi
    carriers+=("$cpath")
  done < "$CARRIERS_FILE"
fi
is_history_carrier() {
  local rel="$1" c
  for c in ${carriers[@]+"${carriers[@]}"}; do
    [[ "$rel" == "$c" || "$rel" == "$c"/* ]] && return 0
  done
  return 1
}

while IFS= read -r f; do
  rel="${f#"$ROOT"/}"
  # CHANGELOG 是规则指定的历史落点（rules/rules-discipline.md 第 3、5 条），整份就是历史，拿历史陈述去扫它是范畴错误。
  if [[ "$(basename "$f")" == "CHANGELOG.md" ]]; then
    [[ -n "${DOC_LINT_VERBOSE:-}" ]] && warn "跳过 $rel（历史文件）"
    skipped=$((skipped+1)); continue
  fi
  base="$(basename "$f")"
  # 认围栏：design-doc-discipline 的示例块里就有一行「## 历史版本」，围栏里的不算数
  has_hist="$(awk -v HIST="$HIST_HEAD" '/^[ \t]*```/{fence=!fence;next} fence{next}
                   $0 ~ ("^" HIST "[ \t]*$") {print 1; exit}' "$f")"
  [[ -n "$has_hist" ]] || has_hist=0

  # ⚠️ 历史节的有无要在免检牌之前判：免检牌只管模式匹配。规范文本全带着这张牌，连结构一起豁免的话，
  # 「规则文件不留历史节」（rules/rules-discipline.md 第 5 条）对它真正管的那批文件一次也红不了。
  structfail=0
    if [[ "$base" == "CLAUDE.md" && $has_hist -eq 1 ]]; then
    bad "$rel  CLAUDE.md 不许有「$HIST_HEAD」节"
    howto "把这一节整段删掉，不另立落点；共享规则的历史进 CHANGELOG.md，一版一节" \
          "（rules/rules-discipline.md 第 3、5 条）。"
    structfail=1
  fi
  if [[ ( "$f" == */rules/*.md || "$f" == */agents/*.md ) && $has_hist -eq 1 ]]; then
    bad "$rel  规则/agent 定义连文末「$HIST_HEAD」都不留"
    howto "把这一节整段删掉，不另立落点；共享规则的历史进 CHANGELOG.md，一版一节" \
          "（rules/rules-discipline.md 第 3、5 条）。"
    structfail=1
  fi

  # 标记要独占一行、在文件头 5 行内：否则正文里提到这个串就被当成带了牌。
  # 只许用在规则本体的位置：kb 贴这张牌，kb 里的「」就成了藏违规的口子。
  example_exempt=0
  if head -5 "$f" | grep -qx '<!-- doc-lint:rule-definition -->'; then
    # kb 分支要排在白名单前面：kb/rules/x.md 否则先匹配上 */rules/*.md 溜掉。
    if is_kb_path "$f"; then
      bad "$rel  rule-definition 标记不许出现在 kb 里"
      howto "删掉文件头的 <!-- doc-lint:rule-definition -->。kb 是给模型检索的内容，" \
            "必须受检；规则定义住在 rules/，不住在 kb（rules/writing-discipline.md）。"
      checked=$((checked+1)); fails=$((fails+1)); continue
    elif [[ "$f" == */CLAUDE.md || "$f" == */rules/*.md || "$f" == */agents/*.md || "$f" == */skills/*/SKILL.md ]]; then
      if [[ $structfail -eq 1 ]]; then
        checked=$((checked+1)); fails=$((fails+1)); continue
      fi
      [[ -n "${DOC_LINT_VERBOSE:-}" ]] && warn "规则定义文件，反引号与「」里的举例不比对词表  $rel"
      example_exempt=1
    else
      bad "$rel  rule-definition 标记只许用于 CLAUDE.md、rules/、agents/、skills/*/SKILL.md"
      howto "删掉文件头的 <!-- doc-lint:rule-definition -->——这份文件不是规则定义，" \
            "内容就该受检。要引用规则，链到 rules/ 对应文件。"
      checked=$((checked+1)); fails=$((fails+1)); continue
    fi
  fi
  # history-registry 只许在 kb 里：别处贴这张牌，等于把整份文件免检。
  registry_flag=0
  if head -5 "$f" | grep -qx '<!-- doc-lint:history-registry -->'; then
    if is_kb_path "$f"; then
      [[ -n "${DOC_LINT_VERBOSE:-}" ]] && warn "历史登记文件，从第一个「## 」标题起不比对指代/历史陈述词表  $rel"
      registry_flag=1
    else
      bad "$rel  history-registry 标记只许用于 kb 里的文件"
      howto "删掉文件头的 <!-- doc-lint:history-registry -->——这份文件不是历史登记表，" \
            "内容就该受检；要留档的历史，写进文末「$HIST_HEAD」。"
      checked=$((checked+1)); fails=$((fails+1)); continue
    fi
  fi
  checked=$((checked+1))
  body="$(body_of "$f" "$registry_flag")"
  # D-3 用不截断的正文：它判祖先标题里有没有日期，历史登记文件的节本身按日期分组，不需要那张牌的豁免。
  if [[ $registry_flag -eq 1 ]]; then
    body_for_time_reference="$(body_of "$f" 0)"
  else
    body_for_time_reference="$body"
  fi
  # 词表比对（A、I，以及 D）用 $scan：规则定义文件把反引号、「」里的举例挖掉，行号不变。
  scan="$body"
  if [[ $example_exempt -eq 1 ]]; then
    scan="$(printf '%s\n' "$body" | sed -E 's/`[^`]*`//g; s/「[^」]*」//g')"
  fi
  filefail=0

  # 落单的 ``` 让其后全文被当代码块跳过，全部检查一起失明，而且极易无意犯出。
  nfence="$(grep -cE '^[ \t]*```' "$f")" || true
  if (( nfence % 2 )); then
    bad "$rel  围栏代码块未闭合（\`\`\` 共 $nfence 处，奇数）"
    howto "找到落单的那行 \`\`\` 补上闭合。围栏没配对时，其后全文不受任何检查。"
    filefail=1
  fi

  # 历史节必须是文末最后一节：正文扫描在历史节停机，之后再开的节躲开全部检查；任何级别的标题都认。
  #   `#` / `##` 判红；`###` 必须以日期开头（历史条目，`### YYYY-MM-DD（其八）：…` 算）；`####` 起是条目内部的小标题，放行。
  # 要求整行只有日期会报出几百行假红，连 `####` 一起拦会拦下条目里的分节；`### 当前口径（现行）` 这种不以日期开头的照拦。
  afterhist="$(awk -v HIST="$HIST_HEAD" '/^[ \t]*```/{fence=!fence;next} fence{next}
                    $0 ~ ("^" HIST "[ \t]*$") {h=1;next}
                    h && /^#{1,3}[ \t]/ && $0 !~ /^###[ \t]+<?[0-9YyMmDd]{4}-[0-9MmDd]{2}-[0-9Dd]{2}>?/ {print FNR}' "$f")"
  if [[ -n "$afterhist" ]]; then
    bad "$rel  「$HIST_HEAD」之后又出现了标题小节（行 $(printf '%s' "$afterhist" | tr '\n' ' ' | sed 's/ $//')）"
    howto "历史版本只能是最后一节。新内容写回正文（历史节之前）；" \
          "第二个历史节与第一个合并。"
    filefail=1
  fi

  i=0
  [[ $WORDLIST -eq 1 ]] || i=${#PATTERNS[@]}      # 没有本语言的词表就不跑，末尾统一报未实现
  while [[ $i -lt ${#PATTERNS[@]} ]]; do
    pat="${PATTERNS[$i]}"; why="${PATTERNS[$((i+1))]}"
    if hits="$(printf '%s\n' "$scan" | grep -n "$pat" || true)"; [[ -n "$hits" ]]; then
      while IFS= read -r h; do
        ln="$(printf '%s' "$h" | sed 's/^[0-9]*://; s/\t.*//')"
        txt="$(printf '%s' "$h" | sed 's/^[0-9]*://; s/^[0-9]*\t//')"
        bad "$rel:$ln  $why"
        say "        > $(printf '%s' "$txt" | cut -c1-80)"
        howto "删掉正文里这句，改写成现行值；确实要留档的，挪到文末「## 历史版本」，" \
              "写成「曾经 X / 现在 Y / 改动依据 Z」，放在「$HIST_HEAD」之下。"
        filefail=1
      done <<< "$hits"
    fi
    i=$((i+2))
  done

  # 文风：所有给人读的 .md 都查，不只 kb。
  if [[ $WORDLIST -eq 1 ]]; then
    j=0
    while [[ $j -lt ${#STYLE[@]} ]]; do
      spat="${STYLE[$j]}"; swhy="${STYLE[$((j+1))]}"
      if shits="$(printf '%s\n' "$scan" | grep -n "$spat" || true)"; [[ -n "$shits" ]]; then
        while IFS= read -r h; do
          ln="$(printf '%s' "$h" | sed 's/^[0-9]*://; s/\t.*//')"
          txt="$(printf '%s' "$h" | sed 's/^[0-9]*://; s/^[0-9]*\t//')"
          bad "$rel:$ln  $swhy"
          say "        > $(printf '%s' "$txt" | cut -c1-80)"
          howto "换成平时说话会用的说法。判据是「这句你会对同事说出口吗」——" \
                "不会就改（rules/writing-discipline.md「文风要简单自然」）。"
          filefail=1
        done <<< "$shits"
      fi
      j=$((j+2))
    done
  fi

  # D：kb 与规范文本会被检索单条端出来，指着「上文」「此处」的话端出来就断
  # （rules/kb-discipline.md 第 1 条、rules/rules-discipline.md 第 7 条）。
  #   D-1 位置指代；D-2 自指称呼，尾字有排除（kb 里真有「该节点」），「本工程」「本仓」「本轮」「本机」指项目，不算。
  # 规则定义文件扫的是 $scan，列举指代词的那几张表不判。
  if ( is_kb_markdown "$f" || [[ "$f" == */rules/*.md || "$base" == "CLAUDE.md" || "$f" == */agents/*.md || "$f" == */skills/*/SKILL.md ]] ) && [[ $REFERENCE_WORDLIST -eq 1 ]]; then
    if is_kb_markdown "$f"; then dockind="kb 正文"; else dockind="规范正文"; fi
    # 「上一条」「下一条」不认：已登记的简称就有「上一条时间线的残留」，还有「记下一条自评」「装得下一条记录」这类动宾。
    # 「同上」只认独立成词：写成左右排除的话排除表补不完（协同、合同、相同上下文、共同上报、同上游清单）。
    ctx='如上所述|如前所述|同上[，。；：、）」]|同上$|见上文|见上面|前面提到|上一节([^点拍]|$)|前述|下面会说|后面会说'
    ctx="$ctx"'|见[上下](表|文|节|条|图|面|$|[，。；：、）」])|[如照][上下](表|图)|上面[那这]|下面[那这]'
    # 不带「见 / 如 / 照」的光秃形态，每一格的收窄都在使用者项目的 kb 上量过：
    #   「上面 / 下面」有物理意义（「它上面的四个点」「多层树下面的单元」「标题下面一行」），左边只认句首、标点、粗体星号、
    #   表格竖线或「以 把 按 取 在 是 了 成 进 含 从 为」，右边只认「的 / 是 / 数量词 / 第 / 保留 / 圈码或数字」；
    #   「下一节」撞「下一节点」、「下一段」「下一行」在文件系统与程序里另有所指，这三样只在「见」后面算，「上一行」另认
    #   「同上一行」「晚于 / 早于上一行」；「如下」后面要紧跟标点；「上文」「下文」排掉「上下文」「上文件」。
    # 不查「前面 / 后面」「以上 / 以下」（多是代码前后与数值阈值）、「上方 / 下方」（多指带名字的位置）。
    dlead='(^|[，。；：、！？（）()「」『』【】〔〕〈〉《》“”"*|[:space:]])'
    ctx="$ctx"'|[上下]述|[上下]表([^格头面达]|$)|上文([^件]|$)|(^|[^上])下文([^件]|$)'
    ctx="$ctx"'|见[上下]一(段|行|节)|同上一行|[早晚]于[上下]一行|如下[：:，。；—]'
    # 「见上方 / 见下方」带了「见」只能是文档位置，光秃的「上方 / 下方」仍不判；「下一节」与「上一节」对称排掉「下一节点」「下一节拍」。
    ctx="$ctx"'|见[上下]方|下一节([^点拍]|$)'
    ctx="$ctx|${dlead}以[上下](是|几[条点项段]|各[条点项段])"
    ctx="$ctx|(${dlead}|[以把按取在是了成进含从为])(上面|下面)(的|是|[一二三四五六七八九十几两各每]|第|保留| ?[0-9①②③④⑤⑥⑦⑧⑨⑩⑪⑫⑬⑭⑮⑯⑰⑱⑲⑳])"
    ctx="$ctx"'|(列|照录|附|放)在(上面|下面)'
    # 日文：只认指文档位置的专用词。「この節」「この表」「この文書」不认：它们常指正在讲的那一类东西（「この文書が誰のためか」），
    # 不是自指；「上表」「下表」排掉「上表面」这类构词。
    if [[ "$DOC_LANG" == ja ]]; then
      ctx='上記|下記|前述|後述|上述|前節|次節|前項|次項|同上|[上下]表([^面]|$)|[上下]の表|(以下|次)の(とおり|通り)'
    fi
    # 判据先单独编一次：下面那条 grep 带 `|| true`，编不过（退 2）与没命中长得一样，整条检查静默判绿（grep 不认非 ASCII 字符的区间）。
    ctxrc=0; printf '\n' | grep -E "$ctx" > /dev/null || ctxrc=$?
    [[ $ctxrc -le 1 ]] || die "位置指代的判据 grep 编不过（退出码 $ctxrc），这一条对哪份 kb 都没判过" \
      "是 doc-lint 的判据写坏了，不是文档的错：把 ctx 单独喂给 grep -E 看报错（非 ASCII 字符的区间 grep 不认），改好再跑。"
    if refs="$(printf '%s\n' "$scan" | grep -nE "$ctx" || true)"; [[ -n "$refs" ]]; then
      while IFS= read -r r; do
        rln="$(printf '%s' "$r" | sed 's/^[0-9]*://; s/\t.*//')"
        rtx="$(printf '%s' "$r" | sed 's/^[0-9]*://; s/^[0-9]*\t//')"
        bad "$rel:$rln  $dockind不许用位置指代"
        say "        > $(printf '%s' "$rtx" | cut -c1-80)"
        howto "把被指代的内容直接写出来：小节写成它的标题，表写成它判的那件事，" \
              "别处的事实链到它所在的文件。" \
              "检索会把这一条单独端出来，指代当场断掉——而模型不会说看不懂，它会补一个。"
        filefail=1
      done <<< "$refs"
    fi
    # D-2 左右都只认白名单：「脚本文件」「副本文件」「成本表」「应该文件化」里的「本」「该」是构词，按撞到的假红逐个补的黑名单补不完
    # （`脚副样文版译抄剧根基成日资蓝范母拓孤标课` 是那份黑名单的存档）；文件系统项目里「该文件」「本文件系统」「该表」几乎全指盘上的东西。
    # 所以「文件」整个拿掉（真自指用「本文档」）。
    tails='(决策|不变量|章节|文档|实验([^室]|$)|条([^件目]|$)|节([^点]|$)|表([^格]|$))'
    # 左侧只在句首或标点之后才算自指。
    lead='(^|[，。；：、！？（）()「」『』【】〔〕〈〉《》“”"[:space:]])'
    # 「表」只跟「本」不跟「该」：「槽位表有 4096 项，该表常驻内存」里的「该表」指内存里的表。
    gtails='(决策|不变量|章节|文档|实验([^室]|$)|条([^件目]|$)|节([^点]|$))'
    # 规范文本只判指文档结构的词：规则里「这个实验」「这条决策」指工作对象，不是文档位置；kb 里「本决策」指被检索出来的那一条，才是自指。
    if [[ "$dockind" == "kb 正文" ]]; then
      self="$lead本$tails|$lead该$gtails|$lead这(条|个)(决策|实验|不变量)"
    else
      self="$lead本(章节|文档|条([^件目]|$)|节([^点]|$)|表([^格]|$))"
    fi
    # 指被测系统而不是文档位置的，一律排除
    selfskip='本(工程|仓|轮|机|文件系统|系统|盘|实现|包|次)'
    # 日文：左边在中文那套之外再认助词（「は本節で」），右边排掉「本条件」「本節点」「本表面」这类构词；
    # kb 里另认「本決定」「本実験」。「本プロジェクト」「本リポジトリ」指的是项目，不是文档位置。
    if [[ "$DOC_LANG" == ja ]]; then
      jlead='(^|[、。，．：；！？（）()「」『』【】〔〕〈〉《》“”"*|[:space:]]|[はがをにでとのもへや])'
      self="${jlead}本(節([^点]|$)|項([^目]|$)|表([^面]|$)|章|文書|条([^件目]|$))"
      if [[ "$dockind" == "kb 正文" ]]; then self="$self|${jlead}本(決定|実験|不変条件)"; fi
      selfskip='本(プロジェクト|リポジトリ|機|ファイルシステム|システム|パッケージ)'
    fi
    # 同位置指代那一处：判据编不过时 `|| true` 会把它吞成「没命中」。
    selfrc=0; printf '\n' | grep -E -e "$self" -e "$selfskip" > /dev/null || selfrc=$?
    [[ $selfrc -le 1 ]] || die "自指称呼的判据 grep 编不过（退出码 $selfrc），这一条对哪份 kb 都没判过" \
      "是 doc-lint 的判据写坏了，不是文档的错：把 self 与 selfskip 单独喂给 grep -E 看报错，改好再跑。"
    if selfs="$(printf '%s\n' "$scan" | grep -nE "$self" | grep -vE "$selfskip" || true)"; [[ -n "$selfs" ]]; then
      while IFS= read -r r; do
        rln="$(printf '%s' "$r" | sed 's/^[0-9]*://; s/\t.*//')"
        rtx="$(printf '%s' "$r" | sed 's/^[0-9]*://; s/^[0-9]*\t//')"
        bad "$rel:$rln  $dockind不许用自指称呼"
        say "        > $(printf '%s' "$rtx" | cut -c1-80)"
        howto "把当前位置写成名字：条目写成「D22（单元原子性怎么合成）」，" \
              "章节写成它的标题，文档写成它的文件名。" \
              "检索端出来的那一条没有「此处」——它已经被从文件里摘下来了。"
        filefail=1
      done <<< "$selfs"
    fi

    # D-3 时间指代：「本轮」被单条端出来时锚不到哪一轮，模型不会说看不懂，它会补一个。
    # 该行或它的任何一层祖先标题带日期就放行。按层记标题：`### 日期` 下另开 `#### 摘要` 的写法，只看最近一个标题会全部误判。
    # 不判「下一轮」（本来泛指）、「本次 / 上次 / 这次」（多挂在技术对象上，自足）；历史节在 body_of 的停机点之后，本来不扫。
    if [[ "$dockind" == "kb 正文" && $WORDLIST -eq 1 ]]; then
      if rounds="$(printf '%s\n' "$body_for_time_reference" | awk '
            { tab = index($0, "\t"); ln = substr($0, 1, tab - 1); line = substr($0, tab + 1) }
            line ~ /^#/ {
              match(line, /^#+/); level = RLENGTH
              head[level] = line
              for (l = level + 1; l <= 6; l++) delete head[l]
            }
            # 左边界排掉构词：「样本轮判决」里的「本轮」不是时间指代
            line ~ /(^|[^样])本轮|这一轮|上一轮|前一轮|(^|[^以])上轮/ {
              if (line ~ /[0-9][0-9]-[0-9][0-9]/) next
              anchored = 0
              for (l = 1; l <= 6; l++) if (head[l] ~ /[0-9][0-9]-[0-9][0-9]/) anchored = 1
              if (anchored) next
              print ln "\t" line
            }')"; [[ -n "$rounds" ]]; then
        while IFS= read -r r; do
          rln="${r%%$'\t'*}"; rtx="${r#*$'\t'}"
          bad "$rel:$rln  kb 正文里的「本轮」锚不到具体哪一轮"
          say "        > $(printf '%s' "$rtx" | cut -c1-80)"
          howto "把指代换成锚：写明是哪一天的那一轮，或者点名那次实验的编号。" \
                "确实泛指任何一轮的规则句，改写成不带指代的说法（「跑它的那一轮」→「产出这份输出的那次运行」）。" \
                "判据是检索：这一条被单独端出来时，读的人能不能知道是哪一轮。"
          filefail=1
        done <<< "$rounds"
      fi
    fi
  fi

  [[ $structfail -eq 1 ]] && filefail=1
  # GLOSSARY 各语言仓共用一份，说明列必须三语并列（zh<br>en<br>ja）：少一段不报错，只让用那种语言的人拿到读不懂的说明。
  if [[ "$base" == "GLOSSARY.md" ]]; then
    while IFS=$'\037' read -r gln gterm gseg; do
      [[ -z "$gln" ]] && continue
      bad "$rel:$gln  术语「$gterm」的说明不是三语（分出 $gseg 段，应为 3）"
      howto "说明列写成「中文<br>English<br>日本語」，三段都要有，用 <br> 分隔。" \
            "这一份各语言仓共用、不翻译，所以说明必须自带三语——" \
            "少一段就是让用那种语言的人拿到一份他读不懂的说明。"
      filefail=1
    done < <(awk -F'|' '
      /^[ \t]*```/ { fence = !fence; next }
      fence { next }
      /^\|/ && NF > 4 {
        term = $2; gsub(/^[ \t]+|[ \t]+$/, "", term)
        if (term ~ /^-+$/ || term == "中文" || term == "") next
        note = $5; gsub(/^[ \t]+|[ \t]+$/, "", note)
        n = split(note, seg, /<br>/)
        ok = (n == 3)
        # 每段要有实质内容：写成 `-` / `—` / `TODO` / `n/a` 等于没写（`中文<br>-<br>-` 不算三语）
        if (ok) for (i = 1; i <= 3; i++) {
          t = seg[i]; gsub(/^[ \t]+|[ \t]+$/, "", t)
          if (t == "" || t ~ /^[-—–~.*_[:space:]]+$/ || tolower(t) ~ /^(todo|tbd|n\/a|na|\?+)$/) ok = 0 }
        if (!ok) printf "%d\037%s\037%d\n", FNR, term, n
      }' "$f")
  fi

  # agent 定义：frontmatter 不从第 1 行起整个定义不被识别，name 与文件名对不上派不到；两样都不报错，只会安静地不生效。
  if [[ "$f" == */agents/*.md && "$base" != "INDEX.md" ]]; then
    aname="$(awk 'NR==1 && $0!="---" {exit} NR==1{next} /^---[[:space:]]*$/{exit} /^name:/{sub(/^name:[[:space:]]*/,""); print; exit}' "$f")"
    adesc="$(awk 'NR==1 && $0!="---" {exit} NR==1{next} /^---[[:space:]]*$/{exit} /^description:/{sub(/^description:[[:space:]]*/,""); print; exit}' "$f")"
    want_name="${base%.md}"
    if [[ -z "$aname" || -z "$adesc" ]]; then
      bad "$rel  agent 定义缺 frontmatter 的 name 或 description"
      howto "文件第 1 行起写 YAML frontmatter（前后各一行 ---），含 name 与 description。" \
            "description 是主模型唯一的选取依据，写清什么时候该委派它——" \
            "写成「审查代码」没人知道何时该派（agents/INDEX.md）。"
      filefail=1
    elif [[ "$aname" != "$want_name" ]]; then
      bad "$rel  agent 的 name「$aname」与文件名「$want_name」对不上"
      howto "两者必须一致，否则按文件名去派它会派不到，而且不会报错。" \
            "改 frontmatter 里的 name，或把文件改名成 $aname.md。"
      filefail=1
    fi
  fi

  if is_kb_markdown "$f" && [[ "$base" != "INDEX.md" ]]; then
    if [[ $carriers_registered -eq 1 ]]; then
      if is_history_carrier "$rel"; then
        if [[ $has_hist -eq 0 ]]; then
          bad "$rel  登记在 .claude/history-carriers 里的 kb 文件必须有「$HIST_HEAD」节收尾"
          howto "在文末补上（没有历史也要留这个节，供以后写）：" \
                "$HIST_HEAD" "" "### $(date +%F)" "- 建档。"
          filefail=1
        fi
      elif [[ $has_hist -eq 1 ]]; then
        bad "$rel  没登记在 .claude/history-carriers 里的 kb 文件不留「$HIST_HEAD」节"
        howto "把这一节整段删掉：改动直接改正文，经过靠 git（要查就 git log 这份文件）；" \
              "这份文件确实要带历史，登记进 .claude/history-carriers 并写明为什么。"
        filefail=1
      fi
    elif [[ $has_hist -eq 0 ]]; then
      bad "$rel  kb 文档必须有「$HIST_HEAD」节收尾"
      howto "在文末补上（没有历史也要留这个节，供以后写）：" \
            "$HIST_HEAD" "" "### $(date +%F)" "- 建档。"
      filefail=1
    fi
  fi

  # ── M. 日期不许是编的 ───────────────────────────────────
  # 编出来的日期只在落进不可能的区间时看得出：早于本仓第一个提交出宽限（lib.sh 的 DATE_GRACE_DAYS），或晚于最晚时区的今天。
  # 三种语言的「实测（日期）」写法都认（实测（、Measured (、実測（）。
  while IFS=: read -r date_line_no date_rest; do
    [[ -n "$date_line_no" ]] || continue
    date_value="$(printf '%s' "$date_rest" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' || true)"
    date_value="${date_value%%$'\n'*}"
    [[ -n "$date_value" ]] || continue
    if date_why="$(date_out_of_range "$date_value" "$PROJECT_START_DATE")"; then
      bad "$rel:$date_line_no  日期 $date_value 不可能：$date_why"
      howto "写真实发生的那一天：历史条目写这一条是哪天记下的，实测写它是哪天跑的。" \
            "不知道是哪天就去查（git log 那个文件、或者当时的产物），别填一个占位日期——" \
            "占位日期读起来和真日期一模一样，而后面每一个引用它的人都会当真。"
      filefail=1
    fi
  done < <(grep -nE '(^###[[:space:]]+|实测（|実測（|Measured \()[0-9]{4}-[0-9]{2}-[0-9]{2}' "$f" || true)

  if [[ $filefail -eq 0 ]]; then
    [[ -n "${DOC_LINT_VERBOSE:-}" ]] && ok "$rel"
  else
    fails=$((fails+1))
  fi
done < <(find "$ROOT" -name '*.md' -not -path '*/.git/*' -not -path '*/target/*' \
                 "${EXCL[@]}" | sort)

# E. 引用了不存在的不变量编号（rules/kb-discipline.md 第 3 条「显式记录「不知道」」）：检索只端出那条引用，模型照单全收。
reffails=0
kb_files="$(kb_markdown_files)"
if [[ -n "$kb_files" ]]; then
  # 定义 = 表格行首的编号，别处都是引用。围栏与「历史版本」节里的不算：历史节的表是删除记录，不能给引用背书。
  defined="$(printf '%s\n' "$kb_files" | while IFS= read -r f; do
      awk '/^## 历史版本[[:space:]]*$/ { exit }
           /^[ \t]*```/ { infence = !infence; next } !infence' "$f"
    done | grep -oE '^\| *I-[0-9]+(\.[0-9]+)+ *\|' | grep -oE 'I-[0-9]+(\.[0-9]+)+' | sort -u || true)"

  while IFS= read -r f; do
    rel="${f#"$ROOT"/}"
    refs="$(awk '/^[ \t]*```/ { infence = !infence; next } !infence { print FNR "\t" $0 }' "$f" \
            | grep -vE '\t\| *I-[0-9]+(\.[0-9]+)+ *\|' || true)"
    [[ -z "$refs" ]] && continue
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      ln="${line%%$'\t'*}"
      for id in $(printf '%s' "$line" | grep -oE 'I-[0-9]+(\.[0-9]+)+' | sort -u); do
        # 不用 `| grep -q`：$defined 超过管道缓冲（64 KiB）时 grep 找到就退出，printf 吃 SIGPIPE，pipefail 下整条退 141，检查静默不判。
        if [[ "$(printf '%s\n' "$defined" | grep -cx "$id" || true)" == 0 ]]; then
          bad "$rel:$ln  引用了没有定义的不变量编号 $id"
          howto "要么在 kb/invariants.md 里把 $id 真的写成一行（可判定的陈述 + 检查状态），" \
                "要么删掉这处引用。引用一个不存在的编号，检索出来看不出它不存在——" \
                "而模型不会说找不到，它会补一个（rules/kb-discipline.md 第 3 条）。"
          reffails=$((reffails+1))
        fi
      done
    done <<< "$refs"
  done <<< "$kb_files"
fi

# F/G/H. 编号只能做索引，不能做称呼（rules/kb-discipline.md 第 5 条）。登记位只认两种：
#   1. 登记表：表格上方单独一行 <!-- doc-lint:registry name-col=N -->，每行首列的编号是登记位，简称取第 N 列（N 默认 2，必须 ≥2）
#   2. 登记标题：`## D1 数据可移动性 —— 已定`，简称取编号之后、破折号之前那一段
#   不从「表格首列是编号」去猜：首列也被当行标签用（`| D2 | 节点内 parity 与 D2 的… |`），猜的话全是假红。
#   其余每一次出现都是引用，写成 `D1（数据可移动性）`。F 查登记位，G 查引用，H 查反复出现却没登记。
NAME_MAX=48     # 简称的显示宽度上限（汉字算 2、ASCII 算 1，即 24 个汉字）。
                # 带不动的名字等于没名字；按显示宽度算，24 个汉字与 24 个 ASCII 字符的信息量差三倍。
ID_MIN=3        # H：出现几次才算「在当称呼用」。一两次算顺带提及。
numfails=0
if [[ -n "$kb_files" ]]; then
  mapfile -t kb_arr <<< "$kb_files"
  rawf="$tmpd/defs.raw"; defsf="$tmpd/defs.tsv"
  : > "$rawf"
  while IFS= read -r f; do
    awk -v FN="${f#"$ROOT"/}" '
      BEGIN { ID = "[A-Z]+-?[0-9]+([.][0-9]+)*" }
      /^[ \t]*```/ { fence = !fence; next }
      fence  { next }
      /<!-- *doc-lint:registry/ {
        reg = 1; intable = 0; ncol = 2; marker = FNR
        if (match($0, /name-col=[0-9]+/)) ncol = substr($0, RSTART + 9, RLENGTH - 9) + 0
        if (ncol < 2) printf "ERR\037%s\037%d\037name-col=%d 会把简称取成编号自己\n", FN, FNR, ncol
        next }
      reg && /^[ \t]*$/ { next }              # 标记与表头之间允许空行
      reg && !/^\|/ {
        # 标记没管住任何一张表：再往下就会捕获后面某张不相干的表，并按 name-col 错取简称。
        if (!intable) printf "ERR\037%s\037%d\037登记标记后面第一处非空内容不是表格\n", FN, marker
        reg = 0; intable = 0 }
      reg && /^\|/ {
        intable = 1
        n = split($0, c, "|")
        id = c[2]; gsub(/^[ \t]+|[ \t]+$/, "", id)
        if (id ~ "^" ID "$") {
          if (n <= ncol) {
            printf "ERR\037%s\037%d\037这一行取不到第 %d 列（简称列），登记不上\n", FN, FNR, ncol
          } else {
            nm = c[ncol + 1]; gsub(/^[ \t]+|[ \t]+$/, "", nm)
            printf "DEF\037%s\037%s\037%s\037%d\n", id, nm, FN, FNR }
        }
        next }
      # 登记标题要带破折号：否则「### D1 与 parity 的关系」这种讨论标题成了第二处登记位，还把简称顶掉，让正确的引用一起红。
      match($0, "^#+[ ]*" ID "[ \t].*(——|—)") {
        h = $0; sub(/^#+[ ]*/, "", h)
        match(h, "^" ID); id = substr(h, 1, RLENGTH)
        nm = substr(h, RLENGTH + 1)
        gsub(/^[ \t]+|[ \t]+$/, "", nm); sub(/ *(——|—).*$/, "", nm)
        printf "DEF\037%s\037%s\037%s\037%d\n", id, nm, FN, FNR }
      END { if (reg && !intable) printf "ERR\037%s\037%d\037登记标记后面没有表格\n", FN, marker }
    ' "$f" >> "$rawf"
  done <<< "$kb_files"
  grep '^DEF' "$rawf" | cut -d$'\037' -f2- > "$defsf" || true

  # F. 登记表本身写坏了：不在这里报的话，最后由 H 报成「没有任何登记位」，指错方向
  while IFS=$'\037' read -r _tag df dl why; do
    [[ -z "$df" ]] && continue
    bad "$df:$dl  登记表写坏了：$why"
    howto "登记标记要紧挨着它管的那张表（中间只许空行），表里每一行都要能取到简称列，" \
          "且 name-col 必须 ≥2——取第 1 列等于把编号自己当简称，F 与 G 当场失效。"
    numfails=$((numfails+1))
  done < <(grep '^ERR' "$rawf" || true)

  # F. 一个编号只许有一处登记位
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    bad "编号 $id 有多处登记位——一个编号只许有一处登记"
    awk -F'\037' -v i="$id" '$1==i {printf "        %s:%s  简称「%s」\n", $3, $4, $2}' "$defsf"
    howto "留一处当登记位，别处改成引用：写成「$id（简称）」并链过去。" \
          "两处登记会各自漂移，而检索只端出一条、并且不告诉你它挑了哪条。"
    numfails=$((numfails+1))
  done < <(cut -d$'\037' -f1 "$defsf" | sort | uniq -d)

  # F. 两个编号共用一个简称 —— 带上名字也分不开，等于没带
  while IFS= read -r nm; do
    [[ -z "$nm" ]] && continue
    ids="$(awk -F'\037' -v n="$nm" '$2==n {printf "%s ", $1}' "$defsf")"
    bad "简称「$nm」被多个编号共用：$ids"
    howto "各起各的名。共用简称时「带上名字」这条就白做了——两处引用长得一模一样。"
    numfails=$((numfails+1))
  done < <(cut -d$'\037' -f2 "$defsf" | sort | uniq -d)

  # F. 简称要能被带着走：不许为空，不许长到没人愿意在引用处写
  while IFS=$'\037' read -r id nm df dl; do
    [[ -z "$id" ]] && continue
    nb="$(printf '%s' "$nm" | wc -c)"
    na="$(printf '%s' "$nm" | tr -d '\200-\377' | wc -c)"
    nlen=$(( na + (nb - na) / 3 * 2 ))      # 按字节算显示宽度，不随 locale 与 awk 实现变
    if [[ -z "$nm" ]]; then
      bad "$df:$dl  编号 $id 的登记位没有简称"
      howto "在登记表的简称列（或标题里编号之后）写一个短名，例：「## $id 反向索引 —— 已定」。" \
            "没有简称的编号在引用处只剩一个符号，含义可以被悄悄改掉。"
      numfails=$((numfails+1))
    elif [[ "$nm" == "$id" ]]; then
      bad "$df:$dl  编号 $id 的简称就是它自己"
      howto "简称要说清这个编号是什么，写成编号自己等于没写（多半是 name-col 指错了列）。"
      numfails=$((numfails+1))
    elif [[ "$nlen" -gt "$NAME_MAX" ]]; then
      bad "$df:$dl  编号 $id 的简称显示宽度 $nlen，超过 $NAME_MAX（汉字算 2、ASCII 算 1）"
      howto "起一个更短的简称——引用处每次都要带着它，带不动的名字等于没名字。" \
            "完整陈述留在登记位的其它列里，别塞进简称列。"
      numfails=$((numfails+1))
    fi
  done < "$defsf"

  # H. 编号形状的记号反复出现却一处登记都没有，是拿编号当称呼：少了这一条，一处登记都没有的 kb 全绿（F、G 无事可做）。
  #    领域术语（RAID5、SHA256、Z3）形状上与编号分不开，靠 not-numbers 显式声明摘出去。
  exemptf="$tmpd/exempt.txt"
  cut -d$'\037' -f1 "$defsf" | sort -u > "$exemptf"
  declaredf="$tmpd/declared.txt"
  # 读豁免声明也要认围栏：不认的话，在 ```markdown 块里「举例」写一行声明就把豁免真的打开了。
  awk '/^[ \t]*```/ { fence = !fence; next } fence { next }
       /<!-- *doc-lint:not-numbers/ { print }' "${kb_arr[@]}" 2>/dev/null \
    | grep -oE '<!-- *doc-lint:not-numbers[^>]*-->' \
    | sed -E 's/<!-- *doc-lint:not-numbers//; s/-->//' | tr -s ' \t' '\n' \
    | grep -v '^$' | sort -u > "$declaredf" || true
  # 已有登记位的编号再声明 not-numbers，等于一行注释把检查对它关掉，判红；没登记过的照放行（形状上分不开 Z3 与 O2）。
  while IFS= read -r tok; do
    [[ -z "$tok" ]] && continue
    if grep -qx "$tok" "$exemptf"; then
      bad "编号 $tok 已有登记位，却被 not-numbers 声明成术语"
      howto "删掉 not-numbers 声明里的 $tok——它是编号不是术语，引用处写成「$tok（简称）」。" \
            "豁免只留给 RAID5、SHA256 这类与编号形状撞车的领域术语。"
      numfails=$((numfails+1))
    fi
  done < "$declaredf"
  cat "$declaredf" >> "$exemptf"
  while IFS=$'\037' read -r tok cnt; do
    [[ -z "$tok" ]] && continue
    bad "编号 $tok 出现 $cnt 次，却没有任何登记位"
    howto "在登记表（表上方加 <!-- doc-lint:registry name-col=2 -->）或标题里登记它并给个简称，" \
          "然后每处引用写成「$tok（简称）」。它若根本不是编号而是领域术语，" \
          "在任一 kb 文件里声明摘出去：<!-- doc-lint:not-numbers $tok -->"
    numfails=$((numfails+1))
  done < <(awk -v MIN="$ID_MIN" -v EXEMPT="$exemptf" '
      BEGIN { ID = "[A-Z]+-?[0-9]+([.][0-9]+)*"
              while ((getline l < EXEMPT) > 0) exempt[l] = 1
              close(EXEMPT) }
      /^[ \t]*```/ { fence = !fence; next }
      fence  { next }
      {
        line = $0
        while (match(line, ID)) {
          tok = substr(line, RSTART, RLENGTH)
          before = (RSTART > 1) ? substr(line, RSTART - 1, 1) : ""
          line = substr(line, RSTART + RLENGTH)
          if (before ~ /[A-Za-z0-9._-]/) continue
          if (line ~ /^[A-Za-z]/) continue          # SHA256sum 这种，不是编号
          if (!(tok in exempt)) n[tok]++
        }
      }
      END { for (t in n) if (n[t] >= MIN) printf "%s\037%d\n", t, n[t] }
    ' "${kb_arr[@]}" | sort)

  # G. 引用处必须带简称，且与登记位一致
  while IFS= read -r f; do
    rel="${f#"$ROOT"/}"
    hits="$(awk -F'\037' -v FN="$rel" -v DEFS="$defsf" '
      function norm(s) {                       # 去掉强调标记，把连续空白压成一个
        gsub(/[*`]/, "", s); gsub(/[ \t]+/, " ", s)
        gsub(/^ | $/, "", s); return s }
      function matchclose(s,   i, d, ch) {     # 与开头那个括号配对的闭括号位置
        d = 0
        for (i = 1; i <= length(s); i++) {
          ch = substr(s, i, 1)
          if (ch == "（" || ch == "(") d++
          else if (ch == "）" || ch == ")") { d--; if (d == 0) return i }
        }
        return 0 }
      BEGIN { ID = "[A-Z]+-?[0-9]+([.][0-9]+)*"
              while ((getline l < DEFS) > 0) {
                split(l, d, "\037")
                name[d[1]] = norm(d[2]); raw[d[1]] = d[2]
                if (d[3] == FN) defid[d[4]] = d[1] }
              close(DEFS) }
      { L[FNR] = $0 }
      END {
        for (n = 1; n <= FNR; n++) {
          line = L[n]
          if (line ~ /^[ \t]*```/) { fence = !fence; continue }
          if (fence) continue
          # 引用可以被硬折行拆开（`O2（独立解析器\n+ checker）`，或编号在行尾、
          # 括注在下一行）。判定用接上后两行的那一段，报的行号还是编号所在这行。
          seg = line " " L[n + 1] " " L[n + 2]
          skipped = 0
          pos = 1
          while (match(substr(seg, pos), ID)) {
            st = pos + RSTART - 1
            tok = substr(seg, st, RLENGTH)
            if (st > length(line)) break                 # 已经扫进下一行，交给下一轮
            before = (st > 1) ? substr(seg, st - 1, 1) : ""
            after  = substr(seg, st + length(tok), 1)
            nxt    = substr(seg, st + length(tok) + 1, 1)
            pos = st + length(tok)
            # `-` `.` `_` 留在排除集里：拿掉能堵住「写成 `-D1` 藏掉裸引用」，但在真实项目的 kb 上误拒正常引用，
            # 误拒比漏检更会把人推去绕过门禁。这条绕法记在 kb-discipline.md 第 5 条的「已知但没拦」里。
            if (before ~ /[A-Za-z0-9._-]/) continue
            if (after ~ /[A-Za-z]/) continue
            if (after ~ /[0-9]/) continue
            if (after == "_") continue              # 标识符的一段（编号后面紧跟 _ 的环境变量名、变量名），不是引用
            if (after == "." && nxt ~ /[0-9]/) continue  # I-6 出现在 I-6.1 里面
            if (!(tok in name)) continue
            if (n in defid) {
              # 登记行/登记标题：放过它登记的那个编号与简称里含的编号（简称再要求带名字是无限递归）；
              # 同一行对别的编号的引用照查，那正是出过事的位置（登记表的「判什么」列）。
              if (defid[n] == tok && !skipped) { skipped = 1; continue }
              if (index(raw[defid[n]], tok) > 0) continue
            }
            rest = substr(seg, st + length(tok))
            pre = 0
            if (match(rest, /^[*`]+/)) { pre += RLENGTH; rest = substr(rest, RLENGTH + 1) }
            if (match(rest, /^ +[（(]/)) {               # 英文写法 `O2 (name)`
              sub(/^ +/, "", rest); pre += RLENGTH - 1 }
            if (rest ~ /^[（(]/) {
              cl = matchclose(rest)                      # 配对计数：简称本身可以含括号
              if (cl == 0) {
                printf "%d\t括注没闭合\t%s\t%s\n", n, tok, substr(line, 1, 60)
              } else {
                inner = substr(rest, 2, cl - 2)
                if (norm(inner) != name[tok])
                  printf "%d\t名字不符\t%s\t写的是「%s」，登记处是「%s」\n", n, tok, inner, raw[tok]
                # 跳过简称内部：简称里含别的编号时，不跳就成了新的裸引用，补上名字又引出下一个，无限递归。
                pos = st + length(tok) + pre + cl
              }
            } else {
              printf "%d\t裸引用\t%s\t%s\n", n, tok, substr(line, 1, 60)
            }
          }
        }
      }
    ' "$f")"
    [[ -z "$hits" ]] && continue
    n="$(printf '%s\n' "$hits" | wc -l)"
    bad "$rel  $n 处编号引用没带简称或简称不符"
    # 只列前 3 条，但要读完全部输入：用 head 截的话前段 printf 吃 SIGPIPE，pipefail 与 set -e 下整个脚本退 141
    printf '%s\n' "$hits" | awk -F'\t' 'NR <= 3 {printf "        :%s  %s %s —— %s\n", $1, $3, $2, $4}'
    howto "每处引用都写成「编号（简称）」，简称照登记位抄，例：「D1（数据可移动性）」。" \
          "编号在引用处只剩一个符号，含义能被悄悄改掉而没有一个字看起来别扭——" \
          "规矩见 rules/kb-discipline.md「编号只能做索引，不能做称呼」。全量清单：DOC_LINT_VERBOSE=1"
    [[ -n "${DOC_LINT_VERBOSE:-}" ]] && printf '%s\n' "$hits" | awk -F'\t' '{printf "        :%s  %s %s —— %s\n", $1, $3, $2, $4}'
    numfails=$((numfails+1))
  done <<< "$kb_files"
fi

# ── K. 规则清单：rules/ 与 @ 引用必须逐项相等 ─────────────
# 没被 @ 引用的规则不进上下文，看起来却和生效的一样；引用不存在的文件只是不展开，也不报错。同一个判据管三处：
#   SOP 仓的 CLAUDE.md ↔ rules/
#   SOP 仓的 templates/CLAUDE.project.md ↔ rules/：install.sh 拿它铺新项目的 CLAUDE.md，模板漏一条，新项目从第一天起就少读一条
#   项目的 CLAUDE.md ↔ 装进来的副本 .claude/<族名>/rules/
# 项目本地的 .claude/rules/ 由项目自己的门禁阶段管。
# 有意不 @ 常驻、开会话读一次的规则，在同一份 md 里写 <!-- doc-lint:read-once <文件名> … -->（空格分隔）登记，不算漏引；
# 登记了却不在 rules/ 里的照报「引用了不存在的文件」。
metafails=0
# `|| true`：I18N 不在时 sed 退 2，pipefail 下整条管道跟着退 2，set -e 把脚本当场带走。
FAMILY="$(sed -n 's/^family=//p' "$(dirname "${BASH_SOURCE[0]}")/../I18N" 2>/dev/null | head -1 || true)"
[[ -n "$FAMILY" ]] || FAMILY=singlefs-ai-sop
check_rule_refs() { # check_rule_refs <被查的 md，相对 ROOT> <@ 之后的前缀> <rules 目录> <sop|template|project>
  local md_rel="$1" prefix="$2" rules_dir="$3" which="$4" on_disk referenced missing extra
  on_disk="$(find "$rules_dir" -maxdepth 1 -name '*.md' -printf '%f\n' | sort)"
  referenced="$(grep -oE "@${prefix//./\\.}[A-Za-z0-9._-]+\.md" "$ROOT/$md_rel" | sed 's|.*/||' | sort -u || true)"
  read_once="$(grep -oE '<!-- *doc-lint:read-once[^>]*-->' "$ROOT/$md_rel" | grep -oE '[A-Za-z0-9._-]+\.md' | sort -u || true)"
  referenced="$(printf '%s\n%s\n' "$referenced" "$read_once" | grep -v '^$' | sort -u || true)"
  missing="$(comm -23 <(printf '%s\n' "$on_disk" | grep -v '^$' || true) \
                      <(printf '%s\n' "$referenced" | grep -v '^$' || true))"
  extra="$(comm -13 <(printf '%s\n' "$on_disk" | grep -v '^$' || true) \
                    <(printf '%s\n' "$referenced" | grep -v '^$' || true))"
  if [[ -n "$missing" ]]; then
    case "$which" in
      sop) bad "这些规则文件存在，但 CLAUDE.md 没有 @ 引用：$(printf '%s' "$missing" | tr '\n' ' ')"
           howto "在 CLAUDE.md 的规则清单里补一行 @rules/<文件名>。" \
                 "没被引用的规则不会被读进上下文——它躺在 rules/ 里，看起来却和生效的规则一模一样。" ;;
      template) bad "这些规则文件存在，但 $md_rel 没有 @ 引用：$(printf '%s' "$missing" | tr '\n' ' ')"
           howto "在 $md_rel 的规则清单里补一行 @$prefix<文件名>。" \
                 "install.sh 拿它铺新项目的 CLAUDE.md：模板漏一条，新项目从第一天起就少读一条规则。" ;;
      project) bad "装进来的副本里有这些规则，但 CLAUDE.md 没有 @ 引用：$(printf '%s' "$missing" | tr '\n' ' ')"
           howto "在 CLAUDE.md 的规则清单里补一行 @$prefix<文件名>。" \
                 "副本里有、CLAUDE.md 没 @ 的规则不会被读进上下文——装了等于没装。" ;;
    esac
    metafails=$((metafails+1))
  fi
  if [[ -n "$extra" ]]; then
    case "$which" in
      sop) bad "CLAUDE.md 引用了不存在的规则：$(printf '%s' "$extra" | tr '\n' ' ')"
           howto "把这几行删掉，或者把文件补上。引用不存在的文件不会报错，那一行只是不展开——" \
                 "CLAUDE.md 读起来照样完整，而那条规矩根本没进来。" ;;
      template) bad "$md_rel 引用了不存在的规则：$(printf '%s' "$extra" | tr '\n' ' ')"
           howto "把这几行删掉，或者改成现在的文件名。模板里悬空的引用会原样铺进新项目。" ;;
      project) bad "CLAUDE.md 引用了副本里没有的规则：$(printf '%s' "$extra" | tr '\n' ' ')"
           howto "上游多半把这条规则合并或改名了：看 .claude/$FAMILY/CHANGELOG.md 里是哪一版动的，" \
                 "把这一行换成现在的文件名，或者删掉。悬空的引用不报错，那条规矩根本没进来。" ;;
    esac
    metafails=$((metafails+1))
  fi
}
if [[ -d "$ROOT/rules" ]]; then
  if [[ -f "$ROOT/CLAUDE.md" ]]; then check_rule_refs CLAUDE.md "rules/" "$ROOT/rules" sop; fi
  if [[ -f "$ROOT/templates/CLAUDE.project.md" ]]; then
    check_rule_refs templates/CLAUDE.project.md ".claude/$FAMILY/rules/" "$ROOT/rules" template
  fi
elif [[ -d "$ROOT/.claude/$FAMILY/rules" && -f "$ROOT/CLAUDE.md" ]]; then
  check_rule_refs CLAUDE.md ".claude/$FAMILY/rules/" "$ROOT/.claude/$FAMILY/rules" project
fi

# ── L. 警告记录：.claude/warnings/<日期>.md ────────────────
# 门禁看不见对话，只查写下来的那一半（rules/pushback-discipline.md）：文件名按日期、每个小节四项齐全。
wdir="$ROOT/.claude/warnings"
if [[ -d "$wdir" ]]; then
  while IFS= read -r wf; do
    [[ -n "$wf" ]] || continue
    wrel="${wf#"$ROOT"/}"; wb="$(basename "$wf")"
    if [[ ! "$wb" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\.md$ ]]; then
      bad "$wrel  警告记录的文件名必须是 YYYY-MM-DD.md"
      howto "按日期建文件，一天一个，例： .claude/warnings/2026-09-06.md" \
            "分日期是为了不用回头改旧文件——警告写下就是当时的记录" \
            "（rules/evidence-discipline.md：原样保存的证据不许事后改）。"
      metafails=$((metafails+1)); continue
    fi
    whits="$(awk -v P="${W_ITEMS[0]}" -v O="${W_ITEMS[1]}" -v R="${W_ITEMS[2]}" -v C="${W_ITEMS[3]}" '
      function emit(   miss) {
        nsec++; miss = ""
        if (!p) miss = miss " " P
        if (!o) miss = miss " " O
        if (!r) miss = miss " " R
        if (!c) miss = miss " " C
        if (miss != "") printf "%d\t%s\t%s\n", ln, sec, miss
      }
      /^[ \t]*```/ { fence = !fence; next }
      fence { next }
      /^## / { if (sec != "") emit(); sec = substr($0, 4); p=o=r=c=0; ln=FNR; next }
      sec != "" {
        if (index($0, P)) p=1
        if (index($0, O)) o=1
        if (index($0, R)) r=1
        if (index($0, C)) c=1
      }
      END { if (sec != "") emit(); if (nsec == 0) print "0\t\tNOSEC" }
    ' "$wf")"
    [[ -z "$whits" ]] && continue
    while IFS= read -r wh; do
      wln="$(printf '%s' "$wh" | cut -f1)"; wsec="$(printf '%s' "$wh" | cut -f2)"
      wmiss="$(printf '%s' "$wh" | cut -f3)"
      if [[ "$wmiss" == NOSEC ]]; then
        bad "$wrel  里一个 ## 小节都没有，这份警告记录是空的"
        howto "一次警告一个 ## 小节，四项都要有：${W_ITEMS[0]} ${W_ITEMS[1]} ${W_ITEMS[2]} ${W_ITEMS[3]}" \
              "格式见 rules/pushback-discipline.md。建了个空文件比没建更糟：" \
              "它看起来像「记过了」。"
      else
        bad "$wrel:$wln  「$wsec」缺这几项：$wmiss"
        howto "四项都要有：${W_ITEMS[0]} ${W_ITEMS[1]} ${W_ITEMS[2]} ${W_ITEMS[3]}" \
              "缺哪一项就少哪一半：没有异议不知道当初反对的是什么，" \
              "没有已知风险不知道该盯什么现象，没有结果不知道最后到底怎么办了。"
      fi
      metafails=$((metafails+1))
    done <<< "$whits"
  done < <(find "$wdir" -maxdepth 1 -name '*.md' | sort)
fi

say ""
if [[ $WORDLIST -ne 1 ]]; then
  warn "本语言（$DOC_LANG）没有词表，以下检查**未实现**，不是通过："
  warn "  A 正文历史陈述（原为 / 曾经 / 已废弃 …）"
  if [[ $REFERENCE_WORDLIST -eq 1 ]]; then
    warn "  D kb 的时间指代（本轮 / 这一轮 …）；位置指代与自称按本语言的词表判了"
  else
    warn "  D kb 的位置指代与自指称呼"
  fi
  warn "  I 文风（翻译腔 / 古风腔 / 过度解释）"
  howto "要补就在 scripts/doc-lint.sh 的 PATTERNS 与 ctx/self 里加本语言的词表，" \
        "并在 scripts/fixtures/ 下配该语言的红样本与踩边界的绿样本（日文的在 doc-lint-ja/）。" \
        "在那之前这几类违规不会被拦——绿灯不代表这几条验过了。"
fi
if [[ $fails -gt 0 || $reffails -gt 0 || $numfails -gt 0 || $exfails -gt 0 || $carrierfails -gt 0 || $metafails -gt 0 ]]; then
  bad "文档铁律检查失败：$fails 个文件违规、$reffails 处编号引用无定义、$numfails 处编号定义/引用不合规、$exfails 条排除项不合规、$carrierfails 条历史登记不合规、$metafails 处规则清单/警告记录不合规（检查 $checked，跳过 $skipped）"   # gate-lint:summary
  exit 1
fi
warn "位置指代与自指称呼这两条是**启发式**：只认句首或标点之后的常见说法，"
warn "  「按本决策办」这种嵌在句中的漏得掉。绿不代表这两条穷举过了。"
ok "文档铁律检查通过（检查 $checked，跳过 $skipped；DOC_LINT_VERBOSE=1 看全部）"
