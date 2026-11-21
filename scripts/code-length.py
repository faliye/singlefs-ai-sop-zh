#!/usr/bin/env python3
# gate-similar: duplicate-definitions.py 它也扫全仓的 .py 与 .sh、走 source-files.py，但判的是同一作用域里同名定义两次；这一道数每个代码文件不算注释有多少行，对象与出路都不同，扫哪些目录两边都调 source-files.py，不各抄一份
# gate-similar: naming-lint.sh 它也剥 .rs 的注释与字面量，但用 awk 逐行剥了判声明的名字；这一道要知道每一行有没有代码，还要认 python 的 docstring 与 shell 的 heredoc，awk 那一份做不了 python 的 tokenize
# gate-similar: root-entries.py 它的 --hook 也在 Write 与 Edit 之前判，判的是写到项目根下的新条目；这一道判写完之后文件有多长，触发点相同、判的东西不同
# gate-similar: relay-timing-lint.py 它也扫全仓的 .rs 与 .py，判读子进程输出的循环，判的是一种写法；这一道只数行
# admission: always 判的是此刻仓里每个代码文件的长度与这一次要写的内容，几秒跑完，每一次都现判
# run-condition: command git
"""一个代码文件不算注释不超过 MAXIMUM_CODE_LINES 行（rules/code-discipline.md「一个代码文件不超过 2000 行」）。

代码文件：后缀在 CODE_SUFFIXES 里的（.rs、.py、.sh、.wgsl）。
怎么数：文件的行数减去只有注释的行。
  - 空行算。代码后面跟着行尾注释的照代码算。
  - 只有注释的行不算：Rust 与 WGSL 认 `//` 与 `/* */`（可嵌套），python 认 `#` 与模块、类、函数的 docstring，shell 认 `#`（含 `#!` 那一行）。
  - 块注释与 docstring 中间的空行也不算。
  - 字符串、原始字符串、字符字面量、python 的普通多行字符串、shell 的 heredoc 体里的 `//`、`#` 不是注释，那几行照代码算。
  - python 解析不了的（语法错），按整行 `#` 起头的算注释，统计里逐个列出。

用法：
    code-length.py --check [仓库根]   # 扫全仓的代码文件（扫哪些目录见 source-files.py），超了的逐个报「文件  行数」；不给仓库根就判当前目录所在的 git 仓
    code-length.py --hook             # Claude Code 的 PreToolUse 钩子（Write、Edit、MultiEdit）：从 stdin 读钩子的 JSON，
                                      #   写完之后超过上限、而且比写之前长的，拒绝；已经超了的文件只许改短
    code-length.py --selftest         # 自证：内嵌的数行样本与钩子样本逐个判；再逐个打开弄坏开关另起子进程跑自证，每一个都必须红在开关表点名的样本上

钩子的项目根取 CLAUDE_PROJECT_DIR，没有就取输入里的 cwd；项目外的文件、门禁不扫的目录里的文件不判。
够不着的写法（不判，不等于通过）：Bash 里写文件（sed -i、重定向、cp）钩子看不见，由门禁阶段兜底；shell 里多行字符串中间以 `#` 起头的行会被当成注释。

CODE_LENGTH_BREAK=<开关名> 打开一个弄坏开关（自证专用，门禁里不许设），开关表见 BREAK_SWITCHES。

退出码：
  --check：0 通过；1 有超了的；2 参数问题；77 一个代码文件都没扫到，本轮无对象可判。
  --hook：0 放行；2 拒绝（Claude Code 不执行这一次写，把 stderr 交给 agent）；1 判不了（照常执行，stderr 留一行原因）。
  --selftest：0 通过；1 判错。
"""
from __future__ import annotations

import ast
import dataclasses
import io
import json
import os
import pathlib
import re
import sys
import tempfile
import tokenize

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
from preflight import load_package_module, preflight  # noqa: E402
SOURCE_FILES = load_package_module("source_files", "source-files.py")
BREAK_SWITCH_SELFTEST = load_package_module("break_switch_selftest", "break-switch-selftest.py")

MAXIMUM_CODE_LINES = 2000
C_STYLE_COMMENT_SUFFIXES = (".rs", ".wgsl")
PYTHON_SUFFIX = ".py"
SHELL_SUFFIX = ".sh"
CODE_SUFFIXES = C_STYLE_COMMENT_SUFFIXES + (PYTHON_SUFFIX, SHELL_SUFFIX)
RULE_REFERENCE = "rules/code-discipline.md「一个代码文件不超过 2000 行」"
WRITING_TOOL_NAMES = ("Write", "Edit", "MultiEdit")

