#!/usr/bin/env python3
# gate-similar: doc-lint.sh 它判全仓 .md 此刻的样子（词表、位置指代、编号登记）；这一道只判相对 diff 基准新加的行，读的是 diff 窗口，输入不同，并进去要给它另起一套取基准与行号的路子
# gate-similar: number-name-sync.sh 它判登记过的编号在别处引用时带没带简称；这一道判的是没登记的代号被拿来当称呼，判据与对象都不同
# gate-similar: history-ordinal.sh 它也只判相对基准新加的行，但判历史条目的序号撞没撞；取基准共用 gate-overlap.py 的 resolve_diff_base 与 changed_lines_by_path，不另抄
# admission: always 判的是此刻相对 diff 基准新加的行，几秒跑完；每一轮门禁都现判
# run-condition: command git
"""进仓的文字里不拿代号指东西：「5a 交回」「9g 另报一处」「SC02」这类，读的人不知道它指什么。

用法：
    code-name-lint.py --check [仓库根]   # 判相对 diff 基准（GATE_DIFF_BASE，单跑时按 lib.sh 的 diff_base 现算）新加的 .md 行
    code-name-lint.py --selftest         # 自证：内嵌红绿样本逐个判；再逐个打开弄坏开关另起子进程跑自证，每一个都必须红在开关表点名的样本上

判据（rules/writing-discipline.md「不写缩写，不用代号指东西」）：新加的一行里独立成词的这两种形态 ⇒ 红：
  ① 数字接一个小写字母，可以再接几段 `-<小写字母或数字>`：`5a`、`10g`、`5g-rs`；科学计数（`1e-9`、`3e5`）不算；
  ② 两个大写字母接两位数字：`SC02`、`PF13`。
  「独立成词」只看前后是不是 ASCII 字母、数字、`_./-#@%$+`：`第10b批` 里的 `10b` 算，`v1.5a`、`sha256`、`#5a` 不算。
不判：围栏（```）里的行、反引号里的、HTML 注释里的（`<!-- doc-lint:not-numbers … -->` 这类声明）、Markdown 链接的目标与网址；
  指编号步骤的（「第 1b 步」「第 2a 条」「step 1b」「手順 1b」），那是有序清单里那一步自己的编号；项目根 `.claude/doc-lint-exclude` 登记的冻结证据；装进项目的本包副本。
登记：项目根 `.claude/code-names` 一行一条 `<正则>  # 理由`，代号整个匹配上某条正则就不判（项目自己的变异名、实验号这类编号体系）；
  正则写坏、理由不到 4 个字判红。

够不着的（不判，不等于通过）：代码注释与 .md 以外的文本；基准里已经有的行（只判新加的，存量不回扫）；
  别的形态的代号（三个以上字母接数字、带连字符的会话名这类）；写成全称但读的人照样不知道指什么的称呼。

CODE_NAME_LINT_BREAK=<开关名> 打开一个弄坏开关（自证专用，门禁里不许设），开关表见 BREAK_SWITCHES。

退出码：0 通过；1 有红（或自证失败、或判不了）；2 参数问题；77 不在 git 仓里，或这一次没有新加的 .md 行。
"""
from __future__ import annotations

import dataclasses
import os
import pathlib
import re
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
from preflight import load_package_module, preflight  # noqa: E402
GATE_OVERLAP = load_package_module("gate_overlap", "gate-overlap.py")
EVIDENCE_EXCLUDE = load_package_module("evidence_exclude", "evidence-exclude.py")
PACKAGE_FAMILY = load_package_module("package_family", "package-family.py")
SOURCE_FILES = load_package_module("source_files", "source-files.py")
BREAK_SWITCH_SELFTEST = load_package_module("break_switch_selftest", "break-switch-selftest.py")

REGISTRY_RELATIVE_PATH = os.path.join(".claude", "code-names")
MINIMUM_REASON_CHARACTERS = 4
EXIT_NOTHING_TO_JUDGE = 77
BREAK_ENVIRONMENT_VARIABLE = "CODE_NAME_LINT_BREAK"
# 弄坏开关 → 打开后自证必须红在哪个样本上
BREAK_SWITCHES = {
    "backticks-kept": "反引号里的代号放行",
    "fences-read": "围栏里的代号放行",
    "registry-ignored": "登记过的编号体系放行",
    "scientific-notation-flagged": "科学计数放行",
    "uppercase-shape-dropped": "两个大写字母接两位数字",
    "html-comments-read": "HTML 注释里的声明放行",
    "step-numbers-flagged": "指编号步骤的放行",
}

