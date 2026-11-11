#!/usr/bin/env bash
# 样本：跳过的条目收进数组，报数之后把数组的前 20 条整组打出来。
checked=0; skipped_files=()
for f in "$1"/*.md; do
  if [[ ! -s "$f" ]]; then skipped_files+=("$f"); continue; fi
  checked=$((checked + 1))
done
ok "检查通过（检查 $checked 份，跳过 ${#skipped_files[@]} 份）"
((${#skipped_files[@]} == 0)) || printf '  跳过（空文件）：%s\n' "${skipped_files[@]:0:20}"
