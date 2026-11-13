#!/usr/bin/env python3
# gate-similar: 无 查过 gate-overlap.py --list 列出的全部钩子：没有一个挂 SessionStart 或 UserPromptSubmit；读钩子输入与会话记录的几个 python 判定（courtesy-phrase.py、unanswered-message.py、borrowed-convention.py、handback-scratch.py）都在判 agent 做没做对，这一道不判对错、只改会话标题
# gate-overlap:copy-kept courtesy-phrase.py 相同的是载入共用库、退出码常量、自证收尾与 main 入口那几段；每份 python 钩子判定各带一份，读钩子输入与会话记录已经抽进 session-transcript.py
# admission: always Claude Code 在会话启动、恢复与每次提交提示时调它，标题要现写
# run-condition: none 只读钩子从标准输入给的 JSON、它点名的会话记录与 Claude Code 的会话登记目录、只用 python 标准库
"""会话标题开头写会话编号，格式 `(编号) 标题`（rules/communication-discipline.md「会话标题开头写编号」）。

用法：
    session-number-title.py --hook       # 从标准输入读 Claude Code 的 SessionStart / UserPromptSubmit 钩子 JSON
    session-number-title.py --selftest   # 自证：内嵌样本逐个判，整条钩子路径；再逐个打开弄坏开关另起子进程跑自证

编号：Claude Code 给没命名的会话起的默认名 `<目录名>-<编号>` 里的编号，每启动或恢复一次随机生成一个。
  从会话登记目录（$CLAUDE_CONFIG_DIR/sessions，默认 ~/.claude/sessions）里祖先进程的 <pid>.json 取；
  那份登记的 nameSource 是 derived 时才取得到（会话已经有自定义标题时，Claude Code 启动后约 1 秒把它换成标题）。
  取不到时沿用标题里已有的编号，再取不到用 SessionStart 记下的那个（状态目录）；
  都没有（会话早就起了自定义标题，默认名已经换掉）时，用会话 ID 的 sha256 前两位十六进制；
  这个号已被登记里别的会话占着（默认名的编号，或标题开头的编号）就顺着 sha256 往后取下一对。
写什么：
  SessionStart（startup / resume / fork）：`(编号) <原标题去掉旧编号>`；原来没有标题时取会话记录里最新的自动标题（ai-title），也没有就只写 `(编号)`。
  UserPromptSubmit：标题开头没有编号（被 /rename 改掉了）就补上；标题只有编号、或编号后面是这个会话的某个自动标题时，换成最新的自动标题。
  用户自己起的标题只加编号，不换。
退出码：写了或不用写 0（要写时往标准输出打 hookSpecificOutput.sessionTitle）；取不到编号或输入不对 1（不拦，stderr 留一行原因）。
  UserPromptSubmit 上退 2 会挡掉用户的提示，所以这一道从不退 2。
  状态目录默认 ${TMPDIR:-/tmp}/session-number-title，SESSION_NUMBER_TITLE_STATE_DIRECTORY 可改；
  登记目录可由 SESSION_NUMBER_TITLE_REGISTRY_DIRECTORY 改（自证用）。

够不着的：恢复一个已有自定义标题的会话时，钩子读到登记之前 Claude Code 已经换成标题的，取不到这一次的新编号，沿用标题里的旧编号
  （标题里也没有时用会话 ID 算的号，它与会话列表里显示过的默认名对不上）；
  子 agent 没有自己的会话标题，不写；不是交互式的会话（claude -p）没有默认名，取不到编号。

SESSION_NUMBER_TITLE_BREAK=<开关名> 打开一个弄坏开关（自证专用，钩子里不许设），开关表见 BREAK_SWITCHES。
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import time

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
from preflight import load_package_module, preflight  # noqa: E402
BREAK_SWITCH_SELFTEST = load_package_module("break_switch_selftest", "break-switch-selftest.py")
SESSION_TRANSCRIPT = load_package_module("session_transcript", "session-transcript.py")

EXIT_PASS = 0
EXIT_NOT_WRITTEN = 1
BREAK_ENVIRONMENT_VARIABLE = "SESSION_NUMBER_TITLE_BREAK"
# 弄坏开关 → 打开后自证必须红在哪个样本上
BREAK_SWITCHES = {
    "old-number-kept": "恢复时换成新编号",
    "custom-title-replaced": "用户起的标题不换",
    "removed-number-ignored": "被改掉的编号补回去",
    "fallback-ignored": "默认名已换掉时用会话 ID 算的号",
    "collision-ignored": "算的号被别的会话占着就取下一对",
}

NUMBERED_TITLE = re.compile(r"^\(([^()\s]+)\)\s*(.*)$", re.S)
REGISTRY_WAIT_SECONDS = 3.0
REGISTRY_POLL_SECONDS = 0.1
SESSION_START_SOURCES = ("startup", "resume", "fork")


def break_switch() -> str:
    return os.environ.get(BREAK_ENVIRONMENT_VARIABLE, "")


def split_title(title: str):
    """`(编号) 标题` → (编号, 标题)；开头没有编号 → (None, 原标题)。"""
    match = NUMBERED_TITLE.match(title or "")
    if match is None:
        return None, (title or "").strip()
    return match.group(1), match.group(2).strip()


def composed_title(number: str, base: str) -> str:
    return f"({number}) {base}".strip()


def next_title(event: str, current_title: str, registry_number, stored_number, ai_titles: list, fallback_number=None):
    """要写的新标题；不用改时是 None。ai_titles 是会话记录里的自动标题，按出现先后排。
    fallback_number 是前几样都取不到时用的号（会话 ID 算的）。返回 (新标题或 None, 用的编号或 None)。"""
    if break_switch() == "fallback-ignored":
        fallback_number = None
    title_number, base = split_title(current_title)
    latest_ai_title = ai_titles[-1] if ai_titles else ""
    if event == "SessionStart":
        number = registry_number or title_number or stored_number or fallback_number
        if break_switch() == "old-number-kept":
            number = title_number or registry_number or stored_number or fallback_number
        if number is None:
            return None, None
        if not base:
            base = latest_ai_title
        title = composed_title(number, base)
        return (title if title != current_title else None), number
    # UserPromptSubmit
    number = title_number or stored_number or registry_number or fallback_number
    if number is None:
        return None, None
    if title_number is None:
        if break_switch() == "removed-number-ignored":
            return None, number
        return composed_title(number, base or latest_ai_title), number
    automatic = not base or base in ai_titles or break_switch() == "custom-title-replaced"
    if automatic and latest_ai_title and latest_ai_title != base:
        return composed_title(number, latest_ai_title), number
    return None, number


def registry_directory() -> str:
    override = os.environ.get("SESSION_NUMBER_TITLE_REGISTRY_DIRECTORY")
    if override:
        return override
    config_directory = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".claude")
    return os.path.join(config_directory, "sessions")


def ancestor_pids() -> list:
    pids = []
    pid = os.getppid()
    while pid > 1 and len(pids) < 64:
        pids.append(pid)
        try:
            with open(f"/proc/{pid}/stat", encoding="utf-8") as stat_file:
                pid = int(stat_file.read().rsplit(")", 1)[1].split()[1])
        except (OSError, ValueError, IndexError):
            break
    return pids


def read_registration(path: str):
    try:
        with open(path, encoding="utf-8") as registration_file:
            registration = json.load(registration_file)
    except (OSError, ValueError):
        return None
    return registration if isinstance(registration, dict) else None


def own_registration(session_id: str):
    """这个会话在登记目录里的那一份：先找祖先进程的 <pid>.json，再按 sessionId 找。"""
    directory = registry_directory()
    for pid in ancestor_pids():
        registration = read_registration(os.path.join(directory, f"{pid}.json"))
        if registration is not None:
            return registration
    try:
        names = sorted(os.listdir(directory))
    except OSError:
        return None
    for name in names:
        if name.endswith(".json"):
            registration = read_registration(os.path.join(directory, name))
            if registration is not None and session_id and registration.get("sessionId") == session_id:
                return registration
    return None


def number_in_registration(registration) -> str | None:
    """登记里的默认名 `<目录名>-<编号>` 的编号；登记的不是默认名（nameSource 不是 derived）时是 None。"""
    if not isinstance(registration, dict) or registration.get("nameSource") != "derived":
        return None
    name = registration.get("name")
    if not isinstance(name, str) or not name:
        return None
    cwd = registration.get("cwd")
    prefix = f"{os.path.basename(cwd.rstrip('/'))}-" if isinstance(cwd, str) and cwd else ""
    if prefix and name.startswith(prefix) and len(name) > len(prefix):
        return name[len(prefix):]
    return name.rsplit("-", 1)[-1] or None


def numbers_in_use(session_id: str) -> set:
    """登记里别的会话占着的编号：默认名的编号与标题开头的编号。"""
    directory = registry_directory()
    try:
        names = os.listdir(directory)
    except OSError:
        return set()
    used = set()
    for name in names:
        registration = read_registration(os.path.join(directory, name)) if name.endswith(".json") else None
        if registration is None or (session_id and registration.get("sessionId") == session_id):
            continue
        number = number_in_registration(registration) or split_title(str(registration.get("name") or ""))[0]
        if number:
            used.add(number)
    return used


def fallback_number(session_id: str, used: set):
    """会话 ID 的 sha256 里第一对没被占的两位十六进制；没有会话 ID 是 None。"""
    if not session_id:
        return None
    digest = hashlib.sha256(session_id.encode("utf-8")).hexdigest()
    candidates = [digest[index:index + 2] for index in range(0, len(digest), 2)]
    if break_switch() == "collision-ignored":
        return candidates[0]
    return next((candidate for candidate in candidates if candidate not in used), candidates[0])


def registry_number(session_id: str, wait: bool):
    """登记里的编号。SessionStart 时登记可能还没写好，等一会儿（REGISTRY_WAIT_SECONDS）。"""
    deadline = time.monotonic() + (REGISTRY_WAIT_SECONDS if wait else 0)
    while True:
        registration = own_registration(session_id)
        if registration is not None or time.monotonic() >= deadline:
            return number_in_registration(registration)
        time.sleep(REGISTRY_POLL_SECONDS)


def state_file(session_id: str) -> str:
    directory = os.environ.get("SESSION_NUMBER_TITLE_STATE_DIRECTORY") or os.path.join(os.environ.get("TMPDIR") or "/tmp", "session-number-title")
    return os.path.join(directory, re.sub(r"[^A-Za-z0-9_-]", "_", session_id or "no-session"))


def ai_titles_in(transcript_path) -> list:
    if not isinstance(transcript_path, str) or not os.path.isfile(transcript_path):
        return []
    titles = []
    for entry in SESSION_TRANSCRIPT.transcript_entries(transcript_path, '"ai-title"'):
        title = entry.get("aiTitle")
        if entry.get("type") == "ai-title" and isinstance(title, str) and title.strip():
            title = title.strip()
            if title in titles:
                titles.remove(title)
            titles.append(title)
    return titles


def judge_hook(hook_text: str) -> int:
    hook_input = SESSION_TRANSCRIPT.hook_input_object(hook_text)
    if hook_input is None:
        print("session-number-title：钩子输入不是 JSON 对象，这一次没写标题", file=sys.stderr)
        return EXIT_NOT_WRITTEN
    event = hook_input.get("hook_event_name")
    if event == "SessionStart" and hook_input.get("source") not in SESSION_START_SOURCES:
        return EXIT_PASS
    if event not in ("SessionStart", "UserPromptSubmit"):
        print(f"session-number-title：只挂 SessionStart 与 UserPromptSubmit，收到的是 {event!r}，这一次没写标题", file=sys.stderr)
        return EXIT_NOT_WRITTEN
    if hook_input.get("agent_id"):
        return EXIT_PASS
    session_id = hook_input.get("session_id") if isinstance(hook_input.get("session_id"), str) else ""
    current_title = hook_input.get("session_title") if isinstance(hook_input.get("session_title"), str) else ""
    stored = SESSION_TRANSCRIPT.stored_fingerprint(state_file(session_id)) or None
    found = registry_number(session_id, wait=(event == "SessionStart" and not split_title(current_title)[0]))
    fallback = fallback_number(session_id, numbers_in_use(session_id))
    title, number = next_title(event, current_title, found, stored, ai_titles_in(hook_input.get("transcript_path")), fallback)
    if number is None:
        print(f"session-number-title：会话登记目录 {registry_directory()} 里取不到这个会话的默认名编号，标题里也没有，输入里也没有 session_id 可算，这一次没写标题", file=sys.stderr)
        return EXIT_NOT_WRITTEN
    if number != stored:
        SESSION_TRANSCRIPT.store_fingerprint(state_file(session_id), number)
    if title is not None:
        print(json.dumps({"hookSpecificOutput": {"hookEventName": event, "sessionTitle": title}}, ensure_ascii=False))
    return EXIT_PASS


AI = ["对话编号前缀规范"]
# 样本：(样本名, 事件, 原标题, 登记里的编号, 状态里记的编号, 自动标题, 期望的新标题；None 是不用改)；会话 ID 算的号一律是 "c9"
SELFTEST_CASES = (
    ("新会话只写编号", "SessionStart", "", "42", None, [], "(42)"),
    ("新会话有自动标题时带上", "SessionStart", "", "42", None, AI, "(42) 对话编号前缀规范"),
    ("恢复时换成新编号", "SessionStart", "(17) 里程碑5 小文件打包", "42", None, [], "(42) 里程碑5 小文件打包"),
    ("恢复时取不到新编号沿用旧的", "SessionStart", "(17) 里程碑5 小文件打包", None, None, [], None),
    ("恢复时给没编号的标题加上", "SessionStart", "里程碑5 小文件打包", "42", None, [], "(42) 里程碑5 小文件打包"),
    ("默认名已换掉时用会话 ID 算的号", "SessionStart", "里程碑5", None, None, [], "(c9) 里程碑5"),
    ("提示时默认名已换掉也用会话 ID 算的号", "UserPromptSubmit", "里程碑3 收尾", None, None, [], "(c9) 里程碑3 收尾"),
    ("自动标题出来了换上", "UserPromptSubmit", "(42)", None, None, AI, "(42) 对话编号前缀规范"),
    ("自动标题变了跟着换", "UserPromptSubmit", "(42) 旧的自动标题", None, None, ["旧的自动标题", "新的自动标题"], "(42) 新的自动标题"),
    ("用户起的标题不换", "UserPromptSubmit", "(42) 里程碑5 小文件打包", None, None, AI, None),
    ("被改掉的编号补回去", "UserPromptSubmit", "里程碑5 小文件打包", None, "42", AI, "(42) 里程碑5 小文件打包"),
    ("已经是最新的不改", "UserPromptSubmit", "(42) 对话编号前缀规范", None, None, AI, None),
)


P_DIGEST = hashlib.sha256(b"p").hexdigest()
# 算号样本：(样本名, 会话 ID, 别的会话占着的号, 期望的号)
FALLBACK_CASES = (
    ("算的号没被占就用头一对", "p", {"00"}, P_DIGEST[:2]),
    ("算的号被别的会话占着就取下一对", "p", {P_DIGEST[:2]}, P_DIGEST[2:4]),
    ("没有会话 ID 算不出", "", set(), None),
)


def run_selftest_cases() -> list:
    misjudged_cases = []
    for case_name, event, current_title, found, stored, ai_titles, expected in SELFTEST_CASES:
        actual, _ = next_title(event, current_title, found, stored, ai_titles, "c9")
        if actual != expected:
            misjudged_cases.append((case_name, expected, actual))
    for case_name, session_id, used, expected in FALLBACK_CASES:
        actual = fallback_number(session_id, used)
        if actual != expected:
            misjudged_cases.append((case_name, expected, actual))
    return misjudged_cases


HOOK_PATH_COUNT = 9


def run_hook_cases() -> list:
    """整条钩子路径：JSON 进，退出码与写出的标题出。"""
    misjudged_cases = []
    with tempfile.TemporaryDirectory() as scratch_directory:
        registry = os.path.join(scratch_directory, "sessions")
        os.makedirs(registry)
        with open(os.path.join(registry, "1.json"), "w", encoding="utf-8") as handle:
            json.dump({"pid": 1, "sessionId": "s", "cwd": "/work/demo", "name": "demo-3f", "nameSource": "derived"}, handle)
        with open(os.path.join(registry, "2.json"), "w", encoding="utf-8") as handle:
            json.dump({"pid": 2, "sessionId": "r", "cwd": "/work/demo", "name": "里程碑5", "nameSource": "auto"}, handle)
        transcript_path = os.path.join(scratch_directory, "session.jsonl")
        with open(transcript_path, "w", encoding="utf-8") as handle:
            handle.write(json.dumps({"type": "ai-title", "aiTitle": "对话编号前缀规范", "sessionId": "s"}, ensure_ascii=False) + "\n")
        environment = dict(os.environ, SESSION_NUMBER_TITLE_STATE_DIRECTORY=os.path.join(scratch_directory, "state"),
                           SESSION_NUMBER_TITLE_REGISTRY_DIRECTORY=registry)
        environment.pop(BREAK_ENVIRONMENT_VARIABLE, None)

        def expect(case_name: str, hook_text: str, expected_exit: int, expected_title):
            hook_run = subprocess.run([sys.executable, os.path.abspath(__file__), "--hook"], input=hook_text,
                                      capture_output=True, text=True, check=False, env=environment)
            written = None
            if hook_run.stdout.strip():
                try:
                    written = json.loads(hook_run.stdout)["hookSpecificOutput"]["sessionTitle"]
                except (ValueError, KeyError, TypeError):
                    written = "<输出不是 hookSpecificOutput.sessionTitle>"
            if hook_run.returncode != expected_exit or written != expected_title:
                misjudged_cases.append((case_name, f"{expected_exit} {expected_title}", f"{hook_run.returncode} {written}"))

        def hook_json(**fields) -> str:
            return json.dumps(fields, ensure_ascii=False)

        expect("启动时从登记取编号写进标题", hook_json(hook_event_name="SessionStart", source="startup", session_id="s",
                                         transcript_path=transcript_path), EXIT_PASS, "(3f) 对话编号前缀规范")
        expect("提示时把被改掉的编号补回去", hook_json(hook_event_name="UserPromptSubmit", session_id="s", session_title="里程碑5"),
               EXIT_PASS, "(3f) 里程碑5")
        expect("登记已换成标题、标题里有编号就沿用", hook_json(hook_event_name="SessionStart", source="resume", session_id="r",
                                                session_title="(17) 里程碑5"), EXIT_PASS, None)
        expect("登记已换成标题、标题里没编号就用会话 ID 算", hook_json(hook_event_name="UserPromptSubmit", session_id="q", session_title="里程碑5"),
               EXIT_PASS, f"({hashlib.sha256(b'q').hexdigest()[:2]}) 里程碑5")
        with open(os.path.join(registry, "3.json"), "w", encoding="utf-8") as handle:
            json.dump({"pid": 3, "sessionId": "o", "cwd": "/work/demo", "name": f"demo-{hashlib.sha256(b'p').hexdigest()[:2]}", "nameSource": "derived"}, handle)
        expect("算的号被别的会话占着就取下一对", hook_json(hook_event_name="UserPromptSubmit", session_id="p", session_title="里程碑5"),
               EXIT_PASS, f"({hashlib.sha256(b'p').hexdigest()[2:4]}) 里程碑5")
        expect("没有会话 ID 也取不到编号不写", hook_json(hook_event_name="UserPromptSubmit", session_title="里程碑5"), EXIT_NOT_WRITTEN, None)
        expect("clear 与 compact 不写", hook_json(hook_event_name="SessionStart", source="compact", session_id="s"), EXIT_PASS, None)
        expect("子 agent 不写", hook_json(hook_event_name="UserPromptSubmit", session_id="s", agent_id="a1"), EXIT_PASS, None)
        expect("输入不是 JSON 对象不写", "[1, 2]", EXIT_NOT_WRITTEN, None)
    return misjudged_cases


def selftest() -> int:
    misjudged_cases = run_selftest_cases()
    if not break_switch():
        misjudged_cases += run_hook_cases()
    exit_code = BREAK_SWITCH_SELFTEST.finish_selftest(__file__, BREAK_ENVIRONMENT_VARIABLE, BREAK_SWITCHES, misjudged_cases,
                                                      len(SELFTEST_CASES) + len(FALLBACK_CASES), "next_title / fallback_number / judge_hook")
    if exit_code is not None:
        return exit_code
    print(f"  ✓ session-number-title 自证：{len(SELFTEST_CASES) + len(FALLBACK_CASES)} 个样本与 {HOOK_PATH_COUNT} 条钩子路径写得对；"
          f"{len(BREAK_SWITCHES)} 个弄坏开关逐个打开，各自红在点名的样本上")
    return 0


def main(arguments: list) -> int:
    if arguments == ["--hook"]:
        return judge_hook(sys.stdin.read())
    if arguments == ["--selftest"]:
        return selftest()
    print("  ✗ 用法：session-number-title.py --hook（从标准输入读钩子 JSON），或 session-number-title.py --selftest")
    print("     → 怎么办：钩子里由 scripts/claude-hooks/session-number-title.sh 起它；改了这份脚本先跑 --selftest。")
    return 2


if __name__ == "__main__":
    preflight(__file__)
    sys.exit(main(sys.argv[1:]))
