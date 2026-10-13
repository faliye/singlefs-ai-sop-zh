#!/usr/bin/env bash
# gate-similar: 无 查过 shell-lint.sh、gate-lint.sh：它们读脚本正文，没有哪一道读暂存区里的文件模式
# admission: always 判的是此刻暂存区里的文件模式，一秒跑完
# run-condition: command git
# 脚本的执行位在暂存区里没有丢，射程里也没有 git 存不下的空目录。
#
# 手工暂存时 `git update-index --cacheinfo` 写死 100644，执行位就丢在暂存区里；工作区那份仍可执行，
# 在工作区上跑的门禁看不见，丢掉的执行位就进了历史。
#
# 判据（只看已跟踪的 .sh 与 .py，fixtures/ 下的不看：样本故意不可执行）：
#   执行位：`.sh` 在暂存区里必须是 100755；
#   模式一致：暂存区里的模式与工作区的执行位一致（100755 ⇔ 工作区可执行）。
#   符号链接（120000）判它在暂存区里指向的那一份：那一份也要在暂存区里，.sh 的要是 100755；
#   空目录：射程里没有空目录（.git 与被 .gitignore 挡着的不算）：空目录进不了提交，工作区里靠它过的样本
#      到了提交与 --staged 的临时树里就没有那个目录。这一条只在工作区上看得见。
#
# 用法：
#   script-modes.sh [目录…]        不给目录就扫本包的 scripts/
#
# 扫到 0 个脚本判红（rules/show-me-test.md：扫到 0 项也不是通过）。
# 判不了的目录（不存在、不在 git 仓里、一个已跟踪的 .sh / .py 都没有，比如被 .gitignore 挡着的规范副本）
# 逐个 report_not_run：别的目录查到了东西时，成功那句看不出那几处没人查。
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight "${BASH_SOURCE[0]}" "$@"; set -- ${PREFLIGHT_ARGUMENTS[@]+"${PREFLIGHT_ARGUMENTS[@]}"}

