#!/usr/bin/env bash
# shell 脚本的已知坑，做成会红的检查（rules/command-safety.md）。
#
# 为什么要有它（rules/sop-first.md）：
#   「注意别在 X 时候做 Y」拦不住手敲命令，一个在那时直接拒绝的检查才拦得住。
#   command-safety.md 里的纪律以前全是提醒句——而本轮审计在**本仓自己的**
#   qemu/run.sh 里挖出了其中一条的实例：日志路径靠子 shell 里的赋值往外带，
#   父进程拿到的是未定义，五处失败分支在打印诊断之前就被 set -u 带走。
#   一条写在文档里的纪律，被写文档的人自己违反了整整一轮——所以它要变成检查。
#
# 查两条：
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
#   S4 会静默丢掉未提交改动的 git 命令（checkout / restore / clean / reset --hard）
#      脚本跑的时候没人在旁边看 git status，而这些命令没有 undo。
#
#   S5 `rm -rf "$VAR/..."` 没有空值守卫
#      变量为空时它从根目录往下删。写成 `"${VAR:?}/..."` 就拦住了。
#
# 机器管得了哪一半：
#   S1 靠三个条件的合取，认的是**看得明白**的那种形态。函数体的收尾按行首 `}` 认，
#   赋值按命令位置认——写成一行流的、或用 eval/间接赋值的，认不出来，不判。
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
S5_RE='rm[[:space:]]+(-[[:alnum:]]*[rR][[:alnum:]]*[[:space:]]+)+"?\$\{?[A-Za-z_][A-Za-z0-9_]*\}?/'

# 命令位置的定义在 lib.sh 的 CMD_POS 一处，与 gate-lint 共用。
#
# 命令名认任意路径前缀（/usr/bin/pkill 也是 pkill）；选项不按拼写枚举，
# 认「有没有全模式匹配那一位」：-f / --full / 合并写法 -af。
# 写死 `-f` 的时候，`pkill --full X`、`pkill -af X`、`/usr/bin/killall X`
# 六种写法整体漏检（对抗测试实测）——它们是同一条命令的另一种拼法。
PK='([A-Za-z0-9_/.-]*/)?'
S2_RE="$CMD_POS$PK"'(pkill([[:space:]]+-[[:alnum:]-]*)*[[:space:]]+(-[[:alnum:]]*f[[:alnum:]]*|--full)|killall)([[:space:]]|$)'
# pgrep -f … | xargs kill 是同一个自杀风险的另一种写法，单列一条
S3_RE="$CMD_POS$PK"'pgrep([[:space:]]+-[[:alnum:]-]*)*[[:space:]]+(-[[:alnum:]]*f[[:alnum:]]*|--full)'

