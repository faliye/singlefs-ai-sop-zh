#!/usr/bin/env python3
# gate-similar: shell-lint.sh 它按正则判 shell 脚本；这一道要解析 Rust 与 Python 的循环体（抹字符串、配花括号、走 ast），语言与解析法都不同
# gate-similar: link-targets.py 读 .claude/doc-lint-exclude 的函数，它、这一道与 number-name-sync.sh 各写了一份，三份已经分叉；抽成共用要先定哪一份的行为对，没在加查重门禁的这一次动它们
"""读子进程输出的循环里，不许一边给行打时间戳、一边把行转打出去。

用法：
    relay-timing-lint.py --check [仓库根]   # 扫 research/ 与 crates/ 下的 .rs 与 .py，逐处报「文件:行」与循环头
    relay-timing-lint.py --selftest         # 自证：内嵌红绿样本逐个判、钉死统计数；再另起一个子进程在弱判据下跑自证，它必须判红

为什么要有它：E152（按里程碑对比六家文件系统的文件性能） 的来宾程序在 `for line in BufReader::new(child_output).lines()` 里
先 `started.elapsed()` 给这一行打时间戳、再 `emitter.emit(...)` 把它转打出去，拿行到达时刻之差当分段挂钟。
虚机里标准输出是串口，转打一次阻塞几毫秒，而子进程写管道不被挡，于是时间戳里混进了前面几行的打印积压：
产物里连着打出、中间只有几微秒计算的几行，时间戳跨了 21.7–25.8 ms；两次跑 10 轮里 9 轮，外层算出的第二个事务挂钟
小于子进程自己计的时间，物理上不可能（2026-09-17 实测）。

判据（Rust，先把字符串、字符字面量与注释抹成空白，再按花括号配对取循环体）：
  ① 这个循环在读子进程输出：`for … in <表达式>` 的表达式或 `while` 的条件里有 `.lines()`、`.read_line(`、`.read_until(`，
     或者有一个在同一函数里用 `let` 绑到 `….lines()` 迭代器上的名字；`loop` 的循环体里有 `.read_line(`、`.read_until(`、
     `.lines().next()` 或那个名字的 `.next()`。并且最内层的 fn 里出现 `Stdio::piped()`、`.stdout.take()`、`.stderr.take()`、
     `child.stdout`、`ChildStdout`、`ChildStderr` 之一；或者这个 fn 在同一文件里被一个带这些标记的 fn 调用，
     实参里出现了输出流标记（上面除 `Stdio::piped()` 外那几个）、或出现了调用方经 `let` 从输出流派生出来的名字（只传一层）。
  ② 循环头加循环体里同时有取时间（`.elapsed(`、`Instant::now(`、`SystemTime::now(`）与输出（`println!`、`print!`、`eprintln!`、
     `eprint!`、`writeln!`、`write!`、`.emit(`、`.write_all(`、`.flush(`）⇒ 红。
判据（Python，用 ast 解析，字符串里的代码不算）：`for` 的迭代对象里有 `<进程>.stdout` 或 `.stderr`（`sys.stdout` 不算），
  或 `while` 里调了 `<进程>.stdout.readline()`；循环头加循环体里同时调了 `time.monotonic`、`time.perf_counter`、`time.time`
  （含 `_ns` 版与 from-import 进来的裸名）与 `print(`、`.write(`、`.writelines(`、`.flush(` ⇒ 红。
豁免：循环头那一行或上一行写 `// relay-timing-lint:allow <理由>`（Python 写 `# relay-timing-lint:allow <理由>`），理由为空判红。

够不着的写法（不判，不等于通过）：
  - 输出藏在自己写的函数里：循环体只调 `relay_line(...)`，打印在那个函数里面；
  - 子进程输出跨文件传进另一个函数，或者传了两层以上（F 传给 G、G 再传给 H），而最里面那个函数自己没有子进程标记；
    输出流不经 `let` 而经结构体字段、闭包捕获或 `if let` / `match` 绑定传出去的，也认不出；
  - 读线程把行经通道送出、收的那一侧一边取时间一边打印：收的一侧不认作读子进程输出；
  - `loop` 套着内层循环时，外层与内层可能各报一次；宏展开出来的循环；shell 装置（`while read` 配 `date`）不查。

不扫：`research/prompts/` 与 `research/results/`。那两处是原样保存的证据，门禁不许逼人回去改原件
（`.claude/singlefs-ai-sop/rules/evidence-discipline.md`「原样保存的证据不许事后改」）；没扫的文件数与解析不了的文件在统计里现算报出。

RELAY_TIMING_LINT_IGNORE_OUTPUT=1 强制走「只看取时间、不看输出调用」的弱判据，--selftest 在它下面必须判红。

退出码：0 通过；1 有红（或自证失败）；2 参数问题；77 一个 .rs / .py 都没扫到，本轮无对象可判。
"""
from __future__ import annotations

import ast
import contextlib
import dataclasses
import io
import os
import pathlib
import re
import subprocess
import sys
import tempfile
from typing import Optional

# 扫哪几个顶层目录：不给就扫仓根下**所有**目录（跳过 SKIP_DIRECTORIES 那几个）。
# 项目的源码与装置住在哪由项目定，上游脚本不写死它的目录名。
SCANNED_TOP_DIRECTORIES = ()
SKIP_DIRECTORIES = {".git", "node_modules", "target", "fixtures"}


def _frozen_evidence_directories(root="."):
    """原样保存的证据不扫：门禁不许逼人回去改原件，那只会把证据链弄断或让检查被绕过
    （rules/evidence-discipline.md「门禁也得绕开这批目录」）。
    清单读项目根的 .claude/doc-lint-exclude，与 doc-lint 用的是同一份，不另抄一份。
    """
    out = []
    try:
        with open(os.path.join(str(root), ".claude/doc-lint-exclude"), encoding="utf-8") as handle:
            for line in handle:
                line = line.split("#")[0].strip()
                if line:
                    out.append(line.rstrip("/"))
    except OSError:
        pass
    return tuple(out)


