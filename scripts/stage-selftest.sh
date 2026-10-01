#!/usr/bin/env bash
# gate-similar: selftest.sh 它拿本包自己的样本喂共享脚本；这一道按 <阶段目录>/fixtures/<阶段>/{red,green}/ 的约定喂项目本地阶段，射程与样本格式都不同
# admission: always 项目的本地阶段与它们的样本随时在改，不在本包的输入里
# run-condition: command python3
# 项目本地门禁阶段自己会不会红。
#
# 拿一组「本该红」和「本该绿」的样本喂给每个本地阶段，看它判得对不对。
# 上游的「门禁判别力」阶段只覆盖共享脚本，够不着项目自己在 .claude/gate.d/ 里接的那一批，
# 而一条恒绿的检查与一条真在跑的检查，在门禁输出里长得一模一样
# （rules/sop-first.md：门禁脚本自己也要有测试）。
# 原是使用者项目的一个本地阶段，判据通用，收归这里。
#
# 怎么加样本：`<阶段目录>/fixtures/<阶段文件名>/{red,green}/`，要第三种情形就再开一个别的名字的目录（先跑 red、green，其余按名字跑），
# 里面按仓库结构摆好被判的文件，再写一个 `expect`：
#   exit=1
#   want=失败信息里必须出现的片段     # 红样本至少一条；防「因为别的原因红了」也算过
# 要 git 仓之类的现场，在样本目录里放一个 `setup.sh`——样本先被拷进临时目录，
# setup.sh 在那里跑，所以不会把 `.git` 塞进本仓。
#
# 用法：
#   stage-selftest.sh [阶段目录]                    不给就找本脚本所在包的根下的 .claude/gate.d（<包根>/.claude/gate.d）；
#                                                   装进项目时包根是 .claude/<包名>/，不是项目根，所以项目里要把阶段目录作为参数给（gate.sh 就是这么调的）
#   stage-selftest.sh [阶段目录] --item <阶段文件名>  只喂点名那几道的样本，给几次取并集；没点名的不起、也不报「本次未跑」
#   stage-selftest.sh [阶段目录] --list-items        逐行列出配了样本、可以点名的阶段，不喂样本
# 退出码：0 判得都对；1 有样本判错；2 用法错（--item 缺值、点名的阶段没配样本或不存在，都列出可点名的阶段）；77 无对象可判；78 准入不满足。
#
# 没有阶段目录、或者没有一个阶段配了样本时退 77（本次无对象可判），不报绿
# （rules/show-me-test.md「门禁不许假装通过」：exit 0 的跳过在汇总里与「判过了」一模一样）。
# 没配样本的阶段逐个用 report_not_run 报出来：门禁下它们进汇总的「本次未跑」，不只在这一段里 warn 一句。
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight "${BASH_SOURCE[0]}" "$@"; set -- ${PREFLIGHT_ARGUMENTS[@]+"${PREFLIGHT_ARGUMENTS[@]}"}

