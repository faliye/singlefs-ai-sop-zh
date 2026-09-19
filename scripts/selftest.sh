#!/usr/bin/env bash
# 门禁自己的测试：拿一组「本该红」和「本该绿」的样本喂给各个门禁脚本，看它判得对不对。
#
# 为什么必须有（rules/sop-first.md）：
#   改了 scripts/ 就得造一个应该被拦的输入，确认它真的会红。
#   没有自检能力的门禁是摆设——一条永远不红的检查与没有这条检查，
#   在门禁输出里长得一模一样。
#
# 每个门禁脚本都要有自己的样本或脚本化用例，**包括 gate.sh 自己**——
# 它是整道门禁唯一的判决点，而它长期不在覆盖之内：把 run_stage 改成无条件记 PASS，
# 造一处真实的文档违规，gate.sh 退出码是 0，而自检 69 例全绿（复核实测）。
#
# **等价变异分开记，不算盲区**（`rules/test-discipline.md`）。复核跑了 126 个变异，
# 剩下门禁察觉不到的，逐个验过都是等价的：
#   - shell-lint 赋值循环里的 local/declare 跳过删掉——`loc[]` 预扫已经收了那些名字
#   - show-me-test 的 `test_files` 正则不再要求 .rs——内容级检查兜住
#   - i18n-sync 的「缺 SOURCE-MANIFEST」检查删掉——被下游的清单比对级联兜住
# 这几条不补样本：补了也只是把等价性再证一遍。
#
# 两类盲区都要盯，方向相反、代价不同：
#   **该红不红** —— 删掉一条检查，违规被放行。最贵。
#   **该绿变红** —— 删掉一条豁免，正常写法被误拒。门禁一旦开始误拒，人就会绕过它。
# 所以每个脚本既要有红样本，也要有**踩在豁免边界上**的绿样本
# （注释里的 bad、历史节里的「曾经 X」、heredoc 里的赋值、local 同名变量…）。
#
# 两类用例：
#   1. 样本目录  scripts/fixtures/<脚本名>/<样本名>/：
#      喂进去的内容 + expect（exit=0|1，红样本再加至少一条 want=<输出里必须出现的片段>）
#   2. 脚本化用例（要临时 git 仓才能摆出来的场景）：在本文件里现搭现跑
#
# want 存在的理由：只比对退出码的话，一个「因为别的原因红了」的样本也算过，
# 于是被测的那条检查悄悄失效也看不出来。
#
# ⚠️ **want 必须指着那条检查自己的消息，不能是几条检查共用的片段。**
# 本轮审计的变异测试实测：doc-lint 的整组历史陈述模式删光、CLAUDE.md 历史节检查
# 删光、kb 历史节检查删光、gate-lint 的窗口从 5 改成 99、
# show-me-test 的标注集缩到只认 #[test]——**每一条都全绿**。
# 根因是 blind 样本一次触发六类违规，而它的 want 写成了「正文不许」，
# 上下文指代那条消息也含这四个字。所以：一个样本触发多类违规时，
# 每一类都要有自己的 want；宁可多写几个单一职责的样本。
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FX="$SCRIPTS/fixtures"
tmpd="$(mktemp -d)"; trap 'rm -rf "$tmpd"' EXIT
# 样本仓不受用户全局 git 配置影响。`commit.gpgsign=true` 之类会让第一个样本仓就建不起来，
# 而 set -e 在那里把整个自检带走——「判错 0 条」加一行 git 的报错，看着不像自检失败（审计实测 rc=128）。
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

pass=0; fails=0; cases=0

# ── 断言器：退出码 + 输出片段 ───────────────────────────
judge() { # judge <名> <期望exit> <实际exit> <输出文件> [want片段...]
  cases=$((cases+1))
  local name="$1" wexit="$2" gexit="$3" out="$4"; shift 4
  local ok_this=1
  if [[ "$gexit" != "$wexit" ]]; then
    bad "$name  退出码 $gexit，应为 $wexit"
    howto "看这个用例的完整输出： cat $out" \
          "样本本身该改就改预期，检查坏了就改检查——别两边一起改到自洽为止。"
    ok_this=0
  else
    local w
    for w in "$@"; do
      [[ -z "$w" ]] && continue
      grep -qF -- "$w" "$out" || {
        bad "$name  退出码对，但输出里没有「$w」"
        howto "退出码对不等于拦对了原因——可能是因为别的检查红的。" \
              "看输出： cat $out"
        ok_this=0; }
    done
  fi
  if [[ $ok_this -eq 1 ]]; then
    pass=$((pass+1)); [[ -n "${SELFTEST_VERBOSE:-}" ]] && ok "$name"
  else
    fails=$((fails+1))
  fi
  return 0
}

# 两种跑法起子进程时都清掉 GATE_BASE 与 GATE_STAGED_FROM：gate.sh 把本脚本当一个阶段跑，
# 用户指定的 diff 基准、--staged 的握手变量都在环境里；子进程继承了，嵌套跑的 gate.sh / show-me-test.sh
# 就按外面那个项目的基准与兄弟目录判（审计实测：GATE_STAGED_FROM 在环境里时「上游比副本旧」两例反红，
# GATE_BASE=HEAD 时 show-me-test 两例退 3）。清的动作只在这两行，对应的用例在 gate 那一节。
# ── 样本目录跑法：expect 文件驱动 ───────────────────────
run_fixture() { # run_fixture <标签> <样本目录> <命令...>（命令自行引用样本目录）
  local label="$1" d="$2"; shift 2
  [[ -f "$d/expect" ]] || { cases=$((cases+1)); fails=$((fails+1))
    bad "$label 缺 expect 文件"
    howto "写一行 exit=0 或 exit=1，红的样本再加至少一条 want=<输出片段>。"
    return 0; }
  local wexit; wexit="$(sed -n 's/^exit=//p' "$d/expect")"
  local wants=(); local w
  while IFS= read -r w; do wants+=("$w"); done < <(sed -n 's/^want=//p' "$d/expect")
  local out="$tmpd/$(printf '%s' "$label" | tr '/ ' '__').out"
  local rc=0
  # 超时保护：挂死的检查在门禁输出里既不红也不绿，只是永远不回来——
  # 比红的门禁危险（本轮实测：gate-lint 的一处无限循环跑了 9 分钟没结束）。
  set +e; timeout "${SELFTEST_TIMEOUT:-60}" env -u GATE_BASE -u GATE_STAGED_FROM "$@" > "$out" 2>&1; rc=$?; set -e
  [[ $rc == 124 ]] && say "        （超时 ${SELFTEST_TIMEOUT:-60}s，按判错记）"
  judge "$label" "$wexit" "$rc" "$out" ${wants[@]+"${wants[@]}"}
}

# ── 样本目录并行跑法：先把一批派出去，再按派活顺序逐个判 ──
# 一批样本之间互不依赖，而每一项都要起一个子进程（起 bash、起 python、扫一遍样本目录），
# 所以并行跑（rules/command-safety.md「一个脚本里的检测项，能并行就并行」）。
# 判定一个字都不并行：judge 仍在主 shell 里按派活顺序跑，输出顺序与串行时相同。
#
# **还没并行的那一半，写在这里免得被当成已经做完**：脚本化用例（run_scripted）要现搭 git 仓、
# 现写文件，搭建与判定在正文里交织，并行化要重写整个脚本的结构，这一轮没做。
# 2026-09-19 实测：并行之后的 21.4 秒里，样本批已经不占什么，约 11 秒是这批脚本化用例，
# 另外 10 秒是 proc 那个故意空等的用例。
#
# 退出码一律走 .rc 文件，不靠 wait 的返回值，也不靠后台作业里的赋值：
# 不带参数的 wait 恒返回 0，后台体是子 shell 赋值传不回来——两样都会把红样本变成绿的
# （rules/command-safety.md「并行不许把失败吃掉」，shell-lint 的 S6 判这一条）。
SELFTEST_JOBS="${SELFTEST_JOBS:-$(nproc 2>/dev/null || echo 4)}"
spawn_labels=(); spawn_dirs=(); inflight=0
fixture_out() { printf '%s/%s.out' "$tmpd" "$(printf '%s' "$1" | tr '/ ' '__')"; }

spawn_fixture() { # spawn_fixture <标签> <样本目录> <命令...>（命令自行引用样本目录）
  local label="$1" d="$2"; shift 2
  spawn_labels+=("$label")
  # 缺 expect 的不派活，占一个空位，collect 时按原来那句话报——与串行时判得一样
  if [[ ! -f "$d/expect" ]]; then spawn_dirs+=(""); return 0; fi
  spawn_dirs+=("$d")
  local out; out="$(fixture_out "$label")"
  rm -f "$out" "$out.rc"
  # 退出码在 if 里取：lib.sh 开着 set -e，写成「里层; echo $? > 文件」的话，样本一判红
  # 子 shell 就在那一行退出，.rc 一个字都不写——红样本全体没有退出码文件
  # （rules/command-safety.md「进程边界上的三种静默失效」第一行；写这段时实测 119 例）。
  ( local_rc=0
    if timeout "${SELFTEST_TIMEOUT:-60}" env -u GATE_BASE -u GATE_STAGED_FROM "$@" > "$out" 2>&1
    then local_rc=0; else local_rc=$?; fi
    echo "$local_rc" > "$out.rc" ) &
  inflight=$((inflight+1))
  # 在手的作业到上限就先收一个。`wait -n` 拿回来的是样本自己的退出码，红样本本来就非 0，
  # 不加 `|| true` 的话 set -e 会在第一个红样本上把整个自检带走（写这段时实测）。
  while [[ $inflight -ge $SELFTEST_JOBS ]]; do wait -n || true; inflight=$((inflight-1)); done
}

collect_fixtures() { # 等这一批跑完，按派活顺序逐个判
  while [[ $inflight -gt 0 ]]; do wait -n || true; inflight=$((inflight-1)); done
  local i label d out rc wexit w; local wants
  for i in "${!spawn_labels[@]}"; do
    label="${spawn_labels[$i]}"; d="${spawn_dirs[$i]}"
    if [[ -z "$d" ]]; then
      cases=$((cases+1)); fails=$((fails+1))
      bad "$label 缺 expect 文件"
      howto "写一行 exit=0 或 exit=1，红的样本再加至少一条 want=<输出片段>。"
      continue
    fi
    out="$(fixture_out "$label")"
    # 派出去多少项，就要收回来多少项：一项没跑完时它的 .rc 根本不存在，
    # 而循环少转一圈是不报错的，末尾照样报绿（rules/command-safety.md）。
    if [[ ! -f "$out.rc" ]]; then
      cases=$((cases+1)); fails=$((fails+1))
      bad "$label 派出去了，却没有退出码文件"
      howto "这一项的后台作业没跑完，或者被杀了——自检不许把它当通过。" \
            "看它的输出： cat $out"
      continue
    fi
    rc="$(cat "$out.rc")"
    [[ $rc == 124 ]] && say "        （超时 ${SELFTEST_TIMEOUT:-60}s，按判错记）"
    wexit="$(sed -n 's/^exit=//p' "$d/expect")"
    wants=()
    while IFS= read -r w; do wants+=("$w"); done < <(sed -n 's/^want=//p' "$d/expect")
    judge "$label" "$wexit" "$rc" "$out" ${wants[@]+"${wants[@]}"}
  done
  spawn_labels=(); spawn_dirs=()
}

# ── 脚本化用例跑法 ──────────────────────────────────────
run_scripted() { # run_scripted <名> <期望exit> <want...> -- <命令...>
  local name="$1" wexit="$2"; shift 2
  local wants=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do wants+=("$1"); shift; done
  shift
  local out="$tmpd/$(printf '%s' "$name" | tr '/ ' '__').out"
  local rc=0
  # 超时保护：挂死的检查在门禁输出里既不红也不绿，只是永远不回来——
  # 比红的门禁危险（本轮实测：gate-lint 的一处无限循环跑了 9 分钟没结束）。
  set +e; timeout "${SELFTEST_TIMEOUT:-60}" env -u GATE_BASE -u GATE_STAGED_FROM "$@" > "$out" 2>&1; rc=$?; set -e
  [[ $rc == 124 ]] && say "        （超时 ${SELFTEST_TIMEOUT:-60}s，按判错记）"
  judge "$name" "$wexit" "$rc" "$out" ${wants[@]+"${wants[@]}"}
}

# ════ doc-lint ═══════════════════════════════════════════
head1 "门禁自检：doc-lint 的判别力"
[[ -d "$FX/doc-lint" ]] || { bad "缺样本目录 $FX/doc-lint"
  howto "样本要随仓走。没有样本，下一个改 doc-lint.sh 的人无从复跑。"; exit 1; }
# ⚠️ **样本一律按 zh 判**。样本是中文写的，而 scripts/ 会逐字节复制进每个语言仓：
# 不钉住语言的话，en 仓里这批样本被拿去跟 `## Revision history` 对判，44 例一起假红，
# 而 doc-lint 自己一个字都没坏（实测：en / ja 两仓的门禁从 0.0.25 起一直红着，就是这个）。
# 语言是**样本的属性**，不是仓的属性。
for d in "$FX"/doc-lint/*/; do
  spawn_fixture "doc-lint/$(basename "$d")" "$d" env DOC_LINT_LANG=zh bash "$SCRIPTS/doc-lint.sh" "$d"
done
collect_fixtures

# 上面那个口子必须自报。少了那句 warn，谁都能拿 DOC_LINT_LANG 换掉判据而不留痕迹——
# 而换判据正是这套门禁最该拦住的一件事（rules/show-me-test.md：门禁不许假装通过）。
run_scripted "doc-lint/语言被覆盖时要自报" 0 "语言由 DOC_LINT_LANG 指定为" -- \
  env DOC_LINT_LANG=zh bash "$SCRIPTS/doc-lint.sh" "$FX/doc-lint/good"

# 扫描范围不许随包所在的路径变。副本排除项此前写成 */singlefs-ai-sop/* 加「ROOT 在包里就不排除」：
# 同一个样本 projok 在 zh 仓里「检查 1」、在项目副本（路径里有 /singlefs-ai-sop/）里「检查 2」——
# 0.0.50 同步到 singlefs 时那边的 selftest 因此红了一例。这里把脚本拷到一个路径里带 /singlefs-ai-sop/ 的地方再跑同一个样本。
r="$tmpd/elsewhere/singlefs-ai-sop"; mkdir -p "$r/scripts/fixtures/doc-lint"
cp "$SCRIPTS/lib.sh" "$SCRIPTS/doc-lint.sh" "$r/scripts/"; cp "$SCRIPTS/../I18N" "$r/I18N"
cp -r "$FX/doc-lint/projok" "$r/scripts/fixtures/doc-lint/"
run_scripted "doc-lint/扫描范围不随包所在路径变" 0 "文档铁律检查通过（检查 1，跳过 0" -- \
  env DOC_LINT_LANG=zh bash "$r/scripts/doc-lint.sh" "$r/scripts/fixtures/doc-lint/projok"

# 判据编不过要当场红。2026-09-17 给上下文指代加光秃的方位形态时写了圈码区间 `①-⑳`，grep 报
# Invalid collation character，而那条 grep 外面套着 `|| true`：整条检查对每份 kb 静默判绿，dirref 样本照样过。
# 这里拷一份脚本、把圈码那一格改回区间写法，要求它报「编不过」，而不是「检查通过」。
b="$tmpd/brokenctx"; mkdir -p "$b/scripts"
cp "$SCRIPTS/lib.sh" "$SCRIPTS/doc-lint.sh" "$b/scripts/"; cp "$SCRIPTS/../I18N" "$b/I18N"
run_scripted "doc-lint/判据编不过要当场红" 1 "上下文指代的判据 grep 编不过" -- \
  bash -c 'sed -i "s/①②③④⑤⑥⑦⑧⑨⑩⑪⑫⑬⑭⑮⑯⑰⑱⑲⑳/①-⑳/" "$1/scripts/doc-lint.sh" && grep -q "①-⑳" "$1/scripts/doc-lint.sh" || { echo "没改到圈码那一格，这条用例什么也没测"; exit 3; }
           env DOC_LINT_LANG=zh bash "$1/scripts/doc-lint.sh" "$2"' brokenctx "$b" "$FX/doc-lint/dirref"

# ════ gate-lint ══════════════════════════════════════════
head1 "门禁自检：gate-lint 的判别力"
for d in "$FX"/gate-lint/*/; do
  [[ -d "$d" ]] || continue
  spawn_fixture "gate-lint/$(basename "$d")" "$d" \
    env GATE_LINT_DIR="$d" bash "$SCRIPTS/gate-lint.sh"
