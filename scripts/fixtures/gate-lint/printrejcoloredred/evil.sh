#!/usr/bin/env bash
# 样本：标记前面是颜色占位（printf 的 %s、echo -e 的转义序列），仍是行首的 ✗。两处都没有出路，照红。
n=0
for f in *.md; do n=$((n+1)); done
printf '%s  ✗%s 有 %s 份文件不合规\n' "$RED" "$RESET" "$n"
echo -e "\033[31m  ✗ 另有文件缺历史节\033[0m"
exit 1
