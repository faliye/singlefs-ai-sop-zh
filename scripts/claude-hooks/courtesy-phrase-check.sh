#!/usr/bin/env bash
# hook-events: Stop SubagentStop
# gate-similar: gate-reuse-check.sh 同挂在 Stop 与 SubagentStop 上，但它判这一轮新写的门禁与钩子该不该单独存在；这里判最后一条回复里的客套话，对象与判定脚本都不同
# gate-similar: handback-scratch-check.sh 同挂 SubagentStop，判子 agent 交回前删没删自己建的目录；对象不同
# gate-similar: borrowed-convention-guard.sh 同样是转给一份 python 判定、判 agent 写出去的文字，但它挂在 PreToolUse 的派发与发消息上、判借用句；触发点与词表都不同
# gate-similar: unanswered-message-check.sh 同挂在 Stop 上、同样转给一份 python 判定，但它判别的会话发来的消息回了没有、读的是会话记录里收到的消息；这里判最后一条回复的文字，对象与判据都不同
# admission: always Claude Code 在 agent 每一次收工时调它，每一条回复都要现判
# run-condition: command python3
# Claude Code 的 Stop / SubagentStop 钩子：这一轮最后一条回复里有客套话（寒暄、道谢、道歉、夸提问、结尾问还要不要别的），
#   就拦下收工，要它删掉重写（rules/communication-discipline.md「不写客套」）。
#
# 判定全在 scripts/courtesy-phrase.py（它不是门禁阶段，只给这个钩子用），这里只转交钩子的 JSON，自证也由它做。
# 退出码：拦下 2（不让收工，stderr 交给 agent）；放行 0；判不了 1（不拦，stderr 留一行原因）；准入与运行条件不满足 78。
#
# 怎么注册：项目 .claude/settings.json 的 hooks 里加两项（Stop 与 SubagentStop 不带 matcher）；已经挂着别的钩子的，追加进同一个 hooks 列表：
#   "Stop":         [{"hooks": [{"type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR\"/.claude/singlefs-ai-sop/scripts/claude-hooks/courtesy-phrase-check.sh"}]}]
#   "SubagentStop": [{"hooks": [{"type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR\"/.claude/singlefs-ai-sop/scripts/claude-hooks/courtesy-phrase-check.sh"}]}]
#
#   courtesy-phrase-check.sh             从 stdin 读钩子的 JSON
#   courtesy-phrase-check.sh --selftest  转给 courtesy-phrase.py --selftest：红绿样本、整条钩子路径、弄坏开关
HOOK_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HOOK_DIRECTORY/../lib.sh"
preflight "${BASH_SOURCE[0]}" "$@"; set -- ${PREFLIGHT_ARGUMENTS[@]+"${PREFLIGHT_ARGUMENTS[@]}"}
JUDGE_SCRIPT="$(cd "$HOOK_DIRECTORY/.." && pwd)/courtesy-phrase.py"

if [[ "${1:-}" == "--selftest" ]]; then
  exec python3 "$JUDGE_SCRIPT" --selftest
fi
exec python3 "$JUDGE_SCRIPT" --hook
