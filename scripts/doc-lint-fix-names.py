#!/usr/bin/env python3
# admission: always 每一次调都按此刻的登记位补此刻那几份文件里的引用，上一次的结论不替这一次作保
# run-condition: none 只读写点名的 Markdown 文件，除了 python3 之外没有环境要求
"""kb 里缺简称的编号引用，按登记位补成「编号（简称）」（rules/kb-discipline.md 第 5 条）。只补、不判：对不对仍由 doc-lint.sh 判。

用法：
    doc-lint-fix-names.py <文件.md> … [--registry-root <目录>] [--dry-run]   # 登记位从 --registry-root（默认仓根的 .claude/kb）下全部 .md 收
    doc-lint-fix-names.py --selftest                                        # DOC_LINT_FIX_NAMES_BREAK=touch-registry 时必须判红

登记位只认 doc-lint.sh 认的两种（与它 F 那一格同一份判法）：
    表格上方单独一行 <!-- doc-lint:registry name-col=N -->，该表每行首列的编号即登记位，简称取第 N 列；
    登记标题 `## D1 数据可移动性 —— 已定`，简称取编号之后、破折号之前那一段。
补哪些：正文里（围栏代码块之外、历史节也算）孤零零的编号——后面没有紧跟「（」或「(」的；编号的形状与 doc-lint.sh 同：[A-Z]+-?[0-9]+([.][0-9]+)*。
不补：登记位所在的那一行（登记标题行、登记表的行）；一个编号在登记位里有多处、或没有登记位的（那是 doc-lint 该红的事，不替它遮）；
      前面紧挨着字母、数字、`-`、`.`、`_`、`/` 的（`-D1`、`e57_field`、路径里的）。
为什么：使用者项目 2026-09-20 起 8 天里 doc-lint 判红 496 次，红行七成是缺简称，而补简称是查表就能做的机械活。
退出码：0 补完（或没有要补的）；1 有编号补不了（登记多处或没登记，逐个列出）；2 用法错、文件不在。
"""
import glob
import os
import re
import shutil
import sys
import tempfile

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
from preflight import preflight  # noqa: E402

BROKEN = os.environ.get("DOC_LINT_FIX_NAMES_BREAK", "")
ID = r"[A-Z]+-?[0-9]+(?:[.][0-9]+)*"
ID_RE = re.compile(ID)
REFERENCE = re.compile(r"(?<![A-Za-z0-9_./\-])(" + ID + r")(?![A-Za-z0-9_\-.（(])")
REGISTRY_MARK = re.compile(r"<!--\s*doc-lint:registry(?:\s+name-col=(\d+))?\s*-->")
HEADING_REGISTRY = re.compile(r"^#+\s*(" + ID + r")[ \t](.*?)(?:——|—)")
FENCE = re.compile(r"^[ \t]*```")


def registry_of(files):
    """→ ({编号: 简称} 只含登记恰好一次的, {编号: 次数} 登记多处的, {(文件, 行号)} 登记位所在的行)。"""
    seen, positions = {}, set()
    for path in files:
        try:
            lines = open(path, encoding="utf-8", errors="replace").read().split("\n")
        except OSError:
            continue
        in_fence = in_table = False
        name_column = 2
        for number, line in enumerate(lines, 1):
            if FENCE.match(line):
                in_fence = not in_fence
                continue
            if in_fence:
                continue
            mark = REGISTRY_MARK.search(line)
            if mark:
                in_table, name_column = True, int(mark.group(1) or 2)
                continue
            if in_table:
                if not line.strip():
                    continue
                if not line.startswith("|"):
                    in_table = False
                else:
                    cells = [cell.strip() for cell in line.split("|")]
                    # split("|") 之后 cells[1] 是首列（编号）、cells[k] 是第 k 列：与 doc-lint.sh 里 awk 的 c[2] / c[ncol+1] 同一格
                    if len(cells) > name_column and ID_RE.fullmatch(cells[1] or ""):
                        seen.setdefault(cells[1], []).append(cells[name_column])
                        positions.add((os.path.abspath(path), number))
                    continue
            heading = HEADING_REGISTRY.match(line)
            if heading:
                seen.setdefault(heading.group(1), []).append(heading.group(2).strip())
                positions.add((os.path.abspath(path), number))
    unique = {identifier: names[0] for identifier, names in seen.items() if len(names) == 1}
    duplicated = {identifier: len(names) for identifier, names in seen.items() if len(names) > 1}
    return unique, duplicated, positions


