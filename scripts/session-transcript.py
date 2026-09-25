#!/usr/bin/env python3
"""读 Claude Code 的会话记录（JSONL）：逐条取出记录、取出每一次工具调用与它进行的时间窗、取出开工的时刻。

读会话记录只在这一处。gate-overlap.py 用它找「这个会话写过哪些门禁与钩子」，
handback-scratch.py 用它找「这个子 agent 在哪些时间窗里动过手、提到过哪些目录」；两边各写一份的话，
Claude Code 的记录格式一变，一边跟上了、另一边还按旧格式读，读不到就当「什么都没做」放行。

不单独跑，由别的脚本按路径载入（importlib），函数照原名调。
"""
import json
import re
from datetime import datetime

# 后台任务（run_in_background）的完成通知里带着发起它的那次工具调用的编号
TOOL_USE_ID_IN_NOTIFICATION_RE = re.compile(r'<tool-use-id>([A-Za-z0-9_-]+)</tool-use-id>')


def transcript_entries(transcript_path, must_contain):
    """逐行流式读会话记录（JSONL），只解析含 must_contain 的行（一个字符串，或几个里含任一个）：
    长会话的记录上百 MB，整份读进来再解析既慢又吃内存。"""
    needles = (must_contain,) if isinstance(must_contain, str) else tuple(must_contain)
    try:
        with open(transcript_path, encoding='utf-8', errors='replace') as transcript_file:
            for line in transcript_file:
                if not any(needle in line for needle in needles):
                    continue
                try:
                    entry = json.loads(line)
                except ValueError:
                    continue
                if isinstance(entry, dict):
                    yield entry
    except OSError:
        return


def content_blocks(entry):
    """一条记录的 content 块。Claude Code 写的是 {"message":{"content":[…]}}；顶层直接放 content 的也认。"""
    message = entry.get('message')
    content = message.get('content') if isinstance(message, dict) else entry.get('content')
    return [block for block in content if isinstance(block, dict)] if isinstance(content, list) else []


def tool_uses_in_transcript(transcript_path):
    """会话记录里每一次工具调用的（工具名, 输入）。一行解析不了就跳过那一行。"""
    tool_uses = []
    for entry in transcript_entries(transcript_path, '"tool_use"'):
        for block in content_blocks(entry):
            if block.get('type') == 'tool_use' and isinstance(block.get('input'), dict):
                tool_uses.append((block.get('name') or '', block['input']))
    return tool_uses


def first_timestamp(transcript_path):
    """会话记录里第一条带时间戳的记录的时间戳（ISO 8601 字符串）；一条都没有时是 None。
    会话记录按时间顺序写，第一条就是开工的时刻。"""
    for entry in transcript_entries(transcript_path, '"timestamp"'):
        if isinstance(entry.get('timestamp'), str):
            return entry['timestamp']
    return None


def epoch_seconds(timestamp_text):
    """ISO 8601 时间戳 → epoch 秒；认不出是 None。"""
    if not isinstance(timestamp_text, str):
        return None
    try:
        return datetime.fromisoformat(timestamp_text.replace('Z', '+00:00')).timestamp()
    except ValueError:
        return None


def text_of(value):
    """tool_result 的 content（字符串，或 [{"type":"text","text":…}] 这种块）拼成一段文本。"""
    if isinstance(value, str):
        return value
    if isinstance(value, list):
        return '\n'.join(block.get('text', '') for block in value if isinstance(block, dict) and isinstance(block.get('text'), str))
    return ''


def tool_calls(transcript_path):
    """每一次工具调用，按发起的先后排：
    {'id', 'name', 'input', 'started_at', 'ended_at', 'result_text', 'result_is_error'}，时刻是 epoch 秒。
    started_at 是发起那条记录的时刻；ended_at 是结果那条记录的时刻，后台跑的（输入里 run_in_background 为真）取它自己那条完成通知的时刻；
    还没有的 ended_at 是 None。result_is_error：结果那条标了 is_error（工具没执行成、被钩子拒了）。
    返回（调用列表, 认不出而没收的调用数：发起时刻认不出、或者 tool_use 块缺编号与输入）。"""
    calls = {}
    order = []
    unreadable_count = 0
    results = {}
    notifications = {}
    for entry in transcript_entries(transcript_path, ('"tool_use"', '"tool_result"', 'task-notification')):
        entry_seconds = epoch_seconds(entry.get('timestamp'))
        blocks = content_blocks(entry)
        for block in blocks:
            if block.get('type') == 'tool_use':
                if entry_seconds is None or not block.get('id') or not isinstance(block.get('input'), dict):
                    unreadable_count += 1
                    continue
                calls[block['id']] = {'id': block['id'], 'name': block.get('name') or '', 'input': block['input'],
                                      'started_at': entry_seconds, 'ended_at': None, 'result_text': '', 'result_is_error': False}
                order.append(block['id'])
            elif block.get('type') == 'tool_result' and block.get('tool_use_id'):
                results[block['tool_use_id']] = (entry_seconds, text_of(block.get('content')), block.get('is_error') is True)
        # 完成通知是单独一条记录（attachment 或 user），不在任何 tool_result 里
        if entry.get('type') != 'assistant' and not any(block.get('type') == 'tool_result' for block in blocks):
            for tool_use_id in TOOL_USE_ID_IN_NOTIFICATION_RE.findall(json.dumps(entry, ensure_ascii=False)):
                notifications[tool_use_id] = entry_seconds
    for call_id in order:
        call = calls[call_id]
        result_seconds, call['result_text'], call['result_is_error'] = results.get(call_id, (None, '', False))
        call['ended_at'] = notifications.get(call_id) if call['input'].get('run_in_background') is True else result_seconds
    return [calls[call_id] for call_id in order], unreadable_count


def assistant_texts(transcript_path):
    """agent 回复里的每一段文字：（时刻, 文字），时刻认不出的不收。"""
    texts = []
    for entry in transcript_entries(transcript_path, '"assistant"'):
        entry_seconds = epoch_seconds(entry.get('timestamp'))
        if entry.get('type') != 'assistant' or entry_seconds is None:
            continue
        for block in content_blocks(entry):
            if block.get('type') == 'text' and isinstance(block.get('text'), str):
                texts.append((entry_seconds, block['text']))
    return texts
