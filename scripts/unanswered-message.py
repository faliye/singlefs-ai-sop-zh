#!/usr/bin/env python3
# gate-similar: courtesy-phrase.py 同样经一个收工钩子挂在 Stop 上、同样读钩子的 JSON 与会话记录，但它判最后一条回复里的客套话；这一道判别的会话发来的消息之后有没有回过去，对象与判据都不同
# gate-similar: gate-overlap.py 它经 gate-reuse-check.sh 也挂在 Stop 上，判这一轮新写的门禁与钩子该不该单独存在；读的不是同一份输入
# gate-similar: borrowed-convention.py 同样看 SendMessage，但它在发出之前判消息里的借用句带没带出处；这一道在收工时判该回的消息回了没有，触发点与对象都不同
# gate-similar: handback-scratch.py 同样读会话记录里的工具调用，但它判子 agent 交回前删没删自己建的目录；对象不同
# gate-overlap:copy-kept courtesy-phrase.py 相同的是载入共用库、退出码常量、自证收尾与 main 入口那几段；每份 python 钩子判定各带一份，读钩子输入与记指纹已经抽进 session-transcript.py
# admission: always Claude Code 在 agent 每一次收工时调它，收到的消息回没回要现判
# run-condition: none 只读钩子从标准输入给的 JSON 与它点名的会话记录、只用 python 标准库
"""agent 收工时核一遍：别的会话发来的消息回了没有（rules/communication-discipline.md「收工前核一遍别的会话发来的消息」）。

用法：
    unanswered-message.py --hook       # 从标准输入读 Claude Code 的 Stop 钩子 JSON
    unanswered-message.py --selftest   # 自证：内嵌红绿样本逐个判，整条钩子路径；再逐个打开弄坏开关另起子进程跑自证

收到的消息：会话记录（transcript_path）里入队的 <cross-session-message …>（queue-operation 的 enqueue），
  与来源是别的会话的那条 user 记录（origin.kind 是 peer）；同一条消息两处都有时只算一条。
算回过：那条消息之后，有一次 SendMessage 或 CrossSessionMessage 的 to 是它的会话名或地址。
算交代过：那条消息之后的回复文字（含钩子输入的 last_assistant_message）里有一行「不回 <会话名>：<理由>」，理由至少 4 个字。
退出码：拦下 2（Claude Code 不让收工，把 stderr 交给 agent）；放行 0；判不了 1（输入不是 JSON 对象、没有会话记录；不拦，stderr 留一行原因）。
只拦一次：同一份没回的清单拦过一次之后放行；清单变了照样再拦。
  状态目录默认 ${TMPDIR:-/tmp}/unanswered-message-check，UNANSWERED_MESSAGE_STATE_DIRECTORY 可改。

够不着的（不判，不等于通过）：那条消息到底要不要回、回的内容答没答上、「不回」的理由成不成立；
  子 agent 与队友（agent-message）发来的；不走这两个工具回的（写文件、让用户转告）；
  没带会话名、地址是 unknown 的（任务服务的结果通知这类，回不过去）不列。

UNANSWERED_MESSAGE_BREAK=<开关名> 打开一个弄坏开关（自证专用，钩子里不许设），开关表见 BREAK_SWITCHES。
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
BREAK_ENVIRONMENT_VARIABLE = "UNANSWERED_MESSAGE_BREAK"
# 弄坏开关 → 打开后自证必须红在哪个样本上
BREAK_SWITCHES = {
    "earlier-reply-counts": "消息到之前发的不算回过",
    "any-recipient-counts": "回给别的会话不算",
    "decline-ignored": "写了不回那一行放行",
    "decline-name-cut-at-spaces": "会话名带空格的不回那一行放行",
    "unreachable-sender-listed": "地址是 unknown 的通知不算",
}

REPLY_TOOLS = ("SendMessage", "CrossSessionMessage")
# 来源地址是这几样、又没带会话名的消息，不是哪个会话发的，回不过去，不列
UNREACHABLE_SENDERS = ("", "unknown")
MESSAGE_TAG = re.compile(r"(?s)^\s*<cross-session-message\b([^>]*)>(.*?)(?:</cross-session-message>\s*)?$")
TAG_ATTRIBUTE = re.compile(r'([a-z-]+)="([^"]*)"')
RECIPIENT_REFERENCE_SUFFIX = re.compile(r"\s*\[[^\]]*\]\s*$")
DECLINE_LINE_START = re.compile(r"(?m)^[\s>*-]*(?:不回|no reply to|返信しない)\s+[`「]?(.*)$")
DECLINE_AFTER_THE_NAME = re.compile(r"[`」]?\s*[：:]\s*(\S.*)$")
DECLINE_NAME_CUT_AT_SPACES = re.compile(r"[^\s：:`」]+")
DECLINE_REASON_MINIMUM = 4
DEDUPLICATION_PREFIX_LENGTH = 80
LISTED_BODY_LENGTH = 60

REMEDY = (
    "逐条看要不要回。要回的用 SendMessage 回给那个会话；不用回的，在回复里各写一行「不回 <会话名>：<理由>」（理由至少 4 个字）。"
    "同一份清单只拦一次（rules/communication-discipline.md「收工前核一遍别的会话发来的消息」）。"
)


def break_switch() -> str:
    return os.environ.get(BREAK_ENVIRONMENT_VARIABLE, "")


def arrival_of(entry: dict):
    """一条记录是不是别的会话发来的消息：是就给出 {会话名, 地址, 正文}，不是给 None。"""
    if entry.get("type") == "queue-operation" and entry.get("operation") == "enqueue" and isinstance(entry.get("content"), str):
        tag = MESSAGE_TAG.match(entry["content"])
        if not tag:
            return None
        attributes = dict(TAG_ATTRIBUTE.findall(tag.group(1)))
        return {"name": attributes.get("from-name", ""), "address": attributes.get("from", ""), "body": tag.group(2).strip()}
    origin = entry.get("origin")
    if entry.get("type") == "user" and isinstance(origin, dict) and origin.get("kind") == "peer":
        if origin.get("handback") is True or origin.get("senderTaskId"):
            return None   # 自己派的子 agent 交回的报告，不是别的会话
        if not origin.get("name") and str(origin.get("from") or "") in UNREACHABLE_SENDERS and break_switch() != "unreachable-sender-listed":
            return None   # 没有会话名、地址是 unknown：不是会话发的（任务服务的结果通知这类），回不过去
        body = origin.get("body")
        return {"name": str(origin.get("name") or ""), "address": str(origin.get("from") or ""), "body": body.strip() if isinstance(body, str) else ""}
    return None


def read_transcript(transcript_path: str):
    """会话记录里的三样，各带它在记录里的次序：收到的消息、发出去的消息的收件方、回复文字。"""
    arrivals, recipients, reply_texts = [], [], []
    seen_arrivals = set()
    needles = ("cross-session-message", '"peer"', '"assistant"')
    for position, entry in enumerate(SESSION_TRANSCRIPT.transcript_entries(transcript_path, needles)):
        arrival = arrival_of(entry)
        if arrival is not None:
            deduplication_key = (arrival["name"], arrival["address"], arrival["body"][:DEDUPLICATION_PREFIX_LENGTH])
            if deduplication_key not in seen_arrivals:
                seen_arrivals.add(deduplication_key)
                arrivals.append(dict(arrival, position=position, timestamp=str(entry.get("timestamp") or "")))
            continue
        if entry.get("type") != "assistant":
            continue
        for block in SESSION_TRANSCRIPT.content_blocks(entry):
            if block.get("type") == "tool_use" and block.get("name") in REPLY_TOOLS and isinstance(block.get("input"), dict):
                recipient = block["input"].get("to")
                if isinstance(recipient, str):
                    recipients.append((position, RECIPIENT_REFERENCE_SUFFIX.sub("", recipient).strip()))
            elif block.get("type") == "text" and isinstance(block.get("text"), str):
                reply_texts.append((position, block["text"]))
    return arrivals, recipients, reply_texts


def declined_names(text: str, sender_names: set) -> set:
    """sender_names 里被「不回 <会话名>：<理由>」那一行点到的名字。会话名照收到的逐字比（名字里带空格、冒号的照认），
    名字之后紧跟冒号与理由才算：只写了名字前一段的不算。"""
    if break_switch() == "decline-ignored":
        return set()
    declined = set()
    for line_start in DECLINE_LINE_START.finditer(text):
        after_the_keyword = line_start.group(1)
        for name in sender_names:
            if not after_the_keyword.startswith(name):
                continue
            if break_switch() == "decline-name-cut-at-spaces" and DECLINE_NAME_CUT_AT_SPACES.fullmatch(name) is None:
                continue
            after_the_name = DECLINE_AFTER_THE_NAME.match(after_the_keyword[len(name):])
            if after_the_name is not None and len(after_the_name.group(1).strip()) >= DECLINE_REASON_MINIMUM:
                declined.add(name)
    return declined


def unanswered_messages(transcript_path: str, last_message: str) -> list:
    """收到之后既没回、也没写「不回」那一行的消息。"""
    arrivals, recipients, reply_texts = read_transcript(transcript_path)
    unanswered = []
    for arrival in arrivals:
        sender_names = {name for name in (arrival["name"], arrival["address"]) if name}
        answered = any(
            (position > arrival["position"] or break_switch() == "earlier-reply-counts")
            and (recipient in sender_names or break_switch() == "any-recipient-counts")
            for position, recipient in recipients
        )
        if answered:
            continue
        later_text = "\n".join([text for position, text in reply_texts if position > arrival["position"]] + [last_message])
        if declined_names(later_text, sender_names):
            continue
        unanswered.append(arrival)
    return unanswered


def already_shown(hook_input: dict, unanswered: list) -> bool:
    """同一份没回的清单拦过一次：放行。其余情形记下指纹、照拦。"""
    state_directory = os.environ.get("UNANSWERED_MESSAGE_STATE_DIRECTORY") or os.path.join(os.environ.get("TMPDIR") or "/tmp", "unanswered-message-check")
    state_file = SESSION_TRANSCRIPT.shown_state_file(state_directory, hook_input, (("session_id", "no-session"),))
    fingerprint = SESSION_TRANSCRIPT.fingerprint_of(
        [(arrival["name"], arrival["address"], arrival["body"][:DEDUPLICATION_PREFIX_LENGTH]) for arrival in unanswered])
    if SESSION_TRANSCRIPT.stored_fingerprint(state_file) == fingerprint:
        return True
    SESSION_TRANSCRIPT.store_fingerprint(state_file, fingerprint)
    return False


def judge_hook(hook_text: str) -> int:
    hook_input = SESSION_TRANSCRIPT.hook_input_object(hook_text)
    if hook_input is None:
        print("unanswered-message：钩子输入不是 JSON 对象，这一次收工没判", file=sys.stderr)
        return EXIT_NOT_JUDGED
    transcript_path = hook_input.get("transcript_path")
    if not isinstance(transcript_path, str) or not os.path.isfile(transcript_path):
        print("unanswered-message：输入里没有 transcript_path，或它指的会话记录不在，这一次收工没判", file=sys.stderr)
        return EXIT_NOT_JUDGED
    last_message = hook_input.get("last_assistant_message")
    unanswered = unanswered_messages(transcript_path, last_message if isinstance(last_message, str) else "")
    if not unanswered or already_shown(hook_input, unanswered):
        return EXIT_PASS
    print(f"✗ 别的会话发来的消息有 {len(unanswered)} 条还没回：", file=sys.stderr)
    for arrival in unanswered:
        first_line = " ".join(arrival["body"].split())[:LISTED_BODY_LENGTH]
        print(f"    {arrival['name'] or arrival['address'] or '没带名字的会话'}（{arrival['timestamp'] or '没带时刻'}）：{first_line}", file=sys.stderr)   # gate-lint:detail
    print(f"  → 怎么办：{REMEDY}", file=sys.stderr)
    return EXIT_BLOCKED


def queued_message(name: str, body: str, address: str = "uds:/run/user/1000/cc-socks/1.sock") -> dict:
    return {"type": "queue-operation", "operation": "enqueue", "timestamp": "2026-01-01T00:00:00Z",
            "content": f'<cross-session-message from="{address}" hop-chain="ab" from-name="{name}" from-mode="prompting">\n{body}\n</cross-session-message>'}


def unreachable_notice() -> dict:
    """任务服务发来的结果通知：来源地址是 unknown、没带会话名，正文只在 message 里。"""
    return {"type": "user", "timestamp": "2026-01-01T00:00:01Z", "origin": {"kind": "peer", "from": "unknown", "verifiedPeerPid": 2},
            "message": {"role": "user", "content": "Another Claude session sent a message:\ntask-server：任务 8794 succeeded（退 0）"}}


def peer_turn(name: str, body: str, address: str = "uds:/run/user/1000/cc-socks/1.sock") -> dict:
    return {"type": "user", "timestamp": "2026-01-01T00:00:01Z", "origin": {"kind": "peer", "from": address, "name": name, "body": body},
            "message": {"role": "user", "content": f'Another Claude session sent a message:\n<cross-session-message from="{address}" from-name="{name}">\n{body}\n</cross-session-message>'}}


def subagent_handback(body: str) -> dict:
    return {"type": "user", "timestamp": "2026-01-01T00:00:05Z",
            "origin": {"kind": "peer", "from": "a53", "senderTaskId": "a53", "name": "general-purpose", "body": body, "handback": True},
            "message": {"role": "user", "content": f'Another Claude session sent a message:\n<agent-message from="a53">\n{body}\n</agent-message>'}}


def sent_message(recipient: str, tool_name: str = "SendMessage") -> dict:
    return {"type": "assistant", "timestamp": "2026-01-01T00:00:02Z",
            "message": {"role": "assistant", "content": [{"type": "tool_use", "id": "t", "name": tool_name, "input": {"to": recipient, "message": "回复"}}]}}


def replied_text(text: str) -> dict:
    return {"type": "assistant", "timestamp": "2026-01-01T00:00:03Z", "message": {"role": "assistant", "content": [{"type": "text", "text": text}]}}


def quoted_in_tool_result(name: str) -> dict:
    return {"type": "user", "timestamp": "2026-01-01T00:00:04Z",
            "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "t", "content": f'<cross-session-message from-name="{name}">\n问一处\n</cross-session-message>'}]}}


QUESTION = "问一处：这 47 页是你那一路改的吗？"
# 样本：(样本名, 会话记录的各条, 钩子输入的最后一条回复, 期望没回的条数)
SELFTEST_CASES = (
    ("收到了没回", [queued_message("north", QUESTION), peer_turn("north", QUESTION), replied_text("改完了。")], "改完了。", 1),
    ("回过了放行", [queued_message("north", QUESTION), peer_turn("north", QUESTION), sent_message("north")], "已回。", 0),
    ("按地址回的也算", [queued_message("north", QUESTION), sent_message("uds:/run/user/1000/cc-socks/1.sock")], "已回。", 0),
    ("收件方带方括号的也算", [queued_message("north", QUESTION), sent_message("north [a1b2]")], "已回。", 0),
    ("用 CrossSessionMessage 回的也算", [peer_turn("north", QUESTION), sent_message("north", "CrossSessionMessage")], "已回。", 0),
    ("消息到之前发的不算回过", [sent_message("north"), queued_message("north", QUESTION)], "改完了。", 1),
    ("回给别的会话不算", [queued_message("north", QUESTION), sent_message("south")], "已回。", 1),
    ("写了不回那一行放行", [queued_message("north", QUESTION)], "改完了。\n不回 north：它只是通知，没有问话。", 0),
    ("不回那一行写在更早的回复里也放行", [queued_message("north", QUESTION), replied_text("不回 `north`：等用户定了再回它。")], "改完了。", 0),
    ("不回的理由太短照拦", [queued_message("north", QUESTION)], "不回 north：无。", 1),
    ("不回写的是别的会话照拦", [queued_message("north", QUESTION)], "不回 south：它只是通知，没有问话。", 1),
    ("会话名带空格的不回那一行放行", [queued_message("north star 收尾", QUESTION)], "改完了。\n不回 north star 收尾：它只是通知，没有问话。", 0),
    ("不回写的是地址也放行", [queued_message("north", QUESTION)], "不回 uds:/run/user/1000/cc-socks/1.sock：它只是通知，没有问话。", 0),
    ("不回只写了会话名的前一段照拦", [queued_message("north star 收尾", QUESTION)], "不回 north：它只是通知，没有问话。", 1),
    ("两个会话只回了一个", [queued_message("north", QUESTION), queued_message("south", "另一处也问一下"), sent_message("north")], "已回。", 1),
    ("同一会话回过之后又来一条", [queued_message("north", QUESTION), sent_message("north"), queued_message("north", "再问一处")], "已回。", 1),
    ("工具输出里引到的标签不算收到", [quoted_in_tool_result("north"), replied_text("看完了。")], "看完了。", 0),
    ("子 agent 交回的报告不算", [subagent_handback("两条检查都绿。"), replied_text("收到报告。")], "看完了。", 0),
    ("没收到过消息放行", [replied_text("改完了。")], "改完了。", 0),
    ("地址是 unknown 的通知不算", [unreachable_notice()], "看完了。", 0),
)


def write_transcript(directory: str, entries: list) -> str:
    transcript_path = os.path.join(directory, "session.jsonl")
    with open(transcript_path, "w", encoding="utf-8") as handle:
        for entry in entries:
            handle.write(json.dumps(entry, ensure_ascii=False) + "\n")
    return transcript_path


def run_selftest_cases() -> list:
    misjudged_cases = []
    for case_name, entries, last_message, expected_count in SELFTEST_CASES:
        with tempfile.TemporaryDirectory() as scratch_directory:
            actual_count = len(unanswered_messages(write_transcript(scratch_directory, entries), last_message))
        if actual_count != expected_count:
            misjudged_cases.append((case_name, expected_count, actual_count))
    return misjudged_cases


HOOK_PATH_COUNT = 7


def run_hook_cases() -> list:
    """整条钩子路径：JSON 进、退出码出。"""
    misjudged_cases = []
    with tempfile.TemporaryDirectory() as scratch_directory:
        unanswered_path = write_transcript(scratch_directory, [queued_message("north", QUESTION), peer_turn("north", QUESTION)])
        environment = dict(os.environ, UNANSWERED_MESSAGE_STATE_DIRECTORY=os.path.join(scratch_directory, "state"))
        environment.pop(BREAK_ENVIRONMENT_VARIABLE, None)

        def run_hook(hook_text: str):
            return subprocess.run([sys.executable, os.path.abspath(__file__), "--hook"], input=hook_text,
                                  capture_output=True, text=True, check=False, env=environment)

        def expect(case_name: str, hook_input: dict, expected_exit: int, expected_stderr: str = ""):
            hook_run = run_hook(json.dumps(hook_input, ensure_ascii=False))
            if hook_run.returncode != expected_exit or expected_stderr not in hook_run.stderr:
                misjudged_cases.append((case_name, expected_exit, hook_run.returncode))

        expect("有没回的就拦，并点出会话名", {"session_id": "s", "transcript_path": unanswered_path, "last_assistant_message": "改完了。"}, EXIT_BLOCKED, "north")
        expect("同一份清单不连拦", {"session_id": "s", "transcript_path": unanswered_path, "last_assistant_message": "改完了。"}, EXIT_PASS)
        with open(unanswered_path, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(queued_message("south", "另一处也问一下"), ensure_ascii=False) + "\n")
        expect("清单变了照样拦", {"session_id": "s", "transcript_path": unanswered_path, "last_assistant_message": "改完了。"}, EXIT_BLOCKED, "south")
        expect("回复里写了不回那一行放行", {"session_id": "v", "transcript_path": unanswered_path,
                                 "last_assistant_message": "不回 north：等用户定了再回它。\n不回 south：它只是通知，没有问话。"}, EXIT_PASS)
        with open(unanswered_path, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(sent_message("north"), ensure_ascii=False) + "\n" + json.dumps(sent_message("south"), ensure_ascii=False) + "\n")
        expect("都回过了放行", {"session_id": "w", "transcript_path": unanswered_path, "last_assistant_message": "已回。"}, EXIT_PASS)
        expect("没有会话记录判不了", {"session_id": "u"}, EXIT_NOT_JUDGED, "没判")
        not_json_run = run_hook("[1, 2]")
        if not_json_run.returncode != EXIT_NOT_JUDGED or "没判" not in not_json_run.stderr:
            misjudged_cases.append(("输入不是 JSON 对象判不了", EXIT_NOT_JUDGED, not_json_run.returncode))
    return misjudged_cases


def selftest() -> int:
    misjudged_cases = run_selftest_cases()
    if not break_switch():
        misjudged_cases += run_hook_cases()
    exit_code = BREAK_SWITCH_SELFTEST.finish_selftest(__file__, BREAK_ENVIRONMENT_VARIABLE, BREAK_SWITCHES, misjudged_cases,
                                                      len(SELFTEST_CASES), "unanswered_messages / judge_hook")
    if exit_code is not None:
        return exit_code
    print(f"  ✓ unanswered-message 自证：{len(SELFTEST_CASES)} 个红绿样本与 {HOOK_PATH_COUNT} 条钩子路径判得对；"
          f"{len(BREAK_SWITCHES)} 个弄坏开关逐个打开，各自红在点名的样本上")
    return 0


def main(arguments: list) -> int:
    if arguments == ["--hook"]:
        return judge_hook(sys.stdin.read())
    if arguments == ["--selftest"]:
        return selftest()
    print("  ✗ 用法：unanswered-message.py --hook（从标准输入读钩子 JSON），或 unanswered-message.py --selftest")
    print("     → 怎么办：钩子里由 scripts/claude-hooks/unanswered-message-check.sh 起它；改了这份脚本先跑 --selftest。")
    return 2


if __name__ == "__main__":
    preflight(__file__)
    sys.exit(main(sys.argv[1:]))