FROZEN_EVIDENCE_DIRECTORIES = ()
SKIPPED_DIRECTORY_NAMES = (".git", "target", "node_modules", "__pycache__")
SCANNED_SUFFIXES = (".rs", ".py")
WEAK_MODE_ENVIRONMENT_VARIABLE = "RELAY_TIMING_LINT_IGNORE_OUTPUT"
ALLOW_MARKER = "relay-timing-lint:allow"

RUST_CHILD_PROCESS_MARKER = re.compile(
    r"\bStdio\s*::\s*piped\s*\(\s*\)|\.\s*stdout\s*\.\s*take\s*\(\s*\)|\.\s*stderr\s*\.\s*take\s*\(\s*\)"
    r"|\bchild\s*\.\s*stdout\b|\bChildStdout\b|\bChildStderr\b"
)
RUST_CHILD_STREAM_MARKER = re.compile(
    r"\.\s*stdout\s*\.\s*take\s*\(\s*\)|\.\s*stderr\s*\.\s*take\s*\(\s*\)|\bchild\s*\.\s*stdout\b|\bChildStdout\b|\bChildStderr\b"
)
RUST_READ_CALL_IN_LOOP_HEADER = re.compile(r"\.\s*lines\s*\(\s*\)|\.\s*read_line\s*\(|\.\s*read_until\s*\(")
RUST_READ_CALL_IN_LOOP_BODY = re.compile(r"\.\s*read_line\s*\(|\.\s*read_until\s*\(|\.\s*lines\s*\(\s*\)\s*\.\s*next\s*\(")
RUST_TIMING_CALL = re.compile(r"\.\s*elapsed\s*\(|\bInstant\s*::\s*now\s*\(|\bSystemTime\s*::\s*now\s*\(")
RUST_OUTPUT_CALL = re.compile(r"\b(?:println|print|eprintln|eprint|writeln|write)\s*!|\.\s*(?:emit|write_all|flush)\s*\(")
RUST_FUNCTION_KEYWORD = re.compile(r"\bfn\s+([A-Za-z_][A-Za-z0-9_]*)")
RUST_LOOP_KEYWORD = re.compile(r"\b(for|while|loop)\b")
RUST_IN_KEYWORD = re.compile(r"\bin\b")
RUST_LET_BINDING = re.compile(r"\blet\s+(?:mut\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*(?::[^=;]*)?=([^;]*);")
RUST_LINES_ITERATOR = re.compile(r"\.\s*lines\s*\(\s*\)")
RUST_ITERATOR_CONSUMER = re.compile(
    r"\.\s*(?:collect|count|last|nth|next|find|find_map|fold|for_each|any|all|position|max|min|sum)\b"
)
RUST_RAW_STRING_START = re.compile(r'b?r(#*)"')

PYTHON_TIMING_ATTRIBUTES = {"monotonic", "perf_counter", "time", "monotonic_ns", "perf_counter_ns", "time_ns"}
PYTHON_TIMING_BARE_NAMES = {"monotonic", "perf_counter", "monotonic_ns", "perf_counter_ns"}
PYTHON_OUTPUT_ATTRIBUTES = {"write", "writelines", "flush"}

RELAY_TIMING_REMEDY = (
    "转打会阻塞（虚机里标准输出是串口），子进程写管道不被挡，行到达的时间戳里就混进前面几行的打印积压。"
    "四条出路：① 在被测进程里自己计时，把时间写进它的结果行；② 先把子进程输出整份读完（或者读线程只打时间戳、经通道送出，不打印），"
    "读完再转打；③ 真要按到达时刻计时，读循环里只记时间与行，打印挪到循环外面；"
    "④ 这个循环的时间确实不进计时结论，就在循环头那一行或上一行写 // relay-timing-lint:allow <理由>（Python 写 # relay-timing-lint:allow <理由>）。"
)


@dataclasses.dataclass
class ChildOutputLoop:
    relative_path: str
    line_number: int
    loop_head: str
    timing_call: Optional[str]
    output_call: Optional[str]
    allow_reason: Optional[str]  # None：没写豁免；""：写了豁免但没写理由


@dataclasses.dataclass
class ScanResult:
    scanned_file_count: int
    frozen_file_counts: dict
    unparsable_files: list
    child_output_loops: list


def weak_mode_enabled() -> bool:
    return os.environ.get(WEAK_MODE_ENVIRONMENT_VARIABLE) == "1"


def allow_reason_near(raw_lines: list, line_number: int) -> Optional[str]:
    """循环头那一行或上一行的豁免注释；返回理由（可能是空串），没有豁免返回 None。"""
    for candidate_line_number in (line_number, line_number - 1):
        if 1 <= candidate_line_number <= len(raw_lines):
            text = raw_lines[candidate_line_number - 1]
            marker_at = text.find(ALLOW_MARKER)
            if marker_at != -1:
                return text[marker_at + len(ALLOW_MARKER):].strip()
    return None


def previous_is_identifier_character(source: str, position: int) -> bool:
    return position > 0 and (source[position - 1].isalnum() or source[position - 1] == "_")


def mask_rust_literals_and_comments(source: str) -> str:
    """字符串、字符字面量与注释抹成空白、换行留着：偏移与行号不变，字面量里的括号与关键字不会带偏配对与匹配。"""
    characters = list(source)
    length = len(source)

    def blank(start: int, end: int) -> None:
        for index in range(start, min(end, length)):
            if characters[index] != "\n":
                characters[index] = " "

    position = 0
    while position < length:
        current = source[position]
        following = source[position + 1] if position + 1 < length else ""
        if current == "/" and following == "/":
            end = source.find("\n", position)
            end = length if end == -1 else end
            blank(position, end)
            position = end
            continue
        if current == "/" and following == "*":
            depth = 1
            cursor = position + 2
            while cursor < length and depth > 0:
                if source.startswith("/*", cursor):
                    depth += 1
                    cursor += 2
                elif source.startswith("*/", cursor):
                    depth -= 1
                    cursor += 2
                else:
                    cursor += 1
            blank(position, cursor)
            position = cursor
            continue
        raw_string_match = RUST_RAW_STRING_START.match(source, position)
        if raw_string_match and not previous_is_identifier_character(source, position):
            terminator = '"' + raw_string_match.group(1)
            end = source.find(terminator, raw_string_match.end())
            end = length if end == -1 else end + len(terminator)
            blank(position, end)
            position = end
            continue
        starts_byte_literal = current == "b" and not previous_is_identifier_character(source, position)
        if current == '"' or (starts_byte_literal and following == '"'):
            cursor = position + (2 if current == "b" else 1)
            while cursor < length and source[cursor] != '"':
                cursor += 2 if source[cursor] == "\\" else 1
            end = cursor + 1
            blank(position, end)
            position = end
            continue
        if current == "'" or (starts_byte_literal and following == "'"):
            content_start = position + (1 if current == "'" else 2)
            if content_start < length and source[content_start] == "\\":
                closing = source.find("'", content_start + 2)
                end = length if closing == -1 else closing + 1
                blank(position, end)
                position = end
                continue
            if content_start + 1 < length and source[content_start + 1] == "'":
                blank(position, content_start + 2)
                position = content_start + 2
                continue
            position += 1  # 生命周期或循环标签，不是字面量
            continue
        position += 1
    return "".join(characters)


