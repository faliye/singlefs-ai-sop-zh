#!/usr/bin/env bash
# gate-similar: stage-selftest.sh 它拿 fixtures 下的红绿样本证明 gate.d 的阶段会红；钩子的证据是在 settings.json 里注册着、带 --selftest 自证，输入与协议都不同
# 工具层的闸注册着、而且会拒绝。
#
# 规则里写一句提醒拦不住手敲的命令，能拦住的是一个当场拒绝执行的钩子
# （rules/sop-first.md、rules/session-wrapup.md 第 4 条：能在工具层拦就在工具层拦）。
# 而钩子被人删掉或改坏时，那道闸**静默消失**——同一个坑会再来一次，
# 只有门禁会在它消失时说话。原是使用者项目的一个本地阶段，判据通用，收归这里。
#
# 判据，对 `.claude/hooks/` 与装进来的 SOP 副本 `scripts/claude-hooks/` 下每个 `*.sh`：
#   ① `.claude/settings.json` 的 hooks.* 里有一条 command 指向它（按文件名的边界认，见 hook-registrations.py）；
#   ② 它带 `--selftest` 时，自检要通过（自检本身证明这道闸会拒绝）；
#   ③ 它文件头写了 `# hook-events: <事件> …` 时，每个事件都有一条注册指向它——
#      只挂了一部分（比如只挂 Stop、没挂 SubagentStop），没挂上的那一类 agent 那里这道闸不在。
#      写成 `<事件>:<工具名>` 的（只该在某个工具上触发），那条注册的 matcher 还要认得这个工具名（空 matcher 与 * 认全部）：
#      挂在别的 matcher 上，钩子一次都不会为那个工具触发，而注册看着是齐的。
# 没有 settings.json 或一个钩子都没有时退 77（本次无对象可判），不报绿。
#
# 用法：
#   hooks-registered.sh [仓根]
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
set +e

ROOT="$(cd "${1:-.}" && pwd)"
SETTINGS="$ROOT/.claude/settings.json"
PKG_HOOKS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/claude-hooks"

hooks=()
for directory in "$ROOT/.claude/hooks" "$PKG_HOOKS"; do
  [[ -d "$directory" ]] || continue
  while IFS= read -r one; do [[ -n "$one" ]] && hooks+=("$one"); done < <(find "$directory" -maxdepth 1 -name '*.sh' -type f | sort)
done
((${#hooks[@]})) || exit 77
[[ -f "$SETTINGS" ]] || exit 77

# 读 settings.json、认「一条注册命令指向哪个钩子」都只在 hook-registrations.py 一处，gate-overlap.py 也用它。
# 按文件名的边界认：按子串认的话，`guard.sh` 会被认成 `old-guard.sh` 的注册。
REGISTRATIONS_READER="$(dirname "${BASH_SOURCE[0]}")/hook-registrations.py"
if ! all_registrations="$(python3 "$REGISTRATIONS_READER" "$SETTINGS" 2>&1)"; then
  bad "$SETTINGS 读不了（不是合法的 JSON，或 hooks 的结构不对）"
  howto "python3 -m json.tool $SETTINGS 看错在哪，改成合法的 JSON 再跑。" \
        "读不了的时候哪个钩子都算没注册，而问题出在文件本身，不在钩子。"
  exit 1
fi
if [[ -z "$all_registrations" ]]; then
  bad "$SETTINGS 里一条钩子都没注册，而 .claude/hooks/ 与装进来的副本里共有 ${#hooks[@]} 个"
  howto "在 settings.json 的 hooks.<事件> 里把它们注册回去：" \
        '{"matcher": "Bash", "hooks": [{"type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR\"/.claude/hooks/<名>.sh"}]}' \
        "每个钩子要挂哪几个事件，看它文件头的 # hook-events: 与「怎么注册」。"
  exit 1
fi

hook_events_of() { sed -n 's/^# hook-events:[[:space:]]*//p' "$1" | head -1; }
missing=(); failed=(); unhooked_events=(); checked=0; selftested=0
for hook in "${hooks[@]}"; do
  name="$(basename "$hook")"
  checked=$((checked + 1))
  hook_registrations="$(python3 "$REGISTRATIONS_READER" --for "$name" "$SETTINGS" 2>/dev/null)"
  if [[ -z "$hook_registrations" ]]; then
    missing+=("$hook")
    continue
  fi
  for declared_event in $(hook_events_of "$hook"); do
    event_name="${declared_event%%:*}"; tool_name=''
    [[ "$declared_event" == *:* ]] && tool_name="${declared_event#*:}"
    if ! awk -F'\t' -v event="$event_name" -v tool="$tool_name" '
          $1 == event && (tool == "" || $2 == "" || $2 == "*" || tool ~ ("^(" $2 ")$")) { found = 1 }
          END { exit !found }' <<<"$hook_registrations"; then
      unhooked_events+=("$name→$declared_event")
    fi
  done
  grep -q -- '--selftest' "$hook" || continue
  selftested=$((selftested + 1))
  output="$(bash "$hook" --selftest 2>&1)"
  if (( $? != 0 )); then
    failed+=("$name")
    printf '%s\n' "$output" | sed 's/^/        /'   # gate-lint:detail
  fi
done

if ((${#missing[@]})); then
  bad "${#missing[@]} 个钩子没在 settings.json 里注册："   # gate-lint:summary
  for hook in "${missing[@]}"; do
    events="$(hook_events_of "$hook")"
    say "        $(basename "$hook")  要挂的事件：${events:-文件头没写 # hook-events:，看它的说明}  （$hook）"   # gate-lint:detail
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
if ((${#failed[@]})); then
  bad "${#failed[@]} 个钩子的自检没过：${failed[*]}"   # gate-lint:summary
  howto "上面是它自检的输出。修那个钩子，再跑 bash <钩子> --selftest 看它转绿。" \
        "自检就是这道闸「会拒绝」的证据，自检不过等于闸开着。"
  exit 1
fi
ok "$checked 个钩子都注册着，其中 $selftested 个的自检通过"
