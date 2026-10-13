#!/usr/bin/env bash
# 样本：该绿的三种写法。判红就是误伤。
#   1. 带 :? 守卫，变量为空时 shell 直接报错，轮不到 rm 动手
#   2. 变量后面没有路径：为空时是 rm -rf ""，rm 自己会拒
#   3. 写死的相对路径，不涉及变量
d="$(mktemp -d)"
rm -rf "${d:?}/work"
rm -rf "$d"
rm -rf build/tmp
# 4. 同一行里 rm 前后别的命令带变量路径，rm 自己的参数守卫过或没跟路径
[[ -n "$d" && "$d" == "$d"/sub* ]] && rm -rf -- "${d:?}"
rm -rf "$d" && mkdir -p "$d/work"
cp -a "$d/." build/ || { rm -rf build/tmp; }
