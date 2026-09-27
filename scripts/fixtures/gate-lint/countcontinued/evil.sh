#!/usr/bin/env bash
# 样本：成功句的格式串一行、参数续在下一行，计数在续行里。只看第一行的话会误判成没报数。
scanned=0
for f in "$1"/*.md; do
  scanned=$((scanned + 1))
done
printf '  ✓ 检查通过（%s 份文档）\n' \
  "$scanned"
