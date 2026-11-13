#!/usr/bin/env bash
# hook-events: SessionStart UserPromptSubmit
# gate-similar: 无 查过 gate-overlap.py --list 列出的全部钩子：没有一个挂 SessionStart 或 UserPromptSubmit；转给 python 判定的几个（courtesy-phrase-check.sh、unanswered-message-check.sh、borrowed-convention-guard.sh、handback-scratch-check.sh）都判 agent 做没做对，这里只改会话标题
# admission: always Claude Code 在会话启动、恢复与每次提交提示时调它，标题要现写
# run-condition: command python3
# Claude Code 的 SessionStart 与 UserPromptSubmit 钩子：会话标题开头写会话编号，格式 `(编号) 标题`
#   （rules/communication-discipline.md「会话标题开头写编号」）。编号取 Claude Code 给会话起的默认名 `<目录名>-<编号>` 里的那一段。
#
# 写法全在 scripts/session-number-title.py（它不是门禁阶段，只给这个钩子用），这里只转交钩子的 JSON，自证也由它做。
# 退出码：写了或不用写 0；取不到编号 1（不拦，stderr 留一行原因）；准入与运行条件不满足 78。从不退 2：UserPromptSubmit 上退 2 会挡掉用户的提示。
#
# 怎么注册：项目 .claude/settings.json 的 hooks 里加两项（都不带 matcher）；已经挂着别的钩子的，追加进同一个 hooks 列表：
#   "SessionStart":     [{"hooks": [{"type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR\"/.claude/singlefs-ai-sop/scripts/claude-hooks/session-number-title.sh"}]}]
#   "UserPromptSubmit": [{"hooks": [{"type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR\"/.claude/singlefs-ai-sop/scripts/claude-hooks/session-number-title.sh"}]}]
#
#   session-number-title.sh             从 stdin 读钩子的 JSON
#   session-number-title.sh --selftest  转给 session-number-title.py --selftest：样本、整条钩子路径、弄坏开关
HOOK_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HOOK_DIRECTORY/../lib.sh"
preflight "${BASH_SOURCE[0]}" "$@"; set -- ${PREFLIGHT_ARGUMENTS[@]+"${PREFLIGHT_ARGUMENTS[@]}"}
JUDGE_SCRIPT="$(cd "$HOOK_DIRECTORY/.." && pwd)/session-number-title.py"

if [[ "${1:-}" == "--selftest" ]]; then
  exec python3 "$JUDGE_SCRIPT" --selftest
fi
exec python3 "$JUDGE_SCRIPT" --hook