EXIT_PASSED = 0
EXIT_RED = 1
EXIT_USAGE = 2
EXIT_NOTHING_TO_JUDGE = 77
EXIT_HOOK_CANNOT_JUDGE = 1
EXIT_HOOK_BLOCKED = 2

BREAK_ENVIRONMENT_VARIABLE = "CODE_LENGTH_BREAK"
# 弄坏开关 → 打开后自证必须红在哪个样本上
BREAK_SWITCHES = {
    "comments-counted": "Rust 的整行注释不算",
    "blank-lines-skipped": "空行算",
    "flat-block-comments": "嵌套的块注释整段不算",
    "strings-not-skipped": "Rust 字符串里以 // 起头的行照代码算",
    "docstrings-counted": "python 的 docstring 不算",
    "heredoc-read-as-comments": "shell 的 heredoc 体里以 # 起头的行照代码算",
    "growth-allowed": "已经超了的文件再加长被拒",
}

RAW_STRING_START = re.compile(r'(?:b|c)?r(#*)"')
# Rust 与 WGSL 里要停下来看的字符：换行、可能开注释的 /、开字符串或字符字面量的引号、原始字符串的前缀；别的字符成段跳过
C_STYLE_INTERESTING = re.compile(r'[\n/"\']|(?<![0-9A-Za-z_])[bc]?r#*"')
IDENTIFIER_CHARACTER = re.compile(r"[0-9A-Za-z_]")
SHELL_HEREDOC_START = re.compile(r"(?<!<)<<(-?)[ \t]*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\2")
PYTHON_TOKENS_WITHOUT_CODE = {tokenize.NL, tokenize.NEWLINE, tokenize.INDENT, tokenize.DEDENT, tokenize.ENCODING,
                              tokenize.ENDMARKER, tokenize.COMMENT}

SPLIT_REMEDY = (
    "按职责把这个文件拆成几个，每份不超过 2000 行：Rust 拆成子模块，python 拆成被 import 的模块，shell 拆成被 source 的库。"
    "拆的时候先把要挪走的那一段写进新文件，再从原文件里删掉；已经超了的文件只许改短，没有豁免"
    f"（{RULE_REFERENCE}）。"
)


def break_switch() -> str:
    return os.environ.get(BREAK_ENVIRONMENT_VARIABLE, "")


def is_identifier_character(character: str) -> bool:
    return bool(IDENTIFIER_CHARACTER.match(character)) or (not character.isascii() and character.isalnum())


@dataclasses.dataclass
class LineKinds:
    """每一行（下标从 1 起）有没有代码、有没有注释、是不是整行落在一段跨行的注释里。"""
    line_count: int
    lines_with_code: set
    lines_with_comment: set

    def comment_only_line_count(self) -> int:
        return len(self.lines_with_comment - self.lines_with_code)


def physical_line_count(text: str) -> int:
    if not text:
        return 0
    return text.count("\n") + (0 if text.endswith("\n") else 1)


