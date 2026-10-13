#!/usr/bin/env bash
# gate-similar: stage-selftest.sh 它拿 fixtures 下的红绿样本证明 gate.d 的阶段会红；钩子的证据是在 settings.json 里注册着、带 --selftest 自证，输入与协议都不同
# admission: always 判的是此刻 settings.json 的注册与钩子的自证，两边随时在改
# run-condition: command python3
# 工具层的闸注册着、而且会拒绝。
#
# 钩子被删掉或改坏时那道闸静默消失，只有门禁会在它消失时说话（rules/session-wrapup.md 第 4 条：能在工具层拦就在工具层拦）。
#
# 判据，对项目登记的钩子目录（默认 `.claude/hooks/`）与装进来的 SOP 副本 `scripts/claude-hooks/` 下每个 `*.sh`：
#   注册：`.claude/settings.json` 的 hooks.* 里有一条 command 指向它（按文件名的边界认，见 hook-registrations.py）；
#   自证：它带 `--selftest` 时，自证要通过（自证本身证明这道闸会拒绝）；
#   事件：它文件头写了 `# hook-events: <事件> …` 时，每个事件都有一条注册指向它；
#      写成 `<事件>:<工具名>` 的，那条注册的 matcher 还要认得这个工具名（空 matcher 与 * 认全部）。
# 例外：副本里的钩子文件头写了 `# hook-registration: optional <理由>`，项目可以不注册它，
#   成功那句逐个列出没注册的可选钩子；注册了就照自证、事件两条判。项目自己的钩子写这一行不算数：不用就连文件删掉。
# 一个钩子都没有时退 77（本次无对象可判），不报绿。有钩子却没有 settings.json 判红：那等于每一个都没注册。
#
# 用法：
#   hooks-registered.sh [仓根]
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
preflight "${BASH_SOURCE[0]}" "$@"; set -- ${PREFLIGHT_ARGUMENTS[@]+"${PREFLIGHT_ARGUMENTS[@]}"}
set +e

PROJECT_ROOT="$(cd "${1:-.}" && pwd)"
SETTINGS_FILE="$PROJECT_ROOT/.claude/settings.json"
PACKAGE_HOOKS_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/claude-hooks"
HOOKS_RELATIVE_DIRECTORY="$(project_hooks_dir "$PROJECT_ROOT")" || exit 1
HOOKS_DIRECTORY="$PROJECT_ROOT/$HOOKS_RELATIVE_DIRECTORY"

hook_files=()
for directory in "$HOOKS_DIRECTORY" "$PACKAGE_HOOKS_DIRECTORY"; do
  [[ -d "$directory" ]] || continue
  while IFS= read -r found_hook_file; do [[ -n "$found_hook_file" ]] && hook_files+=("$found_hook_file"); done < <(find "$directory" -maxdepth 1 -name '*.sh' -type f | sort)
