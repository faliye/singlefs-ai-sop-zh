#!/usr/bin/env bash
# hook-events: PreToolUse:Write PreToolUse:Edit PreToolUse:NotebookEdit PreToolUse:Bash PostToolUse:Bash
# gate-similar: pattern-process-guard.sh 同挂在 PreToolUse 的 Bash 上，但它判命令里按模式找进程的写法，这里判项目根下多没多出没登记的条目、命令写没写登记表，对象与判法都不同
# gate-similar: root-entries.py 判定全在它那里（门禁阶段「项目根的新条目」与这个钩子共用）；这里只把钩子的 JSON 转给它，并带自证
# gate-similar: gate-reuse-check.sh 它挂在 Stop 与 SubagentStop 上、判这一轮新写的门禁与钩子；触发点与对象都不同
# gate-similar: handback-scratch-check.sh 它挂在交回工具与 SubagentStop 上、判子 agent 交回前删没删自己建的编译目录与仓副本；触发点与对象都不同
# admission: always Claude Code 在每一次写文件与 Bash 调用前后调它，每一次都要现判
# run-condition: command python3 git
# Claude Code 钩子：项目根下不新建没登记的文件与目录，改登记表要用户确认（rules/command-safety.md「项目根下不新建文件与目录」）。
#
# 判定全在 scripts/root-entries.py 的 --hook，这里只转交钩子的 JSON：
#   PreToolUse 的 Write / Edit / MultiEdit / NotebookEdit：写到项目根下一个还不存在、也没登记的条目里，拒绝；写登记表 .claude/root-entries，要用户在界面上确认；
#   PreToolUse 的 Bash：命令写到登记表，要用户确认；同时记下项目根此刻有哪些条目；
#   PostToolUse 的 Bash：跑完多出来的、没登记的条目，报给 agent。
# 项目根取 CLAUDE_PROJECT_DIR，没有就取输入里的 cwd。
# 退出码：拦下 2（PreToolUse 不执行、PostToolUse 把 stderr 交给 agent）；放行 0（要用户确认时 stdout 是 permissionDecision 为 ask 的 JSON）；
#   判不了 1（Claude Code 照常执行，stderr 留一行原因）；准入与运行条件不满足 78。
#
# 怎么注册：在项目的 .claude/settings.json 里加三项（PreToolUse 两项、PostToolUse 一项）：
#   "PreToolUse":  [{"matcher": "Write|Edit|MultiEdit|NotebookEdit", "hooks": [{"type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR\"/.claude/singlefs-ai-sop/scripts/claude-hooks/root-entry-guard.sh"}]},
#                   {"matcher": "Bash", "hooks": [{"type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR\"/.claude/singlefs-ai-sop/scripts/claude-hooks/root-entry-guard.sh"}]}]
#   "PostToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR\"/.claude/singlefs-ai-sop/scripts/claude-hooks/root-entry-guard.sh"}]}]
# Bash 那一项已经挂着别的钩子（pattern-process-guard.sh）的，把这一条追加进同一个 hooks 列表里。
#
#   root-entry-guard.sh             从 stdin 读钩子的 JSON
#   root-entry-guard.sh --selftest  造一个临时项目，核写到没登记的新条目被拒、写进已有的、登记过的与本包自己要放在根下的放行、写登记表要确认、
#                                   Bash 跑完多出没登记的条目被报、登记过的不报、项目外的不管、输入坏了判不了
HOOK_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HOOK_DIRECTORY/../lib.sh"
preflight "${BASH_SOURCE[0]}" "$@"; set -- ${PREFLIGHT_ARGUMENTS[@]+"${PREFLIGHT_ARGUMENTS[@]}"}
JUDGE_SCRIPT="$(cd "$HOOK_DIRECTORY/.." && pwd)/root-entries.py"

if [[ "${1:-}" != "--selftest" ]]; then
  exec python3 "$JUDGE_SCRIPT" --hook
fi

selftest_directory="$(mktemp -d)"; trap 'rm -rf "${selftest_directory:?}"' EXIT
project_directory="$selftest_directory/project"
mkdir -p "$project_directory/.claude" "$project_directory/existing"
printf 'approved  # 用户同意放在根下的样本目录\n' > "$project_directory/.claude/root-entries"
export ROOT_ENTRY_GUARD_STATE_DIRECTORY="$selftest_directory/state"

