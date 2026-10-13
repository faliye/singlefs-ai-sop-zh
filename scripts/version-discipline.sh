#!/usr/bin/env bash
# admission: always 判的是这一次 diff 窗口里改没改规范本体、抬没抬版本，一秒跑完
# run-condition: command git
# 版本纪律：改了规范本体就必须同时抬 VERSION。
#
# 「规范本体」管哪些路径以下面的 GOVERNED 为准，文档里链过来、不另抄一份（rules/kb-discipline.md：矛盾比空白更糟）。
#
#   version-discipline.sh <SOP 仓根>
#
# 只对 SOP 仓本身有意义（gate.sh 在 ROOT 是 SOP 仓时才调它）。
# 退出码：0 = 抬了；1 = 该抬没抬、降级了，或者判不了（改动清单、基准里的 VERSION 读不到）；
#   77 = 这一次没改规范本体，无对象可判（gate.sh 记「本次未跑」，不记通过）。
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight "${BASH_SOURCE[0]}" "$@"; set -- ${PREFLIGHT_ARGUMENTS[@]+"${PREFLIGHT_ARGUMENTS[@]}"}

ROOT="${1:-$(project_root)}"
[[ -d "$ROOT" ]] || die "找不到仓根：$ROOT" \
  "把 SOP 仓根作为第一个参数传进来： bash scripts/version-discipline.sh <仓根>"

BASE="$(diff_base "$ROOT")"
say "  diff 基准：$BASE"
changed_files_list="$(changed_files "$ROOT" "$BASE")" || die "取不到相对基准 $BASE 的改动清单（git diff / ls-files 失败，原话在上面）" \
  "先在 $ROOT 跑 git status 与 git diff --name-only $BASE 看 git 报什么，修好再跑。" \
  "清单少一截时，这一条会把改了规范本体判成「没改」，所以取不全就不判。"

# 规范本体的唯一定义，改这一行就是改规矩。README.md 在内：它载着安装步骤与变更门槛。
GOVERNED='^(rules/|scripts/|skills/|agents/|templates/|CLAUDE\.md$|README\.md$|install\.sh$|GLOSSARY\.md$|I18N$)'

governed_changed_files="$(printf '%s\n' "$changed_files_list" | grep -E "$GOVERNED" || true)"

if [[ -z "$governed_changed_files" ]]; then
  warn "这一次的改动没碰规范本体（查了 $(printf '%s\n' "$changed_files_list" | grep -c .) 个改动的文件），版本纪律无对象可判（这不是通过）"
  exit 77
fi
# 判据是内容「抬了」，不是文件「动过」：往 VERSION 末尾加个空行就能过「动过」（实测）。版本只许往上走。
# 「基准里本来没有 VERSION」与「读不到」要分开，否则读取失败也按「原 无」放行：先看文件树里有没有，有才读。
old_version=""
if git -C "$ROOT" rev-parse --verify -q "$BASE^{commit}" >/dev/null; then
  base_version_entry="$(git -C "$ROOT" ls-tree "$BASE" -- VERSION)" || die "读不了基准 $BASE 的文件树（git ls-tree 失败，原话在上面）" \
    "先在 $ROOT 跑 git ls-tree $BASE -- VERSION 看 git 报什么，修好再跑。"
  if [[ -n "$base_version_entry" ]]; then
    old_version="$(git -C "$ROOT" show "$BASE:VERSION" | tr -d '[:space:]')" || die "基准 $BASE 里有 VERSION，却读不出它的内容（git show 失败，原话在上面）" \
      "对象库可能坏了：git -C $ROOT fsck 看一眼，修好再跑。读不出旧版本就判不了抬没抬。"
  fi
fi
new_version="$(tr -d '[:space:]' < "$ROOT/VERSION" 2>/dev/null || true)"
if [[ -n "$new_version" && "$old_version" != "$new_version" ]]; then
  if [[ -z "$old_version" ]] || [[ "$(printf '%s\n%s\n' "$old_version" "$new_version" | sort -V | tail -1)" == "$new_version" ]]; then
    ok "规范本体有改动，VERSION 抬到了 $new_version（原 ${old_version:-无}）"
    exit 0
  fi
  bad "VERSION 降级了：$old_version → $new_version"
  howto "版本只许往上走——降级会让已经装了新版的项目看到「上游更旧」，无从判断。" \
        "用 bash scripts/bump.sh <x.y.z> 抬一个比 $old_version 大的版本。"
  exit 1
fi
bad "改了规范本体却没抬 VERSION（本体的定义见 scripts/version-discipline.sh 的 GOVERNED；当前仍是 ${new_version:-空}）："
printf '%s\n' "$governed_changed_files" | head -10 | sed 's/^/        /'
howto "用 bump.sh 一次抬齐所有语言仓（不要手改单个 VERSION）：" \
      "bash scripts/bump.sh <x.y.z>" \
      "项目侧靠版本戳发现规矩变了；VERSION 不动，改动就静默生效（CLAUDE.md 首屏）。"
exit 1