done
collect_fixtures

# 默认扫描范围（不设 GATE_LINT_DIR / SHELL_LINT_DIR 时扫哪里）——
# 样本目录法测不到它：环境变量一设就把默认值盖掉了。所以现搭一个包，
# 在**包根**放一份该被拦的脚本，不带环境变量地跑。
# 钉住的是「install.sh 在包根，也要扫」（复核实测：它那 4 处裸 die 曾一处没查到）。
head1 "门禁自检：默认扫描范围"
# ⚠️ 该被拦的样本内容**放到样本文件里**，不许写成本脚本内的字符串字面量——
# gate-lint / shell-lint 扫的是 *.sh 的内容，写在这里它会把样本当成真实拒绝，
# 门禁自己红（本轮实测：`die "单测失败"` 写在 printf 里，gate-lint 当场判红）。
mk_scan_pkg() { # mk_scan_pkg <目录> <要拷进包根的样本文件>
  mkdir -p "$1/scripts"
  cp "$SCRIPTS/lib.sh" "$SCRIPTS/gate-lint.sh" "$SCRIPTS/shell-lint.sh" "$1/scripts/"
  cp "$FX/scan/clean.sh" "$1/scripts/clean.sh"
  cp "$2" "$1/rootscript.sh"
}
r="$tmpd/scan-gl"; mk_scan_pkg "$r" "$FX/scan/root-nakeddie.sh"
run_scripted "gate-lint/默认扫到包根" 1 "rootscript.sh:3" -- bash "$r/scripts/gate-lint.sh"

r="$tmpd/scan-sl"; mk_scan_pkg "$r" "$FX/scan/root-pkill.sh"
run_scripted "shell-lint/默认扫到包根" 1 "rootscript.sh:4" -- bash "$r/scripts/shell-lint.sh"

# `… | grep -q` 在管道末端：grep 找到就退出，上游拿 SIGPIPE，pipefail 下整条管道退 141、条件当假。
# 文件小的时候一切正常，大过管道缓冲（64 KiB）就静默不判了——越大的脚本越容易中（审计实测：4 行判红，撑到 338 KB 变绿）。
r="$tmpd/gl-bigfile"; mkdir -p "$r"
{ printf '#!/usr/bin/env bash\nfor f in $(find . -name "*.md"); do\n  echo "$f"\ndone\n'
  printf 'ok "%s"\n' 检查通过
  awk 'BEGIN { for (i = 0; i < 9000; i++) print "# 填充行 " i " 用来把文件撑过管道缓冲区" }'
} > "$r/x.sh"
run_scripted "gate-lint/大文件也判得出没报计数" 1 "成功摘要没报出检查了多少项" -- \
  env GATE_LINT_DIR="$r" bash "$SCRIPTS/gate-lint.sh"

# 项目里单跑这两个 lint（README 就是这么教的）时，装进项目的副本不许被扫：
# 副本带着一整套**故意写坏的**样本，扫了就当成项目自己的违规报出来（审计实测）。
r="$tmpd/lint-copy"; pkg="$r/proj/.claude/f"
mkdir -p "$pkg/scripts/fixtures/gate-lint/bad" "$pkg/scripts/fixtures/shell-lint/bad" "$r/proj/.claude/gate.d"
cp "$SCRIPTS/lib.sh" "$SCRIPTS/gate-lint.sh" "$SCRIPTS/shell-lint.sh" "$pkg/scripts/"
printf 'family=f\nthis=zh\nreference=zh\ndefault=zh\nlanguages=zh\n' > "$pkg/I18N"
cp "$FX/scan/root-nakeddie.sh" "$pkg/scripts/fixtures/gate-lint/bad/evil.sh"
cp "$FX/scan/root-pkill.sh"    "$pkg/scripts/fixtures/shell-lint/bad/evil.sh"
cp "$FX/scan/clean.sh" "$r/proj/.claude/gate.d/10-ok.sh"
run_scripted "gate-lint/项目里单跑不报副本里的样本" 0 "门禁自检通过" -- bash "$pkg/scripts/gate-lint.sh" "$r/proj"
run_scripted "shell-lint/项目里单跑不报副本里的样本" 0 "shell 纪律检查通过" -- bash "$pkg/scripts/shell-lint.sh" "$r/proj"

# ════ shell-lint ═════════════════════════════════════════
head1 "门禁自检：shell-lint 的判别力"
for d in "$FX"/shell-lint/*/; do
  [[ -d "$d" ]] || continue
  spawn_fixture "shell-lint/$(basename "$d")" "$d" \
    env SHELL_LINT_DIR="$d" bash "$SCRIPTS/shell-lint.sh"
done
collect_fixtures

# ════ pattern-process-guard（会话钩子）═══════════════════
# 样本是钩子的 JSON 输入（input.json），不是 .sh：shell-lint / gate-lint 不扫它们。
# 红的 want 带「第一处：」那一行，钉住是哪一行命中的——只比退出码的话，一个因为别的行红了的样本也算过。
head1 "门禁自检：pattern-process-guard 的判别力"
[[ -d "$FX/pattern-process-guard" ]] || { bad "缺样本目录 $FX/pattern-process-guard"
  howto "样本要随仓走。没有样本，下一个改 claude-hooks/pattern-process-guard.sh 的人无从复跑。"; exit 1; }
for d in "$FX"/pattern-process-guard/*/; do
  [[ -d "$d" ]] || continue
  spawn_fixture "pattern-process-guard/$(basename "$d")" "$d" \
    bash -c 'bash "$0" < "$1/input.json"' "$SCRIPTS/claude-hooks/pattern-process-guard.sh" "$d"
done
collect_fixtures

# ════ proc.py（按进程号找、等、停）═══════════════════════
# 它是钩子给出的替代写法，自检坏了等于出路是假的。三个破坏开关各关掉一样东西，自检必须判红。
head1 "门禁自检：proc.py 的判别力"
run_scripted "proc/自检通过" 0 "proc.py 自检通过" -- python3 "$SCRIPTS/proc.py" --selftest
run_scripted "proc/PROC_BREAK=ancestors 必须判红" 1 "find 列出了发出这条命令的进程自己" -- \
  env PROC_BREAK=ancestors python3 "$SCRIPTS/proc.py" --selftest
# ⚠️ 下面这一例要**空等 10 秒**：它验的就是「超时逻辑被破坏之后 wait 不返回」，
# 那个 10 秒是 proc.py 自检里外层 subprocess 的超时。2026-09-19 实测它占整个自检 21.4 秒里的 10 秒。
# 这是故意的等待，不是并行度问题——并行治不了它，别拿并行去解释这一段为什么慢。
run_scripted "proc/PROC_BREAK=timeout 必须判红" 1 "10 秒没返回" -- \
  env PROC_BREAK=timeout python3 "$SCRIPTS/proc.py" --selftest
run_scripted "proc/PROC_BREAK=stopself 必须判红" 1 "stop 停自己的祖先应当拒绝" -- \
  env PROC_BREAK=stopself python3 "$SCRIPTS/proc.py" --selftest

# ════ show-me-test（要 git 仓才摆得出场景，现搭现跑）═════
head1 "门禁自检：show-me-test 的判别力"
mk_repo() { # mk_repo <目录> —— 一个已提交基线的最小 crates 仓
  mkdir -p "$1/crates/foo/src"
  git -C "$1" init -qb master
  printf 'pub fn f() -> u32 { 1 }\n' > "$1/crates/foo/src/lib.rs"
  git -C "$1" add -A
  git -C "$1" -c user.email=selftest@local -c user.name=selftest commit -qm init
}
r="$tmpd/smt-naked"; mk_repo "$r"
printf 'pub fn g() -> u32 { 2 }\n' >> "$r/crates/foo/src/lib.rs"
run_scripted "show-me-test/改代码无测试拒收" 1 拒收 -- bash "$SCRIPTS/show-me-test.sh" "$r"

r="$tmpd/smt-comment"; mk_repo "$r"
printf 'pub fn g() -> u32 { 2 }\n// 计划稍后 #[test]\n' >> "$r/crates/foo/src/lib.rs"
run_scripted "show-me-test/注释里的test标注不算" 1 拒收 -- bash "$SCRIPTS/show-me-test.sh" "$r"

r="$tmpd/smt-eolcomment"; mk_repo "$r"
printf 'pub fn g() -> u32 { 2 } // 待补 #[test]\n' >> "$r/crates/foo/src/lib.rs"
run_scripted "show-me-test/行尾注释的test标注不算" 1 拒收 -- bash "$SCRIPTS/show-me-test.sh" "$r"

r="$tmpd/smt-shell"; mk_repo "$r"
printf 'pub fn g() -> u32 { 2 }\n' >> "$r/crates/foo/src/lib.rs"
mkdir -p "$r/tests"; printf '// 空壳占位\n' > "$r/tests/t.rs"
git -C "$r" add tests
run_scripted "show-me-test/tests下的空壳rs不算" 1 拒收 -- bash "$SCRIPTS/show-me-test.sh" "$r"

r="$tmpd/smt-datafile"; mk_repo "$r"
printf 'pub fn g() -> u32 { 2 }\n' >> "$r/crates/foo/src/lib.rs"
mkdir -p "$r/tests"; echo x > "$r/tests/note.txt"
run_scripted "show-me-test/tests下非代码文件不算" 1 拒收 -- bash "$SCRIPTS/show-me-test.sh" "$r"

r="$tmpd/smt-real"; mk_repo "$r"
printf 'pub fn g() -> u32 { 2 }\n' >> "$r/crates/foo/src/lib.rs"
mkdir -p "$r/tests"; printf '#[test]\nfn t() { assert_eq!(1, 1); }\n' > "$r/tests/t.rs"
run_scripted "show-me-test/真测试放行" 0 伴随测试 -- bash "$SCRIPTS/show-me-test.sh" "$r"

# TEST_RE 里的每一种标注都要有人盯着：本轮审计把它缩到只认 #[test]，
# 54 个用例一个都没红——而 show-me-test 自己的 howto 首推的就是 #[cfg(test)]。
for ann in '#[cfg(test)] mod tests { }' 'proptest! { }' '#[tokio::test] async fn t() {}' '#[kani::proof] fn p() {}'; do
  tag="$(printf '%s' "$ann" | cut -c1-16)"
  r="$tmpd/smt-ann-$(printf '%s' "$ann" | tr -cd 'a-z')"; mk_repo "$r"
  printf 'pub fn g() -> u32 { 2 }\n' >> "$r/crates/foo/src/lib.rs"
  mkdir -p "$r/tests"; printf '%s\n' "$ann" > "$r/tests/t.rs"
  run_scripted "show-me-test/认得出 $tag" 0 伴随测试 -- bash "$SCRIPTS/show-me-test.sh" "$r"
done

# 未跟踪的新文件在 diff 里看不见，内联测试全靠单独扫文件内容。
# 删掉那段扫描，这个用例会从「放行」变成「拒收」（复核实测）。
r="$tmpd/smt-untracked"; mk_repo "$r"
printf 'pub fn g() -> u32 { 2 }\n' >> "$r/crates/foo/src/lib.rs"
printf 'pub fn h() -> u32 { 3 }\n#[cfg(test)]\nmod tests { #[test] fn t() { assert_eq!(1,1); } }\n' \
  > "$r/crates/foo/src/new.rs"
run_scripted "show-me-test/未跟踪文件里的内联测试算数" 0 伴随测试 -- bash "$SCRIPTS/show-me-test.sh" "$r"

# 分两次提交躲开 diff 窗口：第一次改代码不带测试，第二次只改文档。
# 基准退到已推送点之后，两个 commit 都在窗口里，攒多少次都躲不掉（对抗测试实测）。
r="$tmpd/smt-twocommits"; mk_repo "$r"
git -C "$r" update-ref refs/singlefs/gate-ok HEAD     # 门禁在基线那里通过过
printf 'pub fn g() -> u32 { 2 }\n' >> "$r/crates/foo/src/lib.rs"
git -C "$r" add -A
git -C "$r" -c user.email=selftest@local -c user.name=selftest commit -qm "改代码"
printf '# 说明\n' > "$r/NOTES.md"
git -C "$r" add -A
git -C "$r" -c user.email=selftest@local -c user.name=selftest commit -qm "只改文档"
run_scripted "show-me-test/分两次提交躲不掉" 1 拒收 -- bash "$SCRIPTS/show-me-test.sh" "$r"

# 测试标注只认 .rs 的新增行：在 CLAUDE.md 里写一句「请写 #[test]」不算带了测试
r="$tmpd/smt-mdtest"; mk_repo "$r"
printf 'pub fn g() -> u32 { 2 }\n' >> "$r/crates/foo/src/lib.rs"
printf '<!-- 提交模板：新增测试请写 #[test] -->\n' > "$r/CLAUDE.md"
run_scripted "show-me-test/文档里提 #[test] 不算" 1 拒收 -- bash "$SCRIPTS/show-me-test.sh" "$r"

# Rust 字符串字面量里的标注同理
r="$tmpd/smt-strlit"; mk_repo "$r"
printf 'pub const DOC: &str = "#[test]";\npub fn g() -> u32 { 2 }\n' >> "$r/crates/foo/src/lib.rs"
run_scripted "show-me-test/字符串里的标注不算" 1 拒收 -- bash "$SCRIPTS/show-me-test.sh" "$r"

# 仓库根丢一个未跟踪的 scratch.rs 也不算
r="$tmpd/smt-scratch"; mk_repo "$r"
printf 'pub fn g() -> u32 { 2 }\n' >> "$r/crates/foo/src/lib.rs"
printf '#[test]\nfn t() {}\n' > "$r/scratch.rs"
run_scripted "show-me-test/仓根的草稿 rs 不算" 1 拒收 -- bash "$SCRIPTS/show-me-test.sh" "$r"

r="$tmpd/smt-committed"; mk_repo "$r"
printf 'pub fn g() -> u32 { 2 }\n' >> "$r/crates/foo/src/lib.rs"
git -C "$r" add -A
git -C "$r" -c user.email=selftest@local -c user.name=selftest commit -qm naked
run_scripted "show-me-test/提交进master也逃不掉" 1 拒收 -- bash "$SCRIPTS/show-me-test.sh" "$r"

r="$tmpd/smt-buildrs"; mk_repo "$r"
printf 'fn main() {}\n' > "$r/crates/foo/build.rs"
run_scripted "show-me-test/build.rs也是代码" 1 拒收 -- bash "$SCRIPTS/show-me-test.sh" "$r"

# 大过管道缓冲的新文件里的内联测试照样算数（同 gate-lint 那条 grep -q 的坑，方向相反：这边是把带测试的判成没带）。
r="$tmpd/smt-bigfile"; mk_repo "$r"
printf 'pub fn g() -> u32 { 2 }\n' >> "$r/crates/foo/src/lib.rs"
# ⚠️ 填充行不能写成注释：strip_comments 会把它们剥掉，喂给 grep 的其实只剩两行，
# 根本撑不过管道缓冲——这条用例就只是看着像在测大文件（第一版实测：变异改回 grep -q，它一声不吭）。
{ printf '#[cfg(test)]\nmod tests { #[test] fn t() { assert_eq!(1, 1); } }\n'
  awk 'BEGIN { for (i = 0; i < 4000; i++) printf "pub fn filler_%d() -> u32 { %d }\n", i, i }'
} > "$r/crates/foo/src/new.rs"
run_scripted "show-me-test/大文件里的内联测试算数" 0 伴随测试 -- bash "$SCRIPTS/show-me-test.sh" "$r"

# GATE_BASE 写错一个字母，此前 changed_files 按「空仓」处理、只看未跟踪文件，于是报「无对象可判」、门禁绿。
r="$tmpd/smt-badbase"; mk_repo "$r"
printf 'pub fn g() -> u32 { 2 }\n' >> "$r/crates/foo/src/lib.rs"
run_scripted "show-me-test/GATE_BASE 解析不到就拒绝" 1 "解析不到提交" -- \
  env GATE_BASE=orgin/master bash "$SCRIPTS/show-me-test.sh" "$r"