TOKEN_BOUNDARY_CHARACTERS = r"A-Za-z0-9_./\-#@%$+"
LOWERCASE_SUFFIX_CODE_NAME = re.compile(
    rf"(?<![{TOKEN_BOUNDARY_CHARACTERS}])[0-9]+[a-z](?:-[a-z0-9]+)*(?![{TOKEN_BOUNDARY_CHARACTERS}])")
UPPERCASE_PREFIX_CODE_NAME = re.compile(
    rf"(?<![{TOKEN_BOUNDARY_CHARACTERS}])[A-Z]{{2}}[0-9]{{2}}(?![{TOKEN_BOUNDARY_CHARACTERS}])")
SCIENTIFIC_NOTATION = re.compile(r"[0-9]+e-?[0-9]+")
BACKTICK_SPAN = re.compile(r"`[^`]*`")
MARKDOWN_LINK_TARGET = re.compile(r"\]\([^)]*\)")
WEB_ADDRESS = re.compile(r"[a-z]+://\S+")
HTML_COMMENT = re.compile(r"<!--.*?-->")
STEP_NUMBER_REFERENCE = re.compile(
    r"第\s*[0-9]+[a-z]\s*(?:步|条|节|项)|\b[Ss]teps?\s+[0-9]+[a-z]\b|(?:手順|ステップ)\s*[0-9]+[a-z]")
FENCE_LINE = re.compile(r"^\s*(```|~~~)")

CODE_NAME_REMEDY = (
    "代号只有起它的人知道指什么，读的人（别的会话、以后检索到这一行的模型）要么猜、要么去翻来源。"
    "改法：写出它是什么——「5a 交回」写成「<那一批改了什么>交回」，「SC02 红」写成「<那一格判的是什么>红」；"
    "是单位就写全（「60 秒」「2 KiB」「3 倍」）；确实要原样出现的（命令、文件名、产物里的键），放进反引号。"
    "项目自己有登记位的编号体系（变异名、实验号），在 .claude/code-names 登记一条匹配它的正则，写明是什么编号、登记在哪"
    "（rules/writing-discipline.md「不写缩写，不用代号指东西」）。"
)


class CannotJudge(Exception):
    def __init__(self, problem, next_step):
        super().__init__(problem)
        self.problem = problem
        self.next_step = next_step


@dataclasses.dataclass
class CodeNameHit:
    relative_path: str
    line_number: int
    code_name: str
    line_text: str


def break_switch() -> str:
    return os.environ.get(BREAK_ENVIRONMENT_VARIABLE, "")


def read_registry(project_root: str) -> tuple:
    """返回（编译好的正则列表，问题列表）。"""
    registry_path = os.path.join(project_root, REGISTRY_RELATIVE_PATH)
    patterns = []
    problems = []
    try:
        with open(registry_path, encoding="utf-8") as registry_file:
            registry_lines = registry_file.read().splitlines()
    except OSError:
        return patterns, problems
    for line_number, line_text in enumerate(registry_lines, start=1):
        stripped_line = line_text.strip()
        if not stripped_line or stripped_line.startswith("#"):
            continue
        pattern_text, separator, reason = stripped_line.partition("#")
        pattern_text = pattern_text.strip()
        reason = reason.strip()
        location = f"{REGISTRY_RELATIVE_PATH}:{line_number}"
        if not separator or len(reason) < MINIMUM_REASON_CHARACTERS:
            problems.append(f"{location} 没写理由或理由不到 {MINIMUM_REASON_CHARACTERS} 个字：{stripped_line}")
            continue
        try:
            patterns.append(re.compile(pattern_text))
        except re.error as regex_error:
            problems.append(f"{location} 正则写坏了（{regex_error}）：{pattern_text}")
    return patterns, problems


def judged_text(line_text: str) -> str:
    """挖掉不判的部分：反引号、HTML 注释、指编号步骤的、链接目标、网址。"""
    if break_switch() != "backticks-kept":
        line_text = BACKTICK_SPAN.sub(" ", line_text)
    if break_switch() != "html-comments-read":
        line_text = HTML_COMMENT.sub(" ", line_text)
    if break_switch() != "step-numbers-flagged":
        line_text = STEP_NUMBER_REFERENCE.sub(" ", line_text)
    line_text = MARKDOWN_LINK_TARGET.sub(" ", line_text)
    return WEB_ADDRESS.sub(" ", line_text)


