#!/usr/bin/env bash
# Claude Code 的 PreToolUse 钩子（Bash 工具）：命令里有按模式找进程的写法（pgrep 或 pkill 带 -f / --full，或 killall），执行前拒绝。
#
# 为什么（rules/command-safety.md「`pkill -f` / `killall` 一律禁用」那一节）：
#   模式串会命中发出这条命令的 shell 自己的命令行：拿它杀进程会连自己一起杀，拿它当等待条件的循环永远不退出，
#   而且不报错，外面看到的只是「还在等」。scripts/shell-lint.sh 的 S2、S3 只扫脚本文件，会话里手敲的命令它看不见，
#   规则里的一句提醒又拦不住手敲的命令（singlefs 2026-09-17、2026-09-19 两次实测：子 agent 拿 pgrep -f 当等待条件，
#   在后台空转到调度的一方查进度才发现）。所以在执行之前拒绝。
#
# 判据在哪：scripts/lib.sh 的 PATTERN_KILL_RE、PATTERN_PGREP_RE，与 shell-lint 的 S2、S3 是同一份；
#   只认命令位置（lib.sh 的 CMD_POS），写在 grep 参数、echo 字符串里当数据的不判。
# 判哪些文本（内嵌的 python 从钩子 JSON 的 tool_input.command 里取出来，逐行交给 grep -E）：
#   - 命令文本本身；
#   - 喂给 bash / sh / dash / zsh / ksh 的 heredoc 正文（它是代码），包括经管道进 shell 的（cat <<'EOF' | bash）；
#     喂给别的命令的正文（cat > 文件 <<'EOF'、python3 - <<'EOF'）是数据，去掉不判；找不到收尾行的不当 heredoc；
#   - bash / sh / dash / zsh / ksh 的 -c 字符串参数（-lc、-ec 这类合并写法也算）与 <<< 字符串，当成额外几行代码；
#   以 # 开头的注释行跳过。
# 退出码：命中 2（Claude Code 拦下这条命令，把 stderr 交给模型）；没命中、或输入里没有命令 0；
#   输入不是 JSON 对象 1（Claude Code 照常执行命令，stderr 只在详细模式里给人看）——「没判」不记成「判过」。
#
# 怎么注册：在项目的 .claude/settings.json 里给 hooks.PreToolUse 加一项
#   {"matcher": "Bash", "hooks": [{"type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR\"/.claude/singlefs-ai-sop/scripts/claude-hooks/pattern-process-guard.sh"}]}
# 没注册的会话里，这一条仍然只靠 rules/command-safety.md 的文字。
# 手喂一条看效果： printf '%s' '{"tool_name":"Bash","tool_input":{"command":"…"}}' | bash 本文件
# 依赖：python3、GNU grep，以及 lib.sh 要的 gawk（lib.sh 找不到 gawk 就报错退出 1，命令照常执行）。
#
# 管不到的（实测；判别力样本在 scripts/fixtures/pattern-process-guard/）：
#   漏判——前缀不在 CMD_POS 里的：timeout 5 …、nohup …、nice -n 19 …、watch '…'、ssh 主机 '…' 后面跟着的那条命令；
#         eval 带引号的参数（eval 后面不带引号的判得到）；变量里拼出来的命令；
#         先写进脚本文件再执行的：cat > x.sh <<'EOF' 的正文按数据去掉，之后的 bash x.sh 这一步看不到文件内容
#         （脚本文件归 shell-lint 管，前提是它在 shell-lint 的扫描范围里）。
#   误拒——引号里当数据写、而前面恰好是 ( | ; ! { } 或反引号的：grep -E "x|pgrep -f"、git commit -m "修好 (pgrep -f 那处)"；
#         -c 字符串里当数据写的同类形态也一样。要把这几个字当数据写进文件，放进喂给 cat 的 heredoc 正文。
#   判不准——heredoc 所在的那一行按标点切出它属于哪条命令，不管引号：引号里的 ; | ( 会切错，切错时按「不进 shell」算；
#         同一行开了几个 heredoc 的，按次序各找各的收尾行。
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HOOK_DIR/../lib.sh"
PROC_PY="$(cd "$HOOK_DIR/.." && pwd)/proc.py"

