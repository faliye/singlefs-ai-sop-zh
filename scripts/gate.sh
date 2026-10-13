#!/usr/bin/env bash
# admission: always 它判的是此刻的工作区（或暂存区）、兄弟仓与本机环境，上一次的绿不能替这一次作保
# run-condition: command git python3
# 准入门禁。rules/show-me-test.md的可执行形式。
#
# 用法：gate.sh [项目根] [--staged] [--force]（顺序不限）
# 退出码：0 = 没有阶段判红；非 0 = 有阶段失败。准入或运行条件不满足没起的阶段记失败（只因为「输入没变」没起的记本次未跑）；
#   带 --force 强制跑过的阶段不让退出码变非 0，但汇总里逐个列出、末句不说「全部通过」、不前移 gate-ok（rules/preflight-discipline.md）。
# 未实现的阶段显式报告为未实现，不静默跳过（rules/show-me-test.md「门禁不许假装通过」）。
# 共享阶段不知道被测对象是什么，项目自己的验证手段要靠项目本地阶段接上并声明（# gate-covers:）。绿色不等于验证充分，见文末未实现清单。
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight "${BASH_SOURCE[0]}" "$@"; set -- ${PREFLIGHT_ARGUMENTS[@]+"${PREFLIGHT_ARGUMENTS[@]}"}
GATE_FORCE_OPTION=()
if [[ $PREFLIGHT_FORCE_GIVEN -eq 1 ]]; then GATE_FORCE_OPTION=(--force); fi

SCRIPTS_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 从 git 钩子里跑时，git 设了 GIT_DIR / GIT_INDEX_FILE 这一组，它们压过 `git -C`：
# --staged 的 worktree add 会失败，而报出来的出路「先跑 git worktree prune」指的方向是错的。
# shellcheck disable=SC2046
unset $(git rev-parse --local-env-vars 2>/dev/null) 2>/dev/null || true
# 包自己的根，按物理路径算。判「被门禁的是不是 SOP 仓自身」时两边都要 pwd -P：
# 只比 pwd 的话，经符号链接跑就判成消费项目，报「缺版本戳」判红，只在 SOP 仓跑的阶段还静默不跑。
PACKAGE_DIRECTORY="$(cd "$SCRIPTS_DIRECTORY/.." && pwd -P)"
is_package_itself() { [[ "$(cd "$1" 2>/dev/null && pwd -P)" == "$PACKAGE_DIRECTORY" ]]; }
# 族名（.claude/<族名>/ 那一段）。要定义在第一处用到它的地方（「规范版本不一致」的 howto）之前，
# 否则 set -u 下那条拒绝一出口就是 unbound variable。
package_family="$(sed -n 's/^family=//p' "$SCRIPTS_DIRECTORY/../I18N" 2>/dev/null || echo singlefs-ai-sop)"

# ── 参数：项目根与 --staged，顺序不限 ─────────────────────
# 不许写死「$1 == --staged」：项目里的包装脚本（install.sh 铺的那几份包装）把项目根放在 $1、用户的参数接在后面，
# --staged 落在没人读的 $2，门禁照常跑工作区，而且一声不响。
GATE_ROOT_ARGUMENTS=(); WANT_STAGED=0
for gate_argument in "$@"; do
  case "$gate_argument" in
    --staged) WANT_STAGED=1 ;;
    -*)       die "认不出的参数：$gate_argument" "用法： gate.sh [项目根] [--staged] [--force]" ;;
    *)        GATE_ROOT_ARGUMENTS+=("$gate_argument") ;;
  esac
