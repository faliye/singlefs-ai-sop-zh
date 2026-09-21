#!/usr/bin/env bash
# 版本纪律：改了规范本体就必须同时抬 VERSION。
#
# **「规范本体」管哪些路径，以本脚本下面那条 GOVERNED 为准，别处一律链过来。**
# 本轮审计实测：CLAUDE.md、README 的两处、session-wrapup 各说了一份不同的清单，
# 而真正执行的是这里——按文档改 templates/ 的人会被门禁拦下，
# 且看不出自己读的那份清单是不完整的（rules/kb-discipline.md：矛盾比空白更糟）。
#
# CLAUDE.md 首屏写着这条规矩，但它以前只是提醒句——scripts/ 改了、VERSION 不动、
# 全部门禁照绿（对抗测试实测）。按 rules/show-me-test.md：踩过的坑要做成
# 会失败的检查，不要做成提醒句。所以有了这个脚本。
#
#   version-discipline.sh <SOP 仓根>
#
# 只对 SOP 仓本身有意义（gate.sh 在 ROOT 是 SOP 仓时才调它）；
# 消费项目改的是自己的代码，不受这条管。
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="${1:-$(project_root)}"
[[ -d "$ROOT" ]] || die "找不到仓根：$ROOT" \
  "把 SOP 仓根作为第一个参数传进来： bash scripts/version-discipline.sh <仓根>"

BASE="$(diff_base "$ROOT")"
say "  diff 基准：$BASE"
files="$(changed_files "$ROOT" "$BASE")"

# GOVERNED —— 规范本体的唯一定义。改这一行就是改规矩，文档里不许再抄一份。
# README.md 在内：它载着安装步骤与变更门槛，改了而项目侧不知道，
# 等于别人照着旧说明装（本轮审计发现它此前不受任何一道门禁管）。
GOVERNED='^(rules/|scripts/|skills/|agents/|templates/|CLAUDE\.md$|README\.md$|install\.sh$|GLOSSARY\.md$|I18N$)'

governed="$(printf '%s\n' "$files" | grep -E "$GOVERNED" || true)"

if [[ -z "$governed" ]]; then
  ok "本次没改规范本体，版本纪律不适用"
  exit 0
fi
# 判据是「抬了」，不是「动过」。
# 只问 VERSION 在不在变更集里的话，往它末尾加个空行就能过闸——而消费项目读的是
# `cat VERSION` 的内容，一个字都没变（对抗测试实测，全门禁绿）。
# 顺带拦住降级：版本只许往上走。
old_ver="$(git -C "$ROOT" show "$BASE:VERSION" 2>/dev/null | tr -d '[:space:]' || true)"
new_ver="$(tr -d '[:space:]' < "$ROOT/VERSION" 2>/dev/null || true)"
if [[ -n "$new_ver" && "$old_ver" != "$new_ver" ]]; then
  if [[ -z "$old_ver" ]] || [[ "$(printf '%s\n%s\n' "$old_ver" "$new_ver" | sort -V | tail -1)" == "$new_ver" ]]; then
    ok "规范本体有改动，VERSION 抬到了 $new_ver（原 ${old_ver:-无}）"
    exit 0
  fi
  bad "VERSION 降级了：$old_ver → $new_ver"
  howto "版本只许往上走——降级会让已经装了新版的项目看到「上游更旧」，无从判断。" \
        "用 bash scripts/bump.sh <x.y.z> 抬一个比 $old_ver 大的版本。"
  exit 1
fi
bad "改了规范本体却没抬 VERSION（本体的定义见 scripts/version-discipline.sh 的 GOVERNED；当前仍是 ${new_ver:-空}）："
printf '%s\n' "$governed" | head -10 | sed 's/^/        /'
howto "用 bump.sh 一次抬齐所有语言仓（不要手改单个 VERSION）：" \
      "bash scripts/bump.sh <x.y.z>" \
      "项目侧靠版本戳发现规矩变了；VERSION 不动，改动就静默生效（CLAUDE.md 首屏）。"
exit 1
