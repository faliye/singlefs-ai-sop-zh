#!/usr/bin/env bash
# admission: sometimes 看情况
# admission: always 短
# run-condition: check test -d /tmp
# run-condition: single-instance 多余
# run-condition: command
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../singlefs-ai-sop/scripts/lib.sh"
preflight "${BASH_SOURCE[0]}" "$@"; set -- ${PREFLIGHT_ARGUMENTS[@]+"${PREFLIGHT_ARGUMENTS[@]}"}
ROOT="${1:-.}"
echo "$ROOT"
