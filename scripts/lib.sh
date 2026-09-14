#!/usr/bin/env bash
# 公共函数。所有门禁脚本 source 它。
# 约定：任何"验证"函数都必须能返回非零。不许有只会成功的检查。

set -euo pipefail

# 字符数不许随 locale 变。C locale 下 awk 的 length() 按字节算，
# 「24 字」当场变成 8 个汉字，而失败信息还理直气壮报「72 字」。
for _loc in C.UTF-8 C.utf8 en_US.UTF-8; do
  if locale -a 2>/dev/null | grep -qix "$_loc"; then export LC_ALL="$_loc"; break; fi
done
unset _loc

if [[ -t 1 ]]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
  C_BLD=$'\033[1m'; C_RST=$'\033[0m'
else
  C_RED=''; C_GRN=''; C_YEL=''; C_BLD=''; C_RST=''
fi

say()   { printf '%s\n' "$*"; }
# awk 实现必须钉死。mawk 的 substr/length 按字节走，gawk 在 UTF-8 locale 下按字符走，
# 同一份 kb 会得出不同判定——「本地可跑且与远端同判」当场失效（rules/show-me-test.md）。
if ! awk --version 2>/dev/null | head -1 | grep -q GNU; then
  printf '%s  ✗%s 需要 gawk：当前 awk 不是 GNU awk\n' "${C_RED:-}" "${C_RST:-}" >&2
  printf '%s     → 怎么办：%s 装 gawk（Debian/Ubuntu: sudo apt install gawk），\n' "${C_YEL:-}" "${C_RST:-}" >&2
  printf '                或把 PATH 里的 awk 指到 gawk。判定结果不许随 awk 实现变。\n' >&2
  exit 1
fi

head1() { printf '\n%s══ %s ══%s\n' "$C_BLD" "$*" "$C_RST"; }
ok()    { printf '%s  ✓%s %s\n' "$C_GRN" "$C_RST" "$*"; }
bad()   { printf '%s  ✗%s %s\n' "$C_RED" "$C_RST" "$*"; }
warn()  { printf '%s  !%s %s\n' "$C_YEL" "$C_RST" "$*"; }

# 拒绝一个提交时，必须同时说清下一步做什么。
# 默认提交者是想通过的——拒绝而不给出路，等于让人靠猜，而靠猜的人会去绕过门禁。
# scripts/gate-lint.sh 强制：每个非汇总性的 bad 后面 4 行内必须有 howto。
howto() { printf '%s     → 怎么办：%s %s\n' "$C_YEL" "$C_RST" "$1"; shift
          for l in "$@"; do printf '                %s\n' "$l"; done; }

