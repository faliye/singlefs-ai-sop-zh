#!/usr/bin/env python3
# gate-similar: gate-overlap.py 它读文件头的 gate-similar / hook-events 声明、只判这一次新加与改动的门禁与钩子；这一份读 admission / run-condition 声明，在脚本开跑之前现判这一刻的条件，不看 diff
# gate-similar: hooks-registered.sh 它判钩子在 settings.json 里注册着没有，不在任何脚本开跑之前判条件
# admission: always 被判的脚本每次开跑之前都要现判一次；它只回答「这一刻能不能跑」，不产出要留下的结论
# run-condition: command git
"""准入与运行条件（rules/preflight-discipline.md）：读脚本文件头的声明，在它开跑之前现判；不满足就拒绝，带 --force 才放行。

声明写在文件头的注释块里（第一行代码之前；shell 与 python 用 #，Rust 用 //），一行一条：
  admission: always <理由>                                      每次调都有意义
  admission: inputs-changed <路径…> [env:<变量名>…] [arguments]  脚本自己与这些输入自上次成功跑完以来变过
  admission: check <命令> :: <不满足时怎么办>                     命令退出码为 0
  run-condition: none <理由>                                     没有环境要求
  run-condition: command <可执行文件名…>                          都在 PATH 上
  run-condition: single-instance                                 没有别的进程在跑同一个脚本
  run-condition: check <命令> :: <不满足时怎么办>                  命令退出码为 0
inputs-changed 的路径相对仓根；以 ./ 或 ../ 开头的相对脚本所在目录。env:<变量名> 把那个环境变量的值算进指纹，
arguments 把这一次的参数（摘掉 --force 之后）算进指纹。check 的命令用 bash -c 跑，工作目录是仓根（不在 git 仓里时是脚本所在目录），
环境里有 PREFLIGHT_SCRIPT（脚本的绝对路径）与 PREFLIGHT_SCRIPT_DIRECTORY。

用法：
  preflight.py check <脚本> [--force] [-- <脚本的参数…>]   现判。人读的报告写 stderr；stdout 一行给调用方读：
      met<TAB><开跑时的输入指纹，没声明 inputs-changed 时是 -> | undeclared | forced<TAB><类><TAB><摘要>
      | refused<TAB><类><TAB><摘要> | malformed<TAB><摘要>
      类只有两种：inputs-unchanged（只因为输入没变）与 condition（别的条件）。几行 inputs-changed 合成一份输入判
  preflight.py record <脚本> [--fingerprint <开跑时的指纹>] [-- <脚本的参数…>]
      成功跑完时记下输入指纹，下一次 inputs-changed 拿它比。给了开跑时的指纹就只记它，收尾时重算对不上（跑的过程中输入变了）就不记
  preflight.py declared <脚本>                            文件头写了声明退 0，没写退 1

退出码：0 能跑（满足，或 --force 强制）、record 跑完了（没记下时 stderr 说为什么）；78 拒绝；2 用法不对；3 声明写坏了，判不了。
不在 git 仓里时判不了输入变没变，照跑，也没处记。
python 脚本 import 本文件：开头调 preflight(__file__)，成功跑完调 preflight_record_success()；声明写坏了退 1。
shell 脚本调 preflight.sh（lib.sh 会 source 它）的同名函数，它转到这里。
"""
import hashlib
import importlib.util
import os
import re
import shutil
import subprocess
import sys
import urllib.parse
from datetime import datetime, timezone

EXIT_ALLOWED = 0
EXIT_USAGE = 2
EXIT_MALFORMED = 3
EXIT_REFUSED = 78

RULE_FILE = 'rules/preflight-discipline.md'
MINIMUM_REASON_CHARACTERS = 8
CHECK_TIMEOUT_SECONDS = 120
STAMP_DIRECTORY_NAME = 'sop-preflight'
CATEGORY_INPUTS_UNCHANGED = 'inputs-unchanged'
CATEGORY_CONDITION = 'condition'

