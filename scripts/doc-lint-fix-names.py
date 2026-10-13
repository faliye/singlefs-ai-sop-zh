#!/usr/bin/env python3
# admission: always 每一次调都按此刻的登记位补此刻那几份文件里的引用，上一次的结论不替这一次作保
# run-condition: none 只读写点名的 Markdown 文件，除了 python3 之外没有环境要求
"""kb 里缺简称的编号引用，按登记位补成「编号（简称）」（rules/kb-discipline.md 第 5 条）。只补、不判：对不对仍由 doc-lint.sh 判。

用法：
    doc-lint-fix-names.py <文件.md> … [--registry-root <目录>]… [--dry-run]
        登记位从这些目录下的全部 .md 收：给了 --registry-root（可以给几次）就只收给的；
        没给就收当前目录（项目根）的 .claude/kb-directories 登记的全部目录（与 doc-lint.sh 同一份判法：lib.sh 的 kb_directories），
        没登记就收 .claude/kb
    doc-lint-fix-names.py --selftest
弄坏开关（DOC_LINT_FIX_NAMES_BREAK，只给自证用；打开后 --selftest 必须判红）：
    touch-registry          登记位那一行也补            → 「登记标题那一行不动」那一项红
    ignore-not-numbers      不认 not-numbers 声明        → 「not-numbers 声明过的 Z3」那一项红
    ignore-local            不认页内定义                  → 「页内表格首列定义了 C120」那一项红
    ignore-kb-directories   不读 .claude/kb-directories   → 「登记在 .claude/kb-directories 里的目录」那一项红

登记位只认 doc-lint.sh 认的两种（与它判登记位的那一段同一份判法）：
    表格上方单独一行 <!-- doc-lint:registry name-col=N -->，该表每行首列的编号即登记位，简称取第 N 列；
    登记标题 `## D1 <简称> —— 已定`，简称取编号之后、破折号之前那一段。
补哪些：正文里（围栏代码块之外、历史节也算）孤零零的编号——后面没有紧跟「（」或「(」的；编号的形状与 doc-lint.sh 同：[A-Z]+-?[0-9]+([.][0-9]+)*。
不补：登记位所在的那一行（登记标题行、登记表的行）；一个编号在登记位里有多处、或没有登记位的（那是 doc-lint 该红的事，不替它遮）；
      前面紧挨着字母、数字、`-`、`.`、`_`、`/` 的（`-D1`、`e57_field`、路径里的）；
      登记目录里被 <!-- doc-lint:not-numbers … --> 声明成术语的；
      要补的那一页自己像在定义它的（围栏与登记表之外，表格行首列就是它，或行首写成「N1：」「**N1**:」「N1 =」）：这一页的编号整页不补，列成补不了，由人判是页内局部名（改名）还是全局编号（手补）。
退出码：0 补完（或没有要补的）；1 有编号补不了（登记多处或没登记，逐个列出）；2 用法错、文件不在。
"""
import glob
import os
import re
import shutil
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
from preflight import preflight  # noqa: E402

ENABLED_BREAK_SWITCH = os.environ.get("DOC_LINT_FIX_NAMES_BREAK", "")
NUMBER_IDENTIFIER_PATTERN = r"[A-Z]+-?[0-9]+(?:[.][0-9]+)*"
NUMBER_IDENTIFIER = re.compile(NUMBER_IDENTIFIER_PATTERN)
REFERENCE_WITHOUT_SHORT_NAME = re.compile(r"(?<![A-Za-z0-9_./\-])(" + NUMBER_IDENTIFIER_PATTERN + r")(?![A-Za-z0-9_\-.（(])")
REGISTRY_MARK = re.compile(r"<!--\s*doc-lint:registry(?:\s+name-col=(\d+))?\s*-->")
HEADING_REGISTRY = re.compile(r"^#+\s*(" + NUMBER_IDENTIFIER_PATTERN + r")[ \t](.*?)(?:——|—)")
CODE_FENCE = re.compile(r"^[ \t]*```")
NOT_NUMBERS_DECLARATION = re.compile(r"<!--\s*doc-lint:not-numbers([^>]*)-->")
# 一行表格按 "|" 切开之后，首列（编号那一列）落在这个下标：行首的 "|" 前面切出一个空串
NUMBER_COLUMN_INDEX = 1
LOCAL_DEFINITION_LINE = re.compile(r"^[ \t]*(?:[-*+][ \t]+)?(?:\*\*)?(" + NUMBER_IDENTIFIER_PATTERN + r")(?:\*\*)?[ \t]*[：:=]")