def short_name_spans(line):
    """→ [(起, 止)] 这一行里紧跟在编号后面的「（简称）」括注，按全角括号配对；没闭合的算到行尾。
    括注里的编号是那条简称的一部分，补了就与登记位对不上（doc-lint 判「名字不符」）。"""
    spans = []
    for match in re.finditer("(" + ID + r")（", line):
        start = match.end() - 1
        depth, end = 0, len(line)
        for index in range(start, len(line)):
            if line[index] == "（":
                depth += 1
            elif line[index] == "）":
                depth -= 1
                if depth == 0:
                    end = index + 1
                    break
        spans.append((start, end))
    return spans


def fixed_text(path, text, unique, duplicated, positions):
    """→ (改后的文本, 补了几处, [补不了的编号])。"""
    out, fixed, unfixable = [], 0, []
    in_fence = False
    for number, line in enumerate(text.split("\n"), 1):
        if FENCE.match(line):
            in_fence = not in_fence
            out.append(line)
            continue
        if in_fence or ((os.path.abspath(path), number) in positions and BROKEN != "touch-registry"):
            out.append(line)
            continue
        protected_spans = short_name_spans(line)
        def replace(match):
            nonlocal fixed
            identifier = match.group(1)
            if any(start <= match.start() < end for start, end in protected_spans):
                return identifier
            if identifier in unique:
                fixed += 1
                return f"{identifier}（{unique[identifier]}）"
            if identifier in duplicated or (identifier not in unique and re.match(r"^[A-Z]{1,2}-?\d", identifier)):
                unfixable.append(identifier)
            return identifier
        out.append(REFERENCE.sub(replace, line))
    return "\n".join(out), fixed, sorted(set(unfixable))


def run(paths, registry_root, dry_run):
    registry_files = sorted(glob.glob(os.path.join(registry_root, "**", "*.md"), recursive=True))
    unique, duplicated, positions = registry_of(registry_files)
    if not unique:
        print(f"  ✗ {registry_root} 下一处登记位都没找到\n  → 怎么办：--registry-root 给放决策、实验、欠账表的 kb 目录")
        return 2
    total_fixed, problems = 0, []
    for path in paths:
        if not os.path.isfile(path):
            print(f"  ✗ 文件不在：{path}\n  → 怎么办：给存在的 Markdown 文件")
            return 2
        text = open(path, encoding="utf-8", errors="replace").read()
        new_text, fixed, unfixable = fixed_text(path, text, unique, duplicated, positions)
        total_fixed += fixed
        for identifier in unfixable:
            problems.append(f"{path}：{identifier} " + ("登记了多处，补不了" if identifier in duplicated else "没有登记位，补不了"))
        if fixed and not dry_run and new_text != text:
            handle = tempfile.NamedTemporaryFile("w", dir=os.path.dirname(path) or ".", delete=False, encoding="utf-8")
            handle.write(new_text)
            handle.close()
            shutil.copymode(path, handle.name)
            os.replace(handle.name, path)
        print(f"  {'会补' if dry_run else '补了'} {fixed} 处：{path}")
    for problem in problems:
        print(f"  ✗ {problem}")   # gate-lint:detail
    if problems:
        print(f"  → 怎么办：这 {len(problems)} 个编号要先在 kb 里登记（登记表或带破折号的登记标题），或把重复的登记位收成一处，再跑一次")
        return 1
    print(f"  ✓ {len(paths)} 份文件共{'会补' if dry_run else '补了'} {total_fixed} 处缺简称的引用（登记位 {len(unique)} 个）")
    return 0


