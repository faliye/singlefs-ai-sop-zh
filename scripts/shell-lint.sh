#!/usr/bin/env bash
# shell 脚本的已知坑，做成会红的检查（rules/command-safety.md）。
#
# 为什么要有它（rules/sop-first.md）：
#   「注意别在 X 时候做 Y」拦不住手敲命令，一个在那时直接拒绝的检查才拦得住。
#   command-safety.md 里的纪律以前全是提醒句——而本轮审计在一个测试装置
#   里挖出了其中一条的实例：日志路径靠子 shell 里的赋值往外带，
#   父进程拿到的是未定义，五处失败分支在打印诊断之前就被 set -u 带走。
#   一条写在文档里的纪律，被写文档的人自己违反了整整一轮——所以它要变成检查。
#
# 查六条：
#
#   S1 子 shell 里的赋值传不回父进程
#      三个条件同时成立才判红，误报面很窄：
#        (a) 有个函数 f，文件里以 `$(f ...)` 的形式调用它；
#        (b) f 的函数体里给一个**非 local** 变量赋了值；
#        (c) 那个变量在 f 之外被引用（$VAR 或 ${VAR}）。
#      三条凑齐 ⇒ 引用处拿到的必然是旧值或未定义。
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
#      它的退出码恒为 0：并行跑的检测项红了几个，父进程一个字都不知道
#      （实测 2026-09-19：三个后台作业里第二个 exit 7，光秃的 wait 报 0；
#      后台体里写 `|| bad=1` 也一样是 0，因为后台是子 shell，就是 S1 那条）。
#      一道并行化之后再也红不了的门禁，比串行的慢门禁危险得多。
#      收退出码只有两种写法：起的时候记 `pids+=($!)`、逐个 `wait "$pid"` 收；
#      或者每项把 `$?` 写进自己的文件、收的时候按固定顺序逐个读。
#      后一种确实收了的，在那一行写 `# shell-lint:exit-collected <怎么收的>` 放行——
#      理由不许省，跟 .claude/abbreviations 与 naming-lint-exclude 同规矩：
#      猜不着的东西不猜，要放行就把退出码的去向写出来。
#
# 机器管得了哪一半：
#   S1 靠三个条件的合取，认的是**看得明白**的那种形态。多行函数体的收尾按行首 `}` 认，
#   定义与收尾写在同一行的函数按那一行判；赋值按命令位置认——用 eval/间接赋值的认不出来，不判。
#   「认不出」不是「通过」：这条与 rules/show-me-test.md「门禁能证明什么」同律，
#   所以下面每条拒绝都指着规则，不只指着症状。
#   command-safety.md 另外几条（echo 假装成功、管道退出码、破坏性操作先看清楚）
#   还没有可靠的机检形态，**没做**——不是漏了，是判据还没想清楚，先不写成检查。
#
# SHELL_LINT_DIR 可指定要扫的目录（selftest 拿样本喂它用），默认扫本脚本所在目录。
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 默认扫**整个包**，不只是 scripts/：install.sh 在仓根，它是使用者跑的第一个脚本，
# 而它此前不在扫描范围里——本轮刚把「只带一句话的 die 判红」写成规矩，
# scripts/ 下 17 处全补齐了，仓根那 4 处却一处没查（复核实测）。
# 样本排除写成**相对本次 SCAN** 的前缀：写死成 */fixtures/* 的话，
# 拿样本目录当 SCAN 跑时会把样本自己全排除掉，自检当场变成摆设（doc-lint 踩过）。
SCAN="${SHELL_LINT_DIR:-$(cd "$SCRIPTS/.." && pwd)}"
# 位置参数是**额外**要扫的目录（gate.sh 拿它传项目本地阶段目录）。
# 项目扔进 .claude/gate.d/ 的阶段跑在同一道门禁里，命令安全的坑对它们一样致命。
SCANS=("$SCAN")
for d in "$@"; do [[ -d "$d" ]] && SCANS+=("$(cd "$d" && pwd)"); done
[[ -n "${GATE_IN_STAGE:-}" ]] || head1 "shell 纪律检查"