def registry_of(registry_files):
    """→ ({编号: 简称} 只含登记恰好一次的, {编号: 次数} 登记多处的, {(文件, 行号)} 登记位所在的行)。"""
    short_names_by_identifier, registry_line_positions = {}, set()
    for path in registry_files:
        try:
            lines = open(path, encoding="utf-8", errors="replace").read().split("\n")
        except OSError:
            continue
        in_fence = in_table = False
        name_column = 2
        for line_number, line in enumerate(lines, 1):
            if CODE_FENCE.match(line):
                in_fence = not in_fence
                continue
            if in_fence:
                continue
            registry_mark = REGISTRY_MARK.search(line)
            if registry_mark:
                in_table, name_column = True, int(registry_mark.group(1) or 2)
                continue
            if in_table:
                if not line.strip():
                    continue
                if not line.startswith("|"):
                    in_table = False
                else:
                    cells = [cell.strip() for cell in line.split("|")]
                    # split("|") 之后下标 NUMBER_COLUMN_INDEX 是首列（编号）、下标 k 是第 k 列：与 doc-lint.sh 里 awk 取首列与简称列的下标同一格
                    if len(cells) > name_column and NUMBER_IDENTIFIER.fullmatch(cells[NUMBER_COLUMN_INDEX] or ""):
                        short_names_by_identifier.setdefault(cells[NUMBER_COLUMN_INDEX], []).append(cells[name_column])
                        registry_line_positions.add((os.path.abspath(path), line_number))
                    continue
            registry_heading = HEADING_REGISTRY.match(line)
            if registry_heading:
                short_names_by_identifier.setdefault(registry_heading.group(1), []).append(registry_heading.group(2).strip())
                registry_line_positions.add((os.path.abspath(path), line_number))
    short_name_by_identifier = {identifier: short_names[0] for identifier, short_names in short_names_by_identifier.items() if len(short_names) == 1}
    duplicated_registration_counts = {identifier: len(short_names) for identifier, short_names in short_names_by_identifier.items() if len(short_names) > 1}
    return short_name_by_identifier, duplicated_registration_counts, registry_line_positions


def declared_not_numbers(registry_files):
    """→ {编号形状的记号} 登记目录里 <!-- doc-lint:not-numbers … --> 声明成术语的（围栏里的不算，与 doc-lint.sh 同）。"""
    declared = set()
    if ENABLED_BREAK_SWITCH == "ignore-not-numbers":
        return declared
    for path in registry_files:
        try:
            lines = open(path, encoding="utf-8", errors="replace").read().split("\n")
        except OSError:
            continue
        in_fence = False
        for line in lines:
            if CODE_FENCE.match(line):
                in_fence = not in_fence
                continue
            if in_fence:
                continue
            for match in NOT_NUMBERS_DECLARATION.finditer(line):
                declared.update(match.group(1).split())
    return declared


def locally_defined(text):
    """→ {编号} 这一页自己像在定义的：围栏与登记表之外，表格行首列就是它，或行首写成「N1：」「**N1**:」「N1 =」。"""
    locally_defined_identifiers = set()
    in_fence = in_registry = False
    for line in text.split("\n"):
        if CODE_FENCE.match(line):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        if REGISTRY_MARK.search(line):
            in_registry = True
            continue
        if in_registry and line.strip() and not line.startswith("|"):
            in_registry = False
        if line.startswith("|"):
            cells = [cell.strip().strip("*`") for cell in line.split("|")]
            if not in_registry and len(cells) > NUMBER_COLUMN_INDEX and NUMBER_IDENTIFIER.fullmatch(cells[NUMBER_COLUMN_INDEX] or ""):
                locally_defined_identifiers.add(cells[NUMBER_COLUMN_INDEX])
            continue
        definition_match = LOCAL_DEFINITION_LINE.match(line)
        if definition_match:
            locally_defined_identifiers.add(definition_match.group(1))
    return locally_defined_identifiers


