#!/usr/bin/env bash
# 样本：由几段变量拼成的路径，`:?` 只挡整串为空，挡不住其中一段为空。
root="$1"; name="$2"
copy="$root/$name/copy"
rm -rf -- "${copy:?}"
local_build="${root}/${name}"
rm -r "$local_build"
half_guarded="${root:?}/$name/copy"
rm -rf -- "${half_guarded:?}"
