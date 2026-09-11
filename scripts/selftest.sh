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
# 现在只剩 5 个门禁察觉不到，逐个验过都是等价的：
#   - lkmm 两段静态检查中途的 `exit 1` 删掉——最终汇总仍按 fails>0 判红，退出码不变
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
# 删光、kb 历史节检查删光、gate-lint 的窗口从 5 改成 99、lkmm 的两条静态检查删光、
# show-me-test 的标注集缩到只认 #[test]——**每一条都全绿**。
# 根因是 blind 样本一次触发六类违规，而它的 want 写成了「正文不许」，
# 上下文指代那条消息也含这四个字。所以：一个样本触发多类违规时，
# 每一类都要有自己的 want；宁可多写几个单一职责的样本。
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FX="$SCRIPTS/fixtures"
tmpd="$(mktemp -d)"; trap 'rm -rf "$tmpd"' EXIT

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
  set +e; timeout "${SELFTEST_TIMEOUT:-60}" "$@" > "$out" 2>&1; rc=$?; set -e
  [[ $rc == 124 ]] && say "        （超时 ${SELFTEST_TIMEOUT:-60}s，按判错记）"
  judge "$label" "$wexit" "$rc" "$out" ${wants[@]+"${wants[@]}"}
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
  set +e; timeout "${SELFTEST_TIMEOUT:-60}" "$@" > "$out" 2>&1; rc=$?; set -e
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
  run_fixture "doc-lint/$(basename "$d")" "$d" env DOC_LINT_LANG=zh bash "$SCRIPTS/doc-lint.sh" "$d"
done

# 上面那个口子必须自报。少了那句 warn，谁都能拿 DOC_LINT_LANG 换掉判据而不留痕迹——
# 而换判据正是这套门禁最该拦住的一件事（rules/show-me-test.md：门禁不许假装通过）。
run_scripted "doc-lint/语言被覆盖时要自报" 0 "语言由 DOC_LINT_LANG 指定为" -- \
  env DOC_LINT_LANG=zh bash "$SCRIPTS/doc-lint.sh" "$FX/doc-lint/good"

# ════ gate-lint ══════════════════════════════════════════
head1 "门禁自检：gate-lint 的判别力"
for d in "$FX"/gate-lint/*/; do
  [[ -d "$d" ]] || continue
  run_fixture "gate-lint/$(basename "$d")" "$d" \
    env GATE_LINT_DIR="$d" bash "$SCRIPTS/gate-lint.sh"
done

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

# ════ lkmm（静态检查与对照组；herd7 不在场也判得了这两层）══
head1 "门禁自检：lkmm 静态检查的判别力"
for d in "$FX"/lkmm/*/; do
  [[ -d "$d" ]] || continue
  run_fixture "lkmm/$(basename "$d")" "$d" bash "$SCRIPTS/lkmm.sh" "$d"
done

# ════ shell-lint ═════════════════════════════════════════
head1 "门禁自检：shell-lint 的判别力"
for d in "$FX"/shell-lint/*/; do
  [[ -d "$d" ]] || continue
  run_fixture "shell-lint/$(basename "$d")" "$d" \
    env SHELL_LINT_DIR="$d" bash "$SCRIPTS/shell-lint.sh"
done

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

r="$tmpd/smt-nothing"; mk_repo "$r"
run_scripted "show-me-test/无对象可判" 3 无对象可判 -- bash "$SCRIPTS/show-me-test.sh" "$r"

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
  mkdir -p "$d/scripts/qemu" "$d/rules"
  cp "$SCRIPTS/lib.sh" "$SCRIPTS/gate.sh" "$d/scripts/"
  printf '0.0.0\n' > "$d/VERSION"
  printf 'family=f\nthis=zh\nreference=zh\ndefault=zh\nlanguages=zh\n' > "$d/I18N"
  printf '# 规则甲\n' > "$d/rules/a.md"
  local n
  for n in gate-lint selftest shell-lint doc-lint naming-lint show-me-test check manifest i18n-sync version-discipline changelog-lint lkmm; do
    if [[ "$n" == "$failing" ]]; then
      printf '#!/usr/bin/env bash\necho "  桩 %s 判红"\nexit 1\n' "$n" > "$d/scripts/$n.sh"
    else
      printf '#!/usr/bin/env bash\nexit 0\n' > "$d/scripts/$n.sh"
    fi
  done
  printf '#!/usr/bin/env bash\nexit 0\n' > "$d/scripts/qemu/run.sh"
}

# 全绿：退出码 0，且每个阶段名都要出现在汇总里
# —— 这几个 want 钉住的是「阶段没被人悄悄从 gate.sh 里删掉」
r="$tmpd/gate-green"; mk_gate_pkg "$r"
run_scripted "gate/全绿则退出码 0" 0 \
  "已实现的门禁阶段全部通过" 门禁自检 门禁判别力 "shell 纪律" 文档铁律 命名纪律 "Show me test" \
  规则清单 各语言同步 版本纪律 "CHANGELOG 连续" LKMM \
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

# ════ changelog-lint ═════════════════════════════════════
head1 "门禁自检：changelog-lint 的判别力"
[[ -d "$FX/changelog-lint" ]] || { bad "缺样本目录 $FX/changelog-lint"
  howto "样本要随仓走。没有样本，下一个改 changelog-lint.sh 的人无从复跑。"; exit 1; }
for d in "$FX"/changelog-lint/*/; do
  run_fixture "changelog-lint/$(basename "$d")" "$d" bash "$SCRIPTS/changelog-lint.sh" "$d"
