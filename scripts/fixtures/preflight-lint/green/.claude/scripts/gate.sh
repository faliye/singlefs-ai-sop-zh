#!/usr/bin/env bash
# 包装：转发到共享脚本。逻辑不写在这里，写在 .claude/singlefs-ai-sop/scripts/。
shared="$(dirname "${BASH_SOURCE[0]}")/../singlefs-ai-sop/scripts/gate.sh"
if [[ ! -f "$shared" ]]; then
  echo "  ✗ 找不到共享脚本：$shared"
  echo "     → 怎么办： 把规范副本装回来"
  exit 1
fi
exec bash "$shared" "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" "$@"
