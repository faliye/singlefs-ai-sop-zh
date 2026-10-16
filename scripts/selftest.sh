#!/usr/bin/env bash
# admission: inputs-changed ./ ../I18N ../install.sh ../VERSION ../templates ../agents ../skills tool:cargo tool:rustc tool:cargo-clippy tool:rustfmt tool:git tool:python3 tool:gawk tool:bash
# run-condition: command git python3 gawk
# 门禁自己的测试：拿一组「本该红」和「本该绿」的样本喂给各个门禁脚本，看它判得对不对。
#
# 每个门禁脚本都要有样本或脚本化用例，包括 gate.sh 自己（整道门禁唯一的判决点）。
# 两类盲区都要盯：该红不红（删掉一条检查，违规被放行）；该绿变红（删掉一条豁免，正常写法被误拒——门禁一旦开始误拒，人就会绕过它）。
# 所以每个脚本既要有红样本，也要有踩在豁免边界上的绿样本（注释里的 bad、历史节里的「曾经 X」、heredoc 里的赋值、local 同名变量…）。
# 等价变异不算盲区、不补样本（rules/test-discipline.md）：shell-lint 赋值循环里的 local/declare 跳过（`local_names[]` 预扫已经收了那些名字）、
# show-me-test 的 `test_files` 正则不要求 .rs（内容级检查兜住）、i18n-sync 的「缺 SOURCE-MANIFEST」检查（下游的清单比对兜住）。
#
# 两类用例：
#   1. 样本目录  scripts/fixtures/<脚本名>/<样本名>/：
#      喂进去的内容 + expect（exit=0|1，红样本再加至少一条 want=<输出里必须出现的片段>）
#   2. 脚本化用例（要临时 git 仓才能摆出来的场景）：在本文件里现搭现跑
#
# want 必须指着那条检查自己的消息，不能是几条检查共用的片段：只比退出码、或 want 写成共用片段，被测的那条检查删掉了也照样全绿。
# 一个样本触发多类违规时，每一类都要有自己的 want；宁可多写几个单一职责的样本。
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight "${BASH_SOURCE[0]}" "$@"; set -- ${PREFLIGHT_ARGUMENTS[@]+"${PREFLIGHT_ARGUMENTS[@]}"}

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fixtures_directory="$SCRIPTS/fixtures"
temporary_directory="$(mktemp -d)"; trap 'rm -rf "$temporary_directory"' EXIT
# 样本仓不受用户全局 git 配置影响：`commit.gpgsign=true` 之类会让第一个样本仓就建不起来，set -e 把整个自证带走，
# 打出来是「判错 0 条」加一行 git 的报错，看着不像自证失败。
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

passed_case_count=0; failed_case_count=0; case_count=0

# ── 断言器：退出码 + 输出片段 ───────────────────────────
judge() { # judge <名> <期望exit> <实际exit> <输出文件> [want片段...]
  case_count=$((case_count+1))
  local case_name="$1" expected_exit_code="$2" actual_exit_code="$3" output_file="$4"; shift 4
  local is_case_passed=1
  if [[ "$actual_exit_code" != "$expected_exit_code" ]]; then
    bad "$case_name  退出码 $actual_exit_code，应为 $expected_exit_code"
    howto "看这个用例的完整输出： cat $output_file" \
          "样本本身该改就改预期，检查坏了就改检查——别两边一起改到自洽为止。"
    is_case_passed=0
  else
    local wanted_fragment
    for wanted_fragment in "$@"; do
      [[ -z "$wanted_fragment" ]] && continue
      grep -qF -- "$wanted_fragment" "$output_file" || {
        bad "$case_name  退出码对，但输出里没有「$wanted_fragment」"
        howto "退出码对不等于拦对了原因——可能是因为别的检查红的。" \
              "看输出： cat $output_file"
        is_case_passed=0; }
    done
  fi
  if [[ $is_case_passed -eq 1 ]]; then
    passed_case_count=$((passed_case_count+1)); [[ -n "${SELFTEST_VERBOSE:-}" ]] && ok "$case_name"
  else
    failed_case_count=$((failed_case_count+1))
  fi
  return 0
}

# 三种跑法起子进程时都清掉 GATE_BASE、GATE_STAGED_FROM、GATE_DIFF_BASE 与 GATE_STAGED_TREE：gate.sh 把本脚本当一个阶段跑，前三样都在环境里，
# 漏给嵌套跑的 gate.sh / show-me-test.sh / history-ordinal.sh，它们就按外面那个项目的基准与兄弟目录判。对应的用例在 gate 那一节。
# 要给样本一个基准的用例，自己在命令里写 env GATE_DIFF_BASE=…（env 在清完之后才设它）。
# ── 样本目录跑法：expect 文件驱动 ───────────────────────
run_fixture() { # run_fixture <标签> <样本目录> <命令...>（命令自行引用样本目录）
  local label="$1" fixture_directory="$2"; shift 2
  [[ -f "$fixture_directory/expect" ]] || { case_count=$((case_count+1)); failed_case_count=$((failed_case_count+1))
    bad "$label 缺 expect 文件"
    howto "写一行 exit=0 或 exit=1，红的样本再加至少一条 want=<输出片段>。"
    return 0; }
  local expected_exit_code; expected_exit_code="$(sed -n 's/^exit=//p' "$fixture_directory/expect")"
  local wanted_fragments=(); local wanted_fragment
  while IFS= read -r wanted_fragment; do wanted_fragments+=("$wanted_fragment"); done < <(sed -n 's/^want=//p' "$fixture_directory/expect")
  local output_file="$temporary_directory/$(printf '%s' "$label" | tr '/ ' '__').out"
  local exit_code=0
  # 超时保护：挂死的检查在门禁输出里既不红也不绿，只是永远不回来，比红的门禁危险。
  set +e; timeout "${SELFTEST_TIMEOUT:-60}" env -u GATE_BASE -u GATE_STAGED_FROM -u GATE_DIFF_BASE -u GATE_STAGED_TREE "$@" > "$output_file" 2>&1; exit_code=$?; set -e
  [[ $exit_code == 124 ]] && say "        （超时 ${SELFTEST_TIMEOUT:-60}s，按判错记）"
  judge "$label" "$expected_exit_code" "$exit_code" "$output_file" ${wanted_fragments[@]+"${wanted_fragments[@]}"}
}

# ── 样本目录并行跑法：先把一批派出去，再按派活顺序逐个判 ──
# 判定不并行：judge 仍在主 shell 里按派活顺序跑，输出顺序与串行时相同。
# 脚本化用例（run_scripted）还是串行：搭建与判定在正文里交织，并行化要重写整个脚本的结构。
# 退出码一律走 .exit-code 文件：不带参数的 wait 恒返回 0，后台体是子 shell、赋值传不回来，两样都会把红样本变成绿的
# （rules/command-safety.md「并行不许把失败吃掉」）。
SELFTEST_JOBS="${SELFTEST_JOBS:-$(nproc 2>/dev/null || echo 4)}"
spawned_labels=(); spawned_fixture_directories=(); in_flight_job_count=0
fixture_output_path() { printf '%s/%s.out' "$temporary_directory" "$(printf '%s' "$1" | tr '/ ' '__')"; }

spawn_fixture() { # spawn_fixture <标签> <样本目录> <命令...>（命令自行引用样本目录）
  local label="$1" fixture_directory="$2"; shift 2
  spawned_labels+=("$label")
  # 缺 expect 的不派活，占一个空位，collect 时按原来那句话报——与串行时判得一样
  if [[ ! -f "$fixture_directory/expect" ]]; then spawned_fixture_directories+=(""); return 0; fi
  spawned_fixture_directories+=("$fixture_directory")
  local output_file; output_file="$(fixture_output_path "$label")"
  rm -f "$output_file" "$output_file.exit-code"
  # 退出码在 if 里取：lib.sh 开着 set -e，写成「里层; echo $? > 文件」的话，样本一判红子 shell 就在那一行退出，.exit-code 一个字都不写。
  ( fixture_exit_code=0
    if timeout "${SELFTEST_TIMEOUT:-60}" env -u GATE_BASE -u GATE_STAGED_FROM -u GATE_DIFF_BASE -u GATE_STAGED_TREE "$@" > "$output_file" 2>&1
    then fixture_exit_code=0; else fixture_exit_code=$?; fi
    echo "$fixture_exit_code" > "$output_file.exit-code" ) &
  in_flight_job_count=$((in_flight_job_count+1))
  # 在手的作业到上限就先收一个。`wait -n` 拿回来的是样本自己的退出码，红样本本来就非 0，
  # 不加 `|| true` 的话 set -e 会在第一个红样本上把整个自证带走。
  while [[ $in_flight_job_count -ge $SELFTEST_JOBS ]]; do wait -n || true; in_flight_job_count=$((in_flight_job_count-1)); done
}

collect_fixtures() { # 等这一批跑完，按派活顺序逐个判
  while [[ $in_flight_job_count -gt 0 ]]; do wait -n || true; in_flight_job_count=$((in_flight_job_count-1)); done
  local spawn_index label fixture_directory output_file exit_code expected_exit_code wanted_fragment; local wanted_fragments
  for spawn_index in "${!spawned_labels[@]}"; do
    label="${spawned_labels[$spawn_index]}"; fixture_directory="${spawned_fixture_directories[$spawn_index]}"
    if [[ -z "$fixture_directory" ]]; then
      case_count=$((case_count+1)); failed_case_count=$((failed_case_count+1))
      bad "$label 缺 expect 文件"
      howto "写一行 exit=0 或 exit=1，红的样本再加至少一条 want=<输出片段>。"
      continue
    fi
    output_file="$(fixture_output_path "$label")"
    # 派出去多少项，就要收回来多少项：一项没跑完时它的 .exit-code 根本不存在，而循环少转一圈是不报错的，末尾照样报绿。
    if [[ ! -f "$output_file.exit-code" ]]; then
      case_count=$((case_count+1)); failed_case_count=$((failed_case_count+1))
      bad "$label 派出去了，却没有退出码文件"
      howto "这一项的后台作业没跑完，或者被杀了——自证不许把它当通过。" \
            "看它的输出： cat $output_file"
      continue
    fi
    exit_code="$(cat "$output_file.exit-code")"
    [[ $exit_code == 124 ]] && say "        （超时 ${SELFTEST_TIMEOUT:-60}s，按判错记）"
    expected_exit_code="$(sed -n 's/^exit=//p' "$fixture_directory/expect")"
    wanted_fragments=()
    while IFS= read -r wanted_fragment; do wanted_fragments+=("$wanted_fragment"); done < <(sed -n 's/^want=//p' "$fixture_directory/expect")
    judge "$label" "$expected_exit_code" "$exit_code" "$output_file" ${wanted_fragments[@]+"${wanted_fragments[@]}"}
  done
  spawned_labels=(); spawned_fixture_directories=()
}

# ── 脚本化用例跑法 ──────────────────────────────────────
run_scripted() { # run_scripted <名> <期望exit> <want...> -- <命令...>
  local case_name="$1" expected_exit_code="$2"; shift 2
  local wanted_fragments=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do wanted_fragments+=("$1"); shift; done
  shift
  local output_file="$temporary_directory/$(printf '%s' "$case_name" | tr '/ ' '__').out"
  local exit_code=0
  set +e; timeout "${SELFTEST_TIMEOUT:-60}" env -u GATE_BASE -u GATE_STAGED_FROM -u GATE_DIFF_BASE -u GATE_STAGED_TREE "$@" > "$output_file" 2>&1; exit_code=$?; set -e
  [[ $exit_code == 124 ]] && say "        （超时 ${SELFTEST_TIMEOUT:-60}s，按判错记）"
  judge "$case_name" "$expected_exit_code" "$exit_code" "$output_file" ${wanted_fragments[@]+"${wanted_fragments[@]}"}
}

# ════ doc-lint ═══════════════════════════════════════════
head1 "门禁自证：doc-lint 的判别力"
[[ -d "$fixtures_directory/doc-lint" ]] || { bad "缺样本目录 $fixtures_directory/doc-lint"
  howto "样本要随仓走。没有样本，下一个改 doc-lint.sh 的人无从复跑。"; exit 1; }
# 样本一律按 zh 判：样本是中文写的，而 scripts/ 会逐字节复制进每个语言仓，不钉住语言的话，
# en / ja 仓里这批样本按英日的判据一起假红。语言是样本的属性，不是仓的属性。
for fixture_directory in "$fixtures_directory"/doc-lint/*/; do
  spawn_fixture "doc-lint/$(basename "$fixture_directory")" "$fixture_directory" env DOC_LINT_LANG=zh bash "$SCRIPTS/doc-lint.sh" "$fixture_directory"
done
# 日文的位置指代与自称：doc-lint-ja/ 下的样本按日文判
[[ -d "$fixtures_directory/doc-lint-ja" ]] || { bad "缺样本目录 $fixtures_directory/doc-lint-ja"
  howto "样本要随仓走。没有这一套样本，doc-lint 在日文上的位置指代与自称没人验。"; exit 1; }
for fixture_directory in "$fixtures_directory"/doc-lint-ja/*/; do
  spawn_fixture "doc-lint-ja/$(basename "$fixture_directory")" "$fixture_directory" env DOC_LINT_LANG=ja bash "$SCRIPTS/doc-lint.sh" "$fixture_directory"
done
collect_fixtures

# DOC_LINT_LANG 这个口子必须自报：少了那句 warn，谁都能拿它换掉判据而不留痕迹（rules/show-me-test.md：门禁不许假装通过）。
run_scripted "doc-lint/语言被覆盖时要自报" 0 "语言由 DOC_LINT_LANG 指定为" -- \
  env DOC_LINT_LANG=zh bash "$SCRIPTS/doc-lint.sh" "$fixtures_directory/doc-lint/good"

# 编号引用没带简称的命中很多时，只列前 3 条的那一段不许让整个脚本中途退出（输出超过管道缓冲，截断的一端会让前段吃 SIGPIPE）
doc_lint_project="$temporary_directory/doc-lint-many-bare"; mkdir -p "$doc_lint_project/kb"
{ printf '# 决策\n\n## D1 数据可移动性 —— 已定\n\n'
  for bare_citation_line in $(seq 1 3000); do printf '第 %s 行裸提 D1，再提一次 D1，句子写长一点让这一行的命中记录占满管道缓冲。\n' "$bare_citation_line"; done
  printf '\n## 历史版本\n\n### 2026-08-29\n- 建档。\n'; } > "$doc_lint_project/kb/decisions.md"
run_scripted "doc-lint/没带简称的命中很多时照样跑完" 1 "处编号引用没带简称" "文档铁律检查失败" -- \
  env DOC_LINT_LANG=zh bash "$SCRIPTS/doc-lint.sh" "$doc_lint_project"

# 登记了自定义 kb 目录（rules/kb-discipline.md）：不变量编号要有定义、编号只许一处登记位、引用带简称、反复出现的编号要登记这四条，与历史节判据，都认登记的目录，不是只认路径里带 kb 的
doc_lint_project="$temporary_directory/doc-lint-registered-kb-directory"; mkdir -p "$doc_lint_project/crates/checker/invariants" "$doc_lint_project/.claude"
printf '# 不变量\n\n| 编号 | 说明 |\n|---|---|\n| I-1.1 | 块对齐 |\n\n## 历史版本\n\n### 2026-09-01\n- 建档。\n' \
  > "$doc_lint_project/crates/checker/invariants/01-foo.md"
printf '# 另一份\n\n引用 I-1.1，还引用了不存在的 I-9.9。\n\n## 历史版本\n\n### 2026-09-01\n- 建档。\n' \
  > "$doc_lint_project/crates/checker/invariants/02-bar.md"
printf 'crates/checker/invariants  # 不变量清单挪到 checker 旁边\n' > "$doc_lint_project/.claude/kb-directories"
run_scripted "doc-lint/登记了自定义 kb 目录就在那里判引用" 1 "引用了没有定义的不变量编号 I-9.9" -- \
  env DOC_LINT_LANG=zh bash "$SCRIPTS/doc-lint.sh" "$doc_lint_project"
printf 'nope  # 登记的目录不存在\n' > "$doc_lint_project/.claude/kb-directories"
run_scripted "doc-lint/kb 目录登记指到不存在的路径判红" 1 "登记的目录不存在：nope" -- \
  env DOC_LINT_LANG=zh bash "$SCRIPTS/doc-lint.sh" "$doc_lint_project"
printf 'crates/checker/invariants\n' > "$doc_lint_project/.claude/kb-directories"
run_scripted "doc-lint/kb 目录登记没写理由判红" 1 "没写理由，或路径是空的" -- \
  env DOC_LINT_LANG=zh bash "$SCRIPTS/doc-lint.sh" "$doc_lint_project"

# 补简称的工具：自证过得了，弄坏开关打开时自证必须红（证明它分得出登记位那一行动没动过）
run_scripted "doc-lint-fix-names/自证通过" 0 "自证通过（查了" -- \
  python3 "$SCRIPTS/doc-lint-fix-names.py" --selftest
run_scripted "doc-lint-fix-names/改动登记位那一行时自证判红" 1 "登记标题那一行不动" -- \
  env DOC_LINT_FIX_NAMES_BREAK=touch-registry python3 "$SCRIPTS/doc-lint-fix-names.py" --selftest
run_scripted "doc-lint-fix-names/不认 not-numbers 时自证判红" 1 "not-numbers 声明过的 Z3" -- \
  env DOC_LINT_FIX_NAMES_BREAK=ignore-not-numbers python3 "$SCRIPTS/doc-lint-fix-names.py" --selftest
run_scripted "doc-lint-fix-names/不认页内定义时自证判红" 1 "页内表格首列定义了 C120" -- \
  env DOC_LINT_FIX_NAMES_BREAK=ignore-local python3 "$SCRIPTS/doc-lint-fix-names.py" --selftest
run_scripted "doc-lint-fix-names/不读 kb-directories 时自证判红" 1 "登记在 .claude/kb-directories 里的目录" -- \
  env DOC_LINT_FIX_NAMES_BREAK=ignore-kb-directories python3 "$SCRIPTS/doc-lint-fix-names.py" --selftest

# 扫描范围不许随包所在的路径变：同一个样本在包仓里与在项目副本（路径里有 /singlefs-ai-sop/）里要判得一样。
# 这里把脚本拷到一个路径里带 /singlefs-ai-sop/ 的地方再跑同一个样本。
sop_named_package_copy="$temporary_directory/elsewhere/singlefs-ai-sop"; mkdir -p "$sop_named_package_copy/scripts/fixtures/doc-lint"
cp "$SCRIPTS/lib.sh" "$SCRIPTS/preflight.py" "$SCRIPTS/preflight.sh" "$SCRIPTS/proc.py" "$SCRIPTS/doc-lint.sh" "$sop_named_package_copy/scripts/"; cp "$SCRIPTS/../I18N" "$sop_named_package_copy/I18N"
cp -r "$fixtures_directory/doc-lint/projok" "$sop_named_package_copy/scripts/fixtures/doc-lint/"
run_scripted "doc-lint/扫描范围不随包所在路径变" 0 "文档铁律检查通过（检查 1，跳过 0" -- \
  env DOC_LINT_LANG=zh bash "$sop_named_package_copy/scripts/doc-lint.sh" "$sop_named_package_copy/scripts/fixtures/doc-lint/projok"

# 判据编不过要当场红：圈码写成区间 `①-⑳` 时 grep 报 Invalid collation character，而那条 grep 外面套着 `|| true`，
# 整条检查对每份 kb 静默判绿。这里拷一份脚本、把圈码那一格改成区间写法，要求它报「编不过」，而不是「检查通过」。
broken_criterion_package="$temporary_directory/broken-criterion-package"; mkdir -p "$broken_criterion_package/scripts"
cp "$SCRIPTS/lib.sh" "$SCRIPTS/preflight.py" "$SCRIPTS/preflight.sh" "$SCRIPTS/proc.py" "$SCRIPTS/doc-lint.sh" "$broken_criterion_package/scripts/"; cp "$SCRIPTS/../I18N" "$broken_criterion_package/I18N"
run_scripted "doc-lint/判据编不过要当场红" 1 "位置指代的判据 grep 编不过" -- \
  bash -c 'sed -i "s/①②③④⑤⑥⑦⑧⑨⑩⑪⑫⑬⑭⑮⑯⑰⑱⑲⑳/①-⑳/" "$1/scripts/doc-lint.sh" && grep -q "①-⑳" "$1/scripts/doc-lint.sh" || { echo "没改到圈码那一格，这条用例什么也没测"; exit 3; }
           env DOC_LINT_LANG=zh bash "$1/scripts/doc-lint.sh" "$2"' broken_criterion_check "$broken_criterion_package" "$fixtures_directory/doc-lint/dirref"

# ════ gate-lint ══════════════════════════════════════════
head1 "门禁自证：gate-lint 的判别力"
for fixture_directory in "$fixtures_directory"/gate-lint/*/; do
  [[ -d "$fixture_directory" ]] || continue
  spawn_fixture "gate-lint/$(basename "$fixture_directory")" "$fixture_directory" \
    env GATE_LINT_DIR="$fixture_directory" bash "$SCRIPTS/gate-lint.sh"
done
collect_fixtures

# 默认扫描范围（不设 GATE_LINT_DIR / SHELL_LINT_DIR 时扫哪里）样本目录法测不到：环境变量一设就把默认值盖掉了。
# 所以现搭一个包，在包根放一份该被拦的脚本，不带环境变量地跑，钉住「install.sh 在包根，也要扫」。
head1 "门禁自证：默认扫描范围"
# 该被拦的样本内容放到样本文件里，不许写成本脚本内的字符串字面量：gate-lint / shell-lint 扫的是 *.sh 的内容，
# 写在这里会被当成本脚本自己的拒绝，门禁自己红。
make_scan_package() { # make_scan_package <目录> <要拷进包根的样本文件>
  mkdir -p "$1/scripts"
  cp "$SCRIPTS/lib.sh" "$SCRIPTS/preflight.py" "$SCRIPTS/preflight.sh" "$SCRIPTS/proc.py" "$SCRIPTS/gate-lint.sh" "$SCRIPTS/shell-lint.sh" "$1/scripts/"
  cp "$fixtures_directory/scan/clean.sh" "$1/scripts/clean.sh"
  cp "$2" "$1/rootscript.sh"
}
scan_package="$temporary_directory/scan-gate-lint"; make_scan_package "$scan_package" "$fixtures_directory/scan/root-nakeddie.sh"
run_scripted "gate-lint/默认扫到包根" 1 "rootscript.sh:3" -- bash "$scan_package/scripts/gate-lint.sh"

scan_package="$temporary_directory/scan-shell-lint"; make_scan_package "$scan_package" "$fixtures_directory/scan/root-pkill.sh"
run_scripted "shell-lint/默认扫到包根" 1 "rootscript.sh:4" -- bash "$scan_package/scripts/shell-lint.sh"

# `… | grep -q` 在管道末端：grep 找到就退出，上游拿 SIGPIPE，pipefail 下整条管道退 141、条件当假。
# 文件小的时候一切正常，大过管道缓冲（64 KiB）就静默不判了。
gate_lint_target_directory="$temporary_directory/gate-lint-big-file"; mkdir -p "$gate_lint_target_directory"
{ printf '#!/usr/bin/env bash\nfor f in $(find . -name "*.md"); do\n  echo "$f"\ndone\n'
  printf 'ok "%s"\n' 检查通过
  awk 'BEGIN { for (filler_line_number = 0; filler_line_number < 9000; filler_line_number++) print "# 填充行 " filler_line_number " 用来把文件撑过管道缓冲区" }'
} > "$gate_lint_target_directory/x.sh"
run_scripted "gate-lint/大文件也判得出没报计数" 1 "成功摘要没报出检查了多少项" -- \
  env GATE_LINT_DIR="$gate_lint_target_directory" bash "$SCRIPTS/gate-lint.sh"

# 项目里单跑这两个 lint（README 就是这么教的）时，装进项目的副本不许被扫：
# 副本带着一整套故意写坏的样本，扫了就当成项目自己的违规报出来。
lint_copy_scenario_directory="$temporary_directory/lint-copy"; installed_package_copy="$lint_copy_scenario_directory/project/.claude/f"
mkdir -p "$installed_package_copy/scripts/fixtures/gate-lint/bad" "$installed_package_copy/scripts/fixtures/shell-lint/bad" "$lint_copy_scenario_directory/project/.claude/gate.d"
cp "$SCRIPTS/lib.sh" "$SCRIPTS/preflight.py" "$SCRIPTS/preflight.sh" "$SCRIPTS/proc.py" "$SCRIPTS/gate-lint.sh" "$SCRIPTS/shell-lint.sh" "$installed_package_copy/scripts/"
printf 'family=f\nthis=zh\nreference=zh\ndefault=zh\nlanguages=zh\n' > "$installed_package_copy/I18N"
cp "$fixtures_directory/scan/root-nakeddie.sh" "$installed_package_copy/scripts/fixtures/gate-lint/bad/evil.sh"
cp "$fixtures_directory/scan/root-pkill.sh"    "$installed_package_copy/scripts/fixtures/shell-lint/bad/evil.sh"
cp "$fixtures_directory/scan/clean.sh" "$lint_copy_scenario_directory/project/.claude/gate.d/10-ok.sh"
run_scripted "gate-lint/项目里单跑不报副本里的样本" 0 "门禁自检通过" -- bash "$installed_package_copy/scripts/gate-lint.sh" "$lint_copy_scenario_directory/project"
run_scripted "shell-lint/项目里单跑不报副本里的样本" 0 "shell 纪律检查通过" -- bash "$installed_package_copy/scripts/shell-lint.sh" "$lint_copy_scenario_directory/project"

# ════ shell-lint ═════════════════════════════════════════
head1 "门禁自证：shell-lint 的判别力"
for fixture_directory in "$fixtures_directory"/shell-lint/*/; do
  [[ -d "$fixture_directory" ]] || continue
  spawn_fixture "shell-lint/$(basename "$fixture_directory")" "$fixture_directory" \
    env SHELL_LINT_DIR="$fixture_directory" bash "$SCRIPTS/shell-lint.sh"
done
collect_fixtures

# ════ rules-lint ═════════════════════════════════════════
# 样本目录本身当项目根喂进去：里面有 rules/ 和可选的 .claude/rules-lint-exclude。每个红样本只犯一处。
head1 "门禁自证：rules-lint 的判别力"
# 样本的语言是样本的属性：rules-lint/ 下的按中文判，rules-lint-en/、rules-lint-ja/ 下的按英文、日文判，
# 用 RULES_LINT_LANG 钉住。三套在每个语言仓里都跑。
for rules_lint_fixture_language in zh en ja; do
  rules_lint_fixture_family="rules-lint"
  if [[ "$rules_lint_fixture_language" != zh ]]; then rules_lint_fixture_family="rules-lint-$rules_lint_fixture_language"; fi
  [[ -d "$fixtures_directory/$rules_lint_fixture_family" ]] || { bad "缺样本目录 $fixtures_directory/$rules_lint_fixture_family"
    howto "样本要随仓走。没有这一套样本，rules-lint 在 $rules_lint_fixture_language 上的判据没人验。"; exit 1; }
  for fixture_directory in "$fixtures_directory/$rules_lint_fixture_family"/*/; do
    [[ -d "$fixture_directory" ]] || continue
    spawn_fixture "$rules_lint_fixture_family/$(basename "$fixture_directory")" "$fixture_directory" \
      env RULES_LINT_LANG="$rules_lint_fixture_language" RULES_LINT_DIR="$fixture_directory/rules" RULES_LINT_FILES="CLAUDE.md" bash "$SCRIPTS/rules-lint.sh" "$fixture_directory"
  done
done
collect_fixtures
# RULES_LINT_LANG 这个口子同样必须自报（同 DOC_LINT_LANG）
run_scripted "rules-lint/语言被覆盖时要自报" 0 "语言由 RULES_LINT_LANG 指定为 en" -- \
  env RULES_LINT_LANG=en RULES_LINT_DIR="$fixtures_directory/rules-lint-en/ok/rules" bash "$SCRIPTS/rules-lint.sh" "$fixtures_directory/rules-lint-en/ok"

# ════ pattern-process-guard（会话钩子）═══════════════════
# 样本是钩子的 JSON 输入（input.json），不是 .sh：shell-lint / gate-lint 不扫它们。
# 红的 want 带「第一处：」那一行，钉住是哪一行命中的。
head1 "门禁自证：pattern-process-guard 的判别力"
[[ -d "$fixtures_directory/pattern-process-guard" ]] || { bad "缺样本目录 $fixtures_directory/pattern-process-guard"
  howto "样本要随仓走。没有样本，下一个改 claude-hooks/pattern-process-guard.sh 的人无从复跑。"; exit 1; }
for fixture_directory in "$fixtures_directory"/pattern-process-guard/*/; do
  [[ -d "$fixture_directory" ]] || continue
  spawn_fixture "pattern-process-guard/$(basename "$fixture_directory")" "$fixture_directory" \
    bash -c 'bash "$0" < "$1/input.json"' "$SCRIPTS/claude-hooks/pattern-process-guard.sh" "$fixture_directory"
done
collect_fixtures

# ════ proc.py（按进程号找、等、停）═══════════════════════
# 它是钩子给出的替代写法，自证坏了等于出路是假的。三个破坏开关各关掉一样东西，自证必须判红。
head1 "门禁自证：proc.py 的判别力"
run_scripted "proc/自证通过" 0 "proc.py 自证通过" -- python3 "$SCRIPTS/proc.py" --selftest
run_scripted "proc/PROC_BREAK=ancestors 必须判红" 1 "find 列出了发出这条命令的进程自己" -- \
  env PROC_BREAK=ancestors python3 "$SCRIPTS/proc.py" --selftest
# 这一例故意空等 10 秒（proc.py 自证里外层 subprocess 的超时）：它验的就是「超时逻辑被破坏之后 wait 不返回」，
# 并行治不了它。
run_scripted "proc/PROC_BREAK=timeout 必须判红" 1 "10 秒没返回" -- \
  env PROC_BREAK=timeout python3 "$SCRIPTS/proc.py" --selftest
run_scripted "proc/PROC_BREAK=stopself 必须判红" 1 "stop 停自己的祖先应当拒绝" -- \
  env PROC_BREAK=stopself python3 "$SCRIPTS/proc.py" --selftest

