#!/usr/bin/env python3
"""子 agent 交回之前，它自己建的编译目录与仓副本还在不在（rules/session-wrapup.md「子 agent 交回之前，删掉自己建的编译目录与仓副本」）。

钩子 claude-hooks/handback-scratch-check.sh 在交回工具（SubagentHandback）的 PreToolUse 与 SubagentStop 上调它。

判的对象，三样都满足才算：
  ① 编译目录（带 CACHEDIR.TAG 的目录：cargo 的 target 与 CARGO_TARGET_DIR 指的目录都带，别的工具按 https://bford.info/cachedir/ 打了这个标记的缓存也算）、
     工作树（.git 是文件：git worktree add 建的）、仓副本（.git 是目录：clone、连 .git 一起拷的仓；
     或者不带 .git 拷出来、在里面编过的——直接含着名为 target 的编译目录）；
  ② 在临时目录里（/tmp、/var/tmp、/dev/shm、$TMPDIR 之下），不在项目根之内——项目自己的 target 与 Claude Code 建在项目里的 worktree 归主 agent 管；
  ③ 在这个子 agent 自己的某次工具调用还没结束时建的：目录的创建时间（statx 的 btime）落在那次调用的时间窗里
     （发起那条记录到结果那条记录；后台跑的到它自己的完成通知，没有通知的到它之后第一次送达的交回，都没有的到现在；两头各放 WINDOW_SLACK_SECONDS）。
     派子 agent 的调用（DISPATCH_TOOL_NAMES）不开时间窗：派出去的那个建的归它自己的 SubagentStop。
     开工之前就在的、它两次调用之间别人建的，都不算它的。
认哪些是它的：它的工具调用里提到过那个目录本身，或那个目录里面的路径；它自己建的目录（③）被提到过，它下一级的也算。
  「提到」：工具输入里的绝对路径（写进文件的内容与说明文字不算，那是在说它、不是在那里干活）；
  Bash 命令里的每个词（NAME=值、--选项=值 取值那一半）跟着同一条命令里的 cd、pushd 走、按当时的目录解析，-C <目录> 管它那一段；
  喂给解释器的 heredoc（python3 - <<EOF 这类）正文里的绝对路径；命令里有 mktemp 时，它的输出里的绝对路径。磁盘上现在还在的才算。
  临时目录本身、它下面的 claude-<uid>、Claude Code 按项目与会话分的那几层（含 scratchpad）是大家共用的，不当「下一级也算」的上级。
认不出的：路径只在变量里、脚本内部建了而调用里没提到的、不带 .git 也没在里面编过的源码副本、调用返回之后才由脱离出去的进程建的。
说明过为什么不删的不再报：它建好之后，下面几处有一行同时写了它的全路径（后面可以跟 / 或汉字，不能再接路径）与 EXPLANATION_KEYWORDS 里的一个词——
  送达了的交回（结果不是错误；--pending-handback 时还有这一次要交回的那份）；
  --explained-after 那个时刻之后回复里的文字与工具调用的输入（Bash 用 heredoc 写的报告也算；只 du、ls、Read 一下的那几行没有说明词，本来就不算）。
  只写了路径、当出处引的不算：「在副本 …/repo 上跑的」说的不是它为什么还在。

用法：handback-scratch.py <子 agent 的会话记录> <项目根> [--explained-after <epoch 秒>] [--pending-handback]
  --pending-handback：从 stdin 读 PreToolUse 钩子的 JSON，它的 tool_input 就是这一次要交回的报告。
输出：还在的每一个一行「<种类>\\t<路径>」，按路径排序；同一棵树里只报最外层那个。
退出码：0 一个都不剩；1 还有；2 参数不对；3 判不了（会话记录读不了、认不出工具调用、有候选取不到创建时间、脚本自己出错）。
"""
import importlib.util
import json
import os
import re
import subprocess
import sys
import time
import traceback

PACKAGE_SCRIPTS_DIRECTORY = os.path.dirname(os.path.realpath(__file__))

EXIT_NONE_LEFT = 0
EXIT_SOME_LEFT = 1
EXIT_USAGE = 2
EXIT_CANNOT_JUDGE = 3