ADMISSION = 'admission'
RUN_CONDITION = 'run-condition'
KINDS = {
    ADMISSION: ('always', 'inputs-changed', 'check'),
    RUN_CONDITION: ('none', 'command', 'single-instance', 'check'),
}
KIND_LABEL = {ADMISSION: '准入', RUN_CONDITION: '运行'}
# 被当成「同一个脚本在跑」的解释器：argv[0] 是它们、第一个不以 - 开头的参数解析到这个脚本
INTERPRETER_NAME_RE = re.compile(r'^(bash|sh|dash|zsh|ksh|python|python3(\.\d+)?)$')
SHELL_DECLARATION_RE = re.compile(r'^\s*#\s*(admission|run-condition):\s*(.*?)\s*$')
RUST_DECLARATION_RE = re.compile(r'^\s*//[/!]?\s*(admission|run-condition):\s*(.*?)\s*$')


class Declaration:
    def __init__(self, line_number, section, kind, text):
        self.line_number = line_number
        self.section = section
        self.kind = kind
        self.text = text
        self.reason = ''
        self.command = ''
        self.next_step = ''
        self.executable_names = []
        self.input_paths = []
        self.environment_variable_names = []
        self.includes_arguments = False

    def label(self):
        return f'{KIND_LABEL[self.section]} {self.kind}'


class Problem:
    """声明写坏了：第几行、错在哪、怎么改。"""

    def __init__(self, line_number, what, next_step):
        self.line_number = line_number
        self.what = what
        self.next_step = next_step


class Unmet:
    def __init__(self, declaration, what, next_step, category):
        self.declaration = declaration
        self.what = what
        self.next_step = next_step
        self.category = category


def source_language(path):
    """shell / python / rust：决定注释符。没有后缀的看 #! 那一行。"""
    if path.endswith('.rs'):
        return 'rust'
    if path.endswith('.py'):
        return 'python'
    if path.endswith('.sh'):
        return 'shell'
    try:
        with open(path, encoding='utf-8', errors='replace') as handle:
            first_line = handle.readline()
    except OSError:
        return 'shell'
    return 'python' if first_line.startswith('#!') and 'python' in first_line else 'shell'


def header_lines(path):
    """文件头的注释块：从第一行（跳过 #!）到第一行代码之前，连同行号。"""
    language = source_language(path)
    comment_prefix = '//' if language == 'rust' else '#'
    with open(path, encoding='utf-8', errors='replace') as handle:
        lines = handle.read().split('\n')
    header = []
    for line_number, line in enumerate(lines, 1):
        stripped = line.strip()
        if language == 'rust' and stripped.startswith('#!['):
            continue  # Rust 的内属性（#![allow(…)]）不跑任何东西，写在哪一行都算文件头的一部分
        if line_number == 1 and stripped.startswith('#!'):
            continue
        if stripped == '' or stripped.startswith(comment_prefix):
            header.append((line_number, line))
            continue
        break
    return header


def parse_declarations(path):
    """→ (声明列表, 问题列表)。只认文件头注释块里的声明；写在代码之后的不算，也不报——lint 另查「写在了别处」。"""
    declaration_re = RUST_DECLARATION_RE if source_language(path) == 'rust' else SHELL_DECLARATION_RE
    declarations, problems = [], []
    for line_number, line in header_lines(path):
        matched = declaration_re.match(line)
        if not matched:
            continue
        section, body = matched.group(1), matched.group(2)
        kind, _, rest = body.partition(' ')
        rest = rest.strip()
        if kind not in KINDS[section]:
            problems.append(Problem(line_number, f'{section}: 认不出「{kind}」',
                                    f'{section} 只认这几种：{" / ".join(KINDS[section])}（写法见 {RULE_FILE}）'))
            continue
        declaration = Declaration(line_number, section, kind, rest)
        problem = fill_declaration(declaration)
        if problem:
            problems.append(problem)
        else:
            declarations.append(declaration)
    return declarations, problems


