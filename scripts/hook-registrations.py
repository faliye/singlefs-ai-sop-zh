#!/usr/bin/env python3
"""列出 .claude/settings.json 里注册的每一条钩子命令：事件、matcher、命令，一行一条，制表符分隔。

读 settings.json 的钩子、判「一条注册命令指向哪个钩子」都只在这一处。hooks-registered.sh 判「注册着没有、事件挂全没有」，
gate-overlap.py 判「新钩子和谁挂在同一个触发点上」，两边各写一份的话，一边认了新写法、另一边没跟，
就会一个说注册着、一个说找不到（rules/kb-discipline.md 第 4 条）。

用法：
  hook-registrations.py <settings.json>               全部注册
  hook-registrations.py --for <钩子文件名> <settings.json>   只列指向这个钩子的那几条
读不了（不存在、不是 JSON、结构不对）退 1，一行都不打；一条都没有时退 0、什么都不打。
"""
import json
import re
import sys


def registered_hooks(settings_path):
    with open(settings_path, encoding='utf-8') as settings_file:
        settings = json.load(settings_file)
    registrations = []
    for event_name, event_entries in (settings.get('hooks') or {}).items():
        for entry in event_entries or []:
            matcher = entry.get('matcher') or ''
            for hook in entry.get('hooks') or []:
                command = hook.get('command') or ''
                if command:
                    registrations.append((event_name, matcher, command))
    return registrations


def command_points_to_hook(command, hook_file_name):
    """命令里有没有以这个文件名结尾的路径：左边是开头、斜杠、空白或引号，右边是结尾、空白、引号或命令分隔符。

    按子串认的话，`guard.sh` 会认成 `old-guard.sh` 的注册。
    """
    return re.search(r'(^|[/\s"\'])' + re.escape(hook_file_name) + r'($|[\s"\';&|])', command) is not None


def main():
    arguments = sys.argv[1:]
    hook_file_name = None
    if arguments[:1] == ['--for']:
        if len(arguments) < 2:
            sys.exit(1)
        hook_file_name = arguments[1]
        arguments = arguments[2:]
    if len(arguments) != 1:
        sys.exit(1)
    try:
        registrations = registered_hooks(arguments[0])
    except (OSError, ValueError, AttributeError, TypeError):
        sys.exit(1)
    for event_name, matcher, command in registrations:
        if hook_file_name is None or command_points_to_hook(command, hook_file_name):
            print(f'{event_name}\t{matcher}\t{command}')


if __name__ == '__main__':
    main()