CACHE_DIRECTORY_TAG_SIGNATURE = 'Signature: 8a477f597d28d172789f06886806bc55'
KIND_BUILD_DIRECTORY = '编译目录'
KIND_WORKTREE = '工作树'
KIND_REPOSITORY_COPY = '仓副本'
# 实测：目录建在调用发起之后 1.8～2.5 秒、结果那条记录之前 26 毫秒以上；两头各放一点，抵文件系统时间戳的粒度
WINDOW_SLACK_SECONDS = 0.25

# 工具输入里的绝对路径：行首或空白、引号、等号、冒号、括号、逗号之后，以 / 或 ~/ 开头
ABSOLUTE_PATH_RE = re.compile(r"""(?:^|(?<=[\s=:'"(`,]))(~?/[^\s'"`;|&<>(),*?]+)""", re.MULTILINE)
# Bash 命令按这些切成一段一段的简单命令；cd 的效果只在同一条命令里往后传
COMMAND_SEPARATOR_RE = re.compile(r'&&|\|\||[;|&\n()]')
SHELL_WORD_RE = re.compile(r"""[^\s'"`<>]+""")
HEREDOC_START_RE = re.compile(r"""<<-?\s*(['"]?)([A-Za-z_][A-Za-z0-9_]*)\1""")
DIRECTORY_CHANGING_COMMANDS = {'cd', 'pushd'}
# heredoc 喂给这些，正文就是要执行的程序，不是写进文件的内容
INTERPRETER_NAMES = {'python', 'python3', 'bash', 'sh', 'zsh', 'perl', 'ruby', 'node'}
# 交回用的工具：它的输入就是交回的报告
HANDBACK_TOOL_NAMES = {'SubagentHandback'}
# 派子 agent 的工具：派出去的那个自己有 SubagentStop，它建的归它
DISPATCH_TOOL_NAMES = {'Agent', 'Task'}
# 说明「为什么还在」的那一行里要有的词（三种语言的仓共用这一份脚本，三种都认；英文不分大小写）
EXPLANATION_KEYWORDS = ('没删', '未删', '不删', '保留', '留着', '留给', '留下', '不是我建', '不是这个子 agent 建',
                        'not deleted', 'not removed', 'kept', 'keep', 'not mine', '残し', '削除していない', '削除しない', '作っていない')
# 这些字段装的是写进文件的内容或给人看的话，里面的路径是在「说」它，不是在那里干活
CONTENT_FIELD_NAMES = {'content', 'old_string', 'new_string', 'new_source', 'edits', 'description', 'prompt', 'message'}


def load_package_module(module_name, file_name):
    # 不写 __pycache__：它会是仓里一个未跟踪的新目录
    sys.dont_write_bytecode = True
    specification = importlib.util.spec_from_file_location(
        module_name, os.path.join(PACKAGE_SCRIPTS_DIRECTORY, file_name))
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


SESSION_TRANSCRIPT = load_package_module('session_transcript', 'session-transcript.py')


def is_under(path, directory):
    return path == directory or path.startswith(directory.rstrip('/') + '/')


def is_strictly_under(path, directory):
    return path != directory and is_under(path, directory)


def resolve_word(word, directory):
    """一个词当路径解析成规整过的绝对路径；不像路径的（空、选项、带没展开的变量）返回 None。"""
    if not word or word.startswith('-') or '$' in word:
        return None
    if word.startswith('~'):
        word = os.path.expanduser(word)
    if not os.path.isabs(word):
        word = os.path.join(directory, word)
    try:
        return os.path.realpath(word)
    except ValueError:  # 编不成文件名的字符（孤立的代理字符这类）：不是路径
        return None


def existing_absolute_paths(text, directory):
    found = set()
    for match in ABSOLUTE_PATH_RE.findall(text):
        path = resolve_word(match, directory)
        if path is not None and os.path.lexists(path):
            found.add(path)
    return found


def split_heredocs(command):
    """（去掉 heredoc 正文的命令, 喂给解释器的那些 heredoc 正文）。写进文件的 heredoc（cat > 文件 <<EOF）正文两边都不要。"""
    kept_lines = []
    interpreter_bodies = []
    heredoc_delimiter = None
    feeds_interpreter = False
    for line in command.split('\n'):
        if heredoc_delimiter is not None:
            if line.strip() == heredoc_delimiter:
                heredoc_delimiter = None
            elif feeds_interpreter:
                interpreter_bodies.append(line)
            continue
        kept_lines.append(line)
        heredoc_start = HEREDOC_START_RE.search(line)
        if heredoc_start:
            heredoc_delimiter = heredoc_start.group(2)
            segment_before = COMMAND_SEPARATOR_RE.split(line[:heredoc_start.start()])[-1]
            words_before = SHELL_WORD_RE.findall(segment_before)
            feeds_interpreter = bool(words_before) and os.path.basename(words_before[0]) in INTERPRETER_NAMES
    return '\n'.join(kept_lines), '\n'.join(interpreter_bodies)


