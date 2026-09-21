#!/usr/bin/env bash
# 工具层的闸注册着、而且会拒绝。
#
# 规则里写一句提醒拦不住手敲的命令，能拦住的是一个当场拒绝执行的钩子
# （rules/sop-first.md、rules/session-wrapup.md 第 4 条：能在工具层拦就在工具层拦）。
# 而钩子被人删掉或改坏时，那道闸**静默消失**——同一个坑会再来一次，
# 只有门禁会在它消失时说话。原是使用者项目的一个本地阶段，判据通用，收归这里。
#
# 判据，对 `.claude/hooks/` 与装进来的 SOP 副本 `scripts/claude-hooks/` 下每个 `*.sh`：
#   ① `.claude/settings.json` 的 hooks.* 里有一条 command 指向它；
#   ② 它带 `--selftest` 时，自检要通过（自检本身证明这道闸会拒绝）。
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

registered_commands="$(python3 - "$SETTINGS" <<'PY' 2>/dev/null
import json, sys
try:
    data = json.load(open(sys.argv[1], encoding='utf-8'))
except Exception:
    sys.exit(1)
for event_entries in (data.get('hooks') or {}).values():
    for entry in event_entries or []:
        for hook in entry.get('hooks') or []:
            command = hook.get('command') or ''
            if command:
                print(command)
PY
)"
if [[ -z "$registered_commands" ]]; then
  bad "$SETTINGS 里一条钩子都没注册，而 .claude/hooks/ 下有 ${#hooks[@]} 个"
  howto "在 settings.json 的 hooks.<事件> 里把它们注册回去：" \
        '{"matcher": "Bash", "hooks": [{"type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR\"/.claude/hooks/<名>.sh"}]}' \
        "没注册的钩子等于不存在，而它消失时没有任何东西会说话。"
  exit 1
fi

missing=(); failed=(); checked=0; selftested=0
for hook in "${hooks[@]}"; do
  name="$(basename "$hook")"
  checked=$((checked + 1))
  if ! grep -qF -- "$name" <<<"$registered_commands"; then
    missing+=("$name")
    continue
  fi
  grep -q -- '--selftest' "$hook" || continue
  selftested=$((selftested + 1))
  output="$(bash "$hook" --selftest 2>&1)"
  if (( $? != 0 )); then
    failed+=("$name")
    printf '%s\n' "$output" | sed 's/^/        /'   # gate-lint:detail
  fi
done

if ((${#missing[@]})); then
  bad "${#missing[@]} 个钩子没在 settings.json 里注册：${missing[*]}"   # gate-lint:summary
  howto "在 settings.json 的 hooks.<事件> 里注册它，或者删掉这个不再用的钩子脚本。" \
        "留着不注册最糟：看着有一道闸，实际什么都不拦。"
  exit 1
fi
if ((${#failed[@]})); then
  bad "${#failed[@]} 个钩子的自检没过：${failed[*]}"   # gate-lint:summary
  howto "上面是它自检的输出。修那个钩子，再跑 bash <钩子> --selftest 看它转绿。" \
        "自检就是这道闸「会拒绝」的证据，自检不过等于闸开着。"
  exit 1
fi
ok "$checked 个钩子都注册着，其中 $selftested 个的自检通过"
