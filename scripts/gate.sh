#!/usr/bin/env bash
# 准入门禁。rules/show-me-test.md的可执行形式。
#
# 设计原则：
#   1. 未实现的阶段**显式报告为未实现**，绝不静默跳过（第一节第 5 条）
#   2. 任何阶段都能失败——不存在只会成功的检查
#   3. 退出码：0 = 全部已实现阶段通过；非 0 = 有阶段失败
#
# 注意：共享阶段不覆盖崩溃一致性，要靠项目本地阶段接上并声明（# gate-covers:）。绿色不等于验证充分，见文末未实现清单。
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 从 git 钩子里跑时，git 设了 GIT_DIR / GIT_INDEX_FILE 这一组，它们压过 `git -C`：
# --staged 的 worktree add 会失败，而报出来的出路是「先跑 git worktree prune」，指的方向是错的（审计实测）。
# push-all.sh 早就清这一组，gate.sh 没清。
# shellcheck disable=SC2046
unset $(git rev-parse --local-env-vars 2>/dev/null) 2>/dev/null || true
# 包自己的根，按物理路径算。判「被门禁的是不是 SOP 仓自身」时两边都要 pwd -P：
# 只比 pwd 的话，经符号链接跑就判成消费项目——报「缺版本戳」判红，只在 SOP 仓跑的三个阶段还静默不跑（审计实测）。
PKG_DIR="$(cd "$SCRIPTS/.." && pwd -P)"
is_pkg_itself() { [[ "$(cd "$1" 2>/dev/null && pwd -P)" == "$PKG_DIR" ]]; }
# 族名（.claude/<族名>/ 那一段）。定义要排在第一处用到它的地方之前：
# 「规范版本不一致」的 howto 里就有它，而它此前定义在几十行之后，set -u 下那条拒绝一出口就是 unbound variable。
fam="$(sed -n 's/^family=//p' "$SCRIPTS/../I18N" 2>/dev/null || echo singlefs-ai-sop)"

# ── 参数：项目根与 --staged，顺序不限 ─────────────────────
# 不许写死「$1 == --staged」：项目里的包装脚本（install.sh 的 WRAP）把项目根放在 $1、用户的参数接在后面，
# 于是文档推荐的 `bash .claude/scripts/gate.sh --staged` 实际收到的是 `gate.sh <项目根> --staged`，
# --staged 落在没人读的 $2，门禁照常跑**工作区**，而且一声不响（审计实测：包装带 --staged 时
# 「只拿 HEAD + 暂存区跑」一次都没出现，别的会话没暂存的违规照样判红）。
GATE_ROOT_ARGS=(); WANT_STAGED=0
for gate_arg in "$@"; do
  case "$gate_arg" in
    --staged) WANT_STAGED=1 ;;
    -*)       die "认不出的参数：$gate_arg" "用法： gate.sh [项目根] [--staged]" ;;
    *)        GATE_ROOT_ARGS+=("$gate_arg") ;;
  esac
