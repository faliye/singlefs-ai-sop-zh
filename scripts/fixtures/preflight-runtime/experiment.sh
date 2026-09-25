#!/usr/bin/env bash
# 样本实验：登记的输入没变就拒绝重跑；设了 SAMPLE_BLOCKED 就不许跑。selftest 拷进临时仓的 scripts/ 下跑。
# admission: inputs-changed ../input.txt env:SAMPLE_ROUNDS
# run-condition: check test -z "${SAMPLE_BLOCKED:-}" :: 样本：设了 SAMPLE_BLOCKED 就不许跑，先 unset 它
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight "${BASH_SOURCE[0]}" "$@"; set -- ${PREFLIGHT_ARGUMENTS[@]+"${PREFLIGHT_ARGUMENTS[@]}"}
echo "跑了 参数=[$*] 强制=[${PREFLIGHT_FORCED}]"
if [[ -n "${SAMPLE_FAIL:-}" ]]; then echo "样本按要求跑失败"; exit 5; fi
# 模拟跑的过程中别的会话改了登记的输入：收尾时重算的指纹与开跑时的对不上，这一次不许记成测过了
if [[ -n "${SAMPLE_CHANGE_INPUT:-}" ]]; then printf '跑的过程中改的\n' > "$(dirname "${BASH_SOURCE[0]}")/../input.txt"; fi
preflight_record_success
