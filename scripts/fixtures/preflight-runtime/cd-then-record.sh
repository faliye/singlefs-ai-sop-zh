#!/usr/bin/env bash
# 样本：用相对路径起，开跑之后 cd 到别处，成功时照样记得下指纹。
# admission: inputs-changed ../input-cd.txt
# run-condition: none 样本：不碰别的环境
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight "${BASH_SOURCE[0]}" "$@"; set -- ${PREFLIGHT_ARGUMENTS[@]+"${PREFLIGHT_ARGUMENTS[@]}"}
cd /
echo "跑了"
preflight_record_success
