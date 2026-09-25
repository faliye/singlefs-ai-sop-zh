#!/usr/bin/env bash
# admission: always 样本：每一次工具调用之前都现判
# run-condition: command python3
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../singlefs-ai-sop/scripts/preflight.sh"
preflight "${BASH_SOURCE[0]}" "$@"; set -- ${PREFLIGHT_ARGUMENTS[@]+"${PREFLIGHT_ARGUMENTS[@]}"}
cat