def c_style_line_kinds(text: str) -> LineKinds:
    """Rust 与 WGSL：`//` 到行尾、`/* */`（可嵌套）是注释；字符串、原始字符串、字符字面量里的不是。"""
    line_kinds = LineKinds(physical_line_count(text), set(), set())
    text_length, position, line_number = len(text), 0, 1

    def mark_span(kind_set: set, start: int, end: int, starting_line: int) -> int:
        """text[start:end] 跨过的每一行都记进 kind_set（中间的空行在注释里不算、在字符串里本来就算），返回 end 所在的行号。"""
        ending_line = starting_line + text.count("\n", start, end)
        kind_set.update(range(starting_line, ending_line + 1))
        return ending_line

    while position < text_length:
        next_interesting = C_STYLE_INTERESTING.search(text, position)
        stop = next_interesting.start() if next_interesting else text_length
        if text[position:stop].strip():
            line_kinds.lines_with_code.add(line_number)
        position = stop
        if position >= text_length:
            break
        character = text[position]
        if character == "\n":
            line_number += 1
            position += 1
            continue
        if text.startswith("//", position):
            end = text.find("\n", position)
            end = text_length if end < 0 else end
            if break_switch() != "comments-counted":
                line_kinds.lines_with_comment.add(line_number)
            else:
                line_kinds.lines_with_code.add(line_number)
            position = end
            continue
        if text.startswith("/*", position):
            nesting_depth, end = 1, position + 2
            while end < text_length and nesting_depth:
                if break_switch() != "flat-block-comments" and text.startswith("/*", end):
                    nesting_depth, end = nesting_depth + 1, end + 2
                elif text.startswith("*/", end):
                    nesting_depth, end = nesting_depth - 1, end + 2
                else:
                    end += 1
            target_set = line_kinds.lines_with_code if break_switch() == "comments-counted" else line_kinds.lines_with_comment
            line_number = mark_span(target_set, position, end, line_number)
            position = end
            continue
        if break_switch() != "strings-not-skipped":
            raw_string_start = RAW_STRING_START.match(text, position)
            if raw_string_start and (position == 0 or not is_identifier_character(text[position - 1])):
                closing = '"' + raw_string_start.group(1)
                end = text.find(closing, raw_string_start.end())
                end = text_length if end < 0 else end + len(closing)
                line_number = mark_span(line_kinds.lines_with_code, position, end, line_number)
                position = end
                continue
            if character == '"':
                end = position + 1
                while end < text_length and text[end] != '"':
                    end += 2 if text[end] == "\\" else 1
                end = min(end + 1, text_length)
                line_number = mark_span(line_kinds.lines_with_code, position, end, line_number)
                position = end
                continue
            if character == "'":
                if position + 1 < text_length and text[position + 1] == "\\":
                    end = text.find("'", position + 3)
                    end = text_length if end < 0 else end + 1
                elif position + 2 < text_length and text[position + 2] == "'":
                    end = position + 3
                else:
                    end = position + 1
                line_number = mark_span(line_kinds.lines_with_code, position, end, line_number)
                position = end
                continue
        line_kinds.lines_with_code.add(line_number)
        position += 1
    return line_kinds


def python_docstring_line_ranges(syntax_tree: ast.AST) -> list:
    """模块、类、函数体的第一句是字符串常量的，那一句占的行：[(起行, 止行), …]。"""
    line_ranges = []
    for node in ast.walk(syntax_tree):
        if not isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)) or not node.body:
            continue
        first_statement = node.body[0]
        if isinstance(first_statement, ast.Expr) and isinstance(first_statement.value, ast.Constant) \
                and isinstance(first_statement.value.value, str):
            line_ranges.append((first_statement.lineno, first_statement.end_lineno))
    return line_ranges


def whole_line_hash_comment_kinds(text: str) -> LineKinds:
    """整行（去掉开头空白后）以 # 起头的算注释，别的不是空行的都算代码。python 解析不了时的退路。"""
    line_kinds = LineKinds(physical_line_count(text), set(), set())
    for line_number, line_text in enumerate(text.split("\n"), start=1):
        stripped_text = line_text.strip()
        if not stripped_text:
            continue
        if stripped_text.startswith("#") and break_switch() != "comments-counted":
            line_kinds.lines_with_comment.add(line_number)
        else:
            line_kinds.lines_with_code.add(line_number)
    return line_kinds


def python_line_kinds(text: str):
    """→ (LineKinds, 是不是按整行 # 的退路数的)。`#` 注释与 docstring 不算代码，别的词元跨过的每一行都算。"""
    try:
        syntax_tree = ast.parse(text)
        tokens = list(tokenize.generate_tokens(io.StringIO(text).readline))
    except (SyntaxError, tokenize.TokenError, ValueError):
        return whole_line_hash_comment_kinds(text), True
    docstring_ranges = [] if break_switch() == "docstrings-counted" else python_docstring_line_ranges(syntax_tree)
    line_kinds = LineKinds(physical_line_count(text), set(), set())
    for token in tokens:
        (start_line, _), (end_line, _) = token.start, token.end
        if token.type == tokenize.COMMENT:
            target_set = line_kinds.lines_with_code if break_switch() == "comments-counted" else line_kinds.lines_with_comment
            target_set.add(start_line)
            continue
        if token.type in PYTHON_TOKENS_WITHOUT_CODE:
            continue
        is_docstring = token.type == tokenize.STRING and any(
            range_start <= start_line and end_line <= range_end for range_start, range_end in docstring_ranges)
        target_set = line_kinds.lines_with_comment if is_docstring else line_kinds.lines_with_code
        target_set.update(range(start_line, end_line + 1))
    return line_kinds, False


