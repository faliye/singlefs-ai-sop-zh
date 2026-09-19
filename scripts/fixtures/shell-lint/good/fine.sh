#!/usr/bin/env bash
# 样本：该绿的。里面摆了四种**合法但曾被误判**的写法，
# 任何一条变红，都说明对应的排除条款被改坏了。
#   1. heredoc 体里的赋值是被生成脚本的内容，不是本脚本的代码
#   2. `local out; out="$(...)"` 是常规写法，即使外面也有个同名变量
#   3. 函数正常调用（不在 $( ) 里）时，设全局变量是合法的
#   4. 失败信息里提到那两个命令名，不在命令位置，不算调用
#   5. 在 $( ) 里跑的函数设一个外面不读的全局，无害，不该判红

# —— 1 与 2：这个函数在 $( ) 里跑 ——
run_one() {
  local payload="$1" work="$2"
  cat > "$work/init" <<'INIT'
#!/bin/sh
LOG=/var/log/inner.log
/payload.sh; rc=$?
echo "EXIT=$rc" >> "$LOG"
INIT
  # 4b：在 $( ) 里跑的函数设一个**外面根本不读**的全局，是无害的：
  # 值传不出去，但也没人指望它传出去。判红说明「外部引用」这个条件被去掉了。
  LAST_INIT_PATH="$work/init"
  local out; out="$(sed -n 's/EXIT=\(.*\)/\1/p' "$work/init" | tail -1)"
  printf '%s' "$out"
}

# —— 3：这个函数不在 $( ) 里调，设全局变量传值是正当的 ——
detect_env() {
  CONFIG_PATH=/etc/batch-job.conf
  HAS_CACHE=1
}

# 「不要用 pkill -f / killall」——这一行不该判红。
W="$(mktemp -d)"; LOG="$W/run.log"
out="$(run_one p "$W")"
detect_env
echo "$out $LOG $CONFIG_PATH $HAS_CACHE"

# —— 6：并行跑检测项，每项把退出码写进自己的文件，收的时候逐个读。
# 标记写明了退出码的去向，不该判红；去掉那行标记就必须变红（S6）。
work="$(mktemp -d)"
for probe in alpha beta; do
  mkdir -p "$work/$probe"
  ( bash probe.sh "$probe" >"$work/$probe/out" 2>&1; echo "$?" >"$work/$probe/exit" ) &
done
wait  # shell-lint:exit-collected 每项把退出码写进 $work/<项>/exit，紧接着逐个读
for probe in alpha beta; do
  [[ "$(cat "$work/$probe/exit")" == 0 ]] || { echo "$probe 没过"; exit 1; }
done
