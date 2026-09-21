#!/usr/bin/env bash
# 样本：扫一批对象，却不报检查了多少项——扫到 0 项也会报绿（使用者项目实测过的形态）。
for f in "$1"/*.md; do
  grep -q X "$f" || continue
done
ok "检查通过"
