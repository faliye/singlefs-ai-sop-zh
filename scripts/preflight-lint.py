#!/usr/bin/env python3
# gate-similar: gate-lint.sh 它逐行判每条拒绝带不带出路，只认 bad / die / ✗；这一道判脚本开头写没写准入与运行条件、先判了没有，还要解析 python 的 ast 与 Rust 的 main，扫的范围也多出项目登记的实验目录
# gate-similar: gate-overlap.py 它只判这一次新加与改动的门禁与钩子、文件头的 gate-similar / hook-events；这一道不看 diff，每个脚本都判
# gate-similar: script-modes.sh 它判暂存区里的执行位，不读脚本正文
# admission: always 判的是此刻每个脚本的文件头与开头几行，几秒跑完；每一轮门禁都现判
# run-condition: command git
"""准入与运行条件（rules/preflight-discipline.md）：每个脚本在开头写明什么时候该调、什么时候不能调，而且开跑之前先判。

判哪些脚本（.sh、.py、.rs，以及没有后缀、首行是 #! 的）：
  - 本包自己（仓根就是本包时）：install.sh、scripts/、scripts/claude-hooks/、scripts/githooks/ 下的；
  - 项目：项目登记的门禁目录下的（默认 .claude/gate.d/），以及 .claude/preflight-dirs 登记的目录下的
    （项目登记的钩子目录、.claude/scripts/ 这类轻脚本不判，钩子目录默认 .claude/hooks/）。
    门禁目录下的阶段两种形态过渡期并存：扁平的 `<名>.sh`，嵌套的 `<名>/<名>.sh`；
    嵌套阶段同目录下的用例文件 `*.case.sh` 是喂给阶段的数据，不判。
  每个目录只看它自己这一层；子目录要判就另登记一行（嵌套阶段是这一条唯一的例外）。装进项目的规范副本不判：它由上游自己的门禁管。
  只 exec 共享脚本的包装（install.sh 铺的那种）不另判，由被转发的那个共享脚本判。
不判哪些：本包的排除写在 PACKAGE_EXCLUDED；项目的写在 .claude/preflight-exclude（一行一条，`<路径>  # 理由`，理由不许省）。
  排除表与登记表指向不存在的路径、排除项一个脚本都没排到，都判红。

每个脚本判五样：
  ① 文件头的注释块里（第一行代码之前）至少一行 admission 与一行 run-condition，写法认得（preflight.py 解析，与现判是同一份）；
  ② 写在第一行代码之后的声明不算，判红；
  ③ inputs-changed 登记的路径存在；
  ④ 开头先调 preflight：shell 是 `preflight "${BASH_SOURCE[0]}" "$@"; set -- ${PREFLIGHT_ARGUMENTS[@]+"${PREFLIGHT_ARGUMENTS[@]}"}`，
     它之前只许有 set、shopt、source、不读参数的单行赋值与 unset；python 是 `if __name__ == '__main__':` 的第一句
     （没有这一段的，模块里第一句干活的语句），调名叫 preflight 的函数；Rust 是 fn main 的第一句调名叫 preflight 的函数；
  ⑤ 写了 inputs-changed 的，要调 preflight_record_success（成功跑完时记下输入指纹）。

判不了的一半：条件写得对不对、全不全（inputs-changed 漏了一份输入、check 判的不是真要的那件事）、always / none 的理由成不成立、
产物里写没写强制标记——靠 review。认不出的写法：写在 preflight 那一行之后的声明（运行时也不判它，只认文件头）；
python 顶层语句里别的干活方式（只认 sys.stdin、subprocess.*、os.system / os.popen、open、input）。

用法：preflight-lint.py [仓根]
退出码：0 通过；1 有红；2 参数不对；77 范围里一个脚本都没有（无对象可判，不算通过）。
"""
import ast
import importlib.util
import os
import re
import shlex
import sys

PACKAGE_SCRIPTS_DIRECTORY = os.path.dirname(os.path.realpath(__file__))
PACKAGE_ROOT = os.path.dirname(PACKAGE_SCRIPTS_DIRECTORY)
RULE_FILE = 'rules/preflight-discipline.md'

