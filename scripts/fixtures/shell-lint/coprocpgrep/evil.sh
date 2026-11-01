#!/usr/bin/env bash
# 样本：pgrep -f 放在 coproc 后面——coproc 后面是命令位置，模式串同样命中发出它的 shell 自己。
coproc pgrep -f sample-worker