def find_block_open(masked: str, start: int) -> Optional[int]:
    """从 start 往后找圆括号、方括号之外的第一个 `{`；先碰到 `;` 说明没有块（例如只有声明的 fn），返回 None。"""
    bracket_depth = 0
    for index in range(start, len(masked)):
        character = masked[index]
        if character in "([":
            bracket_depth += 1
        elif character in ")]":
            bracket_depth = max(0, bracket_depth - 1)
        elif bracket_depth == 0 and character == ";":
            return None
        elif bracket_depth == 0 and character == "{":
            return index
    return None


def matching_close_brace(masked: str, open_index: int) -> int:
    depth = 0
    for index in range(open_index, len(masked)):
        if masked[index] == "{":
            depth += 1
        elif masked[index] == "}":
            depth -= 1
            if depth == 0:
                return index
    return len(masked) - 1


def collapse_whitespace(text: str, limit: int = 140) -> str:
    collapsed = " ".join(text.split())
    return collapsed if len(collapsed) <= limit else collapsed[: limit - 1] + "…"


def rust_lines_bound_names(function_text: str) -> set:
    names = set()
    for binding in RUST_LET_BINDING.finditer(function_text):
        initializer = binding.group(2)
        if RUST_LINES_ITERATOR.search(initializer) and not RUST_ITERATOR_CONSUMER.search(initializer):
            names.add(binding.group(1))
    return names


def mentions_any_name(text: str, names: set) -> Optional[str]:
    for name in sorted(names):
        if re.search(r"\b" + re.escape(name) + r"\b", text):
            return name
    return None


def matching_close_parenthesis(masked: str, open_index: int) -> int:
    depth = 0
    for index in range(open_index, len(masked)):
        if masked[index] == "(":
            depth += 1
        elif masked[index] == ")":
            depth -= 1
            if depth == 0:
                return index
    return len(masked) - 1


def functions_receiving_child_output(masked: str, function_spans: list) -> dict:
    """同一文件里、从带子进程标记的函数那儿接过子进程输出的函数：名字 → 传进来的那个函数名。只传一层。

    认法：带标记的函数 F 里，调用同文件另一个函数 G 的实参里出现子进程标记，或出现 F 里经 `let` 从子进程输出流派生出来的名字
    （`let child_output = child.stdout.take()…`、再 `let reader = BufReader::new(child_output)`，两个都算）。
    `Stdio::piped()` 绑的是子进程句柄不是输出流，不从它派生，免得 `let status = child.wait()` 之类也被算进来。
    """
    function_names = {name for name, _start, _end in function_spans}
    receivers = {}
    for caller_name, caller_start, caller_end in function_spans:
        caller_text = masked[caller_start:caller_end + 1]
        if not RUST_CHILD_PROCESS_MARKER.search(caller_text):
            continue
        bindings = [(binding.group(1), binding.group(2)) for binding in RUST_LET_BINDING.finditer(caller_text)]
        child_stream_names = set()
        grew = True
        while grew:  # 至多每个 let 加一次名字，轮数不超过 let 的个数加一
            grew = False
            for bound_name, initializer in bindings:
                if bound_name not in child_stream_names and (
                        RUST_CHILD_STREAM_MARKER.search(initializer) or mentions_any_name(initializer, child_stream_names)):
                    child_stream_names.add(bound_name)
                    grew = True
        for callee_name in sorted(function_names - {caller_name}):
            for call_match in re.finditer(r"\b" + re.escape(callee_name) + r"\s*(?:::\s*<[^()]*>\s*)?\(", caller_text):
                open_parenthesis = call_match.end() - 1
                arguments = caller_text[open_parenthesis:matching_close_parenthesis(caller_text, open_parenthesis) + 1]
                if RUST_CHILD_STREAM_MARKER.search(arguments) or mentions_any_name(arguments, child_stream_names):
                    receivers.setdefault(callee_name, caller_name)
    return receivers