def fill_declaration(declaration):
    """按种类解析参数；写坏了返回 Problem。"""
    section, kind, rest = declaration.section, declaration.kind, declaration.text
    if kind in ('always', 'none'):
        if len(rest) < MINIMUM_REASON_CHARACTERS:
            return Problem(declaration.line_number, f'{section}: {kind} 后面的理由不足 {MINIMUM_REASON_CHARACTERS} 个字：「{rest}」',
                           '写清为什么每次调都有意义（always）或为什么没有环境要求（none）')
        declaration.reason = rest
        return None
    if kind == 'check':
        command, separator, next_step = rest.rpartition(' :: ')
        if not separator or not command.strip():
            return Problem(declaration.line_number, f'{section}: check 要写成「<命令> :: <不满足时怎么办>」：「{rest}」',
                           '命令与出路之间用「 :: 」隔开，出路写不满足时下一步做什么')
        if len(next_step.strip()) < MINIMUM_REASON_CHARACTERS:
            return Problem(declaration.line_number, f'{section}: check 的出路不足 {MINIMUM_REASON_CHARACTERS} 个字：「{next_step.strip()}」',
                           '出路写不满足时下一步做什么，拒绝的时候原样打给调用的人')
        declaration.command = command.strip()
        declaration.next_step = next_step.strip()
        return None
    if kind == 'command':
        declaration.executable_names = rest.split()
        if not declaration.executable_names:
            return Problem(declaration.line_number, f'{section}: command 后面没写可执行文件名',
                           '写出它要调的外部命令，空格隔开： command git python3')
        return None
    if kind == 'single-instance':
        if rest:
            return Problem(declaration.line_number, f'run-condition: single-instance 不带参数，多出来：「{rest}」',
                           '去掉后面的字；要说明为什么不能并行，写在它上一行的注释里')
        return None
    # inputs-changed
    for token in rest.split():
        if token == 'arguments':
            declaration.includes_arguments = True
        elif token.startswith('env:') and re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', token[4:]):
            declaration.environment_variable_names.append(token[4:])
        else:
            declaration.input_paths.append(token)
    if not declaration.input_paths:
        return Problem(declaration.line_number, 'admission: inputs-changed 没写输入路径',
                       '写出结果取决于哪些文件：代码、决策、跑前登记（相对仓根；./ 或 ../ 开头的相对脚本所在目录）')
    return None


GIT_LOCAL_VARIABLE_NAMES = []


def git_environment():
    """调 git 用的环境：去掉 git 钩子留下的 GIT_DIR / GIT_INDEX_FILE 这一组，它们压过 `git -C`。那一组的名单只问 git 一次。"""
    if not GIT_LOCAL_VARIABLE_NAMES:
        try:
            listed = subprocess.run(['git', 'rev-parse', '--local-env-vars'], stdin=subprocess.DEVNULL, capture_output=True, text=True)
            names = listed.stdout.split() if listed.returncode == 0 else []
        except FileNotFoundError:
            names = []
        GIT_LOCAL_VARIABLE_NAMES.extend(names or ['GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE', 'GIT_COMMON_DIR'])
    return {key: value for key, value in os.environ.items() if key not in GIT_LOCAL_VARIABLE_NAMES}


def run_git(arguments, **options):
    # 标准输入不给子进程：钩子的 JSON、git 喂给 pre-push 的 ref 都在调用方的标准输入里，被读走调用方就判错了
    try:
        return subprocess.run(['git'] + arguments, env=git_environment(), stdin=subprocess.DEVNULL, **options)
    except FileNotFoundError:
        # 没有 git：当成「不在 git 仓里」往下判；声明了 command git 的那一条会按条件不满足拒绝，给出路
        empty = '' if options.get('text') else b''
        return subprocess.CompletedProcess(['git'] + arguments, 127, empty, empty)


def repository_toplevel(directory):
    completed = run_git(['-C', directory, 'rev-parse', '--show-toplevel'], capture_output=True, text=True)
    return completed.stdout.strip() if completed.returncode == 0 and completed.stdout.strip() else None


def git_common_directory(directory):
    completed = run_git(['-C', directory, 'rev-parse', '--git-common-dir'], capture_output=True, text=True)
    if completed.returncode != 0 or not completed.stdout.strip():
        return None
    return os.path.normpath(os.path.join(directory, completed.stdout.strip()))


def resolve_input_path(script_path, toplevel, declared_path):
    if declared_path.startswith('./') or declared_path.startswith('../') or declared_path in ('.', '..'):
        return os.path.normpath(os.path.join(os.path.dirname(script_path), declared_path))
    return os.path.normpath(os.path.join(toplevel or os.path.dirname(script_path), declared_path))


