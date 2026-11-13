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
#     正文是造输入的脚本：在它自己的临时工作目录里跑（当前目录就是传给阶段的那个目录），起到旧形态 setup.sh 加摆好的样本文件两样的作用。
#   旧形态：扁平的 `<门禁目录>/<阶段文件名>.sh`，用例在 `<门禁目录>/fixtures/<阶段文件名>/{red,green}/`
#     （red、green 之外的情形另开一个别的名字的目录，先跑 red、green，其余按名字跑），里面按仓库结构摆好被判的文件，
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
#   stage-selftest.sh [门禁目录] --jobs <并行度>     同时喂几条用例；不给取环境变量 STAGE_SELFTEST_JOBS，再没有按 nproc。写 1 就是一条一条喂
#
# 并行：用例各在自己的临时工作目录里跑，互不依赖，默认并行喂。每条用例的退出码与输出各写进这一趟的结果目录里它自己的那一格，
#   全部跑完再按登记次序回读、逐条判，打出来的次序与并行度无关。派出去多少条就要收回多少条，对不上整道判红（rules/command-safety.md「并行不许把失败吃掉」）。
#   一道阶段的用例不能同时跑的（共用同一个外部服务、同一个固定端口或固定路径），在阶段文件的前 40 行里单独写一行：
#     # stage-selftest: serial <理由，至少 4 个字>
#   它的用例等并行的那一批全部跑完之后一条一条喂，那时没有别的用例在跑。
#
# STAGE_SELFTEST_BREAK=<开关名> 打开一个弄坏开关（自证专用）：lose-one-result 把并行那一批里第一条的结果丢掉，派收对不上必须判红。
# 退出码：0 判得都对；1 有用例判错或派出去的用例没收全；2 用法错（--item 缺值、点名的阶段没配用例或不存在，都列出可点名的阶段；并行度不是正整数）；77 无对象可判；78 准入不满足。
#
# 没有门禁目录、或者一个阶段都没找到时退 77，不报绿（rules/show-me-test.md「门禁不许假装通过」）。
# 没配用例的阶段逐个 report_not_run，进门禁汇总的「本次未跑」。
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight "${BASH_SOURCE[0]}" "$@"; set -- ${PREFLIGHT_ARGUMENTS[@]+"${PREFLIGHT_ARGUMENTS[@]}"}

