#!/usr/bin/env bash
# hook-events: Stop SubagentStop
# gate-similar: gate-overlap.py 判定全在它那里；这个钩子只负责在 agent 收工时拿这个会话写过的文件调它，有红就拦下收工
# gate-similar: hooks-registered.sh 它判钩子注册着没有、自检过没有，不判这一轮新建的钩子该不该单独存在
# gate-similar: pattern-process-guard.sh 它挂在 PreToolUse 的 Bash 上、在命令执行前拦；这里挂在 Stop 与 SubagentStop 上，触发点不同
# gate-similar: handback-scratch-check.sh 同挂在 SubagentStop 上，但它判子 agent 交回时临时目录里还留着自己建的编译目录与仓副本，这里判这一轮新写的门禁与钩子该不该单独存在，对象与放行条件都不同；读钩子输入那一段两边共用 claude-hook-lib.sh
# Claude Code 的 Stop / SubagentStop 钩子（收工的尾门禁）：agent 这一轮新建了门禁或钩子，收工前先自检它是不是非得单独加。
#
# 主 agent 收工触发 Stop，子 agent 收工触发 SubagentStop，两个都要注册。
# 判定全在 scripts/gate-overlap.py 的 --touched-by：只看这个会话开始以来、它自己写过的门禁与钩子。
# 新建的没写 `# gate-similar:` / `# hook-events:`、同一触发点上或字面上很像的已有门禁与钩子没点名、
# 或整段抄了已有的一份，就拦下收工，把判定输出交给 agent（该点名的、最像的几份、查全表的命令都在里面）。
# agent 要做的：能并进已有的就并进去；非单独加不可，在新文件里逐个写
#   # gate-similar: <已有的文件名> <为什么不并进它>
# 写完再收工就放行（rules/sop-first.md「加门禁或钩子之前，先找已有的」）。
#
# 不死循环：拦下时把判定输出的指纹记在状态目录里（按 session_id 与 agent_id 分开），续跑里同一份红不连拦两次；
#   放行条件在 scripts/claude-hook-lib.sh 的 stop_hook_already_shown。没改的由门禁阶段「门禁查重」在提交前判红。
# 会话记录取 agent_transcript_path（子 agent 自己的那份），没有就取 transcript_path；两个都没有就放行。
# 项目根取 CLAUDE_PROJECT_DIR，没有就取输入里的 cwd。
# 状态目录默认 ${TMPDIR:-/tmp}/gate-reuse-check，GATE_REUSE_CHECK_STATE_DIRECTORY 可改。
# 退出码：拦下 2（Claude Code 不让收工，把 stderr 交给 agent）；放行 0；
#   输入不是 JSON 对象、或判定脚本判不了 1（不拦，stderr 只给人看）——「没判」不记成「判过」。
#
# 怎么注册：项目 .claude/settings.json 的 hooks 里加两项（Stop 与 SubagentStop 不带 matcher）：
#   "Stop":         [{"hooks": [{"type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR\"/.claude/singlefs-ai-sop/scripts/claude-hooks/gate-reuse-check.sh"}]}]
#   "SubagentStop": [{"hooks": [{"type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR\"/.claude/singlefs-ai-sop/scripts/claude-hooks/gate-reuse-check.sh"}]}]
#
#   gate-reuse-check.sh             从 stdin 读钩子的 JSON
#   gate-reuse-check.sh --selftest  造一个临时仓与几份会话记录，核拦得下、写了声明就放行、只读的命令不算写、
#                                   Bash 写进去的也算、别的会话写的不拦、往已有的钩子里追加不算新建、同一份红不连拦两次、
#                                   子 agent 认它自己的会话记录、判不了不拦
set -uo pipefail
HOOK_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_ROOT="$(cd "$HOOK_DIRECTORY/../.." && pwd)"
GATE_OVERLAP="$PACKAGE_ROOT/scripts/gate-overlap.py"
STATE_DIRECTORY="${GATE_REUSE_CHECK_STATE_DIRECTORY:-${TMPDIR:-/tmp}/gate-reuse-check}"
source "$PACKAGE_ROOT/scripts/claude-hook-lib.sh"

