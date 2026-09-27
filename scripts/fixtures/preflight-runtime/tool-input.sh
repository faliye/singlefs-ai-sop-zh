#!/usr/bin/env bash
# 样本：结果取决于一个工具，登记成 tool:。工具装上、换了版本，都算输入变了。selftest 拷进临时仓的 scripts/ 下跑。
# admission: inputs-changed ../input-tool.txt tool:sample-tool-for-selftest
# run-condition: none 样本：不碰任何环境，只看登记的工具
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight "${BASH_SOURCE[0]}" "$@"; set -- ${PREFLIGHT_ARGUMENTS[@]+"${PREFLIGHT_ARGUMENTS[@]}"}
if command -v sample-tool-for-selftest >/dev/null 2>&1; then tool_version="$(sample-tool-for-selftest --version)"; else tool_version=没装; fi
echo "跑了 工具=[$tool_version]"
preflight_record_success
