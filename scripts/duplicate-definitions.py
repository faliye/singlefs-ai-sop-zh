#!/usr/bin/env python3
# gate-similar: shell-lint.sh 它只扫本包与项目登记的门禁目录、按行判 shell 的已知坑；这一道扫全仓的 .py 与 .sh、判同一作用域里同名定义两次，射程与对象都不同，shell 那一半放进它会够不着项目别处的脚本
# gate-similar: relay-timing-lint.py 它也扫全仓的 .py，但判读子进程输出的循环；扫哪些目录、跳过哪些冻结证据两边都调 source-files.py，不各抄一份
# gate-similar: naming-lint.sh 它判 .rs 里我们声明的名字是不是缩写或单字母，判的是名字本身；这一道判的是同一个名字在一个作用域里定义了几次
# admission: always 判的是此刻仓里的 .py 与 .sh，几秒跑完；每一轮门禁都现判
# run-condition: command git
"""同一个文件、同一个作用域里，同名的定义不许出现两次：后一个静默盖掉前一个。

用法：
    duplicate-definitions.py --check [仓库根]   # 扫全仓的 .py 与 .sh（扫哪些目录见 source-files.py），逐处报「文件:行」；不给仓库根就判当前目录所在的 git 仓
    duplicate-definitions.py --selftest         # 自证：内嵌红绿样本逐个判；再逐个打开弄坏开关另起子进程跑自证，每一个都必须判红、红在开关表点名的那个样本上

判据（Python，用 ast 解析）：模块、类体、函数体各自直接的那一层语句里（if / try / with 的分支不算同一层），
  两个 def / async def / class 用了同一个名字 ⇒ 红。放行：带 `@<名>.setter`、`@<名>.getter`、`@<名>.deleter`、`@<名>.register`、
  `@overload`（含 `@typing.overload`）的那一个。
判据（shell）：同一个文件里，顶格写的函数定义（`名字() {`、`function 名字 {`、`function 名字() {`）同一个名字出现两次 ⇒ 红。
  heredoc 体不算代码；缩进着的定义（写在 if 分支或别的函数里的）不判。
豁免：后一个定义那一行或上一行写 `# duplicate-definitions:allow <理由>`，理由至少 8 个字；理由不够判红。

够不着的写法（不判，不等于通过）：赋值盖掉函数（`名字 = …` 在 def 之后）、import 进来的名字被 def 盖掉、
  跨文件的同名（shell 里 source 进来的两份库各定义一次）、eval 或字符串拼出来的定义、python 解析不了的文件（逐个列进统计）。

DUPLICATE_DEFINITIONS_BREAK=<开关名> 打开一个弄坏开关（自证专用，门禁里不许设），开关表见 BREAK_SWITCHES。

退出码：0 通过；1 有红（或自证失败）；2 参数问题；77 一个 .py / .sh 都没扫到，本轮无对象可判。
"""
from __future__ import annotations

import ast
import dataclasses
import os
import pathlib
import re
import sys
from typing import Optional

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
from preflight import load_package_module, preflight  # noqa: E402
SOURCE_FILES = load_package_module("source_files", "source-files.py")
BREAK_SWITCH_SELFTEST = load_package_module("break_switch_selftest", "break-switch-selftest.py")

SCANNED_SUFFIXES = (".py", ".sh")
ALLOW_MARKER = "duplicate-definitions:allow"
MINIMUM_ALLOW_REASON_CHARACTERS = 8
EXEMPT_DECORATOR_ATTRIBUTES = {"setter", "getter", "deleter", "register"}
OVERLOAD_DECORATOR_NAME = "overload"
BREAK_ENVIRONMENT_VARIABLE = "DUPLICATE_DEFINITIONS_BREAK"
# 弄坏开关 → 打开后自证必须红在哪个样本上
BREAK_SWITCHES = {
    "class-bodies-skipped": "类体里两个同名方法",
    "every-decorator-exempt": "带普通装饰器的同名函数",
    "shell-skipped": "shell 顶格的同名函数",
    "heredoc-read-as-code": "heredoc 里的同名函数",
}

SHELL_FUNCTION_DEFINITION = re.compile(
    r"^(?:function[ \t]+([A-Za-z_][A-Za-z0-9_:.-]*)[ \t]*(?:\(\))?[ \t]*\{|([A-Za-z_][A-Za-z0-9_:.-]*)[ \t]*\(\)[ \t]*\{)"
)
SHELL_HEREDOC_START = re.compile(r"(?<!<)<<(-?)[ \t]*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\2")

