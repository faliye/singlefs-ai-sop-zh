#!/usr/bin/env bash
# 准入门禁。rules/show-me-test.md的可执行形式。
#
# 设计原则：
#   1. 未实现的阶段**显式报告为未实现**，绝不静默跳过（第一节第 5 条）
#   2. 任何阶段都能失败——不存在只会成功的检查
#   3. 退出码：0 = 全部已实现阶段通过；非 0 = 有阶段失败
#
# 注意：本门禁当前**尚未覆盖崩溃一致性**。绿色不等于验证充分，见文末未实现清单。
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${1:-$(project_root)}"
[[ -d "$ROOT" ]] || die "找不到项目根：$ROOT" \
  "在项目根跑，或把它作为第一个参数传进来： bash .claude/scripts/gate.sh <项目根>"
cd "$ROOT"

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
if [[ "$(cd "$ROOT" && pwd)" == "$(cd "$SCRIPTS/.." && pwd)" ]]; then
  ok "本仓即 SOP 本身，无需版本戳"
  record "规范版本" PASS
else
pkg_ver="$(cat "$SCRIPTS/../VERSION" 2>/dev/null || echo "?")"
proj_ver="$(cat "$ROOT/.singlefs-ai-sop-version" 2>/dev/null || echo "")"
if [[ -z "$proj_ver" ]]; then
  warn "项目未声明规范版本（缺 .singlefs-ai-sop-version）"
  record "规范版本" FAIL
elif [[ "$proj_ver" != "$pkg_ver" ]]; then
  bad "规范版本不一致：项目声明 $proj_ver，singlefs-ai-sop 是 $pkg_ver"
  howto "先读一遍上游的规范变更（git log .claude/singlefs-ai-sop/），" \
        "确认没有影响你这次改动，再跑 bash .claude/singlefs-ai-sop/install.sh 更新版本戳。"
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
fam="$(sed -n 's/^family=//p' "$SCRIPTS/../I18N" 2>/dev/null || echo singlefs-ai-sop)"
for lang in $(sed -n 's/^languages=//p' "$SCRIPTS/../I18N" 2>/dev/null); do
  cand="$(cd "$ROOT/.." 2>/dev/null && pwd)/$fam-$lang"
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
# command-safety.md 里可机检的那几条：按模式匹配杀进程、子 shell 赋值往外带值。
# 以前它们只是文档里的提醒句，而本仓自己的 qemu/run.sh 违反了其中一条整整一轮。
run_stage "shell 纪律" bash "$SCRIPTS/shell-lint.sh" "${LINT_EXTRA[@]}"

# ── 阶段 1：文档铁律 ────────────────────────────────────
run_stage "文档铁律" bash "$SCRIPTS/doc-lint.sh" "$ROOT"

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
  if [[ -f "$SCRIPTS/../I18N" && "$(cd "$ROOT" && pwd)" == "$(cd "$SCRIPTS/.." && pwd)" ]]; then
    run_stage "各语言同步" bash "$SCRIPTS/i18n-sync.sh"
  fi
  # 版本纪律同理只判 SOP 仓自身：改了规范本体就必须抬 VERSION——
  # 以前这条只是 CLAUDE.md 里的提醒句，拦不住（对抗测试实测）。
  if [[ "$(cd "$ROOT" && pwd)" == "$(cd "$SCRIPTS/.." && pwd)" ]]; then
    run_stage "版本纪律" bash "$SCRIPTS/version-discipline.sh" "$ROOT"
    # 抬了 VERSION 不等于记了账：0.0.39 那次三个语言仓的 CHANGELOG 一起跳过了 0.0.36，全部门禁照绿。
    run_stage "CHANGELOG 连续" bash "$SCRIPTS/changelog-lint.sh" "$ROOT"
  fi
fi

# ── 阶段 3c：项目本地阶段（.claude/gate.d/*.sh）─────────
# 共享门禁管不了「这个项目自己的 kb 该长什么样」这类检查，但那类检查同样必须**会红**，
# 不能只写在文档里当提醒句（rules/show-me-test.md：踩过的坑要做成会失败的检查）。
# 所以留一个挂载点：项目把自己的检查丢进 .claude/gate.d/，门禁按文件名排序逐个当阶段跑。
#
# 三条纪律与其余阶段一致：
#   1. 目录不存在 ⇒ 说「项目没有本地阶段」，不记阶段——那不是「通过」，是「没有」
#   2. 脚本存在但跑不起来（没有执行位、语法错、找不到解释器）⇒ **判红**，不许当成跳过
#   3. 阶段名取脚本头部的 `# gate-stage: <名字>`，没写就用文件名——名字要出现在汇总里
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
    run_stage "$sname" bash "$f" "$ROOT"
  done
fi

# ── 阶段 4：LKMM（内存序）───────────────────────────────
if [[ -d "$ROOT/litmus" ]]; then
  run_stage "LKMM" bash "$SCRIPTS/lkmm.sh" "$ROOT"
else
  head1 "LKMM"
  ok "项目没有 litmus/ 目录，本阶段不适用"
  record "LKMM" PASS
fi

# ── 阶段 5：QEMU harness 自检（默认不跑，太慢）──────────
if [[ -n "${GATE_QEMU:-}" ]]; then
  run_stage "QEMU harness" bash "$SCRIPTS/qemu/run.sh" --selftest "$ROOT"
else
  NOT_RUN+=("QEMU harness 自检   本次未跑（要两次虚机启动）。跑： GATE_QEMU=1 bash .claude/scripts/gate.sh")
fi

# ── 未实现的阶段（必须显式列出）────────────────────────
NOT_IMPL=(
  "模型对拍          需要 checker 与实现存在（rules/test-discipline.md）"
  "崩溃点重放        需要块层写记录 + checker（rules/test-discipline.md）"
  "QEMU 真实负载     harness 已就绪并自检通过，缺被测对象（盘上格式定案，见项目 kb/decisions.md）"
)

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
for s in "${NOT_IMPL[@]}"; do warn "$s"; done

say ""
if [[ $failed -gt 0 ]]; then
  bad "门禁未通过：$failed 个阶段失败"   # gate-lint:summary
  exit 1
fi
# 记下「门禁在这里通过过」。下一轮的 diff 基准优先取它——
# 判据因此变成规则原本那句话：**上次过闸之后的所有改动都要过闸**，
# 而不是「最近一个 commit 里有没有」。没有这个标记时窗口只有一格，
# 分两次提交就能把改代码的那次挤出去（对抗测试实测，gate 退出码 0）。
if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  git -C "$ROOT" update-ref refs/singlefs/gate-ok HEAD 2>/dev/null || true
fi
ok "已实现的门禁阶段全部通过（共 ${#STAGES[@]} 个）"
warn "Gate proves evidence requirements, not semantic correctness."
warn "门禁证明的是证据要求被满足，不是代码语义正确——绿灯之后仍要看「测的是不是对的东西」。"
warn "另：崩溃一致性尚未纳入门禁，此结果不足以证明写路径正确。"