# 从钩子输入里取出要判的代码行，一行一条，写到标准输出。python 程序用 -c 传，标准输入留给钩子的 JSON。
# 输入不是 JSON 对象时退出码 3。
IFS= read -r -d '' EXTRACT_CODE_LINES <<'PY' || true
import json, os, re, shlex, sys

SHELL_NAMES = {"bash", "sh", "dash", "zsh", "ksh"}
OPERATOR_CHARACTERS = ";&|()<>"
# heredoc 的开头：<< 或 <<-，定界符可以带引号；<<< 是字符串，不是 heredoc
HEREDOC_OPERATOR = re.compile(r"(?<!<)<<(?!<)(-?)[ \t]*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\2")
# 一条简单命令的左边界：分号、&&、||、管道、单独的 &（2>&1 与 &> 里的不算）、括号、花括号、反引号
COMMAND_BOUNDARY = re.compile(r";|&&|\|\||\|&?|(?<![<>])&(?!>)|[(){}`]")
SHELL_OPTIONS_WITH_VALUE = {"-o", "+o", "-O", "+O"}
MAXIMUM_NESTING = 8


def words_of(fragment):
    """按 shell 的规矩切词（引号去掉、运算符单列）；切不开（引号没配对）返回 None。"""
    lexer = shlex.shlex(fragment, posix=True, punctuation_chars=OPERATOR_CHARACTERS)
    lexer.whitespace_split = True
    try:
        return list(lexer)
    except ValueError:
        return None


def is_operator(word):
    return word != "" and all(character in OPERATOR_CHARACTERS for character in word)


def ends_command(word):
    """分号、&&、||、管道、&、括号结束一条简单命令；重定向（带 < 或 >）不结束。"""
    return is_operator(word) and "<" not in word and ">" not in word


def is_shell_word(word):
    return os.path.basename(word) in SHELL_NAMES


def heredoc_feeds_shell(line, operator):
    """正文进不进 shell：开 heredoc 的那条简单命令里有 shell（bash <<EOF、sudo bash <<EOF），或它的输出经管道进 shell（cat <<EOF | bash）。"""
    head = line[:operator.start()]
    boundaries = list(COMMAND_BOUNDARY.finditer(head))
    if boundaries:
        head = head[boundaries[-1].end():]
    head_words = words_of(head)
    if any(is_shell_word(word) for word in (head.split() if head_words is None else head_words)):
        return True
    tail = line[operator.end():]
    tail_words = words_of(tail)
    piped = False
    for word in (tail.split() if tail_words is None else tail_words):
        if ends_command(word):
            if word not in ("|", "|&"):
                return False
            piped = True
        elif piped and is_shell_word(word):
            return True
    return False


def separate_heredoc_bodies(text):
    """去掉 heredoc 正文，返回（去掉正文之后的文本, 喂给 shell 的那几段正文）。找不到收尾行的不当 heredoc。"""
    lines = text.split("\n")
    kept_lines, shell_bodies = [], []
    line_index = 0
    while line_index < len(lines):
        line = lines[line_index]
        kept_lines.append(line)
        line_index += 1
        if line.lstrip().startswith("#"):
            continue
        for operator in HEREDOC_OPERATOR.finditer(line):
            delimiter = operator.group(3)
            closing_index = next((candidate for candidate in range(line_index, len(lines)) if lines[candidate].strip() == delimiter), None)
            if closing_index is None:
                continue
            if heredoc_feeds_shell(line, operator):
                shell_bodies.append("\n".join(lines[line_index:closing_index]))
            kept_lines.append(lines[closing_index])
            line_index = closing_index + 1
    return "\n".join(kept_lines), shell_bodies