judge_stop() { # judge_stop < 钩子 JSON → 退出码 0 放行、2 拦下、1 没判
  local fields hook_event_name stop_hook_active agent_transcript main_transcript transcript session_directory session_id agent_id
  local project_root judgement judgement_exit_code
  if ! fields="$(claude_hook_fields)"; then
    printf '%s\n' "! gate-reuse-check：钩子输入不是 JSON 对象，这一次收工没判（放行）。" \
      "  看一眼 .claude/settings.json 里这个钩子是不是挂在 Stop / SubagentStop 上。" >&2
    return 1
  fi
  { IFS= read -r hook_event_name; IFS= read -r stop_hook_active; IFS= read -r agent_transcript; IFS= read -r main_transcript
    IFS= read -r session_directory; IFS= read -r session_id; IFS= read -r agent_id; } <<<"$fields"
  # Stop 与 SubagentStop 同样判（hook_event_name 不分流）；子 agent 认它自己的那份会话记录
  transcript="${agent_transcript:-$main_transcript}"
  [[ -n "$transcript" && -f "$transcript" ]] || return 0
  project_root="${CLAUDE_PROJECT_DIR:-$session_directory}"
  [[ -n "$project_root" && -d "$project_root" ]] || return 0
  # 外层设的 diff 窗口不带进来：收工钩子按这个会话开始的时刻算
  judgement="$(env -u GATE_DIFF_BASE -u GATE_BASE python3 "$GATE_OVERLAP" --touched-by "$transcript" "$project_root" 2>&1)"
  judgement_exit_code=$?
  case "$judgement_exit_code" in
    0|77) return 0 ;;
    1) ;;
    *)
      printf '%s\n' "! gate-reuse-check：判定脚本 $GATE_OVERLAP 退出码 $judgement_exit_code（判不了），这一次收工没判（放行）。它的输出：" \
        "$judgement" >&2
      return 1 ;;
  esac
  if stop_hook_already_shown "$STATE_DIRECTORY/$session_id-$agent_id" "$stop_hook_active" "$judgement"; then
    return 0
  fi
  {
    printf '%s\n' '✗ 收工前先自检：这一轮你新建或改动了门禁、钩子，下面几处还没说清它为什么非得单独存在（或者整段抄了已有的一份）。' \
      '→ 怎么办：逐条看下面的判定。能并进已有的门禁或钩子，就把判据并进去、不再单独留这一份；' \
      '    非单独加不可，在新文件里逐个写 # gate-similar: <已有的文件名> <为什么不并进它>（判定里点了名的每一份都要写到）；' \
      '    只是共用一段逻辑，抽成共用的库，两边都调它。' \
      '    点到的文件不是你这一轮建的，别动它，回一句说明就行——几个会话同时在一个仓里干活时，那是别人的半成品。' \
      "    规矩见 $PACKAGE_ROOT/rules/sop-first.md「加门禁或钩子之前，先找已有的」。" \
      ''
    printf '%s\n' "$judgement"
  } >&2
  return 2
}

