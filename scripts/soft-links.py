#!/usr/bin/env python3
# gate-similar: root-entries.py 它也取跟踪的与没跟踪的条目，但只看项目根下第一层、相对 diff 基准新加的登没登记；这一道看全仓此刻的每一个软链接，不看基准，读的登记表也不是同一份
# gate-similar: script-modes.sh 它读暂存区里的模式，120000 那一类只判指向的脚本执行位对不对；这一道判软链接本身该不该在仓里，射程是全仓、连工作区里没跟踪的一起，并进去它就不再是只判射程目录的脚本
# admission: always 判的是此刻工作区与暂存区里的软链接和豁免表，一秒跑完
# run-condition: command git
"""仓里不放软链接；确实要留的，在项目根的 .claude/soft-link-exempt 登记（rules/command-safety.md「仓里不放软链接」）。

扫什么：项目根往下的每一个文件与目录（.git 除外，跟踪的、没跟踪的、被 .gitignore 忽略的都扫），
  再加暂存区里模式是 120000 的条目（检出时 core.symlinks 关着、或工作区里已经删掉的，靠这一样认出来）。
  --staged-from <源仓>：gate.sh --staged 的里层在临时树上跑，没跟踪的只在源仓工作区里，把源仓工作区也扫一遍。
豁免表：项目根的 .claude/soft-link-exempt，一行一条 `<相对项目根的路径>  # 理由`，理由不少于 MINIMUM_REASON_CHARACTERS 个字，
  同一条路径只许一行。没有这份文件就是一条都没豁免。

判红：没登记的软链接逐个列出路径；豁免表的行写坏了（没写理由、理由太短、路径不是相对项目根的、重复）；
  登记的路径在扫过的地方都不是软链接。
退出码：0 通过；1 有红；3 判不了（项目根不在、git 出错、有目录读不了、脚本自己出错）。

用法：soft-links.py [项目根] [--staged-from <源仓>]
管不到的：理由成不成立，靠 review；.git 目录里的不判。
"""
import os
import subprocess
import sys
import traceback
# 开跑之前先判准入与运行条件（rules/preflight-discipline.md）；不写 __pycache__：门禁跑到一半冒出一个未跟踪的目录，「工作区跑的过程中没变」就对不上
sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
from preflight import preflight  # noqa: E402

EXEMPT_RELATIVE_PATH = os.path.join('.claude', 'soft-link-exempt')
MINIMUM_REASON_CHARACTERS = 4
SYMBOLIC_LINK_INDEX_MODE = '120000'
GIT_DIRECTORY_NAME = '.git'
RULE_REFERENCE = 'rules/command-safety.md「仓里不放软链接」'

EXIT_PASSED = 0
EXIT_RED = 1
EXIT_CANNOT_JUDGE = 3


class CannotJudge(Exception):
    """判不了：不是判红，是这一轮没判成。带着卡在哪与下一步。"""

    def __init__(self, problem, next_step):
        super().__init__(problem)
        self.problem = problem
        self.next_step = next_step


def read_exempt_table(project_root):
    """读豁免表 → (路径到理由的字典, 写坏了的行的说明列表)。没有这份文件就是空字典、没有问题。"""
    exempt_path = os.path.join(project_root, EXEMPT_RELATIVE_PATH)
    exempt_reasons, problems = {}, []
    try:
        with open(exempt_path, encoding='utf-8', errors='replace') as exempt_file:
            exempt_lines = exempt_file.read().splitlines()
    except FileNotFoundError:
        return exempt_reasons, problems
    for line_number, raw_line in enumerate(exempt_lines, start=1):
        stripped_line = raw_line.strip()
        if not stripped_line or stripped_line.startswith('#'):
            continue
        location = f'{EXEMPT_RELATIVE_PATH}:{line_number}'
        if '#' not in stripped_line:
            problems.append(f'{location} 没写理由：{stripped_line}')
            continue
        path_part, reason = stripped_line.split('#', 1)
        link_path, reason = path_part.strip(), reason.strip()
        while link_path.startswith('./'):
            link_path = link_path[2:]
        link_path = link_path.rstrip('/')
        path_components = link_path.split('/')
        if not link_path or link_path.startswith('/') or '..' in path_components or '.' in path_components or '' in path_components:
            problems.append(f'{location} 路径不是相对项目根的：「{path_part.strip()}」')
            continue
        if len(reason) < MINIMUM_REASON_CHARACTERS:
            problems.append(f'{location} 理由不到 {MINIMUM_REASON_CHARACTERS} 个字：{link_path}  # {reason}')
            continue
        if link_path in exempt_reasons:
            problems.append(f'{location} 重复登记：{link_path}')
            continue
        exempt_reasons[link_path] = reason
    return exempt_reasons, problems


