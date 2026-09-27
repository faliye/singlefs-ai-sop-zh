#!/usr/bin/env bash
# 样本：计数是数组长度，先赋给一个变量再报。
documents=()
while IFS= read -r document; do documents+=("$document"); done < <(find "$1" -name '*.md')
document_count=${#documents[@]}
ok "检查通过（${document_count} 份文档）"
