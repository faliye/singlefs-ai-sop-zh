#!/usr/bin/env bash
# gate-stage: 样本阶段
# admission: always 样本：它判的是此刻仓里的文本
# run-condition: command git
# run-condition: single-instance
# 注释里写 $1 不算读参数
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../singlefs-ai-sop/scripts/lib.sh"
export SAMPLE_VARIABLE=1
declare -a SAMPLE_ARRAY=()
unset SAMPLE_UNUSED
preflight "${BASH_SOURCE[0]}" "$@"; set -- ${PREFLIGHT_ARGUMENTS[@]+"${PREFLIGHT_ARGUMENTS[@]}"}
ROOT="${1:-.}"
echo "$ROOT"