failed_cases=()
checked_count=0
check_case() { # check_case <情形名> <期望退出码> <输出里要有的片段，空就不查> <钩子 JSON>
  local case_name="$1" expected_exit="$2" wanted_text="$3" hook_json="$4" case_output actual_exit=0
  checked_count=$((checked_count + 1))
  case_output="$(printf '%s' "$hook_json" | CLAUDE_PROJECT_DIR="$project_directory" bash "${BASH_SOURCE[0]}" 2>&1)" || actual_exit=$?
  if [[ "$actual_exit" -ne "$expected_exit" ]]; then
    failed_cases+=("$case_name: 期望退出码 $expected_exit，实际 $actual_exit；输出：${case_output:0:200}")
  elif [[ -n "$wanted_text" ]] && ! grep -Fq -- "$wanted_text" <<<"$case_output"; then
    failed_cases+=("$case_name: 输出里没有「$wanted_text」；输出：${case_output:0:200}")
  fi
}
write_json() { printf '{"hook_event_name":"PreToolUse","tool_name":"%s","session_id":"s","tool_input":{"%s":"%s"}}' "$1" "$2" "$3"; }
bash_json() { printf '{"hook_event_name":"%s","tool_name":"Bash","session_id":"s","tool_use_id":"%s","tool_input":{"command":"%s"}}' "$1" "$2" "$3"; }

check_case "写到已有目录里放行" 0 "" "$(write_json Write file_path "$project_directory/existing/note.md")"
check_case "在根下新建文件被拒" 2 "要在项目根下新建「scratch.log」" "$(write_json Write file_path "$project_directory/scratch.log")"
check_case "在根下新建目录被拒" 2 "要在项目根下新建「None」" "$(write_json Write file_path "$project_directory/None/output.txt")"
check_case "笔记本写到根下也被拒" 2 "要在项目根下新建「draft.ipynb」" "$(write_json NotebookEdit notebook_path "$project_directory/draft.ipynb")"
check_case "登记过的新条目放行" 0 "" "$(write_json Write file_path "$project_directory/approved/readme.md")"
check_case "本包自己要放在根下的不用登记" 0 "" "$(write_json Write file_path "$project_directory/CLAUDE.md")"
check_case "项目外的路径不管" 0 "" "$(write_json Write file_path "$selftest_directory/outside.txt")"
check_case "改登记表要用户确认" 0 '"permissionDecision": "ask"' "$(write_json Edit file_path "$project_directory/.claude/root-entries")"
check_case "Bash 写登记表要用户确认" 0 '"permissionDecision": "ask"' "$(bash_json PreToolUse registry-write "printf x >> .claude/root-entries")"
check_case "Bash 跑之前记下条目" 0 "" "$(bash_json PreToolUse made-junk "mkdir junk")"
mkdir "$project_directory/junk"
check_case "Bash 跑完多出没登记的条目被报" 2 "多出 1 个没登记的条目：junk" "$(bash_json PostToolUse made-junk "mkdir junk")"
check_case "Bash 跑之前记下条目（登记过的）" 0 "" "$(bash_json PreToolUse made-approved "mkdir approved")"
mkdir "$project_directory/approved"
check_case "Bash 跑完多出登记过的条目不报" 0 "" "$(bash_json PostToolUse made-approved "mkdir approved")"
check_case "Bash 跑完没记下跑之前的条目判不了" 1 "这一次没判" "$(bash_json PostToolUse never-recorded "true")"
check_case "输入不是 JSON 对象判不了" 1 "钩子输入不是 JSON 对象" "[1, 2]"

if ((${#failed_cases[@]} > 0)); then
  bad "root-entry-guard 自证失败（${#failed_cases[@]} 处）："
  for failed_case in "${failed_cases[@]}"; do
    say "        $failed_case"
  done
  howto "看上面失败的情形，修 scripts/root-entries.py 的 --hook 再跑；钩子自己的自证过不了，这道闸就不能信。"
  exit 1
fi
ok "root-entry-guard 自证：$checked_count 种情形判得都对"
exit 0