def shell_line_kinds(text: str) -> LineKinds:
    """整行以 # 起头的是注释；heredoc 体里的行照代码算，到结束标记那一行为止。"""
    line_kinds = LineKinds(physical_line_count(text), set(), set())
    pending_heredocs = []  # [(结束标记, 结束标记前能不能有 tab)]，按出现的次序
    for line_number, line_text in enumerate(text.split("\n"), start=1):
        stripped_text = line_text.strip()
        if pending_heredocs:
            terminator, allows_leading_tabs = pending_heredocs[0]
            if (line_text.lstrip("\t") if allows_leading_tabs else line_text) == terminator:
                pending_heredocs.pop(0)
            if stripped_text:
                if break_switch() == "heredoc-read-as-comments" and stripped_text.startswith("#"):
                    line_kinds.lines_with_comment.add(line_number)
                else:
                    line_kinds.lines_with_code.add(line_number)
            continue
        if not stripped_text:
            continue
        if stripped_text.startswith("#") and break_switch() != "comments-counted":
            line_kinds.lines_with_comment.add(line_number)
            continue
        line_kinds.lines_with_code.add(line_number)
        for heredoc_start in SHELL_HEREDOC_START.finditer(line_text):
            pending_heredocs.append((heredoc_start.group(3), heredoc_start.group(1) == "-"))
    return line_kinds


def code_line_count(file_name: str, text: str):
    """→ (不算注释的行数, 是不是按整行 # 的退路数的)。空行算；只有注释的行不算。"""
    used_fallback = False
    if file_name.endswith(C_STYLE_COMMENT_SUFFIXES):
        line_kinds = c_style_line_kinds(text)
    elif file_name.endswith(PYTHON_SUFFIX):
        line_kinds, used_fallback = python_line_kinds(text)
    else:
        line_kinds = shell_line_kinds(text)
    if break_switch() == "blank-lines-skipped":
        return len(line_kinds.lines_with_code), used_fallback
    return line_kinds.line_count - line_kinds.comment_only_line_count(), used_fallback


def read_text(path: pathlib.Path) -> str:
    with open(path, encoding="utf-8", errors="replace", newline="") as source_file:
        return source_file.read()


# ── 整仓扫 ─────────────────────────────────────────────

def run_check(repository_root: pathlib.Path) -> int:
    source_walk = SOURCE_FILES.walk_source_files(repository_root, CODE_SUFFIXES)
    if break_switch():
        print(f"  ! {BREAK_ENVIRONMENT_VARIABLE}={break_switch()}：弄坏开关打开着（自证专用，门禁里不许设）")
    counts_by_suffix = {suffix: 0 for suffix in CODE_SUFFIXES}
    over_limit_files, fallback_files, longest_file = [], [], ("", 0)
    for relative_path in source_walk.relative_paths:
        line_count, used_fallback = code_line_count(relative_path, read_text(repository_root / relative_path))
        counts_by_suffix[next(suffix for suffix in CODE_SUFFIXES if relative_path.endswith(suffix))] += 1
        if used_fallback:
            fallback_files.append(relative_path)
        if line_count > longest_file[1]:
            longest_file = (relative_path, line_count)
        if line_count > MAXIMUM_CODE_LINES:
            over_limit_files.append((relative_path, line_count))
    scanned_count = len(source_walk.relative_paths)
    suffix_text = "、".join(f"{suffix} {file_count} 个" for suffix, file_count in counts_by_suffix.items())
    frozen_text = "、".join(f"{directory} 里 {skipped_file_count} 个（冻结证据）"
                            for directory, skipped_file_count in source_walk.frozen_file_counts.items()) or "无"
    fallback_text = f"python 解析不了、按整行 # 数的 {len(fallback_files)} 个" + (
        "：" + "、".join(fallback_files) if fallback_files else "")
    statistics = f"查了 {scanned_count} 个代码文件（{suffix_text}）；没扫：{frozen_text}；{fallback_text}"
    if scanned_count == 0:
        print(f"  ! 扫的范围里没有代码文件，本轮无对象可判（{statistics}）")
        return EXIT_NOTHING_TO_JUDGE
    if over_limit_files:
        for relative_path, line_count in sorted(over_limit_files, key=lambda entry: (-entry[1], entry[0])):
            print(f"      {relative_path}  {line_count} 行")   # gate-lint:detail
        print(f"  ✗ 有 {len(over_limit_files)} 个代码文件不算注释超过 {MAXIMUM_CODE_LINES} 行（{statistics}）")
        print(f"     → 怎么办：{SPLIT_REMEDY}")
        return EXIT_RED
    print(f"  ✓ 代码文件都不超过 {MAXIMUM_CODE_LINES} 行：{statistics}；最长的是 {longest_file[0]}（{longest_file[1]} 行）")
    return EXIT_PASSED