# 命令位置的前缀。与 gate-lint.sh 的 BAD_RE 同一个思路：
# 一个记号出现在字符串里不等于它被执行了。
# S4：会静默丢掉未提交改动的 git 命令。脚本里出现就红——
# 脚本跑的时候没人在旁边看 `git status`，而这些命令没有 undo。
# 实测踩过：只想撤一个临时 sed，`git checkout <文件>` 把同文件里当轮所有
# 未提交的改动一起冲掉了，靠 reflog 里一个被撤销的 commit 才救回来。
S4_RE="$CMD_POS"'git[[:space:]]+((-C[[:space:]]+[^[:space:]]+[[:space:]]+)?)(checkout|restore|clean)([[:space:]]|$)'
S4_RESET="$CMD_POS"'git[[:space:]]+((-C[[:space:]]+[^[:space:]]+[[:space:]]+)?)reset[[:space:]]+.*--hard'

# S5：`rm -rf "$VAR/..."` —— 变量为空时它会从根目录往下删。
# 只判**变量后面还跟着路径**的那种：`rm -rf "$d"` 变量为空是 `rm -rf ""`，rm 自己会拒；
# 而 `rm -rf "$d/x"` 变量为空就成了 `rm -rf /x`。守卫写成 `${d:?}` 就行。
#
# 分两步判，不写成一整条正则：一整条只认得第一个参数，而且靠「整行含 :? 就跳过」来放过守卫，
# 于是 `rm -rf "$d"/x`、`rm -rf -- "$d/x"`、`rm -rf "${a:?}/x" "$b/y"` 三种全绿（审计实测）。
# 第一步挑出命令位置上的 rm -r…，第二步在行内逐个参数找**没守卫**的变量路径：
# 守卫形态是 `${名字:?}`，它的 `}` 前面有 `:?`，下面两个分支都匹配不上。
S5_CMD="$CMD_POS"'rm([[:space:]]+-[[:alnum:]-]+)*[[:space:]]+-[[:alnum:]-]*[rR]'
S5_ARG='\$(\{[A-Za-z_][A-Za-z0-9_]*\}|[A-Za-z_][A-Za-z0-9_]*)"?/'

# S6：不带参数的 `wait`。它等所有后台作业结束，然后**恒返回 0**——
# 并行跑的检测项全红了，父进程也只看到 0（实测见文件头 S6 那一段）。
# 只判「后面什么都不跟」的那种：`wait "$pid"`、`wait -n`、`wait $job` 都收得到退出码，不判。
# 结尾的 `;` 与行尾注释算不跟参数：`wait;` 与 `wait  # 等虚机` 一样吃掉失败。
S6_RE="$CMD_POS"'wait[[:space:]]*;?[[:space:]]*(#.*)?$'
# 豁免标记要带理由：只写 `# shell-lint:exit-collected` 而不说退出码去哪了，等于没说。
S6_MARK='shell-lint:exit-collected'
S6_MARK_WITH_REASON="$S6_MARK"'[[:space:]]+[^[:space:]]'

# S2 / S3 的判据（PATTERN_KILL_RE、PATTERN_PGREP_RE）与命令位置 CMD_POS 都定义在 lib.sh 一处：
# S2 / S3 与会话钩子 claude-hooks/pattern-process-guard.sh 共用，CMD_POS 与 gate-lint 共用。

