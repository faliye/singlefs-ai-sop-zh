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

# ── 「按模式找进程」的唯一定义 ────────────────────────────
# shell-lint（S2、S3，判脚本）与 claude-hooks/pattern-process-guard.sh（判会话里手敲的命令）共用，
# 判据只在这里写一份；两边各写一份，迟早一边改了另一边没跟（rules/kb-discipline.md 第 4 条）。
# 为什么禁用、换成什么写法，见 rules/command-safety.md 那一节。
#
# 命令名认任意路径前缀（/usr/bin/pkill 也是 pkill）；选项不按拼写枚举，
# 认「有没有全模式匹配那一位」：-f / --full / 合并写法 -af。
# 写死 `-f` 的时候，`pkill --full X`、`pkill -af X`、`/usr/bin/killall X`
# 六种写法整体漏检（对抗测试实测）——它们是同一条命令的另一种拼法。
COMMAND_PATH_PREFIX_RE='([A-Za-z0-9_/.-]*/)?'
# S2：pkill 带全模式匹配，或 killall。
PATTERN_KILL_RE="$CMD_POS$COMMAND_PATH_PREFIX_RE"'(pkill([[:space:]]+-[[:alnum:]-]*)*[[:space:]]+(-[[:alnum:]]*f[[:alnum:]]*|--full)|killall)([[:space:]]|$)'
# S3：pgrep -f 单列一条。此前命中后还要同一行有 xargs / kill / if / while / until 才红：
# `pids=$(pgrep -f X)` 下一行 `kill $pids`、`while` 与 `pgrep -f` 分两行写，都全绿；
# 反过来 `pgrep -f notify` 因为含子串 if 被判成等待循环（审计实测）。所以命令位置上出现就红。
PATTERN_PGREP_RE="$CMD_POS$COMMAND_PATH_PREFIX_RE"'pgrep([[:space:]]+-[[:alnum:]-]*)*[[:space:]]+(-[[:alnum:]]*f[[:alnum:]]*|--full)'

# ── 「这一行开了一个 heredoc」的唯一定义 ────────────────
# gate-lint 与 shell-lint 都要跳过 heredoc 体（里面是数据，不是代码）。两边此前各写一份
# `<<-?[[:space:]]*['"]?(名字)`，把三种**不是** heredoc 的写法也当成了开头：
#   `n="$(grep -c x <<< abc)"`、注释里的 `# 用法：python3 - <<PY`、`$((1<<SHIFT))`
# 一旦误判，从那行起整个文件都被当成 heredoc 体不再检查——越大的脚本越容易中，而且一声不响
# （审计实测：三种写法各放一行，裸 die 与 S1 的违规全部漏判）。
# 所以：`<<` 前面不许是 `<`（排掉 `<<<`），定界符后面必须是空白、引号或行尾（排掉 `1<<SHIFT))`），
# 注释行由调用方在判之前跳过（这一条写不进正则）。定界符是第 2 个捕获组。
HEREDOC_RE="(^|[^<])<<-?[[:space:]]*['\"]?([A-Za-z_][A-Za-z0-9_]*)(['\"[:space:]]|\$)"

# ── 日期能不能是真的：唯一定义 ──────────────────────────
# 编出来的日期看不出是编的，除非它落在不可能的区间里。两端都可机检：
# 比这个仓第一个提交早一个月以上、或者比今天还晚，都不可能是真发生过的事。
# 实测：三份样本和一处 skill 示例里写着 2026-01-01，比这个仓的第一个提交早了大半年，而门禁一直是绿的。
# 这个包自己的起点：`git log --reverse` 现查，本仓第一个提交是这一天。
# 样本、模板、规则里的日期说的都是这个包的事，下界就用它，不随包被拷到哪里而变。
SOP_START_DATE=2026-08-26

