#!/usr/bin/env bash
# 公共函数。门禁脚本 source 它。
# 约定：任何"验证"函数都必须能返回非零。不许有只会成功的检查。

set -euo pipefail

# 字符数不许随 locale 变：C locale 下 awk 的 length() 按字节算，「24 字」会变成 8 个汉字。
# 前段的输出先落到变量再判：pipefail 下 `… | grep -q` 一命中就退出，前段吃 SIGPIPE、
# 管道返回 141，而 `if` 把它读成「没命中」（shell-lint 的 S7「pipefail 下以 grep -q 收尾的管道」判这一条）。
_installed_locales="$(locale -a 2>/dev/null || true)"
for _locale_candidate in C.UTF-8 C.utf8 en_US.UTF-8; do
  if grep -qix "$_locale_candidate" <<<"$_installed_locales"; then export LC_ALL="$_locale_candidate"; break; fi
done
unset _locale_candidate _installed_locales

if [[ -t 1 ]]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
  C_BLD=$'\033[1m'; C_RST=$'\033[0m'
else
  C_RED=''; C_GRN=''; C_YEL=''; C_BLD=''; C_RST=''
fi

say()   { printf '%s\n' "$*"; }
# awk 实现必须钉死：mawk 的 substr/length 按字节走，gawk 在 UTF-8 locale 下按字符走，同一份 kb 会得出不同判定。
_awk_version="$(awk --version 2>/dev/null | head -1 || true)"
if ! grep -q GNU <<<"$_awk_version"; then
  printf '%s  ✗%s 需要 gawk：当前 awk 不是 GNU awk\n' "${C_RED:-}" "${C_RST:-}" >&2
  printf '%s     → 怎么办：%s 装 gawk（Debian/Ubuntu: sudo apt install gawk），\n' "${C_YEL:-}" "${C_RST:-}" >&2
  printf '                或把 PATH 里的 awk 指到 gawk。判定结果不许随 awk 实现变。\n' >&2
  exit 1
fi

head1() { printf '\n%s══ %s ══%s\n' "$C_BLD" "$*" "$C_RST"; }
ok()    { printf '%s  ✓%s %s\n' "$C_GRN" "$C_RST" "$*"; }
bad()   { printf '%s  ✗%s %s\n' "$C_RED" "$C_RST" "$*"; }
warn()  { printf '%s  !%s %s\n' "$C_YEL" "$C_RST" "$*"; }

# 拒绝时说清下一步做什么（rules/sop-first.md「每一条拒绝都必须给出下一步」）；bad 之后的 howto 由 scripts/gate-lint.sh 判。
howto() { printf '%s     → 怎么办：%s %s\n' "$C_YEL" "$C_RST" "$1"; shift
          local continuation_line
          for continuation_line in "$@"; do printf '                %s\n' "$continuation_line"; done; }