done
[[ ${#GATE_ROOT_ARGS[@]} -le 1 ]] || die "只收一个项目根，收到 ${#GATE_ROOT_ARGS[@]} 个：${GATE_ROOT_ARGS[*]}" \
  "用法： gate.sh [项目根] [--staged]"
set -- ${GATE_ROOT_ARGS[@]+"${GATE_ROOT_ARGS[@]}"}

# ── --staged：只拿「HEAD + 暂存区」跑整道门禁 ─────────────
# 几个会话共写一个仓时，工作区里混着别人没收尾的改动与未跟踪文件，门禁在工作区上判的红分不清是谁的
# （rules/session-wrapup.md 第 4 条）。这里在临时 worktree 上把 `git diff --cached` 套到 HEAD 上，
# 再对那棵树跑一遍整道门禁：别人的未提交改动与未跟踪文件都不进来，红的就是这一次提交带进来的。
# 规范副本不进 git 时（项目常把 .claude/<包名>/ 放进 .gitignore）原样拷进 worktree，否则项目里的包装脚本转发不到。
# worktree 里的构建从零开始；要复用构建产物，自己设 CARGO_TARGET_DIR 之类的环境变量。
if [[ $WANT_STAGED -eq 1 ]]; then
  src_root="$(cd "${1:-$(project_root)}" 2>/dev/null && pwd)" || die "找不到项目根：${1:-当前目录}" \
    "在项目根跑，或把它作为第二个参数传进来： bash .claude/scripts/gate.sh --staged <项目根>"
  git -C "$src_root" rev-parse --git-dir >/dev/null 2>&1 || die "--staged 要在 git 仓里跑，而 $src_root 不是" \
    "去掉 --staged 直接跑，或者到仓里再跑。"
  staged_base="$(mktemp -d)"; staged_tree="$staged_base/tree"
  if ! git -C "$src_root" diff --cached --binary > "$staged_base/staged.patch"; then
    rm -rf "${staged_base:?}"; die "取不到暂存区的 diff" "确认 git 可用，再跑一次。"
  fi
  if ! staged_add_err="$(git -C "$src_root" worktree add --detach "$staged_tree" HEAD 2>&1)"; then
    rm -rf "${staged_base:?}"
    printf '%s\n' "$staged_add_err" | sed 's/^/        /'
    die "建临时 worktree 失败（git 的原话在上面）" \
      "常见的三种：仓里还没有任何提交；从 git 钩子里跑（那一组 GIT_* 压过 -C，本脚本开头已清）；有残留的登记。" \
      "残留用 git -C $src_root worktree remove --force <路径> 删——prune 清不掉 \$TMPDIR 里还在的那个目录。"
  fi
  # 跑到一半被打断（Ctrl-C）或被杀时也要删掉临时 worktree：留下的会一直登记在仓里，下一次还得手工 git worktree prune。
  # 两次跑不会出错：worktree 已经删掉时 git 那句被吞掉，rm -rf 一个不存在的目录也不报错。
  staged_cleanup() { git -C "$src_root" worktree remove --force "$staged_tree" >/dev/null 2>&1; rm -rf "${staged_base:?}"; }
  # EXIT 兜底：worktree 建起来之后，中间任何一处退出（die、set -e 打断的、下面那两处 die）
  # 都靠这一个 trap 把临时 worktree 带走。**别在 die 之前再手工清一次**——
  # 手工清那一份会让「删掉 EXIT 兜底」这个变异检测不到：每条 die 路径都自己清干净了，
  # 兜底有没有都一样，于是盯着它的用例一声不吭（第一版实测）。清理只留这一处。
  trap 'staged_cleanup' EXIT
  trap 'staged_cleanup; exit 130' INT
  trap 'staged_cleanup; exit 143' TERM
  if [[ -s "$staged_base/staged.patch" ]] && ! git -C "$staged_tree" apply --index "$staged_base/staged.patch"; then
    die "暂存区的 diff 套不上 HEAD" "先 git status 看暂存区是不是基于当前 HEAD，再跑一次。"
  fi
  staged_family="$(sed -n 's/^family=//p' "$SCRIPTS/../I18N" 2>/dev/null || true)"; staged_family="${staged_family:-singlefs-ai-sop}"
  if [[ -d "$src_root/.claude/$staged_family" && ! -d "$staged_tree/.claude/$staged_family" ]]; then
    mkdir -p "$staged_tree/.claude"; cp -r "$src_root/.claude/$staged_family" "$staged_tree/.claude/"
  fi
  # diff 基准在源仓上算好再传进去。临时树是 detached HEAD，@{upstream} 解析不到，里层自己算会落到 HEAD~1，
  # 比直接跑窄一档：「分两次提交就绕过去」那条口子在 --staged 这边开着（实测：直接跑基准是 origin/master，--staged 是 HEAD~1）。
  staged_diff_base="${GATE_BASE:-$(diff_base "$src_root")}"
  # 被门禁的是 SOP 仓自身时，里层要跑临时树里那份脚本：跑源仓的 $SCRIPTS 会让里层把临时树当成消费项目，
  # 报「缺版本戳」判红，只在 SOP 仓跑的三个阶段还静默不跑（实测）。
  if is_pkg_itself "$src_root"; then staged_gate="$staged_tree/scripts/gate.sh"; else staged_gate="$SCRIPTS/gate.sh"; fi
  if [[ ! -f "$staged_gate" ]]; then
    die "临时树里没有 scripts/gate.sh（$staged_gate）" "暂存区是不是把 scripts/gate.sh 删了？先把它恢复进暂存区再跑。"
  fi
  head1 "只拿 HEAD + 暂存区跑（--staged）"
  ok "临时 worktree：$staged_tree（跑完删掉）"
  ok "不进这一轮的：工作区里没暂存的 $(git -C "$src_root" diff --name-only | wc -l) 个文件、未跟踪的 $(git -C "$src_root" ls-files --others --exclude-standard | wc -l) 个文件"
  ok "diff 基准 $staged_diff_base（在源仓上算的，与不带 --staged 时相同）"
  # 退出码要在 if 里取：lib.sh 开着 set -e，写成「里层; staged_rc=$?」的话，里层一判红外层就在这一行退出，
  # 下面的清理走不到，每次判红都在仓里留下一个临时 worktree——而判红正是最要看结果的时候（0.0.48 收尾时实测）。
  if GATE_BASE="$staged_diff_base" GATE_STAGED_FROM="$src_root" bash "$staged_gate" "$staged_tree"; then staged_rc=0; else staged_rc=$?; fi
  trap - INT TERM EXIT
  staged_cleanup
  exit "$staged_rc"
fi
# --staged 的握手变量只在这一层用：读进本地变量就从环境里拿掉，不再往下传。
# 传下去的话，selftest 嵌套跑的 gate.sh 与项目本地阶段都会拿它当自己的项目根去找兄弟目录
# （实测：--staged 里 selftest 的「上游比副本旧」两例反红）。GATE_BASE 不能在这里拿掉：
# show-me-test 与版本纪律要读它；由 selftest 自己在起子进程时清。
STAGED_FROM="${GATE_STAGED_FROM:-}"; unset GATE_STAGED_FROM
ROOT="${1:-$(project_root)}"
[[ -d "$ROOT" ]] || die "找不到项目根：$ROOT" \
  "在项目根跑，或把它作为第一个参数传进来： bash .claude/scripts/gate.sh <项目根>"
cd "$ROOT"
# 开跑时的 HEAD。gate-ok 记的是它，不是跑完时的 HEAD——见文末。
START_HEAD="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || true)"
# 开跑时的工作区指纹。汇总之前再算一次，对不上说明这一轮各阶段读到的不是同一版——见「门禁结果」前面那一段。
START_TREE="$(worktree_fingerprint "$ROOT")"

# 这一轮的 diff 基准算一次，导给每个阶段（含项目本地阶段）。
# 此前只有 show-me-test 自己算，项目本地阶段各按各的口径取基准：同一轮里两个阶段判的不是同一批改动，
# 而它们的注释都写着「与 Show me test 同一套口径」（审计实测于 singlefs 的 61 号阶段）。
# 与 GATE_BASE 分成两个名字：GATE_BASE 的含义是「人指定了窗口」，文末 gate-ok 那一条要靠它区分。
# 不写成 `export X="$(…)"`：export 是内建命令，它会把命令替换的退出码吞掉，
# GATE_BASE 写错时 diff_base 的拒绝就传不出来（command-safety.md 里「子 shell 赋值」的同族）。
GATE_DIFF_BASE="$(diff_base "$ROOT")"
export GATE_DIFF_BASE

STAGES=(); RESULTS=(); NOT_RUN=()
record() { STAGES+=("$1"); RESULTS+=("$2"); }

run_stage() { # run_stage <名称> <命令...>
  local name="$1"; shift
  head1 "$name"
  # GATE_IN_STAGE：告诉子脚本标题已经打过了，别再打同名的一遍
  if GATE_IN_STAGE=1 "$@"; then record "$name" PASS; else record "$name" FAIL; fi
}

# ── 阶段 0：规范版本一致性 ───────────────────────────────
head1 "规范版本"
# 版本戳是给消费项目用的；SOP 仓自身没有也不该有。判据同「各语言同步」：
# 被门禁的 ROOT 是不是 SOP 仓本身。
if is_pkg_itself "$ROOT"; then
  ok "本仓即 SOP 本身，无需版本戳"
  record "规范版本" PASS
else
pkg_ver="$(cat "$SCRIPTS/../VERSION" 2>/dev/null || echo "?")"
proj_ver="$(cat "$ROOT/.singlefs-ai-sop-version" 2>/dev/null || echo "")"
if [[ -z "$proj_ver" ]]; then
  # 这是拒绝，不是提醒：记的是 FAIL，就得带出路。此前用 warn 打、没有 howto，gate-lint 只认 bad / die / ✗，看不见它（审计实测）。
  bad "项目未声明规范版本（缺 .singlefs-ai-sop-version）"
  howto "在项目根跑 bash .claude/singlefs-ai-sop/install.sh，它会写出 .singlefs-ai-sop-version；没装过就先装。" \
        "版本戳是项目唯一的「规矩变了」信号，缺了它门禁不知道该按哪一版判。"
  record "规范版本" FAIL
elif [[ "$proj_ver" != "$pkg_ver" ]]; then
  bad "规范版本不一致：项目声明 $proj_ver，singlefs-ai-sop 是 $pkg_ver"
  howto "先读一遍上游这几版改了什么：.claude/$fam/CHANGELOG.md 顶部，或者到兄弟目录的上游仓里 git log。" \
        "副本是普通目录拷贝、里面没有 .git，在它上面跑 git log 只会得到一句「不是 git 仓库」。" \
        "确认没有影响你这次改动，再跑 bash .claude/$fam/install.sh 更新版本戳。"
  record "规范版本" FAIL
else
  ok "规范版本 $pkg_ver"
  record "规范版本" PASS
fi

# 版本戳与副本一致，只证明「装的时候是这个版本」——证明不了「副本还是上游最新」。
# 上游在兄弟目录时顺手比一下；比不了就**显式报未检查**，不静默放过。
#
# ⚠️ 先钉一件事：这里的 $pkg_ver 是**正在跑的这份门禁**所属包的版本，
# 不一定是项目里装的那份副本。两者不同时（例如有人直接跑了上游那份 gate.sh），
# 这条检查测的就不是它名字说的东西——那种情况必须判红，不能让它绿着糊弄过去。
up_ver=""; up_dir=""
for lang in $(sed -n 's/^languages=//p' "$SCRIPTS/../I18N" 2>/dev/null); do
  # --staged 时 ROOT 是临时 worktree，兄弟目录要从原来的项目根找
  cand="$(cd "${STAGED_FROM:-$ROOT}/.." 2>/dev/null && pwd)/$fam-$lang"
  if [[ -f "$cand/VERSION" ]]; then up_ver="$(cat "$cand/VERSION")"; up_dir="$cand"; break; fi
done
inst_ver="$(cat "$ROOT/.claude/$fam/VERSION" 2>/dev/null || echo "")"
if [[ -n "$inst_ver" && "$inst_ver" != "$pkg_ver" ]]; then
  bad "跑的不是项目里那份副本：本门禁来自 $pkg_ver 的包，项目副本是 $inst_ver"
  howto "这条检查比的是「跑的这份包」与上游，测不到项目副本。" \
        "请改跑 bash .claude/scripts/gate.sh（它转发到项目副本），再看这一项。"
  record "副本与上游同版本" FAIL
elif [[ -z "$up_ver" ]]; then
  warn "未检查副本是否落后上游：兄弟目录里没找到上游仓"
  howto "上游仓不在兄弟目录时这一项查不了，属于**未检查**不是通过。" \
        "要查就把上游 clone 到 $(cd "$ROOT/.." 2>/dev/null && pwd)/$fam-<语言> 再跑。"
  # 只在这里 warn 一句是不够的：末尾汇总会报「N 个阶段全部通过」，
  # 而这一项既不在通过列表里也不在未跑列表里——它就这么从结论里消失了
  # （本轮审计实测）。设计原则第 1 条要求显式报告，汇总才是人会看的那一处。
  NOT_RUN+=("副本与上游同版本    本次未检查：兄弟目录里没有上游仓。clone 到 $(cd "$ROOT/.." 2>/dev/null && pwd)/$fam-<语言> 再跑")
elif [[ "$up_ver" != "$pkg_ver" && "$(printf '%s\n' "$up_ver" "$pkg_ver" | sort -V | tail -1)" == "$pkg_ver" ]]; then
  # 副本比上游新：兄弟目录里的上游仓没更新到这一版（没拉，或者副本是从一份还没提交的上游拷的）。
  # 出路与「落后」相反；报成「落后」会把人支去重拷副本，拷回来的是旧版（0.0.48 收尾时实测）。
  bad "上游比副本旧：副本 $pkg_ver，上游 $up_ver（$up_dir）"
  howto "兄弟目录里的上游仓还停在旧版：它没更新（git -C $up_dir pull），" \
        "或者副本是从一份还没提交的上游拷过来的——先把上游那一版提交，再跑这一项。" \
        "别把副本退回旧版去凑齐：副本里的规矩才是这个项目现在守的。"
  record "副本与上游同版本" FAIL
elif [[ "$up_ver" != "$pkg_ver" ]]; then
  bad "副本落后上游：副本 $pkg_ver，上游 $up_ver（$up_dir）"
  howto "副本是拷贝不是链接，上游抬了版本副本不会自己跟。" \
        "先读 cd $up_dir && git log 看改了什么，" \
        "再重新拷贝一份副本，然后跑 bash .claude/$fam/install.sh 刷版本戳。"
  record "副本与上游同版本" FAIL
else
  ok "副本与上游同版本 $up_ver"
  record "副本与上游同版本" PASS
fi
fi

# ── 阶段 0b：门禁自身（每条拒绝都要给出路）──────────────
# 项目本地阶段（.claude/gate.d/）也交给两个 lint：它们和共享阶段一样会拒绝提交者，
# 而此前一条都没被查过——一喂就是 7 条没有出路的拒绝（singlefs 实测）。
LINT_EXTRA=(); [[ -d "$ROOT/.claude/gate.d" ]] && LINT_EXTRA=("$ROOT/.claude/gate.d")
run_stage "门禁自检" bash "$SCRIPTS/gate-lint.sh" "${LINT_EXTRA[@]}"
# 每条拒绝有没有出路是一回事，检查本身红不红得起来是另一回事。
# 后者靠样本证明（rules/sop-first.md：没有自检能力的门禁是摆设）。
run_stage "门禁判别力" bash "$SCRIPTS/selftest.sh"
# command-safety.md 里可机检的那五条：pkill -f / killall、pgrep -f、子 shell 赋值往外带值、git 的撤销命令、无守卫的 rm -rf。
# 做成检查的起因：一个测试装置违反了其中一条整整一轮，而那条纪律当时只是文档里的提醒句。
run_stage "shell 纪律" bash "$SCRIPTS/shell-lint.sh" "${LINT_EXTRA[@]}"

# ── 阶段 1：文档铁律 ────────────────────────────────────
run_stage "文档铁律" bash "$SCRIPTS/doc-lint.sh" "$ROOT"
# 本语言没有词表时，doc-lint 里那几条检查是**没实现**，不是通过。它自己报得出是哪几条，
# 这里只负责把它们搬进末尾的未实现清单——此前它只在阶段里 warn 一句，汇总照样记 PASS，
# 而汇总才是人会看的那一处（审计实测于 en / ja 仓）。
EXTRA_NOT_IMPL=()
while IFS= read -r not_impl_line; do
  [[ -n "$not_impl_line" ]] && EXTRA_NOT_IMPL+=("$not_impl_line")
done < <(bash "$SCRIPTS/doc-lint.sh" --not-impl 2>/dev/null || true)

# ── 阶段 1b：命名纪律 ───────────────────────────────────
# 名字要让模型光看名字就读得出含义（rules/code-discipline.md）。机器判得了的是单字母和常见缩写那一半。
# 退出码 3 = 没有要查的 .rs，与 Show me test 同一个约定：记「本次未跑」，不记通过。
head1 "命名纪律"
naming_rc=0; GATE_IN_STAGE=1 bash "$SCRIPTS/naming-lint.sh" "$ROOT" || naming_rc=$?
case "$naming_rc" in
  0) record "命名纪律" PASS ;;
  3) NOT_RUN+=("命名纪律            本次无对象可判：项目里没有要查的 .rs 文件。写了 Rust 代码之后这一项才有东西可判") ;;
  *) record "命名纪律" FAIL ;;
