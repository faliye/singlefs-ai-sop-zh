#!/usr/bin/env bash
# hook-events: SessionStart
# gate-similar: session-number-title.sh 同挂 SessionStart，但它只改会话标题、不往上下文里补东西，也不跑项目的检查项
# gate-similar: discarded-output-count-check.sh 同样只记不拦、往检出记录追加一行，但它挂 PostToolUse、判一条 Bash 命令
# gate-similar: unanswered-message-check.sh 同样转给一份 python 判定，但它挂 Stop、判收到的消息回没回
# admission: always Claude Code 在每一次会话启动、恢复、清空与压缩之后调它，检查项要现跑
# run-condition: command python3
# Claude Code 的 SessionStart 钩子：会话启动、恢复、清空与压缩之后的检测，只报不改
#   （rules/communication-discipline.md「会话启动与压缩之后的检测」）。
#   压缩之后补一段用本包语言写的对齐提示；每种 source 跑项目在 .claude/session-checks/ 下登记的检查项，输出拼进上下文。
#   检查项没跑成、输入解不开也照常放行，在上下文或 stderr 写一行「没查成」，检出记录追加一行。
#
# 判定全在 scripts/session-checks.py（它不是门禁阶段），这里只转交钩子的 JSON，自证也由它做。
# 检查项的写法（文件头两行、执行位、--selftest）在 session-checks.py 的文件头；登记得对不对由 hooks-registered.sh 调 --check-items 判。
# 退出码：恒 0；准入与运行条件不满足 78。
#
# 怎么注册：项目 .claude/settings.json 的 hooks.SessionStart 里加一项（matcher 写 startup|resume|clear|compact，或不写 matcher）；
#   已经挂着别的 SessionStart 钩子的，追加进同一个 hooks 列表：
#   "SessionStart": [{"matcher": "startup|resume|clear|compact", "hooks": [{"type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR\"/.claude/singlefs-ai-sop/scripts/claude-hooks/session-checks.sh"}]}]
#
#   session-checks.sh             从 stdin 读钩子的 JSON
#   session-checks.sh --selftest  转给 session-checks.py --selftest：样本、整条钩子路径、弄坏开关
HOOK_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HOOK_DIRECTORY/../lib.sh"
preflight "${BASH_SOURCE[0]}" "$@"; set -- ${PREFLIGHT_ARGUMENTS[@]+"${PREFLIGHT_ARGUMENTS[@]}"}
JUDGE_SCRIPT="$(cd "$HOOK_DIRECTORY/.." && pwd)/session-checks.py"

if [[ "${1:-}" == "--selftest" ]]; then
  exec python3 "$JUDGE_SCRIPT" --selftest
fi
exec python3 "$JUDGE_SCRIPT" --hook
