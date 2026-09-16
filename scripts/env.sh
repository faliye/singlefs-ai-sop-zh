#!/usr/bin/env bash
# 环境自检。缺什么直接报什么，不猜、不降级、不静默跳过。
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

head1 "环境自检"
missing=0

req() { # req <命令> <说明> <是否必须:hard|soft>
  local cmd="$1" desc="$2" level="${3:-hard}" ver
  if command -v "$cmd" >/dev/null 2>&1; then
    ver="$("$cmd" --version 2>/dev/null | head -1 || true)"
    ok "$cmd${ver:+  ($ver)}"
  else
    if [[ "$level" == hard ]]; then
      bad "$cmd 缺失"
      howto "$desc"
      missing=$((missing+1))
    else warn "$cmd 缺失 —— $desc（非阻塞）"; fi
  fi
}

# 门禁脚本自己依赖的工具。此前一项都没查：缺了它们门禁不是不跑，是**报错的方向不对**——
# 例如 sort 不认 -V 时，0.0.9 → 0.0.10 这次真抬的版本会被版本纪律判成降级（审核实测）。
req gawk     "判定不许随 awk 实现变（lib.sh 已经拦，这里报出来是为了一次看全）。装：sudo apt install gawk" hard
req sha256sum "规则清单与译文溯源的哈希" hard
req timeout  "门禁自检给每个用例设超时；没有它挂死的检查既不红也不绿" hard

req cargo    "Rust 工具链。装：curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh" hard
req rustc    "同上" hard
req git      "版本控制" hard
req dmsetup  "块层写记录（崩溃点重放）" hard
req shellcheck "脚本静态检查" soft

# 版本下限：selftest 用 git init -b（2.28 起），--staged 用 git worktree；
# 脚本里用了 mapfile 与 declare -A（bash 4），以及空数组展开（4.3 起不再当成未定义）。
git_version="$(git --version 2>/dev/null | sed -n 's/^git version \([0-9]*\)\.\([0-9]*\).*/\1\2/p' | head -1)"
if [[ -n "$git_version" ]] && (( 10#${git_version:0:1}0 + 10#${git_version:1} < 28 )) && (( 10#${git_version:0:1} < 3 )); then
  bad "git 版本过低（$(git --version)）：门禁自检要 git init -b，2.28 起才有"
  howto "升级 git 到 2.28 或更新；旧版上样本仓建不起来，自检会整体判错而不是判红。"
  missing=$((missing+1))
fi
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3) )); then
  bad "bash 版本过低（$BASH_VERSION）：门禁用了 mapfile、declare -A 与空数组展开，要 4.3 或更新"
  howto "装新版 bash 并让脚本跑在它上面（脚本头是 /usr/bin/env bash，改 PATH 即可）。"
  missing=$((missing+1))
fi
if [[ "$(date -d '2026-01-02 - 1 day' +%F 2>/dev/null || true)" != 2026-01-01 ]]; then
  bad "date 不认 -d（日期加减）：doc-lint 与 changelog-lint 的日期下界靠它算"
  howto "装 GNU coreutils 的 date；不认 -d 时这两个检查会直接停下。"
  missing=$((missing+1))
fi
if ! printf '1.10\n1.9\n' | sort -V 2>/dev/null | head -1 | grep -qx 1.9; then
  bad "sort 不支持 -V（版本号排序）：版本纪律与「副本与上游同版本」靠它比大小"
  howto "装 GNU coreutils 的 sort；不支持时两边比较落空，方向会报反。"
  missing=$((missing+1))
fi

if [[ $missing -gt 0 ]]; then
  bad "环境自检失败：$missing 项缺失"   # gate-lint:summary
  exit 1
fi
ok "环境自检通过"
