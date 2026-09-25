#!/usr/bin/env bash
# 样本：两行 inputs-changed 合成一份输入判，哪一行的输入变了都算变了。
# admission: inputs-changed ../code.txt
# admission: inputs-changed ../decision.txt
# run-condition: none 样本：不碰别的环境
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight "${BASH_SOURCE[0]}" "$@"; set -- ${PREFLIGHT_ARGUMENTS[@]+"${PREFLIGHT_ARGUMENTS[@]}"}
echo "跑了"
preflight_record_success