# 上游领先（fetch 了没 merge）时，基准取与上游的 merge-base，不是上游的 tip：
# 取 tip 就是把别人的提交算进这一轮，工作区干净也会被判拒收（审计实测）。
r="$tmpd/smt-upstream"; mk_repo "$r/local"
git init -q --bare -b master "$r/origin.git"
git -C "$r/local" remote add origin "$r/origin.git"; git -C "$r/local" push -q -u origin master
git clone -q "$r/origin.git" "$r/other"
printf 'pub fn g() -> u32 { 2 }\n' >> "$r/other/crates/foo/src/lib.rs"
git -C "$r/other" add -A
git -C "$r/other" -c user.email=selftest@local -c user.name=selftest commit -qm "别人改了代码没带测试"
git -C "$r/other" push -q origin master
git -C "$r/local" fetch -q origin
run_scripted "show-me-test/上游领先时不算别人的提交" 3 无对象可判 -- bash "$SCRIPTS/show-me-test.sh" "$r/local"

r="$tmpd/smt-nothing"; mk_repo "$r"
run_scripted "show-me-test/无对象可判" 3 无对象可判 -- bash "$SCRIPTS/show-me-test.sh" "$r"

# gate-lint 也扫 .py：项目本地阶段常用 python 写，它们的拒绝一样摆在提交者面前。
# ⚠️ 样本内容写进临时文件，不写成本脚本里的字符串——gate-lint 扫的是文件内容，
# 直接写在这里它会把样本当成本脚本自己的拒绝（selftest 头部那条警告说的就是这个），所以 ✗ 用参数传。
r="$tmpd/gl-py"; mkdir -p "$r"
printf '#!/usr/bin/env python3\n# 样本：python 写的阶段，拒绝直接 print，没有出路\nimport sys\nprint("  %s 这几项不成形")\nsys.exit(1)\n' ✗ > "$r/x.py"
run_scripted "gate-lint/python 阶段的拒绝也要给出路" 1 "x.py:4" -- env GATE_LINT_DIR="$r" bash "$SCRIPTS/gate-lint.sh"

# doc-lint 自己报得出「本语言哪几条检查没实现」，gate.sh 拿它填汇总里的未实现清单。
run_scripted "doc-lint/没词表的语言报得出哪几条未实现" 0 "本语言没有词表" -- \
  env DOC_LINT_LANG=en bash "$SCRIPTS/doc-lint.sh" --not-impl
run_scripted "doc-lint/有词表时未实现清单是空的" 0 "未实现清单为空" -- \
  bash -c 'out="$(env DOC_LINT_LANG=zh bash "$1" --not-impl)"; [[ -z "$out" ]] && echo "未实现清单为空"' notimpl_zh "$SCRIPTS/doc-lint.sh"


