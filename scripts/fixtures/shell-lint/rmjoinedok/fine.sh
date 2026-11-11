#!/usr/bin/env bash
# 样本：该绿的写法。判红就是误伤。
d="$(mktemp -d)"
rm -rf -- "${d:?}"
cache="$HOME/.cache/x"
rm -rf "${cache:?}"
rm -rf -- /home/someone/work/copy
scratch="$(mktemp -d)"; fake="$scratch/bin"; mkdir -p "$scratch/a" "$scratch/b"
rm -rf "${scratch:?}"
root="$1"; name="$2"
guarded_copy="${root:?}/${name:?}/copy"
rm -rf -- "${guarded_copy:?}"
