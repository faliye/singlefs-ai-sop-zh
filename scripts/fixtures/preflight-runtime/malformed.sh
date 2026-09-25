#!/usr/bin/env bash
# 样本：条件写坏了，判不了能不能跑。
# admission: sometimes 看情况
# run-condition: command git
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight "${BASH_SOURCE[0]}" "$@"; set -- ${PREFLIGHT_ARGUMENTS[@]+"${PREFLIGHT_ARGUMENTS[@]}"}
echo "不该跑到这里"
