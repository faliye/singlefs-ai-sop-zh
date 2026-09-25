#!/usr/bin/env bash
# admission: always 样本：它判的是此刻仓里的文本
# run-condition: command git
set -uo pipefail
preflight "${BASH_SOURCE[0]}" "$@"; set -- ${PREFLIGHT_ARGUMENTS[@]+"${PREFLIGHT_ARGUMENTS[@]}"}
source "$(dirname "${BASH_SOURCE[0]}")/../singlefs-ai-sop/scripts/lib.sh"
echo 跑