def short_name_spans(line):
    """→ [(起, 止)] 这一行里紧跟在编号后面的「（简称）」括注，按全角括号配对；没闭合的算到行尾。
    括注里的编号是那条简称的一部分，补了就与登记位对不上（doc-lint 判「名字不符」）。"""
    spans = []
    for match in re.finditer("(" + NUMBER_IDENTIFIER_PATTERN + r")（", line):
        start = match.end() - 1
        bracket_depth, end = 0, len(line)
        for character_index in range(start, len(line)):
            if line[character_index] == "（":
                bracket_depth += 1
            elif line[character_index] == "）":
                bracket_depth -= 1
                if bracket_depth == 0:
                    end = character_index + 1
                    break
        spans.append((start, end))
    return spans


CODE_SPAN = re.compile(r"`[^`\n]+`")


def code_spans(line):
    """→ [(起, 止)] 行内反引号包着的一段（含两端的反引号）；反引号数是奇数的行不认任何一段。"""
    if line.count("`") % 2:
        return []
    return [(match.start(), match.end()) for match in CODE_SPAN.finditer(line)]


def fixed_text(path, text, short_name_by_identifier, duplicated_registration_counts, registry_line_positions, not_numbers=frozenset()):
    """→ (改后的文本, 补了几处, [补不了的编号], [页内像有定义、没补的编号])。
    反引号里的编号是命令或路径的一段，简称不能补进去：编号是那一段最后一个词时，简称补在闭合反引号后面
    （`replay.sh E1`（简称）——doc-lint 认这一形态）；夹在中间的不动、列成补不了。"""
    output_lines, fixed_count, unfixable_identifiers = [], 0, []
    locally_defined_identifiers = locally_defined(text) if ENABLED_BREAK_SWITCH != "ignore-local" else set()
    in_fence = False
    for line_number, line in enumerate(text.split("\n"), 1):
        if CODE_FENCE.match(line):
            in_fence = not in_fence
            output_lines.append(line)
            continue
        if in_fence or ((os.path.abspath(path), line_number) in registry_line_positions and ENABLED_BREAK_SWITCH != "touch-registry"):
            output_lines.append(line)
            continue
        protected_spans = short_name_spans(line)
        code_span_ranges = code_spans(line)
        edits = []   # (起, 止, 换成什么)，止 == 起 的是插入
        for match in REFERENCE_WITHOUT_SHORT_NAME.finditer(line):
            identifier = match.group(1)
            if identifier in not_numbers or identifier in locally_defined_identifiers:
                continue
            if any(start <= match.start() < end for start, end in protected_spans):
                continue
            enclosing_code_spans = [(start, end) for start, end in code_span_ranges if start <= match.start() < end]
            if enclosing_code_spans:
                start, end = enclosing_code_spans[0]
                if identifier not in short_name_by_identifier:
                    continue
                if line[match.end():end - 1].strip() != "":
                    unfixable_identifiers.append(identifier)
                elif not line[end:].startswith("（"):
                    edits.append((end, end, f"（{short_name_by_identifier[identifier]}）"))
                    fixed_count += 1
                continue
            if identifier in short_name_by_identifier:
                edits.append((match.start(), match.end(), f"{identifier}（{short_name_by_identifier[identifier]}）"))
                fixed_count += 1
            elif identifier in duplicated_registration_counts or re.match(r"^[A-Z]{1,2}-?\d", identifier):
                unfixable_identifiers.append(identifier)
        for start, end, replacement in sorted(edits, reverse=True):
            line = line[:start] + replacement + line[end:]
        output_lines.append(line)
    referenced_identifiers = {match.group(1) for match in REFERENCE_WITHOUT_SHORT_NAME.finditer(text)}
    skipped_as_local = sorted(identifier for identifier in locally_defined_identifiers & referenced_identifiers
                              if identifier not in not_numbers and (identifier in short_name_by_identifier or identifier in duplicated_registration_counts))
    return "\n".join(output_lines), fixed_count, sorted(set(unfixable_identifiers)), skipped_as_local


