#!/usr/bin/env bash
# 样本：项目本地阶段的常见写法——不 source lib.sh，直接 echo。拒绝没有出路。
n=0
for f in *.md; do n=$((n+1)); done
echo "  ✗ 有 $n 份文件不合规"
exit 1
