#!/usr/bin/env bash
# 项目本地门禁阶段自己会不会红。
#
# 拿一组「本该红」和「本该绿」的样本喂给每个本地阶段，看它判得对不对。
# 上游的「门禁判别力」阶段只覆盖共享脚本，够不着项目自己在 .claude/gate.d/ 里接的那一批，
# 而一条恒绿的检查与一条真在跑的检查，在门禁输出里长得一模一样
# （rules/sop-first.md：门禁脚本自己也要有测试）。
# 原是使用者项目的一个本地阶段，判据通用，收归这里。
#
# 怎么加样本：`<阶段目录>/fixtures/<阶段文件名>/{red,green}/`，
# 里面按仓库结构摆好被判的文件，再写一个 `expect`：
#   exit=1
#   want=失败信息里必须出现的片段     # 红样本至少一条；防「因为别的原因红了」也算过
# 要 git 仓之类的现场，在样本目录里放一个 `setup.sh`——样本先被拷进临时目录，
# setup.sh 在那里跑，所以不会把 `.git` 塞进本仓。
#
# 用法：
#   stage-selftest.sh [阶段目录]      不给就找 <仓根>/.claude/gate.d
#
# 没有阶段目录时退 77（本次无对象可判），不报绿
# （rules/show-me-test.md：exit 0 的跳过在汇总里与「判过了」一模一样）。
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GD="${1:-}"
if [[ -z "$GD" ]]; then
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  GD="$root/.claude/gate.d"
fi
if [[ ! -d "$GD" ]] || ! compgen -G "$GD/*.sh" >/dev/null; then
  exit 77
fi
FX="$GD/fixtures"

if [[ ! -d "$FX" ]]; then
  bad "缺样本目录 $FX"
  howto "样本要随仓走，否则下一个改门禁的人无从复跑。" \
        "一个阶段配 fixtures/<阶段文件名>/{red,green}/，红样本至少一条 want。"
  exit 1
fi

pass=0; fail=0; nocase=()
for stage in "$GD"/*.sh; do
  name="$(basename "$stage")"
  if [[ ! -d "$FX/$name" ]]; then nocase+=("$name"); continue; fi
  for kind in red green; do
    d="$FX/$name/$kind"
    [[ -d "$d" ]] || continue
    want_exit="$(sed -n 's/^exit=//p' "$d/expect")"
    # 样本先拷进临时目录再跑：有 setup.sh 的（例如要 git 仓的阶段）在那里建现场，
    # 免得把 .git 之类的东西塞进本仓。
    work="$(mktemp -d)"
    cp -a "$d/." "$work/"
    # 样本在清掉 GATE_BASE / GATE_STAGED_FROM 的环境里跑：`gate.sh --staged` 把真仓的 diff
    # 基准传给里层，漏进样本就成了临时仓里不存在的提交（实测：--staged 下一对红绿样本一起判错）。
    if [[ -f "$work/setup.sh" ]]; then
      if ! ( cd "$work" && env -u GATE_BASE -u GATE_STAGED_FROM bash setup.sh >/dev/null 2>&1 ); then
        say "  ✗ $(printf '%-28s %-5s' "$name" "$kind") setup.sh 没跑成"   # gate-lint:detail
        fail=$((fail+1)); rm -rf "${work:?}"; continue
      fi
    fi
    # 退出码要在 `|| got=$?` 里取：lib.sh 带进来的 set -e 会在样本判红的那一行
    # 把整个脚本带走，而判红正是这里最要看的结果（rules/command-safety.md）。
    out=""; got=0
    out="$(cd "$work" && env -u GATE_BASE -u GATE_STAGED_FROM bash "$stage" "$work" 2>&1)" || got=$?
    rm -rf "${work:?}"
    okc=1
    if [[ "$got" != "$want_exit" ]]; then
      say "  ✗ $(printf '%-28s %-5s' "$name" "$kind") 期望退出 $want_exit，实测 $got"   # gate-lint:detail
      okc=0
    fi
    while IFS= read -r w; do
      [[ -z "$w" ]] && continue
      if ! grep -qF -- "$w" <<<"$out"; then
        say "  ✗ $(printf '%-28s %-5s' "$name" "$kind") 输出里找不到「$w」"   # gate-lint:detail
        okc=0
      fi
    done < <(sed -n 's/^want=//p' "$d/expect")
    if ((okc)); then say "  ✓ $(printf '%-28s %-5s' "$name" "$kind") 判得对"; pass=$((pass+1)); else fail=$((fail+1)); fi
  done
done

if ((${#nocase[@]})); then
  warn "这些阶段还没有判别力样本，这一条**没有验过它们**："
  printf '      %s\n' "${nocase[@]}"
  howto "一条永远不红的检查与没有这条检查，在门禁输出里长得一模一样。" \
        "给它配 fixtures/<阶段文件名>/{red,green}/，或者把这笔欠账记进项目的欠检查清单。"
fi
if ((fail)); then
  bad "$fail 个样本判错（判对 $pass 个，$((${#nocase[@]})) 个阶段没有样本）"   # gate-lint:summary
  howto "上面每一条写着它错在哪：退出码不对，或者输出里找不到 want。" \
        "样本该改就改 expect，检查坏了就改那个阶段——别两边一起改到自洽为止。"
  exit 1
fi
ok "有样本的阶段判得都对（$pass 个样本），$((${#nocase[@]})) 个阶段仍未自检"
