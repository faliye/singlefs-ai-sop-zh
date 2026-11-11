#!/usr/bin/env bash
# 样本：报了跳过的份数，被跳过的逐条打在输出里（至多前 20 条，余下报条数）；条件里的 > 不是往文件里写。
checked=0; skipped=0
for f in "$1"/*.md; do
  if [[ ! -s "$f" ]]; then
    skipped=$((skipped + 1))
    (( skipped > 20 )) || say "  跳过 $f（空文件）"
    continue
  fi
  checked=$((checked + 1))
done
(( skipped <= 20 )) || say "  另有 $((skipped - 20)) 份空文件没逐条列"
ok "检查通过（检查 $checked 份，跳过 $skipped 份）"
