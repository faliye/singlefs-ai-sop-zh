#!/usr/bin/env bash
# admission: always 判的是此刻全仓的文本，几秒跑完；每一轮门禁都现判，上一轮的结论不替这一轮作保
# run-condition: command gawk
# shell 脚本的已知坑，做成会红的检查（rules/command-safety.md）。
#
# 查七条：
#
#   S1 子 shell 里的赋值传不回父进程
#      三个条件同时成立才判红，误报面很窄：
#        调用：有个函数，文件里以 `$(函数名 ...)` 的形式调用它；
#        赋值：这个函数的函数体里给一个**非 local** 变量赋了值；
#        引用：那个变量在这个函数之外被引用（$变量名 或 ${变量名}）。
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

PACKAGE_SCRIPTS_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 默认扫整个包而不只是 scripts/：install.sh 在仓根。
# 样本排除写成相对本次扫描根的前缀：写死成 */fixtures/* 的话，
# 拿样本目录当扫描根跑时会把样本自己全排除掉，自证当场变成摆设。
DEFAULT_SCAN_ROOT="${SHELL_LINT_DIR:-$(cd "$PACKAGE_SCRIPTS_DIRECTORY/.." && pwd)}"
SCAN_ROOTS=("$DEFAULT_SCAN_ROOT")
for extra_scan_directory in "$@"; do [[ -d "$extra_scan_directory" ]] && SCAN_ROOTS+=("$(cd "$extra_scan_directory" && pwd)"); done
[[ -n "${GATE_IN_STAGE:-}" ]] || head1 "shell 纪律检查"

# S4：只想撤一处临时改动，`git checkout <文件>` 会把同文件里当轮所有未提交的改动一起冲掉。
S4_DISCARDING_GIT_COMMAND_PATTERN="$CMD_POS"'git[[:space:]]+((-C[[:space:]]+[^[:space:]]+[[:space:]]+)?)(checkout|restore|clean)([[:space:]]|$)'
S4_HARD_RESET_PATTERN="$CMD_POS"'git[[:space:]]+((-C[[:space:]]+[^[:space:]]+[[:space:]]+)?)reset[[:space:]]+.*--hard'

# S5：只判变量后面还跟着路径的那种：`rm -rf "$directory"` 变量为空是 `rm -rf ""`，rm 自己会拒。
# 分两步判，不写成一整条正则：一整条只认得第一个参数，而且靠「整行含 :? 就跳过」来放过守卫，
# 于是 `rm -rf "$directory"/x`、`rm -rf -- "$directory/x"`、`rm -rf "${cache_directory:?}/x" "$output_directory/y"` 三种全绿。
# 第一步挑出命令位置上的 rm -r…，第二步只在 rm 自己那一段（到第一个 `;`、`&`、`|` 为止）里逐个参数找没守卫的变量路径，
# 同一行 rm 前后别的命令（`[[ … "$directory"/x ]] && rm …`、`rm -rf "$directory" && mkdir -p "$directory/work"`）里的变量路径不算 rm 的参数：
# 守卫形态 `${名字:?}` 的 `}` 前面有 `:?`，S5_UNGUARDED_PATH_ARGUMENT_PATTERN 两个分支都匹配不上。
S5_RECURSIVE_RM_PATTERN="$CMD_POS"'rm([[:space:]]+-[[:alnum:]-]+)*[[:space:]]+-[[:alnum:]-]*[rR]'
S5_UNGUARDED_PATH_ARGUMENT_PATTERN='\$(\{[A-Za-z_][A-Za-z0-9_]*\}|[A-Za-z_][A-Za-z0-9_]*)"?/'

# S6：只判后面什么都不跟的：`wait "$pid"`、`wait -n`、`wait $job` 都收得到退出码，不判。
# 结尾的 `;` 与行尾注释算不跟参数：`wait;` 与 `wait  # 等虚机` 一样吃掉失败。
S6_BARE_WAIT_PATTERN="$CMD_POS"'wait[[:space:]]*;?[[:space:]]*(#.*)?$'
S6_EXIT_COLLECTED_MARKER='shell-lint:exit-collected'
S6_EXIT_COLLECTED_MARKER_WITH_REASON="$S6_EXIT_COLLECTED_MARKER"'[[:space:]]+[^[:space:]]'