def selftest():
    work = tempfile.mkdtemp(prefix="doc-lint-fix-names-selftest-")
    failures, checked = [], 0
    try:
        kb = os.path.join(work, "kb")
        os.makedirs(os.path.join(kb, "decisions"))
        open(os.path.join(kb, "decisions", "01-x.md"), "w", encoding="utf-8").write("## D1 数据可移动性 —— 已定\n\n正文提到 D1 自己不补。\n")
        open(os.path.join(kb, "checks-owed.md"), "w", encoding="utf-8").write(
            "# 欠账\n\n<!-- doc-lint:registry name-col=2 -->\n| 编号 | 简称 | 说明 |\n|---|---|---|\n| C120 | 撤回没回扫 | x |\n| C121 | 又一条 | y |\n")
        target = os.path.join(kb, "note.md")
        open(target, "w", encoding="utf-8").write(
            "# 笔记\n\n按 D1 与 C120 办；D1（数据可移动性） 已经带了；路径 kb/decisions/01-D1.md 与 e57_field 不动；-D1 不动。\n\n```\nD1 在代码块里不动\n```\n\nX9 没登记。\n")
        unique, duplicated, positions = registry_of(sorted(glob.glob(os.path.join(kb, "**", "*.md"), recursive=True)))
        checked += 1
        if unique.get("D1") != "数据可移动性" or unique.get("C120") != "撤回没回扫" or unique.get("C121") != "又一条":
            failures.append(f"登记位应当收到 D1、C120、C121，实际 {unique}")
        text = open(target, encoding="utf-8").read()
        new_text, fixed, unfixable = fixed_text(target, text, unique, duplicated, positions)
        checked += 1
        wanted = "按 D1（数据可移动性） 与 C120（撤回没回扫） 办；D1（数据可移动性） 已经带了；路径 kb/decisions/01-D1.md 与 e57_field 不动；-D1 不动。"
        if fixed != 2 or wanted not in new_text or "D1 在代码块里不动" not in new_text or "D1（数据可移动性）（" in new_text:
            failures.append(f"应当只补两处、不碰带简称的、路径里的、代码块里的，实际补 {fixed}：\n{new_text}")
        checked += 1
        if unfixable != ["X9"]:
            failures.append(f"没登记的 X9 应当列成补不了，实际 {unfixable}")
        registry_path = os.path.join(kb, "decisions", "01-x.md")
        registry_text = open(registry_path, encoding="utf-8").read()
        registry_new, registry_fixed, _ = fixed_text(registry_path, registry_text, unique, duplicated, positions)
        checked += 1
        if "## D1 数据可移动性 —— 已定" not in registry_new or registry_fixed != 1:
            failures.append(f"登记标题那一行不动、正文里的 D1 补一处，实际补 {registry_fixed}：\n{registry_new}")
        nested_path = os.path.join(kb, "nested.md")
        nested_text = "引 C121（D1 之后的又一条） 与 D1。\n"
        nested_new, nested_fixed, _ = fixed_text(nested_path, nested_text, unique, duplicated, positions)
        checked += 1
        if nested_new != "引 C121（D1 之后的又一条） 与 D1（数据可移动性）。\n" or nested_fixed != 1:
            failures.append(f"别的编号的简称括注里的 D1 不动、括注外的 D1 补一处，实际补 {nested_fixed}：\n{nested_new}")
    finally:
        shutil.rmtree(work, ignore_errors=True)
    for failure in failures:
        print(f"  ✗ 自检：{failure}")   # gate-lint:detail
    if failures:
        print("    → 怎么办：看 registry_of() 与 fixed_text()；DOC_LINT_FIX_NAMES_BREAK=touch-registry 设着的话这里本来就该红")
        return 1
    print(f"  ✓ 自检通过（查了 {checked} 项）：两种登记位都认；孤零零的编号补简称，带简称的、别的编号简称括注里的、路径与标识符里的、代码块里的、登记位那一行不动；没登记的列成补不了")
    return 0


def main(argv):
    if argv[:1] == ["--selftest"]:
        return selftest()
    paths, registry_root, dry_run = [], None, False
    rest = list(argv)
    while rest:
        argument = rest.pop(0)
        if argument == "--registry-root" and rest:
            registry_root = rest.pop(0)
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
    if registry_root is None:
        registry_root = os.path.join(os.getcwd(), ".claude", "kb")
    return run(paths, registry_root, dry_run)


if __name__ == "__main__":
    preflight(__file__)
    sys.exit(main(sys.argv[1:]))