esac

# ── 阶段 2：Show me test ────────────────────────────────
# 判定逻辑住在 show-me-test.sh（selftest 拿样本仓单独喂它）。退出码 3 = 无对象可判。
head1 "Show me test"
smt_rc=0; GATE_IN_STAGE=1 bash "$SCRIPTS/show-me-test.sh" "$ROOT" || smt_rc=$?
case "$smt_rc" in
  0) record "Show me test" PASS ;;
  3) NOT_RUN+=("Show me test        本次无对象可判：工作区与基准无差异。改动之后再跑，或指定基准： GATE_BASE=<ref> bash .claude/scripts/gate.sh") ;;
  *) record "Show me test" FAIL ;;
esac

# ── 阶段 3：构建与单测 ──────────────────────────────────
if [[ ! -f "$ROOT/Cargo.toml" ]]; then
  head1 "构建与单测"
  if [[ -n "$(find "$ROOT/crates" -name '*.rs' 2>/dev/null | head -1)" ]]; then
    bad "有 .rs 文件却没有 Cargo.toml —— 这些代码根本没被构建过"
    howto "在仓库根建 Cargo.toml（workspace），把 crates/* 列进 members。"
    record "构建与单测" FAIL
  else
    ok "项目尚无 Rust 代码，本阶段不适用"
    record "构建与单测" PASS
  fi
