#!/usr/bin/env bash
# 样本：here-doc 体是数据（写进说明文件），里面写到的 git 命令不是在执行。
cat >notes.txt <<'NOTES'
真要回到干净状态：先 git stash，别用 git checkout -- <文件>
NOTES