EXIT_PASSED = 0
EXIT_RED = 1
EXIT_USAGE = 2
EXIT_NOTHING_TO_JUDGE = 77

PACKAGE_DIRECTORIES = ('scripts', 'scripts/claude-hooks', 'scripts/githooks')
PACKAGE_FILES = ('install.sh',)
# 本包里不判的：一行一条，路径相对包根，理由不许省。
PACKAGE_EXCLUDED = {
    'scripts/lib.sh': '被 shell 脚本 source 的函数库，不单独调；它 source preflight.sh，preflight 函数在那里',
    'scripts/claude-hook-lib.sh': '被钩子 source 的函数库，只定义函数，不单独调',
    'scripts/session-transcript.py': '被 gate-overlap.py 与 handback-scratch.py import 的库，没有自己的入口',
    'scripts/package-family.py': '被 link-targets.py、preflight-lint.py 与 number-name-sync.sh 载入的库，没有自己的入口',
    'scripts/preflight.py': '它就是判条件的那一个：自己再判一遍自己，会把要转给被判脚本的 --force 吃掉',
    'scripts/preflight.sh': '被 lib.sh 与钩子 source 的函数库（preflight、preflight_record_success），不单独调',
}
# 项目要判的目录：项目登记的门禁目录（PREFLIGHT.project_gate_directory，默认 .claude/gate.d），加上 .claude/preflight-dirs 登记的那几处；
# 项目登记的钩子目录（PREFLIGHT.project_hooks_directory，默认 .claude/hooks）与 .claude/scripts/ 不判：轻脚本不写准入（rules/preflight-discipline.md）。
PROJECT_REGISTERED_DIRECTORIES_FILE = '.claude/preflight-dirs'
PROJECT_EXCLUDE_FILE = '.claude/preflight-exclude'
SCRIPT_SUFFIXES = ('.sh', '.py', '.rs')
MINIMUM_REASON_CHARACTERS = 4

SHELL_ENTRY_RE = re.compile(
    r'^\s*preflight\s+"(\$\{BASH_SOURCE\[0\]\}|\$0)"\s+"\$@"\s*;\s*'
    r'set\s+--\s+\$\{PREFLIGHT_ARGUMENTS\[@\]\+"\$\{PREFLIGHT_ARGUMENTS\[@\]\}"\}\s*(#.*)?$')
SHELL_ENTRY_LOOSE_RE = re.compile(r'^\s*preflight\s')
SHELL_PROLOGUE_RES = (
    re.compile(r'^\s*$'),
    re.compile(r'^\s*#'),
    re.compile(r'^\s*shopt\s'),
    re.compile(r'^\s*(source|\.)\s+\S'),
    re.compile(r'^\s*unset\s'),
)
# 开头只许的 set：只带选项（-euo pipefail、+e 这类），不许 `set --`（那是在换参数）
SHELL_SET_OPTIONS_RE = re.compile(r'^\s*set(\s+([-+][A-Za-z]+|pipefail|errexit|nounset|xtrace|noclobber))+\s*(#.*)?$')
SHELL_ASSIGNMENT_WORD_RE = re.compile(r'^[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?\+?=')
SHELL_DECLARATION_KEYWORDS = {'export', 'readonly', 'declare', 'typeset', 'local'}
SHELL_SOURCES_PREFLIGHT_RE = re.compile(r'^\s*(source|\.)\s+.*(lib|preflight)\.sh"?\s*(#.*)?$')
POSITIONAL_PARAMETER_RE = re.compile(r'\$[1-9@*#]|\$\{[1-9@*#]')
SHELL_RECORD_RE = re.compile(r'(^|[;&|({]|\bthen|\bdo|\belse)\s*preflight_record_success\b')
RUST_MAIN_RE = re.compile(r'\bfn\s+main\s*\(\s*\)[^{]*\{')
RUST_ENTRY_RE = re.compile(r'(let\s+(mut\s+)?[A-Za-z_][A-Za-z0-9_]*\s*(:[^=;]+)?=\s*)?([A-Za-z_][A-Za-z0-9_]*::)*preflight\s*[(!]')
RUST_RECORD_RE = re.compile(r'\bpreflight_record_success\s*[(!]')
ANY_DECLARATION_RE = re.compile(r'^\s*(#|//[/!]?)\s*(admission|run-condition):')
ENTRY_MENTION_RE = re.compile(r'\bpreflight\b')


