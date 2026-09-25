#!/usr/bin/env bash
# 样本：判据会把标准输入读光。钩子的 JSON、git 喂给 pre-push 的 ref 都在标准输入里，判条件不许读走它。
# admission: always 样本：每次调都有意义
# run-condition: check cat > /dev/null :: 样本：这条判据会把标准输入读光
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight "${BASH_SOURCE[0]}" "$@"; set -- ${PREFLIGHT_ARGUMENTS[@]+"${PREFLIGHT_ARGUMENTS[@]}"}
echo "标准输入=[$(cat)]"
