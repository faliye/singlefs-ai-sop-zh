#!/usr/bin/env python3
# gate-similar: session-number-title.py 同挂 SessionStart，但它只改会话标题、不往上下文里补东西，也不跑项目的检查项；两份读的输入一样、产出与协议都不同
# gate-similar: discarded-output-count-check.sh 同样只记不拦、往检出记录追加一行，但它挂 PostToolUse、判一条 Bash 命令；这一道挂 SessionStart、跑项目登记的检查项
# gate-similar: hooks-registered.sh 检查项登记得对不对、自证过不过由它调这一份的 --check-items 判，判法只在这一份里
# gate-overlap:copy-kept courtesy-phrase.py 相同的是载入共用库与退出码常量那几段；每份 python 钩子判定各带一份，读钩子输入已经抽进 session-transcript.py
# gate-overlap:copy-kept unanswered-message.py 相同的是载入共用库与退出码常量那几段，理由同 courtesy-phrase.py 那一行
# gate-overlap:copy-kept message-target.py 相同的是载入共用库与退出码常量那几段，理由同 courtesy-phrase.py 那一行
# admission: always Claude Code 在每一次会话启动、恢复、清空与压缩之后调它，检查项要现跑
# run-condition: none 只读钩子从标准输入给的 JSON、项目的检查项目录与 git，起项目登记的检查项，只用 python 标准库
"""会话启动、恢复、清空与压缩之后的检测（rules/communication-discipline.md「会话启动与压缩之后的检测」）。

用法：
    session-checks.py --hook                   # 从标准输入读 Claude Code 的 SessionStart 钩子 JSON，往标准输出写要补进上下文的提示
    session-checks.py --check-items [项目根]    # 门禁用：项目登记的检查项文件头写对没有、各自的 --selftest 过没过（hooks-registered.sh 调它）
    session-checks.py --selftest               # 自证：内嵌样本与整条钩子路径；再逐个打开弄坏开关另起子进程跑自证

钩子做两件，只报不改：
  compact 之后：先补一段对齐提示，用本包的语言（I18N 的 this=）写，第一条就是「对话与产出用<本包的语言>」；
    其余几条是分支与未提交的路径数、派出过的子 agent 先看还在不在跑、接续的状态以记录为准。
  每种 source：跑项目登记的检查项（检查项目录，默认 <项目根>/.claude/session-checks/，SESSION_CHECKS_DIRECTORY 可改），
    只跑文件头 `# session-check-sources:` 里列了这一次 source 的；标准输入给钩子的 JSON，工作目录是项目根，
    跑不过文件头 `# session-check-timeout: <秒>` 就杀掉。退 0 且有输出的，输出拼进上下文，前面一行「【<项名>】」；退 0 没输出的不补。
检查项：检查项目录下每个不以 . 起头、不是 .md 的普通文件算一项，项名是文件名。文件头要有两行：
  `# session-check-sources: <startup resume clear compact 里的几个>`、`# session-check-timeout: <1 到 TIMEOUT_MAXIMUM_SECONDS 的整数>`；
  要有执行位，带 `--selftest` 时自证要过（--check-items 判）。
没查成也照常放行：检查项退非 0、超时、起不来、文件头写错，钩子输入解不开，补提示时抛异常，都退 0，
  上下文里（输入解不开时是 stderr）写一行「没查成」与原因，检出记录追加一行。
检出记录：TSV 六列：日期、session_id、source、项名（钩子自己的是 -）、结局（没查成）、原因。
  路径取 SESSION_CHECKS_RECORD，没设就是 ${TMPDIR:-/tmp}/session-checks/records.tsv。
退出码：--hook 恒 0（准入与运行条件不满足 78）；--check-items 判过了 0、判红 1、没有检查项目录 77。

够不着的：检查项的输出说得对不对、用的是不是对话的语言，它不判；检查项自己的 --selftest 证不证得到它会报，靠写检查项的人。

SESSION_CHECKS_BREAK=<开关名> 打开一个弄坏开关（自证专用，钩子里不许设），开关表见 BREAK_SWITCHES。
"""
from __future__ import annotations

import datetime
import json
import os
import re
import stat
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
from preflight import load_package_module, preflight  # noqa: E402
BREAK_SWITCH_SELFTEST = load_package_module("break_switch_selftest", "break-switch-selftest.py")
SESSION_TRANSCRIPT = load_package_module("session_transcript", "session-transcript.py")
PACKAGE_FAMILY = load_package_module("package_family", "package-family.py")

