#!/usr/bin/env bash
# hook-events: PostToolUse:Bash
# hook-registration: optional 只记不拒，命令已经跑完才提醒；不注册时这一条只靠 rules/verify-before-claiming.md 的文字，提交前的门禁不依赖它
# gate-similar: root-entry-guard.sh 同挂在 PostToolUse 的 Bash 上，但它判项目根下多出来的没登记条目、命中就报给 agent 要它处理；这里判命令文本里丢输出又判计数或空的写法、只记不拒，对象与处置都不同
# gate-similar: pattern-process-guard.sh 同样逐条读 Bash 命令的文本找写法，但它挂在 PreToolUse、命中就拒绝执行；这里挂在执行之后、只记不拒，并进去就让一道闸里混着拒与不拒两种处置
# gate-similar: shell-lint.sh 它判脚本文件里的 shell 写法、在门禁里判红；会话里手敲的命令不经过它，判据（丢输出的重定向与计数判空同在一条命令里）它也没有
# gate-overlap:copy-kept pattern-process-guard.sh 相同的是读钩子输入（JSON、取 Bash 的 command）那十来行；两份钩子各自内嵌 python、单文件就能注册，抽成共用库要两边都多带一份文件
# admission: always Claude Code 在每一次 Bash 调用之后调它，每条命令都要现判
# run-condition: command python3 gawk
# Claude Code 的 PostToolUse 钩子（Bash 工具）：命令把输出丢进 /dev/null，同一条命令里又在判计数或空，记进检出记录、在结果里提醒一句，不拒绝
# （rules/verify-before-claiming.md「拿来下结论的命令不丢输出」）。
#
# 判据（判定在内嵌的 python 的 judge_command）：
#   丢输出：2>/dev/null、&>/dev/null、>/dev/null 2>&1（DISCARD_FORMS）；
#   判计数或空：grep -c / --count、wc -l / -c / -w / -m、test -z / -n、[ -z / -n 与 [[ -z / -n、|| echo 0 / || printf 0（COUNT_FORMS）；
#   两样都在整条命令的文本里（整行是注释的不算）就算命中。
#   命令里写了 `# discarded-output: <为什么可以丢>`（理由至少 8 个字）的，记下「已决定照跑」，不提醒。
# 检出记录：一行一次命中，TSV 七列：日期、session_id、agent_id、处置（remind / acknowledged）、丢输出的写法、判计数或空的写法、命令（换行记成 ⏎，截到 400 个字）。
#   路径取 DISCARDED_OUTPUT_COUNT_CHECK_RECORD，没设就是 ${TMPDIR:-/tmp}/discarded-output-count-check/records.tsv。
# 提醒：stdout 打一行 JSON，hookSpecificOutput.additionalContext 交给发命令的 agent，同一段另作 systemMessage 给人看。
# 退出码：判过了 0（命中与没命中一样，只记不拒）；判不了 1：输入不是 JSON 对象、判的时候 python 出错（Claude Code 照常往下走，stderr 留一行「这条命令没判」）；
#   准入与运行条件不满足 78。
#
# 弄坏开关 DISCARDED_OUTPUT_COUNT_CHECK_BREAK（只给自证用，其余时候不设）：
#   no-bare-stderr  丢输出不认单独的 2>/dev/null；自证红在样本 grep-count-stderr-dropped
#   no-record       命中了不写检出记录；自证红在样本 hook-path-records
#   short-reason    `# discarded-output:` 的理由不看长短；自证红在样本 acknowledged-short-reason
#
# 怎么注册（可选）：在项目的 .claude/settings.json 的 hooks.PostToolUse 里加一项；Bash 那一项已经挂着别的钩子的，追加进同一个 hooks 列表：
#   {"matcher": "Bash", "hooks": [{"type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR\"/.claude/singlefs-ai-sop/scripts/claude-hooks/discarded-output-count-check.sh"}]}
#
#   discarded-output-count-check.sh             从 stdin 读钩子的 JSON
#   discarded-output-count-check.sh --selftest  逐个样本判命中与否，整条钩子路径（提醒、记录、判不了、别的工具），再逐个打开弄坏开关核它红在点名的样本上
#
# 管不到的：
#   判的是整条命令的文本：丢输出与计数判空落在用分号隔开的两段里也算命中（ls d 2>/dev/null; grep -c x f 照提醒）；
#   引号里当数据写的照认（grep -c '2>/dev/null' f 照提醒）；
#   先写进脚本文件再跑的（bash x.sh）、变量里拼出来的命令看不到；
#   别的判空写法不认：grep -q、if ! grep、[ $? -eq 1 ]、read 读空。
HOOK_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HOOK_DIRECTORY/../lib.sh"
preflight "${BASH_SOURCE[0]}" "$@"; set -- ${PREFLIGHT_ARGUMENTS[@]+"${PREFLIGHT_ARGUMENTS[@]}"}
declare -A BREAK_SWITCH_CASES=(
  [no-bare-stderr]=grep-count-stderr-dropped
  [no-record]=hook-path-records
  [short-reason]=acknowledged-short-reason
)
if [[ -n "${DISCARDED_OUTPUT_COUNT_CHECK_BREAK:-}" && -z "${BREAK_SWITCH_CASES[${DISCARDED_OUTPUT_COUNT_CHECK_BREAK}]+set}" ]]; then
  die "DISCARDED_OUTPUT_COUNT_CHECK_BREAK 的值不认：${DISCARDED_OUTPUT_COUNT_CHECK_BREAK}" \
    "只认 ${!BREAK_SWITCH_CASES[*]}；不是在自证里弄坏判据的话，不要设这个变量。"
