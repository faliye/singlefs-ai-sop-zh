#!/usr/bin/env bash
# 样本：真的直接打印了 ✗，后面一行只是提到它、没有「→」也没有「怎么办」。照红。
n=0
for f in *.md; do n=$((n+1)); done
echo "  ✗ 有 $n 份文件不合规"
echo "     见上面打的 ✗ 那几行"
exit 1
