#!/usr/bin/env bash
# 样本：条目由别的函数逐个报进汇总，这里认不出，报数那一行写明在哪报的。
checked=0; skipped=0
report_skipped() { report_not_run "空文件没判：$1"; }
for f in "$1"/*.md; do
  if [[ ! -s "$f" ]]; then report_skipped "$f"; skipped=$((skipped + 1)); continue; fi
  checked=$((checked + 1))
done
ok "检查通过（检查 $checked 份，跳过 $skipped 份）"   # gate-lint:skip-listed 空文件由 report_skipped 逐个报进汇总的本次未跑
