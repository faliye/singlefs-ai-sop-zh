#!/usr/bin/env bash
# 样本：同一时刻只许一个实例。设了 SAMPLE_STOP_FILE 就一直跑到那个文件出现。
# admission: always 样本：每次调都有意义
# run-condition: single-instance
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight "${BASH_SOURCE[0]}" "$@"; set -- ${PREFLIGHT_ARGUMENTS[@]+"${PREFLIGHT_ARGUMENTS[@]}"}
echo "起来了"
if [[ -n "${SAMPLE_STOP_FILE:-}" ]]; then
  for ((waited_tenths = 0; waited_tenths < 300; waited_tenths++)); do
    if [[ -f "$SAMPLE_STOP_FILE" ]]; then break; fi
    sleep 0.1
  done
fi
