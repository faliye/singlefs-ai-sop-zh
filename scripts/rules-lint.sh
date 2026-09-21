#!/usr/bin/env bash
# 规则文件只写怎么做，不写历史与原因（rules/rules-discipline.md）。
#
# 扫 rules/*.md：本包自己的，或项目用 RULES_LINT_DIR 交进来的那一份。
# 规则会被整篇读进每一轮工作的上下文，论证与经过混在里面，执行的人和模型要先分辨
# 哪一句是命令、哪一句是背景——所以这条做成会红的检查，不做成提醒句（rules/sop-first.md）。
#
# 判七条，任一条不成立判红：
#   ① 记录小节：标题剥掉编号之后整串就是「历史版本」「变更史」「历史记录」「历史」。
#   ② 论证小节：标题剥掉编号之后以「为什么」「理由」「由来」「怎么来的」「原因」起头。
#   ③ 带日期的行：「」引号与反引号之外出现 `20\d\d-\d\d(-\d\d)?`。
#      不认：「」里的日期（引一条小节名时名字里自带的日期是引用，不是记录）；
#      反引号里的日期（判据的起算日、路径与文件名里的日期是参数，不是叙述）。
#   ④ 解释性段落：段落的头一行（剥掉列表记号、`>`、`**`、⚠️ 之后）以下面三类之一开头——
#      日期；标签词 为什么 / 依据 / 理由 / 实测 / 经过 / 原因 / 来历 / 背景 / 历史 / 沿革 / 前情，
#      后面紧跟 ：:（(，,。、 空白或「是」；连词 因为 / 之所以。
#   ⑤ 解释性半句：行内在 （(，,；;。 或 —— 之后（中间可隔空白与一个日期）紧接着
#      实测 / 试跑 / 踩过 / 撞上 / 撞过、因为 / 之所以，或 为什么 / 依据 / 理由 / 原因 / 经过 后跟 ：:或空白。
#      段落中间的一行若按 ④ 的认法起头，也记在这一条里。
#   ⑥ 词法说明：「实测」后八个字以内跟数字；「今天」后跟数字；
#      （(，,；;。：: 或 —— 之后紧接着 免得 / 以免 / 为了 / 所以。
#   ⑦ 指向历史的链接没带劝阻句：Markdown 链接（`](…)`）指向 `records/` 或 `CHANGELOG.md`，
#      而同一行没有「别读」或「不要读」。反引号里的路径不判，那是在说明落点。
#      读的人和模型默认跟着链接走，跟过去就把刚分出去的东西又装回了上下文。
#
# 都不判的：围栏（``` 或 ~~~）里的行；表格行（以 | 起头）不判 ④ ⑤ ⑥，① ② ③ ⑦ 照判。
# 判不到的：这几条只认上面写的字面。不在标点之后的因果、括注与冒号引出的为什么、
# 表格单元格里的解释，都认不出；论证小节的标题不以那几个词起头时（「第三类为什么危险」）也认不出——
# 那一半靠人念一遍和 review。
#
# 还没回扫完的文件逐个登记进 <项目根>/.claude/rules-lint-exclude：一行一条路径，
# `#` 后面写理由，理由不许省。指向不存在的文件、或一个文件都没排到，都判红。
#
#   bash scripts/rules-lint.sh [项目根]
#   RULES_LINT_DIR=<规则目录> bash scripts/rules-lint.sh <项目根>
#   RULES_LINT_FILES="<文件或 glob> …"：规则目录之外还要扫的文件，空格分隔，每项当 glob 展开。
#   CLAUDE.md、agents/*.md、skills/*/SKILL.md 走这一路：它们和规则一样是照着执行的，
#   不纳入射程就会重新腐烂。
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_ROOT="$(cd "$SCRIPTS/.." && pwd)"
ROOT="${1:-$PACKAGE_ROOT}"
[[ -d "$ROOT" ]] || die "找不到项目根：$ROOT" \
  "把项目根作为第一个参数传进来： bash scripts/rules-lint.sh <项目根>"