fi

# 判定与自证的样本。python 程序用 -c 传，标准输入留给钩子的 JSON；第一个参数是 hook 或 selftest，selftest 再带本文件的路径。
IFS= read -r -d '' JUDGE_PROGRAM <<'PY' || true
import datetime, json, os, re, subprocess, sys, tempfile

BREAK_SWITCH = os.environ.get("DISCARDED_OUTPUT_COUNT_CHECK_BREAK", "")
RULE_REFERENCE = "rules/verify-before-claiming.md「拿来下结论的命令不丢输出」"
ACKNOWLEDGEMENT_REASON_MINIMUM_CHARACTERS = 8
RECORDED_COMMAND_MAXIMUM_CHARACTERS = 400
DISCARD_FORMS = [
    ("2>/dev/null", re.compile(r"(?<![\w&>])2>>?[ \t]*/dev/null(?![\w/])")),
    ("&>/dev/null", re.compile(r"(?<![\w>])&>>?[ \t]*/dev/null(?![\w/])")),
    (">/dev/null 2>&1", re.compile(r"(?<![\w&>])1?>>?[ \t]*/dev/null[ \t]+2>&1")),
]
if BREAK_SWITCH == "no-bare-stderr":
    DISCARD_FORMS = [form for form in DISCARD_FORMS if form[0] != "2>/dev/null"]
COUNT_FORMS = [
    ("grep -c", re.compile(r"(?<![\w-])grep(?:[ \t]+-{1,2}[\w-]+(?:=\S+)?)*?[ \t]+(?:-[A-Za-z]*c[A-Za-z]*|--count)(?![\w-])")),
    ("wc -l", re.compile(r"(?<![\w-])wc(?:[ \t]+-[A-Za-z]+)*?[ \t]+(?:-[A-Za-z]*[lcwm][A-Za-z]*|--(?:lines|bytes|words|chars))(?![\w-])")),
    ("test -z / -n", re.compile(r"(?<![\w-])test[ \t]+(?:![ \t]+)?-[zn](?=[ \t])")),
    ("[ -z / -n", re.compile(r"\[\[?[ \t]+(?:![ \t]+)?-[zn](?=[ \t])")),
    ("|| echo 0", re.compile(r"\|\|[ \t]*(?:echo|printf)[ \t]+(?:'0'|\"0\"|0)(?![\w.])")),
]
ACKNOWLEDGEMENT = re.compile(r"#[ \t]*discarded-output:[ \t]*([^\n]*)")