def code_names_in_line(line_text: str, registered_patterns: list) -> list:
    text = judged_text(line_text)
    candidates = [match.group(0) for match in LOWERCASE_SUFFIX_CODE_NAME.finditer(text)]
    if break_switch() != "uppercase-shape-dropped":
        candidates += [match.group(0) for match in UPPERCASE_PREFIX_CODE_NAME.finditer(text)]
    code_names = []
    for candidate in candidates:
        if SCIENTIFIC_NOTATION.fullmatch(candidate) and break_switch() != "scientific-notation-flagged":
            continue
        if break_switch() != "registry-ignored" and any(pattern.fullmatch(candidate) for pattern in registered_patterns):
            continue
        code_names.append(candidate)
    return code_names


def judge_lines(relative_path: str, all_lines: list, added_line_numbers: set, registered_patterns: list) -> list:
    hits = []
    inside_fence = False
    for line_number, line_text in enumerate(all_lines, start=1):
        if FENCE_LINE.match(line_text):
            inside_fence = not inside_fence
            continue
        if inside_fence and break_switch() != "fences-read":
            continue
        if line_number not in added_line_numbers:
            continue
        for code_name in dict.fromkeys(code_names_in_line(line_text, registered_patterns)):
            hits.append(CodeNameHit(relative_path, line_number, code_name, line_text.strip()))
    return hits


def is_skipped_path(relative_path: str, frozen_prefixes: tuple, installed_package_prefix: str) -> bool:
    return relative_path.startswith(frozen_prefixes) or relative_path.startswith(installed_package_prefix)


def check(project_root: str) -> int:
    if GATE_OVERLAP.run_git(project_root, "rev-parse", "--is-inside-work-tree").returncode != 0:
        print(f"  ! {project_root} 不在 git 仓里，分不出哪些行是这一次新加的，本阶段无对象可判（这不是通过）")
        return EXIT_NOTHING_TO_JUDGE
    try:
        diff_base = GATE_OVERLAP.resolve_diff_base(project_root)
    except GATE_OVERLAP.CannotJudge as error:
        raise CannotJudge(error.problem, error.next_step) from None
    registered_patterns, registry_problems = read_registry(project_root)
    added_lines_by_path, _ = GATE_OVERLAP.changed_lines_by_path(project_root, diff_base, ["*.md"])
    frozen_prefixes = EVIDENCE_EXCLUDE.frozen_evidence_prefixes(project_root)
    installed_package_prefix = PACKAGE_FAMILY.installed_package_directory()
    hits = []
    judged_line_count = 0
    judged_file_count = 0
    skipped_paths = []
    for relative_path in sorted(added_lines_by_path):
        added_line_numbers = added_lines_by_path[relative_path]
        if not added_line_numbers:
            continue
        if is_skipped_path(relative_path, frozen_prefixes, installed_package_prefix):
            skipped_paths.append(relative_path)
            continue
        try:
            all_lines = pathlib.Path(project_root, relative_path).read_text(encoding="utf-8").splitlines()
        except (OSError, UnicodeDecodeError):
            skipped_paths.append(relative_path + "（读不出）")
            continue
        judged_file_count += 1
        judged_line_count += len(added_line_numbers)
        hits.extend(judge_lines(relative_path, all_lines, added_line_numbers, registered_patterns))
    base_text = "空树（仓里还没有提交）" if diff_base == GATE_OVERLAP.EMPTY_TREE else diff_base
    statistics = (f"相对 {base_text}：判了 {judged_file_count} 个 .md 里新加的 {judged_line_count} 行，"
                  f"登记的编号体系 {len(registered_patterns)} 条；没判 {len(skipped_paths)} 个"
                  + ("：" + "、".join(skipped_paths) if skipped_paths else ""))
    if registry_problems:
        for problem in registry_problems:
            print(f"      {problem}")   # gate-lint:detail
        print(f"  ✗ {REGISTRY_RELATIVE_PATH} 有 {len(registry_problems)} 行写坏了（{statistics}）")
        print("     → 怎么办：一行一条 `<正则>  # 理由`，正则整个匹配要放过的代号，理由写清它是哪一套编号、登记在哪，至少 4 个字。")
    if hits:
        for hit in hits:
            print(f"      {hit.relative_path}:{hit.line_number}  {hit.code_name}  ← {hit.line_text[:80]}")   # gate-lint:detail
        print(f"  ✗ 新加的行里有 {len(hits)} 处拿代号指东西（{statistics}）")
        print(f"     → 怎么办：{CODE_NAME_REMEDY}")
    if registry_problems or hits:
        return 1
    if judged_line_count == 0:
        print(f"  ! 这一次没有新加的 .md 行，本阶段无对象可判（{statistics}）")
        return EXIT_NOTHING_TO_JUDGE
    print(f"  ✓ 新加的行里没有拿代号指东西（{statistics}）")
    return 0


