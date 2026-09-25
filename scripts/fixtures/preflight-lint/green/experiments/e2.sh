#!/usr/bin/env bash
# admission: inputs-changed ./data.txt env:SAMPLE_ROUNDS arguments
# run-condition: check test -r /proc/self/status :: 样本：读不到 /proc 就别跑
source "$(dirname "${BASH_SOURCE[0]}")/../.claude/singlefs-ai-sop/scripts/lib.sh"
preflight "${BASH_SOURCE[0]}" "$@"; set -- ${PREFLIGHT_ARGUMENTS[@]+"${PREFLIGHT_ARGUMENTS[@]}"}
echo 跑
preflight_record_success