def files_under(path, toplevel):
    """这个输入路径下要算进指纹的文件：在 git 仓里、没被忽略时取 git 认的（跟踪的与没被忽略的未跟踪文件）；
    被忽略的（装进项目的规范副本就是）或不在 git 仓里的，整个目录照实走一遍。"""
    if toplevel:
        ignored = run_git(['-C', toplevel, 'check-ignore', '-q', '--', path]).returncode == 0
        if not ignored:
            listed = run_git(['-C', toplevel, 'ls-files', '-z', '-co', '--exclude-standard', '--', path], capture_output=True)
            if listed.returncode == 0:
                return sorted(os.path.join(toplevel, name.decode()) for name in listed.stdout.split(b'\0') if name)
    if os.path.isfile(path):
        return [path]
    found = []
    for directory, subdirectories, file_names in os.walk(path):
        subdirectories[:] = sorted(name for name in subdirectories if name != '__pycache__')
        found.extend(os.path.join(directory, name) for name in file_names)
    return sorted(found)


def combined_inputs(declarations):
    """全部 inputs-changed 行合成一份：路径与环境变量取并集，任一行写了 arguments 就把参数算进去。没有这类声明时是 None。"""
    inputs = [declaration for declaration in declarations if declaration.kind == 'inputs-changed']
    if not inputs:
        return None
    combined = Declaration(inputs[0].line_number, ADMISSION, 'inputs-changed', ' '.join(declaration.text for declaration in inputs))
    for declaration in inputs:
        combined.input_paths += [path for path in declaration.input_paths if path not in combined.input_paths]
        combined.environment_variable_names += [name for name in declaration.environment_variable_names
                                                if name not in combined.environment_variable_names]
        combined.includes_arguments = combined.includes_arguments or declaration.includes_arguments
    return combined


def input_fingerprint(script_path, declaration, arguments):
    """→ (指纹, None) 或 (None, 判不了的原因)。"""
    script_directory = os.path.dirname(script_path)
    toplevel = repository_toplevel(script_directory)
    digest = hashlib.sha256()
    input_files = [script_path]
    for declared_path in declaration.input_paths:
        resolved = resolve_input_path(script_path, toplevel, declared_path)
        if not os.path.exists(resolved):
            return None, f'登记的输入 {declared_path} 不存在（解析成 {resolved}）'
        input_files.extend(files_under(resolved, toplevel))
    anchor = toplevel or script_directory
    for input_file in sorted(set(input_files)):
        digest.update(os.path.relpath(input_file, anchor).encode() + b'\0')
        try:
            with open(input_file, 'rb') as handle:
                digest.update(hashlib.sha256(handle.read()).digest())
        except OSError:
            digest.update(b'<unreadable>')
    for name in sorted(declaration.environment_variable_names):
        value = os.environ.get(name)
        digest.update(f'env:{name}='.encode() + (b'<unset>' if value is None else value.encode()) + b'\0')
    if declaration.includes_arguments:
        digest.update(b'arguments:' + '\0'.join(arguments).encode())
    return digest.hexdigest(), None


def stamp_path(script_path):
    """上次成功跑完时的指纹记在哪：仓的公共 git 目录下（worktree 与主仓共用），按脚本相对仓根的路径分文件。不在 git 仓里时是 None。"""
    script_directory = os.path.dirname(script_path)
    toplevel = repository_toplevel(script_directory)
    common_directory = git_common_directory(script_directory)
    if not toplevel or not common_directory:
        return None
    relative = os.path.relpath(script_path, toplevel)
    # 按路径百分号转义起名：只把 / 换成别的字的话，a/b__c.sh 与 a__b/c.sh 会记到同一个文件里
    return os.path.join(common_directory, STAMP_DIRECTORY_NAME, urllib.parse.quote(relative, safe=''))


def read_stamp(script_path):
    path = stamp_path(script_path)
    if not path:
        return None, None
    try:
        with open(path, encoding='utf-8') as handle:
            fingerprint, _, recorded_at = handle.read().strip().partition('\t')
        return fingerprint, recorded_at.split('\t')[0]
    except OSError:
        return None, None


