#!/usr/bin/env bash
# admission: always 判的是此刻全仓的文本，几秒跑完；每一轮门禁都现判，上一轮的结论不替这一轮作保
# run-condition: command gawk
# shell 脚本的已知坑，做成会红的检查（rules/command-safety.md）。
#
# 查七条：
#
#   S1 子 shell 里的赋值传不回父进程
#      三个条件同时成立才判红，误报面很窄：
#        (a) 有个函数 f，文件里以 `$(f ...)` 的形式调用它；
#        (b) f 的函数体里给一个**非 local** 变量赋了值；
#        (c) 那个变量在 f 之外被引用（$VAR 或 ${VAR}）。
#      只认看得明白的形态：多行函数体的收尾按行首 `}` 认，定义与收尾写在同一行的函数按那一行判；
#      赋值按命令位置认，eval / 间接赋值认不出、不判。「认不出」不是「通过」。
#
#   S2 pkill -f / killall
#      模式串会匹配到 wrapper 自己的命令行，杀掉自己的 shell。
#
#   S3 pgrep 的全模式匹配（pgrep -f）
#      接 kill 是 pkill -f 的另一种拼法；放进等待循环会命中循环自己所在的命令行、永远不退出；
#      先赋给变量、下一行再 kill 是同一件事拆成两行。命令位置上出现就红，不看同一行还有什么。
#
#   S4 会静默丢掉未提交改动的 git 命令（checkout / restore / clean / reset --hard）
#      脚本跑的时候没人在旁边看 git status，而这些命令没有 undo。
#
#   S5 `rm -rf "$VAR/..."` 没有空值守卫
#      变量为空时它从根目录往下删。写成 `"${VAR:?}/..."` 就拦住了。
#
#   S6 不带参数的 `wait`
#      它的退出码恒为 0，并行跑的检测项红了几个父进程都不知道；后台体里写 `|| bad=1` 也一样（那是 S1）。
#      收法见 rules/command-safety.md「并行不许把失败吃掉」。
#      退出码确实在别处收了的，在那一行写 `# shell-lint:exit-collected <怎么收的>` 放行，理由不许省。
#
#   S7 pipefail 下以提前退出的 `grep -q` 收尾的管道
#      grep 命中就退出，前段吃 SIGPIPE，管道返回 141，`if` 把它读成「没命中」。
#
# command-safety.md 另外几条（echo 假装成功、破坏性操作先看清楚）判据还没想清楚，没做；管道退出码只做了 S7 那一种。
#
# 用法：
#   SHELL_LINT_DIR   要扫的目录（selftest 拿样本喂它用），默认扫整个包
#   位置参数         额外要扫的目录（gate.sh 拿它传项目登记的门禁目录，默认 .claude/gate.d/）
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight "${BASH_SOURCE[0]}" "$@"; set -- ${PREFLIGHT_ARGUMENTS[@]+"${PREFLIGHT_ARGUMENTS[@]}"}

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 默认扫整个包而不只是 scripts/：install.sh 在仓根。
# 样本排除写成相对本次 SCAN 的前缀：写死成 */fixtures/* 的话，
# 拿样本目录当 SCAN 跑时会把样本自己全排除掉，自证当场变成摆设。
SCAN="${SHELL_LINT_DIR:-$(cd "$SCRIPTS/.." && pwd)}"
SCANS=("$SCAN")
for d in "$@"; do [[ -d "$d" ]] && SCANS+=("$(cd "$d" && pwd)"); done
[[ -n "${GATE_IN_STAGE:-}" ]] || head1 "shell 纪律检查"

# S4：只想撤一处临时改动，`git checkout <文件>` 会把同文件里当轮所有未提交的改动一起冲掉。
S4_RE="$CMD_POS"'git[[:space:]]+((-C[[:space:]]+[^[:space:]]+[[:space:]]+)?)(checkout|restore|clean)([[:space:]]|$)'
S4_RESET="$CMD_POS"'git[[:space:]]+((-C[[:space:]]+[^[:space:]]+[[:space:]]+)?)reset[[:space:]]+.*--hard'

