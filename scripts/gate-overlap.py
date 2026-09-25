#!/usr/bin/env python3
# gate-similar: gate-lint.sh 它逐个脚本、逐行判拒绝带不带出路，不看文件之间，也不看这一次改动加了什么
# gate-similar: hooks-registered.sh 它判钩子注册着、自检过、事件挂全，不看两个钩子是不是挂在同一个触发点上；读 settings.json、认命令指向哪个钩子的那段已抽成 hook-registrations.py，两边共用
"""新加的门禁与钩子要先对过已有的：能追加就追加，能合并就合并，不另起一份，更不整段抄一份。

判的是新加与改动的部分，不翻存量：
  ① 新加的门禁阶段或钩子，文件里至少一行
       # gate-similar: <已有的门禁或钩子的文件名> <为什么不并进它>
     一个像的都没有就写 `# gate-similar: 无 <查过哪些>`。点名的要是已有的门禁或钩子，理由不少于 MINIMUM_REASON_CHARACTERS 个字。
     新加的 Claude Code 钩子还要写 `# hook-events: <事件> …`，列出它要挂的每个事件。
  ② 下面这几种已有的，每一个都要点名，写「无」不算：
     - 与新钩子挂在同一个事件上、matcher 有交集的已有钩子（按 .claude/settings.json 的注册；新钩子还没注册的事件按 hook-events 声明、matcher 当全匹配）；
     - 与新加的那份字面上很像的已有门禁或钩子（标识符重合 ≥ SIMILARITY_REQUIRING_NAMING，两边都至少 MINIMUM_IDENTIFIERS_FOR_SIMILARITY 个）。
  ③ 加进来的行里，有连续 CLONE_MINIMUM_LINES 行（去掉空行、注释、短行与只剩一个关键字的行，行内连续空白压成一个之后）
     与另一份门禁、钩子或共享脚本逐行相同：判红。确实要留两份的，在其中一份里写
       # gate-overlap:copy-kept <另一份的文件名> <为什么不抽成共用>

「新加与改动」有两种算法：
  - 门禁阶段「门禁查重」：相对 GATE_DIFF_BASE（gate.sh 导出它；单跑时按 lib.sh 的 diff_base 现算）。
  - 收工钩子（--touched-by <会话记录>）：相对这个会话开始之前的最后一个提交（取会话记录里最早的时间戳），
    而且只判这个会话自己写过的文件——Write / Edit 类工具的 file_path，或 Bash 里写入的目标
    （重定向、tee、cp / mv / install / ln 的目标、touch、sed -i、git mv；跟着 cd 走）。
    认不出的写法：路径拼在变量里、python 或别的解释器里写文件。这些由门禁阶段兜底。

「门禁」：本包 gate.sh 里以 $SCRIPTS/<名> 调的脚本；项目的 .claude/gate.d/*.sh。
「钩子」：本包的 scripts/claude-hooks/*.sh（本包自己的仓里还有 scripts/githooks/*）；项目的 .claude/hooks/*.sh；
  以及 .claude/settings.json 里注册命令指向的文件，放在哪个目录、什么后缀都算。符号链接按它自己的路径认。
③ 的对照范围再加上本包 scripts/ 下其余的脚本，以及 .claude/gate.d/、.claude/hooks/ 下的 .py 助手。
装进项目的 SOP 副本只当对照，不判：它由上游自己的门禁管。注册命令指不到文件的（内联命令）判不了，成功那句逐个列出。

判不了的一半：点名的那一份是不是真的最像、「为什么不并进去」的理由成不成立，靠 review
（rules/sop-first.md「加门禁或钩子之前，先找已有的」）。

用法：
  gate-overlap.py [仓根]                          判这一次改动
  gate-overlap.py --touched-by <会话记录> [仓根]   只判这个会话写过的文件（收工钩子 claude-hooks/gate-reuse-check.sh 用它）
  gate-overlap.py --list [仓根]                   列出已有的门禁与钩子：文件、触发点、头一行说明。加新的之前先看这张表

退出码：0 通过；1 有红；2 参数不对；3 判不了（diff 基准算不出、settings.json 读不了、脚本自己出错）；
  77 这一次没有新加或改动门禁与钩子，或不在 git 仓里（无对象可判，不算通过）。
"""
import importlib.util
import os
import re
import shlex
import subprocess
import sys
import traceback

PACKAGE_SCRIPTS_DIRECTORY = os.path.dirname(os.path.realpath(__file__))
PACKAGE_ROOT = os.path.dirname(PACKAGE_SCRIPTS_DIRECTORY)
THIS_SCRIPT_FILE_NAME = 'gate-overlap.py'
RULE_SECTION = '「加门禁或钩子之前，先找已有的」'

EXIT_PASSED = 0
EXIT_RED = 1
EXIT_USAGE = 2
EXIT_CANNOT_JUDGE = 3
EXIT_NOTHING_TO_JUDGE = 77