def paths_in_bash_command(command, start_directory):
    """一条 Bash 命令里提到的、磁盘上还在的路径。cd、pushd 跟着走（只在这一条命令里），-C <目录> 管它那一段。"""
    mentioned = set()
    directory = start_directory
    for segment in COMMAND_SEPARATOR_RE.split(command):
        words = SHELL_WORD_RE.findall(segment)
        if not words:
            continue
        if words[0] in DIRECTORY_CHANGING_COMMANDS:
            directory = (resolve_word(words[1], directory) if len(words) > 1 else None) or start_directory
        segment_directory = directory
        for position, word in enumerate(words):
            if position > 0 and words[position - 1] == '-C':
                segment_directory = resolve_word(word, directory) or directory
            for piece in word.split('='):
                path = resolve_word(piece, segment_directory)
                if path is not None and os.path.lexists(path):
                    mentioned.add(path)
    return mentioned


def strings_in(value, skipped_field_names):
    """输入里的每个字符串；skipped_field_names 里的字段不算。"""
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for field_name, inner in value.items():
            if field_name not in skipped_field_names:
                yield from strings_in(inner, skipped_field_names)
    elif isinstance(value, list):
        for inner in value:
            yield from strings_in(inner, skipped_field_names)


def paths_mentioned_in_calls(calls, project_root):
    mentioned = set()
    for call in calls:
        if call['name'] == 'Bash' and isinstance(call['input'].get('command'), str):
            command, interpreter_bodies = split_heredocs(call['input']['command'])
            mentioned |= paths_in_bash_command(command, project_root)
            mentioned |= existing_absolute_paths(command, project_root)
            mentioned |= existing_absolute_paths(interpreter_bodies, project_root)
            # mktemp 建的目录多半只在变量里，它的路径要从输出里取
            if 'mktemp' in command:
                mentioned |= existing_absolute_paths(call['result_text'], project_root)
        else:
            for text in strings_in(call['input'], CONTENT_FIELD_NAMES):
                mentioned |= existing_absolute_paths(text, project_root)
    return mentioned


def scratch_roots():
    """临时目录的根：只有它们下面的目录才判。"""
    roots = []
    for candidate in ('/tmp', '/var/tmp', '/dev/shm', os.environ.get('TMPDIR') or ''):
        if candidate and os.path.isdir(candidate):
            real_candidate = os.path.realpath(candidate)
            if real_candidate not in roots:
                roots.append(real_candidate)
    return roots


def is_shared_directory(path, roots):
    """大家共用的目录：临时目录的根；它下面 Claude Code 的 claude-<uid>；claude-<uid> 下按项目（-开头）、按会话分的两层，以及会话下的 scratchpad。"""
    for root in roots:
        claude_directory = os.path.join(root, f'claude-{os.getuid()}')
        if path in (root, claude_directory):
            return True
        if is_strictly_under(path, claude_directory):
            parts = os.path.relpath(path, claude_directory).split(os.sep)
            if parts[0].startswith('-') and (len(parts) <= 2 or (len(parts) == 3 and parts[2] == 'scratchpad')):
                return True
    return False


def is_build_directory(path):
    """带 CACHEDIR.TAG（签名对得上）的目录。符号链接不跟：链过去的那一份不是在这里建的。"""
    if os.path.islink(path) or not os.path.isdir(path):
        return False
    try:
        with open(os.path.join(path, 'CACHEDIR.TAG'), encoding='utf-8', errors='replace') as tag_file:
            return tag_file.read(len(CACHE_DIRECTORY_TAG_SIGNATURE)) == CACHE_DIRECTORY_TAG_SIGNATURE
    except OSError:
        return False


def kind_of(path):
    """编译目录、工作树、仓副本，或者都不是（None）。"""
    if os.path.islink(path) or not os.path.isdir(path):
        return None
    if is_build_directory(path):
        return KIND_BUILD_DIRECTORY
    git_path = os.path.join(path, '.git')
    if os.path.isfile(git_path) and not os.path.islink(git_path):
        return KIND_WORKTREE
    if os.path.lexists(git_path) or is_build_directory(os.path.join(path, 'target')):
        return KIND_REPOSITORY_COPY
    return None


