#!/usr/bin/env bash
# 样本：pipefail 下拿 grep -q 收尾。命中时前段吃 SIGPIPE、管道返回 141，
# if 把它读成「没命中」——明明命中，判成没有，而且机器越忙越容易撞上。
set -uo pipefail

if git show --stat HEAD | grep -q decisions.md; then
  echo "这次提交动了决策文件"
fi

if yes X | head -200000 | grep -qx X; then
  echo "找到了"
fi
