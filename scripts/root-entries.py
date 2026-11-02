#!/usr/bin/env python3
# gate-similar: gate-overlap.py 它判这一次新加与改动的门禁和钩子该不该单独存在，对象是脚本；这一道判项目根下新加的文件与目录登没登记，对象与判据都不同；算 diff 基准、认 Bash 写到哪的两段调它的，不另写
# gate-similar: version-discipline.sh 同样只看 diff 窗口，但它判改没改规范本体、抬没抬版本，不看项目根下多了什么
# gate-similar: script-modes.sh 它判暂存区里的执行位与射程里的空目录，不看项目根下的条目
# admission: always 判的是此刻项目根下的条目与登记表，diff 窗口随提交在动
# run-condition: command git
"""项目根下不新建文件与目录；确实要建的，向用户申请过、在 .claude/root-entries 登记了才建（rules/command-safety.md「项目根下不新建文件与目录」）。

登记表：项目根的 .claude/root-entries，一行一条 `<名字>  # 理由`。名字只写一层（可以带结尾的 /，不许再有别的 /），
  理由不少于 MINIMUM_REASON_CHARACTERS 个字，同一个名字只许一行。没有这份文件就是一条都没登记。
  本包自己要放在项目根的几个（PACKAGE_ROOT_ENTRIES）不用登记。
读登记表与「哪些名字在项目根下」只在这一处，门禁阶段与钩子 claude-hooks/root-entry-guard.sh 都调它。

两种用法：
  root-entries.py [项目根]
      门禁阶段「项目根的新条目」。项目根下的条目取 git 跟踪的与没被 .gitignore 忽略的未跟踪的，各取第一层；
      相对 diff 基准（GATE_DIFF_BASE，单跑时按 lib.sh 的 diff_base 现算）新加的，每个都要登记。
      另判登记表本身：行写坏了（没写理由、理由太短、名字带 /、重复），或登记的条目不在、也不被 .gitignore 覆盖，判红。
      被忽略的条目不判：--staged 的临时树里它们本来就不在，判了两种跑法就对不上。它们只有钩子看得到。
  root-entries.py --hook
      Claude Code 钩子的判定（从 stdin 读钩子 JSON）：
        PreToolUse 的 Write / Edit / MultiEdit / NotebookEdit：要写的路径落在项目根下一个还不存在、也没登记的条目里，拒绝（退 2）；
          写的是登记表本身，要用户在界面上确认（stdout 打 permissionDecision 为 ask 的 JSON，退 0）。
        PreToolUse 的 Bash：命令写到登记表（认法与 gate-overlap.py 的 bash_write_targets 同一份），要用户确认；
          另外记下项目根此刻有哪些条目（按 session_id 与 tool_use_id 存一份，状态目录 ROOT_ENTRY_GUARD_STATE_DIRECTORY，
          默认 ${TMPDIR:-/tmp}/root-entry-guard）。
        PostToolUse 的 Bash：与跑之前记下的比，多出来的条目里没登记的，报给 agent（退 2）。这一步在命令跑完之后，建出来的已经在了。
      判不了退 1（输入不是 JSON 对象、找不到项目根、Bash 跑之前没记下条目），Claude Code 照常放行，stderr 留一行原因。

退出码（门禁）：0 通过；1 有红；3 判不了（diff 基准算不出、git 出错、脚本自己出错）；77 不在 git 仓里，或仓里还没有提交（无对象可判，不算通过）。

管不到的：用户同意没有、理由成不成立，靠 review；被 .gitignore 忽略的条目，门禁不判；
  Bash 里建的，钩子在命令跑完之后才报；Bash 写登记表的写法拼在变量里、写在解释器里的，认不出，不要求确认。
"""
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import traceback
# 开跑之前先判准入与运行条件（rules/preflight-discipline.md）；不写 __pycache__：门禁跑到一半冒出一个未跟踪的目录，「工作区跑的过程中没变」就对不上
sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
from preflight import load_package_module, preflight  # noqa: E402

