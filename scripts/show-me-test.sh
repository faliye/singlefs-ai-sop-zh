#!/usr/bin/env bash
# admission: always 判的是这一次 diff 窗口里的改动，窗口随提交在动
# run-condition: command git
# Show me test 阶段：改了 crates 代码就必须带测试（rules/show-me-test.md）。
#
#   show-me-test.sh <项目根>
#
# 退出码：0 = 通过；1 = 拒收，或判不了（改动清单取不全）；3 = 无对象可判（工作区与基准无差异，或差异里没有 crates 代码），
#   gate.sh 记 NOT_RUN，不算通过。
#
# 下面各处「不算数」都是对抗测试实测过的绕法，逐条写在代码旁。build.rs 编译期执行，算代码。
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight "${BASH_SOURCE[0]}" "$@"; set -- ${PREFLIGHT_ARGUMENTS[@]+"${PREFLIGHT_ARGUMENTS[@]}"}

ROOT="${1:-$(project_root)}"
[[ -d "$ROOT" ]] || die "找不到项目根：$ROOT" \
  "把项目根作为第一个参数传进来： bash scripts/show-me-test.sh <项目根>"

BASE="$(diff_base "$ROOT")"
say "  diff 基准：$BASE"
files="$(changed_files "$ROOT" "$BASE")" || die "取不到相对基准 $BASE 的改动清单（git diff / ls-files 失败，原话在上面）" \
  "先在 $ROOT 跑 git status 与 git diff --name-only $BASE 看 git 报什么，修好再跑。" \
  "清单少一截时，这一条会把改了代码判成「无对象可判」，所以取不全就不判。"

if [[ -z "$files" ]]; then
  # 无变更不判失败：否则「刚装完就有一格红」成了常态，红就不再是信号。
  warn "工作区与基准无差异 —— 本阶段无对象可判（这不是通过）"
  exit 3
fi

code_changed="$(printf '%s\n' "$files" | grep -E '^crates/.*/(src/.*\.rs|build\.rs)$' || true)"
test_files="$(printf '%s\n' "$files" | grep -E '(^|/)(tests|benches|fuzz)/.*\.rs$' || true)"
TEST_RE='#\[test\]|#\[cfg\(test\)\]|proptest!|#\[kani|#\[tokio::test\]'
# 注释里的标注不算数：整行注释、块注释行、行尾注释（`code // #[test]`）。
strip_comments() { sed -E 's@//.*@@' | grep -vE '^\+?[[:space:]]*(/\*|\*)' || true; }
# 只在 .rs 文件的新增行里找：不按路径过滤的话，文档里一句「新增测试请写 #[test]」就能让不带测试的改动过闸。
# Rust 字符串字面量里的也不算。
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
# 新建的未跟踪文件 diff 里看不见，直接扫文件内容。
untracked_tests=""
while IFS= read -r uf; do
  [[ -f "$ROOT/$uf" ]] || continue
  # 只认会被编译的位置：仓库根丢一个 scratch.rs 不算带了测试
  case "$uf" in crates/*/src/*|crates/*/tests/*|crates/*/benches/*|tests/*|benches/*|fuzz/*) ;; *) continue ;; esac
  # 不用 `| grep -q`：找到就退出让上游拿 SIGPIPE，pipefail 下条件当假，
  # 大过管道缓冲（64 KiB）的带测试新文件被判成没带测试（实测 108 KB 的判拒收）。
  if [[ "$(strip_comments < "$ROOT/$uf" | strip_strings | grep -cE "$TEST_RE" || true)" != 0 ]]; then untracked_tests+="$uf"$'\n'; fi
done < <(git -C "$ROOT" ls-files --others --exclude-standard -- '*.rs' 2>/dev/null || true)
test_lines="$test_lines$untracked_tests"
# tests/ 下改了 .rs 还不够，改动的测试文件里至少一个要真含测试标注：`// 空壳` 占位文件不算。
tests_content_ok=""
while IFS= read -r tf; do
  [[ -n "$tf" && -f "$ROOT/$tf" ]] || continue
  if [[ "$(strip_comments < "$ROOT/$tf" | grep -cE "$TEST_RE" || true)" != 0 ]]; then tests_content_ok=1; break; fi   # grep -q 在管道末端会让上游拿 SIGPIPE，见上
done <<< "$test_files"

if [[ -z "$code_changed" ]]; then
  # 与「无差异」同一个口径：有差异但一行 crates 代码都没改，同样没有要判的对象，记本次未跑、不记通过
  warn "改动里没有 crates 代码（查了 $(printf '%s\n' "$files" | grep -c .) 个改动的文件，只有文档 / 脚本）—— 本阶段无对象可判（这不是通过）"
  exit 3
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
    "涉及磁盘格式        → 先在 kb/invariants.md 加一条不变量，再加一个检查实现它" \
    "涉及崩溃恢复        → 用项目自己的验证手段（登记在 .claude/gate-not-implemented.tsv 的那几项）验，说明怎么验的" \
    "" \
    "写完把被测代码改坏一次，确认测试真的变红，再改回来——" \
    "并在 commit message 里写明你是怎么确认的。" \
    "注释里的 #[test] 不算数；tests/ 下的文件也要真的含 #[test] 等标注才算。"
  exit 1
fi