# 样本：(样本名, 内容, 新加的行号；None 表示全部是新加的, 期望的红处数)
SELFTEST_REGISTRY = (re.compile(r"E[0-9]+"), re.compile(r"[0-9]+[a-z]-mutant"))
SELFTEST_CASES = (
    ("数字接小写字母", "第 5a 批交回，9g 另报一处。\n", None, 2),
    ("数字接小写字母再接连字符", "改动并进 5g-rs 那一份。\n", None, 1),
    ("汉字紧挨着也算独立成词", "第10b批合入之后再跑。\n", None, 1),
    ("两个大写字母接两位数字", "SC02 那一格还红着。\n", None, 1),
    ("反引号里的代号放行", "原样写进命令：`run --batch 5a`。\n", None, 0),
    ("围栏里的代号放行", "```\nbatch 5a\n```\n", None, 0),
    ("登记过的编号体系放行", "E12 与 3b-mutant 都登记了。\n", None, 0),
    ("科学计数放行", "误差上界 1e-9，样本 3e5 个。\n", None, 0),
    ("版本号与哈希不算", "装到 v1.5a 上，sha256 对得上，#5a 是议题号。\n", None, 0),
    ("链接目标与网址不判", "见 [记录](records/5a-notes.md) 与 https://example.org/5a。\n", None, 0),
    ("HTML 注释里的声明放行", "<!-- doc-lint:not-numbers MR18 SC02 -->\n", None, 0),
    ("指编号步骤的放行", "照第 2b 步核它；单测归第 1b 步。See step 1b.\n", None, 0),
    ("同一行同一个代号只报一次", "10z 合入之后 10z 再跑一次。\n", None, 1),
    ("只判新加的行", "旧行写着 5a。\n新行干净。\n", {2}, 0),
    ("新加的行在围栏之后照判", "```\nx\n```\n新加的 7c 交回。\n", {4}, 1),
)


def run_selftest_cases() -> list:
    misjudged_cases = []
    for case_name, content, added_line_numbers, expected_red_count in SELFTEST_CASES:
        all_lines = content.splitlines()
        judged_line_numbers = set(range(1, len(all_lines) + 1)) if added_line_numbers is None else added_line_numbers
        red_count = len(judge_lines("sample.md", all_lines, judged_line_numbers, list(SELFTEST_REGISTRY)))
        if red_count != expected_red_count:
            misjudged_cases.append((case_name, expected_red_count, red_count))
    return misjudged_cases


def selftest() -> int:
    misjudged_cases = run_selftest_cases()
    exit_code = BREAK_SWITCH_SELFTEST.finish_selftest(__file__, BREAK_ENVIRONMENT_VARIABLE, BREAK_SWITCHES, misjudged_cases,
                                                      len(SELFTEST_CASES), "code_names_in_line / judge_lines")
    if exit_code is not None:
        return exit_code
    print(f"  ✓ code-name-lint 自证：{len(SELFTEST_CASES)} 个红绿样本判得对；"
          f"{len(BREAK_SWITCHES)} 个弄坏开关逐个打开，各自红在点名的样本上")
    return 0


def main(arguments: list) -> int:
    if arguments == ["--selftest"]:
        return selftest()
    if not arguments or arguments[0] != "--check" or len(arguments) > 2:
        print("  ✗ 用法：code-name-lint.py --check [仓库根]，或 code-name-lint.py --selftest")
        print("     → 怎么办：门禁里跑 --check，改了这份脚本先跑 --selftest。")
        return 2
    project_root = str((pathlib.Path(arguments[1]) if len(arguments) == 2 else SOURCE_FILES.default_root()).resolve())
    try:
        return check(project_root)
    except CannotJudge as error:
        print(f"  ✗ 判不了：{error.problem}")
        print(f"     → 怎么办：{error.next_step}")
        return 1


if __name__ == "__main__":
    preflight(__file__)
    sys.exit(main(sys.argv[1:]))
