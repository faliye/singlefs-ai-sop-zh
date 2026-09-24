#!/usr/bin/env bash
# gate-similar: doc-lint.sh 它判每份 kb 文档此刻的文本形态，不看改动；撞号只判这一次新增的条目（存量撞号一改就改坏已经指过去的锚点），要拿 HEAD 比
# 本次新增的历史条目有没有撞号。
#
# 变更史的条目标题形如 `### 2026-09-01（其十六）：……`，同一天按「其 N」顺序编号。
# **这个编号是先到先得的公共资源**：并发会话各写各的，取号前不查最大号就会撞
# （rules/session-wrapup.md 第 4 节：公共编号先到先得）。
# 撞号的后果不是难看——别处拿「日期（其 N）」当锚点引用时，一个日期下有两条同号条目，
# 那个锚点指向哪一条无从判断。
# 原是使用者项目的一个本地阶段，判据通用，收归这里。
#
# 只判**本次新增**的条目（与 HEAD 比）：存量撞号只报数，不判红——
# 那是历史，改它会改坏已经指过去的锚点。
#
# 用法：
#   history-ordinal.sh <仓根> [变更史文件…]
# 不给文件就按 <仓根>/.claude/kb 下的 *-history.md 与 decisions-history/*.md 找。
# 一份都没有时退 77（本次无对象可判），不报绿。
#
# 判据是「日期（其 N）」这个中文形态，别的语言的变更史不长这样——
# 那些仓里这一项报未实现，不假装通过（rules/show-me-test.md）。
set -uo pipefail
# lib.sh 要在 cd 之前按绝对路径 source：cd 之后 BASH_SOURCE 的相对路径就指不到了。
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# lib.sh 带进来的 set -e 要关掉：下面拿 ((...)) 与 grep -c 的返回值做判断，
# 条件为假时它们返回 1，-e 会在那一行把整个脚本带走（rules/command-safety.md）。
set +e
ROOT="${1:-.}"
cd "$ROOT" || exit 2
shift 2>/dev/null || true
# 决策变更史 2026-09-12 起按月拆档（decisions-history/<年-月>.md），几份都要查
shopt -s nullglob
if (($#)); then
  HIST=("$@")
else
  HIST=(.claude/kb/*-history.md .claude/kb/decisions-history/*.md .claude/kb/experiments-history/*.md)
fi
shopt -u nullglob

# 一行标题里取出「日期（其 N）」这把钥匙；取不到的（没带序号的条目）不参与判定。
key_of() { grep -o '^### 20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]（其[^）]*）'; }

hits=(); legacy=0; checked=0
# HEAD 里各份变更史已有的条目标题（整行）。按月拆档时条目整份搬进 HEAD 里还没有的新文件，
# 搬过去的不是新取的号——不排掉的话，存量撞号会在搬家那一次被当成新撞号判红。
# ⚠️ 按整行比，不按「日期（其 N）」比：新写的一条若又取了已有的号，钥匙与 HEAD 里那条相同，
# 按钥匙排会把它一起排掉，这一路就永远不红（2026-09-12 写这段时实测）。
# ⚠️ 按 HEAD 当时的文件名取，不按现在的：文件改名或挪目录的那一次，现在的路径在 HEAD 里不存在，
# 按现在的取就一条都取不到，搬过去的存量撞号又会被当成新撞号（2026-09-12 挪进 decisions-history/ 时写的）。
head_history_files="$(git ls-tree -r --name-only HEAD -- .claude/kb 2>/dev/null | grep -E -- '-history\.md$|/decisions-history/[^/]+\.md$' || true)"
# 存量：以 HEAD 那几份为准数重复，只报数不判红
while IFS= read -r head_file; do
  [[ -n "$head_file" ]] || continue
  n=$(git show "HEAD:$head_file" 2>/dev/null | key_of | sort | uniq -d | wc -l)
  legacy=$((legacy + n))
done <<<"$head_history_files"
head_headings="$(while IFS= read -r head_file; do [[ -n "$head_file" ]] && git show "HEAD:$head_file" 2>/dev/null; done <<<"$head_history_files" | grep '^### 20' || true)"
for f in "${HIST[@]}"; do
  [[ -f "$f" ]] || continue
  checked=$((checked + 1))
  # 本次新增的条目标题
  if git cat-file -e "HEAD:$f" 2>/dev/null; then
    mapfile -t added < <(git diff HEAD -- "$f" 2>/dev/null | sed -n 's/^+//p' | key_of)
  else
    # HEAD 里还没有的新文件（暂存了没暂存都算）：HEAD 里哪一份变更史都没有的标题，才是本次新写的条目
    mapfile -t added < <(grep '^### 20' "$f" | grep -vxF -f <(printf '%s\n' "$head_headings") | key_of || true)
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
ok "本次新增的历史条目没有撞号（存量 $legacy 处撞号不在本阶段射程，见文件头）"
