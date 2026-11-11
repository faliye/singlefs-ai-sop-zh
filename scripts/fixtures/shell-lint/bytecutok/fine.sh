#!/usr/bin/env bash
# 样本：截给人看的照字符截；只截十六进制摘要的写明只截 ASCII。
clip_text() { cut -c "1-$1" | iconv -c -f UTF-8 -t UTF-8 2>/dev/null; }
report() {
  echo "  ✗ 那一趟的输出末尾：$(tail -n 5 "$1" | tr '\n' '|' | clip_text 600)" >&2
  echo "摘要 $(sha256sum "$1" | cut -c1-12)"   # shell-lint:bytes-ok 十六进制摘要只有 ASCII
}
