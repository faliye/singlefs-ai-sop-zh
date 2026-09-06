#!/usr/bin/env bash
# 门禁自身的门禁：每一条拒绝，都必须同时给出下一步。
#
# 为什么要有这个脚本（rules/sop-first.md）：
#   默认提交者是想通过的。他们被拦下来，多数时候不是不想测，是不知道怎么测。
#   一条只说「不合格」的失败信息，等于把「怎么做才对」留给人猜——
#   而人只能靠猜的时候，就会去绕过门禁，或者干脆不提交。
#
# 查四条：前两条与第四条是拒绝的形态，第三条是「通过」的形态。
#
# 一、bad：从它那一行起 5 个非注释行内必须出现 howto **命令**。
#   - bad 认的形态：行首、`;`/`{`/`||`/`&&`/`then`/`else`/`do` 之后、
#     单双引号或变量消息——以前只认「行首 + 双引号」，其余全部漏检（对抗测试实测）。
#   - howto 必须是命令位置（行首或 `;`/`{` 之后），注释里的 howto 字样不算
#     （对抗测试实测：`# TODO: howto` 就能糊弄过去）。
#   - 汇总行豁免收紧为「失败/未通过/未过 + 全角冒号 + 紧跟 $计数变量」——
#     以前消息里随便含「检查失败」四个字就永久免检（对抗测试实测）。
#
# 二、die：它是 bad + exit，同样是拒绝，所以同样要给出路。
#   die 的出路写在**第二个参数起**（lib.sh 的 die 会把它们交给 howto），
#   所以判据是「这处 die 有没有第二个参数」。只带一句话的 die 判红。
#   以前 gate-lint 只认 bad，于是 17 处 die 整体免检——`die "单测失败"`
#   这种毫无下一步的拒绝就在门禁路径上（本轮审计实测）。
#
# 三、扫一批对象的脚本，成功摘要要报出检查了多少项。
#   「扫到 0 项」不是通过：判据写窄了、对象全被第一步跳过时，末尾照样报绿，
#   而没有任何人看得出来（singlefs C114：一个阶段的第 3 项就这样绿着）。
#   只对**报了成功**的脚本判；确实不扫对象的写 `# gate-lint:nocount <理由>`。
#
# 四、直接打印的拒绝（`echo "  ✗ …"` / 内嵌 python 的 `print('  ✗ …')`）同样要给出路。
#   项目本地的阶段多半不 source lib.sh，前两条一条都够不着它们——实测 singlefs 的
#   本地阶段有 46 处这样的拒绝，此前全部免检（本轮审计）。
#   窗口是「到下一处拒绝之前」，不是 5 行：python 常常先打 ✗、再循环列明细、最后给出路。
#   循环里的明细行标 `# gate-lint:detail`，汇总行标 `# gate-lint:summary`，两种都要显式写。
#
# 认不出参数个数的形态（消息是变量、或引号被转义拆开）**不判**，
# 交给 lib.sh 的运行期兜底。这里只拦看得明白的那些——机器管得了哪一半要说清楚。
#
# GATE_LINT_DIR 可指定要扫的目录（selftest 拿样本喂它用），默认扫本脚本所在目录。
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 默认扫**整个包**，不只是 scripts/：install.sh 在仓根，它是使用者跑的第一个脚本，
# 而它此前不在扫描范围里——本轮刚把「只带一句话的 die 判红」写成规矩，
# scripts/ 下 17 处全补齐了，仓根那 4 处却一处没查（复核实测）。
# 样本排除写成**相对本次 SCAN** 的前缀：写死成 */fixtures/* 的话，
# 拿样本目录当 SCAN 跑时会把样本自己全排除掉，自检当场变成摆设（doc-lint 踩过）。
SCAN="${GATE_LINT_DIR:-$(cd "$SCRIPTS/.." && pwd)}"
# 位置参数是**额外**要扫的目录（gate.sh 拿它传项目本地阶段目录）。
# 此前只扫本包：项目扔进 .claude/gate.d/ 的阶段一条都没被查过，
# 而它们和共享阶段一样会拒绝提交者——一喂就是 7 条没有出路的拒绝（本仓实测）。
SCANS=("$SCAN")
for d in "$@"; do [[ -d "$d" ]] && SCANS+=("$(cd "$d" && pwd)"); done
head1 "门禁自检（每条拒绝都要给出路）"

