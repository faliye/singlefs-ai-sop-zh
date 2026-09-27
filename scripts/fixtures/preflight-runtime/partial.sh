#!/usr/bin/env bash
# 样本：设了 SAMPLE_SKIP_PART 就跳过一部分（report_not_run 报出来），那一次不记成「上次成功」。selftest 拷进临时仓的 scripts/ 下跑。
# admission: inputs-changed ../input-partial.txt
# run-condition: none 样本：不碰任何环境，只看登记的输入
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight "${BASH_SOURCE[0]}" "$@"; set -- ${PREFLIGHT_ARGUMENTS[@]+"${PREFLIGHT_ARGUMENTS[@]}"}
if [[ -n "${SAMPLE_SKIP_PART:-}" ]]; then report_not_run "样本：这一部分跳过了"; fi
echo "跑了"
preflight_record_success
