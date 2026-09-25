#!/usr/bin/env bash
# admission: always 样本：它判的是此刻仓里的文本
# run-condition: command git
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../singlefs-ai-sop/scripts/lib.sh"
preflight "$0" "$@"
echo "$@"