if [[ "$ROOT" != "/" ]]; then ROOT="${ROOT%/}"; fi
SCAN="${RULES_LINT_DIR:-$PACKAGE_ROOT/rules}"
[[ -d "$SCAN" ]] || die "找不到规则目录：$SCAN" \
  "项目的规则目录不在默认位置时，用 RULES_LINT_DIR 指过去： RULES_LINT_DIR=.claude/rules bash scripts/rules-lint.sh ."

# 判据的词表是中文的。别的语言仓硬套只会把误判堆上来，所以显式报未实现，不假装通过
# （rules/show-me-test.md：门禁不许假装通过）。语言看本包的 I18N。
PACKAGE_LANGUAGE="$(sed -n 's/^this=//p' "$PACKAGE_ROOT/I18N" 2>/dev/null || true)"
if [[ -n "$PACKAGE_LANGUAGE" && "$PACKAGE_LANGUAGE" != zh ]]; then
  echo "  ! 规则纪律的判据只有中文词表，本包语言是 $PACKAGE_LANGUAGE —— 这一项未实现，不记通过"
  echo "     → 怎么办：要在这个语言上生效，先给它写一套词表并配判别力样本，再把语言加进 rules-lint.sh 的判定。"
  exit 77
fi

# 使用这套 SOP 的项目叫什么，登记在**被扫那个仓**的 I18N 的 consumers= 里——
# 上游脚本不写死下游的名字。读 $ROOT 的 I18N 而不是本包的：项目根没有 I18N，
# 所以项目拿 RULES_LINT_DIR 扫自己的规则时这一条无对象可判（项目写自己的名字是正常的）。
CONSUMERS="$(sed -n 's/^consumers=//p' "$ROOT/I18N" 2>/dev/null || true)"
PACKAGE_FAMILY="$(sed -n 's/^family=//p' "$ROOT/I18N" 2>/dev/null || true)"

RULES_LINT_SCAN="$SCAN" RULES_LINT_ROOT="$ROOT" RULES_LINT_FILES="${RULES_LINT_FILES:-}" \
  RULES_LINT_CONSUMERS="$CONSUMERS" RULES_LINT_FAMILY="$PACKAGE_FAMILY" python3 - <<'PY'
import glob, os, re, sys

scan = os.path.realpath(os.environ["RULES_LINT_SCAN"])
root = os.path.realpath(os.environ["RULES_LINT_ROOT"])
targets = sorted(os.path.realpath(p) for p in glob.glob(os.path.join(scan, "*.md")))
for pattern in os.environ.get("RULES_LINT_FILES", "").split():
    for extra in sorted(glob.glob(os.path.join(root, pattern))):
        resolved = os.path.realpath(extra)
        if os.path.isfile(resolved) and resolved not in targets:
            targets.append(resolved)
if not targets:
    print(f"  ! {scan} 下一个 .md 都没有，本阶段无对象可判")
    sys.exit(77)

# ── 排除清单 ────────────────────────────────────────────
exclude_path = os.path.join(root, ".claude", "rules-lint-exclude")
excluded, exclude_problems = {}, []
if os.path.isfile(exclude_path):
    for number, raw in enumerate(open(exclude_path, encoding="utf-8").read().split("\n"), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        path, _, reason = line.partition("#")
        path, reason = path.strip(), reason.strip()
        if not path:
            continue
        if not reason:
            exclude_problems.append(f"{exclude_path}:{number}：「{path}」没写理由")
            continue
        full = os.path.realpath(os.path.join(root, path))
        if not os.path.isfile(full):
            exclude_problems.append(f"{exclude_path}:{number}：「{path}」指向的文件不存在")
            continue
        excluded[full] = reason

skipped = [t for t in targets if t in excluded]
scanned_targets = [t for t in targets if t not in excluded]
unused = [os.path.relpath(p, root) for p in excluded if p not in set(targets)]
for path in unused:
    exclude_problems.append(f"{exclude_path}：「{path}」不在本次扫描范围里，一个文件都没排到")

# ── 判据 ────────────────────────────────────────────────
DATE = re.compile(r"20\d\d-\d\d(?:-\d\d)?")
QUOTED = re.compile(r"「[^「」]*」")
INLINE_CODE = re.compile(r"`[^`]*`")
HEADING = re.compile(r"^\s{0,3}#{1,6}\s+(.*)$")
FENCE = re.compile(r"^\s*(?:```|~~~)")
TABLE = re.compile(r"^\s*\|")
LIST_MARKER = re.compile(r"^[\s>]*(?:[-*+]\s+|\d+[a-z]?\s*[.)、]\s*)")
DECORATION = re.compile(r"^(?:[\s>*_`~]|⚠️|⚠|✗|✓|！|!)+")
HEADING_NUMBER = re.compile(r"^\s*(?:\d+[a-z]?\s*[.)、]\s*|[一二三四五六七八九十]+[、.]\s*)")
HISTORY_HEADINGS = ["历史版本", "变更史", "历史记录", "历史"]
ARGUMENT_HEADINGS = ["为什么", "理由", "由来", "怎么来的", "原因"]
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
]
HISTORY_LINK = re.compile(r"\]\([^)]*(?:records/|CHANGELOG\.md)")
DISCOURAGEMENT = re.compile(r"别读|不要读")