elif ! command -v cargo >/dev/null 2>&1; then
  head1 "构建与单测"
  bad "有 Cargo.toml 但 cargo 缺失 —— 无法验证，按失败处理（不降级、不跳过）"
  howto "装 Rust 工具链：" \
        "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
  record "构建与单测" FAIL
else
  run_stage "构建与单测" bash "$SCRIPTS/check.sh" "$ROOT"
fi

# ── 阶段 3b：规则清单（译文仓的对账依据）─────────────────
if [[ -d "$SCRIPTS/../rules" && -f "$SCRIPTS/manifest.sh" ]]; then
  run_stage "规则清单" bash "$SCRIPTS/manifest.sh"
  # 译文同步是 SOP 仓自己的事，消费项目那边没有兄弟语言仓，不该判它。
  # 判据：被门禁的这个 ROOT 是不是 SOP 仓本身。
  if [[ -f "$SCRIPTS/../I18N" ]] && is_pkg_itself "$ROOT"; then
    # --staged 时本包是临时树，兄弟语言仓要从源仓的父目录找；不带 --staged 时不传参数，i18n-sync 按默认找兄弟目录。
    run_stage "各语言同步" bash "$SCRIPTS/i18n-sync.sh" ${STAGED_FROM:+"$(dirname "$STAGED_FROM")"}
  fi
  # 版本纪律同理只判 SOP 仓自身：改了规范本体就必须抬 VERSION——
  # 以前这条只是 CLAUDE.md 里的提醒句，拦不住（对抗测试实测）。
  if is_pkg_itself "$ROOT"; then
    run_stage "版本纪律" bash "$SCRIPTS/version-discipline.sh" "$ROOT"
    # 抬了 VERSION 不等于记了账：0.0.39 那次三个语言仓的 CHANGELOG 一起跳过了 0.0.36，全部门禁照绿。
    run_stage "CHANGELOG 连续" bash "$SCRIPTS/changelog-lint.sh" "$ROOT"
  fi