def registered_kb_directories(project_root):
    """→ [绝对路径] 项目 .claude/kb-directories 登记的目录，调 lib.sh 的 kb_directories（与 doc-lint.sh 同一份判法）；登记写坏了抛 RuntimeError。"""
    library_script_path = os.path.join(os.path.dirname(os.path.realpath(__file__)), "lib.sh")
    kb_directories_run = subprocess.run(["bash", "-c", 'source "$1" && kb_directories "$2"', "_", library_script_path, project_root],
                            capture_output=True, text=True)
    if kb_directories_run.returncode != 0:
        raise RuntimeError((kb_directories_run.stdout + kb_directories_run.stderr).strip())
    return [line for line in kb_directories_run.stdout.split("\n") if line.strip()]


def default_registry_roots(project_root):
    registered_directories = registered_kb_directories(project_root) if ENABLED_BREAK_SWITCH != "ignore-kb-directories" else []
    return registered_directories if registered_directories else [os.path.join(project_root, ".claude", "kb")]


def run(paths, registry_roots, dry_run):
    registry_files = sorted({path for registry_root in registry_roots
                             for path in glob.glob(os.path.join(registry_root, "**", "*.md"), recursive=True)})
    short_name_by_identifier, duplicated_registration_counts, registry_line_positions = registry_of(registry_files)
    not_numbers = declared_not_numbers(registry_files)
    if not short_name_by_identifier:
        print(f"  ✗ {'、'.join(registry_roots)} 下一处登记位都没找到\n  → 怎么办：--registry-root 给放决策、实验、欠账表的 kb 目录，或在 .claude/kb-directories 登记它们")
        return 2
    total_fixed, problems = 0, []
    for path in paths:
        if not os.path.isfile(path):
            print(f"  ✗ 文件不在：{path}\n  → 怎么办：给存在的 Markdown 文件")
            return 2
        text = open(path, encoding="utf-8", errors="replace").read()
        new_text, fixed_count, unfixable_identifiers, skipped_as_local = fixed_text(path, text, short_name_by_identifier, duplicated_registration_counts, registry_line_positions, not_numbers)
        total_fixed += fixed_count
        for identifier in unfixable_identifiers:
            problems.append(f"{path}：{identifier} " + ("登记了多处，补不了" if identifier in duplicated_registration_counts else "没有登记位，补不了"))
        for identifier in skipped_as_local:
            problems.append(f"{path}：{identifier} 这一页自己像在定义它（表格首列或行首「{identifier}：」），整页没补；"
                            f"是页内局部名就改个不与全局编号同形的名字，是全局编号就手补「{identifier}（{short_name_by_identifier.get(identifier, '简称')}）」")
        if fixed_count and not dry_run and new_text != text:
            temporary_file = tempfile.NamedTemporaryFile("w", dir=os.path.dirname(path) or ".", delete=False, encoding="utf-8")
            temporary_file.write(new_text)
            temporary_file.close()
            shutil.copymode(path, temporary_file.name)
            os.replace(temporary_file.name, path)
        print(f"  {'会补' if dry_run else '补了'} {fixed_count} 处：{path}")
    for problem in problems:
        print(f"  ✗ {problem}")   # gate-lint:detail
    if problems:
        print(f"  → 怎么办：没登记的先在 kb 里登记（登记表或带破折号的登记标题），重复的登记位收成一处，页内局部名按上面各行处理，再跑一次")
        return 1
    print(f"  ✓ {len(paths)} 份文件共{'会补' if dry_run else '补了'} {total_fixed} 处缺简称的引用（登记位 {len(short_name_by_identifier)} 个）")
    return 0


