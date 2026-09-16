#!/usr/bin/env bash
# 样本：同一件事的四种拼法。写成一整条正则时，只有第 4 行会红。
d=""; a=""; b=""
rm -rf "$d"/x
rm -rf -- "$d/x"
rm -rf "${a:?}/x" "$b/y"
rm -rf "$d/x"
rm -rf "${d:?}/x"
