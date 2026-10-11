#!/usr/bin/env bash
# admission: always 判的是此刻全仓的文本，几秒跑完；每一轮门禁都现判，上一轮的结论不替这一轮作保
# run-condition: command gawk
# 门禁自身的门禁：每一条拒绝，都必须同时给出下一步。
# 规则：rules/sop-first.md「每一条拒绝都必须给出下一步」，rules/show-me-test.md「门禁不许假装通过」。
#
# 用法：gate-lint.sh [额外要扫的目录…]
#   GATE_LINT_DIR  要扫的目录（selftest 拿样本喂它用），默认扫本包根；位置参数是额外要扫的目录（gate.sh 拿它传项目登记的门禁目录，默认 .claude/gate.d/）。
#
# 查四条：G1、G2、G4 是拒绝的形态，G3 是「通过」的形态。G1–G3 只对 .sh 判，.py 只判 G4。
#   G1 bad：从它那一行起 HOWTO_WINDOW 个非注释行内要有命令位置上的 howto（命令位置见 lib.sh 的 CMD_POS）；
#      注释里的 howto 字样不算。行尾写 `# gate-lint:summary` 的汇总行豁免，不按消息文本猜。
#   G2 die：出路写在第二个参数起（lib.sh 的 die 交给 howto）；只带一句话、或第二个参数是空串的判红。
#   G3 扫一批对象的脚本，最后一句成功句要带一个在文件里数出来的计数（认哪些写法见 summary_reports_count）；
#      确实不扫对象的单独写一行注释 `# gate-lint:nocount <理由>`，理由至少 8 个字。
#   G4 直接打印的拒绝（`echo "  ✗ …"` / python 的 `print('  ✗ …')`）到下一处拒绝之前要出现「→」；
#      循环里的明细行标 `# gate-lint:detail`，汇总行标 `# gate-lint:summary`，两种都要显式写。
#
# 认不出参数个数的形态（消息是变量、或引号被转义拆开）不判，交给 lib.sh 的运行期兜底。
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight "${BASH_SOURCE[0]}" "$@"; set -- ${PREFLIGHT_ARGUMENTS[@]+"${PREFLIGHT_ARGUMENTS[@]}"}

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 默认扫整个包，不只是 scripts/：install.sh 在仓根。
# 样本排除写成相对本次 SCAN 的前缀：写死成 */fixtures/* 的话，
# 拿样本目录当 SCAN 跑时会把样本自己全排除掉，自证当场变成摆设。
SCAN="${GATE_LINT_DIR:-$(cd "$SCRIPTS/.." && pwd)}"
SCANS=("$SCAN")
for d in "$@"; do [[ -d "$d" ]] && SCANS+=("$(cd "$d" && pwd)"); done
head1 "门禁自检（每条拒绝都要给出路）"

# HOWTO_WINDOW 是 rules/sop-first.md 写下的那个数（bad 自己那行 + 后面 4 行），是判据的一部分：
# fixtures/gate-lint/farhowto 盯着它，改大改小都会让那个样本变绿，自证当场红。
HOWTO_WINDOW=5

# 命令位置的定义在 lib.sh 的 CMD_POS 一处，两个 lint 共用。
BAD_RE="$CMD_POS"'bad[[:space:]]'
DIE_RE="$CMD_POS"'die[[:space:]]'
HOWTO_RE="$CMD_POS"'howto[[:space:]]'
# 汇总行豁免只认行尾的显式标记：按消息文本猜的话，把拒绝写成「…检查失败：$n 处」就能永久免检。
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
  # 提交者看到的是「→ 怎么办：」后面一片空白。
  case "$body" in '""'*|"''"*) return 0 ;; esac
  return 1
}