# 样本里的日期也要可能。样本**不在** doc-lint 的扫描范围里（它们是故意写坏的），所以这一条由 selftest 自己扫——
# 踩过的正是这个：三份样本与一处 skill 示例里写着 2026-01-01，比这个仓第一个提交早了大半年，而门禁一直是绿的。
# 故意拿不可能的日期去测那条检查的样本，在它自己的 expect 里声明出来，显式豁免（猜不着的东西不猜）。
fxdate_check=(bash -c '
  FX="$1"; LO="$2"; TODAY="$3"; bad_count=0; seen_count=0
  while IFS= read -r fixture_file; do
    rel="${fixture_file#"$FX"/}"; lint_name="${rel%%/*}"; rest="${rel#*/}"; fixture_name="${rest%%/*}"
    expect_file="$FX/$lint_name/$fixture_name/expect"
    if [[ -f "$expect_file" ]] && grep -q "晚于今天\|早于这个仓" "$expect_file"; then continue; fi
    while IFS=: read -r line_no line_rest; do
      found_date="$(printf "%s" "$line_rest" | grep -oE "[0-9]{4}-[0-9]{2}-[0-9]{2}" || true)"
      found_date="${found_date%%$'"'"'\n'"'"'*}"
      [[ -n "$found_date" ]] || continue
      seen_count=$((seen_count+1))
      if [[ "$found_date" > "$TODAY" ]] || { [[ -n "$LO" ]] && [[ "$found_date" < "$LO" ]]; }; then
        echo "  样本日期不可能：$rel:$line_no  $found_date"; bad_count=$((bad_count+1))
      fi
    done < <(grep -nE "(^###[[:space:]]+|^##[[:space:]]+[0-9]+\.[0-9]+\.[0-9]+[[:space:]]+—[[:space:]]+|实测（)[0-9]{4}-[0-9]{2}-[0-9]{2}" "$fixture_file" || true)
  done < <(find "$FX" -type f -name "*.md" | sort)
  echo "样本里查了 $seen_count 个日期，不可能的 $bad_count 个"
  [[ $bad_count -eq 0 ]]' fxdate_check)
run_scripted "selftest/样本里的日期也要可能" 0 "不可能的 0 个" -- \
  "${fxdate_check[@]}" "$FX" "$(date_lower_bound "$SOP_START_DATE")" "$(latest_today)"

# 日期的下界只在被查目录**本身**是 git 仓顶层时才问 git。不这么限，`git -C` 会一路往上找：
# 目录嵌在一个更晚才开始的仓里时（SOP 副本放在项目的 .claude/ 下就是这种形状），拿外层仓的第一个提交当下界，
# 真日期会被判成不可能。这里造一个 2026-09-15 才开始的外层仓，里面的子目录写着 2026-09-01：
# 按外层仓算早出了 7 天的宽限，按这个包的起点算在宽限之内。
r="$tmpd/date-walkup"; mkdir -p "$r/outer/sub/kb"
git -C "$r/outer" init -q
printf '起点\n' > "$r/outer/README.md"; git -C "$r/outer" add -A
GIT_AUTHOR_DATE="2026-09-15T00:00:00" GIT_COMMITTER_DATE="2026-09-15T00:00:00" \
  git -C "$r/outer" -c user.name=t -c user.email=t@t commit -qm 起点
printf '# 决策\n\n正文只写现状。\n\n## 历史版本\n\n### 2026-09-01\n- 建档。\n' > "$r/outer/sub/kb/a.md"
run_scripted "doc-lint/日期下界不往上找外层仓" 0 "文档铁律检查通过" -- \
  env DOC_LINT_LANG=zh bash "$SCRIPTS/doc-lint.sh" "$r/outer/sub"

# 下界从第一个提交往前宽限 7 天：git init 之前做的工作会带着当时的日期进第一个提交
# （singlefs 的初版提交里就有前一天的历史条目）。两例钉住宽限的两边：之内放行，之外照样判红。
r="$tmpd/date-grace"
for side in within beyond; do
  mkdir -p "$r/$side/kb"; git -C "$r/$side" init -q
  printf '起点\n' > "$r/$side/README.md"; git -C "$r/$side" add -A
  GIT_AUTHOR_DATE="2026-09-15T00:00:00" GIT_COMMITTER_DATE="2026-09-15T00:00:00" \
    git -C "$r/$side" -c user.name=t -c user.email=t@t commit -qm 起点
done
printf '# 决策\n\n正文只写现状。\n\n## 历史版本\n\n### 2026-09-10\n- 建档。\n' > "$r/within/kb/a.md"
printf '# 决策\n\n正文只写现状。\n\n## 历史版本\n\n### 2026-09-05\n- 建档。\n' > "$r/beyond/kb/a.md"
run_scripted "doc-lint/第一个提交之前 7 天以内的日期放行" 0 "文档铁律检查通过" -- \
  env DOC_LINT_LANG=zh bash "$SCRIPTS/doc-lint.sh" "$r/within"
run_scripted "doc-lint/早于第一个提交 7 天以上的日期判红" 1 "早于这个仓第一个提交（2026-09-15）7 天以上" -- \
  env DOC_LINT_LANG=zh bash "$SCRIPTS/doc-lint.sh" "$r/beyond"

# 「今天」按最晚的时区（UTC+14）算。本机时钟是 UTC、人在东京时，东京凌晨写下的当天日期比 UTC 的今天晚一天。
# 用一个假 date 把时钟钉住：本机时钟上是 2026-09-16，UTC+14 已是 2026-09-17。退回只看本机时钟，第一例就红。
r="$tmpd/date-latest-zone"; mkdir -p "$r/bin" "$r/today/kb" "$r/tomorrow/kb"
printf '#!/usr/bin/env bash\nif [[ "${1:-}" == "+%%F" ]]; then\n  case "${TZ:-}" in UTC-14|Etc/GMT-14) echo 2026-09-17 ;; *) echo 2026-09-16 ;; esac; exit 0\nfi\nexec %q "$@"\n' \
  "$(command -v date)" > "$r/bin/date"
chmod +x "$r/bin/date"
printf '# 决策\n\n正文只写现状。\n\n## 历史版本\n\n### 2026-09-17\n- 建档。\n' > "$r/today/kb/a.md"
printf '# 决策\n\n正文只写现状。\n\n## 历史版本\n\n### 2026-09-18\n- 建档。\n' > "$r/tomorrow/kb/a.md"
run_scripted "doc-lint/今天按最晚的时区算，东京已到的日期放行" 0 "文档铁律检查通过" -- \
  env PATH="$r/bin:$PATH" DOC_LINT_LANG=zh bash "$SCRIPTS/doc-lint.sh" "$r/today"
run_scripted "doc-lint/比最晚时区的今天还晚就判红" 1 "晚于今天（2026-09-17，按最晚的时区算）" -- \
  env PATH="$r/bin:$PATH" DOC_LINT_LANG=zh bash "$SCRIPTS/doc-lint.sh" "$r/tomorrow"

# 下界靠 date -d 做减法。不认 -d 的 date 算不出下界，下界要是静默变空，2026-01-01 就放行了：停下来说清楚。
r="$tmpd/date-no-minus-d"; mkdir -p "$r/bin" "$r/proj/kb"
printf '#!/usr/bin/env bash\nfor argument in "$@"; do [[ "$argument" == -d ]] && { echo "date: illegal option -- d" >&2; exit 1; }; done\nexec %q "$@"\n' \
  "$(command -v date)" > "$r/bin/date"
chmod +x "$r/bin/date"
printf '# 决策\n\n正文只写现状。\n\n## 历史版本\n\n### 2026-01-01\n- 建档。\n' > "$r/proj/kb/a.md"
run_scripted "doc-lint/date 不认 -d 时停下，不许静默放过" 1 "这台机器的 date 不认 -d" -- \
  env PATH="$r/bin:$PATH" DOC_LINT_LANG=zh bash "$SCRIPTS/doc-lint.sh" "$r/proj"

# 浅克隆里「第一个提交」是截断处：拿它当下界，项目越老误判越多。这里完整历史从 2026-09-01 开始，浅克隆只看得到 2026-09-16。
r="$tmpd/date-shallow"; mkdir -p "$r/full"; git -C "$r/full" init -q
printf '起点\n' > "$r/full/README.md"; git -C "$r/full" add -A
GIT_AUTHOR_DATE="2026-09-01T00:00:00" GIT_COMMITTER_DATE="2026-09-01T00:00:00" \
  git -C "$r/full" -c user.name=t -c user.email=t@t commit -qm 起点
printf '又一行\n' >> "$r/full/README.md"; git -C "$r/full" add -A
GIT_AUTHOR_DATE="2026-09-16T00:00:00" GIT_COMMITTER_DATE="2026-09-16T00:00:00" \
  git -C "$r/full" -c user.name=t -c user.email=t@t commit -qm 又一行
git clone -q --depth 1 "file://$r/full" "$r/shallow" 2>/dev/null
mkdir -p "$r/shallow/kb"
printf '# 决策\n\n正文只写现状。\n\n## 历史版本\n\n### 2026-09-02\n- 建档。\n' > "$r/shallow/kb/a.md"
run_scripted "doc-lint/浅克隆不拿截断处当第一个提交" 0 "文档铁律检查通过" -- \
  env DOC_LINT_LANG=zh bash "$SCRIPTS/doc-lint.sh" "$r/shallow"

# en / ja 仓写实测日期的形态是 Measured ( 与 実測（。只认中文那种时，这两种一条都不查。
r="$tmpd/date-forms"; mkdir -p "$r/kb"
printf '# 决策\n\nMeasured (2099-01-01) 一次。\n\n## 历史版本\n' > "$r/kb/en.md"
printf '# 决策\n\n実測（2099-01-01）一次。\n\n## 历史版本\n' > "$r/kb/ja.md"
run_scripted "doc-lint/英日两种实测写法的日期也查" 1 "kb/en.md:3  日期 2099-01-01 不可能" "kb/ja.md:3  日期 2099-01-01 不可能" -- \
  env DOC_LINT_LANG=zh bash "$SCRIPTS/doc-lint.sh" "$r"

# 包里没有 I18N 时照常判：sed 读不到文件退 2，赋值带着这个退出码，set -e 当场把脚本带走、一个字都不打。
# doc-lint 与 manifest 各一处（审核实测）；同一形态的另外六处已经带着 `|| true`。
r="$tmpd/noi18n-doclint"; mkdir -p "$r/pkg/scripts" "$r/proj/kb"
cp "$SCRIPTS/lib.sh" "$SCRIPTS/doc-lint.sh" "$r/pkg/scripts/"
printf '# 决策\n\n正文只写现状。\n\n## 历史版本\n' > "$r/proj/kb/a.md"
run_scripted "doc-lint/包里没有 I18N 也照常判" 0 "文档铁律检查通过" -- bash "$r/pkg/scripts/doc-lint.sh" "$r/proj"
r="$tmpd/noi18n-manifest"; mkdir -p "$r/scripts" "$r/rules"
cp "$SCRIPTS/lib.sh" "$SCRIPTS/manifest.sh" "$r/scripts/"
printf '# 规则\n\n正文。\n' > "$r/rules/a.md"; printf "# 包\\n" > "$r/CLAUDE.md"
run_scripted "manifest/包里没有 I18N 也照常判" 0 "清单与规范文本一致" -- \
  bash -c 'bash "$1/scripts/manifest.sh" --update >/dev/null && bash "$1/scripts/manifest.sh"' _ "$r"

# ════ bump.sh ════════════════════════════════════════════
head1 "门禁自检：bump.sh 的判别力"
# 此前零覆盖：一次升全部语言的 VERSION，靠的就是「先查全部在场、再动手」这一个顺序。
# 在 <族目录>/f-zh 放一个只带 bump.sh 的包；清单生成换成桩，这里只测版本号那一半。
mk_bump_pkg() { # mk_bump_pkg <族目录> <声明的语言...>
  local family_root="$1"; shift
  mkdir -p "$family_root/f-zh/scripts"
  cp "$SCRIPTS/lib.sh" "$SCRIPTS/bump.sh" "$family_root/f-zh/scripts/"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$family_root/f-zh/scripts/manifest.sh"
  printf 'family=f\nthis=zh\nreference=zh\ndefault=zh\nlanguages=%s\n' "$*" > "$family_root/f-zh/I18N"
  printf '0.0.1\n' > "$family_root/f-zh/VERSION"
}
r="$tmpd/bump-badver"; mk_bump_pkg "$r" zh
run_scripted "bump/版本号不是三段数字要拒绝" 1 "版本号必须是三段数字" -- bash "$r/f-zh/scripts/bump.sh" 1.2
r="$tmpd/bump-noi18n"; mk_bump_pkg "$r" zh; rm -f "$r/f-zh/I18N"
run_scripted "bump/缺 I18N 要拒绝" 1 "缺 I18N" -- bash "$r/f-zh/scripts/bump.sh" 0.0.2
# 声明的语言仓有一个不在：必须在写任何一份之前就拒绝，否则会升出互相不一致的几份。
r="$tmpd/bump-missing"; mk_bump_pkg "$r" zh en
run_scripted "bump/有语言仓不在就一份都不写" 1 "找不到" "VERSION 仍是 0.0.1" -- \
  bash -c 'bash "$1/f-zh/scripts/bump.sh" 0.0.2; rc=$?; echo "VERSION 仍是 $(cat "$1/f-zh/VERSION")"; exit $rc' bump_missing "$r"
r="$tmpd/bump-ok"; mk_bump_pkg "$r" zh en; mkdir -p "$r/f-en"
run_scripted "bump/全部语言仓都在就一起升" 0 "f-zh  → 0.0.2" "f-en  → 0.0.2" -- bash "$r/f-zh/scripts/bump.sh" 0.0.2

# ════ install.sh ═════════════════════════════════════════
head1 "门禁自检：install.sh 的判别力"
# 版本戳只许往上走。副本比项目声明的版本旧时照写，就是把戳**降级**，而戳是入库的——
# 降级顺着提交传给所有人，门禁从此按旧规矩判（审计实测这条路是通的）。
r="$tmpd/inst-downgrade"; mkdir -p "$r/proj"
printf '9.9.9\n' > "$r/proj/.singlefs-ai-sop-version"
run_scripted "install/不给版本戳降级" 1 "不给版本戳降级" -- bash "$SCRIPTS/../install.sh" "$r/proj"

# 副本被 .gitignore 挡着，新 clone 出来的仓里它不存在。包装脚本 exec 一个不存在的路径，
# 拿到的只有 bash 的「No such file or directory」，一句出路都没有——所以包装里要自己说清楚。
r="$tmpd/inst-nocopy"; mkdir -p "$r/proj"
bash "$SCRIPTS/../install.sh" "$r/proj" >/dev/null 2>&1 || true
run_scripted "install/包装说得清副本不在" 1 "找不到共享脚本" -- bash "$r/proj/.claude/scripts/gate.sh"

# ════ gate.sh 自己（判决点，此前零覆盖）═══════════════════
# 复核实测：把 run_stage 改成无条件记 PASS，造一处真实文档违规，
# gate.sh 退出码是 **0**，而 selftest 69 例全绿——整道门禁的判决点没有任何人盯着。
#
# 不直接跑真 gate.sh：它把 selftest 当一个阶段跑，那样会无限递归。
# 改成把 gate.sh + lib.sh 拷进一个临时包，各子脚本换成**桩**（按参数决定退出码）。
# 这样测的正是 run_stage 的记录、汇总的判读、以及最终退出码——与子脚本无关。
head1 "门禁自检：gate.sh 判决逻辑的判别力"
mk_gate_pkg() { # mk_gate_pkg <目录> [要让哪个桩失败]
  local d="$1" failing="${2:-}"
  mkdir -p "$d/scripts" "$d/rules"
  cp "$SCRIPTS/lib.sh" "$SCRIPTS/gate.sh" "$d/scripts/"
  printf '0.0.0\n' > "$d/VERSION"
  printf 'family=f\nthis=zh\nreference=zh\ndefault=zh\nlanguages=zh\n' > "$d/I18N"
  printf '# 规则甲\n' > "$d/rules/a.md"
  local n
  for n in gate-lint selftest shell-lint doc-lint naming-lint show-me-test check manifest i18n-sync version-discipline changelog-lint; do
    if [[ "$n" == "$failing" ]]; then
      printf '#!/usr/bin/env bash\necho "  桩 %s 判红"\nexit 1\n' "$n" > "$d/scripts/$n.sh"
    else
      printf '#!/usr/bin/env bash\nexit 0\n' > "$d/scripts/$n.sh"
    fi
  done
}

# 全绿：退出码 0，且每个阶段名都要出现在汇总里
# —— 这几个 want 钉住的是「阶段没被人悄悄从 gate.sh 里删掉」
r="$tmpd/gate-green"; mk_gate_pkg "$r"
run_scripted "gate/全绿则退出码 0" 0 \
  "已实现的门禁阶段全部通过" 门禁自检 门禁判别力 "shell 纪律" 文档铁律 命名纪律 "Show me test" \
  规则清单 各语言同步 版本纪律 "CHANGELOG 连续" \
  -- bash "$r/scripts/gate.sh" "$r"

# 任一阶段红 ⇒ 整道门禁必须红。这是判决点，缺了它前面所有检查都白做。
for st in doc-lint naming-lint selftest gate-lint shell-lint show-me-test version-discipline changelog-lint manifest; do
  r="$tmpd/gate-red-$st"; mk_gate_pkg "$r" "$st"
  run_scripted "gate/$st 红则门禁红" 1 门禁未通过 -- bash "$r/scripts/gate.sh" "$r"
done

# --staged：别的会话没暂存的改动不算，暂存了的算（rules/session-wrapup.md 第 4 条）。
# 同一处改动不带 --staged 时要算进来——少了这一例，「--staged 的绿」分不清是没算进来还是那个阶段根本不红。
mk_staged_project() { # mk_staged_project <目录>：带一个项目本地阶段的最小项目仓，kb/ 里出现 BAD 就红
  local p="$1"
  mkdir -p "$p/.claude/gate.d" "$p/kb"
  printf '0.0.0\n' > "$p/.singlefs-ai-sop-version"
  printf '#!/usr/bin/env bash\n# gate-stage: 样本\ncd "${1:-.}" || exit 2\nif grep -rq BAD kb/; then echo "  ✗ kb 里有 BAD"; echo "     → 删掉"; exit 1; fi\necho "  ✓ kb 里没有 BAD"\n' > "$p/.claude/gate.d/50-sample.sh"
  printf '干净\n' > "$p/kb/a.md"; printf '干净\n' > "$p/kb/b.md"
  git -C "$p" init -q && git -C "$p" add -A && git -C "$p" -c user.name=t -c user.email=t@t commit -qm base
}
r="$tmpd/gate-staged"; mk_gate_pkg "$r/pkg"; mk_staged_project "$r/proj"
printf 'BAD（别的会话没暂存的）\n' >> "$r/proj/kb/a.md"
printf '这一轮的\n' >> "$r/proj/kb/b.md"; git -C "$r/proj" add kb/b.md
run_scripted "gate/--staged 不算没暂存的改动" 0 "只拿 HEAD + 暂存区跑" "已实现的门禁阶段全部通过" \
  -- bash "$r/pkg/scripts/gate.sh" --staged "$r/proj"
run_scripted "gate/不带 --staged 时同一处要算进来" 1 门禁未通过 -- bash "$r/pkg/scripts/gate.sh" "$r/proj"
printf 'BAD（这一轮的）\n' >> "$r/proj/kb/b.md"; git -C "$r/proj" add kb/b.md
run_scripted "gate/--staged 算暂存了的改动" 1 门禁未通过 -- bash "$r/pkg/scripts/gate.sh" --staged "$r/proj"
# 判红的那一次也要清掉临时 worktree。外层在 set -e 下跑里层，写成「里层; rc=$?」时里层一红外层就当场退出，
# 清理走不到——判红正是最要看结果的时候（0.0.48 收尾时实测：判红一次，仓里就多一个 detached worktree）。
staged_red_cleanup=(bash -c '
  bash "$1/scripts/gate.sh" --staged "$2" >/dev/null 2>&1; rc=$?
  left="$(git -C "$2" worktree list --porcelain | grep -c "^worktree ")"
  echo "判红（退出码 $rc）之后仓里登记的 worktree：$left 个"
  [[ "$rc" == 1 && "$left" == 1 ]]' staged_red_cleanup)
run_scripted "gate/--staged 判红也清掉临时 worktree" 0 "判红（退出码 1）之后仓里登记的 worktree：1 个" \
  -- "${staged_red_cleanup[@]}" "$r/pkg" "$r/proj"

# 项目根要认得出 git worktree（它的 .git 是文件）。只认目录的话，在 worktree 里不带参数跑，门禁零输出退 1。
r="$tmpd/gate-in-worktree"; mk_gate_pkg "$r/pkg"
git -C "$r/pkg" init -q && git -C "$r/pkg" add -A && git -C "$r/pkg" -c user.name=t -c user.email=t@t commit -qm base
git -C "$r/pkg" worktree add --detach "$r/wt" HEAD >/dev/null 2>&1
run_scripted "gate/在 git worktree 里不带参数也找得到项目根" 0 "已实现的门禁阶段全部通过" -- \
  bash -c 'cd "$1" && bash scripts/gate.sh' in_worktree "$r/wt"
# 真找不到项目根时要说出来，不许零输出退出。
mkdir -p "$tmpd/no-project"
run_scripted "gate/找不到项目根要说出来" 1 "往上找不到项目根" -- \
  bash -c 'cd "$1" && bash "$2/scripts/gate.sh"' no_project "$tmpd/no-project" "$r/pkg"

# 「副本与上游同版本」分两个方向，出路相反：副本比上游新，去更新上游；副本落后上游，去重拷副本。
mk_versioned_project() { # mk_versioned_project <目录> <兄弟目录里上游的版本>
  mk_gate_pkg "$1/proj/.claude/f"
  printf '0.0.1\n' > "$1/proj/.claude/f/VERSION"; printf '0.0.1\n' > "$1/proj/.singlefs-ai-sop-version"
  mkdir -p "$1/f-zh"; printf '%s\n' "$2" > "$1/f-zh/VERSION"
}
r="$tmpd/gate-upstream-older"; mk_versioned_project "$r" 0.0.0
run_scripted "gate/上游比副本旧要说上游旧" 1 "上游比副本旧：副本 0.0.1，上游 0.0.0" -- \
  bash "$r/proj/.claude/f/scripts/gate.sh" "$r/proj"
r="$tmpd/gate-upstream-newer"; mk_versioned_project "$r" 0.0.2
run_scripted "gate/副本落后上游照旧说落后" 1 "副本落后上游：副本 0.0.1，上游 0.0.2" -- \
  bash "$r/proj/.claude/f/scripts/gate.sh" "$r/proj"

# 缺版本戳是拒绝，得带出路：此前用 warn 打、没有 howto，gate-lint 只认 bad / die / ✗，看不见它。
r="$tmpd/gate-nostamp"; mk_gate_pkg "$r/proj/.claude/f"; mkdir -p "$r/proj/kb"
run_scripted "gate/缺版本戳要给出路" 1 "项目未声明规范版本" "它会写出 .singlefs-ai-sop-version" -- \
  bash "$r/proj/.claude/f/scripts/gate.sh" "$r/proj"

# 本脚本起的子进程看不到 GATE_BASE 与 GATE_STAGED_FROM（清的动作在 run_fixture / run_scripted 里）。
# 函数调用前的临时赋值会导出给函数起的子进程，所以这一行就是在模拟 gate.sh 带着这两样跑本脚本。
GATE_BASE=HEAD GATE_STAGED_FROM=/nonexistent run_scripted "selftest/自己起的子进程看不到 GATE_BASE 与 GATE_STAGED_FROM" 0 \
  "GATE_BASE=<空>" "GATE_STAGED_FROM=<空>" -- \
  bash -c 'echo "GATE_BASE=${GATE_BASE:-<空>}"; echo "GATE_STAGED_FROM=${GATE_STAGED_FROM:-<空>}"'

# 样本仓也不看用户的全局 / 系统 git 配置（头部两个 export 钉的就是这个）。
# 不钉的话，用户开着 commit.gpgsign 之类，第一个样本仓就建不起来，set -e 把整个自检带走——
# 打出来是「判错 0 条」加一行 git 的报错，看着不像自检失败（审计实测 rc=128）。
run_scripted "selftest/样本仓不看用户的全局 git 配置" 0 "GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1" -- \
  bash -c 'echo "GIT_CONFIG_GLOBAL=${GIT_CONFIG_GLOBAL:-<空>} GIT_CONFIG_NOSYSTEM=${GIT_CONFIG_NOSYSTEM:-<空>}"'

# --staged 的握手变量到里层就要消费掉，不许再漏给项目本地阶段（它们会拿它当自己的项目根去找兄弟目录）。
r="$tmpd/gate-staged-env"; mk_gate_pkg "$r/pkg"; mk_staged_project "$r/proj"
printf '#!/usr/bin/env bash\n# gate-stage: 环境探针\necho "  ✓ GATE_STAGED_FROM=${GATE_STAGED_FROM:-<空>}"\n' > "$r/proj/.claude/gate.d/60-env.sh"
git -C "$r/proj" add -A && git -C "$r/proj" -c user.name=t -c user.email=t@t commit -qm probe
run_scripted "gate/--staged 不把 GATE_STAGED_FROM 漏给本地阶段" 0 "GATE_STAGED_FROM=<空>" -- \
  bash "$r/pkg/scripts/gate.sh" --staged "$r/proj"

# 被门禁的是 SOP 仓自身时，--staged 要跑临时树里那份脚本、按 SOP 仓判；跑源仓的脚本会把临时树当消费项目，
# 报「缺版本戳」判红，只在 SOP 仓跑的三个阶段还静默不跑（审计实测）。
r="$tmpd/gate-staged-self"; mk_gate_pkg "$r"
git -C "$r" init -q && git -C "$r" add -A && git -C "$r" -c user.name=t -c user.email=t@t commit -qm base
printf '# 规则乙\n' >> "$r/rules/a.md"; git -C "$r" add rules/a.md
run_scripted "gate/--staged 在 SOP 仓自身上按 SOP 仓判" 0 "本仓即 SOP 本身" "已实现的门禁阶段全部通过" -- \
  bash "$r/scripts/gate.sh" --staged "$r"

# --staged 的 diff 基准要与直接跑相同。临时树是 detached HEAD，里层自己算会落到 HEAD~1，
# 「分两次提交就绕过去」那条口子在 --staged 这边就开着（审计实测：直接跑 origin/master，--staged HEAD~1）。
# 这里的项目没有 Cargo.toml，「构建与单测」也会红，所以判据钉在 show-me-test 的「拒收」上，不只看退出码。
r="$tmpd/gate-staged-base"; mk_gate_pkg "$r/pkg"; cp "$SCRIPTS/show-me-test.sh" "$r/pkg/scripts/"
mk_repo "$r/proj"; printf '0.0.0\n' > "$r/proj/.singlefs-ai-sop-version"
git -C "$r/proj" add -A && git -C "$r/proj" -c user.email=t@t -c user.name=t commit -qm stamp
git init -q --bare -b master "$r/origin.git"
git -C "$r/proj" remote add origin "$r/origin.git" && git -C "$r/proj" push -q -u origin master
printf 'pub fn g() -> u32 { 2 }\n' >> "$r/proj/crates/foo/src/lib.rs"
git -C "$r/proj" add -A && git -C "$r/proj" -c user.email=t@t -c user.name=t commit -qm "改代码不带测试"
printf '# 说明\n' > "$r/proj/NOTES.md"
git -C "$r/proj" add -A && git -C "$r/proj" -c user.email=t@t -c user.name=t commit -qm "只改文档"
printf '再改一行\n' >> "$r/proj/NOTES.md"; git -C "$r/proj" add NOTES.md
run_scripted "gate/--staged 的 diff 基准与直接跑相同" 1 拒收 -- bash "$r/pkg/scripts/gate.sh" --staged "$r/proj"

# 项目里的包装脚本把项目根放在 $1、用户的参数接在后面，所以文档推荐的 `gate.sh --staged` 到里层是 `gate.sh <项目根> --staged`。
# 写死「$1 == --staged」时它被静默吃掉，门禁照常跑工作区（审计实测：那条命令根本没进 --staged 分支）。
r="$tmpd/gate-wrap"; mk_gate_pkg "$r/pkg"; mk_staged_project "$r/proj"
mkdir -p "$r/proj/.claude/scripts"
printf '#!/usr/bin/env bash\nexec bash "%s/scripts/gate.sh" "%s" "$@"\n' "$r/pkg" "$r/proj" > "$r/proj/.claude/scripts/gate.sh"
printf 'BAD（别的会话没暂存的）\n' >> "$r/proj/kb/a.md"
run_scripted "gate/经包装脚本带 --staged 也认得" 0 "只拿 HEAD + 暂存区跑" "已实现的门禁阶段全部通过" -- \
  bash "$r/proj/.claude/scripts/gate.sh" --staged
run_scripted "gate/认不出的参数要拒绝" 1 "认不出的参数：--stagd" -- \
  bash "$r/pkg/scripts/gate.sh" --stagd "$r/proj"

# 判「被门禁的是不是 SOP 仓自身」要按物理路径：只比 pwd 的话，经符号链接跑就判成消费项目，
# 报「缺版本戳」判红，只在 SOP 仓跑的三个阶段还静默不跑（审计实测）。
r="$tmpd/gate-symlink"; mk_gate_pkg "$r/pkg"; ln -s "$r/pkg" "$r/link"
run_scripted "gate/经符号链接也认得出 SOP 仓自身" 0 "本仓即 SOP 本身" -- \
  bash "$r/link/scripts/gate.sh" "$r/pkg"

# gate-ok 记的是**开跑时**的 HEAD。跑完再解析一次的话，另一个会话在这一轮跑的过程中提交，
# 那个从没验过的提交会被一并盖章，此后永远落在 diff 窗口外（审计实测）。
r="$tmpd/gate-okref"; mk_gate_pkg "$r/pkg"; mk_staged_project "$r/proj"
# 中途提交的内容开跑之前就写进工作区：跑的过程中只让 HEAD 动、不让工作区内容动。
# 否则「工作区跑的过程中没变」那一项先判红，门禁不通过、gate-ok 根本不写，这条用例测的就不再是「记哪个 HEAD」。
printf '#!/usr/bin/env bash\n# gate-stage: 中途提交\ncd "${1:?}" || exit 2\ngit add kb/a.md\ngit -c user.name=t -c user.email=t@t commit -qm "跑的过程中提交" >/dev/null\necho "  %s 已提交（查了 1 项）"\n' ✓ > "$r/proj/.claude/gate.d/60-commit.sh"
git -C "$r/proj" add -A; git -C "$r/proj" -c user.name=t -c user.email=t@t commit -qm stage
printf '别的会话写的\n' >> "$r/proj/kb/a.md"
okref_check=(bash -c '
  start="$(git -C "$2" rev-parse HEAD)"
  bash "$1/scripts/gate.sh" "$2" >/dev/null 2>&1
  [[ "$(git -C "$2" rev-parse HEAD)" != "$start" ]] || { echo "场景没摆成：跑的过程中 HEAD 没变"; exit 1; }
  if [[ "$(git -C "$2" rev-parse refs/singlefs/gate-ok)" == "$start" ]]; then echo "gate-ok 指向开跑时那个提交"
  else echo "gate-ok 指向跑完时那个提交"; exit 1; fi' okref_check)
run_scripted "gate/gate-ok 记的是开跑时的 HEAD" 0 "gate-ok 指向开跑时那个提交" -- "${okref_check[@]}" "$r/pkg" "$r/proj"

# --staged 跑到一半被打断（Ctrl-C）也要清掉临时 worktree：留下的会一直登记在仓里，下一次还得手工 git worktree prune。
# 一个睡 20 秒的项目阶段，worktree 建起来之后给整组发 INT；开 job control（set -m）是为了让后台那一组收得到 INT。
# 写成独立的 bash 程序：run_scripted 经 timeout 执行命令，timeout 看不见 shell 函数。
staged_interrupt=(bash -c '
  pkg="$1" proj="$2"
  set -m
  bash "$pkg/scripts/gate.sh" --staged "$proj" >/dev/null 2>&1 &
  job="$!"
  for _ in $(seq 1 100); do
    [[ "$(git -C "$proj" worktree list --porcelain | grep -c "^worktree ")" -ge 2 ]] && break
    sleep 0.1
  done
  kill -INT -- -"$job" 2>/dev/null; wait "$job" 2>/dev/null
  left="$(git -C "$proj" worktree list --porcelain | grep -c "^worktree ")"
  echo "打断之后仓里登记的 worktree：$left 个"
  [[ "$left" == 1 ]]' staged_interrupt)
r="$tmpd/gate-staged-interrupt"; mk_gate_pkg "$r/pkg"; mk_staged_project "$r/proj"
printf '#!/usr/bin/env bash\n# gate-stage: 慢样本\nsleep 20\n' > "$r/proj/.claude/gate.d/60-slow.sh"
git -C "$r/proj" add .claude/gate.d/60-slow.sh
run_scripted "gate/--staged 跑到一半被打断也清掉临时 worktree" 0 "打断之后仓里登记的 worktree：1 个" \
  -- "${staged_interrupt[@]}" "$r/pkg" "$r/proj"

# 未实现清单由项目阶段声明覆盖（# gate-covers:）。四个方向各一例：
# 通过 ⇒ 那一项换成「由谁覆盖」、收尾那句跟着换；跑红 ⇒ 照旧列着；退 77 ⇒ 记本次未跑、照旧列着；键写错 ⇒ 判红。
# 「列着 / 没列着」只看未实现那一段：收尾那句与 howto 里也会出现同一个词。
mk_covers_project() { # mk_covers_project <目录> <本地阶段的退出码> <gate-covers 的键>
  mkdir -p "$1/.claude/gate.d"
  printf '0.0.0\n' > "$1/.singlefs-ai-sop-version"
  printf '#!/usr/bin/env bash\n# gate-stage: 样本重放\n# gate-covers: %s\necho "  样本阶段跑完"\nexit %s\n' "$3" "$2" \
    > "$1/.claude/gate.d/54-sample.sh"
}
gate_with_not_impl_section=(bash -c '
  bash "$1/scripts/gate.sh" "$2" > "$3" 2>&1; rc=$?
  cat "$3"
  listed="$(sed -n "/未实现的门禁阶段/,/^\$/p" "$3" | sed -n "s/^ *! \([^：]*\)：.*/\1/p" | tr -d " " | paste -sd " " -)"
  echo "未实现段：$listed"
  exit "$rc"' gate_with_not_impl_section)
r="$tmpd/gate-covers-pass"; mk_gate_pkg "$r/pkg"; mk_covers_project "$r/proj" 0 崩溃点重放
run_scripted "gate/覆盖声明的阶段通过，那一项换成由谁覆盖" 0 "崩溃点重放 ← 样本重放" \
  "未实现段：模型对拍 最终判据 命名纪律（shell）" "崩溃点重放由「样本重放」覆盖" \
  -- "${gate_with_not_impl_section[@]}" "$r/pkg" "$r/proj" "$r/out.txt"
r="$tmpd/gate-covers-fail"; mk_gate_pkg "$r/pkg"; mk_covers_project "$r/proj" 1 崩溃点重放
run_scripted "gate/覆盖声明的阶段跑红，那一项照旧列着" 1 门禁未通过 "未实现段：模型对拍 崩溃点重放 最终判据 命名纪律（shell）" \
  -- "${gate_with_not_impl_section[@]}" "$r/pkg" "$r/proj" "$r/out.txt"
r="$tmpd/gate-covers-77"; mk_gate_pkg "$r/pkg"; mk_covers_project "$r/proj" 77 崩溃点重放
run_scripted "gate/本地阶段退 77 记本次未跑，不算覆盖" 0 "本次未跑：阶段报了这一轮无对象可判（退出码 77）" \
  "未实现段：模型对拍 崩溃点重放 最终判据 命名纪律（shell）" "崩溃一致性尚未纳入门禁" \
  -- "${gate_with_not_impl_section[@]}" "$r/pkg" "$r/proj" "$r/out.txt"
r="$tmpd/gate-covers-typo"; mk_gate_pkg "$r/pkg"; mk_covers_project "$r/proj" 0 崩溃重放
run_scripted "gate/gate-covers 写了清单里没有的项要红" 1 "gate-covers 写了清单里没有的项：「崩溃重放」" \
  -- "${gate_with_not_impl_section[@]}" "$r/pkg" "$r/proj" "$r/out.txt"

# ── gate.sh 与各脚本之间的约定 ──────────────────────────
# doc-lint 报的未实现项要出现在汇总里。此前 en / ja 仓那三条检查报了「未实现」，阶段照样记 PASS，
# 汇总的未实现清单里也没有它们——而汇总才是人会看的那一处（审计实测）。
r="$tmpd/gate-notimpl"; mk_gate_pkg "$r"
printf '#!/usr/bin/env bash\nif [[ "${1:-}" == --not-impl ]]; then echo "文档铁律的词表型检查（en）：本语言没有词表"; exit 0; fi\nexit 0\n' > "$r/scripts/doc-lint.sh"
run_scripted "gate/汇总里列出 doc-lint 报的未实现项" 0 "文档铁律的词表型检查（en）：本语言没有词表" -- bash "$r/scripts/gate.sh" "$r"

# 命名纪律退 3 = 没有要查的 .rs，记「本次未跑」不记通过（与 Show me test 同一个约定）。
r="$tmpd/gate-naming3"; mk_gate_pkg "$r"
printf '#!/usr/bin/env bash\nexit 3\n' > "$r/scripts/naming-lint.sh"
run_scripted "gate/命名纪律无对象可判记本次未跑" 0 "命名纪律            本次无对象可判" -- bash "$r/scripts/gate.sh" "$r"

# 本地阶段拿得到这一轮的 diff 基准：此前只有 show-me-test 自己算，本地阶段各按各的口径取，
# 同一轮里两个阶段判的不是同一批改动，而它们的注释都写着「与 Show me test 同一套口径」。
r="$tmpd/gate-diffbase"; mk_gate_pkg "$r/pkg"; mk_staged_project "$r/proj"
printf '#!/usr/bin/env bash\n# gate-stage: 基准探针\nif [[ -n "${GATE_DIFF_BASE:-}" ]]; then echo "  %s 基准已导入（查了 1 项）"; else echo "  基准没导入"; exit 1; fi\n' ✓ > "$r/proj/.claude/gate.d/70-base.sh"
git -C "$r/proj" add -A; git -C "$r/proj" -c user.name=t -c user.email=t@t commit -qm probe
run_scripted "gate/本地阶段拿得到这一轮的 diff 基准" 0 "基准已导入" -- bash "$r/pkg/scripts/gate.sh" "$r/proj"

# 从 git 钩子里跑时 git 设了 GIT_DIR 这一组，它们压过 `git -C`：不清掉的话 worktree add 会失败，
# 而报出来的出路是「先跑 git worktree prune」，指的方向是错的。
# ⚠️ GIT_DIR 要用**相对路径**，而且要 cd 进项目再跑——git 给钩子设的就是相对的 `.git`。
# 写成绝对路径时它恰好还指着同一个仓，不清掉也照样跑得通，这条用例就分不出修没修
# （第一版实测：变异之后它一声不吭）。相对路径在 gate.sh 换了工作目录之后才会指错地方。
r="$tmpd/gate-hookenv"; mk_gate_pkg "$r/pkg"; mk_staged_project "$r/proj"
hookenv_check=(bash -c 'cd "$2" && GIT_DIR=.git GIT_INDEX_FILE=.git/index bash "$1/scripts/gate.sh" --staged .' hookenv_check)
run_scripted "gate/带着 git 钩子的环境变量也跑得了 --staged" 0 "只拿 HEAD + 暂存区跑" -- \
  "${hookenv_check[@]}" "$r/pkg" "$r/proj"

# --staged 中途 die 也要把临时 worktree 带走。只挂 INT / TERM 时，die 那几条路径会留下一个 worktree。
# 摆法：暂存区里删掉 scripts/gate.sh，临时树里就没有它，里层跑不起来，走 die。
r="$tmpd/gate-exittrap"; mk_gate_pkg "$r"
git -C "$r" init -q && git -C "$r" add -A && git -C "$r" -c user.name=t -c user.email=t@t commit -qm base
git -C "$r" rm -q --cached scripts/gate.sh >/dev/null
exittrap_check=(bash -c '
  bash "$1/scripts/gate.sh" --staged "$1" >/dev/null 2>&1
  left="$(git -C "$1" worktree list --porcelain | grep -c "^worktree ")"
  echo "die 之后仓里登记的 worktree：$left 个"
  [[ "$left" == 1 ]]' exittrap_check)
run_scripted "gate/--staged 中途 die 也清掉临时 worktree" 0 "die 之后仓里登记的 worktree：1 个" -- "${exittrap_check[@]}" "$r"

# 「规范版本不一致」那条拒绝里用到族名，而族名此前定义在几十行之后：set -u 下它一出口就是 unbound variable，
# 拒绝本身一个字都打不出来。
r="$tmpd/gate-vermis"; mk_gate_pkg "$r/proj/.claude/f"
printf '0.0.1\n' > "$r/proj/.singlefs-ai-sop-version"
run_scripted "gate/版本戳对不上时那条拒绝打得出来" 1 "规范版本不一致" "install.sh 更新版本戳" -- \
  bash "$r/proj/.claude/f/scripts/gate.sh" "$r/proj"

# ── gate.sh 的判决分支：改成无条件记 PASS 也要有人发现 ──
# 审计实测：把这几处改成 record PASS，自检 292 例一个都没红——判决点自己没人盯。
# 本地阶段要交给两个 lint：它们和共享阶段一样会拒绝提交者。
r="$tmpd/gate-lintextra"; mk_gate_pkg "$r/pkg"; mk_staged_project "$r/proj"
cp "$SCRIPTS/gate-lint.sh" "$SCRIPTS/shell-lint.sh" "$r/pkg/scripts/"
# 放进 gate.d 的**子目录**：gate.sh 只把 maxdepth 1 的 *.sh 当阶段跑，而两个 lint 是递归扫的。
# 直接放在 gate.d 根下，它会作为一个阶段被执行、自己判红，于是去掉 LINT_EXTRA 之后门禁照样退 1、
# 输出里照样有这个文件名——这条用例就分不出「lint 扫到了」还是「阶段自己红了」（第一版实测：变异之后它一声不吭）。
mkdir -p "$r/proj/.claude/gate.d/lib"
cp "$FX/scan/root-nakeddie.sh" "$r/proj/.claude/gate.d/lib/90-nakeddie.sh"
run_scripted "gate/本地阶段也交给两个 lint" 1 "90-nakeddie.sh:3  拒绝但没有出路" -- bash "$r/pkg/scripts/gate.sh" "$r/proj"

# ── gate.sh：跑的过程中工作区变了要判红 ──
# 门禁的结论只对它读到的那一版成立。拿一个项目本地阶段在跑的时候改文件，模拟边改边跑与别的会话中途改动。
r="$tmpd/gate-worktree-changed"; mk_gate_pkg "$r/pkg"; mk_staged_project "$r/proj"
printf '#!/usr/bin/env bash\n# gate-stage: 中途改文件\ncd "${1:-.}" || exit 2\nprintf "跑到一半有人改了\\n" >> kb/b.md\necho "  ✓ 改了 1 个文件"\n' > "$r/proj/.claude/gate.d/60-edit-midway.sh"
git -C "$r/proj" add -A && git -C "$r/proj" -c user.name=t -c user.email=t@t commit -qm 加一个中途改文件的阶段
run_scripted "gate/跑的过程中工作区变了要判红" 1 "门禁跑的这段时间里工作区变了" 门禁未通过 -- bash "$r/pkg/scripts/gate.sh" "$r/proj"
# 反面：跑的过程中只暂存、不改内容，不算工作区变了（指纹用临时索引算，与暂存区无关）。
# 少了这一例，指纹换成「git status 的输出」这种会被别的会话暂存搅动的算法也照样全绿。
r="$tmpd/gate-worktree-staged-only"; mk_gate_pkg "$r/pkg"; mk_staged_project "$r/proj"
printf '#!/usr/bin/env bash\n# gate-stage: 中途只暂存\ncd "${1:-.}" || exit 2\ngit add kb/a.md\necho "  ✓ 暂存了 1 个文件"\n' > "$r/proj/.claude/gate.d/60-stage-midway.sh"
git -C "$r/proj" add .claude && git -C "$r/proj" -c user.name=t -c user.email=t@t commit -qm 加一个中途只暂存的阶段
printf '这一轮改过\n' >> "$r/proj/kb/a.md"
run_scripted "gate/中途只暂存不算工作区变了" 0 "开跑与收尾的工作区指纹相同" "已实现的门禁阶段全部通过" -- bash "$r/pkg/scripts/gate.sh" "$r/proj"
# 指纹不许碰真索引：直接在真索引上 git add -A 的话，每跑一次门禁，使用者没暂存的改动都被悄悄暂存。
# 只比指纹的值看不出这一点——两种算法算出来的树逐字节相同（审核实测）——所以直接比调用前后的 git status。
fingerprint_index_check=(bash -c '
  source "$1/lib.sh"; repo="$2"
  before="$(git -C "$repo" status --porcelain)"
  fingerprint="$(worktree_fingerprint "$repo")"
  after="$(git -C "$repo" status --porcelain)"
  [[ -n "$fingerprint" ]] || { echo "指纹是空的"; exit 1; }
  if [[ "$before" == "$after" ]]; then echo "调用前后 git status 相同"
  else printf "调用前：\n%s\n调用后：\n%s\n" "$before" "$after"; exit 1; fi' fingerprint_index_check)
r="$tmpd/fingerprint-index"; mkdir -p "$r"; git -C "$r" init -q
printf '甲\n' > "$r/a.md"; git -C "$r" add a.md; git -C "$r" -c user.name=t -c user.email=t@t commit -qm a
printf '改了没暂存\n' >> "$r/a.md"; printf '没跟踪\n' > "$r/b.md"
run_scripted "lib/工作区指纹不碰真索引" 0 "调用前后 git status 相同" -- "${fingerprint_index_check[@]}" "$SCRIPTS" "$r"

# Show me test 退 3 = 无对象可判，记「本次未跑」不记通过。
r="$tmpd/gate-smt3"; mk_gate_pkg "$r"
printf '#!/usr/bin/env bash\nexit 3\n' > "$r/scripts/show-me-test.sh"
run_scripted "gate/Show me test 无对象可判记本次未跑" 0 "Show me test        本次无对象可判" -- bash "$r/scripts/gate.sh" "$r"

# 跑的不是项目里装的那份副本时，这条检查测的就不是它名字说的东西，必须判红。
r="$tmpd/gate-notcopy"; mk_gate_pkg "$r/pkg"; mkdir -p "$r/proj/.claude/f"
printf '0.0.0\n' > "$r/proj/.singlefs-ai-sop-version"
printf '0.0.9\n' > "$r/proj/.claude/f/VERSION"
run_scripted "gate/跑的不是项目里那份副本要判红" 1 "跑的不是项目里那份副本" -- bash "$r/pkg/scripts/gate.sh" "$r/proj"

# 有 .rs 却没有 Cargo.toml：这些代码根本没被构建过，不能当「本阶段不适用」放过。
r="$tmpd/gate-nocargo"; mk_gate_pkg "$r/proj/.claude/f"
printf '0.0.0\n' > "$r/proj/.singlefs-ai-sop-version"
mkdir -p "$r/proj/crates/foo/src"; printf 'pub fn f() {}\n' > "$r/proj/crates/foo/src/lib.rs"
run_scripted "gate/有 .rs 却没有 Cargo.toml 要判红" 1 "这些代码根本没被构建过" -- \
  bash "$r/proj/.claude/f/scripts/gate.sh" "$r/proj"

# 规范副本被 .gitignore 挡着时，--staged 要把它原样拷进临时树，否则项目里的包装脚本转发不到。
r="$tmpd/gate-copyinto"; mkdir -p "$r/proj/.claude/gate.d"; mk_gate_pkg "$r/proj/.claude/f"
printf '0.0.0\n' > "$r/proj/.singlefs-ai-sop-version"
printf '.claude/f/\n' > "$r/proj/.gitignore"
printf '#!/usr/bin/env bash\n# gate-stage: 副本在不在\nif [[ -d "${1:?}/.claude/f" ]]; then echo "  %s 副本在（查了 1 项）"; else echo "  副本不在"; exit 1; fi\n' ✓ > "$r/proj/.claude/gate.d/80-copy.sh"
git -C "$r/proj" init -q && git -C "$r/proj" add -A && git -C "$r/proj" -c user.name=t -c user.email=t@t commit -qm base
run_scripted "gate/--staged 把不进 git 的副本拷进临时树" 0 "副本在" -- \
  bash "$r/proj/.claude/f/scripts/gate.sh" --staged "$r/proj"

# ════ changelog-lint ═════════════════════════════════════
head1 "门禁自检：changelog-lint 的判别力"
[[ -d "$FX/changelog-lint" ]] || { bad "缺样本目录 $FX/changelog-lint"
  howto "样本要随仓走。没有样本，下一个改 changelog-lint.sh 的人无从复跑。"; exit 1; }
for d in "$FX"/changelog-lint/*/; do
  spawn_fixture "changelog-lint/$(basename "$d")" "$d" bash "$SCRIPTS/changelog-lint.sh" "$d"
done
collect_fixtures

# ════ naming-lint ════════════════════════════════════════
head1 "门禁自检：naming-lint 的判别力"
[[ -d "$FX/naming-lint" ]] || { bad "缺样本目录 $FX/naming-lint"
  howto "样本要随仓走。没有样本，下一个改 naming-lint.sh 的人无从复跑。"; exit 1; }
for d in "$FX"/naming-lint/*/; do
  spawn_fixture "naming-lint/$(basename "$d")" "$d" bash "$SCRIPTS/naming-lint.sh" "$d"
done
collect_fixtures

# ════ version-discipline ═════════════════════════════════
head1 "门禁自检：version-discipline 的判别力"
mk_sop() { # mk_sop <目录> —— 一个已提交基线的最小规范仓
  mkdir -p "$1/scripts"
  printf '0.0.1\n' > "$1/VERSION"
  printf 'echo hi\n' > "$1/scripts/x.sh"
  git -C "$1" init -qb master
  git -C "$1" add -A
  git -C "$1" -c user.email=selftest@local -c user.name=selftest commit -qm init
}
r="$tmpd/vd-red"; mk_sop "$r"
printf 'echo more\n' >> "$r/scripts/x.sh"
run_scripted "version-discipline/改脚本不抬版本" 1 没抬 -- bash "$SCRIPTS/version-discipline.sh" "$r"

r="$tmpd/vd-green"; mk_sop "$r"
printf 'echo more\n' >> "$r/scripts/x.sh"
printf '0.0.2\n' > "$r/VERSION"
run_scripted "version-discipline/带着版本一起改" 0 "抬到了 0.0.2" -- bash "$SCRIPTS/version-discipline.sh" "$r"

# 判据是「抬了」不是「动过」：往 VERSION 末尾加个空行就过闸的话，
# 消费项目读到的内容一个字没变（对抗测试实测，全门禁绿）。
r="$tmpd/vd-touch"; mk_sop "$r"
printf 'echo more\n' >> "$r/scripts/x.sh"
printf '\n' >> "$r/VERSION"
run_scripted "version-discipline/只动 VERSION 不抬不算" 1 没抬 -- bash "$SCRIPTS/version-discipline.sh" "$r"

# 版本只许往上走：降级会让已装新版的项目看到「上游更旧」，无从判断
r="$tmpd/vd-down"; mk_sop "$r"
printf 'echo more\n' >> "$r/scripts/x.sh"
printf '0.0.0\n' > "$r/VERSION"
run_scripted "version-discipline/降级要红" 1 降级了 -- bash "$SCRIPTS/version-discipline.sh" "$r"

# CHANGELOG 不在 GOVERNED 里：它是记版本变更的地方，改它本身不构成规范变更。
# （README.md 曾经被当成这个用例的「无关改动」，纳入 GOVERNED 后这里当场红——
#  自检起作用的样子就是这样。）
r="$tmpd/vd-na"; mk_sop "$r"
echo note > "$r/CHANGELOG.md"
run_scripted "version-discipline/无关改动不管" 0 不适用 -- bash "$SCRIPTS/version-discipline.sh" "$r"

# GOVERNED 是脚本自称的唯一权威，**每一项都要有人盯**：
# 复核实测，9 项里只有 scripts/ 与 README.md 有样本，其余 7 项可以静默摘掉。
for gp in README.md CLAUDE.md install.sh GLOSSARY.md I18N \
          rules/a.md skills/s/SKILL.md templates/t.md agents/a.md; do
  r="$tmpd/vd-gov-$(printf '%s' "$gp" | tr '/.' '__')"; mk_sop "$r"
  mkdir -p "$r/$(dirname "$gp")"; echo note > "$r/$gp"
  run_scripted "version-discipline/$gp 也要抬版本" 1 没抬 -- bash "$SCRIPTS/version-discipline.sh" "$r"
done

# VERSION 要精确匹配整行：写成 grep -q 的话，新增一个 VERSIONING.md 就能冒充抬过版本
r="$tmpd/vd-lookalike"; mk_sop "$r"
printf 'echo more\n' >> "$r/scripts/x.sh"
echo note > "$r/VERSIONING.md"
run_scripted "version-discipline/名字像VERSION的文件不算" 1 没抬 -- bash "$SCRIPTS/version-discipline.sh" "$r"

# ════ manifest 与 i18n-sync（失败分支曾静默崩溃，这两条是回归钉）══
head1 "门禁自检：manifest / i18n-sync 的判别力"
# 搭样本用的盖章。失败要当场说清：输出丢进 /dev/null 的话，lib.sh 的 set -e 会把整个自检一声不响地带走，
# 后面几十个用例一个都不跑，只剩一个退出码 1（审核实测：盖章与回读的形态一对不上，自检停在第 245 例）。
setup_stamp() { # setup_stamp <参照仓> <语言> <篇目...>
  local ref="$1" lang="$2" log; shift 2
  log="$(mktemp)"
  if ! bash "$ref/scripts/i18n-sync.sh" --stamp "$lang" "$@" > "$log" 2>&1; then
    sed 's/^/     | /' "$log"
    die "搭译本样本时 i18n-sync --stamp 失败，依赖这份样本的用例一个都没跑" \
        "照上面的原话修 i18n-sync（多半是盖章与回读认的形态对不上），再重跑 selftest。"
  fi
  rm -f "$log"
}
mk_pair() { # mk_pair <目录> —— 参照仓 + 一个完全跟上的 en 译本仓，返回参照仓路径
  local base="$1"
  local ref="$base/f-zh" sib="$base/f-en"
  mk_pkg "$ref" f
  mkdir -p "$sib"
  cp "$ref/MANIFEST.sha256" "$sib/SOURCE-MANIFEST.sha256"
  cp "$ref/VERSION" "$sib/VERSION"
  local item
  for item in install.sh scripts skills templates GLOSSARY.md; do
    [[ -e "$ref/$item" ]] && cp -a "$ref/$item" "$sib/$item"
  done
  sed 's/^this=.*/this=en/' "$ref/I18N" > "$sib/I18N"
  # 逐篇盖上溯源标记：**走真正的 --stamp**，不在这里另写一份放置逻辑。
  # 手写的话，标记会一律拍在第 1 行，把 SKILL.md 的 frontmatter 压掉——
  # 那正是被检查拦下的形态（第一版这么写，当场被自己的检查判红）。
  local path
  while read -r _h path; do
    mkdir -p "$sib/$(dirname "$path")"; cp "$ref/$path" "$sib/$path"
  done < "$ref/MANIFEST.sha256"
  git -C "$sib" init -q          # --stamp 只往 git 仓里写
  # shellcheck disable=SC2046  # 篇目按空白拆开，正是要的
  setup_stamp "$ref" en $(sed 's/^[0-9a-f]*  //' "$ref/MANIFEST.sha256")
}
mk_pkg() { # mk_pkg <目录> <族名> —— 最小参照仓（脚本用真的，内容是样本）
  mkdir -p "$1/scripts" "$1/rules" "$1/skills" "$1/templates" "$1/agents"
  cp "$SCRIPTS/lib.sh" "$SCRIPTS/manifest.sh" "$SCRIPTS/i18n-sync.sh" "$1/scripts/"
  printf '# 样本规范\n' > "$1/CLAUDE.md"
  printf '# 规则甲\n' > "$1/rules/a.md"
  printf '# 术语\n' > "$1/GLOSSARY.md"
  printf 'echo install\n' > "$1/install.sh"
  printf '# 骨架\n' > "$1/templates/t.md"
  printf -- '---\nname: a\ndescription: 样本 agent\n---\n\n正文。\n' > "$1/agents/a.md"
  mkdir -p "$1/skills/s"
  printf -- '---\nname: s\ndescription: 样本 skill\n---\n\n正文。\n' > "$1/skills/s/SKILL.md"
  printf '0.0.1\n' > "$1/VERSION"
  printf 'family=%s\nthis=zh\nreference=zh\ndefault=zh\nlanguages=zh en\n' "$2" > "$1/I18N"
  bash "$1/scripts/manifest.sh" --update >/dev/null
}

p="$tmpd/mani/f-zh"; mk_pkg "$p" f
printf '改了一句\n' >> "$p/rules/a.md"
run_scripted "manifest/清单陈旧要红且给出路" 1 不一致 怎么办 -- bash "$p/scripts/manifest.sh"

p="$tmpd/i18n/f-zh"; mk_pkg "$p" f
sib="$tmpd/i18n/f-en"; mkdir -p "$sib"
cp "$p/MANIFEST.sha256" "$sib/SOURCE-MANIFEST.sha256"
printf '0.0.1\n' > "$sib/VERSION"
printf '改了一句\n' >> "$p/rules/a.md"
bash "$p/scripts/manifest.sh" --update >/dev/null
# 关键 want：待重译（诊断打了）+ 怎么办（howto 打了）+ 失败汇总（脚本活到了最后）。
# 曾经 diff 管道在 set -e + pipefail 下把脚本中途带走，三样全丢（对抗测试实测）。
run_scripted "i18n-sync/落后要红且诊断齐全" 1 待重译 怎么办 各语言同步失败 -- \
  bash "$p/scripts/i18n-sync.sh"

# i18n-sync 的其余分支：复核实测，8 条检查只有上面这一条有人盯，
# 其中三条在脚本注释里被标成「对抗测试实测过的回归」——可以再犯一次而无人知晓。
# 造一个「一切就绪」的参照仓 + 译本仓，再逐项破坏其中一样。
b="$tmpd/i18n-ok"; mk_pair "$b"
run_scripted "i18n-sync/一切就绪要绿" 0 逐篇溯源对得上 -- bash "$b/f-zh/scripts/i18n-sync.sh" "$b"

b="$tmpd/i18n-stalemf"; mk_pair "$b"
printf '改了一句\n' >> "$b/f-zh/rules/a.md"          # 源文改了、清单没刷新
run_scripted "i18n-sync/清单陈旧则无法判定" 1 陈旧 -- bash "$b/f-zh/scripts/i18n-sync.sh" "$b"

b="$tmpd/i18n-notrans"; mk_pair "$b"
printf '改了一句\n' >> "$b/f-zh/rules/a.md"
bash "$b/f-zh/scripts/manifest.sh" --update >/dev/null
cp "$b/f-zh/MANIFEST.sha256" "$b/f-en/SOURCE-MANIFEST.sha256"   # 抄了清单却没重译
run_scripted "i18n-sync/抄了清单没重译" 1 溯源标记与源文对不上 -- bash "$b/f-zh/scripts/i18n-sync.sh" "$b"

# --update 替译本仓刷新 SOURCE-MANIFEST：逐篇溯源都对上才抄，有一篇没重译就不抄。
# 以前这一步靠人手抄，漏抄时 --update 整个被「落后」拒掉（2026-09-11 发 0.0.42 时实测）。
b="$tmpd/i18n-autosm"; mk_pair "$b"
printf '改了一句\n' >> "$b/f-zh/rules/a.md"
bash "$b/f-zh/scripts/manifest.sh" --update >/dev/null
printf '改了一句（已重译）\n' >> "$b/f-en/rules/a.md"
setup_stamp "$b/f-zh" en rules/a.md
run_scripted "i18n-sync/重译并盖章后 --update 自己抄 SOURCE-MANIFEST" 0 \
  "SOURCE-MANIFEST 已照本仓清单刷新" 逐篇溯源对得上 -- bash "$b/f-zh/scripts/i18n-sync.sh" --update "$b"
run_scripted "i18n-sync/抄出来的 SOURCE-MANIFEST 与清单逐字节一致" 0 -- \
  cmp "$b/f-zh/MANIFEST.sha256" "$b/f-en/SOURCE-MANIFEST.sha256"

b="$tmpd/i18n-autosm-stale"; mk_pair "$b"
printf '改了一句\n' >> "$b/f-zh/rules/a.md"
bash "$b/f-zh/scripts/manifest.sh" --update >/dev/null
cp "$b/f-en/SOURCE-MANIFEST.sha256" "$tmpd/i18n-autosm-stale.before"
run_scripted "i18n-sync/没重译时 --update 不替它抄 SOURCE-MANIFEST" 1 \
  "SOURCE-MANIFEST 不替它抄" "译自旧版源文，需重译: rules/a.md" -- bash "$b/f-zh/scripts/i18n-sync.sh" --update "$b"
run_scripted "i18n-sync/没重译时 SOURCE-MANIFEST 一个字节都没动" 0 -- \
  cmp "$tmpd/i18n-autosm-stale.before" "$b/f-en/SOURCE-MANIFEST.sha256"

b="$tmpd/i18n-autosm-missing"; mk_pair "$b"; rm -f "$b/f-en/SOURCE-MANIFEST.sha256"
run_scripted "i18n-sync/缺 SOURCE-MANIFEST 时 --update 替它补上" 0 \
  "SOURCE-MANIFEST 已照本仓清单刷新" -- bash "$b/f-zh/scripts/i18n-sync.sh" --update "$b"

b="$tmpd/i18n-missing"; mk_pair "$b"
rm -f "$b/f-en/rules/a.md"                            # 少一篇译文
run_scripted "i18n-sync/少一篇译文" 1 缺 -- bash "$b/f-zh/scripts/i18n-sync.sh" "$b"

b="$tmpd/i18n-ver"; mk_pair "$b"
printf '9.9.9\n' > "$b/f-en/VERSION"                  # 版本不一致
run_scripted "i18n-sync/版本不一致" 1 版本不一致 -- bash "$b/f-zh/scripts/i18n-sync.sh" "$b"

b="$tmpd/i18n-shared"; mk_pair "$b"
printf 'echo 手改的\n' >> "$b/f-en/install.sh"        # 共享部分被手改
run_scripted "i18n-sync/共享部分被手改" 1 共享部分与本仓不一致 -- bash "$b/f-zh/scripts/i18n-sync.sh" "$b"

b="$tmpd/i18n-gloss"; mk_pair "$b"
printf '多加一个词\n' >> "$b/f-en/GLOSSARY.md"        # GLOSSARY 跨语言漂移
run_scripted "i18n-sync/GLOSSARY 漂移" 1 共享部分与本仓不一致 -- bash "$b/f-zh/scripts/i18n-sync.sh" "$b"

# 溯源标记不许压住文件本身的头，实测过的坑：
# SKILL.md 的 frontmatter 被顶下去 → skill 安静地装不上。
b="$tmpd/i18n-headfm"; mk_pair "$b"
sed -i '1i <!-- generated-from: skills/s/SKILL.md sha256:0000000000000000000000000000000000000000000000000000000000000000 -->' \
  "$b/f-en/skills/s/SKILL.md"
run_scripted "i18n-sync/标记压住 frontmatter" 1 "篇的第 1 行被压住了" -- bash "$b/f-zh/scripts/i18n-sync.sh" "$b"

# 溯源标记的几种坏法，各自有自己的消息——共用一条 want 就盖住了别的。
# agents 定义与 SKILL.md 同律。此前 case 分支写成 */agents/*.md，而清单里的路径是
# 仓根相对的 agents/x.md，前面没有那一段——整条 agents 路径一次也没被检查过（复核实测）。
b="$tmpd/i18n-agentfm"; mk_pair "$b"
sed -i '1i <!-- generated-from: agents/a.md sha256:0000000000000000000000000000000000000000000000000000000000000000 -->' \
  "$b/f-en/agents/a.md"
run_scripted "i18n-sync/标记压住 agent 的 frontmatter" 1 "篇的第 1 行被压住了" -- \
  bash "$b/f-zh/scripts/i18n-sync.sh" "$b"

b="$tmpd/i18n-nosm"; mk_pair "$b"
rm -f "$b/f-en/SOURCE-MANIFEST.sha256"
run_scripted "i18n-sync/缺 SOURCE-MANIFEST" 1 "译本仓缺 SOURCE-MANIFEST" -- \
  bash "$b/f-zh/scripts/i18n-sync.sh" "$b"

b="$tmpd/i18n-nomark"; mk_pair "$b"
sed -i '1d' "$b/f-en/rules/a.md"                       # 把溯源标记整行删掉
run_scripted "i18n-sync/译文缺溯源标记" 1 "首行缺 generated-from 标记" -- \
  bash "$b/f-zh/scripts/i18n-sync.sh" "$b"

b="$tmpd/i18n-wrongsrc"; mk_pair "$b"
sed -i '1s|rules/a.md|CLAUDE.md|' "$b/f-en/rules/a.md"  # 标记指向别的源文
run_scripted "i18n-sync/溯源指向别的源文" 1 "溯源标记指向别的源文" -- \
  bash "$b/f-zh/scripts/i18n-sync.sh" "$b"

b="$tmpd/i18n-norepo"; mk_pair "$b"
rm -rf "${b:?}/f-en"                                       # 译本仓根本不在
run_scripted "i18n-sync/译本仓缺失" 1 找不到译本仓 -- bash "$b/f-zh/scripts/i18n-sync.sh" "$b"


# --stamp 的拒绝分支此前一条样本都没有：盖章是译本仓的日常操作，拒错了会把没重译的篇目标成新的。
b="$tmpd/stamp-nofile"; mk_pair "$b"
run_scripted "i18n-sync/--stamp 不给篇目要拒绝" 1 "--stamp 没给篇目" -- bash "$b/f-zh/scripts/i18n-sync.sh" --stamp en
b="$tmpd/stamp-norepo"; mk_pair "$b"
run_scripted "i18n-sync/--stamp 的语言仓不在要拒绝" 1 "找不到 git 仓" -- bash "$b/f-zh/scripts/i18n-sync.sh" --stamp ja rules/a.md
b="$tmpd/stamp-notlisted"; mk_pair "$b"
run_scripted "i18n-sync/--stamp 不在清单里的篇目要拒绝" 1 "不在 MANIFEST.sha256 里" -- bash "$b/f-zh/scripts/i18n-sync.sh" --stamp en rules/nope.md
b="$tmpd/stamp-notranslation"; mk_pair "$b"; rm -f "$b/f-en/rules/a.md"
run_scripted "i18n-sync/--stamp 没译出来的篇目要拒绝" 1 "en 仓里没有 rules/a.md" -- bash "$b/f-zh/scripts/i18n-sync.sh" --stamp en rules/a.md
# `.git` 也可以是文件（git worktree、子模块都是这样）。i18n-sync 三处判「是不是 git 仓」此前只认目录，
# 在 worktree 上做译文同步会被拒，理由还写成「不是 git 仓」——而这个仓自己发布时就是在 worktree 上做的。
mk_gitfile_sibling() { # mk_gitfile_sibling <mk_pair 的目录>：把 f-en 的 .git 目录挪出去，原位只留一个指路的文件
  mv "$1/f-en/.git" "$1/en.gitdir"
  printf 'gitdir: %s\n' "$1/en.gitdir" > "$1/f-en/.git"
}
b="$tmpd/stamp-gitfile"; mk_pair "$b"; mk_gitfile_sibling "$b"
run_scripted "i18n-sync/--stamp 认 .git 是文件的译本仓" 0 "rules/a.md" -- bash "$b/f-zh/scripts/i18n-sync.sh" --stamp en rules/a.md
# 先删掉译本仓的 SOURCE-MANIFEST：mk_pair 建出来的是完全跟上的，--update 根本走不到「替它抄 SOURCE-MANIFEST」那一支，
# 那一处的 .git 判据改回只认目录，这条用例也照样绿（第一版实测：变异之后它一声不吭）。
b="$tmpd/update-gitfile"; mk_pair "$b"; mk_gitfile_sibling "$b"; rm -f "$b/f-en/SOURCE-MANIFEST.sha256"
run_scripted "i18n-sync/--update 认 .git 是文件的译本仓" 0 "SOURCE-MANIFEST 已照本仓清单刷新" "共享部分已同步" -- \
  bash "$b/f-zh/scripts/i18n-sync.sh" --update "$b"
# 回读闸：frontmatter 闭合之后文件就结束了，标记该插在一个不存在的行前面，`sed` 什么都不做、也不报错——
# 要当场拒绝，不许报「盖好了」。（第一版用没闭合的 frontmatter 去触发，它被正常处理了，那条用例是假的。）
b="$tmpd/stamp-readback"; mk_pair "$b"; printf -- '---\nname: s\ndescription: 正文一行都没有\n---' > "$b/f-en/skills/s/SKILL.md"
run_scripted "i18n-sync/--stamp 回读对不上要拒绝" 1 "盖章后回读不一致" -- bash "$b/f-zh/scripts/i18n-sync.sh" --stamp en skills/s/SKILL.md
# ════ check.sh（此前零用例）══════════════════════════════
# 复核实测：删掉整个 cargo test 阶段、或去掉 clippy 的 -D warnings，selftest 无感。
# 它是门禁的「构建与单测」阶段，坏了等于代码根本没被验过。
head1 "门禁自检：check.sh 的判别力"
if command -v cargo >/dev/null 2>&1; then
  mk_crate() { # mk_crate <目录> <lib.rs 内容>
    mkdir -p "$1/src"
    printf '[package]\nname = "t"\nversion = "0.1.0"\nedition = "2021"\n' > "$1/Cargo.toml"
    printf '%s' "$2" > "$1/src/lib.rs"
  }
  r="$tmpd/ck-ok"; mk_crate "$r" 'pub fn f() -> u32 {
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
  run_scripted "check/干净的 crate 放行" 0 单测通过 -- bash "$SCRIPTS/check.sh" "$r"

  r="$tmpd/ck-test"; mk_crate "$r" 'pub fn f() -> u32 {
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
  run_scripted "check/单测失败要红" 1 单测失败 -- bash "$SCRIPTS/check.sh" "$r"

  r="$tmpd/ck-clippy"; mk_crate "$r" 'pub fn f() -> u32 {
    let unused = 7;
    1
}
'
  run_scripted "check/告警按错误处理" 1 "clippy 有告警" -- bash "$SCRIPTS/check.sh" "$r"

  r="$tmpd/ck-fmt"; mk_crate "$r" 'pub fn f()->u32{1}
'
  run_scripted "check/格式不合规要红" 1 格式不合规 -- bash "$SCRIPTS/check.sh" "$r"
else
  # 不许静默跳过：环境缺 cargo 就说出来，这几条判别力**本轮没验**
  warn "cargo 缺失 —— check.sh 的 4 个用例本次未跑（这不是通过）"
fi

# ════ install.sh 铺出来的东西 ════════════════════════════
# 装出来的项目里不许留分发层的账：溯源标记是「这份译文译自哪个版本」，
# 抄进使用者项目就是一条永不更新的陈旧标注，而且贴在他马上要改的文件上。
# 实测过：第一版原样 cp，装出来的 CLAUDE.md 第 1 行就是 generated-from。
head1 "门禁自检：install.sh 铺出来的东西"
# 从一个**模板带着溯源标记**的包里装——参照仓自己的模板没有标记（它是源文），
# 拿它装什么也测不出来。译本仓的模板才带标记，那才是使用者实际装的东西。
pkg="$tmpd/inst-pkg"; cp -a "$SCRIPTS/.." "$pkg"
sed -i '1i <!-- generated-from: templates/kb/decisions.md sha256:0000000000000000000000000000000000000000000000000000000000000000 -->' \
  "$pkg/templates/kb/decisions.md"
r="$tmpd/inst"; mkdir -p "$r"
inst_out="$tmpd/inst.log"
if bash "$pkg/install.sh" "$r" > "$inst_out" 2>&1; then
  leaked="$(grep -rlE 'generated-from: .+ sha256:' "$r" 2>/dev/null || true)"
  cases=$((cases+1))
  if [[ -z "$leaked" ]]; then
    pass=$((pass+1)); [[ -n "${SELFTEST_VERBOSE:-}" ]] && ok "install/不把溯源标记铺进项目"
  else
    fails=$((fails+1))
    bad "install/不把溯源标记铺进项目  这几份带着分发层的账："
    printf '%s\n' "$leaked" | sed "s|$r/||; s|^|        |"
    howto "install.sh 的 put() 在铺文件时要剥掉 generated-from 行。" \
          "它记的是译文译自哪个源文版本，是分发层的账，不是使用者项目的。"
  fi
else
  cases=$((cases+1)); fails=$((fails+1))
  bad "install/装不上：$(tail -1 "$inst_out")"
  howto "看完整输出： cat $inst_out"
fi

# 升级路径：上游改了内容而项目那份没跟上时，**版本戳不许刷**。
# 刷了就等于替项目声明「已经是新版了」，而它的 skill / 骨架还是旧的——
# 版本戳是项目唯一的「规矩变了」信号（对抗测试实测：刷了，gate 退出码 0）。
pkg2="$tmpd/inst-up"; cp -a "$SCRIPTS/.." "$pkg2"
r2="$tmpd/inst-up-proj"; mkdir -p "$r2"
bash "$pkg2/install.sh" "$r2" >/dev/null 2>&1 || true
run_scripted "install/无变化时重装干净" 0 "跳过" -- bash "$pkg2/install.sh" "$r2"
sed -i '1s|^|# 上游改了这一行\n|' "$pkg2/templates/kb/decisions.md"
printf '9.9.9\n' > "$pkg2/VERSION"
run_scripted "install/内容落后就不刷版本戳" 1 "份内容落后于上游，版本戳**没有**刷新" -- \
  bash "$pkg2/install.sh" "$r2"
cases=$((cases+1))
if [[ "$(cat "$r2/.singlefs-ai-sop-version")" != "9.9.9" ]]; then pass=$((pass+1))
  [[ -n "${SELFTEST_VERBOSE:-}" ]] && ok "install/落后时版本戳确实没动"
else fails=$((fails+1)); bad "install/落后时版本戳被刷成了 9.9.9"
  howto "install.sh 在 STALE 非空时必须直接退出，不许走到写版本戳那一步。"
fi

# 接管清单：项目自己改过的那几份不该算「落后」——kb 骨架本来就是给项目改的。
# 少了它，任何一个动过自己 kb 的项目，装完第一次之后版本戳就再也刷不动
# （实测于 singlefs：12 份「落后」全是项目自己改的，门禁阶段 0 因此长红）。
mkdir -p "$r2/.claude"
printf '.claude/kb/decisions.md  # 决策正文归项目，模板只给了格式\n' > "$r2/.claude/install-owned"
run_scripted "install/接管的那份不算落后" 0 "按 .claude/install-owned 不比对" -- \
  bash "$pkg2/install.sh" "$r2"
cases=$((cases+1))
if [[ "$(cat "$r2/.singlefs-ai-sop-version")" == "9.9.9" ]]; then pass=$((pass+1))
  [[ -n "${SELFTEST_VERBOSE:-}" ]] && ok "install/接管之后版本戳刷得动了"
else fails=$((fails+1)); bad "install/接管之后版本戳仍然没刷"
  howto "接管清单的用处就是让这几份不再算落后。它没生效，这条升级路就还是堵死的。"
fi

# 清单本身坏了不许放行：一份读不准的接管清单，等于把「落后就不刷戳」那道守卫悄悄关掉。
printf '.claude/kb/decisions.md\n' > "$r2/.claude/install-owned"
run_scripted "install/接管清单没写理由要红" 1 "这一条没写理由" -- bash "$pkg2/install.sh" "$r2"
printf 'research/nowhere.md  # 写了也没用\n' > "$r2/.claude/install-owned"
run_scripted "install/接管清单写了不铺的路径要红" 1 "install.sh 根本不铺" -- bash "$pkg2/install.sh" "$r2"
rm -f "$r2/.claude/install-owned"

# 清单坏了必须**挡住**，不只是报一句。
# 上面两个样本里，就算不挡也照样退 1——因为同时还有内容落后，是那条路让它红的。
# 变异测试实测：把「清单坏了就 exit 1」整段删掉，那两个样本一起全绿。
# 所以要一个**没有别的落后**的场景：少了这道拦截，install.sh 会带着一份
# 读不准的清单把版本戳照刷不误（复核实测）。
pkg3="$tmpd/inst-own"; cp -a "$SCRIPTS/.." "$pkg3"
r3="$tmpd/inst-own-proj"; mkdir -p "$r3"
bash "$pkg3/install.sh" "$r3" >/dev/null 2>&1 || true
printf '9.9.9\n' > "$pkg3/VERSION"
mkdir -p "$r3/.claude"
printf '.claude/kb/decisions.md\n' > "$r3/.claude/install-owned"
run_scripted "install/清单坏了要挡住（此时没有别的落后）" 1 "接管清单有 1 处不合规" -- \
  bash "$pkg3/install.sh" "$r3"
cases=$((cases+1))
if [[ "$(cat "$r3/.singlefs-ai-sop-version")" != "9.9.9" ]]; then pass=$((pass+1))
  [[ -n "${SELFTEST_VERBOSE:-}" ]] && ok "install/清单坏了时版本戳确实没动"
else fails=$((fails+1)); bad "install/清单坏了，版本戳还是被刷成了 9.9.9"
  howto "接管清单读不准的时候不许放行——那等于把「内容落后就不刷戳」这道守卫悄悄关掉。"
fi

# 退役的包装：共享脚本不在这一版里了，项目里一字未改的包装要被点名、版本戳不刷；
# 项目自己改过的同名文件不归 install.sh 管，照常刷戳。退役的那份照现行包装的样子造：把 gate 包装里的脚本名换成 lkmm。
pkg4="$tmpd/inst-retired"; cp -a "$SCRIPTS/.." "$pkg4"
r4="$tmpd/inst-retired-proj"; mkdir -p "$r4"
bash "$pkg4/install.sh" "$r4" >/dev/null 2>&1 || true
sed 's#/scripts/gate\.sh"#/scripts/lkmm.sh"#' "$r4/.claude/scripts/gate.sh" > "$r4/.claude/scripts/lkmm.sh"
printf '9.9.9\n' > "$pkg4/VERSION"
run_scripted "install/一字未改的退役包装要点名" 1 "份包装这一版已经不铺了" ".claude/scripts/lkmm.sh" -- \
  bash "$pkg4/install.sh" "$r4"
cases=$((cases+1))
if [[ "$(cat "$r4/.singlefs-ai-sop-version")" != "9.9.9" ]]; then pass=$((pass+1))
  [[ -n "${SELFTEST_VERBOSE:-}" ]] && ok "install/留着退役包装时版本戳确实没动"
else fails=$((fails+1)); bad "install/留着退役包装，版本戳还是被刷成了 9.9.9"
  howto "退役包装还在时不许刷戳：戳说「新版」，项目里却留着一个转发到已删脚本的包装。"
fi
# 反面：项目照模板给一个还在的共享脚本自己加的包装，不是退役包装。
sed 's#/scripts/gate\.sh"#/scripts/bump.sh"#' "$r4/.claude/scripts/gate.sh" > "$r4/.claude/scripts/bump.sh"
# 这时 lkmm.sh 还在，install.sh 照样判红；要看的是点名的清单里没有 bump.sh。
run_scripted "install/照模板包一个还在的共享脚本不算退役" 0 "份包装这一版已经不铺了" "bump.sh 没被点名" -- \
  bash -c 'out="$(bash "$1/install.sh" "$2" 2>&1)"; printf "%s\n" "$out"
    [[ "$(printf "%s\n" "$out" | grep -c "scripts/bump.sh")" == 0 ]] && echo "bump.sh 没被点名"' _ "$pkg4" "$r4"
# 0.0.49 以前铺的三行包装同样要认：只认现行形态时，旧形态的退役包装一声不响、照常刷戳（审核实测）。
r4b="$tmpd/inst-retired-legacy"; mkdir -p "$r4b"
bash "$pkg4/install.sh" "$r4b" >/dev/null 2>&1 || true
printf '%s\n' '#!/usr/bin/env bash' \
  '# 包装：转发到共享脚本。逻辑不写在这里，写在 .claude/singlefs-ai-sop/scripts/。' \
  'exec bash "$(dirname "${BASH_SOURCE[0]}")/../singlefs-ai-sop/scripts/lkmm.sh" "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" "$@"' \
  > "$r4b/.claude/scripts/lkmm.sh"
run_scripted "install/0.0.49 以前形态的退役包装也要点名" 1 "份包装这一版已经不铺了" ".claude/scripts/lkmm.sh" -- \
  bash "$pkg4/install.sh" "$r4b"
printf '# 项目自己加的一行\n' >> "$r4/.claude/scripts/lkmm.sh"
run_scripted "install/改过的同名文件不归它管" 0 "版本戳  .singlefs-ai-sop-version = 9.9.9" -- \
  bash "$pkg4/install.sh" "$r4"

# 接管清单里登记了、项目又删掉了的那份，不许重铺：put 只管不覆盖已有的文件，删掉的那份 kb 骨架
# 下一次 install.sh 又会被铺回来（0.0.48 收尾时查出）。
pkg5="$tmpd/inst-owned-absent"; cp -a "$SCRIPTS/.." "$pkg5"
r5="$tmpd/inst-owned-absent-proj"; mkdir -p "$r5"
bash "$pkg5/install.sh" "$r5" >/dev/null 2>&1 || true
rm "$r5/.claude/kb/pitfalls.md"
printf '.claude/kb/pitfalls.md  # 踩过的坑记在项目自己的另一处，这份骨架删掉\n' > "$r5/.claude/install-owned"
run_scripted "install/接管清单里删掉的那份不重铺" 0 "已接管，项目删掉了它，不重铺" -- bash "$pkg5/install.sh" "$r5"
cases=$((cases+1))
if [[ ! -e "$r5/.claude/kb/pitfalls.md" ]]; then pass=$((pass+1))
  [[ -n "${SELFTEST_VERBOSE:-}" ]] && ok "install/删掉又登记接管的那份确实没被铺回来"
else fails=$((fails+1)); bad "install/删掉又登记接管的那份，被 install.sh 铺回来了"
  howto "put() 在目标不存在、路径又在 install-owned 里时要跳过，不许新建。"
fi

# ════ lib.sh 的环境守卫（此前零覆盖）═════════════════════
# 两道守卫都是「判定结果不许随环境变」的前提，坏了不会报错，只会悄悄改判。
head1 "门禁自检：环境守卫的判别力"

# LC_ALL：lib.sh 把 locale 钉成 UTF-8。摘掉之后，C locale 下 gawk 按字节走，
# doc-lint 的编号引用检查会把每处「D1（简称）」都误判成「括注没闭合」（复核实测）。
# 故意用 LC_ALL=C 跑一个该绿的样本：守卫在 → 绿；守卫没了 → 一片假红。
run_scripted "lib/LC_ALL 被钉住（C locale 下判定不变）" 0 检查通过 -- \
  env LC_ALL=C DOC_LINT_LANG=zh bash "$SCRIPTS/doc-lint.sh" "$FX/doc-lint/good"

# gawk：mawk 的 substr/length 按字节走，同一份 kb 会得出不同判定。
# 伪造一个自称 mawk 的 awk 摆在 PATH 最前面，门禁必须拒绝跑，而不是照跑。
fakeawk="$tmpd/fakeawk"; mkdir -p "$fakeawk"
printf '#!/bin/sh\n[ "$1" = --version ] && { echo "mawk 1.3.4 20200120"; exit 0; }\nexec /usr/bin/awk "$@"\n' \
  > "$fakeawk/awk"; chmod +x "$fakeawk/awk"
run_scripted "lib/不是 gawk 就拒绝跑" 1 需要 gawk -- \
  env PATH="$fakeawk:$PATH" bash "$SCRIPTS/doc-lint.sh" "$FX/doc-lint/good"

# die 的运行期兜底：gate-lint 在调用点静态拦裸 die，但它自己写明有几种形态
# 「认不出、不判」（消息是变量、引号被转义拆开）。那几种只剩这道运行期兜底，
# 而兜底本身此前没人盯——删掉它，`die "只有一句"` 的输出里就再没有出路（复核实测）。
run_scripted "lib/die 少了出路也要兜一句" 1 怎么办 -- \
  bash -c 'source "$1/lib.sh"; die "只有一句"' _ "$SCRIPTS"

# ════ manifest：CLAUDE.md 必须在清单里 ═══════════════════
# manifest.sh 专门写了一段解释它为什么在清单里（它是规范正文、还规定对话语言）。
# 复核实测：把它从 gen() 里摘掉，只改 CLAUDE.md 时清单照样「一致」。
head1 "门禁自检：manifest 覆盖面"
p="$tmpd/mani-claude/f-zh"; mkdir -p "$(dirname "$p")"; mk_pkg "$p" f
printf '改了规范正文\n' >> "$p/CLAUDE.md"
run_scripted "manifest/只改 CLAUDE.md 也要红" 1 不一致 -- bash "$p/scripts/manifest.sh"

# agents 层为空时必须显式说出来。空是状态不是通过——
# 「没有」和「忘了」在目录里长得一模一样（复核实测：这条 warn 此前无人盯）。
p="$tmpd/mani-emptyagents/f-zh"; mkdir -p "$(dirname "$p")"; mk_pkg "$p" f
rm -f "$p/agents/a.md"
bash "$p/scripts/manifest.sh" --update >/dev/null
run_scripted "manifest/agents 为空要说出来" 0 "本层已纳入治理，当前为空：agents/" -- bash "$p/scripts/manifest.sh"

# 覆盖率：面向人的文本两边都不沾就红。少了它，新加一份 .md 会静默留在共享区说中文。
p="$tmpd/mani-orphan/f-zh"; mkdir -p "$(dirname "$p")"; mk_pkg "$p" f
mkdir -p "$p/records"; printf '# 一份没人认领的文档\n' > "$p/records/x.md"
run_scripted "manifest/没归属的文本要红" 1 "既没进清单、也没显式豁免" -- bash "$p/scripts/manifest.sh"

# 反过来：显式豁免的那几份不许被这条检查误伤
p="$tmpd/mani-exempt/f-zh"; mkdir -p "$(dirname "$p")"; mk_pkg "$p" f
printf '# 门面\n' > "$p/README.md"; printf '# 历史\n' > "$p/CHANGELOG.md"
run_scripted "manifest/显式豁免的不算漏" 0 没有漏归属 -- bash "$p/scripts/manifest.sh"

# ════ push-all ═══════════════════════════════════════════
head1 "门禁自检：push-all 的判别力"
# 三个语言仓各带一个没推的提交，各配一个本地裸仓当远端；gate.sh 用桩，红绿由参数定。
# 走的是真实路径：在 zh 里 git push → pre-push 钩子 → push-all.sh → 推 ja、en → 放行 zh。
mk_push_family() { # mk_push_family <目录> [门禁判红的语言]
  local root="$1" red_language="${2:-}" language clone
  mkdir -p "$root"
  for language in zh en ja; do
    clone="$root/fam-$language"
    git init -q --bare -b master "$root/remote-$language.git"
    git init -q -b master "$clone"
    mkdir -p "$clone/scripts/githooks"
    cp "$SCRIPTS/push-all.sh" "$SCRIPTS/lib.sh" "$clone/scripts/"
    cp "$SCRIPTS/githooks/pre-push" "$clone/scripts/githooks/"
    if [[ "$language" == "$red_language" ]]; then
      printf '#!/usr/bin/env bash\necho "  桩门禁判红"\nexit 1\n' > "$clone/scripts/gate.sh"
    else
      printf '#!/usr/bin/env bash\nexit 0\n' > "$clone/scripts/gate.sh"
    fi
    printf 'family=fam\nthis=%s\nreference=zh\ndefault=en\nlanguages=zh ja en\n' "$language" > "$clone/I18N"
    echo 0.0.1 > "$clone/VERSION"
    git -C "$clone" add -A
    git -C "$clone" -c user.name=selftest -c user.email=selftest@invalid commit -qm 起点
    git -C "$clone" remote add origin "$root/remote-$language.git"
    git -C "$clone" push -q origin master
    echo 0.0.2 > "$clone/VERSION"
    git -C "$clone" -c user.name=selftest -c user.email=selftest@invalid commit -qam 待推
    git -C "$clone" config core.hooksPath scripts/githooks
  done
}
# 远端 master 与本地 HEAD 逐仓比：all = 三个都到了，none = 一个都没到。
# 写成独立的 bash 程序而不是函数：run_scripted 经 timeout 执行命令，timeout 看不见 shell 函数（退出码 127）。
remotes_state=(bash -c '
  root="$1" want="$2" matched=0
  for language in zh en ja; do
    [[ "$(git -C "$root/fam-$language" rev-parse HEAD)" == "$(git -C "$root/remote-$language.git" rev-parse master)" ]] \
      && matched=$((matched+1))
  done
  echo "远端对上本地的仓：$matched 个"
  if [[ "$want" == all ]]; then [[ $matched == 3 ]]; else [[ $matched == 0 ]]; fi' remotes_state)

r="$tmpd/push-green"; mk_push_family "$r"
run_scripted "push-all/三仓全绿：在 zh 里 git push 就三个一起推" 0 "放行 zh 这次推送" "ja：已推" "en：已推" -- \
  git -C "$r/fam-zh" push origin master
run_scripted "push-all/全绿之后三个远端都到了本地的提交" 0 "远端对上本地的仓：3 个" -- "${remotes_state[@]}" "$r" all

r="$tmpd/push-dirty"; mk_push_family "$r"; echo 没提交 > "$r/fam-en/stray"
run_scripted "push-all/有一个仓工作区不干净就一个都不推" 1 "en：工作区不干净" "一个仓都没推" -- \
  git -C "$r/fam-zh" push origin master
run_scripted "push-all/工作区不干净时三个远端都没动" 0 "远端对上本地的仓：0 个" -- "${remotes_state[@]}" "$r" none

r="$tmpd/push-version"; mk_push_family "$r"; echo 0.0.3 > "$r/fam-ja/VERSION"
git -C "$r/fam-ja" -c user.name=selftest -c user.email=selftest@invalid commit -qam 版本漂了
run_scripted "push-all/VERSION 不一致就拒" 1 "ja：VERSION 是 0.0.3，而 zh 是 0.0.2" -- \
  git -C "$r/fam-zh" push origin master

r="$tmpd/push-gate-red"; mk_push_family "$r" ja
run_scripted "push-all/任一仓门禁红就拒" 1 "ja：门禁没过" "桩门禁判红" -- \
  git -C "$r/fam-zh" push origin master
run_scripted "push-all/门禁红时三个远端都没动" 0 "远端对上本地的仓：0 个" -- "${remotes_state[@]}" "$r" none

# 在 git worktree 里推：git 给钩子的 GIT_DIR 是 zh 的绝对路径，它压过 `git -C`。
# push-all.sh 开头不清掉它的话，对 ja、en 的查验和推送都会落在 zh 上，这两个远端就到不了。
r="$tmpd/push-worktree"; mk_push_family "$r"
git -C "$r/fam-zh" switch -q -c parking
git -C "$r/fam-zh" worktree add -q "$r/worktree-zh" master
run_scripted "push-all/在 git worktree 里推也三个一起推" 0 "放行 zh 这次推送" "ja：已推" "en：已推" -- \
  git -C "$r/worktree-zh" push origin master
run_scripted "push-all/worktree 里推完三个远端都到了本地的提交" 0 "远端对上本地的仓：3 个" -- "${remotes_state[@]}" "$r" all

# 推到一半失败：en 的远端有一个本地没有的提交 ⇒ ja 已推、en 被拒、zh 不推，而且要报出已推的是哪些
r="$tmpd/push-partial"; mk_push_family "$r"
git clone -q "$r/remote-en.git" "$r/other-en"
echo 别处 > "$r/other-en/elsewhere"; git -C "$r/other-en" add elsewhere
git -C "$r/other-en" -c user.name=selftest -c user.email=selftest@invalid commit -qm 别处的提交
git -C "$r/other-en" push -q origin master
run_scripted "push-all/推到一半被拒要报出已推的仓" 1 "en：推送失败" "已经推上去的：ja" -- \
  git -C "$r/fam-zh" push origin master

# ── 汇总 ────────────────────────────────────────────────
say ""
[[ $cases -gt 0 ]] || { bad "一个用例都没跑"
  howto "样本目录空了。至少要有一个该绿的和一个该红的，否则这个自检本身什么也不证明。"; exit 1; }
[[ $fails -eq 0 ]] || { bad "门禁自检失败：$fails 个用例判错（共 $cases）"; exit 1; }   # gate-lint:summary
ok "门禁自检通过：$pass 个用例判定与预期一致（SELFTEST_VERBOSE=1 看逐条）"