# 连续多少行相同算「整段抄」。按上游包与一个使用者项目的门禁、钩子现量过：
# 6 行开始出现两份各写一遍的排除表解析这类真抄，同时开始混进几行一样的起手式（读共用库的 importlib 那几行）；
# 8 行以上只剩真抄的整段。取 8，宁可漏一小段，不让起手式把人逼去写豁免。selftest 用 7 行与 8 行两例钉住它。
CLONE_MINIMUM_LINES = 8
# 字面上多像就必须点名：同一批门禁与钩子两两算标识符重合（交集 / 并集），6216 对的中位数 0.10，
# 0.5 以上只有一对（两个判同一类「对抗审查」的阶段，0.74）。标识符太少的小脚本碰巧重合高，不算。
SIMILARITY_REQUIRING_NAMING = 0.5
MINIMUM_IDENTIFIERS_FOR_SIMILARITY = 20
MINIMUM_REASON_CHARACTERS = 8
# 这些行不带信息：两份脚本在这里相同，说明不了谁抄了谁。
INFORMATIONLESS_LINE_RE = re.compile(
    r'^(fi|done|esac|then|else|do|in|;;|PY|EOF|pass|continue|break|return|else:|try:|finally:|[(){}\[\],;]+)$')
MINIMUM_INFORMATIVE_LINE_LENGTH = 8

# 声明与豁免的字面。名字后面允许直接跟全角标点再接理由（`gate-lint.sh：它逐行判…`）。
SIMILAR_DECLARATION_RE = re.compile(r'^\s*#\s*gate-similar:\s*(无|[A-Za-z0-9._/-]+)\s*[：:，,、]?\s*(.*?)\s*$')
COPY_KEPT_RE = re.compile(r'^\s*#\s*gate-overlap:copy-kept\s+([A-Za-z0-9._/-]+)\s*[：:，,、]?\s*(.*?)\s*$')
HOOK_EVENTS_RE = re.compile(r'^\s*#\s*hook-events:\s*(.*?)\s*$')
GATE_STAGE_REFERENCE_RE = re.compile(r'\$\{?SCRIPTS\}?/([A-Za-z0-9._-]+\.(?:sh|py))')
IDENTIFIER_RE = re.compile(r'[A-Za-z_][A-Za-z0-9_.-]{3,}')
EMPTY_TREE = '4b825dc642cb6eb9a060e54bf8d69288fbee4904'
# 文件头里给机器读的那几种标记行，不当说明取。
MACHINE_DIRECTIVE_RE = re.compile(r'^(gate-similar|gate-overlap|gate-covers|gate-lint|shell-lint|hook-events|shellcheck)\b')