def without_quoted(text):
    previous = None
    while previous != text:
        previous, text = text, QUOTED.sub("", text)
    return text

def paragraph_opener(first_line):
    text = DECORATION.sub("", LIST_MARKER.sub("", first_line, count=1))
    if DATE.match(text):
        return "日期"
    for word in PARAGRAPH_CONJUNCTIONS:
        if text.startswith(word):
            return word
    for word in PARAGRAPH_LABELS:
        if text.startswith(word):
            rest = text[len(word):]
            if rest == "" or rest[0] in PARAGRAPH_LABEL_DELIMITERS:
                return word
    return None

CONSUMER_NAMES = [n for n in os.environ.get("RULES_LINT_CONSUMERS", "").split() if n]
FAMILY = os.environ.get("RULES_LINT_FAMILY", "")

history_sections, argument_sections, dated_lines_found = [], [], []
explanatory_paragraphs, explanatory_half_sentences = [], []
lexical_explanations, bare_links, consumer_mentions = [], [], []
scanned_lines = dated_only_in_quotes = lexical_lines = 0

for path in scanned_targets:
    relative = os.path.relpath(path, root)
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
        location = f"{relative}:{index + 1}"
        unquoted_line = without_quoted(line)
        heading = HEADING.match(line)
        if heading:
            title = HEADING_NUMBER.sub("", heading.group(1)).strip().strip("「」*`").strip()
            if title in HISTORY_HEADINGS:
                history_sections.append(f"{location}：{line.strip()}")
            for word in ARGUMENT_HEADINGS:
                if title.startswith(word):
                    argument_sections.append(f"{location}（以「{word}」起头）：{line.strip()}")
                    break
        if DATE.search(line):
            if DATE.search(INLINE_CODE.sub("", unquoted_line)):
                dated_lines_found.append(f"{location}：{line.strip()[:90]}")
            else:
                dated_only_in_quotes += 1
        if not breaks_paragraph[index] and not starts_paragraph[index]:
            opener = paragraph_opener(line)
            if opener:
                explanatory_half_sentences.append(f"{location}（段落中间一行以「{opener}」起头）：{line.strip()[:90]}")
        if not breaks_paragraph[index]:
            for match in HALF_SENTENCE.finditer(unquoted_line):
                start = max(0, match.start() - 12)
                explanatory_half_sentences.append(f"{location}（「{match.group(1)}」）：…{unquoted_line[start:match.end() + 24].strip()}…")
        if not TABLE.match(line):
            lexical_lines += 1
            for kind, pattern in LEXICAL_EXPLANATIONS:
                for match in pattern.finditer(unquoted_line):
                    start = max(0, match.start() - 12)
                    lexical_explanations.append(f"{location}（{kind}「{match.group(0).strip()}」）：…{unquoted_line[start:match.end() + 24].strip()}…")
        if HISTORY_LINK.search(line) and not DISCOURAGEMENT.search(line):
            bare_links.append(f"{location}：{line.strip()[:90]}")
        # ⑧ 使用者项目的名字：本包名（family）先整串挖掉，剩下的还出现就是在写下游的东西
        if CONSUMER_NAMES:
            stripped = line.replace(FAMILY, "") if FAMILY else line
            for name in CONSUMER_NAMES:
                if name in stripped:
                    consumer_mentions.append(f"{location}（「{name}」）：{line.strip()[:90]}")
                    break
    index = 0
    while index < len(lines):
        if not starts_paragraph[index]:
            index += 1
            continue
        end = index + 1
        while end < len(lines) and not breaks_paragraph[end] and not starts_paragraph[end]:
            end += 1
        opener = paragraph_opener(lines[index])
        if opener:
            explanatory_paragraphs.append(f"{os.path.relpath(path, root)}:{index + 1}（以「{opener}」起头，{end - index} 行）：{lines[index].strip()[:90]}")
        index = end

