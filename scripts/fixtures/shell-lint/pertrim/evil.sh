#!/usr/bin/env bash
# 样本：$* 的去前缀逐个参数各去一次，模式里的空格去不掉拼起来那一段。
record_items() {
  printf 'items %s\n' "${*#* -- items }"
}