def analyze_rust(relative_path: str, source: str) -> list:
    masked = mask_rust_literals_and_comments(source)
    raw_lines = source.split("\n")
    function_spans = []
    for function_match in RUST_FUNCTION_KEYWORD.finditer(masked):
        open_index = find_block_open(masked, function_match.end())
        if open_index is not None:
            function_spans.append((function_match.group(1), function_match.start(), matching_close_brace(masked, open_index)))
    receivers = functions_receiving_child_output(masked, function_spans)
    child_output_loops = []
    for loop_match in RUST_LOOP_KEYWORD.finditer(masked):
        keyword = loop_match.group(1)
        keyword_start = loop_match.start()
        open_index = find_block_open(masked, loop_match.end())
        if open_index is None:
            continue
        header = masked[loop_match.end():open_index]
        if keyword == "loop" and header.strip():
            continue
        enclosing_spans = [span for span in function_spans if span[1] <= keyword_start <= span[2]]
        if enclosing_spans:
            innermost_name, innermost_start, innermost_end = max(enclosing_spans, key=lambda span: span[1])
            function_text = masked[innermost_start:innermost_end + 1]
        else:
            innermost_name = None
            function_text = masked
        close_index = matching_close_brace(masked, open_index)
        body = masked[open_index:close_index + 1]
        bound_names = rust_lines_bound_names(function_text)
        if keyword == "for":
            in_match = RUST_IN_KEYWORD.search(header)
            if in_match is None:
                continue  # `impl Trait for Type {` 之类，不是 for 循环
            iterated_expression = header[in_match.end():]
            reads_lines = bool(RUST_READ_CALL_IN_LOOP_HEADER.search(iterated_expression)) or mentions_any_name(iterated_expression, bound_names) is not None
        elif keyword == "while":
            reads_lines = bool(RUST_READ_CALL_IN_LOOP_HEADER.search(header)) or mentions_any_name(header, bound_names) is not None
        else:
            reads_lines = bool(RUST_READ_CALL_IN_LOOP_BODY.search(body)) or any(
                re.search(r"\b" + re.escape(name) + r"\s*\.\s*next\s*\(", body) for name in bound_names
            )
        if not reads_lines:
            continue
        if not RUST_CHILD_PROCESS_MARKER.search(function_text) and innermost_name not in receivers:
            continue
        region = masked[keyword_start:close_index + 1]
        timing_match = RUST_TIMING_CALL.search(region)
        output_match = RUST_OUTPUT_CALL.search(region)
        line_number = masked.count("\n", 0, keyword_start) + 1
        passed_from = receivers.get(innermost_name) if not RUST_CHILD_PROCESS_MARKER.search(function_text) else None
        loop_head = collapse_whitespace(source[keyword_start:open_index + 1])
        child_output_loops.append(ChildOutputLoop(
            relative_path=relative_path,
            line_number=line_number,
            loop_head=loop_head + (f"（子进程输出由 {passed_from} 传入 {innermost_name}）" if passed_from else ""),
            timing_call=collapse_whitespace(timing_match.group(0)) if timing_match else None,
            output_call=collapse_whitespace(output_match.group(0)) if output_match else None,
            allow_reason=allow_reason_near(raw_lines, line_number),
        ))
    return child_output_loops


def is_process_stream_attribute(node: ast.AST) -> bool:
    return (isinstance(node, ast.Attribute) and node.attr in ("stdout", "stderr")
            and not (isinstance(node.value, ast.Name) and node.value.id == "sys"))


def contains_process_stream(node: ast.AST) -> bool:
    return any(is_process_stream_attribute(child) for child in ast.walk(node))


def is_process_readline_call(node: ast.AST) -> bool:
    return (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and node.func.attr == "readline"
            and contains_process_stream(node.func.value))


def python_timing_label(call: ast.Call) -> Optional[str]:
    function = call.func
    if isinstance(function, ast.Attribute) and isinstance(function.value, ast.Name) and function.value.id == "time" \
            and function.attr in PYTHON_TIMING_ATTRIBUTES:
        return f"time.{function.attr}("
    if isinstance(function, ast.Name) and function.id in PYTHON_TIMING_BARE_NAMES:
        return f"{function.id}("
    return None


def python_output_label(call: ast.Call) -> Optional[str]:
    function = call.func
    if isinstance(function, ast.Name) and function.id == "print":
        return "print("
    if isinstance(function, ast.Attribute) and function.attr in PYTHON_OUTPUT_ATTRIBUTES:
        return f".{function.attr}("
    return None


def first_call_label(roots: list, labeler) -> Optional[str]:
    for root in roots:
        for child in ast.walk(root):
            if isinstance(child, ast.Call):
                label = labeler(child)
                if label is not None:
                    return label
    return None


def analyze_python(relative_path: str, source: str) -> list:
    tree = ast.parse(source)
    raw_lines = source.split("\n")
    child_output_loops = []
    for node in ast.walk(tree):
        if isinstance(node, (ast.For, ast.AsyncFor)) and contains_process_stream(node.iter):
            scanned_roots = [node.iter] + list(node.body)
        elif isinstance(node, ast.While) and any(is_process_readline_call(child) for child in ast.walk(node)):
            scanned_roots = [node.test] + list(node.body)
        else:
            continue
        line_number = node.lineno
        child_output_loops.append(ChildOutputLoop(
            relative_path=relative_path,
            line_number=line_number,
            loop_head=collapse_whitespace(raw_lines[line_number - 1]),
            timing_call=first_call_label(scanned_roots, python_timing_label),
            output_call=first_call_label(scanned_roots, python_output_label),
            allow_reason=allow_reason_near(raw_lines, line_number),
        ))
    return child_output_loops


def scan(root: pathlib.Path) -> ScanResult:
    scanned_file_count = 0
    # 冻结证据的清单按**被扫那个仓**现算：射程与排除表都不写死在这里。
    frozen_directories = _frozen_evidence_directories(root)
    frozen_file_counts = {directory: 0 for directory in frozen_directories}
    unparsable_files = []
    child_output_loops = []
    # 不给顶层目录就扫仓根下所有目录：项目的源码与装置住在哪由项目定。
    top_directories = SCANNED_TOP_DIRECTORIES or tuple(
        name for name in sorted(os.listdir(root))
        if (root / name).is_dir() and name not in SKIP_DIRECTORIES and not name.startswith(".")
    ) + tuple(
        name for name in sorted(os.listdir(root))
        if (root / name).is_dir() and name.startswith(".claude")
    )
    for top_directory in top_directories:
        for directory, subdirectories, files in os.walk(root / top_directory):
            subdirectories[:] = sorted(name for name in subdirectories if name not in SKIPPED_DIRECTORY_NAMES)
            for file_name in sorted(files):
                if not file_name.endswith(SCANNED_SUFFIXES):
                    continue
                relative_path = (pathlib.Path(directory) / file_name).relative_to(root).as_posix()
                frozen_directory = next((frozen for frozen in frozen_directories if relative_path.startswith(frozen + "/")), None)
                if frozen_directory is not None:
                    frozen_file_counts[frozen_directory] += 1
                    continue
                try:
                    source = (root / relative_path).read_text(encoding="utf-8")
                    if file_name.endswith(".rs"):
                        loops = analyze_rust(relative_path, source)
                    else:
                        loops = analyze_python(relative_path, source)
                except (UnicodeDecodeError, OSError, SyntaxError, ValueError):
                    unparsable_files.append(relative_path)
                    continue
                scanned_file_count += 1
                child_output_loops.extend(loops)
    return ScanResult(scanned_file_count, frozen_file_counts, unparsable_files, child_output_loops)


