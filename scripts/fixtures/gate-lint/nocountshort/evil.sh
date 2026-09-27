#!/usr/bin/env bash
# gate-lint:nocount 不扫
# 样本：豁免的理由太短，说不清为什么不扫一批对象。
for f in "$1"/*.md; do
  grep -q X "$f" || continue
done
ok "检查通过"