# S5：只判变量后面还跟着路径的那种：`rm -rf "$d"` 变量为空是 `rm -rf ""`，rm 自己会拒。
# 分两步判，不写成一整条正则：一整条只认得第一个参数，而且靠「整行含 :? 就跳过」来放过守卫，
# 于是 `rm -rf "$d"/x`、`rm -rf -- "$d/x"`、`rm -rf "${a:?}/x" "$b/y"` 三种全绿。
# 第一步挑出命令位置上的 rm -r…，第二步在行内逐个参数找没守卫的变量路径：
# 守卫形态 `${名字:?}` 的 `}` 前面有 `:?`，S5_ARG 两个分支都匹配不上。
S5_CMD="$CMD_POS"'rm([[:space:]]+-[[:alnum:]-]+)*[[:space:]]+-[[:alnum:]-]*[rR]'
S5_ARG='\$(\{[A-Za-z_][A-Za-z0-9_]*\}|[A-Za-z_][A-Za-z0-9_]*)"?/'

# S6：只判后面什么都不跟的：`wait "$pid"`、`wait -n`、`wait $job` 都收得到退出码，不判。
# 结尾的 `;` 与行尾注释算不跟参数：`wait;` 与 `wait  # 等虚机` 一样吃掉失败。
S6_RE="$CMD_POS"'wait[[:space:]]*;?[[:space:]]*(#.*)?$'
S6_MARK='shell-lint:exit-collected'
S6_MARK_WITH_REASON="$S6_MARK"'[[:space:]]+[^[:space:]]'

# S7：前段输出越大（git show / git diff）、机器越忙越容易撞上。
# 复现：`set -uo pipefail; yes X | head -200000 | grep -q X` 稳定返回 141。
# 两种不判：脚本没设 pipefail（管道退出码本来就只看最后一段）；
# `grep -q … <<<"$var"` 这种没有前段的形态。
S7_RE='\|[[:space:]]*grep[[:space:]]+(-[A-Za-z]*q[A-Za-z]*)([[:space:]]|$)'
S7_PIPEFAIL_RE='^[[:space:]]*set[[:space:]].*pipefail'

# S2 / S3 的判据（PATTERN_KILL_RE、PATTERN_PGREP_RE）与命令位置 CMD_POS 都定义在 lib.sh 一处：
# S2 / S3 与会话钩子 claude-hooks/pattern-process-guard.sh 共用，CMD_POS 与 gate-lint 共用。
# 只认命令位置：一个记号出现在字符串里（本脚本自己的 bad 消息就是）不等于它被执行了。