REGISTRY_RELATIVE_PATH = os.path.join('.claude', 'root-entries')
# 本包自己要放在项目根的：git 的目录、install.sh 铺的 CLAUDE.md 与版本戳、装副本与登记表的 .claude。不用登记。
PACKAGE_ROOT_ENTRIES = frozenset({'.git', '.claude', 'CLAUDE.md', '.singlefs-ai-sop-version'})
MINIMUM_REASON_CHARACTERS = 4
RULE_REFERENCE = 'rules/command-safety.md「项目根下不新建文件与目录」'
WRITING_TOOL_PATH_KEYS = {'Write': 'file_path', 'Edit': 'file_path', 'MultiEdit': 'file_path', 'NotebookEdit': 'notebook_path'}
DEFAULT_STATE_DIRECTORY = os.path.join(os.environ.get('TMPDIR') or '/tmp', 'root-entry-guard')

EXIT_PASSED = 0
EXIT_RED = 1
EXIT_HOOK_BLOCKED = 2
EXIT_CANNOT_JUDGE = 3
EXIT_NOTHING_TO_JUDGE = 77
EXIT_HOOK_NOT_JUDGED = 1


class CannotJudge(Exception):
    """判不了：不是判红，是这一轮没判成。带着卡在哪与下一步。"""

    def __init__(self, problem, next_step):
        super().__init__(problem)
        self.problem = problem
        self.next_step = next_step


def read_registry(project_root):
    """读登记表 → (名字到理由的字典, 写坏了的行的说明列表)。没有这份文件就是空字典、没有问题。"""
    registry_path = os.path.join(project_root, REGISTRY_RELATIVE_PATH)
    registered_reasons, problems = {}, []
    try:
        with open(registry_path, encoding='utf-8', errors='replace') as registry_file:
            registry_lines = registry_file.read().splitlines()
    except FileNotFoundError:
        return registered_reasons, problems
    for line_number, raw_line in enumerate(registry_lines, start=1):
        stripped_line = raw_line.strip()
        if not stripped_line or stripped_line.startswith('#'):
            continue
        location = f'{REGISTRY_RELATIVE_PATH}:{line_number}'
        if '#' not in stripped_line:
            problems.append(f'{location} 没写理由：{stripped_line}')
            continue
        name_part, reason = stripped_line.split('#', 1)
        entry_name, reason = name_part.strip(), reason.strip()
        if entry_name.endswith('/'):
            entry_name = entry_name[:-1]
        if not entry_name or '/' in entry_name or entry_name in ('.', '..'):
            problems.append(f'{location} 名字不是项目根下的一层：「{name_part.strip()}」')
            continue
        if len(reason) < MINIMUM_REASON_CHARACTERS:
            problems.append(f'{location} 理由不到 {MINIMUM_REASON_CHARACTERS} 个字：{entry_name}  # {reason}')
            continue
        if entry_name in registered_reasons:
            problems.append(f'{location} 重复登记：{entry_name}')
            continue
        registered_reasons[entry_name] = reason
    return registered_reasons, problems


def run_git(project_root, *arguments):
    return subprocess.run(['git', '-C', project_root, *arguments], capture_output=True, text=True,
                          encoding='utf-8', errors='replace')


def git_first_components(project_root, *arguments):
    """git 列出的路径（-z 分隔、相对项目根）各取第一层。"""
    listing = run_git(project_root, *arguments)
    if listing.returncode != 0:
        raise CannotJudge(f'git {" ".join(arguments)} 失败：{listing.stderr.strip()}',
                          f'在 {project_root} 里手跑同一条命令看 git 报什么，修好再跑。')
    return {path.split('/', 1)[0] for path in listing.stdout.split('\0') if path}


def is_ignored(project_root, entry_name):
    return run_git(project_root, 'check-ignore', '-q', '--no-index', '--', entry_name).returncode == 0