GD=""; requested_stages=(); list_items_only=0
while (($#)); do
  case "$1" in
    --item)
      if (($# < 2)) || [[ -z "$2" ]]; then requested_stages+=(""); shift; continue; fi
      requested_stages+=("$2"); shift 2 ;;
    --list-items) list_items_only=1; shift ;;
    *) GD="$1"; shift ;;
  esac
done
if [[ -z "$GD" ]]; then
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  GD="$root/.claude/gate.d"
fi
if [[ ! -d "$GD" ]]; then
  warn "没有阶段目录 $GD，本阶段无对象可判（这不是通过）"
  exit 77
fi
if ! compgen -G "$GD/*.sh" >/dev/null; then
  warn "$GD 下没有本地阶段（*.sh），本阶段无对象可判（这不是通过）"
  exit 77
fi
# 阶段要在样本的临时目录里跑，相对路径到了那里就指不到东西。手跑时传 `.claude/gate.d`，
# 每个样本都会以 127 收场，而报出来的是「N 个样本判错」，出路指向改 expect 或改那个阶段——两边其实都没毛病。
GD="$(cd "$GD" && pwd)"
FX="$GD/fixtures"

if [[ ! -d "$FX" ]]; then
  bad "缺样本目录 $FX"
  howto "样本要随仓走，否则下一个改门禁的人无从复跑。" \
        "一个阶段配 fixtures/<阶段文件名>/{red,green}/，红样本至少一条 want。"
  exit 1
fi

# 配了样本、可以点名的阶段：--list-items 列它们，--item 只认它们。
stages_with_samples=()
for stage in "$GD"/*.sh; do
  [[ -d "$FX/$(basename "$stage")" ]] && stages_with_samples+=("$(basename "$stage")")
done
if ((list_items_only)); then
  printf '%s\n' ${stages_with_samples[@]+"${stages_with_samples[@]}"}
  exit 0
fi
for requested_stage in ${requested_stages[@]+"${requested_stages[@]}"}; do
  if [[ -z "$requested_stage" || ! " ${stages_with_samples[*]-} " == *" $requested_stage "* ]]; then
    say "  ✗ --item ${requested_stage:-（缺阶段名）}：$GD 下没有这个配了样本的阶段"   # gate-lint:detail
    say "     → 怎么办：点名下面列的阶段文件名之一（stage-selftest.sh $GD --list-items 也列这一份）："
    printf '       %s\n' ${stages_with_samples[@]+"${stages_with_samples[@]}"}
    exit 2
  fi
done

pass=0; fail=0; nocase=()
for stage in "$GD"/*.sh; do
  name="$(basename "$stage")"
  if ((${#requested_stages[@]})) && [[ ! " ${requested_stages[*]} " == *" $name "* ]]; then continue; fi
  if [[ ! -d "$FX/$name" ]]; then nocase+=("$name"); continue; fi
  # 样本只验阶段判得对不对，不产出证据：写了准入与运行条件的阶段带 --force 喂（输入没变、环境不齐也照判；
  # 强制跑的那一次不记成「上次成功」）。没写的不带：它还不认 --force，多一个参数可能被当成项目根（rules/preflight-discipline.md）。
  stage_force_option=()
  if python3 "$(dirname "${BASH_SOURCE[0]}")/preflight.py" declared "$stage"; then stage_force_option=(--force); fi
  # 先跑 red、green，再按名字跑别的样本目录（例如「登记表 0 行」这种第三种情形）：带 expect 的都跑，
  # 只认 red / green 的话，第三种样本摆在那里看着像验过了，其实一次都没被跑到。
  sample_kinds=(red green)
  while IFS= read -r extra_kind; do
    [[ "$extra_kind" == red || "$extra_kind" == green ]] || sample_kinds+=("$extra_kind")
  done < <(find "$FX/$name" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
  for kind in "${sample_kinds[@]}"; do
    d="$FX/$name/$kind"
    [[ -d "$d" ]] || continue
    if [[ ! -f "$d/expect" ]]; then
      say "  ✗ $(printf '%-28s %-5s' "$name" "$kind") 样本目录里没有 expect，判不了它该红还是该绿"   # gate-lint:detail
      fail=$((fail+1)); continue
    fi
    want_exit="$(sed -n 's/^exit=//p' "$d/expect")"
    # 样本先拷进临时目录再跑：有 setup.sh 的（例如要 git 仓的阶段）在那里建现场，
    # 免得把 .git 之类的东西塞进本仓。
    work="$(mktemp -d)"
    cp -a "$d/." "$work/"
    # 样本在清掉 GATE_BASE / GATE_STAGED_FROM / GATE_DIFF_BASE 的环境里跑：`gate.sh --staged` 把真仓的 diff
    # 基准传给里层，`gate.sh` 自己也导出 GATE_DIFF_BASE，漏进样本就成了临时仓里不存在的提交（实测：--staged 下一对红绿样本一起判错）。
    if [[ -f "$work/setup.sh" ]]; then
      if ! ( cd "$work" && env -u GATE_BASE -u GATE_STAGED_FROM -u GATE_DIFF_BASE bash setup.sh >/dev/null 2>&1 ); then
        say "  ✗ $(printf '%-28s %-5s' "$name" "$kind") setup.sh 没跑成"   # gate-lint:detail
        fail=$((fail+1)); rm -rf "${work:?}"; continue
      fi
    fi
    # 退出码要在 `|| got=$?` 里取：lib.sh 带进来的 set -e 会在样本判红的那一行
    # 把整个脚本带走，而判红正是这里最要看的结果（rules/command-safety.md）。
    out=""; got=0
    out="$(cd "$work" && env -u GATE_BASE -u GATE_STAGED_FROM -u GATE_DIFF_BASE bash "$stage" "$work" ${stage_force_option[@]+"${stage_force_option[@]}"} 2>&1)" || got=$?
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
  for stage_without_samples in "${nocase[@]}"; do
    report_not_run "$stage_without_samples 没有判别力样本，它会不会红没有验过（配 fixtures/$stage_without_samples/{red,green}/）"
  done
  say "     一条永远不红的检查与没有这条检查，在门禁输出里长得一模一样：给它们配样本，或者把这笔欠账记进项目的欠检查清单。"
fi
if ((fail)); then
  bad "$fail 个样本判错（判对 $pass 个，$((${#nocase[@]})) 个阶段没有样本）"   # gate-lint:summary
  howto "上面每一条写着它错在哪：退出码不对，或者输出里找不到 want。" \
        "样本该改就改 expect，检查坏了就改那个阶段——别两边一起改到自洽为止。"
  exit 1
fi
if ((pass == 0)); then
  warn "没有一个阶段配了样本，一个样本都没判，本阶段无对象可判（这不是通过）"
  exit 77
fi
if ((${#requested_stages[@]})); then
  ok "点名的 ${#requested_stages[@]} 道阶段判得都对（$pass 个样本）：${requested_stages[*]}；没点名的这一趟不喂"
  exit 0
fi
ok "有样本的阶段判得都对（$pass 个样本），$((${#nocase[@]})) 个阶段仍未自证"