# ── 判决 ────────────────────────────────────────────────
MOVE_HINT = "删掉（共享规则的历史进 CHANGELOG.md 一版一节；项目本地规则的经过进项目已有的 records/、kb/）"
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
       f"把这一节整段{MOVE_HINT}，正文里删掉这一节；",
       "共享规则的历史进 CHANGELOG.md（rules/rules-discipline.md 第 5 条）。")
report(argument_sections, "个论证小节（标题以「为什么」「理由」「由来」「怎么来的」「原因」起头）：",
       f"把这一节整段{MOVE_HINT}；",
       "里面那句判得出该不该做的，改写成判据留在正文（rules/rules-discipline.md 第 2 条）。")
report(dated_lines_found, "行写了日期——规矩没有日期，日期属于案卷：",
       f"把这一句的经过{MOVE_HINT}，正文只留该怎么做；",
       "日期是引的小节名的一部分，就把小节名放进「」里原样引；判据的起算日、路径里的日期放进反引号。")
report(explanatory_paragraphs, "处解释性段落（以日期、「为什么」「依据」「实测」「经过」「因为」这类起头）：",
       f"把这一段{MOVE_HINT}；",
       "是要读的规则或 kb，改成一条读取指令「开工先读：`文件`「小节」」。")
report(explanatory_half_sentences, "处解释性半句（指令后面挂着「实测」「因为」「依据」这类尾巴）：",
       "指令留下，尾巴删掉；",
       f"尾巴里的经过{MOVE_HINT}。")
report(lexical_explanations, "处词法说明（「实测」「今天」后跟数、标点后的「免得」「以免」「为了」「所以」）：",
       f"数与经过删掉，要留的{MOVE_HINT}；",
       "执行者要照它分支的前提不删，改写成一条指令（条件 → 动作）。")
report(consumer_mentions, "处写了使用这套 SOP 的项目的名字——规范是给任何使用者读的，正文里不许出现某一个使用者：",
       "把那半句删掉，或者改写成不指名的说法：接法写成「项目在 `.claude/gate.d/` 里接一个本地阶段」，",
       "实测来历整句删掉（规则正文本来就不写来历）。名单在 I18N 的 consumers=。")

report(bare_links, "处指向历史的链接没带劝阻句：",
       "在同一行写上「除非要查来历，别读它。」——劝阻句写成「别读」或「不要读」，一字不许省；",
       "指的不是历史，就别链到 records/ 或 CHANGELOG.md。")

if failed:
    sys.exit(1)

skipped_names = [os.path.relpath(p, root) for p in skipped]
skipped_text = "；没扫 0 个" if not skipped_names else \
    f"；没扫 {len(skipped_names)} 个（登记在 .claude/rules-lint-exclude）：{'、'.join(skipped_names)}"
consumer_text = ("使用者名字 0 处（名单：" + "、".join(CONSUMER_NAMES) + "）") if CONSUMER_NAMES \
    else "使用者名字这一条无对象可判：被扫的仓没有 I18N 或没登记 consumers="
print(f"  ✓ 规则只写怎么做（扫了 {len(scanned_targets)} 份文件 {scanned_lines} 行{skipped_text}；"
      f"记录小节 0、论证小节 0、带日期的行 0（另有 {dated_only_in_quotes} 行的日期只在「」或反引号里）、"
      f"解释性段落 0、解释性半句 0、没带劝阻句的链接 0；词法说明判了 {lexical_lines} 行（围栏与表格行不判），命中 0；"
      f"{consumer_text}）")
PY