def judge_gate(project_root):
    if run_git(project_root, 'rev-parse', '--is-inside-work-tree').returncode != 0:
        print(f'  ! {project_root} 不在 git 仓里，项目根的新条目无从比起，本阶段无对象可判（这不是通过）')
        return EXIT_NOTHING_TO_JUDGE
    gate_overlap = load_package_module('gate_overlap', 'gate-overlap.py')
    try:
        diff_base = gate_overlap.resolve_diff_base(project_root)
    except gate_overlap.CannotJudge as error:
        raise CannotJudge(error.problem, error.next_step) from None
    if diff_base == gate_overlap.EMPTY_TREE:
        print('  ! 仓里还没有提交，没有基准可比，本阶段无对象可判（这不是通过）')
        return EXIT_NOTHING_TO_JUDGE
    print(f'  diff 基准：{diff_base}')
    registered_reasons, problems = read_registry(project_root)
    current_entries = git_first_components(project_root, 'ls-files', '-z') | git_first_components(
        project_root, 'ls-files', '-z', '--others', '--exclude-standard', '--directory', '--no-empty-directory')
    base_entries = git_first_components(project_root, 'ls-tree', '-z', '--name-only', diff_base)
    new_entries = sorted(current_entries - base_entries)
    unregistered_new_entries = [entry_name for entry_name in new_entries
                                if entry_name not in registered_reasons and entry_name not in PACKAGE_ROOT_ENTRIES]
    missing_registered_entries = sorted(
        entry_name for entry_name in registered_reasons
        if not os.path.lexists(os.path.join(project_root, entry_name)) and not is_ignored(project_root, entry_name))
    failed = False
    if problems:
        print(f'  ✗ 登记表 {REGISTRY_RELATIVE_PATH} 有 {len(problems)} 行写坏了：')  # gate-lint:summary
        for problem in problems:
            print(f'        {problem}')  # gate-lint:detail
        print(f'     → 怎么办：一行一条 `<名字>  # 理由`：名字只写项目根下的那一层，理由至少 {MINIMUM_REASON_CHARACTERS} 个字，写放什么、为什么不能放进已有的目录；一个名字只登记一行。')
        failed = True
    if unregistered_new_entries:
        print(f'  ✗ 项目根下新加了 {len(unregistered_new_entries)} 个没登记的条目：{"、".join(unregistered_new_entries)}')
        print('     → 怎么办：挪进已有的目录（草稿与日志放 $TMPDIR，脚本、记录、产物放项目定好的目录）；'
              f'确实要放在根下，先向用户申请，同意了在 {REGISTRY_RELATIVE_PATH} 登记一行 `<名字>  # 理由`，与它同一次提交（{RULE_REFERENCE}）。')
        failed = True
    if missing_registered_entries:
        print(f'  ✗ 登记表里有 {len(missing_registered_entries)} 条登记的条目不在项目根下、也不被 .gitignore 覆盖：{"、".join(missing_registered_entries)}')
        print(f'     → 怎么办：条目已经删掉的，把 {REGISTRY_RELATIVE_PATH} 里那一行也删掉；还没提交进来的，与登记表同一次提交。')
        failed = True
    if failed:
        return EXIT_RED
    print(f'  ✓ 项目根下 {len(current_entries)} 个条目（不算被忽略的），相对基准新加 {len(new_entries)} 个，都登记了；'
          f'登记表 {len(registered_reasons)} 条都指得到')
    return EXIT_PASSED


# ── 钩子 ──────────────────────────────────────────────────

def hook_not_judged(reason):
    print(f'! root-entry-guard：{reason}，这一次没判（照常执行）。', file=sys.stderr)
    return EXIT_HOOK_NOT_JUDGED


def ask_user(reason):
    print(json.dumps({'hookSpecificOutput': {'hookEventName': 'PreToolUse', 'permissionDecision': 'ask',
                                             'permissionDecisionReason': reason}}, ensure_ascii=False))
    return EXIT_PASSED


def registry_change_reason(project_root):
    return (f'要改项目根的登记表 {REGISTRY_RELATIVE_PATH}：登记一条就是准许在项目根下新建它（{RULE_REFERENCE}）。'
            '确认 agent 已经说清要建什么、为什么不能放进已有的目录，并且你同意了，再放行。')


def entry_of(project_root, path):
    """路径落在项目根下的哪一个条目（第一层的名字）；不在项目根下、或就是项目根本身，返回 None。"""
    relative_path = os.path.relpath(os.path.realpath(path), project_root)
    if relative_path == '.' or relative_path == '..' or relative_path.startswith('..' + os.sep):
        return None
    return relative_path.split(os.sep, 1)[0]


def is_registry_path(project_root, path):
    return os.path.realpath(path) == os.path.realpath(os.path.join(project_root, REGISTRY_RELATIVE_PATH))


