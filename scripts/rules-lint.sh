#!/usr/bin/env bash
# admission: always 判的是此刻全仓的文本，几秒跑完；每一轮门禁都现判，上一轮的结论不替这一轮作保
# run-condition: command python3
# 规则文件只写怎么做，不写历史与原因（rules/rules-discipline.md）。
#
# 扫 rules/*.md（本包的，或 RULES_LINT_DIR 给的目录）与 RULES_LINT_FILES 点名的文件，判七条，任一条成立判红：
#   记录小节、论证小节：看标题剥掉编号之后的字面。
#   带日期的行：「」与反引号里的日期不算（引的小节名自带日期是引用，起算日、路径里的日期是参数）。
#   解释性段落、解释性半句、词法说明：词表在 PARAGRAPH_LABELS 到 LEXICAL_EXPLANATIONS 那几个常量。
#   没带劝阻句的历史链接：链到 records/ 或 CHANGELOG.md 而同一行没有劝阻句；读的人默认跟着链接走，跟过去就把分出去的历史又装回上下文。反引号里的路径不判。
# 围栏里的行不判；表格行不判解释性段落、解释性半句与词法说明。认不出的（不在标点之后的因果、表格里的解释、不以那几个词起头的论证标题）靠 review。
#
# 语言按本包 I18N 的 this= 取，词表在 WORDS_BY_LANGUAGE。英文、日文判记录小节、论证小节、带日期的行与没带劝阻句的历史链接，解释性段落与半句只认「标签词加冒号」；
# 连词起头、标点后的连词与词法说明认的是汉语句式，照翻误判比真违规多，由 --not-impl 报未实现，不假装通过。
# RULES_LINT_LANG 只给门禁自证用（样本的语言是样本的属性，不是仓的属性），设了就自报。
#
# 还没回扫完的文件登记进 <项目根>/.claude/rules-lint-exclude：一行一条「路径  # 理由」；理由为空、指向不存在的文件、一个都没排到，都判红。
#
# 退出码：0 通过；1 判红；77 无对象可判，或本语言没有词表。
#
#   bash scripts/rules-lint.sh [项目根]
#   bash scripts/rules-lint.sh --not-impl    本包的语言上这一项没实现时打一行说明（gate.sh 收进汇总的未实现清单），实现了什么都不打；都退 0
#   RULES_LINT_DIR=<规则目录> bash scripts/rules-lint.sh <项目根>
#   RULES_LINT_FILES="<文件或 glob> …"：规则目录之外还要扫的文件，空格分隔，每项当 glob 展开。
#   CLAUDE.md、agents/*.md、skills/*/SKILL.md 走这一路：它们和规则一样是照着执行的，
#   不纳入射程就会重新腐烂。
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight "${BASH_SOURCE[0]}" "$@"; set -- ${PREFLIGHT_ARGUMENTS[@]+"${PREFLIGHT_ARGUMENTS[@]}"}

PACKAGE_SCRIPTS_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_ROOT="$(cd "$PACKAGE_SCRIPTS_DIRECTORY/.." && pwd)"
PACKAGE_LANGUAGE="$(sed -n 's/^this=//p' "$PACKAGE_ROOT/I18N" 2>/dev/null | head -1 || true)"
RULES_LANGUAGE="${PACKAGE_LANGUAGE:-zh}"
RULES_LANGUAGE_FORCED=0
if [[ -n "${RULES_LINT_LANG:-}" ]]; then RULES_LANGUAGE="$RULES_LINT_LANG"; RULES_LANGUAGE_FORCED=1; fi
case "$RULES_LANGUAGE" in
  zh)    RULES_NOT_IMPLEMENTED="" ;;
  en|ja) RULES_NOT_IMPLEMENTED="规则纪律（$RULES_LANGUAGE）：解释性段落与半句只认「标签词加冒号」这一种；以连词起头的、标点后的连词与词法说明只有中文词表，本语言未实现" ;;
  *)     RULES_NOT_IMPLEMENTED="规则纪律（$RULES_LANGUAGE）：本语言没有词表，这一项未实现" ;;
