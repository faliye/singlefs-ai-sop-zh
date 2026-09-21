#!/usr/bin/env bash
# 脚本的执行位在暂存区里没有丢。
#
# 手工只暂存「这一轮的」时，`git update-index --cacheinfo` 要自己写模式；写死 100644 就把
# 可执行位丢在暂存区里，而工作区那份还是可执行的——在工作区上跑的门禁一声不吭，
# 丢掉的执行位就这样进了历史，下一次别人 clone 出来的脚本跑不起来。
# 原是使用者项目的一个本地阶段，判据通用（git 模式位与文件系统无关），收归这里。
#
# 判据（只看已跟踪的 .sh 与 .py，fixtures/ 下的不看——样本故意不可执行）：
#   ① `.sh` 在暂存区里必须是 100755；
#   ② 暂存区里的模式与工作区的执行位一致（100755 ⇔ 工作区可执行）。
#
# 用法：
#   script-modes.sh [目录…]        不给目录就扫本包的 scripts/
#
# 扫到 0 个脚本判红：射程写窄了会让这一条什么也没验，而末尾照样报绿
# （rules/show-me-test.md：扫到 0 项也不是通过）。
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIRS=("$@")
((${#DIRS[@]})) || DIRS=("$SCRIPTS")

ROOT="$(cd "${DIRS[0]}" && git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$ROOT" ]]; then
  warn "不在 git 仓库里，这一条无对象可判（暂存区的模式只有 git 仓里才有）"
  exit 77
fi

checked=0; wrong=0
# git ls-files 的输出先整份读进来再逐行判：管道里逐行读时，循环体里的计数留在子 shell
# 里出不来（rules/command-safety.md：子 shell 里的赋值传不回父进程）。
entries="$(git -C "$ROOT" ls-files -s -z -- "${DIRS[@]}" | tr '\0' '\n' || true)"
while IFS= read -r entry; do
  [[ -n "$entry" ]] || continue
  mode="${entry%% *}"; path="${entry#*$'\t'}"
  case "$path" in */fixtures/*) continue ;; esac
  case "$path" in *.sh|*.py) ;; *) continue ;; esac
  checked=$((checked + 1))
  full="$ROOT/$path"
  if [[ "$path" == *.sh && "$mode" != 100755 ]]; then
    say "  ✗ $path 在暂存区里是 $mode，.sh 要可执行"   # gate-lint:detail
    wrong=$((wrong + 1)); continue
  fi
  [[ -f "$full" ]] || continue
  if { [[ -x "$full" ]] && [[ "$mode" != 100755 ]]; } || { [[ ! -x "$full" ]] && [[ "$mode" == 100755 ]]; }; then
    say "  ✗ $path 在暂存区里是 $mode，与工作区的执行位不一致"   # gate-lint:detail
    wrong=$((wrong + 1))
  fi
done <<< "$entries"

if (( checked == 0 )); then
  bad "一个已跟踪的 .sh / .py 都没查到（射程：${DIRS[*]}）"
  howto "在仓根跑，或者把要扫的目录作为参数传进来。" \
        "射程写窄了的话这一条什么也没验，而末尾照样会报绿。"
  exit 1
fi

if (( wrong > 0 )); then
  bad "$wrong 个脚本的执行位在暂存区里不对（查了 $checked 个）"   # gate-lint:summary
  howto "用 git update-index --chmod=+x <路径>（或 -x）改暂存区里的模式，让它与工作区一致。" \
        "手工暂存时别写死 100644——那会把可执行位丢进历史。"
  exit 1
fi
ok "查了 $checked 个脚本：.sh 都可执行，暂存区里的模式与工作区一致"
