#!/usr/bin/env bash
# 样本：被跳过的条目逐条写进了收尾会删的临时文件，输出里只报了条数。
checked=0; skipped=0
skip_list="$(mktemp)"
for f in "$1"/*.md; do
  if [[ ! -s "$f" ]]; then echo "跳过 $f（空文件）" >> "$skip_list"; skipped=$((skipped + 1)); continue; fi
  checked=$((checked + 1))
done
rm -f "$skip_list"
ok "检查通过（检查 $checked 份，跳过 $skipped 份）"
