#!/usr/bin/env bash
# gate-similar: doc-lint.sh 它判每份 kb 文档此刻的文本形态，不看改动；撞号只判这一次新增的条目（存量撞号一改就改坏已经指过去的锚点），要拿这一轮的 diff 基准比
# admission: always 判的是这一次 diff 窗口里新增的历史条目，窗口随提交在动
# run-condition: command git python3
# 本次新增的历史条目有没有撞号。
#
# 变更史的条目标题形如 `### 2026-09-01（其十六）：……`，同一天按「其 N」顺序编号。
# **这个编号是先到先得的公共资源**：并发会话各写各的，取号前不查最大号就会撞
# （rules/session-wrapup.md 第 4 节：公共编号先到先得）。
# 撞号的后果不是难看——别处拿「日期（其 N）」当锚点引用时，一个日期下有两条同号条目，
# 那个锚点指向哪一条无从判断。
# 原是使用者项目的一个本地阶段，判据通用，收归这里。
#
# 只判**本次新增**的条目（与这一轮的 diff 基准比，与 Show me test 同一个窗口）：存量撞号只报数，不判红——
# 那是历史，改它会改坏已经指过去的锚点。基准取 gate.sh 导出的 GATE_DIFF_BASE，单跑时按 lib.sh 的 diff_base 现算：
# 只和 HEAD 比的话，撞号的条目先提交、再跑门禁，就落在窗口外看不见了。
#
# 用法：
#   history-ordinal.sh <仓根> [变更史文件…]
# 不给文件就按 <仓根>/.claude/kb 下的 *-history.md 与 HISTORY_SUBDIRECTORIES 那几个目录里的 *.md 找。
# 一份都没有时退 77（本次无对象可判），不报绿。
#
# 判据是「日期（其 N）」这个中文形态，别的语言的变更史不长这样——
# 那些仓里这一项报未实现，不假装通过（rules/show-me-test.md）。
set -uo pipefail
# lib.sh 要在 cd 之前按绝对路径 source：cd 之后 BASH_SOURCE 的相对路径就指不到了。
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
preflight "${BASH_SOURCE[0]}" "$@"; set -- ${PREFLIGHT_ARGUMENTS[@]+"${PREFLIGHT_ARGUMENTS[@]}"}
# lib.sh 带进来的 set -e 要关掉：下面拿 ((...)) 与 grep -c 的返回值做判断，
# 条件为假时它们返回 1，-e 会在那一行把整个脚本带走（rules/command-safety.md）。
set +e
ROOT="${1:-.}"
cd "$ROOT" 2>/dev/null || die "找不到仓根：$ROOT" \
  "把仓根作为第一个参数传进来： bash scripts/history-ordinal.sh <仓根> [变更史文件…]"
