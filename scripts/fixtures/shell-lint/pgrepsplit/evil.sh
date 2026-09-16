#!/usr/bin/env bash
# 样本：pgrep -f 先赋给变量、下一行才 kill——与 pkill -f 同一个自杀风险，拆成两行不算躲开。
pids="$(pgrep -f e142-first-txn-dry-run)"
kill $pids
