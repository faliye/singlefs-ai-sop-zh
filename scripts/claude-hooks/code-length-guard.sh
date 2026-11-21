#!/usr/bin/env bash
# hook-events: PreToolUse:Write PreToolUse:Edit PreToolUse:MultiEdit
# gate-similar: root-entry-guard.sh 同挂在 PreToolUse 的 Write、Edit、MultiEdit 上，但它判写到项目根下的新条目登没登记；这里判写完之后代码文件有多长，对象与判法都不同
# gate-similar: code-length.py 判定全在它那里（门禁阶段「代码文件长度」与这个钩子共用）；这里只把钩子的 JSON 转给它，并带端到端的自证
# gate-similar: pattern-process-guard.sh 它挂在 PreToolUse 的 Bash 上、判命令里按模式找进程的写法；触发点与对象都不同
# admission: always Claude Code 在每一次写文件之前调它，每一次都要现判
# run-condition: command python3
# Claude Code 钩子：一个代码文件不算注释不超过 2000 行（rules/code-discipline.md「一个代码文件不超过 2000 行」）。
#
# 判定全在 scripts/code-length.py 的 --hook，这里只转交钩子的 JSON：
#   PreToolUse 的 Write / Edit / MultiEdit：代码文件（.rs、.py、.sh、.wgsl）写完之后不算注释超过 2000 行、而且比写之前长，拒绝；
#   已经超了的文件只许改短。项目外的文件、门禁不扫的目录里的文件不判。
# 项目根取 CLAUDE_PROJECT_DIR，没有就取输入里的 cwd。
# 退出码：拦下 2（不执行这一次写，stderr 交给 agent）；放行 0；判不了 1（Claude Code 照常执行，stderr 留一行原因）；准入与运行条件不满足 78。
#
# 怎么注册：在项目的 .claude/settings.json 的 PreToolUse 里，matcher 为 "Write|Edit|MultiEdit|NotebookEdit" 的那一项的 hooks 列表里追加：
#   {"type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR\"/.claude/singlefs-ai-sop/scripts/claude-hooks/code-length-guard.sh"}
# 还没有这一项的，新加一项 {"matcher": "Write|Edit|MultiEdit|NotebookEdit", "hooks": [上面那一条]}。
#
#   code-length-guard.sh             从 stdin 读钩子的 JSON
#   code-length-guard.sh --selftest  造一个临时项目，经 bash 走一遍：写成超限的新文件被拒、正好 2000 行放行、已超的文件改短放行、
#                                    再加长被拒、不是代码文件不管、输入坏了判不了
HOOK_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HOOK_DIRECTORY/../lib.sh"
preflight "${BASH_SOURCE[0]}" "$@"; set -- ${PREFLIGHT_ARGUMENTS[@]+"${PREFLIGHT_ARGUMENTS[@]}"}
JUDGE_SCRIPT="$(cd "$HOOK_DIRECTORY/.." && pwd)/code-length.py"

if [[ "${1:-}" != "--selftest" ]]; then
  exec python3 "$JUDGE_SCRIPT" --hook
fi

selftest_directory="$(mktemp -d)"; trap 'rm -rf "${selftest_directory:?}"' EXIT
project_directory="$selftest_directory/project"
mkdir -p "$project_directory/src" "$project_directory/docs"
long_file="$project_directory/src/long.sh"
for ((line_index = 0; line_index < 2100; line_index++)); do printf 'echo hi\n'; done > "$long_file"

failed_cases=()
checked_count=0
check_case() { # check_case <情形名> <期望退出码> <输出里要有的片段，空就不查> <钩子 JSON>
  local case_name="$1" expected_exit="$2" wanted_text="$3" hook_json="$4" case_output actual_exit=0
  checked_count=$((checked_count + 1))
  case_output="$(printf '%s' "$hook_json" | CLAUDE_PROJECT_DIR="$project_directory" bash "${BASH_SOURCE[0]}" 2>&1)" || actual_exit=$?
  if [[ "$actual_exit" -ne "$expected_exit" ]]; then
    failed_cases+=("$case_name: 期望退出码 $expected_exit，实际 $actual_exit；输出：$(clip_text 200 <<<"$case_output")")
  elif [[ -n "$wanted_text" ]] && ! grep -Fq -- "$wanted_text" <<<"$case_output"; then
    failed_cases+=("$case_name: 输出里没有「$wanted_text」；输出：$(clip_text 200 <<<"$case_output")")
  fi
}
repeated_lines() { # repeated_lines <一行的内容，JSON 里的写法> <行数>
  local line_index; for ((line_index = 0; line_index < $2; line_index++)); do printf '%s' "$1"; done
}
write_json() { printf '{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"%s","content":"%s"}}' "$1" "$2"; }
edit_json() { printf '{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"%s","old_string":"%s","new_string":"%s"}}' "$1" "$2" "$3"; }

check_case "写成 2001 行的新文件被拒" 2 "不算注释有 2001 行" "$(write_json "$project_directory/src/new.py" "$(repeated_lines 'value = 1\n' 2001)")"
check_case "写成正好 2000 行的新文件放行" 0 "" "$(write_json "$project_directory/src/new.py" "$(repeated_lines 'value = 1\n' 2000)")"
check_case "已经超了的文件改短放行" 0 "" "$(edit_json "$long_file" 'echo hi\necho hi\n' 'echo hi\n')"
check_case "已经超了的文件再加长被拒" 2 "写之前 2100 行" "$(edit_json "$long_file" 'echo hi\n' 'echo hi\necho more\n')"
check_case "不是代码文件不管" 0 "" "$(write_json "$project_directory/docs/notes.md" "$(repeated_lines 'text\n' 3000)")"
check_case "输入不是 JSON 对象判不了" 1 "钩子输入不是 JSON 对象" "[1, 2]"

if ((${#failed_cases[@]} > 0)); then
  bad "code-length-guard 自证失败（${#failed_cases[@]} 处）："
  for failed_case in "${failed_cases[@]}"; do
    say "        $failed_case"
  done
  howto "看上面失败的情形，修 scripts/code-length.py 的 --hook 再跑；钩子自己的自证过不了，这道闸就不能信。"
  exit 1
fi
ok "code-length-guard 自证：$checked_count 种情形判得都对"
exit 0
