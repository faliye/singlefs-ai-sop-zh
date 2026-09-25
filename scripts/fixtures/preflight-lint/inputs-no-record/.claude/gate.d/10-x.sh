#!/usr/bin/env bash
# admission: inputs-changed ./10-x.sh
# run-condition: command git
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../singlefs-ai-sop/scripts/lib.sh"
preflight "${BASH_SOURCE[0]}" "$@"; set -- ${PREFLIGHT_ARGUMENTS[@]+"${PREFLIGHT_ARGUMENTS[@]}"}
ROOT="${1:-.}"
echo "$ROOT"
# preflight_record_success 写在注释里不算
