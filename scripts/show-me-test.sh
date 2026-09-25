#!/usr/bin/env bash
# admission: always 判的是这一次 diff 窗口里的改动，窗口随提交在动
# run-condition: command git
# Show me test 阶段：改了 crates 代码就必须带测试（rules/show-me-test.md）。
# 从 gate.sh 里拆出来，selftest 才能拿样本仓单独喂它（rules/sop-first.md：
# 没有自检能力的门禁是摆设）。
#
#   show-me-test.sh <项目根>
#
# 退出码：0 = 通过；1 = 拒收；3 = 无对象可判（gate.sh 记 NOT_RUN，不算通过）。
#
# 判据里的三个「不算数」，都是对抗测试实测过的绕法：
#   1. 注释行里的 #[test] 不算测试标注（一行 `// #[test]` 曾经就能过）
#   2. tests/ 下只有非代码文件不算测试改动（`echo x > tests/note.txt` 曾经就能过）
#   3. build.rs 也是代码：编译期执行，改它同样要带测试
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight "${BASH_SOURCE[0]}" "$@"; set -- ${PREFLIGHT_ARGUMENTS[@]+"${PREFLIGHT_ARGUMENTS[@]}"}

ROOT="${1:-$(project_root)}"
[[ -d "$ROOT" ]] || die "找不到项目根：$ROOT" \
  "把项目根作为第一个参数传进来： bash scripts/show-me-test.sh <项目根>"

BASE="$(diff_base "$ROOT")"
say "  diff 基准：$BASE"
files="$(changed_files "$ROOT" "$BASE")"

if [[ -z "$files" ]]; then
  # 无变更既不是通过也不是失败——没有可判的对象。判成失败会让「刚装完就有一格红」
  # 成为常态，而红色一旦成为常态就不再是信号，人会开始习惯性忽略它。
  warn "工作区与基准无差异 —— 本阶段无对象可判（这不是通过）"
  exit 3
fi

code_changed="$(printf '%s\n' "$files" | grep -E '^crates/.*/(src/.*\.rs|build\.rs)$' || true)"
test_files="$(printf '%s\n' "$files" | grep -E '(^|/)(tests|benches|fuzz)/.*\.rs$' || true)"
TEST_RE='#\[test\]|#\[cfg\(test\)\]|proptest!|#\[kani|#\[tokio::test\]'
# 注释里的标注不算数：整行注释、块注释行、以及**行尾注释**（`code // #[test]`
# 这种走私对抗测试实测过）。先剁掉 // 到行尾，再滤块注释行，剩下的才配匹配。
strip_comments() { sed -E 's@//.*@@' | grep -vE '^\+?[[:space:]]*(/\*|\*)' || true; }
# ⚠️ 只在 **.rs 文件的新增行**里找测试标注。
# 不按路径过滤的话，`#[test]` 出现在任何被加的行里都算数——在 CLAUDE.md 里写一句
# 「提交模板：新增测试请写 #[test]」就能让改代码不带测试的提交过闸
# （对抗测试实测，gate 退出码 0）。同理 Rust 字符串字面量里的也不算。
added_rs_lines() {
  local root="$1" base="$2" f
  while IFS= read -r f; do
    [[ "$f" == *.rs ]] || continue
    git -C "$root" diff -U0 "$base" -- "$f" 2>/dev/null | grep '^+' | grep -v '^+++' || true
    git -C "$root" diff -U0 --cached -- "$f" 2>/dev/null | grep '^+' | grep -v '^+++' || true
  done < <(printf '%s\n' "$files")
}
strip_strings() { sed -E 's/"([^"\\]|\\.)*"//g'; }
test_lines="$(added_rs_lines "$ROOT" "$BASE" | strip_comments | strip_strings | grep -E "$TEST_RE" || true)"
# 新建的未跟踪文件在 diff 里看不见，内联测试会被漏掉——直接扫文件内容。
# 对刚起步的项目，新文件是常态，漏掉等于这条门禁形同虚设。
untracked_tests=""
while IFS= read -r uf; do
  [[ -f "$ROOT/$uf" ]] || continue
  # 只认真的会被编译的位置：仓库根丢一个 scratch.rs 不算带了测试（对抗测试实测）
  case "$uf" in crates/*/src/*|crates/*/tests/*|crates/*/benches/*|tests/*|benches/*|fuzz/*) ;; *) continue ;; esac
  # 不用 `| grep -q`：grep 找到就退出，上游拿 SIGPIPE，pipefail 下整条管道退 141、条件当假——
  # 文件大过管道缓冲（64 KiB）时，带测试的新文件会被判成没带测试（审计实测：108 KB 的新文件判拒收）。
  if [[ "$(strip_comments < "$ROOT/$uf" | strip_strings | grep -cE "$TEST_RE" || true)" != 0 ]]; then untracked_tests+="$uf"$'\n'; fi
done < <(git -C "$ROOT" ls-files --others --exclude-standard -- '*.rs' 2>/dev/null || true)
test_lines="$test_lines$untracked_tests"
# tests/ 下改了 .rs 还不够，得真的含测试标注——`echo '// 空壳' > tests/t.rs`
# 这种占位文件对抗测试实测过。内容级证据：改动的测试文件里至少一个匹配 TEST_RE。
tests_content_ok=""
while IFS= read -r tf; do
  [[ -n "$tf" && -f "$ROOT/$tf" ]] || continue
  if [[ "$(strip_comments < "$ROOT/$tf" | grep -cE "$TEST_RE" || true)" != 0 ]]; then tests_content_ok=1; break; fi   # grep -q 在管道末端会让上游拿 SIGPIPE，见上
done <<< "$test_files"

if [[ -z "$code_changed" ]]; then
  ok "无 crates 代码改动（仅文档/脚本），本阶段不适用"
  exit 0
elif [[ -n "$tests_content_ok" || -n "$test_lines" ]]; then
  ok "代码改动伴随测试改动（改了 $(printf '%s\n' "$code_changed" | grep -c .) 个代码文件）"
  [[ -n "$test_files" ]] && printf '%s\n' "$test_files" | sed 's/^/        测试文件: /'
  [[ -n "$test_lines" ]] && say "        新增测试标注 $(printf '%s\n' "$test_lines" | grep -c .) 处"
  warn "脚本只能验证「有测试」，验证不了「测试会红」——"
  warn "  按 rules/show-me-test.md，请在 commit message 写明你是怎么确认它会红的"
  exit 0
else
  bad "改了 crates 代码但没有任何测试改动，按 rules/show-me-test.md 拒收："
  printf '%s\n' "$code_changed" | sed 's/^/        /'
  howto "给这次改动补测试。不确定怎么测的话，按改动类型对号入座：" \
    "纯函数 / 数据结构   → 同文件里加 #[cfg(test)] mod tests，最省事" \
    "涉及磁盘格式        → 先在 kb/invariants.md 加一条不变量，再让 checker 实现它" \
    "涉及崩溃恢复        → 见 crash-test skill；这条还没有 harness，说明情况即可" \
    "" \
    "写完把被测代码改坏一次，确认测试真的变红，再改回来——" \
    "并在 commit message 里写明你是怎么确认的。" \
    "注释里的 #[test] 不算数；tests/ 下的文件也要真的含 #[test] 等标注才算。"
  exit 1
fi