def load_preflight_module():
    # 不写 __pycache__：它会是仓里一个未跟踪的新目录，门禁跑到一半冒出来，「工作区跑的过程中没变」那一项就对不上
    sys.dont_write_bytecode = True
    specification = importlib.util.spec_from_file_location(
        'preflight', os.path.join(PACKAGE_SCRIPTS_DIRECTORY, 'preflight.py'))
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


PREFLIGHT = load_preflight_module()
PACKAGE_FAMILY = PREFLIGHT.load_package_module('package_family', 'package-family.py')


class Finding:
    def __init__(self, path, line_number, what, next_step):
        self.path = path
        self.line_number = line_number
        self.what = what
        self.next_step = next_step


def is_script(path):
    # 符号链接跟着走：gate.sh 照样跑链接形式的本地阶段，它的条件就得判；判的是链接指向的那一份的内容
    if not os.path.isfile(path):
        return False
    # 新形态门禁阶段的用例文件（<用例名>.case.sh）是喂给阶段的数据，不是可调的脚本，不写准入与运行条件
    if path.endswith('.case.sh'):
        return False
    if path.endswith(SCRIPT_SUFFIXES):
        return True
    if os.path.splitext(path)[1]:
        return False
    try:
        with open(path, 'rb') as handle:
            return handle.read(2) == b'#!'
    except OSError:
        return False


def scripts_in(directory):
    if not os.path.isdir(directory):
        return []
    return sorted(os.path.join(directory, entry_name) for entry_name in os.listdir(directory) if is_script(os.path.join(directory, entry_name)))


def nested_gate_stages_in(gate_directory):
    """新形态门禁阶段：`<gate_directory>/<名>/<名>.sh`，与扁平的 `<gate_directory>/<名>.sh` 过渡期并存。"""
    if not os.path.isdir(gate_directory):
        return []
    nested_stage_scripts = []
    for stage_name in sorted(os.listdir(gate_directory)):
        candidate = os.path.join(gate_directory, stage_name, stage_name + '.sh')
        if is_script(candidate):
            nested_stage_scripts.append(candidate)
    return nested_stage_scripts


def read_table(root, relative_file, findings):
    """`<路径>  # 理由` 一行一条的表 → [(行号, 路径, 理由)]；格式不对的记进 findings。"""
    path = os.path.join(root, relative_file)
    if not os.path.isfile(path):
        return []
    rows = []
    with open(path, encoding='utf-8') as handle:
        for line_number, line in enumerate(handle, 1):
            stripped = line.strip()
            if not stripped or stripped.startswith('#'):
                continue
            table_path, separator, reason = stripped.partition('#')
            table_path, reason = table_path.strip(), reason.strip()
            if not separator or len(reason) < MINIMUM_REASON_CHARACTERS or not table_path:
                findings.append(Finding(relative_file, line_number, f'这一行没写理由，或路径是空的：{stripped}',
                                        '一行一条： <相对仓根的路径>  # 为什么（理由不许省）'))
                continue
            rows.append((line_number, table_path.rstrip('/'), reason))
    return rows


# install.sh 铺的包装里除注释外只有这几种行；夹了别的逻辑就不算包装，照普通脚本判
WRAPPER_LINE_RES = (
    re.compile(r'^shared="\$\(dirname "\$\{BASH_SOURCE\[0\]\}"\)/\.\./[A-Za-z0-9._-]+/scripts/[A-Za-z0-9._-]+\.sh"$'),
    re.compile(r'^if \[\[ ! -f "\$shared" \]\]; then$'),
    re.compile(r'^echo "[^"`$]*(\$shared[^"`$]*)?"$'),
    re.compile(r'^exit 1$'),
    re.compile(r'^fi$'),
    re.compile(r'^exec bash "(\$shared|\$\(dirname "\$\{BASH_SOURCE\[0\]\}"\)/\.\./[A-Za-z0-9._-]+/scripts/[A-Za-z0-9._-]+\.sh)" '
               r'"\$\(cd "\$\(dirname "\$\{BASH_SOURCE\[0\]\}"\)/\.\./\.\." && pwd\)" "\$@"$'),
)