fi

# ── 未实现的验证手段：共享门禁带不了、要项目自己接的 ─────
# 键 → 缺的是什么。项目本地阶段在头部写 `# gate-covers: <键>`（一行一个，字面照抄键），
# 它这一轮跑了而且通过，汇总里这一项才换成「由哪个阶段覆盖」；跑红了、退 77 了，都照旧列在未实现里。
# 覆盖只说明「有一个阶段在做这件事，这一轮过了」，它做到多大范围，看那个阶段自己的名字与说明。
# 清单写死的时候，singlefs 每次门禁都跑崩溃点重放与真设备阶段，汇总却照样打印「缺被测对象」。
# 「最终判据」不点名任何装置：准入标准由项目定，项目没接上、或这一轮没跑过，它就一直列在这里。
NOT_IMPL_KEYS=("模型对拍" "崩溃点重放" "最终判据" "命名纪律（shell）")
declare -A NOT_IMPL_WHAT=(
  ["模型对拍"]="同一串随机操作分别施加到理想模型与实现上，比结果（rules/test-discipline.md）"
  ["崩溃点重放"]="记下块层的全部写请求，逐个崩溃点截断、重放、跑 checker（rules/test-discipline.md）"
  ["最终判据"]="准入标准：起什么环境、跑什么负载、注入什么故障由项目定，接在 .claude/gate.d/ 里（rules/show-me-test.md「最终判据由项目定」）"
  ["命名纪律（shell）"]="只查 .rs 里声明的名字；shell 脚本的名字还没做成检查（rules/code-discipline.md）"
)
declare -A COVERED_BY=()

