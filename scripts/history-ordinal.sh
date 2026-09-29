#!/usr/bin/env bash
# gate-similar: doc-lint.sh 它判每份 kb 文档此刻的文本形态，不看改动；撞号只判这一次新增的条目（存量撞号一改就改坏已经指过去的锚点），要拿这一轮的 diff 基准比
# admission: always 判的是这一次 diff 窗口里新增的历史条目，窗口随提交在动
# run-condition: command git python3
# 本次新增的历史条目有没有撞号。
#
# 变更史一份 kb 文件的「## 历史版本」节按日期分组：`### 2026-09-01` 下面挂几个 `#### `子标题，
# 子标题需要编号时写成「已定项 15（其一）」「（其一）」这类形态，「其 N」按写入次序编号。
# 兼容尚未搬迁成这个形态的旧文件：日期与编号仍融合在一行的 `### 2026-09-01（其十六）：……`。
#
# **这个编号是先到先得的公共资源**：并发会话各写各的，取号前不查最大号就会撞
# （rules/session-wrapup.md 第 4 节：公共编号先到先得）。
# 撞号的后果不是难看——别处拿「日期（其 N）」或「已定项 N（其 N）」当锚点引用时，
# 一个位置下有两条同号条目，那个锚点指向哪一条无从判断。
#
# 判据：取「最近的 `## ` 标题」+「最近的 `### 日期` 标题」+「子标题里的点名词（已定项 N /
# 未定项 N / E<n> 这类；没有就用去掉编号之后的整句）」三者拼成一个位置钥匙，同一把钥匙下
# 「（其 N）」的 N 撞了才算撞号——不同点名词、或不同日期、不同 `## ` 节，各自的编号互不相干。
#
# 只判**本次新增**的条目（与这一轮的 diff 基准比，与 Show me test 同一个窗口）：存量撞号只报数，不判红——
# 那是历史，改它会改坏已经指过去的锚点。基准取 gate.sh 导出的 GATE_DIFF_BASE，单跑时按 lib.sh 的 diff_base 现算：
# 只和 HEAD 比的话，撞号的条目先提交、再跑门禁，就落在窗口外看不见了。
#
# 用法：
#   history-ordinal.sh <仓根> [变更史文件…]
# 不给文件就扫 <仓根>/.claude/kb 下的全部 *.md（含子目录）；没有「## 历史版本」或任何
# `### 日期` 标题的文件，键提取器对它一个键都不产，扫了也白扫，不用先过滤。
# 一份都没有时退 77（本次无对象可判），不报绿。
#
# 判据是「日期」「其 N」这两个中文形态，别的语言的变更史不长这样——
# 那些仓里这一项报未实现，不假装通过（rules/show-me-test.md）。
set -uo pipefail
# lib.sh 要在 cd 之前按绝对路径 source：cd 之后 BASH_SOURCE 的相对路径就指不到了。
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
preflight "${BASH_SOURCE[0]}" "$@"; set -- ${PREFLIGHT_ARGUMENTS[@]+"${PREFLIGHT_ARGUMENTS[@]}"}
# lib.sh 带进来的 set -e 要关掉：下面拿 ((...)) 与 grep -c 的返回值做判断，
# 条件为假时它们返回 1，-e 会在那一行把整个脚本带走（rules/command-safety.md）。
set +e
# 键提取器同样要在 cd 之前取绝对路径
KEY_EXTRACTOR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/history-ordinal-keys.py"
[[ -f "$KEY_EXTRACTOR" ]] || die "找不到键提取器 $KEY_EXTRACTOR" "这份脚本与 history-ordinal-keys.py 要放在同一个目录，重新同步一次这个包。"
ROOT="${1:-.}"
cd "$ROOT" 2>/dev/null || die "找不到仓根：$ROOT" \
  "把仓根作为第一个参数传进来： bash scripts/history-ordinal.sh <仓根> [变更史文件…]"
shift 2>/dev/null || true


