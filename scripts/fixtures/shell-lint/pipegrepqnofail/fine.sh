#!/usr/bin/env bash
# 样本：没设 pipefail，S7 不判——管道退出码本来就只看最后一段，
# grep -q 的退出码就是整条管道的退出码，读不错。
set -u

if git show --stat HEAD | grep -q decisions.md; then
  echo "这次提交动了决策文件"
fi