def load_package_module(module_name, file_name):
    # 不写 __pycache__：它会是仓里一个未跟踪的新目录，门禁跑到一半冒出来，「工作区跑的过程中没变」那一项就对不上
    sys.dont_write_bytecode = True
    specification = importlib.util.spec_from_file_location(
        module_name, os.path.join(os.path.dirname(os.path.realpath(__file__)), file_name))
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


# 解释器命令行里带一个值的选项：跳过选项时连它的值一起跳过，否则会把值当成脚本（bash -o pipefail x.sh）
INTERPRETER_OPTIONS_TAKING_A_VALUE = {'-o', '+o', '-O', '+O', '--rcfile', '--init-file', '-W', '-X', '-Q'}


def script_operand(arguments):
    """解释器命令行里被当成脚本文件跑的那个参数；-c / -m 跑的是字符串或模块，返回 None。"""
    index = 1
    while index < len(arguments):
        value = arguments[index]
        if value == '--':
            return arguments[index + 1] if index + 1 < len(arguments) else None
        if value in INTERPRETER_OPTIONS_TAKING_A_VALUE:
            index += 2
            continue
        if value.startswith('-') or value.startswith('+'):
            if value == '-m' or (not value.startswith('--') and 'c' in value[1:]):
                return None
            index += 1
            continue
        return value
    return None


# 找进程、认祖先的函数直接 import proc.py 的，不另写一份：它按可执行文件名找，这里按脚本路径找同一个脚本的别的实例
def other_instances(script_path):
    """别的进程在跑同一个脚本：/proc/<pid>/exe 就是它，或解释器命令行里的脚本参数解析到它。自己与祖先不算。
    Rust 实验传进来的是源文件，跑着的是编出来的二进制：按调 preflight.py 的那个进程（父进程）的可执行文件认；
    父进程本身是个解释器（经 sh -c 调的）时认不出是哪个二进制，返回 None（判不了）。"""
    process_module = load_package_module('proc', 'proc.py')
    excluded = process_module.ancestor_process_ids()
    if source_language(script_path) == 'rust':
        try:
            script_path = os.path.realpath(f'/proc/{os.getppid()}/exe')
        except OSError:
            return None
        if INTERPRETER_NAME_RE.match(os.path.basename(script_path)):
            return None
    hits = []
    for entry in os.listdir('/proc'):
        if not entry.isdigit() or int(entry) in excluded:
            continue
        process_id = int(entry)
        arguments = process_module.arguments_of(process_id)
        if not arguments or not process_module.is_alive(process_id):
            continue
        try:
            if os.path.realpath(f'/proc/{process_id}/exe') == script_path:
                hits.append((process_id, arguments))
                continue
        except OSError:
            pass
        if not INTERPRETER_NAME_RE.match(os.path.basename(arguments[0])):
            continue
        operand = script_operand(arguments)
        if not operand:
            continue
        if not os.path.isabs(operand):
            try:
                operand = os.path.join(os.readlink(f'/proc/{process_id}/cwd'), operand)
            except OSError:
                continue
        if os.path.realpath(operand) == script_path:
            hits.append((process_id, arguments))
    return sorted(hits)


