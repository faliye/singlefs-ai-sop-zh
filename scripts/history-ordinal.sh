#!/usr/bin/env bash
# gate-similar: doc-lint.sh 它判每份 kb 文档此刻的文本形态，不看改动；撞号只判这一次新增的条目（存量撞号一改就改坏已经指过去的锚点），要拿这一轮的 diff 基准比
# admission: always 判的是这一次 diff 窗口里新增的历史条目，窗口随提交在动
# run-condition: command git python3
# 本次新增的历史条目有没有撞号。
#
# 「（其 <序号>）」编号先到先得（rules/session-wrapup.md 第 4 条）：同一位置下两条同号，拿它当锚点的引用就指不清。
# 位置钥匙是「最近的 `## ` 标题 + 最近的 `### 日期` + 点名词（已定项 <序号> / E<序号> 这类，没有就用去掉编号的整句）」，
# 同一把钥匙下序号撞了才算撞号；钥匙怎么取在 history-ordinal-keys.py。
#
# 只判本次新增的（存量撞号只报数：改它会改坏已经指过去的锚点）。基准取 GATE_DIFF_BASE，单跑时按 lib.sh 的 diff_base 现算；
# 不只和 HEAD 比，否则撞号的条目先提交、再跑门禁就落在窗口外。
#
# 用法：
#   history-ordinal.sh <仓根> [变更史文件…]
# 不给文件就扫登记的 kb 目录（.claude/kb-directories，没登记就是 <仓根>/.claude/kb）下的全部 *.md（含子目录），
# 不先过滤：没有历史节的文件一个键都不产。
# 一份都没有时退 77（本次无对象可判），不报绿。
#
# 只认「日期」「其 <序号>」这两个中文形态。别的语言的仓里判不到撞号，也没报未实现：一个键都不产时照样报「没有撞号」。
set -uo pipefail
# lib.sh 要在 cd 之前按绝对路径 source：cd 之后 BASH_SOURCE 的相对路径就指不到了。
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
preflight "${BASH_SOURCE[0]}" "$@"; set -- ${PREFLIGHT_ARGUMENTS[@]+"${PREFLIGHT_ARGUMENTS[@]}"}
# 关掉 lib.sh 带进来的 set -e：下面 ((...)) 与 grep -c 条件为假时返回 1，-e 会在那一行退出整个脚本。
set +e
# 键提取器同样要在 cd 之前取绝对路径
KEY_EXTRACTOR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/history-ordinal-keys.py"
[[ -f "$KEY_EXTRACTOR" ]] || die "找不到键提取器 $KEY_EXTRACTOR" "这份脚本与 history-ordinal-keys.py 要放在同一个目录，重新同步一次这个包。"
REPOSITORY_ROOT="${1:-.}"
cd "$REPOSITORY_ROOT" 2>/dev/null || die "找不到仓根：$REPOSITORY_ROOT" \
  "把仓根作为第一个参数传进来： bash scripts/history-ordinal.sh <仓根> [变更史文件…]"
shift 2>/dev/null || true