# ── 钩子 ───────────────────────────────────────────────

class HookCannotJudge(Exception):
    """判不了：不拦，照常执行，stderr 留一行原因。"""


def text_after_writing(tool_name: str, tool_input: dict, text_before: str):
    """→ 这一次写完之后的全文；替换的原文对不上（工具自己会报错不写）时返回 None。"""
    if tool_name == "Write":
        content = tool_input.get("content")
        if not isinstance(content, str):
            raise HookCannotJudge("Write 的 tool_input 里没有字符串 content")
        return content
    edits = [tool_input] if tool_name == "Edit" else tool_input.get("edits")
    if not isinstance(edits, list):
        raise HookCannotJudge("MultiEdit 的 tool_input 里没有 edits 列表")
    text_after = text_before
    for edit in edits:
        old_string, new_string = edit.get("old_string") if isinstance(edit, dict) else None, \
            edit.get("new_string") if isinstance(edit, dict) else None
        if not isinstance(old_string, str) or not isinstance(new_string, str):
            raise HookCannotJudge(f"{tool_name} 的替换里缺字符串 old_string 或 new_string")
        if old_string not in text_after:
            return None
        text_after = text_after.replace(old_string, new_string) if edit.get("replace_all") \
            else text_after.replace(old_string, new_string, 1)
    return text_after


def judge_hook_input(hook_input, fallback_project_root: str):
    """→ (退出码, 给 agent 的话)。放行时话是空的。"""
    if not isinstance(hook_input, dict):
        raise HookCannotJudge("钩子输入不是 JSON 对象")
    tool_name = hook_input.get("tool_name")
    if tool_name not in WRITING_TOOL_NAMES:
        return EXIT_PASSED, ""
    tool_input = hook_input.get("tool_input")
    if not isinstance(tool_input, dict) or not isinstance(tool_input.get("file_path"), str):
        raise HookCannotJudge(f"{tool_name} 的 tool_input 里没有 file_path")
    project_root_text = fallback_project_root or hook_input.get("cwd") or ""
    if not project_root_text:
        raise HookCannotJudge("取不到项目根：没有 CLAUDE_PROJECT_DIR，输入里也没有 cwd")
    project_root = pathlib.Path(project_root_text).resolve()
    target_path = pathlib.Path(tool_input["file_path"])
    if not target_path.is_absolute():
        target_path = pathlib.Path(hook_input.get("cwd") or project_root) / target_path
    target_path = target_path.resolve()
    try:
        relative_path = target_path.relative_to(project_root).as_posix()
    except ValueError:
        return EXIT_PASSED, ""
    if not SOURCE_FILES.is_walked_relative_path(project_root, relative_path, CODE_SUFFIXES):
        return EXIT_PASSED, ""
    text_before = read_text(target_path) if target_path.is_file() else ""
    text_after = text_after_writing(tool_name, tool_input, text_before)
    if text_after is None:
        return EXIT_PASSED, ""
    count_before, _ = code_line_count(relative_path, text_before)
    count_after, _ = code_line_count(relative_path, text_after)
    is_growing = count_after > count_before
    if break_switch() == "growth-allowed" and count_before > MAXIMUM_CODE_LINES:
        is_growing = False
    if count_after > MAXIMUM_CODE_LINES and is_growing:
        return EXIT_HOOK_BLOCKED, (
            f"✗ 写完之后 {relative_path} 不算注释有 {count_after} 行，超过 {MAXIMUM_CODE_LINES} 行的上限（写之前 {count_before} 行）\n"
            f"   → 怎么办：{SPLIT_REMEDY}")
    return EXIT_PASSED, ""