def judge_command(command):
    """命中返回 {"discards": […], "counts": […], "acknowledged": bool}，没命中返回 None。"""
    reasons = [match.group(1).strip() for match in ACKNOWLEDGEMENT.finditer(command)]
    judged_text = ACKNOWLEDGEMENT.sub("", command)
    judged_text = "\n".join(line for line in judged_text.split("\n") if not line.lstrip().startswith("#"))
    discards = [label for label, pattern in DISCARD_FORMS if pattern.search(judged_text)]
    counts = [label for label, pattern in COUNT_FORMS if pattern.search(judged_text)]
    if not discards or not counts:
        return None
    minimum_characters = 1 if BREAK_SWITCH == "short-reason" else ACKNOWLEDGEMENT_REASON_MINIMUM_CHARACTERS
    acknowledged = any(len(reason) >= minimum_characters for reason in reasons)
    return {"discards": discards, "counts": counts, "acknowledged": acknowledged}


def record_path():
    configured = os.environ.get("DISCARDED_OUTPUT_COUNT_CHECK_RECORD", "")
    if configured:
        return configured
    return os.path.join(os.environ.get("TMPDIR") or "/tmp", "discarded-output-count-check", "records.tsv")


def single_field(value):
    return re.sub(r"[\t\r]", " ", str(value)).replace("\n", "⏎")


def write_record(path, hook_input, verdict, command):
    """追加一行检出记录；写不进返回原因，写进了返回 None。"""
    if BREAK_SWITCH == "no-record":
        return None
    fields = [
        datetime.date.today().isoformat(),
        re.sub(r"[^A-Za-z0-9_-]", "_", str(hook_input.get("session_id") or "")) or "no-session",
        re.sub(r"[^A-Za-z0-9_-]", "_", str(hook_input.get("agent_id") or "")) or "main",
        "acknowledged" if verdict["acknowledged"] else "remind",
        ",".join(verdict["discards"]),
        ",".join(verdict["counts"]),
        single_field(command)[:RECORDED_COMMAND_MAXIMUM_CHARACTERS],
    ]
    try:
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        with open(path, "a", encoding="utf-8") as record_file:
            record_file.write("\t".join(single_field(field) for field in fields) + "\n")
    except OSError as error:
        return str(error)
    return None


def reminder_text(verdict):
    return (f"! 这条命令把输出丢进了 /dev/null（{'、'.join(verdict['discards'])}），同一条里又在判计数或空（{'、'.join(verdict['counts'])}）："
            "空输出与 0 也可能是命令没跑成（文件不在、参数错、没权限）。"
            "要据它说「零命中」「没出错」之前，去掉丢输出的重定向重跑这条命令，或在它后面接 `; echo rc=$?` 打出退出码，看过报错与退出码再下结论"
            f"（{RULE_REFERENCE}）。确要丢、不据它下结论的，在命令里加一句注释 `# discarded-output: <为什么可以丢，至少 {ACKNOWLEDGEMENT_REASON_MINIMUM_CHARACTERS} 个字>`，记下之后这条命令不再提醒。")


def run_hook():
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
    verdict = judge_command(command)
    if verdict is None:
        return 0
    path = record_path()
    record_error = write_record(path, hook_input, verdict, command)
    if record_error:
        print(f"! discarded-output-count-check：检出记录写不进 {path}（{record_error}），这一次只提醒、没记下。", file=sys.stderr)
    if verdict["acknowledged"]:
        return 0
    message = reminder_text(verdict)
    print(json.dumps({"systemMessage": message,
                      "hookSpecificOutput": {"hookEventName": hook_input.get("hook_event_name") or "PostToolUse", "additionalContext": message}},
                     ensure_ascii=False))
    return 0


# 样本：名字、命令、期望（none 没命中、remind 命中并提醒、acknowledged 命中、记下已决定照跑、不提醒）。
JUDGE_CASES = [
    ("grep-count-stderr-dropped", "n=$(grep -c TODO notes.md 2>/dev/null || echo 0)", "remind"),
    ("wc-lines-all-dropped", "ls build/*.o >/dev/null 2>&1 | wc -l", "remind"),
    ("wc-lines-ampersand-dropped", "find out -name '*.log' &>/dev/null | wc -l", "remind"),
    ("empty-test-stderr-dropped", "[[ -n \"$(git status --porcelain 2>/dev/null)\" ]] && echo dirty", "remind"),
    ("test-z-stderr-dropped", "test -z \"$(ls cache 2>/dev/null)\" && echo empty", "remind"),
    ("grep-count-option-cluster", "grep -rc TODO src 2> /dev/null", "remind"),
    ("grep-count-stderr-kept", "grep -c TODO notes.md; echo rc=$?", "none"),
    ("discard-without-count", "rm -f stale.tmp 2>/dev/null", "none"),
    ("count-without-discard", "ls build | wc -l", "none"),
    ("grep-color-not-count", "grep --color=never TODO notes.md 2>/dev/null", "none"),
    ("stderr-to-stdout-not-discard", "grep -c TODO notes.md 2>&1", "none"),
    ("comment-line-not-command", "# grep -c TODO notes.md 2>/dev/null\nls", "none"),
    ("acknowledged", "ls cache 2>/dev/null | wc -l  # discarded-output: 目录不在就是零个缓存，不据它下结论", "acknowledged"),
    ("acknowledged-short-reason", "ls cache 2>/dev/null | wc -l  # discarded-output: 无", "remind"),
]