# S7：前段输出越大（git show / git diff）、机器越忙越容易撞上。
# 复现：`set -uo pipefail; yes X | head -200000 | grep -q X` 稳定返回 141。
# 三种不判：脚本没设 pipefail（管道退出码本来就只看最后一段）；
# `grep -q … <<<"$变量"` 这种没有前段的形态；`… || grep -q 模式 文件` 这种「或」链（`||` 不是管道，正则要 `|` 前面不是 `|`）。
S7_PIPE_INTO_QUIET_GREP_PATTERN='(^|[^|])\|[[:space:]]*grep[[:space:]]+(-[A-Za-z]*q[A-Za-z]*)([[:space:]]|$)'
S7_PIPEFAIL_SETTING_PATTERN='^[[:space:]]*set[[:space:]].*pipefail'

# S2 / S3 的判据（PATTERN_KILL_RE、PATTERN_PGREP_RE）与命令位置 CMD_POS 都定义在 lib.sh 一处：
# S2 / S3 与会话钩子 claude-hooks/pattern-process-guard.sh 共用，CMD_POS 与 gate-lint 共用。
# 只认命令位置：一个记号出现在字符串里（本脚本自己的 bad 消息就是）不等于它被执行了。

failure_count=0; checked_script_count=0
for scan_root in "${SCAN_ROOTS[@]}"; do
# 装进项目的 SOP 副本不扫：它由上游自己的门禁管，而它带着一整套故意写坏的样本，
# 项目里单跑时会被当成项目自己的违规报出来。
PACKAGE_FAMILY_NAME="$(sed -n 's/^family=//p' "$PACKAGE_SCRIPTS_DIRECTORY/../I18N" 2>/dev/null || true)"
EXCLUDED_PATH_ARGUMENTS=(-not -path "$scan_root/scripts/fixtures/*" -not -path "$scan_root/fixtures/*" -not -name "*.case.sh" -not -path "$scan_root/.claude/${PACKAGE_FAMILY_NAME:-singlefs-ai-sop}/*")
while IFS= read -r scanned_file; do
  relative_path="${scanned_file#"$scan_root"/}"
  checked_script_count=$((checked_script_count+1))

  # ── S2 按模式匹配杀进程 ─────────────────────────────────
  if matched_lines="$(grep -nE "$PATTERN_KILL_RE" "$scanned_file" | grep -vE '^[0-9]+:[[:space:]]*#' || true)"; [[ -n "$matched_lines" ]]; then
    while IFS= read -r matched_line; do
      bad "$relative_path:${matched_line%%:*}  按模式匹配杀进程（pkill 的 -f，或 killall）"
      say "        $(printf '%s' "${matched_line#*:}" | cut -c1-80)"
      howto "模式串会出现在 wrapper 自己的命令行里，把自己的 shell 一起杀掉。" \
            "改成：先 ps 列出来看清楚，再用**字面量 pid** 分第二条命令杀；" \
            "统计类改用 /proc 结构化判据并排除自身进程树（rules/command-safety.md）。"
      failure_count=$((failure_count+1))
    done <<< "$matched_lines"
  fi

  if matched_lines="$(grep -nE "$PATTERN_PGREP_RE" "$scanned_file" | grep -vE '^[0-9]+:[[:space:]]*#' || true)"; [[ -n "$matched_lines" ]]; then
    while IFS= read -r matched_line; do
      bad "$relative_path:${matched_line%%:*}  pgrep 的全模式匹配 —— 与 pkill -f 同一个自杀风险，放进等待循环还会命中自己、永远不退出"
      say "        $(printf '%s' "${matched_line#*:}" | cut -c1-80)"
      howto "模式串会命中 wrapper 自己的命令行：接 kill 是把自己的 shell 一起杀掉，放进 if / while / until 是永远为真；" \
            "先赋给变量再 kill、只是数一数，都一样。要杀先 ps 看清楚再用**字面量 pid** 分第二条命令杀；" \
            "等进程结束用写死的 pid（kill -0）或 wait；统计类改用 /proc 并排掉自己这一支进程树（rules/command-safety.md）。"
      failure_count=$((failure_count+1))
    done <<< "$matched_lines"
  fi

  # ── S4 会静默丢掉未提交改动的 git 命令 ──────────────────
  if matched_lines="$(grep -nE "$S4_DISCARDING_GIT_COMMAND_PATTERN|$S4_HARD_RESET_PATTERN" "$scanned_file" | grep -vE '^[0-9]+:[[:space:]]*#' || true)"; [[ -n "$matched_lines" ]]; then
    while IFS= read -r matched_line; do
      bad "$relative_path:${matched_line%%:*}  脚本里用了会丢掉未提交改动的 git 命令"
      say "        $(printf '%s' "${matched_line#*:}" | cut -c1-80)"
      howto "checkout / restore / clean / reset --hard 会直接丢掉未提交的改动，而且没有 undo。" \
            "脚本跑的时候没人在旁边看 git status，所以别写进脚本。" \
            "真要在脚本里回到干净状态：先 git stash，或者整个仓拷一份出来在副本上做" \
            "（rules/command-safety.md）。"
      failure_count=$((failure_count+1))
    done <<< "$matched_lines"
  fi

  # ── S5 rm -rf 作用在变量路径上，没有空值守卫 ─────────────
  if matched_lines="$(grep -nE "$S5_RECURSIVE_RM_PATTERN" "$scanned_file" | grep -vE '^[0-9]+:[[:space:]]*#' || true)"; [[ -n "$matched_lines" ]]; then
    while IFS= read -r matched_line; do
      # 行内逐个参数看有没有没守卫的。不用 `| head -1`：head 会让上游 grep 拿 SIGPIPE，pipefail 下整条管道退 141。
      rm_segments="$(printf '%s\n' "${matched_line#*:}" | grep -oE "${S5_RECURSIVE_RM_PATTERN}[^;&|]*" || true)"
      unguarded="$(printf '%s\n' "$rm_segments" | grep -oE "$S5_UNGUARDED_PATH_ARGUMENT_PATTERN" || true)"
      unguarded="${unguarded%%$'\n'*}"
      [[ -n "$unguarded" ]] || continue
      bad "$relative_path:${matched_line%%:*}  rm -rf 作用在变量路径上（$unguarded），变量为空时会从根目录往下删"
      say "        $(printf '%s' "${matched_line#*:}" | cut -c1-80)"
      howto '加空值守卫：把 "$directory/x" 写成 "${directory:?}/x" —— 变量为空时 shell 直接报错退出，' \
            '而不是把 rm -rf 指到 /x（rules/command-safety.md）。'
      failure_count=$((failure_count+1))
    done <<< "$matched_lines"
  fi

  # ── S6 不带参数的 wait，把并行作业的失败全吃掉 ───────────
  if matched_lines="$(grep -nE "$S6_BARE_WAIT_PATTERN" "$scanned_file" | grep -vE '^[0-9]+:[[:space:]]*#' || true)"; [[ -n "$matched_lines" ]]; then
    while IFS= read -r matched_line; do
      s6_wait_line="${matched_line#*:}"
      if [[ "$s6_wait_line" == *"$S6_EXIT_COLLECTED_MARKER"* ]]; then
        [[ "$s6_wait_line" =~ $S6_EXIT_COLLECTED_MARKER_WITH_REASON ]] && continue
        bad "$relative_path:${matched_line%%:*}  $S6_EXIT_COLLECTED_MARKER 标记后面没写退出码收在哪"
        howto "这个标记是用来说清「这一批后台作业的退出码去哪了」的，只写标记等于没说。" \
              "照这个样子写：wait  # $S6_EXIT_COLLECTED_MARKER 每项把退出码写进 \$work/<项>/exit，下面逐个读" \
              "（rules/command-safety.md）。"
        failure_count=$((failure_count+1))
        continue
      fi
      bad "$relative_path:${matched_line%%:*}  不带参数的 wait —— 后台作业里红了几个，它的退出码还是 0"
      say "        $(printf '%s' "$s6_wait_line" | cut -c1-80)"
      howto "光秃的 wait 恒返回 0，并行跑的检测项全红了父进程也看不见。" \
            "一道并行化之后再也红不了的门禁，比串行的慢门禁危险得多。" \
            "两种收法：起的时候记 pids+=(\$!)，收的时候逐个 wait \"\$pid\" 取退出码；" \
            "或者每项把退出码写进自己的文件，收的时候按固定顺序逐个读（rules/command-safety.md）。" \
            "退出码确实在别处收了的，在这一行写 # $S6_EXIT_COLLECTED_MARKER <怎么收的>。"
      failure_count=$((failure_count+1))
    done <<< "$matched_lines"
  fi

  # ── S7 pipefail 下以提前退出的 grep -q 收尾的管道 ───────
  if grep -qE "$S7_PIPEFAIL_SETTING_PATTERN" "$scanned_file"; then
    if matched_lines="$(grep -nE "$S7_PIPE_INTO_QUIET_GREP_PATTERN" "$scanned_file" | grep -vE '^[0-9]+:[[:space:]]*#' || true)"; [[ -n "$matched_lines" ]]; then
      while IFS= read -r matched_line; do
        bad "$relative_path:${matched_line%%:*}  pipefail 下的管道以 grep -q 收尾 —— 命中会被读成没命中"
        say "        $(printf '%s' "${matched_line#*:}" | cut -c1-80)"
        howto "grep -q 一命中就退出，前段吃 SIGPIPE，管道整体返回 141，而 if 把它读成「没命中」。" \
              "把前段的输出先落到变量，再对变量判：" \
              "out=\$(前段 || true); if grep -q '模式' <<<\"\$out\"; then …" \
              "前段是 git show / git diff 时尤其要改：输出越大越容易吃 SIGPIPE（rules/command-safety.md）。"
        failure_count=$((failure_count+1))
      done <<< "$matched_lines"
    fi
  fi

  # ── S1 子 shell 里的赋值传不回父进程 ────────────────────
  while IFS=$'\037' read -r assignment_line_number function_name variable_name; do
    [[ -z "$assignment_line_number" ]] && continue
    bad "$relative_path:$assignment_line_number  $function_name() 里给 \$$variable_name 赋值，而它只在 \$( ) 里被调用——外面拿不到这个值"
    howto "命令替换开的是子 shell，赋值到不了父进程；引用处拿到的是旧值，" \
          "或者在 set -u 下当场是「unbound variable」，把脚本在打印诊断之前带走。" \
          "改法：让调用方把这个值**作为参数传进去**，或者由函数落到文件、" \
          "调用方读文件——不要靠变量往外带（rules/command-safety.md）。"
    failure_count=$((failure_count+1))
  done < <(awk -v HEREDOC_PATTERN="$HEREDOC_RE" '
    # heredoc 体不是代码，按代码读会把里面的 `exit_code=$?` 误判成函数里的赋值。
    # 注释行不判开没开 heredoc：注释里一句 `# 用法示例： cat <<EOF` 会让其后整个文件当成 heredoc 体、一条都不再检查。
    {
      if (heredoc_terminator != "") { if ($0 == heredoc_terminator || $0 ~ ("^[ \t]*" heredoc_terminator "[ \t]*$")) heredoc_terminator = ""; file_lines[NR] = ""; next }
      if ($0 !~ /^[ \t]*#/ && match($0, HEREDOC_PATTERN, heredoc_match)) heredoc_terminator = heredoc_match[2]
      file_lines[NR] = $0
    }
    END {
      function_count = 0
      for (line_number = 1; line_number <= NR; line_number++) {
        # 两种定义形态都认：`name() {` 与 `function name {`
        # （只认前者的话，写成 function 的函数会整体漏检）
        function_name = ""
        if (file_lines[line_number] ~ /^[A-Za-z_][A-Za-z0-9_]*\(\)[ \t]*\{/) {
          function_name = file_lines[line_number]; sub(/\(\).*/, "", function_name); gsub(/[ \t]/, "", function_name)
        } else if (file_lines[line_number] ~ /^function[ \t]+[A-Za-z_][A-Za-z0-9_]*([ \t]*\(\))?[ \t]*\{/) {
          function_name = file_lines[line_number]; sub(/^function[ \t]+/, "", function_name); sub(/[ \t(].*/, "", function_name)
        }
        if (function_name != "") {
          # 定义与收尾写在同一行的（`say_line() { printf …; }`），函数体就是这一行，不往下找收尾：
          # 往下找会拿下一个函数行首的 } 当收尾，把中间的顶层赋值全算成这个函数的。
          single_line_body = file_lines[line_number]; sub(/^[^{]*\{/, "", single_line_body)
          if (single_line_body ~ /(^|[;&| \t])\}[ \t;]*(#.*)?$/) {
            sub(/\}[ \t;]*(#.*)?$/, "", single_line_body)
            function_count++; function_names[function_count] = function_name; function_start_lines[function_count] = line_number; function_end_lines[function_count] = line_number; single_line_bodies[function_count] = single_line_body
            continue
          }
          # 认不出收尾的跳过这个函数：记成不判，不记成通过。
          closing_line_number = 0
          for (search_line_number = line_number + 1; search_line_number <= NR; search_line_number++) if (file_lines[search_line_number] ~ /^\}/) { closing_line_number = search_line_number; break }
          if (closing_line_number == 0) continue
          function_count++; function_names[function_count] = function_name; function_start_lines[function_count] = line_number; function_end_lines[function_count] = closing_line_number; single_line_bodies[function_count] = ""
        }
      }
      for (function_index = 1; function_index <= function_count; function_index++) {
        # 调用：有没有 `$(函数名` 形式的调用（在函数体之外）
        is_called_in_substitution = 0
        for (line_number = 1; line_number <= NR; line_number++) {
          if (line_number >= function_start_lines[function_index] && line_number <= function_end_lines[function_index]) continue
          if (file_lines[line_number] ~ /^[ \t]*#/) continue
          # `$(函数名`、`$( 函数名`、`` `函数名` `` 三种调用形态都认；用词边界，免得同前缀的函数（scan / scan_one）互相误伤
          if (file_lines[line_number] ~ ("\\$\\([ \t]*" function_names[function_index] "([ \t)]|$)")) { is_called_in_substitution = 1 }
          if (file_lines[line_number] ~ ("`[ \t]*" function_names[function_index] "([ \t`]|$)")) { is_called_in_substitution = 1 }
          if (is_called_in_substitution) break
        }
        if (!is_called_in_substitution) continue
        # 只要还有一处直接调用，赋值就传得出去，判红没有依据
        has_direct_call = 0
        for (line_number = 1; line_number <= NR; line_number++) {
          if (line_number >= function_start_lines[function_index] && line_number <= function_end_lines[function_index]) continue
          if (file_lines[line_number] ~ /^[ \t]*#/) continue
          # 先把命令替换整段挖掉再看：不挖的话 `$(函数名 参数)` 里的 `(` 会被当成命令位置，
          # 每个 $( ) 调用都自称「还有直接调用」，整条 S1 静默失效
          line_without_substitutions = file_lines[line_number]
          while (match(line_without_substitutions, /\$\([^()]*\)/)) line_without_substitutions = substr(line_without_substitutions, 1, RSTART - 1) " " substr(line_without_substitutions, RSTART + RLENGTH)
          while (match(line_without_substitutions, /`[^`]*`/))        line_without_substitutions = substr(line_without_substitutions, 1, RSTART - 1) " " substr(line_without_substitutions, RSTART + RLENGTH)
          # 行首的缩进也算命令位置：函数体里缩进着的直接调用不认，就会把「还有直接调用」的函数误判成只在 $( ) 里调用
          if (line_without_substitutions ~ ("(^[ \t]*|[;&|(){}][ \t]*)" function_names[function_index] "([ \t;&|)]|$)")) { has_direct_call = 1; break }
        }
        if (has_direct_call) continue
        # 赋值：函数体里对非 local 变量的赋值。先把 local/declare 过的名字收齐再判：
        #     `local exit_code; exit_code="$(...)"` 两段分开看会把第二段误判成全局赋值。
        delete assignment_line_by_name; delete local_names; delete body_lines; delete body_line_numbers; body_line_count = 0
        if (function_start_lines[function_index] == function_end_lines[function_index]) { body_line_count = 1; body_lines[1] = single_line_bodies[function_index]; body_line_numbers[1] = function_start_lines[function_index] }
        else for (line_number = function_start_lines[function_index] + 1; line_number < function_end_lines[function_index]; line_number++) { body_line_count++; body_lines[body_line_count] = file_lines[line_number]; body_line_numbers[body_line_count] = line_number }
        for (body_index = 1; body_index <= body_line_count; body_index++) {
          if (body_lines[body_index] ~ /^[ \t]*#/) continue
          segment_count = split(body_lines[body_index], segments, ";")
          for (segment_index = 1; segment_index <= segment_count; segment_index++) {
            if (match(segments[segment_index], /^[ \t]*(local|declare|export|typeset|readonly)[ \t]+/)) {
              declared_text = substr(segments[segment_index], RSTART + RLENGTH)
              declared_word_count = split(declared_text, declared_words, /[ \t]+/)
              for (declared_word_index = 1; declared_word_index <= declared_word_count; declared_word_index++) { declared_name = declared_words[declared_word_index]; sub(/=.*$/, "", declared_name)
                                         if (declared_name ~ /^[A-Za-z_][A-Za-z0-9_]*$/) local_names[declared_name] = 1 }
            }
          }
        }
        for (body_index = 1; body_index <= body_line_count; body_index++) {
          if (body_lines[body_index] ~ /^[ \t]*#/) continue
          segment_count = split(body_lines[body_index], segments, ";")
          for (segment_index = 1; segment_index <= segment_count; segment_index++) {
            if (segments[segment_index] ~ /^[ \t]*(local|declare|export|typeset|readonly)[ \t]/) continue
            if (match(segments[segment_index], /^[ \t]*[A-Za-z_][A-Za-z0-9_]*=/)) {
              assigned_name = substr(segments[segment_index], RSTART, RLENGTH - 1); gsub(/[ \t]/, "", assigned_name)
              if (!(assigned_name in local_names) && !(assigned_name in assignment_line_by_name)) assignment_line_by_name[assigned_name] = body_line_numbers[body_index]
            }
          }
        }
        # 引用：那个变量在函数体之外被引用
        for (assigned_name in assignment_line_by_name) {
          for (line_number = 1; line_number <= NR; line_number++) {
            if (line_number >= function_start_lines[function_index] && line_number <= function_end_lines[function_index]) continue
            if (file_lines[line_number] ~ /^[ \t]*#/) continue
            if (file_lines[line_number] ~ ("\\$\\{?" assigned_name "\\y")) {
              printf "%d\037%s\037%s\n", assignment_line_by_name[assigned_name], function_names[function_index], assigned_name
              break
            }
          }
        }
      }
    }
  ' "$scanned_file")
done < <(find "$scan_root" -name '*.sh' "${EXCLUDED_PATH_ARGUMENTS[@]}" | sort)
done

say ""
if [[ $failure_count -gt 0 ]]; then
  bad "shell 纪律检查失败：$failure_count 处（共检查 $checked_script_count 个脚本）"   # gate-lint:summary
  exit 1
fi
ok "shell 纪律检查通过（共 $checked_script_count 个脚本）"