done
((${#hook_files[@]})) || { warn "项目的 $HOOKS_DIRECTORY 与装进来的副本里一个钩子都没有，本阶段无对象可判（这不是通过）"; exit 77; }
if [[ ! -f "$SETTINGS_FILE" ]]; then
  bad "没有 $SETTINGS_FILE，而 $HOOKS_DIRECTORY 与装进来的副本里共有 ${#hook_files[@]} 个钩子：它们一个都没注册"
  howto "建 .claude/settings.json，在 hooks.<事件> 里把它们注册上，写法见各钩子文件头的「怎么注册」：" \
        "{\"hooks\": {\"PreToolUse\": [{\"matcher\": \"Bash\", \"hooks\": [{\"type\": \"command\", \"command\": \"bash \\\"\$CLAUDE_PROJECT_DIR\\\"/$HOOKS_RELATIVE_DIRECTORY/<名>.sh\"}]}]}}" \
        "装进来的副本里的钩子归上游管，不删，只注册。"
  exit 1
fi

# 读 settings.json、认「一条注册命令指向哪个钩子」都只在 hook-registrations.py 一处，gate-overlap.py 也用它。
# 按文件名的边界认：按子串认的话，`guard.sh` 会被认成 `old-guard.sh` 的注册。
REGISTRATIONS_READER="$(dirname "${BASH_SOURCE[0]}")/hook-registrations.py"
if ! all_registrations="$(python3 "$REGISTRATIONS_READER" "$SETTINGS_FILE" 2>&1)"; then
  bad "$SETTINGS_FILE 读不了（不是合法的 JSON，或 hooks 的结构不对）"
  howto "python3 -m json.tool $SETTINGS_FILE 看错在哪，改成合法的 JSON 再跑。" \
        "读不了的时候哪个钩子都算没注册，而问题出在文件本身，不在钩子。"
  exit 1
fi
if [[ -z "$all_registrations" ]]; then
  bad "$SETTINGS_FILE 里一条钩子都没注册，而 $HOOKS_DIRECTORY 与装进来的副本里共有 ${#hook_files[@]} 个"
  howto "在 settings.json 的 hooks.<事件> 里把它们注册回去：" \
        "{\"matcher\": \"Bash\", \"hooks\": [{\"type\": \"command\", \"command\": \"bash \\\"\$CLAUDE_PROJECT_DIR\\\"/$HOOKS_RELATIVE_DIRECTORY/<名>.sh\"}]}" \
        "每个钩子要挂哪几个事件，看它文件头的 # hook-events: 与「怎么注册」。"
  exit 1
fi

hook_events_of() { sed -n 's/^# hook-events:[[:space:]]*//p' "$1" | head -1; }
# 副本里的钩子声明可以不注册时，echo 出它的理由；没声明、或是项目自己的钩子，什么都不出
optional_registration_reason_of() {
  [[ "$(dirname "$1")" == "$PACKAGE_HOOKS_DIRECTORY" ]] || return 0
  sed -n 's/^# hook-registration:[[:space:]]*optional[[:space:]]\{1,\}//p' "$1" | head -1
}
OPTIONAL_REASON_MINIMUM_CHARACTERS=8
unregistered_hooks=(); failed_selftest_hooks=(); unhooked_events=(); unreadable_registration_hooks=(); optional_unregistered=(); malformed_optional=(); checked_hook_count=0; selftested_hook_count=0
for hook_file in "${hook_files[@]}"; do
  hook_file_name="$(basename "$hook_file")"
  checked_hook_count=$((checked_hook_count + 1))
  # 读注册失败与「没注册」分开：吞掉的话，这一次读失败的钩子被报成「没在 settings.json 里注册」，出路指错了地方
  if ! hook_registrations="$(python3 "$REGISTRATIONS_READER" --for "$hook_file_name" "$SETTINGS_FILE" 2>/dev/null)"; then
    unreadable_registration_hooks+=("$hook_file_name")
    continue
  fi
  if [[ -z "$hook_registrations" ]]; then
    optional_reason="$(optional_registration_reason_of "$hook_file")"
    if [[ -z "$optional_reason" ]]; then
      unregistered_hooks+=("$hook_file")
    elif (( ${#optional_reason} < OPTIONAL_REASON_MINIMUM_CHARACTERS )); then
      malformed_optional+=("$hook_file_name")
    else
      optional_unregistered+=("$hook_file_name")
    fi
    continue
  fi
  for declared_event in $(hook_events_of "$hook_file"); do
    event_name="${declared_event%%:*}"; tool_name=''
    [[ "$declared_event" == *:* ]] && tool_name="${declared_event#*:}"
    if ! awk -F'\t' -v event="$event_name" -v tool="$tool_name" '
          $1 == event && (tool == "" || $2 == "" || $2 == "*" || tool ~ ("^(" $2 ")$")) { found = 1 }
          END { exit !found }' <<<"$hook_registrations"; then
      unhooked_events+=("$hook_file_name→$declared_event")
    fi
  done
  grep -q -- '--selftest' "$hook_file" || continue
  selftested_hook_count=$((selftested_hook_count + 1))
  selftest_output="$(bash "$hook_file" --selftest 2>&1)"
  if (( $? != 0 )); then
    failed_selftest_hooks+=("$hook_file_name")
    printf '%s\n' "$selftest_output" | sed 's/^/        /'   # gate-lint:detail
  fi
done

if ((${#unreadable_registration_hooks[@]})); then
  bad "${#unreadable_registration_hooks[@]} 个钩子的注册读不出来（hook-registrations.py --for 失败）：${unreadable_registration_hooks[*]}"   # gate-lint:summary
  howto "单跑 python3 $REGISTRATIONS_READER --for <钩子文件名> $SETTINGS_FILE 看它为什么失败（settings.json 跑到一半被改了、或读它的脚本坏了），修好再跑。" \
        "读不出来不等于没注册：这一条没判，所以不许当成通过。"
  exit 1
fi
if ((${#malformed_optional[@]})); then
  bad "${#malformed_optional[@]} 个钩子写了 # hook-registration: optional，理由不到 $OPTIONAL_REASON_MINIMUM_CHARACTERS 个字：${malformed_optional[*]}"   # gate-lint:summary
  howto "在那个钩子文件头写全：# hook-registration: optional <为什么项目可以不注册它>，理由至少 $OPTIONAL_REASON_MINIMUM_CHARACTERS 个字；" \
        "或者在 settings.json 里照它的 # hook-events: 把它注册上。"
  exit 1
fi
if ((${#unregistered_hooks[@]})); then
  bad "${#unregistered_hooks[@]} 个钩子没在 settings.json 里注册："   # gate-lint:summary
  for hook_file in "${unregistered_hooks[@]}"; do
    declared_events="$(hook_events_of "$hook_file")"
    say "        $(basename "$hook_file")  要挂的事件：${declared_events:-文件头没写 # hook-events:，看它的说明}  （$hook_file）"   # gate-lint:detail
  done
  howto "在 settings.json 的 hooks.<事件> 里，按上面列的事件各注册一次，写法见各钩子文件头的「怎么注册」。" \
        "项目自己的钩子不再用了，就连文件一起删掉；装进来的副本里的钩子归上游管，不删，只注册。" \
        "留着不注册最糟：看着有一道闸，实际什么都不拦。"
  exit 1
fi
if ((${#unhooked_events[@]})); then
  bad "${#unhooked_events[@]} 处钩子没挂在它声明的事件上：${unhooked_events[*]}"   # gate-lint:summary
  howto "按那个钩子文件头的 # hook-events: 一行，在 settings.json 的 hooks.<事件> 里每个事件各注册一次（写法见它文件头的「怎么注册」）；" \
        "写成 <事件>:<工具名> 的，那条注册的 matcher 要认得这个工具名。" \
        "只挂了一部分，没挂上的那一类 agent 那里这道闸不在。"
  exit 1
fi
if ((${#failed_selftest_hooks[@]})); then
  bad "${#failed_selftest_hooks[@]} 个钩子的自证没过：${failed_selftest_hooks[*]}"   # gate-lint:summary
  howto "上面是它自证的输出。修那个钩子，再跑 bash <钩子> --selftest 看它转绿。" \
        "自证就是这道闸「会拒绝」的证据，自证不过等于闸开着。"
  exit 1
fi
if ((${#optional_unregistered[@]})); then
  ok "$checked_hook_count 个钩子里 $((checked_hook_count - ${#optional_unregistered[@]})) 个注册着，其中 $selftested_hook_count 个的自证通过；${#optional_unregistered[@]} 个可选钩子没注册：${optional_unregistered[*]}"
else
  ok "$checked_hook_count 个钩子都注册着，其中 $selftested_hook_count 个的自证通过"
fi
