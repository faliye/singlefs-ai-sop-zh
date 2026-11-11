#!/usr/bin/env bash
# hook-events: PreToolUse:Agent PreToolUse:Task PreToolUse:SendMessage
# gate-similar: root-entry-guard.sh 同样是转给一份 python 判定的钩子，但挂在写文件与 Bash 上、判项目根下的新条目，工具与对象都不同
# gate-similar: pattern-process-guard.sh 同挂 PreToolUse，但只挂 Bash、判命令里按模式找进程的写法，matcher 没有交集
# gate-similar: handback-scratch-check.sh 它挂在交回工具与 SubagentStop 上、判子 agent 交回前删没删自己建的目录；触发点与对象都不同
# admission: always Claude Code 在每一次派子 agent、给别的会话发消息之前调它，每一次都要现判
# run-condition: command python3
# Claude Code 钩子：派给子 agent 的提示、发给别的会话的消息里，借用别处做法的句子（「与 X 同口径」「照 X 那一份」）
#   同一句里要带 `路径:行号` 或原文引用（rules/communication-discipline.md「转述别处的做法，带出处或原文」）。
#
# 判定全在 scripts/borrowed-convention.py（它不是门禁阶段，只给这个钩子用），这里只转交钩子的 JSON，自证也由它做。
# 退出码：拦下 2（这一次不派，stderr 交给 agent）；放行 0；判不了 1（照常执行，stderr 留一行原因）；准入与运行条件不满足 78。
#
# 怎么注册：在项目的 .claude/settings.json 的 hooks.PreToolUse 里加一项
#   {"matcher": "Agent|Task|SendMessage", "hooks": [{"type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR\"/.claude/singlefs-ai-sop/scripts/claude-hooks/borrowed-convention-guard.sh"}]}
#
#   borrowed-convention-guard.sh             从 stdin 读钩子的 JSON
#   borrowed-convention-guard.sh --selftest  转给 borrowed-convention.py --selftest：红绿样本、整条钩子路径、弄坏开关
HOOK_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HOOK_DIRECTORY/../lib.sh"
preflight "${BASH_SOURCE[0]}" "$@"; set -- ${PREFLIGHT_ARGUMENTS[@]+"${PREFLIGHT_ARGUMENTS[@]}"}
JUDGE_SCRIPT="$(cd "$HOOK_DIRECTORY/.." && pwd)/borrowed-convention.py"

if [[ "${1:-}" == "--selftest" ]]; then
  exec python3 "$JUDGE_SCRIPT" --selftest
fi
exec python3 "$JUDGE_SCRIPT" --hook
