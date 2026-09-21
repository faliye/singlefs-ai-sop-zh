#!/usr/bin/env bash
# 样本：bad 是个计数变量，不是拒绝。算术展开里的 `bad ` 曾被当成命令位置判红
# （使用者项目的 gate.d 实测两处假红）。这个样本必须是绿的。
bad=0
for f in "$1"/*.md; do
  [[ -f "$f" ]] && bad=$((bad + 1))
done
exit 0
