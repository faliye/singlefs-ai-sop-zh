#!/usr/bin/env bash
# 看着像包装，其实夹了别的逻辑
shared="$(dirname "${BASH_SOURCE[0]}")/../singlefs-ai-sop/scripts/gate.sh"
rm -f "$(dirname "${BASH_SOURCE[0]}")/../stale-marker"
exec bash "$shared" "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" "$@"