SCRIPTS_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCANNED_DIRECTORIES=("$@")
((${#SCANNED_DIRECTORIES[@]})) || SCANNED_DIRECTORIES=("$SCRIPTS_DIRECTORY")

# 每个目录用它自己的仓根解：`gate.sh --staged` 下项目在临时 worktree 里，装进来的 SOP 副本仍在真仓；
# 拿别的仓根 `ls-files` 会 fatal、输出为空，报成「一个都没查到」（实测）。
checked_script_count=0; wrong_mode_count=0; any_directory_in_repository=0; unjudged_directories=()
for scanned_directory in "${SCANNED_DIRECTORIES[@]}"; do
  if [[ ! -d "$scanned_directory" ]]; then unjudged_directories+=("$scanned_directory（不存在）"); continue; fi
  scanned_repository_root="$(cd "$scanned_directory" && git rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -z "$scanned_repository_root" ]]; then unjudged_directories+=("$scanned_directory（不在 git 仓里）"); continue; fi
  any_directory_in_repository=1
  checked_before_this_directory=$checked_script_count
  # 整份读进来再逐行判：接管道的话，循环体里的计数留在子 shell 里出不来。
  entries="$(git -C "$scanned_repository_root" ls-files -s -z -- "$scanned_directory" | tr '\0' '\n' || true)"
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    mode="${entry%% *}"; path="${entry#*$'\t'}"
    case "$path" in */fixtures/*) continue ;; esac
    case "$path" in *.sh|*.py) ;; *) continue ;; esac
    checked_script_count=$((checked_script_count + 1))
    worktree_file_path="$scanned_repository_root/$path"
    # 符号链接（120000）本身没有执行位：判它在暂存区里指向的那一份（gate.sh 照样跑链接形式的本地阶段）
    if [[ "$mode" == 120000 ]]; then
      link_target="$(git -C "$scanned_repository_root" cat-file -p ":$path" 2>/dev/null || true)"
      link_target_path="$(realpath -m --relative-to="$scanned_repository_root" "$scanned_repository_root/$(dirname "$path")/$link_target" 2>/dev/null || true)"
      link_target_mode="$(git -C "$scanned_repository_root" ls-files -s -- "$link_target_path" 2>/dev/null | cut -d' ' -f1 || true)"
      if [[ -z "$link_target" || -z "$link_target_mode" ]]; then
        say "  ✗ $path 是符号链接，指向的 ${link_target_path:-（读不出）} 不在暂存区里，判不了它的执行位"   # gate-lint:detail
        wrong_mode_count=$((wrong_mode_count + 1))
      elif [[ "$path" == *.sh && "$link_target_mode" != 100755 ]]; then
        say "  ✗ $path 是符号链接，指向的 $link_target_path 在暂存区里是 $link_target_mode，.sh 要可执行"   # gate-lint:detail
        wrong_mode_count=$((wrong_mode_count + 1))
      fi
      continue
    fi
    if [[ "$path" == *.sh && "$mode" != 100755 ]]; then
      say "  ✗ $path 在暂存区里是 $mode，.sh 要可执行"   # gate-lint:detail
      wrong_mode_count=$((wrong_mode_count + 1)); continue
    fi
    [[ -f "$worktree_file_path" ]] || continue
    if { [[ -x "$worktree_file_path" ]] && [[ "$mode" != 100755 ]]; } || { [[ ! -x "$worktree_file_path" ]] && [[ "$mode" == 100755 ]]; }; then
      say "  ✗ $path 在暂存区里是 $mode，与工作区的执行位不一致"   # gate-lint:detail
      wrong_mode_count=$((wrong_mode_count + 1))
    fi
  done <<< "$entries"
  if (( checked_script_count == checked_before_this_directory )); then
    unjudged_directories+=("$scanned_directory（一个已跟踪的 .sh / .py 都没有：被 .gitignore 挡着，或还没 git add）")
  fi
done

# 空目录那一条：在 git 仓里的那几个射程目录上数，.git 与被 .gitignore 挡着的跳过
directories_checked=0; empty_directories=()
for scanned_directory in "${SCANNED_DIRECTORIES[@]}"; do
  [[ -d "$scanned_directory" ]] || continue
  scanned_repository_root="$(cd "$scanned_directory" && git rev-parse --show-toplevel 2>/dev/null || true)"
  [[ -n "$scanned_repository_root" ]] || continue
  directory_listing="$(find "$scanned_directory" -name .git -prune -o -type d -print)"
  while IFS= read -r candidate_directory; do
    [[ -n "$candidate_directory" ]] || continue
    if git -C "$scanned_repository_root" check-ignore -q -- "$candidate_directory" 2>/dev/null; then continue; fi
    directories_checked=$((directories_checked + 1))
    if [[ -z "$(find "$candidate_directory" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
      empty_directories+=("$candidate_directory")
    fi
  done <<< "$directory_listing"
done

if (( checked_script_count > 0 )); then
  for unjudged_directory in ${unjudged_directories[@]+"${unjudged_directories[@]}"}; do
    report_not_run "脚本执行位：$unjudged_directory，那里的执行位没查"
  done
fi
if (( any_directory_in_repository == 0 )); then
  warn "射程里没有一个目录在 git 仓库里，这一条无对象可判（暂存区的模式只有 git 仓里才有）"
  exit 77
fi

if (( checked_script_count == 0 )); then
  bad "一个已跟踪的 .sh / .py 都没查到（射程：${SCANNED_DIRECTORIES[*]}）"
  howto "在仓根跑，或者把要扫的目录作为参数传进来。" \
        "射程写窄了的话这一条什么也没验，而末尾照样会报绿。"
  exit 1
fi

if ((${#empty_directories[@]})); then
  for empty_directory in "${empty_directories[@]}"; do
    say "  ✗ $empty_directory 是空目录：git 存不下它，提交与 --staged 的临时树里没有这个目录"   # gate-lint:detail
  done
fi
if (( wrong_mode_count > 0 || ${#empty_directories[@]} > 0 )); then
  bad "$wrong_mode_count 个脚本的执行位在暂存区里不对（查了 $checked_script_count 个）；${#empty_directories[@]} 个空目录（查了 $directories_checked 个目录）"   # gate-lint:summary
  howto "用 git update-index --chmod=+x <路径>（或 -x）改暂存区里的模式，让它与工作区一致；是符号链接的，改它指向的那一份，" \
        "指向的文件没进暂存区就先 git add 它。手工暂存时别写死 100644——那会把可执行位丢进历史。" \
        "空目录要留着的，放一个 .keep 再 git add（: > <目录>/.keep）；用不着的删掉。"
  exit 1
fi
ok "查了 $checked_script_count 个脚本：.sh 都可执行，暂存区里的模式与工作区一致；查了 $directories_checked 个目录，没有空目录（射程 ${#SCANNED_DIRECTORIES[@]} 个目录，没查的 ${#unjudged_directories[@]} 个，见上）"