fails=0; checked=0
for BASE in "${SCANS[@]}"; do
EXCL=(-not -path "$BASE/scripts/fixtures/*" -not -path "$BASE/fixtures/*")
while IFS= read -r f; do
  rel="${f#"$BASE"/}"
  checked=$((checked+1))

  # ── S2 按模式匹配杀进程 ─────────────────────────────────
  # 只认**命令位置**的那种：行首、`;&|(){}` 之后、或 sudo/xargs/exec/then/else/do 之后。
  # 不这么锚的话，失败信息里引用这两个命令名的字符串会被当成调用——
  # 本脚本自己的 bad 消息就是第一个被误报的（写的时候实测到）。
  if hits="$(grep -nE "$S2_RE" "$f" | grep -vE '^[0-9]+:[[:space:]]*#' || true)"; [[ -n "$hits" ]]; then
    while IFS= read -r h; do
      bad "$rel:${h%%:*}  按模式匹配杀进程（pkill 的 -f，或 killall）"
      say "        $(printf '%s' "${h#*:}" | cut -c1-80)"
      howto "模式串会出现在 wrapper 自己的命令行里，把自己的 shell 一起杀掉。" \
            "改成：先 ps 列出来看清楚，再用**字面量 pid** 分第二条命令杀；" \
            "统计类改用 /proc 结构化判据并排除自身进程树（rules/command-safety.md）。"
      fails=$((fails+1))
    done <<< "$hits"
  fi

  if hits="$(grep -nE "$S3_RE" "$f" | grep -vE '^[0-9]+:[[:space:]]*#' | grep -E 'xargs|kill|until|while|if' || true)"; [[ -n "$hits" ]]; then  # 接 kill 会误杀自己；放在 if / while / until 里会命中自己、永远为真
    while IFS= read -r h; do
      bad "$rel:${h%%:*}  pgrep 的全模式匹配 —— 接 kill 与 pkill -f 同一个自杀风险，放进等待循环会命中自己、永远不退出"
      say "        $(printf '%s' "${h#*:}" | cut -c1-80)"
      howto "模式串会命中 wrapper 自己的命令行，把自己的 shell 一起杀掉。" \
            "先 ps 列出来看清楚，再用**字面量 pid** 分第二条命令杀（rules/command-safety.md）。"
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
  if hits="$(grep -nE "$S5_RE" "$f" | grep -vE '^[0-9]+:[[:space:]]*#' | grep -v ':?}' || true)"; [[ -n "$hits" ]]; then
    while IFS= read -r h; do
      bad "$rel:${h%%:*}  rm -rf 作用在变量路径上，变量为空时会从根目录往下删"
      say "        $(printf '%s' "${h#*:}" | cut -c1-80)"
      howto '加空值守卫：把 "$d/x" 写成 "${d:?}/x" —— 变量为空时 shell 直接报错退出，' \
            '而不是把 rm -rf 指到 /x（rules/command-safety.md）。'
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
  done < <(awk '
    # heredoc 体不是代码：`/payload.sh; rc=$?` 写在 initramfs 的 init 脚本里，
    # 按代码读会误判成「函数里给 rc 赋值」（写这条检查时实测到的第一个假红）。
    {
      if (hd != "") { if ($0 == hd || $0 ~ ("^[ \t]*" hd "[ \t]*$")) hd = ""; L[NR] = ""; next }
      if (match($0, /<<-?[ \t]*['"'"'"]?[A-Za-z_][A-Za-z0-9_]*['"'"'"]?/)) {
        w = substr($0, RSTART, RLENGTH)
        sub(/^<<-?[ \t]*/, "", w); gsub(/['"'"'"]/, "", w)
        hd = w
      }
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
          # 函数体收尾按行首 } 认。认不出收尾的（一行流写法）就跳过这个函数——
          # 「认不出」记成不判，不记成通过。
          e = 0
          for (j = i + 1; j <= NR; j++) if (L[j] ~ /^\}/) { e = j; break }
          if (e == 0) continue
          nf++; FNM[nf] = nm; FST[nf] = i; FEN[nf] = e
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
          if (t ~ ("(^|[;&|(){}][ \t]*)" FNM[k] "([ \t;&|)]|$)")) { direct = 1; break }
        }
        if (direct) continue
        # (b) 函数体里对非 local 变量的赋值。
        #     先把整个函数体里 local/declare 过的名字收齐再判——
        #     `local rc; rc="$(...)"` 是常规写法，两段分开看会把第二段误判成全局赋值。
        delete asg; delete loc
        for (i = FST[k] + 1; i < FEN[k]; i++) {
          if (L[i] ~ /^[ \t]*#/) continue
          n = split(L[i], seg, ";")
          for (p = 1; p <= n; p++) {
            if (match(seg[p], /^[ \t]*(local|declare|export|typeset|readonly)[ \t]+/)) {
              rest = substr(seg[p], RSTART + RLENGTH)
              m = split(rest, names, /[ \t]+/)
              for (q = 1; q <= m; q++) { nv = names[q]; sub(/=.*$/, "", nv)
                                         if (nv ~ /^[A-Za-z_][A-Za-z0-9_]*$/) loc[nv] = 1 }
            }
          }
        }
        for (i = FST[k] + 1; i < FEN[k]; i++) {
          if (L[i] ~ /^[ \t]*#/) continue
          n = split(L[i], seg, ";")
          for (p = 1; p <= n; p++) {
            if (seg[p] ~ /^[ \t]*(local|declare|export|typeset|readonly)[ \t]/) continue
            if (match(seg[p], /^[ \t]*[A-Za-z_][A-Za-z0-9_]*=/)) {
              v = substr(seg[p], RSTART, RLENGTH - 1); gsub(/[ \t]/, "", v)
              if (!(v in loc) && !(v in asg)) asg[v] = i
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