def run_hook() -> int:
    try:
        hook_input = json.loads(sys.stdin.read())
        exit_code, message = judge_hook_input(hook_input, os.environ.get("CLAUDE_PROJECT_DIR", ""))
    except (HookCannotJudge, json.JSONDecodeError, OSError) as problem:
        print(f"code-length 钩子这一次没判：{problem}", file=sys.stderr)
        return EXIT_HOOK_CANNOT_JUDGE
    if message:
        print(message, file=sys.stderr)
    return exit_code


# ── 自证 ───────────────────────────────────────────────

# 数行样本：(样本名, 文件名, 内容, 期望的行数)
COUNT_CASES = (
    ("Rust 的整行注释不算", "lib.rs", "// 为什么\n/// 文档\n//! 模块文档\nfn main() {}\n", 1),
    ("空行算", "lib.rs", "fn first() {}\n\n\nfn second() {}\n", 4),
    ("块注释里的空行不算", "lib.rs", "/*\n\n  说明\n*/\nfn main() {}\n", 1),
    ("嵌套的块注释整段不算", "lib.rs", "/* 外层 /* 里层 */ 还在注释里\n还在注释里 */\nfn main() {}\n", 1),
    ("代码后面跟着行尾注释照代码算", "lib.rs", "let value = 1; // 为什么\n/* 前 */ let other = 2;\n", 2),
    ("Rust 字符串里以 // 起头的行照代码算", "lib.rs", 'let text = "\n// 不是注释\n";\n', 3),
    ("原始字符串里的 /* 不开块注释", "lib.rs", 'let pattern = r#"/*"#;\nfn main() {}\n', 2),
    ("字符字面量里的引号不开字符串", "lib.rs", "fn quote<'text>(value: &'text str) -> char { '\"' }\n// 注释\n", 1),
    ("最后一行不带换行也算", "lib.rs", "fn main() {}", 1),
    ("WGSL 的注释不算", "shader.wgsl", "// 着色器\nfn main() {}\n/* 说明 */\n", 1),
    ("python 的 # 注释不算", "tool.py", "# 说明\nimport os\n    # 缩进着的注释\n", 1),
    ("python 的 docstring 不算", "tool.py",
     '"""模块说明。\n\n第二段。\n"""\nimport os\n\n\ndef run():\n    """跑一次。"""\n    return os.getcwd()\n', 5),
    ("python 的普通多行字符串照代码算", "tool.py", 'TEXT = """\n# 不是注释\n"""\n', 3),
    ("python 解析不了时按整行 # 数", "broken.py", "def broken(:\n    # 注释\n    pass\n", 2),
    ("shell 的 # 注释不算", "run.sh", "#!/usr/bin/env bash\n# 说明\necho hi\n\n", 2),
    ("shell 的 heredoc 体里以 # 起头的行照代码算", "run.sh", "cat <<'EOF'\n# 标题\nEOF\n# 注释\n", 3),
)


def lines_of(code_line: str, line_count: int) -> str:
    return code_line * line_count


# 钩子样本：(样本名, 写之前的文件内容或 None, 文件相对项目根的路径, 工具名, tool_input 里除 file_path 之外的部分, 期望的退出码)
HOOK_CASES = (
    ("写成 2001 行的新文件被拒", None, "src/new.py", "Write", {"content": lines_of("value = 1\n", 2001)}, EXIT_HOOK_BLOCKED),
    ("写成正好 2000 行的新文件放行", None, "src/new.py", "Write", {"content": lines_of("value = 1\n", 2000)}, EXIT_PASSED),
    ("注释再多也不拦", None, "src/new.rs", "Write",
     {"content": lines_of("// 说明\n", 3000) + "fn main() {}\n"}, EXIT_PASSED),
    ("已经超了的文件改短放行", lines_of("echo hi\n", 2100), "src/long.sh", "Edit",
     {"old_string": "echo hi\necho hi\n", "new_string": "echo hi\n"}, EXIT_PASSED),
    ("已经超了的文件改一行、不变长放行", lines_of("echo hi\n", 2099) + "echo last\n", "src/long.sh", "Edit",
     {"old_string": "echo last\n", "new_string": "echo changed\n"}, EXIT_PASSED),
    ("已经超了的文件再加长被拒", lines_of("echo hi\n", 2100), "src/long.sh", "Edit",
     {"old_string": "echo hi\n", "new_string": "echo hi\necho more\n"}, EXIT_HOOK_BLOCKED),
    ("MultiEdit 逐个套用之后超了被拒", lines_of("let value = 1;\n", 1999) + "fn main() {}\n", "src/lib.rs", "MultiEdit",
     {"edits": [{"old_string": "fn main() {}\n", "new_string": "fn main() {}\nfn other() {}\n"},
                {"old_string": "fn other() {}\n", "new_string": "fn other() {}\nfn third() {}\n"}]}, EXIT_HOOK_BLOCKED),
    ("替换的原文对不上不判", lines_of("value = 1\n", 2100), "src/long.py", "Edit",
     {"old_string": "不在文件里", "new_string": lines_of("value = 2\n", 50)}, EXIT_PASSED),
    ("不是代码文件不管", None, "docs/notes.md", "Write", {"content": lines_of("文字\n", 3000)}, EXIT_PASSED),
    ("样本目录里的不管", None, "fixtures/big.py", "Write", {"content": lines_of("value = 1\n", 3000)}, EXIT_PASSED),
    ("项目外的文件不管", None, "../outside.py", "Write", {"content": lines_of("value = 1\n", 3000)}, EXIT_PASSED),
)


