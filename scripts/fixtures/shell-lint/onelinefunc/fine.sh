#!/usr/bin/env bash
# 样本：该绿的。一行写完的函数（定义与收尾在同一行），后面紧跟顶层赋值，再往后才是下一个函数行首的 }。
# 往下找收尾会把这几行顶层赋值算成 size_of 的函数体，而 size_of 只在 $( ) 里被调用——
# 于是判成「子 shell 里的赋值传不出去」，是假红（singlefs 2026-09-19 实测：研究脚本里 14 处）。
size_of() { wc -c < "$1"; }
WORKDIR="$(mktemp -d)"
COUNT=0
report() {
  echo "$COUNT"
}
bytes="$(size_of "$WORKDIR/x")"
echo "$bytes $WORKDIR"
report