esac
if [[ "${1:-}" == --not-impl ]]; then
  if [[ -n "$RULES_NOT_IMPLEMENTED" ]]; then echo "$RULES_NOT_IMPLEMENTED"; fi
  exit 0
fi
PROJECT_ROOT="${1:-$PACKAGE_ROOT}"
[[ -d "$PROJECT_ROOT" ]] || die "找不到项目根：$PROJECT_ROOT" \
  "把项目根作为第一个参数传进来： bash scripts/rules-lint.sh <项目根>"
if [[ "$PROJECT_ROOT" != "/" ]]; then PROJECT_ROOT="${PROJECT_ROOT%/}"; fi
RULES_DIRECTORY="${RULES_LINT_DIR:-$PACKAGE_ROOT/rules}"
[[ -d "$RULES_DIRECTORY" ]] || die "找不到规则目录：$RULES_DIRECTORY" \
  "项目的规则目录不在默认位置时，用 RULES_LINT_DIR 指过去： RULES_LINT_DIR=.claude/rules bash scripts/rules-lint.sh ."

if [[ $RULES_LANGUAGE_FORCED -eq 1 ]]; then
  warn "语言由 RULES_LINT_LANG 指定为 $RULES_LANGUAGE（本包是 ${PACKAGE_LANGUAGE:-zh}）——这个变量只给门禁自证用"
  howto "跑真实项目不要设它：判据换成别的语言，等于自己给自己改判据。" \
        "要让本包换语言，改 I18N 的 this=，别在命令行上盖。"
fi
case "$RULES_LANGUAGE" in
  zh|en|ja) ;;
  *)
    echo "  ! 规则纪律没有 $RULES_LANGUAGE 的词表 —— 这一项未实现，不记通过"
    echo "     → 怎么办：要在这个语言上生效，先给它写一套词表并配判别力样本，再把语言加进 rules-lint.sh 的 WORDS_BY_LANGUAGE。"
    exit 77 ;;
esac

RULES_LINT_SCAN="$RULES_DIRECTORY" RULES_LINT_ROOT="$PROJECT_ROOT" RULES_LINT_FILES="${RULES_LINT_FILES:-}" \
  RULES_LINT_LANGUAGE="$RULES_LANGUAGE" python3 - <<'PY'
import glob, os, re, sys

rules_directory = os.path.realpath(os.environ["RULES_LINT_SCAN"])
project_root = os.path.realpath(os.environ["RULES_LINT_ROOT"])
targets = sorted(os.path.realpath(rule_path) for rule_path in glob.glob(os.path.join(rules_directory, "*.md")))
for pattern in os.environ.get("RULES_LINT_FILES", "").split():
    for extra in sorted(glob.glob(os.path.join(project_root, pattern))):
        resolved = os.path.realpath(extra)
        if os.path.isfile(resolved) and resolved not in targets:
            targets.append(resolved)
if not targets:
    print(f"  ! {rules_directory} 下一个 .md 都没有，本阶段无对象可判")
    sys.exit(77)

