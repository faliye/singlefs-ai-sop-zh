#!/usr/bin/env bash
# 样本：前面一句成功句带着计数，最后那句总结却不报数。判「任一句带任一个变量」的话，前一句就替总结句作保了。
n=0
for f in "$1"/*.md; do
  n=$((n + 1))
done
ok "扫了 $n 份文档"
for f in "$1"/*.txt; do
  grep -q X "$f" || continue
done
ok "全部检查通过"
