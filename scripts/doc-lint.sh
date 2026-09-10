#!/usr/bin/env bash
# 文档铁律的自动检查。rules/writing-discipline.md 和它分出去的 design-doc、kb 两篇靠这个脚本强制，不靠自觉。
#
# 检查十二条：
#   A. 正文（「## 历史版本」之前的部分）不许出现历史陈述与就地废弃标注
#   A2. 围栏必须配对；「## 历史版本」之后不许再开 ## 级小节——
#       两者任一成立时，其后内容都躲开了全部扫描（对抗测试实测）
#   B. CLAUDE.md 与 rules/*.md 不许有「## 历史版本」节（历史外置）
#   B3. GLOSSARY.md 的说明列必须三语并列（zh<br>en<br>ja），少一段判红
#   B2. agents/*.md 同 rules/：不留历史节；且必须有 frontmatter 的 name（与文件名一致）
#       与 description——两样都不会报错，只会安静地不生效
#   C. kb/*.md 必须有「## 历史版本」节收尾
#   D. kb/*.md 正文不许出现上下文指代、方位指代与自指称呼（检索把单条端出来时，
#      「上文」「下面」「此处」一起断掉；rules/kb-discipline.md 第 1 条）
#   E. kb/*.md 里引用的不变量编号（I-<类>.<号>）必须真的被某张表定义过
#   F. kb/*.md 里一个编号只许有一处登记位（rules/kb-discipline.md 第 5 条）
#   G. kb/*.md 里编号的每一处引用都要带上简称，且与登记位一致（同上）
#   H. kb/*.md 里编号形状的记号反复出现（≥3 次）却一处登记位都没有（同上）
#   I. 所有给人读的 .md 不许出现翻译腔 / 古风腔 / 过度解释的固定构式
#      （rules/writing-discipline.md「说人话」；同 A、D，只在有词表的语言上跑）
#   J. $ROOT/.claude/doc-lint-exclude 里的每条排除都要带理由、指向真实目录、且真的有东西被排除
#   K. rules/*.md 与 @ 引用逐项相等：SOP 仓的 CLAUDE.md 与模板，项目的 CLAUDE.md 与装进来的副本
#      ——没被引用的规则不进上下文，等于没写
#   L. .claude/warnings/ 下的警告记录：文件名是 YYYY-MM-DD.md，每个 ## 小节四项齐全
#      （rules/pushback-discipline.md）
#
# 门禁自己的样本（$ROOT/scripts/fixtures/）不扫：那些文件是**故意写坏的**，
# 排除写成相对本次 ROOT 的路径——selftest 把某个样本目录当 ROOT 跑时，这个前缀不匹配，
# 样本照查（写成 */fixtures/* 的话样本永远被跳过，自检就成了摆设）。
# 由 scripts/selftest.sh 拿去证明检查会红，不是项目内容。
# 装进项目的 SOP 副本（*/singlefs-ai-sop/*）不扫：它由上游自己的门禁管，
# 在项目侧再扫一遍，只会让它的模板与项目 kb 的编号互相撞成假红。
# 围栏代码块内的内容不检查（那是示例）。
# 定义规则本身的文件加 <!-- doc-lint:rule-definition --> 跳过，并会显式报告为已跳过。

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="${1:-$(project_root)}"
[[ -d "$ROOT" ]] || die "找不到项目根：$ROOT" \
  "把项目根作为第一个参数传进来： bash scripts/doc-lint.sh <项目根>"
# 末尾斜杠要削掉。selftest 传进来的样本目录带 `/`，于是下面 EXCL 里的
# `$ROOT//<目录>/*` 一个文件都匹配不上——排除项静默失效，而输出里看不出区别
# （实测：新加的排除样本在直接跑时绿、在 selftest 里红，差别只有这个斜杠）。
if [[ "$ROOT" != "/" ]]; then ROOT="${ROOT%/}"; fi

tmpd="$(mktemp -d)"; trap 'rm -rf "$tmpd"' EXIT