def strings_run_by_shell(command_words):
    """一条简单命令里交给 shell 当代码跑的字符串：bash -c '…'（-lc、-ec 这类合并写法也算）与 bash <<< '…'。"""
    found = []
    for position, word in enumerate(command_words):
        if word == "<<<" and position + 1 < len(command_words) and any(is_shell_word(earlier) for earlier in command_words[:position]):
            found.append(command_words[position + 1])
        if not is_shell_word(word):
            continue
        option_index = position + 1
        while option_index < len(command_words):
            option = command_words[option_index]
            if option in SHELL_OPTIONS_WITH_VALUE:
                option_index += 2
                continue
            if not option.startswith("-") or option == "-":
                break
            if re.fullmatch(r"-[A-Za-z]*c[A-Za-z]*", option):
                if option_index + 1 < len(command_words):
                    found.append(command_words[option_index + 1])
                break
            option_index += 1
    return found


def shell_strings_in(text):
    """整段切词；引号没配对切不开时逐行切，切不开的那一行不取字符串（它自己仍按原文判）。"""
    words = words_of(text)
    if words is None:
        words = []
        for line in text.split("\n"):
            words.extend(words_of(line) or [])
            words.append(";")
    found, command_words = [], []
    for word in words + [";"]:
        if ends_command(word):
            found.extend(strings_run_by_shell(command_words))
            command_words = []
        else:
            command_words.append(word)
    return found


def code_lines_of(text, nesting):
    if nesting > MAXIMUM_NESTING:
        return text.split("\n")
    kept_text, shell_bodies = separate_heredoc_bodies(text)
    lines = kept_text.split("\n")
    for body in shell_bodies:
        lines.extend(code_lines_of(body, nesting + 1))
    for string in shell_strings_in(kept_text):
        lines.extend(code_lines_of(string, nesting + 1))
    return lines


def main():
    try:
        hook_input = json.load(sys.stdin)
    except ValueError:
        return 3
    if not isinstance(hook_input, dict):
        return 3
    if hook_input.get("tool_name", "Bash") != "Bash":
        return 0
    tool_input = hook_input.get("tool_input")
    command = tool_input.get("command") if isinstance(tool_input, dict) else None
    if not isinstance(command, str) or not command.strip():
        return 0
    sys.stdout.write("".join(line + "\n" for line in code_lines_of(command, 0) if line.strip()))
    return 0


sys.exit(main())
PY

if ! code_lines="$(python3 -c "$EXTRACT_CODE_LINES")"; then
  printf '%s\n' "! pattern-process-guard：钩子输入不是 JSON 对象，这条命令没判（照常执行）。" \
    "  看一眼 .claude/settings.json 里这个钩子是不是挂在 PreToolUse 的 Bash 上；手喂时输入要形如 {\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"…\"}}。" >&2
  exit 1
fi
[[ -n "$code_lines" ]] || exit 0
hits="$(printf '%s\n' "$code_lines" | grep -vE '^[[:space:]]*#' | grep -E "$PATTERN_KILL_RE|$PATTERN_PGREP_RE" || true)"
[[ -n "$hits" ]] || exit 0
hit_count="$(printf '%s\n' "$hits" | wc -l)"
first_hit="${hits%%$'\n'*}"
{
  printf '✗ 这条命令里有按模式找进程的写法（pgrep 或 pkill 带 -f / --full，或 killall），执行前拒绝。共 %s 处，第一处：%s\n' "$hit_count" "${first_hit:0:160}"
  printf '%s\n' '→ 怎么办：模式串会命中发出这条命令的 shell 自己，拿它等进程的循环永远不退出，拿它杀进程会连自己一起杀（rules/command-safety.md）。改成按进程号办事：' \
    '    自己起的进程：起的时候 pid=$! 记下来，用 wait "$pid"，或者 while kill -0 "$pid" 2>/dev/null; do sleep 5; done，外面套 timeout；' \
    '    要会话在它跑完时叫醒你：放后台起（run_in_background），等完成通知，不写轮询；' \
    "    不是自己起的进程：python3 $PROC_PY find 可执行文件名 [--argument 参数] 拿进程号（不列发出命令的那一支），" \
    "      再 python3 $PROC_PY wait 进程号 --timeout 秒，或 python3 $PROC_PY stop 进程号；" \
    '    只是要把这几个字当数据写进文件：写进喂给 cat 的 heredoc 正文（正文不判）。'
} >&2
exit 2