def selftest():
    scratch_directory = tempfile.mkdtemp(prefix="doc-lint-fix-names-selftest-")
    failures, checked_count = [], 0
    try:
        kb_directory = os.path.join(scratch_directory, "kb")
        os.makedirs(os.path.join(kb_directory, "decisions"))
        open(os.path.join(kb_directory, "decisions", "01-data-mobility.md"), "w", encoding="utf-8").write("## D1 数据可移动性 —— 已定\n\n正文提到 D1 自己不补。\n")
        open(os.path.join(kb_directory, "checks-owed.md"), "w", encoding="utf-8").write(
            "# 欠账\n\n<!-- doc-lint:registry name-col=2 -->\n| 编号 | 简称 | 说明 |\n|---|---|---|\n| C120 | 撤回没回扫 | x |\n| C121 | 又一条 | y |\n")
        note_path = os.path.join(kb_directory, "note.md")
        open(note_path, "w", encoding="utf-8").write(
            "# 笔记\n\n按 D1 与 C120 办；D1（数据可移动性） 已经带了；路径 kb/decisions/01-D1.md 与 e57_field 不动；-D1 不动。\n\n```\nD1 在代码块里不动\n```\n\nX9 没登记。\n")
        short_name_by_identifier, duplicated_registration_counts, registry_line_positions = registry_of(sorted(glob.glob(os.path.join(kb_directory, "**", "*.md"), recursive=True)))
        checked_count += 1
        if short_name_by_identifier.get("D1") != "数据可移动性" or short_name_by_identifier.get("C120") != "撤回没回扫" or short_name_by_identifier.get("C121") != "又一条":
            failures.append(f"登记位应当收到 D1、C120、C121，实际 {short_name_by_identifier}")
        text = open(note_path, encoding="utf-8").read()
        new_text, fixed_count, unfixable_identifiers, _ = fixed_text(note_path, text, short_name_by_identifier, duplicated_registration_counts, registry_line_positions)
        checked_count += 1
        expected_note_line = "按 D1（数据可移动性） 与 C120（撤回没回扫） 办；D1（数据可移动性） 已经带了；路径 kb/decisions/01-D1.md 与 e57_field 不动；-D1 不动。"
        if fixed_count != 2 or expected_note_line not in new_text or "D1 在代码块里不动" not in new_text or "D1（数据可移动性）（" in new_text:
            failures.append(f"应当只补两处、不碰带简称的、路径里的、代码块里的，实际补 {fixed_count}：\n{new_text}")
        checked_count += 1
        if unfixable_identifiers != ["X9"]:
            failures.append(f"没登记的 X9 应当列成补不了，实际 {unfixable_identifiers}")
        registry_path = os.path.join(kb_directory, "decisions", "01-data-mobility.md")
        registry_text = open(registry_path, encoding="utf-8").read()
        registry_fixed_text, registry_fixed_count, _, _ = fixed_text(registry_path, registry_text, short_name_by_identifier, duplicated_registration_counts, registry_line_positions)
        checked_count += 1
        if "## D1 数据可移动性 —— 已定" not in registry_fixed_text or registry_fixed_count != 1:
            failures.append(f"登记标题那一行不动、正文里的 D1 补一处，实际补 {registry_fixed_count}：\n{registry_fixed_text}")
        code_path = os.path.join(kb_directory, "code.md")
        code_text = "复跑 `bash replay.sh C120` 与 `C121_ROOT=1 run`，别碰 `run C121 now` 与 `已带 C120`（撤回没回扫）。\n"
        code_fixed_text, code_fixed_count, code_unfixable, _ = fixed_text(code_path, code_text, short_name_by_identifier, duplicated_registration_counts, registry_line_positions)
        checked_count += 1
        if (code_fixed_text != "复跑 `bash replay.sh C120`（撤回没回扫） 与 `C121_ROOT=1 run`，别碰 `run C121 now` 与 `已带 C120`（撤回没回扫）。\n"
                or code_fixed_count != 1 or code_unfixable != ["C121"]):
            failures.append(f"反引号里收尾的编号把简称补到闭合反引号后面、夹在中间的列成补不了、标识符里的与已带的不动，实际补 {code_fixed_count}、补不了 {code_unfixable}：\n{code_fixed_text}")
        nested_path = os.path.join(kb_directory, "nested.md")
        nested_text = "引 C121（D1 之后的又一条） 与 D1。\n"
        nested_fixed_text, nested_fixed_count, _, _ = fixed_text(nested_path, nested_text, short_name_by_identifier, duplicated_registration_counts, registry_line_positions)
        checked_count += 1
        if nested_fixed_text != "引 C121（D1 之后的又一条） 与 D1（数据可移动性）。\n" or nested_fixed_count != 1:
            failures.append(f"别的编号的简称括注里的 D1 不动、括注外的 D1 补一处，实际补 {nested_fixed_count}：\n{nested_fixed_text}")
        open(os.path.join(kb_directory, "terms.md"), "w", encoding="utf-8").write("# 术语\n\n<!-- doc-lint:not-numbers Z3 -->\n")
        registry_files = sorted(glob.glob(os.path.join(kb_directory, "**", "*.md"), recursive=True))
        not_numbers = declared_not_numbers(registry_files)
        terms_fixed_text, terms_fixed_count, terms_unfixable, _ = fixed_text(os.path.join(kb_directory, "terms-reference.md"), "求解用 Z3，按 D1 办。\n", short_name_by_identifier, duplicated_registration_counts, registry_line_positions, not_numbers)
        checked_count += 1
        if terms_unfixable or terms_fixed_count != 1 or "Z3（" in terms_fixed_text:
            failures.append(f"not-numbers 声明过的 Z3 不补也不列成补不了、D1 照补，实际补 {terms_fixed_count}、补不了 {terms_unfixable}：\n{terms_fixed_text}")
        local_text = "# 实验页\n\n| 臂 | 做法 |\n|---|---|\n| C120 | 本页的一条臂 |\n\nC120 胜出，按 D1 办。\n"
        local_fixed_text, local_fixed_count, _, local_skipped = fixed_text(os.path.join(kb_directory, "experiment-page.md"), local_text, short_name_by_identifier, duplicated_registration_counts, registry_line_positions)
        checked_count += 1
        if local_skipped != ["C120"] or "C120（" in local_fixed_text or local_fixed_count != 1:
            failures.append(f"页内表格首列定义了 C120：整页不补它、列成页内定义，D1 照补，实际补 {local_fixed_count}、页内定义 {local_skipped}：\n{local_fixed_text}")
        project_root = os.path.join(scratch_directory, "project")
        moved_kb_directory = os.path.join(project_root, "crates", "checker", "invariants")
        os.makedirs(moved_kb_directory)
        os.makedirs(os.path.join(project_root, ".claude", "kb"))
        open(os.path.join(project_root, ".claude", "kb-directories"), "w", encoding="utf-8").write(
            "crates/checker/invariants  # 不变量跟着检查器放\n.claude/kb  # 其余照旧\n")
        registry_roots_found = default_registry_roots(project_root)
        checked_count += 1
        if os.path.realpath(moved_kb_directory) not in {os.path.realpath(registry_root) for registry_root in registry_roots_found}:
            failures.append(f"登记在 .claude/kb-directories 里的目录应当收进登记位来源，实际 {registry_roots_found}")
    finally:
        shutil.rmtree(scratch_directory, ignore_errors=True)
    for failure in failures:
        print(f"  ✗ 自证：{failure}")   # gate-lint:detail
    if failures:
        print("    → 怎么办：看 registry_of() 与 fixed_text()；DOC_LINT_FIX_NAMES_BREAK=touch-registry 设着的话这里本来就该红")
        return 1
    print(f"  ✓ 自证通过（查了 {checked_count} 项）：两种登记位都认；登记目录照 .claude/kb-directories 收；not-numbers 声明过的不补不列；页内自己定义的编号整页不补、列出来；孤零零的编号补简称，带简称的、别的编号简称括注里的、路径与标识符里的、代码块里的、登记位那一行不动；反引号里收尾的编号把简称补到闭合反引号后面，夹在中间的与没登记的列成补不了")
    return 0