def birth_times(paths):
    """每个路径的创建时间（epoch 秒）；取不到的记 None。"""
    ordered = sorted(paths)
    if not ordered:
        return {}
    # 每条带上路径名再配对：中途被删掉的那个 stat 不输出，按位置配会让后面的全错一位
    completed = subprocess.run(['stat', '--printf=%.9W\\t%n\\0', '--', *ordered],
                               capture_output=True, text=True, check=False)
    reported = {}
    for record in completed.stdout.split('\0'):
        seconds_text, separator, path = record.partition('\t')
        if separator:
            try:
                reported[path] = float(seconds_text)
            except ValueError:
                pass
    return {path: (reported[path] if reported.get(path, 0.0) > 0 else None) for path in ordered}


def delivered_handbacks(calls):
    """送达了的交回：交回工具的调用，结果回来了、不是错误（被钩子拒掉的不算）。"""
    return [call for call in calls
            if call['name'] in HANDBACK_TOOL_NAMES and call['ended_at'] is not None and not call['result_is_error']]


def activity_windows(calls, now):
    handback_times = sorted(call['ended_at'] for call in delivered_handbacks(calls))
    windows = []
    for call in calls:
        if call['name'] in DISPATCH_TOOL_NAMES:
            continue
        window_end = call['ended_at']
        if window_end is None and call['input'].get('run_in_background') is True:
            # 没收到自己的完成通知：交回之后它就收工了，窗口截到那一刻
            window_end = next((handback_time for handback_time in handback_times if handback_time > call['started_at']), None)
        windows.append((call['started_at'] - WINDOW_SLACK_SECONDS, (window_end if window_end is not None else now) + WINDOW_SLACK_SECONDS))
    return windows


def is_within(seconds, windows):
    return seconds is not None and any(window_start <= seconds <= window_end for window_start, window_end in windows)


def candidate_directories(mentioned, project_root, roots, windows):
    def is_judged_area(path):
        return (any(is_strictly_under(path, root) for root in roots)
                and not is_shared_directory(path, roots)
                and not is_under(path, project_root)
                and not is_under(project_root, path))

    candidates = set()
    parents_to_scan = []
    for mentioned_path in mentioned:
        # 它自己与它的各级上级：提到了目录里面的路径，就是在那个目录里干过活
        path = mentioned_path
        while is_judged_area(path):
            if kind_of(path):
                candidates.add(path)
            path = os.path.dirname(path)
        if is_judged_area(mentioned_path) and os.path.isdir(mentioned_path) and not os.path.islink(mentioned_path):
            parents_to_scan.append(mentioned_path)
    # 它的下一级：只看它自己建的目录。在里面跑 cargo、跑脚本，建出来的东西不一定在调用里点名
    parent_birth_times = birth_times(parents_to_scan)
    for parent in parents_to_scan:
        if not is_within(parent_birth_times.get(parent), windows):
            continue
        try:
            names = os.listdir(parent)
        except OSError:
            names = []
        for name in names:
            child = os.path.join(parent, name)
            if kind_of(child):
                candidates.add(child)
    return candidates


def explains_path(text, path):
    """有一行同时写了这个全路径（后面可以跟 / 或汉字，不能再接路径：…/work2 与 …/work/sub 都不算 …/work）与一个说明词。"""
    path_pattern = re.compile(re.escape(path) + r'(?!/?[A-Za-z0-9_.-])')
    return any(path_pattern.search(line) and any(keyword in line.lower() for keyword in EXPLANATION_KEYWORDS)
               for line in text.splitlines())


def explanations(transcript_path, calls, explained_after, pending_handback_text, now):
    """（时刻, 文字）：送达了的交回；这一次要交回的那份；拦下之后回复里的文字与工具调用的输入。"""
    found = [(call['started_at'], '\n'.join(strings_in(call['input'], set()))) for call in delivered_handbacks(calls)]
    if explained_after is not None:
        found.extend((call['started_at'], '\n'.join(strings_in(call['input'], set()))) for call in calls
                     if call['started_at'] > explained_after and call['name'] not in HANDBACK_TOOL_NAMES)
        found.extend((at, text) for at, text in SESSION_TRANSCRIPT.assistant_texts(transcript_path) if at > explained_after)
    if pending_handback_text is not None:
        found.append((now, pending_handback_text))
    return found


