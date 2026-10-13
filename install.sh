#!/usr/bin/env bash
# admission: always 装与升级副本之后都跑：它逐份比对铺下去的文件、刷版本戳，每次项目那边的状态都可能不一样
# run-condition: command gawk
# 把本 SOP 接进一个项目（任一语言版本，目录名统一为 .claude/singlefs-ai-sop）。
#
# 用法（在项目根跑）：
#   git clone <singlefs-ai-sop> .claude/singlefs-ai-sop
#   bash .claude/singlefs-ai-sop/install.sh
#
# 原则：已存在的文件一律不覆盖，只报告；每一步写完都回读验证。
set -euo pipefail
PACKAGE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$PACKAGE_ROOT/scripts/lib.sh"
preflight "${BASH_SOURCE[0]}" "$@"; set -- ${PREFLIGHT_ARGUMENTS[@]+"${PREFLIGHT_ARGUMENTS[@]}"}

ROOT="${1:-$PWD}"
[[ -d "$ROOT" ]] || die "目标目录不存在：$ROOT" \
  "先建好项目目录，或把它作为第一个参数传进来： bash install.sh <项目根>"
ROOT="$(cd "$ROOT" && pwd)"
[[ "$ROOT" != "$PACKAGE_ROOT" ]] || die "不能装到自己身上" \
  "在**项目**根跑，不是在 SOP 包里跑：" \
  "cd <你的项目> && bash .claude/singlefs-ai-sop/install.sh"

PACKAGE_VERSION="$(cat "$PACKAGE_ROOT/VERSION")"
head1 "安装 $(basename "$PACKAGE_ROOT") $PACKAGE_VERSION → $ROOT"

created=0; skipped=0; STALE=()
SEEDED=(); OWNED_HIT=(); owned_list_problem_count=0
declare -A OWNED=()