def evaluate(script_path, declaration, arguments):
    """→ Unmet 或 None。"""
    kind = declaration.kind
    if kind in ('always', 'none'):
        return None
    if kind == 'command':
        missing = [name for name in declaration.executable_names if shutil.which(name) is None]
        if missing:
            return Unmet(declaration, f'缺 {" ".join(missing)}', '装上它，或把它放进 PATH，再跑', CATEGORY_CONDITION)
        return None
    if kind == 'check':
        toplevel = repository_toplevel(os.path.dirname(script_path))
        environment = dict(git_environment(), PREFLIGHT_SCRIPT=script_path, PREFLIGHT_SCRIPT_DIRECTORY=os.path.dirname(script_path))
        try:
            completed = subprocess.run(['bash', '-c', declaration.command], cwd=toplevel or os.path.dirname(script_path), env=environment,
                                       stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=CHECK_TIMEOUT_SECONDS)
        except subprocess.TimeoutExpired:
            return Unmet(declaration, f'判据 {CHECK_TIMEOUT_SECONDS} 秒没跑完：{declaration.command}', declaration.next_step, CATEGORY_CONDITION)
        if completed.returncode != 0:
            return Unmet(declaration, f'判据不成立（退出码 {completed.returncode}）：{declaration.command}', declaration.next_step, CATEGORY_CONDITION)
        return None
    if kind == 'single-instance':
        if not os.path.isdir('/proc'):
            return Unmet(declaration, '判不了有没有别的实例在跑：这台机器没有 /proc', '在 Linux 上跑；确认没有别的实例在跑再加 --force', CATEGORY_CONDITION)
        hits = other_instances(script_path)
        if hits is None:
            return Unmet(declaration, '判不了有没有别的实例在跑：调 preflight.py 的是一个解释器（经 sh -c 调的），认不出跑的是哪个二进制',
                         '在 Rust 里直接起 python3 调 preflight.py，别经 sh -c；确认没有别的实例在跑再加 --force', CATEGORY_CONDITION)
        if hits:
            listed = '；'.join(f'{process_id}（{" ".join(arguments)[:120]}）' for process_id, arguments in hits)
            return Unmet(declaration, f'同一个脚本已有 {len(hits)} 个实例在跑：{listed}',
                         f'等它跑完：python3 {os.path.join(os.path.dirname(os.path.realpath(__file__)), "proc.py")} wait <进程号> --timeout <秒>', CATEGORY_CONDITION)
        return None
    raise ValueError(f'evaluate 不判 {kind}：inputs-changed 由 evaluate_inputs 合成一份判')


def evaluate_inputs(script_path, inputs, arguments):
    """合成之后的 inputs-changed → (开跑时的指纹或 -, Unmet 或 None)。"""
    fingerprint, cannot_judge = input_fingerprint(script_path, inputs, arguments)
    if cannot_judge:
        return '-', Unmet(inputs, cannot_judge, '改对文件头里登记的路径，或者把那份输入补上', CATEGORY_CONDITION)
    recorded_fingerprint, recorded_at = read_stamp(script_path)
    if recorded_fingerprint == fingerprint:
        return fingerprint, Unmet(inputs, f'脚本与登记的输入自上次成功跑完（{recorded_at}）以来没变，重跑得不到新信息',
                                  '改了代码、决策或登记的输入再跑；确要重跑（复现、换了机器或环境）就加 --force，这一次的结果记成「强制跑」',
                                  CATEGORY_INPUTS_UNCHANGED)
    return fingerprint, None


class Outcome:
    def __init__(self, verdict, category='', summary='', fingerprint='-'):
        self.verdict = verdict
        self.category = category
        self.summary = summary
        self.fingerprint = fingerprint

    def machine_line(self):
        if self.verdict == 'met':
            return f'met\t{self.fingerprint}'
        if self.verdict == 'undeclared':
            return self.verdict
        if self.verdict == 'malformed':
            return f'malformed\t{self.summary}'
        return f'{self.verdict}\t{self.category}\t{self.summary}'


def display_path(script_path):
    toplevel = repository_toplevel(os.path.dirname(script_path))
    return os.path.relpath(script_path, toplevel) if toplevel else script_path


