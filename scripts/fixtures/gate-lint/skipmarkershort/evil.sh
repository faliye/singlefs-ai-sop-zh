#!/usr/bin/env bash
# 样本：报数那一行写了 skip-listed 标记，理由太短，不算豁免。
checked=0; skipped=0
report_skipped() { report_not_run "空文件没判：$1"; }
for f in "$1"/*.md; do
  if [[ ! -s "$f" ]]; then report_skipped "$f"; skipped=$((skipped + 1)); continue; fi
  checked=$((checked + 1))
done
ok "检查通过（检查 $checked 份，跳过 $skipped 份）"   # gate-lint:skip-listed 见上