done
[[ ${#GATE_ROOT_ARGUMENTS[@]} -le 1 ]] || die "只收一个项目根，收到 ${#GATE_ROOT_ARGUMENTS[@]} 个：${GATE_ROOT_ARGUMENTS[*]}" \
  "用法： gate.sh [项目根] [--staged] [--force]"
set -- ${GATE_ROOT_ARGUMENTS[@]+"${GATE_ROOT_ARGUMENTS[@]}"}

# ── --staged：只拿「HEAD + 暂存区」跑整道门禁 ─────────────
# 几个会话共写一个仓时，工作区里混着别人没收尾的改动与未跟踪文件，门禁在工作区上判的红分不清是谁的
# （rules/session-wrapup.md 第 4 条「同一个仓里有没有别的会话在飞？」）。这里在临时 worktree 上把 `git diff --cached` 套到 HEAD 上，再对那棵树跑一遍整道门禁。
# 规范副本不进 git 时（项目常把 .claude/<包名>/ 放进 .gitignore）原样拷进 worktree，否则项目里的包装脚本转发不到。
# worktree 里的构建从零开始；要复用构建产物，自己设 CARGO_TARGET_DIR 之类的环境变量。
if [[ $WANT_STAGED -eq 1 ]]; then
  source_repository_root="$(cd "${1:-$(project_root)}" 2>/dev/null && pwd)" || die "找不到项目根：${1:-当前目录}" \
    "在项目根跑 bash .claude/scripts/gate.sh --staged（包装自己会带上项目根，别再给一个）；" \
    "直接调共享脚本时才把项目根作为参数： bash <规范副本>/scripts/gate.sh --staged <项目根>"
  git -C "$source_repository_root" rev-parse --git-dir >/dev/null 2>&1 || die "--staged 要在 git 仓里跑，而 $source_repository_root 不是" \
    "去掉 --staged 直接跑，或者到仓里再跑。"
  staged_scratch_directory="$(mktemp -d)"; staged_tree="$staged_scratch_directory/tree"
  if ! git -C "$source_repository_root" diff --cached --binary > "$staged_scratch_directory/staged.patch"; then
    rm -rf "${staged_scratch_directory:?}"; die "取不到暂存区的 diff" "确认 git 可用，再跑一次。"
  fi
  if ! staged_worktree_add_error="$(git -C "$source_repository_root" worktree add --detach "$staged_tree" HEAD 2>&1)"; then
    rm -rf "${staged_scratch_directory:?}"
    printf '%s\n' "$staged_worktree_add_error" | sed 's/^/        /'
    die "建临时 worktree 失败（git 的原话在上面）" \
      "常见的三种：仓里还没有任何提交；从 git 钩子里跑（那一组 GIT_* 压过 -C，本脚本开头已清）；有残留的登记。" \
      "残留用 git -C $source_repository_root worktree remove --force <路径> 删——prune 清不掉 \$TMPDIR 里还在的那个目录。"
  fi
  # 跑到一半被打断（Ctrl-C）或被杀时也要删掉临时 worktree：留下的会一直登记在仓里。两次跑不会出错。
  # git 那句要带 || true：被 INT / TERM 打断时这里先清一次、exit 又触发 EXIT 再清一次，再清的那一次 git 退非 0，
  # set -e 在 trap 里当场把脚本带走，下面那句「没跑完」打不出来、退出码也变了。
  staged_cleanup() { git -C "$source_repository_root" worktree remove --force "$staged_tree" >/dev/null 2>&1 || true; rm -rf "${staged_scratch_directory:?}"; }
  # 中途退出（die、set -e 打断的 cp / mkdir 这类）也要说出来：只剩那条命令自己的一句 stderr 时，
  # 外面看不出里层门禁根本没起。与非 --staged 那一支的 gate_exit_guard 同一条规矩。
  STAGED_INNER_FINISHED=0
  staged_exit_guard() {
    local staged_exit_code=$?
    staged_cleanup
    (( STAGED_INNER_FINISHED )) && return
    printf '  ✗ --staged 没跑完就退出了（退出码 %s）：里层门禁没起或没跑完，临时 worktree 已删\n' "$staged_exit_code" >&2
    printf '     → 怎么办：看上面最后一句是哪一步出的错（建临时树、套暂存区、拷副本、查前缀登记），修好再跑。\n' >&2
    printf '               中途退出时「没跑」和「跑过了」在输出里长得一样，所以这一条必须自己说出来。\n' >&2
    exit "$(( staged_exit_code == 0 ? 1 : staged_exit_code ))"
  }
  # EXIT 兜底：worktree 建起来之后，中间任何一处退出都靠这一个 trap 把临时 worktree 带走。
  # 别在 die 之前再手工清一次：每条 die 路径都自己清干净的话，「删掉 EXIT 兜底」这个变异就检测不到。清理只留这一处。
  trap 'staged_exit_guard' EXIT
  trap 'staged_cleanup; exit 130' INT
  trap 'staged_cleanup; exit 143' TERM
  if [[ -s "$staged_scratch_directory/staged.patch" ]] && ! git -C "$staged_tree" apply --index "$staged_scratch_directory/staged.patch"; then
    die "暂存区的 diff 套不上 HEAD" "先 git status 看暂存区是不是基于当前 HEAD，再跑一次。"
  fi
  staged_family="$(sed -n 's/^family=//p' "$SCRIPTS_DIRECTORY/../I18N" 2>/dev/null || true)"; staged_family="${staged_family:-singlefs-ai-sop}"
  if [[ -d "$source_repository_root/.claude/$staged_family" && ! -d "$staged_tree/.claude/$staged_family" ]]; then
    mkdir -p "$staged_tree/.claude"; cp -r "$source_repository_root/.claude/$staged_family" "$staged_tree/.claude/"
  fi
  # 项目给 cargo 挂的前缀登记（scripts/check.sh 读它）没进 HEAD + 暂存区时，临时树里没有它，
  # 里层的「构建与单测」就退回无包装的 cargo 去跑（rules/command-safety.md）。不替它拷：拷的是工作区那一份，不是这一次要提交的。
  if [[ -f "$source_repository_root/$CARGO_COMMAND_PREFIX_FILE" && ! -f "$staged_tree/$CARGO_COMMAND_PREFIX_FILE" ]]; then
    die "源仓有 $CARGO_COMMAND_PREFIX_FILE，而 HEAD + 暂存区里没有它：--staged 这一轮的 cargo 会不经前缀跑" \
      "把它提交或暂存（git -C $source_repository_root add $CARGO_COMMAND_PREFIX_FILE）再跑；不要这个前缀了，就从源仓删掉它。"
  fi
  # diff 基准在源仓上算好再传进去。临时树是 detached HEAD，@{upstream} 解析不到，里层自己算会落到 HEAD~1，
  # 比直接跑窄一档：「分两次提交就绕过去」那条口子会在 --staged 这边开着。
  staged_diff_base="${GATE_BASE:-$(diff_base "$source_repository_root")}"
  # 被门禁的是 SOP 仓自身时，里层要跑临时树里那份脚本：跑源仓的 $SCRIPTS_DIRECTORY 会让里层把临时树当成消费项目，
  # 报「缺版本戳」判红，只在 SOP 仓跑的阶段还静默不跑。
  if is_package_itself "$source_repository_root"; then staged_gate="$staged_tree/scripts/gate.sh"; else staged_gate="$SCRIPTS_DIRECTORY/gate.sh"; fi
  if [[ ! -f "$staged_gate" ]]; then
    die "临时树里没有 scripts/gate.sh（$staged_gate）" "暂存区是不是把 scripts/gate.sh 删了？先把它恢复进暂存区再跑。"
  fi
  head1 "只拿 HEAD + 暂存区跑（--staged）"
  ok "临时 worktree：$staged_tree（跑完删掉）"
  ok "不进这一轮的：工作区里没暂存的 $(git -C "$source_repository_root" diff --name-only | wc -l) 个文件、未跟踪的 $(git -C "$source_repository_root" ls-files --others --exclude-standard | wc -l) 个文件"
  ok "diff 基准 $staged_diff_base（在源仓上算的，与不带 --staged 时相同）"
  # 退出码要在 if 里取：lib.sh 开着 set -e，写成「里层; staged_exit_code=$?」的话，里层一判红外层就在这一行退出，
  # 下面的清理走不到，每次判红都在仓里留下一个临时 worktree。
  if GATE_BASE="$staged_diff_base" GATE_STAGED_FROM="$source_repository_root" bash "$staged_gate" "$staged_tree" ${GATE_FORCE_OPTION[@]+"${GATE_FORCE_OPTION[@]}"}; then staged_exit_code=0; else staged_exit_code=$?; fi
  STAGED_INNER_FINISHED=1
  trap - INT TERM EXIT
  staged_cleanup
  # --staged 这一轮不会给 gate-ok 前移：外层必定给里层设 GATE_BASE，而写 gate-ok 的守卫要求它为空（理由见文末）。
  # 要说出来：不然下一轮的 diff 窗口照旧从上一次不带 --staged 跑绿那一点起算，重阶段又被全量拉起来，没人知道为什么。
  if [[ "$staged_exit_code" -eq 0 ]]; then
    previous_gate_ok_commit="$(git -C "$source_repository_root" rev-parse --short refs/sop/gate-ok 2>/dev/null || true)"
    ok "这一轮没有给 gate-ok 前移（--staged 的窗口是人为收窄的）：下一轮的 diff 基准仍从 ${previous_gate_ok_commit:-「从未写过，退回默认算法」} 起算"
    ok "  要让它前移，就在工作区干净的时候不带 --staged 再跑一次"
  fi
  exit "$staged_exit_code"
fi
# --staged 的握手变量只在这一层用：读进本地变量就从环境里拿掉。传下去的话，selftest 嵌套跑的 gate.sh
# 与项目本地阶段都会拿它当自己的项目根去找兄弟目录。GATE_BASE 不能在这里拿掉：
# show-me-test 与版本纪律要读它；由 selftest 自己在起子进程时清。
STAGED_FROM="${GATE_STAGED_FROM:-}"; unset GATE_STAGED_FROM
ROOT="${1:-$(project_root)}"
[[ -d "$ROOT" ]] || die "找不到项目根：$ROOT" \
  "在项目根跑 bash .claude/scripts/gate.sh（包装自己会带上项目根，别再给一个）；" \
  "直接调共享脚本时才把项目根作为参数： bash <规范副本>/scripts/gate.sh <项目根>"
cd "$ROOT"
# 判红时留下的临时目录按它记：只清、只列同一个项目根留下的
GATE_PROJECT_ROOT_PHYSICAL="$(pwd -P)"
# 开跑时的 HEAD。gate-ok 记的是它，不是跑完时的 HEAD——见文末。
START_HEAD="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || true)"
# 开跑时的工作区指纹。汇总之前再算一次，对不上说明这一轮各阶段读到的不是同一版——见「门禁结果」前面那一段。
START_WORKTREE_FINGERPRINT="$(worktree_fingerprint "$ROOT")"

# 这一轮的 diff 基准算一次，导给每个阶段（含项目本地阶段），同一轮里各阶段判的是同一批改动。
# 与 GATE_BASE 分成两个名字：GATE_BASE 的含义是「人指定了窗口」，文末 gate-ok 那一条要靠它区分。
# 不写成 `export 变量="$(…)"`：export 会把命令替换的退出码吞掉，GATE_BASE 写错时 diff_base 的拒绝就传不出来。
GATE_DIFF_BASE="$(diff_base "$ROOT")"
export GATE_DIFF_BASE

# 项目登记的门禁目录（rules/sop-first.md）；没登记就是默认值 .claude/gate.d。钩子目录由各自读它的脚本
# （hooks-registered.sh、gate-overlap.py 这类）自己调 project_hooks_dir / project_hooks_directory 取，这里不重复算。
PROJECT_GATE_DIRECTORY="$ROOT/$(project_gate_dir "$ROOT")"

# 中途退出要说出来。门禁在半路死掉（脚本写坏、函数先用后定、某个阶段把 shell 带走）时，
# 后面的阶段一个都不跑，汇总行也不打印，外面看到的与「跑过了」长得一模一样，只在 stderr 留一句话。
GATE_SUMMARY_PRINTED=0
gate_exit_guard() {
  local gate_exit_code=$?
  # 这一轮的临时目录不许比门禁活得久：正常收尾与中途退出（die、被打断、被杀）都在这里删，只删这一处。
  # 例外只有一个：有阶段判红、它的现场留在里面（「跑完没留下临时文件」那一段决定留，打印路径）
  if [[ -n "${GATE_RUN_TMPDIR:-}" && "${GATE_RUN_TMPDIR_KEPT:-0}" != 1 ]]; then rm -rf --one-file-system -- "${GATE_RUN_TMPDIR:?}"; fi
  (( GATE_SUMMARY_PRINTED )) && return
  printf '  ✗ 门禁没跑完就退出了（退出码 %s），一行汇总都没打印\n' "$gate_exit_code" >&2
  printf '     → 怎么办：上面最后打印的那个阶段就是断点，从那里往下看。\n' >&2
  printf '               中途退出时「没跑」和「跑过了」在输出里长得一样，所以这一条必须自己说出来。\n' >&2
  exit "$(( gate_exit_code == 0 ? 1 : gate_exit_code ))"
}
trap gate_exit_guard EXIT

# ── 这一轮自己的临时目录 ─────────────────────────────
# 各阶段（连同它们起的测试与装置）拿到这一轮自己的 TMPDIR；收尾时里面还剩下的，就是谁建了没删
# （rules/command-safety.md「测试镜像一律放临时目录」）。
# 有意跨轮复用的缓存放 GATE_CROSS_RUN_TMPDIR（这一轮开跑前的那个临时目录），门禁不管那里；
# 阶段里写成 ${GATE_CROSS_RUN_TMPDIR:-${TMPDIR:-/tmp}}，门禁之外单跑时落回平常的临时目录。
# 嵌套跑（selftest 里的门禁）沿用外层的。
if [[ -z "${GATE_CROSS_RUN_TMPDIR:-}" ]]; then GATE_CROSS_RUN_TMPDIR="${TMPDIR:-/tmp}"; fi
export GATE_CROSS_RUN_TMPDIR
GATE_RUN_TMPDIR_KEPT=0
# 判红时整个留着的那些，带这个标记（一行：留下的时刻、制表符、项目根）；同一个项目根留下的只留最近 KEPT_RUN_DIRECTORY_LIMIT 个，
# 更早的在之后跑的那一轮删掉。没有标记的 gate-run.* 是别的会话正在跑的那一轮，别的项目根留下的归那个项目，都不碰。
KEPT_RUN_DIRECTORY_MARKER=.kept-by-gate
KEPT_RUN_DIRECTORY_LIMIT=3
GATE_RUN_PARENT_DIRECTORY="${TMPDIR:-/tmp}"
if ! GATE_RUN_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/gate-run.XXXXXX")"; then
  die "建不了这一轮的临时目录（在 ${TMPDIR:-/tmp} 下）" \
    "看一眼那里的空间与权限（df -h ${TMPDIR:-/tmp}），或者把 TMPDIR 指到一个写得进去的目录再跑。"
fi
TMPDIR="$GATE_RUN_TMPDIR"
export TMPDIR
# 「本次未跑」的侧信道：阶段只跑了一部分时，用 lib.sh 的 report_not_run 往这里追加一行；不 source lib.sh 的项目阶段直接追加，
# 写成带守卫的 ${GATE_NOT_RUN_FILE:+…}（单跑、stage-selftest 喂样本时这个变量不在）。
# 放在这一轮的临时目录里，「跑完没留下临时文件」不把它算成阶段留下的。
GATE_NOT_RUN_FILE_NAME=.gate-not-run
GATE_NOT_RUN_FILE="$GATE_RUN_TMPDIR/$GATE_NOT_RUN_FILE_NAME"
: > "$GATE_NOT_RUN_FILE"
export GATE_NOT_RUN_FILE

STAGES=(); RESULTS=(); NOT_RUN=()
record() { STAGES+=("$1"); RESULTS+=("$2"); }
# 报过的那个阶段在 STAGE_REPORTED_NOT_RUN 里留 1：只跑了一部分的本地阶段不算覆盖了 gate-covers 那一项
STAGE_REPORTED_NOT_RUN=0
drain_not_run_side_channel() { # drain_not_run_side_channel <阶段名>：把这个阶段报的「本次未跑」收进汇总，清空侧信道
  local stage_name="$1" not_run_line
  STAGE_REPORTED_NOT_RUN=0
  [[ -s "$GATE_NOT_RUN_FILE" ]] || return 0
  while IFS= read -r not_run_line || [[ -n "$not_run_line" ]]; do
    if [[ -n "$not_run_line" ]]; then NOT_RUN+=("$stage_name        本次未跑一部分：$not_run_line"); STAGE_REPORTED_NOT_RUN=1; fi
  done < "$GATE_NOT_RUN_FILE"
  : > "$GATE_NOT_RUN_FILE"
}

# ── 起一个阶段之前，先判它的准入与运行条件（rules/preflight-discipline.md「gate.sh 怎么编排」）──
# 判据只在 preflight.py 一处，「起不起」只信这里的预判：阶段起了之后退 78，分不出是它自己的条件变了、
# 还是它调的别的脚本拒绝了，跑了一半的检查也可能被吞掉，所以一律按失败记。
EXIT_REFUSED_BY_PREFLIGHT=78
STAGE_FORCE_OPTION=(); STAGE_FORCED_SUMMARY=""
GATE_OK_HELD_BY=()
stage_admitted() { # stage_admitted <阶段名> <脚本> [脚本的参数…] → 0 起它；1 不起（已记好）
  local name="$1" script="$2"; shift 2
  local preflight_status preflight_exit_code=0 refused_category
  STAGE_FORCE_OPTION=(); STAGE_FORCED_SUMMARY=""
  preflight_status="$(python3 "$SCRIPTS_DIRECTORY/preflight.py" check "$script" ${GATE_FORCE_OPTION[@]+"${GATE_FORCE_OPTION[@]}"} -- "$@")" \
    || preflight_exit_code=$?
  case "$preflight_exit_code" in
    0)
      if [[ "$preflight_status" == forced* ]]; then
        STAGE_FORCE_OPTION=(--force); STAGE_FORCED_SUMMARY="${preflight_status#forced*$'\t'*$'\t'}"
      fi
      return 0 ;;
    "$EXIT_REFUSED_BY_PREFLIGHT")
      refused_category="${preflight_status#refused$'\t'}"; refused_category="${refused_category%%$'\t'*}"
      if [[ "$refused_category" == inputs-unchanged ]]; then
        NOT_RUN+=("$name        本次未跑：输入自上次成功跑完以来没变，重跑得不到新信息——${preflight_status##*$'\t'}。确认要照跑就 gate.sh --force")
      else
        bad "$name：条件不满足，没起它，按失败记——${preflight_status##*$'\t'}"
        howto "按上面每一条的出路补齐条件再跑；确认要在条件不满足时照跑就 gate.sh --force（记「强制跑过」，不记通过）。"
        record "$name" FAIL
      fi
      return 1 ;;
    *)
      bad "$name：判不了它的准入与运行条件（preflight.py 退出码 $preflight_exit_code），没起它"
      howto "照上面 preflight.py 的原话改 $script 的文件头；写法见 rules/preflight-discipline.md。"
      record "$name" FAIL
      return 1 ;;
  esac
}
# 起过的阶段按退出码记：0 通过（强制跑的记 FORCED）；77 与 <无对象时退出码> 记「本次未跑：<无对象时怎么说>」（给了才认）；
# 78 与其余的都是失败。强制跑过的，不管退出码是几，这一轮都不前移 gate-ok。
record_stage() { # record_stage <阶段名> <退出码> [无对象时的退出码] [无对象时怎么说]
  local name="$1" stage_exit_code="$2" nothing_exit_code="${3:-}" nothing_to_judge_message="${4:-}"
  drain_not_run_side_channel "$name"
  if [[ -n "$STAGE_FORCED_SUMMARY" ]]; then GATE_OK_HELD_BY+=("$name（强制跑过）"); fi
  if [[ "$stage_exit_code" -eq 0 && -n "$STAGE_FORCED_SUMMARY" ]]; then
    record "$name" FORCED
  elif [[ "$stage_exit_code" -eq 0 ]]; then
    record "$name" PASS
  elif [[ "$stage_exit_code" -eq "$EXIT_REFUSED_BY_PREFLIGHT" ]]; then
    bad "$name：起了之后退了 78（它自己的条件在预判之后变了，或者它调的别的脚本拒绝了），按失败记"
    howto "看上方它的输出是哪一个脚本拒绝的：是这个阶段自己，就补齐条件再跑；是它调的脚本，让阶段自己接住那个 78 再决定怎么判。"
    record "$name" FAIL
  elif [[ -n "$nothing_exit_code" && "$stage_exit_code" -eq "$nothing_exit_code" ]]; then
    NOT_RUN+=("$name        $nothing_to_judge_message")
  else
    record "$name" FAIL
  fi
  STAGE_FORCED_SUMMARY=""
}

