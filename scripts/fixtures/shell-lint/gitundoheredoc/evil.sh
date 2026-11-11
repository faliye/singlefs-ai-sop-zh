#!/usr/bin/env bash
# 样本：喂给 bash 的 here-doc 是代码，里面会丢掉未提交改动的 git 命令照样红。
bash <<'SCRIPT'
git reset --hard HEAD~1
SCRIPT