def is_hit(child_output_loop: ChildOutputLoop) -> bool:
    if weak_mode_enabled():
        return child_output_loop.timing_call is not None
    return child_output_loop.timing_call is not None and child_output_loop.output_call is not None


def run(root: pathlib.Path) -> int:
    result = scan(root)
    if weak_mode_enabled():
        print(f"  ! {WEAK_MODE_ENVIRONMENT_VARIABLE}=1：弱判据，只看取时间、不看输出调用（自证专用，门禁里不许设）")
    hits = [loop for loop in result.child_output_loops if is_hit(loop)]
    exempted = [loop for loop in hits if loop.allow_reason]
    unexempted = [loop for loop in hits if loop.allow_reason is None]
    empty_reasons = [loop for loop in result.child_output_loops if loop.allow_reason == ""]
    frozen_text = "、".join(f"{directory} 里 {count} 个（冻结证据）" for directory, count in result.frozen_file_counts.items())
    unparsable_text = f"解析不了的 {len(result.unparsable_files)} 个" + (
        "（" + "、".join(result.unparsable_files) + "）" if result.unparsable_files else "")
    statistics = (f"扫了 {result.scanned_file_count} 个文件、{len(result.child_output_loops)} 个读子进程输出的循环、"
                  f"豁免 {len(exempted)} 处；没扫：{frozen_text}、{unparsable_text}")
    if result.scanned_file_count == 0:
        print(f"  ! research/ 与 crates/ 下没有可扫的 .rs / .py，本轮无对象可判（{statistics}）")
        return 77
    failed = False
    if unexempted:
        failed = True
        for loop in unexempted:
            print(f"      {loop.relative_path}:{loop.line_number}  {loop.loop_head}  "   # gate-lint:detail
                  f"取时间 {loop.timing_call}  输出 {loop.output_call}")
        print(f"  ✗ 有 {len(unexempted)} 处读子进程输出的循环一边给行打时间戳一边转打（{statistics}）")
        print(f"     → 怎么办：{RELAY_TIMING_REMEDY}")
    if empty_reasons:
        failed = True
        for loop in empty_reasons:
            print(f"      {loop.relative_path}:{loop.line_number}  {loop.loop_head}  豁免注释没写理由")   # gate-lint:detail
        print(f"  ✗ 有 {len(empty_reasons)} 处 {ALLOW_MARKER} 后面没写理由（{statistics}）")
        print("     → 怎么办：在 allow 后面写清这个循环的时间戳为什么不受转打阻塞影响（例如时间只拿来判超时、不进任何计时结论）；"
              "写不出理由就别豁免，按「读子进程输出的循环一边打时间戳一边转打」那条的出路改写法。")
    if failed:
        return 1
    print(f"  ✓ 没有读子进程输出的循环一边给行打时间戳一边转打（{statistics}）")
    return 0


RUST_RELAY_WHILE_READING = """use std::io::{BufRead, BufReader};
use std::process::{Command, Stdio};
use std::time::Instant;

fn run_child_and_relay_lines(emitter: &mut Emitter) {
    let started = Instant::now();
    let mut child = Command::new("child-binary").stdout(Stdio::piped()).spawn().expect("子进程起得来");
    let child_output = child.stdout.take().expect("刚用 Stdio::piped() 起的子进程一定有 stdout");
    for line in BufReader::new(child_output).lines() {
        let line = line.expect("读得出一行");
        let at_nanoseconds = started.elapsed().as_nanos();
        emitter.emit("inner", &format!("at_nanoseconds={at_nanoseconds} {line}"));
    }
}
"""

RUST_READ_ALL_THEN_RELAY = """use std::io::{BufRead, BufReader};
use std::process::{Command, Stdio};
use std::time::Instant;

fn run_child_then_relay_lines() {
    let started = Instant::now();
    let mut child = Command::new("child-binary").stdout(Stdio::piped()).spawn().expect("子进程起得来");
    let child_output = child.stdout.take().expect("刚用 Stdio::piped() 起的子进程一定有 stdout");
    let mut arrived_lines: Vec<(u128, String)> = Vec::new();
    for line in BufReader::new(child_output).lines() {
        let line = line.expect("读得出一行");
        arrived_lines.push((started.elapsed().as_nanos(), line));
    }
    child.wait().expect("子进程收得了尾");
    for (at_nanoseconds, line) in arrived_lines {
        println!("at_nanoseconds={at_nanoseconds} {line}");
    }
}
"""

RUST_TIMING_ONLY_NO_PRINT = """use std::io::{BufRead, BufReader};
use std::process::{ChildStdout};
use std::time::Instant;

fn record_arrival_times(child_output: ChildStdout, started: Instant) -> Vec<(u128, String)> {
    let mut arrived_lines = Vec::new();
    for line in BufReader::new(child_output).lines() {
        arrived_lines.push((started.elapsed().as_nanos(), line.expect("读得出一行")));
    }
    arrived_lines
}
"""

RUST_NOT_CHILD_OUTPUT_BESIDE_RELAY = """use std::io::{BufRead, BufReader};
use std::process::{Command, Stdio};
use std::time::Instant;

fn read_process_io_counters_with_timestamps() {
    let started = Instant::now();
    let counter_text = std::fs::read_to_string("/proc/self/io").expect("这里没有 Stdio::piped() 起的子进程，括号 { 不配对也不该带偏");
    // 注释里写 child.stdout.take() 与 { 也不算
    for line in counter_text.lines() {
        let at_nanoseconds = started.elapsed().as_nanos();
        println!("at_nanoseconds={at_nanoseconds} {line}");
    }
}

fn run_child_and_relay_lines() {
    let started = Instant::now();
    let mut child = Command::new("child-binary").stdout(Stdio::piped()).spawn().expect("子进程起得来");
    let child_output = child.stdout.take().expect("有 stdout");
    for line in BufReader::new(child_output).lines() {
        println!("at_nanoseconds={} {}", started.elapsed().as_nanos(), line.expect("读得出一行"));
    }
}
"""