EXIT_PASS = 0
EXIT_RED = 1
EXIT_NO_OBJECT = 77
BREAK_ENVIRONMENT_VARIABLE = "SESSION_CHECKS_BREAK"
# 弄坏开关 → 打开后自证必须红在哪个样本上
BREAK_SWITCHES = {
    "failure-dropped": "检查项退非 0 报没查成",
    "source-ignored": "source 没列的检查项不跑",
    "language-fixed": "压缩提示用本包的语言（en）",
    "unrecorded": "没查成的记一条检出",
    "header-unchecked": "门禁：文件头没写超时判红",
}

SOURCES = ("startup", "resume", "clear", "compact")
TIMEOUT_MAXIMUM_SECONDS = 120
ITEM_SELFTEST_TIMEOUT_SECONDS = 300
HEADER_LINES_READ = 40
SOURCES_HEADER = re.compile(r"^#\s*session-check-sources:\s*(.*?)\s*$")
TIMEOUT_HEADER = re.compile(r"^#\s*session-check-timeout:\s*(.*?)\s*$")
OUTPUT_MAXIMUM_CHARACTERS = 4000

# 压缩之后的对齐提示，按本包的语言取；三个语言仓拷的是同一份脚本，所以三种都在这里
COMPACT_TEXT = {
    "zh": {
        "head": "【上下文刚压缩过，接着干活之前先对齐这几件】",
        "language": "- 对话与产出一律用中文（本包的语言）；压缩之前用的若是别的语言，从这一条回复起改回中文。",
        "branch": "- 分支 {branch}；工作区未提交 {count} 个路径：`git status --short` 看清哪些是这一轮的，别的会话的不碰。",
        "agents": "- 派出过子 agent 的，先用 `ListAgents` 看还有没有在跑，不重派还在跑的那一件。",
        "state": "- 接续的状态以记录与文件为准，不凭压缩摘要里的印象。",
        "unread": "（读不出）",
        "failed": "检查项 {name} 没查成：{reason}；这一次照常放行，检出记录记了一行。",
        "hook_failed": "session-checks 没查成：{reason}；这一次照常放行。",
    },
    "en": {
        "head": "[The context was just compacted; line these up before carrying on]",
        "language": "- Converse and write in English (this package's language); if the conversation before the compaction drifted into another language, switch back to English from this reply on.",
        "branch": "- Branch {branch}; {count} uncommitted paths in the working tree: check `git status --short` for which are this task's, and leave other sessions' alone.",
        "agents": "- If you dispatched subagents, check with `ListAgents` whether any are still running; do not dispatch again one that still runs.",
        "state": "- Take the state to resume from the records and files, not from impressions in the compaction summary.",
        "unread": "(unreadable)",
        "failed": "Check {name} did not run: {reason}; the session goes on as usual, and one line was added to the detection record.",
        "hook_failed": "session-checks did not run: {reason}; the session goes on as usual.",
    },
    "ja": {
        "head": "【コンテキストが圧縮されたところです。作業を続ける前に次の点を揃える】",
        "language": "- 対話と成果物は日本語（本パッケージの言語）で書く。圧縮の前に別の言語になっていたら、この返答から日本語に戻す。",
        "branch": "- ブランチ {branch}。作業ツリーの未コミットのパスは {count} 個：`git status --short` でどれがこの作業のものか確かめ、ほかのセッションのものには触れない。",
        "agents": "- サブエージェントを出していたら、まだ動いているものがあるか `ListAgents` で見る。動いているものは出し直さない。",
        "state": "- 続きの状態は記録とファイルで確かめ、圧縮の要約の印象で判断しない。",
        "unread": "（読めない）",
        "failed": "検査項目 {name} は実行できなかった：{reason}。今回はそのまま通し、検出記録に一行残した。",
        "hook_failed": "session-checks は実行できなかった：{reason}。今回はそのまま通す。",
    },
}


def break_switch() -> str:
    return os.environ.get(BREAK_ENVIRONMENT_VARIABLE, "")


def texts(language: str) -> dict:
    if break_switch() == "language-fixed":
        language = "zh"
    return COMPACT_TEXT.get(language, COMPACT_TEXT["zh"])


