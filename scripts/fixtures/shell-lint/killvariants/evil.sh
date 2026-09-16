#!/usr/bin/env bash
# 样本：同一条命令的六种拼法，写死 -f 的时候整体漏检。
a() { pkill --full batch-job; }
b() { pkill -af batch-job; }
c() { /usr/bin/pkill -f batch-job; }
d() { command pkill -f batch-job; }
e() { /usr/bin/killall fio; }
f() { pgrep -f batch-job | xargs kill; }
