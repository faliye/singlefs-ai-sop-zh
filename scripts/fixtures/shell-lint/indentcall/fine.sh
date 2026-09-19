#!/usr/bin/env bash
# 样本：该绿的。函数既在 $( ) 里被调用、也在另一个函数体里缩进着直接调用——直接那次的赋值传得出去，判红没有依据。
# 只认行首不带缩进的直接调用时，写在函数体里的调用全看不见，于是误判（singlefs 2026-09-19 修一行流函数时一起看到）。
init_paths() {
  LOGDIR="$1/logs"
  printf '%s' "$LOGDIR"
}
setup() {
  init_paths /tmp/run
}
setup
echo "$(init_paths /tmp/other)"
echo "$LOGDIR"