def wrapper_target(path, package_family_name):
    """install.sh 铺的包装：只 exec 本包里的一个共享脚本。是就返回那个共享脚本的路径。"""
    try:
        with open(path, encoding='utf-8', errors='replace') as handle:
            text = handle.read()
    except OSError:
        return None
    code_lines = [line.strip() for line in text.split('\n')[1:] if line.strip() and not line.strip().startswith('#')]
    if not all(any(pattern.match(line) for pattern in WRAPPER_LINE_RES) for line in code_lines):
        return None
    family_pattern = re.escape(package_family_name)
    direct_exec_match = re.search(r'^exec bash "\$\(dirname "\$\{BASH_SOURCE\[0\]\}"\)/\.\./' + family_pattern + r'/scripts/([A-Za-z0-9._-]+\.sh)"', text, re.M)
    shared_assignment_match = re.search(r'^shared="\$\(dirname "\$\{BASH_SOURCE\[0\]\}"\)/\.\./' + family_pattern + r'/scripts/([A-Za-z0-9._-]+\.sh)"$', text, re.M)
    shared_script_name = direct_exec_match.group(1) if direct_exec_match else (shared_assignment_match.group(1) if shared_assignment_match and re.search(r'^exec bash "\$shared"', text, re.M) else None)
    if not shared_script_name:
        return None
    shared_script_path = os.path.join(PACKAGE_SCRIPTS_DIRECTORY, shared_script_name)
    return shared_script_path if os.path.isfile(shared_script_path) else None


def without_command_substitutions(line):
    """把 $(…) 整段（含嵌套）换成占位符：里面的引号与空白自成一层，按词切的时候不该算进外面这一行。"""
    kept_characters, character_index, substitution_depth = [], 0, 0
    while character_index < len(line):
        if line.startswith('$(', character_index):
            if substitution_depth == 0:
                kept_characters.append('SUBSTITUTION')
            substitution_depth += 1
            character_index += 2
            continue
        character = line[character_index]
        if substitution_depth > 0:
            if character == '(':
                substitution_depth += 1
            elif character == ')':
                substitution_depth -= 1
        else:
            kept_characters.append(character)
        character_index += 1
    return ''.join(kept_characters)


def is_single_line_assignment(line):
    """整行只是赋值（可以带 export / readonly / declare 这类前缀）：`LANG=C sort notes.txt` 是带环境变量跑命令，不算。"""
    try:
        words = shlex.split(without_command_substitutions(line), comments=True, posix=True)
    except ValueError:
        return False
    while words and words[0] in SHELL_DECLARATION_KEYWORDS:
        words = words[1:]
        while words and words[0].startswith('-'):
            words = words[1:]
    return bool(words) and all(SHELL_ASSIGNMENT_WORD_RE.match(word) for word in words)


