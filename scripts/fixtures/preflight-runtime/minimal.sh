#!/usr/bin/env bash
# admission: always 样本：每次调都有意义
# run-condition: command git
# 样本：只 source preflight.sh（不要 gawk、不要 coreutils），好在一个什么都没有的 PATH 下跑。
source "${BASH_SOURCE[0]%/*}/preflight.sh"
preflight "${BASH_SOURCE[0]}" "$@"; set -- ${PREFLIGHT_ARGUMENTS[@]+"${PREFLIGHT_ARGUMENTS[@]}"}
echo "跑了 强制=[${PREFLIGHT_FORCED}]"