run_selftest() {
  local scratch project base_date session_date passed=0 failed=0
  scratch="$(mktemp -d)"
  project="$scratch/project"
  # 收工钩子的窗口从「会话开始之前的最后一个提交」算起：起点提交钉在会话记录的第一个时间戳之前
  base_date="$(date -u -d '-2 days' +%Y-%m-%dT%H:%M:%SZ)"
  session_date="$(date -u -d '-1 day' +%Y-%m-%dT%H:%M:%SZ)"
  mkdir -p "$project/.claude/hooks"
  git -C "$project" init -q
  printf '#!/usr/bin/env bash\n# 已有的钩子：拦 Bash 里的一种写法\necho "拦一种写法"\n' > "$project/.claude/hooks/old-guard.sh"
  printf '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"bash .claude/hooks/old-guard.sh"},{"type":"command","command":"bash .claude/hooks/new-guard.sh"}]}]}}\n' \
    > "$project/.claude/settings.json"
  git -C "$project" add -A
  GIT_COMMITTER_DATE="$base_date" GIT_AUTHOR_DATE="$base_date" \
    git -C "$project" -c user.name=selftest -c user.email=selftest@invalid commit -qm base
  printf '#!/usr/bin/env bash\n# 新加的钩子：拦 Bash 里的另一种写法\necho "拦另一种写法"\n' > "$project/.claude/hooks/new-guard.sh"

  transcript_with() { # transcript_with <文件名> <工具名> <输入的 JSON 对象>：写一份只有这一次工具调用的会话记录
    printf '{"type":"user","timestamp":"%s","message":{"role":"user","content":"开工"}}\n{"type":"assistant","timestamp":"%s","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"%s","input":%s}]}}\n' \
      "$session_date" "$session_date" "$2" "$3" > "$scratch/$1"
  }
  transcript_with writes.jsonl Write "{\"file_path\":\"$project/.claude/hooks/new-guard.sh\",\"content\":\"…\"}"
  transcript_with reads.jsonl Read "{\"file_path\":\"$project/.claude/hooks/new-guard.sh\"}"
  transcript_with runs-with-redirect.jsonl Bash '{"command":"bash .claude/hooks/new-guard.sh --selftest > /tmp/log 2>&1 | tail -3; cp .claude/hooks/new-guard.sh /tmp/backup.sh"}'
  transcript_with bash-heredoc.jsonl Bash '{"command":"cat > .claude/hooks/new-guard.sh <<'"'"'EOF'"'"'\necho > not-a-target\nEOF"}'
  transcript_with bash-cd.jsonl Bash '{"command":"cd .claude/hooks && printf x > new-guard.sh"}'
  transcript_with edits-existing.jsonl Edit "{\"file_path\":\"$project/.claude/hooks/old-guard.sh\",\"old_string\":\"a\",\"new_string\":\"b\"}"

  stop_input() { # stop_input <事件> <stop_hook_active> <会话记录> [子 agent 自己的会话记录]
    printf '{"hook_event_name":"%s","session_id":"selftest-%s","stop_hook_active":%s,"transcript_path":"%s","cwd":"%s"%s}' \
      "$1" "$$" "$2" "$scratch/$3" "$project" "${4:+,\"agent_id\":\"sub\",\"agent_transcript_path\":\"$scratch/$4\"}"
  }
  expect_stop() { # expect_stop <情形> <期望退出码> <输出里要有的片段或空> <钩子 JSON>
    local label="$1" wanted_exit_code="$2" wanted_text="$3" output exit_code
    output="$(printf '%s' "$4" | env -u CLAUDE_PROJECT_DIR GATE_REUSE_CHECK_STATE_DIRECTORY="$scratch/state" \
      bash "$HOOK_DIRECTORY/gate-reuse-check.sh" 2>&1)"
    exit_code=$?
    if [[ "$exit_code" == "$wanted_exit_code" && ( -z "$wanted_text" || "$output" == *"$wanted_text"* ) ]]; then
      passed=$((passed + 1))
    else
      failed=$((failed + 1))
      printf '  ✗ 自检「%s」：期望退出 %s%s，实测 %s\n' "$label" "$wanted_exit_code" "${wanted_text:+、输出含「$wanted_text」}" "$exit_code"   # gate-lint:detail
      printf '%s\n' "$output" | sed 's/^/      /'
    fi
  }
  expect_stop "新建的钩子没写 gate-similar 就拦" 2 "new-guard.sh 是新加的，没写 gate-similar" "$(stop_input Stop false writes.jsonl)"
  expect_stop "拦的时候点名同一触发点上的已有钩子" 2 "old-guard.sh  挂在同一个触发点上" "$(stop_input Stop false writes.jsonl)"
  expect_stop "同一份红在续跑里不连拦两次" 0 "" "$(stop_input Stop true writes.jsonl)"
  expect_stop "Bash 用 heredoc 写进去的也算" 2 "new-guard.sh 是新加的" "$(stop_input Stop false bash-heredoc.jsonl)"
  expect_stop "Bash 先 cd 再写的也算" 2 "new-guard.sh 是新加的" "$(stop_input Stop false bash-cd.jsonl)"
  expect_stop "只读、只跑、只备份的命令不算写" 0 "" "$(stop_input Stop false runs-with-redirect.jsonl)"
  expect_stop "别的会话写的钩子不拦这个会话" 0 "" "$(stop_input Stop false reads.jsonl)"
  printf 'echo "多拦一种写法"\n' >> "$project/.claude/hooks/old-guard.sh"
  expect_stop "往开工前就有的钩子里追加不算新建" 0 "" "$(stop_input Stop false edits-existing.jsonl)"
  expect_stop "子 agent 认它自己的会话记录" 2 "new-guard.sh 是新加的" "$(stop_input SubagentStop false reads.jsonl writes.jsonl)"
  expect_stop "输入不是 JSON 不拦" 1 "不是 JSON 对象" "不是 JSON"
  cp "$project/.claude/settings.json" "$scratch/settings.json.good"
  printf '{ 坏掉的 JSON\n' > "$project/.claude/settings.json"
  expect_stop "判定脚本判不了时不拦" 1 "判不了" "$(stop_input Stop false writes.jsonl)"
  cp "$scratch/settings.json.good" "$project/.claude/settings.json"
  # 改了一半：写了 hook-events 与「无」，同一触发点上的 old-guard 还没点名——判定结果变了，续跑里照样再拦
  printf '#!/usr/bin/env bash\n# hook-events: PreToolUse\n# gate-similar: 无 查过全表，没有管同一件事的\necho "拦另一种写法"\n' \
    > "$project/.claude/hooks/new-guard.sh"
  expect_stop "续跑里结果变了照样再拦" 2 "old-guard.sh  挂在同一个触发点上" "$(stop_input Stop true writes.jsonl)"
  printf '#!/usr/bin/env bash\n# hook-events: PreToolUse\n# gate-similar: old-guard.sh 它拦的是另一类命令，拒绝时给的出路也不同\necho "拦另一种写法"\n' \
    > "$project/.claude/hooks/new-guard.sh"
  expect_stop "写明为什么不并进已有的就放行" 0 "" "$(stop_input Stop false writes.jsonl)"
  rm -rf "${scratch:?}"
  if (( failed > 0 )); then
    printf '  ✗ gate-reuse-check 自检：%s 种情形判错（共 %s 种）\n' "$failed" "$((passed + failed))"   # gate-lint:summary
    printf '%s\n' '     → 怎么办：看上面判错的那几种情形，修 gate-reuse-check.sh 或它调的 gate-overlap.py，再跑 bash gate-reuse-check.sh --selftest。'
    return 1
  fi
  printf '  ✓ gate-reuse-check 自检：%s 种情形判得都对\n' "$passed"
  return 0
}

if [[ "${1:-}" == --selftest ]]; then
  run_selftest
  exit $?
fi
judge_stop
exit $?