# ── 阶段 3c：项目本地阶段（.claude/gate.d/*.sh）─────────
# 共享门禁管不了「这个项目自己的 kb 该长什么样」这类检查，但那类检查同样必须**会红**，
# 不能只写在文档里当提醒句（rules/show-me-test.md：踩过的坑要做成会失败的检查）。
# 所以留一个挂载点：项目把自己的检查丢进 .claude/gate.d/，门禁按文件名排序逐个当阶段跑。
#
# 五条纪律与其余阶段一致：
#   1. 目录不存在 ⇒ 说「项目没有本地阶段」，不记阶段——那不是「通过」，是「没有」
#   2. 脚本存在但跑不起来（没有执行位、语法错、找不到解释器）⇒ **判红**，不许当成跳过
#   3. 阶段名取脚本头部的 `# gate-stage: <名字>`，没写就用文件名——名字要出现在汇总里
#   4. 退出码 77 = 这一轮无对象可判 ⇒ 记「本次未跑」，不记通过。exit 0 的跳过在汇总里与「判过了」一模一样
#   5. 头部 `# gate-covers: <键>` 声明它覆盖上面未实现清单里的哪一项；只有这一轮通过才算数，键写错判红
head1 "项目本地阶段"
GATE_D="$ROOT/.claude/gate.d"
LOCAL_FILES=()
if [[ -d "$GATE_D" ]]; then
  while IFS= read -r f; do [[ -n "$f" ]] && LOCAL_FILES+=("$f"); done \
    < <(find "$GATE_D" -maxdepth 1 -name '*.sh' -type f | sort)