# G3：nocount 的理由至少几个字
NOCOUNT_REASON_MINIMUM_CHARACTERS=8
# 这一行成功句带没带计数（G3）。计数变量要在同一个文件里累加过，算「报了数」；随便一个变量（$ROOT、$lang）不算。
# 认的累加形态：NAME=$(( … ))、(( NAME++ / ++NAME / NAME+= / NAME-= / NAME= … ))、let NAME、NAME=${#数组[@]}、NAME=… wc -l / wc -w / grep -c / ${#数组[@]}，
# python 里 NAME += …（+= 前面有空白：shell 的 x+=… 是拼字符串、追加数组，不是计数）、NAME = len( / sum( …。
# 认不出的写法多半让它判红。已知会放过没报数的：失败计数（fails 也是累加过的变量，而通过时它恒为 0）、
# 同一行两个赋值时取错名字、heredoc 正文里的 ok 句被当成最后一句——这几样靠 review。
summary_reports_count() { # summary_reports_count <成功句> ；读全局的 L（这个文件的全部行）
  local summary="$1" counter_name
  [[ "$summary" =~ \$\{#[A-Za-z_][A-Za-z0-9_]*\[[@*]\]\} ]] && return 0
  [[ "$summary" == *'$(('* ]] && return 0
  [[ "$summary" =~ wc[[:space:]]+-[lw]|grep[[:space:]]+-[A-Za-z]*c|\{len\( ]] && return 0
  while IFS= read -r counter_name; do
    [[ -n "$counter_name" ]] || continue
    if [[ "$summary" =~ \$\{?$counter_name([^A-Za-z0-9_]|$) || "$summary" =~ \{$counter_name[}:!] ]]; then return 0; fi
  done < <(printf '%s\n' "${L[@]}" | grep -oE \
      '([A-Za-z_][A-Za-z0-9_]*)=\$\(\(|\(\([[:space:]]*(\+\+|--)?[A-Za-z_][A-Za-z0-9_]*[[:space:]]*(\+\+|--|[-+]=|=[^=])|(^|[^A-Za-z0-9_])let[[:space:]]+"?[A-Za-z_][A-Za-z0-9_]*|([A-Za-z_][A-Za-z0-9_]*)=("?\$\{#[A-Za-z_][A-Za-z0-9_]*\[[@*]\]|[^=].*(wc[[:space:]]+-[lw]|grep[[:space:]]+-[A-Za-z]*c|\$\{#[A-Za-z_][A-Za-z0-9_]*\[[@*]\]))|[A-Za-z_][A-Za-z0-9_]*[[:space:]]+\+=|[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=[[:space:]]*(len|sum)\(' \
    | sed -E 's/^\(\([[:space:]]*(\+\+|--)?//; s/^[^A-Za-z0-9_]?let[[:space:]]+"?//; s/[^A-Za-z0-9_].*$//' | sort -u || true)
  return 1
}

fails=0; checked=0; files=0
for BASE in "${SCANS[@]}"; do
# 装进项目的 SOP 副本不扫：副本里的样本是故意写坏的，项目里单跑这个 lint 时会被当成项目自己的违规。
LINT_FAMILY="$(sed -n 's/^family=//p' "$SCRIPTS/../I18N" 2>/dev/null || true)"
EXCL=(-not -path "$BASE/scripts/fixtures/*" -not -path "$BASE/fixtures/*" -not -name "*.case.sh" -not -path "$BASE/.claude/${LINT_FAMILY:-singlefs-ai-sop}/*")
while IFS= read -r f; do
  rel="${f#"$BASE"/}"
  files=$((files+1))
  mapfile -t L < "$f"
  # .py 也扫（项目本地的阶段常用 python 写），但只判 G4：G1 / G2 认的是 lib.sh 的 bad / die，
  # G3 认的是 shell 的成功摘要，套到 python 上只会造假红。
  is_shell=0; [[ "$f" == *.sh ]] && is_shell=1
  hd=""
if [[ $is_shell -eq 1 ]]; then
  for ((i=0; i<${#L[@]}; i++)); do
    line="${L[$i]}"
    # heredoc 体不是代码：脚本里用 heredoc 生成「故意写坏的样本」是正当写法，按代码读会把样本内容当成真实拒绝。
    if [[ -n "$hd" ]]; then
      [[ "$line" == "$hd" || "$line" =~ ^[[:space:]]*"$hd"[[:space:]]*$ ]] && hd=""
      continue
    fi
    # 注释行先跳过，再判 heredoc：反过来写的话，注释里一句 `# 用法：python3 - <<PY`
    # 就把这一行之后的整个文件当成 heredoc 体，一条拒绝都不再检查。
    [[ "$line" =~ ^[[:space:]]*# ]] && continue        # 注释里的拒绝不算
    if [[ "$line" =~ $HEREDOC_RE ]]; then
      hd="${BASH_REMATCH[2]}"
    fi
    # 算术展开不是命令位置：`bad=$((bad + 1))` 里的 `bad ` 紧跟在 `(` 后面，按 CMD_POS 读就成了一处「拒绝」。
    # 配对的 `))` 只在 `$((` 之后找：在整行里找第一个 `))` 的话，`if ((okc)); then …; pass=$((pass+1)); fi`
    # 切完之后不变短，当场无限循环。每轮删掉一整对 `$(( … ))`，长度严格递减，一定停得下来。
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
    [[ "$line" =~ $SUMMARY_RE ]] && continue           # 汇总行豁免：行尾带 # gate-lint:summary 的那一行
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

fi   # ← G1 / G2 到此为止，只对 shell 脚本判

  # ── G4 直接打印的拒绝，也要给出路 ───────────────────────
  # 窗口是「这一处拒绝到下一处拒绝之间（或到文件末）」，不是 5 行：python 的拒绝常常先打一句 ✗、
  # 再用一个循环逐条列明细、最后才给出路。
  # heredoc 体默认不当代码读（那是生成样本用的），但解释器 heredoc（`python3 - <<'PY'`）里的 print
  # 是真的会打给提交者看的：这一遍只对解释器 heredoc 的体照读。
  rej=()
  inhd=""; hdcode=0
  for ((i=0; i<${#L[@]}; i++)); do
    line="${L[$i]}"
    if [[ -n "$inhd" ]]; then
      if [[ "$line" == "$inhd" || "$line" =~ ^[[:space:]]*"$inhd"[[:space:]]*$ ]]; then inhd=""; hdcode=0; continue; fi
      [[ $hdcode -eq 1 ]] || continue
    elif [[ $is_shell -eq 1 ]] && [[ ! "$line" =~ ^[[:space:]]*# ]] && [[ "$line" =~ $HEREDOC_RE ]]; then
      inhd="${BASH_REMATCH[2]}"
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

if [[ $is_shell -eq 1 ]]; then
  # ── G3 成功摘要要报出检查了多少项 ───────────────────────
  # 这里不许用 `… | grep -q`：grep 找到就退出，上游 printf 写不完拿 SIGPIPE，pipefail 下整个管道退 141、
  # 条件当假——文件大过管道缓冲（64 KiB）就静默不判了。grep -c 会读完全部输入。
  loop_hits="$(printf '%s\n' "${L[@]}" | grep -cE 'while[[:space:]]+.*read|for[[:space:]]+[A-Za-z_]+[[:space:]]+in|find[[:space:]]' || true)"
  # nocount 只认单独一行的注释：写在代码里、字符串里的不算豁免（按子串认的话，一句 echo 里提到它就免检了）。
  nocount_exempt=0
  for ((i=0; i<${#L[@]}; i++)); do
    [[ "${L[$i]}" =~ ^[[:space:]]*#[[:space:]]*gate-lint:nocount([[:space:]]+(.*))?$ ]] || continue
    nocount_reason="${BASH_REMATCH[2]}"
    nocount_reason="${nocount_reason%"${nocount_reason##*[![:space:]]}"}"
    if (( ${#nocount_reason} >= NOCOUNT_REASON_MINIMUM_CHARACTERS )); then nocount_exempt=1; continue; fi
    checked=$((checked+1))
    bad "$rel:$((i+1))  gate-lint:nocount 的理由不到 $NOCOUNT_REASON_MINIMUM_CHARACTERS 个字（「$nocount_reason」），不算豁免"
    howto "写清为什么这个脚本不扫一批对象，至少 $NOCOUNT_REASON_MINIMUM_CHARACTERS 个字：# gate-lint:nocount <理由>；" \
          "说不出理由，就在成功那句里报出检查了多少项。"
    fails=$((fails+1))
  done
  if [[ "$loop_hits" -gt 0 && "$nocount_exempt" -eq 0 ]]; then
    # 只对报了成功的脚本判；一个字都不说的脚本是另一类问题，这里不判。
    # 判的是最后一句成功句：任一句成功句带任一个变量就算报了数的话，前面一句「扫描 $ROOT」就能替没报数的总结句作保。
    # 成功句以反斜杠续行的（printf 的格式串一行、参数下一行），连同续行一起算那一句。
    summary_line_number=0; summary_line=""
    for ((i=0; i<${#L[@]}; i++)); do
      [[ "${L[$i]}" =~ ^[[:space:]]*# ]] && continue
      # 成功句可以跟在 && / || / ; / then / else / do 后面：(( fails == 0 )) && ok "…" 也是成功句
      if [[ "${L[$i]}" =~ (^|&&|\|\||;|then|else|do)[[:space:]]*ok[[:space:]]+\" || "${L[$i]}" == *✓* ]]; then
        summary_line_number=$((i+1)); summary_line="${L[$i]}"
        for ((j=i; j+1<${#L[@]}; j++)); do
          [[ "${L[$j]}" == *\\ ]] || break
          summary_line+=$'\n'"${L[$((j+1))]}"
        done
      fi
    done
    if [[ -n "$summary_line" ]] && ! summary_reports_count "$summary_line"; then
      checked=$((checked+1))
      bad "$rel:$summary_line_number  成功摘要没报出检查了多少项（判的是文件里最后一句成功句）——扫到 0 项也会报绿"
      say "        $summary_line"
      howto "在成功那句里带上计数，例： ok \"检查通过（共 \$checked 项）\"，并让它真的在循环里累加（checked=\$((checked+1))）；" \
            "认得出的计数：在这个文件里累加过的变量、\${#数组[@]}、算术展开、行内的 wc -l / wc -w / grep -c、python 的 {len(…)} 或累加过的名字。" \
            "确实不扫对象的脚本，单独写一行注释 # gate-lint:nocount <理由>（至少 $NOCOUNT_REASON_MINIMUM_CHARACTERS 个字）显式豁免（rules/show-me-test.md）。"
      fails=$((fails+1))
    fi
  fi
fi   # ← G3 到此为止，只对 shell 脚本判
done < <(find "$BASE" \( -name '*.sh' -o -name '*.py' \) -not -name 'lib.sh' "${EXCL[@]}" | sort)
done

say ""
if [[ $fails -gt 0 ]]; then
  bad "门禁自检失败：$fails 处（共 $files 个脚本、$checked 条拒绝）"   # gate-lint:summary
  exit 1
fi
ok "门禁自检通过：$files 个脚本（.sh 与 .py）、$checked 条拒绝都带了出路"
