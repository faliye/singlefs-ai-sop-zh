#!/usr/bin/env bash
# 样本：出路在明细之后才给——5 行窗口会误判它，「到下一处拒绝之前」不会。
n=0
for f in *.md; do n=$((n+1)); done
echo "  ✗ 有 $n 份文件不合规："
for f in *.md; do echo "        $f"; done
echo "     → 怎么办：照 rules/writing-discipline.md 改，改完重跑本阶段。"
exit 1
