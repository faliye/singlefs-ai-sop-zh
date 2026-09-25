#!/usr/bin/env bash
# Claude Code 钩子共用的：读钩子的输入（gate-reuse-check.sh 与 handback-scratch-check.sh 都用），与「同一份红不连拦两次」（gate-reuse-check.sh 用）。
# claude-hooks/ 下的钩子 source 它；只定义函数，不改 shell 选项。
# 各写一份的话，Claude Code 的钩子输入一变，一边跟上了、另一边还按旧字段读（rules/sop-first.md「加门禁或钩子之前，先找已有的」）。
#
#   claude_hook_fields < 钩子 JSON
#       一行一样打印八样：hook_event_name、stop_hook_active（true / false）、agent_transcript_path、transcript_path、cwd、
#       session_id、agent_id、tool_name。session_id 与 agent_id 只留 [A-Za-z0-9_-]，空的记成 no-session / main（拿来拼路径与状态文件名）。
#       子 agent 里触发的 PreToolUse 带 agent_id，而 transcript_path 是主 agent 那一份；SubagentStop 另带 agent_transcript_path。
#       输入不是 JSON 对象时退出码 3，一行都不打。
#   stop_hook_already_shown <状态文件> <stop_hook_active> <判定输出>
#       这一段是被收工钩子拦回来之后的续跑（stop_hook_active 为 true），而判定输出与上一次拦下时一字不差：返回 0，调用方放行——
#       agent 已经看过这一份，再拦只会原地打转。其余情形把这一份的指纹记进状态文件、返回 1，调用方拦下。
#       结果变了（改了一半、又新建了一份）照样再拦。Claude Code 自己也在连拦 8 次之后强制收工。

IFS= read -r -d '' CLAUDE_HOOK_FIELDS_PROGRAM <<'PY' || true
import json, re, sys
try:
    hook_input = json.load(sys.stdin)
except ValueError:
    sys.exit(3)
if not isinstance(hook_input, dict):
    sys.exit(3)
def text(key):
    value = hook_input.get(key)
    return value.replace('\n', ' ') if isinstance(value, str) else ''
print(text('hook_event_name'))
print('true' if hook_input.get('stop_hook_active') is True else 'false')
print(text('agent_transcript_path'))
print(text('transcript_path'))
print(text('cwd'))
print(re.sub(r'[^A-Za-z0-9_-]', '_', text('session_id')) or 'no-session')
print(re.sub(r'[^A-Za-z0-9_-]', '_', text('agent_id')) or 'main')
print(text('tool_name'))
PY

claude_hook_fields() {
  python3 -c "$CLAUDE_HOOK_FIELDS_PROGRAM"
}

stop_hook_already_shown() { # stop_hook_already_shown <状态文件> <stop_hook_active> <判定输出> → 0 放行、1 拦下
  local state_file="$1" stop_hook_active="$2" judgement="$3" fingerprint
  fingerprint="$(printf '%s' "$judgement" | sha256sum | cut -d' ' -f1)"
  if [[ "$stop_hook_active" == true && -f "$state_file" && "$(cat "$state_file" 2>/dev/null)" == "$fingerprint" ]]; then
    return 0
  fi
  mkdir -p "$(dirname "$state_file")" 2>/dev/null && printf '%s\n' "$fingerprint" > "$state_file" 2>/dev/null
  return 1
}