def check_shell_entry(path, shown_path, lines, findings):
    sourced_preflight = False
    for line_index, line in enumerate(lines):
        if line_index == 0 and line.startswith('#!'):
            continue
        if SHELL_ENTRY_RE.match(line):
            if not sourced_preflight:
                findings.append(Finding(shown_path, line_index + 1, 'preflight 那一行之前没有 source lib.sh（或 preflight.sh）：函数还没定义，条件一条都不会判，参数还会被清空',
                                        '在它前面加一行 source …/lib.sh（不 source lib.sh 的钩子 source …/preflight.sh）'))
            return
        if SHELL_ENTRY_LOOSE_RE.match(line):
            findings.append(Finding(shown_path, line_index + 1, 'preflight 那一行写得不对：要把参数整个交给它，并在同一行把 --force 摘掉之后的参数放回去',
                                    '照抄这一行： preflight "${BASH_SOURCE[0]}" "$@"; set -- ${PREFLIGHT_ARGUMENTS[@]+"${PREFLIGHT_ARGUMENTS[@]}"}'))
            return
        if SHELL_SOURCES_PREFLIGHT_RE.match(line):
            sourced_preflight = True
        if not (any(pattern.match(line) for pattern in SHELL_PROLOGUE_RES) or SHELL_SET_OPTIONS_RE.match(line)
                or is_single_line_assignment(line)):
            findings.append(Finding(shown_path, line_index + 1, f'开跑之前没先判条件：这一行在调 preflight 之前就干活了：{line.strip()[:80]}',
                                    '在 source lib.sh 之后、第一件干活的事之前加一行：'
                                    ' preflight "${BASH_SOURCE[0]}" "$@"; set -- ${PREFLIGHT_ARGUMENTS[@]+"${PREFLIGHT_ARGUMENTS[@]}"}'
                                    '（它之前只许 set、shopt、source、不读参数的单行赋值与 unset）'))
            return
        if not line.lstrip().startswith('#') and POSITIONAL_PARAMETER_RE.search(line):
            findings.append(Finding(shown_path, line_index + 1, f'在调 preflight 之前读了参数，--force 还没摘掉：{line.strip()[:80]}',
                                    '把这一行挪到 preflight 那一行之后'))
            return
    findings.append(Finding(shown_path, 1, '开头没调 preflight：条件写了也没人判',
                            '在 source lib.sh 之后加一行： preflight "${BASH_SOURCE[0]}" "$@"; set -- ${PREFLIGHT_ARGUMENTS[@]+"${PREFLIGHT_ARGUMENTS[@]}"}'))


def callee_name(call_node):
    if isinstance(call_node.func, ast.Name):
        return call_node.func.id
    if isinstance(call_node.func, ast.Attribute):
        return call_node.func.attr
    return ''


def is_named_call(statement, function_name):
    statement_value = statement.value if isinstance(statement, (ast.Expr, ast.Assign, ast.AnnAssign)) else None
    return isinstance(statement_value, ast.Call) and callee_name(statement_value) == function_name


def reads_process_arguments(node):
    return any(isinstance(descendant, ast.Attribute) and descendant.attr == 'argv'
               and isinstance(descendant.value, ast.Name) and descendant.value.id == 'sys' for descendant in ast.walk(node))


def is_main_guard(statement):
    if not isinstance(statement, ast.If) or not isinstance(statement.test, ast.Compare):
        return False
    sides = [statement.test.left] + list(statement.test.comparators)
    return (any(isinstance(side, ast.Name) and side.id == '__name__' for side in sides)
            and any(isinstance(side, ast.Constant) and side.value == '__main__' for side in sides))


def does_work_at_import(statement):
    """顶层语句在判条件之前就读标准输入、起子进程、开文件：钩子这样写，判条件之前 stdin 就被读走了。"""
    for node in ast.walk(statement):
        if isinstance(node, ast.Attribute) and node.attr == 'stdin' and isinstance(node.value, ast.Name) and node.value.id == 'sys':
            return True
        if isinstance(node, ast.Call):
            callee = node.func
            if isinstance(callee, ast.Attribute) and isinstance(callee.value, ast.Name) and (
                    callee.value.id == 'subprocess' or (callee.value.id == 'os' and callee.attr in ('system', 'popen'))):
                return True
            if isinstance(callee, ast.Name) and callee.id in ('open', 'input'):
                return True
    return False


def is_inert_module_statement(statement):
    """模块顶层里不干活的语句：文档串、import、函数与类的定义、赋值、sys.path 的增补。"""
    if isinstance(statement, (ast.Import, ast.ImportFrom, ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef, ast.Assign, ast.AnnAssign)):
        return True
    if isinstance(statement, ast.Expr) and isinstance(statement.value, ast.Constant) and isinstance(statement.value.value, str):
        return True
    if isinstance(statement, ast.Expr) and isinstance(statement.value, ast.Call):
        callee = statement.value.func
        return (isinstance(callee, ast.Attribute) and callee.attr in ('insert', 'append')
                and isinstance(callee.value, ast.Attribute) and callee.value.attr == 'path')
    return False


