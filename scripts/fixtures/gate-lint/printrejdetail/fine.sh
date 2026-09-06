#!/usr/bin/env bash
# 样本：循环里逐条列明细，出路写在汇总上。明细行显式标 detail。
n=0
for f in *.md; do
  echo "  ✗ $f 缺历史节"   # gate-lint:detail
  n=$((n+1))
done
echo "  ✗ 共 $n 份不合规"   # gate-lint:summary
echo "     → 怎么办：每份文末补一节「## 历史版本」。"
exit 1
