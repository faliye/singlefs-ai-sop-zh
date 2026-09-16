#!/usr/bin/env bash
# 样本：function 形态的定义 + 反引号调用，只认 name(){ 与 $( 时整体漏检。
function run_one {
  LOGF="/tmp/run.log"
  printf '%s' 0
}
rc=`run_one`
tail -1 "$LOGF"
