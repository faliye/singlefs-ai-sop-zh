#!/usr/bin/env python3
# gate-similar: root-entries.py 同样是给 Claude Code 钩子做判定的 python，但判写文件与 Bash 在项目根下建了什么；这一道判派发提示与转述里的借用句，对象与判法都不同
# gate-similar: code-name-lint.py 它判进仓的 .md 新行里有没有拿代号指东西；这一道判的是还没进仓的派发提示与跨会话消息，输入是钩子的 JSON，不是 diff
# gate-similar: pattern-process-guard.sh 同挂 PreToolUse，但它判 Bash 命令里按模式找进程的写法，工具与对象都不同
# admission: always Claude Code 在每一次派子 agent、给别的会话发消息之前调它，每一次都要现判
# run-condition: none 只读钩子从标准输入给的 JSON、只用 python 标准库，不碰文件与网络
"""派给子 agent 的提示、发给别的会话的消息里，借用别处口径的句子要带出处：同一句里有 `路径:行号`，或者原文引用。

「与 X 同口径」「照 X 那一份」「同 X」这类话，是写的人凭印象把 X 的做法转述给对方；X 实际怎么做的，对方看不到，
转述错了对方就照着错的做（rules/verify-before-claiming.md「转述别处的做法，带出处或原文」）。

用法：
    borrowed-convention.py --hook       # 从标准输入读 Claude Code PreToolUse 钩子的 JSON（Agent / Task 的 prompt、SendMessage 的 message）
    borrowed-convention.py --selftest   # 自证：内嵌红绿样本逐个判；再逐个打开弄坏开关另起子进程跑自证，每一个都必须红在开关表点名的样本上

判据：按「。」「；」「！」「？」与换行切成句子；一句里有借用说法（BORROW_PHRASES），而同一句里既没有 `路径:行号`
  （或路径、「同文件」加「第 N 行」）、
  也没有原文引用（「」或 "" 里至少 MINIMUM_QUOTE_CHARACTERS 个字，或以 `>` 起头的引用行），也没有「路径 + 反引号里的函数名或标题」⇒ 拒绝。
  围栏（```）里的不判。
退出码：拒绝 2（Claude Code 不派这一次，把 stderr 交给 agent）；放行 0；判不了 1（Claude Code 照常执行，stderr 留一行原因）。

够不着的（不判，不等于通过）：借用说法不在 BORROW_PHRASES 里的（「跟那边一样」「老规矩」）；带了出处、但出处指错了或原文抄错了的；
  派发之外的转述（写进文件、提交说明）；对方读没读那个出处。

BORROWED_CONVENTION_BREAK=<开关名> 打开一个弄坏开关（自证专用，钩子里不许设），开关表见 BREAK_SWITCHES。
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
from preflight import load_package_module, preflight  # noqa: E402
BREAK_SWITCH_SELFTEST = load_package_module("break_switch_selftest", "break-switch-selftest.py")

EXIT_PASS = 0
EXIT_NOT_JUDGED = 1
EXIT_BLOCKED = 2
MINIMUM_QUOTE_CHARACTERS = 6
JUDGED_TEXT_FIELDS = {"Agent": "prompt", "Task": "prompt", "SendMessage": "message"}
BREAK_ENVIRONMENT_VARIABLE = "BORROWED_CONVENTION_BREAK"
# 弄坏开关 → 打开后自证必须红在哪个样本上
BREAK_SWITCHES = {
    "line-reference-ignored": "带路径与行号放行",
    "quote-ignored": "带原文引用放行",
    "fences-read": "围栏里的借用句放行",
    "whole-text-evidence": "出处在别的句子里照样拒",
}

BORROW_PHRASES = re.compile(
    r"同一?口径|口径(?:相同|一致|一样)"
    r"|照(?:着)?(?!你|自己|现在|原样)[^。；！？\n]{1,40}?(?:那一份|那份|那一套|那套|那一版|那版|的做法|的写法|的取法|的算法)"
    r"|(?:与|和|跟)[^。；！？\n]{1,40}?(?:同一个做法|同样的做法|一样的做法|同一种写法|一样的写法)"
    r"|(?<![相共不如等大连一合协])同\s*`[^`]{1,60}`"
)
LINE_REFERENCE = re.compile(r"[\w.@/-]+\.[A-Za-z0-9]+:[0-9]+|[\w.@-]*/[\w.@/-]+:[0-9]+")
QUOTED_ORIGINAL = re.compile(rf"「[^」]{{{MINIMUM_QUOTE_CHARACTERS},}}」|\"[^\"]{{{MINIMUM_QUOTE_CHARACTERS + 2},}}\"|“[^”]{{{MINIMUM_QUOTE_CHARACTERS},}}”")
BLOCK_QUOTE_LINE = re.compile(r"^\s*>")
CHINESE_LINE_NUMBER = re.compile(r"第\s*[0-9]+(?:\s*[–—-]\s*[0-9]+)?\s*行")
SAME_FILE = re.compile(r"同(?:一个?)?文件")
FILE_PATH = re.compile(r"[\w.@-]*/[\w.@/-]+\.[A-Za-z0-9]+|[\w.@-]+\.(?:py|sh|rs|md|toml|json|yaml|yml|tsv)\b")
BACKTICK_ANCHOR = re.compile(r"`[A-Za-z_][\w.:]*(?:\(\))?`|「[^」]{2,}」")
SENTENCE_SPLIT = re.compile(r"(?<=[。；！？\n])")
FENCE_LINE = re.compile(r"^\s*(```|~~~)")

REMEDY = (
    "这一句说「照别处的做法办」，却没给出别处到底怎么做：对方看到的只是你的转述，转述错了它就照错的做。"
    "改法（任选一样，写在同一句里）：写出 `路径:行号` 让它自己去读；或把那一处的原文用「」引进来；"
    "或写出路径加反引号里的函数名、或「」里的标题。拿不准原文是什么，先自己读一遍再派"
    "（rules/verify-before-claiming.md「转述别处的做法，带出处或原文」）。"
)


def break_switch() -> str:
    return os.environ.get(BREAK_ENVIRONMENT_VARIABLE, "")


def has_evidence(sentence: str, whole_text: str) -> bool:
    judged_text = whole_text if break_switch() == "whole-text-evidence" else sentence
    if break_switch() != "line-reference-ignored" and LINE_REFERENCE.search(judged_text):
        return True
    if break_switch() != "line-reference-ignored" and CHINESE_LINE_NUMBER.search(judged_text) \
            and (FILE_PATH.search(judged_text) or SAME_FILE.search(judged_text)):
        return True
    if break_switch() != "quote-ignored" and (QUOTED_ORIGINAL.search(judged_text) or BLOCK_QUOTE_LINE.search(judged_text)):
        return True
    return bool(FILE_PATH.search(judged_text) and BACKTICK_ANCHOR.search(judged_text))


def unfenced_text(text: str) -> str:
    if break_switch() == "fences-read":
        return text
    kept_lines = []
    inside_fence = False
    for line_text in text.split("\n"):
        if FENCE_LINE.match(line_text):
            inside_fence = not inside_fence
            continue
        if not inside_fence:
            kept_lines.append(line_text)
    return "\n".join(kept_lines)


def unsupported_borrow_sentences(text: str) -> list:
    judged_text = unfenced_text(text)
    sentences = SENTENCE_SPLIT.split(judged_text)
    unsupported = []
    for sentence_index, sentence in enumerate(sentences):
        if not BORROW_PHRASES.search(sentence) or has_evidence(sentence, judged_text):
            continue
        # 以冒号收尾、下一行是 `>` 引用行的，原文就在紧跟着的那一行
        following_sentence = sentences[sentence_index + 1] if sentence_index + 1 < len(sentences) else ""
        if sentence.rstrip().endswith(("：", ":")) and BLOCK_QUOTE_LINE.match(following_sentence) and break_switch() != "quote-ignored":
            continue
        unsupported.append(sentence.strip())
    return unsupported


def judge_hook(hook_text: str) -> int:
    try:
        hook_input = json.loads(hook_text)
    except ValueError:
        hook_input = None
    if not isinstance(hook_input, dict):
        print("borrowed-convention：钩子输入不是 JSON 对象，这一次没判", file=sys.stderr)
        return EXIT_NOT_JUDGED
    tool_name = hook_input.get("tool_name", "")
    field_name = JUDGED_TEXT_FIELDS.get(tool_name)
    tool_input = hook_input.get("tool_input")
    if field_name is None or not isinstance(tool_input, dict):
        return EXIT_PASS
    judged_text = tool_input.get(field_name)
    if not isinstance(judged_text, str):
        return EXIT_PASS
    unsupported = unsupported_borrow_sentences(judged_text)
    if not unsupported:
        return EXIT_PASS
    print(f"✗ {tool_name} 的 {field_name} 里有 {len(unsupported)} 句借用别处的做法，同一句里没有出处或原文：", file=sys.stderr)
    for sentence in unsupported:
        print(f"    {sentence[:160]}", file=sys.stderr)
    print(f"  → 怎么办：{REMEDY}", file=sys.stderr)
    return EXIT_BLOCKED


# 样本：(样本名, 文本, 期望拒绝的句数)
SELFTEST_CASES = (
    ("凭印象说同口径", "取名照 crates-mutation-rows 那一份同一口径：取限定名。", 1),
    ("与某处一样的做法", "超时的算法与门禁库一样的做法，不用另想。", 1),
    ("同反引号里的名字", "键的拼法同 `qualified_name`，直接用。", 1),
    ("带路径与行号放行", "取名照 scripts/mutation/rows.py:3241 那一份同一口径。", 0),
    ("带原文引用放行", "照门禁库那一份办：「限定名取到 crate 为止，不带模块路径」。", 0),
    ("带路径与函数名放行", "照 scripts/mutation/rows.py 里 `qualified_name()` 的写法取。", 0),
    ("引用行放行", "照规则那一份的写法：\n> 名字自己站得住，不靠模块路径补全\n", 0),
    ("围栏里的借用句放行", "```\n照旧版那一份同一口径\n```\n其余照常。", 0),
    ("出处在别的句子里照样拒", "先读 scripts/mutation/rows.py:3241。取名与那边同一口径。", 1),
    ("同文件加行号放行", "照同文件 `base-fingerprint` 第 1418–1419 行的写法补出路。", 0),
    ("没有借用说法放行", "把 scripts/a.py 的超时改成 30 秒，跑完报数。", 0),
    ("验收里的两样相比不算借用", "验收：模型与实现逐项相同，改动与现状一致。", 0),
    ("照对方自己的写法不算借用", "交回记进调度记录（照你现在的写法）。", 0),
    ("说了内容也要带出处", "长度 0 的 discard 与后端同一口径——长度 0 不记一步。", 1),
    ("两句各算各的", "取名照门禁库那一份。超时同一口径。", 2),
)


def run_selftest_cases() -> list:
    misjudged_cases = []
    for case_name, text, expected_count in SELFTEST_CASES:
        actual_count = len(unsupported_borrow_sentences(text))
        if actual_count != expected_count:
            misjudged_cases.append((case_name, expected_count, actual_count))
    return misjudged_cases


def run_hook_cases() -> list:
    """整条钩子路径：JSON 进、退出码出。"""
    hook_cases = (
        ("Agent 的借用句被拒", {"tool_name": "Agent", "tool_input": {"prompt": "超时同一口径。"}}, EXIT_BLOCKED),
        ("SendMessage 的借用句被拒", {"tool_name": "SendMessage", "tool_input": {"to": "x", "message": "照那边那一份办。"}}, EXIT_BLOCKED),
        ("别的工具不管", {"tool_name": "Bash", "tool_input": {"command": "echo 同一口径"}}, EXIT_PASS),
        ("干净的提示放行", {"tool_name": "Agent", "tool_input": {"prompt": "读 scripts/a.py，报行数。"}}, EXIT_PASS),
    )
    misjudged_cases = []
    for case_name, hook_input, expected_exit in hook_cases:
        hook_run = subprocess.run([sys.executable, os.path.abspath(__file__), "--hook"], input=json.dumps(hook_input, ensure_ascii=False),
                                  capture_output=True, text=True, check=False)
        if hook_run.returncode != expected_exit:
            misjudged_cases.append((case_name, expected_exit, hook_run.returncode))
    not_json_run = subprocess.run([sys.executable, os.path.abspath(__file__), "--hook"], input="[1, 2]",
                                  capture_output=True, text=True, check=False)
    if not_json_run.returncode != EXIT_NOT_JUDGED or "这一次没判" not in not_json_run.stderr:
        misjudged_cases.append(("输入不是 JSON 对象判不了", EXIT_NOT_JUDGED, not_json_run.returncode))
    return misjudged_cases


def selftest() -> int:
    misjudged_cases = run_selftest_cases()
    if not break_switch():
        misjudged_cases += run_hook_cases()
    exit_code = BREAK_SWITCH_SELFTEST.finish_selftest(__file__, BREAK_ENVIRONMENT_VARIABLE, BREAK_SWITCHES, misjudged_cases,
                                                      len(SELFTEST_CASES), "unsupported_borrow_sentences / judge_hook")
    if exit_code is not None:
        return exit_code
    print(f"  ✓ borrowed-convention 自证：{len(SELFTEST_CASES)} 个红绿样本与 5 条钩子路径判得对；"
          f"{len(BREAK_SWITCHES)} 个弄坏开关逐个打开，各自红在点名的样本上")
    return 0


def main(arguments: list) -> int:
    if arguments == ["--hook"]:
        return judge_hook(sys.stdin.read())
    if arguments == ["--selftest"]:
        return selftest()
    print("  ✗ 用法：borrowed-convention.py --hook（从标准输入读钩子 JSON），或 borrowed-convention.py --selftest")
    print("     → 怎么办：钩子里由 scripts/claude-hooks/borrowed-convention-guard.sh 起它；改了这份脚本先跑 --selftest。")
    return 2


if __name__ == "__main__":
    preflight(__file__)
    sys.exit(main(sys.argv[1:]))
