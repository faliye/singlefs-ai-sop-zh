#!/usr/bin/env bash
# hook-events: PreToolUse:SendMessage
# gate-similar: borrowed-convention-guard.sh 同挂 PreToolUse 的 SendMessage，但它判消息正文里的借用句、还挂 Agent 与 Task；这一道只判收件的会话还在不在跑，读的是会话登记，判据不同
# gate-similar: unanswered-message-check.sh 同样管跨会话消息，但挂在 Stop 上、判收到的消息回没回；触发点不同
# gate-similar: session-number-title.sh 同样读 Claude Code 的会话登记，但挂在 SessionStart 与 UserPromptSubmit 上、改会话标题，不拦什么
# admission: always Claude Code 在每一次给别的会话发消息之前调它，对象活着没有要现判
# run-condition: command python3
# Claude Code 钩子：给别的会话发消息，只发给正在跑的会话；对象长得像会话名、而本机会话登记里没有进程还在的会话对得上它，
#   就不让发，列出正在跑的会话（rules/communication-discipline.md「找别的会话，只找正在跑的」）。
#
# 判定全在 scripts/message-target.py（它不是门禁阶段，只给这个钩子用），这里只转交钩子的 JSON，自证也由它做。
# 退出码：拦下 2（这一次不发，stderr 交给 agent）；放行 0；判不了 1（照常发，stderr 留一行原因）；准入与运行条件不满足 78。
#
# 怎么注册：在项目的 .claude/settings.json 的 hooks.PreToolUse 里加一项（已有 SendMessage 的 matcher 的，追加进它的 hooks 列表）：
#   {"matcher": "SendMessage", "hooks": [{"type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR\"/.claude/singlefs-ai-sop/scripts/claude-hooks/message-target-guard.sh"}]}
#
#   message-target-guard.sh             从 stdin 读钩子的 JSON
#   message-target-guard.sh --selftest  转给 message-target.py --selftest：样本、整条钩子路径、弄坏开关
HOOK_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HOOK_DIRECTORY/../lib.sh"
preflight "${BASH_SOURCE[0]}" "$@"; set -- ${PREFLIGHT_ARGUMENTS[@]+"${PREFLIGHT_ARGUMENTS[@]}"}
JUDGE_SCRIPT="$(cd "$HOOK_DIRECTORY/.." && pwd)/message-target.py"

if [[ "${1:-}" == "--selftest" ]]; then
  exec python3 "$JUDGE_SCRIPT" --selftest
fi
exec python3 "$JUDGE_SCRIPT" --hook