# 不扫哪些：
#   $ROOT/scripts/fixtures/  —— 门禁自己的样本，故意写坏的，由 selftest.sh 拿去用
#   */singlefs-ai-sop/*      —— 装进项目的 SOP 副本，由上游自己的门禁管
# 两条都写成「相对本次 ROOT」的形态。写死成 */…/* 的话，selftest 把样本目录当 ROOT 跑时
# 路径照样匹配，样本被跳过、全绿——自检就成了摆设（装进项目后实测踩到）。
EXCL=(-not -path "$ROOT/scripts/fixtures/*")
case "$ROOT" in
  */singlefs-ai-sop|*/singlefs-ai-sop/*) ;;   # 就在包里（或包内样本里）跑，不排除自己
  *) EXCL+=(-not -path '*/singlefs-ai-sop/*') ;;
esac

# ── 语言 ────────────────────────────────────────────────
# 本脚本在 SHARED 里逐字节复制到各语言仓，而它的判据（历史陈述的词、
# 「## 历史版本」这个标题、上下文指代与自指的词表）**全是语言相关的字面量**。
# 复制过去之后：英文项目的 kb 写 `## Revision history`，被要求写中文标题——
# 而英文的 "previously"、"as noted above" 一条也抓不到（复核实测：
# **en 仓自己发的 kb 模板过不了 en 仓自己的 doc-lint**）。
# 误拒比漏检更糟：门禁一旦开始误拒，人就会绕过它。
#
# 所以判据按语言取。语言从包的 I18N 的 this= 读；读不到按参照语言（zh）算。
# **没有词表的语言，对应的检查显式报「未实现」，不静默通过**
# （rules/show-me-test.md：门禁不许假装通过）。
#
# 判据取哪种语言，另有一处例外：**门禁自己的样本是中文写的**，而它们随 scripts/
# 逐字节复制进每个语言仓。于是在 en 仓里，同一批样本被拿去跟 `## Revision history`
# 对判，44 个样本一起假红，而 doc-lint 自己一个字都没坏
# （实测：en / ja 两仓的门禁从 0.0.25 起一直是红的，根因就是这个）。
# 样本的语言是**样本的属性**，不是仓的属性，所以要能显式指定：DOC_LINT_LANG。
# 它只给 scripts/selftest.sh 用。拿它去跑真实项目，等于自己给自己换判据，
# 所以**设了就打印出来**——改判据的事不许不留痕迹（rules/show-me-test.md）。
PKG_LANG="$(sed -n 's/^this=//p' "$(dirname "${BASH_SOURCE[0]}")/../I18N" 2>/dev/null | head -1)"
LANG_FORCED=0
DOC_LANG="$PKG_LANG"
if [[ -n "${DOC_LINT_LANG:-}" ]]; then DOC_LANG="$DOC_LINT_LANG"; LANG_FORCED=1; fi
[[ -n "$DOC_LANG" ]] || DOC_LANG=zh

# 警告记录（.claude/warnings/<日期>.md）的四个项名同样是语言相关的字面量，
# 与 HIST_HEAD 一样按语言取。这是**结构型**判据，不是词表——它认的是固定的项名，
# 不是靠字形黑名单猜语义，所以三种语言都跑得了，不进 WORDLIST 那一档。
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

# 词表型检查（历史陈述 A、上下文指代与自指 D）只有中文词表。
# **不给别的语言硬造一套**：这类判据是用字形黑名单去判语义，中文这一套是按撞到的
# 假红逐个补出来的（`脚副样文版译抄剧根基成日资蓝范母拓孤标课` 这串就是存档），
# 再造两套等于把假红面乘三。没有就说没有——门禁不许假装通过
# （rules/show-me-test.md）。结构型检查（围栏、历史节的有无与位置、编号治理）
# 与语言无关，所有语言照跑。
WORDLIST=0
[[ "$DOC_LANG" == zh ]] && WORDLIST=1

# 违规模式：正则 → 为什么违规
# ⚠️ **每条模式的 why 都要不一样。** 共用一句的话，样本只需一条 want 就能盖住几条，
#    于是删掉其中任一条都不会红——原先「原先/以前/之前」三条共用「正文不许写历史陈述」，
#    复核的变异测试逐条删，三次全绿。
# ⚠️ 方括号集合里**不许用 \] \[ 转义**：POSIX 规定括号内的反斜杠是字面量，
#    GNU grep 照 POSIX 办，于是 '[〕】\]]' 变成「〕|】|\ 之后再跟一个 ]」——
#    这条模式从来没命中过任何东西（本轮审计实测）。要收进 ] 就把它放在集合首位：
#    '[]〕】]'；要收进 [ 直接写 '[[〔【]'。fixtures/doc-lint/histstate 盯着它。
PATTERNS=(
  '~~[^~]'                    '正文不许用删除线标注废弃，直接删掉并写进「历史版本」'
  '[[〔【]已废弃[]〕】]'         '正文不许就地标注已废弃'
  '[（〔【(]已废弃'              '正文不许就地标注已废弃，删掉旧内容并写进「历史版本」'
  '[（(][[:space:]]*原为'        '正文不许写"（原为 X）"，直接改成现行值'
  '[^还复恢化]原先[^前]'         '正文不许写"原先 X"，直接改成现行值'
  '以前[叫是][^否]'              '正文不许写"以前叫/是 X"，直接改成现行值'
  '之前[叫][^否]'                '正文不许写"之前叫 X"，直接改成现行值'
  '曾经[叫是]'                   '"曾经叫/是"只能出现在「历史版本」节内'
  # 前缀收窄到本 SOP 管的那几套编号（D 决策 / E 实验 / C 欠检查 / I 不变量 / A 前提 / O oracle）。
  # ⚠️ 收窄是实测逼出来的：原式是 [A-Z][A-Za-z-]*[0-9]，于是一句讲盘上字节的话
  # 「要重建 U1，需要 U2 的原始字节 —— 已被 U9 覆盖」被判成「就地标注被某条决策覆盖」。
  # 那句里的「覆盖」是字节被写掉，不是条款被推翻——两个义项撞在同一个词上，
  # 只能靠「被覆盖的那个东西是不是一条编号条款」来分。
  '已被[[:space:]]*[DECIAO][0-9]\{1,3\}[^，。；]\{0,4\}覆盖'  '正文不许就地标注被某条覆盖，删掉并写进「历史版本」'
)

# ── I. 文风：翻译腔与古风腔的固定构式（rules/writing-discipline.md「说人话」）──────
# 只查**词表里那些固定说法**。句子顺不顺、转折多不多余、解释啰不啰嗦，机器判不了，
# 那半靠人念一遍——词表全绿不代表这条守住了，只代表没踩到最明显的几个坑。
# 与 A/D 同样是词表型检查，所以同样只在有词表的语言上跑。
STYLE=(
  '在[^，。；：]\{0,10\}的情况下'   '翻译腔：「在……的情况下」→ 直接说「……的时候」，或者整句重写'
  '对[^，。；：]\{1,10\}而言'       '翻译腔：「对……而言」→「对……来说」'
  '就[^，。；：]\{1,10\}来说'       '翻译腔：「就……来说」→「对……来说」，或者删掉'
  '使得[^到以]'                    '翻译腔：「使得」→「让」'
  '\(^\|[^不未别]\)\(进行\|予以\|加以\)..'  '翻译腔：「进行/予以/加以 + 动词」→ 直接用那个动词'
  '\(此乃\|实乃\|是故\|然则\|殊为\|不失为\)'  '古风腔：直接说这是什么、所以怎样'
  '\(众所周知\|毋庸置疑\|不言而喻\|无可厚非\)'  '过度解释：这几个词说了等于没说，删掉'
  '诚然[^，。]\{0,12\}[，。]'      '不必要的转折：「诚然……但是」多半两边不冲突，只留你真想说的那半'
)

fails=0; skipped=0; checked=0

# 输出正文部分（截到「## 历史版本」之前），并剔除围栏代码块
body_of() {
  awk -v HIST="$HIST_HEAD" '
    $0 == HIST { exit }
    /^[ \t]*```/ { infence = !infence; next }
    { if (!infence) print NR "\t" $0; else print NR "\t" }
  ' "$1"
}

head1 "文档铁律检查"

if [[ $LANG_FORCED -eq 1 ]]; then
  warn "语言由 DOC_LINT_LANG 指定为 $DOC_LANG（本包是 ${PKG_LANG:-zh}）——这个变量只给门禁自检用"
  howto "跑真实项目不要设它：判据换成别的语言，等于自己给自己改判据。" \
        "要让本包换语言，改 I18N 的 this=，别在命令行上盖。"
fi

# ── 原样保存的证据：扫描要绕开 ──────────────────────────
# 有些 .md 是**当时原样存下来的**：发给模型的提示、跑出来的原始输出。
# 它们与产物一一对应，事后改一个字，产物就不再对应它的输入
# （rules/evidence-discipline.md 的「原样保存的证据不许事后改」）。
# 这种目录由项目自己声明，一行一条，格式 `<相对目录>  # 为什么`：
#   $ROOT/.claude/doc-lint-exclude
# **理由不许省**：排除范围是会被后来人照抄的东西，抄的人得看得见当初为什么排。
# 排除项一律**报出来**——静悄悄少扫 207 个文件，和这道检查没实现长得一模一样。
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
    # 路径必须是 ROOT 之下的一个**子**目录。允许 `.` 或绝对路径的话，
    # 一行就能把整棵树排掉，而门禁照样全绿——那正是这道机制最该拦住的滥用。
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

while IFS= read -r f; do
  rel="${f#"$ROOT"/}"
  # CHANGELOG 是规则指定的历史存放处（design-doc-discipline：历史外置到 CHANGELOG.md）——
  # 它整个文件就是历史，拿「正文不许历史陈述」去扫它是范畴错误。
  if [[ "$(basename "$f")" == "CHANGELOG.md" ]]; then
    [[ -n "${DOC_LINT_VERBOSE:-}" ]] && warn "跳过 $rel（历史文件）"
    skipped=$((skipped+1)); continue
  fi
  base="$(basename "$f")"
  # 认围栏：design-doc-discipline 的示例块里就有一行「## 历史版本」，围栏里的不算数
  has_hist="$(awk -v HIST="$HIST_HEAD" '/^[ \t]*```/{fence=!fence;next} fence{next}
                   $0 == HIST {print 1; exit}' "$f")"
  [[ -n "$has_hist" ]] || has_hist=0

  # ⚠️ **历史节的有无要在免检牌之前判。**
  # 免检牌的用途是「这份文件在定义那些模式，正文里出现『原为 X』不算违规」——
  # 它管的是**模式匹配**，不该连「有没有 ## 历史版本 这个标题」这种纯结构判定一起豁免。
  # 而本仓 14 份规范文本全带着这张牌，于是 design-doc-discipline 声称由本脚本强制的
  # 那条「rules 连文末历史节都不留」，对它真正管的那批文件一次也没红过（复核实测）。
  structfail=0
  if [[ "$base" == "CLAUDE.md" && $has_hist -eq 1 ]]; then
    bad "$rel  CLAUDE.md 不许有「$HIST_HEAD」节，历史外置到 kb/ 或 CHANGELOG.md"
    howto "把这一节整段挪到 CHANGELOG.md 或 kb/。CLAUDE.md 每次开工都要通读，" \
          "混进历史会稀释它（rules/design-doc-discipline.md）。"
    structfail=1
  fi
  if [[ ( "$f" == */rules/*.md || "$f" == */agents/*.md ) && $has_hist -eq 1 ]]; then
    bad "$rel  规则/agent 定义连文末「$HIST_HEAD」都不留，历史外置到 CHANGELOG.md"
    howto "把这一节挪到 CHANGELOG.md。规则是每次开工都要通读的，" \
          "混进历史会稀释（rules/design-doc-discipline.md）。"
    structfail=1
  fi

  # 标记必须独占一行且在文件头 5 行内——否则正文里"提到"这个字符串会被误判为跳过。
  # 且只许出现在规则本体的位置：别处（尤其 kb）贴这张免检牌，
  # 等于一行注释把整个文件的检查关掉（对抗测试实测）。
  if head -5 "$f" | grep -qx '<!-- doc-lint:rule-definition -->'; then
    case "$f" in
      # kb 分支必须排在白名单前面：kb/rules/x.md 这种嵌套路径否则会先匹配上
      # */rules/*.md 白名单溜掉（对抗测试实测）
      */kb/*)
        bad "$rel  rule-definition 标记不许出现在 kb 里"
        howto "删掉文件头的 <!-- doc-lint:rule-definition -->。kb 是给模型检索的内容，" \
              "必须受检；规则定义住在 rules/，不住在 kb（rules/writing-discipline.md）。"
        checked=$((checked+1)); fails=$((fails+1)); continue ;;
      */CLAUDE.md|*/rules/*.md|*/agents/*.md|*/skills/*/SKILL.md)
        if [[ $structfail -eq 1 ]]; then
          # 结构检查已经红了：这一份既不算「跳过」，也不能算通过
          checked=$((checked+1)); fails=$((fails+1)); continue
        fi
        [[ -n "${DOC_LINT_VERBOSE:-}" ]] && warn "跳过 $rel（规则定义文件）"
        skipped=$((skipped+1)); continue ;;
      *)
        bad "$rel  rule-definition 标记只许用于 CLAUDE.md、rules/、skills/*/SKILL.md"
        howto "删掉文件头的 <!-- doc-lint:rule-definition -->——这份文件不是规则定义，" \
              "内容就该受检。要引用规则，链到 rules/ 对应文件。"
        checked=$((checked+1)); fails=$((fails+1)); continue ;;
    esac
  fi
  checked=$((checked+1))
  body="$(body_of "$f")"
  filefail=0

  # 围栏必须配对：一行落单的 ``` 让其后全文被当代码块跳过——
  # 所有检查一起失明，而这个错误极易无意犯出（对抗测试实测）。
  nfence="$(grep -cE '^[ \t]*```' "$f")" || true
  if (( nfence % 2 )); then
    bad "$rel  围栏代码块未闭合（\`\`\` 共 $nfence 处，奇数）"
    howto "找到落单的那行 \`\`\` 补上闭合。围栏没配对时，其后全文不受任何检查。"
    filefail=1
  fi

  # 「## 历史版本」必须是文末最后一节：它之后再开新节，
  # 新内容就躲开了正文检查——正文扫描在第一处历史节停机（对抗测试实测）。
  # 认**任何级别**的标题，不只 ## —— 用 ### 或 # 另起一节同样能把内容藏到
  # 正文扫描的停机点之后（对抗测试实测：藏了五处违规，全门禁绿）。
  #
  # 判据分三档，按「这是不是另起了一节」来定：
  #   `#` / `##`  —— 另起一节，一律判红
  #   `###`       —— 历史条目，必须**以日期开头**（`### 2026-09-02（其八）：…` 这种算）
  #   `####` 起   —— 一条历史条目内部的小标题，放行
  # 两处都是在真实项目上校准的：要求整行只有日期，会一次报出几百行假红；
  # 连 `####` 一起拦，会把历史条目里的分节也拦下（都实测于 singlefs）。
  # 被堵住的绕法是 `### 当前口径（现行）` 这种不以日期开头的标题，判据仍然管得住。
  afterhist="$(awk -v HIST="$HIST_HEAD" '/^[ \t]*```/{fence=!fence;next} fence{next}
                    $0 == HIST {h=1;next}
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
    if hits="$(printf '%s\n' "$body" | grep -n "$pat" || true)"; [[ -n "$hits" ]]; then
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

  # 文风（rules/writing-discipline.md「说人话」）。所有给人读的 .md 都查，不只 kb。
  if [[ $WORDLIST -eq 1 ]]; then
    j=0
    while [[ $j -lt ${#STYLE[@]} ]]; do
      spat="${STYLE[$j]}"; swhy="${STYLE[$((j+1))]}"
      if shits="$(printf '%s\n' "$body" | grep -n "$spat" || true)"; [[ -n "$shits" ]]; then
        while IFS= read -r h; do
          ln="$(printf '%s' "$h" | sed 's/^[0-9]*://; s/\t.*//')"
          txt="$(printf '%s' "$h" | sed 's/^[0-9]*://; s/^[0-9]*\t//')"
          bad "$rel:$ln  $swhy"
          say "        > $(printf '%s' "$txt" | cut -c1-80)"
          howto "换成平时说话会用的说法。判据是「这句你会对同事说出口吗」——" \
                "不会就改（rules/writing-discipline.md「说人话」）。"
          filefail=1
        done <<< "$shits"
      fi
      j=$((j+2))
    done
  fi

  # kb 是被检索的，不是被通读的：一条事实被单独取出时必须仍然成立
  #   D-1 上下文指代：指着「上文」，而检索结果里没有上文
  #   D-2 自指称呼：指着「此处」，而检索把这一条从文件里摘下来时，「此处」也没了——
  #       那个 `## D22 单元原子性怎么合成` 的标题不会跟着走。
  #       尾字排除是实测出来的：kb 里真有「该节点」，不排除就是假红。
  #       「本工程」「本仓」「本轮」「本机」不在其内——它们指的是项目，不是文档位置。
  if [[ "$f" == */kb/*.md && $WORDLIST -eq 1 ]]; then
    # 方位指代（见下 / 见上表 / 上面那张表）与上下文指代同一个病：检索结果里没有上下。
    # 「上一条」「下一条」**不在其内**——实测假红压倒真红：一个已登记的简称就叫
    # 「上一条时间线的残留」，还有「记下一条自评」「装得下一条记录」这类动宾。
    # 「同上」要认边界：左排除构词（协同/合同/不同），右排除「同上游/同上层」——
    # 「哈希口径同上游清单」是正常句子，不排除就是假红（对抗测试实测）。
    # 「同上」只在**独立成词**时算指代。写成左右排除的话，排除表永远补不完
    # （`相同上下文`、`共同上报` 都实测撞过），而这几个词本身与指代无关。
    ctx='如上所述|如前所述|同上[，。；：、）」]|同上$|见上文|见上面|前面提到|上一节([^点拍]|$)|前述|下面会说|后面会说'
    ctx="$ctx"'|见[上下](表|文|节|条|图|面|$|[，。；：、）」])|[如照][上下](表|图)|上面[那这]|下面[那这]'
    if refs="$(printf '%s\n' "$body" | grep -nE "$ctx" || true)"; [[ -n "$refs" ]]; then
      while IFS= read -r r; do
        rln="$(printf '%s' "$r" | sed 's/^[0-9]*://; s/\t.*//')"
        rtx="$(printf '%s' "$r" | sed 's/^[0-9]*://; s/^[0-9]*\t//')"
        bad "$rel:$rln  kb 正文不许用上下文指代"
        say "        > $(printf '%s' "$rtx" | cut -c1-80)"
        howto "把被指代的内容直接写出来，或链到那条事实所在的文件。" \
              "检索会把这一条单独端出来，指代当场断掉——而模型不会说看不懂，它会补一个。"
        filefail=1
      done <<< "$refs"
    fi
    # 首字排除与尾字排除同一个理由（实测假红压倒真红）：「脚本文件」「副本文件」
    # 「成本表」里的「本」是构词，不是自指；「应该文件化」里的「该」同理。
    # 判据从**黑名单**收到**白名单**：只认真正指「此处」的那几个固定说法。
    # 黑名单版是按撞到的假红逐个补出来的（`脚副样文版译抄剧根基成日资蓝范母拓孤标课`
    # 这串就是存档），而在一个文件系统项目里「该文件」「本文件系统」「该表」几乎
    # 全指盘上的东西，不指文档位置——假红实测四条，都是这个来源。
    #
    # 「文件」整个拿掉：真自指用的是「本文档」。
    # 「表」只认「本表」，不认「该表」（内存里的表就叫「该表」）。
    tails='(决策|不变量|章节|文档|实验([^室]|$)|条([^件目]|$)|节([^点]|$)|表([^格]|$))'
    # 左侧用**白名单**：只在句首或标点之后才算自指。
    # 黑名单版（排掉「脚副样文版译抄剧根基成日资蓝范母拓孤标课」）是按撞到的假红
    # 逐个补出来的，每补一个字就是一次「上一轮误拒过一个人」的存档——
    # 而「样本文档」「成本表」「三本文档」这类构词根本枚举不完（假红实测）。
    lead='(^|[，。；：、！？（）()「」『』【】〔〕〈〉《》“”"[:space:]])'
    # 「该表」在文件系统项目里几乎总指内存里的表（「槽位表有 4096 项，该表常驻内存」），
    # 真自指用的是「本表」——所以「表」只跟「本」，不跟「该」（假红实测）。
    gtails='(决策|不变量|章节|文档|实验([^室]|$)|条([^件目]|$)|节([^点]|$))'
    self="$lead本$tails|$lead该$gtails|$lead这(条|个)(决策|实验|不变量)"
    # 指被测系统而不是文档位置的，一律排除
    selfskip='本(工程|仓|轮|机|文件系统|系统|盘|实现|包|次)'
    if selfs="$(printf '%s\n' "$body" | grep -nE "$self" | grep -vE "$selfskip" || true)"; [[ -n "$selfs" ]]; then
      while IFS= read -r r; do
        rln="$(printf '%s' "$r" | sed 's/^[0-9]*://; s/\t.*//')"
        rtx="$(printf '%s' "$r" | sed 's/^[0-9]*://; s/^[0-9]*\t//')"
        bad "$rel:$rln  kb 正文不许用自指称呼"
        say "        > $(printf '%s' "$rtx" | cut -c1-80)"
        howto "把当前位置写成名字：条目写成「D22（单元原子性怎么合成）」，" \
              "章节写成它的标题，文档写成它的文件名。" \
              "检索端出来的那一条没有「此处」——它已经被从文件里摘下来了。"
        filefail=1
      done <<< "$selfs"
    fi
  fi

  # 结构检查（历史节的有无）已在免检牌之前跑过，结果在 $structfail
  [[ $structfail -eq 1 ]] && filefail=1
  # GLOSSARY 是各语言仓共用的一份，说明列必须三语并列（zh<br>en<br>ja）。
  # 少一列不会报错，只会让用那种语言的人拿到一份他读不懂的说明——
  # 而「先加中文，别的下次补」正是分叉的起点（rules/kb-discipline.md：矛盾比空白更糟）。
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
        # 每段要有实质内容：写成 `-` / `—` / `TODO` / `n/a` 就等于没写
        # （对抗测试实测：`中文<br>-<br>-` 判绿）
        if (ok) for (i = 1; i <= 3; i++) {
          t = seg[i]; gsub(/^[ \t]+|[ \t]+$/, "", t)
          if (t == "" || t ~ /^[-—–~.*_[:space:]]+$/ || tolower(t) ~ /^(todo|tbd|n\/a|na|\?+)$/) ok = 0 }
        if (!ok) printf "%d\037%s\037%d\n", FNR, term, n
      }' "$f")
  fi

  # agent 定义是被**委派**的，主模型靠 description 决定派不派它、靠 frontmatter 认它。
  # frontmatter 不从第 1 行起 → 整个定义不被识别；name 与文件名对不上 → 派不到。
  # 两样都不会报错，只会安静地不生效——所以做成会红的检查（rules/sop-first.md）。
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

  if [[ "$f" == */kb/*.md && "$base" != "INDEX.md" && $has_hist -eq 0 ]]; then
    bad "$rel  kb 文档必须有「$HIST_HEAD」节收尾"
    howto "在文末补上（没有历史也要留这个节，供以后写）：" \
          "$HIST_HEAD" "" "### $(date +%F)" "- 建档。"
    filefail=1
  fi

  if [[ $filefail -eq 0 ]]; then
    [[ -n "${DOC_LINT_VERBOSE:-}" ]] && ok "$rel"
  else
    fails=$((fails+1))
  fi
done < <(find "$ROOT" -name '*.md' -not -path '*/.git/*' -not -path '*/target/*' \
                 "${EXCL[@]}" | sort)

# E. 引用了不存在的编号 —— 空白比错误更危险（rules/kb-discipline.md 第 3 条）
#    典型形态：「历史版本」写了「补 I-4.4~I-4.7」，正文其实没补，别处还在引用它们。
#    人通读能察觉，检索不会——它只会把那条引用端出来，模型照单全收。
reffails=0
kb_files="$(find "$ROOT" -path '*/kb/*.md' -not -path '*/.git/*' \
                    "${EXCL[@]}" | sort)"
if [[ -n "$kb_files" ]]; then
  # 定义 = 表格行首的编号；引用 = 别的任何位置出现的编号。围栏代码块不算。
  # 「历史版本」节里的也不算——那里的表格是删除记录，已删的不变量不能再给引用背书
  # （对抗测试实测：定义只剩历史节里一行，全部引用照绿）。
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
        if ! printf '%s\n' "$defined" | grep -qx "$id"; then
          bad "$rel:$ln  引用了没有定义的不变量编号 $id"
          howto "要么在 kb/invariants.md 里把 $id 真的写成一行（可判定的陈述 + checker 状态），" \
                "要么删掉这处引用。引用一个不存在的编号，检索出来看不出它不存在——" \
                "而模型不会说找不到，它会补一个（rules/kb-discipline.md 第 3 条）。"
          reffails=$((reffails+1))
        fi
      done
    done <<< "$refs"
  done <<< "$kb_files"
fi

# F/G/H. 编号只能做索引，不能做称呼（rules/kb-discipline.md 第 5 条）
#   登记位有且只有两种：
#     1. 登记表：表格上方单独一行 <!-- doc-lint:registry name-col=N -->，
#        该表每行首列的编号即登记位，简称取第 N 列（N 默认 2，必须 ≥2）
#     2. 登记标题：`## D1 数据可移动性 —— 已定`，简称取编号之后、破折号之前那一段
#   不从「表格首列是编号」去猜——实测过，首列同样被用来当行标签
#   （`| D2 | 节点内 parity 与 D2 的… |`、`| I-6.1 | 补注：… |`），猜的话这些全是假红。
#   标题也要带破折号才算登记，否则「### D1 与 parity 的关系」这种讨论标题会被当成
#   第二处登记位，还把简称顶掉，让所有本来正确的引用一起红。
#   其余每一次出现都算引用，必须写成 `D1（数据可移动性）`。
#   F 查登记位（唯一、简称非空不超长、不重名、登记表本身没写坏），
#   G 查引用带简称且与登记位一致，H 查「反复出现却一处登记都没有」。
NAME_MAX=48     # 简称的显示宽度上限（汉字算 2、ASCII 算 1，即 24 个汉字）。
                # 带不动的名字等于没名字，逼登记处起个短的。一个字符数管三种语言不行：
                # 24 个汉字与 24 个 ASCII 字符的信息量差三倍。
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
            # 静默跳过等于「登记表里写着却没登记上」，最后由 H 报成「没有任何登记位」——
            # 指着错的方向。这里直接报出来。
            printf "ERR\037%s\037%d\037这一行取不到第 %d 列（简称列），登记不上\n", FN, FNR, ncol
          } else {
            nm = c[ncol + 1]; gsub(/^[ \t]+|[ \t]+$/, "", nm)
            printf "DEF\037%s\037%s\037%s\037%d\n", id, nm, FN, FNR }
        }
        next }
      # 登记标题的形态是「编号 简称 —— 状态」。少了分隔符就不算登记位——
      # 否则「### D1 与 parity 的关系」这种讨论标题会被当成第二处登记位，
      # 还把简称顶掉，让所有本来正确的引用一起红。
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

  # F. 登记表本身写坏了——这些以前是静默降级，最后由 H 报成「没有任何登记位」，指错方向
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

  # H. 反过来：编号形状的记号反复出现，却一处登记位都没有——那是拿编号当称呼在用。
  #    少了这一条，一个从没登记过的 kb 会全绿：登记位为空 ⇒ F、G 都无事可做，
  #    而实测出事的那个 kb 正是一处登记都没有的。
  #    领域术语（RAID5、SHA256、Z3）形状上与编号分不开，靠显式声明摘出去，不靠猜。
  exemptf="$tmpd/exempt.txt"
  cut -d$'\037' -f1 "$defsf" | sort -u > "$exemptf"
  declaredf="$tmpd/declared.txt"
  # 读豁免声明也要认围栏：别处所有扫描都认，只有这里不认，
  # 于是在 ```markdown 块里「举例」写一行声明就能把豁免真的打开（对抗测试实测）。
  awk '/^[ \t]*```/ { fence = !fence; next } fence { next }
       /<!-- *doc-lint:not-numbers/ { print }' "${kb_arr[@]}" 2>/dev/null \
    | grep -oE '<!-- *doc-lint:not-numbers[^>]*-->' \
    | sed -E 's/<!-- *doc-lint:not-numbers//; s/-->//' | tr -s ' \t' '\n' \
    | grep -v '^$' | sort -u > "$declaredf" || true
  # not-numbers 是给 RAID5/SHA256/Z3 这类术语的。已有登记位的编号再声明豁免，
  # 等于一行注释把检查对它关掉（对抗测试实测）——判红。
  # 没登记过的编号声明豁免仍放行：形状上分不开 Z3 与 O2，机器只能管到这里。
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
            # `-`/`.`/`_` 留在排除集里：把它们拿掉能堵住「写成 `-D1` 藏掉裸引用」这种
            # 刻意绕法，但代价是在真实项目的 kb 上误拒了 9 处正常引用（实测于 singlefs）。
            # 按 selftest.sh 头部那条：误拒比漏检更会把人推去绕过门禁，所以留着。
            # 那条绕法记在 kb-discipline.md 的「只能靠人的那半」里，不假装拦住了。
            if (before ~ /[A-Za-z0-9._-]/) continue
            if (after ~ /[A-Za-z]/) continue
            if (after ~ /[0-9]/) continue
            if (after == "." && nxt ~ /[0-9]/) continue  # I-6 出现在 I-6.1 里面
            if (!(tok in name)) continue
            # 登记行/登记标题：只放过它登记的那个编号本身，同一行里对**别的**编号的
            # 引用照查——那正是实测出事的位置形态（登记表的「判什么」列）。
            if (n in defid) {
              # 登记行/登记标题：放过它登记的那个编号，以及简称里含的编号——
              # 简称本身要求带名字是无限递归。同一行其它位置对别的编号的引用照查，
              # 那正是实测出事的位置形态（登记表的「判什么」列）。
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
                # 跳过简称内部：简称里含的是**别的**编号时，不跳就成了新的裸引用，
                # 补上名字又引出下一个——无限递归。
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
    printf '%s\n' "$hits" | head -3 | awk -F'\t' '{printf "        :%s  %s %s —— %s\n", $1, $3, $2, $4}'
    howto "每处引用都写成「编号（简称）」，简称照登记位抄，例：「D1（数据可移动性）」。" \
          "编号在引用处只剩一个符号，含义能被悄悄改掉而没有一个字看起来别扭——" \
          "实测代价见 rules/kb-discipline.md 第 5 条。全量清单：DOC_LINT_VERBOSE=1"
    [[ -n "${DOC_LINT_VERBOSE:-}" ]] && printf '%s\n' "$hits" | awk -F'\t' '{printf "        :%s  %s %s —— %s\n", $1, $3, $2, $4}'
    numfails=$((numfails+1))
  done <<< "$kb_files"
fi

# ── K. 规则清单：rules/ 与 @ 引用必须逐项相等 ─────────────
# 没被 @ 引用的规则**不会被读进上下文**，等于没写；而它躺在 rules/ 里，
# 看起来和生效的规则一模一样。反过来，引用了不存在的文件同样无声——
# 那一行只是不展开，CLAUDE.md 读起来照样完整。
# 同一个判据管三处：
#   SOP 仓的 CLAUDE.md ↔ rules/
#   SOP 仓的 templates/CLAUDE.project.md ↔ rules/：install.sh 拿它铺新项目的 CLAUDE.md，
#     模板漏一条，新项目从第一天起就少读一条（实测：pushback-discipline 从 0.0.31 起就不在模板里）
#   项目的 CLAUDE.md ↔ 装进来的副本 .claude/<族名>/rules/
#     （实测 singlefs：engineering-philosophy、sop-first、pushback-discipline、writing-style 四条从没被引用过）
# 项目本地的 .claude/rules/ 是项目自己的事，由项目自己的门禁阶段管（判据一样，但那批文件不归上游）。
metafails=0
FAMILY="$(sed -n 's/^family=//p' "$(dirname "${BASH_SOURCE[0]}")/../I18N" 2>/dev/null | head -1)"
[[ -n "$FAMILY" ]] || FAMILY=singlefs-ai-sop
check_rule_refs() { # check_rule_refs <被查的 md，相对 ROOT> <@ 之后的前缀> <rules 目录> <sop|template|project>
  local md_rel="$1" prefix="$2" rules_dir="$3" which="$4" on_disk referenced missing extra
  on_disk="$(find "$rules_dir" -maxdepth 1 -name '*.md' -printf '%f\n' | sort)"
  referenced="$(grep -oE "@${prefix//./\\.}[A-Za-z0-9._-]+\.md" "$ROOT/$md_rel" | sed 's|.*/||' | sort -u || true)"
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
# 反对过、对方仍然坚持，那条警告要留下来（rules/pushback-discipline.md）。
# 门禁看不见对话，只能查写下来的这一半：文件名按日期、每个小节四项齐全。
# 只写一半的记录，三个月后照样没法重新判——那时想问的正是「当初的依据是什么」。
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
  warn "  D kb 的上下文指代与自指称呼"
  warn "  I 文风（翻译腔 / 古风腔 / 过度解释）"
  howto "要补就在 scripts/doc-lint.sh 的 PATTERNS 与 ctx/self 里加本语言的词表，" \
        "并在 scripts/fixtures/doc-lint/ 下配该语言的红样本与踩边界的绿样本。" \
        "在那之前这两类违规不会被拦——绿灯不代表这两条验过了。"
fi
if [[ $fails -gt 0 || $reffails -gt 0 || $numfails -gt 0 || $exfails -gt 0 || $metafails -gt 0 ]]; then
  bad "文档铁律检查失败：$fails 个文件违规、$reffails 处编号引用无定义、$numfails 处编号定义/引用不合规、$exfails 条排除项不合规、$metafails 处规则清单/警告记录不合规（检查 $checked，跳过 $skipped）"   # gate-lint:summary
  exit 1
fi
warn "上下文指代与自指称呼这两条是**启发式**：只认句首或标点之后的常见说法，"
warn "  「按本决策办」这种嵌在句中的漏得掉。绿不代表这两条穷举过了。"
ok "文档铁律检查通过（检查 $checked，跳过 $skipped；DOC_LINT_VERBOSE=1 看全部）"
