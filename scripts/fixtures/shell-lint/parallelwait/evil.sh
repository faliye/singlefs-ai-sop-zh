#!/usr/bin/env bash
# 样本：把检测项并行起来之后，失败全被光秃的 wait 吃掉。
# 三项里红了一项，wait 的退出码还是 0，末尾照样报绿——一道再也红不了的门禁。
for case_dir in cases/*/; do
  ( bash check-one.sh "$case_dir" ) &
done
wait
echo "  ✓ 全部通过"

# 第二处：标记贴了，却没说退出码收在哪。只写标记等于没说。
for case_dir in cases/*/; do
  ( bash check-one.sh "$case_dir" ) &
done
wait  # shell-lint:exit-collected
