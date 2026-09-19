#!/usr/bin/env bash
# 样本：一行写完的函数也要判——函数体就是定义那一行，给全局变量赋值、只在 $( ) 里调用，照样传不出去。
get_path() { RESULT_PATH="/tmp/out"; printf '%s' 0; }
rc="$(get_path)"
cat "$RESULT_PATH"