def judged_outcome(verdict):
    if verdict is None:
        return "none"
    return "acknowledged" if verdict["acknowledged"] else "remind"


def run_selftest(script_path):
    misjudged_cases = []
    checked_names = []
    for case_name, command, expected in JUDGE_CASES:
        checked_names.append(case_name)
        actual = judged_outcome(judge_command(command))
        if actual != expected:
            misjudged_cases.append((case_name, expected, actual))
    with tempfile.TemporaryDirectory() as scratch_directory:
        record = os.path.join(scratch_directory, "records.tsv")
        environment = dict(os.environ, DISCARDED_OUTPUT_COUNT_CHECK_RECORD=record)

        def run_hook_script(payload):
            return subprocess.run(["bash", script_path], input=payload, capture_output=True, text=True, env=environment,
                                  timeout=60, check=False, start_new_session=True)

        hit_payload = json.dumps({"hook_event_name": "PostToolUse", "tool_name": "Bash", "session_id": "selftest",
                                  "tool_input": {"command": "n=$(grep -c TODO notes.md 2>/dev/null || echo 0)"}})
        hit = run_hook_script(hit_payload)
        context = ""
        try:
            context = json.loads(hit.stdout)["hookSpecificOutput"]["additionalContext"] if hit.stdout.strip() else ""
        except (ValueError, KeyError, TypeError):
            context = ""
        checked_names.append("hook-path-reminds")
        if hit.returncode != 0 or RULE_REFERENCE not in context:
            misjudged_cases.append(("hook-path-reminds", "退 0、提醒里点到规则", f"退 {hit.returncode}、提醒「{context[:80]}」"))
        record_lines = []
        if os.path.exists(record):
            with open(record, encoding="utf-8") as record_file:
                record_lines = [line for line in record_file.read().split("\n") if line]
        checked_names.append("hook-path-records")
        if len(record_lines) != 1 or "\tremind\t" not in record_lines[0]:
            misjudged_cases.append(("hook-path-records", "检出记录一行、处置 remind", f"{len(record_lines)} 行"))
        unreadable = run_hook_script("not json")
        checked_names.append("hook-path-unjudged")
        if unreadable.returncode != 1 or "没判" not in unreadable.stderr:
            misjudged_cases.append(("hook-path-unjudged", "退 1、stderr 说没判", f"退 {unreadable.returncode}"))
        other_tool = run_hook_script(json.dumps({"tool_name": "Write", "tool_input": {"file_path": "x", "content": "grep -c x 2>/dev/null"}}))
        checked_names.append("hook-path-other-tool")
        if other_tool.returncode != 0 or other_tool.stdout.strip():
            misjudged_cases.append(("hook-path-other-tool", "退 0、不提醒", f"退 {other_tool.returncode}、输出「{other_tool.stdout.strip()[:80]}」"))
    misjudged_names = {case[0] for case in misjudged_cases}
    for case_name in checked_names:
        if case_name not in misjudged_names:
            print(f"  case {case_name}: right")
    for case_name, expected, actual in misjudged_cases:
        print(f"      判错的样本：{case_name}（期望 {expected}，实际 {actual}）")
    return 1 if misjudged_cases else 0


if __name__ == "__main__":
    if sys.argv[1:2] == ["selftest"]:
        sys.exit(run_selftest(sys.argv[2]))
    sys.exit(run_hook())
PY