shift 2>/dev/null || true
# 变更史按月拆档的目录（<目录>/<年-月>.md）。扫哪几份、基准里算存量的是哪几份，都从这一张表现算，不各写一份：
# 两处各写时，存量那一处漏了 experiments-history/，搬进新文件的实验史条目被当成新条目判撞号。
HISTORY_SUBDIRECTORIES=(decisions-history experiments-history)
shopt -s nullglob
if (($#)); then
  HIST=("$@")
else
  HIST=(.claude/kb/*-history.md)
  for history_subdirectory in "${HISTORY_SUBDIRECTORIES[@]}"; do HIST+=(.claude/kb/"$history_subdirectory"/*.md); done
fi
shopt -u nullglob
history_file_re="-history\.md\$"
for history_subdirectory in "${HISTORY_SUBDIRECTORIES[@]}"; do history_file_re+="|/$history_subdirectory/[^/]+\.md\$"; done

# 窗口的起点：gate.sh 导出的 GATE_DIFF_BASE，单跑时现算。解析不到的（外层门禁的基准漏进了别的仓）判不了，不当成空窗口
BASE="${GATE_DIFF_BASE:-}"
if [[ -z "$BASE" ]]; then BASE="$(diff_base .)" || die "算不出 diff 基准" "照上面 diff_base 的原话改（多半是 GATE_BASE 写错了），再跑。"; fi
if [[ "$BASE" != HEAD ]] && ! git rev-parse --verify -q "$BASE^{commit}" >/dev/null 2>&1; then
  die "diff 基准 $BASE 在这个仓里解析不到提交" \
    "外层门禁的 GATE_DIFF_BASE 漏进了别的仓就会这样：单跑时 env -u GATE_DIFF_BASE，或者把 GATE_DIFF_BASE 设成这个仓里的提交。"
fi

# 一行标题里取出「日期（其 N）」这把钥匙；取不到的（没带序号的条目）不参与判定。
key_of() { grep -o '^### 20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]（其[^）]*）'; }

hits=(); legacy=0; checked=0
# 基准里各份变更史已有的条目标题（整行）。按月拆档时条目整份搬进基准里还没有的新文件，
# 搬过去的不是新取的号——不排掉的话，存量撞号会在搬家那一次被当成新撞号判红。
# ⚠️ 按整行比，不按「日期（其 N）」比：新写的一条若又取了已有的号，钥匙与基准里那条相同，
# 按钥匙排会把它一起排掉，这一路就永远不红（2026-09-12 写这段时实测）。
# ⚠️ 按基准当时的文件名取，不按现在的：文件改名或挪目录的那一次，现在的路径在基准里不存在，
# 按现在的取就一条都取不到，搬过去的存量撞号又会被当成新撞号（2026-09-12 挪进 decisions-history/ 时写的）。
base_history_files="$(git ls-tree -r --name-only "$BASE" -- .claude/kb 2>/dev/null | grep -E -- "$history_file_re" || true)"
# 存量：以基准里那几份为准数重复，只报数不判红
while IFS= read -r base_file; do
  [[ -n "$base_file" ]] || continue
  n=$(git show "$BASE:$base_file" 2>/dev/null | key_of | sort | uniq -d | wc -l)
  legacy=$((legacy + n))
done <<<"$base_history_files"
base_headings="$(while IFS= read -r base_file; do [[ -n "$base_file" ]] && git show "$BASE:$base_file" 2>/dev/null; done <<<"$base_history_files" | grep '^### 20' || true)"
for f in "${HIST[@]}"; do
  [[ -f "$f" ]] || continue
  checked=$((checked + 1))
  # 本次新增的条目标题：基准之后提交的、暂存的、没暂存的都算
  if git cat-file -e "$BASE:$f" 2>/dev/null; then
    mapfile -t added < <(git diff "$BASE" -- "$f" 2>/dev/null | sed -n 's/^+//p' | key_of)
  else
    # 基准里还没有的新文件（提交了、暂存了、没暂存都算）：基准里哪一份变更史都没有的标题，才是本次新写的条目
    mapfile -t added < <(grep '^### 20' "$f" | grep -vxF -f <(printf '%s\n' "$base_headings") | key_of || true)
  fi
  ((${#added[@]})) || continue
  # 撞号有两种：与文件里已有的条目撞，或本次新增的两条自己撞
  all="$(key_of < "$f")"
  for k in "${added[@]}"; do
    cnt=$(grep -cxF "$k" <<<"$all")
    ((cnt > 1)) && hits+=("$f  $k  在该文件里出现 $cnt 次")
  done
done

if ((checked == 0)); then
  warn "$ROOT/.claude/kb 下没有变更史文件，本阶段无对象可判（这不是通过）"
  exit 77
fi

if ((${#hits[@]})); then
  bad "本次新增的历史条目里有 ${#hits[@]} 处撞号"
  printf '     %s\n' "${hits[@]}"
  howto "取号前先查该文件里当天的最大号： grep -o '^### <日期>（其[^）]*）' <变更史文件> | sort -u"
  howto "把自己这条改成下一个没被占的号——先到先得，改别人已提交的那条会改坏引用它的锚点。"
  howto "并发会话的完整对法见 rules/session-wrapup.md 第 4 节。"
  exit 1
fi
ok "本次新增的历史条目没有撞号（查了 $checked 份变更史，窗口从 $BASE 起；存量 $legacy 处撞号不在本阶段射程，见文件头）"