# ── 项目接管的文件：不再拿它们跟上游模板比 ────────────────
# `put` 铺下去的 kb 骨架、skill 桩是**给项目改的**——kb 尤其如此，
# 项目不改它才不正常。而 STALE 的判据只是「与上游不同」，分不出
# 「项目接管了这份」和「项目落后于上游」。
# 于是任何一个动过自己 kb 的项目，装完第一次之后版本戳就再也刷不动了
# （实测于使用者项目：12 份全是项目自己改的，版本戳因此卡在旧版，门禁的「规范版本」阶段长红）。
#
# 所以让项目把接管的那几份**显式写出来**：$ROOT/.claude/install-owned，
# 一行一条，`<相对路径>  # 为什么`。理由不许省——接管一份文件的代价是
# **此后上游对它的改动都不会再送到**，写理由的时候要正面对上这一点。
# 清单一律报进输出：静悄悄少比几份，和这道守卫没实现长得一模一样。
# 登记了的那份项目要是删掉了，也不重铺：删掉是项目的决定（判据在 put）。
OWNED_LIST_FILE="$ROOT/.claude/install-owned"
if [[ -f "$OWNED_LIST_FILE" ]]; then
  owned_list_line_number=0
  while IFS= read -r owned_list_line || [[ -n "$owned_list_line" ]]; do
    owned_list_line_number=$((owned_list_line_number+1))
    [[ -z "${owned_list_line//[[:space:]]/}" || "${owned_list_line#"${owned_list_line%%[![:space:]]*}"}" == \#* ]] && continue
    if [[ "$owned_list_line" != *\#* ]]; then
      bad ".claude/install-owned:$owned_list_line_number  这一条没写理由：$owned_list_line"
      howto "格式： .claude/kb/INDEX.md  # 索引由项目自己维护，模板只是起手" \
            "理由不许省：接管一份文件之后，上游对它的改动就再也不会送到你这儿了。"
      owned_list_problem_count=$((owned_list_problem_count+1)); continue
    fi
    owned_relative_path="${owned_list_line%%#*}"; owned_reason="${owned_list_line#*#}"
    owned_relative_path="${owned_relative_path#"${owned_relative_path%%[![:space:]]*}"}"; owned_relative_path="${owned_relative_path%"${owned_relative_path##*[![:space:]]}"}"
    owned_reason="${owned_reason#"${owned_reason%%[![:space:]]*}"}"; owned_reason="${owned_reason%"${owned_reason##*[![:space:]]}"}"
    if [[ -z "$owned_relative_path" || -z "$owned_reason" ]]; then
      bad ".claude/install-owned:$owned_list_line_number  路径或理由是空的：$owned_list_line"
      howto "一行一条，形如： .claude/kb/decisions.md  # 决策正文归项目，模板只给了格式"
      owned_list_problem_count=$((owned_list_problem_count+1)); continue
    fi
    OWNED["$owned_relative_path"]="$owned_reason"
  done < "$OWNED_LIST_FILE"
fi

# 溯源标记（generated-from）记的是**这份译文译自哪个版本的源文**，是分发层的账。
# 抄进使用者的项目就成了一条永远不会更新的陈旧标注，而且贴在一份他马上要动手改的
# 文件上（rules/writing-discipline.md：正文只写现状）。所以铺进项目时剥掉。
strip_stamp() {
  grep -vE '^<!-- generated-from: .+ sha256:[0-9a-f]{64} -->$' "$1" || true
}

put() { # put <目标相对路径> <内容来源:file|stdin>
  local relative_path="$1" source_file="${2:-}"
  local destination_path="$ROOT/$relative_path"
  SEEDED+=("$relative_path")
  # 先把「应该长什么样」算出来。桩是 heredoc 生成的（$source_file 为空），
  # 只比对有 $source_file 的那些，桩里的 description 落后了照样查不出来。
  local wanted_content_file; wanted_content_file="$(mktemp)"
  if [[ -n "$source_file" ]]; then strip_stamp "$source_file" > "$wanted_content_file"; else cat > "$wanted_content_file"; fi
  if [[ -e "$destination_path" ]]; then
    # 已存在不覆盖，但要看它是不是**落后于**上游那一份。
    # 不看的话：上游改了 skill 正文并抬了版本，重跑 install.sh → 内容一份没换，
    # 版本戳却被刷成新的，而版本戳是项目唯一的「规矩变了」信号
    # ——此刻它在说谎（对抗测试实测，gate 退出码 0）。
    if diff -q "$wanted_content_file" "$destination_path" >/dev/null 2>&1; then
      warn "已存在，跳过  $relative_path"
    elif [[ -n "${OWNED[$relative_path]:-}" ]]; then
      warn "已接管，不比对  $relative_path"; OWNED_HIT+=("$relative_path")
    else
      warn "已存在但与上游不同  $relative_path"; STALE+=("$relative_path")
    fi
    rm -f "$wanted_content_file"; skipped=$((skipped+1)); return 0
  fi
  # 接管清单里登记了、项目又删掉了的那份，不重铺：删掉是项目的决定（例：kb 骨架被项目自己的那一份取代）。
  # 不这么判，下一次 install.sh 会安静地把它铺回来，铺回来的那份又被门禁拿去判（0.0.48 收尾时查出）。
  if [[ -n "${OWNED[$relative_path]:-}" ]]; then
    warn "已接管，项目删掉了它，不重铺  $relative_path"; OWNED_HIT+=("$relative_path")
    rm -f "$wanted_content_file"; skipped=$((skipped+1)); return 0
  fi
  mkdir -p "$(dirname "$destination_path")"
  mv "$wanted_content_file" "$destination_path"
  # mktemp 造出来的是 0600，mv 原样保留：铺下去的 CLAUDE.md、kb、skill 桩全是「只有我自己读得了」，
  # 而它们是给整个项目看的（审计实测：装出来的项目里 13 份都是 600）。包装脚本随后再 chmod +x。
  chmod 644 "$destination_path" 2>/dev/null || true
  [[ -s "$destination_path" ]] || die "写入后回读为空：$relative_path" \
    "写进去的文件读回来是空的——多半是磁盘满了或目标目录只读。" \
    "看 df -h 与该目录权限，修好后重跑 install.sh（已存在的文件不会被覆盖）。"
  ok "创建  $relative_path"; created=$((created+1))
}

# 项目 CLAUDE.md
put "CLAUDE.md" "$PACKAGE_ROOT/templates/CLAUDE.project.md"

# kb 骨架
for template_file in "$PACKAGE_ROOT"/templates/kb/*.md; do
  [[ -e "$template_file" ]] || continue
  put ".claude/kb/$(basename "$template_file")" "$template_file"
done

# 警告记录的落点（rules/pushback-discipline.md）
# 只铺一个指路的占位文件，不铺格式说明——格式只许有一处，在那条规则里
# （rules/kb-discipline.md 第 4 条：同一个事实只许有一处权威记录）。
put ".claude/warnings/.keep" <<'KEEP'
# 警告记录放这里，按日期一天一个 YYYY-MM-DD.md。
# 反对过而对方仍然坚持时，那条警告写进当天这份文件；别处一律链过来，不抄第二份。
# 格式与判据只有一处：.claude/singlefs-ai-sop/rules/pushback-discipline.md
KEEP

# scripts 包装（不写逻辑，只 exec 共享脚本）
# 包装全文只写在 wrapper_text 这一处：铺新包装、认出退役包装，比的是同一份文本。
WRAPPED_SCRIPTS=(env check gate doc-lint naming-lint gate-lint shell-lint)
wrapper_text() { # wrapper_text <共享脚本名，不带 .sh>
  local script_name="$1"
  cat <<WRAP
#!/usr/bin/env bash
# 包装：转发到共享脚本。逻辑不写在这里，写在 .claude/singlefs-ai-sop/scripts/。
# 只多做一件事：副本不在时说清怎么办。副本被 .gitignore 挡着，新 clone 出来的仓里它不存在，
# 而 exec 一个不存在的路径只会得到 bash 的「No such file or directory」，一句出路都没有。
shared="\$(dirname "\${BASH_SOURCE[0]}")/../singlefs-ai-sop/scripts/$script_name.sh"
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
  local script_name="$1"
  cat <<WRAP
#!/usr/bin/env bash
# 包装：转发到共享脚本。逻辑不写在这里，写在 .claude/singlefs-ai-sop/scripts/。
exec bash "\$(dirname "\${BASH_SOURCE[0]}")/../singlefs-ai-sop/scripts/$script_name.sh" "\$(cd "\$(dirname "\${BASH_SOURCE[0]}")/../.." && pwd)" "\$@"
WRAP
}
for script_name in "${WRAPPED_SCRIPTS[@]}"; do
  put ".claude/scripts/$script_name.sh" < <(wrapper_text "$script_name")
  chmod +x "$ROOT/.claude/scripts/$script_name.sh" 2>/dev/null || true
done

# 退役的包装：这一版不再铺、项目里却还一字未改地留着的那几份。
# 共享脚本删掉之后（例：0.0.50 把 lkmm.sh 交给使用者项目自己管），项目里的包装转发到一个不存在的脚本，
# 跑它的人看到的出路是「规范副本没装」，而副本明明装着（审核实测）。
# 只认与包装模板（现行或 0.0.49 以前的形态）一字不差、而且它转发的共享脚本这一版里确实没有的那份：
# 项目改过、写了自己逻辑的同名文件不归这里管；项目照模板给一个还在的共享脚本（例如 bump.sh）自己加的包装也不算退役。
# 这一版铺的那几份，共享脚本都在，所以不用另外排除。
RETIRED=()
for existing_wrapper in "$ROOT"/.claude/scripts/*.sh; do
  [[ -f "$existing_wrapper" ]] || continue
  script_name="$(basename "$existing_wrapper" .sh)"
  if [[ -f "$PACKAGE_ROOT/scripts/$script_name.sh" ]]; then continue; fi
  existing_wrapper_content="$(cat "$existing_wrapper")"
  if [[ "$existing_wrapper_content" == "$(wrapper_text "$script_name")" || "$existing_wrapper_content" == "$(wrapper_text_before_0_0_50 "$script_name")" ]]; then
    RETIRED+=(".claude/scripts/$script_name.sh")
  fi
done

# agent 桩（与 skill 同构：正文只在共享层一处）
for agent_file in "$PACKAGE_ROOT"/agents/*.md; do
  [[ -e "$agent_file" ]] || continue
  agent_name="$(basename "$agent_file" .md)"
  [[ "$agent_name" == "INDEX" ]] && continue
  put ".claude/agents/$agent_name.md" <<STUB
---
name: $agent_name
description: $(sed -n 's/^description: //p' "$agent_file" | head -1)
---

正文在共享层，读它：\`.claude/singlefs-ai-sop/agents/$agent_name.md\`

**不要把正文抄到这里。** 正文只该有一处，抄一份就多出第二处，两处早晚说不同的话。
STUB
done

# skill 桩
for skill_directory in "$PACKAGE_ROOT"/skills/*/; do
  [[ -d "$skill_directory" ]] || continue
  skill_name="$(basename "$skill_directory")"
  put ".claude/skills/$skill_name/SKILL.md" <<STUB
---
name: $skill_name
description: $(sed -n 's/^description: //p' "$skill_directory/SKILL.md" | head -1)
---

正文在共享层，读它：\`.claude/singlefs-ai-sop/skills/$skill_name/SKILL.md\`

**不要把正文抄到这里。** 正文只该有一处，抄一份就多出第二处，两处早晚说不同的话。
STUB
done

# 接管清单的校验：只能写 install.sh 真的会铺的那些路径。
# 写别的路径不会有任何作用，而清单看起来还是「已经接管了」——
# 不起作用的条目比没有条目更糟，它让人以为那份文件已经被豁免了。
for owned_relative_path in "${!OWNED[@]}"; do
  owned_path_is_seeded=0
  for seeded_relative_path in "${SEEDED[@]}"; do [[ "$seeded_relative_path" == "$owned_relative_path" ]] && { owned_path_is_seeded=1; break; }; done
  if [[ $owned_path_is_seeded -eq 0 ]]; then
    bad ".claude/install-owned  这条路径 install.sh 根本不铺，写了也没用：$owned_relative_path"
    howto "只能写 install.sh 会铺下去的那些：CLAUDE.md、.claude/kb/*.md、.claude/warnings/.keep、" \
          ".claude/skills/*/SKILL.md、.claude/agents/*.md、.claude/scripts/*.sh。" \
          "路径拼错就改对；那份文件已经不铺了，就把这一行删掉。"
    owned_list_problem_count=$((owned_list_problem_count+1))
  fi
done
if [[ $owned_list_problem_count -gt 0 ]]; then
  say ""
  bad "接管清单有 $owned_list_problem_count 处不合规，版本戳**没有**刷新"
  howto "先把 .claude/install-owned 改对再重跑。清单坏了的时候不许放行——" \
        "一份读不准的接管清单，等于把「内容落后就不刷戳」这道守卫悄悄关掉了。"
  exit 1
fi
if [[ ${#OWNED_HIT[@]} -gt 0 ]]; then
  say ""
  warn "按 .claude/install-owned 不比对 ${#OWNED_HIT[@]} 份——项目已接管，上游对它们的改动不会再送到："
  for owned_relative_path in "${OWNED_HIT[@]}"; do say "        $owned_relative_path  —— ${OWNED[$owned_relative_path]}"; done
fi

# 版本戳：**有文件落后于上游时不刷**——刷了就等于替项目声明「已经是新版了」，
# 而它的 skill / 骨架还是旧的。版本戳是项目唯一的「规矩变了」信号，不许让它说谎。
stamp_blocked=0
if [[ ${#STALE[@]} -gt 0 ]]; then
  say ""
  bad "${#STALE[@]} 份内容落后于上游，版本戳**没有**刷新（仍是 $(cat "$ROOT/.singlefs-ai-sop-version" 2>/dev/null || echo 无)）："
  printf '%s\n' "${STALE[@]}" | sed 's/^/        /'
  howto "逐份看差异，决定合并还是留着自己的改法：" \
        "diff <(sed '/generated-from/d' $PACKAGE_ROOT/<对应源文>) <这份文件>" \
        "改完再跑一次 install.sh；全部对齐了版本戳才会刷到 $PACKAGE_VERSION。" \
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
stamped_version="$(cat "$ROOT/.singlefs-ai-sop-version" 2>/dev/null || true)"
if [[ -n "$stamped_version" && "$stamped_version" != "$PACKAGE_VERSION" \
      && "$(printf '%s\n' "$stamped_version" "$PACKAGE_VERSION" | sort -V | tail -1)" == "$stamped_version" ]]; then
  bad "不给版本戳降级：项目现在声明 $stamped_version，而这份副本是 $PACKAGE_VERSION"
  howto "副本比项目声明的版本旧——多半是拷了一份旧的，或者拷到一半。" \
        "先把副本换成 $stamped_version 或更新的那一版（从兄弟目录的上游仓拷），再跑 install.sh。" \
        "真要退回旧版，先手工把 .singlefs-ai-sop-version 改成 $PACKAGE_VERSION，再跑一次。"
  exit 1
fi
printf '%s\n' "$PACKAGE_VERSION" > "$ROOT/.singlefs-ai-sop-version"
[[ "$(cat "$ROOT/.singlefs-ai-sop-version")" == "$PACKAGE_VERSION" ]] || die "版本戳回读不一致" \
  "版本戳写进去和读出来不一样，此刻项目声明的版本是错的，门禁会拿它去比对。" \
  "看 df -h 与项目根的权限，修好后重跑 install.sh。"
ok "版本戳  .singlefs-ai-sop-version = $PACKAGE_VERSION"

# gitignore 提醒（不自动改）
if [[ -f "$ROOT/.gitignore" ]] && ! grep -q 'singlefs-ai-sop' "$ROOT/.gitignore"; then
  warn "建议在 .gitignore 或 .gitmodules 里处理 .claude/singlefs-ai-sop/ 的归属"
fi

say ""
ok "完成：新建 $created 个，跳过 $skipped 个（已存在的不覆盖）"
say "下一步： bash .claude/scripts/gate.sh"
