#!/usr/bin/env python3
# gate-similar: borrowed-convention.py 同样判 SendMessage 的钩子输入，但它判消息正文里的借用句；这一道只判收件的会话还在不在跑，读的是 Claude Code 的会话登记，判据与输入的另一半都不同
# gate-similar: unanswered-message.py 同样管跨会话消息，但它在收工时判收到的消息回没回；这一道在发之前判对象活着没有，触发点不同
# gate-overlap:copy-kept unanswered-message.py 相同的是载入共用库、退出码常量与自证样本前的那几段；每份 python 钩子判定各带一份，读钩子输入与会话登记已经抽进 session-transcript.py 与 session-number-title.py
# gate-overlap:copy-kept courtesy-phrase.py 相同的是载入共用库与退出码常量那几段；每份 python 钩子判定各带一份，与 unanswered-message.py 那一行同理
# gate-similar: session-number-title.py 同样读 Claude Code 的会话登记，读登记、取编号的几个函数直接载入它的，不另抄一份；它改会话标题，不判对错
# admission: always Claude Code 在每一次给别的会话发消息之前调它，对象活着没有要现判
# run-condition: none 只读钩子从标准输入给的 JSON、Claude Code 的会话登记目录、/proc 与会话记录目录的目录名、只用 python 标准库
"""给别的会话发消息，只发给正在跑的会话（rules/communication-discipline.md「找别的会话，只找正在跑的」）。

用法：
    message-target.py --hook       # 从标准输入读 Claude Code PreToolUse 钩子的 JSON（SendMessage 的 to）
    message-target.py --selftest   # 自证：内嵌样本逐个判，整条钩子路径；再逐个打开弄坏开关另起子进程跑自证

判据：to 去掉行尾的 ` [ref]` 之后，长得像一个会话的名字，而 Claude Code 的会话登记里没有一个进程还在的会话对得上它 ⇒ 拒绝。
  像会话的名字：`(编号) 标题`；`<目录名>-<编号>`（目录名是登记里某个会话的工作目录名、这次的工作目录名，
    或会话记录目录 $CLAUDE_CONFIG_DIR/projects 下某个目录名的末段）；会话 ID（UUID）。
  对得上：名字逐字相同；或者编号相同（标题会改，编号不变）；或者会话 ID 相同。
  进程还在：登记里的 pid 在 /proc 下有目录。
  别的 to（子 agent 名、队友名、main、agentId）不判，放行。
退出码：拒绝 2（这一次不发，stderr 交给 agent）；放行 0；判不了 1（照常发，stderr 留一行原因）。

够不着的（不判，不等于通过）：别的机器上、云端的会话（本机登记里没有，长得像会话名的会被拒，改用 ListAgents 给的名字与 [ref]）；
  不带编号、也不是默认名的会话名；agent 用什么办法找到的那个会话（按会话记录的日期捞的、记错的）它不分，只看发不发得到。
登记目录可由 SESSION_NUMBER_TITLE_REGISTRY_DIRECTORY 改（自证用），会话记录目录可由 MESSAGE_TARGET_PROJECTS_DIRECTORY 改。

MESSAGE_TARGET_BREAK=<开关名> 打开一个弄坏开关（自证专用，钩子里不许设），开关表见 BREAK_SWITCHES。
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
from preflight import load_package_module, preflight  # noqa: E402
BREAK_SWITCH_SELFTEST = load_package_module("break_switch_selftest", "break-switch-selftest.py")
SESSION_TRANSCRIPT = load_package_module("session_transcript", "session-transcript.py")
SESSION_NUMBER_TITLE = load_package_module("session_number_title", "session-number-title.py")

EXIT_PASS = 0
EXIT_UNJUDGED = 1
EXIT_REJECT = 2
BREAK_ENVIRONMENT_VARIABLE = "MESSAGE_TARGET_BREAK"
# 弄坏开关 → 打开后自证必须红在哪个样本上
BREAK_SWITCHES = {
    "dead-process-counts": "进程已经退出的会话拒绝",
    "number-ignored": "标题换过、编号对得上放行",
    "stale-name-passes": "登记里没有的默认名拒绝",
}

REFERENCE_SUFFIX = re.compile(r"\s*\[[0-9A-Za-z]+\]\s*$")
SESSION_ID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")


def break_switch() -> str:
    return os.environ.get(BREAK_ENVIRONMENT_VARIABLE, "")


def projects_directory() -> str:
    override = os.environ.get("MESSAGE_TARGET_PROJECTS_DIRECTORY")
    if override:
        return override
    config_directory = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".claude")
    return os.path.join(config_directory, "projects")


def process_alive(pid) -> bool:
    if break_switch() == "dead-process-counts":
        return True
    return isinstance(pid, int) and pid > 0 and os.path.isdir(f"/proc/{pid}")


def registrations():
    """登记目录里的全部登记；目录读不了是 None。"""
    directory = SESSION_NUMBER_TITLE.registry_directory()
    try:
        names = sorted(os.listdir(directory))
    except OSError:
        return None
    found = []
    for name in names:
        if name.endswith(".json"):
            registration = SESSION_NUMBER_TITLE.read_registration(os.path.join(directory, name))
            if registration is not None:
                found.append(registration)
    return found


def directory_names(all_registrations: list, cwd) -> set:
    """`<目录名>-<编号>` 里可能的目录名：登记里的工作目录名、这次的工作目录名、会话记录目录下各目录名的末段。"""
    names = set()
    for working_directory in [registration.get("cwd") for registration in all_registrations] + [cwd]:
        if isinstance(working_directory, str) and working_directory.strip("/"):
            names.add(os.path.basename(working_directory.rstrip("/")))
    try:
        project_entries = os.listdir(projects_directory())
    except OSError:
        project_entries = []
    for entry in project_entries:
        names.add(entry.rsplit("-", 1)[-1])
    names.discard("")
    return names


def target_number(target: str, known_directories: set):
    """像会话名的对象 → (是不是像会话名, 编号或 None)。"""
    number, _ = SESSION_NUMBER_TITLE.split_title(target)
    if number is not None:
        return True, number
    if SESSION_ID.match(target):
        return True, None
    prefix, separator, suffix = target.rpartition("-")
    if separator and suffix and prefix in known_directories:
        return True, suffix
    return False, None


def live_target(target: str, all_registrations: list, cwd) -> tuple:
    """(要不要拒绝, 对不上时登记里正在跑的会话名单)。"""
    target = REFERENCE_SUFFIX.sub("", target).strip()
    looks_like_session, number = target_number(target, directory_names(all_registrations, cwd))
    if not looks_like_session:
        return False, []
    live = [registration for registration in all_registrations if process_alive(registration.get("pid"))]
    for registration in live:
        name = str(registration.get("name") or "")
        if target == name or target == registration.get("sessionId"):
            return False, []
        if break_switch() == "stale-name-passes" and SESSION_NUMBER_TITLE.split_title(target)[0] is None:
            return False, []
        live_number = SESSION_NUMBER_TITLE.number_in_registration(registration) or SESSION_NUMBER_TITLE.split_title(name)[0]
        if number is not None and live_number == number and break_switch() != "number-ignored":
            return False, []
    return True, sorted(str(registration.get("name") or registration.get("sessionId")) for registration in live)


def judge_hook(hook_text: str) -> int:
    hook_input = SESSION_TRANSCRIPT.hook_input_object(hook_text)
    if hook_input is None:
        print("message-target：钩子输入不是 JSON 对象，这一次没判", file=sys.stderr)
        return EXIT_UNJUDGED
    if hook_input.get("tool_name") != "SendMessage":
        return EXIT_PASS
    tool_input = hook_input.get("tool_input") if isinstance(hook_input.get("tool_input"), dict) else {}
    target = tool_input.get("to")
    if not isinstance(target, str) or not target.strip():
        return EXIT_PASS
    all_registrations = registrations()
    if all_registrations is None:
        print(f"message-target：读不了会话登记目录 {SESSION_NUMBER_TITLE.registry_directory()}，这一次没判对象 {target!r} 还在不在跑", file=sys.stderr)
        return EXIT_UNJUDGED
    reject, live_names = live_target(target, all_registrations, hook_input.get("cwd"))
    if not reject:
        return EXIT_PASS
    print(f"  ✗ 发消息的对象 {target!r} 不是正在跑的会话：本机会话登记里进程还在的会话，没有一个名字、编号或会话 ID 对得上它", file=sys.stderr)
    print(f"     正在跑的会话 {len(live_names)} 个：{'、'.join(live_names) or '（没有）'}", file=sys.stderr)
    print("     → 怎么办：跑 ListAgents，只给它列出来的会话发，名字照它那一行抄；要找的会话不在列表里就是已经停了，"
          "要说的事报给用户（rules/communication-discipline.md「找别的会话，只找正在跑的」），不按会话记录的日期去捞旧会话。", file=sys.stderr)
    return EXIT_REJECT


LIVE = [
    {"pid": "self", "sessionId": "11111111-2222-3333-4444-555555555555", "cwd": "/work/demo", "name": "(85) 门禁优化", "nameSource": "auto"},
    {"pid": "self", "sessionId": "66666666-2222-3333-4444-555555555555", "cwd": "/work/demo", "name": "demo-3f", "nameSource": "derived"},
    {"pid": 0, "sessionId": "77777777-2222-3333-4444-555555555555", "cwd": "/work/demo", "name": "(12) 已经停了", "nameSource": "auto"},
]
# 样本：(样本名, to, 期望拒绝不拒绝)
SELFTEST_CASES = (
    ("正在跑的会话放行", "(85) 门禁优化", False),
    ("带 [ref] 的照样认", "(85) 门禁优化 [4fcd5f]", False),
    ("标题换过、编号对得上放行", "(85) 旧标题", False),
    ("默认名对得上放行", "demo-3f", False),
    ("会话 ID 对得上放行", "11111111-2222-3333-4444-555555555555", False),
    ("进程已经退出的会话拒绝", "(12) 已经停了", True),
    ("登记里没有的会话拒绝", "(77) 三天前的任务", True),
    ("登记里没有的默认名拒绝", "demo-9a", True),
    ("登记里没有的会话 ID 拒绝", "88888888-2222-3333-4444-555555555555", True),
    ("子 agent 名不判", "researcher", False),
    ("main 不判", "main", False),
)


def selftest_registrations() -> list:
    own = os.getpid()
    return [dict(registration, pid=own if registration["pid"] == "self" else registration["pid"]) for registration in LIVE]


def run_selftest_cases() -> list:
    misjudged_cases = []
    for case_name, target, expected in SELFTEST_CASES:
        actual, _ = live_target(target, selftest_registrations(), "/work/demo")
        if actual != expected:
            misjudged_cases.append((case_name, "拒绝" if expected else "放行", "拒绝" if actual else "放行"))
    return misjudged_cases


HOOK_PATH_COUNT = 5


def run_hook_cases() -> list:
    """整条钩子路径：JSON 进，退出码出。"""
    misjudged_cases = []
    with tempfile.TemporaryDirectory() as scratch_directory:
        registry = os.path.join(scratch_directory, "sessions")
        os.makedirs(registry)
        for index, registration in enumerate(selftest_registrations()):
            with open(os.path.join(registry, f"{index}.json"), "w", encoding="utf-8") as handle:
                json.dump(registration, handle, ensure_ascii=False)
        environment = dict(os.environ, SESSION_NUMBER_TITLE_REGISTRY_DIRECTORY=registry,
                           MESSAGE_TARGET_PROJECTS_DIRECTORY=os.path.join(scratch_directory, "projects"))
        environment.pop(BREAK_ENVIRONMENT_VARIABLE, None)

        def expect(case_name: str, hook_text: str, expected_exit: int, environment_used=environment):
            hook_run = subprocess.run([sys.executable, os.path.abspath(__file__), "--hook"], input=hook_text,
                                      capture_output=True, text=True, check=False, env=environment_used)
            if hook_run.returncode != expected_exit:
                misjudged_cases.append((case_name, expected_exit, hook_run.returncode))

        def send(target: str) -> str:
            return json.dumps({"hook_event_name": "PreToolUse", "tool_name": "SendMessage", "cwd": "/work/demo",
                               "tool_input": {"to": target, "message": "x"}}, ensure_ascii=False)

        expect("钩子：正在跑的会话放行", send("(85) 门禁优化 [4fcd5f]"), EXIT_PASS)
        expect("钩子：停了的会话拒绝", send("(12) 已经停了"), EXIT_REJECT)
        expect("钩子：别的工具不判", json.dumps({"tool_name": "Agent", "tool_input": {"prompt": "x"}}), EXIT_PASS)
        expect("钩子：输入不是 JSON 对象判不了", "[1]", EXIT_UNJUDGED)
        expect("钩子：登记目录读不了判不了", send("(12) 已经停了"), EXIT_UNJUDGED,
               dict(environment, SESSION_NUMBER_TITLE_REGISTRY_DIRECTORY=os.path.join(scratch_directory, "missing")))
    return misjudged_cases


def selftest() -> int:
    misjudged_cases = run_selftest_cases()
    if not break_switch():
        misjudged_cases += run_hook_cases()
    exit_code = BREAK_SWITCH_SELFTEST.finish_selftest(__file__, BREAK_ENVIRONMENT_VARIABLE, BREAK_SWITCHES, misjudged_cases,
                                                      len(SELFTEST_CASES), "live_target / judge_hook")
    if exit_code is not None:
        return exit_code
    print(f"  ✓ message-target 自证：{len(SELFTEST_CASES)} 个样本与 {HOOK_PATH_COUNT} 条钩子路径判得对；"
          f"{len(BREAK_SWITCHES)} 个弄坏开关逐个打开，各自红在点名的样本上")
    return 0


def main(arguments: list) -> int:
    if arguments == ["--hook"]:
        return judge_hook(sys.stdin.read())
    if arguments == ["--selftest"]:
        return selftest()
    print("  ✗ 用法：message-target.py --hook（从标准输入读钩子 JSON），或 message-target.py --selftest")
    print("     → 怎么办：钩子里由 scripts/claude-hooks/message-target-guard.sh 起它；改了这份脚本先跑 --selftest。")
    return 2


if __name__ == "__main__":
    preflight(__file__)
    sys.exit(main(sys.argv[1:]))