RUST_WHILE_LET_OVER_BOUND_LINES = """use std::io::{BufRead, BufReader, Write};
use std::process::{Command, Stdio};
use std::time::Instant;

fn relay_with_while_let() {
    let mut child = Command::new("child-binary").stdout(Stdio::piped()).spawn().expect("子进程起得来");
    let mut child_lines = BufReader::new(child.stdout.take().expect("有 stdout")).lines();
    let mut standard_output = std::io::stdout();
    while let Some(line) = child_lines.next() {
        let arrived_at = Instant::now();
        writeln!(standard_output, "{:?} {}", arrived_at, line.expect("读得出一行")).expect("写得出去");
    }
}
"""

RUST_TIMING_IN_HEADER_AND_LOOP_READ_LINE = """use std::io::{BufRead, BufReader};
use std::process::{Command, Stdio};
use std::time::Instant;

fn relay_with_timestamp_in_iterator() {
    let started = Instant::now();
    let mut child = Command::new("child-binary").stdout(Stdio::piped()).spawn().expect("子进程起得来");
    let child_output = child.stdout.take().expect("有 stdout");
    for (at_nanoseconds, line) in BufReader::new(child_output).lines().map(|line| (started.elapsed().as_nanos(), line)) {
        println!("at_nanoseconds={at_nanoseconds} {}", line.expect("读得出一行"));
    }
}

fn relay_with_read_line_loop() {
    let started = Instant::now();
    let mut child = Command::new("child-binary").stdout(Stdio::piped()).spawn().expect("子进程起得来");
    let mut reader = BufReader::new(child.stdout.take().expect("有 stdout"));
    loop {
        let mut buffer = String::new();
        if reader.read_line(&mut buffer).expect("读得出一行") == 0 {
            break;
        }
        eprint!("{} {}", started.elapsed().as_nanos(), buffer);
    }
}
"""

RUST_READER_THREAD_THEN_PRINT = """use std::io::{BufRead, BufReader};
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::time::Instant;

fn relay_through_reader_thread() {
    let started = Instant::now();
    let mut child = Command::new("child-binary").stdout(Stdio::piped()).spawn().expect("子进程起得来");
    let child_output = child.stdout.take().expect("有 stdout");
    let (sender, receiver) = mpsc::channel();
    let reader_thread = std::thread::spawn(move || {
        for line in BufReader::new(child_output).lines() {
            sender.send((started.elapsed().as_nanos(), line.expect("读得出一行"))).expect("收的一侧还在");
        }
    });
    for (at_nanoseconds, line) in receiver {
        println!("at_nanoseconds={at_nanoseconds} {line}");
    }
    reader_thread.join().expect("读线程收得了尾");
}
"""

RUST_CODE_ONLY_IN_STRINGS = r'''use std::process::{Command, Stdio};

fn sample_text_only() {
    let mut child = Command::new("child-binary").stdout(Stdio::piped()).spawn().expect("子进程起得来");
    let example = r#"for line in reader.lines() { started.elapsed(); println!("{line}"); }"#;
    /* for line in reader.lines() { started.elapsed(); println!("{line}"); } */
    let _ = (example, child.wait());
}
'''

RUST_ALLOW_WITH_REASON = """use std::io::{BufRead, BufReader};
use std::process::{Command, Stdio};
use std::time::Instant;

fn relay_with_timeout_check() {
    let started = Instant::now();
    let mut child = Command::new("child-binary").stdout(Stdio::piped()).spawn().expect("子进程起得来");
    // relay-timing-lint:allow 时间只拿来判超时，不进任何计时结论
    for line in BufReader::new(child.stdout.take().expect("有 stdout")).lines() {
        if started.elapsed().as_secs() > 600 {
            break;
        }
        println!("{}", line.expect("读得出一行"));
    }
}
"""

RUST_ALLOW_WITHOUT_REASON = RUST_ALLOW_WITH_REASON.replace(" 时间只拿来判超时，不进任何计时结论", "")

RUST_HELPER_RELAYS_WHILE_READING = """use std::io::{BufRead, BufReader};
use std::process::{Command, Stdio};
use std::time::Instant;

fn relay_lines_as_they_arrive<Reader: BufRead>(reader: Reader, started: Instant) {
    for line in reader.lines() {
        println!("at_nanoseconds={} {}", started.elapsed().as_nanos(), line.expect("读得出一行"));
    }
}

fn run_child_through_helper() {
    let started = Instant::now();
    let mut child = Command::new("child-binary").stdout(Stdio::piped()).spawn().expect("子进程起得来");
    let child_output = child.stdout.take().expect("有 stdout");
    let reader = BufReader::new(child_output);
    relay_lines_as_they_arrive(reader, started);
    let status = child.wait().expect("子进程收得了尾");
    summarize_text_lines(&status.to_string(), started);
}

fn summarize_text_lines(text: &str, started: Instant) {
    for line in text.lines() {
        println!("{} {line}", started.elapsed().as_nanos());
    }
}
"""

RUST_HELPER_READS_TO_END_THEN_CALLER_RELAYS = """use std::io::{BufRead, BufReader};
use std::process::{Command, Stdio};
use std::time::Instant;

struct ArrivedLine {
    at_nanoseconds: u128,
    text: String,
}

fn read_lines_with_arrival_times<Reader: BufRead>(reader: Reader, started: Instant) -> std::io::Result<Vec<ArrivedLine>> {
    let mut arrived_lines = Vec::new();
    for line in reader.lines() {
        let text = line?;
        arrived_lines.push(ArrivedLine { at_nanoseconds: started.elapsed().as_nanos(), text });
    }
    Ok(arrived_lines)
}

fn run_child_then_relay_through_helper() {
    let started = Instant::now();
    let mut child = Command::new("child-binary").stdout(Stdio::piped()).spawn().expect("子进程起得来");
    let child_output = child.stdout.take().expect("刚用 Stdio::piped() 起的子进程一定有 stdout");
    let arrived_lines = read_lines_with_arrival_times(BufReader::new(child_output), started).expect("读得完");
    child.wait().expect("子进程收得了尾");
    for arrived_line in arrived_lines {
        println!("at_nanoseconds={} {}", arrived_line.at_nanoseconds, arrived_line.text);
    }
}
"""

