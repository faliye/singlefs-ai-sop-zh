#!/usr/bin/env bash
# 样本：成功句报了跳过的份数（数写在跳过词前面），被跳过的是哪几份一条都没打出来。
checked=0; skipped_files=()
for f in "$1"/*.md; do
  if [[ ! -s "$f" ]]; then skipped_files+=("$f"); continue; fi
  checked=$((checked + 1))
done
ok "检查通过（检查 $checked 份，${#skipped_files[@]} 份跳过）"