fails=0; checked=0
for BASE in "${SCANS[@]}"; do
# 装进项目的 SOP 副本不扫：它由上游自己的门禁管，而它带着一整套**故意写坏的**样本——
# 项目里单跑 `bash .claude/scripts/shell-lint.sh`（README 就是这么写的）时，那些样本会被当成项目自己的违规报出来（审计实测）。
LINT_FAMILY="$(sed -n 's/^family=//p' "$SCRIPTS/../I18N" 2>/dev/null || true)"
EXCL=(-not -path "$BASE/scripts/fixtures/*" -not -path "$BASE/fixtures/*" -not -path "$BASE/.claude/${LINT_FAMILY:-singlefs-ai-sop}/*")
while IFS= read -r f; do
  rel="${f#"$BASE"/}"
  checked=$((checked+1))

  # ── S2 按模式匹配杀进程 ─────────────────────────────────
  # 只认**命令位置**的那种：行首、`;&|(){}` 之后、或 sudo/xargs/exec/then/else/do 之后。
  # 不这么锚的话，失败信息里引用这两个命令名的字符串会被当成调用——
  # 本脚本自己的 bad 消息就是第一个被误报的（写的时候实测到）。
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
        # 带了标记又写了理由的放行；只有标记没有理由的，按「说不出退出码去哪了」判
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
    # heredoc 体不是代码：`/payload.sh; rc=$?` 写在 initramfs 的 init 脚本里，
    # 按代码读会误判成「函数里给 rc 赋值」（写这条检查时实测到的第一个假红）。
    # 判「这行开了 heredoc」用 lib.sh 的 HEREDOC_RE 一处定义，注释行不判：反过来写的话，
    # 注释里一句 `# 用法示例： cat <<EOF` 就让其后整个文件当成 heredoc 体、一条都不再检查（审计实测）。
    {
      if (hd != "") { if ($0 == hd || $0 ~ ("^[ \t]*" hd "[ \t]*$")) hd = ""; L[NR] = ""; next }
      if ($0 !~ /^[ \t]*#/ && match($0, HD_RE, hdm)) hd = hdm[2]
      L[NR] = $0
    }
    END {
      nf = 0
      for (i = 1; i <= NR; i++) {
        # 两种定义形态都认：`name() {` 与 `function name {`
        # （只认前者时，写成 function 的函数整体漏检——对抗测试实测）
        nm = ""
        if (L[i] ~ /^[A-Za-z_][A-Za-z0-9_]*\(\)[ \t]*\{/) {
          nm = L[i]; sub(/\(\).*/, "", nm); gsub(/[ \t]/, "", nm)
        } else if (L[i] ~ /^function[ \t]+[A-Za-z_][A-Za-z0-9_]*([ \t]*\(\))?[ \t]*\{/) {
          nm = L[i]; sub(/^function[ \t]+/, "", nm); sub(/[ \t(].*/, "", nm)
        }
        if (nm != "") {
          # 定义与收尾写在同一行的（`S() { printf …; }`），函数体就是这一行，不往下找收尾：
          # 往下找会拿下一个函数行首的 } 当收尾，把中间的顶层赋值全算成这个函数的
          # （singlefs 2026-09-19 实测：研究脚本里 14 处假红，全是这个形态）。
          one = L[i]; sub(/^[^{]*\{/, "", one)
          if (one ~ /(^|[;&| \t])\}[ \t;]*(#.*)?$/) {
            sub(/\}[ \t;]*(#.*)?$/, "", one)
            nf++; FNM[nf] = nm; FST[nf] = i; FEN[nf] = i; ONE[nf] = one
            continue
          }
          # 多行的函数体收尾按行首 } 认。认不出收尾的就跳过这个函数——
          # 「认不出」记成不判，不记成通过。
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
          # `$(f`、`$( f`、`` `f` `` 三种调用形态都认；并用词边界，
          # 免得同前缀的别的函数（scan / scan_one）互相误伤（对抗测试实测两侧都出过问题）
          if (L[i] ~ ("\\$\\([ \t]*" FNM[k] "([ \t)]|$)")) { called = 1 }
          if (L[i] ~ ("`[ \t]*" FNM[k] "([ \t`]|$)")) { called = 1 }
          if (called) break
        }
        if (!called) continue
        # 只要还有一处**直接调用**，赋值就传得出去，判红没有依据
        # （假红实测：`init_paths /tmp/run` 与 `"$(init_paths …)"` 并存时被误拒）
        direct = 0
        for (i = 1; i <= NR; i++) {
          if (i >= FST[k] && i <= FEN[k]) continue
          if (L[i] ~ /^[ \t]*#/) continue
          # 先把命令替换整段挖掉再看有没有直接调用——不挖的话 `$(f x)` 里的 `(`
          # 会被当成命令位置，于是每个 $( ) 调用都自称「还有直接调用」，
          # 整条 S1 检查静默失效（写这段时被自己的样本抓到）
          t = L[i]
          while (match(t, /\$\([^()]*\)/)) t = substr(t, 1, RSTART - 1) " " substr(t, RSTART + RLENGTH)
          while (match(t, /`[^`]*`/))        t = substr(t, 1, RSTART - 1) " " substr(t, RSTART + RLENGTH)
          # 行首的缩进也算命令位置：函数体里缩进着的直接调用不认，就会把「还有直接调用」的函数误判成只在 $( ) 里调用
          if (t ~ ("(^[ \t]*|[;&|(){}][ \t]*)" FNM[k] "([ \t;&|)]|$)")) { direct = 1; break }
        }
        if (direct) continue
        # (b) 函数体里对非 local 变量的赋值。
        #     先把整个函数体里 local/declare 过的名字收齐再判——
        #     `local rc; rc="$(...)"` 是常规写法，两段分开看会把第二段误判成全局赋值。
        #     一行写完的函数，函数体是定义那一行花括号里的部分；多行的是两行之间的各行。
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