def main(arguments):
    if arguments[:1] == ["--selftest"]:
        return selftest()
    paths, registry_roots, dry_run = [], [], False
    remaining_arguments = list(arguments)
    while remaining_arguments:
        argument = remaining_arguments.pop(0)
        if argument == "--registry-root" and remaining_arguments:
            registry_roots.append(remaining_arguments.pop(0))
        elif argument == "--dry-run":
            dry_run = True
        elif argument.startswith("--"):
            print(f"  ✗ 认不出参数 {argument}\n  → 怎么办：只认 --registry-root <目录> 与 --dry-run")
            return 2
        else:
            paths.append(argument)
    if not paths:
        print("  ✗ 没给要补的文件\n  → 怎么办：doc-lint-fix-names.py <文件.md> … [--registry-root <目录>] [--dry-run]")
        return 2
    if not registry_roots:
        try:
            registry_roots = default_registry_roots(os.getcwd())
        except RuntimeError as error:
            print(f"  ✗ 读不了 .claude/kb-directories：{error}\n  → 怎么办：照上面那句改好登记，或用 --registry-root 显式给登记目录")
            return 2
    return run(paths, registry_roots, dry_run)


if __name__ == "__main__":
    preflight(__file__)
    sys.exit(main(sys.argv[1:]))