def judge(script_file, arguments, force):
    """现判一个脚本的准入与运行条件；人读的报告写 stderr。"""
    script_path = os.path.realpath(script_file)
    shown = display_path(script_path)
    declarations, problems = parse_declarations(script_path)
    if problems:
        for problem in problems:
            print(f'  ✗ {shown}:{problem.line_number} 准入与运行条件写坏了，判不了能不能跑：{problem.what}', file=sys.stderr)
            print(f'     → 怎么办： {problem.next_step}', file=sys.stderr)
        return Outcome('malformed', summary=f'{shown} 的条件写坏了 {len(problems)} 处')
    if not declarations:
        print(f'  ! {shown} 的文件头没写准入与运行条件（{RULE_FILE}），照跑；门禁阶段「准入与运行条件」判它', file=sys.stderr)
        return Outcome('undeclared')
    unmet = [result for result in (evaluate(script_path, declaration, arguments) for declaration in declarations
                                   if declaration.kind != 'inputs-changed') if result]
    fingerprint = '-'
    inputs = combined_inputs(declarations)
    if inputs:
        fingerprint, inputs_unmet = evaluate_inputs(script_path, inputs, arguments)
        if inputs_unmet:
            unmet.append(inputs_unmet)
    if not unmet:
        return Outcome('met', fingerprint=fingerprint)
    category = CATEGORY_INPUTS_UNCHANGED if all(result.category == CATEGORY_INPUTS_UNCHANGED for result in unmet) else CATEGORY_CONDITION
    summary = '；'.join(f'{result.declaration.label()}：{result.what}' for result in unmet)
    if force:
        print(f'  ! {shown}：{len(unmet)} 条条件没满足，--force 强制跑（这一次的结果记成「强制跑」，写产物的把 PREFLIGHT_FORCED 写进产物）：', file=sys.stderr)
        for result in unmet:
            print(f'       - {result.declaration.label()}（第 {result.declaration.line_number} 行）：{result.what}', file=sys.stderr)
        return Outcome('forced', category, summary)
    print(f'  ✗ {shown}：{len(unmet)} 条条件没满足，拒绝执行（退出码 {EXIT_REFUSED}）：', file=sys.stderr)
    for result in unmet:
        print(f'       - {result.declaration.label()}（第 {result.declaration.line_number} 行）：{result.what}', file=sys.stderr)
        print(f'         → {result.next_step}', file=sys.stderr)
    print(f'     → 怎么办： 按上面每一条的出路补齐条件再跑；确认要在条件不满足时照跑，加 --force（结果记成「强制跑」，规矩见 {RULE_FILE}）', file=sys.stderr)
    return Outcome('refused', category, summary)


def record(script_file, arguments, fingerprint_at_start=None):
    """成功跑完时记下输入指纹；没声明 inputs-changed 的不记。→ (记没记下, 没记的原因或 None)
    给了开跑时的指纹就只记它，而且收尾时重算一遍：对不上说明跑的过程中输入变了，这一次测的不是现在这一版，不记。"""
    script_path = os.path.realpath(script_file)
    declarations, problems = parse_declarations(script_path)
    if problems:
        return False, f'{display_path(script_path)} 的条件写坏了，记不了'
    inputs = combined_inputs(declarations)
    if not inputs:
        return False, None
    fingerprint, cannot_judge = input_fingerprint(script_path, inputs, arguments)
    if cannot_judge:
        return False, cannot_judge
    if fingerprint_at_start and fingerprint_at_start != fingerprint:
        return False, (f'跑的过程中登记的输入变了（开跑时 {fingerprint_at_start[:12]}，收尾时 {fingerprint[:12]}）：'
                       '这一次测的不是现在这一版，不记（下一次照跑）')
    path = stamp_path(script_path)
    if not path:
        return False, '不在 git 仓里，没处记（下一次照跑）'
    os.makedirs(os.path.dirname(path), exist_ok=True)
    temporary_path = f'{path}.{os.getpid()}.partial'
    with open(temporary_path, 'w', encoding='utf-8') as handle:
        handle.write(f'{fingerprint}\t{datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}\t{display_path(script_path)}\n')
    os.replace(temporary_path, path)
    return True, None


# ── python 脚本用的两个入口 ────────────────────────────
PREFLIGHT_STATE = {'script': None, 'arguments': [], 'forced': '', 'fingerprint': '-'}
# 条件写坏了，python 脚本退 1，与 shell 一侧相同（3 在别的脚本里是「无对象可判」）。命令行 check 仍退 EXIT_MALFORMED
EXIT_MALFORMED_IN_SCRIPT = 1


def preflight(script_file, arguments=None):
    """python 脚本开头调它：摘掉 --force、现判条件。不满足就退 78；强制跑时置环境变量 PREFLIGHT_FORCED（没满足的条件摘要）。
    arguments 不给时判 sys.argv[1:]，并把 --force 从 sys.argv 里摘掉；返回摘掉之后的参数。"""
    uses_process_arguments = arguments is None
    given = sys.argv[1:] if uses_process_arguments else list(arguments)
    force = '--force' in given
    remaining = [value for value in given if value != '--force']
    if uses_process_arguments:
        sys.argv[1:] = remaining
    outcome = judge(script_file, remaining, force)
    if outcome.verdict == 'refused':
        sys.exit(EXIT_REFUSED)
    if outcome.verdict == 'malformed':
        sys.exit(EXIT_MALFORMED_IN_SCRIPT)
    PREFLIGHT_STATE.update(script=os.path.realpath(script_file), arguments=remaining, fingerprint=outcome.fingerprint,
                           forced=outcome.summary if outcome.verdict == 'forced' else '')
    os.environ['PREFLIGHT_FORCED'] = PREFLIGHT_STATE['forced']
    return remaining


