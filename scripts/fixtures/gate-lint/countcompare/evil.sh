#!/usr/bin/env bash
# 样本：成功句里只带一个在 (( … == … )) 比较里出现过的变量。比较不是累加，它不算计数
verbose=0
for f in "$1"/*.md; do
  if (( verbose == 1 )); then echo "$f"; fi
done
ok "查完了（verbose=$verbose）"