fi
if [[ ${#LOCAL_FILES[@]} -eq 0 ]]; then
  ok "项目没有本地阶段（$GATE_D 不存在或没有 *.sh）"
else
  ok "发现 ${#LOCAL_FILES[@]} 个本地阶段，按文件名顺序跑"
  for f in "${LOCAL_FILES[@]}"; do
    # ⚠️ **可读性判断必须排在读取之前。** 反过来写的话，读不了的脚本会让
    # sed 在 set -e + pipefail 下把整个门禁带走——退出码非零、汇总一行都不打印，
    # 比静默跳过更糟：看不出是哪一步、也看不出别的阶段过没过。实测踩过。
    if [[ ! -r "$f" ]]; then
      head1 "$(basename "$f" .sh)"
      bad "读不了 $f"
      howto "检查该文件的读权限，或把它从 .claude/gate.d/ 拿掉。读不到不等于通过，本阶段按失败记。"
      record "$(basename "$f" .sh)" FAIL
      continue
    fi
    # 取阶段名。读得到才走到这里，但仍然兜一层——名字取不到不该让门禁失去汇总。
    sname="$(sed -n 's/^# gate-stage:[[:space:]]*//p' "$f" 2>/dev/null | head -1 || true)"
    [[ -n "$sname" ]] || sname="$(basename "$f" .sh)"
    covered_keys=()
    while IFS= read -r covered_key; do
      if [[ -n "$covered_key" ]]; then covered_keys+=("$covered_key"); fi
    done < <(sed -n 's/^# gate-covers:[[:space:]]*//p' "$f" 2>/dev/null | sed 's/[[:space:]]*$//' || true)
    head1 "$sname"
    stage_rc=0; GATE_IN_STAGE=1 bash "$f" "$ROOT" || stage_rc=$?
    case "$stage_rc" in
      0)  record "$sname" PASS ;;
      77) NOT_RUN+=("$sname    本次未跑：阶段报了这一轮无对象可判（退出码 77），原因见上方它的输出") ;;
      *)  record "$sname" FAIL ;;
    esac
    unknown_keys=()
    for covered_key in "${covered_keys[@]}"; do
      if [[ -z "${NOT_IMPL_WHAT[$covered_key]+set}" ]]; then
        unknown_keys+=("$covered_key")
      elif [[ $stage_rc -eq 0 ]]; then
        COVERED_BY["$covered_key"]+="${COVERED_BY[$covered_key]:+、}$sname"
      fi
    done
    if [[ ${#unknown_keys[@]} -gt 0 ]]; then
      bad "$sname 的 gate-covers 写了清单里没有的项：$(printf '「%s」' "${unknown_keys[@]}")"
      howto "只认这几个键，一行一个，字面照抄：$(printf '「%s」' "${NOT_IMPL_KEYS[@]}")" \
            "写错一个字，那一项就一直列在未实现里，而写的人以为已经覆盖了。"
      record "覆盖声明（$sname）" FAIL
    fi
  done
fi

# ── 跑的过程中工作区变没变 ───────────────────────────
# 门禁的结论只对它读到的那一版成立。跑的过程中有人改文件（自己还在改，或别的会话在改），
# 前面的阶段读旧版、后面的阶段读新版，汇总出来的红绿不对应任何一版，而输出里看不出来。
# 实测（singlefs，2026-09-16）：一次是边改 kb 边跑全量门禁，只好停掉重跑；另一次跑到一半别的会话改好了一行，
# 文档铁律红在一个收尾时已经不存在的状态上。
END_TREE="$(worktree_fingerprint "$ROOT")"
if [[ -z "$START_TREE" || -z "$END_TREE" ]]; then
  NOT_RUN+=("工作区跑的过程中没变  本次未检查：不是 git 仓，或取不到工作区指纹")
else
  head1 "工作区跑的过程中没变"
  if [[ "$START_TREE" == "$END_TREE" ]]; then
    ok "开跑与收尾的工作区指纹相同（${START_TREE:0:12}）：各阶段读到的是同一版"
    record "工作区跑的过程中没变" PASS
  else
    bad "门禁跑的这段时间里工作区变了（开跑 ${START_TREE:0:12}，收尾 ${END_TREE:0:12}）：各阶段读到的不一定是同一版，这一轮的结论不对应任何一版"
    howto "等自己与别的会话的改动都停下再跑一遍；几个会话共写一个仓时跑 bash .claude/scripts/gate.sh --staged，它在临时 worktree 上跑一个不会被人改的快照。"
    record "工作区跑的过程中没变" FAIL
  fi
fi

# ── 汇总 ────────────────────────────────────────────────
head1 "门禁结果"
failed=0
for i in "${!STAGES[@]}"; do
  if [[ "${RESULTS[$i]}" == PASS ]]; then ok "${STAGES[$i]}"
  else bad "${STAGES[$i]}"; failed=$((failed+1)); fi
done
[[ $failed -eq 0 ]] || howto "红色阶段的细节与出路在上方对应段落里，按那里的「怎么办」执行，修完重跑。"

if [[ ${#NOT_RUN[@]} -gt 0 ]]; then
  printf '\n%s本次未跑的阶段：%s\n' "$C_YEL" "$C_RST"
  for s in "${NOT_RUN[@]}"; do warn "$s"; done
fi

printf '\n%s未实现的门禁阶段（绿色不代表验证充分）：%s\n' "$C_YEL" "$C_RST"
uncovered_count=0
for extra in ${EXTRA_NOT_IMPL[@]+"${EXTRA_NOT_IMPL[@]}"}; do warn "$extra"; uncovered_count=$((uncovered_count+1)); done
for key in "${NOT_IMPL_KEYS[@]}"; do
  if [[ -z "${COVERED_BY[$key]:-}" ]]; then warn "$key：${NOT_IMPL_WHAT[$key]}"; uncovered_count=$((uncovered_count+1)); fi
done
if [[ $uncovered_count -eq 0 ]]; then ok "清单里每一项都有项目阶段覆盖，见下"; fi
if [[ ${#COVERED_BY[@]} -gt 0 ]]; then
  printf '\n%s由项目本地阶段覆盖（这一轮跑过且通过；覆盖到多大范围，看那个阶段自己的说明）：%s\n' "$C_YEL" "$C_RST"
  for key in "${NOT_IMPL_KEYS[@]}"; do
    if [[ -n "${COVERED_BY[$key]:-}" ]]; then ok "$key ← ${COVERED_BY[$key]}"; fi
  done
fi

say ""
if [[ $failed -gt 0 ]]; then
  bad "门禁未通过：$failed 个阶段失败"   # gate-lint:summary
  exit 1
fi
# 记下「门禁在这里通过过」。下一轮的 diff 基准优先取它——
# 判据因此变成规则原本那句话：**上次过闸之后的所有改动都要过闸**，
# 而不是「最近一个 commit 里有没有」。没有这个标记时窗口只有一格，
# 分两次提交就能把改代码的那次挤出去（对抗测试实测，gate 退出码 0）。
# 记的是**开跑时**的 HEAD：跑完再解析一次的话，另一个会话在这一轮跑的过程中提交，
# 那个从没验过的提交会被一并盖章，此后永远落在 diff 窗口外（审计实测：跑的中途提交，gate-ok 指向了新提交）。
# GATE_BASE 被显式指定时不记：那一轮的窗口是人为收窄的（--staged 的里层也走这一支），
# 拿它当「此后都验过」的起点会把中间的提交漏掉。不记只会让下一轮的窗口更宽，不会更窄。
if [[ -n "$START_HEAD" && -z "${GATE_BASE:-}" ]]; then
  now_head="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || true)"
  if [[ -n "$now_head" && "$now_head" != "$START_HEAD" ]]; then
    warn "跑的过程中 HEAD 变了（${START_HEAD:0:7} → ${now_head:0:7}）：gate-ok 只记到开跑时那个提交"
    howto "那之后的提交没在这一轮验过，要它们过闸就再跑一遍门禁。"
  fi
  git -C "$ROOT" update-ref refs/singlefs/gate-ok "$START_HEAD" 2>/dev/null || true
fi
ok "已实现的门禁阶段全部通过（共 ${#STAGES[@]} 个）"
warn "Gate proves evidence requirements, not semantic correctness."
warn "门禁证明的是证据要求被满足，不是代码语义正确——绿灯之后仍要看「测的是不是对的东西」。"
if [[ -n "${COVERED_BY[崩溃点重放]:-}" ]]; then
  warn "另：崩溃点重放由「${COVERED_BY[崩溃点重放]}」覆盖，只说到它枚举过的那些写路径为止，别的写路径照样没验过。"
else
  warn "另：崩溃一致性尚未纳入门禁，此结果不足以证明写路径正确。"
fi
