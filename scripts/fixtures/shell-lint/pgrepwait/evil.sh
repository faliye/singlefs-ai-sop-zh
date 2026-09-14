#!/usr/bin/env bash
# 样本：等待循环里用 pgrep -f 匹配进程名——模式串命中循环自己所在的命令行，永远不退出。
until ! pgrep -f e142-first-txn-dry-run >/dev/null; do sleep 5; done
