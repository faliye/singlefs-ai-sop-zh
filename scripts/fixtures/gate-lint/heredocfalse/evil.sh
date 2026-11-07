#!/usr/bin/env bash
# 样本：三种**不是** heredoc 的写法，不许当成 heredoc 开头；当成了，从那行起整个文件就不再检查。
n="$(grep -c x <<< abc)"          # <<< 是 here-string，不是 heredoc
# 用法：python3 - <<PY            ← 注释里的 heredoc 不算开了 heredoc
size=$((1 << SHIFT))              # 算术位移里的 << 也不算
die "单测失败"