fails=0; checked=0
for BASE in "${SCANS[@]}"; do
# 装进项目的 SOP 副本不扫：它由上游自己的门禁管，而它带着一整套故意写坏的样本，
# 项目里单跑时会被当成项目自己的违规报出来。
LINT_FAMILY="$(sed -n 's/^family=//p' "$SCRIPTS/../I18N" 2>/dev/null || true)"
EXCL=(-not -path "$BASE/scripts/fixtures/*" -not -path "$BASE/fixtures/*" -not -name "*.case.sh" -not -path "$BASE/.claude/${LINT_FAMILY:-singlefs-ai-sop}/*")
while IFS= read -r f; do
  rel="${f#"$BASE"/}"
  checked=$((checked+1))

  # ── S2 按模式匹配杀进程 ─────────────────────────────────
  if hits="$(grep -nE "$PATTERN_KILL_RE" "$f" | grep -vE '^[0-9]+:[[:space:]]*#' || true)"; [[ -n "$hits" ]]; then
    while IFS= read -r h; do
      bad "$rel:${h%%:*}  按模式匹配杀进程（pkill 的 -f，或 killall）"
      say "        $(printf '%s' "${h#*:}" | cut -c1-80)"
      howto "模式串会出现在 wrapper 自己的命令行里，把自己的 shell 一起杀掉。" \
            "改成：先 ps 列出来看清楚，再用**字面量 pid** 分第二条命令杀；" \
            "统计类改用 /proc 结构化判据并排除自身进程树（rules/command-safety.md）。"
      fails=$((fails+1))
    done <<< "$hits"
  fi

  if hits="$(grep -nE "$PATTERN_PGREP_RE" "$f" | grep -vE '^[0-9]+:[[:space:]]*#' || true)"; [[ -n "$hits" ]]; then
    while IFS= read -r h; do
      bad "$rel:${h%%:*}  pgrep 的全模式匹配 —— 与 pkill -f 同一个自杀风险，放进等待循环还会命中自己、永远不退出"
      say "        $(printf '%s' "${h#*:}" | cut -c1-80)"
      howto "模式串会命中 wrapper 自己的命令行：接 kill 是把自己的 shell 一起杀掉，放进 if / while / until 是永远为真；" \
            "先赋给变量再 kill、只是数一数，都一样。要杀先 ps 看清楚再用**字面量 pid** 分第二条命令杀；" \
            "等进程结束用写死的 pid（kill -0）或 wait；统计类改用 /proc 并排掉自己这一支进程树（rules/command-safety.md）。"
      fails=$((fails+1))
    done <<< "$hits"
  fi

  # ── S4 会静默丢掉未提交改动的 git 命令 ──────────────────
  if hits="$(grep -nE "$S4_RE|$S4_RESET" "$f" | grep -vE '^[0-9]+:[[:space:]]*#' || true)"; [[ -n "$hits" ]]; then
    while IFS= read -r h; do
      bad "$rel:${h%%:*}  脚本里用了会丢掉未提交改动的 git 命令"
      say "        $(printf '%s' "${h#*:}" | cut -c1-80)"
      howto "checkout / restore / clean / reset --hard 会直接丢掉未提交的改动，而且没有 undo。" \
            "脚本跑的时候没人在旁边看 git status，所以别写进脚本。" \
            "真要在脚本里回到干净状态：先 git stash，或者整个仓拷一份出来在副本上做" \
            "（rules/command-safety.md）。"
      fails=$((fails+1))
    done <<< "$hits"
  fi

  # ── S5 rm -rf 作用在变量路径上，没有空值守卫 ─────────────
  if hits="$(grep -nE "$S5_CMD" "$f" | grep -vE '^[0-9]+:[[:space:]]*#' || true)"; [[ -n "$hits" ]]; then
    while IFS= read -r h; do
      # 行内逐个参数看有没有没守卫的。不用 `| head -1`：head 会让上游 grep 拿 SIGPIPE，pipefail 下整条管道退 141。
      unguarded="$(printf '%s\n' "${h#*:}" | grep -oE "$S5_ARG" || true)"
      unguarded="${unguarded%%$'\n'*}"
      [[ -n "$unguarded" ]] || continue
      bad "$rel:${h%%:*}  rm -rf 作用在变量路径上（$unguarded），变量为空时会从根目录往下删"
      say "        $(printf '%s' "${h#*:}" | cut -c1-80)"
      howto '加空值守卫：把 "$d/x" 写成 "${d:?}/x" —— 变量为空时 shell 直接报错退出，' \
            '而不是把 rm -rf 指到 /x（rules/command-safety.md）。'
      fails=$((fails+1))
    done <<< "$hits"
  fi

  # ── S6 不带参数的 wait，把并行作业的失败全吃掉 ───────────
  if hits="$(grep -nE "$S6_RE" "$f" | grep -vE '^[0-9]+:[[:space:]]*#' || true)"; [[ -n "$hits" ]]; then
    while IFS= read -r h; do
      s6_line="${h#*:}"
      if [[ "$s6_line" == *"$S6_MARK"* ]]; then
        [[ "$s6_line" =~ $S6_MARK_WITH_REASON ]] && continue
        bad "$rel:${h%%:*}  $S6_MARK 标记后面没写退出码收在哪"
        howto "这个标记是用来说清「这一批后台作业的退出码去哪了」的，只写标记等于没说。" \
              "照这个样子写：wait  # $S6_MARK 每项把退出码写进 \$work/<项>/exit，下面逐个读" \
              "（rules/command-safety.md）。"
        fails=$((fails+1))
        continue
      fi
      bad "$rel:${h%%:*}  不带参数的 wait —— 后台作业里红了几个，它的退出码还是 0"
      say "        $(printf '%s' "$s6_line" | cut -c1-80)"
      howto "光秃的 wait 恒返回 0，并行跑的检测项全红了父进程也看不见。" \
            "一道并行化之后再也红不了的门禁，比串行的慢门禁危险得多。" \
            "两种收法：起的时候记 pids+=(\$!)，收的时候逐个 wait \"\$pid\" 取退出码；" \
            "或者每项把退出码写进自己的文件，收的时候按固定顺序逐个读（rules/command-safety.md）。" \
            "退出码确实在别处收了的，在这一行写 # $S6_MARK <怎么收的>。"
      fails=$((fails+1))
    done <<< "$hits"
  fi

  # ── S7 pipefail 下以提前退出的 grep -q 收尾的管道 ───────
  if grep -qE "$S7_PIPEFAIL_RE" "$f"; then
    if hits="$(grep -nE "$S7_RE" "$f" | grep -vE '^[0-9]+:[[:space:]]*#' || true)"; [[ -n "$hits" ]]; then
      while IFS= read -r h; do
        bad "$rel:${h%%:*}  pipefail 下的管道以 grep -q 收尾 —— 命中会被读成没命中"
        say "        $(printf '%s' "${h#*:}" | cut -c1-80)"
        howto "grep -q 一命中就退出，前段吃 SIGPIPE，管道整体返回 141，而 if 把它读成「没命中」。" \
              "把前段的输出先落到变量，再对变量判：" \
              "out=\$(前段 || true); if grep -q '模式' <<<\"\$out\"; then …" \
              "前段是 git show / git diff 时尤其要改：输出越大越容易吃 SIGPIPE（rules/command-safety.md）。"
        fails=$((fails+1))
      done <<< "$hits"
    fi
  fi

  # ── S1 子 shell 里的赋值传不回父进程 ────────────────────
  while IFS=$'\037' read -r ln fn var; do
    [[ -z "$ln" ]] && continue
    bad "$rel:$ln  $fn() 里给 \$$var 赋值，而它只在 \$( ) 里被调用——外面拿不到这个值"
    howto "命令替换开的是子 shell，赋值到不了父进程；引用处拿到的是旧值，" \
          "或者在 set -u 下当场是「unbound variable」，把脚本在打印诊断之前带走。" \
          "改法：让调用方把这个值**作为参数传进去**，或者由函数落到文件、" \
          "调用方读文件——不要靠变量往外带（rules/command-safety.md）。"
    fails=$((fails+1))
  done < <(awk -v HD_RE="$HEREDOC_RE" '
    # heredoc 体不是代码，按代码读会把里面的 `rc=$?` 误判成函数里的赋值。
    # 注释行不判开没开 heredoc：注释里一句 `# 用法示例： cat <<EOF` 会让其后整个文件当成 heredoc 体、一条都不再检查。
    {
      if (hd != "") { if ($0 == hd || $0 ~ ("^[ \t]*" hd "[ \t]*$")) hd = ""; L[NR] = ""; next }
      if ($0 !~ /^[ \t]*#/ && match($0, HD_RE, hdm)) hd = hdm[2]
      L[NR] = $0
    }
    END {
      nf = 0
      for (i = 1; i <= NR; i++) {
        # 两种定义形态都认：`name() {` 与 `function name {`
        # （只认前者的话，写成 function 的函数会整体漏检）
        nm = ""
        if (L[i] ~ /^[A-Za-z_][A-Za-z0-9_]*\(\)[ \t]*\{/) {
          nm = L[i]; sub(/\(\).*/, "", nm); gsub(/[ \t]/, "", nm)
        } else if (L[i] ~ /^function[ \t]+[A-Za-z_][A-Za-z0-9_]*([ \t]*\(\))?[ \t]*\{/) {
          nm = L[i]; sub(/^function[ \t]+/, "", nm); sub(/[ \t(].*/, "", nm)
        }
        if (nm != "") {
          # 定义与收尾写在同一行的（`S() { printf …; }`），函数体就是这一行，不往下找收尾：
          # 往下找会拿下一个函数行首的 } 当收尾，把中间的顶层赋值全算成这个函数的。
          one = L[i]; sub(/^[^{]*\{/, "", one)
          if (one ~ /(^|[;&| \t])\}[ \t;]*(#.*)?$/) {
            sub(/\}[ \t;]*(#.*)?$/, "", one)
            nf++; FNM[nf] = nm; FST[nf] = i; FEN[nf] = i; ONE[nf] = one
            continue
          }
          # 认不出收尾的跳过这个函数：记成不判，不记成通过。
          e = 0
          for (j = i + 1; j <= NR; j++) if (L[j] ~ /^\}/) { e = j; break }
          if (e == 0) continue
          nf++; FNM[nf] = nm; FST[nf] = i; FEN[nf] = e; ONE[nf] = ""
        }
      }
      for (k = 1; k <= nf; k++) {
        # (a) 有没有 $(fname 形式的调用（在函数体之外）
        called = 0
        for (i = 1; i <= NR; i++) {
          if (i >= FST[k] && i <= FEN[k]) continue
          if (L[i] ~ /^[ \t]*#/) continue
          # `$(f`、`$( f`、`` `f` `` 三种调用形态都认；用词边界，免得同前缀的函数（scan / scan_one）互相误伤
          if (L[i] ~ ("\\$\\([ \t]*" FNM[k] "([ \t)]|$)")) { called = 1 }
          if (L[i] ~ ("`[ \t]*" FNM[k] "([ \t`]|$)")) { called = 1 }
          if (called) break
        }
        if (!called) continue
        # 只要还有一处直接调用，赋值就传得出去，判红没有依据
        direct = 0
        for (i = 1; i <= NR; i++) {
          if (i >= FST[k] && i <= FEN[k]) continue
          if (L[i] ~ /^[ \t]*#/) continue
          # 先把命令替换整段挖掉再看：不挖的话 `$(f x)` 里的 `(` 会被当成命令位置，
          # 每个 $( ) 调用都自称「还有直接调用」，整条 S1 静默失效
          t = L[i]
          while (match(t, /\$\([^()]*\)/)) t = substr(t, 1, RSTART - 1) " " substr(t, RSTART + RLENGTH)
          while (match(t, /`[^`]*`/))        t = substr(t, 1, RSTART - 1) " " substr(t, RSTART + RLENGTH)
          # 行首的缩进也算命令位置：函数体里缩进着的直接调用不认，就会把「还有直接调用」的函数误判成只在 $( ) 里调用
          if (t ~ ("(^[ \t]*|[;&|(){}][ \t]*)" FNM[k] "([ \t;&|)]|$)")) { direct = 1; break }
        }
        if (direct) continue
        # (b) 函数体里对非 local 变量的赋值。先把 local/declare 过的名字收齐再判：
        #     `local rc; rc="$(...)"` 两段分开看会把第二段误判成全局赋值。
        delete asg; delete loc; delete body; delete bodyline; nb = 0
        if (FST[k] == FEN[k]) { nb = 1; body[1] = ONE[k]; bodyline[1] = FST[k] }
        else for (i = FST[k] + 1; i < FEN[k]; i++) { nb++; body[nb] = L[i]; bodyline[nb] = i }
        for (b = 1; b <= nb; b++) {
          if (body[b] ~ /^[ \t]*#/) continue
          n = split(body[b], seg, ";")
          for (p = 1; p <= n; p++) {
            if (match(seg[p], /^[ \t]*(local|declare|export|typeset|readonly)[ \t]+/)) {
              rest = substr(seg[p], RSTART + RLENGTH)
              m = split(rest, names, /[ \t]+/)
              for (q = 1; q <= m; q++) { nv = names[q]; sub(/=.*$/, "", nv)
                                         if (nv ~ /^[A-Za-z_][A-Za-z0-9_]*$/) loc[nv] = 1 }
            }
          }
        }
        for (b = 1; b <= nb; b++) {
          if (body[b] ~ /^[ \t]*#/) continue
          n = split(body[b], seg, ";")
          for (p = 1; p <= n; p++) {
            if (seg[p] ~ /^[ \t]*(local|declare|export|typeset|readonly)[ \t]/) continue
            if (match(seg[p], /^[ \t]*[A-Za-z_][A-Za-z0-9_]*=/)) {
              v = substr(seg[p], RSTART, RLENGTH - 1); gsub(/[ \t]/, "", v)
              if (!(v in loc) && !(v in asg)) asg[v] = bodyline[b]
            }
          }
        }
        # (c) 那个变量在函数体之外被引用
        for (v in asg) {
          for (i = 1; i <= NR; i++) {
            if (i >= FST[k] && i <= FEN[k]) continue
            if (L[i] ~ /^[ \t]*#/) continue
            if (L[i] ~ ("\\$\\{?" v "\\y")) {
              printf "%d\037%s\037%s\n", asg[v], FNM[k], v
              break
            }
          }
        }
      }
    }
  ' "$f")
done < <(find "$BASE" -name '*.sh' "${EXCL[@]}" | sort)
done

say ""
if [[ $fails -gt 0 ]]; then
  bad "shell 纪律检查失败：$fails 处（共检查 $checked 个脚本）"   # gate-lint:summary
  exit 1
fi
ok "shell 纪律检查通过（共 $checked 个脚本）"