# HOWTO_WINDOW 是 rules/sop-first.md 写下的那个数（bad 自己那行 + 后面 4 行）。
# 它是判据的一部分，不是实现细节——fixtures/gate-lint/farhowto 盯着它，
# 改大改小都会让那个样本变绿，自检当场红。
HOWTO_WINDOW=5

# 命令位置的定义在 lib.sh 的 CMD_POS 一处，两个 lint 共用——
# 各写一份的时候，这一份漏了括号，`( bad "..." )` 与 `eval bad` 整体漏检（对抗测试实测）。
BAD_RE="$CMD_POS"'bad[[:space:]]'
DIE_RE="$CMD_POS"'die[[:space:]]'
HOWTO_RE="$CMD_POS"'howto[[:space:]]'
# 汇总行豁免：以前靠猜消息文本（含「失败：$计数」就免检），于是把拒绝消息写成
# 「…检查失败：$n 处」就能永久免检（对抗测试实测）。改成**显式标记**——
# 汇总行在行尾写 `# gate-lint:summary`，猜不着的东西就别猜。
SUMMARY_RE='#[[:space:]]*gate-lint:summary[[:space:]]*$'

# 这处 die 只带了一句话（没有第二个参数）吗？
# 认不出来就返回非零 —— 「不判」与「判过」要分开，前者不该悄悄算通过。
naked_die() {
  local rest="${1#*die }" body=""
  rest="${rest#"${rest%%[![:space:]]*}"}"
  case "$rest" in
    '"'*) body="${rest#\"}"; [[ "$body" == *'"'* ]] || return 1; body="${body#*\"}" ;;
    "'"*) body="${rest#\'}"; [[ "$body" == *"'"* ]] || return 1; body="${body#*\'}" ;;
    *)    return 1 ;;                       # 变量或裸词，参数个数认不出，不判
  esac
  body="${body#"${body%%[![:space:]]*}"}"
  # 只带一句话 → 没给出路
  [[ -z "$body" || "$body" == ';'* || "$body" == '}'* || "$body" == '#'* ]] && return 0
  # 第二个参数是空串也一样：运行期 `$# -gt 0` 成立，兜底那句不打，
  # 提交者看到的是「→ 怎么办：」后面一片空白（对抗测试实测）。
  case "$body" in '""'*|"''"*) return 0 ;; esac
  return 1
}

