#!/usr/bin/env bash
# 样本：往人看的输出里按字节截，汉字会被截成半个。
report() {
  echo "  ✗ 那一趟的输出末尾：$(tail -n 5 "$1" | tr '\n' '|' | cut -c1-600)" >&2
}