DUPLICATE_REMEDY = (
    "后一个定义会静默盖掉前一个：调到的是哪一个取决于调用发生在第几行之后，前一个的调用方拿到的是后一个的签名与行为。"
    "改法：两个做的是不同的事就给其中一个改名，改名后把它的调用处一起改；做的是同一件事就删掉一个，留下的那个兼顾两边的调用。"
    "确实要按顺序重定义（例如测试替身覆盖库函数），在后一个定义那一行或上一行写 # duplicate-definitions:allow <理由>，理由至少 8 个字"
    "（rules/code-discipline.md「同一作用域里一个名字只定义一次」）。"
)


@dataclasses.dataclass
class DuplicateDefinition:
    relative_path: str
    name: str
    first_line_number: int
    later_line_number: int
    allow_reason: Optional[str]  # None：没写豁免；其余：写了，可能太短


def break_switch() -> str:
    return os.environ.get(BREAK_ENVIRONMENT_VARIABLE, "")


def allow_reason_near(raw_lines: list, line_number: int) -> Optional[str]:
    for candidate_line_number in (line_number, line_number - 1):
        if 1 <= candidate_line_number <= len(raw_lines):
            line_text = raw_lines[candidate_line_number - 1]
            marker_position = line_text.find(ALLOW_MARKER)
            if marker_position >= 0:
                return line_text[marker_position + len(ALLOW_MARKER):].strip()
    return None


def is_exempt_decorated(definition: ast.AST) -> bool:
    if isinstance(definition, ast.ClassDef):
        return False
    for decorator in definition.decorator_list:
        if break_switch() == "every-decorator-exempt":
            return True
        if isinstance(decorator, ast.Attribute) and decorator.attr in EXEMPT_DECORATOR_ATTRIBUTES:
            return True
        if isinstance(decorator, ast.Name) and decorator.id == OVERLOAD_DECORATOR_NAME:
            return True
        if isinstance(decorator, ast.Attribute) and decorator.attr == OVERLOAD_DECORATOR_NAME:
            return True
    return False


def python_scopes(tree: ast.Module) -> list:
    scope_types = (ast.FunctionDef, ast.AsyncFunctionDef) if break_switch() == "class-bodies-skipped" \
        else (ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)
    return [tree] + [node for node in ast.walk(tree) if isinstance(node, scope_types)]