run_stage() { # run_stage <名称> <解释器> <脚本> [参数…]
  local name="$1" interpreter="$2" script="$3"; shift 3
  head1 "$name"
  stage_admitted "$name" "$script" "$@" || return 0
  local stage_exit_code=0
  # GATE_IN_STAGE：告诉子脚本标题已经打过了，别再打同名的一遍
  GATE_IN_STAGE=1 "$interpreter" "$script" "$@" ${STAGE_FORCE_OPTION[@]+"${STAGE_FORCE_OPTION[@]}"} || stage_exit_code=$?
  record_stage "$name" "$stage_exit_code"
}

# 退出码 77 = 这一轮无对象可判，记「本次未跑」，既不算通过也不算失败（rules/show-me-test.md「门禁不许假装通过」）。
run_stage_may_skip() { # run_stage_may_skip <名称> <无对象时怎么说> <解释器> <脚本> [参数…]
  local name="$1" nothing_to_judge_message="$2" interpreter="$3" script="$4"; shift 4
  head1 "$name"
  stage_admitted "$name" "$script" "$@" || return 0
  local stage_exit_code=0
  GATE_IN_STAGE=1 "$interpreter" "$script" "$@" ${STAGE_FORCE_OPTION[@]+"${STAGE_FORCE_OPTION[@]}"} || stage_exit_code=$?
  record_stage "$name" "$stage_exit_code" 77 "$nothing_to_judge_message"
}

# ── 规范版本一致性 ───────────────────────────────
head1 "规范版本"
# 版本戳是给消费项目用的；SOP 仓自身没有也不该有。
if is_package_itself "$ROOT"; then
  warn "本仓即 SOP 本身，没有版本戳可判（本次无对象可判，这不是通过）"
  NOT_RUN+=("规范版本            本次无对象可判：本仓即 SOP 本身，版本戳是给消费项目的")
else
package_version="$(cat "$SCRIPTS_DIRECTORY/../VERSION" 2>/dev/null || echo "?")"
project_stamped_version="$(cat "$ROOT/.singlefs-ai-sop-version" 2>/dev/null || echo "")"
if [[ -z "$project_stamped_version" ]]; then
  # 这是拒绝，不是提醒：记的是 FAIL，就得带出路。用 warn 打、没有 howto 的话，gate-lint 看不见它。
  bad "项目未声明规范版本（缺 .singlefs-ai-sop-version）"
  howto "在项目根跑 bash .claude/singlefs-ai-sop/install.sh，它会写出 .singlefs-ai-sop-version；没装过就先装。" \
        "版本戳是项目唯一的「规矩变了」信号，缺了它门禁不知道该按哪一版判。"
  record "规范版本" FAIL
elif [[ "$project_stamped_version" != "$package_version" ]]; then
  bad "规范版本不一致：项目声明 $project_stamped_version，singlefs-ai-sop 是 $package_version"
  howto "先读一遍上游这几版改了什么：.claude/$package_family/CHANGELOG.md 顶部，或者到兄弟目录的上游仓里 git log。" \
        "副本是普通目录拷贝、里面没有 .git，在它上面跑 git log 只会得到一句「不是 git 仓库」。" \
        "确认没有影响你这次改动，再跑 bash .claude/$package_family/install.sh 更新版本戳。"
  record "规范版本" FAIL
