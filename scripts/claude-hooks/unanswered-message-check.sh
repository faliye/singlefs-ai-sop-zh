#!/usr/bin/env bash
# hook-events: Stop
# gate-similar: courtesy-phrase-check.sh 同挂在 Stop 上、同样转给一份 python 判定，但它判最后一条回复里的客套话；这里判别的会话发来的消息回了没有，对象与判定脚本都不同
# gate-similar: gate-reuse-check.sh 同挂在 Stop 上，但它判这一轮新写的门禁与钩子该不该单独存在；对象不同
# gate-similar: borrowed-convention-guard.sh 同样看 SendMessage，但它挂在 PreToolUse 上、判发出去的消息里的借用句；这里在收工时判该回的消息回了没有
# admission: always Claude Code 在 agent 每一次收工时调它，收到的消息回没回要现判
# run-condition: command python3
# Claude Code 的 Stop 钩子：别的会话发来的消息，到收工时既没回过去、回复里也没写「不回 <会话名>：<理由>」，
#   就拦下收工，把没回的逐条列给它（rules/communication-discipline.md「收工前核一遍别的会话发来的消息」）。同一份清单只拦一次。
#
# 判定全在 scripts/unanswered-message.py（它不是门禁阶段，只给这个钩子用），这里只转交钩子的 JSON，自证也由它做。
# 退出码：拦下 2（不让收工，stderr 交给 agent）；放行 0；判不了 1（不拦，stderr 留一行原因）；准入与运行条件不满足 78。
#
# 怎么注册：项目 .claude/settings.json 的 hooks 里加一项（Stop 不带 matcher）；已经挂着别的钩子的，追加进同一个 hooks 列表：
#   "Stop": [{"hooks": [{"type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR\"/.claude/singlefs-ai-sop/scripts/claude-hooks/unanswered-message-check.sh"}]}]
#
#   unanswered-message-check.sh             从 stdin 读钩子的 JSON
#   unanswered-message-check.sh --selftest  转给 unanswered-message.py --selftest：红绿样本、整条钩子路径、弄坏开关
HOOK_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HOOK_DIRECTORY/../lib.sh"
preflight "${BASH_SOURCE[0]}" "$@"; set -- ${PREFLIGHT_ARGUMENTS[@]+"${PREFLIGHT_ARGUMENTS[@]}"}
JUDGE_SCRIPT="$(cd "$HOOK_DIRECTORY/.." && pwd)/unanswered-message.py"

if [[ "${1:-}" == "--selftest" ]]; then
  exec python3 "$JUDGE_SCRIPT" --selftest
fi
exec python3 "$JUDGE_SCRIPT" --hook