def check_python_entry(shown_path, text, findings):
    try:
        syntax_tree = ast.parse(text)
    except SyntaxError as error:
        findings.append(Finding(shown_path, error.lineno or 1, f'python 解析不了：{error.msg}', '先让它能被 python3 解析'))
        return
    python_next_step = "开头先调 preflight(__file__)：有 if __name__ == '__main__': 的，放在它的第一句；没有的，放在模块里第一句干活的语句之前"
    for statement in syntax_tree.body:
        if is_main_guard(statement):
            if not statement.body or not is_named_call(statement.body[0], 'preflight'):
                findings.append(Finding(shown_path, statement.lineno, "if __name__ == '__main__': 的第一句不是 preflight(…)", python_next_step))
            return
        if is_named_call(statement, 'preflight'):
            return
        if not is_inert_module_statement(statement):
            findings.append(Finding(shown_path, statement.lineno, '开跑之前没先判条件：这一句在调 preflight 之前就干活了', python_next_step))
            return
        if not isinstance(statement, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)) and reads_process_arguments(statement):
            findings.append(Finding(shown_path, statement.lineno, '在调 preflight 之前读了 sys.argv，--force 还没摘掉', '把读参数的那一句挪到 preflight 之后'))
            return
        if not isinstance(statement, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)) and does_work_at_import(statement):
            findings.append(Finding(shown_path, statement.lineno, '在调 preflight 之前就读标准输入、起子进程或开文件了', '把这一句挪进 main，或挪到 preflight 之后'))
            return
    findings.append(Finding(shown_path, 1, '没调 preflight：条件写了也没人判', python_next_step))


def python_records_success(text):
    try:
        syntax_tree = ast.parse(text)
    except SyntaxError:
        return False
    return any(isinstance(node, ast.Call) and callee_name(node) == 'preflight_record_success' for node in ast.walk(syntax_tree))


def strip_rust_comments(text):
    text = re.sub(r'/\*.*?\*/', ' ', text, flags=re.S)
    return re.sub(r'//[^\n]*', ' ', text)


def check_rust_entry(shown_path, text, findings):
    code_without_comments = strip_rust_comments(text)
    main_function_match = RUST_MAIN_RE.search(code_without_comments)
    rust_next_step = 'fn main 的第一句调名叫 preflight 的函数：它执行 python3 <规范副本>/scripts/preflight.py check <源文件> [--force] -- <参数…>，退出码不是 0 就原样退出'
    if not main_function_match:
        findings.append(Finding(shown_path, 1, '找不到 fn main()', rust_next_step))
        return
    if not RUST_ENTRY_RE.match(code_without_comments[main_function_match.end():].lstrip()):
        findings.append(Finding(shown_path, text[:main_function_match.start()].count('\n') + 1 if main_function_match.start() < len(text) else 1,
                                'fn main 的第一句不是 preflight(…)', rust_next_step))


