#!/usr/bin/env bash
# gate-similar: selftest.sh 它拿本包自己的样本喂共享脚本；这一道按阶段自己登记的用例喂项目本地阶段，射程与样本格式都不同
# admission: always 项目的本地阶段与它们的用例随时在改，不在本包的输入里
# run-condition: command python3
# 项目本地门禁阶段自己会不会红。
#
# 拿「本该红」和「本该绿」的用例喂每个本地阶段，看它判得对不对。上游的门禁判别力阶段只覆盖共享脚本，
# 项目登记的门禁目录（默认 .claude/gate.d/）下的阶段靠这一道证明会红（rules/sop-first.md：门禁脚本自己也要有测试）。
#
# 阶段与用例认两种形态，过渡期并存：
#   新形态（推荐）：一道阶段一个目录 `<门禁目录>/<阶段名>/<阶段名>.sh`，用例是同一目录下的 `<用例名>.case.sh`，一条一个文件。
#     用例文件头几行写期望：
#       # expect-exit: <退出码>
#       # expect-want: <失败信息里必须出现的片段>   # 期望非 0 的用例至少一条；防「因为别的原因红了」也算过
#     正文是造输入的脚本：在它自己的临时工作目录里跑（cwd 就是传给阶段的那个目录），起到旧形态 setup.sh 加摆好的样本文件两样的作用。
#   旧形态：扁平的 `<门禁目录>/<阶段文件名>.sh`，用例在 `<门禁目录>/fixtures/<阶段文件名>/{red,green}/`
#     （第三种情形另开一个别的名字的目录，先跑 red、green，其余按名字跑），里面按仓库结构摆好被判的文件，
#     再写一个 `expect`：
#       exit=1
#       want=失败信息里必须出现的片段
#     要 git 仓之类的现场，放一个 `setup.sh`：样本先拷进临时目录，setup.sh 在那里跑，`.git` 不会进本仓。
#
# 用法：
#   stage-selftest.sh [门禁目录]                    不给就找本脚本所在包的根下登记的门禁目录（没登记就是默认值 <包根>/.claude/gate.d）；
#                                                   装进项目时包根是 .claude/<包名>/，不是项目根，所以项目里要把门禁目录作为参数给（gate.sh 就是这么调的）
#   stage-selftest.sh [门禁目录] --item <阶段名>     只喂点名那几道的用例，给几次取并集；没点名的不起、也不报「本次未跑」
#   stage-selftest.sh [门禁目录] --list-items        逐行列出配了用例、可以点名的阶段，不喂用例
# 退出码：0 判得都对；1 有用例判错；2 用法错（--item 缺值、点名的阶段没配用例或不存在，都列出可点名的阶段）；77 无对象可判；78 准入不满足。
#
# 没有门禁目录、或者一个阶段都没找到时退 77，不报绿（rules/show-me-test.md「门禁不许假装通过」）。
# 没配用例的阶段逐个 report_not_run，进门禁汇总的「本次未跑」。
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
  GD="$root/$(project_gate_dir "$root")"
fi
if [[ ! -d "$GD" ]]; then
  warn "没有门禁目录 $GD，本阶段无对象可判（这不是通过）"
  exit 77
fi
# 阶段在用例的临时目录里跑，相对路径到那里指不到：手跑传 `.claude/gate.d` 会让每个用例退 127、报成「用例判错」。
GD="$(cd "$GD" && pwd)"
FX="$GD/fixtures"

# 收集阶段：扁平的 <门禁目录>/<名>.sh（旧形态），与嵌套的 <门禁目录>/<名>/<名>.sh（新形态）。
# 两份路径分别存，报告时按它属于哪种形态取用例的来源；名字（不带 .sh）两种形态里都唯一。
STAGE_NAMES=(); STAGE_PATHS=(); STAGE_FORMS=()
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  STAGE_NAMES+=("$(basename "$f")"); STAGE_PATHS+=("$f"); STAGE_FORMS+=(flat)
done < <(find "$GD" -maxdepth 1 -name '*.sh' \( -type f -o -type l \) | sort)
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  dir_name="$(basename "$(dirname "$f")")"
  file_name="$(basename "$f" .sh)"
  [[ "$dir_name" == "$file_name" ]] || continue
  STAGE_NAMES+=("$file_name"); STAGE_PATHS+=("$f"); STAGE_FORMS+=(nested)