else
  ok "规范版本 $package_version"
  record "规范版本" PASS
fi

# 版本戳与副本一致，只证明「装的时候是这个版本」，证明不了「副本还是上游最新」。
# 上游在兄弟目录时比一下；比不了就显式报未检查，不静默放过。
# 这里的 $package_version 是正在跑的这份门禁所属包的版本，不一定是项目里装的那份副本。两者不同时
# （例如有人直接跑了上游那份 gate.sh），这条检查测的就不是它名字说的东西，必须判红。
upstream_version=""; upstream_directory=""
for language in $(sed -n 's/^languages=//p' "$SCRIPTS_DIRECTORY/../I18N" 2>/dev/null); do
  # --staged 时 ROOT 是临时 worktree，兄弟目录要从原来的项目根找
  candidate_upstream_directory="$(cd "${STAGED_FROM:-$ROOT}/.." 2>/dev/null && pwd)/$package_family-$language"
  if [[ -f "$candidate_upstream_directory/VERSION" ]]; then upstream_version="$(cat "$candidate_upstream_directory/VERSION")"; upstream_directory="$candidate_upstream_directory"; break; fi
done
installed_copy_version="$(cat "$ROOT/.claude/$package_family/VERSION" 2>/dev/null || echo "")"
if [[ -n "$installed_copy_version" && "$installed_copy_version" != "$package_version" ]]; then
  bad "跑的不是项目里那份副本：本门禁来自 $package_version 的包，项目副本是 $installed_copy_version"
  howto "这条检查比的是「跑的这份包」与上游，测不到项目副本。" \
        "请改跑 bash .claude/scripts/gate.sh（它转发到项目副本），再看这一项。"
  record "副本与上游同版本" FAIL
elif [[ -z "$upstream_version" ]]; then
  warn "未检查副本是否落后上游：兄弟目录里没找到上游仓"
  howto "上游仓不在兄弟目录时这一项查不了，属于**未检查**不是通过。" \
        "要查就把上游 clone 到 $(cd "$ROOT/.." 2>/dev/null && pwd)/$package_family-<语言> 再跑。"
  # 只 warn 一句不够：这一项既不在通过列表里也不在未跑列表里，会从汇总的结论里消失。
  NOT_RUN+=("副本与上游同版本    本次未检查：兄弟目录里没有上游仓。clone 到 $(cd "$ROOT/.." 2>/dev/null && pwd)/$package_family-<语言> 再跑")
elif [[ "$upstream_version" != "$package_version" && "$(printf '%s\n' "$upstream_version" "$package_version" | sort -V | tail -1)" == "$package_version" ]]; then
  # 副本比上游新：兄弟目录里的上游仓没更新到这一版（没拉，或者副本是从一份还没提交的上游拷的）。
  # 出路与「落后」相反；报成「落后」会把人支去重拷副本，拷回来的是旧版。
  bad "上游比副本旧：副本 $package_version，上游 $upstream_version（$upstream_directory）"
  howto "兄弟目录里的上游仓还停在旧版：它没更新（git -C $upstream_directory pull），" \
        "或者副本是从一份还没提交的上游拷过来的——先把上游那一版提交，再跑这一项。" \
        "别把副本退回旧版去凑齐：副本里的规矩才是这个项目现在守的。"
  record "副本与上游同版本" FAIL
elif [[ "$upstream_version" != "$package_version" ]]; then
  bad "副本落后上游：副本 $package_version，上游 $upstream_version（$upstream_directory）"
  howto "副本是拷贝不是链接，上游抬了版本副本不会自己跟。" \
        "先读 cd $upstream_directory && git log 看改了什么，" \
        "再重新拷贝一份副本，然后跑 bash .claude/$package_family/install.sh 刷版本戳。"
  record "副本与上游同版本" FAIL
else
  ok "副本与上游同版本 $upstream_version"
  record "副本与上游同版本" PASS
fi
fi

# ── 门禁自身（每条拒绝都要给出路）──────────────
# 项目本地阶段（$PROJECT_GATE_DIRECTORY）也交给两个 lint：它们和共享阶段一样会拒绝提交者。
LINT_EXTRA=(); [[ -d "$PROJECT_GATE_DIRECTORY" ]] && LINT_EXTRA=("$PROJECT_GATE_DIRECTORY")
run_stage "门禁自检" bash "$SCRIPTS_DIRECTORY/gate-lint.sh" ${LINT_EXTRA[@]+"${LINT_EXTRA[@]}"}
# 每个脚本开头写明什么时候该调、什么时候不能调，开跑之前先判（rules/preflight-discipline.md）。
run_stage_may_skip "准入与运行条件" "本次无对象可判：判的范围里一个脚本都没有" \
  python3 "$SCRIPTS_DIRECTORY/preflight-lint.py" "$ROOT"
# 实验放在哪由项目登记；没登记，这一类就一个都没判——列进未跑，不让汇总把它当成判过了。
if ! is_package_itself "$ROOT" && [[ ! -f "$ROOT/.claude/preflight-dirs" ]]; then
  NOT_RUN+=("实验脚本的准入与运行条件  本次未查：项目没有 .claude/preflight-dirs，实验脚本放在哪没登记。建这个文件，一行一个目录（没有实验也写一行注释说明）")
fi
# 每条拒绝有没有出路是一回事，检查本身红不红得起来是另一回事，后者靠样本证明。
run_stage "门禁判别力" bash "$SCRIPTS_DIRECTORY/selftest.sh"
# rules/command-safety.md 里做成检查的那几条（shell-lint.sh 的 S1–S7）。
run_stage "shell 纪律" bash "$SCRIPTS_DIRECTORY/shell-lint.sh" ${LINT_EXTRA[@]+"${LINT_EXTRA[@]}"}
# 暂存区里的执行位：手工只暂存「这一轮的」时写死 100644，可执行位就丢在历史里，而工作区那份还是可执行的，
# 在工作区上跑的门禁看不出。同一道也判射程里的空目录：git 存不下，提交与 --staged 的临时树里没有它。
MODE_CHECKED_DIRECTORIES=("$SCRIPTS_DIRECTORY"); [[ -d "$PROJECT_GATE_DIRECTORY" ]] && MODE_CHECKED_DIRECTORIES+=("$PROJECT_GATE_DIRECTORY")
[[ -d "$ROOT/.claude/scripts" ]] && MODE_CHECKED_DIRECTORIES+=("$ROOT/.claude/scripts")
run_stage_may_skip "脚本执行位" "本次无对象可判：不在 git 仓库里，暂存区的模式无从判起" \
  bash "$SCRIPTS_DIRECTORY/script-modes.sh" "${MODE_CHECKED_DIRECTORIES[@]}"
# 项目本地阶段自己会不会红：「门禁判别力」只覆盖共享脚本，恒绿的检查与真在跑的检查长得一模一样。
run_stage_may_skip "本地阶段判别力" "本次无对象可判：$PROJECT_GATE_DIRECTORY 下没有本地阶段，或没有一个阶段配了样本（哪一种见上方它的输出）" \
  bash "$SCRIPTS_DIRECTORY/stage-selftest.sh" "$PROJECT_GATE_DIRECTORY"
# 文档里的相对链接与「第 N 节」指向：两类失效都是静默的，点开是空的那种还算好，
# 恰好指到另一个同名文件时连「打不开」这个信号都没有。
# 它按当前目录找文档：门禁开头已经 cd 到 $ROOT
run_stage "链接指向" python3 "$SCRIPTS_DIRECTORY/link-targets.py"
# 变更史的「其 N」是先到先得的公共编号：并发会话取号前不查最大号就会撞，同号条目被当锚点引用时指向哪一条无从判断。
run_stage_may_skip "历史条目编号" "本次无对象可判：$ROOT/.claude/kb 下没有变更史文件" \
  bash "$SCRIPTS_DIRECTORY/history-ordinal.sh" "$ROOT"
# 工具层的闸：规则里的提醒拦不住手敲的命令，钩子能；而钩子被删掉或改坏时那道闸静默消失。
run_stage_may_skip "工具层的闸" "本次无对象可判：项目与装进来的副本里一个钩子都没有" \
  bash "$SCRIPTS_DIRECTORY/hooks-registered.sh" "$ROOT"
# 新加的门禁与钩子先对过已有的（rules/sop-first.md「加门禁或钩子之前，先找已有的」）。
run_stage_may_skip "门禁查重" "本次无对象可判：这一次没有新加或改动门禁与钩子，或不在 git 仓里" \
  python3 "$SCRIPTS_DIRECTORY/gate-overlap.py" "$ROOT"
# 分段计时不许在转发输出的循环里打时间戳（rules/test-discipline.md「分段计时在被测进程里计，不在转发输出的循环里计」）。
run_stage_may_skip "转发计时" "本次无对象可判：它扫的那几处目录里没有 .rs / .py（扫哪几处见上方它的输出）" \
  python3 "$SCRIPTS_DIRECTORY/relay-timing-lint.py" --check "$ROOT"