def git_output(project_root: str, *arguments):
    try:
        completed = subprocess.run(["git", "-C", project_root, *arguments], capture_output=True, text=True, timeout=10, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return completed.stdout if completed.returncode == 0 else None


def compact_reminder(project_root: str, language: str) -> str:
    text = texts(language)
    branch = (git_output(project_root, "branch", "--show-current") or "").strip() or text["unread"]
    status = git_output(project_root, "status", "--porcelain")
    count = len([line for line in status.splitlines() if line.strip()]) if status is not None else text["unread"]
    return "\n".join([text["head"], text["language"], text["branch"].format(branch=branch, count=count), text["agents"], text["state"]])


def checks_directory(project_root: str) -> str:
    return os.environ.get("SESSION_CHECKS_DIRECTORY") or os.path.join(project_root, ".claude", "session-checks")


def check_items(directory: str) -> list:
    """检查项目录下的各项（按文件名排）；目录不在是空表。"""
    try:
        names = sorted(os.listdir(directory))
    except OSError:
        return []
    return [os.path.join(directory, name) for name in names
            if not name.startswith(".") and not name.endswith(".md") and os.path.isfile(os.path.join(directory, name))]


def item_header(path: str):
    """(sources, timeout, 错在哪)：文件头写对了第三样是 None。"""
    sources = timeout = None
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            for _, line in zip(range(HEADER_LINES_READ), handle):
                sources_match = SOURCES_HEADER.match(line)
                timeout_match = TIMEOUT_HEADER.match(line)
                if sources_match and sources is None:
                    sources = sources_match.group(1).split()
                if timeout_match and timeout is None:
                    timeout = timeout_match.group(1)
    except OSError as error:
        return None, None, f"读不了（{error}）"
    if not sources:
        return None, None, "文件头没写 # session-check-sources: <startup resume clear compact 里的几个>"
    unknown = [source for source in sources if source not in SOURCES]
    if unknown:
        return None, None, f"# session-check-sources: 里有不认得的 source：{' '.join(unknown)}（只认 {' '.join(SOURCES)}）"
    if timeout is None and break_switch() == "header-unchecked":
        timeout = "10"
    if timeout is None or not timeout.isdigit() or not 1 <= int(timeout) <= TIMEOUT_MAXIMUM_SECONDS:
        return None, None, f"文件头没写对 # session-check-timeout: <1 到 {TIMEOUT_MAXIMUM_SECONDS} 的整数秒>"
    if not os.access(path, os.X_OK):
        return None, None, "没有执行位（chmod +x）"
    return sources, int(timeout), None


def run_item(path: str, source: str, hook_text: str, project_root: str):
    """(要补的输出, 没查成的原因)；这一次 source 不跑的返回 (None, None)。"""
    sources, timeout, header_error = item_header(path)
    if header_error is not None:
        return None, header_error
    if source not in sources and break_switch() != "source-ignored":
        return None, None
    try:
        completed = subprocess.run([path], input=hook_text, capture_output=True, text=True, timeout=timeout, cwd=project_root, check=False)
    except subprocess.TimeoutExpired:
        return None, f"过了 {timeout} 秒没跑完，杀掉了"
    except OSError as error:
        return None, f"起不来（{error}）"
    if completed.returncode != 0 and break_switch() != "failure-dropped":
        last_line = (completed.stderr.strip().splitlines() or [""])[-1][:200]
        return None, f"退出码 {completed.returncode}" + (f"：{last_line}" if last_line else "")
    output = completed.stdout.strip()
    return (output[:OUTPUT_MAXIMUM_CHARACTERS] or None), None


def record_path() -> str:
    return os.environ.get("SESSION_CHECKS_RECORD") or os.path.join(os.environ.get("TMPDIR") or "/tmp", "session-checks", "records.tsv")


def record(session_id, source, item_name: str, reason: str) -> None:
    if break_switch() == "unrecorded":
        return
    fields = [datetime.date.today().isoformat(), re.sub(r"[^A-Za-z0-9_-]", "_", str(session_id or "")) or "no-session",
              str(source or "-"), item_name, "没查成", re.sub(r"[\t\r\n]", " ", reason)]
    try:
        os.makedirs(os.path.dirname(record_path()), exist_ok=True)
        with open(record_path(), "a", encoding="utf-8") as handle:
            handle.write("\t".join(fields) + "\n")
    except OSError as error:
        print(f"session-checks：检出记录写不进 {record_path()}（{error}），这一次没记下", file=sys.stderr)


def session_context(hook_input: dict, hook_text: str, project_root: str, language: str) -> str:
    source = hook_input.get("source")
    text = texts(language)
    parts = []
    if source == "compact":
        parts.append(compact_reminder(project_root, language))
    for path in check_items(checks_directory(project_root)):
        name = os.path.basename(path)
        output, reason = run_item(path, source, hook_text, project_root)
        if reason is not None:
            record(hook_input.get("session_id"), source, name, reason)
            parts.append(text["failed"].format(name=name, reason=reason))
        elif output:
            parts.append(f"【{name}】\n{output}")
    return "\n\n".join(parts)


def judge_hook(hook_text: str) -> int:
    language = PACKAGE_FAMILY.package_language()
    hook_input = SESSION_TRANSCRIPT.hook_input_object(hook_text)
    if hook_input is None:
        reason = "钩子输入不是 JSON 对象"
        record(None, None, "-", reason)
        print(texts(language)["hook_failed"].format(reason=reason), file=sys.stderr)
        return EXIT_PASS
    project_root = os.environ.get("CLAUDE_PROJECT_DIR") or hook_input.get("cwd") or os.getcwd()
    try:
        context = session_context(hook_input, hook_text, project_root, language)
    except Exception as error:  # noqa: BLE001 —— 补提示时出什么错都照常放行、记一条
        reason = f"补提示时出错（{type(error).__name__}: {error}）"
        record(hook_input.get("session_id"), hook_input.get("source"), "-", reason)
        print(texts(language)["hook_failed"].format(reason=reason), file=sys.stderr)
        return EXIT_PASS
    if context:
        print(context)
    return EXIT_PASS


def check_items_for_gate(project_root: str) -> int:
    directory = checks_directory(project_root)
    if not os.path.isdir(directory):
        print(f"  ! 项目没有检查项目录 {directory}，这一项无对象可判（这不是通过）")
        return EXIT_NO_OBJECT
    items = check_items(directory)
    problems = []
    selftested = 0
    for path in items:
        _, _, header_error = item_header(path)
        if header_error is not None:
            problems.append((os.path.basename(path), header_error))
            continue
        if not _mentions_selftest(path):
            continue
        selftested += 1
        try:
            completed = subprocess.run([path, "--selftest"], capture_output=True, text=True, timeout=ITEM_SELFTEST_TIMEOUT_SECONDS,
                                       cwd=project_root, check=False)
        except subprocess.TimeoutExpired:
            problems.append((os.path.basename(path), f"--selftest 过了 {ITEM_SELFTEST_TIMEOUT_SECONDS} 秒没跑完"))
            continue
        except OSError as error:
            problems.append((os.path.basename(path), f"--selftest 起不来（{error}）"))
            continue
        if completed.returncode != 0:
            tail = "\n".join((completed.stdout + completed.stderr).strip().splitlines()[-5:])
            problems.append((os.path.basename(path), f"--selftest 退 {completed.returncode}：{tail}"))
    if problems:
        print(f"  ✗ 会话检查项有 {len(problems)} 项不对（{directory}，共 {len(items)} 项）：")
        for name, problem in problems:
            print(f"        {name}：{problem}")  # gate-lint:detail
        print(f"     → 怎么办：每一项文件头写 # session-check-sources: <{' '.join(SOURCES)} 里的几个> 与 "
              f"# session-check-timeout: <1 到 {TIMEOUT_MAXIMUM_SECONDS} 的整数秒>，加执行位；带 --selftest 的自证要过，"
              "单跑 <检查项> --selftest 看它为什么红（rules/communication-discipline.md「会话启动与压缩之后的检测」）。")
        return EXIT_RED
    without_selftest = [os.path.basename(path) for path in items if not _mentions_selftest(path)]
    print(f"  ✓ 会话检查项 {len(items)} 项文件头都写对了，其中 {selftested} 项的 --selftest 过了；"
          f"没带自证的 {len(without_selftest)} 项：{'、'.join(without_selftest) or '（没有）'}")
    return EXIT_PASS


def _mentions_selftest(path: str) -> bool:
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            return "--selftest" in handle.read()
    except OSError:
        return False


def write_item(directory: str, name: str, body: str, sources="startup resume", timeout="5", executable=True) -> None:
    path = os.path.join(directory, name)
    header = "#!/usr/bin/env bash\n"
    if sources is not None:
        header += f"# session-check-sources: {sources}\n"
    if timeout is not None:
        header += f"# session-check-timeout: {timeout}\n"
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(header + body + "\n")
    os.chmod(path, os.stat(path).st_mode | (stat.S_IXUSR if executable else 0))


def run_selftest_cases() -> list:
    """检查项分派、压缩提示的语言、没查成的记录、门禁的 --check-items。"""
    misjudged_cases = []

    def expect(case_name: str, condition: bool, detail: str):
        if not condition:
            misjudged_cases.append((case_name, "成立", detail))

    with tempfile.TemporaryDirectory() as scratch:
        project = os.path.join(scratch, "project")
        items = os.path.join(project, ".claude", "session-checks")
        os.makedirs(items)
        subprocess.run(["git", "init", "-q", project], check=False, capture_output=True)
        write_item(items, "report", 'echo "近 12 小时有 1 次内存不够"')
        write_item(items, "quiet", "exit 0")
        write_item(items, "broken", 'echo "读不了日志" >&2; exit 3')
        write_item(items, "compact-only", 'echo "压缩之后才跑"', sources="compact")
        write_item(items, "README.md", "说明", sources=None, timeout=None)
        record_file = os.path.join(scratch, "records.tsv")
        os.environ["SESSION_CHECKS_RECORD"] = record_file
        os.environ.pop("SESSION_CHECKS_DIRECTORY", None)

        def context(source: str, language: str = "zh") -> str:
            return session_context({"source": source, "session_id": "s1"}, "{}", project, language)

        startup = context("startup")
        expect("有输出的检查项拼进上下文", "【report】\n近 12 小时有 1 次内存不够" in startup, startup)
        expect("没输出的检查项不补", "【quiet】" not in startup, startup)
        expect("检查项退非 0 报没查成", "检查项 broken 没查成：退出码 3：读不了日志" in startup, startup)
        expect("source 没列的检查项不跑", "压缩之后才跑" not in startup, startup)
        expect("说明文件不算检查项", "README.md" not in startup, startup)
        expect("startup 不补压缩提示", "上下文刚压缩过" not in startup, startup)
        try:
            with open(record_file, encoding="utf-8") as handle:
                recorded = handle.read()
        except OSError:
            recorded = ""
        expect("没查成的记一条检出", "\tstartup\tbroken\t没查成\t" in recorded, recorded or "（没记）")
        compact = context("compact")
        expect("压缩之后补对齐提示、头一条是对话语言", "上下文刚压缩过" in compact and "对话与产出一律用中文" in compact, compact)
        expect("压缩之后也跑列了 compact 的项", "【compact-only】" in compact, compact)
        english = context("compact", "en")
        expect("压缩提示用本包的语言（en）", "Converse and write in English" in english, english)
        japanese = context("compact", "ja")
        expect("压缩提示用本包的语言（ja）", "日本語（本パッケージの言語）" in japanese, japanese)

        write_item(items, "slow", "sleep 5", timeout="1")
        slow = context("startup")
        expect("超时的检查项杀掉、报没查成", "检查项 slow 没查成：过了 1 秒没跑完" in slow, slow)
        os.remove(os.path.join(items, "slow"))
        write_item(items, "no-timeout", "exit 0", timeout=None)
        no_timeout = context("startup")
        expect("文件头没写超时报没查成", "检查项 no-timeout 没查成：文件头没写对 # session-check-timeout" in no_timeout, no_timeout)

        gate_output = subprocess.run([sys.executable, os.path.abspath(__file__), "--check-items", project], capture_output=True, text=True,
                                     check=False, env=dict(os.environ))
        expect("门禁：文件头没写超时判红", gate_output.returncode == EXIT_RED and "no-timeout：文件头没写对" in gate_output.stdout,
               f"{gate_output.returncode} {gate_output.stdout.strip()[-200:]}")
        os.remove(os.path.join(items, "no-timeout"))
        write_item(items, "with-selftest", '[[ "${1:-}" == --selftest ]] && { echo "自证没过"; exit 1; }; exit 0')
        failing_selftest = subprocess.run([sys.executable, os.path.abspath(__file__), "--check-items", project], capture_output=True, text=True,
                                          check=False, env=dict(os.environ))
        expect("门禁：检查项的自证没过判红", failing_selftest.returncode == EXIT_RED and "with-selftest：--selftest 退 1" in failing_selftest.stdout,
               f"{failing_selftest.returncode} {failing_selftest.stdout.strip()[-200:]}")
        write_item(items, "with-selftest", '[[ "${1:-}" == --selftest ]] && { echo "自证：查了 2 种"; exit 0; }; exit 0')
        os.remove(os.path.join(items, "broken"))
        passing = subprocess.run([sys.executable, os.path.abspath(__file__), "--check-items", project], capture_output=True, text=True,
                                 check=False, env=dict(os.environ))
        expect("门禁：都写对、自证都过放行", passing.returncode == EXIT_PASS and "其中 1 项的 --selftest 过了" in passing.stdout,
               f"{passing.returncode} {passing.stdout.strip()[-200:]}")
        os.environ.pop("SESSION_CHECKS_RECORD", None)
    return misjudged_cases


SELFTEST_CASE_COUNT = 16
HOOK_PATH_COUNT = 3


def run_hook_cases() -> list:
    """整条钩子路径：JSON 进，退出码、标准输出与检出记录出。"""
    misjudged_cases = []
    with tempfile.TemporaryDirectory() as scratch:
        items = os.path.join(scratch, ".claude", "session-checks")
        os.makedirs(items)
        write_item(items, "report", 'echo "有一件要看"')
        record_file = os.path.join(scratch, "records.tsv")
        environment = dict(os.environ, CLAUDE_PROJECT_DIR=scratch, SESSION_CHECKS_RECORD=record_file)
        environment.pop(BREAK_ENVIRONMENT_VARIABLE, None)
        environment.pop("SESSION_CHECKS_DIRECTORY", None)

        def run(hook_text: str):
            return subprocess.run([sys.executable, os.path.abspath(__file__), "--hook"], input=hook_text, capture_output=True,
                                  text=True, check=False, env=environment)

        started = run(json.dumps({"hook_event_name": "SessionStart", "source": "startup", "session_id": "s"}))
        if started.returncode != 0 or "【report】\n有一件要看" not in started.stdout:
            misjudged_cases.append(("钩子：启动时跑检查项", "0 与 【report】", f"{started.returncode} {started.stdout.strip()}"))
        broken = run("[1, 2]")
        try:
            with open(record_file, encoding="utf-8") as handle:
                recorded = handle.read()
        except OSError:
            recorded = ""
        if broken.returncode != 0 or "钩子输入不是 JSON 对象" not in recorded:
            misjudged_cases.append(("钩子：输入解不开照常放行、记一条", "0 与一行检出", f"{broken.returncode} {recorded.strip()}"))
        cleared = run(json.dumps({"hook_event_name": "SessionStart", "source": "clear", "session_id": "s"}))
        if cleared.returncode != 0 or cleared.stdout.strip():
            misjudged_cases.append(("钩子：source 没列的不补", "0 与空输出", f"{cleared.returncode} {cleared.stdout.strip()}"))
    return misjudged_cases


def selftest() -> int:
    misjudged_cases = run_selftest_cases()
    if not break_switch():
        misjudged_cases += run_hook_cases()
    exit_code = BREAK_SWITCH_SELFTEST.finish_selftest(__file__, BREAK_ENVIRONMENT_VARIABLE, BREAK_SWITCHES, misjudged_cases,
                                                      SELFTEST_CASE_COUNT, "session_context / run_item / item_header / check_items_for_gate")
    if exit_code is not None:
        return exit_code
    print(f"  ✓ session-checks 自证：{SELFTEST_CASE_COUNT} 个样本与 {HOOK_PATH_COUNT} 条钩子路径判得对；"
          f"{len(BREAK_SWITCHES)} 个弄坏开关逐个打开，各自红在点名的样本上")
    return 0


def main(arguments: list) -> int:
    if arguments == ["--hook"]:
        return judge_hook(sys.stdin.read())
    if arguments == ["--selftest"]:
        return selftest()
    if arguments[:1] == ["--check-items"] and len(arguments) <= 2:
        return check_items_for_gate(os.path.abspath(arguments[1] if len(arguments) == 2 else "."))
    print("  ✗ 用法：session-checks.py --hook | --check-items [项目根] | --selftest")
    print("     → 怎么办：钩子里由 scripts/claude-hooks/session-checks.sh 起它；门禁由 hooks-registered.sh 起 --check-items；改了这份脚本先跑 --selftest。")
    return 2


if __name__ == "__main__":
    preflight(__file__)
    sys.exit(main(sys.argv[1:]))
