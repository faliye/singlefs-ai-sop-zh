#!/usr/bin/env bash
# 样本：总结句写在 && 后面、不报数；它前面是循环里逐项的 ok。总结句要被认出来，判的是它
fails=0
for f in "$1"/*.md; do ok "逐项 $f"; done
(( fails == 0 )) && ok "全部通过"