if [[ "${1:-}" == "--selftest" ]]; then
  selftest_exit_code=0
  selftest_output="$(python3 -c "$JUDGE_PROGRAM" selftest "${BASH_SOURCE[0]}" 2>&1)" || selftest_exit_code=$?
  checked_case_count="$(grep -cE '^(  case |      判错的样本：)' <<<"$selftest_output" || true)"
  printf '%s\n' "$selftest_output" | grep -v '^  case ' || true
  if [[ $selftest_exit_code -ne 0 ]]; then
    if [[ -n "${DISCARDED_OUTPUT_COUNT_CHECK_BREAK:-}" ]]; then
      bad "弄坏开关 ${DISCARDED_OUTPUT_COUNT_CHECK_BREAK} 下自证判错（共 $checked_case_count 个样本）"
      howto "这是弄坏开关下的预期结果，由不带开关的自证核它红在点名的样本上；单跑时去掉 DISCARDED_OUTPUT_COUNT_CHECK_BREAK。"
      exit 1
    fi
    bad "discarded-output-count-check 自证判错（共 $checked_case_count 个样本，python 退出码 $selftest_exit_code）"
    howto "看上面「判错的样本」那几行：判据错了修本文件内嵌 python 的 judge_command 与 DISCARD_FORMS、COUNT_FORMS，样本错了改 JUDGE_CASES，再跑 bash ${BASH_SOURCE[0]} --selftest。"
    exit 1
  fi
  if [[ -n "${DISCARDED_OUTPUT_COUNT_CHECK_BREAK:-}" ]]; then
    warn "弄坏开关 ${DISCARDED_OUTPUT_COUNT_CHECK_BREAK} 下自证居然通过了（共 $checked_case_count 个样本）；由不带开关的自证判它红没红"
    exit 0
  fi
  silent_switches=(); switch_count=0
  for switch_name in "${!BREAK_SWITCH_CASES[@]}"; do
    switch_count=$((switch_count + 1))
    expected_case_name="${BREAK_SWITCH_CASES[$switch_name]}"
    switch_exit_code=0
    switch_output="$(env DISCARDED_OUTPUT_COUNT_CHECK_BREAK="$switch_name" bash "${BASH_SOURCE[0]}" --selftest 2>&1)" || switch_exit_code=$?
    if [[ $switch_exit_code -ne 1 || "$switch_output" != *"判错的样本：${expected_case_name}（"* ]]; then
      silent_switches+=("$switch_name（退出码 $switch_exit_code，该红在 $expected_case_name）")
    fi
  done
  if ((${#silent_switches[@]})); then
    bad "有 ${#silent_switches[@]} 个弄坏开关打开后自证没红在点名的样本上（共 $switch_count 个）：${silent_switches[*]}"
    howto "改样本让它红在 BREAK_SWITCH_CASES 点名的那一个，或改开关让它真的弄坏点名的那一处；两样都修不了就删掉这个开关（rules/test-discipline.md「每一个弄坏开关都必须会红」）。" \
      "单跑：DISCARDED_OUTPUT_COUNT_CHECK_BREAK=<开关名> bash ${BASH_SOURCE[0]} --selftest"
    exit 1
  fi
  ok "discarded-output-count-check 自证：$checked_case_count 个样本判得都对，$switch_count 个弄坏开关打开后都红在点名的样本上"
  exit 0
fi

judge_exit_code=0
python3 -c "$JUDGE_PROGRAM" hook || judge_exit_code=$?
if [[ $judge_exit_code -eq 3 ]]; then
  printf '%s\n' "! discarded-output-count-check：钩子输入不是 JSON 对象，这条命令没判（照常往下走）。" \
    "  看一眼 .claude/settings.json 里这个钩子是不是挂在 PostToolUse 的 Bash 上；手喂时输入要形如 {\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"…\"}}。" >&2
  exit 1
fi
if [[ $judge_exit_code -ne 0 ]]; then
  printf '%s\n' "! discarded-output-count-check：判的时候 python 出错（退出码 $judge_exit_code），这条命令没判（照常往下走）。" \
    "  它的报错在上面；手喂同一份输入复现： printf '%s' '<钩子 JSON>' | bash $HOOK_DIRECTORY/discarded-output-count-check.sh" >&2
  exit 1
fi
exit 0