# ── 排除清单 ────────────────────────────────────────────
exclude_path = os.path.join(project_root, ".claude", "rules-lint-exclude")
excluded, exclude_problems = {}, []
if os.path.isfile(exclude_path):
    for line_number, raw_line in enumerate(open(exclude_path, encoding="utf-8").read().split("\n"), 1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        path, _, reason = line.partition("#")
        path, reason = path.strip(), reason.strip()
        if not path:
            continue
        if not reason:
            exclude_problems.append(f"{exclude_path}:{line_number}：「{path}」没写理由")
            continue
        resolved_excluded_path = os.path.realpath(os.path.join(project_root, path))
        if not os.path.isfile(resolved_excluded_path):
            exclude_problems.append(f"{exclude_path}:{line_number}：「{path}」指向的文件不存在")
            continue
        excluded[resolved_excluded_path] = reason

skipped = [target for target in targets if target in excluded]
scanned_targets = [target for target in targets if target not in excluded]
unused_exclusions = [os.path.relpath(excluded_path, project_root) for excluded_path in excluded if excluded_path not in set(targets)]
for path in unused_exclusions:
    exclude_problems.append(f"{exclude_path}：「{path}」不在本次扫描范围里，一个文件都没排到")

# ── 判据 ────────────────────────────────────────────────
# 英文按整词、不分大小写认：「Reasoning…」不算「Reason」。
LANGUAGE = os.environ["RULES_LINT_LANGUAGE"]
WORDS_BY_LANGUAGE = {
    "zh": {
        "history_headings": ["历史版本", "变更史", "历史记录", "历史"],
        "argument_heading": re.compile(r"为什么|理由|由来|怎么来的|原因"),
        "argument_words": "「为什么」「理由」「由来」「怎么来的」「原因」",
        "quoted": re.compile(r"「[^「」]*」"),
        "discouragement": re.compile(r"别读|不要读"),
        "discouragement_example": "「除非要查来历，别读它。」——劝阻句写成「别读」或「不要读」",
        "prose_checks": True,
        "label_explanation": None,
    },
    "en": {
        "history_headings": ["revision history", "change history", "version history", "changelog", "history"],
        "argument_heading": re.compile(r"(?:why|rationale|reasons?|origins?|how (?:it|this) came about|causes?)\b", re.IGNORECASE),
        "argument_words": "「Why」「Rationale」「Reason」「Origin」「How it came about」「Cause」",
        "quoted": re.compile(r'「[^「」]*」|"[^"]*"|“[^”]*”'),
        "discouragement": re.compile(r"\bdo not read\b", re.IGNORECASE),
        "discouragement_example": "「Do not read it unless you are tracing where this came from.」——劝阻句写成「do not read」",
        "prose_checks": False,
        # 标签词首字母大写才算：段首与句末标点之后的标签都是大写起头的，小写的 why / history 多半是句子里的普通词
        "label_explanation": re.compile(r"(?:^[\s>*+\-\d.)]*|[.;!?)]\s+|—\s*)(?:\*\*)?(Observed|Measured|Basis|Background|Rationale|History|Why|Reason|Evidence|Origin)(?:\*\*)?\s*:"),
        "label_words": "「Observed:」「Measured:」「Basis:」「Why:」",
    },
    "ja": {
        "history_headings": ["改訂履歴", "変更履歴", "履歴記録", "変更史", "履歴"],
        "argument_heading": re.compile(r"なぜ|理由|由来|経緯|成り立ち|原因"),
        "argument_words": "「なぜ」「理由」「由来」「経緯」「成り立ち」「原因」",
        "quoted": re.compile(r"「[^「」]*」"),
        "discouragement": re.compile(r"読むな"),
        "discouragement_example": "「由来を辿る用でなければ読むな。」——劝阻句写成「読むな」",
        "prose_checks": False,
        "label_explanation": re.compile(r"(?:^[\s>*+\-\d.)]*|[。；！？）)]|——)\s*(?:\*\*)?(実測|経緯|根拠|背景|由来|理由|なぜ|来歴|沿革)(?:\*\*)?\s*[：:]"),
        "label_words": "「実測：」「経緯：」「根拠：」「なぜ：」",
    },
}
WORDS = WORDS_BY_LANGUAGE[LANGUAGE]
HISTORY_HEADINGS = WORDS["history_headings"]
ARGUMENT_HEADING = WORDS["argument_heading"]
QUOTED = WORDS["quoted"]
DISCOURAGEMENT = WORDS["discouragement"]
PROSE_CHECKS = WORDS["prose_checks"]
LABEL_EXPLANATION = WORDS["label_explanation"]
DATE = re.compile(r"20\d\d-\d\d(?:-\d\d)?")
INLINE_CODE = re.compile(r"`[^`]*`")
HEADING = re.compile(r"^\s{0,3}#{1,6}\s+(.*)$")
FENCE = re.compile(r"^\s*(?:```|~~~)")
TABLE = re.compile(r"^\s*\|")
LIST_MARKER = re.compile(r"^[\s>]*(?:[-*+]\s+|\d+[a-z]?\s*[.)、]\s*)")
DECORATION = re.compile(r"^(?:[\s>*_`~]|⚠️|⚠|✗|✓|！|!)+")
HEADING_NUMBER = re.compile(r"^\s*(?:\d+[a-z]?\s*[.)、]\s*|[一二三四五六七八九十]+[、.]\s*)")
PARAGRAPH_LABELS = ["为什么", "依据", "理由", "实测", "经过", "原因", "来历", "背景", "历史", "沿革", "前情"]
PARAGRAPH_CONJUNCTIONS = ["因为", "之所以"]
PARAGRAPH_LABEL_DELIMITERS = "：:（(，,。、 \t是"
HALF_SENTENCE = re.compile(
    r"(?:[（(，,；;。]|——)\s*(?:20\d\d-\d\d(?:-\d\d)?\s*)?"
    r"(实测|试跑|踩过|撞上|撞过|因为|之所以|(?:为什么|依据|理由|原因|经过)(?=[：:\s]))"
)
LEXICAL_EXPLANATIONS = [
    ("「实测」后跟数", re.compile(r"实测[^，。；,;（）()「」]{0,8}\d")),
    ("「今天」后跟数", re.compile(r"今天\s*\d")),
    ("标点后的目的或因果", re.compile(r"(?:[（(，,；;。：:]|——)\s*(?:免得|以免|为了|所以)")),
    # 「计划第 <序号> 节」：计划增删一节序号就指到别处，又不带路径，读的人跟不过去。
    ("不带路径的「计划第 <序号> 节」", re.compile(r"计划第[一二三四五六七八九十]+节")),
    # 「否则」后面跟动作（「否则归 harness 档」「否则退 0」）是条件分支，照留；跟后果（会、没区别、不是）才是论证
    ("「否则」「不然」后跟后果", re.compile(r"(?:否则|不然)[^，。；,;]{0,15}?(?:会|没区别|等于|不是|白跑|白做|看不出|分不出|证明不了)")),
    ("论证与来历的固定说法", re.compile(r"病根|算一遍就知道|差别不在|早晚(?!高峰)|没人知道|三个月后|第一次记|第一次写成|用户原话|用户当天|当天质疑")),
]
HISTORY_LINK = re.compile(r"\]\([^)]*(?:records/|CHANGELOG\.md)")

def without_quoted(text):
    previous = None
    while previous != text:
        previous, text = text, QUOTED.sub("", text)
    return text

def paragraph_opener(first_line):
    # 反引号里的是在举字段名、写法（「`**依据**：` 只写指针」），不是这一段自己的标签，先挖掉；与带日期的行豁免反引号同一个口径
    text = DECORATION.sub("", LIST_MARKER.sub("", INLINE_CODE.sub("", first_line), count=1))
    if DATE.match(text):
        return "日期"
    for word in PARAGRAPH_CONJUNCTIONS:
        if text.startswith(word):
            return word
    for word in PARAGRAPH_LABELS:
        if text.startswith(word):
            # 「**为什么**：」：标签词自己加了粗体，收尾的星号跳过再看冒号
            text_after_label = text[len(word):].lstrip("*")
            if text_after_label == "" or text_after_label[0] in PARAGRAPH_LABEL_DELIMITERS:
                return word
    return None

history_sections, argument_sections, dated_lines_found = [], [], []
explanatory_paragraphs, explanatory_half_sentences = [], []
lexical_explanations, bare_links = [], []
scanned_lines = dated_only_in_quotes = lexical_lines = 0

for path in scanned_targets:
    relative_path = os.path.relpath(path, project_root)
    lines = open(path, encoding="utf-8").read().split("\n")
    in_fence = False
    fenced = [False] * len(lines)
    breaks_paragraph = [False] * len(lines)
    for index, line in enumerate(lines):
        if FENCE.match(line):
            fenced[index] = breaks_paragraph[index] = True
            in_fence = not in_fence
        elif in_fence:
            fenced[index] = breaks_paragraph[index] = True
        elif not line.strip() or HEADING.match(line) or TABLE.match(line):
            breaks_paragraph[index] = True
    starts_paragraph = [
        not breaks_paragraph[index] and (index == 0 or breaks_paragraph[index - 1] or bool(LIST_MARKER.match(line)))
        for index, line in enumerate(lines)
    ]
    for index, line in enumerate(lines):
        if fenced[index]:
            continue
        scanned_lines += 1
        location = f"{relative_path}:{index + 1}"
        unquoted_line = without_quoted(line)
        heading = HEADING.match(line)
        if heading:
            title = HEADING_NUMBER.sub("", heading.group(1)).strip().strip("「」*`").strip()
            if title.casefold() in HISTORY_HEADINGS:
                history_sections.append(f"{location}：{line.strip()}")
            argument_opener = ARGUMENT_HEADING.match(title)
            if argument_opener:
                argument_sections.append(f"{location}（以「{argument_opener.group(0)}」起头）：{line.strip()}")
        if DATE.search(line):
            if DATE.search(INLINE_CODE.sub("", unquoted_line)):
                dated_lines_found.append(f"{location}：{line.strip()[:90]}")
            else:
                dated_only_in_quotes += 1
        if PROSE_CHECKS and not breaks_paragraph[index] and not starts_paragraph[index]:
            opener = paragraph_opener(line)
            if opener:
                explanatory_half_sentences.append(f"{location}（段落中间一行以「{opener}」起头）：{line.strip()[:90]}")
        if LABEL_EXPLANATION is not None and not breaks_paragraph[index]:
            for match in LABEL_EXPLANATION.finditer(INLINE_CODE.sub("", unquoted_line)):
                explanatory_half_sentences.append(f"{location}（标签「{match.group(1)}」加冒号）：{line.strip()[:90]}")
        if PROSE_CHECKS and not breaks_paragraph[index]:
            for match in HALF_SENTENCE.finditer(unquoted_line):
                excerpt_start = max(0, match.start() - 12)
                explanatory_half_sentences.append(f"{location}（「{match.group(1)}」）：…{unquoted_line[excerpt_start:match.end() + 24].strip()}…")
        if PROSE_CHECKS and not TABLE.match(line):
            lexical_lines += 1
            for kind, pattern in LEXICAL_EXPLANATIONS:
                for match in pattern.finditer(unquoted_line):
                    excerpt_start = max(0, match.start() - 12)
                    lexical_explanations.append(f"{location}（{kind}「{match.group(0).strip()}」）：…{unquoted_line[excerpt_start:match.end() + 24].strip()}…")
        if HISTORY_LINK.search(line) and not DISCOURAGEMENT.search(line):
            bare_links.append(f"{location}：{line.strip()[:90]}")
    index = 0
    while PROSE_CHECKS and index < len(lines):
        if not starts_paragraph[index]:
            index += 1
            continue
        paragraph_end = index + 1
        while paragraph_end < len(lines) and not breaks_paragraph[paragraph_end] and not starts_paragraph[paragraph_end]:
            paragraph_end += 1
        opener = paragraph_opener(lines[index])
        if opener:
            explanatory_paragraphs.append(f"{relative_path}:{index + 1}（以「{opener}」起头，{paragraph_end - index} 行）：{lines[index].strip()[:90]}")
        index = paragraph_end

# ── 判决 ────────────────────────────────────────────────
MOVE_HINT = "删掉，不另立落点（rules/rules-discipline.md 第 3 条；共享规则的历史进 CHANGELOG.md，一版一节）"
failed = False

def report(entries, summary, *steps):
    global failed
    if not entries:
        return
    failed = True
    print(f"  ✗ {len(entries)} {summary}")  # gate-lint:summary
    for entry in entries:
        print(f"     {entry}")  # gate-lint:detail
    print(f"     → 怎么办：{steps[0]}")
    for step in steps[1:]:
        print(f"               {step}")

report(exclude_problems, "条排除项不合规（.claude/rules-lint-exclude）：",
       "每条排除写成「路径 # 理由」，路径指向真实的规则文件，理由不许省；",
       "文件已经回扫完就把那一行删掉——排除只缩不涨。")
report(history_sections, "个记录小节（标题带「历史」或「变更史」）——规则是执行用的，不是说明：",
       f"把这一节整段{MOVE_HINT}；",
       "规则文件不留历史节（rules/rules-discipline.md 第 5 条）。")
report(argument_sections, f"个论证小节（标题以{WORDS['argument_words']}这类论证词起头）：",
       f"把这一节整段{MOVE_HINT}；",
       "里面那句判得出该不该做的，改写成判据留在正文（rules/rules-discipline.md 第 2 条）。")
report(dated_lines_found, "行写了日期——规矩不写日期：",
       f"把这一句的经过{MOVE_HINT}，正文只留该怎么做；",
       "日期是引的小节名的一部分，就把小节名放进「」里原样引；判据的起算日、路径里的日期放进反引号。")
report(explanatory_paragraphs, "处解释性段落（以日期、「为什么」「依据」「实测」「经过」「因为」这类起头）：",
       f"把这一段{MOVE_HINT}；",
       "是要读的规则或 kb，改成一条读取指令「开工先读：`文件`「小节」」。")
report(explanatory_half_sentences, "处解释性半句（指令后面挂着「实测」「因为」「依据」这类尾巴，或者英文、日文里段首与句末标点之后的"
       + (WORDS["label_words"] if LABEL_EXPLANATION is not None else "「Observed:」「実測：」") + "这类标签）：",
       "指令留下，尾巴删掉；",
       f"尾巴里的经过{MOVE_HINT}。")
report(lexical_explanations, "处词法说明（「实测」「今天」后跟数、标点后的「免得」「以免」「为了」「所以」、「否则」「不然」后跟后果，以及「病根」「早晚」「第一次记」「用户原话」这类论证与来历的固定说法）：",
       f"数与经过{MOVE_HINT}；",
       "执行者要照它分支的前提不删，改写成一条指令（条件 → 动作）。")
report(bare_links, "处指向历史的链接没带劝阻句：",
       f"在同一行写上{WORDS['discouragement_example']}，一字不许省；",
       "指的不是历史，就别链到 records/ 或 CHANGELOG.md。")

if failed:
    sys.exit(1)

skipped_names = [os.path.relpath(skipped_path, project_root) for skipped_path in skipped]
skipped_text = "；没扫 0 个" if not skipped_names else \
    f"；没扫 {len(skipped_names)} 个（登记在 .claude/rules-lint-exclude）：{'、'.join(skipped_names)}"
prose_text = (f"解释性段落 0、解释性半句 0、没带劝阻句的链接 0；词法说明判了 {lexical_lines} 行（围栏与表格行不判），命中 0；"
              if PROSE_CHECKS else
              f"标签式解释 0、没带劝阻句的链接 0；以连词起头的段落与半句、词法说明在 {LANGUAGE} 上未实现，没判；")
print(f"  ✓ 规则只写怎么做（语言 {LANGUAGE}；扫了 {len(scanned_targets)} 份文件 {scanned_lines} 行{skipped_text}；"
      f"记录小节 0、论证小节 0、带日期的行 0（另有 {dated_only_in_quotes} 行的日期只在引号或反引号里）、"
      f"{prose_text.rstrip('；')}）")
PY
