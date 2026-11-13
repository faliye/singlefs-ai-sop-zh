#!/usr/bin/env python3
# gate-similar: borrowed-convention.py 同样是给 Claude Code 钩子做判定的 python、判 agent 写出去的文字，但它在派发与发消息之前判借用句带没带出处；这一道在收工时判最后一条回复里的客套话，触发点、对象与词表都不同
# gate-similar: gate-overlap.py 它经 gate-reuse-check.sh 也挂在 Stop 与 SubagentStop 上，判这一轮新写的门禁与钩子该不该单独存在；这一道判回复的文字，读的不是同一份输入
# gate-similar: handback-scratch.py 同挂 SubagentStop，判子 agent 交回前删没删自己建的目录；对象不同
# gate-similar: doc-lint.sh 它的文风词表判进仓的 .md 里的翻译腔与古风腔；这一道判的是还没进仓的对话回复，输入是钩子的 JSON
# admission: always Claude Code 在 agent 每一次收工时调它，每一条回复都要现判
# run-condition: none 只读钩子从标准输入给的 JSON 与它点名的会话记录、只用 python 标准库
"""agent 收工时的最后一条回复里不写客套话（rules/communication-discipline.md「不写客套」）。

用法：
    courtesy-phrase.py --hook       # 从标准输入读 Claude Code 的 Stop / SubagentStop 钩子 JSON
    courtesy-phrase.py --selftest   # 自证：内嵌红绿样本逐个判，整条钩子路径；再逐个打开弄坏开关另起子进程跑自证

判的文字：钩子输入的 last_assistant_message；没有这一项时取会话记录（agent_transcript_path，没有就 transcript_path）里最后一段回复。
判据：去掉代码块、反引号、「」与引号里的内容之后，文字里有 COURTESY_PHRASES 里的说法就算命中。
  「好的」「当然」这类应答只在一行的开头、后面紧跟标点时才认（「做好的那一份」不算）。
退出码：拦下 2（Claude Code 不让收工，把 stderr 交给 agent）；放行 0；判不了 1（输入不是 JSON 对象、取不到回复；不拦，stderr 留一行原因）。
不死循环：被拦回来的续跑（stop_hook_active 为 true）里，回复与上一次拦下时命中的说法一字不差就放行；换了说法照样再拦。
  状态目录默认 ${TMPDIR:-/tmp}/courtesy-phrase-check，COURTESY_PHRASE_STATE_DIRECTORY 可改。

够不着的（不判，不等于通过）：词表外的客套话；英文、日文的回复（词表只有中文）；回复当中、不在收工那一条里的；
  发给别的会话与子 agent 的消息；先说没说结论、有没有软化判断。

COURTESY_PHRASE_BREAK=<开关名> 打开一个弄坏开关（自证专用，钩子里不许设），开关表见 BREAK_SWITCHES。
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

EXIT_PASS = 0
EXIT_NOT_JUDGED = 1
EXIT_BLOCKED = 2
BREAK_ENVIRONMENT_VARIABLE = "COURTESY_PHRASE_BREAK"
# 弄坏开关 → 打开后自证必须红在哪个样本上
BREAK_SWITCHES = {
    "leading-reply-ignored": "开头的应答",
    "quotes-read": "引号里举的例子放行",
    "fences-read": "代码块里的放行",
}

# (说法的名字, 正则)。应答类只认行首、后面紧跟标点。
LEADING_REPLY = ("开头的应答", re.compile(r"(?m)^\s*(?:好的|好嘞|好滴|当然(?:可以)?|没问题|收到|明白了?|了解)\s*[，。！!,.~～]"))
COURTESY_PHRASES = (
    LEADING_REPLY,
    ("表示高兴", re.compile(r"很高兴|乐意(?:为|效劳)|荣幸")),
    ("道谢", re.compile(r"(?:谢谢|感谢)(?:你|您|提醒|指出|指正|反馈|耐心|理解)")),
    ("道歉", re.compile(r"(?:非常|十分|很|实在)?(?:抱歉|对不起|不好意思)")),
    ("夸提问", re.compile(r"(?:好|很好的?|很棒的?|非常好的?)问题|问得好")),
    ("结尾问还要不要别的", re.compile(r"还(?:有|需要)[^。？?\n]{0,10}(?:别的|其他|其它|什么)[^。？?\n]{0,8}吗\s*[？?]")),
    ("随时找我", re.compile(r"(?:随时|尽管)(?:告诉我|找我|提出|问我|联系)|希望(?:这|以上)[^。\n]{0,8}(?:有帮助|有所帮助)")),
)
FENCED_BLOCK = re.compile(r"(?ms)^\s*(```|~~~).*?^\s*\1\s*$")
QUOTED_SPANS = re.compile(r"`[^`\n]*`|「[^」\n]*」|“[^”\n]*”|\"[^\"\n]*\"")

REMEDY = (
    "把点到的客套话删掉，直接说结论与依据，重写这一条回复；别的内容不用动。"
    "确实是在引用或举例，放进「」或反引号里（rules/communication-discipline.md「不写客套」）。"
)


def break_switch() -> str:
    return os.environ.get(BREAK_ENVIRONMENT_VARIABLE, "")


def judged_text(reply: str) -> str:
    text = reply
    if break_switch() != "fences-read":
        text = FENCED_BLOCK.sub("", text)
    if break_switch() != "quotes-read":
        text = QUOTED_SPANS.sub("", text)
    return text


def courtesy_hits(reply: str) -> list:
    """回复里命中的客套话：[(说法的名字, 命中的原文)]。"""
    text = judged_text(reply)
    hits = []
    for phrase_name, pattern in COURTESY_PHRASES:
        if phrase_name == LEADING_REPLY[0] and break_switch() == "leading-reply-ignored":
            continue
        for match in pattern.finditer(text):
            hits.append((phrase_name, match.group(0).strip()))
    return hits


def last_reply(hook_input: dict):
    message = hook_input.get("last_assistant_message")
    if isinstance(message, str) and message.strip():
        return message
    for key in ("agent_transcript_path", "transcript_path"):
        transcript_path = hook_input.get(key)
        if isinstance(transcript_path, str) and os.path.isfile(transcript_path):
            texts = SESSION_TRANSCRIPT.assistant_texts(transcript_path)
            return texts[-1][1] if texts else None
    return None


def already_shown(hook_input: dict, hits: list) -> bool:
    """被拦回来的续跑里命中的说法与上一次一字不差：放行。其余情形记下指纹、照拦。"""
    state_directory = os.environ.get("COURTESY_PHRASE_STATE_DIRECTORY") or os.path.join(os.environ.get("TMPDIR") or "/tmp", "courtesy-phrase-check")
    state_file = SESSION_TRANSCRIPT.shown_state_file(state_directory, hook_input, (("session_id", "no-session"), ("agent_id", "main")))
    fingerprint = SESSION_TRANSCRIPT.fingerprint_of(hits)
    if hook_input.get("stop_hook_active") is True and SESSION_TRANSCRIPT.stored_fingerprint(state_file) == fingerprint:
        return True
    SESSION_TRANSCRIPT.store_fingerprint(state_file, fingerprint)
    return False


def judge_hook(hook_text: str) -> int:
    hook_input = SESSION_TRANSCRIPT.hook_input_object(hook_text)
    if hook_input is None:
        print("courtesy-phrase：钩子输入不是 JSON 对象，这一次收工没判", file=sys.stderr)
        return EXIT_NOT_JUDGED
    reply = last_reply(hook_input)
    if reply is None:
        print("courtesy-phrase：输入里没有 last_assistant_message，会话记录里也取不到回复，这一次收工没判", file=sys.stderr)
        return EXIT_NOT_JUDGED
    hits = courtesy_hits(reply)
    if not hits or already_shown(hook_input, hits):
        return EXIT_PASS
    print(f"✗ 最后一条回复里有 {len(hits)} 处客套话：", file=sys.stderr)
    for phrase_name, matched_text in hits:
        print(f"    {phrase_name}：{matched_text[:60]}", file=sys.stderr)   # gate-lint:detail
    print(f"  → 怎么办：{REMEDY}", file=sys.stderr)
    return EXIT_BLOCKED


# 样本：(样本名, 回复, 期望命中的处数)
SELFTEST_CASES = (
    ("开头的应答", "好的，已经改完。\n门禁通过 21 个阶段。", 1),
    ("表示高兴", "改完了。很高兴能帮上忙。", 1),
    ("道歉", "非常抱歉，上一条的数算错了，应为 18 处。", 1),
    ("道谢与夸提问", "谢谢你的提醒。这是个好问题。", 2),
    ("结尾问还要不要别的", "三仓已推。还有别的需要我做的吗？", 1),
    ("随时找我", "已同步。有问题随时告诉我。", 1),
    ("直说结论放行", "三仓已推，下游副本已同步。门禁红 2 处，都在下游自己的脚本里。", 0),
    ("句中的好的不算", "做好的那一份在草稿目录里，当然这一步还没验。", 0),
    ("引号里举的例子放行", "规则里的例子是「好的」「很高兴」，以及 `抱歉` 这个词。", 0),
    ("代码块里的放行", "输出如下：\n```\n好的，抱歉，谢谢你\n```\n共 1 行。", 0),
)


def run_selftest_cases() -> list:
    misjudged_cases = []
    for case_name, reply, expected_count in SELFTEST_CASES:
        actual_count = len(courtesy_hits(reply))
        if actual_count != expected_count:
            misjudged_cases.append((case_name, expected_count, actual_count))
    return misjudged_cases


def run_hook_cases() -> list:
    """整条钩子路径：JSON 进、退出码出。"""
    misjudged_cases = []
    with tempfile.TemporaryDirectory() as scratch_directory:
        transcript_path = os.path.join(scratch_directory, "session.jsonl")
        with open(transcript_path, "w", encoding="utf-8") as handle:
            handle.write(json.dumps({"type": "assistant", "timestamp": "2026-01-01T00:00:00Z",
                                     "message": {"role": "assistant", "content": [{"type": "text", "text": "好的，改完了。"}]}}, ensure_ascii=False) + "\n")
        environment = dict(os.environ, COURTESY_PHRASE_STATE_DIRECTORY=os.path.join(scratch_directory, "state"))
        hook_cases = (
            ("回复里有客套话就拦", {"session_id": "s", "last_assistant_message": "好的，改完了。"}, EXIT_BLOCKED),
            ("续跑里同一份命中不连拦", {"session_id": "s", "stop_hook_active": True, "last_assistant_message": "好的，改完了。"}, EXIT_PASS),
            ("续跑里换了说法照样拦", {"session_id": "s", "stop_hook_active": True, "last_assistant_message": "改完了，非常抱歉。"}, EXIT_BLOCKED),
            ("干净的回复放行", {"session_id": "s", "last_assistant_message": "改完了，门禁通过。"}, EXIT_PASS),
            ("没有 last_assistant_message 时读会话记录", {"session_id": "t", "transcript_path": transcript_path}, EXIT_BLOCKED),
            ("取不到回复判不了", {"session_id": "u"}, EXIT_NOT_JUDGED),
        )
        for case_name, hook_input, expected_exit in hook_cases:
            hook_run = subprocess.run([sys.executable, os.path.abspath(__file__), "--hook"], input=json.dumps(hook_input, ensure_ascii=False),
                                      capture_output=True, text=True, check=False, env=environment)
            if hook_run.returncode != expected_exit:
                misjudged_cases.append((case_name, expected_exit, hook_run.returncode))
        not_json_run = subprocess.run([sys.executable, os.path.abspath(__file__), "--hook"], input="[1, 2]",
                                      capture_output=True, text=True, check=False, env=environment)
        if not_json_run.returncode != EXIT_NOT_JUDGED or "没判" not in not_json_run.stderr:
            misjudged_cases.append(("输入不是 JSON 对象判不了", EXIT_NOT_JUDGED, not_json_run.returncode))
    return misjudged_cases


def selftest() -> int:
    misjudged_cases = run_selftest_cases()
    if not break_switch():
        misjudged_cases += run_hook_cases()
    exit_code = BREAK_SWITCH_SELFTEST.finish_selftest(__file__, BREAK_ENVIRONMENT_VARIABLE, BREAK_SWITCHES, misjudged_cases,
                                                      len(SELFTEST_CASES), "courtesy_hits / judge_hook")
    if exit_code is not None:
        return exit_code
    print(f"  ✓ courtesy-phrase 自证：{len(SELFTEST_CASES)} 个红绿样本与 7 条钩子路径判得对；"
          f"{len(BREAK_SWITCHES)} 个弄坏开关逐个打开，各自红在点名的样本上")
    return 0


def main(arguments: list) -> int:
    if arguments == ["--hook"]:
        return judge_hook(sys.stdin.read())
    if arguments == ["--selftest"]:
        return selftest()
    print("  ✗ 用法：courtesy-phrase.py --hook（从标准输入读钩子 JSON），或 courtesy-phrase.py --selftest")
    print("     → 怎么办：钩子里由 scripts/claude-hooks/courtesy-phrase-check.sh 起它；改了这份脚本先跑 --selftest。")
    return 2


if __name__ == "__main__":
    preflight(__file__)
    sys.exit(main(sys.argv[1:]))
