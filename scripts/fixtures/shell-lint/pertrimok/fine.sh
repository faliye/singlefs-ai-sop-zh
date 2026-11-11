#!/usr/bin/env bash
# 样本：先拼成一串再去前缀；对单个参数去前缀不带空格。
record_items() {
  local joined="$*"
  printf 'items %s\n' "${joined#* -- items }"
  printf '%s\n' "${@#--}"
}
