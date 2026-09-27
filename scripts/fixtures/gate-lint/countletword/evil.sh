#!/usr/bin/env bash
# 样本：成功句里只带一个变量，而 let 只出现在别的词里（outlet mode）。词里的 let 不算累加
mode=strict # outlet mode here
for f in "$1"/*.md; do
  grep -q X "$f" || continue
done
ok "查完了（$mode）"