gate_directory=""; requested_stages=(); list_items_only=0; case_parallelism="${STAGE_SELFTEST_JOBS:-}"
while (($#)); do
  case "$1" in
    --item)
      if (($# < 2)) || [[ -z "${2//[[:space:]]/}" ]]; then requested_stages+=(""); shift; continue; fi
      # 一个值里用空白隔开的几个名字各算一道；每个名字摘掉结尾的 .sh，与阶段名同一个写法
      read -r -a requested_stage_words <<<"$2"
      for requested_stage_word in "${requested_stage_words[@]}"; do requested_stages+=("${requested_stage_word%.sh}"); done
      shift 2 ;;
    --list-items) list_items_only=1; shift ;;
    --jobs)
      if (($# < 2)); then case_parallelism="（缺值）"; shift; else case_parallelism="$2"; shift 2; fi ;;
    *) gate_directory="$1"; shift ;;
  esac
done
[[ -n "$case_parallelism" ]] || case_parallelism="$(nproc)"
if [[ ! "$case_parallelism" =~ ^[1-9][0-9]*$ ]]; then
  say "  ✗ 并行度「$case_parallelism」不是正整数（--jobs 或环境变量 STAGE_SELFTEST_JOBS 给的）"
  say "     → 怎么办：写一个正整数，比如 --jobs 8；不给就按 nproc；要一条一条喂写 --jobs 1。"
  exit 2
fi
if [[ -z "$gate_directory" ]]; then
  package_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  gate_directory="$package_root/$(project_gate_dir "$package_root")"
fi
if [[ ! -d "$gate_directory" ]]; then
  warn "没有门禁目录 $gate_directory，本阶段无对象可判（这不是通过）"
  exit 77
fi
# 阶段在用例的临时目录里跑，相对路径到那里指不到：手跑传 `.claude/gate.d` 会让每个用例退 127、报成「用例判错」。
gate_directory="$(cd "$gate_directory" && pwd)"
fixtures_directory="$gate_directory/fixtures"

# 收集阶段：扁平的 <门禁目录>/<名>.sh（旧形态），与嵌套的 <门禁目录>/<名>/<名>.sh（新形态）。
# 两份路径分别存，报告时按它属于哪种形态取用例的来源。阶段名两种形态都不带 .sh（--item 写了 .sh 的照认）；
# 旧形态的样本目录仍按阶段文件名（带 .sh）找，存在 STAGE_FIXTURE_NAMES 里。两种形态撞了名的判红。
STAGE_NAMES=(); STAGE_PATHS=(); STAGE_FORMS=(); STAGE_FIXTURE_NAMES=()
while IFS= read -r stage_file; do
  [[ -n "$stage_file" ]] || continue
  STAGE_NAMES+=("$(basename "$stage_file" .sh)"); STAGE_PATHS+=("$stage_file"); STAGE_FORMS+=(flat)
  STAGE_FIXTURE_NAMES+=("$(basename "$stage_file")")
done < <(find "$gate_directory" -maxdepth 1 -name '*.sh' \( -type f -o -type l \) | sort)
while IFS= read -r stage_file; do
  [[ -n "$stage_file" ]] || continue
  stage_directory_name="$(basename "$(dirname "$stage_file")")"
  stage_file_name="$(basename "$stage_file" .sh)"
  [[ "$stage_directory_name" == "$stage_file_name" ]] || continue
  STAGE_NAMES+=("$stage_file_name"); STAGE_PATHS+=("$stage_file"); STAGE_FORMS+=(nested)
  STAGE_FIXTURE_NAMES+=("")
done < <(find "$gate_directory" -mindepth 2 -maxdepth 2 -name '*.sh' \( -type f -o -type l \) | sort)
duplicated_stage_names="$(printf '%s\n' ${STAGE_NAMES[@]+"${STAGE_NAMES[@]}"} | sort | uniq -d)"
if [[ -n "$duplicated_stage_names" ]]; then
  bad "$gate_directory 下有同名的阶段（扁平的 <名>.sh 与嵌套的 <名>/<名>.sh 撞了）：$(tr '\n' ' ' <<<"$duplicated_stage_names")"
  howto "--item 点名时分不清是哪一道：把其中一道改名，或把旧形态那道挪成新形态、删掉旧的那份。"
  exit 1
fi
if ((${#STAGE_NAMES[@]} == 0)); then
  warn "$gate_directory 下没有本地阶段（扁平的 *.sh，或嵌套的 <名>/<名>.sh），本阶段无对象可判（这不是通过）"
  exit 77
fi

# 一道阶段配没配用例：新形态看同目录下的 *.case.sh；旧形态看 fixtures/<阶段文件名>/ 是否存在。
stage_has_cases() { # stage_has_cases <下标>
  local index="$1"
  if [[ "${STAGE_FORMS[$index]}" == nested ]]; then
    compgen -G "$(dirname "${STAGE_PATHS[$index]}")/*.case.sh" >/dev/null
  else
    [[ -d "$fixtures_directory/${STAGE_FIXTURE_NAMES[$index]}" ]]
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
    say "  ✗ --item ${requested_stage:-（缺阶段名）}：$gate_directory 下没有这个配了用例的阶段"   # gate-lint:detail
    say "     → 怎么办：点名下面列的阶段名之一（stage-selftest.sh $gate_directory --list-items 也列这一份）："
    printf '       %s\n' ${stages_with_samples[@]+"${stages_with_samples[@]}"}
    exit 2
  fi
done

correct_case_count=0; wrong_case_count=0; stages_without_cases=()

# 判一条用例：它已经跑完，拿到了退出码与输出。
judge_case() { # judge_case <名字> <用例标签> <期望退出码> <实测退出码> <输出> <want...>
  local name="$1" label="$2" want_exit="$3" actual_exit="$4" stage_output="$5"; shift 5
  local case_judged_correctly=1
  if [[ "$actual_exit" != "$want_exit" ]]; then
    say "  ✗ $(printf '%-28s %-16s' "$name" "$label") 期望退出 $want_exit，实测 $actual_exit"   # gate-lint:detail
    case_judged_correctly=0
  fi
  local wanted_fragment
  for wanted_fragment in "$@"; do
    [[ -z "$wanted_fragment" ]] && continue
    if ! grep -qF -- "$wanted_fragment" <<<"$stage_output"; then
      say "  ✗ $(printf '%-28s %-16s' "$name" "$label") 输出里找不到「$wanted_fragment」"   # gate-lint:detail
      case_judged_correctly=0
    fi
  done
  if ((case_judged_correctly)); then
    say "  ✓ $(printf '%-28s %-16s' "$name" "$label") 判得对"
    correct_case_count=$((correct_case_count + 1))
  else
    wrong_case_count=$((wrong_case_count + 1))
  fi
}

# ── 第一步：按登记次序列出要喂的用例（一条一格），不跑 ──
# CASE_KINDS：nested / flat 是要跑的；unjudgeable 是没跑就判不了的（没写期望），CASE_SOURCES 里放要打的那句话。
CASE_STAGE_NAMES=(); CASE_LABELS=(); CASE_KINDS=(); CASE_STAGES=(); CASE_SOURCES=(); CASE_WANT_EXITS=(); CASE_FORCED=(); CASE_SERIAL=()
serial_stage_names=()
register_case() { # register_case <阶段名> <用例标签> <形态> <阶段文件> <用例文件、样本目录或要打的话> <期望退出码> <带不带 --force> <串行不串行>
  CASE_STAGE_NAMES+=("$1"); CASE_LABELS+=("$2"); CASE_KINDS+=("$3"); CASE_STAGES+=("$4"); CASE_SOURCES+=("$5")
  CASE_WANT_EXITS+=("$6"); CASE_FORCED+=("$7"); CASE_SERIAL+=("$8")
}

for ((index = 0; index < ${#STAGE_NAMES[@]}; index++)); do
  name="${STAGE_NAMES[$index]}"
  stage="${STAGE_PATHS[$index]}"
  form="${STAGE_FORMS[$index]}"
  fixture_name="${STAGE_FIXTURE_NAMES[$index]}"
  if ((${#requested_stages[@]})) && [[ ! " ${requested_stages[*]} " == *" $name "* ]]; then continue; fi
  if ! stage_has_cases "$index"; then stages_without_cases+=("$name"); continue; fi
  # 写了准入与运行条件的阶段带 --force 喂：输入没变、环境不齐也照判，强制跑不记成「上次成功」。
  # 没写的不带：它不认 --force，多一个参数可能被当成项目根。
  stage_forced=0
  if python3 "$(dirname "${BASH_SOURCE[0]}")/preflight.py" declared "$stage"; then stage_forced=1; fi
  # 串行声明：阶段文件前 40 行里的 `# stage-selftest: serial <理由>`。
  stage_serial=0
  serial_declaration="$(head -40 "$stage" | sed -n 's/^#[[:space:]]*stage-selftest:[[:space:]]*serial\([[:space:]].*\)\{0,1\}$/serial\1/p' | head -1)"
  if [[ -n "$serial_declaration" ]]; then
    serial_reason="${serial_declaration#serial}"; serial_reason="${serial_reason//[[:space:]]/}"
    if ((${#serial_reason} < 4)); then
      register_case "$name" "（串行声明）" unjudgeable "$stage" "# stage-selftest: serial 后面没写理由（至少 4 个字）：写明它的用例为什么不能同时跑" "" 0 0
    fi
    stage_serial=1; serial_stage_names+=("$name")
  fi

  if [[ "$form" == nested ]]; then
    while IFS= read -r case_file; do
      [[ -n "$case_file" ]] || continue
      case_label="$(basename "$case_file" .case.sh)"
      want_exit="$(sed -n 's/^#[[:space:]]*expect-exit:[[:space:]]*//p' "$case_file" | head -1)"
      if [[ -z "$want_exit" ]]; then
        register_case "$name" "$case_label" unjudgeable "$stage" "用例文件没写 # expect-exit:，判不了它该红还是该绿" "" 0 0
        continue
      fi
      register_case "$name" "$case_label" nested "$stage" "$case_file" "$want_exit" "$stage_forced" "$stage_serial"
    done < <(find "$(dirname "$stage")" -maxdepth 1 -name '*.case.sh' | sort)
    continue
  fi

  # 旧形态：fixtures/<阶段文件名>/{red,green,其余按名字}/，带 expect 的样本目录都跑——只认 red / green 的话，
  # red、green 之外的样本看着像验过了，其实一次都没跑到。
  sample_kinds=(red green)
  while IFS= read -r extra_kind; do
    [[ "$extra_kind" == red || "$extra_kind" == green ]] || sample_kinds+=("$extra_kind")
  done < <(find "$fixtures_directory/$fixture_name" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
  for kind in "${sample_kinds[@]}"; do
    sample_directory="$fixtures_directory/$fixture_name/$kind"
    [[ -d "$sample_directory" ]] || continue
    if [[ ! -f "$sample_directory/expect" ]]; then
      register_case "$name" "$kind" unjudgeable "$stage" "样本目录里没有 expect，判不了它该红还是该绿" "" 0 0
      continue
    fi
    want_exit="$(sed -n 's/^exit=//p' "$sample_directory/expect" | head -1)"
    if [[ ! "$want_exit" =~ ^[0-9]+$ ]]; then
      register_case "$name" "$kind" unjudgeable "$stage" "expect 里没有 exit=<退出码>（或写的不是数），判不了它该红还是该绿" "" 0 0
      continue
    fi
    register_case "$name" "$kind" flat "$stage" "$sample_directory" "$want_exit" "$stage_forced" "$stage_serial"
  done
done

# ── 第二步：跑。每条用例把结果写进结果目录里它自己的那一格：state（done / setup-failed）、exit、output ──
results_directory="$(mktemp -d)"
trap 'rm -rf "${results_directory:?}"' EXIT

run_case() { # run_case <格号>：在自己的临时工作目录里建场景、起阶段；不往 stdout 写
  local case_index="$1"
  local result_directory="$results_directory/$case_index" stage="${CASE_STAGES[$case_index]}" source_path="${CASE_SOURCES[$case_index]}"
  local work_directory actual_exit=0 force_option=()
  [[ "${CASE_FORCED[$case_index]}" == 1 ]] && force_option=(--force)
  mkdir -p "$result_directory"
  work_directory="$(mktemp -d)" || return 0
  # 清掉 GATE_BASE / GATE_STAGED_FROM / GATE_DIFF_BASE：gate.sh 导出的是真仓的 diff 基准，
  # 漏进用例就是临时仓里不存在的提交（实测：--staged 下一对红绿用例一起判错）。
  if [[ "${CASE_KINDS[$case_index]}" == nested ]]; then
    if ! ( cd "$work_directory" && env -u GATE_BASE -u GATE_STAGED_FROM -u GATE_DIFF_BASE bash "$source_path" >/dev/null 2>&1 ); then
      rm -rf "${work_directory:?}"; echo setup-failed > "$result_directory/state"; return 0
    fi
  else
    cp -dR --preserve=timestamps,links "$source_path/." "$work_directory/"   # 不保留权限：样本在 NFS 共享树上时，保留权限那一步在挂载它的另一台上退非 0（Operation not supported）
    if [[ -f "$work_directory/setup.sh" ]]; then
      if ! ( cd "$work_directory" && env -u GATE_BASE -u GATE_STAGED_FROM -u GATE_DIFF_BASE bash setup.sh >/dev/null 2>&1 ); then
        rm -rf "${work_directory:?}"; echo setup-failed > "$result_directory/state"; return 0
      fi
    fi
  fi
  # 退出码在 `|| actual_exit=$?` 里取：lib.sh 带进来的 set -e 会在用例判红那一行退出整个子 shell。
  ( cd "$work_directory" && env -u GATE_BASE -u GATE_STAGED_FROM -u GATE_DIFF_BASE bash "$stage" "$work_directory" ${force_option[@]+"${force_option[@]}"} ) > "$result_directory/output" 2>&1 || actual_exit=$?
  rm -rf "${work_directory:?}"
  echo "$actual_exit" > "$result_directory/exit"
  echo done > "$result_directory/state"
}

dispatched_case_count=0; parallel_case_indexes=(); serial_case_indexes=()
for ((case_index = 0; case_index < ${#CASE_KINDS[@]}; case_index++)); do
  [[ "${CASE_KINDS[$case_index]}" == unjudgeable ]] && continue
  dispatched_case_count=$((dispatched_case_count + 1))
  if [[ "${CASE_SERIAL[$case_index]}" == 1 ]]; then serial_case_indexes+=("$case_index"); else parallel_case_indexes+=("$case_index"); fi
done

# 并行的那一批：同时在跑的不超过并行度；结果不从 wait 取，各在自己那一格里。
running_process_ids=(); started_process_ids=()
for case_index in ${parallel_case_indexes[@]+"${parallel_case_indexes[@]}"}; do
  while ((${#running_process_ids[@]} >= case_parallelism)); do
    wait -n "${running_process_ids[@]}" || true
    still_running_process_ids=()
    for running_process_id in "${running_process_ids[@]}"; do
      if kill -0 "$running_process_id" 2>/dev/null; then still_running_process_ids+=("$running_process_id"); fi
    done
    running_process_ids=(${still_running_process_ids[@]+"${still_running_process_ids[@]}"})
  done
  run_case "$case_index" &
  running_process_ids+=("$!"); started_process_ids+=("$!")
done
for started_process_id in ${started_process_ids[@]+"${started_process_ids[@]}"}; do
  wait "$started_process_id" || true
done
# 声明串行的：并行那一批都退出了才喂，一条一条来。
for case_index in ${serial_case_indexes[@]+"${serial_case_indexes[@]}"}; do
  run_case "$case_index"
done
if [[ "${STAGE_SELFTEST_BREAK:-}" == lose-one-result && ${#parallel_case_indexes[@]} -gt 0 ]]; then
  rm -rf "${results_directory:?}/${parallel_case_indexes[0]}"
fi

# ── 第三步：按登记次序回读、逐条判 ──
collected_case_count=0; uncollected_case_labels=()
for ((case_index = 0; case_index < ${#CASE_KINDS[@]}; case_index++)); do
  name="${CASE_STAGE_NAMES[$case_index]}"; case_label="${CASE_LABELS[$case_index]}"
  if [[ "${CASE_KINDS[$case_index]}" == unjudgeable ]]; then
    say "  ✗ $(printf '%-28s %-16s' "$name" "$case_label") ${CASE_SOURCES[$case_index]}"   # gate-lint:detail
    wrong_case_count=$((wrong_case_count + 1)); continue
  fi
  result_directory="$results_directory/$case_index"
  case_state=""; [[ -f "$result_directory/state" ]] && case_state="$(< "$result_directory/state")"
  if [[ "$case_state" == setup-failed ]]; then
    collected_case_count=$((collected_case_count + 1))
    if [[ "${CASE_KINDS[$case_index]}" == nested ]]; then
      say "  ✗ $(printf '%-28s %-16s' "$name" "$case_label") 用例的建场景正文没跑成"   # gate-lint:detail
    else
      say "  ✗ $(printf '%-28s %-16s' "$name" "$case_label") setup.sh 没跑成"   # gate-lint:detail
    fi
    wrong_case_count=$((wrong_case_count + 1)); continue
  fi
  if [[ "$case_state" != done || ! -f "$result_directory/exit" || ! -f "$result_directory/output" ]]; then
    uncollected_case_labels+=("$name/$case_label"); continue
  fi
  collected_case_count=$((collected_case_count + 1))
  if [[ "${CASE_KINDS[$case_index]}" == nested ]]; then
    mapfile -t want_list < <(sed -n 's/^#[[:space:]]*expect-want:[[:space:]]*//p' "${CASE_SOURCES[$case_index]}")
  else
    mapfile -t want_list < <(sed -n 's/^want=//p' "${CASE_SOURCES[$case_index]}/expect")
  fi
  judge_case "$name" "$case_label" "${CASE_WANT_EXITS[$case_index]}" "$(< "$result_directory/exit")" "$(< "$result_directory/output")" ${want_list[@]+"${want_list[@]}"}
done
if ((collected_case_count != dispatched_case_count)); then
  bad "派出去 $dispatched_case_count 条用例，只收回 $collected_case_count 条；没收回的：${uncollected_case_labels[*]-}"
  howto "没收回的用例没写下结果（喂它的进程被杀、临时目录写满、结果目录被别的进程删了）。先单喂它看现场：" \
        "bash scripts/stage-selftest.sh $gate_directory --item <阶段名> --jobs 1；这一趟整道不算数。"
  exit 1
fi
parallelism_note="并行度 $case_parallelism"
if ((${#serial_stage_names[@]})); then parallelism_note+="，声明串行的阶段 ${#serial_stage_names[@]} 道（${serial_stage_names[*]}）一条一条喂"; fi

if ((${#stages_without_cases[@]})); then
  for stage_without_samples in "${stages_without_cases[@]}"; do
    report_not_run "$stage_without_samples 没有判别力用例，它会不会红没有验过（新形态配同目录下的 *.case.sh，旧形态配 fixtures/$stage_without_samples.sh/{red,green}/）"
  done
  say "     一条永远不红的检查与没有这条检查，在门禁输出里长得一模一样：给它配用例，或者把这笔欠账记进项目的欠检查清单。"
fi
if ((wrong_case_count)); then
  bad "$wrong_case_count 个用例判错（判对 $correct_case_count 个，$((${#stages_without_cases[@]})) 个阶段没有用例）"   # gate-lint:summary
  howto "上面每一条写着它错在哪：退出码不对，或者输出里找不到 want / expect-want。" \
        "用例该改就改，检查坏了就改那个阶段——别两边一起改到自洽为止。"
  exit 1
fi
if ((correct_case_count == 0)); then
  warn "没有一个阶段配了用例，一个用例都没判，本阶段无对象可判（这不是通过）"
  exit 77
fi
if ((${#requested_stages[@]})); then
  ok "点名的 ${#requested_stages[@]} 道阶段判得都对（$correct_case_count 个用例）：${requested_stages[*]}；没点名的这一趟不喂；$parallelism_note"
  exit 0
fi
ok "有用例的阶段判得都对（$correct_case_count 个用例），$((${#stages_without_cases[@]})) 个阶段仍未自证；$parallelism_note"