fails=0; checked=0; files=0
for BASE in "${SCANS[@]}"; do
EXCL=(-not -path "$BASE/scripts/fixtures/*" -not -path "$BASE/fixtures/*")
while IFS= read -r f; do
  rel="${f#"$BASE"/}"
  files=$((files+1))
  mapfile -t L < "$f"
  hd=""
  for ((i=0; i<${#L[@]}; i++)); do
    line="${L[$i]}"
    # heredoc 体不是代码：脚本里用 heredoc 生成「故意写坏的样本」是正当写法，
    # 按代码读会把样本内容当成真实拒绝（对抗测试实测，本仓自己踩过一次）。
    if [[ -n "$hd" ]]; then
      [[ "$line" == "$hd" || "$line" =~ ^[[:space:]]*"$hd"[[:space:]]*$ ]] && hd=""
      continue
    fi
    if [[ "$line" =~ \<\<-?[[:space:]]*[\'\"]?([A-Za-z_][A-Za-z0-9_]*) ]]; then
      hd="${BASH_REMATCH[1]}"
    fi
    [[ "$line" =~ ^[[:space:]]*# ]] && continue        # 注释里的拒绝不算
    # 算术展开不是命令位置：`bad=$((bad + 1))` 里的 `bad ` 紧跟在 `(` 后面，
    # 按 CMD_POS 读就成了一处「拒绝」，而它只是个计数（singlefs 的 gate.d 实测两处假红）。
    #
    # ⚠️ 配对的 `))` **只在 `$((` 之后**找。在整行里找第一个 `))` 会挂死：
    # `if ((okc)); then …; pass=$((pass+1)); fi` 这样的行，第一个 `))` 落在 `$((` 前面，
    # 切完之后剩下的串仍然含 `$((` 而且不变短——真实语料上当场无限循环（写这条时实测）。
    # 现在每轮删掉一整对 `$(( … ))`，长度严格递减，所以一定停得下来。
    while :; do
      pre="${line%%'$(('*}"
      [[ "$pre" == "$line" ]] && break              # 没有 $((
      rest="${line#*'$(('}"
      [[ "$rest" == *'))'* ]] || break              # 没有配对的 ))
      line="$pre${rest#*'))'}"
    done

    if [[ "$line" =~ $DIE_RE ]] && naked_die "$line"; then
      checked=$((checked+1))
      bad "$rel:$((i+1))  拒绝但没有出路（die 只带了一句话）"
      say "        ${L[$i]}"
      howto "给这处 die 补上第二个参数，写清提交者下一步做什么：" \
            "die \"卡在哪了\" \"下一步做什么\"" \
            "die 是 bad + exit，同样是拒绝——rules/sop-first.md 不给它开例外。"
      fails=$((fails+1))
      continue
    fi

    [[ "$line" =~ $BAD_RE ]] || continue
    [[ "$line" =~ $SUMMARY_RE ]] && continue           # 汇总行豁免（带计数变量的那种）
    checked=$((checked+1))
    found=0; seen=0
    # 从 bad 自己那行起：bad "x"; howto 合法
    for ((j=i; seen<HOWTO_WINDOW && j<${#L[@]}; j++)); do
      # 注释行不占窗口名额：在 bad 与 howto 之间写注释解释缘由是合法的，
      # 但注释里出现 howto 字样不算出路
      [[ "${L[$j]}" =~ ^[[:space:]]*# ]] && continue
      seen=$((seen+1))
      [[ "${L[$j]}" =~ $HOWTO_RE ]] && { found=1; break; }
    done
    if [[ $found -eq 0 ]]; then
      bad "$rel:$((i+1))  拒绝但没有 howto"
      say "        ${L[$i]}"
      howto "从这条拒绝起 $HOWTO_WINDOW 行内加一句 howto \"...\"，写清楚提交者下一步做什么。" \
            "不知道写什么，说明这条检查的判据自己也还没想清楚。"
      fails=$((fails+1))
    fi
  done

  # ── G4 直接打印的拒绝，也要给出路 ───────────────────────
  # 上面两条只认 lib.sh 的 bad / die。而**项目本地的阶段多半不 source lib.sh**：
  # 它们直接 `echo "  ✗ …"`，或者在内嵌 python 里 `print('  ✗ …')`。
  # 这批拒绝一样摆在提交者面前，此前 gate-lint 一条都看不见——
  # 实测 singlefs 的本地阶段：46 处这样的拒绝，全部免检（本轮审计）。
  #
  # 窗口不用 5 行：python 的拒绝常常先打一句 ✗、再用一个循环逐条列明细、
  # 最后才给出路，5 行窗口会把它们整批误判。判据改成
  # **「这一处拒绝到下一处拒绝之间（或到文件末），要出现出路」**。
  #
  # heredoc 体默认不当代码读（那是生成样本用的），但**解释器 heredoc 是代码**——
  # `python3 - <<'PY'` 里的 print 是真的会打给提交者看的。所以这一遍
  # 只对解释器 heredoc 的体照读，别的 heredoc 仍然跳过。
  #
  # 两种豁免都得**显式写出来**，猜不着的东西不猜（同汇总行那条）：
  #   # gate-lint:summary  汇总行
  #   # gate-lint:detail   循环里逐条列明细的那种行，出路在它的汇总上
  rej=()
  inhd=""; hdcode=0
  for ((i=0; i<${#L[@]}; i++)); do
    line="${L[$i]}"
    if [[ -n "$inhd" ]]; then
      if [[ "$line" == "$inhd" || "$line" =~ ^[[:space:]]*"$inhd"[[:space:]]*$ ]]; then inhd=""; hdcode=0; continue; fi
      [[ $hdcode -eq 1 ]] || continue
    elif [[ "$line" =~ \<\<-?[[:space:]]*[\'\"]?([A-Za-z_][A-Za-z0-9_]*) ]]; then
      inhd="${BASH_REMATCH[1]}"
      hdcode=0
      [[ "$line" =~ (python3?|perl|node|gawk|awk)[[:space:]] ]] && hdcode=1
      continue
    fi
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" == *✗* ]] || continue
    [[ "$line" =~ (echo|printf|print\() ]] || continue
    rej+=("$i")
  done
  for ((k=0; k<${#rej[@]}; k++)); do
    i="${rej[$k]}"
    [[ "${L[$i]}" =~ $SUMMARY_RE ]] && continue
    [[ "${L[$i]}" =~ '#'[[:space:]]*gate-lint:detail ]] && continue
    checked=$((checked+1))
    end=${#L[@]}; [[ $((k+1)) -lt ${#rej[@]} ]] && end="${rej[$((k+1))]}"
    found=0
    for ((j=i; j<end; j++)); do
      [[ "${L[$j]}" == *→* || "${L[$j]}" == *怎么办* ]] && { found=1; break; }
      [[ "${L[$j]}" =~ $HOWTO_RE ]] && { found=1; break; }
    done
    if [[ $found -eq 0 ]]; then
      bad "$rel:$((i+1))  拒绝但没有出路（直接打印的 ✗，到下一处拒绝之前没有「→」）"
      say "        ${L[$i]}"
      howto "在这条拒绝后面补一行出路，例： echo '     → 怎么办：<下一步做什么>'" \
            "循环里逐条列明细的那种行，在行尾标 # gate-lint:detail（出路写在它的汇总上）；" \
            "汇总行标 # gate-lint:summary。两种豁免都要显式写出来。"
      fails=$((fails+1))
    fi
  done

  # ── G3 成功摘要要报出检查了多少项 ───────────────────────
  # 「扫到 0 项」不是通过。实测：一个阶段的第 3 项因为搜索范围写窄，
  # 每个对象都在第一步 continue，既不算 ok 也不算 bad，末尾照样报绿——
  # 它这样绿了不知道多久，没有任何人看得出来（本仓 C114）。
  # 判据只对扫一批对象的脚本生效；成功摘要里带上计数变量，0 项就自己露出来。
  if printf '%s\n' "${L[@]}" | grep -qE 'while[[:space:]]+.*read|for[[:space:]]+[A-Za-z_]+[[:space:]]+in|find[[:space:]]' \
     && ! printf '%s\n' "${L[@]}" | grep -q 'gate-lint:nocount'; then
    succ="$(printf '%s\n' "${L[@]}" | grep -vE '^[[:space:]]*#' | grep -E '^[[:space:]]*ok[[:space:]]+"|✓' || true)"
    # 判据只对**报了成功**的脚本生效。一个字都不说的脚本是另一类问题，这里不判——
    # 「认不出」与「通过」要分开（rules/show-me-test.md）。
    # 计数认两种占位：shell 的 `$n` 与 python f-string 的 `{n}`。
    # 只认 `$` 的话，用 python 实现的阶段全是假红——它们的成功摘要在 python 里格式化
    # （singlefs 的 26 / 27 号阶段实测）。
    if [[ -n "$succ" ]] && ! grep -qE '[$][A-Za-z_{(]|\{[A-Za-z_]' <<< "$succ"; then
      bad "$rel  成功摘要没报出检查了多少项——扫到 0 项也会报绿"
      howto "在成功那句里带上计数，例： ok \"检查通过（共 \$n 项）\"；" \
            "并让计数真的在循环里累加。确实不扫对象的脚本，写一句" \
            "# gate-lint:nocount <理由> 显式豁免（rules/show-me-test.md）。"
      fails=$((fails+1))
    fi
  fi
done < <(find "$BASE" -name '*.sh' -not -name 'lib.sh' "${EXCL[@]}" | sort)
done

say ""
if [[ $fails -gt 0 ]]; then
  bad "门禁自检失败：$fails 处（共 $files 个脚本、$checked 条拒绝）"   # gate-lint:summary
  exit 1
fi
ok "门禁自检通过：$files 个脚本、$checked 条拒绝都带了出路"