done

# ════ naming-lint ════════════════════════════════════════
head1 "门禁自检：naming-lint 的判别力"
[[ -d "$FX/naming-lint" ]] || { bad "缺样本目录 $FX/naming-lint"
  howto "样本要随仓走。没有样本，下一个改 naming-lint.sh 的人无从复跑。"; exit 1; }
for d in "$FX"/naming-lint/*/; do
  run_fixture "naming-lint/$(basename "$d")" "$d" bash "$SCRIPTS/naming-lint.sh" "$d"
done

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
  # 手写的话，标记会一律拍在第 1 行，把 SKILL.md 的 frontmatter 与 litmus 头压掉——
  # 那正是被检查拦下的形态（第一版这么写，当场被自己的检查判红）。
  local path
  while read -r _h path; do
    mkdir -p "$sib/$(dirname "$path")"; cp "$ref/$path" "$sib/$path"
  done < "$ref/MANIFEST.sha256"
  git -C "$sib" init -q          # --stamp 只往 git 仓里写
  bash "$ref/scripts/i18n-sync.sh" --stamp en \
    $(sed 's/^[0-9a-f]*  //' "$ref/MANIFEST.sha256") >/dev/null
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
  printf 'C sample\n\n(* singlefs-expect: Never *)\n\n{}\n' > "$1/templates/x.litmus"
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
bash "$b/f-zh/scripts/i18n-sync.sh" --stamp en rules/a.md >/dev/null
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

# 溯源标记不许压住文件本身的头。两类各一条，都是实测过的坑：
# SKILL.md 的 frontmatter 被顶下去 → skill 安静地装不上；
# .litmus 的第 1 行被顶下去 → herd7 报 splitter error（跑 herd7 实测）。
b="$tmpd/i18n-headfm"; mk_pair "$b"
sed -i '1i <!-- generated-from: skills/s/SKILL.md sha256:0000000000000000000000000000000000000000000000000000000000000000 -->' \
  "$b/f-en/skills/s/SKILL.md"
run_scripted "i18n-sync/标记压住 frontmatter" 1 "篇的第 1 行被压住了" -- bash "$b/f-zh/scripts/i18n-sync.sh" "$b"

b="$tmpd/i18n-headlit"; mk_pair "$b"
sed -i '1i (* generated-from: templates/x.litmus sha256:0000000000000000000000000000000000000000000000000000000000000000 *)' \
  "$b/f-en/templates/x.litmus"
run_scripted "i18n-sync/标记压住 litmus 头" 1 "篇的第 1 行被压住了" -- bash "$b/f-zh/scripts/i18n-sync.sh" "$b"

# 溯源标记的三种坏法，各自有自己的消息——共用一条 want 就盖住了别的
# litmus 的溯源标记必须用 litmus 注释：位置对而形式错时，读回来照样解析得了
# （stamp_read 两种包裹都认），只有真跑 herd7 才会露——所以要单独查。
# agents 定义与 SKILL.md 同律。此前 case 分支写成 */agents/*.md，而清单里的路径是
# 仓根相对的 agents/x.md，前面没有那一段——整条 agents 路径一次也没被检查过（复核实测）。
b="$tmpd/i18n-agentfm"; mk_pair "$b"
sed -i '1i <!-- generated-from: agents/a.md sha256:0000000000000000000000000000000000000000000000000000000000000000 -->' \
  "$b/f-en/agents/a.md"
run_scripted "i18n-sync/标记压住 agent 的 frontmatter" 1 "篇的第 1 行被压住了" -- \
  bash "$b/f-zh/scripts/i18n-sync.sh" "$b"

b="$tmpd/i18n-litwrap"; mk_pair "$b"
sed -i '2s|.*|<!-- generated-from: templates/x.litmus sha256:0000000000000000000000000000000000000000000000000000000000000000 -->|' \
  "$b/f-en/templates/x.litmus"
run_scripted "i18n-sync/litmus 用了 HTML 注释" 1 "litmus 里用了 HTML 注释包裹溯源标记" -- \
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
sed -i '2i (* generated-from: templates/litmus/commit-publish.litmus sha256:0000000000000000000000000000000000000000000000000000000000000000 *)' \
  "$pkg/templates/litmus/commit-publish.litmus"
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