PYTHON_RELAY_WHILE_READING = """import subprocess
import sys
import time


def relay_child_lines():
    started = time.monotonic()
    process = subprocess.Popen(["child-binary"], stdout=subprocess.PIPE, text=True)
    for line in process.stdout:
        at_seconds = time.monotonic() - started
        print(f"at_seconds={at_seconds} {line}", end="")
    process.wait()


def relay_with_readline():
    from time import perf_counter
    process = subprocess.Popen(["child-binary"], stdout=subprocess.PIPE, text=True)
    while True:
        line = process.stdout.readline()
        if not line:
            break
        sys.stdout.write(f"{perf_counter()} {line}")
"""

PYTHON_READ_ALL_THEN_RELAY = '''import subprocess
import time

EXAMPLE = """
for line in process.stdout:
    print(time.monotonic(), line)
"""


def read_then_relay_child_lines():
    started = time.monotonic()
    process = subprocess.Popen(["child-binary"], stdout=subprocess.PIPE, text=True)
    arrived_lines = []
    for line in process.stdout:
        arrived_lines.append((time.monotonic() - started, line))
    process.wait()
    for at_seconds, line in arrived_lines:
        print(f"at_seconds={at_seconds} {line}", end="")


def read_process_io_counters_with_timestamps():
    started = time.perf_counter()
    with open("/proc/self/io", encoding="utf-8") as counter_file:
        for line in counter_file:
            print(time.perf_counter() - started, line, end="")
'''

SELFTEST_CASES = [
    ("旧写法：读一行、打时间戳、转打，再读下一行（照 E152 的 run_singlefs）",
     {"research/sample/src/relay.rs": RUST_RELAY_WHILE_READING},
     "exit=1\nwant=research/sample/src/relay.rs:9\nwant=取时间 .elapsed(  输出 .emit(\n"
     "want=✗ 有 1 处读子进程输出的循环一边给行打时间戳一边转打（扫了 1 个文件、1 个读子进程输出的循环、豁免 0 处\n"
     "want=→ 怎么办"),
    ("先读进 Vec、读完再打印",
     {"research/sample/src/relay.rs": RUST_READ_ALL_THEN_RELAY},
     "exit=0\nwant=✓ 没有读子进程输出的循环一边给行打时间戳一边转打（扫了 1 个文件、1 个读子进程输出的循环、豁免 0 处"),
    ("只取时间不打印的循环（迭代器从参数 ChildStdout 进来）",
     {"research/sample/src/timing_only.rs": RUST_TIMING_ONLY_NO_PRINT},
     "exit=0\nwant=扫了 1 个文件、1 个读子进程输出的循环、豁免 0 处"),
    ("不是子进程输出的 lines() 循环（读 /proc/self/io），同一文件里另一个函数是旧写法；字符串与注释里的标记不算",
     {"research/sample/src/mixed.rs": RUST_NOT_CHILD_OUTPUT_BESIDE_RELAY},
     "exit=1\nwant=research/sample/src/mixed.rs:19\nwant=扫了 1 个文件、1 个读子进程输出的循环、豁免 0 处"),
    ("while let 读绑到 lines() 上的名字，Instant::now 加 writeln!",
     {"research/sample/src/while_let.rs": RUST_WHILE_LET_OVER_BOUND_LINES},
     "exit=1\nwant=research/sample/src/while_let.rs:9\nwant=取时间 Instant::now(  输出 writeln!\n"
     "want=扫了 1 个文件、1 个读子进程输出的循环、豁免 0 处"),
    ("时间戳打在迭代器的 map 里；loop 加 read_line",
     {"research/sample/src/header_and_loop.rs": RUST_TIMING_IN_HEADER_AND_LOOP_READ_LINE},
     "exit=1\nwant=research/sample/src/header_and_loop.rs:9\nwant=research/sample/src/header_and_loop.rs:18\n"
     "want=✗ 有 2 处\nwant=扫了 1 个文件、2 个读子进程输出的循环、豁免 0 处"),
    ("子进程输出经 let 派生后传给同文件的辅助函数，辅助函数一边打时间戳一边打印；不经输出流的调用不算",
     {"research/sample/src/helper.rs": RUST_HELPER_RELAYS_WHILE_READING},
     "exit=1\nwant=research/sample/src/helper.rs:6\nwant=（子进程输出由 run_child_through_helper 传入 relay_lines_as_they_arrive）\n"
     "want=✗ 有 1 处\nwant=扫了 1 个文件、1 个读子进程输出的循环、豁免 0 处"),
    ("辅助函数读到 EOF 只记时间，调用方读完再打印（照 E152 改过之后的形态）",
     {"research/sample/src/helper.rs": RUST_HELPER_READS_TO_END_THEN_CALLER_RELAYS},
     "exit=0\nwant=扫了 1 个文件、1 个读子进程输出的循环、豁免 0 处"),
    ("读线程只打时间戳经通道送出，收的一侧打印",
     {"research/sample/src/reader_thread.rs": RUST_READER_THREAD_THEN_PRINT},
     "exit=0\nwant=扫了 1 个文件、1 个读子进程输出的循环、豁免 0 处"),
    ("代码只出现在原始字符串与块注释里",
     {"research/sample/src/strings.rs": RUST_CODE_ONLY_IN_STRINGS},
     "exit=0\nwant=扫了 1 个文件、0 个读子进程输出的循环、豁免 0 处"),
    ("豁免写了理由",
     {"research/sample/src/allow.rs": RUST_ALLOW_WITH_REASON},
     "exit=0\nwant=扫了 1 个文件、1 个读子进程输出的循环、豁免 1 处"),
    ("豁免没写理由",
     {"research/sample/src/allow.rs": RUST_ALLOW_WITHOUT_REASON},
     "exit=1\nwant=research/sample/src/allow.rs:9\nwant=豁免注释没写理由\n"
     "want=✗ 有 1 处 relay-timing-lint:allow 后面没写理由（扫了 1 个文件、1 个读子进程输出的循环、豁免 0 处"),
    ("Python 旧写法：for line in process.stdout 与 while readline",
     {"research/scripts/relay.py": PYTHON_RELAY_WHILE_READING},
     "exit=1\nwant=research/scripts/relay.py:9\nwant=取时间 time.monotonic(  输出 print(\n"
     "want=research/scripts/relay.py:18\nwant=取时间 perf_counter(  输出 .write(\n"
     "want=扫了 1 个文件、2 个读子进程输出的循环、豁免 0 处"),
    ("Python 先读完再打印；读 /proc/self/io 的循环；字符串里的旧写法不算",
     {"research/scripts/relay.py": PYTHON_READ_ALL_THEN_RELAY},
     "exit=0\nwant=扫了 1 个文件、1 个读子进程输出的循环、豁免 0 处"),
    ("target/ 与冻结证据目录不扫，解析不了的 .py 列名；别的目录照扫",
     {# 冻结证据的清单与 doc-lint 共用一份，样本里也得有它，否则那两个目录会被照扫
      ".claude/doc-lint-exclude": "research/prompts/  # 当时原样发给模型的提示\nresearch/results/  # 跑出来的原始输出\n",
      "research/sample/target/debug/relay.rs": RUST_RELAY_WHILE_READING,
      "research/prompts/frozen-model/relay.rs": RUST_RELAY_WHILE_READING,
      "research/results/frozen-probe/relay.py": PYTHON_RELAY_WHILE_READING,
      "research/scripts/broken.py": "def broken(:\n",
      "crates/sample/src/relay.rs": RUST_READ_ALL_THEN_RELAY},
     "exit=0\nwant=扫了 1 个文件、1 个读子进程输出的循环、豁免 0 处；"
     "没扫：research/prompts 里 1 个（冻结证据）、research/results 里 1 个（冻结证据）、解析不了的 1 个（research/scripts/broken.py）"),
    ("一个 .rs / .py 都没有",
     {"research/notes.md": "没有源码\n"},
     "exit=77\nwant=本轮无对象可判"),
]