def run_count_cases() -> list:
    misjudged_cases = []
    for case_name, file_name, content, expected_count in COUNT_CASES:
        actual_count, _ = code_line_count(file_name, content)
        if actual_count != expected_count:
            misjudged_cases.append((case_name, expected_count, actual_count))
    return misjudged_cases


def run_hook_cases() -> list:
    misjudged_cases = []
    with tempfile.TemporaryDirectory() as selftest_directory:
        project_root = pathlib.Path(selftest_directory) / "project"
        for case_name, existing_text, relative_path, tool_name, tool_input, expected_exit in HOOK_CASES:
            target_path = project_root / relative_path
            target_path.parent.mkdir(parents=True, exist_ok=True)
            if existing_text is None:
                target_path.unlink(missing_ok=True)
            else:
                target_path.write_text(existing_text, encoding="utf-8")
            hook_input = {"hook_event_name": "PreToolUse", "tool_name": tool_name,
                          "tool_input": dict(tool_input, file_path=str(target_path))}
            try:
                actual_exit, _ = judge_hook_input(hook_input, str(project_root))
            except HookCannotJudge as problem:
                actual_exit = f"判不了：{problem}"
            if actual_exit != expected_exit:
                misjudged_cases.append((case_name, expected_exit, actual_exit))
        for case_name, hook_input in (("输入不是 JSON 对象判不了", [1, 2]),
                                      ("Write 缺 content 判不了", {"tool_name": "Write",
                                                                   "tool_input": {"file_path": str(project_root / "src/x.py")}})):
            try:
                judge_hook_input(hook_input, str(project_root))
                misjudged_cases.append((case_name, "判不了", "判了"))
            except HookCannotJudge:
                pass
    return misjudged_cases


def selftest() -> int:
    misjudged_cases = run_count_cases() + run_hook_cases()
    case_count = len(COUNT_CASES) + len(HOOK_CASES) + 2
    exit_code = BREAK_SWITCH_SELFTEST.finish_selftest(__file__, BREAK_ENVIRONMENT_VARIABLE, BREAK_SWITCHES, misjudged_cases,
                                                      case_count, "code_line_count / judge_hook_input")
    if exit_code is not None:
        return exit_code
    print(f"  ✓ code-length 自证：{case_count} 个样本判得对（数行 {len(COUNT_CASES)} 个、钩子 {len(HOOK_CASES) + 2} 个）；"
          f"{len(BREAK_SWITCHES)} 个弄坏开关逐个打开，各自红在点名的样本上")
    return 0


def main(arguments: list) -> int:
    if arguments == ["--selftest"]:
        return selftest()
    if arguments == ["--hook"]:
        return run_hook()
    if not arguments or arguments[0] != "--check" or len(arguments) > 2:
        print("  ✗ 用法：code-length.py --check [仓库根]、code-length.py --hook，或 code-length.py --selftest")
        print("     → 怎么办：门禁里跑 --check，钩子里跑 --hook，改了这份脚本先跑 --selftest。")
        return EXIT_USAGE
    repository_root = pathlib.Path(arguments[1]) if len(arguments) == 2 else SOURCE_FILES.default_root()
    return run_check(repository_root.resolve())


if __name__ == "__main__":
    preflight(__file__)
    sys.exit(main(sys.argv[1:]))