def judge_writing_tool(project_root, tool_input, path_key, session_directory):
    path = tool_input.get(path_key)
    if not isinstance(path, str) or not path:
        return EXIT_PASSED
    if not os.path.isabs(path):
        path = os.path.join(session_directory or project_root, path)
    if is_registry_path(project_root, path):
        return ask_user(registry_change_reason(project_root))
    entry_name = entry_of(project_root, path)
    if entry_name is None or os.path.lexists(os.path.join(project_root, entry_name)):
        return EXIT_PASSED
    registered_reasons, _ = read_registry(project_root)
    if entry_name in registered_reasons or entry_name in PACKAGE_ROOT_ENTRIES:
        return EXIT_PASSED
    print(f'✗ 这一步要在项目根下新建「{entry_name}」（{path}），它没登记，执行前拒绝。', file=sys.stderr)
    print('→ 怎么办：放进已有的目录：草稿与日志放 $TMPDIR 或会话的草稿目录，脚本、记录、产物放项目定好的目录。'
          f'确实要放在根下：先向用户申请，说清要建什么、放什么、为什么不能放进已有的目录；用户同意后在 {REGISTRY_RELATIVE_PATH} '
          f'登记一行 `{entry_name}  # 理由`（改登记表要用户在界面上确认），再建（{RULE_REFERENCE}）。', file=sys.stderr)
    return EXIT_HOOK_BLOCKED


def snapshot_path(state_directory, session_id, tool_use_id):
    return os.path.join(state_directory, f'{session_id}-{tool_use_id}.json')


def root_entries_now(project_root):
    return sorted(os.listdir(project_root))


def judge_bash_before(project_root, tool_input, state_directory, session_id, tool_use_id):
    record_snapshot(project_root, state_directory, session_id, tool_use_id)
    command = tool_input.get('command')
    if not isinstance(command, str) or not command.strip():
        return EXIT_PASSED
    gate_overlap = load_package_module('gate_overlap', 'gate-overlap.py')
    if any(is_registry_path(project_root, target) for target in gate_overlap.bash_write_targets(command, project_root)):
        return ask_user(registry_change_reason(project_root))
    return EXIT_PASSED


def record_snapshot(project_root, state_directory, session_id, tool_use_id):
    os.makedirs(state_directory, exist_ok=True)
    with tempfile.NamedTemporaryFile('w', encoding='utf-8', dir=state_directory, delete=False) as snapshot_file:
        json.dump(root_entries_now(project_root), snapshot_file)
    os.replace(snapshot_file.name, snapshot_path(state_directory, session_id, tool_use_id))


def judge_bash_after(project_root, state_directory, session_id, tool_use_id):
    recorded_path = snapshot_path(state_directory, session_id, tool_use_id)
    try:
        with open(recorded_path, encoding='utf-8') as snapshot_file:
            entries_before = set(json.load(snapshot_file))
    except (OSError, ValueError):
        return hook_not_judged(f'找不到这条命令跑之前记下的项目根条目（{recorded_path}）：PreToolUse 的 Bash 上没挂这个钩子，或状态目录被清了')
    os.remove(recorded_path)
    registered_reasons, _ = read_registry(project_root)
    created_entries = [entry_name for entry_name in root_entries_now(project_root)
                       if entry_name not in entries_before and entry_name not in registered_reasons
                       and entry_name not in PACKAGE_ROOT_ENTRIES]
    if not created_entries:
        return EXIT_PASSED
    print(f'✗ 这条命令跑完，项目根下多出 {len(created_entries)} 个没登记的条目：{"、".join(created_entries)}'
          '（同时在跑的别的会话建的也会算进来，先认一认是不是你建的）。', file=sys.stderr)
    print('→ 怎么办：是你建的，就挪进已有的目录或删掉（草稿与日志放 $TMPDIR 或会话的草稿目录）；'
          f'确实要放在根下，先向用户申请，说清为什么不能放进已有的目录，用户同意后在 {REGISTRY_RELATIVE_PATH} 登记一行 `<名字>  # 理由`'
          f'（{RULE_REFERENCE}）。', file=sys.stderr)
    return EXIT_HOOK_BLOCKED