def walk_soft_links(scanned_root):
    """扫一棵目录（.git 除外，不顺着软链接往里走）→ (软链接的相对路径到指向的字典, 扫过的文件与目录个数)。"""
    soft_link_targets, scanned_entry_count, unreadable_directories = {}, 0, []

    def remember_unreadable(error):
        unreadable_directories.append(f'{error.filename}：{error.strerror}')

    for directory_path, directory_names, file_names in os.walk(scanned_root, onerror=remember_unreadable):
        directory_names[:] = [directory_name for directory_name in directory_names if directory_name != GIT_DIRECTORY_NAME]
        for entry_name in directory_names + file_names:
            if entry_name == GIT_DIRECTORY_NAME:
                continue
            scanned_entry_count += 1
            entry_path = os.path.join(directory_path, entry_name)
            if os.path.islink(entry_path):
                relative_path = os.path.relpath(entry_path, scanned_root).replace(os.sep, '/')
                soft_link_targets[relative_path] = os.readlink(entry_path)
    if unreadable_directories:
        raise CannotJudge(f'{scanned_root} 下有 {len(unreadable_directories)} 个目录读不了：{"；".join(unreadable_directories)}',
                          '给这些目录加上读与进入的权限（或删掉它们），再跑；读不了的目录里有没有软链接，这一道看不见。')
    return soft_link_targets, scanned_entry_count


def run_git(project_root, *arguments):
    return subprocess.run(['git', '-C', project_root, *arguments], capture_output=True, text=True,
                          encoding='utf-8', errors='replace')


def indexed_soft_links(project_root):
    """暂存区里模式是 120000 的条目的相对路径；不在 git 仓里返回 None。"""
    if run_git(project_root, 'rev-parse', '--is-inside-work-tree').returncode != 0:
        return None
    listing = run_git(project_root, 'ls-files', '-s', '-z')
    if listing.returncode != 0:
        raise CannotJudge(f'git ls-files -s 失败：{listing.stderr.strip()}',
                          f'在 {project_root} 里手跑 git ls-files -s 看 git 报什么，修好再跑。')
    soft_link_paths = set()
    for index_entry in listing.stdout.split('\0'):
        if not index_entry:
            continue
        entry_metadata, entry_path = index_entry.split('\t', 1)
        if entry_metadata.split(' ', 1)[0] == SYMBOLIC_LINK_INDEX_MODE:
            soft_link_paths.add(entry_path)
    return soft_link_paths