# ════ 准入与运行条件（rules/preflight-discipline.md）═══════
# 三样各自要会红：preflight-lint 判文件头与开头；preflight.py 现判时拒绝得了、--force 放得过、输入没变拦得住；
# gate.sh 条件不满足时不起那个阶段。
head1 "门禁自证：准入与运行条件的判别力"
for fixture_directory in "$fixtures_directory"/preflight-lint/*/; do
  spawn_fixture "preflight-lint/$(basename "$fixture_directory")" "$fixture_directory" python3 "$SCRIPTS/preflight-lint.py" "$fixture_directory"
done
collect_fixtures

# 本包自己的默认范围：install.sh、scripts/、scripts/claude-hooks/、scripts/githooks/ 四处都要扫到，排除表指到的每一份都要在。
make_preflight_package() { # make_preflight_package <目录>：只带判条件那几份真脚本的最小包
  mkdir -p "$1/scripts/claude-hooks" "$1/scripts/githooks"
  cp "$SCRIPTS/lib.sh" "$SCRIPTS/preflight.py" "$SCRIPTS/preflight.sh" "$SCRIPTS/proc.py" "$SCRIPTS/preflight-lint.py" \
    "$SCRIPTS/claude-hook-lib.sh" "$SCRIPTS/session-transcript.py" "$SCRIPTS/package-family.py" "$1/scripts/"
  cp "$SCRIPTS/../I18N" "$1/I18N"
}
preflight_package="$temporary_directory/preflight-scope-clean"; make_preflight_package "$preflight_package"
run_scripted "preflight-lint/本包的默认范围全写了就绿" 0 "判了 2 个脚本（脚本 2）" "排除 6 个" -- python3 "$preflight_package/scripts/preflight-lint.py" "$preflight_package"
preflight_package="$temporary_directory/preflight-scope"; make_preflight_package "$preflight_package"
for undeclared_script_path in install.sh scripts/undeclared.sh scripts/claude-hooks/undeclared-hook.sh scripts/githooks/pre-commit; do
  printf '#!/usr/bin/env bash\necho 没写条件\n' > "$preflight_package/$undeclared_script_path"
done
run_scripted "preflight-lint/本包的默认范围四处都扫到" 1 "install.sh:1 文件头没写 admission" "scripts/undeclared.sh:1 文件头没写 admission" \
  "scripts/claude-hooks/undeclared-hook.sh:1 文件头没写 admission" "scripts/githooks/pre-commit:1 文件头没写 admission" \
  -- python3 "$preflight_package/scripts/preflight-lint.py" "$preflight_package"
# 符号链接形式的本地阶段：gate.sh 照样跑它，它指向的那一份没写条件就要红；跳过链接的话，这种阶段不判就过闸
preflight_project="$temporary_directory/preflight-linked-stage"; mkdir -p "$preflight_project/.claude/gate.d" "$preflight_project/.claude/stages"
printf '# 本项目没有实验\n' > "$preflight_project/.claude/preflight-dirs"
printf '#!/usr/bin/env bash\necho 没写条件\n' > "$preflight_project/.claude/stages/probe.sh"; ln -s ../stages/probe.sh "$preflight_project/.claude/gate.d/65-linked.sh"
run_scripted "preflight-lint/符号链接形式的阶段也判" 1 ".claude/gate.d/65-linked.sh:1 文件头没写 admission" -- python3 "$SCRIPTS/preflight-lint.py" "$preflight_project"
preflight_package="$temporary_directory/preflight-scope-excluded"; make_preflight_package "$preflight_package"; rm "$preflight_package/scripts/session-transcript.py"
run_scripted "preflight-lint/排除表指到不存在的要红" 1 "PACKAGE_EXCLUDED 里的 scripts/session-transcript.py 不在判的范围里" \
  -- python3 "$preflight_package/scripts/preflight-lint.py" "$preflight_package"
# 项目登记了自定义门禁目录（rules/sop-first.md「加门禁或钩子之前，先找已有的」的默认路径只是例子）：preflight-lint 要扫那个目录，不是默认的 .claude/gate.d
preflight_project="$temporary_directory/preflight-registered-gate-directory"; mkdir -p "$preflight_project/scripts/gates" "$preflight_project/.claude"
printf '# 本项目没有实验\n' > "$preflight_project/.claude/preflight-dirs"
printf 'scripts/gates  # 工程脚本统一挪进项目仓根 scripts/\n' > "$preflight_project/.claude/gate-directory"
printf '#!/usr/bin/env bash\necho 没写条件\n' > "$preflight_project/scripts/gates/10-demo.sh"
run_scripted "preflight-lint/登记了自定义门禁目录就扫那里" 1 "scripts/gates/10-demo.sh:1 文件头没写 admission" -- python3 "$SCRIPTS/preflight-lint.py" "$preflight_project"
# 登记文件写坏：一行有效路径都没有
preflight_project="$temporary_directory/preflight-gate-directory-malformed"; mkdir -p "$preflight_project/.claude"
printf '# 只有注释，没有路径\n' > "$preflight_project/.claude/gate-directory"
printf '# 本项目没有实验\n' > "$preflight_project/.claude/preflight-dirs"
run_scripted "preflight-lint/门禁目录登记写坏就红" 1 "gate-directory 登记了但一行有效路径都没有" -- python3 "$SCRIPTS/preflight-lint.py" "$preflight_project"

# 副本目录名不叫 singlefs-ai-sop：认副本的三道（preflight-lint、link-targets、number-name-sync）都要从副本自己的 I18N 或目录名取，不写死名字
make_installed_copy() { # make_installed_copy <项目根> <family> [--without-i18n]：在 .claude/<family>/ 下装一份只带这三道与它们依赖的副本
  local copy="$1/.claude/$2"
  mkdir -p "$copy/scripts"
  cp "$SCRIPTS/lib.sh" "$SCRIPTS/preflight.py" "$SCRIPTS/preflight.sh" "$SCRIPTS/proc.py" "$SCRIPTS/package-family.py" \
    "$SCRIPTS/preflight-lint.py" "$SCRIPTS/link-targets.py" "$SCRIPTS/number-name-sync.sh" "$copy/scripts/"
  [[ "${3:-}" == --without-i18n ]] || printf 'family=%s\nthis=zh\nreference=zh\ndefault=zh\nlanguages=zh\n' "$2" > "$copy/I18N"
}
preflight_project="$temporary_directory/preflight-copy-name"; make_installed_copy "$preflight_project" demo-sop --without-i18n; mkdir -p "$preflight_project/.claude/scripts" "$preflight_project/.claude/gate.d"
printf '.claude/scripts  # install.sh 铺的包装\n' > "$preflight_project/.claude/preflight-dirs"
printf '#!/usr/bin/env bash\nexec bash "$(dirname "${BASH_SOURCE[0]}")/../demo-sop/scripts/lib.sh" "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" "$@"\n' > "$preflight_project/.claude/scripts/lib.sh"
printf '#!/usr/bin/env bash\n# admission: always 样本：每次调都有意义\n# run-condition: none 样本：不碰任何环境\nsource "$(dirname "${BASH_SOURCE[0]}")/../demo-sop/scripts/lib.sh"\npreflight "${BASH_SOURCE[0]}" "$@"; set -- ${PREFLIGHT_ARGUMENTS[@]+"${PREFLIGHT_ARGUMENTS[@]}"}\necho 通过\n' > "$preflight_project/.claude/gate.d/10-demo.sh"
run_scripted "preflight-lint/没有 I18N 时按副本的目录名认包装" 0 "只 exec 共享脚本的包装 1 个" -- python3 "$preflight_project/.claude/demo-sop/scripts/preflight-lint.py" "$preflight_project"

# 现判：样本脚本拷进一个临时 git 仓，按次序跑。每一步的前提是上一步留下的指纹，次序不能换。
preflight_runtime_repository="$temporary_directory/preflight-runtime"; mkdir -p "$preflight_runtime_repository/scripts"
cp "$SCRIPTS/lib.sh" "$SCRIPTS/preflight.py" "$SCRIPTS/preflight.sh" "$SCRIPTS/proc.py" "$fixtures_directory"/preflight-runtime/* "$preflight_runtime_repository/scripts/"
printf '第一版输入\n' > "$preflight_runtime_repository/input.txt"; printf 'cd 样本的输入\n' > "$preflight_runtime_repository/input-cd.txt"; git -C "$preflight_runtime_repository" init -q
run_scripted "preflight/输入第一次出现就跑，参数原样交回" 0 "跑了 参数=[甲 乙] 强制=[]" -- bash "$preflight_runtime_repository/scripts/experiment.sh" 甲 乙
run_scripted "preflight/输入没变就拒绝重跑，退出码 78" 78 "以来没变，重跑得不到新信息" "拒绝执行（退出码 78）" \
  -- bash "$preflight_runtime_repository/scripts/experiment.sh" 甲
run_scripted "preflight/--force 照跑、标强制、从参数里摘掉" 0 "跑了 参数=[甲] 强制=[准入 inputs-changed" "不记成「上次成功」" \
  -- bash "$preflight_runtime_repository/scripts/experiment.sh" 甲 --force
run_scripted "preflight/登记的环境变量变了算输入变了" 0 "跑了 参数=[] 强制=[]" -- env SAMPLE_ROUNDS=3 bash "$preflight_runtime_repository/scripts/experiment.sh"
printf '第二版输入\n' > "$preflight_runtime_repository/input.txt"
run_scripted "preflight/运行条件不满足就拒绝" 78 "设了 SAMPLE_BLOCKED 就不许跑" -- env SAMPLE_BLOCKED=1 bash "$preflight_runtime_repository/scripts/experiment.sh"
run_scripted "preflight/强制跑的那一次不记（前半：强制跑）" 0 "强制=[运行 check" -- env SAMPLE_BLOCKED=1 bash "$preflight_runtime_repository/scripts/experiment.sh" --force
run_scripted "preflight/强制跑的那一次不记（后半：照判输入变了）" 0 "跑了 参数=[] 强制=[]" -- bash "$preflight_runtime_repository/scripts/experiment.sh"
printf '第三版输入\n' > "$preflight_runtime_repository/input.txt"
run_scripted "preflight/跑失败的那一次不记（前半：跑失败）" 5 "样本按要求跑失败" -- env SAMPLE_FAIL=1 bash "$preflight_runtime_repository/scripts/experiment.sh"
run_scripted "preflight/跑失败的那一次不记（后半：照判输入变了）" 0 "跑了 参数=[] 强制=[]" -- bash "$preflight_runtime_repository/scripts/experiment.sh"
printf '第四版输入\n' > "$preflight_runtime_repository/input.txt"
run_scripted "preflight/跑的过程中输入变了就不记（前半：改了输入）" 0 "跑的过程中登记的输入变了" \
  -- env SAMPLE_CHANGE_INPUT=1 bash "$preflight_runtime_repository/scripts/experiment.sh"
run_scripted "preflight/跑的过程中输入变了就不记（后半：照判输入变了）" 0 "跑了 参数=[] 强制=[]" -- bash "$preflight_runtime_repository/scripts/experiment.sh"
printf '代码甲\n' > "$preflight_runtime_repository/code.txt"; printf '决策甲\n' > "$preflight_runtime_repository/decision.txt"
run_scripted "preflight/两行 inputs-changed（前半：第一次跑）" 0 "跑了" -- bash "$preflight_runtime_repository/scripts/two-inputs.sh"
printf '代码乙\n' > "$preflight_runtime_repository/code.txt"
run_scripted "preflight/两行 inputs-changed（后半：第一行的输入变了也算）" 0 "跑了" -- bash "$preflight_runtime_repository/scripts/two-inputs.sh"
run_scripted "preflight/cd 到别处之后照样记得下指纹（前半）" 0 "跑了" -- bash -c 'cd "$1" && bash scripts/cd-then-record.sh' cd_then_record "$preflight_runtime_repository"
run_scripted "preflight/cd 到别处之后照样记得下指纹（后半：没变就拒绝）" 78 "以来没变" \
  -- bash -c 'cd "$1" && bash scripts/cd-then-record.sh' cd_then_record "$preflight_runtime_repository"
run_scripted "preflight/没有 python3 就拒绝" 78 "没有 python3，判不了准入与运行条件" \
  -- env PATH=/nonexistent-for-selftest "$BASH" "$preflight_runtime_repository/scripts/minimal.sh"
run_scripted "preflight/没有 python3 时 --force 照跑、标强制" 0 "强制=[没有 python3" \
  -- env PATH=/nonexistent-for-selftest "$BASH" "$preflight_runtime_repository/scripts/minimal.sh" --force
mkdir -p "$preflight_runtime_repository/python-only"; ln -s "$(command -v python3)" "$preflight_runtime_repository/python-only/python3"
run_scripted "preflight/没有 git 按条件不满足拒绝，不崩" 78 "运行 command（第 3 行）：缺 git" \
  -- env PATH="$preflight_runtime_repository/python-only" python3 "$preflight_runtime_repository/scripts/preflight.py" check "$preflight_runtime_repository/scripts/minimal.sh"
run_scripted "preflight/判条件不读走调用方的标准输入" 0 "标准输入=[钩子的输入]" \
  -- bash -c 'printf "钩子的输入" | bash "$1"' stdin_guard "$preflight_runtime_repository/scripts/stdin-guard.sh"
run_scripted "preflight/条件写坏了就不跑" 1 "认不出「sometimes」" "判不了" "正文：没跑" \
  -- bash -c 'script_output="$(bash "$1" 2>&1)"; script_exit_code=$?; printf "%s\n" "$script_output"
              if grep -q 不该跑到这里 <<<"$script_output"; then echo "正文：跑了"; else echo "正文：没跑"; fi
              exit "$script_exit_code"' malformed "$preflight_runtime_repository/scripts/malformed.sh"
run_scripted "preflight/同一个脚本已有实例在跑就拒绝" 78 "已有 1 个实例在跑" -- bash -c '
  stop_file="$2/stop"; running_instance_output="$2/running-instance.out"
  SAMPLE_STOP_FILE="$stop_file" bash -o pipefail "$1" > "$running_instance_output" 2>&1 & running_instance_process_id=$!
  for ((waited_tenths = 0; waited_tenths < 100; waited_tenths++)); do
    if grep -q 起来了 "$running_instance_output" 2>/dev/null; then break; fi
    sleep 0.1
  done
  competing_instance_exit_code=0; bash "$1" || competing_instance_exit_code=$?
  touch "$stop_file"; wait "$running_instance_process_id"
  exit "$competing_instance_exit_code"' single_instance "$preflight_runtime_repository/scripts/single.sh" "$preflight_runtime_repository"
run_scripted "preflight/没有别的实例就照跑" 0 "起来了" -- bash "$preflight_runtime_repository/scripts/single.sh"
run_scripted "preflight/python 脚本条件不满足就拒绝" 78 "设了 SAMPLE_BLOCKED 就不许跑" -- env SAMPLE_BLOCKED=1 python3 "$preflight_runtime_repository/scripts/tool.py" 甲
run_scripted "preflight/python 脚本 --force 照跑、从 sys.argv 里摘掉" 0 "跑了 参数=['甲'] 强制=[运行 check" \
  -- env SAMPLE_BLOCKED=1 python3 "$preflight_runtime_repository/scripts/tool.py" 甲 --force
# tool:<可执行文件名>：工具本身算进输入。没装、装上、换了版本，都是不同的输入
printf '工具样本的输入\n' > "$preflight_runtime_repository/input-tool.txt"; mkdir -p "$preflight_runtime_repository/tool-bin"
run_scripted "preflight/tool: 登记的工具没装也照判（前半：第一次跑）" 0 "工具=[没装]" -- env PATH="$preflight_runtime_repository/tool-bin:$PATH" bash "$preflight_runtime_repository/scripts/tool-input.sh"
run_scripted "preflight/tool: 登记的工具没装也照判（后半：没变就拒绝）" 78 "以来没变" -- env PATH="$preflight_runtime_repository/tool-bin:$PATH" bash "$preflight_runtime_repository/scripts/tool-input.sh"
printf '#!/usr/bin/env bash\necho "sample-tool 1.0"\n' > "$preflight_runtime_repository/tool-bin/sample-tool-for-selftest"; chmod +x "$preflight_runtime_repository/tool-bin/sample-tool-for-selftest"
run_scripted "preflight/tool: 登记的工具装上了算输入变了" 0 "工具=[sample-tool 1.0]" -- env PATH="$preflight_runtime_repository/tool-bin:$PATH" bash "$preflight_runtime_repository/scripts/tool-input.sh"
printf '#!/usr/bin/env bash\necho "sample-tool 2.0"\n' > "$preflight_runtime_repository/tool-bin/sample-tool-for-selftest"
run_scripted "preflight/tool: 登记的工具换了版本算输入变了" 0 "工具=[sample-tool 2.0]" -- env PATH="$preflight_runtime_repository/tool-bin:$PATH" bash "$preflight_runtime_repository/scripts/tool-input.sh"
# 跳过了一部分（lib.sh 的 report_not_run 报过）的那一次不记成「上次成功」：记了的话下一次按输入没变不起，跳过的那一部分一直没人跑
printf '跳过一部分样本的输入\n' > "$preflight_runtime_repository/input-partial.txt"
run_scripted "preflight/有一部分本次未跑就不记（前半：跳过一部分）" 0 "这一次有 1 部分本次未跑" -- env SAMPLE_SKIP_PART=1 bash "$preflight_runtime_repository/scripts/partial.sh"
run_scripted "preflight/有一部分本次未跑就不记（后半：照判输入变了）" 0 "跑了" -- bash "$preflight_runtime_repository/scripts/partial.sh"
run_scripted "preflight/全跑了的那一次照记（输入没变就拒绝）" 78 "以来没变" -- bash "$preflight_runtime_repository/scripts/partial.sh"

# ════ show-me-test（要 git 仓才摆得出场景，现搭现跑）═════
head1 "门禁自证：show-me-test 的判别力"
make_crates_repository() { # make_crates_repository <目录> —— 一个已提交基线的最小 crates 仓
  mkdir -p "$1/crates/foo/src"
  git -C "$1" init -qb master
  printf 'pub fn f() -> u32 { 1 }\n' > "$1/crates/foo/src/lib.rs"
  git -C "$1" add -A
  git -C "$1" -c user.email=selftest@local -c user.name=selftest commit -qm init
}
show_me_test_repository="$temporary_directory/show-me-test-naked"; make_crates_repository "$show_me_test_repository"
printf 'pub fn g() -> u32 { 2 }\n' >> "$show_me_test_repository/crates/foo/src/lib.rs"
run_scripted "show-me-test/改代码无测试拒收" 1 拒收 -- bash "$SCRIPTS/show-me-test.sh" "$show_me_test_repository"
# 还没有任何提交的仓：暂存了的 crates 代码也算改动。只看未跟踪文件的话，暂存的整批漏掉，报「与基准无差异」
show_me_test_repository="$temporary_directory/show-me-test-unborn-staged"; mkdir -p "$show_me_test_repository/crates/foo/src"; git -C "$show_me_test_repository" init -q
printf 'pub fn f() -> u32 { 1 }\n' > "$show_me_test_repository/crates/foo/src/lib.rs"; git -C "$show_me_test_repository" add -A
run_scripted "show-me-test/空仓里暂存了的代码也算改动" 1 拒收 -- bash "$SCRIPTS/show-me-test.sh" "$show_me_test_repository"

show_me_test_repository="$temporary_directory/show-me-test-comment"; make_crates_repository "$show_me_test_repository"
printf 'pub fn g() -> u32 { 2 }\n// 计划稍后 #[test]\n' >> "$show_me_test_repository/crates/foo/src/lib.rs"
run_scripted "show-me-test/注释里的test标注不算" 1 拒收 -- bash "$SCRIPTS/show-me-test.sh" "$show_me_test_repository"

show_me_test_repository="$temporary_directory/show-me-test-end-of-line-comment"; make_crates_repository "$show_me_test_repository"
printf 'pub fn g() -> u32 { 2 } // 待补 #[test]\n' >> "$show_me_test_repository/crates/foo/src/lib.rs"
run_scripted "show-me-test/行尾注释的test标注不算" 1 拒收 -- bash "$SCRIPTS/show-me-test.sh" "$show_me_test_repository"

show_me_test_repository="$temporary_directory/show-me-test-shell"; make_crates_repository "$show_me_test_repository"
printf 'pub fn g() -> u32 { 2 }\n' >> "$show_me_test_repository/crates/foo/src/lib.rs"
mkdir -p "$show_me_test_repository/tests"; printf '// 空壳占位\n' > "$show_me_test_repository/tests/t.rs"
git -C "$show_me_test_repository" add tests
run_scripted "show-me-test/tests下的空壳rs不算" 1 拒收 -- bash "$SCRIPTS/show-me-test.sh" "$show_me_test_repository"

show_me_test_repository="$temporary_directory/show-me-test-data-file"; make_crates_repository "$show_me_test_repository"
printf 'pub fn g() -> u32 { 2 }\n' >> "$show_me_test_repository/crates/foo/src/lib.rs"
mkdir -p "$show_me_test_repository/tests"; echo x > "$show_me_test_repository/tests/note.txt"
run_scripted "show-me-test/tests下非代码文件不算" 1 拒收 -- bash "$SCRIPTS/show-me-test.sh" "$show_me_test_repository"

show_me_test_repository="$temporary_directory/show-me-test-real"; make_crates_repository "$show_me_test_repository"
printf 'pub fn g() -> u32 { 2 }\n' >> "$show_me_test_repository/crates/foo/src/lib.rs"
mkdir -p "$show_me_test_repository/tests"; printf '#[test]\nfn t() { assert_eq!(1, 1); }\n' > "$show_me_test_repository/tests/t.rs"
run_scripted "show-me-test/真测试放行" 0 伴随测试 -- bash "$SCRIPTS/show-me-test.sh" "$show_me_test_repository"

# TEST_MARKER_PATTERN 里的每一种标注都要有用例盯着：缩到只认 #[test] 时别的用例都不红，而 show-me-test 自己的 howto 首推的就是 #[cfg(test)]。
for test_annotation in '#[cfg(test)] mod tests { }' 'proptest! { }' '#[tokio::test] async fn t() {}' '#[kani::proof] fn p() {}'; do
  annotation_label="$(printf '%s' "$test_annotation" | cut -c1-16)"
  show_me_test_repository="$temporary_directory/show-me-test-annotation-$(printf '%s' "$test_annotation" | tr -cd 'a-z')"; make_crates_repository "$show_me_test_repository"
  printf 'pub fn g() -> u32 { 2 }\n' >> "$show_me_test_repository/crates/foo/src/lib.rs"
  mkdir -p "$show_me_test_repository/tests"; printf '%s\n' "$test_annotation" > "$show_me_test_repository/tests/t.rs"
  run_scripted "show-me-test/认得出 $annotation_label" 0 伴随测试 -- bash "$SCRIPTS/show-me-test.sh" "$show_me_test_repository"
done

# 未跟踪的新文件在 diff 里看不见，内联测试全靠单独扫文件内容；删掉那段扫描，这个用例从「放行」变成「拒收」。
show_me_test_repository="$temporary_directory/show-me-test-untracked"; make_crates_repository "$show_me_test_repository"
printf 'pub fn g() -> u32 { 2 }\n' >> "$show_me_test_repository/crates/foo/src/lib.rs"
printf 'pub fn h() -> u32 { 3 }\n#[cfg(test)]\nmod tests { #[test] fn t() { assert_eq!(1,1); } }\n' \
  > "$show_me_test_repository/crates/foo/src/new.rs"
run_scripted "show-me-test/未跟踪文件里的内联测试算数" 0 伴随测试 -- bash "$SCRIPTS/show-me-test.sh" "$show_me_test_repository"

# 分两次提交躲开 diff 窗口：第一次改代码不带测试，第二次只改文档。
# 基准退到已推送点之后，两个 commit 都在窗口里，攒多少次都躲不掉。
show_me_test_repository="$temporary_directory/show-me-test-two-commits"; make_crates_repository "$show_me_test_repository"
git -C "$show_me_test_repository" update-ref refs/sop/gate-ok HEAD     # 门禁在基线那里通过过
printf 'pub fn g() -> u32 { 2 }\n' >> "$show_me_test_repository/crates/foo/src/lib.rs"
git -C "$show_me_test_repository" add -A
git -C "$show_me_test_repository" -c user.email=selftest@local -c user.name=selftest commit -qm "改代码"
printf '# 说明\n' > "$show_me_test_repository/NOTES.md"
git -C "$show_me_test_repository" add -A
git -C "$show_me_test_repository" -c user.email=selftest@local -c user.name=selftest commit -qm "只改文档"
run_scripted "show-me-test/分两次提交躲不掉" 1 拒收 -- bash "$SCRIPTS/show-me-test.sh" "$show_me_test_repository"

# 测试标注只认 .rs 的新增行：在 CLAUDE.md 里写一句「请写 #[test]」不算带了测试
show_me_test_repository="$temporary_directory/show-me-test-markdown-test"; make_crates_repository "$show_me_test_repository"
printf 'pub fn g() -> u32 { 2 }\n' >> "$show_me_test_repository/crates/foo/src/lib.rs"
printf '<!-- 提交模板：新增测试请写 #[test] -->\n' > "$show_me_test_repository/CLAUDE.md"
run_scripted "show-me-test/文档里提 #[test] 不算" 1 拒收 -- bash "$SCRIPTS/show-me-test.sh" "$show_me_test_repository"

# Rust 字符串字面量里的标注同理
show_me_test_repository="$temporary_directory/show-me-test-string-literal"; make_crates_repository "$show_me_test_repository"
printf 'pub const DOC: &str = "#[test]";\npub fn g() -> u32 { 2 }\n' >> "$show_me_test_repository/crates/foo/src/lib.rs"
run_scripted "show-me-test/字符串里的标注不算" 1 拒收 -- bash "$SCRIPTS/show-me-test.sh" "$show_me_test_repository"

# 仓库根丢一个未跟踪的 scratch.rs 也不算
show_me_test_repository="$temporary_directory/show-me-test-scratch"; make_crates_repository "$show_me_test_repository"
printf 'pub fn g() -> u32 { 2 }\n' >> "$show_me_test_repository/crates/foo/src/lib.rs"
printf '#[test]\nfn t() {}\n' > "$show_me_test_repository/scratch.rs"
run_scripted "show-me-test/仓根的草稿 rs 不算" 1 拒收 -- bash "$SCRIPTS/show-me-test.sh" "$show_me_test_repository"

show_me_test_repository="$temporary_directory/show-me-test-committed"; make_crates_repository "$show_me_test_repository"
printf 'pub fn g() -> u32 { 2 }\n' >> "$show_me_test_repository/crates/foo/src/lib.rs"
git -C "$show_me_test_repository" add -A
git -C "$show_me_test_repository" -c user.email=selftest@local -c user.name=selftest commit -qm naked
run_scripted "show-me-test/提交进master也逃不掉" 1 拒收 -- bash "$SCRIPTS/show-me-test.sh" "$show_me_test_repository"

show_me_test_repository="$temporary_directory/show-me-test-build-script"; make_crates_repository "$show_me_test_repository"
printf 'fn main() {}\n' > "$show_me_test_repository/crates/foo/build.rs"
run_scripted "show-me-test/build.rs也是代码" 1 拒收 -- bash "$SCRIPTS/show-me-test.sh" "$show_me_test_repository"

# 只改注释的 crates 文件不算改了代码（判法 comment-only-change.py）；字符串里的 // 不是注释；混着的只拒改代码的那份
show_me_test_repository="$temporary_directory/show-me-test-comment-only"; make_crates_repository "$show_me_test_repository"
printf '// 说明 f 返回什么\npub fn f() -> u32 { 1 } // 行尾也写一句\n' > "$show_me_test_repository/crates/foo/src/lib.rs"
run_scripted "show-me-test/只改注释不算改了代码" 3 "只改注释" -- bash "$SCRIPTS/show-me-test.sh" "$show_me_test_repository"
run_scripted "show-me-test/弄坏开关：注释照代码算就拒收" 1 拒收 -- env SHOW_ME_TEST_BREAK=comments-count-as-code bash "$SCRIPTS/show-me-test.sh" "$show_me_test_repository"
show_me_test_repository="$temporary_directory/show-me-test-string-slashes"; mkdir -p "$show_me_test_repository/crates/foo/src"; git -C "$show_me_test_repository" init -qb master
printf 'pub fn f() -> &'"'"'static str { "a//b" }\n' > "$show_me_test_repository/crates/foo/src/lib.rs"
git -C "$show_me_test_repository" add -A; git -C "$show_me_test_repository" -c user.email=selftest@local -c user.name=selftest commit -qm init
printf 'pub fn f() -> &'"'"'static str { "a//c" }\n' > "$show_me_test_repository/crates/foo/src/lib.rs"
run_scripted "show-me-test/字符串里的 // 改了照代码算" 1 拒收 -- bash "$SCRIPTS/show-me-test.sh" "$show_me_test_repository"
show_me_test_repository="$temporary_directory/show-me-test-mixed"; make_crates_repository "$show_me_test_repository"
printf '// 只是说明\npub fn f() -> u32 { 1 }\n' > "$show_me_test_repository/crates/foo/src/lib.rs"
printf 'pub fn g() -> u32 { 2 }\n' > "$show_me_test_repository/crates/foo/src/other.rs"
git -C "$show_me_test_repository" add -A
run_scripted "show-me-test/混着只改注释的那份也照拒改代码的那份" 1 "crates/foo/src/other.rs" -- bash "$SCRIPTS/show-me-test.sh" "$show_me_test_repository"
run_scripted "comment-only-change/自证" 0 "自证通过" -- python3 "$SCRIPTS/comment-only-change.py" --selftest
for comment_only_break in strings-as-comments doc-code-ignored flat-block-comments lint-comments-ignored; do
  run_scripted "comment-only-change/弄坏开关 $comment_only_break 判错" 1 "判错" -- env COMMENT_ONLY_CHANGE_BREAK="$comment_only_break" python3 "$SCRIPTS/comment-only-change.py" --selftest
done

# 大过管道缓冲的新文件里的内联测试照样算数（同 gate-lint 那条 grep -q 的坑，方向相反：这边是把带测试的判成没带）。
show_me_test_repository="$temporary_directory/show-me-test-big-file"; make_crates_repository "$show_me_test_repository"
printf 'pub fn g() -> u32 { 2 }\n' >> "$show_me_test_repository/crates/foo/src/lib.rs"
# 填充行不能写成注释：strip_comments 会把它们剥掉，喂给 grep 的其实只剩两行，撑不过管道缓冲，
# 这条用例就只是看着像在测大文件。
{ printf '#[cfg(test)]\nmod tests { #[test] fn t() { assert_eq!(1, 1); } }\n'
  awk 'BEGIN { for (filler_index = 0; filler_index < 4000; filler_index++) printf "pub fn filler_%d() -> u32 { %d }\n", filler_index, filler_index }'
} > "$show_me_test_repository/crates/foo/src/new.rs"
run_scripted "show-me-test/大文件里的内联测试算数" 0 伴随测试 -- bash "$SCRIPTS/show-me-test.sh" "$show_me_test_repository"

# GATE_BASE 写错一个字母要拒绝：按「空仓」处理、只看未跟踪文件的话，会报「无对象可判」、门禁绿。
show_me_test_repository="$temporary_directory/show-me-test-bad-base"; make_crates_repository "$show_me_test_repository"
printf 'pub fn g() -> u32 { 2 }\n' >> "$show_me_test_repository/crates/foo/src/lib.rs"
run_scripted "show-me-test/GATE_BASE 解析不到就拒绝" 1 "解析不到提交" -- \
  env GATE_BASE=orgin/master bash "$SCRIPTS/show-me-test.sh" "$show_me_test_repository"

# 上游领先（fetch 了没 merge）时，基准取与上游的 merge-base，不是上游的 tip：
# 取 tip 就是把别人的提交算进这一轮，工作区干净也会被判拒收。
upstream_scenario_directory="$temporary_directory/show-me-test-upstream"; make_crates_repository "$upstream_scenario_directory/local"
git init -q --bare -b master "$upstream_scenario_directory/origin.git"
git -C "$upstream_scenario_directory/local" remote add origin "$upstream_scenario_directory/origin.git"; git -C "$upstream_scenario_directory/local" push -q -u origin master
git clone -q "$upstream_scenario_directory/origin.git" "$upstream_scenario_directory/other"
printf 'pub fn g() -> u32 { 2 }\n' >> "$upstream_scenario_directory/other/crates/foo/src/lib.rs"
git -C "$upstream_scenario_directory/other" add -A
git -C "$upstream_scenario_directory/other" -c user.email=selftest@local -c user.name=selftest commit -qm "别人改了代码没带测试"
git -C "$upstream_scenario_directory/other" push -q origin master
git -C "$upstream_scenario_directory/local" fetch -q origin
run_scripted "show-me-test/上游领先时不算别人的提交" 3 无对象可判 -- bash "$SCRIPTS/show-me-test.sh" "$upstream_scenario_directory/local"

show_me_test_repository="$temporary_directory/show-me-test-nothing"; make_crates_repository "$show_me_test_repository"
run_scripted "show-me-test/无对象可判" 3 无对象可判 -- bash "$SCRIPTS/show-me-test.sh" "$show_me_test_repository"
# 有差异、但一行 crates 代码都没改：与「无差异」同一个口径，记无对象可判，不记通过
show_me_test_repository="$temporary_directory/show-me-test-documents-only"; make_crates_repository "$show_me_test_repository"
printf '# 说明\n' > "$show_me_test_repository/NOTES.md"
run_scripted "show-me-test/改动里没有 crates 代码记无对象可判" 3 "改动里没有 crates 代码" -- bash "$SCRIPTS/show-me-test.sh" "$show_me_test_repository"
# 改动清单取不全就不判：changed_files 里任一条 git 失败被吞掉的话，清单少一截，改了代码被判成「无对象可判」。
# 假 git 只让「git diff --name-only <基准>」失败；改代码的那个提交只在这一条里看得见。
fake_git_directory="$temporary_directory/fake-git-diff"; mkdir -p "$fake_git_directory"
printf '#!/usr/bin/env bash\nif [[ " $* " == *" diff --name-only "* && " $* " != *--cached* ]]; then echo "fatal: 样本：这一条 git diff 失败" >&2; exit 128; fi\nexec %q "$@"\n' \
  "$(command -v git)" > "$fake_git_directory/git"
chmod +x "$fake_git_directory/git"
show_me_test_repository="$temporary_directory/show-me-test-diff-fails"; make_crates_repository "$show_me_test_repository"
git -C "$show_me_test_repository" update-ref refs/sop/gate-ok HEAD
printf 'pub fn g() -> u32 { 2 }\n' >> "$show_me_test_repository/crates/foo/src/lib.rs"
git -C "$show_me_test_repository" add -A; git -C "$show_me_test_repository" -c user.email=selftest@local -c user.name=selftest commit -qm "改代码"
run_scripted "show-me-test/改动清单取不全就判不了" 1 "取不到相对基准" -- env PATH="$fake_git_directory:$PATH" bash "$SCRIPTS/show-me-test.sh" "$show_me_test_repository"

# gate-lint 也扫 .py：项目本地阶段常用 python 写，它们的拒绝一样摆在提交者面前。
# 样本内容写进临时文件，不写成本脚本里的字符串（同「默认扫描范围」那一节的警告），所以 ✗ 用参数传。
gate_lint_target_directory="$temporary_directory/gate-lint-python"; mkdir -p "$gate_lint_target_directory"
printf '#!/usr/bin/env python3\n# 样本：python 写的阶段，拒绝直接 print，没有出路\nimport sys\nprint("  %s 这几项不成形")\nsys.exit(1)\n' ✗ > "$gate_lint_target_directory/x.py"
run_scripted "gate-lint/python 阶段的拒绝也要给出路" 1 "x.py:4" -- env GATE_LINT_DIR="$gate_lint_target_directory" bash "$SCRIPTS/gate-lint.sh"

# doc-lint 自己报得出「本语言哪几条检查没实现」，gate.sh 拿它填汇总里的未实现清单。
run_scripted "doc-lint/没词表的语言报得出哪几条未实现" 0 "文档铁律的词表型检查（en）：历史陈述、kb 的指代与自称、文风" -- \
  env DOC_LINT_LANG=en bash "$SCRIPTS/doc-lint.sh" --not-impl
run_scripted "doc-lint/日文只报没实现的那几条" 0 "文档铁律的词表型检查（ja）：历史陈述、kb 的时间指代、文风" -- \
  env DOC_LINT_LANG=ja bash "$SCRIPTS/doc-lint.sh" --not-impl
run_scripted "doc-lint/有词表时未实现清单是空的" 0 "未实现清单为空" -- \
  bash -c 'not_implemented_output="$(env DOC_LINT_LANG=zh bash "$1" --not-impl)"; [[ -z "$not_implemented_output" ]] && echo "未实现清单为空"' doc_lint_not_implemented_zh "$SCRIPTS/doc-lint.sh"


# 样本里的日期也要可能。样本不在 doc-lint 的扫描范围里（它们是故意写坏的），所以这一条由 selftest 自己扫：
# 样本与 skill 示例里写过早于仓起点的日期，门禁一直是绿的。
# 故意拿不可能的日期去测那条检查的样本，在它自己的 expect 里声明出来，显式豁免（猜不着的东西不猜）。
fixture_date_check=(bash -c '
  fixtures_directory="$1"; lower_bound_date="$2"; today_date="$3"; bad_count=0; seen_count=0
  while IFS= read -r fixture_file; do
    relative_path="${fixture_file#"$fixtures_directory"/}"; lint_name="${relative_path%%/*}"; path_after_lint_name="${relative_path#*/}"; fixture_name="${path_after_lint_name%%/*}"
    expect_file="$fixtures_directory/$lint_name/$fixture_name/expect"
    if [[ -f "$expect_file" ]] && grep -q "晚于今天\|早于这个仓" "$expect_file"; then continue; fi
    while IFS=: read -r line_number line_text; do
      found_date="$(printf "%s" "$line_text" | grep -oE "[0-9]{4}-[0-9]{2}-[0-9]{2}" || true)"
      found_date="${found_date%%$'"'"'\n'"'"'*}"
      [[ -n "$found_date" ]] || continue
      seen_count=$((seen_count+1))
      if [[ "$found_date" > "$today_date" ]] || { [[ -n "$lower_bound_date" ]] && [[ "$found_date" < "$lower_bound_date" ]]; }; then
        echo "  样本日期不可能：$relative_path:$line_number  $found_date"; bad_count=$((bad_count+1))
      fi
    done < <(grep -nE "(^###[[:space:]]+|^##[[:space:]]+[0-9]+\.[0-9]+\.[0-9]+[[:space:]]+—[[:space:]]+|实测（)[0-9]{4}-[0-9]{2}-[0-9]{2}" "$fixture_file" || true)
  done < <(find "$fixtures_directory" -type f -name "*.md" | sort)
  echo "样本里查了 $seen_count 个日期，不可能的 $bad_count 个"
  [[ $bad_count -eq 0 ]]' fixture_date_check)
run_scripted "selftest/样本里的日期也要可能" 0 "不可能的 0 个" -- \
  "${fixture_date_check[@]}" "$fixtures_directory" "$(date_lower_bound "$SOP_START_DATE")" "$(latest_today)"

# ── 编号与简称：源码注释与记录里引的简称与登记位不符 ──────
number_name_project="$temporary_directory/number-name"; mkdir -p "$number_name_project/.claude/kb/decisions" "$number_name_project/src"
printf '## D1 数据可移动性 —— 已定\n\n正文。\n' > "$number_name_project/.claude/kb/decisions/01-a.md"
printf '// 照 D1（数据可移动性）办。\n' > "$number_name_project/src/a.rs"
run_scripted "number-name-sync/简称与登记位一致时通过" 0 "编号与简称一致" -- \
  bash "$SCRIPTS/number-name-sync.sh" "$number_name_project"
printf '// 照 D1（旧名字）办。\n' > "$number_name_project/src/a.rs"
run_scripted "number-name-sync/简称与登记位不符判红" 1 "登记处是「数据可移动性」" -- \
  bash "$SCRIPTS/number-name-sync.sh" "$number_name_project"
mkdir -p "$temporary_directory/number-name-none"
run_scripted "number-name-sync/没有 kb 退 77" 77 "" -- \
  bash "$SCRIPTS/number-name-sync.sh" "$temporary_directory/number-name-none"
run_scripted "number-name-sync/仓根不在要给出路" 2 "找不到仓根" -- bash "$SCRIPTS/number-name-sync.sh" "$temporary_directory/number-name-no-such-root"
# 登记了自定义 kb 目录（rules/kb-discipline.md）：登记位与扫描范围都跟着它走，不是默认的 .claude/kb
number_name_project="$temporary_directory/number-name-registered"; mkdir -p "$number_name_project/crates/checker/invariants/decisions" "$number_name_project/src" "$number_name_project/.claude"
printf 'crates/checker/invariants  # 不变量与决策挪到 checker 旁边\n' > "$number_name_project/.claude/kb-directories"
printf '## D1 数据可移动性 —— 已定\n\n正文。\n' > "$number_name_project/crates/checker/invariants/decisions/01-a.md"
printf '// 照 D1（旧名字）办。\n' > "$number_name_project/src/a.rs"
run_scripted "number-name-sync/登记了自定义 kb 目录就在那里认登记位" 1 "登记处是「数据可移动性」" -- \
  bash "$SCRIPTS/number-name-sync.sh" "$number_name_project"
printf '// 照 D1（数据可移动性）办。\n' > "$number_name_project/src/a.rs"
printf '登记位自己目录里的「D1（旧名字）」不该被扫\n' > "$number_name_project/crates/checker/invariants/decisions/02-ref.md"
run_scripted "number-name-sync/登记的 kb 目录自己排除在扫描范围外" 0 "编号与简称一致" -- \
  bash "$SCRIPTS/number-name-sync.sh" "$number_name_project"
printf 'nope  # 登记的目录不存在\n' > "$number_name_project/.claude/kb-directories"
run_scripted "number-name-sync/kb 目录登记指到不存在的路径判红" 2 "登记的目录不存在：nope" -- \
  bash "$SCRIPTS/number-name-sync.sh" "$number_name_project"
number_name_project="$temporary_directory/number-name-copy"; make_installed_copy "$number_name_project" demo-sop; mkdir -p "$number_name_project/.claude/kb/decisions" "$number_name_project/src" "$number_name_project/.claude/demo-sop/rules"
printf '## D1 数据可移动性 —— 已定\n' > "$number_name_project/.claude/kb/decisions/01-a.md"; printf '// 照 D1（数据可移动性）办。\n' > "$number_name_project/src/a.rs"
printf '照 D1（别的名字）办。\n' > "$number_name_project/.claude/demo-sop/rules/a.md"
run_scripted "number-name-sync/副本按 I18N 的 family 认、不扫" 0 "扫 1 个文件" -- bash "$number_name_project/.claude/demo-sop/scripts/number-name-sync.sh" "$number_name_project"

# ── 转发计时：它自己的红绿样本还判得对吗 ──────────────
run_scripted "relay-timing-lint/自证 16 个样本判得对" 0 "自证：16 个红绿样本判得对" -- \
  python3 "$SCRIPTS/relay-timing-lint.py" --selftest
# 不给仓库根时判当前目录所在的仓：按本文件的位置往上数两层的话，装在包里时数到的是包根的上一层，被判的仓一个文件都没扫
relay_timing_scenario_directory="$temporary_directory/relay-timing-root"; mkdir -p "$relay_timing_scenario_directory/outer/nested/package/scripts" "$relay_timing_scenario_directory/project/research"
cp "$SCRIPTS/relay-timing-lint.py" "$SCRIPTS/preflight.py" "$SCRIPTS/proc.py" "$relay_timing_scenario_directory/outer/nested/package/scripts/"
git -C "$relay_timing_scenario_directory/project" init -q
printf 'import subprocess\nimport time\n\n\ndef relay():\n    process = subprocess.Popen(["child"], stdout=subprocess.PIPE, text=True)\n    for line in process.stdout:\n        print(time.monotonic(), line)\n' \
  > "$relay_timing_scenario_directory/project/research/relay.py"
run_scripted "relay-timing-lint/不给仓库根时判当前目录所在的仓" 1 "research/relay.py:7" -- \
  bash -c 'cd "$1/research" && python3 "$2/relay-timing-lint.py" --check' relay_default_root "$relay_timing_scenario_directory/project" "$relay_timing_scenario_directory/outer/nested/package/scripts"

# ── 工具层的闸：钩子注册着没有、自证过不过 ──────────────
hooks_project="$temporary_directory/hooks-registered"; mkdir -p "$hooks_project/.claude/hooks"
printf '#!/usr/bin/env bash\n[[ "${1:-}" == --selftest ]] && { echo "  自证：查了 2 种情形"; exit 0; }\nexit 0\n' > "$hooks_project/.claude/hooks/guard.sh"
chmod +x "$hooks_project/.claude/hooks/guard.sh"
# 包自带的钩子也要注册：pattern-process-guard 挂 PreToolUse（rules/command-safety.md），
# gate-reuse-check 可选，注册了就挂 Stop 与 SubagentStop（rules/sop-first.md「谁来查」），
# handback-scratch-check 挂交回工具的 PreToolUse 与 SubagentStop（rules/session-wrapup.md「子 agent 交回之前，删掉自己建的编译目录与仓副本」）
hooks_registered_settings() { # hooks_registered_settings <gate-reuse-check 挂在哪：yes 两个都挂 / no 只挂 Stop / none 不注册>
  local gate_reuse_on_subagent_stop='' gate_reuse_on_stop='{"type":"command","command":"bash gate-reuse-check.sh"}'
  [[ "$1" == yes ]] && gate_reuse_on_subagent_stop='{"type":"command","command":"bash gate-reuse-check.sh"},'
  [[ "$1" == none ]] && gate_reuse_on_stop=''
  printf '{"hooks":{"PreToolUse":[{"matcher":"Write","hooks":[{"type":"command","command":"bash guard.sh"},{"type":"command","command":"bash pattern-process-guard.sh"}]},{"matcher":"SubagentHandback","hooks":[{"type":"command","command":"bash handback-scratch-check.sh"}]}],"Stop":[{"hooks":[%s]}],"SubagentStop":[{"hooks":[%s{"type":"command","command":"bash handback-scratch-check.sh"}]}]}}\n' \
    "$gate_reuse_on_stop" "$gate_reuse_on_subagent_stop" > "$hooks_project/.claude/settings.json"
}
hooks_registered_settings yes
run_scripted "hooks-registered/注册着且自证过就通过" 0 "个钩子都注册着" -- \
  bash "$SCRIPTS/hooks-registered.sh" "$hooks_project"
hooks_registered_settings no
run_scripted "hooks-registered/声明的事件没挂全判红" 1 "gate-reuse-check.sh→SubagentStop" -- \
  bash "$SCRIPTS/hooks-registered.sh" "$hooks_project"
# 副本里声明了 # hook-registration: optional 的钩子，项目可以不注册；成功那句要逐个列出没注册的
hooks_registered_settings none
run_scripted "hooks-registered/可选钩子不注册放行并列出" 0 "1 个可选钩子没注册：gate-reuse-check.sh" -- \
  bash "$SCRIPTS/hooks-registered.sh" "$hooks_project"
# 项目自己的钩子写 optional 不算数：不用就连文件删掉
printf '#!/usr/bin/env bash\n# hook-registration: optional 项目自己的钩子也想不注册\nexit 0\n' > "$hooks_project/.claude/hooks/unused-guard.sh"
run_scripted "hooks-registered/项目自己的钩子写可选也要注册" 1 "unused-guard.sh  要挂的事件" -- \
  bash "$SCRIPTS/hooks-registered.sh" "$hooks_project"
rm -f "$hooks_project/.claude/hooks/unused-guard.sh"
# 声明了只在某个工具上触发（<事件>:<工具名>）的，注册在别的 matcher 上等于没挂：钩子一次都不会为那个工具触发
hooks_registered_settings yes
python3 - "$hooks_project/.claude/settings.json" <<'SETTINGS'
import json, sys
with open(sys.argv[1], encoding='utf-8') as settings_file:
    settings = json.load(settings_file)
for entry in settings['hooks']['PreToolUse']:
    if entry.get('matcher') == 'SubagentHandback':
        entry['matcher'] = 'Bash'
with open(sys.argv[1], 'w', encoding='utf-8') as settings_file:
    json.dump(settings, settings_file)
SETTINGS
run_scripted "hooks-registered/挂在别的 matcher 上判红" 1 "handback-scratch-check.sh→PreToolUse:SubagentHandback" -- \
  bash "$SCRIPTS/hooks-registered.sh" "$hooks_project"
# 按文件名的边界认：注册的是 old-guard.sh，不等于 guard.sh 注册着
printf '{"hooks":{"PreToolUse":[{"matcher":"Write","hooks":[{"type":"command","command":"bash .claude/hooks/old-guard.sh"},{"type":"command","command":"bash pattern-process-guard.sh"}]}],"Stop":[{"hooks":[{"type":"command","command":"bash gate-reuse-check.sh"}]}],"SubagentStop":[{"hooks":[{"type":"command","command":"bash gate-reuse-check.sh"},{"type":"command","command":"bash handback-scratch-check.sh"}]}]}}\n' > "$hooks_project/.claude/settings.json"
run_scripted "hooks-registered/名字是别的钩子名的一截也不算注册" 1 "没在 settings.json 里注册" "guard.sh  要挂的事件" -- \
  bash "$SCRIPTS/hooks-registered.sh" "$hooks_project"
printf '{ 坏掉的 JSON\n' > "$hooks_project/.claude/settings.json"
run_scripted "hooks-registered/settings.json 读不了时说清是文件坏了" 1 "读不了（不是合法的 JSON" -- \
  bash "$SCRIPTS/hooks-registered.sh" "$hooks_project"
printf '{"hooks":{"PreToolUse":[]}}\n' > "$hooks_project/.claude/settings.json"
run_scripted "hooks-registered/一条都没注册时判红" 1 "一条钩子都没注册" -- \
  bash "$SCRIPTS/hooks-registered.sh" "$hooks_project"
printf '{"hooks":{"PreToolUse":[{"matcher":"Write","hooks":[{"type":"command","command":"bash other.sh"}]}]}}\n' > "$hooks_project/.claude/settings.json"
run_scripted "hooks-registered/钩子没被注册到时判红" 1 "没在 settings.json 里注册" -- \
  bash "$SCRIPTS/hooks-registered.sh" "$hooks_project"
# 自证会红的钩子：注册着也不算数——自证就是这道闸「会拒绝」的证据
printf '#!/usr/bin/env bash\n[[ "${1:-}" == --selftest ]] && { echo "  自证：有一种情形没拦住"; exit 1; }\nexit 0\n' > "$hooks_project/.claude/hooks/guard.sh"
hooks_registered_settings yes
run_scripted "hooks-registered/钩子自证没过时判红" 1 "个钩子的自证没过" -- \
  bash "$SCRIPTS/hooks-registered.sh" "$hooks_project"
# 有钩子（装进来的副本自带三个）却没有 settings.json：等于一个都没注册，判红；一个钩子都没有才是无对象可判
mkdir -p "$temporary_directory/hooks-none"
run_scripted "hooks-registered/有钩子却没有 settings.json 判红" 1 "它们一个都没注册" -- \
  bash "$SCRIPTS/hooks-registered.sh" "$temporary_directory/hooks-none"
make_hooks_package() { # make_hooks_package <目录>：只带判注册那几份脚本的最小包，claude-hooks/ 放什么由调用方定
  mkdir -p "$1/scripts"
  cp "$SCRIPTS/lib.sh" "$SCRIPTS/preflight.py" "$SCRIPTS/preflight.sh" "$SCRIPTS/proc.py" "$SCRIPTS/hooks-registered.sh" "$SCRIPTS/hook-registrations.py" "$1/scripts/"
}
hooks_scenario_directory="$temporary_directory/hooks-no-package"; make_hooks_package "$hooks_scenario_directory/package"; mkdir -p "$hooks_scenario_directory/project"
run_scripted "hooks-registered/一个钩子都没有退 77" 77 "一个钩子都没有" -- bash "$hooks_scenario_directory/package/scripts/hooks-registered.sh" "$hooks_scenario_directory/project"
# 读某一个钩子的注册失败，不许报成「没注册」：出路会指错地方
hooks_scenario_directory="$temporary_directory/hooks-reader-fails"; make_hooks_package "$hooks_scenario_directory/package"; mkdir -p "$hooks_scenario_directory/package/scripts/claude-hooks" "$hooks_scenario_directory/project/.claude"
printf '#!/usr/bin/env bash\n# hook-events: Stop\nexit 0\n' > "$hooks_scenario_directory/package/scripts/claude-hooks/sample-hook.sh"
printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"bash sample-hook.sh"}]}]}}\n' > "$hooks_scenario_directory/project/.claude/settings.json"
printf 'import sys\nif sys.argv[1:2] == ["--for"]:\n    sys.exit(1)\nprint("Stop\\t\\tbash sample-hook.sh")\n' > "$hooks_scenario_directory/package/scripts/hook-registrations.py"
run_scripted "hooks-registered/读注册失败不报成没注册" 1 "个钩子的注册读不出来" -- bash "$hooks_scenario_directory/package/scripts/hooks-registered.sh" "$hooks_scenario_directory/project"
# 可选的理由太短：判不了该不该放行，判红
hooks_scenario_directory="$temporary_directory/hooks-optional-short"; make_hooks_package "$hooks_scenario_directory/package"; mkdir -p "$hooks_scenario_directory/package/scripts/claude-hooks" "$hooks_scenario_directory/project/.claude"
printf '#!/usr/bin/env bash\n# hook-events: Stop\n# hook-registration: optional 不必\nexit 0\n' > "$hooks_scenario_directory/package/scripts/claude-hooks/sample-hook.sh"
printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"bash other-hook.sh"}]}]}}\n' > "$hooks_scenario_directory/project/.claude/settings.json"
run_scripted "hooks-registered/可选的理由太短判红" 1 "理由不到 8 个字：sample-hook.sh" -- bash "$hooks_scenario_directory/package/scripts/hooks-registered.sh" "$hooks_scenario_directory/project"
# 项目登记了自定义钩子目录：没有这份登记时默认目录是空的，会退 77（无对象可判）；读了登记才找得到这个钩子、判它没注册
hooks_scenario_directory="$temporary_directory/hooks-registered-directory"; make_hooks_package "$hooks_scenario_directory/package"; mkdir -p "$hooks_scenario_directory/project/scripts/guards" "$hooks_scenario_directory/project/.claude"
printf 'scripts/guards  # 工程脚本统一挪进项目仓根 scripts/\n' > "$hooks_scenario_directory/project/.claude/hooks-directory"
printf '#!/usr/bin/env bash\nexit 0\n' > "$hooks_scenario_directory/project/scripts/guards/guard.sh"
run_scripted "hooks-registered/登记了自定义钩子目录就扫那里" 1 "而 $hooks_scenario_directory/project/scripts/guards 与装进来的副本里共有" "它们一个都没注册" -- bash "$hooks_scenario_directory/package/scripts/hooks-registered.sh" "$hooks_scenario_directory/project"

# ── 门禁查重：新加的门禁与钩子先对过已有的，不整段抄 ──────
overlap_repository="$temporary_directory/gate-overlap"; mkdir -p "$overlap_repository/.claude/gate.d" "$overlap_repository/.claude/hooks"
git -C "$overlap_repository" init -q
overlap_block() { # overlap_block [行数，默认 9]：一段每行都不一样、每行都算有信息的行
  local step; for ((step = 1; step <= ${1:-9}; step++)); do printf 'echo "第 %s 步：核对登记表里的第 %s 行"\n' "$step" "$step"; done
}
rich_identifiers() { local index; for ((index = 1; index <= 25; index++)); do printf 'registry_column_%02d ' "$index"; done; }
{ printf '#!/usr/bin/env bash\n# gate-stage: 已有的样本阶段\n'; overlap_block; } > "$overlap_repository/.claude/gate.d/10-existing.sh"
{ printf '#!/usr/bin/env bash\n# gate-stage: 早就抄了一份的旧阶段\n'; overlap_block; } > "$overlap_repository/.claude/gate.d/16-legacy-copy.sh"
printf '#!/usr/bin/env bash\n# gate-stage: 另一个旧阶段\necho "只判一件不相干的事"\n' > "$overlap_repository/.claude/gate.d/15-plain.sh"
{ printf '#!/usr/bin/env bash\n# gate-stage: 标识符很多的旧阶段\n'; for identifier in $(rich_identifiers); do printf 'check_column "%s"\n' "$identifier"; done; } > "$overlap_repository/.claude/gate.d/30-rich.sh"
printf '#!/usr/bin/env bash\n# admission: always 样本钩子，每次调都要判\n# run-condition: none 样本钩子没有环境要求\n# 已有的钩子\necho "拦 Bash 里的一种写法"\n' > "$overlap_repository/.claude/hooks/old-guard.sh"
overlap_settings() { # overlap_settings <新钩子挂的事件> <新钩子的 matcher> [新钩子的命令]：已有钩子挂在 PreToolUse 的 Bash|Write 上
  local existing_hook_entry new_hook_entry
  existing_hook_entry='{"matcher":"Bash|Write","hooks":[{"type":"command","command":"bash .claude/hooks/old-guard.sh"}]}'
  new_hook_entry="$(printf '{"matcher":"%s","hooks":[{"type":"command","command":"%s"}]}' "$2" "${3:-bash .claude/hooks/new-guard.sh}")"
  # 同一个事件要放进同一个数组：JSON 里写两个同名的键，后一个会把已有钩子的注册整个盖掉
  if [[ "$1" == PreToolUse ]]; then
    printf '{"hooks":{"PreToolUse":[%s,%s]}}\n' "$existing_hook_entry" "$new_hook_entry"
  else
    printf '{"hooks":{"PreToolUse":[%s],"%s":[%s]}}\n' "$existing_hook_entry" "$1" "$new_hook_entry"
  fi > "$overlap_repository/.claude/settings.json"
}
overlap_settings PostToolUse Bash
git -C "$overlap_repository" add -A; git -C "$overlap_repository" -c user.name=t -c user.email=t@t commit -qm base
overlap_check=(env GATE_DIFF_BASE="$(git -C "$overlap_repository" rev-parse HEAD)" python3 "$SCRIPTS/gate-overlap.py")
# 存量里就有的整段相同（10 与 16）不判：它们都不在这一次的改动里
run_scripted "gate-overlap/没有新加或改动门禁时退 77" 77 "这一次没有新加或改动门禁与钩子" -- "${overlap_check[@]}" "$overlap_repository"
# 说明列取的是真正的说明行：old-guard.sh 的头几行是 admission: / run-condition:，说明「已有的钩子」排在它们后面
run_scripted "gate-overlap/--list 列出已有的与触发点，说明列跳过准入与运行条件" 0 "old-guard.sh" "PreToolUse[Bash|Write]" "已有的样本阶段" "已有的钩子" -- \
  python3 "$SCRIPTS/gate-overlap.py" --list "$overlap_repository"
# 本包的阶段是按 gate.sh 里调脚本的那个变量名认出来的：gate.sh 改了变量名而这里没跟上，本包的门禁一份都列不出来
run_scripted "gate-overlap/--list 认得出本包 gate.sh 调的阶段" 0 $'门禁\tscripts/doc-lint.sh' $'门禁\tscripts/show-me-test.sh' -- \
  python3 "$SCRIPTS/gate-overlap.py" --list "$SCRIPTS/.."
printf '#!/usr/bin/env bash\necho "新判据：只看一件别的事"\n' > "$overlap_repository/.claude/gate.d/20-new.sh"
run_scripted "gate-overlap/新阶段没写 gate-similar 判红" 1 "20-new.sh 是新加的，没写 gate-similar" "按字面最像的几份" -- \
  "${overlap_check[@]}" "$overlap_repository"
printf '#!/usr/bin/env bash\n# gate-similar: 10-existing.sh 它判登记表，这一道判别的事\necho "新判据：只看一件别的事"\n' > "$overlap_repository/.claude/gate.d/20-new.sh"
run_scripted "gate-overlap/写明比过谁就通过" 0 "新加的门禁与钩子 1 个（.claude/gate.d/20-new.sh）" -- "${overlap_check[@]}" "$overlap_repository"
printf '#!/usr/bin/env bash\n# gate-similar: 99-nowhere.sh 它判登记表，这一道判别的事\necho "新判据：只看一件别的事"\n' > "$overlap_repository/.claude/gate.d/20-new.sh"
run_scripted "gate-overlap/点名的不存在判红" 1 "「99-nowhere.sh」不是已有的门禁或钩子" -- "${overlap_check[@]}" "$overlap_repository"
printf '#!/usr/bin/env bash\n# gate-similar: 10-existing.sh 不同\necho "新判据：只看一件别的事"\n' > "$overlap_repository/.claude/gate.d/20-new.sh"
run_scripted "gate-overlap/理由太短判红" 1 "理由不到 8 个字" -- "${overlap_check[@]}" "$overlap_repository"
# 字面上很像的已有一份：写「无」不算，要点名
{ printf '#!/usr/bin/env bash\n# gate-similar: 无 查过全表，没有管同一件事的\n'; printf ': %s\n' "$(rich_identifiers)"; } > "$overlap_repository/.claude/gate.d/20-new.sh"
run_scripted "gate-overlap/字面上很像的没点名判红" 1 "30-rich.sh  字面上很像" -- "${overlap_check[@]}" "$overlap_repository"
# 像的字样只在注释里、代码是另一套标识符（20 个，正好够算重合）：不算字面上很像；注释也算的话重合过 0.5
other_identifiers() { local index; for ((index = 1; index <= 20; index++)); do printf 'other_column_%02d ' "$index"; done; }
{ printf '#!/usr/bin/env bash\n# gate-similar: 无 查过全表，没有管同一件事的\n'; printf '# 说明里提到 check_column gate-stage %s\n' "$(rich_identifiers)"; printf ': %s\n' "$(other_identifiers)"; } > "$overlap_repository/.claude/gate.d/20-new.sh"
run_scripted "gate-overlap/只在注释里像的不算字面上很像" 0 "新加的门禁与钩子 1 个（.claude/gate.d/20-new.sh）" -- "${overlap_check[@]}" "$overlap_repository"
# 新阶段整段抄了已有的一份：写了声明也红
{ printf '#!/usr/bin/env bash\n# gate-similar: 10-existing.sh 它只判登记表里的行号\n'; overlap_block; } > "$overlap_repository/.claude/gate.d/20-new.sh"
run_scripted "gate-overlap/新阶段整段抄已有的判红" 1 "20-new.sh:3-11 与 .claude/gate.d/10-existing.sh:3 起（连续 9 行相同）" -- \
  "${overlap_check[@]}" "$overlap_repository"
# 门槛钉在 CLONE_MINIMUM_LINES：7 行不判，8 行判；多敲几个空格也还是同一行
{ printf '#!/usr/bin/env bash\n# gate-similar: 10-existing.sh 它只判登记表里的行号\n'; overlap_block 7; } > "$overlap_repository/.claude/gate.d/20-new.sh"
run_scripted "gate-overlap/整段相同不到门槛不判" 0 "没有整段相同" -- "${overlap_check[@]}" "$overlap_repository"
{ printf '#!/usr/bin/env bash\n# gate-similar: 10-existing.sh 它只判登记表里的行号\n'; overlap_block 8; } > "$overlap_repository/.claude/gate.d/20-new.sh"
run_scripted "gate-overlap/整段相同到了门槛判红" 1 "连续 8 行相同" -- "${overlap_check[@]}" "$overlap_repository"
{ printf '#!/usr/bin/env bash\n# gate-similar: 10-existing.sh 它只判登记表里的行号\n'; overlap_block | sed 's/ /   /g'; } > "$overlap_repository/.claude/gate.d/20-new.sh"
run_scripted "gate-overlap/多敲空格绕不过整段相同" 1 "连续 9 行相同" -- "${overlap_check[@]}" "$overlap_repository"
{ printf '#!/usr/bin/env bash\n# gate-similar: 10-existing.sh 它只判登记表里的行号\n# gate-overlap:copy-kept 10-existing.sh 样本要两份各自独立跑\n# gate-overlap:copy-kept 16-legacy-copy.sh 这一份也是样本，要各自独立跑\n'; overlap_block; } > "$overlap_repository/.claude/gate.d/20-new.sh"
run_scripted "gate-overlap/写了 copy-kept 就放行并报出来" 0 "按 copy-kept 留着两份的" -- "${overlap_check[@]}" "$overlap_repository"
{ printf '#!/usr/bin/env bash\n# gate-similar: 10-existing.sh 它只判登记表里的行号\n# gate-overlap:copy-kept 99-nowhere.sh 样本要两份各自独立跑\n'; overlap_block; } > "$overlap_repository/.claude/gate.d/20-new.sh"
run_scripted "gate-overlap/copy-kept 点名不存在判红" 1 "copy-kept 有 1 处写得不对" -- "${overlap_check[@]}" "$overlap_repository"
# 抄了装进来的共享脚本也算：对照范围含本包的 scripts/
{ printf '#!/usr/bin/env bash\n# gate-similar: 10-existing.sh 它只判登记表里的行号\n'; sed -n '/^diff_base()/,/^}/p' "$SCRIPTS/lib.sh"; } > "$overlap_repository/.claude/gate.d/20-new.sh"
run_scripted "gate-overlap/抄共享脚本也判红" 1 "lib.sh" "整段相同" -- "${overlap_check[@]}" "$overlap_repository"
rm -f "$overlap_repository/.claude/gate.d/20-new.sh"
# 往已有的阶段里贴一整段：不是新文件，加进来的行照样判
cp "$overlap_repository/.claude/gate.d/15-plain.sh" "$temporary_directory/overlap-15-plain.sh"
overlap_block >> "$overlap_repository/.claude/gate.d/15-plain.sh"
run_scripted "gate-overlap/往已有的阶段里贴一整段判红" 1 "15-plain.sh:4-12" -- "${overlap_check[@]}" "$overlap_repository"
cp "$temporary_directory/overlap-15-plain.sh" "$overlap_repository/.claude/gate.d/15-plain.sh"
# 只动了存量重复旁边的一行：窗口里没有一整段是这一次加的，不判
cp "$overlap_repository/.claude/gate.d/16-legacy-copy.sh" "$temporary_directory/overlap-16-legacy-copy.sh"
printf 'echo "旧阶段里补的一行，和谁都不一样"\n' >> "$overlap_repository/.claude/gate.d/16-legacy-copy.sh"
run_scripted "gate-overlap/存量重复旁边改一行不判" 0 "改过的 1 份脚本" -- "${overlap_check[@]}" "$overlap_repository"
cp "$temporary_directory/overlap-16-legacy-copy.sh" "$overlap_repository/.claude/gate.d/16-legacy-copy.sh"
# 两份都改过：旧的那份只加了一行，新的那份整段是新加的——要报整段那一侧
cp "$overlap_repository/.claude/gate.d/10-existing.sh" "$temporary_directory/overlap-10-existing.sh"
printf 'echo "第 10 步：核对登记表里的第 10 行"\n' >> "$overlap_repository/.claude/gate.d/10-existing.sh"
{ printf '#!/usr/bin/env bash\n# gate-similar: 10-existing.sh 它只判登记表里的行号\n'; overlap_block 10; } > "$overlap_repository/.claude/gate.d/25-copy.sh"
run_scripted "gate-overlap/两份都改过时报整段那一侧" 1 "连续 10 行相同" -- "${overlap_check[@]}" "$overlap_repository"
cp "$temporary_directory/overlap-10-existing.sh" "$overlap_repository/.claude/gate.d/10-existing.sh"; rm -f "$overlap_repository/.claude/gate.d/25-copy.sh"
# 新钩子与已有钩子挂在同一个触发点上：写「无」不算，要点名
overlap_settings PreToolUse Bash
printf '#!/usr/bin/env bash\n# hook-events: PreToolUse\n# gate-similar: 无 查过全表，没有管同一件事的\necho "拦 Bash 里的另一种写法"\n' > "$overlap_repository/.claude/hooks/new-guard.sh"
run_scripted "gate-overlap/同触发点的钩子没点名判红" 1 "old-guard.sh  挂在同一个触发点上：PreToolUse[Bash|Write]" -- \
  "${overlap_check[@]}" "$overlap_repository"
printf '#!/usr/bin/env bash\n# hook-events: PreToolUse\n# gate-similar: old-guard.sh 它拦的是另一类命令，拒绝时要写的出路不同\necho "拦 Bash 里的另一种写法"\n' > "$overlap_repository/.claude/hooks/new-guard.sh"
run_scripted "gate-overlap/同触发点的钩子点了名就通过" 0 "new-guard.sh" -- "${overlap_check[@]}" "$overlap_repository"
printf '#!/usr/bin/env bash\n# gate-similar: old-guard.sh 它拦的是另一类命令，拒绝时要写的出路不同\necho "拦 Bash 里的另一种写法"\n' > "$overlap_repository/.claude/hooks/new-guard.sh"
run_scripted "gate-overlap/新钩子没写 hook-events 判红" 1 "没写 hook-events" -- "${overlap_check[@]}" "$overlap_repository"
# 事件不同、matcher 不相交，都不算同一个触发点
printf '#!/usr/bin/env bash\n# hook-events: PreToolUse\n# gate-similar: 无 查过全表，没有管同一件事的\necho "拦 Edit 里的一种写法"\n' > "$overlap_repository/.claude/hooks/new-guard.sh"
overlap_settings PreToolUse Edit
run_scripted "gate-overlap/matcher 不相交的钩子写「无」可以" 0 "new-guard.sh" -- "${overlap_check[@]}" "$overlap_repository"
printf '#!/usr/bin/env bash\n# hook-events: PostToolUse\n# gate-similar: 无 查过全表，没有管同一件事的\necho "Bash 跑完之后记一笔"\n' > "$overlap_repository/.claude/hooks/new-guard.sh"
overlap_settings PostToolUse Bash
run_scripted "gate-overlap/事件不同的钩子写「无」可以" 0 "new-guard.sh" -- "${overlap_check[@]}" "$overlap_repository"
rm -f "$overlap_repository/.claude/hooks/new-guard.sh"
# 钩子不在 .claude/hooks/、也不是 .sh：注册命令指到它，它就是钩子
mkdir -p "$overlap_repository/.claude/tools"
printf '# 拦 Bash 里的另一种写法\nprint("拦")\n' > "$overlap_repository/.claude/tools/new-guard.py"
overlap_settings PreToolUse Bash 'python3 \"$CLAUDE_PROJECT_DIR\"/.claude/tools/new-guard.py'
run_scripted "gate-overlap/注册命令指到的别处的钩子也判" 1 ".claude/tools/new-guard.py 是新加的，没写 gate-similar" -- "${overlap_check[@]}" "$overlap_repository"
# python 的文档串同注释：像的字样只在文档串里，不算字面上很像
{ printf '# hook-events: PreToolUse\n# gate-similar: old-guard.sh 它拦的是另一类命令，拒绝时要写的出路不同\n'
  printf '"""说明里提到 check_column gate-stage bash %s"""\n' "$(rich_identifiers)"; printf 'print("%s")\n' "$(other_identifiers)"; } > "$overlap_repository/.claude/tools/new-guard.py"
run_scripted "gate-overlap/只在文档串里像的不算字面上很像" 0 "new-guard.py" -- "${overlap_check[@]}" "$overlap_repository"
rm -rf "${overlap_repository:?}/.claude/tools"; overlap_settings PostToolUse Bash
run_scripted "gate-overlap/外层的 diff 基准漏进来判不了" 3 "解析不到提交" -- \
  env GATE_DIFF_BASE=0000000000000000000000000000000000000000 python3 "$SCRIPTS/gate-overlap.py" "$overlap_repository"
mkdir -p "$temporary_directory/overlap-no-git/.claude/gate.d"
run_scripted "gate-overlap/不在 git 仓里退 77" 77 "不在 git 仓里" -- python3 "$SCRIPTS/gate-overlap.py" "$temporary_directory/overlap-no-git"
# 项目登记了自定义门禁目录与钩子目录（rules/sop-first.md）：新加的门禁要去那里找，不是默认的 .claude/gate.d。
# 不读登记的话，scripts/gates/ 下的新文件不算门禁，这一轮会报「没有新加或改动门禁与钩子」而不是「没写 gate-similar」
overlap_repository="$temporary_directory/gate-overlap-registered-directory"; mkdir -p "$overlap_repository/scripts/gates" "$overlap_repository/.claude"
git -C "$overlap_repository" init -q
printf 'scripts/gates  # 工程脚本统一挪进项目仓根 scripts/\n' > "$overlap_repository/.claude/gate-directory"
printf '#!/usr/bin/env bash\n# gate-stage: 已有的样本阶段\necho 已有\n' > "$overlap_repository/scripts/gates/10-existing.sh"
git -C "$overlap_repository" add -A; git -C "$overlap_repository" -c user.name=t -c user.email=t@t commit -qm base
printf '#!/usr/bin/env bash\n# gate-stage: 新阶段\necho 新\n' > "$overlap_repository/scripts/gates/20-new.sh"
run_scripted "gate-overlap/登记了自定义门禁目录就在那里找新加的" 1 "scripts/gates/20-new.sh 是新加的，没写 gate-similar" -- \
  env GATE_DIFF_BASE="$(git -C "$overlap_repository" rev-parse HEAD)" python3 "$SCRIPTS/gate-overlap.py" "$overlap_repository"

# ── 收工钩子：agent 这一轮新建了门禁或钩子，收工前先自检能不能复用已有的 ──
run_scripted "gate-reuse-check/自证的每种情形都判得对" 0 "gate-reuse-check 自证：15 种情形判得都对" -- \
  bash "$SCRIPTS/claude-hooks/gate-reuse-check.sh" --selftest

# ── 历史条目编号：本次新增的条目撞了已有的号 ──────────────
history_repository="$temporary_directory/history-ordinal"; mkdir -p "$history_repository/.claude/kb"
git -C "$history_repository" init -q
printf '# 变更史\n\n### 2026-09-17（其一）：建档\n- 起点。\n' > "$history_repository/.claude/kb/decisions-history.md"
git -C "$history_repository" add -A; git -C "$history_repository" -c user.name=t -c user.email=t@t commit -qm init
run_scripted "history-ordinal/没有新增条目时通过" 0 "没有撞号" -- \
  bash "$SCRIPTS/history-ordinal.sh" "$history_repository"
printf '\n### 2026-09-17（其一）：又一条\n- 撞号了。\n' >> "$history_repository/.claude/kb/decisions-history.md"
run_scripted "history-ordinal/新增的条目撞号判红" 1 "处撞号" -- \
  bash "$SCRIPTS/history-ordinal.sh" "$history_repository"
# 用相对路径起它：cd 到仓根之后，键提取器照样要找得到
run_scripted "history-ordinal/相对路径起也找得到键提取器" 1 "处撞号" -- \
  bash -c 'cd "$1" && bash scripts/history-ordinal.sh "$2"' history_ordinal_relative "$SCRIPTS/.." "$history_repository"
run_scripted "history-ordinal/没有变更史文件退 77" 77 "" -- \
  bash "$SCRIPTS/history-ordinal.sh" "$temporary_directory"
# 窗口按这一轮的 diff 基准算，不只和 HEAD 比：撞号的条目先提交、再跑门禁，只和 HEAD 比就落在窗口外看不见
history_repository="$temporary_directory/history-committed"; mkdir -p "$history_repository/.claude/kb"; git -C "$history_repository" init -q
printf '# 变更史\n\n### 2026-09-17（其一）：建档\n- 起点。\n' > "$history_repository/.claude/kb/decisions-history.md"
git -C "$history_repository" add -A; git -C "$history_repository" -c user.name=t -c user.email=t@t commit -qm init
history_diff_base_commit="$(git -C "$history_repository" rev-parse HEAD)"
printf '\n### 2026-09-17（其一）：又一条\n- 先提交了再跑门禁。\n' >> "$history_repository/.claude/kb/decisions-history.md"
git -C "$history_repository" add -A; git -C "$history_repository" -c user.name=t -c user.email=t@t commit -qm 撞号
run_scripted "history-ordinal/撞号先提交再跑也看得见" 1 "处撞号" -- env GATE_DIFF_BASE="$history_diff_base_commit" bash "$SCRIPTS/history-ordinal.sh" "$history_repository"
run_scripted "history-ordinal/外层的 diff 基准解析不到就判不了" 1 "在这个仓里解析不到提交" -- \
  env GATE_DIFF_BASE=0000000000000000000000000000000000000000 bash "$SCRIPTS/history-ordinal.sh" "$history_repository"
# 搬进实验史新文件的存量撞号不是新撞号：基准那一侧的清单漏了 experiments-history/ 的话，搬过去的条目全被当成新写的
history_repository="$temporary_directory/history-moved-experiments"; mkdir -p "$history_repository/.claude/kb/experiments-history"; git -C "$history_repository" init -q
printf '# 实验史\n\n### 2026-09-10（其一）：甲\n- 存量。\n\n### 2026-09-10（其一）：乙\n- 存量撞号。\n' > "$history_repository/.claude/kb/experiments-history/2026-08.md"
git -C "$history_repository" add -A; git -C "$history_repository" -c user.name=t -c user.email=t@t commit -qm init
git -C "$history_repository" mv .claude/kb/experiments-history/2026-08.md .claude/kb/experiments-history/2026-09.md
run_scripted "history-ordinal/搬进实验史新文件的存量撞号不算新撞号" 0 "没有撞号" "存量 1 处撞号" -- bash "$SCRIPTS/history-ordinal.sh" "$history_repository"
run_scripted "history-ordinal/仓根不在要给出路" 1 "找不到仓根" -- bash "$SCRIPTS/history-ordinal.sh" "$temporary_directory/history-no-such-root"
# 登记了自定义 kb 目录（rules/kb-discipline.md）：默认的 .claude/kb 不存在也不报「无对象可判」，扫登记的那个目录
history_repository="$temporary_directory/history-registered-kb-directory"; mkdir -p "$history_repository/crates/checker/invariants" "$history_repository/.claude"; git -C "$history_repository" init -q
printf 'crates/checker/invariants  # 不变量挪到 checker 旁边\n' > "$history_repository/.claude/kb-directories"
printf '# 不变量变更史\n\n### 2026-09-17（其一）：建档\n- 起点。\n' > "$history_repository/crates/checker/invariants/history.md"
git -C "$history_repository" add -A; git -C "$history_repository" -c user.name=t -c user.email=t@t commit -qm init
printf '\n### 2026-09-17（其一）：又一条\n- 撞号了。\n' >> "$history_repository/crates/checker/invariants/history.md"
run_scripted "history-ordinal/登记了自定义 kb 目录就扫那里" 1 "处撞号" -- \
  bash "$SCRIPTS/history-ordinal.sh" "$history_repository"

# ── 本地阶段判别力：项目在 .claude/gate.d/ 里接的阶段，自己会不会红 ──
stage_selftest_project="$temporary_directory/stage-selftest"; mkdir -p "$stage_selftest_project/.claude/gate.d/fixtures/10-demo.sh/red" "$stage_selftest_project/.claude/gate.d/fixtures/10-demo.sh/green"
# 样本阶段里不写 ✗ / ✓：gate-lint 扫的是本文件的字面，写了就成了「一处没有出路的拒绝」
printf '#!/usr/bin/env bash\n[[ -f "${1:-.}/bad.txt" ]] && { echo "  拒绝：有 bad.txt"; exit 1; }\necho "  通过：没有 bad.txt"\n' > "$stage_selftest_project/.claude/gate.d/10-demo.sh"
printf 'exit=1\nwant=有 bad.txt\n' > "$stage_selftest_project/.claude/gate.d/fixtures/10-demo.sh/red/expect"
: > "$stage_selftest_project/.claude/gate.d/fixtures/10-demo.sh/red/bad.txt"
printf 'exit=0\n' > "$stage_selftest_project/.claude/gate.d/fixtures/10-demo.sh/green/expect"
run_scripted "stage-selftest/样本判得对就通过" 0 "有用例的阶段判得都对" -- \
  bash "$SCRIPTS/stage-selftest.sh" "$stage_selftest_project/.claude/gate.d"
# 外层 gate.sh 导出的 GATE_DIFF_BASE 是真仓的提交号，漏进样本就成了临时仓里不存在的提交：样本看得到它就判错
printf '#!/usr/bin/env bash\n[[ -n "${GATE_DIFF_BASE:-}" ]] && { echo "  拒绝：看得到外层的基准"; exit 1; }\n[[ -f "${1:-.}/bad.txt" ]] && { echo "  拒绝：有 bad.txt"; exit 1; }\necho "  通过：没有 bad.txt"\n' > "$stage_selftest_project/.claude/gate.d/10-demo.sh"
run_scripted "stage-selftest/样本看不到外层的 GATE_DIFF_BASE" 0 "有用例的阶段判得都对" -- \
  env GATE_DIFF_BASE=0000000000000000000000000000000000000000 bash "$SCRIPTS/stage-selftest.sh" "$stage_selftest_project/.claude/gate.d"
# 阶段坏成恒绿时必须红：把那个阶段改成永远 exit 0，红样本当场判错
printf '#!/usr/bin/env bash\necho "  通过：没有 bad.txt"\n' > "$stage_selftest_project/.claude/gate.d/10-demo.sh"
run_scripted "stage-selftest/阶段变恒绿时判红" 1 "期望退出 1，实测 0" -- \
  bash "$SCRIPTS/stage-selftest.sh" "$stage_selftest_project/.claude/gate.d"
# red / green 之外、带 expect 的样本目录也要跑：摆一个目录名不是 red / green、期望又写错了的样本，它必须判错
printf '#!/usr/bin/env bash\n[[ -f "${1:-.}/bad.txt" ]] && { echo "  拒绝：有 bad.txt"; exit 1; }\necho "  通过：没有 bad.txt"\n' > "$stage_selftest_project/.claude/gate.d/10-demo.sh"
mkdir -p "$stage_selftest_project/.claude/gate.d/fixtures/10-demo.sh/third"; : > "$stage_selftest_project/.claude/gate.d/fixtures/10-demo.sh/third/bad.txt"
printf 'exit=0\n' > "$stage_selftest_project/.claude/gate.d/fixtures/10-demo.sh/third/expect"
run_scripted "stage-selftest/red 与 green 之外的样本目录也跑" 1 "third            期望退出 0，实测 1" -- \
  bash "$SCRIPTS/stage-selftest.sh" "$stage_selftest_project/.claude/gate.d"
rm -f "$stage_selftest_project/.claude/gate.d/fixtures/10-demo.sh/third/expect"
run_scripted "stage-selftest/样本目录没有 expect 要判错" 1 "样本目录里没有 expect" -- \
  bash "$SCRIPTS/stage-selftest.sh" "$stage_selftest_project/.claude/gate.d"
rm -rf "${stage_selftest_project:?}/.claude/gate.d/fixtures/10-demo.sh/third"
# 新形态：一道阶段一个目录 <门禁目录>/<名>/<名>.sh，用例是同目录下的 *.case.sh，头部写 expect-exit / expect-want
stage_selftest_project="$temporary_directory/stage-selftest-nested"; mkdir -p "$stage_selftest_project/.claude/gate.d/my-stage"
printf '#!/usr/bin/env bash\n[[ -f "${1:-.}/bad.txt" ]] && { echo "  拒绝：有 bad.txt"; exit 1; }\necho "  通过：没有 bad.txt"\n' > "$stage_selftest_project/.claude/gate.d/my-stage/my-stage.sh"
printf '#!/usr/bin/env bash\n# expect-exit: 1\n# expect-want: 有 bad.txt\ntouch bad.txt\n' > "$stage_selftest_project/.claude/gate.d/my-stage/red.case.sh"
printf '#!/usr/bin/env bash\n# expect-exit: 0\n' > "$stage_selftest_project/.claude/gate.d/my-stage/green.case.sh"
run_scripted "stage-selftest/新形态：嵌套阶段配同目录下的用例就通过" 0 "有用例的阶段判得都对（2 个用例）" -- \
  bash "$SCRIPTS/stage-selftest.sh" "$stage_selftest_project/.claude/gate.d"
run_scripted "stage-selftest/新形态：--list-items 认嵌套阶段" 0 my-stage -- \
  bash "$SCRIPTS/stage-selftest.sh" "$stage_selftest_project/.claude/gate.d" --list-items
# 新旧两种形态同时存在时各自判各自的
cp -r "$stage_selftest_project/.claude/gate.d/my-stage" "$stage_selftest_project/.claude/gate.d/my-stage-copy"
mv "$stage_selftest_project/.claude/gate.d/my-stage-copy/my-stage.sh" "$stage_selftest_project/.claude/gate.d/my-stage-copy/my-stage-copy.sh"
mkdir -p "$stage_selftest_project/.claude/gate.d/fixtures/10-demo.sh/red" "$stage_selftest_project/.claude/gate.d/fixtures/10-demo.sh/green"
printf '#!/usr/bin/env bash\n[[ -f "${1:-.}/bad.txt" ]] && { echo "  拒绝：有 bad.txt"; exit 1; }\necho "  通过：没有 bad.txt"\n' > "$stage_selftest_project/.claude/gate.d/10-demo.sh"
printf 'exit=1\nwant=有 bad.txt\n' > "$stage_selftest_project/.claude/gate.d/fixtures/10-demo.sh/red/expect"
: > "$stage_selftest_project/.claude/gate.d/fixtures/10-demo.sh/red/bad.txt"
printf 'exit=0\n' > "$stage_selftest_project/.claude/gate.d/fixtures/10-demo.sh/green/expect"
run_scripted "stage-selftest/新旧两种形态过渡期并存" 0 "有用例的阶段判得都对（6 个用例）" -- \
  bash "$SCRIPTS/stage-selftest.sh" "$stage_selftest_project/.claude/gate.d"
# 用例文件没写 # expect-exit: 判不了该红还是该绿，要判错
printf '#!/usr/bin/env bash\ntouch bad.txt\n' > "$stage_selftest_project/.claude/gate.d/my-stage/malformed.case.sh"
run_scripted "stage-selftest/新形态：用例没写 expect-exit 要判错" 1 "malformed" "用例文件没写 # expect-exit" -- \
  bash "$SCRIPTS/stage-selftest.sh" "$stage_selftest_project/.claude/gate.d" --item my-stage
# 没有本地阶段目录、或目录里没有阶段时退 77（本次无对象可判），不许报绿，而且要说出是哪一种：gate.sh 的跳过说明让人看它的输出
run_scripted "stage-selftest/没有本地阶段目录退 77 并说出来" 77 "没有门禁目录" "这不是通过" -- \
  bash "$SCRIPTS/stage-selftest.sh" "$temporary_directory/stage-selftest-none"
mkdir -p "$temporary_directory/stage-selftest-empty"
run_scripted "stage-selftest/阶段目录里没有阶段退 77 并说出来" 77 "下没有本地阶段（扁平的" "这不是通过" -- \
  bash "$SCRIPTS/stage-selftest.sh" "$temporary_directory/stage-selftest-empty"
# 写了准入与运行条件的阶段带 --force 喂样本：它的条件（这里是一条永远不满足的）不挡判别力自证（rules/preflight-discipline.md）
stage_selftest_project="$temporary_directory/stage-selftest-conditions"; mkdir -p "$stage_selftest_project/.claude/gate.d/fixtures/10-demo.sh/red" "$stage_selftest_project/.claude/gate.d/fixtures/10-demo.sh/green" "$stage_selftest_project/.claude/singlefs-ai-sop/scripts"
cp "$SCRIPTS/lib.sh" "$SCRIPTS/preflight.py" "$SCRIPTS/preflight.sh" "$SCRIPTS/proc.py" "$stage_selftest_project/.claude/singlefs-ai-sop/scripts/"
printf '#!/usr/bin/env bash\n# admission: always 样本：每次调都有意义\n# run-condition: check false :: 样本：这条条件永远不满足\nsource "$(dirname "${BASH_SOURCE[0]}")/../singlefs-ai-sop/scripts/lib.sh"\npreflight "${BASH_SOURCE[0]}" "$@"; set -- ${PREFLIGHT_ARGUMENTS[@]+"${PREFLIGHT_ARGUMENTS[@]}"}\n[[ -f "${1:-.}/bad.txt" ]] && { echo "  拒绝：有 bad.txt"; exit 1; }\necho "  通过：没有 bad.txt"\n' > "$stage_selftest_project/.claude/gate.d/10-demo.sh"
printf 'exit=1\nwant=有 bad.txt\n' > "$stage_selftest_project/.claude/gate.d/fixtures/10-demo.sh/red/expect"
: > "$stage_selftest_project/.claude/gate.d/fixtures/10-demo.sh/red/bad.txt"
printf 'exit=0\n' > "$stage_selftest_project/.claude/gate.d/fixtures/10-demo.sh/green/expect"
run_scripted "stage-selftest/写了条件的阶段带 --force 喂样本" 0 "有用例的阶段判得都对" -- \
  bash "$SCRIPTS/stage-selftest.sh" "$stage_selftest_project/.claude/gate.d"
# 没配样本的阶段逐个用 report_not_run 报出来（门禁下进汇总的「本次未跑」），不只在这一段里 warn 一句
stage_selftest_project="$temporary_directory/stage-selftest-no-case"; mkdir -p "$stage_selftest_project/.claude/gate.d/fixtures/10-demo.sh/red" "$stage_selftest_project/.claude/gate.d/fixtures/10-demo.sh/green"
printf '#!/usr/bin/env bash\n[[ -f "${1:-.}/bad.txt" ]] && { echo "  拒绝：有 bad.txt"; exit 1; }\necho "  通过：没有 bad.txt"\n' > "$stage_selftest_project/.claude/gate.d/10-demo.sh"
printf 'exit=1\nwant=有 bad.txt\n' > "$stage_selftest_project/.claude/gate.d/fixtures/10-demo.sh/red/expect"
: > "$stage_selftest_project/.claude/gate.d/fixtures/10-demo.sh/red/bad.txt"
printf 'exit=0\n' > "$stage_selftest_project/.claude/gate.d/fixtures/10-demo.sh/green/expect"
printf '#!/usr/bin/env bash\necho "  通过：没有样本的阶段"\n' > "$stage_selftest_project/.claude/gate.d/20-nosample.sh"
run_scripted "stage-selftest/没有样本的阶段逐个报本次未跑" 0 "本次未跑（这不是通过）：20-nosample.sh 没有判别力用例" -- \
  bash "$SCRIPTS/stage-selftest.sh" "$stage_selftest_project/.claude/gate.d"
# 一个阶段都没配样本：一个样本都没判，是无对象可判，不许报「判得都对」
stage_selftest_project="$temporary_directory/stage-selftest-no-samples"; mkdir -p "$stage_selftest_project/.claude/gate.d/fixtures"
printf '#!/usr/bin/env bash\necho "  通过"\n' > "$stage_selftest_project/.claude/gate.d/10-demo.sh"
run_scripted "stage-selftest/一个阶段都没配样本退 77" 77 "一个用例都没判" -- bash "$SCRIPTS/stage-selftest.sh" "$stage_selftest_project/.claude/gate.d"
# --item 只喂点名那几道：另摆一道坏成恒绿的阶段，没点名它时整趟要绿（证明它没被起），点名它时要红
stage_selftest_project="$temporary_directory/stage-selftest-item"; mkdir -p "$stage_selftest_project/.claude/gate.d/fixtures/10-demo.sh/red" "$stage_selftest_project/.claude/gate.d/fixtures/10-demo.sh/green" "$stage_selftest_project/.claude/gate.d/fixtures/30-broken.sh/red"
printf '#!/usr/bin/env bash\n[[ -f "${1:-.}/bad.txt" ]] && { echo "  拒绝：有 bad.txt"; exit 1; }\necho "  通过：没有 bad.txt"\n' > "$stage_selftest_project/.claude/gate.d/10-demo.sh"
printf 'exit=1\nwant=有 bad.txt\n' > "$stage_selftest_project/.claude/gate.d/fixtures/10-demo.sh/red/expect"
: > "$stage_selftest_project/.claude/gate.d/fixtures/10-demo.sh/red/bad.txt"
printf 'exit=0\n' > "$stage_selftest_project/.claude/gate.d/fixtures/10-demo.sh/green/expect"
printf '#!/usr/bin/env bash\necho "  通过：恒绿"\n' > "$stage_selftest_project/.claude/gate.d/30-broken.sh"
printf 'exit=1\nwant=有 bad.txt\n' > "$stage_selftest_project/.claude/gate.d/fixtures/30-broken.sh/red/expect"
: > "$stage_selftest_project/.claude/gate.d/fixtures/30-broken.sh/red/bad.txt"
printf '#!/usr/bin/env bash\necho "  通过：没有样本的阶段"\n' > "$stage_selftest_project/.claude/gate.d/20-nosample.sh"
run_scripted "stage-selftest/--item 只喂点名的阶段" 0 "点名的 1 道阶段判得都对（2 个用例）：10-demo.sh" -- \
  bash "$SCRIPTS/stage-selftest.sh" "$stage_selftest_project/.claude/gate.d" --item 10-demo.sh
run_scripted "stage-selftest/--item 点名坏阶段要红" 1 "30-broken.sh                 red              期望退出 1，实测 0" -- \
  bash "$SCRIPTS/stage-selftest.sh" "$stage_selftest_project/.claude/gate.d" --item 30-broken.sh
run_scripted "stage-selftest/--item 写错退 2 并列出可点名的阶段" 2 "--item nope.sh：" "       10-demo.sh" "       30-broken.sh" -- \
  bash "$SCRIPTS/stage-selftest.sh" "$stage_selftest_project/.claude/gate.d" --item nope.sh
run_scripted "stage-selftest/--item 缺阶段名退 2" 2 "--item （缺阶段名）" -- \
  bash "$SCRIPTS/stage-selftest.sh" "$stage_selftest_project/.claude/gate.d" --item
run_scripted "stage-selftest/--list-items 只列配了样本的阶段" 0 "10-demo.sh" "30-broken.sh" -- \
  bash "$SCRIPTS/stage-selftest.sh" "$stage_selftest_project/.claude/gate.d" --list-items

# ── 脚本执行位：暂存区里丢了可执行位，工作区那份还是可执行的 ──────
# 手工暂存时写死 100644 就是这个形态，而在工作区上跑的门禁一声不吭。
script_modes_repository="$temporary_directory/script-modes"; mkdir -p "$script_modes_repository/scripts"
git -C "$script_modes_repository" init -q
printf '#!/usr/bin/env bash\necho hi\n' > "$script_modes_repository/scripts/tool.sh"; chmod +x "$script_modes_repository/scripts/tool.sh"
git -C "$script_modes_repository" add -A; git -C "$script_modes_repository" -c user.name=t -c user.email=t@t commit -qm init
run_scripted "script-modes/模式与工作区一致时通过" 0 "暂存区里的模式与工作区一致" -- \
  bash "$SCRIPTS/script-modes.sh" "$script_modes_repository/scripts"
git -C "$script_modes_repository" update-index --chmod=-x scripts/tool.sh
run_scripted "script-modes/暂存区里丢了执行位判红" 1 ".sh 要可执行" -- \
  bash "$SCRIPTS/script-modes.sh" "$script_modes_repository/scripts"
# 射程写窄到一个脚本都没有时，不许报绿（rules/show-me-test.md：扫到 0 项也不是通过）
mkdir -p "$script_modes_repository/empty"
run_scripted "script-modes/扫到 0 个脚本判红" 1 "一个已跟踪的 .sh / .py 都没查到" -- \
  bash "$SCRIPTS/script-modes.sh" "$script_modes_repository/empty"
# 射程可能跨两个 git 仓：gate.sh --staged 把项目摊在临时 worktree 里，而装进来的 SOP 副本仍在真仓。
# 拿射程里排在最前的那个目录的仓根去 ls-files 另一个仓里的路径，git 直接 fatal、输出为空，这一条就报「一个都没查到」。
# 先还原 scripts/tool.sh 所在那个仓的执行位（「暂存区里丢了执行位判红」那一例改坏的），否则这一条永远红，测不到跨仓那件事
git -C "$script_modes_repository" update-index --chmod=+x scripts/tool.sh
other_script_modes_repository="$temporary_directory/script-modes-other"; mkdir -p "$other_script_modes_repository/tools"
git -C "$other_script_modes_repository" init -q
printf '#!/usr/bin/env bash\necho hi\n' > "$other_script_modes_repository/tools/other.sh"; chmod +x "$other_script_modes_repository/tools/other.sh"
git -C "$other_script_modes_repository" add -A; git -C "$other_script_modes_repository" -c user.name=t -c user.email=t@t commit -qm init
run_scripted "script-modes/射程跨两个仓时两边都查" 0 "查了 2 个脚本" -- \
  bash "$SCRIPTS/script-modes.sh" "$script_modes_repository/scripts" "$other_script_modes_repository/tools"
git -C "$other_script_modes_repository" update-index --chmod=-x tools/other.sh
run_scripted "script-modes/跨仓时第二个仓的红也要报出来" 1 "tools/other.sh" -- \
  bash "$SCRIPTS/script-modes.sh" "$script_modes_repository/scripts" "$other_script_modes_repository/tools"
# 射程里判不了的目录要逐个报出来，不能因为别的目录查到了东西就不吭声（项目里被 .gitignore 挡着的副本那一格每次都是 0 项）
script_modes_repository="$temporary_directory/script-modes"; mkdir -p "$temporary_directory/script-modes-outside-git"
run_scripted "script-modes/射程里不在 git 仓的目录要报出来" 0 "脚本执行位：$temporary_directory/script-modes-outside-git（不在 git 仓里）" -- \
  bash "$SCRIPTS/script-modes.sh" "$script_modes_repository/scripts" "$temporary_directory/script-modes-outside-git"
mkdir -p "$script_modes_repository/ignored-copy"; printf 'ignored-copy/\n' > "$script_modes_repository/.gitignore"; printf '#!/usr/bin/env bash\necho hi\n' > "$script_modes_repository/ignored-copy/tool.sh"
run_scripted "script-modes/射程里一个已跟踪脚本都没有的目录要报出来" 0 "$script_modes_repository/ignored-copy（一个已跟踪的 .sh / .py 都没有" -- \
  bash "$SCRIPTS/script-modes.sh" "$script_modes_repository/scripts" "$script_modes_repository/ignored-copy"
# 空目录 git 存不下：工作区里靠它过的样本，到了提交与 --staged 的临时树里就没有那个目录
mkdir -p "$script_modes_repository/scripts/fixtures/sample/rules"
run_scripted "script-modes/射程里有空目录判红" 1 "$script_modes_repository/scripts/fixtures/sample/rules 是空目录" "1 个空目录" -- \
  bash "$SCRIPTS/script-modes.sh" "$script_modes_repository/scripts"
: > "$script_modes_repository/scripts/fixtures/sample/rules/.keep"
run_scripted "script-modes/空目录放了 .keep 就通过" 0 "没有空目录" -- \
  bash "$SCRIPTS/script-modes.sh" "$script_modes_repository/scripts"
printf 'scripts/build-cache/\n' >> "$script_modes_repository/.gitignore"; mkdir -p "$script_modes_repository/scripts/build-cache"
run_scripted "script-modes/被 .gitignore 挡着的空目录不判" 0 "没有空目录" -- \
  bash "$SCRIPTS/script-modes.sh" "$script_modes_repository/scripts"
# 符号链接形式的阶段：判它在暂存区里指向的那一份。链接本身的模式是 120000，判成「.sh 要可执行」的话给的出路对链接不起作用
make_linked_stage_repository() { # make_linked_stage_repository <目录> <指向的脚本在暂存区里的模式：+x 或 -x>
  git -C "$1" init -q 2>/dev/null || { mkdir -p "$1" && git -C "$1" init -q; }
  mkdir -p "$1/.claude/gate.d" "$1/.claude/stages"
  printf '#!/usr/bin/env bash\necho probe\n' > "$1/.claude/stages/probe.sh"; chmod +x "$1/.claude/stages/probe.sh"
  ln -s ../stages/probe.sh "$1/.claude/gate.d/65-linked.sh"
  git -C "$1" add -A; git -C "$1" update-index --chmod="$2" .claude/stages/probe.sh
}
linked_stage_repository="$temporary_directory/script-modes-link-ok"; mkdir -p "$linked_stage_repository"; make_linked_stage_repository "$linked_stage_repository" +x
run_scripted "script-modes/符号链接判它指向的那一份（可执行就过）" 0 "查了 1 个脚本" -- bash "$SCRIPTS/script-modes.sh" "$linked_stage_repository/.claude/gate.d"
linked_stage_repository="$temporary_directory/script-modes-link-bad"; mkdir -p "$linked_stage_repository"; make_linked_stage_repository "$linked_stage_repository" -x
run_scripted "script-modes/符号链接指向的那一份不可执行要红" 1 "指向的 .claude/stages/probe.sh 在暂存区里是 100644" -- bash "$SCRIPTS/script-modes.sh" "$linked_stage_repository/.claude/gate.d"

# 日期的下界只在被查目录本身是 git 仓顶层时才问 git。不这么限，`git -C` 会一路往上找：
# 目录嵌在一个更晚才开始的仓里时（SOP 副本放在项目的 .claude/ 下就是这种形状），拿外层仓的第一个提交当下界，
# 真日期会被判成不可能。这里造一个 2026-09-15 才开始的外层仓，里面的子目录写着 2026-09-01：
# 按外层仓算早出了 7 天的宽限，按这个包的起点算在宽限之内。
date_scenario_directory="$temporary_directory/date-walkup"; mkdir -p "$date_scenario_directory/outer/sub/kb"
git -C "$date_scenario_directory/outer" init -q
printf '起点\n' > "$date_scenario_directory/outer/README.md"; git -C "$date_scenario_directory/outer" add -A
GIT_AUTHOR_DATE="2026-09-15T00:00:00" GIT_COMMITTER_DATE="2026-09-15T00:00:00" \
  git -C "$date_scenario_directory/outer" -c user.name=t -c user.email=t@t commit -qm 起点
printf '# 决策\n\n正文只写现状。\n\n## 历史版本\n\n### 2026-09-01\n- 建档。\n' > "$date_scenario_directory/outer/sub/kb/a.md"
run_scripted "doc-lint/日期下界不往上找外层仓" 0 "文档铁律检查通过" -- \
  env DOC_LINT_LANG=zh bash "$SCRIPTS/doc-lint.sh" "$date_scenario_directory/outer/sub"

# 下界从第一个提交往前宽限 7 天：git init 之前做的工作会带着当时的日期进第一个提交。
# 两例钉住宽限的两边：之内放行，之外照样判红。
date_scenario_directory="$temporary_directory/date-grace"
for grace_side in within beyond; do
  mkdir -p "$date_scenario_directory/$grace_side/kb"; git -C "$date_scenario_directory/$grace_side" init -q
  printf '起点\n' > "$date_scenario_directory/$grace_side/README.md"; git -C "$date_scenario_directory/$grace_side" add -A
  GIT_AUTHOR_DATE="2026-09-15T00:00:00" GIT_COMMITTER_DATE="2026-09-15T00:00:00" \
    git -C "$date_scenario_directory/$grace_side" -c user.name=t -c user.email=t@t commit -qm 起点
done
printf '# 决策\n\n正文只写现状。\n\n## 历史版本\n\n### 2026-09-10\n- 建档。\n' > "$date_scenario_directory/within/kb/a.md"
printf '# 决策\n\n正文只写现状。\n\n## 历史版本\n\n### 2026-09-05\n- 建档。\n' > "$date_scenario_directory/beyond/kb/a.md"
run_scripted "doc-lint/第一个提交之前 7 天以内的日期放行" 0 "文档铁律检查通过" -- \
  env DOC_LINT_LANG=zh bash "$SCRIPTS/doc-lint.sh" "$date_scenario_directory/within"
run_scripted "doc-lint/早于第一个提交 7 天以上的日期判红" 1 "早于这个仓第一个提交（2026-09-15）7 天以上" -- \
  env DOC_LINT_LANG=zh bash "$SCRIPTS/doc-lint.sh" "$date_scenario_directory/beyond"

# 「今天」按最晚的时区（UTC+14）算。本机时钟是 UTC、人在东京时，东京凌晨写下的当天日期比 UTC 的今天晚一天。
# 用一个假 date 把时钟钉住：本机时钟上是 2026-09-16，UTC+14 已是 2026-09-17。退回只看本机时钟，「东京已到的日期放行」那一例就红。
date_scenario_directory="$temporary_directory/date-latest-zone"; mkdir -p "$date_scenario_directory/bin" "$date_scenario_directory/today/kb" "$date_scenario_directory/tomorrow/kb"
printf '#!/usr/bin/env bash\nif [[ "${1:-}" == "+%%F" ]]; then\n  case "${TZ:-}" in UTC-14|Etc/GMT-14) echo 2026-09-17 ;; *) echo 2026-09-16 ;; esac; exit 0\nfi\nexec %q "$@"\n' \
  "$(command -v date)" > "$date_scenario_directory/bin/date"
chmod +x "$date_scenario_directory/bin/date"
printf '# 决策\n\n正文只写现状。\n\n## 历史版本\n\n### 2026-09-17\n- 建档。\n' > "$date_scenario_directory/today/kb/a.md"
printf '# 决策\n\n正文只写现状。\n\n## 历史版本\n\n### 2026-09-18\n- 建档。\n' > "$date_scenario_directory/tomorrow/kb/a.md"
run_scripted "doc-lint/今天按最晚的时区算，东京已到的日期放行" 0 "文档铁律检查通过" -- \
  env PATH="$date_scenario_directory/bin:$PATH" DOC_LINT_LANG=zh bash "$SCRIPTS/doc-lint.sh" "$date_scenario_directory/today"
run_scripted "doc-lint/比最晚时区的今天还晚就判红" 1 "晚于今天（2026-09-17，按最晚的时区算）" -- \
  env PATH="$date_scenario_directory/bin:$PATH" DOC_LINT_LANG=zh bash "$SCRIPTS/doc-lint.sh" "$date_scenario_directory/tomorrow"

# 下界靠 date -d 做减法。不认 -d 的 date 算不出下界，下界要是静默变空，2026-01-01 就放行了：停下来说清楚。
date_scenario_directory="$temporary_directory/date-no-minus-d"; mkdir -p "$date_scenario_directory/bin" "$date_scenario_directory/project/kb"
printf '#!/usr/bin/env bash\nfor argument in "$@"; do [[ "$argument" == -d ]] && { echo "date: illegal option -- d" >&2; exit 1; }; done\nexec %q "$@"\n' \
  "$(command -v date)" > "$date_scenario_directory/bin/date"
chmod +x "$date_scenario_directory/bin/date"
printf '# 决策\n\n正文只写现状。\n\n## 历史版本\n\n### 2026-01-01\n- 建档。\n' > "$date_scenario_directory/project/kb/a.md"
run_scripted "doc-lint/date 不认 -d 时停下，不许静默放过" 1 "这台机器的 date 不认 -d" -- \
  env PATH="$date_scenario_directory/bin:$PATH" DOC_LINT_LANG=zh bash "$SCRIPTS/doc-lint.sh" "$date_scenario_directory/project"

# 浅克隆里「第一个提交」是截断处：拿它当下界，项目越老误判越多。这里完整历史从 2026-09-01 开始，浅克隆只看得到 2026-09-16。
date_scenario_directory="$temporary_directory/date-shallow"; mkdir -p "$date_scenario_directory/full"; git -C "$date_scenario_directory/full" init -q
printf '起点\n' > "$date_scenario_directory/full/README.md"; git -C "$date_scenario_directory/full" add -A
GIT_AUTHOR_DATE="2026-09-01T00:00:00" GIT_COMMITTER_DATE="2026-09-01T00:00:00" \
  git -C "$date_scenario_directory/full" -c user.name=t -c user.email=t@t commit -qm 起点
printf '又一行\n' >> "$date_scenario_directory/full/README.md"; git -C "$date_scenario_directory/full" add -A
GIT_AUTHOR_DATE="2026-09-16T00:00:00" GIT_COMMITTER_DATE="2026-09-16T00:00:00" \
  git -C "$date_scenario_directory/full" -c user.name=t -c user.email=t@t commit -qm 又一行
git clone -q --depth 1 "file://$date_scenario_directory/full" "$date_scenario_directory/shallow" 2>/dev/null
mkdir -p "$date_scenario_directory/shallow/kb"
printf '# 决策\n\n正文只写现状。\n\n## 历史版本\n\n### 2026-09-02\n- 建档。\n' > "$date_scenario_directory/shallow/kb/a.md"
run_scripted "doc-lint/浅克隆不拿截断处当第一个提交" 0 "文档铁律检查通过" -- \
  env DOC_LINT_LANG=zh bash "$SCRIPTS/doc-lint.sh" "$date_scenario_directory/shallow"

# en / ja 仓写实测日期的形态是 Measured ( 与 実測（。只认中文那种时，这两种一条都不查。
date_scenario_directory="$temporary_directory/date-forms"; mkdir -p "$date_scenario_directory/kb"
printf '# 决策\n\nMeasured (2099-01-01) 一次。\n\n## 历史版本\n' > "$date_scenario_directory/kb/en.md"
printf '# 决策\n\n実測（2099-01-01）一次。\n\n## 历史版本\n' > "$date_scenario_directory/kb/ja.md"
run_scripted "doc-lint/英日两种实测写法的日期也查" 1 "kb/en.md:3  日期 2099-01-01 不可能" "kb/ja.md:3  日期 2099-01-01 不可能" -- \
  env DOC_LINT_LANG=zh bash "$SCRIPTS/doc-lint.sh" "$date_scenario_directory"

# 包里没有 I18N 时照常判：sed 读不到文件退 2，赋值带着这个退出码，set -e 当场把脚本带走、一个字都不打。
# doc-lint 与 manifest 各一例；同一形态的另外六处带着 `|| true`。
no_i18n_scenario_directory="$temporary_directory/no-i18n-doc-lint"; mkdir -p "$no_i18n_scenario_directory/package/scripts" "$no_i18n_scenario_directory/project/kb"
cp "$SCRIPTS/lib.sh" "$SCRIPTS/preflight.py" "$SCRIPTS/preflight.sh" "$SCRIPTS/proc.py" "$SCRIPTS/doc-lint.sh" "$no_i18n_scenario_directory/package/scripts/"
printf '# 决策\n\n正文只写现状。\n\n## 历史版本\n' > "$no_i18n_scenario_directory/project/kb/a.md"
run_scripted "doc-lint/包里没有 I18N 也照常判" 0 "文档铁律检查通过" -- bash "$no_i18n_scenario_directory/package/scripts/doc-lint.sh" "$no_i18n_scenario_directory/project"
no_i18n_package="$temporary_directory/no-i18n-manifest"; mkdir -p "$no_i18n_package/scripts" "$no_i18n_package/rules"
cp "$SCRIPTS/lib.sh" "$SCRIPTS/preflight.py" "$SCRIPTS/preflight.sh" "$SCRIPTS/proc.py" "$SCRIPTS/manifest.sh" "$no_i18n_package/scripts/"
printf '# 规则\n\n正文。\n' > "$no_i18n_package/rules/a.md"; printf "# 包\\n" > "$no_i18n_package/CLAUDE.md"
run_scripted "manifest/包里没有 I18N 也照常判" 0 "清单与规范文本一致" -- \
  bash -c 'bash "$1/scripts/manifest.sh" --update >/dev/null && bash "$1/scripts/manifest.sh"' manifest_without_i18n "$no_i18n_package"

# ════ bump.sh ════════════════════════════════════════════
head1 "门禁自证：bump.sh 的判别力"
# 一次升全部语言的 VERSION，靠的就是「先查全部在场、再动手」这一个顺序。
# 在 <族目录>/f-zh 放一个只带 bump.sh 的包；清单生成换成桩，这里只测版本号那一半。
make_bump_package() { # make_bump_package <族目录> <声明的语言...>
  local family_root="$1"; shift
  mkdir -p "$family_root/f-zh/scripts"
  cp "$SCRIPTS/lib.sh" "$SCRIPTS/preflight.py" "$SCRIPTS/preflight.sh" "$SCRIPTS/proc.py" "$SCRIPTS/bump.sh" "$family_root/f-zh/scripts/"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$family_root/f-zh/scripts/manifest.sh"
  printf 'family=f\nthis=zh\nreference=zh\ndefault=zh\nlanguages=%s\n' "$*" > "$family_root/f-zh/I18N"
  printf '0.0.1\n' > "$family_root/f-zh/VERSION"
}
bump_family_directory="$temporary_directory/bump-bad-version"; make_bump_package "$bump_family_directory" zh
run_scripted "bump/版本号不是三段数字要拒绝" 1 "版本号必须是三段数字" -- bash "$bump_family_directory/f-zh/scripts/bump.sh" 1.2
bump_family_directory="$temporary_directory/bump-no-i18n"; make_bump_package "$bump_family_directory" zh; rm -f "$bump_family_directory/f-zh/I18N"
run_scripted "bump/缺 I18N 要拒绝" 1 "缺 I18N" -- bash "$bump_family_directory/f-zh/scripts/bump.sh" 0.0.2
# 声明的语言仓有一个不在：必须在写任何一份之前就拒绝，否则会升出互相不一致的几份。
bump_family_directory="$temporary_directory/bump-missing"; make_bump_package "$bump_family_directory" zh en
run_scripted "bump/有语言仓不在就一份都不写" 1 "找不到" "VERSION 仍是 0.0.1" -- \
  bash -c 'bash "$1/f-zh/scripts/bump.sh" 0.0.2; bump_exit_code=$?; echo "VERSION 仍是 $(cat "$1/f-zh/VERSION")"; exit $bump_exit_code' bump_missing "$bump_family_directory"
bump_family_directory="$temporary_directory/bump-ok"; make_bump_package "$bump_family_directory" zh en; mkdir -p "$bump_family_directory/f-en"
run_scripted "bump/全部语言仓都在就一起升" 0 "f-zh  → 0.0.2" "f-en  → 0.0.2" -- bash "$bump_family_directory/f-zh/scripts/bump.sh" 0.0.2
bump_custom_root_scenario="$temporary_directory/bump-custom-root"; mkdir -p "$bump_custom_root_scenario/other-dir"
make_bump_package "$bump_custom_root_scenario/other-dir" zh en; mkdir -p "$bump_custom_root_scenario/other-dir/f-en"
run_scripted "bump/支持 --root 显式指定语言仓目录" 0 "f-zh  → 0.0.3" "f-en  → 0.0.3" -- bash "$bump_custom_root_scenario/other-dir/f-zh/scripts/bump.sh" 0.0.3 --root "$bump_custom_root_scenario/other-dir"
run_scripted "bump/认不出选项时拒绝" 1 "认不出的参数" -- bash "$bump_custom_root_scenario/other-dir/f-zh/scripts/bump.sh" 0.0.3 --unknown


# ════ install.sh ═════════════════════════════════════════
head1 "门禁自证：install.sh 的判别力"
# 版本戳只许往上走。副本比项目声明的版本旧时照写，就是把戳降级，而戳是入库的：
# 降级顺着提交传给所有人，门禁从此按旧规矩判。
install_scenario_directory="$temporary_directory/install-downgrade"; mkdir -p "$install_scenario_directory/project"
printf '9.9.9\n' > "$install_scenario_directory/project/.singlefs-ai-sop-version"
run_scripted "install/不给版本戳降级" 1 "不给版本戳降级" -- bash "$SCRIPTS/../install.sh" "$install_scenario_directory/project"

# 副本被 .gitignore 挡着，新 clone 出来的仓里它不存在。包装脚本 exec 一个不存在的路径，
# 拿到的只有 bash 的「No such file or directory」，一句出路都没有——所以包装里要自己说清楚。
install_scenario_directory="$temporary_directory/install-no-copy"; mkdir -p "$install_scenario_directory/project"
bash "$SCRIPTS/../install.sh" "$install_scenario_directory/project" >/dev/null 2>&1 || true
run_scripted "install/包装说得清副本不在" 1 "找不到共享脚本" -- bash "$install_scenario_directory/project/.claude/scripts/gate.sh"

# ════ gate.sh 自己（判决点）═══════════════════
# 不直接跑真 gate.sh：它把 selftest 当一个阶段跑，那样会无限递归。
# 改成把 gate.sh + lib.sh 拷进一个临时包，各子脚本换成**桩**（按参数决定退出码）。
# 这样测的正是 run_stage 的记录、汇总的判读、以及最终退出码——与子脚本无关。
head1 "门禁自证：gate.sh 判决逻辑的判别力"
STUB_CONDITIONS='# admission: always 桩：selftest 里替真脚本占位，每次调都有意义
# run-condition: none 桩：不碰任何环境'
make_gate_package() { # make_gate_package <目录> [要让哪个桩失败]
  local package_directory="$1" failing_stub_name="${2:-}"
  mkdir -p "$package_directory/scripts" "$package_directory/rules"
  cp "$SCRIPTS/lib.sh" "$SCRIPTS/preflight.py" "$SCRIPTS/preflight.sh" "$SCRIPTS/proc.py" "$SCRIPTS/gate.sh" "$package_directory/scripts/"
  printf '0.0.0\n' > "$package_directory/VERSION"
  printf 'family=f\nthis=zh\nreference=zh\ndefault=zh\nlanguages=zh\n' > "$package_directory/I18N"
  printf '# 规则甲\n' > "$package_directory/rules/a.md"
  local stub_name
  for stub_name in gate-lint selftest shell-lint doc-lint rules-lint naming-lint show-me-test check manifest i18n-sync version-discipline changelog-lint script-modes stage-selftest history-ordinal hooks-registered number-name-sync; do
    # 桩也写准入与运行条件：gate.sh 起每个阶段之前先判它（rules/preflight-discipline.md），没写的会逐个报一句「没写，照跑」
    if [[ "$stub_name" == "$failing_stub_name" ]]; then
      printf '#!/usr/bin/env bash\n%s\necho "  桩 %s 判红"\nexit 1\n' "$STUB_CONDITIONS" "$stub_name" > "$package_directory/scripts/$stub_name.sh"
    else
      printf '#!/usr/bin/env bash\n%s\nexit 0\n' "$STUB_CONDITIONS" > "$package_directory/scripts/$stub_name.sh"
    fi
  done
  # 桩脚本也要可执行：门禁的「脚本执行位」阶段判暂存区里的模式，printf 写出来的是 644。
  chmod +x "$package_directory/scripts"/*.sh
  # python 写的共享脚本也要有桩：gate.sh 直接 python3 它，缺了就是退出码 2。
  local python_stub
  for python_stub in link-targets relay-timing-lint gate-overlap preflight-lint; do
    printf '#!/usr/bin/env python3\n%s\nraise SystemExit(0)\n' "$STUB_CONDITIONS" > "$package_directory/scripts/$python_stub.py"
  done
}

# 全绿：退出码 0，且每个阶段名都要出现在汇总里，钉住「阶段没被人悄悄从 gate.sh 里删掉」
gate_package="$temporary_directory/gate-green"; make_gate_package "$gate_package"
run_scripted "gate/全绿则退出码 0" 0 \
  "已实现的门禁阶段全部通过" 门禁自检 准入与运行条件 门禁判别力 "shell 纪律" 门禁查重 文档铁律 规则纪律 命名纪律 "Show me test" \
  规则清单 各语言同步 版本纪律 "CHANGELOG 连续" 跑完没留下临时文件 \
  -- bash "$gate_package/scripts/gate.sh" "$gate_package"

# 项目登记了自定义门禁目录（rules/sop-first.md）：gate.sh 自己扫「项目本地阶段」时要去那里找，不是默认的 .claude/gate.d
gate_package="$temporary_directory/gate-registered-gate-directory"; make_gate_package "$gate_package"; mkdir -p "$gate_package/scripts/gates" "$gate_package/.claude"
printf 'scripts/gates  # 工程脚本统一挪进项目仓根 scripts/\n' > "$gate_package/.claude/gate-directory"
printf '#!/usr/bin/env bash\n# gate-stage: 挪过去的本地阶段\necho "  ✓ 挪过去的阶段跑到了（查了 1 项）"\n' > "$gate_package/scripts/gates/50-moved.sh"
chmod +x "$gate_package/scripts/gates/50-moved.sh"
run_scripted "gate/登记了自定义门禁目录就跑那里的本地阶段" 0 "挪过去的本地阶段" -- bash "$gate_package/scripts/gate.sh" "$gate_package"

# 任一阶段红 ⇒ 整道门禁必须红。这是判决点，缺了它前面所有检查都白做。
for failing_stage in doc-lint rules-lint naming-lint selftest gate-lint shell-lint show-me-test version-discipline changelog-lint manifest; do
  gate_package="$temporary_directory/gate-red-$failing_stage"; make_gate_package "$gate_package" "$failing_stage"
  run_scripted "gate/$failing_stage 红则门禁红" 1 门禁未通过 -- bash "$gate_package/scripts/gate.sh" "$gate_package"
done

# gate.sh 的编排：阶段的条件不满足就不起它，记失败；只因为「输入没变」没起的记本次未跑（rules/preflight-discipline.md「gate.sh 怎么编排」）。
# 拿「规则清单」那个桩当被判的阶段：它跑了就在包根留一个标记文件。
BLOCKED_STUB_CONDITIONS='# admission: always 桩：每次调都有意义
# run-condition: check test ! -e "$PREFLIGHT_SCRIPT_DIRECTORY/../blocked" :: 桩：包根有 blocked 文件就不许跑，删掉它'
MARK_STUB_RAN='touch "$(dirname "$0")/../manifest-ran"; exit 0'
make_condition_stub() { # make_condition_stub <包目录> <文件头的条件行> <正文>：把「规则清单」的桩换成带这些条件的
  printf '#!/usr/bin/env bash\n%s\n%s\n' "$2" "$3" > "$1/scripts/manifest.sh"; chmod +x "$1/scripts/manifest.sh"
}
gate_then_check_marker=(bash -c '
  gate_output="$(bash "$1/scripts/gate.sh" "$1" "${@:2}" 2>&1)"; gate_exit_code=$?
  printf "%s\n" "$gate_output"
  if [[ -e "$1/manifest-ran" ]]; then echo "标记：阶段跑过了"; else echo "标记：阶段没跑"; fi
  if grep -q "这一轮不前移 gate-ok" <<<"$gate_output"; then echo "gate-ok：这一轮不前移"; else echo "gate-ok：照常"; fi
  exit "$gate_exit_code"' gate_then_check_marker)
gate_package="$temporary_directory/gate-preflight-refused"; make_gate_package "$gate_package"; make_condition_stub "$gate_package" "$BLOCKED_STUB_CONDITIONS" "$MARK_STUB_RAN"; touch "$gate_package/blocked"
run_scripted "gate/阶段条件不满足就不起它、判红" 1 "规则清单：条件不满足，没起它，按失败记" "包根有 blocked 文件就不许跑" \
  "标记：阶段没跑" "门禁未通过：1 个阶段失败" -- "${gate_then_check_marker[@]}" "$gate_package"
gate_package="$temporary_directory/gate-preflight-forced"; make_gate_package "$gate_package"; make_condition_stub "$gate_package" "$BLOCKED_STUB_CONDITIONS" "$MARK_STUB_RAN"; touch "$gate_package/blocked"
run_scripted "gate/--force 照起，记「强制跑过」" 0 "规则清单（强制跑过" "这一轮不算「全部通过」" "标记：阶段跑过了" "gate-ok：这一轮不前移" \
  -- "${gate_then_check_marker[@]}" "$gate_package" --force
gate_package="$temporary_directory/gate-preflight-met"; make_gate_package "$gate_package"; make_condition_stub "$gate_package" "$BLOCKED_STUB_CONDITIONS" "$MARK_STUB_RAN"
run_scripted "gate/条件满足就照常起" 0 "已实现的门禁阶段全部通过" "标记：阶段跑过了" "gate-ok：照常" -- "${gate_then_check_marker[@]}" "$gate_package"
# 起了之后退 78：分不出是它自己的条件变了，还是它调的脚本拒绝了（传出来的 78），跑了一半的检查也可能被吞掉，按失败记
gate_package="$temporary_directory/gate-preflight-stage-exit-78"; make_gate_package "$gate_package"; make_condition_stub "$gate_package" "$STUB_CONDITIONS" 'echo "  桩：前一半判完了"; exit 78'
run_scripted "gate/阶段起了之后退 78 按失败记" 1 "规则清单：起了之后退了 78" "门禁未通过" -- "${gate_then_check_marker[@]}" "$gate_package"
gate_package="$temporary_directory/gate-preflight-malformed"; make_gate_package "$gate_package"; make_condition_stub "$gate_package" '# admission: sometimes 看情况
# run-condition: none 桩：不碰任何环境' "$MARK_STUB_RAN"
run_scripted "gate/阶段的条件写坏了判红、不起它" 1 "规则清单：判不了它的准入与运行条件" "门禁未通过" "标记：阶段没跑" \
  -- "${gate_then_check_marker[@]}" "$gate_package"
gate_package="$temporary_directory/gate-preflight-unchanged"; make_gate_package "$gate_package"; make_condition_stub "$gate_package" '# admission: inputs-changed ./manifest.sh
# run-condition: none 桩：不碰任何环境' "$MARK_STUB_RAN"
git -C "$gate_package" init -q; python3 "$gate_package/scripts/preflight.py" record "$gate_package/scripts/manifest.sh" >/dev/null
run_scripted "gate/只因输入没变而没起的阶段不挡 gate-ok" 0 "规则清单        本次未跑：输入自上次成功跑完以来没变" \
  "标记：阶段没跑" "gate-ok：照常" "已实现的门禁阶段全部通过" -- "${gate_then_check_marker[@]}" "$gate_package"
# 输入没变、同时别的条件也不满足：不是「只因为输入没变」，照样判红
gate_package="$temporary_directory/gate-preflight-unchanged-and-blocked"; make_gate_package "$gate_package"; make_condition_stub "$gate_package" '# admission: inputs-changed ./manifest.sh
# run-condition: check test ! -e "$PREFLIGHT_SCRIPT_DIRECTORY/../blocked" :: 桩：包根有 blocked 文件就不许跑，删掉它' "$MARK_STUB_RAN"
git -C "$gate_package" init -q; python3 "$gate_package/scripts/preflight.py" record "$gate_package/scripts/manifest.sh" >/dev/null; touch "$gate_package/blocked"
run_scripted "gate/输入没变又有别的条件不满足，照样判红" 1 "规则清单：条件不满足，没起它，按失败记" "标记：阶段没跑" "门禁未通过" \
  -- "${gate_then_check_marker[@]}" "$gate_package"
gate_package="$temporary_directory/gate-red-preflight-lint"; make_gate_package "$gate_package"
printf '#!/usr/bin/env python3\n%s\nprint("  桩 preflight-lint 判红")\nraise SystemExit(1)\n' "$STUB_CONDITIONS" > "$gate_package/scripts/preflight-lint.py"
run_scripted "gate/preflight-lint 红则门禁红" 1 门禁未通过 "桩 preflight-lint 判红" -- bash "$gate_package/scripts/gate.sh" "$gate_package"

# --staged：别的会话没暂存的改动不算，暂存了的算（rules/session-wrapup.md 第 4 条）。
# 同一处改动不带 --staged 时要算进来——少了这一例，「--staged 的绿」分不清是没算进来还是那个阶段根本不红。
make_staged_project() { # make_staged_project <目录>：带一个项目本地阶段的最小项目仓，kb/ 里出现 BAD 就红
  local project_directory="$1"
  mkdir -p "$project_directory/.claude/gate.d" "$project_directory/kb"
  printf '0.0.0\n' > "$project_directory/.singlefs-ai-sop-version"
  printf '#!/usr/bin/env bash\n# gate-stage: 样本\ncd "${1:-.}" || exit 2\nif grep -rq BAD kb/; then echo "  ✗ kb 里有 BAD"; echo "     → 删掉"; exit 1; fi\necho "  ✓ kb 里没有 BAD"\n' > "$project_directory/.claude/gate.d/50-sample.sh"
  printf '干净\n' > "$project_directory/kb/a.md"; printf '干净\n' > "$project_directory/kb/b.md"
  git -C "$project_directory" init -q && git -C "$project_directory" add -A && git -C "$project_directory" -c user.name=t -c user.email=t@t commit -qm base
}
gate_scenario_directory="$temporary_directory/gate-staged"; make_gate_package "$gate_scenario_directory/package"; make_staged_project "$gate_scenario_directory/project"
printf 'BAD（别的会话没暂存的）\n' >> "$gate_scenario_directory/project/kb/a.md"
printf '这一轮的\n' >> "$gate_scenario_directory/project/kb/b.md"; git -C "$gate_scenario_directory/project" add kb/b.md
run_scripted "gate/--staged 不算没暂存的改动" 0 "只拿 HEAD + 暂存区跑" "已实现的门禁阶段全部通过" \
  -- bash "$gate_scenario_directory/package/scripts/gate.sh" --staged "$gate_scenario_directory/project"
run_scripted "gate/不带 --staged 时同一处要算进来" 1 门禁未通过 -- bash "$gate_scenario_directory/package/scripts/gate.sh" "$gate_scenario_directory/project"
printf 'BAD（这一轮的）\n' >> "$gate_scenario_directory/project/kb/b.md"; git -C "$gate_scenario_directory/project" add kb/b.md
run_scripted "gate/--staged 算暂存了的改动" 1 门禁未通过 -- bash "$gate_scenario_directory/package/scripts/gate.sh" --staged "$gate_scenario_directory/project"
# 调用方给了 GATE_STAGED_TREE，里层判那一棵、不再读暂存区：此刻暂存区里有 BAD，给的是 HEAD 那棵干净的树，要绿；
# 反过来暂存区干净、给的树里有 BAD，要红。两例缺一例，「判的是给的树」与「判的是暂存区」分不开。
run_scripted "gate/--staged 给了 GATE_STAGED_TREE 就判那棵树，不读暂存区" 0 "被判的树" "已实现的门禁阶段全部通过" -- \
  env GATE_STAGED_TREE="$(git -C "$gate_scenario_directory/project" rev-parse "HEAD^{tree}")" bash "$gate_scenario_directory/package/scripts/gate.sh" --staged "$gate_scenario_directory/project"
gate_given_tree_directory="$temporary_directory/gate-staged-given-tree"; make_gate_package "$gate_given_tree_directory/package"; make_staged_project "$gate_given_tree_directory/project"
printf 'BAD（只在给的树里）\n' > "$gate_given_tree_directory/bad-b.md"
gate_given_tree_blob="$(git -C "$gate_given_tree_directory/project" hash-object -w "$gate_given_tree_directory/bad-b.md")"
GIT_INDEX_FILE="$gate_given_tree_directory/given.index" git -C "$gate_given_tree_directory/project" read-tree HEAD
GIT_INDEX_FILE="$gate_given_tree_directory/given.index" git -C "$gate_given_tree_directory/project" update-index --cacheinfo "100644,$gate_given_tree_blob,kb/b.md"
gate_given_bad_tree="$(GIT_INDEX_FILE="$gate_given_tree_directory/given.index" git -C "$gate_given_tree_directory/project" write-tree)"
run_scripted "gate/--staged 给的树里有红就判红，暂存区干净也一样" 1 "被判的树" 门禁未通过 -- \
  env GATE_STAGED_TREE="$gate_given_bad_tree" bash "$gate_given_tree_directory/package/scripts/gate.sh" --staged "$gate_given_tree_directory/project"
run_scripted "gate/--staged 给的 GATE_STAGED_TREE 不是树要拒绝" 1 "不是这个仓里的一棵树" -- \
  env GATE_STAGED_TREE=0000000000000000000000000000000000000000 bash "$gate_given_tree_directory/package/scripts/gate.sh" --staged "$gate_given_tree_directory/project"
# 同一个仓同一时刻只许一趟 --staged：临时树目录按仓根固定，里面记的 pid 还活着就拒绝；pid 不在了的算残留，清掉接着跑、判法照旧。
gate_busy_scratch="${TMPDIR:-/tmp}/gate-staged-$(printf '%s' "$(cd "$gate_given_tree_directory/project" && pwd)" | git hash-object --stdin | cut -c1-12)"
mkdir -p "$gate_busy_scratch"; printf '%s\n' "$$" > "$gate_busy_scratch/pid"
run_scripted "gate/--staged 另一趟还在跑就拒绝" 1 "正在这个仓上跑" -- bash "$gate_given_tree_directory/package/scripts/gate.sh" --staged "$gate_given_tree_directory/project"
printf '%s\n' 4000000000 > "$gate_busy_scratch/pid"
run_scripted "gate/--staged 残留的临时树目录清掉接着跑" 0 "已实现的门禁阶段全部通过" -- bash "$gate_given_tree_directory/package/scripts/gate.sh" --staged "$gate_given_tree_directory/project"
rm -rf "${gate_busy_scratch:?}"
# 判红的那一次也要清掉临时 worktree。外层在 set -e 下跑里层，写成「里层; rc=$?」时里层一红外层就当场退出，清理走不到。
staged_red_cleanup=(bash -c '
  bash "$1/scripts/gate.sh" --staged "$2" >/dev/null 2>&1; gate_exit_code=$?
  remaining_worktree_count="$(git -C "$2" worktree list --porcelain | grep -c "^worktree ")"
  echo "判红（退出码 $gate_exit_code）之后仓里登记的 worktree：$remaining_worktree_count 个"
  [[ "$gate_exit_code" == 1 && "$remaining_worktree_count" == 1 ]]' staged_red_cleanup)
run_scripted "gate/--staged 判红也清掉临时 worktree" 0 "判红（退出码 1）之后仓里登记的 worktree：1 个" \
  -- "${staged_red_cleanup[@]}" "$gate_scenario_directory/package" "$gate_scenario_directory/project"

# 项目根要认得出 git worktree（它的 .git 是文件）。只认目录的话，在 worktree 里不带参数跑，门禁零输出退 1。
gate_scenario_directory="$temporary_directory/gate-in-worktree"; make_gate_package "$gate_scenario_directory/package"
git -C "$gate_scenario_directory/package" init -q && git -C "$gate_scenario_directory/package" add -A && git -C "$gate_scenario_directory/package" -c user.name=t -c user.email=t@t commit -qm base
git -C "$gate_scenario_directory/package" worktree add --detach "$gate_scenario_directory/worktree" HEAD >/dev/null 2>&1
run_scripted "gate/在 git worktree 里不带参数也找得到项目根" 0 "已实现的门禁阶段全部通过" -- \
  bash -c 'cd "$1" && bash scripts/gate.sh' in_worktree "$gate_scenario_directory/worktree"
# 真找不到项目根时要说出来，不许零输出退出。
mkdir -p "$temporary_directory/no-project"
run_scripted "gate/找不到项目根要说出来" 1 "往上找不到项目根" -- \
  bash -c 'cd "$1" && bash "$2/scripts/gate.sh"' no_project "$temporary_directory/no-project" "$gate_scenario_directory/package"

# 「副本与上游同版本」分两个方向，出路相反：副本比上游新，去更新上游；副本落后上游，去重拷副本。
make_versioned_project() { # make_versioned_project <目录> <兄弟目录里上游的版本>
  make_gate_package "$1/project/.claude/f"
  printf '0.0.1\n' > "$1/project/.claude/f/VERSION"; printf '0.0.1\n' > "$1/project/.singlefs-ai-sop-version"
  mkdir -p "$1/f-zh"; printf '%s\n' "$2" > "$1/f-zh/VERSION"
}
gate_scenario_directory="$temporary_directory/gate-upstream-older"; make_versioned_project "$gate_scenario_directory" 0.0.0
run_scripted "gate/上游比副本旧要说上游旧" 1 "上游比副本旧：副本 0.0.1，上游 0.0.0" -- \
  bash "$gate_scenario_directory/project/.claude/f/scripts/gate.sh" "$gate_scenario_directory/project"
gate_scenario_directory="$temporary_directory/gate-upstream-newer"; make_versioned_project "$gate_scenario_directory" 0.0.2
run_scripted "gate/副本落后上游照旧说落后" 1 "副本落后上游：副本 0.0.1，上游 0.0.2" -- \
  bash "$gate_scenario_directory/project/.claude/f/scripts/gate.sh" "$gate_scenario_directory/project"

# 缺版本戳是拒绝，得带出路：用 warn 打、没有 howto 的话，gate-lint 只认 bad / die / ✗，看不见它。
gate_scenario_directory="$temporary_directory/gate-no-stamp"; make_gate_package "$gate_scenario_directory/project/.claude/f"; mkdir -p "$gate_scenario_directory/project/kb"
run_scripted "gate/缺版本戳要给出路" 1 "项目未声明规范版本" "它会写出 .singlefs-ai-sop-version" -- \
  bash "$gate_scenario_directory/project/.claude/f/scripts/gate.sh" "$gate_scenario_directory/project"

# 本脚本起的子进程看不到 GATE_BASE 与 GATE_STAGED_FROM（清的动作在 run_fixture / run_scripted 里）。
# 函数调用前的临时赋值会导出给函数起的子进程，所以这一行就是在模拟 gate.sh 带着这两样跑本脚本。
GATE_BASE=HEAD GATE_STAGED_FROM=/nonexistent run_scripted "selftest/自己起的子进程看不到 GATE_BASE 与 GATE_STAGED_FROM" 0 \
  "GATE_BASE=<空>" "GATE_STAGED_FROM=<空>" -- \
  bash -c 'echo "GATE_BASE=${GATE_BASE:-<空>}"; echo "GATE_STAGED_FROM=${GATE_STAGED_FROM:-<空>}"'

# 样本仓也不看用户的全局 / 系统 git 配置（头部 GIT_CONFIG_* 那一行 export 钉的就是这个）。
run_scripted "selftest/样本仓不看用户的全局 git 配置" 0 "GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1" -- \
  bash -c 'echo "GIT_CONFIG_GLOBAL=${GIT_CONFIG_GLOBAL:-<空>} GIT_CONFIG_NOSYSTEM=${GIT_CONFIG_NOSYSTEM:-<空>}"'

# --staged 的握手变量到里层就要消费掉，不许再漏给项目本地阶段（它们会拿它当自己的项目根去找兄弟目录）。
gate_scenario_directory="$temporary_directory/gate-staged-env"; make_gate_package "$gate_scenario_directory/package"; make_staged_project "$gate_scenario_directory/project"
printf '#!/usr/bin/env bash\n# gate-stage: 环境探针\necho "  ✓ GATE_STAGED_FROM=${GATE_STAGED_FROM:-<空>}"\n' > "$gate_scenario_directory/project/.claude/gate.d/60-env.sh"
git -C "$gate_scenario_directory/project" add -A && git -C "$gate_scenario_directory/project" -c user.name=t -c user.email=t@t commit -qm probe
run_scripted "gate/--staged 不把 GATE_STAGED_FROM 漏给本地阶段" 0 "GATE_STAGED_FROM=<空>" -- \
  bash "$gate_scenario_directory/package/scripts/gate.sh" --staged "$gate_scenario_directory/project"

# 被门禁的是 SOP 仓自身时，--staged 要跑临时树里那份脚本、按 SOP 仓判；跑源仓的脚本会把临时树当消费项目，
# 报「缺版本戳」判红，只在 SOP 仓跑的四个阶段还静默不跑。
gate_package="$temporary_directory/gate-staged-self"; make_gate_package "$gate_package"
git -C "$gate_package" init -q && git -C "$gate_package" add -A && git -C "$gate_package" -c user.name=t -c user.email=t@t commit -qm base
printf '# 规则乙\n' >> "$gate_package/rules/a.md"; git -C "$gate_package" add rules/a.md
run_scripted "gate/--staged 在 SOP 仓自身上按 SOP 仓判" 0 "本仓即 SOP 本身" "已实现的门禁阶段全部通过" -- \
  bash "$gate_package/scripts/gate.sh" --staged "$gate_package"

# --staged 的 diff 基准要与直接跑相同。临时树是 detached HEAD，里层自己算会落到 HEAD~1，
# 「分两次提交就绕过去」那条口子在 --staged 这边就开着。
# 这里的项目没有 Cargo.toml，「构建与单测」也会红，所以判据钉在 show-me-test 的「拒收」上，不只看退出码。
gate_scenario_directory="$temporary_directory/gate-staged-base"; make_gate_package "$gate_scenario_directory/package"; cp "$SCRIPTS/show-me-test.sh" "$SCRIPTS/comment-only-change.py" "$gate_scenario_directory/package/scripts/"
make_crates_repository "$gate_scenario_directory/project"; printf '0.0.0\n' > "$gate_scenario_directory/project/.singlefs-ai-sop-version"
git -C "$gate_scenario_directory/project" add -A && git -C "$gate_scenario_directory/project" -c user.email=t@t -c user.name=t commit -qm stamp
git init -q --bare -b master "$gate_scenario_directory/origin.git"
git -C "$gate_scenario_directory/project" remote add origin "$gate_scenario_directory/origin.git" && git -C "$gate_scenario_directory/project" push -q -u origin master
printf 'pub fn g() -> u32 { 2 }\n' >> "$gate_scenario_directory/project/crates/foo/src/lib.rs"
git -C "$gate_scenario_directory/project" add -A && git -C "$gate_scenario_directory/project" -c user.email=t@t -c user.name=t commit -qm "改代码不带测试"
printf '# 说明\n' > "$gate_scenario_directory/project/NOTES.md"
git -C "$gate_scenario_directory/project" add -A && git -C "$gate_scenario_directory/project" -c user.email=t@t -c user.name=t commit -qm "只改文档"
printf '再改一行\n' >> "$gate_scenario_directory/project/NOTES.md"; git -C "$gate_scenario_directory/project" add NOTES.md
run_scripted "gate/--staged 的 diff 基准与直接跑相同" 1 拒收 -- bash "$gate_scenario_directory/package/scripts/gate.sh" --staged "$gate_scenario_directory/project"

# 项目里的包装脚本把项目根放在 $1、用户的参数接在后面，所以文档推荐的 `gate.sh --staged` 到里层是 `gate.sh <项目根> --staged`。
# 写死「$1 == --staged」时它被静默吃掉，门禁照常跑工作区。
gate_scenario_directory="$temporary_directory/gate-wrap"; make_gate_package "$gate_scenario_directory/package"; make_staged_project "$gate_scenario_directory/project"
mkdir -p "$gate_scenario_directory/project/.claude/scripts"
printf '#!/usr/bin/env bash\nexec bash "%s/scripts/gate.sh" "%s" "$@"\n' "$gate_scenario_directory/package" "$gate_scenario_directory/project" > "$gate_scenario_directory/project/.claude/scripts/gate.sh"
printf 'BAD（别的会话没暂存的）\n' >> "$gate_scenario_directory/project/kb/a.md"
run_scripted "gate/经包装脚本带 --staged 也认得" 0 "只拿 HEAD + 暂存区跑" "已实现的门禁阶段全部通过" -- \
  bash "$gate_scenario_directory/project/.claude/scripts/gate.sh" --staged
run_scripted "gate/认不出的参数要拒绝" 1 "认不出的参数：--stagd" -- \
  bash "$gate_scenario_directory/package/scripts/gate.sh" --stagd "$gate_scenario_directory/project"

# 判「被门禁的是不是 SOP 仓自身」要按物理路径：只比 pwd 的话，经符号链接跑就判成消费项目，
# 报「缺版本戳」判红，只在 SOP 仓跑的四个阶段还静默不跑。
gate_scenario_directory="$temporary_directory/gate-symlink"; make_gate_package "$gate_scenario_directory/package"; ln -s "$gate_scenario_directory/package" "$gate_scenario_directory/link"
run_scripted "gate/经符号链接也认得出 SOP 仓自身" 0 "本仓即 SOP 本身" -- \
  bash "$gate_scenario_directory/link/scripts/gate.sh" "$gate_scenario_directory/package"

# ── 门禁中途退出时要自己喊出来 ──────────────────────
# 门禁半路死掉（比如一处函数先用后定）时，只在 stderr 留一句 command not found、没有汇总行的话，
# 外面看不出「没跑」和「跑过了」的区别。
gate_scenario_directory="$temporary_directory/gate-halt"; make_gate_package "$gate_scenario_directory/package"; make_staged_project "$gate_scenario_directory/project"
# 在「规范版本」那个阶段的标题之后插一处必然失败的调用，模拟脚本半路死掉
sed -i 's|^head1 "规范版本"$|head1 "规范版本"\nthis_function_does_not_exist|' "$gate_scenario_directory/package/scripts/gate.sh"
# 退出码原样保留（bash 的「命令未找到」是 127）：断点的性质比「统一成 1」有用
run_scripted "gate/中途退出时说出来并返回非 0" 127 "门禁没跑完就退出了" -- \
  bash "$gate_scenario_directory/package/scripts/gate.sh" "$gate_scenario_directory/project"

# gate-ok 记的是开跑时的 HEAD。跑完再解析一次的话，另一个会话在这一轮跑的过程中提交，
# 那个从没验过的提交会被一并盖章，此后永远落在 diff 窗口外。
gate_scenario_directory="$temporary_directory/gate-ok-reference"; make_gate_package "$gate_scenario_directory/package"; make_staged_project "$gate_scenario_directory/project"
# 中途提交的内容开跑之前就写进工作区：跑的过程中只让 HEAD 动、不让工作区内容动。
# 否则「工作区跑的过程中没变」那一项先判红，门禁不通过、gate-ok 根本不写，这条用例测的就不再是「记哪个 HEAD」。
printf '#!/usr/bin/env bash\n# gate-stage: 中途提交\ncd "${1:?}" || exit 2\ngit add kb/a.md\ngit -c user.name=t -c user.email=t@t commit -qm "跑的过程中提交" >/dev/null\necho "  %s 已提交（查了 1 项）"\n' ✓ > "$gate_scenario_directory/project/.claude/gate.d/60-commit.sh"
git -C "$gate_scenario_directory/project" add -A; git -C "$gate_scenario_directory/project" -c user.name=t -c user.email=t@t commit -qm stage
printf '别的会话写的\n' >> "$gate_scenario_directory/project/kb/a.md"
gate_ok_reference_check=(bash -c '
  head_at_start="$(git -C "$2" rev-parse HEAD)"
  bash "$1/scripts/gate.sh" "$2" >/dev/null 2>&1
  [[ "$(git -C "$2" rev-parse HEAD)" != "$head_at_start" ]] || { echo "场景没摆成：跑的过程中 HEAD 没变"; exit 1; }
  if [[ "$(git -C "$2" rev-parse refs/sop/gate-ok)" == "$head_at_start" ]]; then echo "gate-ok 指向开跑时那个提交"
  else echo "gate-ok 指向跑完时那个提交"; exit 1; fi' gate_ok_reference_check)
run_scripted "gate/gate-ok 记的是开跑时的 HEAD" 0 "gate-ok 指向开跑时那个提交" -- "${gate_ok_reference_check[@]}" "$gate_scenario_directory/package" "$gate_scenario_directory/project"

# --staged 跑到一半被打断（Ctrl-C）也要清掉临时 worktree：留下的会一直登记在仓里，下一次还得手工 git worktree prune。
# 一个睡 20 秒的项目阶段，worktree 建起来之后给整组发 INT；开 job control（set -m）是为了让后台那一组收得到 INT。
# 写成独立的 bash 程序：run_scripted 经 timeout 执行命令，timeout 看不见 shell 函数。
# 被打断的那道门禁用它自己的 TMPDIR：整组在任意一刻收到 INT，正在建的临时目录（工作区指纹那种）来不及删，
# 留在外层 TMPDIR 里的话，外层门禁的「跑完没留下临时文件」会偶发地判红。
staged_interrupt=(bash -c '
  package_directory="$1" project_directory="$2"
  set -m
  mkdir -p "$project_directory.temporary"
  TMPDIR="$project_directory.temporary" bash "$package_directory/scripts/gate.sh" --staged "$project_directory" >/dev/null 2>&1 &
  gate_job_pid="$!"
  for attempt in $(seq 1 100); do
    [[ "$(git -C "$project_directory" worktree list --porcelain | grep -c "^worktree ")" -ge 2 ]] && break
    sleep 0.1
  done
  kill -INT -- -"$gate_job_pid" 2>/dev/null; wait "$gate_job_pid" 2>/dev/null
  remaining_worktree_count="$(git -C "$project_directory" worktree list --porcelain | grep -c "^worktree ")"
  echo "打断之后仓里登记的 worktree：$remaining_worktree_count 个"
  [[ "$remaining_worktree_count" == 1 ]]' staged_interrupt)
gate_scenario_directory="$temporary_directory/gate-staged-interrupt"; make_gate_package "$gate_scenario_directory/package"; make_staged_project "$gate_scenario_directory/project"
printf '#!/usr/bin/env bash\n# gate-stage: 慢样本\nsleep 20\n' > "$gate_scenario_directory/project/.claude/gate.d/60-slow.sh"
git -C "$gate_scenario_directory/project" add .claude/gate.d/60-slow.sh
run_scripted "gate/--staged 跑到一半被打断也清掉临时 worktree" 0 "打断之后仓里登记的 worktree：1 个" \
  -- "${staged_interrupt[@]}" "$gate_scenario_directory/package" "$gate_scenario_directory/project"

# 未实现清单由项目阶段声明覆盖（# gate-covers:）。四个方向各一例：
# 通过 ⇒ 那一项换成「由谁覆盖」、收尾那句跟着换；跑红 ⇒ 照旧列着；退 77 ⇒ 记本次未跑、照旧列着；键写错 ⇒ 判红。
# 「列着 / 没列着」只看未实现那一段：收尾那句与 howto 里也会出现同一个词。
make_covers_project() { # make_covers_project <目录> <本地阶段的退出码> <gate-covers 的键>；项目登记一项「样本手段」，带覆盖之后的提醒句
  mkdir -p "$1/.claude/gate.d"
  printf '0.0.0\n' > "$1/.singlefs-ai-sop-version"
  printf '# 样本登记\n样本手段\t样本缺的东西\t样本提醒句\n' > "$1/.claude/gate-not-implemented.tsv"
  printf '#!/usr/bin/env bash\n# gate-stage: 样本重放\n# gate-covers: %s\necho "  样本阶段跑完"\nexit %s\n' "$3" "$2" \
    > "$1/.claude/gate.d/54-sample.sh"
}
gate_with_not_implemented_section=(bash -c '
  bash "$1/scripts/gate.sh" "$2" > "$3" 2>&1; gate_exit_code=$?
  cat "$3"
  not_implemented_keys="$(sed -n "/未实现的门禁阶段/,/^\$/p" "$3" | sed -n "s/^ *! \([^：]*\)：.*/\1/p" | tr -d " " | paste -sd " " -)"
  echo "未实现段：$not_implemented_keys"
  exit "$gate_exit_code"' gate_with_not_implemented_section)
# 覆盖声明的阶段退 0，却报了本次未跑一部分：覆盖到哪说不清，那一项留在未实现清单里
gate_scenario_directory="$temporary_directory/gate-covers-partial"; make_gate_package "$gate_scenario_directory/package"; make_covers_project "$gate_scenario_directory/project" 0 样本手段
sed -i '/^exit 0$/i if [[ -n "${GATE_NOT_RUN_FILE:-}" ]]; then echo "样本：缺 qemu，这一部分没跑" >> "$GATE_NOT_RUN_FILE"; fi' "$gate_scenario_directory/project/.claude/gate.d/54-sample.sh"
run_scripted "gate/只跑了一部分的本地阶段不算覆盖" 0 "样本重放        本次未跑一部分：样本：缺 qemu，这一部分没跑" \
  "未实现段：样本手段 最终判据 命名纪律（shell）" -- "${gate_with_not_implemented_section[@]}" "$gate_scenario_directory/package" "$gate_scenario_directory/project" "$gate_scenario_directory/out.txt"
gate_scenario_directory="$temporary_directory/gate-covers-pass"; make_gate_package "$gate_scenario_directory/package"; make_covers_project "$gate_scenario_directory/project" 0 样本手段
run_scripted "gate/覆盖声明的阶段通过，那一项换成由谁覆盖" 0 "样本手段 ← 样本重放" "项目登记了 1 项自己的验证手段" \
  "未实现段：最终判据 命名纪律（shell）" "样本手段由「样本重放」覆盖，样本提醒句" \
  -- "${gate_with_not_implemented_section[@]}" "$gate_scenario_directory/package" "$gate_scenario_directory/project" "$gate_scenario_directory/out.txt"
gate_scenario_directory="$temporary_directory/gate-covers-fail"; make_gate_package "$gate_scenario_directory/package"; make_covers_project "$gate_scenario_directory/project" 1 样本手段
run_scripted "gate/覆盖声明的阶段跑红，那一项照旧列着" 1 门禁未通过 "未实现段：样本手段 最终判据 命名纪律（shell）" \
  -- "${gate_with_not_implemented_section[@]}" "$gate_scenario_directory/package" "$gate_scenario_directory/project" "$gate_scenario_directory/out.txt"
gate_scenario_directory="$temporary_directory/gate-covers-77"; make_gate_package "$gate_scenario_directory/package"; make_covers_project "$gate_scenario_directory/project" 77 样本手段
run_scripted "gate/本地阶段退 77 记本次未跑，不算覆盖" 0 "本次未跑：阶段报了这一轮无对象可判（退出码 77）" \
  "未实现段：样本手段 最终判据 命名纪律（shell）" "样本手段还没有项目阶段覆盖" \
  -- "${gate_with_not_implemented_section[@]}" "$gate_scenario_directory/package" "$gate_scenario_directory/project" "$gate_scenario_directory/out.txt"
gate_scenario_directory="$temporary_directory/gate-covers-no-registry"; make_gate_package "$gate_scenario_directory/package"; make_covers_project "$gate_scenario_directory/project" 0 最终判据; rm "$gate_scenario_directory/project/.claude/gate-not-implemented.tsv"
run_scripted "gate/项目没登记自己的手段，清单只剩共享键" 0 "最终判据 ← 样本重放" "未实现段：命名纪律（shell）" \
  -- "${gate_with_not_implemented_section[@]}" "$gate_scenario_directory/package" "$gate_scenario_directory/project" "$gate_scenario_directory/out.txt"
gate_scenario_directory="$temporary_directory/gate-covers-bad-registry"; make_gate_package "$gate_scenario_directory/package"; make_covers_project "$gate_scenario_directory/project" 0 样本手段
printf '只有键没有说明\n最终判据\t与共享键重名\n说明空着\t\t只写了提醒句\n' >> "$gate_scenario_directory/project/.claude/gate-not-implemented.tsv"
run_scripted "gate/登记表少列或与共享键重名要红" 1 "少了键或说明：只有键没有说明" "「最终判据」与共享键或前面的行重名" \
  "少了键或说明：说明空着" "项目登记的未实现手段" \
  -- "${gate_with_not_implemented_section[@]}" "$gate_scenario_directory/package" "$gate_scenario_directory/project" "$gate_scenario_directory/out.txt"
gate_scenario_directory="$temporary_directory/gate-covers-typo"; make_gate_package "$gate_scenario_directory/package"; make_covers_project "$gate_scenario_directory/project" 0 样本手
run_scripted "gate/gate-covers 写了清单里没有的项要红" 1 "gate-covers 写了清单里没有的项：「样本手」" \
  -- "${gate_with_not_implemented_section[@]}" "$gate_scenario_directory/package" "$gate_scenario_directory/project" "$gate_scenario_directory/out.txt"

# 本地阶段的条件不满足：不起它、记失败、不算覆盖；带 --force 起了也只记「强制跑过」，同样不算覆盖（rules/preflight-discipline.md）
gate_forcing_with_not_implemented_section=(bash -c '
  bash "$1/scripts/gate.sh" "$2" "${@:4}" > "$3" 2>&1; gate_exit_code=$?
  cat "$3"
  not_implemented_keys="$(sed -n "/未实现的门禁阶段/,/^\$/p" "$3" | sed -n "s/^ *! \([^：]*\)：.*/\1/p" | tr -d " " | paste -sd " " -)"
  echo "未实现段：$not_implemented_keys"
  exit "$gate_exit_code"' gate_forcing_with_not_implemented_section)
make_blocked_covers_project() { # make_blocked_covers_project <目录>：覆盖样本手段、而条件永远不满足的本地阶段
  make_covers_project "$1" 0 样本手段
  sed -i '2a # admission: always 桩：每次调都有意义\n# run-condition: check false :: 桩：这条条件永远不满足' "$1/.claude/gate.d/54-sample.sh"
}
gate_scenario_directory="$temporary_directory/gate-covers-blocked"; make_gate_package "$gate_scenario_directory/package"; make_blocked_covers_project "$gate_scenario_directory/project"
run_scripted "gate/本地阶段条件不满足就不起、判红、不算覆盖" 1 "样本重放：条件不满足，没起它，按失败记" \
  "未实现段：样本手段 最终判据 命名纪律（shell）" -- "${gate_forcing_with_not_implemented_section[@]}" "$gate_scenario_directory/package" "$gate_scenario_directory/project" "$gate_scenario_directory/out.txt"
gate_scenario_directory="$temporary_directory/gate-covers-forced"; make_gate_package "$gate_scenario_directory/package"; make_blocked_covers_project "$gate_scenario_directory/project"
run_scripted "gate/本地阶段强制跑过也不算覆盖" 0 "样本重放（强制跑过" "未实现段：样本手段 最终判据 命名纪律（shell）" \
  -- "${gate_forcing_with_not_implemented_section[@]}" "$gate_scenario_directory/package" "$gate_scenario_directory/project" "$gate_scenario_directory/out.txt" --force

# ── gate.sh 与各脚本之间的约定 ──────────────────────────
# doc-lint 报的未实现项要出现在汇总里：汇总才是人会看的那一处，只在阶段输出里报、阶段照样记 PASS 不算。
gate_package="$temporary_directory/gate-not-implemented"; make_gate_package "$gate_package"
printf '#!/usr/bin/env bash\nif [[ "${1:-}" == --not-impl ]]; then echo "文档铁律的词表型检查（en）：本语言没有词表"; exit 0; fi\nexit 0\n' > "$gate_package/scripts/doc-lint.sh"
run_scripted "gate/汇总里列出 doc-lint 报的未实现项" 0 "文档铁律的词表型检查（en）：本语言没有词表" -- bash "$gate_package/scripts/gate.sh" "$gate_package"

# 命名纪律退 3 = 没有要查的 .rs，记「本次未跑」不记通过（与 Show me test 同一个约定）。
gate_package="$temporary_directory/gate-naming-exit-3"; make_gate_package "$gate_package"
printf '#!/usr/bin/env bash\nexit 3\n' > "$gate_package/scripts/naming-lint.sh"
run_scripted "gate/命名纪律无对象可判记本次未跑" 0 "命名纪律            本次无对象可判" -- bash "$gate_package/scripts/gate.sh" "$gate_package"

# 本地阶段拿得到这一轮的 diff 基准：各阶段各按各的口径取的话，同一轮里两个阶段判的不是同一批改动。
gate_scenario_directory="$temporary_directory/gate-diff-base"; make_gate_package "$gate_scenario_directory/package"; make_staged_project "$gate_scenario_directory/project"
printf '#!/usr/bin/env bash\n# gate-stage: 基准探针\nif [[ -n "${GATE_DIFF_BASE:-}" ]]; then echo "  %s 基准已导入（查了 1 项）"; else echo "  基准没导入"; exit 1; fi\n' ✓ > "$gate_scenario_directory/project/.claude/gate.d/70-base.sh"
git -C "$gate_scenario_directory/project" add -A; git -C "$gate_scenario_directory/project" -c user.name=t -c user.email=t@t commit -qm probe
run_scripted "gate/本地阶段拿得到这一轮的 diff 基准" 0 "基准已导入" -- bash "$gate_scenario_directory/package/scripts/gate.sh" "$gate_scenario_directory/project"

# 从 git 钩子里跑时 git 设了 GIT_DIR 这一组，它们压过 `git -C`：不清掉的话 worktree add 会失败，
# 而报出来的出路是「先跑 git worktree prune」，指的方向是错的。
# GIT_DIR 要用相对路径，而且要 cd 进项目再跑：git 给钩子设的就是相对的 `.git`。
# 写成绝对路径时它恰好还指着同一个仓，不清掉也照样跑得通，这条用例就分不出修没修；相对路径在 gate.sh 换了工作目录之后才会指错地方。
gate_scenario_directory="$temporary_directory/gate-hook-environment"; make_gate_package "$gate_scenario_directory/package"; make_staged_project "$gate_scenario_directory/project"
hook_environment_check=(bash -c 'cd "$2" && GIT_DIR=.git GIT_INDEX_FILE=.git/index bash "$1/scripts/gate.sh" --staged .' hook_environment_check)
run_scripted "gate/带着 git 钩子的环境变量也跑得了 --staged" 0 "只拿 HEAD + 暂存区跑" -- \
  "${hook_environment_check[@]}" "$gate_scenario_directory/package" "$gate_scenario_directory/project"

# --staged 中途 die 也要把临时 worktree 带走。只挂 INT / TERM 时，die 那几条路径会留下一个 worktree。
# 摆法：暂存区里删掉 scripts/gate.sh，临时树里就没有它，里层跑不起来，走 die。
gate_package="$temporary_directory/gate-exit-trap"; make_gate_package "$gate_package"
git -C "$gate_package" init -q && git -C "$gate_package" add -A && git -C "$gate_package" -c user.name=t -c user.email=t@t commit -qm base
git -C "$gate_package" rm -q --cached scripts/gate.sh >/dev/null
exit_trap_check=(bash -c '
  bash "$1/scripts/gate.sh" --staged "$1" >/dev/null 2>&1
  remaining_worktree_count="$(git -C "$1" worktree list --porcelain | grep -c "^worktree ")"
  echo "die 之后仓里登记的 worktree：$remaining_worktree_count 个"
  [[ "$remaining_worktree_count" == 1 ]]' exit_trap_check)
run_scripted "gate/--staged 中途 die 也清掉临时 worktree" 0 "die 之后仓里登记的 worktree：1 个" -- "${exit_trap_check[@]}" "$gate_package"

# 「规范版本不一致」那条拒绝里用到族名：族名定义在它之后的话，set -u 下它一出口就是 unbound variable，
# 拒绝本身一个字都打不出来。
gate_scenario_directory="$temporary_directory/gate-version-mismatch"; make_gate_package "$gate_scenario_directory/project/.claude/f"
printf '0.0.1\n' > "$gate_scenario_directory/project/.singlefs-ai-sop-version"
run_scripted "gate/版本戳对不上时那条拒绝打得出来" 1 "规范版本不一致" "install.sh 更新版本戳" -- \
  bash "$gate_scenario_directory/project/.claude/f/scripts/gate.sh" "$gate_scenario_directory/project"

# ── gate.sh 的判决分支：改成无条件记 PASS 也要有人发现 ──
# 本地阶段要交给两个 lint：它们和共享阶段一样会拒绝提交者。
gate_scenario_directory="$temporary_directory/gate-lint-extra"; make_gate_package "$gate_scenario_directory/package"; make_staged_project "$gate_scenario_directory/project"
cp "$SCRIPTS/gate-lint.sh" "$SCRIPTS/shell-lint.sh" "$gate_scenario_directory/package/scripts/"
# 放进 gate.d 的**子目录**：gate.sh 只把 maxdepth 1 的 *.sh 当阶段跑，而两个 lint 是递归扫的。
# 直接放在 gate.d 根下，它会作为一个阶段被执行、自己判红，于是去掉 LINT_EXTRA 之后门禁照样退 1、
# 输出里照样有这个文件名，这条用例就分不出「lint 扫到了」还是「阶段自己红了」。
mkdir -p "$gate_scenario_directory/project/.claude/gate.d/lib"
cp "$fixtures_directory/scan/root-nakeddie.sh" "$gate_scenario_directory/project/.claude/gate.d/lib/90-nakeddie.sh"
run_scripted "gate/本地阶段也交给两个 lint" 1 "90-nakeddie.sh:3  拒绝但没有出路" -- bash "$gate_scenario_directory/package/scripts/gate.sh" "$gate_scenario_directory/project"

# ── gate.sh：跑的过程中工作区变了要判红 ──
# 门禁的结论只对它读到的那一版成立。拿一个项目本地阶段在跑的时候改文件，模拟边改边跑与别的会话中途改动。
gate_scenario_directory="$temporary_directory/gate-worktree-changed"; make_gate_package "$gate_scenario_directory/package"; make_staged_project "$gate_scenario_directory/project"
printf '#!/usr/bin/env bash\n# gate-stage: 中途改文件\ncd "${1:-.}" || exit 2\nprintf "跑到一半有人改了\\n" >> kb/b.md\necho "  ✓ 改了 1 个文件"\n' > "$gate_scenario_directory/project/.claude/gate.d/60-edit-midway.sh"
git -C "$gate_scenario_directory/project" add -A && git -C "$gate_scenario_directory/project" -c user.name=t -c user.email=t@t commit -qm 加一个中途改文件的阶段
run_scripted "gate/跑的过程中工作区变了要判红" 1 "门禁跑的这段时间里工作区变了" 门禁未通过 -- bash "$gate_scenario_directory/package/scripts/gate.sh" "$gate_scenario_directory/project"
# 反面：跑的过程中只暂存、不改内容，不算工作区变了（指纹用临时索引算，与暂存区无关）。
# 少了这一例，指纹换成「git status 的输出」这种会被别的会话暂存搅动的算法也照样全绿。
gate_scenario_directory="$temporary_directory/gate-worktree-staged-only"; make_gate_package "$gate_scenario_directory/package"; make_staged_project "$gate_scenario_directory/project"
printf '#!/usr/bin/env bash\n# gate-stage: 中途只暂存\ncd "${1:-.}" || exit 2\ngit add kb/a.md\necho "  ✓ 暂存了 1 个文件"\n' > "$gate_scenario_directory/project/.claude/gate.d/60-stage-midway.sh"
git -C "$gate_scenario_directory/project" add .claude && git -C "$gate_scenario_directory/project" -c user.name=t -c user.email=t@t commit -qm 加一个中途只暂存的阶段
printf '这一轮改过\n' >> "$gate_scenario_directory/project/kb/a.md"
run_scripted "gate/中途只暂存不算工作区变了" 0 "开跑与收尾的工作区指纹相同" "已实现的门禁阶段全部通过" -- bash "$gate_scenario_directory/package/scripts/gate.sh" "$gate_scenario_directory/project"
# 指纹不许碰真索引：直接在真索引上 git add -A 的话，每跑一次门禁，使用者没暂存的改动都被悄悄暂存。
# 只比指纹的值看不出这一点（两种算法算出来的树逐字节相同），所以直接比调用前后的 git status。
fingerprint_index_check=(bash -c '
  source "$1/lib.sh"; repository="$2"
  status_before="$(git -C "$repository" status --porcelain)"
  fingerprint="$(worktree_fingerprint "$repository")"
  status_after="$(git -C "$repository" status --porcelain)"
  [[ -n "$fingerprint" ]] || { echo "指纹是空的"; exit 1; }
  if [[ "$status_before" == "$status_after" ]]; then echo "调用前后 git status 相同"
  else printf "调用前：\n%s\n调用后：\n%s\n" "$status_before" "$status_after"; exit 1; fi' fingerprint_index_check)
fingerprint_repository="$temporary_directory/fingerprint-index"; mkdir -p "$fingerprint_repository"; git -C "$fingerprint_repository" init -q
printf '甲\n' > "$fingerprint_repository/a.md"; git -C "$fingerprint_repository" add a.md; git -C "$fingerprint_repository" -c user.name=t -c user.email=t@t commit -qm a
printf '改了没暂存\n' >> "$fingerprint_repository/a.md"; printf '没跟踪\n' > "$fingerprint_repository/b.md"
run_scripted "lib/工作区指纹不碰真索引" 0 "调用前后 git status 相同" -- "${fingerprint_index_check[@]}" "$SCRIPTS" "$fingerprint_repository"

# ── gate.sh：这一轮各阶段在 TMPDIR 里建了、跑完没删的要判红（rules/command-safety.md「测试镜像一律放临时目录」）──
# 外面给门禁一个空的 TMPDIR，跑完再看它：门禁要替阶段删掉留下的，自己这一轮的临时目录也不许留；
# 放进 GATE_CROSS_RUN_TMPDIR 的跨轮缓存留在外面，门禁不管。
temporary_leftover_check=(bash -c '
  mkdir -p "$3"
  env -u GATE_CROSS_RUN_TMPDIR TMPDIR="$3" bash "$1/scripts/gate.sh" "$2"; gate_exit_code=$?
  echo "门禁跑完，外面的 TMPDIR 里剩：$(ls -A "$3" | tr "\n" " ")（共 $(ls -A "$3" | wc -l) 项）"
  exit "$gate_exit_code"' temporary_leftover_check)
gate_scenario_directory="$temporary_directory/gate-temporary-leftover"; make_gate_package "$gate_scenario_directory/package"; make_staged_project "$gate_scenario_directory/project"
cat > "$gate_scenario_directory/project/.claude/gate.d/60-leave-image.sh" <<'STAGE'
#!/usr/bin/env bash
# gate-stage: 建了镜像不删
truncate -s 64M "$TMPDIR/sample-pool.img"
echo "  ✓ 建了 1 个镜像"
STAGE
git -C "$gate_scenario_directory/project" add -A && git -C "$gate_scenario_directory/project" -c user.name=t -c user.email=t@t commit -qm 加一个建了镜像不删的阶段
run_scripted "gate/阶段在 TMPDIR 里留下镜像要判红" 1 "跑完没删的有 1 项" "sample-pool.img" 门禁未通过 \
  "外面的 TMPDIR 里剩：（共 0 项）" -- "${temporary_leftover_check[@]}" "$gate_scenario_directory/package" "$gate_scenario_directory/project" "$gate_scenario_directory/outer-temporary"
gate_scenario_directory="$temporary_directory/gate-temporary-clean"; make_gate_package "$gate_scenario_directory/package"; make_staged_project "$gate_scenario_directory/project"
cat > "$gate_scenario_directory/project/.claude/gate.d/60-clean-image.sh" <<'STAGE'
#!/usr/bin/env bash
# gate-stage: 镜像用完就删、缓存放跨轮的地方
work="$(mktemp -d)"
trap 'rm -rf "${work:?}"' EXIT
truncate -s 64M "$work/pool.img"
mkdir -p "${GATE_CROSS_RUN_TMPDIR:-${TMPDIR:-/tmp}}/sample-cache"
echo "  ✓ 用完删了 1 个镜像"
STAGE
git -C "$gate_scenario_directory/project" add -A && git -C "$gate_scenario_directory/project" -c user.name=t -c user.email=t@t commit -qm 加一个用完就删的阶段
run_scripted "gate/阶段用完就删、缓存放 GATE_CROSS_RUN_TMPDIR 不判红" 0 "跑完都删了（剩 0 项）" "已实现的门禁阶段全部通过" \
  "外面的 TMPDIR 里剩：sample-cache （共 1 项）" -- "${temporary_leftover_check[@]}" "$gate_scenario_directory/package" "$gate_scenario_directory/project" "$gate_scenario_directory/outer-temporary"
# 嵌套跑（外层门禁里再起一道门禁）：GATE_CROSS_RUN_TMPDIR 沿用外层给的，缓存落到外层指的地方，不落进里层的 TMPDIR
nested_cross_run_check=(bash -c '
  mkdir -p "$3" "$4"
  GATE_CROSS_RUN_TMPDIR="$4" TMPDIR="$3" bash "$1/scripts/gate.sh" "$2"; gate_exit_code=$?
  echo "里层 TMPDIR 剩 $(ls -A "$3" | wc -l) 项；外层指的跨轮目录里有：$(ls -A "$4" | tr "\n" " ")"
  exit "$gate_exit_code"' nested_cross_run_check)
run_scripted "gate/嵌套跑时沿用外层的 GATE_CROSS_RUN_TMPDIR" 0 "里层 TMPDIR 剩 0 项；外层指的跨轮目录里有：sample-cache" -- \
  "${nested_cross_run_check[@]}" "$gate_scenario_directory/package" "$gate_scenario_directory/project" "$gate_scenario_directory/inner-temporary" "$gate_scenario_directory/outer-cross-run"
# 有阶段判红、把现场留在 TMPDIR 里、出路里点了它的路径：这一项不判，这一轮的临时目录整个留着
gate_scenario_directory="$temporary_directory/gate-temporary-scene"; make_gate_package "$gate_scenario_directory/package"; make_staged_project "$gate_scenario_directory/project"
cat > "$gate_scenario_directory/project/.claude/gate.d/60-keep-scene.sh" <<'STAGE'
#!/usr/bin/env bash
# gate-stage: 判红时留现场
mkdir -p "$TMPDIR/scene" && echo 对不上 > "$TMPDIR/scene/check.txt"
echo "  ✗ 判红，现场没清：$TMPDIR/scene"
echo "     → 看 $TMPDIR/scene/check.txt"
exit 1
STAGE
git -C "$gate_scenario_directory/project" add -A && git -C "$gate_scenario_directory/project" -c user.name=t -c user.email=t@t commit -qm 加一个判红时留现场的阶段
scene_kept_check=(bash -c '
  mkdir -p "$3"
  env -u GATE_CROSS_RUN_TMPDIR TMPDIR="$3" bash "$1/scripts/gate.sh" "$2"; gate_exit_code=$?
  echo "门禁跑完，出路里点名的现场还在：$(find "$3" -path "*/scene/check.txt" | wc -l) 份"
  exit "$gate_exit_code"' scene_kept_check)
run_scripted "gate/有阶段判红时留着这一轮的临时目录" 1 "这一项不判" "跑完没留下临时文件  本次未判" \
  "出路里点名的现场还在：1 份" -- "${scene_kept_check[@]}" "$gate_scenario_directory/package" "$gate_scenario_directory/project" "$gate_scenario_directory/outer-temporary"
# 判红时留下的：同一个项目根的只留最近 3 个，更早的由之后那一轮删掉，还在的每一轮都列出来。
# 没标记的（别的会话正在跑的那一轮）与别的项目根留下的不碰、不列；删不掉的只报，门禁照样跑完、打汇总。
repeated_scene_check=(bash -c '
  project_root_physical="$(cd "$2" && pwd -P)"
  mkdir -p "$3/gate-run.unmarked-in-progress" "$3/gate-run.other-project" "$3/gate-run.stuck/read-only"
  printf "1\t/some/other/project\n" > "$3/gate-run.other-project/.kept-by-gate"
  printf "2\t%s\n" "$project_root_physical" > "$3/gate-run.stuck/.kept-by-gate"
  touch "$3/gate-run.stuck/read-only/file"; chmod 555 "$3/gate-run.stuck/read-only"
  for run_number in 1 2 3 4; do env -u GATE_CROSS_RUN_TMPDIR TMPDIR="$3" bash "$1/scripts/gate.sh" "$2" > "$3.run-$run_number" 2>&1; done
  chmod 755 "$3/gate-run.stuck/read-only"
  cat "$3.run-4"
  echo "没标记的还在 $(find "$3" -maxdepth 1 -name gate-run.unmarked-in-progress | wc -l) 个；别的项目留的还在 $(find "$3" -maxdepth 1 -name gate-run.other-project | wc -l) 个、列出来 $(grep -c other-project "$3.run-4") 次"
  echo "删不掉的那个还带着标记：$(find "$3/gate-run.stuck" -maxdepth 1 -name .kept-by-gate | wc -l)"
  echo "这个项目根留着能删的：$(grep -l "$project_root_physical" "$3"/gate-run.*/.kept-by-gate | grep -vc gate-run.stuck) 个"' repeated_scene_check)
run_scripted "gate/判红时留下的临时目录只留最近 3 个" 0 "删掉更早的" "删不掉（权限或挂载点）" "之前判红时留下的临时目录还在" "门禁未通过" \
  "没标记的还在 1 个；别的项目留的还在 1 个、列出来 0 次" "删不掉的那个还带着标记：1" "这个项目根留着能删的：3 个" -- \
  "${repeated_scene_check[@]}" "$gate_scenario_directory/package" "$gate_scenario_directory/project" "$gate_scenario_directory/outer-temporary-repeated"

# Show me test 退 3 = 无对象可判，记「本次未跑」不记通过。
gate_package="$temporary_directory/gate-show-me-test-exit-3"; make_gate_package "$gate_package"
printf '#!/usr/bin/env bash\nexit 3\n' > "$gate_package/scripts/show-me-test.sh"
run_scripted "gate/Show me test 无对象可判记本次未跑" 0 "Show me test        本次无对象可判" -- bash "$gate_package/scripts/gate.sh" "$gate_package"

# 跑的不是项目里装的那份副本时，这条检查测的就不是它名字说的东西，必须判红。
gate_scenario_directory="$temporary_directory/gate-not-copy"; make_gate_package "$gate_scenario_directory/package"; mkdir -p "$gate_scenario_directory/project/.claude/f"
printf '0.0.0\n' > "$gate_scenario_directory/project/.singlefs-ai-sop-version"
printf '0.0.9\n' > "$gate_scenario_directory/project/.claude/f/VERSION"
run_scripted "gate/跑的不是项目里那份副本要判红" 1 "跑的不是项目里那份副本" -- bash "$gate_scenario_directory/package/scripts/gate.sh" "$gate_scenario_directory/project"

# 有 .rs 却没有 Cargo.toml：这些代码根本没被构建过，不能当「本阶段不适用」放过。
gate_scenario_directory="$temporary_directory/gate-no-cargo"; make_gate_package "$gate_scenario_directory/project/.claude/f"
printf '0.0.0\n' > "$gate_scenario_directory/project/.singlefs-ai-sop-version"
mkdir -p "$gate_scenario_directory/project/crates/foo/src"; printf 'pub fn f() {}\n' > "$gate_scenario_directory/project/crates/foo/src/lib.rs"
run_scripted "gate/有 .rs 却没有 Cargo.toml 要判红" 1 "这些代码根本没被构建过" -- \
  bash "$gate_scenario_directory/project/.claude/f/scripts/gate.sh" "$gate_scenario_directory/project"

# 规范副本被 .gitignore 挡着时，--staged 要把它原样拷进临时树，否则项目里的包装脚本转发不到。
gate_scenario_directory="$temporary_directory/gate-copy-into"; mkdir -p "$gate_scenario_directory/project/.claude/gate.d"; make_gate_package "$gate_scenario_directory/project/.claude/f"
printf '0.0.0\n' > "$gate_scenario_directory/project/.singlefs-ai-sop-version"
printf '.claude/f/\n' > "$gate_scenario_directory/project/.gitignore"
printf '#!/usr/bin/env bash\n# gate-stage: 副本在不在\nif [[ -d "${1:?}/.claude/f" ]]; then echo "  %s 副本在（查了 1 项）"; else echo "  副本不在"; exit 1; fi\n' ✓ > "$gate_scenario_directory/project/.claude/gate.d/80-copy.sh"
git -C "$gate_scenario_directory/project" init -q && git -C "$gate_scenario_directory/project" add -A && git -C "$gate_scenario_directory/project" -c user.name=t -c user.email=t@t commit -qm base
run_scripted "gate/--staged 把不进 git 的副本拷进临时树" 0 "副本在" -- \
  bash "$gate_scenario_directory/project/.claude/f/scripts/gate.sh" --staged "$gate_scenario_directory/project"

# ── gate.sh：「本次未跑」都要进汇总，不记通过 ──────────────
# 阶段只跑了一部分时，用 lib.sh 的 report_not_run 报出来，gate.sh 收进汇总；侧信道的文件不算阶段留下的临时文件
gate_package="$temporary_directory/gate-not-run-side-channel"; make_gate_package "$gate_package"
printf '#!/usr/bin/env bash\n%s\nsource "$(dirname "$0")/lib.sh"\nreport_not_run "样本：缺一样工具，这几个用例没跑"\nexit 0\n' "$STUB_CONDITIONS" > "$gate_package/scripts/selftest.sh"
run_scripted "gate/阶段报的本次未跑一部分进汇总" 0 "门禁判别力        本次未跑一部分：样本：缺一样工具，这几个用例没跑" -- bash "$gate_package/scripts/gate.sh" "$gate_package"
run_scripted "gate/侧信道不算阶段留下的临时文件" 0 "跑完都删了（剩 0 项）" -- bash "$gate_package/scripts/gate.sh" "$gate_package"
# 无对象可判的几种都记本次未跑：SOP 仓自身没有版本戳可判；没有 .rs 也没有 Cargo.toml
gate_package="$temporary_directory/gate-self-not-run"; make_gate_package "$gate_package"
run_scripted "gate/SOP 仓自身的规范版本记本次未跑" 0 "规范版本            本次无对象可判：本仓即 SOP 本身" -- bash "$gate_package/scripts/gate.sh" "$gate_package"
run_scripted "gate/没有 .rs 也没有 Cargo.toml 记本次未跑" 0 "构建与单测          本次无对象可判：项目里没有 .rs" -- bash "$gate_package/scripts/gate.sh" "$gate_package"
# 规则清单、各语言同步、版本纪律退 77 记本次未跑，不当失败记
for stage_stub_and_name in manifest:规则清单 i18n-sync:各语言同步 version-discipline:版本纪律; do
  stage_stub="${stage_stub_and_name%%:*}"; stage_name="${stage_stub_and_name#*:}"
  gate_package="$temporary_directory/gate-77-$stage_stub"; make_gate_package "$gate_package"
  printf '#!/usr/bin/env bash\n%s\necho "  样本：本阶段无对象可判"\nexit 77\n' "$STUB_CONDITIONS" > "$gate_package/scripts/$stage_stub.sh"
  run_scripted "gate/$stage_name 退 77 记本次未跑" 0 "$stage_name        本次无对象可判" -- bash "$gate_package/scripts/gate.sh" "$gate_package"
done
# 有 .rs 就要有 Cargo.toml，不只看 crates/
gate_scenario_directory="$temporary_directory/gate-rust-source-elsewhere"; make_gate_package "$gate_scenario_directory/project/.claude/f"
printf '0.0.0\n' > "$gate_scenario_directory/project/.singlefs-ai-sop-version"
mkdir -p "$gate_scenario_directory/project/tools/probe/src"; printf 'pub fn f() {}\n' > "$gate_scenario_directory/project/tools/probe/src/lib.rs"
run_scripted "gate/crates 之外的 .rs 没有 Cargo.toml 也要判红" 1 "这些代码根本没被构建过（例：tools/probe/src/lib.rs）" -- \
  bash "$gate_scenario_directory/project/.claude/f/scripts/gate.sh" "$gate_scenario_directory/project"
# 项目根没有 Cargo.toml，而 .rs 在自带 Cargo.toml 的子目录里：它有自己的构建，不判「没被构建过」，记本次未跑
gate_scenario_directory="$temporary_directory/gate-rust-source-subcrate"; make_gate_package "$gate_scenario_directory/project/.claude/f"
printf '0.0.0\n' > "$gate_scenario_directory/project/.singlefs-ai-sop-version"
mkdir -p "$gate_scenario_directory/project/research/probe/src"; printf 'pub fn f() {}\n' > "$gate_scenario_directory/project/research/probe/src/lib.rs"
printf '[package]\nname = "probe"\nversion = "0.1.0"\n' > "$gate_scenario_directory/project/research/probe/Cargo.toml"
run_scripted "gate/.rs 在自带 Cargo.toml 的子目录里不判没构建过" 0 "构建与单测          本次无对象可判：项目根没有 Cargo.toml，.rs 都在自带 Cargo.toml 的子目录里" -- \
  bash "$gate_scenario_directory/project/.claude/f/scripts/gate.sh" "$gate_scenario_directory/project"
# doc-lint 报不出未实现清单（它的条件不满足、或崩了）要判红，不许吞掉、让未实现清单静默变短
gate_package="$temporary_directory/gate-doc-lint-not-implemented-fails"; make_gate_package "$gate_package"
printf '#!/usr/bin/env bash\n%s\nif [[ "${1:-}" == --not-impl ]]; then echo "  样本：未实现清单取不出来" >&2; exit 78; fi\nexit 0\n' "$STUB_CONDITIONS" > "$gate_package/scripts/doc-lint.sh"
run_scripted "gate/doc-lint 报不出未实现项要判红" 1 "取不到 doc-lint 报的未实现项（doc-lint.sh --not-impl 退出码 78）" -- bash "$gate_package/scripts/gate.sh" "$gate_package"
# rules-lint 在本包的语言上整项没实现（退 77）：记本次未跑、它报的那一行进未实现清单
gate_package="$temporary_directory/gate-rules-not-implemented"; make_gate_package "$gate_package"
printf '#!/usr/bin/env bash\n%s\nif [[ "${1:-}" == --not-impl ]]; then echo "规则纪律（xx）：本语言没有词表，这一项未实现"; exit 0; fi\nexit 77\n' "$STUB_CONDITIONS" > "$gate_package/scripts/rules-lint.sh"
run_scripted "gate/rules-lint 整项未实现记本次未跑并进未实现清单" 0 "规则纪律        本次无对象可判" \
  "未实现段：规则纪律（xx） 最终判据 命名纪律（shell）" -- \
  "${gate_with_not_implemented_section[@]}" "$gate_package" "$gate_package" "$temporary_directory/gate-rules-not-implemented.out"
# 只实现了一部分（英文、日文）：实现了的照判——判红就红，没实现的那几条照样进未实现清单
gate_package="$temporary_directory/gate-rules-partial-red"; make_gate_package "$gate_package"
printf '#!/usr/bin/env bash\n%s\nif [[ "${1:-}" == --not-impl ]]; then echo "规则纪律（en）：有几条只有中文词表"; exit 0; fi\necho "  桩 rules-lint 判红"; exit 1\n' "$STUB_CONDITIONS" > "$gate_package/scripts/rules-lint.sh"
run_scripted "gate/rules-lint 部分实现时照判、判红就红" 1 "桩 rules-lint 判红" "门禁未通过" \
  "未实现段：规则纪律（en） 最终判据 命名纪律（shell）" -- \
  "${gate_with_not_implemented_section[@]}" "$gate_package" "$gate_package" "$temporary_directory/gate-rules-partial-red.out"
gate_package="$temporary_directory/gate-rules-not-implemented-fails"; make_gate_package "$gate_package"
printf '#!/usr/bin/env bash\n%s\nif [[ "${1:-}" == --not-impl ]]; then exit 78; fi\nexit 0\n' "$STUB_CONDITIONS" > "$gate_package/scripts/rules-lint.sh"
run_scripted "gate/rules-lint 报不出未实现项要判红" 1 "取不到 rules-lint 报的未实现项" -- bash "$gate_package/scripts/gate.sh" "$gate_package"
# 符号链接形式的本地阶段也要跑：find -type f 会把它排掉，不跑、不进未跑清单，汇总里也没有
gate_scenario_directory="$temporary_directory/gate-symlink-stage"; make_gate_package "$gate_scenario_directory/package"; make_staged_project "$gate_scenario_directory/project"
mkdir -p "$gate_scenario_directory/project/.claude/stages"
printf '#!/usr/bin/env bash\n# gate-stage: 链接进来的阶段\necho "  %s 链接进来的阶段跑了（查了 1 项）"\n' ✓ > "$gate_scenario_directory/project/.claude/stages/probe.sh"
ln -s ../stages/probe.sh "$gate_scenario_directory/project/.claude/gate.d/65-linked.sh"
run_scripted "gate/符号链接形式的本地阶段也跑" 0 "链接进来的阶段跑了" -- bash "$gate_scenario_directory/package/scripts/gate.sh" "$gate_scenario_directory/project"
# gate-ok 写不进去要说出来（不判红：后果只是下一轮的窗口更宽）：update-ref 的失败被吞掉的话，人以为窗口已经前移了
gate_scenario_directory="$temporary_directory/gate-ok-reference-unwritable"; make_gate_package "$gate_scenario_directory/package"; make_staged_project "$gate_scenario_directory/project"
printf '占住 refs/sop 这个名字\n' > "$gate_scenario_directory/project/.git/refs/sop"
run_scripted "gate/gate-ok 写不进去要说出来" 0 "gate-ok 没写进去" -- bash "$gate_scenario_directory/package/scripts/gate.sh" "$gate_scenario_directory/project"
# --staged 中途在 set -e 下断掉（这里是往临时树里建 .claude 失败）也要说出来，不能只剩那条命令自己的一句 stderr
gate_scenario_directory="$temporary_directory/gate-staged-halt"; make_gate_package "$gate_scenario_directory/package"; mkdir -p "$gate_scenario_directory/project"
printf '0.0.0\n' > "$gate_scenario_directory/project/.singlefs-ai-sop-version"; printf '占位\n' > "$gate_scenario_directory/project/.claude"
git -C "$gate_scenario_directory/project" init -q && git -C "$gate_scenario_directory/project" add -A && git -C "$gate_scenario_directory/project" -c user.name=t -c user.email=t@t commit -qm base
rm "$gate_scenario_directory/project/.claude"; mkdir -p "$gate_scenario_directory/project/.claude/f"
run_scripted "gate/--staged 中途断掉要说出来" 1 "--staged 没跑完就退出了" -- bash "$gate_scenario_directory/package/scripts/gate.sh" --staged "$gate_scenario_directory/project"
# --staged 跑到一半收到 TERM：清理跑两次也不许把「没跑完」那句与退出码吞掉（第二次 git worktree remove 失败时，set -e 会在 trap 里退 128）。
# 用 TERM 不用 INT：非交互 shell 里 & 起的后台进程忽略 INT，trap 也设不上
gate_scenario_directory="$temporary_directory/gate-staged-term"; make_gate_package "$gate_scenario_directory/package"; make_staged_project "$gate_scenario_directory/project"
printf '#!/usr/bin/env bash\n# gate-stage: 慢阶段\ntouch "%s"\nsleep 2\necho "  ✓ 慢阶段跑完（查了 1 项）"\n' "$gate_scenario_directory/slow-stage-started" > "$gate_scenario_directory/project/.claude/gate.d/60-slow.sh"
git -C "$gate_scenario_directory/project" add -A && git -C "$gate_scenario_directory/project" -c user.name=t -c user.email=t@t commit -qm slow
gate_terminated_while_staged=(bash -c '
  mkdir -p "$2.temporary"
  TMPDIR="$2.temporary" bash "$1/scripts/gate.sh" --staged "$2" > "$3" 2>&1 & gate_pid=$!
  for attempt in $(seq 100); do [[ -e "$4" ]] && break; sleep 0.1; done
  kill -TERM "$gate_pid"; wait "$gate_pid"; gate_exit_code=$?
  cat "$3"; echo "worktree 剩 $(git -C "$2" worktree list | wc -l) 个"
  exit "$gate_exit_code"' gate_terminated_while_staged)
run_scripted "gate/--staged 被 TERM 打断也要说出来" 143 "--staged 没跑完就退出了（退出码 143）" "worktree 剩 1 个" \
  -- "${gate_terminated_while_staged[@]}" "$gate_scenario_directory/package" "$gate_scenario_directory/project" "$gate_scenario_directory/out.txt" "$gate_scenario_directory/slow-stage-started"
# --staged：源仓有 cargo 前缀登记而 HEAD + 暂存区里没有，里层的 cargo 就会不经前缀跑，判红
gate_scenario_directory="$temporary_directory/gate-staged-prefix"; make_gate_package "$gate_scenario_directory/package"; make_staged_project "$gate_scenario_directory/project"
printf 'nice -n 5  # 样本：工作区里有、没进暂存区的前缀登记\n' > "$gate_scenario_directory/project/.claude/cargo-command-prefix"
run_scripted "gate/--staged 时前缀登记没进暂存区要判红" 1 "HEAD + 暂存区里没有它" -- bash "$gate_scenario_directory/package/scripts/gate.sh" --staged "$gate_scenario_directory/project"

# ════ changelog-lint ═════════════════════════════════════
head1 "门禁自证：changelog-lint 的判别力"
[[ -d "$fixtures_directory/changelog-lint" ]] || { bad "缺样本目录 $fixtures_directory/changelog-lint"
  howto "样本要随仓走。没有样本，下一个改 changelog-lint.sh 的人无从复跑。"; exit 1; }
for fixture_directory in "$fixtures_directory"/changelog-lint/*/; do
  spawn_fixture "changelog-lint/$(basename "$fixture_directory")" "$fixture_directory" bash "$SCRIPTS/changelog-lint.sh" "$fixture_directory"
done
collect_fixtures

# ════ naming-lint ════════════════════════════════════════
head1 "门禁自证：naming-lint 的判别力"
[[ -d "$fixtures_directory/naming-lint" ]] || { bad "缺样本目录 $fixtures_directory/naming-lint"
  howto "样本要随仓走。没有样本，下一个改 naming-lint.sh 的人无从复跑。"; exit 1; }
for fixture_directory in "$fixtures_directory"/naming-lint/*/; do
  spawn_fixture "naming-lint/$(basename "$fixture_directory")" "$fixture_directory" bash "$SCRIPTS/naming-lint.sh" "$fixture_directory"
done
collect_fixtures

# ════ version-discipline ═════════════════════════════════
head1 "门禁自证：version-discipline 的判别力"
make_sop_repository() { # make_sop_repository <目录> —— 一个已提交基线的最小规范仓
  mkdir -p "$1/scripts"
  printf '0.0.1\n' > "$1/VERSION"
  printf 'echo hi\n' > "$1/scripts/x.sh"
  git -C "$1" init -qb master
  git -C "$1" add -A
  git -C "$1" -c user.email=selftest@local -c user.name=selftest commit -qm init
}
version_discipline_repository="$temporary_directory/version-discipline-red"; make_sop_repository "$version_discipline_repository"
printf 'echo more\n' >> "$version_discipline_repository/scripts/x.sh"
run_scripted "version-discipline/改脚本不抬版本" 1 没抬 -- bash "$SCRIPTS/version-discipline.sh" "$version_discipline_repository"

version_discipline_repository="$temporary_directory/version-discipline-green"; make_sop_repository "$version_discipline_repository"
printf 'echo more\n' >> "$version_discipline_repository/scripts/x.sh"
printf '0.0.2\n' > "$version_discipline_repository/VERSION"
run_scripted "version-discipline/带着版本一起改" 0 "抬到了 0.0.2" -- bash "$SCRIPTS/version-discipline.sh" "$version_discipline_repository"

# 门禁上次过闸位置（refs/sop/gate-ok）如果就是 HEAD，随后的工作区改动必须以 HEAD 为基准，
# 不能跌落至 HEAD~1（否则上一轮抬过的版本会掩盖这一轮未抬版本）。
version_discipline_repository="$temporary_directory/version-discipline-gate-ok-head"; make_sop_repository "$version_discipline_repository"
printf '0.0.2\n' > "$version_discipline_repository/VERSION"
printf 'echo v2\n' >> "$version_discipline_repository/scripts/x.sh"
git -C "$version_discipline_repository" add -A
git -C "$version_discipline_repository" -c user.email=selftest@local -c user.name=selftest commit -qm "bump to 0.0.2"
git -C "$version_discipline_repository" update-ref refs/sop/gate-ok HEAD
printf 'echo v2-modified\n' >> "$version_discipline_repository/scripts/x.sh"
run_scripted "version-discipline/门禁过闸后新改动不提版本要拦住" 1 没抬 -- bash "$SCRIPTS/version-discipline.sh" "$version_discipline_repository"

# 判据是「抬了」不是「动过」：往 VERSION 末尾加个空行就过闸的话，
# 消费项目读到的内容一个字没变。
version_discipline_repository="$temporary_directory/version-discipline-touch"; make_sop_repository "$version_discipline_repository"
printf 'echo more\n' >> "$version_discipline_repository/scripts/x.sh"
printf '\n' >> "$version_discipline_repository/VERSION"
run_scripted "version-discipline/只动 VERSION 不抬不算" 1 没抬 -- bash "$SCRIPTS/version-discipline.sh" "$version_discipline_repository"

# 版本只许往上走：降级会让已装新版的项目看到「上游更旧」，无从判断
version_discipline_repository="$temporary_directory/version-discipline-down"; make_sop_repository "$version_discipline_repository"
printf 'echo more\n' >> "$version_discipline_repository/scripts/x.sh"
printf '0.0.0\n' > "$version_discipline_repository/VERSION"
run_scripted "version-discipline/降级要红" 1 降级了 -- bash "$SCRIPTS/version-discipline.sh" "$version_discipline_repository"

# CHANGELOG 不在 GOVERNED 里：它是记版本变更的地方，改它本身不构成规范变更。
version_discipline_repository="$temporary_directory/version-discipline-not-applicable"; make_sop_repository "$version_discipline_repository"
echo note > "$version_discipline_repository/CHANGELOG.md"
run_scripted "version-discipline/无关改动记无对象可判" 77 "版本纪律无对象可判" -- bash "$SCRIPTS/version-discipline.sh" "$version_discipline_repository"

# GOVERNED（scripts/version-discipline.sh）是脚本自称的唯一权威，**每一项都要有人盯**：
# scripts/ 由别的用例盯着（改 scripts/x.sh 的那几例），其余每一项在这个循环里各有一例；GOVERNED 加了一项，这里跟着加一例，
# 不然摘掉那一项也没有用例会红。
for governed_path in README.md CLAUDE.md install.sh GLOSSARY.md I18N \
          rules/a.md skills/s/SKILL.md templates/t.md agents/a.md; do
  version_discipline_repository="$temporary_directory/version-discipline-governed-$(printf '%s' "$governed_path" | tr '/.' '__')"; make_sop_repository "$version_discipline_repository"
  mkdir -p "$version_discipline_repository/$(dirname "$governed_path")"; echo note > "$version_discipline_repository/$governed_path"
  run_scripted "version-discipline/$governed_path 也要抬版本" 1 没抬 -- bash "$SCRIPTS/version-discipline.sh" "$version_discipline_repository"
done

# VERSION 要精确匹配整行：写成 grep -q 的话，新增一个 VERSIONING.md 就能冒充抬过版本
version_discipline_repository="$temporary_directory/version-discipline-lookalike"; make_sop_repository "$version_discipline_repository"
printf 'echo more\n' >> "$version_discipline_repository/scripts/x.sh"
echo note > "$version_discipline_repository/VERSIONING.md"
run_scripted "version-discipline/名字像VERSION的文件不算" 1 没抬 -- bash "$SCRIPTS/version-discipline.sh" "$version_discipline_repository"
# 改动清单取不全就不判（假 git 在 show-me-test 那一段搭的）：吞掉的话，改了规范本体被判成「没改」
version_discipline_repository="$temporary_directory/version-discipline-diff-fails"; make_sop_repository "$version_discipline_repository"
git -C "$version_discipline_repository" update-ref refs/sop/gate-ok HEAD
printf 'echo more\n' >> "$version_discipline_repository/scripts/x.sh"
git -C "$version_discipline_repository" add -A; git -C "$version_discipline_repository" -c user.email=selftest@local -c user.name=selftest commit -qm "改脚本"
run_scripted "version-discipline/改动清单取不全就判不了" 1 "取不到相对基准" -- env PATH="$fake_git_directory:$PATH" bash "$SCRIPTS/version-discipline.sh" "$version_discipline_repository"
# 基准里有 VERSION 却读不出内容：与「基准里没有 VERSION」一样得到空值的话，按「原 无」放行，降级也算抬过。
# 假 git 只让「git show <基准>:VERSION」失败（对象库坏了、读到一半被打断都是这个形态）
fake_git_show_directory="$temporary_directory/fake-git-show"; mkdir -p "$fake_git_show_directory"
printf '#!/usr/bin/env bash\nif [[ " $* " == *" show "*":VERSION "* ]]; then echo "fatal: 样本：读不出这个对象" >&2; exit 128; fi\nexec %q "$@"\n' \
  "$(command -v git)" > "$fake_git_show_directory/git"
chmod +x "$fake_git_show_directory/git"
version_discipline_repository="$temporary_directory/version-discipline-unreadable"; make_sop_repository "$version_discipline_repository"
printf 'echo more\n' >> "$version_discipline_repository/scripts/x.sh"; printf '0.0.0\n' > "$version_discipline_repository/VERSION"
run_scripted "version-discipline/基准里的 VERSION 读不出就判不了" 1 "却读不出它的内容" -- env PATH="$fake_git_show_directory:$PATH" bash "$SCRIPTS/version-discipline.sh" "$version_discipline_repository"

# ════ manifest 与 i18n-sync ════════════════════════════
head1 "门禁自证：manifest / i18n-sync 的判别力"
# 搭样本用的盖章。失败要当场说清：输出丢进 /dev/null 的话，lib.sh 的 set -e 会把整个自证一声不响地带走，
# 后面几十个用例一个都不跑，只剩一个退出码 1。
setup_stamp() { # setup_stamp <参照仓> <语言> <篇目...>
  local reference_repository="$1" language="$2" log_file; shift 2
  log_file="$(mktemp)"
  if ! bash "$reference_repository/scripts/i18n-sync.sh" --stamp "$language" "$@" > "$log_file" 2>&1; then
    sed 's/^/     | /' "$log_file"
    die "搭译本样本时 i18n-sync --stamp 失败，依赖这份样本的用例一个都没跑" \
        "照上面的原话修 i18n-sync（多半是盖章与回读认的形态对不上），再重跑 selftest。"
  fi
  rm -f "$log_file"
}
make_reference_and_translation_pair() { # make_reference_and_translation_pair <目录> —— 参照仓 + 一个完全跟上的 en 译本仓，返回参照仓路径
  local family_directory="$1"
  local reference_repository="$family_directory/f-zh" translation_repository="$family_directory/f-en"
  make_reference_package "$reference_repository" f
  mkdir -p "$translation_repository"
  cp "$reference_repository/MANIFEST.sha256" "$translation_repository/SOURCE-MANIFEST.sha256"
  cp "$reference_repository/VERSION" "$translation_repository/VERSION"
  local shared_item
  for shared_item in install.sh scripts skills templates GLOSSARY.md .gitignore; do
    [[ -e "$reference_repository/$shared_item" ]] && cp -a "$reference_repository/$shared_item" "$translation_repository/$shared_item"
  done
  sed 's/^this=.*/this=en/' "$reference_repository/I18N" > "$translation_repository/I18N"
  # 逐篇盖上溯源标记：走真正的 --stamp，不在这里另写一份放置逻辑。
  # 手写的话，标记会一律拍在第 1 行，把 SKILL.md 的 frontmatter 压掉，那正是被检查拦下的形态。
  local manifest_path
  while read -r manifest_hash manifest_path; do
    mkdir -p "$translation_repository/$(dirname "$manifest_path")"; cp "$reference_repository/$manifest_path" "$translation_repository/$manifest_path"
  done < "$reference_repository/MANIFEST.sha256"
  git -C "$translation_repository" init -q          # --stamp 只往 git 仓里写
  # shellcheck disable=SC2046  # 篇目按空白拆开，正是要的
  setup_stamp "$reference_repository" en $(sed 's/^[0-9a-f]*  //' "$reference_repository/MANIFEST.sha256")
}
make_reference_package() { # make_reference_package <目录> <族名> —— 最小参照仓（脚本用真的，内容是样本）
  mkdir -p "$1/scripts" "$1/rules" "$1/skills" "$1/templates" "$1/agents"
  cp "$SCRIPTS/lib.sh" "$SCRIPTS/preflight.py" "$SCRIPTS/preflight.sh" "$SCRIPTS/proc.py" "$SCRIPTS/manifest.sh" "$SCRIPTS/i18n-sync.sh" "$1/scripts/"
  printf '# 样本规范\n' > "$1/CLAUDE.md"
  printf '# 规则甲\n' > "$1/rules/a.md"
  printf '# 术语\n' > "$1/GLOSSARY.md"
  printf 'echo install\n' > "$1/install.sh"
  printf '*.pyc\n' > "$1/.gitignore"
  printf '# 骨架\n' > "$1/templates/t.md"
  printf -- '---\nname: a\ndescription: 样本 agent\n---\n\n正文。\n' > "$1/agents/a.md"
  mkdir -p "$1/skills/s"
  printf -- '---\nname: s\ndescription: 样本 skill\n---\n\n正文。\n' > "$1/skills/s/SKILL.md"
  printf '0.0.1\n' > "$1/VERSION"
  printf 'family=%s\nthis=zh\nreference=zh\ndefault=zh\nlanguages=zh en\n' "$2" > "$1/I18N"
  bash "$1/scripts/manifest.sh" --update >/dev/null
}

reference_package="$temporary_directory/manifest/f-zh"; make_reference_package "$reference_package" f
printf '改了一句\n' >> "$reference_package/rules/a.md"
run_scripted "manifest/清单陈旧要红且给出路" 1 不一致 怎么办 -- bash "$reference_package/scripts/manifest.sh"

# 装进项目的副本（没有 .git）不带 CLAUDE.md：缺它照绿、成功句报没比它；别的篇目变了照红；SOP 仓（有 .git）缺它照红
reference_package="$temporary_directory/manifest-copy/f-zh"; make_reference_package "$reference_package" f; rm "$reference_package/CLAUDE.md"
run_scripted "manifest/副本不带 CLAUDE.md 照绿并报没比它" 0 "没比 1 条：CLAUDE.md" -- bash "$reference_package/scripts/manifest.sh"
printf '改了一句\n' >> "$reference_package/rules/a.md"
run_scripted "manifest/副本不带 CLAUDE.md 时别的篇目陈旧照红" 1 不一致 -- bash "$reference_package/scripts/manifest.sh"
reference_package="$temporary_directory/manifest-repository/f-zh"; make_reference_package "$reference_package" f; rm "$reference_package/CLAUDE.md"; git -C "$reference_package" init -q
run_scripted "manifest/SOP 仓缺 CLAUDE.md 照红" 1 不一致 -- bash "$reference_package/scripts/manifest.sh"

reference_package="$temporary_directory/i18n/f-zh"; make_reference_package "$reference_package" f
translation_repository="$temporary_directory/i18n/f-en"; mkdir -p "$translation_repository"
cp "$reference_package/MANIFEST.sha256" "$translation_repository/SOURCE-MANIFEST.sha256"
printf '0.0.1\n' > "$translation_repository/VERSION"
printf '改了一句\n' >> "$reference_package/rules/a.md"
bash "$reference_package/scripts/manifest.sh" --update >/dev/null
# 关键 want：待重译（诊断打了）+ 怎么办（howto 打了）+ 失败汇总（脚本活到了最后）。
# diff 管道在 set -e + pipefail 下会把脚本中途带走，三样全丢。
run_scripted "i18n-sync/落后要红且诊断齐全" 1 待重译 怎么办 各语言同步失败 -- \
  bash "$reference_package/scripts/i18n-sync.sh"

# i18n-sync 的其余分支：造一个「一切就绪」的参照仓 + 译本仓，再逐项破坏其中一样。
language_family_directory="$temporary_directory/i18n-ok"; make_reference_and_translation_pair "$language_family_directory"
run_scripted "i18n-sync/一切就绪要绿" 0 逐篇溯源对得上 "除本仓外声明的 1 种语言都与清单一致" -- bash "$language_family_directory/f-zh/scripts/i18n-sync.sh" "$language_family_directory"

language_family_directory="$temporary_directory/i18n-stale-manifest"; make_reference_and_translation_pair "$language_family_directory"
printf '改了一句\n' >> "$language_family_directory/f-zh/rules/a.md"          # 源文改了、清单没刷新
run_scripted "i18n-sync/清单陈旧则无法判定" 1 陈旧 -- bash "$language_family_directory/f-zh/scripts/i18n-sync.sh" "$language_family_directory"

language_family_directory="$temporary_directory/i18n-no-translation"; make_reference_and_translation_pair "$language_family_directory"
printf '改了一句\n' >> "$language_family_directory/f-zh/rules/a.md"
bash "$language_family_directory/f-zh/scripts/manifest.sh" --update >/dev/null
cp "$language_family_directory/f-zh/MANIFEST.sha256" "$language_family_directory/f-en/SOURCE-MANIFEST.sha256"   # 抄了清单却没重译
run_scripted "i18n-sync/抄了清单没重译" 1 溯源标记与源文对不上 -- bash "$language_family_directory/f-zh/scripts/i18n-sync.sh" "$language_family_directory"

# --update 替译本仓刷新 SOURCE-MANIFEST：逐篇溯源都对上才抄，有一篇没重译就不抄。
language_family_directory="$temporary_directory/i18n-auto-source-manifest"; make_reference_and_translation_pair "$language_family_directory"
printf '改了一句\n' >> "$language_family_directory/f-zh/rules/a.md"
bash "$language_family_directory/f-zh/scripts/manifest.sh" --update >/dev/null
printf '改了一句（已重译）\n' >> "$language_family_directory/f-en/rules/a.md"
setup_stamp "$language_family_directory/f-zh" en rules/a.md
run_scripted "i18n-sync/重译并盖章后 --update 自己抄 SOURCE-MANIFEST" 0 \
  "SOURCE-MANIFEST 已照本仓清单刷新" 逐篇溯源对得上 -- bash "$language_family_directory/f-zh/scripts/i18n-sync.sh" --update "$language_family_directory"
run_scripted "i18n-sync/抄出来的 SOURCE-MANIFEST 与清单逐字节一致" 0 -- \
  cmp "$language_family_directory/f-zh/MANIFEST.sha256" "$language_family_directory/f-en/SOURCE-MANIFEST.sha256"

language_family_directory="$temporary_directory/i18n-auto-source-manifest-stale"; make_reference_and_translation_pair "$language_family_directory"
printf '改了一句\n' >> "$language_family_directory/f-zh/rules/a.md"
bash "$language_family_directory/f-zh/scripts/manifest.sh" --update >/dev/null
cp "$language_family_directory/f-en/SOURCE-MANIFEST.sha256" "$temporary_directory/i18n-auto-source-manifest-stale.before"
run_scripted "i18n-sync/没重译时 --update 不替它抄 SOURCE-MANIFEST" 1 \
  "SOURCE-MANIFEST 不替它抄" "译自旧版源文，需重译: rules/a.md" -- bash "$language_family_directory/f-zh/scripts/i18n-sync.sh" --update "$language_family_directory"
run_scripted "i18n-sync/没重译时 SOURCE-MANIFEST 一个字节都没动" 0 -- \
  cmp "$temporary_directory/i18n-auto-source-manifest-stale.before" "$language_family_directory/f-en/SOURCE-MANIFEST.sha256"

language_family_directory="$temporary_directory/i18n-auto-source-manifest-missing"; make_reference_and_translation_pair "$language_family_directory"; rm -f "$language_family_directory/f-en/SOURCE-MANIFEST.sha256"
run_scripted "i18n-sync/缺 SOURCE-MANIFEST 时 --update 替它补上" 0 \
  "SOURCE-MANIFEST 已照本仓清单刷新" -- bash "$language_family_directory/f-zh/scripts/i18n-sync.sh" --update "$language_family_directory"

language_family_directory="$temporary_directory/i18n-missing"; make_reference_and_translation_pair "$language_family_directory"
rm -f "$language_family_directory/f-en/rules/a.md"                            # 少一篇译文
run_scripted "i18n-sync/少一篇译文" 1 缺 -- bash "$language_family_directory/f-zh/scripts/i18n-sync.sh" "$language_family_directory"

language_family_directory="$temporary_directory/i18n-version"; make_reference_and_translation_pair "$language_family_directory"
printf '9.9.9\n' > "$language_family_directory/f-en/VERSION"                  # 版本不一致
run_scripted "i18n-sync/版本不一致" 1 版本不一致 -- bash "$language_family_directory/f-zh/scripts/i18n-sync.sh" "$language_family_directory"

language_family_directory="$temporary_directory/i18n-shared"; make_reference_and_translation_pair "$language_family_directory"
printf 'echo 手改的\n' >> "$language_family_directory/f-en/install.sh"        # 共享部分被手改
run_scripted "i18n-sync/共享部分被手改" 1 共享部分与本仓不一致 -- bash "$language_family_directory/f-zh/scripts/i18n-sync.sh" "$language_family_directory"

language_family_directory="$temporary_directory/i18n-glossary"; make_reference_and_translation_pair "$language_family_directory"
printf '多加一个词\n' >> "$language_family_directory/f-en/GLOSSARY.md"        # GLOSSARY 跨语言漂移
run_scripted "i18n-sync/GLOSSARY 漂移" 1 共享部分与本仓不一致 -- bash "$language_family_directory/f-zh/scripts/i18n-sync.sh" "$language_family_directory"

# 溯源标记不许压住文件本身的头，实测过的坑：
# SKILL.md 的 frontmatter 被顶下去 → skill 安静地装不上。
language_family_directory="$temporary_directory/i18n-head-frontmatter"; make_reference_and_translation_pair "$language_family_directory"
sed -i '1i <!-- generated-from: skills/s/SKILL.md sha256:0000000000000000000000000000000000000000000000000000000000000000 -->' \
  "$language_family_directory/f-en/skills/s/SKILL.md"
run_scripted "i18n-sync/标记压住 frontmatter" 1 "篇的第 1 行被压住了" -- bash "$language_family_directory/f-zh/scripts/i18n-sync.sh" "$language_family_directory"

# 溯源标记的几种坏法，各自有自己的消息——共用一条 want 就盖住了别的。
# agents 定义与 SKILL.md 同律。清单里的路径是仓根相对的 agents/<名>.md，case 分支写成 */agents/*.md 就一次也匹配不上。
language_family_directory="$temporary_directory/i18n-agent-frontmatter"; make_reference_and_translation_pair "$language_family_directory"
sed -i '1i <!-- generated-from: agents/a.md sha256:0000000000000000000000000000000000000000000000000000000000000000 -->' \
  "$language_family_directory/f-en/agents/a.md"
run_scripted "i18n-sync/标记压住 agent 的 frontmatter" 1 "篇的第 1 行被压住了" -- \
  bash "$language_family_directory/f-zh/scripts/i18n-sync.sh" "$language_family_directory"

language_family_directory="$temporary_directory/i18n-no-source-manifest"; make_reference_and_translation_pair "$language_family_directory"
rm -f "$language_family_directory/f-en/SOURCE-MANIFEST.sha256"
run_scripted "i18n-sync/缺 SOURCE-MANIFEST" 1 "译本仓缺 SOURCE-MANIFEST" -- \
  bash "$language_family_directory/f-zh/scripts/i18n-sync.sh" "$language_family_directory"

language_family_directory="$temporary_directory/i18n-no-mark"; make_reference_and_translation_pair "$language_family_directory"
sed -i '1d' "$language_family_directory/f-en/rules/a.md"                       # 把溯源标记整行删掉
run_scripted "i18n-sync/译文缺溯源标记" 1 "首行缺 generated-from 标记" -- \
  bash "$language_family_directory/f-zh/scripts/i18n-sync.sh" "$language_family_directory"

language_family_directory="$temporary_directory/i18n-wrong-source"; make_reference_and_translation_pair "$language_family_directory"
sed -i '1s|rules/a.md|CLAUDE.md|' "$language_family_directory/f-en/rules/a.md"  # 标记指向别的源文
run_scripted "i18n-sync/溯源指向别的源文" 1 "溯源标记指向别的源文" -- \
  bash "$language_family_directory/f-zh/scripts/i18n-sync.sh" "$language_family_directory"

language_family_directory="$temporary_directory/i18n-no-repository"; make_reference_and_translation_pair "$language_family_directory"
rm -rf "${language_family_directory:?}/f-en"                                       # 译本仓根本不在
run_scripted "i18n-sync/译本仓缺失" 1 找不到译本仓 -- bash "$language_family_directory/f-zh/scripts/i18n-sync.sh" "$language_family_directory"


# --stamp 的拒绝分支：盖章是译本仓的日常操作，拒错了会把没重译的篇目标成新的。
language_family_directory="$temporary_directory/stamp-no-file"; make_reference_and_translation_pair "$language_family_directory"
run_scripted "i18n-sync/--stamp 不给篇目要拒绝" 1 "--stamp 没给篇目" -- bash "$language_family_directory/f-zh/scripts/i18n-sync.sh" --stamp en
language_family_directory="$temporary_directory/stamp-no-repository"; make_reference_and_translation_pair "$language_family_directory"
run_scripted "i18n-sync/--stamp 的语言仓不在要拒绝" 1 "找不到 git 仓" -- bash "$language_family_directory/f-zh/scripts/i18n-sync.sh" --stamp ja rules/a.md
language_family_directory="$temporary_directory/stamp-not-listed"; make_reference_and_translation_pair "$language_family_directory"
run_scripted "i18n-sync/--stamp 不在清单里的篇目要拒绝" 1 "不在 MANIFEST.sha256 里" -- bash "$language_family_directory/f-zh/scripts/i18n-sync.sh" --stamp en rules/nope.md
language_family_directory="$temporary_directory/stamp-no-translation"; make_reference_and_translation_pair "$language_family_directory"; rm -f "$language_family_directory/f-en/rules/a.md"
run_scripted "i18n-sync/--stamp 没译出来的篇目要拒绝" 1 "en 仓里没有 rules/a.md" -- bash "$language_family_directory/f-zh/scripts/i18n-sync.sh" --stamp en rules/a.md
# `.git` 也可以是文件（git worktree、子模块都是这样）。i18n-sync 判「是不是 git 仓」只认目录的话，
# 在 worktree 上做译文同步会被拒，理由还写成「不是 git 仓」，而这个仓自己发布时就是在 worktree 上做的。
make_gitfile_translation_repository() { # make_gitfile_translation_repository <make_reference_and_translation_pair 的目录>：把 f-en 的 .git 目录挪出去，原位只留一个指路的文件
  mv "$1/f-en/.git" "$1/en.gitdir"
  printf 'gitdir: %s\n' "$1/en.gitdir" > "$1/f-en/.git"
}
language_family_directory="$temporary_directory/stamp-gitfile"; make_reference_and_translation_pair "$language_family_directory"; make_gitfile_translation_repository "$language_family_directory"
run_scripted "i18n-sync/--stamp 认 .git 是文件的译本仓" 0 "rules/a.md" -- bash "$language_family_directory/f-zh/scripts/i18n-sync.sh" --stamp en rules/a.md
# 先删掉译本仓的 SOURCE-MANIFEST：make_reference_and_translation_pair 建出来的是完全跟上的，--update 根本走不到「替它抄 SOURCE-MANIFEST」那一支，
# 那一处的 .git 判据改成只认目录，这条用例也照样绿。
language_family_directory="$temporary_directory/update-gitfile"; make_reference_and_translation_pair "$language_family_directory"; make_gitfile_translation_repository "$language_family_directory"; rm -f "$language_family_directory/f-en/SOURCE-MANIFEST.sha256"
run_scripted "i18n-sync/--update 认 .git 是文件的译本仓" 0 "SOURCE-MANIFEST 已照本仓清单刷新" "共享部分已同步" -- \
  bash "$language_family_directory/f-zh/scripts/i18n-sync.sh" --update "$language_family_directory"
# 回读闸：frontmatter 闭合之后文件就结束了，标记该插在一个不存在的行前面，`sed` 什么都不做、也不报错，
# 要当场拒绝，不许报「盖好了」。没闭合的 frontmatter 触发不了这一支（它被正常处理）。
language_family_directory="$temporary_directory/stamp-readback"; make_reference_and_translation_pair "$language_family_directory"; printf -- '---\nname: s\ndescription: 正文一行都没有\n---' > "$language_family_directory/f-en/skills/s/SKILL.md"
run_scripted "i18n-sync/--stamp 回读对不上要拒绝" 1 "盖章后回读不一致" -- bash "$language_family_directory/f-zh/scripts/i18n-sync.sh" --stamp en skills/s/SKILL.md
# ════ check.sh ══════════════════════════════════════════
# 它是门禁的「构建与单测」阶段，坏了等于代码根本没被验过：删掉整个 cargo test 阶段、或去掉 clippy 的 -D warnings，都要有用例红。
head1 "门禁自证：check.sh 的判别力"
if command -v cargo >/dev/null 2>&1; then
  make_crate() { # make_crate <目录> <lib.rs 内容>
    mkdir -p "$1/src"
    printf '[package]\nname = "t"\nversion = "0.1.0"\nedition = "2021"\n' > "$1/Cargo.toml"
    printf '%s' "$2" > "$1/src/lib.rs"
  }
  crate_directory="$temporary_directory/check-ok"; make_crate "$crate_directory" 'pub fn f() -> u32 {
    1
}

#[cfg(test)]
mod tests {
    #[test]
    fn t() {
        assert_eq!(super::f(), 1);
    }
}
'
  run_scripted "check/干净的 crate 放行" 0 单测通过 "共 1 条测试" -- bash "$SCRIPTS/check.sh" "$crate_directory"

  crate_directory="$temporary_directory/check-test"; make_crate "$crate_directory" 'pub fn f() -> u32 {
    1
}

#[cfg(test)]
mod tests {
    #[test]
    fn t() {
        assert_eq!(super::f(), 2);
    }
}
'
  run_scripted "check/单测失败要红" 1 单测失败 -- bash "$SCRIPTS/check.sh" "$crate_directory"

  crate_directory="$temporary_directory/check-clippy"; make_crate "$crate_directory" 'pub fn f() -> u32 {
    let unused = 7;
    1
}
'
  run_scripted "check/告警按错误处理" 1 "clippy 有告警" -- bash "$SCRIPTS/check.sh" "$crate_directory"

  crate_directory="$temporary_directory/check-format"; make_crate "$crate_directory" 'pub fn f()->u32{1}
'
  run_scripted "check/格式不合规要红" 1 格式不合规 -- bash "$SCRIPTS/check.sh" "$crate_directory"

  # cargo test 退 0 却一条测试都没跑：照报「单测通过」的话，与跑过了在输出里一模一样
  crate_directory="$temporary_directory/check-no-tests"; make_crate "$crate_directory" 'pub fn f() -> u32 {
    1
}
'
  run_scripted "check/一条测试都没跑要红" 1 "一条测试都没跑" -- bash "$SCRIPTS/check.sh" "$crate_directory"

  # 项目登记的 cargo 前缀（内存上限这类包装）：每一条 cargo 都经它；前缀自己的退出码原样报出来；前缀起不来、没写理由都判红，不退回无包装
  make_prefixed_crate() { # make_prefixed_crate <目录> <前缀登记的那一行>：带一条测试的干净 crate，外加三个前缀脚本：
    # 记账后照跑的；空跑照过、起 cargo 时退 250 的（比如撞了内存上限）；自己就起不来、一律退 251 的（比如没有 user systemd）
    make_crate "$1" 'pub fn f() -> u32 {
    1
}

#[cfg(test)]
mod tests {
    #[test]
    fn t() {
        assert_eq!(super::f(), 1);
    }
}
'
    mkdir -p "$1/.claude"
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$(dirname "$0")/prefix-calls.log"\nexec "$@"\n' > "$1/record-prefix.sh"
    printf '#!/usr/bin/env bash\n[[ "${1:-}" == cargo ]] || exec "$@"\nexit 250\n' > "$1/refusing-prefix.sh"
    printf '#!/usr/bin/env bash\nexit 251\n' > "$1/broken-prefix.sh"
    printf '# 样本\n%s\n' "$2" > "$1/.claude/cargo-command-prefix"
  }
  crate_directory="$temporary_directory/check-prefix"; make_prefixed_crate "$crate_directory" 'bash record-prefix.sh  # 样本：记下每一次经前缀起的 cargo'
  run_scripted "check/每一条 cargo 都经项目登记的前缀" 0 "cargo 经项目的前缀跑：bash record-prefix.sh" "经前缀起的 cargo：fmt clippy build test" "前缀先空跑了 1 次" -- \
    bash -c 'bash "$1/check.sh" "$2" || exit $?
             printf "经前缀起的 cargo：%s\n" "$(grep "^cargo " "$2/prefix-calls.log" | cut -d" " -f2 | paste -sd" " -)"
             printf "前缀先空跑了 %s 次\n" "$(grep -cx true "$2/prefix-calls.log")"' check_prefix "$SCRIPTS" "$crate_directory"
  crate_directory="$temporary_directory/check-prefix-refused"; make_prefixed_crate "$crate_directory" 'bash refusing-prefix.sh  # 样本：前缀自己退 250（比如撞了内存上限）'
  run_scripted "check/前缀自己的退出码原样报出来" 1 "格式不合规（退出码 250）" "这一条 cargo 是经项目的前缀跑的" -- bash "$SCRIPTS/check.sh" "$crate_directory"
  crate_directory="$temporary_directory/check-prefix-missing"; make_prefixed_crate "$crate_directory" 'no-such-wrapper-for-selftest  # 样本：找不到的前缀'
  run_scripted "check/前缀找不到就判红，不退回无包装" 1 "前缀命令找不到：no-such-wrapper-for-selftest" -- bash "$SCRIPTS/check.sh" "$crate_directory"
  crate_directory="$temporary_directory/check-prefix-reason"; make_prefixed_crate "$crate_directory" 'bash record-prefix.sh'
  run_scripted "check/前缀没写理由就判红" 1 "那一行没写理由" -- bash "$SCRIPTS/check.sh" "$crate_directory"
  # 前缀自己起不来（空跑就失败）：退出码是它的，不许挂在「格式不合规」这句下面
  crate_directory="$temporary_directory/check-prefix-broken"; make_prefixed_crate "$crate_directory" 'bash broken-prefix.sh  # 样本：前缀自己起不来'
  run_scripted "check/前缀起不来就判红，不归到 cargo 头上" 1 "的前缀起不来：空跑 bash broken-prefix.sh true 退出码 251" -- bash "$SCRIPTS/check.sh" "$crate_directory"
  # 前缀是「解释器 + 脚本路径」时，第一个词找得到而脚本缺了：bash 退 127，不许报成「格式不合规」
  crate_directory="$temporary_directory/check-prefix-path"; make_prefixed_crate "$crate_directory" 'bash scripts/no-such-wrapper.sh 16  # 样本：前缀里的脚本路径写错了'
  run_scripted "check/前缀里的路径不存在就判红" 1 "个路径不存在：scripts/no-such-wrapper.sh" -- bash "$SCRIPTS/check.sh" "$crate_directory"
  # 选项与赋值里带 / 的不是路径：env CARGO_TARGET_DIR=<还没建的目录> 判成「路径不存在」的话，除了改写前缀没有出路
  crate_directory="$temporary_directory/check-prefix-assignment"; make_prefixed_crate "$crate_directory" "env CARGO_TARGET_DIR=$temporary_directory/check-prefix-assignment-target  # 样本：编译产物放到别处"
  run_scripted "check/前缀里的赋值与选项不当路径查" 0 "单测通过" "cargo 经项目的前缀跑：env CARGO_TARGET_DIR=" -- bash "$SCRIPTS/check.sh" "$crate_directory"
else
  # 不许静默跳过：环境缺 cargo 就说出来，这几条判别力**本轮没验**。条数按本文件里 check/ 那一段现数，不写死。
  # report_not_run 让门禁把它收进汇总的「本次未跑」，也让这一次不记成「上次成功」（装上 cargo 之后下一次照跑）。
  report_not_run "check.sh 的 $(grep -cE '^[[:space:]]*run_scripted "check/' "${BASH_SOURCE[0]}") 个用例：缺 cargo，装上 Rust 工具链再跑"
fi

# ════ install.sh 铺出来的东西 ════════════════════════════
# 装出来的项目里不许留分发层的账：溯源标记是「这份译文译自哪个版本」，
# 抄进使用者项目就是一条永不更新的陈旧标注，而且贴在他马上要改的文件上。
head1 "门禁自证：install.sh 铺出来的东西"
# 从一个**模板带着溯源标记**的包里装——参照仓自己的模板没有标记（它是源文），
# 拿它装什么也测不出来。译本仓的模板才带标记，那才是使用者实际装的东西。
install_source_package="$temporary_directory/install-source-package"; cp -a "$SCRIPTS/.." "$install_source_package"
sed -i '1i <!-- generated-from: templates/kb/decisions.md sha256:0000000000000000000000000000000000000000000000000000000000000000 -->' \
  "$install_source_package/templates/kb/decisions.md"
install_target_project="$temporary_directory/install-target-project"; mkdir -p "$install_target_project"
install_output_file="$temporary_directory/install.log"
if bash "$install_source_package/install.sh" "$install_target_project" > "$install_output_file" 2>&1; then
  leaked_files="$(grep -rlE 'generated-from: .+ sha256:' "$install_target_project" 2>/dev/null || true)"
  case_count=$((case_count+1))
  if [[ -z "$leaked_files" ]]; then
    passed_case_count=$((passed_case_count+1)); [[ -n "${SELFTEST_VERBOSE:-}" ]] && ok "install/不把溯源标记铺进项目"
  else
    failed_case_count=$((failed_case_count+1))
    bad "install/不把溯源标记铺进项目  这几份带着分发层的账："
    printf '%s\n' "$leaked_files" | sed "s|$install_target_project/||; s|^|        |"
    howto "install.sh 的 put() 在铺文件时要剥掉 generated-from 行。" \
          "它记的是译文译自哪个源文版本，是分发层的账，不是使用者项目的。"
  fi
else
  case_count=$((case_count+1)); failed_case_count=$((failed_case_count+1))
  bad "install/装不上：$(tail -1 "$install_output_file")"
  howto "看完整输出： cat $install_output_file"
fi

# 升级路径：上游改了内容而项目那份没跟上时，**版本戳不许刷**。
# 刷了就等于替项目声明「已经是新版了」，而它的 skill / 骨架还是旧的——
# 版本戳是项目唯一的「规矩变了」信号。
upgrade_source_package="$temporary_directory/install-upgrade"; cp -a "$SCRIPTS/.." "$upgrade_source_package"
upgrade_target_project="$temporary_directory/install-upgrade-project"; mkdir -p "$upgrade_target_project"
bash "$upgrade_source_package/install.sh" "$upgrade_target_project" >/dev/null 2>&1 || true
run_scripted "install/无变化时重装干净" 0 "跳过" -- bash "$upgrade_source_package/install.sh" "$upgrade_target_project"
sed -i '1s|^|# 上游改了这一行\n|' "$upgrade_source_package/templates/kb/decisions.md"
printf '9.9.9\n' > "$upgrade_source_package/VERSION"
run_scripted "install/内容落后就不刷版本戳" 1 "份内容落后于上游，版本戳**没有**刷新" -- \
  bash "$upgrade_source_package/install.sh" "$upgrade_target_project"
case_count=$((case_count+1))
if [[ "$(cat "$upgrade_target_project/.singlefs-ai-sop-version")" != "9.9.9" ]]; then passed_case_count=$((passed_case_count+1))
  [[ -n "${SELFTEST_VERBOSE:-}" ]] && ok "install/落后时版本戳确实没动"
else failed_case_count=$((failed_case_count+1)); bad "install/落后时版本戳被刷成了 9.9.9"
  howto "install.sh 在 STALE 非空时必须直接退出，不许走到写版本戳那一步。"
fi

# 接管清单：项目自己改过的那几份不该算「落后」——kb 骨架本来就是给项目改的。
# 少了它，任何一个动过自己 kb 的项目，装完第一次之后版本戳就再也刷不动
mkdir -p "$upgrade_target_project/.claude"
printf '.claude/kb/decisions.md  # 决策正文归项目，模板只给了格式\n' > "$upgrade_target_project/.claude/install-owned"
run_scripted "install/接管的那份不算落后" 0 "按 .claude/install-owned 不比对" -- \
  bash "$upgrade_source_package/install.sh" "$upgrade_target_project"
case_count=$((case_count+1))
if [[ "$(cat "$upgrade_target_project/.singlefs-ai-sop-version")" == "9.9.9" ]]; then passed_case_count=$((passed_case_count+1))
  [[ -n "${SELFTEST_VERBOSE:-}" ]] && ok "install/接管之后版本戳刷得动了"
else failed_case_count=$((failed_case_count+1)); bad "install/接管之后版本戳仍然没刷"
  howto "接管清单的用处就是让这几份不再算落后。它没生效，这条升级路就还是堵死的。"
fi

# 清单本身坏了不许放行：一份读不准的接管清单，等于把「落后就不刷戳」那道守卫悄悄关掉。
printf '.claude/kb/decisions.md\n' > "$upgrade_target_project/.claude/install-owned"
run_scripted "install/接管清单没写理由要红" 1 "这一条没写理由" -- bash "$upgrade_source_package/install.sh" "$upgrade_target_project"
printf 'research/nowhere.md  # 写了也没用\n' > "$upgrade_target_project/.claude/install-owned"
run_scripted "install/接管清单写了不铺的路径要红" 1 "install.sh 根本不铺" -- bash "$upgrade_source_package/install.sh" "$upgrade_target_project"
rm -f "$upgrade_target_project/.claude/install-owned"

# 清单坏了必须挡住，不只是报一句。「接管清单没写理由」「接管清单写了不铺的路径」这两个样本里同时还有内容落后，就算不挡也照样退 1，是那条路让它红的。
# 所以要一个没有别的落后的场景：少了这道拦截，install.sh 会带着一份读不准的清单把版本戳照刷不误。
ownership_source_package="$temporary_directory/install-ownership"; cp -a "$SCRIPTS/.." "$ownership_source_package"
ownership_target_project="$temporary_directory/install-ownership-project"; mkdir -p "$ownership_target_project"
bash "$ownership_source_package/install.sh" "$ownership_target_project" >/dev/null 2>&1 || true
printf '9.9.9\n' > "$ownership_source_package/VERSION"
mkdir -p "$ownership_target_project/.claude"
printf '.claude/kb/decisions.md\n' > "$ownership_target_project/.claude/install-owned"
run_scripted "install/清单坏了要挡住（此时没有别的落后）" 1 "接管清单有 1 处不合规" -- \
  bash "$ownership_source_package/install.sh" "$ownership_target_project"
case_count=$((case_count+1))
if [[ "$(cat "$ownership_target_project/.singlefs-ai-sop-version")" != "9.9.9" ]]; then passed_case_count=$((passed_case_count+1))
  [[ -n "${SELFTEST_VERBOSE:-}" ]] && ok "install/清单坏了时版本戳确实没动"
else failed_case_count=$((failed_case_count+1)); bad "install/清单坏了，版本戳还是被刷成了 9.9.9"
  howto "接管清单读不准的时候不许放行——那等于把「内容落后就不刷戳」这道守卫悄悄关掉。"
fi

# 退役的包装：共享脚本不在这一版里了，项目里一字未改的包装要被点名、版本戳不刷；
# 项目自己改过的同名文件不归 install.sh 管，照常刷戳。退役的那份照现行包装的样子造：把 gate 包装里的脚本名换成 lkmm。
retirement_source_package="$temporary_directory/install-retired"; cp -a "$SCRIPTS/.." "$retirement_source_package"
retirement_target_project="$temporary_directory/install-retired-project"; mkdir -p "$retirement_target_project"
bash "$retirement_source_package/install.sh" "$retirement_target_project" >/dev/null 2>&1 || true
sed 's#/scripts/gate\.sh"#/scripts/lkmm.sh"#' "$retirement_target_project/.claude/scripts/gate.sh" > "$retirement_target_project/.claude/scripts/lkmm.sh"
printf '9.9.9\n' > "$retirement_source_package/VERSION"
run_scripted "install/一字未改的退役包装要点名" 1 "份包装这一版已经不铺了" ".claude/scripts/lkmm.sh" -- \
  bash "$retirement_source_package/install.sh" "$retirement_target_project"
case_count=$((case_count+1))
if [[ "$(cat "$retirement_target_project/.singlefs-ai-sop-version")" != "9.9.9" ]]; then passed_case_count=$((passed_case_count+1))
  [[ -n "${SELFTEST_VERBOSE:-}" ]] && ok "install/留着退役包装时版本戳确实没动"
else failed_case_count=$((failed_case_count+1)); bad "install/留着退役包装，版本戳还是被刷成了 9.9.9"
  howto "退役包装还在时不许刷戳：戳说「新版」，项目里却留着一个转发到已删脚本的包装。"
fi
# 反面：项目照模板给一个还在的共享脚本自己加的包装，不是退役包装。
sed 's#/scripts/gate\.sh"#/scripts/bump.sh"#' "$retirement_target_project/.claude/scripts/gate.sh" > "$retirement_target_project/.claude/scripts/bump.sh"
# 这时 lkmm.sh 还在，install.sh 照样判红；要看的是点名的清单里没有 bump.sh。
run_scripted "install/照模板包一个还在的共享脚本不算退役" 0 "份包装这一版已经不铺了" "bump.sh 没被点名" -- \
  bash -c 'install_output="$(bash "$1/install.sh" "$2" 2>&1)"; printf "%s\n" "$install_output"
    [[ "$(printf "%s\n" "$install_output" | grep -c "scripts/bump.sh")" == 0 ]] && echo "bump.sh 没被点名"' install_retired_wrapper_check "$retirement_source_package" "$retirement_target_project"
# 0.0.49 以前铺的三行包装同样要认：只认现行形态时，旧形态的退役包装一声不响、照常刷戳。
legacy_retirement_target_project="$temporary_directory/install-retired-legacy"; mkdir -p "$legacy_retirement_target_project"
bash "$retirement_source_package/install.sh" "$legacy_retirement_target_project" >/dev/null 2>&1 || true
printf '%s\n' '#!/usr/bin/env bash' \
  '# 包装：转发到共享脚本。逻辑不写在这里，写在 .claude/singlefs-ai-sop/scripts/。' \
  'exec bash "$(dirname "${BASH_SOURCE[0]}")/../singlefs-ai-sop/scripts/lkmm.sh" "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" "$@"' \
  > "$legacy_retirement_target_project/.claude/scripts/lkmm.sh"
run_scripted "install/0.0.49 以前形态的退役包装也要点名" 1 "份包装这一版已经不铺了" ".claude/scripts/lkmm.sh" -- \
  bash "$retirement_source_package/install.sh" "$legacy_retirement_target_project"
printf '# 项目自己加的一行\n' >> "$retirement_target_project/.claude/scripts/lkmm.sh"
run_scripted "install/改过的同名文件不归它管" 0 "版本戳  .singlefs-ai-sop-version = 9.9.9" -- \
  bash "$retirement_source_package/install.sh" "$retirement_target_project"

# 接管清单里登记了、项目又删掉了的那份，不许重铺：put 只管不覆盖已有的文件，删掉的那份 kb 骨架
# 下一次 install.sh 又会被铺回来。
owned_absent_source_package="$temporary_directory/install-owned-absent"; cp -a "$SCRIPTS/.." "$owned_absent_source_package"
owned_absent_target_project="$temporary_directory/install-owned-absent-project"; mkdir -p "$owned_absent_target_project"
bash "$owned_absent_source_package/install.sh" "$owned_absent_target_project" >/dev/null 2>&1 || true
rm "$owned_absent_target_project/.claude/kb/pitfalls.md"
printf '.claude/kb/pitfalls.md  # 踩过的坑记在项目自己的另一处，这份骨架删掉\n' > "$owned_absent_target_project/.claude/install-owned"
run_scripted "install/接管清单里删掉的那份不重铺" 0 "已接管，项目删掉了它，不重铺" -- bash "$owned_absent_source_package/install.sh" "$owned_absent_target_project"
case_count=$((case_count+1))
if [[ ! -e "$owned_absent_target_project/.claude/kb/pitfalls.md" ]]; then passed_case_count=$((passed_case_count+1))
  [[ -n "${SELFTEST_VERBOSE:-}" ]] && ok "install/删掉又登记接管的那份确实没被铺回来"
else failed_case_count=$((failed_case_count+1)); bad "install/删掉又登记接管的那份，被 install.sh 铺回来了"
  howto "put() 在目标不存在、路径又在 install-owned 里时要跳过，不许新建。"
fi

# ════ lib.sh 的环境守卫 ═════════════════════════════════
# 两道守卫都是「判定结果不许随环境变」的前提，坏了不会报错，只会悄悄改判。
head1 "门禁自证：环境守卫的判别力"

# LC_ALL：lib.sh 把 locale 钉成 UTF-8。摘掉之后，C locale 下 gawk 按字节走，
# doc-lint 的编号引用检查会把每处「D1（简称）」都误判成「括注没闭合」。
# 故意用 LC_ALL=C 跑一个该绿的样本：守卫在 → 绿；守卫没了 → 一片假红。
run_scripted "lib/LC_ALL 被钉住（C locale 下判定不变）" 0 检查通过 -- \
  env LC_ALL=C DOC_LINT_LANG=zh bash "$SCRIPTS/doc-lint.sh" "$fixtures_directory/doc-lint/good"

# gawk：mawk 的 substr/length 按字节走，同一份 kb 会得出不同判定。
# 伪造一个自称 mawk 的 awk 摆在 PATH 最前面，门禁必须拒绝跑，而不是照跑。
fake_awk_directory="$temporary_directory/fake-awk"; mkdir -p "$fake_awk_directory"
printf '#!/bin/sh\n[ "$1" = --version ] && { echo "mawk 1.3.4 20200120"; exit 0; }\nexec /usr/bin/awk "$@"\n' \
  > "$fake_awk_directory/awk"; chmod +x "$fake_awk_directory/awk"
run_scripted "lib/不是 gawk 就拒绝跑" 1 需要 gawk -- \
  env PATH="$fake_awk_directory:$PATH" bash "$SCRIPTS/doc-lint.sh" "$fixtures_directory/doc-lint/good"

# die 的运行期兜底：gate-lint 在调用点静态拦裸 die，但它自己写明有几种形态
# 「认不出、不判」（消息是变量、引号被转义拆开）。那几种只剩这道运行期兜底：
# 删掉它，`die "只有一句"` 的输出里就再没有出路。
run_scripted "lib/die 少了出路也要兜一句" 1 怎么办 -- \
  bash -c 'source "$1/lib.sh"; die "只有一句"' die_without_next_step "$SCRIPTS"

# ════ manifest：CLAUDE.md 必须在清单里 ═══════════════════
# manifest.sh 专门写了一段解释它为什么在清单里（它是规范正文、还规定对话语言）。
# 把它从 generate_manifest() 里摘掉，只改 CLAUDE.md 时清单要判不一致。
head1 "门禁自证：manifest 覆盖面"
reference_package="$temporary_directory/manifest-claude/f-zh"; mkdir -p "$(dirname "$reference_package")"; make_reference_package "$reference_package" f
printf '改了规范正文\n' >> "$reference_package/CLAUDE.md"
run_scripted "manifest/只改 CLAUDE.md 也要红" 1 不一致 -- bash "$reference_package/scripts/manifest.sh"

# agents 层为空时必须显式说出来。空是状态不是通过——
# 「没有」和「忘了」在目录里长得一模一样。
reference_package="$temporary_directory/manifest-empty-agents/f-zh"; mkdir -p "$(dirname "$reference_package")"; make_reference_package "$reference_package" f
rm -f "$reference_package/agents/a.md"
bash "$reference_package/scripts/manifest.sh" --update >/dev/null
run_scripted "manifest/agents 为空要说出来" 0 "本层已纳入治理，当前为空：agents/" -- bash "$reference_package/scripts/manifest.sh"

# 覆盖率：面向人的文本两边都不沾就红。少了它，新加一份 .md 会静默留在共享区说中文。
reference_package="$temporary_directory/manifest-orphan/f-zh"; mkdir -p "$(dirname "$reference_package")"; make_reference_package "$reference_package" f
mkdir -p "$reference_package/records"; printf '# 一份没人认领的文档\n' > "$reference_package/records/x.md"
run_scripted "manifest/没归属的文本要红" 1 "既没进清单、也没显式豁免" -- bash "$reference_package/scripts/manifest.sh"

# 反过来：显式豁免的那几份不许被这条检查误伤
reference_package="$temporary_directory/manifest-exempt/f-zh"; mkdir -p "$(dirname "$reference_package")"; make_reference_package "$reference_package" f
printf '# 门面\n' > "$reference_package/README.md"; printf '# 历史\n' > "$reference_package/CHANGELOG.md"
run_scripted "manifest/显式豁免的不算漏" 0 没有漏归属 -- bash "$reference_package/scripts/manifest.sh"

# 无对象可判退 77，不退 0：译本仓没有清单可判、没有 I18N、languages= 里除本仓外没有别的语言（gate.sh 记「本次未跑」，不记通过）
reference_package="$temporary_directory/manifest-translated/f-zh"; mkdir -p "$(dirname "$reference_package")"; make_reference_package "$reference_package" f
sed -i 's/^this=zh$/this=en/' "$reference_package/I18N"
run_scripted "manifest/译本仓里无对象可判退 77" 77 "清单以 zh 仓为准，本阶段无对象可判" -- bash "$reference_package/scripts/manifest.sh"
run_scripted "manifest/译本仓里 --update 什么也不做" 0 "--update 什么也没做" -- bash "$reference_package/scripts/manifest.sh" --update
run_scripted "i18n-sync/译本仓里无对象可判退 77" 77 "同步以 zh 仓为准，本阶段无对象可判" -- bash "$reference_package/scripts/i18n-sync.sh"
# --update / --stamp 是动作：在译本仓里跑，--update 说清什么也没做、退 0；--stamp 拒绝并指到参照仓，都不说「无对象可判」
run_scripted "i18n-sync/译本仓里 --update 什么也不做" 0 "--update 什么也没做" -- bash "$reference_package/scripts/i18n-sync.sh" --update
run_scripted "i18n-sync/译本仓里 --stamp 要指到参照仓" 1 "溯源标记要在参照仓（zh）里盖" -- bash "$reference_package/scripts/i18n-sync.sh" --stamp ja rules/a.md
reference_package="$temporary_directory/i18n-only-self/f-zh"; mkdir -p "$(dirname "$reference_package")"; make_reference_package "$reference_package" f
sed -i 's/^languages=.*/languages=zh/' "$reference_package/I18N"
run_scripted "i18n-sync/除本仓外没有别的语言退 77" 77 "没有译本仓可比" -- bash "$reference_package/scripts/i18n-sync.sh"
reference_package="$temporary_directory/i18n-no-i18n/f-zh"; mkdir -p "$(dirname "$reference_package")"; make_reference_package "$reference_package" f; rm -f "$reference_package/I18N"
run_scripted "i18n-sync/没有 I18N 退 77" 77 "未声明语言族" -- bash "$reference_package/scripts/i18n-sync.sh"

# ════ link-targets、env.sh、rules-lint --not-impl ══════════
head1 "门禁自证：link-targets / env / rules-lint --not-impl 的判别力"
# link-targets 按当前目录找文档：门禁里是先 cd 到项目根再起它
link_targets_run_in_directory=(bash -c 'cd "$1" && python3 "$2/link-targets.py"' link_targets_run_in_directory)
link_targets_project="$temporary_directory/link-targets"; mkdir -p "$link_targets_project/docs"
printf '# 甲\n\n见 [乙](b.md)。\n' > "$link_targets_project/docs/a.md"; printf '# 乙\n' > "$link_targets_project/docs/b.md"
run_scripted "link-targets/链接都到得了就通过" 0 "2 份文档、1 条相对链接" -- "${link_targets_run_in_directory[@]}" "$link_targets_project" "$SCRIPTS"
printf '见 [丙](c.md)。\n' >> "$link_targets_project/docs/a.md"
run_scripted "link-targets/指到不存在的文件判红" 1 "那里没有东西" -- "${link_targets_run_in_directory[@]}" "$link_targets_project" "$SCRIPTS"
# 读不了的文档（坏掉的符号链接、不是 UTF-8）不许静默跳过：它里面的链接一条都没查，成功那句却照报「都到得了」
link_targets_project="$temporary_directory/link-targets-unreadable"; mkdir -p "$link_targets_project/docs"
printf '# 甲\n' > "$link_targets_project/docs/a.md"; ln -s nowhere.md "$link_targets_project/docs/broken.md"
run_scripted "link-targets/读不了的文档判红" 1 "broken.md 读不了，里面的链接一条都没查" -- "${link_targets_run_in_directory[@]}" "$link_targets_project" "$SCRIPTS"
link_targets_project="$temporary_directory/link-targets-encoding"; mkdir -p "$link_targets_project/docs"
printf '# \xff\xfe\n' > "$link_targets_project/docs/latin.md"
run_scripted "link-targets/不是 UTF-8 的文档判红" 1 "latin.md 读不了" -- "${link_targets_run_in_directory[@]}" "$link_targets_project" "$SCRIPTS"
# 「第 N 节」指到一份不是 UTF-8 的文档：数它的节时也要接住，不许抛 traceback 退出、没有出路
link_targets_project="$temporary_directory/link-targets-section-encoding"; mkdir -p "$link_targets_project/docs" "$link_targets_project/other"
printf '# \xff\xfe\n' > "$link_targets_project/other/latin.md"; printf '# 甲\n\n见 [它](../other/latin.md) 第二节。\n' > "$link_targets_project/docs/a.md"
run_scripted "link-targets/第 N 节指到读不出的文档判红" 1 "数不了它有几节" -- "${link_targets_run_in_directory[@]}" "$link_targets_project/docs" "$SCRIPTS"
# 项目登记了自定义门禁目录（rules/sop-first.md）：它的 fixtures/ 才该被跳过，不是默认的 .claude/gate.d/fixtures/
link_targets_project="$temporary_directory/link-targets-registered-gate-directory"; mkdir -p "$link_targets_project/docs" "$link_targets_project/scripts/gates/fixtures" "$link_targets_project/.claude"
printf 'scripts/gates  # 工程脚本统一挪进项目仓根 scripts/\n' > "$link_targets_project/.claude/gate-directory"
printf '# 甲\n' > "$link_targets_project/docs/a.md"
printf '见 [不在](nowhere.md)。\n' > "$link_targets_project/scripts/gates/fixtures/sample.md"
run_scripted "link-targets/登记了自定义门禁目录就跳过它的 fixtures" 0 "1 份文档" -- "${link_targets_run_in_directory[@]}" "$link_targets_project" "$SCRIPTS"
link_targets_project="$temporary_directory/link-targets-copy"; make_installed_copy "$link_targets_project" demo-sop; mkdir -p "$link_targets_project/docs" "$link_targets_project/.claude/demo-sop/rules"
printf '# 甲\n' > "$link_targets_project/docs/a.md"; printf '见 [不在](nowhere.md)。\n' > "$link_targets_project/.claude/demo-sop/rules/a.md"
run_scripted "link-targets/副本按 I18N 的 family 认、不判" 0 "1 份文档" -- "${link_targets_run_in_directory[@]}" "$link_targets_project" "$link_targets_project/.claude/demo-sop/scripts"

# env.sh 的 git 版本下限（2.28）：主、次版本号拼成一个串再切的话，2.8–2.27 都会被算成够新
fake_git_versions_directory="$temporary_directory/env-git"; mkdir -p "$fake_git_versions_directory/old" "$fake_git_versions_directory/new"
printf '#!/usr/bin/env bash\n[[ "${1:-}" == --version ]] && { echo "git version 2.27.0"; exit 0; }\nexec %q "$@"\n' "$(command -v git)" > "$fake_git_versions_directory/old/git"
printf '#!/usr/bin/env bash\n[[ "${1:-}" == --version ]] && { echo "git version 2.28.1"; exit 0; }\nexec %q "$@"\n' "$(command -v git)" > "$fake_git_versions_directory/new/git"
chmod +x "$fake_git_versions_directory/old/git" "$fake_git_versions_directory/new/git"
# 只看 git 这一条判没判：env.sh 的退出码还取决于这台机器缺不缺别的工具
environment_check_reports_old_git=(bash -c 'env_output="$(env PATH="$1:$PATH" bash "$2/env.sh" 2>&1)"; printf "%s\n" "$env_output"
  if grep -q "git 版本过低（git version" <<<"$env_output"; then echo "判定：报了 git 过低"; else echo "判定：没报 git 过低"; fi' environment_check_reports_old_git)
run_scripted "env/git 2.27 判过低" 0 "判定：报了 git 过低" -- "${environment_check_reports_old_git[@]}" "$fake_git_versions_directory/old" "$SCRIPTS"
run_scripted "env/git 2.28 不判过低" 0 "判定：没报 git 过低" -- "${environment_check_reports_old_git[@]}" "$fake_git_versions_directory/new" "$SCRIPTS"

# rules-lint --not-impl：本包的语言上没实现时报一行（gate.sh 收进未实现清单），实现了什么都不打。语言看包自己的 I18N
make_rules_lint_package() { # make_rules_lint_package <目录> <本包语言>
  mkdir -p "$1/scripts"
  cp "$SCRIPTS/lib.sh" "$SCRIPTS/preflight.py" "$SCRIPTS/preflight.sh" "$SCRIPTS/proc.py" "$SCRIPTS/rules-lint.sh" "$1/scripts/"
  printf 'family=f\nthis=%s\nreference=zh\ndefault=zh\nlanguages=zh en\n' "$2" > "$1/I18N"
}
rules_lint_package="$temporary_directory/rules-lint-not-implemented-zh"; make_rules_lint_package "$rules_lint_package" zh
run_scripted "rules-lint/--not-impl 在中文包里什么都不打" 0 "未实现清单为空" -- \
  bash -c 'rules_not_implemented="$(bash "$1/scripts/rules-lint.sh" --not-impl)" || exit $?; [[ -z "$rules_not_implemented" ]] && echo "未实现清单为空"' rules_lint_not_implemented_zh "$rules_lint_package"
rules_lint_package="$temporary_directory/rules-lint-not-implemented-en"; make_rules_lint_package "$rules_lint_package" en
run_scripted "rules-lint/--not-impl 在英文包里报没实现的那几条" 0 "规则纪律（en）：解释性段落与半句只认「标签词加冒号」这一种" -- bash "$rules_lint_package/scripts/rules-lint.sh" --not-impl
rules_lint_package="$temporary_directory/rules-lint-not-implemented-xx"; make_rules_lint_package "$rules_lint_package" xx
run_scripted "rules-lint/--not-impl 在没有词表的语言包里报整项未实现" 0 "规则纪律（xx）：本语言没有词表，这一项未实现" -- bash "$rules_lint_package/scripts/rules-lint.sh" --not-impl
run_scripted "rules-lint/没有词表的语言退 77，不记通过" 77 "规则纪律没有 xx 的词表" -- \
  env RULES_LINT_DIR="$fixtures_directory/rules-lint/ok/rules" bash "$rules_lint_package/scripts/rules-lint.sh" "$fixtures_directory/rules-lint/ok"

# ════ push-all ═══════════════════════════════════════════
head1 "门禁自证：push-all 的判别力"
# 三个语言仓各带一个没推的提交，各配一个本地裸仓当远端；gate.sh 用桩，红绿由参数定。
# 推 master 只走 push-all.sh：先验完三个仓，才逐个连远端推验过的那个提交；直接 git push master 由钩子当场拒绝。
make_push_family() { # make_push_family <目录> [门禁判红的语言] [门禁跑的时候又提交一次的语言]
  local family_root="$1" red_language="${2:-}" moving_language="${3:-}" language language_repository
  mkdir -p "$family_root"
  for language in zh en ja; do
    language_repository="$family_root/fam-$language"
    git init -q --bare -b master "$family_root/remote-$language.git"
    git init -q -b master "$language_repository"
    mkdir -p "$language_repository/scripts/githooks"
    cp "$SCRIPTS/push-all.sh" "$SCRIPTS/lib.sh" "$SCRIPTS/preflight.py" "$SCRIPTS/preflight.sh" "$SCRIPTS/proc.py" "$language_repository/scripts/"
    cp "$SCRIPTS/githooks/pre-push" "$language_repository/scripts/githooks/"
    if [[ "$language" == "$red_language" ]]; then
      printf '#!/usr/bin/env bash\necho "  桩门禁判红"\nexit 1\n' > "$language_repository/scripts/gate.sh"
    elif [[ "$language" == "$moving_language" ]]; then
      # 验的这段时间里别的会话提交了：门禁跑到一半，仓里多出一个提交
      printf '#!/usr/bin/env bash\ngit -c user.name=selftest -c user.email=selftest@invalid commit -q --allow-empty -m 验的过程中又提交了一个\nexit 0\n' > "$language_repository/scripts/gate.sh"
    else
      printf '#!/usr/bin/env bash\nexit 0\n' > "$language_repository/scripts/gate.sh"
    fi
    printf 'family=fam\nthis=%s\nreference=zh\ndefault=en\nlanguages=zh ja en\n' "$language" > "$language_repository/I18N"
    echo 0.0.1 > "$language_repository/VERSION"
    git -C "$language_repository" add -A
    git -C "$language_repository" -c user.name=selftest -c user.email=selftest@invalid commit -qm 起点
    git -C "$language_repository" remote add origin "$family_root/remote-$language.git"
    git -C "$language_repository" push -q origin master
    echo 0.0.2 > "$language_repository/VERSION"
    git -C "$language_repository" -c user.name=selftest -c user.email=selftest@invalid commit -qam 待推
    git -C "$language_repository" config core.hooksPath scripts/githooks
  done
}
# 远端 master 与本地 HEAD 逐仓比：all = 三个都到了，none = 一个都没到。
# 写成独立的 bash 程序而不是函数：run_scripted 经 timeout 执行命令，timeout 看不见 shell 函数（退出码 127）。
remotes_state=(bash -c '
  family_root="$1" expected_state="$2" matched_count=0
  for language in zh en ja; do
    [[ "$(git -C "$family_root/fam-$language" rev-parse HEAD)" == "$(git -C "$family_root/remote-$language.git" rev-parse master)" ]] \
      && matched_count=$((matched_count+1))
  done
  echo "远端对上本地的仓：$matched_count 个"
  if [[ "$expected_state" == all ]]; then [[ $matched_count == 3 ]]; else [[ $matched_count == 0 ]]; fi' remotes_state)

push_family_directory="$temporary_directory/push-green"; make_push_family "$push_family_directory"
run_scripted "push-all/三仓全绿：跑 push-all.sh 就三个一起推" 0 "ja：已推" "en：已推" "zh：已推" "3 个语言仓都推上去了" -- \
  bash "$push_family_directory/fam-zh/scripts/push-all.sh"
run_scripted "push-all/全绿之后三个远端都到了本地的提交" 0 "远端对上本地的仓：3 个" -- "${remotes_state[@]}" "$push_family_directory" all

# 直接 git push master：钩子当场拒绝、一个仓都不推，指回 push-all.sh（验证不许放在已经连上的连接里跑）
push_family_directory="$temporary_directory/push-direct"; make_push_family "$push_family_directory"
run_scripted "push-all/直接 git push master 当场拒绝" 1 "直接 git push master 不放行" "bash scripts/push-all.sh" -- \
  git -C "$push_family_directory/fam-zh" push origin master
run_scripted "push-all/直接 git push 被拒时三个远端都没动" 0 "远端对上本地的仓：0 个" -- "${remotes_state[@]}" "$push_family_directory" none
run_scripted "push-all/推别的分支钩子照常放行" 0 "推的不是 master" -- \
  git -C "$push_family_directory/fam-zh" push origin master:refs/heads/topic

push_family_directory="$temporary_directory/push-dirty"; make_push_family "$push_family_directory"; echo 没提交 > "$push_family_directory/fam-en/stray"
run_scripted "push-all/有一个仓工作区不干净就一个都不推" 1 "en：工作区不干净" "一个仓都没推" -- \
  bash "$push_family_directory/fam-zh/scripts/push-all.sh"
run_scripted "push-all/工作区不干净时三个远端都没动" 0 "远端对上本地的仓：0 个" -- "${remotes_state[@]}" "$push_family_directory" none

push_family_directory="$temporary_directory/push-version"; make_push_family "$push_family_directory"; echo 0.0.3 > "$push_family_directory/fam-ja/VERSION"
git -C "$push_family_directory/fam-ja" -c user.name=selftest -c user.email=selftest@invalid commit -qam 版本漂了
run_scripted "push-all/VERSION 不一致就拒" 1 "ja：VERSION 是 0.0.3，而 zh 是 0.0.2" -- \
  bash "$push_family_directory/fam-zh/scripts/push-all.sh"

push_family_directory="$temporary_directory/push-gate-red"; make_push_family "$push_family_directory" ja
run_scripted "push-all/任一仓门禁红就拒" 1 "ja：门禁没过" "桩门禁判红" -- \
  bash "$push_family_directory/fam-zh/scripts/push-all.sh"
run_scripted "push-all/门禁红时三个远端都没动" 0 "远端对上本地的仓：0 个" -- "${remotes_state[@]}" "$push_family_directory" none

# 验完到推之间有人提交：推的就不是验过的那一份，一个都不推
push_family_directory="$temporary_directory/push-moved"; make_push_family "$push_family_directory" "" en
run_scripted "push-all/验完之后 HEAD 变了就一个都不推" 1 "en：验完之后 HEAD 变了" "一个仓都没推" -- \
  bash "$push_family_directory/fam-zh/scripts/push-all.sh"
run_scripted "push-all/HEAD 变了时三个远端都没动" 0 "远端对上本地的仓：0 个" -- "${remotes_state[@]}" "$push_family_directory" none

# 带着 GIT_DIR 在 git worktree 里跑：GIT_DIR 指向 zh，它压过 `git -C`。
# push-all.sh 开头不清掉它的话，对 ja、en 的查验和推送都会落在 zh 上，这两个远端就到不了。
push_family_directory="$temporary_directory/push-worktree"; make_push_family "$push_family_directory"
git -C "$push_family_directory/fam-zh" switch -q -c parking
git -C "$push_family_directory/fam-zh" worktree add -q "$push_family_directory/worktree-zh" master
run_scripted "push-all/带着 GIT_DIR 在 git worktree 里跑也三个一起推" 0 "ja：已推" "en：已推" "zh：已推" -- \
  env GIT_DIR="$(git -C "$push_family_directory/worktree-zh" rev-parse --absolute-git-dir)" bash "$push_family_directory/worktree-zh/scripts/push-all.sh"
run_scripted "push-all/worktree 里推完三个远端都到了本地的提交" 0 "远端对上本地的仓：3 个" -- "${remotes_state[@]}" "$push_family_directory" all

# 推到一半失败：en 的远端有一个本地没有的提交 ⇒ ja 已推、en 被拒、zh 不推，而且要报出已推的是哪些
push_family_directory="$temporary_directory/push-partial"; make_push_family "$push_family_directory"
git clone -q "$push_family_directory/remote-en.git" "$push_family_directory/other-en"
echo 别处 > "$push_family_directory/other-en/elsewhere"; git -C "$push_family_directory/other-en" add elsewhere
git -C "$push_family_directory/other-en" -c user.name=selftest -c user.email=selftest@invalid commit -qm 别处的提交
git -C "$push_family_directory/other-en" push -q origin master
run_scripted "push-all/推到一半被拒要报出已推的仓" 1 "en：推送失败" "已经推上去的：ja" -- \
  bash "$push_family_directory/fam-zh/scripts/push-all.sh"

# ── 汇总 ────────────────────────────────────────────────
say ""
[[ $case_count -gt 0 ]] || { bad "一个用例都没跑"
  howto "样本目录空了。至少要有一个该绿的和一个该红的，否则这个自证本身什么也不证明。"; exit 1; }
[[ $failed_case_count -eq 0 ]] || { bad "门禁自证失败：$failed_case_count 个用例判错（共 $case_count）"; exit 1; }   # gate-lint:summary
ok "门禁自证通过：$passed_case_count 个用例判定与预期一致（SELFTEST_VERBOSE=1 看逐条）；本次未跑 $PREFLIGHT_PARTS_NOT_RUN 部分"
# 记下这一次的输入指纹（文件头的 inputs-changed）；有一部分本次未跑时 preflight_record_success 不记，下一次照跑
preflight_record_success