shopt -s nullglob
if (($#)); then
  HIST=("$@")
else
  mapfile -t HIST < <(find .claude/kb -type f -name '*.md' 2>/dev/null | sort)
fi
shopt -u nullglob

# 窗口的起点：gate.sh 导出的 GATE_DIFF_BASE，单跑时现算。解析不到的（外层门禁的基准漏进了别的仓）判不了，不当成空窗口
BASE="${GATE_DIFF_BASE:-}"
if [[ -z "$BASE" ]]; then BASE="$(diff_base .)" || die "算不出 diff 基准" "照上面 diff_base 的原话改（多半是 GATE_BASE 写错了），再跑。"; fi
if [[ "$BASE" != HEAD ]] && ! git rev-parse --verify -q "$BASE^{commit}" >/dev/null 2>&1; then
  die "diff 基准 $BASE 在这个仓里解析不到提交" \
    "外层门禁的 GATE_DIFF_BASE 漏进了别的仓就会这样：单跑时 env -u GATE_DIFF_BASE，或者把 GATE_DIFF_BASE 设成这个仓里的提交。"
fi

# 键提取器读整份文件内容（要靠上下文找「最近的 ## / ### 日期」），产出「有编号的条目」各一行，
# 用 \x1f 隔开四段：## 标题、日期、点名词或整句、（其 N）。同一行出现两次以上就是同一把钥匙的两条。
keys_of_text() { python3 "$KEY_EXTRACTOR"; }

# 基准侧的键池按**整个 .claude/kb 树**汇总，不按文件名对文件名比：一份存量重复的文件改了名
# （比如按月的文件搬进了新目录），新文件名在基准里不存在，按文件名找基准会把搬过去的存量
# 重复全部误判成新增（2026-09-12 那次搬 experiments-history/ 就踩过这个坑，selftest.sh 里
# 「搬进实验史新文件的存量撞号不算新撞号」那条治具专测这个）。
base_pool_files="$(git ls-tree -r --name-only "$BASE" 2>/dev/null | grep -E '\.claude/kb/.*\.md$' || true)"
base_keys_all=""
while IFS= read -r base_file; do
  [[ -n "$base_file" ]] || continue
  base_keys_all+="$(git show "$BASE:$base_file" 2>/dev/null | keys_of_text)"$'\n'
done <<<"$base_pool_files"

hits=(); legacy=0; checked=0
for f in "${HIST[@]}"; do
  [[ -f "$f" ]] || continue
  checked=$((checked + 1))
  current_keys="$(keys_of_text < "$f")"
  [[ -n "$current_keys" ]] || continue
  # 现有的重复键（含存量）：这份文件里出现 ≥2 次的键
  mapfile -t dup_keys < <(sort <<<"$current_keys" | uniq -d)
  ((${#dup_keys[@]})) || continue
  for k in "${dup_keys[@]}"; do
    [[ -n "$k" ]] || continue
    current_count=$(grep -cxF "$k" <<<"$current_keys")
    base_count=$(grep -cxF "$k" <<<"$base_keys_all")
    new_count=$((current_count - base_count))
    if ((new_count > 0)); then
      IFS=$'\x1f' read -r k_h2 k_date k_ref k_ordinal <<<"$k"
      hits+=("$f  「${k_h2:-（无 ## 节）}」$k_date $k_ref$k_ordinal  这把钥匙下现有 $current_count 条，其中 $new_count 条是本次新增")
    else
      legacy=$((legacy + 1))
    fi
  done
done

if ((checked == 0)); then
  warn "$ROOT/.claude/kb 下没有变更史文件，本阶段无对象可判（这不是通过）"
  exit 77
fi

if ((${#hits[@]})); then
  bad "本次新增的历史条目里有 ${#hits[@]} 处撞号"
  printf '     %s\n' "${hits[@]}"
  howto "取号前先查同一个『## 节 + 日期 + 点名词』下已经用到的最大号（grep 那一节那个日期块下的「（其…）」）。"
  howto "把自己这条改成下一个没被占的号——先到先得，改别人已提交的那条会改坏引用它的锚点。"
  howto "并发会话的完整对法见 rules/session-wrapup.md 第 4 节。"
  exit 1
fi
ok "本次新增的历史条目没有撞号（查了 $checked 份变更史，窗口从 $BASE 起；存量 $legacy 处撞号不在本阶段射程，见文件头）"