def judge(project_root, staged_from_root):
    exempt_reasons, problems = read_exempt_table(project_root)
    # 路径到「在哪看到的」说明：同一条路径在几处都看到，只列一次
    found_soft_links = {}
    worktree_links, scanned_entry_count = walk_soft_links(project_root)
    for relative_path, link_target in worktree_links.items():
        found_soft_links[relative_path] = f'指向 {link_target}'
    tracked_paths = indexed_soft_links(project_root)
    if tracked_paths is None:
        print(f'  ! {project_root} 不在 git 仓里：只扫了文件系统，暂存区里的软链接无从查起')
        tracked_paths = set()
    for relative_path in tracked_paths:
        found_soft_links.setdefault(relative_path, '暂存区里是软链接，工作区里不是')
    if staged_from_root:
        source_links, source_entry_count = walk_soft_links(staged_from_root)
        scanned_entry_count += source_entry_count
        print(f'  源仓工作区也扫了：{staged_from_root}（没跟踪的只在那里）')
        for relative_path, link_target in source_links.items():
            found_soft_links.setdefault(relative_path, f'指向 {link_target}（在源仓工作区里）')
    unexempt_paths = sorted(relative_path for relative_path in found_soft_links if relative_path not in exempt_reasons)
    stale_exempt_paths = sorted(relative_path for relative_path in exempt_reasons if relative_path not in found_soft_links)
    failed = False
    if problems:
        print(f'  ✗ 豁免表 {EXEMPT_RELATIVE_PATH} 有 {len(problems)} 行写坏了：')  # gate-lint:summary
        for problem in problems:
            print(f'        {problem}')  # gate-lint:detail
        print(f'     → 怎么办：一行一条 `<相对项目根的路径>  # 理由`：路径不带开头的 /、不带 . 与 ..，'
              f'理由至少 {MINIMUM_REASON_CHARACTERS} 个字，写它指向哪、为什么不能换成拷贝或写明路径；一条路径只登记一行。')
        failed = True
    if unexempt_paths:
        print(f'  ✗ 仓里有 {len(unexempt_paths)} 个软链接没在 {EXEMPT_RELATIVE_PATH} 登记：')  # gate-lint:summary
        for relative_path in unexempt_paths:
            tracked_note = '跟踪的' if relative_path in tracked_paths else '没跟踪的'
            print(f'        {relative_path}  （{tracked_note}，{found_soft_links[relative_path]}）')  # gate-lint:detail
        print('     → 怎么办：换成它指向的那一份的拷贝，或者在用到它的地方写明真实路径，再删掉软链接（跟踪的用 git rm）；'
              f'确实要留，在 {EXEMPT_RELATIVE_PATH} 登记一行 `<路径>  # 理由`（{RULE_REFERENCE}）。')
        failed = True
    if stale_exempt_paths:
        print(f'  ✗ 豁免表里有 {len(stale_exempt_paths)} 条登记的路径不是软链接：{"、".join(stale_exempt_paths)}')
        print(f'     → 怎么办：软链接已经删掉、或换成了普通文件的，把 {EXEMPT_RELATIVE_PATH} 里那一行也删掉；路径写错了的改对。')
        failed = True
    if failed:
        return EXIT_RED
    print(f'  ✓ 扫了 {scanned_entry_count} 个文件与目录（.git 除外）与暂存区的 {len(tracked_paths)} 个软链接条目，'
          f'软链接 {len(found_soft_links)} 个，都登记了；豁免表 {len(exempt_reasons)} 条都指得到')
    return EXIT_PASSED


def main():
    arguments = sys.argv[1:]
    staged_from_root = ''
    if '--staged-from' in arguments:
        option_position = arguments.index('--staged-from')
        if option_position + 1 >= len(arguments):
            print('  ✗ --staged-from 后面没给源仓')
            print('     → 怎么办：用法 soft-links.py [项目根] [--staged-from <源仓>]')
            return EXIT_CANNOT_JUDGE
        staged_from_root = os.path.realpath(arguments[option_position + 1])
        del arguments[option_position:option_position + 2]
    if len(arguments) > 1:
        print(f'  ✗ 只收一个项目根，收到 {len(arguments)} 个：{" ".join(arguments)}')
        print('     → 怎么办：用法 soft-links.py [项目根] [--staged-from <源仓>]')
        return EXIT_CANNOT_JUDGE
    project_root = os.path.realpath(arguments[0] if arguments else '.')
    for required_directory in filter(None, (project_root, staged_from_root)):
        if not os.path.isdir(required_directory):
            print(f'  ✗ 找不到目录：{required_directory}')
            print('     → 怎么办：在项目根跑，或者把项目根作为参数传进来；--staged-from 给源仓的根。')
            return EXIT_CANNOT_JUDGE
    return judge(project_root, staged_from_root)


if __name__ == '__main__':
    preflight(__file__)
    try:
        sys.exit(main())
    except CannotJudge as error:
        print(f'  ✗ 软链接判不了：{error.problem}')
        print(f'     → 怎么办：{error.next_step}')
        sys.exit(EXIT_CANNOT_JUDGE)
    except Exception:  # noqa: BLE001 —— 脚本自己出错与「判红」分开报
        traceback.print_exc(file=sys.stderr)
        print('  ✗ 软链接：判定脚本自己出错了（stderr 里是调用栈），这一轮没判')
        print('     → 怎么办：这是 soft-links.py 的缺陷，按调用栈修它；修好之前这一道不算通过。')
        sys.exit(EXIT_CANNOT_JUDGE)