# die <消息> <出路…>：bad + howto + exit 1。少了出路时这里兜一句，静态那半由 scripts/gate-lint.sh 判调用点的参数个数。
die()   { bad "$1"; shift
          if [[ $# -gt 0 ]]; then howto "$@"
          else howto "这条拒绝没写出路，是本仓自己的缺陷。请给这处 die 补上第二个参数。"; fi
          exit 1; }

# ── 准入与运行条件（rules/preflight-discipline.md）──────────
# 每个脚本在 source 本文件之后、第一件干活的事之前照抄这一行：
#   preflight "${BASH_SOURCE[0]}" "$@"; set -- ${PREFLIGHT_ARGUMENTS[@]+"${PREFLIGHT_ARGUMENTS[@]}"}
# preflight、preflight_record_success 定义在 preflight.sh；不 source 本文件的钩子直接 source 它。
source "$(dirname "${BASH_SOURCE[0]}")/preflight.sh"

# ── 「命令位置」的唯一定义 ──────────────────────────────
# gate-lint 与 shell-lint 都要判「这个记号是被执行了，还是只是出现在字符串里」。
# 各写一份时一份漏了 `(){}`，`( bad "不合格" )` 与 `eval bad "..."` 整体漏检。
CMD_POS='(^[[:space:]]*|[;&|(){}`!][[:space:]]*|(then|else|do|if|while|until|sudo|env|xargs|exec|eval|command|time)[[:space:]]+)'

# ── 「按模式找进程」的唯一定义 ────────────────────────────
# shell-lint（S2、S3，判脚本）与 claude-hooks/pattern-process-guard.sh（判手敲的命令）共用；
# 为什么禁用、换成什么写法，见 rules/command-safety.md「`pkill -f` / `killall` 一律禁用」。
# 命令名认任意路径前缀（/usr/bin/pkill 也是 pkill）；选项认「有没有全模式匹配那一位」（-f / --full / 合并写法 -af），
# 不按拼写枚举：写死 `-f` 时 `pkill --full 模式`、`pkill -af 模式`、`/usr/bin/killall 进程名` 都漏检。
COMMAND_PATH_PREFIX_RE='([A-Za-z0-9_/.-]*/)?'
# S2：pkill 带全模式匹配，或 killall。
PATTERN_KILL_RE="$CMD_POS$COMMAND_PATH_PREFIX_RE"'(pkill([[:space:]]+-[[:alnum:]-]*)*[[:space:]]+(-[[:alnum:]]*f[[:alnum:]]*|--full)|killall)([[:space:]]|$)'
# S3：pgrep -f 在命令位置上出现就红，不看同一行有没有 kill / while：`pids=$(pgrep -f 模式)` 下一行再 kill、
# 循环与 pgrep -f 分两行写，都会漏；按子串找 if 又会把 `pgrep -f notify` 判成等待循环。
PATTERN_PGREP_RE="$CMD_POS$COMMAND_PATH_PREFIX_RE"'pgrep([[:space:]]+-[[:alnum:]-]*)*[[:space:]]+(-[[:alnum:]]*f[[:alnum:]]*|--full)'

# ── 「这一行开了一个 heredoc」的唯一定义 ────────────────
# gate-lint 与 shell-lint 都要跳过 heredoc 体（里面是数据，不是代码）。误判一行，从那行起整个文件都被当成
# heredoc 体不再检查，而且一声不响。所以：`<<` 前面不许是 `<`（排掉 `<<<`），定界符后面必须是空白、
# 引号或行尾（排掉 `$((1<<SHIFT))`）；注释行（`# 用法：python3 - <<PY`）由调用方在判之前跳过。定界符是第 2 个捕获组。
HEREDOC_RE="(^|[^<])<<-?[[:space:]]*['\"]?([A-Za-z_][A-Za-z0-9_]*)(['\"[:space:]]|\$)"

# ── 日期能不能是真的：唯一定义 ──────────────────────────
# 编出来的日期看不出是编的，除非它落在不可能的区间里：早于起点（放宽 DATE_GRACE_DAYS 天）或晚于今天。
# 本包自己的起点（`git log --reverse` 现查）。样本、模板、规则里的日期说的都是这个包的事，下界就用它，不随包被拷到哪里而变。
SOP_START_DATE=2026-08-26

# 被检查的那个项目自己的起点。只在 <目录> 本身就是 git 仓的顶层时才问 git：不然 `git -C` 一路往上找，
# SOP 副本放在项目的 .claude/ 下时找到的是项目的历史。
# 不拿 CHANGELOG 最早那一节兜底：它不是从第一版起逐节记的，比真起点晚，会把真日期判成不可能。
# 拿不到就返回空，由调用方决定退到哪。
project_start_date() { # project_start_date <目录> → YYYY-MM-DD 或空
  local checked_directory toplevel
  checked_directory="$(cd "$1" 2>/dev/null && pwd -P)" || return 0
  toplevel="$(git -C "$checked_directory" rev-parse --show-toplevel 2>/dev/null || true)"
  [[ -n "$toplevel" && "$(cd "$toplevel" && pwd -P)" == "$checked_directory" ]] || return 0
  # 浅克隆里「第一个提交」是截断处，不是项目的起点，这时也返回空。
  [[ "$(git -C "$checked_directory" rev-parse --is-shallow-repository 2>/dev/null || true)" != true ]] || return 0
  git -C "$checked_directory" log --reverse --format=%ad --date=short 2>/dev/null | head -1 || true
}
# 下界从第一个提交往前放宽 DATE_GRACE_DAYS 天：git init 之前做的工作，会带着当时的日期进第一个提交（实测早一天）。
# 宽得越多，放过的编造日期越多。
DATE_GRACE_DAYS=7
date_lower_bound() { # date_lower_bound <起点 YYYY-MM-DD 或空> → 下界或空
  [[ -n "${1:-}" ]] || return 0
  date -d "$1 - $DATE_GRACE_DAYS days" +%F
}
# 下界要做日期减法，靠 GNU date 的 -d。不认 -d 时 date_out_of_range 在 if 条件里调、set -e 不管，
# 下界静默变空、早得不可能的日期照样放行。所以查日期的脚本开头先调它。
require_date_arithmetic() {
  [[ "$(date -d '2026-01-02 - 1 day' +%F 2>/dev/null || true)" == 2026-01-01 ]] || die "这台机器的 date 不认 -d，算不出日期下界" \
    "日期检查要 GNU date（coreutils）：装上它，或把它放到 PATH 前面，再重跑。env.sh 也查这一项。"
}
# 「今天」按地球上最晚的那个时区（UTC+14）算：比它还晚的日期，在哪儿都还没到。
# 只取本机时钟的日期不行：本机是 UTC、人在东京时，东京 00:00–09:00 写下的当天日期会被判成「晚于今天」。
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

# 找到项目根：向上找到含 .singlefs-ai-sop-version 或 .git 的目录（.git 可以是文件：git worktree 里它是指路的文件）。
# 找不到要说出来：调用方写成 ROOT="${1:-$(project_root)}"，set -e 下静默返回 1 门禁就一句话都没有地退出了。
# 说明写到 stderr，stdout 只留路径。
project_root() {
  local candidate_directory="${1:-$PWD}"
  while [[ "$candidate_directory" != "/" ]]; do
    [[ -f "$candidate_directory/.singlefs-ai-sop-version" || -e "$candidate_directory/.git" ]] && { printf '%s' "$candidate_directory"; return 0; }
    candidate_directory="$(dirname "$candidate_directory")"
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
    # show-me-test 报「无对象可判」、整道门禁绿。
    if ! git -C "$root" rev-parse --verify -q "${GATE_BASE}^{commit}" >/dev/null 2>&1; then
      { bad "GATE_BASE=$GATE_BASE 解析不到提交"
        howto "写成真实存在的 ref 或提交号（git -C $root log --oneline 看一眼），" \
              "或者不设它，让门禁自己算基准。解析不到就往下跑的话，这一轮等于没判。"; } >&2
      return 1
    fi
    printf '%s' "$GATE_BASE"; return 0
  fi
  local default_branch
  for default_branch in master main; do
    if git -C "$root" rev-parse --verify -q "$default_branch" >/dev/null; then
      local merge_base
      if merge_base="$(git -C "$root" merge-base HEAD "$default_branch" 2>/dev/null)" && [[ -n "$merge_base" ]]; then
        # 在默认分支上时 merge-base 等于 HEAD，得往回退。只退 HEAD~1 不够：分两次提交就绕过去了
        # （先改代码不带测试、再只改文档，基准落在改代码的那次提交上，「本次无 crates 改动」）。
        # 所以退到已经过闸的点，本地还没推的提交全部纳入判定。
        if [[ "$merge_base" == "$(git -C "$root" rev-parse HEAD 2>/dev/null)" ]]; then
          local upstream_merge_base parent_of_head
          # 优先级：上游 > 门禁上次通过的位置 > HEAD~1。
          # 取与上游的 merge-base，不是上游的 tip：fetch 了没 merge、或本地与上游分叉时，
          # 上游 tip 上有本地没有的提交，拿它当基准就是把别人的改动算进这一轮。
          if upstream_merge_base="$(git -C "$root" merge-base HEAD "@{upstream}" 2>/dev/null)" \
             && [[ -n "$upstream_merge_base" && "$upstream_merge_base" != "$(git -C "$root" rev-parse HEAD)" ]]; then
            printf '%s' "$upstream_merge_base"; return 0
          fi
          local gate_ok_commit
          if gate_ok_commit="$(git -C "$root" rev-parse -q --verify refs/sop/gate-ok 2>/dev/null)" \
             && [[ -n "$gate_ok_commit" ]] \
             && git -C "$root" merge-base --is-ancestor "$gate_ok_commit" HEAD 2>/dev/null; then
            printf '%s' "$gate_ok_commit"; return 0
          fi
          if parent_of_head="$(git -C "$root" rev-parse -q --verify HEAD~1 2>/dev/null)"; then
            printf '%s' "$parent_of_head"; return 0
          fi
        fi
        printf '%s' "$merge_base"; return 0
      fi
    fi
  done
  printf 'HEAD'
}

# 列出相对基准变更的文件（含工作区未提交改动）。任一条 git 失败就返回 1、一行都不输出：
# 少一截的清单与「没有改动」长得一样，调用方会把它判成无对象可判。调用方写成
#   files="$(changed_files "$ROOT" "$BASE")" || die "取不到改动清单" "<出路>"
changed_files() {
  local root="$1" base="$2" worktree_changes cached_changes untracked_files
  # 空仓（还没有任何 commit）时 HEAD 不存在，对基准的 diff 会失败——看暂存区（没有 HEAD 时 --cached 对的是空树）与未跟踪文件
  if ! git -C "$root" rev-parse --verify -q "$base^{commit}" >/dev/null 2>&1; then
    cached_changes="$(git -C "$root" diff --name-only --cached --)" || return 1
    untracked_files="$(git -C "$root" ls-files --others --exclude-standard)" || return 1
    printf '%s\n%s\n' "$cached_changes" "$untracked_files" | sort -u | grep -v '^$' || true
    return 0
  fi
  worktree_changes="$(git -C "$root" diff --name-only "$base" --)" || return 1
  cached_changes="$(git -C "$root" diff --name-only --cached --)" || return 1
  untracked_files="$(git -C "$root" ls-files --others --exclude-standard)" || return 1
  printf '%s\n%s\n%s\n' "$worktree_changes" "$cached_changes" "$untracked_files" | sort -u | grep -v '^$' || true
}

# 项目给 cargo 挂的前缀登记，相对项目根（rules/command-safety.md）。check.sh 读它；gate.sh --staged 查临时树里有没有它。
CARGO_COMMAND_PREFIX_FILE=.claude/cargo-command-prefix

# ── 项目登记的门禁目录与钩子目录（rules/sop-first.md）──────────────
# 项目要把门禁或钩子挪出 .claude/ 时，各登记一个文件（项目根，一行，相对项目根的路径，去掉结尾的 /）；
# 不存在就是默认值。preflight-lint.py、gate-overlap.py、link-targets.py 读的是同一份登记（各自的 project_gate_directory /
# project_hooks_directory），两边的默认值与解析规则必须一致，改一处要跟着改另一处。
GATE_DIRECTORY_REGISTRATION_FILE=.claude/gate-directory
GATE_DIRECTORY_DEFAULT=.claude/gate.d
HOOKS_DIRECTORY_REGISTRATION_FILE=.claude/hooks-directory
HOOKS_DIRECTORY_DEFAULT=.claude/hooks

# bad / howto / die 都写 stdout；这几个读登记的函数设计成 变量="$(函数 ...)" 来用，拒绝时若也走 bad/howto，
# 消息会被命令替换吃进那个变量，终端上什么都看不见，只剩一个解释不出来的非零退出码。拒绝一律走这个，直写 stderr。
die_to_stderr() { # die_to_stderr <消息> <出路…>：同 die，但写 stderr，给要用命令替换取值的函数用
  printf '%s  ✗%s %s\n' "$C_RED" "$C_RST" "$1" >&2; shift
  printf '%s     → 怎么办：%s %s\n' "$C_YEL" "$C_RST" "$1" >&2; shift
  local continuation_line; for continuation_line in "$@"; do printf '                %s\n' "$continuation_line" >&2; done
  return 1
}

_project_registered_directory() { # _project_registered_directory <根> <登记文件相对路径> <默认值>
  local root="$1" default="$3" line
  local file="$root/$2"
  if [[ -f "$file" ]]; then
    line="$(grep -vE '^[[:space:]]*(#|$)' "$file" | head -1)" || true
    line="${line%%#*}"   # 去掉行内注释：一行写成 `<路径>  # 理由`
    line="${line%"${line##*[![:space:]]}"}"; line="${line#"${line%%[![:space:]]*}"}"   # 去掉首尾空白
    if [[ -z "$line" ]]; then
      die_to_stderr "$file 登记了但一行有效路径都没有" \
        "写一行相对项目根的路径（比如 scripts/gates），或者删掉这个文件改用默认值 $default。"
      return 1
    fi
    printf '%s' "${line%/}"
  else
    printf '%s' "$default"
  fi
}

# 项目登记的门禁目录（没登记就是 $GATE_DIRECTORY_DEFAULT），相对项目根，不带结尾的 /。
project_gate_dir() { _project_registered_directory "$1" "$GATE_DIRECTORY_REGISTRATION_FILE" "$GATE_DIRECTORY_DEFAULT"; }
# 项目登记的钩子目录（没登记就是 $HOOKS_DIRECTORY_DEFAULT），相对项目根，不带结尾的 /。
project_hooks_dir() { _project_registered_directory "$1" "$HOOKS_DIRECTORY_REGISTRATION_FILE" "$HOOKS_DIRECTORY_DEFAULT"; }

# ── 项目登记的 kb 目录（rules/kb-discipline.md）──────────────────
# 项目把 kb 文本（不变量、决策、实验这类）挪出 .claude/kb/ 时，登记项目根的 .claude/kb-directories：
# 一行一条，相对项目根，`#` 后写理由（理由不许省）；可以登记多条（kb 的一部分搬走、其余留在 .claude/kb/ 也认）。
# 没有这份文件时什么都不打印，调用方按各自的默认值（多半是 .claude/kb 或 */kb/*）处理。
KB_DIRECTORIES_FILE=.claude/kb-directories
kb_directories() { # kb_directories <项目根> → 登记的目录，一行一个绝对路径；没登记什么都不打印
  local root="$1" line_number=0 raw_line stripped path reason absolute_directory
  local file="$root/$KB_DIRECTORIES_FILE"
  [[ -f "$file" ]] || return 0
  while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
    line_number=$((line_number + 1))
    stripped="${raw_line#"${raw_line%%[![:space:]]*}"}"
    [[ -z "$stripped" || "$stripped" == \#* ]] && continue
    path="${raw_line%%#*}"; path="${path%"${path##*[![:space:]]}"}"; path="${path#"${path%%[![:space:]]*}"}"
    reason="${raw_line#*#}"
    if [[ "$raw_line" != *'#'* || -z "${reason//[[:space:]]/}" || -z "$path" ]]; then
      die_to_stderr "$file:$line_number 没写理由，或路径是空的：$raw_line" \
        "一行一条： <相对项目根的路径>  # 为什么（理由不许省）。"
      return 1
    fi
    absolute_directory="$root/${path%/}"
    if [[ ! -d "$absolute_directory" ]]; then
      die_to_stderr "$file:$line_number 登记的目录不存在：$path" \
        "改对路径（相对项目根 $root），或删掉这一行。"
      return 1
    fi
    printf '%s\n' "$(cd "$absolute_directory" && pwd)"
  done < "$file"
}

# 项目里的 Rust 源码：默认不看编译产物、git 自己、.claude/（工具、样本、装进来的 SOP 副本）与本包的样本目录。
# naming-lint 与 gate.sh 的「构建与单测」共用这一份口径。
rust_source_files() { # rust_source_files <根> [额外的 find 条件…] → 一行一个 .rs 的路径
  local root="$1"; shift
  find "$root" -name '*.rs' -type f -not -path '*/target/*' -not -path "$root/.git/*" -not -path "$root/.claude/*" \
    -not -path "$root/scripts/fixtures/*" "$@"
}

# ── 「本次未跑」的侧信道（rules/show-me-test.md「门禁不许假装通过」）──
# gate.sh 导出 GATE_NOT_RUN_FILE，阶段用 report_not_run 往里追加一行，gate.sh 在记这个阶段的结果时收进汇总。
# 读进本地变量就从环境里拿掉：漏给阶段再起的子进程（selftest 嵌套跑的门禁与样本），
# 它们跳过的东西就记到了外层门禁的账上。
GATE_NOT_RUN_SIDE_CHANNEL="${GATE_NOT_RUN_FILE:-}"; unset GATE_NOT_RUN_FILE
report_not_run() { # report_not_run <哪一部分没跑：为什么、怎么补>
  warn "本次未跑（这不是通过）：$1"
  if [[ -n "$GATE_NOT_RUN_SIDE_CHANNEL" ]]; then printf '%s\n' "$1" >> "$GATE_NOT_RUN_SIDE_CHANNEL"; fi
  # 跳过了一部分的那一次，preflight_record_success 不记成「上次成功」（preflight.sh）
  PREFLIGHT_PARTS_NOT_RUN=$((PREFLIGHT_PARTS_NOT_RUN + 1))
}

# 工作区指纹：把工作区此刻的内容（跟踪的文件 + 没被忽略的未跟踪文件）写成一棵树，输出树的哈希；不是 git 仓时输出空。
# 用一份拷出来的临时索引算，不碰真索引：别人暂存了什么不改变指纹，只有文件内容变了才变。
# 指纹按 git 仓算，不按项目根：项目根是外层仓的一个子目录时，外层别处的改动也算「变了」。
# 代价：没进过对象库的内容会被写成松散对象，由 git gc 收掉。
worktree_fingerprint() { # worktree_fingerprint <目录> → 树哈希或空
  local root="$1" git_directory fingerprint_directory
  git_directory="$(git -C "$root" rev-parse --absolute-git-dir 2>/dev/null)" || return 0
  fingerprint_directory="$(mktemp -d)"
  cp "$git_directory/index" "$fingerprint_directory/index" 2>/dev/null || true
  if GIT_INDEX_FILE="$fingerprint_directory/index" git -C "$root" add -A >/dev/null 2>&1; then
    GIT_INDEX_FILE="$fingerprint_directory/index" git -C "$root" write-tree 2>/dev/null || true
  fi
  rm -rf "${fingerprint_directory:?}"
}