def check_script(path, shown_path, findings):
    language = PREFLIGHT.source_language(path)
    with open(path, encoding='utf-8', errors='replace') as handle:
        text = handle.read()
    lines = text.split('\n')
    declarations, problems = PREFLIGHT.parse_declarations(path)
    for problem in problems:
        findings.append(Finding(shown_path, problem.line_number, problem.what, problem.next_step))
    # 写错了位置的声明：文件头之后、第一处提到 preflight 之前的那一段里。再往后的多半是字符串里的数据（造样本脚本的那种），不判
    header_line_numbers = {line_number for line_number, _ in PREFLIGHT.header_lines(path)}
    for line_number, line in enumerate(lines, 1):
        if line_number in header_line_numbers:
            continue
        if ENTRY_MENTION_RE.search(line):
            break
        if ANY_DECLARATION_RE.match(line):
            findings.append(Finding(shown_path, line_number, '这条声明写在第一行代码之后，不算',
                                    '挪进文件头的注释块（#! 之后、第一行代码之前）'))
    declared_sections = {declaration.section for declaration in declarations}
    for section, meaning in (('admission', '什么时候该调它（这一次调有没有意义）'), ('run-condition', '什么时候不能调它（环境、工具、权限、并发）')):
        if section not in declared_sections and not problems:
            findings.append(Finding(shown_path, 1, f'文件头没写 {section}：{meaning}',
                                    f'在文件头的注释块里加一行 `# {section}: …`（{language} 用 {"//" if language == "rust" else "#"}），写法见 {RULE_FILE}'))
    declares_inputs_changed = False
    for declaration in declarations:
        if declaration.kind != 'inputs-changed':
            continue
        declares_inputs_changed = True
        toplevel = PREFLIGHT.repository_toplevel(os.path.dirname(path))
        for declared_path in declaration.input_paths:
            if not os.path.exists(PREFLIGHT.resolve_input_path(path, toplevel, declared_path)):
                findings.append(Finding(shown_path, declaration.line_number, f'inputs-changed 登记的 {declared_path} 不存在',
                                        '路径相对仓根；./ 或 ../ 开头的相对脚本所在目录。改对它，或删掉这一项'))
    if language == 'shell':
        check_shell_entry(path, shown_path, lines, findings)
        records_success = any(SHELL_RECORD_RE.search(line) for line in lines if not line.lstrip().startswith('#'))
    elif language == 'python':
        check_python_entry(shown_path, text, findings)
        records_success = python_records_success(text)
    else:
        check_rust_entry(shown_path, text, findings)
        records_success = bool(RUST_RECORD_RE.search(strip_rust_comments(text)))
    if declares_inputs_changed and not records_success:
        findings.append(Finding(shown_path, 1, '写了 inputs-changed，却没有一处调 preflight_record_success：上次成功的指纹永远记不下来，每次都算「变了」',
                                '成功跑完、退出之前调一次 preflight_record_success'))


def category_of(relative_path, gate_directory, hooks_directory):
    if relative_path.startswith(gate_directory + '/'):
        return '门禁阶段'
    if '/claude-hooks/' in relative_path or '/githooks/' in relative_path or relative_path.startswith(hooks_directory + '/'):
        return '钩子'
    return '脚本'


