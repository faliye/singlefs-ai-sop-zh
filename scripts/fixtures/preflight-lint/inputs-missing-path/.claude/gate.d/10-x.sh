#!/usr/bin/env bash
# admission: inputs-changed ./no-such-input
# run-condition: command git
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../singlefs-ai-sop/scripts/lib.sh"
preflight "${BASH_SOURCE[0]}" "$@"; set -- ${PREFLIGHT_ARGUMENTS[@]+"${PREFLIGHT_ARGUMENTS[@]}"}
ROOT="${1:-.}"
echo "$ROOT"
preflight_record_success