def count_tool_use_lines(transcript_path):
    with open(transcript_path, encoding='utf-8', errors='replace') as transcript_file:
        return sum(1 for line in transcript_file if '"tool_use"' in line)


def judge(transcript_path, project_root, explained_after, pending_handback_text):
    now = time.time()
    try:
        tool_use_line_count = count_tool_use_lines(transcript_path)
    except OSError as error:
        print(f'  ✗ 会话记录读不了：{transcript_path}（{error.strerror}）', file=sys.stderr)
        print('     → 怎么办：这一次没判。看一眼这份会话记录在不在、读不读得了。', file=sys.stderr)
        return EXIT_CANNOT_JUDGE
    calls, unreadable_count = SESSION_TRANSCRIPT.tool_calls(transcript_path)
    windows = activity_windows(calls, now)
    roots = scratch_roots()
    mentioned = paths_mentioned_in_calls(calls, project_root)
    candidates = candidate_directories(mentioned, project_root, roots, windows)
    created = birth_times(candidates)
    unknown_birth = sorted(path for path, seconds in created.items() if seconds is None)
    own = sorted(path for path, seconds in created.items() if is_within(seconds, windows))
    left = [path for path in own if not any(is_strictly_under(path, outer) for outer in own)]
    if left:
        # 说明要写在它建好之后：同一个路径删了又重建，之前那句说明管不到新建的这一份
        explanation_entries = explanations(transcript_path, calls, explained_after, pending_handback_text, now)
        left = [path for path in left
                if not any(at >= created[path] and explains_path(text, path) for at, text in explanation_entries)]

    for path in left:
        print(f'{kind_of(path)}\t{path}')
    cannot_judge = []
    if unreadable_count:
        cannot_judge.append(f'有 {unreadable_count} 次工具调用认不出（时间戳认不出，或缺编号与输入），它们建的东西分不出来')
    elif tool_use_line_count and not calls:
        cannot_judge.append(f'会话记录里有 {tool_use_line_count} 行带 tool_use，一次工具调用都没认出来：记录的格式可能变了')
    if unknown_birth:
        cannot_judge.append(f'这些目录取不到创建时间，分不出是不是它建的：{" ".join(unknown_birth)}')
    for problem in cannot_judge:
        print(f'  ✗ {problem}', file=sys.stderr)
        print('     → 怎么办：这一部分没判。自己看一眼是不是这个子 agent 建的，是就照删。', file=sys.stderr)
    if left:
        return EXIT_SOME_LEFT
    return EXIT_CANNOT_JUDGE if cannot_judge else EXIT_NONE_LEFT


def read_pending_handback():
    """PreToolUse 钩子的 JSON（stdin）里 tool_input 的文字。"""
    try:
        hook_input = json.load(sys.stdin)
    except ValueError:
        return ''
    tool_input = hook_input.get('tool_input') if isinstance(hook_input, dict) else None
    return '\n'.join(strings_in(tool_input, set())) if isinstance(tool_input, dict) else ''


def main():
    positional = []
    explained_after = None
    pending_handback_text = None
    arguments = iter(sys.argv[1:])
    for argument in arguments:
        if argument == '--explained-after':
            value = next(arguments, '')
            try:
                explained_after = float(value)
            except ValueError:
                explained_after = None  # 状态文件写坏了：当作没拦过，重新拦一次
        elif argument == '--pending-handback':
            pending_handback_text = read_pending_handback()
        else:
            positional.append(argument)
    if len(positional) != 2:
        print('  ✗ 参数不对')
        print('     → 怎么办：用法 handback-scratch.py <子 agent 的会话记录.jsonl> <项目根> [--explained-after <epoch 秒>] [--pending-handback]')
        return EXIT_USAGE
    return judge(positional[0], os.path.realpath(positional[1]), explained_after, pending_handback_text)


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception:  # noqa: BLE001 —— 脚本自己出错与「还有没删的」分开报，收工钩子据此不拦
        traceback.print_exc(file=sys.stderr)
        print('  ✗ handback-scratch.py 自己出错了（上面是调用栈），这一次没判', file=sys.stderr)
        print('     → 怎么办：这是 handback-scratch.py 的缺陷，按调用栈修它。', file=sys.stderr)
        sys.exit(EXIT_CANNOT_JUDGE)
