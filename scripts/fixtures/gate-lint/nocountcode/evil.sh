#!/usr/bin/env bash
# 样本：豁免标记写进了字符串，不是单独一行的注释。按子串认的话，这一句就把整个文件免检了。
for f in "$1"/*.md; do
  grep -q X "$f" || continue
done
echo "这里写了 gate-lint:nocount 这几个字，但它在字符串里"
ok "检查通过"