def preflight_record_success():
    """成功跑完时调：记下这一次的输入指纹。强制跑的那一次不记。"""
    if PREFLIGHT_STATE['script'] is None:
        raise RuntimeError('preflight_record_success 之前没调 preflight：先在开头调 preflight(__file__)')
    if PREFLIGHT_STATE['forced']:
        print('  ! 这一次是强制跑的，不记成「上次成功」：下一次照判输入变没变', file=sys.stderr)
        return
    if PREFLIGHT_STATE['fingerprint'] == '-':
        return
    try:
        _, not_recorded = record(PREFLIGHT_STATE['script'], PREFLIGHT_STATE['arguments'], PREFLIGHT_STATE['fingerprint'])
    except OSError as error:
        not_recorded = f'写不进指纹文件：{error}'
    if not_recorded:
        print(f'  ! 没记下这一次的输入指纹：{not_recorded}', file=sys.stderr)


def split_command_line(values):
    """<脚本> [--force] [--fingerprint <开跑时的指纹>] [-- <参数…>] → (脚本, 强制, 指纹或 None, 参数)；认不出返回脚本为 None。"""
    if not values:
        return None, False, None, []
    script, rest = values[0], values[1:]
    force, fingerprint = False, None
    while rest and rest[0] != '--':
        if rest[0] == '--force':
            force, rest = True, rest[1:]
        elif rest[0] == '--fingerprint' and len(rest) > 1:
            fingerprint, rest = rest[1], rest[2:]
        else:
            return None, False, None, []
    return script, force, fingerprint, rest[1:] if rest else []


def main():
    usage = ('用法：preflight.py check <脚本> [--force] [-- <参数…>] | record <脚本> [--fingerprint <开跑时的指纹>] [-- <参数…>]'
             ' | declared <脚本>')
    if len(sys.argv) < 3 or sys.argv[1] not in ('check', 'record', 'declared'):
        print(f'  ✗ {usage}', file=sys.stderr)
        print(f'     → 怎么办： 照这个用法再调一次；规矩见 {RULE_FILE}', file=sys.stderr)
        return EXIT_USAGE
    command = sys.argv[1]
    script, force, fingerprint, arguments = split_command_line(sys.argv[2:])
    if script is None or not os.path.isfile(script):
        print(f'  ✗ 找不到要判的脚本，或参数不对：{" ".join(sys.argv[2:])}', file=sys.stderr)
        print(f'     → 怎么办： {usage}', file=sys.stderr)
        return EXIT_USAGE
    if command == 'declared':
        declarations, problems = parse_declarations(os.path.realpath(script))
        return 0 if declarations or problems else 1
    if command == 'record':
        if force:
            print('  ✗ record 不收 --force：强制跑的那一次不记成「上次成功」', file=sys.stderr)
            print('     → 怎么办： 调用方判到这一次是强制跑的，就别调 record', file=sys.stderr)
            return EXIT_USAGE
        try:
            _, not_recorded = record(script, arguments, fingerprint)
        except OSError as error:
            not_recorded = f'写不进指纹文件：{error}'
        if not_recorded:
            print(f'  ! 没记下这一次的输入指纹：{not_recorded}', file=sys.stderr)
        return EXIT_ALLOWED
    if fingerprint:
        print('  ✗ check 不收 --fingerprint：指纹是 check 算出来交给调用方的', file=sys.stderr)
        print(f'     → 怎么办： {usage}', file=sys.stderr)
        return EXIT_USAGE
    outcome = judge(script, arguments, force)
    print(outcome.machine_line())
    if outcome.verdict == 'refused':
        return EXIT_REFUSED
    if outcome.verdict == 'malformed':
        return EXIT_MALFORMED
    return EXIT_ALLOWED


if __name__ == '__main__':
    sys.exit(main())