# kb 目录登记（rules/kb-discipline.md，kb_directories 在 lib.sh）：没登记就是默认的 .claude/kb。
kb_directories_text="$(kb_directories "$PWD")" || exit 1
KB_DIRECTORIES=(); [[ -n "$kb_directories_text" ]] && mapfile -t KB_DIRECTORIES <<< "$kb_directories_text"
if ((${#KB_DIRECTORIES[@]})); then KB_SCAN_DIRECTORIES=("${KB_DIRECTORIES[@]}"); else KB_SCAN_DIRECTORIES=("$PWD/.claude/kb"); fi
KB_RELATIVE_DIRECTORIES=(); for kb_scan_directory in "${KB_SCAN_DIRECTORIES[@]}"; do KB_RELATIVE_DIRECTORIES+=("${kb_scan_directory#"$PWD"/}"); done

shopt -s nullglob
if (($#)); then
  HISTORY_FILES=("$@")
else
  mapfile -t HISTORY_FILES < <(for kb_scan_directory in "${KB_SCAN_DIRECTORIES[@]}"; do find "$kb_scan_directory" -type f -name '*.md' 2>/dev/null; done | sort)
fi
shopt -u nullglob

# 窗口的起点：gate.sh 导出的 GATE_DIFF_BASE，单跑时现算。解析不到的（外层门禁的基准漏进了别的仓）判不了，不当成空窗口
DIFF_BASE="${GATE_DIFF_BASE:-}"
if [[ -z "$DIFF_BASE" ]]; then DIFF_BASE="$(diff_base .)" || die "算不出 diff 基准" "照上面 diff_base 的原话改（多半是 GATE_BASE 写错了），再跑。"; fi
if [[ "$DIFF_BASE" != HEAD ]] && ! git rev-parse --verify -q "$DIFF_BASE^{commit}" >/dev/null 2>&1; then
  die "diff 基准 $DIFF_BASE 在这个仓里解析不到提交" \
    "外层门禁的 GATE_DIFF_BASE 漏进了别的仓就会这样：单跑时 env -u GATE_DIFF_BASE，或者把 GATE_DIFF_BASE 设成这个仓里的提交。"
fi

# 读整份文件，每个有编号的条目出一行，\x1f 隔开四段：## 标题、日期、点名词或整句、（其 <序号>）。
keys_of_text() { python3 "$KEY_EXTRACTOR"; }

# 基准侧的键池按整个 .claude/kb 树汇总，不按文件名对文件名比：文件改名或搬目录后，按文件名找基准
# 会把搬过去的存量撞号全判成新增（selftest.sh「搬进实验史新文件的存量撞号不算新撞号」专测这个）。
kb_prefix_pattern="$(printf '%s|' "${KB_RELATIVE_DIRECTORIES[@]}")"; kb_prefix_pattern="${kb_prefix_pattern%|}"
base_pool_files="$(git ls-tree -r --name-only "$DIFF_BASE" 2>/dev/null | grep -E "^($kb_prefix_pattern)/.*\.md\$" || true)"
base_keys_all=""
while IFS= read -r base_file; do
  [[ -n "$base_file" ]] || continue
  base_keys_all+="$(git show "$DIFF_BASE:$base_file" 2>/dev/null | keys_of_text)"$'\n'
done <<<"$base_pool_files"

new_collisions=(); legacy_collision_count=0; checked_file_count=0
for history_file in "${HISTORY_FILES[@]}"; do
  [[ -f "$history_file" ]] || continue
  checked_file_count=$((checked_file_count + 1))
  current_keys="$(keys_of_text < "$history_file")"
  [[ -n "$current_keys" ]] || continue
  mapfile -t duplicated_keys < <(sort <<<"$current_keys" | uniq -d)
  ((${#duplicated_keys[@]})) || continue
  for key in "${duplicated_keys[@]}"; do
    [[ -n "$key" ]] || continue
    current_count=$(grep -cxF "$key" <<<"$current_keys")
    base_count=$(grep -cxF "$key" <<<"$base_keys_all")
    new_count=$((current_count - base_count))
    if ((new_count > 0)); then
      IFS=$'\x1f' read -r key_section_heading key_date key_named_reference key_ordinal <<<"$key"
      new_collisions+=("$history_file  「${key_section_heading:-（无 ## 节）}」$key_date $key_named_reference$key_ordinal  这把钥匙下现有 $current_count 条，其中 $new_count 条是本次新增")
    else
      legacy_collision_count=$((legacy_collision_count + 1))
    fi
  done
done

if ((checked_file_count == 0)); then
  warn "kb 目录（${KB_RELATIVE_DIRECTORIES[*]}）下没有变更史文件，本阶段无对象可判（这不是通过）"
  exit 77
fi

if ((${#new_collisions[@]})); then
  bad "本次新增的历史条目里有 ${#new_collisions[@]} 处撞号"
  printf '     %s\n' "${new_collisions[@]}"
  howto "取号前先查同一个『## 节 + 日期 + 点名词』下已经用到的最大号（grep 那一节那个日期块下的「（其…）」）。"
  howto "把自己这条改成下一个没被占的号——先到先得，改别人已提交的那条会改坏引用它的锚点。"
  howto "并发会话的完整对法见 rules/session-wrapup.md 第 4 条。"
  exit 1
fi
ok "本次新增的历史条目没有撞号（查了 $checked_file_count 份变更史，窗口从 $DIFF_BASE 起；存量 $legacy_collision_count 处撞号不在本阶段射程，见文件头）"