WRITING_TOOL_NAMES = {'Write', 'Edit', 'MultiEdit', 'NotebookEdit'}
SHELL_SEPARATORS = {';', '&&', '||', '|', '|&', '&', '(', ')', ';;'}
OUTPUT_REDIRECTIONS = {'>', '>>', '>|', '&>', '&>>'}
OTHER_REDIRECTIONS = {'<', '<<', '<<<', '<<-', '<>', '>&', '<&', '2>&', '&>&'}
COMMAND_PREFIXES = {'sudo', 'env', 'command', 'exec', 'nohup', 'time'}
OPTIONS_TAKING_A_VALUE = {'-m', '-o', '-g', '-t', '-S', '--mode', '--owner', '--group', '--suffix', '--target-directory'}
HEREDOC_START_RE = re.compile(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")


class CannotJudge(Exception):
    """判不了：不是判红，是这一轮没判成。带着卡在哪与下一步。"""

    def __init__(self, problem, next_step):
        super().__init__(problem)
        self.problem = problem
        self.next_step = next_step


def load_package_module(module_name, file_name):
    # 不写 __pycache__：它会是仓里一个未跟踪的新目录，门禁跑到一半冒出来，「工作区跑的过程中没变」那一项就对不上
    sys.dont_write_bytecode = True
    specification = importlib.util.spec_from_file_location(
        module_name, os.path.join(PACKAGE_SCRIPTS_DIRECTORY, file_name))
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


HOOK_REGISTRATIONS = load_package_module('hook_registrations', 'hook-registrations.py')
# 读会话记录只在 session-transcript.py 一处，收工钩子 handback-scratch-check.sh 调的 handback-scratch.py 也用它
SESSION_TRANSCRIPT = load_package_module('session_transcript', 'session-transcript.py')
tool_uses_in_transcript = SESSION_TRANSCRIPT.tool_uses_in_transcript


def read_lines(path):
    try:
        with open(path, encoding='utf-8', errors='replace') as source_file:
            return source_file.read().splitlines()
    except OSError:
        return []


def is_under(path, directory):
    return path == directory or path.startswith(directory.rstrip('/') + '/')


def top_level_files(directory, suffixes):
    """目录下第一层的文件（跟着符号链接判是不是文件，路径保留链接自己的那一个）。"""
    if not os.path.isdir(directory):
        return []
    real_directory = os.path.realpath(directory)
    found = []
    for name in sorted(os.listdir(real_directory)):
        full_path = os.path.join(real_directory, name)
        if os.path.isfile(full_path) and (suffixes is None or name.endswith(suffixes)):
            found.append(full_path)
    return found


def expand_project_directory(text, project_root):
    return text.replace('${CLAUDE_PROJECT_DIR}', project_root).replace('$CLAUDE_PROJECT_DIR', project_root)


def files_named_in_command(command, project_root):
    """注册命令里指到的文件：展开 $CLAUDE_PROJECT_DIR 之后，逐词看它是不是仓里或本包里的一个文件。"""
    expanded = expand_project_directory(command, project_root)
    try:
        words = shlex.split(expanded)
    except ValueError:
        words = expanded.split()
    found = []
    for word in words:
        candidate = os.path.normpath(word if os.path.isabs(word) else os.path.join(project_root, word))
        if os.path.isfile(candidate) and (is_under(candidate, project_root) or is_under(candidate, PACKAGE_ROOT)):
            found.append(candidate)
    return found


def unique_in_order(paths):
    seen = set()
    ordered = []
    for path in paths:
        if path not in seen:
            seen.add(path)
            ordered.append(path)
    return ordered


class Inventory:
    """已有的门禁、钩子与对照范围。路径是规整过的绝对路径，符号链接不展开；显示时换成相对仓根的写法。"""

    def __init__(self, project_root):
        self.project_root = project_root
        self.package_is_the_project = PACKAGE_ROOT == project_root
        settings_path = os.path.join(project_root, '.claude', 'settings.json')
        self.registrations = []
        if os.path.isfile(settings_path):
            try:
                self.registrations = HOOK_REGISTRATIONS.registered_hooks(settings_path)
            except (OSError, ValueError, AttributeError, TypeError) as error:
                raise CannotJudge(f'{settings_path} 读不了：{error}',
                                  f'先让它是合法的 JSON（python3 -m json.tool {settings_path} 看错在哪），再跑这一道。')
        gate_script_text = '\n'.join(read_lines(os.path.join(PACKAGE_SCRIPTS_DIRECTORY, 'gate.sh')))
        package_stage_names = set(GATE_STAGE_REFERENCE_RE.findall(gate_script_text))
        package_scripts = top_level_files(PACKAGE_SCRIPTS_DIRECTORY, ('.sh', '.py'))
        package_claude_hooks = top_level_files(os.path.join(PACKAGE_SCRIPTS_DIRECTORY, 'claude-hooks'), ('.sh', '.py'))
        self.git_hooks = top_level_files(os.path.join(PACKAGE_SCRIPTS_DIRECTORY, 'githooks'), None)
        project_gate_directory = os.path.join(project_root, '.claude', 'gate.d')
        project_hook_directory = os.path.join(project_root, '.claude', 'hooks')
        registered_hook_files = []
        self.unresolved_commands = []
        for _event_name, _matcher, command in self.registrations:
            named_files = files_named_in_command(command, project_root)
            if named_files:
                registered_hook_files.extend(named_files)
            elif command not in self.unresolved_commands:
                self.unresolved_commands.append(command)
        self.gate_stages = unique_in_order(
            [path for path in package_scripts if os.path.basename(path) in package_stage_names]
            + top_level_files(project_gate_directory, ('.sh',)))
        # .claude/hooks/ 下的 .py 多半是钩子共用的库，不当钩子；真是钩子的 .py 由注册命令指到。
        self.claude_hooks = unique_in_order(
            package_claude_hooks + top_level_files(project_hook_directory, ('.sh',)) + registered_hook_files)
        self.comparison_files = unique_in_order(
            package_scripts + package_claude_hooks + self.git_hooks
            + top_level_files(project_gate_directory, ('.sh', '.py'))
            + top_level_files(project_hook_directory, ('.sh', '.py')) + self.claude_hooks)
        # 本包的 git 钩子只在本包自己的仓里生效（core.hooksPath 指向它），装进项目之后只当对照。
        if not self.package_is_the_project:
            self.git_hooks = []
        self.objects = unique_in_order(self.gate_stages + self.claude_hooks + self.git_hooks)
        # 判的范围：项目自己的两个目录与注册命令指到的文件；本包只在门禁的正是本包时才判。
        self.judged_pathspecs = ['.claude/gate.d', '.claude/hooks']
        for path in registered_hook_files:
            if is_under(path, project_root) and (self.package_is_the_project or not is_under(path, PACKAGE_ROOT)):
                self.judged_pathspecs.append(os.path.relpath(path, project_root))
        if self.package_is_the_project:
            self.judged_pathspecs.append(os.path.relpath(PACKAGE_SCRIPTS_DIRECTORY, project_root))
        self.judged_pathspecs = unique_in_order(self.judged_pathspecs)

    def rule_reference(self):
        return self.display(os.path.join(PACKAGE_ROOT, 'rules', 'sop-first.md')) + RULE_SECTION

    def display(self, path):
        relative = os.path.relpath(path, self.project_root)
        return path if relative.startswith('..') else relative

    def kind_of(self, path):
        if path in self.gate_stages:
            return '门禁'
        if path in self.claude_hooks or path in self.git_hooks:
            return '钩子'
        return '脚本'

    def resolve_object(self, name, excluding):
        """点名的文件名 → 已有的门禁或钩子；认文件名，也认相对仓根的路径尾巴。"""
        for path in self.objects:
            if path == excluding:
                continue
            shown = self.display(path)
            if os.path.basename(path) == name or shown == name or shown.endswith('/' + name):
                return path
        return None

    def resolve_comparison_file(self, name, excluding):
        for path in self.comparison_files:
            if path == excluding:
                continue
            shown = self.display(path)
            if os.path.basename(path) == name or shown == name or shown.endswith('/' + name):
                return path
        return None

    def registered_triggers(self, hook_path):
        hook_file_name = os.path.basename(hook_path)
        return [(event_name, matcher) for event_name, matcher, command in self.registrations
                if HOOK_REGISTRATIONS.command_points_to_hook(command, hook_file_name)]

    def triggers_of_new_hook(self, hook_path):
        """新钩子可能还没注册：注册了的按注册算，hook-events 里声明了、还没注册的事件，matcher 当全匹配。
        已有的钩子只按注册算——没注册的本来就不生效，谈不上和谁挂在一起。"""
        registered = self.registered_triggers(hook_path)
        registered_events = {event_name for event_name, _matcher in registered}
        declared = [(event_name, matcher) for event_name, matcher in declared_hook_events(hook_path) if event_name not in registered_events]
        return registered + declared


def declared_hook_events(path):
    """文件头 # hook-events: 里的（事件, matcher）；写成 <事件>:<工具名> 的 matcher 就是那个工具名，只写事件的是空（全匹配）。"""
    for line in read_lines(path)[:60]:
        match = HOOK_EVENTS_RE.match(line)
        if match:
            return [tuple(token.partition(':')[::2]) for token in match.group(1).split()]
    return []


def description_of(path):
    lines = read_lines(path)[:40]
    for line in lines:
        stage_name = re.match(r'^\s*#\s*gate-stage:\s*(.+)$', line)
        if stage_name:
            return stage_name.group(1).strip()
    for line in lines:
        stripped = line.strip()
        if stripped.startswith('#!'):
            continue
        if stripped.startswith('"""'):
            text = stripped.strip('"').strip()
        elif stripped.startswith('#'):
            text = stripped.lstrip('#').strip()
        else:
            continue
        if text and not MACHINE_DIRECTIVE_RE.match(text):
            return text[:70]
    return ''


def run_git(project_root, *arguments):
    return subprocess.run(['git', '-C', project_root, '-c', 'core.quotepath=off', *arguments],
                          capture_output=True, text=True, encoding='utf-8', errors='replace')


def matchers_overlap(first_matcher, second_matcher):
    """两个 matcher 认不认同一个工具名。空与 `*` 什么都认；按 `|` 拆开之后，字面对字面比相等，
    正则对字面拿正则去整串匹配字面，正则对正则分不出来，当成有交集。"""
    if first_matcher in ('', '*') or second_matcher in ('', '*'):
        return True
    for first_alternative in first_matcher.split('|'):
        for second_alternative in second_matcher.split('|'):
            first_is_literal = re.fullmatch(r'[A-Za-z0-9_]+', first_alternative) is not None
            second_is_literal = re.fullmatch(r'[A-Za-z0-9_]+', second_alternative) is not None
            if first_is_literal and second_is_literal:
                if first_alternative == second_alternative:
                    return True
                continue
            if first_is_literal or second_is_literal:
                pattern, literal = (second_alternative, first_alternative) if first_is_literal else (first_alternative, second_alternative)
                try:
                    if re.fullmatch(pattern, literal):
                        return True
                except re.error:
                    return True
                continue
            return True
    return False


def triggers_overlap(first_triggers, second_triggers):
    for first_event, first_matcher in first_triggers:
        for second_event, second_matcher in second_triggers:
            if first_event == second_event and matchers_overlap(first_matcher, second_matcher):
                return True
    return False


def normalized_lines(path):
    informative = []
    for line_number, line in enumerate(read_lines(path), 1):
        stripped = ' '.join(line.split())
        if not stripped or stripped.startswith('#'):
            continue
        if len(stripped) < MINIMUM_INFORMATIVE_LINE_LENGTH or INFORMATIONLESS_LINE_RE.match(stripped):
            continue
        informative.append((line_number, stripped))
    return informative


def identifier_set(path):
    return set(IDENTIFIER_RE.findall('\n'.join(read_lines(path))))


def similarity_ranking(inventory, new_path):
    """已有的门禁与钩子按标识符重合从高到低：[(重合度, 路径, 两边是不是都够多标识符)]。"""
    new_identifiers = identifier_set(new_path)
    scored = []
    for path in inventory.objects:
        if path == new_path:
            continue
        other_identifiers = identifier_set(path)
        union = new_identifiers | other_identifiers
        if union:
            enough = min(len(new_identifiers), len(other_identifiers)) >= MINIMUM_IDENTIFIERS_FOR_SIMILARITY
            scored.append((len(new_identifiers & other_identifiers) / len(union), path, enough))
    scored.sort(key=lambda entry: (-entry[0], entry[1]))
    return scored


def resolve_diff_base(project_root):
    """门禁阶段的窗口起点。解析不到一个提交时退到空树：空仓里 diff_base 给的是 HEAD，那里一切都是新加的。"""
    base = os.environ.get('GATE_DIFF_BASE', '')
    base_given_by_gate = bool(base)
    if not base:
        completed = subprocess.run(['bash', '-c', 'source "$1" && diff_base "$2"', '_',
                                    os.path.join(PACKAGE_SCRIPTS_DIRECTORY, 'lib.sh'), project_root],
                                   capture_output=True, text=True, encoding='utf-8', errors='replace')
        if completed.returncode != 0:
            raise CannotJudge('算不出这一次改动的 diff 基准：' + completed.stderr.strip(),
                              '按上面 lib.sh 的出路修；GATE_BASE 写错了就改成真实存在的提交，或者不设它。')
        base = completed.stdout.strip()
    if run_git(project_root, 'rev-parse', '--verify', '-q', base + '^{commit}').returncode == 0:
        return base
    if base == 'HEAD':
        return EMPTY_TREE
    if base_given_by_gate:
        raise CannotJudge(f'GATE_DIFF_BASE={base} 在 {project_root} 里解析不到提交',
                          '它是 gate.sh 按这个仓算好导出的，解析不到多半是外层仓的值漏进了这里。'
                          '单跑时不设它（env -u GATE_DIFF_BASE），让脚本按这个仓自己算。')
    return EMPTY_TREE


def session_start_base(project_root, transcript_path):
    """收工钩子的窗口起点：会话开始之前的最后一个提交。会话记录按时间顺序写，第一条带时间戳的就是开始的时刻；
    一条都没有就退回门禁阶段那套算法。"""
    session_started_at = SESSION_TRANSCRIPT.first_timestamp(transcript_path)
    if session_started_at is None:
        return resolve_diff_base(project_root)
    completed = run_git(project_root, 'rev-list', '-1', '--before=' + session_started_at, 'HEAD')
    commit = completed.stdout.strip()
    return commit if completed.returncode == 0 and commit else EMPTY_TREE


def changed_lines_by_path(project_root, base, pathspecs):
    """相对 base 各文件加进来的行号（相对仓根的路径 → 行号集合），以及新加的文件。"""
    added_lines = {}
    diff_text = run_git(project_root, 'diff', '--relative', '--no-color', '--no-ext-diff', '-M', '-U0',
                        base, '--', *pathspecs).stdout
    current_path = None
    for line in diff_text.splitlines():
        if line.startswith('+++ '):
            target = line[4:]
            current_path = None if target == '/dev/null' else (target[2:] if target.startswith('b/') else target)
            if current_path is not None:
                added_lines.setdefault(current_path, set())
            continue
        hunk = re.match(r'^@@ -\S+ \+(\d+)(?:,(\d+))? @@', line)
        if hunk and current_path is not None:
            start = int(hunk.group(1))
            count = int(hunk.group(2)) if hunk.group(2) is not None else 1
            added_lines[current_path].update(range(start, start + count))
    new_paths = set(run_git(project_root, 'diff', '--relative', '--name-only', '--diff-filter=A', '-M',
                            base, '--', *pathspecs).stdout.splitlines())
    for untracked_path in run_git(project_root, 'ls-files', '--others', '--exclude-standard', '--',
                                  *pathspecs).stdout.splitlines():
        new_paths.add(untracked_path)
        line_count = len(read_lines(os.path.join(project_root, untracked_path)))
        added_lines[untracked_path] = set(range(1, line_count + 1))
    return added_lines, new_paths


def shell_words(line):
    lexer = shlex.shlex(line, posix=True, punctuation_chars=';&|()<>')
    lexer.whitespace_split = True
    return list(lexer)


def split_segments(words):
    segments = [[]]
    for word in words:
        if word in SHELL_SEPARATORS:
            segments.append([])
        else:
            segments[-1].append(word)
    return [segment for segment in segments if segment]


def bash_write_targets(command, project_root):
    """一条 Bash 命令往哪些路径写：重定向的目标、tee / touch 的参数、cp / mv / install / ln / git mv 的目标、sed -i 的文件。

    只认命令文本里写明的目标：cd 跟着走（只在这一条命令里），heredoc 的正文跳过。
    拼在变量里的路径、解释器里写的文件都认不出，那一半由门禁阶段兜底。
    """
    targets = set()
    directory = project_root

    def resolve(word):
        expanded = os.path.expanduser(expand_project_directory(word, project_root))
        return os.path.normpath(expanded if os.path.isabs(expanded) else os.path.join(directory, expanded))

    heredoc_delimiter = None
    for line in command.split('\n'):
        if heredoc_delimiter is not None:
            if line.strip() == heredoc_delimiter:
                heredoc_delimiter = None
            continue
        heredoc_start = HEREDOC_START_RE.search(line)
        try:
            words = shell_words(line)
        except ValueError:
            for target in re.findall(r'(?<![0-9&<>])>>?\s*([^\s;&|<>]+)', line):
                targets.add(resolve(target))
            words = []
        for segment in split_segments(words):
            arguments = []
            position = 0
            while position < len(segment):
                word = segment[position]
                following = segment[position + 1] if position + 1 < len(segment) else None
                if word in OUTPUT_REDIRECTIONS:
                    if following is not None:
                        targets.add(resolve(following))
                    position += 2
                    continue
                if word in OTHER_REDIRECTIONS:
                    position += 2
                    continue
                if word.isdigit() and following in OUTPUT_REDIRECTIONS | OTHER_REDIRECTIONS:
                    position += 1
                    continue
                arguments.append(word)
                position += 1
            while arguments and (re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*=.*', arguments[0]) or arguments[0] in COMMAND_PREFIXES):
                arguments = arguments[1:]
            if not arguments:
                continue
            command_name = os.path.basename(arguments[0])
            rest = arguments[1:]
            if command_name == 'git' and rest[:1] == ['mv']:
                command_name, rest = 'mv', rest[1:]
            operands = []
            options = []
            skip_next = False
            for word in rest:
                if skip_next:
                    options.append(word)
                    skip_next = False
                elif word.startswith('-') and word != '-':
                    options.append(word)
                    skip_next = word in OPTIONS_TAKING_A_VALUE
                else:
                    operands.append(word)
            if command_name == 'cd':
                directory = resolve(operands[0]) if operands else project_root
            elif command_name in ('tee', 'touch'):
                targets.update(resolve(operand) for operand in operands)
            elif command_name in ('cp', 'mv', 'install', 'ln') and len(operands) >= 2:
                destination_word = operands[-1]
                destination = resolve(destination_word)
                if destination_word.endswith('/') or os.path.isdir(destination):
                    targets.update(os.path.join(destination, os.path.basename(source)) for source in operands[:-1])
                else:
                    targets.add(destination)
            elif command_name == 'sed' and any(option.startswith('-i') or option.startswith('--in-place') for option in options):
                has_script_option = any(option in ('-e', '-f') or option.startswith('--expression') for option in options)
                targets.update(resolve(operand) for operand in (operands if has_script_option else operands[1:]))
        if heredoc_start:
            heredoc_delimiter = heredoc_start.group(2)
    return targets


def paths_written_in_transcript(inventory, transcript_path):
    """这份会话记录写过哪些路径（规整过的绝对路径）。"""
    written = set()
    for tool_name, tool_input in tool_uses_in_transcript(transcript_path):
        if tool_name in WRITING_TOOL_NAMES:
            target = tool_input.get('file_path') or tool_input.get('notebook_path')
            if isinstance(target, str) and target:
                written.add(os.path.normpath(os.path.join(inventory.project_root, target)))
        elif tool_name == 'Bash' and isinstance(tool_input.get('command'), str):
            written |= bash_write_targets(tool_input['command'], inventory.project_root)
    return written


def similar_declarations(path):
    declarations = []
    for line_number, line in enumerate(read_lines(path), 1):
        match = SIMILAR_DECLARATION_RE.match(line)
        if match:
            declarations.append((line_number, match.group(1), match.group(2)))
    return declarations


def copy_kept_declarations(path):
    kept = []
    for line_number, line in enumerate(read_lines(path), 1):
        match = COPY_KEPT_RE.match(line)
        if match:
            kept.append((line_number, match.group(1), match.group(2)))
    return kept


def trigger_text(inventory, hook_path):
    return '、'.join(f'{event_name}[{matcher or "*"}]' for event_name, matcher in inventory.registered_triggers(hook_path)) or '没注册'


def list_inventory(inventory):
    for path in inventory.objects:
        triggers = ''
        if path in inventory.claude_hooks:
            triggers = trigger_text(inventory, path)
        elif path in inventory.git_hooks:
            triggers = 'git ' + os.path.basename(path)
        print(f'{inventory.kind_of(path)}\t{inventory.display(path)}\t{triggers}\t{description_of(path)}')
    print(f'共 {len(inventory.objects)} 份：门禁 {len(inventory.gate_stages)}、'
          f'钩子 {len(inventory.claude_hooks) + len(inventory.git_hooks)}')
    for command in inventory.unresolved_commands:
        print(f'注册命令指不到文件（内联命令）：{command}')


def judge_new_object(inventory, new_path):
    """① ② 对一份新加的门禁或钩子。返回要打印的拒绝（各是一组行），没有就是空列表。"""
    shown = inventory.display(new_path)
    rejections = []
    declarations = similar_declarations(new_path)
    named_paths = set()
    declaration_problems = []
    for line_number, name, reason in declarations:
        if len(reason) < MINIMUM_REASON_CHARACTERS:
            declaration_problems.append(f'第 {line_number} 行点了「{name}」，理由不到 {MINIMUM_REASON_CHARACTERS} 个字：「{reason}」')
        if name == '无':
            continue
        resolved = inventory.resolve_object(name, excluding=new_path)
        if resolved is None:
            declaration_problems.append(f'第 {line_number} 行点名的「{name}」不是已有的门禁或钩子')
        else:
            named_paths.add(resolved)
    ranking = similarity_ranking(inventory, new_path)
    is_claude_hook = new_path in inventory.claude_hooks
    required = []
    if is_claude_hook:
        new_triggers = inventory.triggers_of_new_hook(new_path)
        for other_hook in inventory.claude_hooks:
            if other_hook != new_path and triggers_overlap(new_triggers, inventory.registered_triggers(other_hook)):
                required.append((other_hook, '挂在同一个触发点上：' + trigger_text(inventory, other_hook)))
    for score, other_path, enough in ranking:
        if enough and score >= SIMILARITY_REQUIRING_NAMING and other_path not in [path for path, _why in required]:
            required.append((other_path, f'字面上很像：标识符重合 {score:.2f}'))
    unnamed = [(path, why) for path, why in required if path not in named_paths]
    if not declarations:
        rejections.append([
            f'  ✗ {inventory.kind_of(new_path)} {shown} 是新加的，没写 gate-similar：看不出加之前对过哪些已有的',
            '     → 怎么办：先看已有的有没有管同一件事的——能追加就写进那一份，能合并就合并，不另起一份。',
            f'               全表： python3 {inventory.display(os.path.join(PACKAGE_SCRIPTS_DIRECTORY, THIS_SCRIPT_FILE_NAME))} --list',
            '               按字面最像的几份：' + '、'.join(f'{inventory.display(path)}（{score:.2f}）' for score, path, _enough in ranking[:3]),
            '               确实要另起一份，在文件里逐个写： # gate-similar: <已有的文件名> <为什么不并进它>',
            f'               一个像的都没有写： # gate-similar: 无 <查过哪些>（{inventory.rule_reference()}）',
        ])
    if declaration_problems:
        rejections.append(
            [f'  ✗ {shown} 的 gate-similar 有 {len(declaration_problems)} 处写得不对：']  # gate-lint:summary
            + [f'       {problem}' for problem in declaration_problems]
            + ['     → 怎么办：点名写已有门禁或钩子的文件名（--list 列出来的那一列），名字后面跟为什么不并进它，'
               f'理由至少 {MINIMUM_REASON_CHARACTERS} 个字。'])
    if unnamed:
        rejections.append(
            [f'  ✗ {shown} 与这几份已有的最可能是一回事，却没点名它们：']  # gate-lint:summary
            + [f'       {inventory.display(path)}  {why}  {description_of(path)}' for path, why in unnamed]
            + ['     → 怎么办：先看新判据能不能并进其中一份。确实要分开，逐个写 # gate-similar: <那份的文件名> <为什么不并进它>；写「无」不算。'])
    if is_claude_hook and not declared_hook_events(new_path):
        rejections.append([
            f'  ✗ 钩子 {shown} 是新加的，没写 hook-events：看不出它要挂在哪几个事件上',
            '     → 怎么办：在文件头写 # hook-events: <事件> …（例如 PreToolUse、Stop SubagentStop），'
            '每个事件都在 .claude/settings.json 里注册一次；「工具层的闸」按它核挂全没有。',
        ])
    return rejections


def find_copies(inventory, added_lines):
    """③ 加进来的行与别的文件整段相同。返回（copy-kept 写错的、整段相同的、按 copy-kept 放行的对）。"""
    normalized = {path: normalized_lines(path) for path in inventory.comparison_files}
    windows = {}
    for path, lines in normalized.items():
        for position in range(len(lines) - CLONE_MINIMUM_LINES + 1):
            key = tuple(text for _line_number, text in lines[position:position + CLONE_MINIMUM_LINES])
            windows.setdefault(key, []).append((path, position))
    kept_pairs = set()
    kept_problems = []
    for path in inventory.comparison_files:
        for line_number, name, reason in copy_kept_declarations(path):
            resolved = inventory.resolve_comparison_file(name, excluding=path)
            if path in added_lines and (resolved is None or len(reason) < MINIMUM_REASON_CHARACTERS):
                problem = (f'点名的「{name}」不是已有的门禁、钩子或共享脚本' if resolved is None
                           else f'理由不到 {MINIMUM_REASON_CHARACTERS} 个字')
                kept_problems.append(f'{inventory.display(path)} 第 {line_number} 行：{problem}')
                continue
            if resolved is not None:
                kept_pairs.add(frozenset((path, resolved)))
    kept_pairs_used = set()
    matched_positions = {}
    for path, line_numbers in added_lines.items():
        lines = normalized.get(path, [])
        for position in range(len(lines) - CLONE_MINIMUM_LINES + 1):
            window = lines[position:position + CLONE_MINIMUM_LINES]
            if not any(line_number in line_numbers for line_number, _text in window):
                continue
            key = tuple(text for _line_number, text in window)
            first_position_by_other = {}
            for other_path, other_position in windows.get(key, []):
                if other_path != path and other_path not in first_position_by_other:
                    first_position_by_other[other_path] = other_position
            for other_path, other_position in first_position_by_other.items():
                pair = frozenset((path, other_path))
                if pair in kept_pairs:
                    kept_pairs_used.add(pair)
                    continue
                matched_positions.setdefault((path, other_path), []).append((position, other_position))
    # 两份都改过时，同一对会从两侧各匹配一次：从只改了几行的那一侧看只有那几行，从新加的那一侧看才是整段。
    # 每一对只报一侧，取匹配到的窗口多的那一侧。
    chosen_direction = {}
    for (path, other_path), positions in matched_positions.items():
        pair = frozenset((path, other_path))
        if pair not in chosen_direction or len(positions) > len(matched_positions[chosen_direction[pair]]):
            chosen_direction[pair] = (path, other_path)
    copies = []
    for path, other_path in sorted(chosen_direction.values()):
        runs = []
        run_start = previous = None
        for position, other_position in sorted(matched_positions[(path, other_path)]):
            if previous is not None and position == previous[0] + 1:
                previous = (position, other_position)
                continue
            if run_start is not None:
                runs.append((run_start, previous))
            run_start = previous = (position, other_position)
        runs.append((run_start, previous))
        lines = normalized[path]
        other_lines = normalized[other_path]
        for (first_position, first_other_position), (last_position, _last_other_position) in runs:
            copies.append(f'{inventory.display(path)}:{lines[first_position][0]}-{lines[last_position + CLONE_MINIMUM_LINES - 1][0]}'
                          f' 与 {inventory.display(other_path)}:{other_lines[first_other_position][0]} 起'
                          f'（连续 {last_position - first_position + CLONE_MINIMUM_LINES} 行相同）')
    return kept_problems, copies, kept_pairs_used


def judge(inventory, transcript_path=None):
    project_root = inventory.project_root
    if run_git(project_root, 'rev-parse', '--git-dir').returncode != 0:
        print(f'  ! {project_root} 不在 git 仓里，分不出哪些是新加的——本阶段无对象可判（这不是通过）')
        return EXIT_NOTHING_TO_JUDGE
    base = session_start_base(project_root, transcript_path) if transcript_path else resolve_diff_base(project_root)
    added_lines_relative, new_paths_relative = changed_lines_by_path(project_root, base, inventory.judged_pathspecs)
    comparison_set = set(inventory.comparison_files)
    added_lines = {}
    for relative_path, line_numbers in added_lines_relative.items():
        full_path = os.path.normpath(os.path.join(project_root, relative_path))
        if full_path in comparison_set and line_numbers:
            added_lines[full_path] = line_numbers
    new_objects = [path for path in inventory.objects if os.path.relpath(path, project_root) in new_paths_relative]
    left_to_other_sessions = []
    if transcript_path:
        # 收工钩子只判这个会话自己写过的：别的会话同一段时间里加的，归它们自己收工时判。
        written = paths_written_in_transcript(inventory, transcript_path)
        left_to_other_sessions = [path for path in new_objects if path not in written]
        added_lines = {path: line_numbers for path, line_numbers in added_lines.items() if path in written}
        new_objects = [path for path in new_objects if path in written]
    if not added_lines and not new_objects:
        scope = '这个会话' if transcript_path else f'相对 {base[:12]}，这一次'
        print(f'  ! {scope}没有新加或改动门禁与钩子——无对象可判（这不是通过）')
        return EXIT_NOTHING_TO_JUDGE

    rejections = []
    for new_path in new_objects:
        rejections.extend(judge_new_object(inventory, new_path))
    kept_problems, copies, kept_pairs_used = find_copies(inventory, added_lines)
    if kept_problems:
        rejections.append(
            [f'  ✗ gate-overlap:copy-kept 有 {len(kept_problems)} 处写得不对：']  # gate-lint:summary
            + [f'       {problem}' for problem in kept_problems]
            + ['     → 怎么办：写成 # gate-overlap:copy-kept <另一份的文件名> <为什么不抽成共用>，文件要真的存在，'
               f'理由至少 {MINIMUM_REASON_CHARACTERS} 个字。'])
    if copies:
        rejections.append(
            [f'  ✗ 加进来的行里有 {len(copies)} 段与别的门禁、钩子或共享脚本整段相同：']  # gate-lint:summary
            + [f'       {copy}' for copy in copies]
            + ['     → 怎么办：两份要做的是同一件事，就把新判据并进已有的那一份；',
               '               只是共用一段逻辑，抽成共用的库（本包的 lib.sh、项目 .claude/gate.d/ 下的 lib-*.py 这类），两边都调它。',
               '               确实要留两份，在其中一份里写 # gate-overlap:copy-kept <另一份的文件名> <为什么不抽成共用>。'])
    for rejection in rejections:
        print('\n'.join(rejection))
    if rejections:
        return EXIT_RED

    new_object_names = '、'.join(inventory.display(path) for path in new_objects) or '无'
    print(f'  ✓ 相对 {base[:12]}：新加的门禁与钩子 {len(new_objects)} 个（{new_object_names}）都写明了比过谁，'
          f'改过的 {len(added_lines)} 份脚本对照已有的 {len(inventory.comparison_files)} 份没有整段相同')
    if kept_pairs_used:
        print('    按 copy-kept 留着两份的：' + '、'.join(
            ' 与 '.join(sorted(inventory.display(path) for path in pair)) for pair in sorted(kept_pairs_used, key=sorted)))
    if not inventory.package_is_the_project:
        package_count = sum(1 for path in inventory.comparison_files if is_under(path, PACKAGE_ROOT))
        print(f'    没判的：装进来的 SOP 副本 {package_count} 份只当对照（{inventory.display(PACKAGE_SCRIPTS_DIRECTORY)}）')
    if left_to_other_sessions:
        print('    没判的：新加了、但不是这个会话写的：' + '、'.join(inventory.display(path) for path in left_to_other_sessions))
    for command in inventory.unresolved_commands:
        print(f'    没判的：注册命令指不到文件（内联命令）：{command}')
    return EXIT_PASSED


def main():
    arguments = sys.argv[1:]
    list_only = False
    transcript_path = None
    if arguments[:1] == ['--list']:
        list_only = True
        arguments = arguments[1:]
    elif arguments[:1] == ['--touched-by']:
        if len(arguments) < 2:
            print('  ✗ --touched-by 后面要跟会话记录的路径')
            print('     → 怎么办：用法 gate-overlap.py --touched-by <会话记录.jsonl> [仓根]')
            return EXIT_USAGE
        transcript_path = arguments[1]
        arguments = arguments[2:]
    if len(arguments) > 1:
        print(f'  ✗ 只收一个仓根，收到 {len(arguments)} 个：{" ".join(arguments)}')
        print('     → 怎么办：用法 gate-overlap.py [--list | --touched-by <会话记录>] [仓根]')
        return EXIT_USAGE
    project_root = os.path.realpath(arguments[0] if arguments else '.')
    if not os.path.isdir(project_root):
        print(f'  ✗ 找不到仓根：{project_root}')
        print('     → 怎么办：在仓根跑，或者把仓根作为参数传进来。')
        return EXIT_USAGE
    inventory = Inventory(project_root)
    if list_only:
        list_inventory(inventory)
        return EXIT_PASSED
    return judge(inventory, transcript_path)


if __name__ == '__main__':
    try:
        sys.exit(main())
    except CannotJudge as error:
        print(f'  ✗ 门禁查重判不了：{error.problem}')
        print(f'     → 怎么办：{error.next_step}')
        sys.exit(EXIT_CANNOT_JUDGE)
    except Exception:  # noqa: BLE001 —— 脚本自己出错与「判红」分开报，收工钩子据此不拦
        traceback.print_exc(file=sys.stdout)
        print('  ✗ 门禁查重自己出错了（上面是调用栈），这一轮没判')
        print(f'     → 怎么办：这是 {THIS_SCRIPT_FILE_NAME} 的缺陷，按调用栈修它；修好之前这一道不算通过。')
        sys.exit(EXIT_CANNOT_JUDGE)