# 被检查的那个项目自己的起点。**只在 <目录> 本身就是 git 仓的顶层时**才问 git：
# 不这么限的话，`git -C` 会一路往上找——SOP 副本放在项目的 .claude/ 下，找到的是项目的历史，
# 拿项目的第一个提交去判这个包的样本日期，量的就不是同一件事。
# 也不拿 CHANGELOG 最早那一节兜底：它从 0.0.22 才开始逐节记，比真起点晚一周，
# 拿它当下界会把 2026-08-29 这类真日期判成不可能（实测）。拿不到就返回空，由调用方决定退到哪。
project_start_date() { # project_start_date <目录> → YYYY-MM-DD 或空
  local dir toplevel
  dir="$(cd "$1" 2>/dev/null && pwd -P)" || return 0
  toplevel="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || true)"
  [[ -n "$toplevel" && "$(cd "$toplevel" && pwd -P)" == "$dir" ]] || return 0
  # 浅克隆里「第一个提交」是截断处，不是项目的起点：拿它当下界，项目越老误判越多（审核实测）。这时也返回空。
  [[ "$(git -C "$dir" rev-parse --is-shallow-repository 2>/dev/null || true)" != true ]] || return 0
  git -C "$dir" log --reverse --format=%ad --date=short 2>/dev/null | head -1 || true
}
# 下界从第一个提交往前放宽 DATE_GRACE_DAYS 天：git init 之前做的工作，会带着当时的日期进第一个提交。
# 实测：singlefs 的第一个提交在 2026-08-26，那次提交里就有 5 条 2026-08-25 的历史条目，按第一个提交卡死全被判成不可能。
# 实测只早一天，放宽一周；宽得越多，放过的编造日期越多。2026-01-01 这种早了大半年的照样拦得住。
DATE_GRACE_DAYS=7
date_lower_bound() { # date_lower_bound <起点 YYYY-MM-DD 或空> → 下界或空
  [[ -n "${1:-}" ]] || return 0
  date -d "$1 - $DATE_GRACE_DAYS days" +%F
}
# 下界要做日期减法，靠 GNU date 的 -d。不认 -d 的 date（busybox、BSD）算不出下界，
# 而 date_out_of_range 是在 if 条件里调的，set -e 不管：下界静默变空，2026-01-01 照样放行（审核实测）。
# 所以查日期的脚本开头先试一次，不行就停。
require_date_arithmetic() {
  [[ "$(date -d '2026-01-02 - 1 day' +%F 2>/dev/null || true)" == 2026-01-01 ]] || die "这台机器的 date 不认 -d，算不出日期下界" \
    "日期检查要 GNU date（coreutils）：装上它，或把它放到 PATH 前面，再重跑。env.sh 也查这一项。"
}
# 「今天」按地球上最晚的那个时区（UTC+14）算：比它还晚的日期，在哪儿都还没到。
# 只取本机时钟的日期不行：本机时钟是 UTC、人在东京时，东京 00:00–09:00 写下的当天日期比 UTC 的今天晚一天，
# 会被判成「晚于今天」（审核实测：singlefs 的 194 个提交里有 8 个在这个时段按东京日期写了历史条目）。
# 用 POSIX 写法 UTC-14（符号与直觉相反，表示 UTC+14），不依赖系统装没装时区数据。
latest_today() { TZ=UTC-14 date +%F; }
# 在范围内时不输出、返回 1；不在范围内时打印「为什么不可能」、返回 0。
date_out_of_range() { # date_out_of_range <YYYY-MM-DD> [项目起点]
  local checked_date="$1" start_date="${2:-}" today lower_bound
  today="$(latest_today)"
  if [[ "$checked_date" > "$today" ]]; then printf '晚于今天（%s，按最晚的时区算）' "$today"; return 0; fi
  lower_bound="$(date_lower_bound "$start_date")"
  if [[ -n "$lower_bound" && "$checked_date" < "$lower_bound" ]]; then
    printf '早于这个仓第一个提交（%s）%s 天以上' "$start_date" "$DATE_GRACE_DAYS"; return 0
  fi
  return 1
}

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
  if [[ -n "${GATE_BASE:-}" ]]; then
    # 写错的 ref 不许静默放行：changed_files 解析不到基准时按「空仓」处理，只看未跟踪文件，
    # 于是 show-me-test 报「无对象可判」、整道门禁绿（审计实测：GATE_BASE=orgin/master 拼错一个字母，退 3）。
    if ! git -C "$root" rev-parse --verify -q "${GATE_BASE}^{commit}" >/dev/null 2>&1; then
      { bad "GATE_BASE=$GATE_BASE 解析不到提交"
        howto "写成真实存在的 ref 或提交号（git -C $root log --oneline 看一眼），" \
              "或者不设它，让门禁自己算基准。解析不到就往下跑的话，这一轮等于没判。"; } >&2
      return 1
    fi
    printf '%s' "$GATE_BASE"; return 0
  fi
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
          # 取与上游的 merge-base，不是上游的 tip：fetch 了没 merge、或本地与上游分叉时，
          # 上游 tip 上有本地没有的提交，拿它当基准就是把别人的改动算进这一轮
          # （审计实测：工作区干净、只是 origin/master 多一个提交，show-me-test 就报「改了 crates 代码但没有任何测试改动」）。
          if up="$(git -C "$root" merge-base HEAD "@{upstream}" 2>/dev/null)" \
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

# 工作区指纹：把工作区此刻的内容（跟踪的文件 + 没被忽略的未跟踪文件）写成一棵树，输出树的哈希；不是 git 仓时输出空。
# 用一份拷出来的临时索引算，不碰真索引：别人暂存了什么不改变指纹，只有文件内容变了才变。
# 指纹按 git 仓算，不按项目根：项目根是外层仓的一个子目录时，外层别处的改动也算「变了」。
# 代价：没进过对象库的内容会被写成松散对象，由 git gc 收掉。
worktree_fingerprint() { # worktree_fingerprint <目录> → 树哈希或空
  local root="$1" git_dir fingerprint_dir
  git_dir="$(git -C "$root" rev-parse --absolute-git-dir 2>/dev/null)" || return 0
  fingerprint_dir="$(mktemp -d)"
  cp "$git_dir/index" "$fingerprint_dir/index" 2>/dev/null || true
  if GIT_INDEX_FILE="$fingerprint_dir/index" git -C "$root" add -A >/dev/null 2>&1; then
    GIT_INDEX_FILE="$fingerprint_dir/index" git -C "$root" write-tree 2>/dev/null || true
  fi
  rm -rf "${fingerprint_dir:?}"
}
