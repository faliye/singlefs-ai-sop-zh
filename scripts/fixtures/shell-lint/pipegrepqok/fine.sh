#!/usr/bin/env bash
# 样本：这两种都不判。
# ① 输出先落到变量，再对变量判——这是出路本身。
set -uo pipefail

stat_out="$(git show --stat HEAD || true)"
if grep -q decisions.md <<<"$stat_out"; then
  echo "这次提交动了决策文件"
fi

# ② grep -q 读的是 here-string，没有前段，谈不上 SIGPIPE。
if grep -q X <<<"$stat_out"; then echo "有 X"; fi

# ③ 没设 pipefail 的脚本不判：管道退出码本来就只看最后一段。
#    这一条由 fixtures/shell-lint/pipegrepqnofail 盯着。

# ④ `||` 后面接 grep -q 读文件是「或」链，不是管道：没有前段，谈不上 SIGPIPE。行首续行的 `|| grep -q` 也一样。
if [[ -z "$stat_out" ]] || ! grep -qF Y "$0" \
   || grep -q X "$0"; then echo "空的，或者本文件里没有 Y、有 X"; fi