def analyze_python(relative_path: str, source: str) -> tuple:
    """返回（定义个数，同名定义列表）。解析不了抛 SyntaxError / ValueError，由调用方记进统计。"""
    tree = ast.parse(source)
    raw_lines = source.splitlines()
    definition_count = 0
    duplicates = []
    for scope in python_scopes(tree):
        first_line_by_name = {}
        for statement in scope.body:
            if not isinstance(statement, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
                continue
            definition_count += 1
            if is_exempt_decorated(statement):
                continue
            if statement.name in first_line_by_name:
                duplicates.append(DuplicateDefinition(relative_path, statement.name, first_line_by_name[statement.name],
                                                      statement.lineno, allow_reason_near(raw_lines, statement.lineno)))
            else:
                first_line_by_name[statement.name] = statement.lineno
    return definition_count, duplicates


def analyze_shell(relative_path: str, source: str) -> tuple:
    raw_lines = source.splitlines()
    definition_count = 0
    duplicates = []
    first_line_by_name = {}
    heredoc_terminator = None
    heredoc_strips_tabs = False
    for line_number, line_text in enumerate(raw_lines, start=1):
        if heredoc_terminator is not None:
            compared_text = line_text.lstrip("\t") if heredoc_strips_tabs else line_text
            if compared_text == heredoc_terminator:
                heredoc_terminator = None
            continue
        if not line_text.lstrip().startswith("#") and break_switch() != "heredoc-read-as-code":
            heredoc_match = SHELL_HEREDOC_START.search(line_text)
            if heredoc_match:
                heredoc_terminator = heredoc_match.group(3)
                heredoc_strips_tabs = heredoc_match.group(1) == "-"
        definition_match = SHELL_FUNCTION_DEFINITION.match(line_text)
        if not definition_match:
            continue
        function_name = definition_match.group(1) or definition_match.group(2)
        definition_count += 1
        if function_name in first_line_by_name:
            duplicates.append(DuplicateDefinition(relative_path, function_name, first_line_by_name[function_name],
                                                  line_number, allow_reason_near(raw_lines, line_number)))
        else:
            first_line_by_name[function_name] = line_number
    return definition_count, duplicates


@dataclasses.dataclass
class ScanResult:
    python_file_count: int
    shell_file_count: int
    definition_count: int
    frozen_file_counts: dict
    unparsable_files: list
    duplicates: list


def analyze_file(relative_path: str, source: str) -> tuple:
    if relative_path.endswith(".py"):
        return analyze_python(relative_path, source)
    if break_switch() == "shell-skipped":
        return 0, []
    return analyze_shell(relative_path, source)


def scan(repository_root: pathlib.Path) -> ScanResult:
    source_walk = SOURCE_FILES.walk_source_files(repository_root, SCANNED_SUFFIXES)
    scan_result = ScanResult(0, 0, 0, source_walk.frozen_file_counts, [], [])
    for relative_path in source_walk.relative_paths:
        try:
            source = (repository_root / relative_path).read_text(encoding="utf-8")
            definition_count, duplicates = analyze_file(relative_path, source)
        except (UnicodeDecodeError, OSError, SyntaxError, ValueError):
            scan_result.unparsable_files.append(relative_path)
            continue
        if relative_path.endswith(".py"):
            scan_result.python_file_count += 1
        else:
            scan_result.shell_file_count += 1
        scan_result.definition_count += definition_count
        scan_result.duplicates.extend(duplicates)
    return scan_result


def statistics_text(scan_result: ScanResult, exempted_count: int) -> str:
    frozen_text = "、".join(f"{directory} 里 {skipped_file_count} 个（冻结证据）"
                            for directory, skipped_file_count in scan_result.frozen_file_counts.items())
    unparsable_text = f"解析不了的 {len(scan_result.unparsable_files)} 个" + (
        "（" + "、".join(scan_result.unparsable_files) + "）" if scan_result.unparsable_files else "")
    return (f"扫了 python {scan_result.python_file_count} 个、shell {scan_result.shell_file_count} 个文件，"
            f"{scan_result.definition_count} 个定义，豁免 {exempted_count} 处；"
            f"没扫：{'、'.join(part for part in (frozen_text, unparsable_text) if part)}")


def run(repository_root: pathlib.Path) -> int:
    scan_result = scan(repository_root)
    if break_switch():
        print(f"  ! {BREAK_ENVIRONMENT_VARIABLE}={break_switch()}：弄坏开关打开着（自证专用，门禁里不许设）")
    exempted = [duplicate for duplicate in scan_result.duplicates
                if duplicate.allow_reason is not None and len(duplicate.allow_reason) >= MINIMUM_ALLOW_REASON_CHARACTERS]
    short_reasons = [duplicate for duplicate in scan_result.duplicates
                     if duplicate.allow_reason is not None and len(duplicate.allow_reason) < MINIMUM_ALLOW_REASON_CHARACTERS]
    unexempted = [duplicate for duplicate in scan_result.duplicates if duplicate.allow_reason is None]
    statistics = statistics_text(scan_result, len(exempted))
    if scan_result.python_file_count + scan_result.shell_file_count == 0:
        print(f"  ! 扫的范围里没有可判的 .py / .sh，本轮无对象可判（{statistics}）")
        return 77
    if unexempted:
        for duplicate in unexempted:
            print(f"      {duplicate.relative_path}:{duplicate.later_line_number}  {duplicate.name} "   # gate-lint:detail
                  f"又定义了一次（前一个在第 {duplicate.first_line_number} 行）")
        print(f"  ✗ 有 {len(unexempted)} 处同一作用域里同名定义两次，后一个盖掉前一个（{statistics}）")
        print(f"     → 怎么办：{DUPLICATE_REMEDY}")
    if short_reasons:
        for duplicate in short_reasons:
            print(f"      {duplicate.relative_path}:{duplicate.later_line_number}  {duplicate.name}  "   # gate-lint:detail
                  f"豁免理由「{duplicate.allow_reason}」不到 {MINIMUM_ALLOW_REASON_CHARACTERS} 个字")
        print(f"  ✗ 有 {len(short_reasons)} 处 {ALLOW_MARKER} 的理由太短（{statistics}）")
        print("     → 怎么办：写清为什么要按顺序重定义、后一个盖掉前一个是有意的（例如「测试替身覆盖库里的同名函数」）；"
              "写不出就别豁免，按同名定义那条的出路改名或删掉一个。")
    if unexempted or short_reasons:
        return 1
    print(f"  ✓ 没有同一作用域里同名定义两次（{statistics}）")
    return 0


# 样本：(样本名, 文件名, 内容, 期望的红处数)
SELFTEST_CASES = (
    ("模块里两个同名函数", "module_duplicate.py",
     "def closure_names(tree):\n    return []\n\n\ndef closure_names(closure):\n    return closure\n", 1),
    ("类体里两个同名方法", "class_duplicate.py",
     "class Closure:\n    def names(self):\n        return []\n\n    def names(self, extra):\n        return [extra]\n", 1),
    ("函数体里两个同名的嵌套函数", "nested_duplicate.py",
     "def outer():\n    def helper():\n        return 1\n    def helper():\n        return 2\n    return helper()\n", 1),
    ("同名的类与函数", "class_and_function.py",
     "class Report:\n    pass\n\n\ndef Report():\n    return None\n", 1),
    ("带普通装饰器的同名函数", "decorated_duplicate.py",
     "import functools\n\n\n@functools.cache\ndef table():\n    return 1\n\n\n@functools.cache\ndef table():\n    return 2\n", 1),
    ("property 的 setter 放行", "property_setter.py",
     "class Box:\n    @property\n    def size(self):\n        return self._size\n\n    @size.setter\n    def size(self, value):\n        self._size = value\n", 0),
    ("overload 放行", "overloads.py",
     "from typing import overload\n\n\n@overload\ndef parse(value: int) -> int: ...\n@overload\ndef parse(value: str) -> str: ...\ndef parse(value):\n    return value\n", 0),
    ("if 两个分支各定义一次放行", "conditional.py",
     "import sys\nif sys.platform == 'linux':\n    def opener():\n        return 'linux'\nelse:\n    def opener():\n        return 'other'\n", 0),
    ("不同类里同名方法放行", "two_classes.py",
     "class Left:\n    def run(self):\n        return 1\n\n\nclass Right:\n    def run(self):\n        return 2\n", 0),
    ("豁免写了理由放行", "allowed.py",
     "def hook():\n    return 1\n\n\n# duplicate-definitions:allow 测试替身覆盖前面库里的同名函数\ndef hook():\n    return 2\n", 0),
    ("豁免理由太短判红", "short_reason.py",
     "def hook():\n    return 1\n\n\ndef hook():  # duplicate-definitions:allow 替身\n    return 2\n", 1),
    ("shell 顶格的同名函数", "duplicate.sh",
     "#!/usr/bin/env bash\nreport() {\n  echo first\n}\n\nfunction report {\n  echo second\n}\nreport\n", 1),
    ("heredoc 里的同名函数", "heredoc.sh",
     "#!/usr/bin/env bash\nbuild() {\n  echo real\n}\ncat > stub.sh <<'EOF'\nbuild() {\n  echo stub\n}\nEOF\nbuild\n", 0),
    ("shell 缩进着的分支定义放行", "branches.sh",
     "#!/usr/bin/env bash\nif [[ -n \"${FAST:-}\" ]]; then\n  run() { echo fast; }\nelse\n  run() { echo slow; }\nfi\nrun\n", 0),
    ("shell 不同名的函数放行", "distinct.sh",
     "#!/usr/bin/env bash\nscan() { :; }\nscan_one() { :; }\n", 0),
)


def run_selftest_cases() -> list:
    """返回判错的样本：(样本名, 期望红处, 实际红处)。"""
    misjudged_cases = []
    for case_name, file_name, content, expected_red_count in SELFTEST_CASES:
        try:
            _, duplicates = analyze_file(file_name, content)
        except (SyntaxError, ValueError) as parse_error:
            misjudged_cases.append((case_name, expected_red_count, f"解析失败 {parse_error}"))
            continue
        red_count = sum(1 for duplicate in duplicates
                        if duplicate.allow_reason is None or len(duplicate.allow_reason) < MINIMUM_ALLOW_REASON_CHARACTERS)
        if red_count != expected_red_count:
            misjudged_cases.append((case_name, expected_red_count, red_count))
    return misjudged_cases


def selftest() -> int:
    misjudged_cases = run_selftest_cases()
    exit_code = BREAK_SWITCH_SELFTEST.finish_selftest(__file__, BREAK_ENVIRONMENT_VARIABLE, BREAK_SWITCHES, misjudged_cases,
                                                      len(SELFTEST_CASES), "analyze_python / analyze_shell")
    if exit_code is not None:
        return exit_code
    print(f"  ✓ duplicate-definitions 自证：{len(SELFTEST_CASES)} 个红绿样本判得对；"
          f"{len(BREAK_SWITCHES)} 个弄坏开关逐个打开，各自红在点名的样本上")
    return 0


def main(arguments: list) -> int:
    if arguments == ["--selftest"]:
        return selftest()
    if not arguments or arguments[0] != "--check" or len(arguments) > 2:
        print("  ✗ 用法：duplicate-definitions.py --check [仓库根]，或 duplicate-definitions.py --selftest")
        print("     → 怎么办：门禁里跑 --check，改了这份脚本先跑 --selftest。")
        return 2
    repository_root = pathlib.Path(arguments[1]) if len(arguments) == 2 else SOURCE_FILES.default_root()
    return run(repository_root.resolve())


if __name__ == "__main__":
    preflight(__file__)
    sys.exit(main(sys.argv[1:]))
