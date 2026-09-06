#!/usr/bin/env bash
# 把本 SOP 接进一个项目（任一语言版本，目录名统一为 .claude/singlefs-ai-sop）。
#
# 用法（在项目根跑）：
#   git clone <singlefs-ai-sop> .claude/singlefs-ai-sop
#   bash .claude/singlefs-ai-sop/install.sh
#
# 原则：已存在的文件一律不覆盖，只报告；每一步写完都回读验证。
set -euo pipefail
PKG="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$PKG/scripts/lib.sh"

ROOT="${1:-$PWD}"
[[ -d "$ROOT" ]] || die "目标目录不存在：$ROOT" \
  "先建好项目目录，或把它作为第一个参数传进来： bash install.sh <项目根>"
ROOT="$(cd "$ROOT" && pwd)"
[[ "$ROOT" != "$PKG" ]] || die "不能装到自己身上" \
  "在**项目**根跑，不是在 SOP 包里跑：" \
  "cd <你的项目> && bash .claude/singlefs-ai-sop/install.sh"

VER="$(cat "$PKG/VERSION")"
head1 "安装 $(basename "$PKG") $VER → $ROOT"

created=0; skipped=0; STALE=()

# 溯源标记（generated-from）记的是**这份译文译自哪个版本的源文**，是分发层的账。
# 抄进使用者的项目就成了一条永远不会更新的陈旧标注，而且贴在一份他马上要动手改的
# 文件上（rules/doc-discipline.md：正文只写现状）。所以铺进项目时剥掉。
strip_stamp() {
  grep -vE '^(<!--|\(\*) generated-from: .+ sha256:[0-9a-f]{64} (-->|\*\))$' "$1" || true
}

put() { # put <目标相对路径> <内容来源:file|stdin>
  local rel="$1" src="${2:-}"
  local dst="$ROOT/$rel"
  # 先把「应该长什么样」算出来。桩是 heredoc 生成的（$src 为空），
  # 只比对有 $src 的那些，桩里的 description 落后了照样查不出来。
  local want; want="$(mktemp)"
  if [[ -n "$src" ]]; then strip_stamp "$src" > "$want"; else cat > "$want"; fi
  if [[ -e "$dst" ]]; then
    # 已存在不覆盖，但要看它是不是**落后于**上游那一份。
    # 不看的话：上游改了 skill 正文并抬了版本，重跑 install.sh → 内容一份没换，
    # 版本戳却被刷成新的，而版本戳是项目唯一的「规矩变了」信号
    # ——此刻它在说谎（对抗测试实测，gate 退出码 0）。
    if diff -q "$want" "$dst" >/dev/null 2>&1; then
      warn "已存在，跳过  $rel"
    else
      warn "已存在但与上游不同  $rel"; STALE+=("$rel")
    fi
    rm -f "$want"; skipped=$((skipped+1)); return 0
  fi
  mkdir -p "$(dirname "$dst")"
  mv "$want" "$dst"
  [[ -s "$dst" ]] || die "写入后回读为空：$rel" \
    "写进去的文件读回来是空的——多半是磁盘满了或目标目录只读。" \
    "看 df -h 与该目录权限，修好后重跑 install.sh（已存在的文件不会被覆盖）。"
  ok "创建  $rel"; created=$((created+1))
}

# 1. 项目 CLAUDE.md
put "CLAUDE.md" "$PKG/templates/CLAUDE.project.md"

