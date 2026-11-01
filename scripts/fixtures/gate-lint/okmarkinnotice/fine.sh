#!/usr/bin/env bash
# 样本：错误说明的出路里提到 ✓，它在 die 的第二个参数中间，不是成功句。最后一句成功句是带计数的那一句。
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
checked=0
for f in *.md; do checked=$((checked+1)); done
ok "检查通过（共 $checked 份）"
[[ -e README.md ]] || die "没有可查的文件" "放一份 .md 进来，重跑后看到 ✓ 才算通过。"
