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
SEEDED=(); OWNED_HIT=(); ownfails=0
declare -A OWNED=()

# ── 项目接管的文件：不再拿它们跟上游模板比 ────────────────
# `put` 铺下去的 kb 骨架、skill 桩是**给项目改的**——kb 尤其如此，
# 项目不改它才不正常。而 STALE 的判据只是「与上游不同」，分不出
# 「项目接管了这份」和「项目落后于上游」。
# 于是任何一个动过自己 kb 的项目，装完第一次之后版本戳就再也刷不动了
# （实测于使用者项目：12 份全是项目自己改的，版本戳因此卡在旧版，门禁阶段 0 长红）。
#
# 所以让项目把接管的那几份**显式写出来**：$ROOT/.claude/install-owned，
# 一行一条，`<相对路径>  # 为什么`。理由不许省——接管一份文件的代价是
# **此后上游对它的改动都不会再送到**，写理由的时候要正面对上这一点。
# 清单一律报进输出：静悄悄少比几份，和这道守卫没实现长得一模一样。
# 登记了的那份项目要是删掉了，也不重铺：删掉是项目的决定（判据在 put）。
OWNFILE="$ROOT/.claude/install-owned"
if [[ -f "$OWNFILE" ]]; then
  ownline=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    ownline=$((ownline+1))
    [[ -z "${line//[[:space:]]/}" || "${line#"${line%%[![:space:]]*}"}" == \#* ]] && continue
    if [[ "$line" != *\#* ]]; then
      bad ".claude/install-owned:$ownline  这一条没写理由：$line"
      howto "格式： .claude/kb/INDEX.md  # 索引由项目自己维护，模板只是起手" \
            "理由不许省：接管一份文件之后，上游对它的改动就再也不会送到你这儿了。"
      ownfails=$((ownfails+1)); continue
    fi
    orel="${line%%#*}"; owhy="${line#*#}"
    orel="${orel#"${orel%%[![:space:]]*}"}"; orel="${orel%"${orel##*[![:space:]]}"}"
    owhy="${owhy#"${owhy%%[![:space:]]*}"}"; owhy="${owhy%"${owhy##*[![:space:]]}"}"
    if [[ -z "$orel" || -z "$owhy" ]]; then
      bad ".claude/install-owned:$ownline  路径或理由是空的：$line"
      howto "一行一条，形如： .claude/kb/decisions.md  # 决策正文归项目，模板只给了格式"
      ownfails=$((ownfails+1)); continue
    fi
    OWNED["$orel"]="$owhy"
  done < "$OWNFILE"
fi

# 溯源标记（generated-from）记的是**这份译文译自哪个版本的源文**，是分发层的账。
# 抄进使用者的项目就成了一条永远不会更新的陈旧标注，而且贴在一份他马上要动手改的
# 文件上（rules/writing-discipline.md：正文只写现状）。所以铺进项目时剥掉。
strip_stamp() {
  grep -vE '^<!-- generated-from: .+ sha256:[0-9a-f]{64} -->$' "$1" || true
}

put() { # put <目标相对路径> <内容来源:file|stdin>
  local rel="$1" src="${2:-}"
  local dst="$ROOT/$rel"
  SEEDED+=("$rel")
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
    elif [[ -n "${OWNED[$rel]:-}" ]]; then
      warn "已接管，不比对  $rel"; OWNED_HIT+=("$rel")
    else
      warn "已存在但与上游不同  $rel"; STALE+=("$rel")
    fi
    rm -f "$want"; skipped=$((skipped+1)); return 0
  fi
  # 接管清单里登记了、项目又删掉了的那份，不重铺：删掉是项目的决定（例：kb 骨架被项目自己的那一份取代）。
  # 不这么判，下一次 install.sh 会安静地把它铺回来，铺回来的那份又被门禁拿去判（0.0.48 收尾时查出）。
  if [[ -n "${OWNED[$rel]:-}" ]]; then
    warn "已接管，项目删掉了它，不重铺  $rel"; OWNED_HIT+=("$rel")
    rm -f "$want"; skipped=$((skipped+1)); return 0
  fi
  mkdir -p "$(dirname "$dst")"
  mv "$want" "$dst"
  # mktemp 造出来的是 0600，mv 原样保留：铺下去的 CLAUDE.md、kb、skill 桩全是「只有我自己读得了」，
  # 而它们是给整个项目看的（审计实测：装出来的项目里 13 份都是 600）。包装脚本随后再 chmod +x。
  chmod 644 "$dst" 2>/dev/null || true
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
# 包装全文只写在 wrapper_text 这一处：铺新包装、认出退役包装，比的是同一份文本。
WRAPPED_SCRIPTS=(env check gate doc-lint naming-lint gate-lint shell-lint)
wrapper_text() { # wrapper_text <共享脚本名，不带 .sh>
  local s="$1"
  cat <<WRAP
#!/usr/bin/env bash
# 包装：转发到共享脚本。逻辑不写在这里，写在 .claude/singlefs-ai-sop/scripts/。
# 只多做一件事：副本不在时说清怎么办。副本被 .gitignore 挡着，新 clone 出来的仓里它不存在，
# 而 exec 一个不存在的路径只会得到 bash 的「No such file or directory」，一句出路都没有。
shared="\$(dirname "\${BASH_SOURCE[0]}")/../singlefs-ai-sop/scripts/$s.sh"
if [[ ! -f "\$shared" ]]; then
  echo "  ✗ 找不到共享脚本：\$shared"
  echo "     → 怎么办： 规范副本没装（它被 .gitignore 挡着，不随仓库走）。"
  echo "                把 singlefs-ai-sop-<语言> 仓拷进 .claude/singlefs-ai-sop/，再跑它的 install.sh。"
  exit 1
fi
exec bash "\$shared" "\$(cd "\$(dirname "\${BASH_SOURCE[0]}")/../.." && pwd)" "\$@"
WRAP
}
# 0.0.49 及以前铺的包装是三行，不管副本在不在。认退役包装时两种形态都要认（审核实测：只认现行形态时，旧形态的退役包装一声不响、照常刷戳）。
wrapper_text_before_0_0_50() { # wrapper_text_before_0_0_50 <共享脚本名，不带 .sh>
  local s="$1"
  cat <<WRAP
#!/usr/bin/env bash
# 包装：转发到共享脚本。逻辑不写在这里，写在 .claude/singlefs-ai-sop/scripts/。
exec bash "\$(dirname "\${BASH_SOURCE[0]}")/../singlefs-ai-sop/scripts/$s.sh" "\$(cd "\$(dirname "\${BASH_SOURCE[0]}")/../.." && pwd)" "\$@"
WRAP
}
for s in "${WRAPPED_SCRIPTS[@]}"; do
  put ".claude/scripts/$s.sh" < <(wrapper_text "$s")
  chmod +x "$ROOT/.claude/scripts/$s.sh" 2>/dev/null || true
done

# 3a. 退役的包装：这一版不再铺、项目里却还一字未改地留着的那几份。
# 共享脚本删掉之后（例：0.0.50 把 lkmm.sh 交给使用者项目自己管），项目里的包装转发到一个不存在的脚本，
# 跑它的人看到的出路是「规范副本没装」，而副本明明装着（审核实测）。
# 只认与包装模板（现行或 0.0.49 以前的形态）一字不差、而且它转发的共享脚本这一版里确实没有的那份：
# 项目改过、写了自己逻辑的同名文件不归这里管；项目照模板给一个还在的共享脚本（例如 bump.sh）自己加的包装也不算退役。
# 这一版铺的那几份，共享脚本都在，所以不用另外排除。
RETIRED=()
for f in "$ROOT"/.claude/scripts/*.sh; do
  [[ -f "$f" ]] || continue
  s="$(basename "$f" .sh)"
  if [[ -f "$PKG/scripts/$s.sh" ]]; then continue; fi
  content="$(cat "$f")"
  if [[ "$content" == "$(wrapper_text "$s")" || "$content" == "$(wrapper_text_before_0_0_50 "$s")" ]]; then
    RETIRED+=(".claude/scripts/$s.sh")
  fi
done

# 3b. agent 桩（与 skill 同构：正文只在共享层一处）
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

# 4b. 接管清单的校验：只能写 install.sh 真的会铺的那些路径。
# 写别的路径不会有任何作用，而清单看起来还是「已经接管了」——
# 不起作用的条目比没有条目更糟，它让人以为那份文件已经被豁免了。
for orel in "${!OWNED[@]}"; do
  hit=0
  for srel in "${SEEDED[@]}"; do [[ "$srel" == "$orel" ]] && { hit=1; break; }; done
  if [[ $hit -eq 0 ]]; then
    bad ".claude/install-owned  这条路径 install.sh 根本不铺，写了也没用：$orel"
    howto "只能写 install.sh 会铺下去的那些：CLAUDE.md、.claude/kb/*.md、" \
          ".claude/skills/*/SKILL.md、.claude/agents/*.md、.claude/scripts/*.sh。" \
          "路径拼错就改对；那份文件已经不铺了，就把这一行删掉。"
    ownfails=$((ownfails+1))
  fi
done
if [[ $ownfails -gt 0 ]]; then
  say ""
  bad "接管清单有 $ownfails 处不合规，版本戳**没有**刷新"
  howto "先把 .claude/install-owned 改对再重跑。清单坏了的时候不许放行——" \
        "一份读不准的接管清单，等于把「内容落后就不刷戳」这道守卫悄悄关掉了。"
  exit 1
fi
if [[ ${#OWNED_HIT[@]} -gt 0 ]]; then
  say ""
  warn "按 .claude/install-owned 不比对 ${#OWNED_HIT[@]} 份——项目已接管，上游对它们的改动不会再送到："
  for orel in "${OWNED_HIT[@]}"; do say "        $orel  —— ${OWNED[$orel]}"; done
fi

# 5. 版本戳。**有文件落后于上游时不刷**——刷了就等于替项目声明「已经是新版了」，
# 而它的 skill / 骨架还是旧的。版本戳是项目唯一的「规矩变了」信号，不许让它说谎。
stamp_blocked=0
if [[ ${#STALE[@]} -gt 0 ]]; then
  say ""
  bad "${#STALE[@]} 份内容落后于上游，版本戳**没有**刷新（仍是 $(cat "$ROOT/.singlefs-ai-sop-version" 2>/dev/null || echo 无)）："
  printf '%s\n' "${STALE[@]}" | sed 's/^/        /'
  howto "逐份看差异，决定合并还是留着自己的改法：" \
        "diff <(sed '/generated-from/d' $PKG/<对应源文>) <这份文件>" \
        "改完再跑一次 install.sh；全部对齐了版本戳才会刷到 $VER。" \
        "不刷戳是有意的：戳说「新版」而内容是旧的，比不装还糟。"
  stamp_blocked=1
fi
# 退役的包装还在，同样不刷：戳说「新版」，项目里却留着一个转发到已删脚本的包装。
if [[ ${#RETIRED[@]} -gt 0 ]]; then
  say ""
  bad "${#RETIRED[@]} 份包装这一版已经不铺了，版本戳**没有**刷新："
  printf '%s\n' "${RETIRED[@]}" | sed 's/^/        /'
  howto "它转发到的共享脚本已经不在这一版里；跑它会报「找不到共享脚本」，那句出路说的「副本没装」并不是原因。" \
        "先确认项目里没有别处在调它（grep -rn 它的文件名），删掉它，再跑一次 install.sh。" \
        "项目还要这件事，就把它改写成项目自己的脚本；为什么删、那件事现在归谁，见 .claude/singlefs-ai-sop/CHANGELOG.md。"
  stamp_blocked=1
fi
[[ $stamp_blocked -eq 0 ]] || exit 1
# 戳只许往上走。副本比戳旧时（另一个人拷了旧副本、或者拷到一半），照写就是把戳**降级**，
# 而戳是入库的：降级会顺着提交传给所有人，门禁从此按旧规矩判（审计实测这条路是通的）。
old_ver="$(cat "$ROOT/.singlefs-ai-sop-version" 2>/dev/null || true)"
if [[ -n "$old_ver" && "$old_ver" != "$VER" \
      && "$(printf '%s\n' "$old_ver" "$VER" | sort -V | tail -1)" == "$old_ver" ]]; then
  bad "不给版本戳降级：项目现在声明 $old_ver，而这份副本是 $VER"
  howto "副本比项目声明的版本旧——多半是拷了一份旧的，或者拷到一半。" \
        "先把副本换成 $old_ver 或更新的那一版（从兄弟目录的上游仓拷），再跑 install.sh。" \
        "真要退回旧版，先手工把 .singlefs-ai-sop-version 改成 $VER，再跑一次。"
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