# 2. kb 骨架
for f in "$PKG"/templates/kb/*.md; do
  [[ -e "$f" ]] || continue
  put ".claude/kb/$(basename "$f")" "$f"
done

# 2b. 警告记录的落点（rules/pushback-discipline.md）
# 只铺一个指路的占位文件，不铺格式说明——格式只许有一处，在那条规则里
# （rules/kb-discipline.md 第 4 条：同一个事实只许有一处权威记录）。
put ".claude/warnings/.keep" <<'KEEP'
# 警告记录放这里，按日期一天一个 YYYY-MM-DD.md。
# 反对过而对方仍然坚持时，那条警告写进当天这份文件；别处一律链过来，不抄第二份。
# 格式与判据只有一处：.claude/singlefs-ai-sop/rules/pushback-discipline.md
KEEP

# 3. scripts 包装（不写逻辑，只 exec 共享脚本）
for s in env check gate doc-lint lkmm gate-lint shell-lint; do
  put ".claude/scripts/$s.sh" <<WRAP
#!/usr/bin/env bash
# 包装：转发到共享脚本。逻辑不写在这里，写在 .claude/singlefs-ai-sop/scripts/。
exec bash "\$(dirname "\${BASH_SOURCE[0]}")/../singlefs-ai-sop/scripts/$s.sh" "\$(cd "\$(dirname "\${BASH_SOURCE[0]}")/../.." && pwd)" "\$@"
WRAP
  chmod +x "$ROOT/.claude/scripts/$s.sh" 2>/dev/null || true
done

# 3b. qemu 包装（在子目录里，单独处理）
put ".claude/scripts/qemu.sh" <<'WRAP'
#!/usr/bin/env bash
# 包装：转发到共享脚本。逻辑不写在这里，写在 .claude/singlefs-ai-sop/scripts/qemu/。
exec bash "$(dirname "${BASH_SOURCE[0]}")/../singlefs-ai-sop/scripts/qemu/run.sh" "$@"
WRAP
chmod +x "$ROOT/.claude/scripts/qemu.sh" 2>/dev/null || true

# 3c. litmus 骨架（内存序声明，项目本地）
for f in "$PKG"/templates/litmus/*.litmus; do
  [[ -e "$f" ]] || continue
  put "litmus/$(basename "$f")" "$f"
done

# 3d. agent 桩（与 skill 同构：正文只在共享层一处）
for f in "$PKG"/agents/*.md; do
  [[ -e "$f" ]] || continue
  n="$(basename "$f" .md)"
  [[ "$n" == "INDEX" ]] && continue
  put ".claude/agents/$n.md" <<STUB
---
name: $n
description: $(sed -n 's/^description: //p' "$f" | head -1)
---

正文在共享层，读它：\`.claude/singlefs-ai-sop/agents/$n.md\`

**不要把正文抄到这里。** 正文只该有一处，抄一份就多出第二处，两处早晚说不同的话。
STUB
done

# 4. skill 桩
for d in "$PKG"/skills/*/; do
  [[ -d "$d" ]] || continue
  n="$(basename "$d")"
  put ".claude/skills/$n/SKILL.md" <<STUB
---
name: $n
description: $(sed -n 's/^description: //p' "$d/SKILL.md" | head -1)
---

正文在共享层，读它：\`.claude/singlefs-ai-sop/skills/$n/SKILL.md\`

**不要把正文抄到这里。** 正文只该有一处，抄一份就多出第二处，两处早晚说不同的话。
STUB
done

# 5. 版本戳。**有文件落后于上游时不刷**——刷了就等于替项目声明「已经是新版了」，
# 而它的 skill / 骨架还是旧的。版本戳是项目唯一的「规矩变了」信号，不许让它说谎。
if [[ ${#STALE[@]} -gt 0 ]]; then
  say ""
  bad "${#STALE[@]} 份内容落后于上游，版本戳**没有**刷新（仍是 $(cat "$ROOT/.singlefs-ai-sop-version" 2>/dev/null || echo 无)）："
  printf '%s\n' "${STALE[@]}" | sed 's/^/        /'
  howto "逐份看差异，决定合并还是留着自己的改法：" \
        "diff <(sed '/generated-from/d' $PKG/<对应源文>) <这份文件>" \
        "改完再跑一次 install.sh；全部对齐了版本戳才会刷到 $VER。" \
        "不刷戳是有意的：戳说「新版」而内容是旧的，比不装还糟。"
  exit 1
fi
printf '%s\n' "$VER" > "$ROOT/.singlefs-ai-sop-version"
[[ "$(cat "$ROOT/.singlefs-ai-sop-version")" == "$VER" ]] || die "版本戳回读不一致" \
  "版本戳写进去和读出来不一样，此刻项目声明的版本是错的，门禁会拿它去比对。" \
  "看 df -h 与项目根的权限，修好后重跑 install.sh。"
ok "版本戳  .singlefs-ai-sop-version = $VER"

# 6. gitignore 提醒（不自动改）
if [[ -f "$ROOT/.gitignore" ]] && ! grep -q 'singlefs-ai-sop' "$ROOT/.gitignore"; then
  warn "建议在 .gitignore 或 .gitmodules 里处理 .claude/singlefs-ai-sop/ 的归属"
fi

say ""
ok "完成：新建 $created 个，跳过 $skipped 个（已存在的不覆盖）"
say "下一步： bash .claude/scripts/gate.sh"