# 编号引用散在源码注释与记录里，doc-lint 只管 markdown，够不着那些地方。
run_stage_may_skip "编号与简称" "本次无对象可判：$ROOT/.claude/kb 不在，或一个 .rs / .md 都没扫到" \
  bash "$SCRIPTS_DIRECTORY/number-name-sync.sh" "$ROOT"

# ── 文档铁律 ────────────────────────────────────
run_stage "文档铁律" bash "$SCRIPTS_DIRECTORY/doc-lint.sh" "$ROOT"
# 本语言没有词表时，doc-lint 里那几条检查是没实现，不是通过：它自己报得出是哪几条，这里搬进末尾的未实现清单。
# 取不到那份清单（它的准入与运行条件不满足、或者崩了）要判红：吞掉的话，未实现清单静默变短，汇总照样报全部通过。
EXTRA_NOT_IMPLEMENTED=()
if doc_lint_not_implemented="$(bash "$SCRIPTS_DIRECTORY/doc-lint.sh" --not-impl)"; then
  while IFS= read -r not_implemented_line; do
    if [[ -n "$not_implemented_line" ]]; then EXTRA_NOT_IMPLEMENTED+=("$not_implemented_line"); fi
  done <<< "$doc_lint_not_implemented"
else
  doc_lint_not_implemented_exit_code=$?
  bad "取不到 doc-lint 报的未实现项（doc-lint.sh --not-impl 退出码 $doc_lint_not_implemented_exit_code）：汇总末尾的未实现清单会少掉它那几条"
  howto "单跑 bash $SCRIPTS_DIRECTORY/doc-lint.sh --not-impl 看它为什么失败（退出码 78 是它的准入与运行条件不满足），修好再跑。"
  record "文档铁律的未实现清单" FAIL
fi

# ── 规则纪律 ──────────────────────────────────
# 上游包自己的 rules/ 只在上游判；项目的 .claude/rules/ 在哪边跑都判；装进项目的副本不判，由上游自己的门禁管。
# 退出码 77 = 那个目录下一个 .md 都没有，或者本包的语言整个没有词表，记「本次未跑」。
# 本包的语言上没实现的那几条由 rules-lint.sh --not-impl 报出、进末尾的未实现清单，与 doc-lint 的未实现项同一个办法。
run_rules_lint() { # run_rules_lint <阶段名> <规则目录> <额外要扫的文件…>
  head1 "$1"
  local rules_lint_exit_code=0 stage_name="$1" rules_directory="$2" rules_not_implemented listed_not_implemented already_listed=0; shift 2
  stage_admitted "$stage_name" "$SCRIPTS_DIRECTORY/rules-lint.sh" "$ROOT" || return 0
  if ! rules_not_implemented="$(bash "$SCRIPTS_DIRECTORY/rules-lint.sh" --not-impl)"; then
    bad "$stage_name：取不到 rules-lint 报的未实现项（rules-lint.sh --not-impl 失败），这一项没判"
    howto "单跑 bash $SCRIPTS_DIRECTORY/rules-lint.sh --not-impl 看它为什么失败，修好再跑。"
    record "$stage_name" FAIL
    return 0
  fi
  if [[ -n "$rules_not_implemented" ]]; then
    for listed_not_implemented in ${EXTRA_NOT_IMPLEMENTED[@]+"${EXTRA_NOT_IMPLEMENTED[@]}"}; do
      if [[ "$listed_not_implemented" == "$rules_not_implemented" ]]; then already_listed=1; fi
    done
    if [[ $already_listed -eq 0 ]]; then EXTRA_NOT_IMPLEMENTED+=("$rules_not_implemented"); fi
  fi
  GATE_IN_STAGE=1 RULES_LINT_DIR="$rules_directory" RULES_LINT_FILES="$*" bash "$SCRIPTS_DIRECTORY/rules-lint.sh" "$ROOT" \
    ${STAGE_FORCE_OPTION[@]+"${STAGE_FORCE_OPTION[@]}"} || rules_lint_exit_code=$?
  record_stage "$stage_name" "$rules_lint_exit_code" 77 "本次无对象可判：$rules_directory 下面一个 .md 都没有，或本包的语言没有词表（哪一种见上方它的输出）"
}
# CLAUDE.md、agent 定义与 skill 正文一起扫：它们和规则一样是照着执行的。
if is_package_itself "$ROOT"; then
  run_rules_lint "规则纪律" "$SCRIPTS_DIRECTORY/../rules" CLAUDE.md "agents/*.md" "skills/*/SKILL.md"
fi
# 规则目录取项目有的那个：只有 .claude/agents/ 没有 .claude/rules/ 的项目，agent 定义也要被扫到。
PROJECT_RULES_DIRECTORY=""
[[ -d "$ROOT/.claude/rules" ]] && PROJECT_RULES_DIRECTORY="$ROOT/.claude/rules"
[[ -z "$PROJECT_RULES_DIRECTORY" && -d "$ROOT/.claude/agents" ]] && PROJECT_RULES_DIRECTORY="$ROOT/.claude/agents"
if [[ -n "$PROJECT_RULES_DIRECTORY" ]]; then
  run_rules_lint "规则纪律（项目本地）" "$PROJECT_RULES_DIRECTORY" CLAUDE.md \
    ".claude/agents/*.md" ".claude/agent-common.md" ".claude/main-agent.md" ".claude/skills/*/SKILL.md"
fi

# ── 命名纪律 ───────────────────────────────────
# 机器判得了的是单字母和常见缩写那一半（rules/code-discipline.md）。
# 退出码 3 = 没有要查的 .rs，与 Show me test 同一个约定：记「本次未跑」，不记通过。
head1 "命名纪律"
if stage_admitted "命名纪律" "$SCRIPTS_DIRECTORY/naming-lint.sh" "$ROOT"; then
  naming_lint_exit_code=0; GATE_IN_STAGE=1 bash "$SCRIPTS_DIRECTORY/naming-lint.sh" "$ROOT" ${STAGE_FORCE_OPTION[@]+"${STAGE_FORCE_OPTION[@]}"} || naming_lint_exit_code=$?
  record_stage "命名纪律" "$naming_lint_exit_code" 3 "    本次无对象可判：项目里没有要查的 .rs 文件。写了 Rust 代码之后这一项才有东西可判"
fi

# ── Show me test ────────────────────────────────
# 判定逻辑住在 show-me-test.sh（selftest 拿样本仓单独喂它）。退出码 3 = 无对象可判。
head1 "Show me test"
if stage_admitted "Show me test" "$SCRIPTS_DIRECTORY/show-me-test.sh" "$ROOT"; then
  show_me_test_exit_code=0; GATE_IN_STAGE=1 bash "$SCRIPTS_DIRECTORY/show-me-test.sh" "$ROOT" ${STAGE_FORCE_OPTION[@]+"${STAGE_FORCE_OPTION[@]}"} || show_me_test_exit_code=$?
  record_stage "Show me test" "$show_me_test_exit_code" 3 "本次无对象可判：工作区与基准无差异，或差异里没有 crates 代码（哪一种见上方它的输出）。改动之后再跑，或指定基准： GATE_BASE=<ref> bash .claude/scripts/gate.sh"
fi