done < <(find "$GD" -mindepth 2 -maxdepth 2 -name '*.sh' \( -type f -o -type l \) | sort)
if ((${#STAGE_NAMES[@]} == 0)); then
  warn "$GD 下没有本地阶段（扁平的 *.sh，或嵌套的 <名>/<名>.sh），本阶段无对象可判（这不是通过）"
  exit 77
fi

# 一道阶段配没配用例：新形态看同目录下的 *.case.sh；旧形态看 fixtures/<阶段文件名>/ 是否存在。
stage_has_cases() { # stage_has_cases <下标>
  local index="$1"
  if [[ "${STAGE_FORMS[$index]}" == nested ]]; then
    compgen -G "$(dirname "${STAGE_PATHS[$index]}")/*.case.sh" >/dev/null
  else
    [[ -d "$FX/${STAGE_NAMES[$index]}" ]]
  fi
}

# 配了用例、可以点名的阶段：--list-items 列它们，--item 只认它们。
stages_with_samples=()
for ((index = 0; index < ${#STAGE_NAMES[@]}; index++)); do
  stage_has_cases "$index" && stages_with_samples+=("${STAGE_NAMES[$index]}")
done
if ((list_items_only)); then
  printf '%s\n' ${stages_with_samples[@]+"${stages_with_samples[@]}"}
  exit 0
fi
for requested_stage in ${requested_stages[@]+"${requested_stages[@]}"}; do
  if [[ -z "$requested_stage" || ! " ${stages_with_samples[*]-} " == *" $requested_stage "* ]]; then
    say "  ✗ --item ${requested_stage:-（缺阶段名）}：$GD 下没有这个配了用例的阶段"   # gate-lint:detail
    say "     → 怎么办：点名下面列的阶段名之一（stage-selftest.sh $GD --list-items 也列这一份）："
    printf '       %s\n' ${stages_with_samples[@]+"${stages_with_samples[@]}"}
    exit 2
  fi
done

pass=0; fail=0; nocase=()

# 判一条用例：外层已经跑完它的「建场景」步骤、拿到了 $got 与 $out。
judge_case() { # judge_case <名字> <用例标签> <期望退出码> <实测退出码> <输出> <want...>
  local name="$1" label="$2" want_exit="$3" got="$4" out="$5"; shift 5
  local okc=1
  if [[ "$got" != "$want_exit" ]]; then
    say "  ✗ $(printf '%-28s %-16s' "$name" "$label") 期望退出 $want_exit，实测 $got"   # gate-lint:detail
    okc=0
  fi
  local w
  for w in "$@"; do
    [[ -z "$w" ]] && continue
    if ! grep -qF -- "$w" <<<"$out"; then
      say "  ✗ $(printf '%-28s %-16s' "$name" "$label") 输出里找不到「$w」"   # gate-lint:detail
      okc=0
    fi
  done
  if ((okc)); then
    say "  ✓ $(printf '%-28s %-16s' "$name" "$label") 判得对"
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
  fi
}

for ((index = 0; index < ${#STAGE_NAMES[@]}; index++)); do
  name="${STAGE_NAMES[$index]}"
  stage="${STAGE_PATHS[$index]}"
  form="${STAGE_FORMS[$index]}"
  if ((${#requested_stages[@]})) && [[ ! " ${requested_stages[*]} " == *" $name "* ]]; then continue; fi
  if ! stage_has_cases "$index"; then nocase+=("$name"); continue; fi
  # 写了准入与运行条件的阶段带 --force 喂：输入没变、环境不齐也照判，强制跑不记成「上次成功」。
  # 没写的不带：它不认 --force，多一个参数可能被当成项目根。
  stage_force_option=()
  if python3 "$(dirname "${BASH_SOURCE[0]}")/preflight.py" declared "$stage"; then stage_force_option=(--force); fi

  if [[ "$form" == nested ]]; then
    stage_dir="$(dirname "$stage")"
    while IFS= read -r case_file; do
      [[ -n "$case_file" ]] || continue
      case_label="$(basename "$case_file" .case.sh)"
      want_exit="$(sed -n 's/^#[[:space:]]*expect-exit:[[:space:]]*//p' "$case_file" | head -1)"
      if [[ -z "$want_exit" ]]; then
        say "  ✗ $(printf '%-28s %-16s' "$name" "$case_label") 用例文件没写 # expect-exit:，判不了它该红还是该绿"   # gate-lint:detail
        fail=$((fail + 1)); continue
      fi
      mapfile -t want_list < <(sed -n 's/^#[[:space:]]*expect-want:[[:space:]]*//p' "$case_file")
      work="$(mktemp -d)"
      # 清掉 GATE_BASE / GATE_STAGED_FROM / GATE_DIFF_BASE：gate.sh 导出的是真仓的 diff 基准，
      # 漏进用例就是临时仓里不存在的提交（实测：--staged 下一对红绿用例一起判错）。
      if ! ( cd "$work" && env -u GATE_BASE -u GATE_STAGED_FROM -u GATE_DIFF_BASE bash "$case_file" >/dev/null 2>&1 ); then
        say "  ✗ $(printf '%-28s %-16s' "$name" "$case_label") 用例的建场景正文没跑成"   # gate-lint:detail
        fail=$((fail + 1)); rm -rf "${work:?}"; continue
      fi
      # 退出码在 `|| got=$?` 里取：lib.sh 带进来的 set -e 会在用例判红那一行退出整个脚本。
      out=""; got=0
      out="$(cd "$work" && env -u GATE_BASE -u GATE_STAGED_FROM -u GATE_DIFF_BASE bash "$stage" "$work" ${stage_force_option[@]+"${stage_force_option[@]}"} 2>&1)" || got=$?
      rm -rf "${work:?}"
      judge_case "$name" "$case_label" "$want_exit" "$got" "$out" ${want_list[@]+"${want_list[@]}"}
    done < <(find "$stage_dir" -maxdepth 1 -name '*.case.sh' | sort)
    continue
  fi

  # 旧形态：fixtures/<阶段文件名>/{red,green,其余按名字}/，带 expect 的样本目录都跑——只认 red / green 的话，
  # 第三种样本看着像验过了，其实一次都没跑到。
  sample_kinds=(red green)
  while IFS= read -r extra_kind; do
    [[ "$extra_kind" == red || "$extra_kind" == green ]] || sample_kinds+=("$extra_kind")
  done < <(find "$FX/$name" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
  for kind in "${sample_kinds[@]}"; do
    d="$FX/$name/$kind"
    [[ -d "$d" ]] || continue
    if [[ ! -f "$d/expect" ]]; then
      say "  ✗ $(printf '%-28s %-16s' "$name" "$kind") 样本目录里没有 expect，判不了它该红还是该绿"   # gate-lint:detail
      fail=$((fail + 1)); continue
    fi
    want_exit="$(sed -n 's/^exit=//p' "$d/expect")"
    mapfile -t want_list < <(sed -n 's/^want=//p' "$d/expect")
    work="$(mktemp -d)"
    cp -a "$d/." "$work/"
    if [[ -f "$work/setup.sh" ]]; then
      if ! ( cd "$work" && env -u GATE_BASE -u GATE_STAGED_FROM -u GATE_DIFF_BASE bash setup.sh >/dev/null 2>&1 ); then
        say "  ✗ $(printf '%-28s %-16s' "$name" "$kind") setup.sh 没跑成"   # gate-lint:detail
        fail=$((fail + 1)); rm -rf "${work:?}"; continue
      fi
    fi
    out=""; got=0
    out="$(cd "$work" && env -u GATE_BASE -u GATE_STAGED_FROM -u GATE_DIFF_BASE bash "$stage" "$work" ${stage_force_option[@]+"${stage_force_option[@]}"} 2>&1)" || got=$?
    rm -rf "${work:?}"
    judge_case "$name" "$kind" "$want_exit" "$got" "$out" ${want_list[@]+"${want_list[@]}"}
  done
done

if ((${#nocase[@]})); then
  for stage_without_samples in "${nocase[@]}"; do
    report_not_run "$stage_without_samples 没有判别力用例，它会不会红没有验过（新形态配同目录下的 *.case.sh，旧形态配 fixtures/$stage_without_samples/{red,green}/）"
  done
  say "     一条永远不红的检查与没有这条检查，在门禁输出里长得一模一样：给它配用例，或者把这笔欠账记进项目的欠检查清单。"
fi
if ((fail)); then
  bad "$fail 个用例判错（判对 $pass 个，$((${#nocase[@]})) 个阶段没有用例）"   # gate-lint:summary
  howto "上面每一条写着它错在哪：退出码不对，或者输出里找不到 want / expect-want。" \
        "用例该改就改，检查坏了就改那个阶段——别两边一起改到自洽为止。"
  exit 1
fi
if ((pass == 0)); then
  warn "没有一个阶段配了用例，一个用例都没判，本阶段无对象可判（这不是通过）"
  exit 77
fi
if ((${#requested_stages[@]})); then
  ok "点名的 ${#requested_stages[@]} 道阶段判得都对（$pass 个用例）：${requested_stages[*]}；没点名的这一趟不喂"
  exit 0
fi
ok "有用例的阶段判得都对（$pass 个用例），$((${#nocase[@]})) 个阶段仍未自证"