# 直接终止的拒绝。**第一个参数是消息，第二个起是出路**——
# die 也是拒绝，同样不许只说「不合格」（rules/sop-first.md）。
# 少了出路时这里兜一句，静态那半由 scripts/gate-lint.sh 拦（它检查调用点的参数个数）。
die()   { bad "$1"; shift
          if [[ $# -gt 0 ]]; then howto "$@"
          else howto "这条拒绝没写出路，是本仓自己的缺陷。请给这处 die 补上第二个参数。"; fi
          exit 1; }

# ── 「命令位置」的唯一定义 ──────────────────────────────
# gate-lint 与 shell-lint 都要判「这个记号是被执行了，还是只是出现在字符串里」。
# 各写一份的结果：shell-lint 的那份含 `(){}`，gate-lint 的那份没有，于是
# `( bad "不合格" )` 与 `eval bad "..."` 两种形态整体漏检（对抗测试实测）。
# 同一个事实只许有一处权威记录（rules/kb-discipline.md 第 4 条）——就是这里。
CMD_POS='(^[[:space:]]*|[;&|(){}`!][[:space:]]*|(then|else|do|if|while|until|sudo|env|xargs|exec|eval|command|time)[[:space:]]+)'

# 找到项目根：向上找到含 .singlefs-ai-sop-version 或 .git 的目录
# （.git 可以是文件：git worktree 里它是一个指路的文件，gate.sh --staged 的临时树就是这种。）
# 找不到要说出来：调用方都写成 ROOT="${1:-$(project_root)}"，在 set -e 下这里静默返回 1，
# 门禁就一句话都没有地退出了。说明写到 stderr，stdout 只留路径——调用方是拿 $(…) 接的。
project_root() {
  local d="${1:-$PWD}"
  while [[ "$d" != "/" ]]; do
    [[ -f "$d/.singlefs-ai-sop-version" || -e "$d/.git" ]] && { printf '%s' "$d"; return 0; }
    d="$(dirname "$d")"
  done
  { bad "从 ${1:-$PWD} 往上找不到项目根（含 .singlefs-ai-sop-version 或 .git 的目录）"
    howto "在项目目录里跑，或者把项目根作为第一个参数传进来。"; } >&2
  return 1
}

# 本包自身的根
pkg_root() { cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd; }

# 确定 diff 基准。优先 $GATE_BASE，否则与默认分支的 merge-base，
# 都没有就用 HEAD（即只看工作区改动）。
diff_base() {
  local root="$1"
  if [[ -n "${GATE_BASE:-}" ]]; then printf '%s' "$GATE_BASE"; return 0; fi
  local def
  for def in master main; do
    if git -C "$root" rev-parse --verify -q "$def" >/dev/null; then
      local mb
      if mb="$(git -C "$root" merge-base HEAD "$def" 2>/dev/null)" && [[ -n "$mb" ]]; then
        # 在默认分支上时 merge-base 等于 HEAD，得往回退。
        #
        # 退一格（HEAD~1）不够：**分两次提交就绕过去了**——第一次改代码不带测试，
        # 第二次只改文档，跑门禁时基准是第一次，于是「本次无 crates 改动」，绿灯
        # （对抗测试实测，gate 退出码 0）。判据比规则弱一档：规则说「改了代码要带
        # 测试」，检查却只问「最近一个 commit 里有没有」。
        #
        # 所以退到**已经推出去的那个点**：本地还没推的提交全部纳入判定，
        # 攒多少次都躲不掉。没有远端跟踪分支时才退回 HEAD~1。
        if [[ "$mb" == "$(git -C "$root" rev-parse HEAD 2>/dev/null)" ]]; then
          local up p1
          # 优先级：上游 > 门禁上次通过的位置 > HEAD~1。
          # 前两个都是「已经过闸的地方」，此后的所有提交一并纳入判定。
          if up="$(git -C "$root" rev-parse -q --verify "@{upstream}" 2>/dev/null)" \
             && [[ -n "$up" && "$up" != "$(git -C "$root" rev-parse HEAD)" ]]; then
            printf '%s' "$up"; return 0
          fi
          local ok
          if ok="$(git -C "$root" rev-parse -q --verify refs/singlefs/gate-ok 2>/dev/null)" \
             && [[ -n "$ok" && "$ok" != "$(git -C "$root" rev-parse HEAD)" ]] \
             && git -C "$root" merge-base --is-ancestor "$ok" HEAD 2>/dev/null; then
            printf '%s' "$ok"; return 0
          fi
          if p1="$(git -C "$root" rev-parse -q --verify HEAD~1 2>/dev/null)"; then
            printf '%s' "$p1"; return 0
          fi
        fi
        printf '%s' "$mb"; return 0
      fi
    fi
  done
  printf 'HEAD'
}

# 列出相对基准变更的文件（含工作区未提交改动）
changed_files() {
  local root="$1" base="$2"
  # 空仓（还没有任何 commit）时 HEAD 不存在，diff 会失败——只看未跟踪文件
  if ! git -C "$root" rev-parse --verify -q "$base^{commit}" >/dev/null 2>&1; then
    git -C "$root" ls-files --others --exclude-standard | sort -u | grep -v '^$' || true
    return 0
  fi
  { git -C "$root" diff --name-only "$base" -- ;
    git -C "$root" diff --name-only --cached -- ;
    git -C "$root" ls-files --others --exclude-standard ; } | sort -u | grep -v '^$' || true
}

# 变更中新增的行（用于检查是否新增了测试）
added_lines() {
  local root="$1" base="$2"
  git -C "$root" rev-parse --verify -q "$base^{commit}" >/dev/null 2>&1 || { git -C "$root" diff -U0 --cached -- 2>/dev/null | grep '^+' | grep -v '^+++' || true; return 0; }
  { git -C "$root" diff -U0 "$base" -- ;
    git -C "$root" diff -U0 --cached -- ; } 2>/dev/null \
    | grep '^+' | grep -v '^+++' || true
}