def judge_hook(hook_text, state_directory):
    try:
        hook_input = json.loads(hook_text)
    except ValueError:
        hook_input = None
    if not isinstance(hook_input, dict):
        return hook_not_judged('钩子输入不是 JSON 对象（看一眼 .claude/settings.json 里它是不是挂在 PreToolUse / PostToolUse 上）')
    session_directory = hook_input.get('cwd') if isinstance(hook_input.get('cwd'), str) else ''
    project_root = os.environ.get('CLAUDE_PROJECT_DIR') or session_directory
    if not project_root or not os.path.isdir(project_root):
        return hook_not_judged(f'找不到项目根（CLAUDE_PROJECT_DIR 与输入里的 cwd：{project_root or "都没有"}）')
    project_root = os.path.realpath(project_root)
    tool_name = hook_input.get('tool_name')
    tool_input = hook_input.get('tool_input') if isinstance(hook_input.get('tool_input'), dict) else {}
    event_name = hook_input.get('hook_event_name')
    session_id = ''.join(character if character.isalnum() or character in '-_' else '_'
                         for character in str(hook_input.get('session_id') or 'no-session'))
    # 跑之前与跑之后靠 tool_use_id 对上；输入里没有它时退到命令文本的指纹（同一会话里并行跑两条一模一样的命令才会撞）
    tool_use_id = ''.join(character if character.isalnum() or character in '-_' else '_'
                          for character in str(hook_input.get('tool_use_id') or ''))
    if not tool_use_id:
        tool_use_id = 'command-' + hashlib.sha256(str(tool_input.get('command')).encode('utf-8')).hexdigest()[:16]
    if tool_name in WRITING_TOOL_PATH_KEYS and event_name == 'PreToolUse':
        return judge_writing_tool(project_root, tool_input, WRITING_TOOL_PATH_KEYS[tool_name], session_directory)
    if tool_name == 'Bash' and event_name == 'PreToolUse':
        return judge_bash_before(project_root, tool_input, state_directory, session_id, tool_use_id)
    if tool_name == 'Bash' and event_name == 'PostToolUse':
        return judge_bash_after(project_root, state_directory, session_id, tool_use_id)
    return EXIT_PASSED


def main():
    arguments = sys.argv[1:]
    if arguments == ['--hook']:
        return judge_hook(sys.stdin.read(), os.environ.get('ROOT_ENTRY_GUARD_STATE_DIRECTORY') or DEFAULT_STATE_DIRECTORY)
    if len(arguments) > 1:
        print(f'  ✗ 只收一个项目根，收到 {len(arguments)} 个：{" ".join(arguments)}')
        print('     → 怎么办：用法 root-entries.py [项目根]，或 root-entries.py --hook（从 stdin 读钩子 JSON）')
        return EXIT_CANNOT_JUDGE
    project_root = os.path.realpath(arguments[0] if arguments else '.')
    if not os.path.isdir(project_root):
        print(f'  ✗ 找不到项目根：{project_root}')
        print('     → 怎么办：在项目根跑，或者把项目根作为参数传进来。')
        return EXIT_CANNOT_JUDGE
    return judge_gate(project_root)


if __name__ == '__main__':
    preflight(__file__)
    try:
        sys.exit(main())
    except CannotJudge as error:
        print(f'  ✗ 项目根的新条目判不了：{error.problem}')
        print(f'     → 怎么办：{error.next_step}')
        sys.exit(EXIT_CANNOT_JUDGE)
    except Exception:  # noqa: BLE001 —— 脚本自己出错与「判红」分开报；钩子据此不拦
        traceback.print_exc(file=sys.stderr)
        if sys.argv[1:] == ['--hook']:
            print('! root-entry-guard：判定脚本自己出错了（上面是调用栈），这一次没判（照常执行）。', file=sys.stderr)
            sys.exit(EXIT_HOOK_NOT_JUDGED)
        print('  ✗ 项目根的新条目：判定脚本自己出错了（stderr 里是调用栈），这一轮没判')
        print('     → 怎么办：这是 root-entries.py 的缺陷，按调用栈修它；修好之前这一道不算通过。')
        sys.exit(EXIT_CANNOT_JUDGE)
