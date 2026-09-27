#!/usr/bin/env bash
# 样本：成功句带着一个变量，但它是路径不是计数。判「带变量就算报了数」的话，这一句就过了。
ROOT="${1:-.}"
for f in "$ROOT"/*.md; do
  grep -q X "$f" || continue
done
ok "检查通过：$ROOT"
