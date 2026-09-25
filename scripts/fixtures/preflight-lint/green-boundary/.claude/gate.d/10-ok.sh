#!/usr/bin/env bash
# admission: inputs-changed ./10-ok.sh
# run-condition: command git
set -euo pipefail
PACKAGE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../singlefs-ai-sop" && pwd)"
source "$PACKAGE/scripts/lib.sh"
readonly SAMPLE_CONSTANT=3
preflight "${BASH_SOURCE[0]}" "$@"; set -- ${PREFLIGHT_ARGUMENTS[@]+"${PREFLIGHT_ARGUMENTS[@]}"}
if [[ -n "${1:-}" ]]; then preflight_record_success; fi