# ── 构建与单测 ──────────────────────────────────
if [[ ! -f "$ROOT/Cargo.toml" ]]; then
  head1 "构建与单测"
  # 哪些 .rs 算项目的，与命名纪律同一份口径（lib.sh 的 rust_source_files），不只看 crates/。
  # 往上到项目根都没有 Cargo.toml 的才是没人构建过的；自带 Cargo.toml 的子目录（研究用的小 crate）有它自己的构建
  first_rust_source=""; first_orphan_rust_source=""
  while IFS= read -r rust_source; do
    [[ -n "$rust_source" ]] || continue
    if [[ -z "$first_rust_source" ]]; then first_rust_source="$rust_source"; fi
    rust_source_directory="${rust_source%/*}"
    while [[ "$rust_source_directory" == "$ROOT"/* && ! -f "$rust_source_directory/Cargo.toml" ]]; do
      rust_source_directory="${rust_source_directory%/*}"
    done
    if [[ ! -f "$rust_source_directory/Cargo.toml" ]]; then first_orphan_rust_source="$rust_source"; break; fi
  done < <(rust_source_files "$ROOT" 2>/dev/null || true)
  if [[ -n "$first_orphan_rust_source" ]]; then
    bad "有 .rs 文件往上到项目根都没有 Cargo.toml —— 这些代码根本没被构建过（例：${first_orphan_rust_source#"$ROOT"/}）"
    howto "在仓库根建 Cargo.toml（workspace），把含这些 .rs 的 crate 列进 members；或者给它所在的 crate 建自己的 Cargo.toml。" \
          "算不算项目的代码按 lib.sh 的 rust_source_files：target/、.git/、.claude/ 与本包的样本目录之外的 .rs 都算。"
    record "构建与单测" FAIL
  elif [[ -n "$first_rust_source" ]]; then
    warn "项目根没有 Cargo.toml，.rs 都在自带 Cargo.toml 的子目录里（例：${first_rust_source#"$ROOT"/}）：共享的构建与单测不跑它们（这不是通过）"
    NOT_RUN+=("构建与单测          本次无对象可判：项目根没有 Cargo.toml，.rs 都在自带 Cargo.toml 的子目录里，由它们自己的阶段构建")
  else
    warn "项目里没有 .rs，也没有 Cargo.toml：这一项无对象可判（这不是通过）"
    NOT_RUN+=("构建与单测          本次无对象可判：项目里没有 .rs，也没有 Cargo.toml")
  fi
elif ! command -v cargo >/dev/null 2>&1; then
  head1 "构建与单测"
  bad "有 Cargo.toml 但 cargo 缺失 —— 无法验证，按失败处理（不降级、不跳过）"
  howto "装 Rust 工具链：" \
        "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
  record "构建与单测" FAIL
else
  run_stage "构建与单测" bash "$SCRIPTS_DIRECTORY/check.sh" "$ROOT"
fi

# ── 规则清单（译文仓的对账依据）─────────────────
if [[ -d "$SCRIPTS_DIRECTORY/../rules" && -f "$SCRIPTS_DIRECTORY/manifest.sh" ]]; then
  run_stage_may_skip "规则清单" "本次无对象可判：本仓不是参照仓，清单以参照仓为准" bash "$SCRIPTS_DIRECTORY/manifest.sh"
  # 译文同步只判 SOP 仓自身：消费项目那边没有兄弟语言仓。
  if [[ -f "$SCRIPTS_DIRECTORY/../I18N" ]] && is_package_itself "$ROOT"; then
    # --staged 时本包是临时树，兄弟语言仓要从源仓的父目录找；不带 --staged 时不传参数，i18n-sync 按默认找兄弟目录。
    run_stage_may_skip "各语言同步" "本次无对象可判：本仓不是参照仓，或 languages= 里除了本仓没有别的语言（哪一种见上方它的输出）" \
      bash "$SCRIPTS_DIRECTORY/i18n-sync.sh" ${STAGED_FROM:+"$(dirname "$STAGED_FROM")"}
  fi
  # 版本纪律同样只判 SOP 仓自身：改了规范本体就必须抬 VERSION。
  if is_package_itself "$ROOT"; then
    run_stage_may_skip "版本纪律" "本次无对象可判：这一次的改动没碰规范本体（GOVERNED 的路径）" \
      bash "$SCRIPTS_DIRECTORY/version-discipline.sh" "$ROOT"
    # 抬了 VERSION 不等于记了账：几个语言仓的 CHANGELOG 可以一起跳过一版而别的阶段照绿。
    run_stage "CHANGELOG 连续" bash "$SCRIPTS_DIRECTORY/changelog-lint.sh" "$ROOT"
  fi
fi

# ── 未实现的验证手段：共享门禁带不了、要项目自己接的 ─────
# 键 → 缺的是什么。项目本地阶段在头部写 `# gate-covers: <键>`（一行一个，字面照抄键），
# 它这一轮跑了而且通过，汇总里这一项才换成「由哪个阶段覆盖」；跑红了、退 77 了，都照旧列在未实现里。
# 共享的键只有两个：「最终判据」不点名任何装置，准入标准由项目定；「命名纪律（shell）」是本包自己还没做成检查的那一半。
# 项目自己的验证手段（键由项目起名）登记在项目根 .claude/gate-not-implemented.tsv：
# 一行一条，制表符分隔：键、缺的是什么、覆盖之后仍要提醒的话（「覆盖之后仍要提醒的话」可空）；# 开头是注释。登记的键排在共享键前面；
# 少一列、键或说明为空、与共享键或前面的行重名都判红。没有这份文件就只有共享键。
NOT_IMPLEMENTED_SHARED_KEYS=("最终判据" "命名纪律（shell）")
declare -A NOT_IMPLEMENTED_SHARED_WHAT=(
  ["最终判据"]="准入标准：起什么环境、跑什么负载、注入什么故障由项目定，接在项目登记的门禁目录里（默认 .claude/gate.d/；rules/show-me-test.md「最终判据由项目定」）"
  ["命名纪律（shell）"]="只查 .rs 里声明的名字；.rs 以外的代码与文档里的名字、缩写、代称还没做成检查（rules/code-discipline.md）"
)
NOT_IMPLEMENTED_KEYS=()
declare -A NOT_IMPLEMENTED_WHAT=()
declare -A NOT_IMPLEMENTED_COVERED_REMINDER=()
PROJECT_NOT_IMPLEMENTED_FILE="$ROOT/.claude/gate-not-implemented.tsv"
project_not_implemented_problems=0
project_not_implemented_count=0
if [[ -f "$PROJECT_NOT_IMPLEMENTED_FILE" ]]; then
  while IFS= read -r project_not_implemented_line || [[ -n "$project_not_implemented_line" ]]; do
    [[ -z "${project_not_implemented_line//[[:space:]]/}" || "$project_not_implemented_line" == \#* ]] && continue
    # 按制表符逐列切，不用 IFS=$'\t' read：制表符是空白分隔符，连着两个会并成一个，「缺的是什么」空着时「覆盖之后仍要提醒的话」会被读成说明、这一行不判红
    project_not_implemented_what=""; project_not_implemented_reminder=""
    project_not_implemented_key="${project_not_implemented_line%%$'\t'*}"
    if [[ "$project_not_implemented_line" == *$'\t'* ]]; then
      project_not_implemented_rest="${project_not_implemented_line#*$'\t'}"
      project_not_implemented_what="${project_not_implemented_rest%%$'\t'*}"
      if [[ "$project_not_implemented_rest" == *$'\t'* ]]; then project_not_implemented_reminder="${project_not_implemented_rest#*$'\t'}"; fi
    fi
    if [[ -z "${project_not_implemented_key//[[:space:]]/}" || -z "${project_not_implemented_what//[[:space:]]/}" ]]; then
      bad "$PROJECT_NOT_IMPLEMENTED_FILE 里有一行少了键或说明：$project_not_implemented_line"
      howto "一行写成 键<制表符>缺的是什么<制表符>覆盖之后仍要提醒的话（「覆盖之后仍要提醒的话」可空），列之间用制表符，不用空格。"
      project_not_implemented_problems=$((project_not_implemented_problems+1)); continue
    fi
    if [[ -n "${NOT_IMPLEMENTED_SHARED_WHAT[$project_not_implemented_key]+x}" || -n "${NOT_IMPLEMENTED_WHAT[$project_not_implemented_key]+x}" ]]; then
      bad "$PROJECT_NOT_IMPLEMENTED_FILE 里的键「$project_not_implemented_key」与共享键或前面的行重名"
      howto "一个键只登记一处；共享键（${NOT_IMPLEMENTED_SHARED_KEYS[*]}）由本包带，项目不再登记。"
      project_not_implemented_problems=$((project_not_implemented_problems+1)); continue
    fi
    NOT_IMPLEMENTED_KEYS+=("$project_not_implemented_key")
    NOT_IMPLEMENTED_WHAT["$project_not_implemented_key"]="$project_not_implemented_what"
    NOT_IMPLEMENTED_COVERED_REMINDER["$project_not_implemented_key"]="${project_not_implemented_reminder:-}"
    project_not_implemented_count=$((project_not_implemented_count+1))
  done < "$PROJECT_NOT_IMPLEMENTED_FILE"
fi
for not_implemented_shared_key in "${NOT_IMPLEMENTED_SHARED_KEYS[@]}"; do
  NOT_IMPLEMENTED_KEYS+=("$not_implemented_shared_key")
  NOT_IMPLEMENTED_WHAT["$not_implemented_shared_key"]="${NOT_IMPLEMENTED_SHARED_WHAT[$not_implemented_shared_key]}"
done
if (( project_not_implemented_problems > 0 )); then
  record "项目登记的未实现手段" FAIL
elif [[ -f "$PROJECT_NOT_IMPLEMENTED_FILE" ]]; then
  ok "项目登记了 $project_not_implemented_count 项自己的验证手段（$PROJECT_NOT_IMPLEMENTED_FILE），并进未实现清单"
fi
declare -A COVERED_BY=()

# ── 项目本地阶段（项目登记的门禁目录下的阶段，默认 .claude/gate.d/）─────────
# 项目把自己的检查丢进这个目录，门禁按文件名排序逐个当阶段跑。两种形态过渡期并存：
# 扁平的 `<门禁目录>/<名>.sh`（旧形态），嵌套的 `<门禁目录>/<名>/<名>.sh`（新形态，同目录下的 `<用例>.case.sh` 是它的用例）。约定：
#   1. 目录不存在、或两种形态一个阶段都没有 ⇒ 说「项目没有本地阶段」，不记阶段——那不是「通过」，是「没有」
#   2. 脚本存在但跑不起来（没有执行位、语法错、找不到解释器）⇒ 判红，不当成跳过
#   3. 阶段名取脚本头部的 `# gate-stage: <名字>`，没写就用文件名（嵌套形态用目录名，与文件名相同）
#   4. 退出码 77 = 这一轮无对象可判 ⇒ 记「本次未跑」，不记通过
#   5. 头部 `# gate-covers: <键>` 声明它覆盖未实现清单里的哪一项；只有这一轮通过才算数，键写错判红
head1 "项目本地阶段"
LOCAL_STAGE_FILES=()
if [[ -d "$PROJECT_GATE_DIRECTORY" ]]; then
  while IFS= read -r local_stage_file; do [[ -n "$local_stage_file" ]] && LOCAL_STAGE_FILES+=("$local_stage_file"); done \
    < <(find "$PROJECT_GATE_DIRECTORY" -maxdepth 1 -name '*.sh' \( -type f -o -type l \) | sort)
  while IFS= read -r local_stage_file; do
    [[ -n "$local_stage_file" ]] || continue
    [[ "$(basename "$(dirname "$local_stage_file")")" == "$(basename "$local_stage_file" .sh)" ]] && LOCAL_STAGE_FILES+=("$local_stage_file")
  done < <(find "$PROJECT_GATE_DIRECTORY" -mindepth 2 -maxdepth 2 -name '*.sh' \( -type f -o -type l \) | sort)
  # 两种形态各自排过序，合起来按阶段名重排一遍：阶段按文件名顺序跑是约定好的，形态混在一起也要守。
  if ((${#LOCAL_STAGE_FILES[@]})); then
    mapfile -t LOCAL_STAGE_FILES < <(for local_stage_file in "${LOCAL_STAGE_FILES[@]}"; do printf '%s\t%s\n' "$(basename "$local_stage_file" .sh)" "$local_stage_file"; done | sort | cut -f2-)
  fi
fi
if [[ ${#LOCAL_STAGE_FILES[@]} -eq 0 ]]; then
  ok "项目没有本地阶段（$PROJECT_GATE_DIRECTORY 不存在，扁平的 *.sh 与嵌套的 <名>/<名>.sh 都没有）"
else
  ok "发现 ${#LOCAL_STAGE_FILES[@]} 个本地阶段，按文件名顺序跑"
  for local_stage_file in "${LOCAL_STAGE_FILES[@]}"; do
    # 可读性判断必须排在读取之前：读不了的脚本会让 sed 在 set -e + pipefail 下把整个门禁带走，
    # 汇总一行都不打印，看不出是哪一步、也看不出别的阶段过没过。
    if [[ ! -r "$local_stage_file" ]]; then
      head1 "$(basename "$local_stage_file" .sh)"
      bad "读不了 $local_stage_file"
      howto "检查该文件的读权限，或把它从 $PROJECT_GATE_DIRECTORY 拿掉。读不到不等于通过，本阶段按失败记。"
      record "$(basename "$local_stage_file" .sh)" FAIL
      continue
    fi
    # 取阶段名。读得到才走到这里，但仍然兜一层——名字取不到不该让门禁失去汇总。
    local_stage_name="$(sed -n 's/^# gate-stage:[[:space:]]*//p' "$local_stage_file" 2>/dev/null | head -1 || true)"
    [[ -n "$local_stage_name" ]] || local_stage_name="$(basename "$local_stage_file" .sh)"
    covered_keys=()
    while IFS= read -r covered_key; do
      if [[ -n "$covered_key" ]]; then covered_keys+=("$covered_key"); fi
    done < <(sed -n 's/^# gate-covers:[[:space:]]*//p' "$local_stage_file" 2>/dev/null | sed 's/[[:space:]]*$//' || true)
    head1 "$local_stage_name"
    # 条件不满足就不起它；强制跑过的不算覆盖了清单里的哪一项（rules/preflight-discipline.md）
    local_stage_exit_code=0; stage_counts_as_coverage=0
    if stage_admitted "$local_stage_name" "$local_stage_file" "$ROOT"; then
      if [[ -z "$STAGE_FORCED_SUMMARY" ]]; then stage_counts_as_coverage=1; fi
      GATE_IN_STAGE=1 bash "$local_stage_file" "$ROOT" ${STAGE_FORCE_OPTION[@]+"${STAGE_FORCE_OPTION[@]}"} || local_stage_exit_code=$?
      record_stage "$local_stage_name" "$local_stage_exit_code" 77 "本次未跑：阶段报了这一轮无对象可判（退出码 77），原因见上方它的输出"
      # 只跑了一部分（报过本次未跑）的，覆盖到哪说不清，不算覆盖
      if [[ $local_stage_exit_code -ne 0 || $STAGE_REPORTED_NOT_RUN -eq 1 ]]; then stage_counts_as_coverage=0; fi
    fi
    unknown_keys=()
    for covered_key in "${covered_keys[@]}"; do
      if [[ -z "${NOT_IMPLEMENTED_WHAT[$covered_key]+set}" ]]; then
        unknown_keys+=("$covered_key")
      elif [[ $stage_counts_as_coverage -eq 1 ]]; then
        COVERED_BY["$covered_key"]+="${COVERED_BY[$covered_key]:+、}$local_stage_name"
      fi
    done
    if [[ ${#unknown_keys[@]} -gt 0 ]]; then
      bad "$local_stage_name 的 gate-covers 写了清单里没有的项：$(printf '「%s」' "${unknown_keys[@]}")"
      howto "只认这几个键，一行一个，字面照抄：$(printf '「%s」' "${NOT_IMPLEMENTED_KEYS[@]}")" \
            "写错一个字，那一项就一直列在未实现里，而写的人以为已经覆盖了。"
      record "覆盖声明（$local_stage_name）" FAIL
    fi
  done
fi

# ── 跑的过程中工作区变没变 ───────────────────────────
# 门禁的结论只对它读到的那一版成立。跑的过程中有人改文件（自己还在改，或别的会话在改），
# 前面的阶段读旧版、后面的阶段读新版，汇总出来的红绿不对应任何一版，而输出里看不出来。
END_WORKTREE_FINGERPRINT="$(worktree_fingerprint "$ROOT")"
if [[ -z "$START_WORKTREE_FINGERPRINT" || -z "$END_WORKTREE_FINGERPRINT" ]]; then
  NOT_RUN+=("工作区跑的过程中没变  本次未检查：不是 git 仓，或取不到工作区指纹")
else
  head1 "工作区跑的过程中没变"
  if [[ "$START_WORKTREE_FINGERPRINT" == "$END_WORKTREE_FINGERPRINT" ]]; then
    ok "开跑与收尾的工作区指纹相同（${START_WORKTREE_FINGERPRINT:0:12}）：各阶段读到的是同一版"
    record "工作区跑的过程中没变" PASS
  else
    bad "门禁跑的这段时间里工作区变了（开跑 ${START_WORKTREE_FINGERPRINT:0:12}，收尾 ${END_WORKTREE_FINGERPRINT:0:12}）：各阶段读到的不一定是同一版，这一轮的结论不对应任何一版"
    howto "等自己与别的会话的改动都停下再跑一遍；几个会话共写一个仓时跑 bash .claude/scripts/gate.sh --staged，它在临时 worktree 上跑一个不会被人改的快照。"
    record "工作区跑的过程中没变" FAIL
  fi
fi

# ── 这一轮建的临时文件，跑完删了没有 ─────────────────
# 判据见 rules/command-safety.md「测试镜像一律放临时目录」：别的阶段都绿时剩下的判红，由 gate_exit_guard 替它们删掉；
# 有阶段判红时它可能按设计把现场留在里面，这一项记本次未判，这一轮的临时目录整个留着。
head1 "跑完没留下临时文件"
leftover_entries=()
while IFS= read -r -d '' leftover_entry; do leftover_entries+=("$leftover_entry"); done \
  < <(find "$GATE_RUN_TMPDIR" -mindepth 1 -maxdepth 1 ! -name "$GATE_NOT_RUN_FILE_NAME" -print0 | sort -z)
stages_failed_before_this_one=0
for stage_result in "${RESULTS[@]}"; do [[ "$stage_result" == PASS || "$stage_result" == FORCED ]] || stages_failed_before_this_one=$((stages_failed_before_this_one + 1)); done
list_leftover_entries() { # 实占 / 标称大小（稀疏的盘镜像两个数差得远）与名字
  for leftover_entry in "${leftover_entries[@]}"; do
    say "        $(du -sh -- "$leftover_entry" | cut -f1) / $(du -sh --apparent-size -- "$leftover_entry" | cut -f1)  ${leftover_entry##*/}"
  done
}
if [[ ${#leftover_entries[@]} -eq 0 ]]; then
  ok "这一轮各阶段在 TMPDIR 里建的东西，跑完都删了（剩 ${#leftover_entries[@]} 项）"
  record "跑完没留下临时文件" PASS
elif [[ $stages_failed_before_this_one -gt 0 ]]; then
  GATE_RUN_TMPDIR_KEPT=1
  warn "这一轮有 $stages_failed_before_this_one 个阶段判红，这一项不判：TMPDIR 里剩的 ${#leftover_entries[@]} 项可能是它们留的现场（实占 / 标称大小）："
  list_leftover_entries
  warn "这一轮的临时目录整个留着，看完自己删： rm -rf $GATE_RUN_TMPDIR"
  NOT_RUN+=("跑完没留下临时文件  本次未判：有阶段判红，剩下的 ${#leftover_entries[@]} 项可能是它留的现场；临时目录留在 $GATE_RUN_TMPDIR")
else
  bad "这一轮各阶段在 TMPDIR（$GATE_RUN_TMPDIR）里建了、跑完没删的有 ${#leftover_entries[@]} 项（实占 / 标称大小；门禁退出时替它们删掉）："
  list_leftover_entries
  howto "按名字找到建它的阶段或测试装置，让它在跑完时自己删：成功、失败、panic 都删（Rust 用 Drop 守卫，shell 用 trap … EXIT）。" \
        "有意跨轮复用的缓存放 \${GATE_CROSS_RUN_TMPDIR:-\${TMPDIR:-/tmp}}（门禁里是这一轮开跑前的临时目录，门禁不管那里），别放 \$TMPDIR。" \
        "规矩见 rules/command-safety.md「测试镜像一律放临时目录」。"
  record "跑完没留下临时文件" FAIL
fi
# 判红时留下的：这一轮留的记上标记；连同这个项目根之前留着的按留下的时刻排，只留最近几个，更早的删掉，剩下的每一轮都列出来
if [[ "$GATE_RUN_TMPDIR_KEPT" == 1 ]]; then
  printf '%s\t%s\n' "$(date +%s.%N)" "$GATE_PROJECT_ROOT_PHYSICAL" > "$GATE_RUN_TMPDIR/$KEPT_RUN_DIRECTORY_MARKER"
fi
kept_run_directories=()
while IFS= read -r kept_line; do kept_run_directories+=("${kept_line#* }"); done < <(
  for kept_marker in "$GATE_RUN_PARENT_DIRECTORY"/gate-run.*/"$KEPT_RUN_DIRECTORY_MARKER"; do
    [[ -f "$kept_marker" ]] || continue
    kept_time=''; kept_root=''
    IFS=$'\t' read -r kept_time kept_root < "$kept_marker" || true
    if [[ "$kept_root" == "$GATE_PROJECT_ROOT_PHYSICAL" ]]; then printf '%s %s\n' "$kept_time" "${kept_marker%/*}"; fi
  done | sort -rn)
if [[ ${#kept_run_directories[@]} -gt $KEPT_RUN_DIRECTORY_LIMIT ]]; then
  for older_kept_directory in "${kept_run_directories[@]:KEPT_RUN_DIRECTORY_LIMIT}"; do
    warn "判红时留下的临时目录只留最近 $KEPT_RUN_DIRECTORY_LIMIT 个，删掉更早的：$(du -sh -- "$older_kept_directory" 2>/dev/null | cut -f1)  $older_kept_directory"
    older_kept_marker_line="$(head -1 "$older_kept_directory/$KEPT_RUN_DIRECTORY_MARKER" 2>/dev/null || true)"
    # 删不掉（权限、挂载点）只报，门禁接着往下走；标记原样写回，之后每一轮照样列出来、再试
    if ! rm -rf --one-file-system -- "${older_kept_directory:?}" 2>/dev/null; then
      printf '%s\n' "$older_kept_marker_line" > "$older_kept_directory/$KEPT_RUN_DIRECTORY_MARKER" 2>/dev/null || true
      warn "删不掉（权限或挂载点），留着，自己看一眼再删： $older_kept_directory"
    fi
  done
  kept_run_directories=("${kept_run_directories[@]:0:KEPT_RUN_DIRECTORY_LIMIT}")
fi
for kept_run_directory in "${kept_run_directories[@]}"; do
  if [[ "$kept_run_directory" != "$GATE_RUN_TMPDIR" ]]; then warn "之前判红时留下的临时目录还在，看完删掉： rm -rf $kept_run_directory"; fi
done

# ── 汇总 ────────────────────────────────────────────────
GATE_SUMMARY_PRINTED=1
head1 "门禁结果"
failed_stage_count=0; forced_stage_count=0
for stage_index in "${!STAGES[@]}"; do
  case "${RESULTS[$stage_index]}" in
    PASS)   ok "${STAGES[$stage_index]}" ;;
    FORCED) warn "${STAGES[$stage_index]}（强制跑过：条件没满足，带 --force 照跑的，不记通过）"; forced_stage_count=$((forced_stage_count+1)) ;;
    *)      bad "${STAGES[$stage_index]}"; failed_stage_count=$((failed_stage_count+1)) ;;
  esac
done
[[ $failed_stage_count -eq 0 ]] || howto "红色阶段的细节与出路在上方对应段落里，按那里的「怎么办」执行，修完重跑。"

if [[ ${#NOT_RUN[@]} -gt 0 ]]; then
  printf '\n%s本次未跑的阶段：%s\n' "$C_YEL" "$C_RST"
  for not_run_entry in "${NOT_RUN[@]}"; do warn "$not_run_entry"; done
fi

printf '\n%s未实现的门禁阶段（绿色不代表验证充分）：%s\n' "$C_YEL" "$C_RST"
uncovered_count=0
for extra_not_implemented_entry in ${EXTRA_NOT_IMPLEMENTED[@]+"${EXTRA_NOT_IMPLEMENTED[@]}"}; do warn "$extra_not_implemented_entry"; uncovered_count=$((uncovered_count+1)); done
for listed_key in "${NOT_IMPLEMENTED_KEYS[@]}"; do
  if [[ -z "${COVERED_BY[$listed_key]:-}" ]]; then warn "$listed_key：${NOT_IMPLEMENTED_WHAT[$listed_key]}"; uncovered_count=$((uncovered_count+1)); fi
done
if [[ $uncovered_count -eq 0 ]]; then ok "清单里每一项都有项目阶段覆盖，见下"; fi
if [[ ${#COVERED_BY[@]} -gt 0 ]]; then
  printf '\n%s由项目本地阶段覆盖（这一轮跑过且通过；覆盖到多大范围，看那个阶段自己的说明）：%s\n' "$C_YEL" "$C_RST"
  for listed_key in "${NOT_IMPLEMENTED_KEYS[@]}"; do
    if [[ -n "${COVERED_BY[$listed_key]:-}" ]]; then ok "$listed_key ← ${COVERED_BY[$listed_key]}"; fi
  done
fi

say ""
if [[ $failed_stage_count -gt 0 ]]; then
  bad "门禁未通过：$failed_stage_count 个阶段失败"   # gate-lint:summary
  exit 1
fi
# 记下「门禁在这里通过过」，下一轮的 diff 基准优先取它：上次过闸之后的所有改动都要过闸，
# 没有这个标记时窗口只有一格，分两次提交就能把改代码的那次挤出去。
# 记的是开跑时的 HEAD：跑完再解析一次的话，另一个会话在这一轮跑的过程中提交的那个没验过的提交会被一并盖章。
# GATE_BASE 被显式指定时不记（--staged 的里层也走这一支）：窗口是人为收窄的，拿它当起点会把中间的提交漏掉；
# 不记只会让下一轮的窗口更宽，不会更窄。有阶段强制跑过也不记：那些阶段该判的窗口要留给下一轮。
if [[ ${#GATE_OK_HELD_BY[@]} -gt 0 ]]; then
  warn "这一轮不前移 gate-ok：$(IFS='、'; printf '%s' "${GATE_OK_HELD_BY[*]}")"
  howto "这些阶段是在条件不满足时强制跑的，它们的 diff 窗口留给下一轮；条件补齐之后不带 --force 再跑一遍。"
elif [[ -n "$START_HEAD" && -z "${GATE_BASE:-}" ]]; then
  head_at_end="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || true)"
  if [[ -n "$head_at_end" && "$head_at_end" != "$START_HEAD" ]]; then
    warn "跑的过程中 HEAD 变了（${START_HEAD:0:7} → ${head_at_end:0:7}）：gate-ok 只记到开跑时那个提交"
    howto "那之后的提交没在这一轮验过，要它们过闸就再跑一遍门禁。"
  fi
  # 写不进去不判红（后果只是下一轮的窗口更宽，不会漏判），但要说出来：吞掉的话，人以为窗口已经前移了
  if ! git -C "$ROOT" update-ref refs/sop/gate-ok "$START_HEAD" 2>/dev/null; then
    warn "gate-ok 没写进去（git update-ref 失败）：下一轮的 diff 窗口照旧从上一次写成的那一点起算，只会更宽、不会漏判"
    warn "  看一眼 $ROOT 的 git 目录能不能写（权限、磁盘、refs/sop 是不是被一个同名文件占了），修好之后跑绿一次它就前移"
  fi
fi
if [[ $forced_stage_count -gt 0 ]]; then
  warn "没有阶段判红，但 $forced_stage_count 个阶段是强制跑的（跑了 ${#STAGES[@]} 个）：这一轮不算「全部通过」"
else
  ok "已实现的门禁阶段全部通过（共 ${#STAGES[@]} 个）"
fi
warn "Gate proves evidence requirements, not semantic correctness."
warn "门禁证明的是证据要求被满足，不是代码语义正确——绿灯之后仍要看「测的是不是对的东西」。"
# 项目登记的手段里带「覆盖之后仍要提醒的话」的，收尾照打：有阶段覆盖就提醒它只说到那个阶段验到的范围，没有就说这一轮的绿不包含它
for not_implemented_key in "${NOT_IMPLEMENTED_KEYS[@]}"; do
  not_implemented_reminder="${NOT_IMPLEMENTED_COVERED_REMINDER[$not_implemented_key]:-}"
  [[ -n "$not_implemented_reminder" ]] || continue
  if [[ -n "${COVERED_BY[$not_implemented_key]:-}" ]]; then
    warn "另：${not_implemented_key}由「${COVERED_BY[$not_implemented_key]}」覆盖，${not_implemented_reminder}"
  else
    warn "另：${not_implemented_key}还没有项目阶段覆盖，这一轮的绿不包含它。"
  fi
done