def main():
    if len(sys.argv) > 2 or (len(sys.argv) == 2 and sys.argv[1].startswith('-')):
        print('  ✗ 用法：preflight-lint.py [仓根]', file=sys.stderr)
        print(f'     → 怎么办： 只收一个仓根；规矩见 {RULE_FILE}', file=sys.stderr)
        return EXIT_USAGE
    repository_root = os.path.realpath(sys.argv[1] if len(sys.argv) == 2 else '.')
    if not os.path.isdir(repository_root):
        print(f'  ✗ 仓根不存在：{repository_root}', file=sys.stderr)
        print('     → 怎么办： 把项目根作为参数传进来： preflight-lint.py <仓根>', file=sys.stderr)
        return EXIT_USAGE
    package_family_name = PACKAGE_FAMILY.package_family()
    gate_directory = PREFLIGHT.project_gate_directory(repository_root)
    hooks_directory = PREFLIGHT.project_hooks_directory(repository_root)

    findings = []
    category_by_script_path = {}  # 绝对路径 → 类别（门禁阶段 / 钩子 / 脚本 / 登记目录）
    excluded_entries = []  # (相对路径, 理由)
    is_package_itself = repository_root == PACKAGE_ROOT
    if is_package_itself:
        for relative_path in PACKAGE_FILES:
            if is_script(os.path.join(repository_root, relative_path)):
                category_by_script_path[os.path.join(repository_root, relative_path)] = '脚本'
        for relative_directory in PACKAGE_DIRECTORIES:
            for path in scripts_in(os.path.join(repository_root, relative_directory)):
                category_by_script_path[path] = category_of(os.path.relpath(path, repository_root), gate_directory, hooks_directory)
        for relative_path, reason in PACKAGE_EXCLUDED.items():
            absolute_path = os.path.join(repository_root, relative_path)
            if absolute_path not in category_by_script_path:
                findings.append(Finding('scripts/preflight-lint.py', 1, f'PACKAGE_EXCLUDED 里的 {relative_path} 不在判的范围里（不存在或不是脚本）',
                                        '删掉这一项；排除项指向不存在的路径，会让人以为那份已经被绕开了'))
                continue
            del category_by_script_path[absolute_path]
            excluded_entries.append((relative_path, reason))
    for path in scripts_in(os.path.join(repository_root, gate_directory)):
        category_by_script_path[path] = category_of(os.path.relpath(path, repository_root), gate_directory, hooks_directory)
    for path in nested_gate_stages_in(os.path.join(repository_root, gate_directory)):
        category_by_script_path[path] = '门禁阶段'
    registered_directories = read_table(repository_root, PROJECT_REGISTERED_DIRECTORIES_FILE, findings)
    for line_number, relative_directory, _ in registered_directories:
        directory = os.path.join(repository_root, relative_directory)
        if not os.path.isdir(directory):
            findings.append(Finding(PROJECT_REGISTERED_DIRECTORIES_FILE, line_number, f'登记的目录不存在：{relative_directory}',
                                    '改对路径（相对仓根），或删掉这一行'))
            continue
        for path in scripts_in(directory):
            category_by_script_path.setdefault(path, '登记目录')
    for line_number, relative_path, reason in read_table(repository_root, PROJECT_EXCLUDE_FILE, findings):
        absolute_path = os.path.join(repository_root, relative_path)
        if not os.path.exists(absolute_path):
            findings.append(Finding(PROJECT_EXCLUDE_FILE, line_number, f'排除的路径不存在：{relative_path}',
                                    '删掉这一行；排除项指向不存在的路径，会让人以为那批文件已经被绕开了'))
            continue
        excluded_scripts = [path for path in category_by_script_path if path == absolute_path or path.startswith(absolute_path + os.sep)]
        if not excluded_scripts:
            findings.append(Finding(PROJECT_EXCLUDE_FILE, line_number, f'这一行一个要判的脚本都没排到：{relative_path}',
                                    '删掉这一行：它排的不在判的范围里（范围见 scripts/preflight-lint.py 文件头）'))
            continue
        for path in excluded_scripts:
            del category_by_script_path[path]
        excluded_entries.append((relative_path, reason))

    wrapper_count = 0
    judged_count_by_category = {}
    for path in sorted(category_by_script_path):
        shown_path = os.path.relpath(path, repository_root)
        if category_by_script_path[path] in ('脚本', '登记目录') and wrapper_target(path, package_family_name):   # 登记目录里 install.sh 铺的包装同样不另判
            wrapper_count += 1
            continue
        judged_count_by_category[category_by_script_path[path]] = judged_count_by_category.get(category_by_script_path[path], 0) + 1
        check_script(path, shown_path, findings)

    for finding in findings:
        print(f'  ✗ {finding.path}:{finding.line_number} {finding.what}')
        print(f'     → 怎么办： {finding.next_step}')
    judged_count = sum(judged_count_by_category.values())
    if judged_count == 0 and not findings:
        print(f'  ! 判的范围里一个脚本都没有（{repository_root}），本次无对象可判')
        return EXIT_NOTHING_TO_JUDGE
    breakdown = '、'.join(f'{category} {script_count}' for category, script_count in sorted(judged_count_by_category.items()))
    excluded_text = '；'.join(f'{relative_path}（{reason}）' for relative_path, reason in excluded_entries) or '无'
    if not is_package_itself and not os.path.isfile(os.path.join(repository_root, PROJECT_REGISTERED_DIRECTORIES_FILE)):
        print(f'  ! 项目没有 {PROJECT_REGISTERED_DIRECTORIES_FILE}：实验脚本放在哪没登记，那一类本次一个都没判（没有实验也写一行注释说明）')
    if findings:
        print(f'  ✗ 准入与运行条件：判了 {judged_count} 个脚本（{breakdown}），{len(findings)} 处不合格；排除 {len(excluded_entries)} 个：{excluded_text}')  # gate-lint:summary
        print(f'     → 怎么办： 按上面每一处的出路改；规矩见 {RULE_FILE}')
        return EXIT_RED
    print(f'  ✓ 准入与运行条件：判了 {judged_count} 个脚本（{breakdown}），都在开头写明了条件并先判；'
          f'只 exec 共享脚本的包装 {wrapper_count} 个，由被转发的脚本判；排除 {len(excluded_entries)} 个：{excluded_text}')
    return EXIT_PASSED


if __name__ == '__main__':
    PREFLIGHT.preflight(__file__)
    sys.exit(main())