def run_selftest_cases() -> int:
    failures = []
    for case_name, files, expectation in SELFTEST_CASES:
        want_exit = None
        wanted_fragments = []
        for expectation_line in expectation.split("\n"):
            if expectation_line.startswith("exit="):
                want_exit = int(expectation_line[len("exit="):])
            elif expectation_line.startswith("want="):
                wanted_fragments.append(expectation_line[len("want="):])
        with tempfile.TemporaryDirectory() as work_directory:
            root = pathlib.Path(work_directory)
            for relative_path, content in files.items():
                (root / relative_path).parent.mkdir(parents=True, exist_ok=True)
                (root / relative_path).write_text(content, encoding="utf-8")
            captured = io.StringIO()
            with contextlib.redirect_stdout(captured):
                got_exit = run(root)
        output = captured.getvalue()
        problems = []
        if got_exit != want_exit:
            problems.append(f"期望退出 {want_exit}，实测 {got_exit}")
        problems.extend(f"输出里找不到「{fragment}」" for fragment in wanted_fragments if fragment not in output)
        if problems:
            failures.append((case_name, problems, output))
    for case_name, problems, output in failures:
        print(f"      样本「{case_name}」：{'；'.join(problems)}")   # gate-lint:detail
        for output_line in output.rstrip("\n").split("\n"):
            print(f"        | {output_line}")   # gate-lint:detail
    if failures:
        print(f"  ✗ 自证失败：{len(failures)} 个样本判错（共 {len(SELFTEST_CASES)} 个）")   # gate-lint:summary
        print("     → 怎么办：上面每一条写着错在哪；检查坏了就改 analyze_rust / analyze_python，样本写错了才改样本，别两边一起改到自洽为止。")
        return 1
    return 0


def selftest() -> int:
    if run_selftest_cases() != 0:
        return 1
    if weak_mode_enabled():
        print(f"  ✓ 弱判据下自证居然通过了（{len(SELFTEST_CASES)} 个样本）")
        return 0
    weak_environment = dict(os.environ)
    weak_environment[WEAK_MODE_ENVIRONMENT_VARIABLE] = "1"
    weak_run = subprocess.run([sys.executable, os.path.abspath(__file__), "--selftest"], env=weak_environment,
                              capture_output=True, text=True, check=False)
    if weak_run.returncode != 1 or "只取时间不打印的循环" not in weak_run.stdout:
        print(f"  ✗ 自证分不出「看不看输出调用」：{WEAK_MODE_ENVIRONMENT_VARIABLE}=1 下自证退出码 {weak_run.returncode}，"
              "或者没有点名「只取时间不打印的循环」那个样本")
        print("     → 怎么办：样本里要有一个只取时间、不打印的读子进程输出循环，判绿；弱判据只看取时间，它必须把那个样本判红。"
              f"单独跑 {WEAK_MODE_ENVIRONMENT_VARIABLE}=1 python3 research/scripts/relay-timing-lint.py --selftest 看输出。")
        return 1
    print(f"  ✓ relay-timing-lint 自证：{len(SELFTEST_CASES)} 个红绿样本判得对，统计数对得上；"
          f"{WEAK_MODE_ENVIRONMENT_VARIABLE}=1（不看输出调用）下自证判红")
    return 0


def main(arguments: list) -> int:
    if arguments == ["--selftest"]:
        return selftest()
    if not arguments or arguments[0] != "--check" or len(arguments) > 2:
        print("  ✗ 用法：relay-timing-lint.py --check [仓库根]，或 relay-timing-lint.py --selftest")
        print("     → 怎么办：门禁里跑 --check，改了这份脚本先跑 --selftest。")
        return 2
    root = pathlib.Path(arguments[1]) if len(arguments) == 2 else pathlib.Path(__file__).resolve().parents[2]
    return run(root.resolve())


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
