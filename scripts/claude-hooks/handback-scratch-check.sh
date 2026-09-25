#!/usr/bin/env bash
# hook-events: PreToolUse:SubagentHandback SubagentStop
# gate-similar: gate-reuse-check.sh 同挂在 SubagentStop 上、读同一份子 agent 会话记录，但它判这一轮新写的门禁与钩子该不该单独存在，这里判临时目录里留没留编译目录与仓副本，对象与放行条件都不同；读钩子输入那一段已抽进 claude-hook-lib.sh 两边共用
# gate-similar: pattern-process-guard.sh 同在 PreToolUse 上，但它的 matcher 是 Bash、在命令执行前拒绝按模式杀进程；这里的 matcher 是交回工具 SubagentHandback，看的是磁盘上留下了什么
# admission: always Claude Code 在子 agent 交回与收工时调它，判的是此刻临时目录里还剩什么
# run-condition: command python3
# Claude Code 钩子（交回的尾门禁）：子 agent 交回之前，它自己建的编译目录与仓副本要删掉
# （rules/session-wrapup.md「子 agent 交回之前，删掉自己建的编译目录与仓副本」）。
#
# 判定全在 scripts/handback-scratch.py：临时目录里、在这个子 agent 自己的工具调用还没结束时建的、它的调用里提到过的
# 编译目录、工作树与仓副本，还在、而且没说明为什么不删，就拦下，把清单交给它。它要做的：删掉，或者在交回报告里逐个写全路径、写明为什么不删。
# 两个触发点：
#   PreToolUse（matcher SubagentHandback）：交回之前拦。说明要写在这一次要交回的报告里，拦下之后重调交回工具。
#     子 agent 里触发的 PreToolUse 只带主 agent 的 transcript_path 与 agent_id，它自己的会话记录按
#     <主 agent 的会话记录去掉 .jsonl>/subagents/agent-<agent_id>.jsonl 找；找不到不判，退 1。
#   SubagentStop：没有交回工具、或者没经交回工具就收工时兜底。送达了的交回报告里写了的算说明（被拒掉的那次不算）；
#     拦下时记下时刻，之后回复里的文字与工具调用的输入里写了的也算（只 du、ls、Read 一下不算）。
# 说明的写法：一行里同时有全路径与「没删」「保留」「留给」「kept」这类词（handback-scratch.py 的 EXPLANATION_KEYWORDS），只当出处引一下路径不算。
#
# 只判子 agent：主 agent 在多轮之间有意留着编译目录（Stop 上与主 agent 自己的工具调用都不判）。
# SubagentStop 的输入里没有 agent_transcript_path 时认不出是哪个子 agent，不判，退 1：拿主 agent 的会话记录去认，会把主 agent 建的算到子 agent 头上。
# 项目根取 CLAUDE_PROJECT_DIR，没有就取输入里的 cwd。
# 状态目录默认 ${TMPDIR:-/tmp}/handback-scratch-check（按 session_id 与 agent_id 各记一份 SubagentStop 拦下的时刻），HANDBACK_SCRATCH_CHECK_STATE_DIRECTORY 可改。
#   记下的时刻认不出（写到一半）就当没拦过。
# 退出码：拦下 2（Claude Code 不执行这次交回 / 不让收工，把 stderr 交给子 agent）；放行 0；
#   输入不是 JSON 对象、认不出是哪个子 agent、或判定脚本判不了 1（不拦，stderr 只给人看）——「没判」不记成「判过」。
#
# 怎么注册：项目 .claude/settings.json 的 hooks 里加两项；SubagentStop 上已经挂着 gate-reuse-check.sh 的，加进同一个 hooks 数组：
#   "PreToolUse":   [{"matcher": "SubagentHandback", "hooks": [{"type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR\"/.claude/singlefs-ai-sop/scripts/claude-hooks/handback-scratch-check.sh"}]}]
#   "SubagentStop": [{"hooks": [{"type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR\"/.claude/singlefs-ai-sop/scripts/claude-hooks/handback-scratch-check.sh"}]}]
#
#   handback-scratch-check.sh             从 stdin 读钩子的 JSON
#   handback-scratch-check.sh --selftest  造一个临时目录与带时刻的会话记录，核各种建法拦得下（绝对路径、跟着 cd / pushd / -C 的相对路径、
#                                         NAME=相对路径、~、换行之后的 cd、自己建的上级下面的、读过的文件所在的、喂给解释器的 heredoc、
#                                         mktemp 的输出、后台命令在结果之后建的与没收到完成通知的）、开工之前与两次调用之间别人建的不拦、
#                                         派出去的子 agent 建的不拦、写进文件的内容与共用目录不连带、项目里的与符号链接不拦、
#                                         交回之前拦而交回报告里写了全路径就放行（前缀相同的别的路径不算）、收工时交回过的报告与
#                                         拦下之后的回复里写了就放行（只 du、Read 一下与拦下之前写的不算，删了重建的要重新说明）、
#                                         Stop 与主 agent 不判、判不了时不拦
set -uo pipefail
HOOK_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_ROOT="$(cd "$HOOK_DIRECTORY/../.." && pwd)"
HANDBACK_SCRATCH="$PACKAGE_ROOT/scripts/handback-scratch.py"
STATE_DIRECTORY="${HANDBACK_SCRATCH_CHECK_STATE_DIRECTORY:-${TMPDIR:-/tmp}/handback-scratch-check}"
HANDBACK_TOOL_NAME=SubagentHandback
source "$PACKAGE_ROOT/scripts/claude-hook-lib.sh"
source "$PACKAGE_ROOT/scripts/preflight.sh"
preflight "${BASH_SOURCE[0]}" "$@"; set -- ${PREFLIGHT_ARGUMENTS[@]+"${PREFLIGHT_ARGUMENTS[@]}"}

judge_handback() { # judge_handback（钩子 JSON 在 stdin）→ 退出码 0 放行、2 拦下、1 没判
  local hook_json fields hook_event_name stop_hook_active agent_transcript main_transcript session_directory session_id agent_id tool_name
  local project_root state_file judgement judgement_exit_code block_heading remedy
  local judge_options=()
  hook_json="$(cat)"
  if ! fields="$(printf '%s' "$hook_json" | claude_hook_fields)"; then
    printf '%s\n' "! handback-scratch-check：钩子输入不是 JSON 对象，这一次没判（放行）。" \
      "  看一眼 .claude/settings.json 里这个钩子是不是挂在 PreToolUse（matcher $HANDBACK_TOOL_NAME）与 SubagentStop 上。" >&2
    return 1
  fi
  { IFS= read -r hook_event_name; IFS= read -r stop_hook_active; IFS= read -r agent_transcript; IFS= read -r main_transcript
    IFS= read -r session_directory; IFS= read -r session_id; IFS= read -r agent_id; IFS= read -r tool_name; } <<<"$fields"
  case "$hook_event_name" in
    PreToolUse)
      [[ "$tool_name" == "$HANDBACK_TOOL_NAME" && "$agent_id" != main ]] || return 0
      agent_transcript="${main_transcript%.jsonl}/subagents/agent-$agent_id.jsonl"
      judge_options=(--pending-handback)
      block_heading="✗ 交回之前先删掉你自己建的编译目录与仓副本：下面这些是在你的工具调用还没结束时建的、你的调用里提到过，现在还在，这一次交回的报告里也没说为什么留。"
      remedy="没删的，在交回报告里逐个写一行「没删 <全路径>：<为什么>」（全路径照抄下面的清单），再调一次交回工具；只把路径当出处引一下不算。" ;;
    SubagentStop)
      block_heading="✗ 交回之前先删掉你自己建的编译目录与仓副本：下面这些是在你的工具调用还没结束时建的、你的调用里提到过，现在还在，也没说明为什么留。"
      remedy="没删的，在回复里逐个写一行「没删 <全路径>：<为什么>」（全路径照抄下面的清单），写了再收工就放行；只 du、ls、Read 一下、只把路径当出处引一下都不算。" ;;
    *) return 0 ;;
  esac
  if [[ -z "$agent_transcript" || ! -f "$agent_transcript" ]]; then
    printf '%s\n' "! handback-scratch-check：找不到这个子 agent 自己的会话记录（${agent_transcript:-输入里没有 agent_transcript_path}），认不出是哪个子 agent，这一次没判（放行）。" \
      "  主 agent 的会话记录是 ${main_transcript:-（也没有）}；拿它去认会把主 agent 建的算到子 agent 头上，所以不用。" >&2
    return 1
  fi
  project_root="${CLAUDE_PROJECT_DIR:-$session_directory}"
  [[ -n "$project_root" && -d "$project_root" ]] || return 0
  state_file="$STATE_DIRECTORY/$session_id-$agent_id"
  if [[ "$hook_event_name" == SubagentStop && -f "$state_file" ]]; then judge_options=(--explained-after "$(cat "$state_file")"); fi
  judgement="$(printf '%s' "$hook_json" | python3 "$HANDBACK_SCRATCH" "$agent_transcript" "$project_root" ${judge_options[@]+"${judge_options[@]}"} 2>&1)"
  judgement_exit_code=$?
  case "$judgement_exit_code" in
    0) return 0 ;;
    1) ;;
    *)
      printf '%s\n' "! handback-scratch-check：判定脚本 $HANDBACK_SCRATCH 退出码 $judgement_exit_code（判不了），这一次没判（放行）。它的输出：" \
        "$judgement" >&2
      return 1 ;;
  esac
  if [[ "$hook_event_name" == SubagentStop ]]; then
    mkdir -p "$STATE_DIRECTORY" 2>/dev/null && date +%s.%N > "$state_file" 2>/dev/null
  fi
  {
    printf '%s\n' "$block_heading" \
      '→ 怎么办：逐个先 du -sh 记下大小再删——工作树在它的源仓里 git worktree remove --force <路径>（源仓里的登记一起清掉），其余 rm -rf；' \
      '    交回报告里写一行删了哪些、各多大。' \
      '    报告、要入库的产物、主 agent 还要核的复跑材料不删；点到的不是你建的（前任、主 agent 或别的 agent 在用）也别动。' \
      "    $remedy" \
      "    规矩见 $PACKAGE_ROOT/rules/session-wrapup.md「子 agent 交回之前，删掉自己建的编译目录与仓副本」。" \
      ''
    printf '%s\n' "$judgement" | awk -F'\t' '{ if (NF >= 2) printf "  %s  %s\n", $1, $2; else print }'
  } >&2
  return 2
}

# 往会话记录里追加记录，时刻都由调用方给（ISO 8601）：
#   prompt <记录> <时刻> | text <记录> <时刻> <回复文字>
#   call <记录> <调用号> <发起时刻> <结果时刻> <工具名> <输入 JSON> [结果文字]
#   background <记录> <调用号> <发起时刻> <完成通知时刻，空就是没收到通知> <工具名> <输入 JSON>
#   rejected <记录> <调用号> <时刻> <工具名> <输入 JSON>：结果标了 is_error（被钩子拒掉）
#   raw <记录> <一行 JSON>
IFS= read -r -d '' TRANSCRIPT_WRITER_PROGRAM <<'PY' || true
import json, sys
kind, transcript_path = sys.argv[1], sys.argv[2]
arguments = sys.argv[3:]
def assistant(at, blocks): return {"type": "assistant", "timestamp": at, "message": {"role": "assistant", "content": blocks}}
def result(at, call_id, text): return {"type": "user", "timestamp": at, "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": call_id, "content": text}]}}
if kind == "prompt":
    entries = [{"type": "user", "timestamp": arguments[0], "message": {"role": "user", "content": "开工"}}]
elif kind == "text":
    entries = [assistant(arguments[0], [{"type": "text", "text": arguments[1]}])]
elif kind == "call":
    call_id, started, ended, name, tool_input = arguments[:5]
    result_text = arguments[5] if len(arguments) > 5 else "ok"
    entries = [assistant(started, [{"type": "tool_use", "id": call_id, "name": name, "input": json.loads(tool_input)}]),
               result(ended, call_id, result_text)]
elif kind == "background":
    call_id, started, notified, name, tool_input = arguments[:5]
    tool_input = dict(json.loads(tool_input), run_in_background=True)
    entries = [assistant(started, [{"type": "tool_use", "id": call_id, "name": name, "input": tool_input}]),
               result(started, call_id, "running in background")]
    if notified:
        entries.append({"type": "attachment", "timestamp": notified, "attachment": {"type": "queued_command",
                        "prompt": "<task-notification>\n<tool-use-id>" + call_id + "</tool-use-id>\n<status>completed</status>\n</task-notification>"}})
elif kind == "rejected":
    call_id, at, name, tool_input = arguments[:4]
    entries = [assistant(at, [{"type": "tool_use", "id": call_id, "name": name, "input": json.loads(tool_input)}]),
               {"type": "user", "timestamp": at, "message": {"role": "user", "content": [
                   {"type": "tool_result", "tool_use_id": call_id, "content": "PreToolUse hook blocked", "is_error": True}]}}]
else:
    entries = [json.loads(arguments[0])]
with open(transcript_path, "a", encoding="utf-8") as transcript_file:
    for entry in entries:
        transcript_file.write(json.dumps(entry, ensure_ascii=False) + "\n")
PY

run_selftest() {
  local scratch project temporary_root claude_directory own_area other_area session_scratchpad fake_home passed=0 failed=0
  local main_transcript transcript prompt_at window_start window_end gap_call_at background_start background_notified
  local dispatch_start dispatch_notified read_after_dispatch_at unnotified_start first_handback_at resumed_at read_after_resume_at open_start
  scratch="$(mktemp -d)"
  project="$scratch/project"
  # 钩子只判临时目录之下的：把 TMPDIR 指到这里；claude-<uid> 与它下面按项目、按会话分的几层是大家共用的
  temporary_root="$scratch/temporary"
  claude_directory="$temporary_root/claude-$(id -u)"
  own_area="$claude_directory/implementer"
  other_area="$claude_directory/verifier"
  session_scratchpad="$claude_directory/-home-someone-project/0b7c6d2e-session/scratchpad"
  fake_home="$temporary_root/home"
  # 主 agent 的会话记录；子 agent 的在 <它去掉 .jsonl>/subagents/agent-<agent_id>.jsonl，PreToolUse 按这个找
  main_transcript="$scratch/session.jsonl"
  transcript="$scratch/session/subagents/agent-implementer.jsonl"
  now_iso() { date -u +%Y-%m-%dT%H:%M:%S.%3NZ; }
  make_build_directory() { mkdir -p "$1"; printf 'Signature: 8a477f597d28d172789f06886806bc55\n# cargo\n' > "$1/CACHEDIR.TAG"; }
  write_transcript() { python3 -c "$TRANSCRIPT_WRITER_PROGRAM" "$@"; }
  json_of() { python3 -c 'import json, sys; print(json.dumps(dict(zip(sys.argv[1::2], sys.argv[2::2])), ensure_ascii=False))' "$@"; }
  # 各段之间隔 0.4 秒，比判定两头放的余量（0.25 秒）宽
  pause() { sleep 0.4; }

  # 开工之前就在的：草稿目录、别人的仓、家目录，还有前任留下的仓副本与编译目录（这一轮也提到了它们）
  mkdir -p "$project/crates" "$own_area" "$other_area/work/.git" "$own_area/predecessor-work/.git" "$fake_home" "$(dirname "$transcript")"
  printf 'ref: refs/heads/master\n' > "$other_area/work/.git/HEAD"
  make_build_directory "$own_area/predecessor-target"
  pause
  prompt_at="$(now_iso)"
  pause
  window_start="$(now_iso)"
  # ── 第一段调用还没结束时：它自己建的 ──
  make_build_directory "$own_area/unit-target"
  mkdir -p "$own_area/nested/work3/.git"; make_build_directory "$own_area/nested/work3/target"
  mkdir -p "$own_area/runner"; make_build_directory "$own_area/runner/mutation-target"
  mkdir -p "$own_area/rsync-copy/crates"; printf '[workspace]\n' > "$own_area/rsync-copy/Cargo.toml"; make_build_directory "$own_area/rsync-copy/target"
  mkdir -p "$own_area/deep/variable-copy/.git"; printf '副本\n' > "$own_area/deep/variable-copy/README"
  make_build_directory "$own_area/relative-target"
  make_build_directory "$fake_home/tilde-target"
  mkdir -p "$own_area/pushd-copy/.git" "$own_area/gitc-copy/.git" "$own_area/py-copy/.git" "$own_area/newline-copy/.git" \
    "$temporary_root/tmp.selftest-mktemp/repo/.git"
  mkdir -p "$own_area/wt-copy"; printf 'gitdir: %s/.git/worktrees/wt-copy\n' "$project" > "$own_area/wt-copy/.git"
  make_build_directory "$project/target"
  # 它建的仓副本里套着另一个项目的根：那个项目的上级不许算成要删的副本
  mkdir -p "$own_area/wrapper/.git" "$own_area/wrapper/project2"
  # 它自己建的上级里，一个名叫 target、指到项目 target 的符号链接：链过去的那一份不是在这里建的，它的上级也不因此算工程副本
  mkdir -p "$own_area/linkparent"; ln -s "$project/target" "$own_area/linkparent/target"; ln -s "$other_area/work" "$own_area/linkparent/work-link"; ln -s "$other_area/work" "$own_area/linkparent/work-link"
  # ── 同一时间别人建的：只在写进文件的内容里提到、只在会话的 scratchpad 这一层下面、开工前就在的目录下面 ──
  mkdir -p "$other_area/copy-after-start/.git" "$other_area/written-about/.git" "$session_scratchpad/sibling-copy/.git" \
    "$other_area/sibling-in-window/.git"
  window_end="$(now_iso)"
  pause
  # 两次调用之间别人建的，之后它看了一眼
  mkdir -p "$own_area/created-in-gap/.git"
  pause
  gap_call_at="$(now_iso)"
  pause
  # 后台命令：结果那条记录马上就回来，编译目录在那之后才建出来，完成通知更晚
  background_start="$(now_iso)"
  pause
  make_build_directory "$own_area/background-target"
  pause
  background_notified="$(now_iso)"
  pause
  # 派出去的子 agent 在它跑着的时候建的，之后读了一眼
  dispatch_start="$(now_iso)"
  pause
  mkdir -p "$own_area/grandchild-copy/.git"; printf '孙 agent 的副本\n' > "$own_area/grandchild-copy/README"
  pause
  dispatch_notified="$(now_iso)"
  pause
  read_after_dispatch_at="$(now_iso)"
  pause
  # 没收到完成通知的后台命令：交回之前它建的算；交回之后（续跑之前）别人建的不算
  unnotified_start="$(now_iso)"
  pause
  make_build_directory "$own_area/unnotified-target"
  pause
  first_handback_at="$(now_iso)"
  pause
  mkdir -p "$own_area/after-handback-copy/.git"; printf '交回之后别人建的\n' > "$own_area/after-handback-copy/README"
  pause
  resumed_at="$(now_iso)"
  pause
  mkdir -p "$own_area/after-resume-copy/.git"; printf '续跑之后别人建的\n' > "$own_area/after-resume-copy/README"
  pause
  read_after_resume_at="$(now_iso)"
  pause
  # 最后一条：没收到完成通知、之后也没有新话的后台命令，时间窗开到现在
  open_start="$(now_iso)"
  pause
  make_build_directory "$own_area/open-background-target"

  local call_number=0
  bash_call() { # bash_call <命令> [结果文字]：第一段里的一次 Bash 调用
    call_number=$((call_number + 1))
    write_transcript call "$transcript" "t$call_number" "$window_start" "$window_end" Bash "$(json_of command "$1")" "${2:-ok}"
  }
  write_transcript prompt "$transcript" "$prompt_at"
  # 开工时的话里就提到了清单里的一个：拦下之前写的不算说明
  write_transcript text "$transcript" "$window_start" "开工，先在 $own_area/unit-target 编一遍"
  bash_call "CARGO_TARGET_DIR=$own_area/unit-target cargo test -p core"
  # 建好之后、拦下之前又写了一句像说明的话：也不算说明
  write_transcript text "$transcript" "$window_end" "编好了 $own_area/unit-target，先保留着"
  bash_call "cd $own_area && cp -a $project nested/work3 && cd nested/work3 && cargo build"
  bash_call "mkdir $own_area/runner && cd $own_area/runner && python3 run-mutations.py"
  bash_call "cd $own_area && rsync -a --exclude .git $project/ rsync-copy/ && cd rsync-copy && cargo build"
  bash_call "cd $own_area && CARGO_TARGET_DIR=relative-target cargo test"
  bash_call "CARGO_TARGET_DIR=~/tilde-target cargo build"
  bash_call "pushd $own_area && git clone -q src pushd-copy && popd"
  bash_call "git -C $own_area clone -q src gitc-copy"
  bash_call "ls
cd $own_area && cp -a src newline-copy"
  bash_call "python3 - <<'EOF'
import shutil
shutil.copytree('src', '$own_area/py-copy')
EOF"
  bash_call 'W=$(mktemp -d) && git clone -q src "$W/repo" && echo "$W"' "$temporary_root/tmp.selftest-mktemp"
  bash_call "git worktree add $own_area/wt-copy HEAD"
  bash_call "mkdir $own_area/linkparent && ls $own_area/linkparent"
  bash_call "ls $own_area/predecessor-work $own_area/predecessor-target $session_scratchpad $other_area && cat $other_area/work/.git/HEAD"
  bash_call "du -sh $project/target && cat > $own_area/report.md <<'EOF'
没动 $other_area/copy-after-start
EOF"
  # shellcheck disable=SC2016  # $W 就是要原样留在命令里：路径只在变量里，判定认不出，要靠之后读过它里面的文件
  bash_call 'cp -a src "$W/deep/variable-copy"'
  write_transcript call "$transcript" read1 "$window_start" "$window_end" Read "$(json_of file_path "$own_area/deep/variable-copy/README")"
  write_transcript call "$transcript" write1 "$window_start" "$window_end" Write \
    "$(json_of file_path "$own_area/notes.md" content "看过 $other_area/written-about")"
  write_transcript call "$transcript" gap "$gap_call_at" "$gap_call_at" Bash "$(json_of command "ls $own_area/created-in-gap")"
  write_transcript background "$transcript" background "$background_start" "$background_notified" Bash \
    "$(json_of command "CARGO_TARGET_DIR=$own_area/background-target cargo build --release")"
  write_transcript background "$transcript" dispatch "$dispatch_start" "$dispatch_notified" Agent "$(json_of prompt "去干活" description "派一个")"
  write_transcript call "$transcript" read2 "$read_after_dispatch_at" "$read_after_dispatch_at" Read "$(json_of file_path "$own_area/grandchild-copy/README")"
  write_transcript background "$transcript" unnotified "$unnotified_start" "" Bash \
    "$(json_of command "CARGO_TARGET_DIR=$own_area/unnotified-target cargo build")"
  write_transcript call "$transcript" first-handback "$first_handback_at" "$first_handback_at" SubagentHandback "$(json_of message "第一段做完了")"
  write_transcript prompt "$transcript" "$resumed_at"
  write_transcript call "$transcript" read3 "$read_after_resume_at" "$read_after_resume_at" Read "$(json_of file_path "$own_area/after-resume-copy/README")"
  write_transcript call "$transcript" read4 "$read_after_resume_at" "$read_after_resume_at" Read "$(json_of file_path "$own_area/after-handback-copy/README")"
  write_transcript background "$transcript" open "$open_start" "" Bash \
    "$(json_of command "CARGO_TARGET_DIR=$own_area/open-background-target cargo build")"
  write_transcript prompt "$main_transcript" "$prompt_at"
  write_transcript call "$main_transcript" m1 "$window_start" "$window_end" Bash "$(json_of command "CARGO_TARGET_DIR=$own_area/unit-target cargo test")"
  write_transcript prompt "$scratch/wrapper.jsonl" "$prompt_at"
  write_transcript call "$scratch/wrapper.jsonl" w1 "$window_start" "$window_end" Bash "$(json_of command "ls $own_area/wrapper")"
  mkdir -p "$scratch/reads-only/subagents"
  write_transcript prompt "$scratch/reads-only/subagents/agent-reader.jsonl" "$prompt_at"
  write_transcript call "$scratch/reads-only/subagents/agent-reader.jsonl" r1 "$window_start" "$window_end" Bash "$(json_of command "ls $own_area")"

  stop_input() { # stop_input <事件> [子 agent 的会话记录，空就不带]
    printf '{"hook_event_name":"%s","session_id":"selftest-%s","stop_hook_active":false,"transcript_path":"%s","cwd":"%s"%s}' \
      "$1" "$$" "$main_transcript" "$project" "${2:+,\"agent_id\":\"implementer\",\"agent_transcript_path\":\"$2\"}"
  }
  handback_input() { # handback_input <工具名> <agent_id，空就是主 agent> <交回的报告>
    python3 -c 'import json, sys
hook_input = {"hook_event_name": "PreToolUse", "session_id": "selftest", "transcript_path": sys.argv[1], "cwd": sys.argv[2],
              "tool_name": sys.argv[3], "tool_input": {"message": sys.argv[5]}}
if sys.argv[4]:
    hook_input.update(agent_id=sys.argv[4], agent_type="implementer")
print(json.dumps(hook_input, ensure_ascii=False))' "$main_transcript" "$project" "$1" "$2" "$3"
  }
  run_hook() { # run_hook <状态目录> < 钩子 JSON
    env -u CLAUDE_PROJECT_DIR TMPDIR="$temporary_root" HOME="$fake_home" HANDBACK_SCRATCH_CHECK_STATE_DIRECTORY="$1" \
      bash "$HOOK_DIRECTORY/handback-scratch-check.sh"
  }
  expect_handback() { # expect_handback <情形> <期望退出码> <输出里要有的片段或空> <输出里不许有的片段或空> <钩子 JSON> [状态目录，空就每次新的]
    local label="$1" wanted_exit_code="$2" wanted_text="$3" unwanted_text="$4" output exit_code state_directory="${6:-$scratch/state}"
    output="$(printf '%s' "$5" | run_hook "$state_directory" 2>&1)"
    exit_code=$?
    if [[ "$exit_code" == "$wanted_exit_code" && ( -z "$wanted_text" || "$output" == *"$wanted_text"* ) \
          && ( -z "$unwanted_text" || "$output" != *"$unwanted_text"* ) ]]; then
      passed=$((passed + 1))
    else
      failed=$((failed + 1))
      printf '  ✗ 自检「%s」：期望退出 %s%s%s，实测 %s\n' "$label" "$wanted_exit_code" "${wanted_text:+、输出含「$wanted_text」}" "${unwanted_text:+、不含「$unwanted_text」}" "$exit_code"   # gate-lint:detail
      printf '%s\n' "$output" | sed 's/^/      /'
    fi
    [[ -n "${6:-}" ]] || rm -rf "${scratch:?}/state"
  }
  local first_stop
  first_stop="$(stop_input SubagentStop "$transcript")"
  expect_handback "CARGO_TARGET_DIR 指的编译目录拦得下" 2 "编译目录  $own_area/unit-target" "" "$first_stop"
  expect_handback "跟着 cd 走的相对路径拷的仓副本拦得下" 2 "仓副本  $own_area/nested/work3" "" "$first_stop"
  expect_handback "仓副本里的编译目录不另报" 2 "" "$own_area/nested/work3/target" "$first_stop"
  expect_handback "自己建的上级下面、脚本建的也拦" 2 "编译目录  $own_area/runner/mutation-target" "" "$first_stop"
  expect_handback "不带 .git 拷出来、在里面编过的算仓副本" 2 "仓副本  $own_area/rsync-copy" "" "$first_stop"
  expect_handback "NAME=相对路径跟着 cd 解析" 2 "编译目录  $own_area/relative-target" "" "$first_stop"
  expect_handback "~ 按家目录展开" 2 "编译目录  $fake_home/tilde-target" "" "$first_stop"
  expect_handback "pushd 当 cd 跟" 2 "仓副本  $own_area/pushd-copy" "" "$first_stop"
  expect_handback "-C <目录> 管它那一段" 2 "仓副本  $own_area/gitc-copy" "" "$first_stop"
  expect_handback "换行之后的 cd 也跟" 2 "仓副本  $own_area/newline-copy" "" "$first_stop"
  expect_handback "喂给解释器的 heredoc 正文里的路径算提到" 2 "仓副本  $own_area/py-copy" "" "$first_stop"
  expect_handback "mktemp 输出的目录下面建的也拦" 2 "仓副本  $temporary_root/tmp.selftest-mktemp/repo" "" "$first_stop"
  expect_handback "工作树单列" 2 "工作树  $own_area/wt-copy" "" "$first_stop"
  expect_handback "别的工具读过它里面的文件也算提到" 2 "仓副本  $own_area/deep/variable-copy" "" "$first_stop"
  expect_handback "后台命令在结果之后建的也拦" 2 "编译目录  $own_area/background-target" "" "$first_stop"
  expect_handback "没收到完成通知的后台命令，交回之前建的也拦" 2 "编译目录  $own_area/unnotified-target" "" "$first_stop"
  expect_handback "没收到完成通知的后台命令，交回之后别人建的不拦" 2 "" "after-handback-copy" "$first_stop"
  expect_handback "没收到完成通知、也没有续跑的后台命令，时间窗开到现在" 2 "编译目录  $own_area/open-background-target" "" "$first_stop"
  expect_handback "续跑之后别人建的不拦" 2 "" "after-resume-copy" "$first_stop"
  expect_handback "派出去的子 agent 建的不拦" 2 "" "grandchild-copy" "$first_stop"
  expect_handback "开工之前就在的仓副本不拦" 2 "" "predecessor-work" "$first_stop"
  expect_handback "开工之前就在的编译目录不拦" 2 "" "predecessor-target" "$first_stop"
  expect_handback "两次调用之间别人建的不拦" 2 "" "created-in-gap" "$first_stop"
  expect_handback "写进文件的 heredoc 正文里的路径不算提到" 2 "" "copy-after-start" "$first_stop"
  expect_handback "写进文件的内容里提到的路径不算提到" 2 "" "written-about" "$first_stop"
  expect_handback "提到会话的 scratchpad 不连带它下面别人的" 2 "" "sibling-copy" "$first_stop"
  expect_handback "提到开工前就在的目录，不连带它下面同一时间别人建的" 2 "" "sibling-in-window" "$first_stop"
  expect_handback "项目根里的编译目录不拦" 2 "" "$project/target" "$first_stop"
  expect_handback "符号链接不当编译目录" 2 "" "linkparent" "$first_stop"
  expect_handback "只读过、没建东西的不拦" 0 "" "" "$(stop_input SubagentStop "$scratch/reads-only/subagents/agent-reader.jsonl")"
  expect_handback "Stop 上不判" 0 "" "" "$(stop_input Stop "$transcript")"
  expect_handback "认不出是哪个子 agent 时不拦" 1 "认不出是哪个子 agent" "" "$(stop_input SubagentStop)"
  expect_handback "输入不是 JSON 不拦" 1 "不是 JSON 对象" "" "不是 JSON"
  # 删到只剩 unit-target，之后看放行
  rm -rf "${own_area:?}/nested/work3" "${own_area:?}/runner/mutation-target" "${own_area:?}/rsync-copy" "${own_area:?}/relative-target" \
    "${fake_home:?}/tilde-target" "${own_area:?}/pushd-copy" "${own_area:?}/gitc-copy" "${own_area:?}/newline-copy" "${own_area:?}/py-copy" \
    "${temporary_root:?}/tmp.selftest-mktemp" "${own_area:?}/wt-copy" "${own_area:?}/deep/variable-copy" "${own_area:?}/background-target" \
    "${own_area:?}/unnotified-target" "${own_area:?}/open-background-target"
  # ── 交回之前（PreToolUse）：说明要写在这一次要交回的报告里 ──
  expect_handback "交回之前拦：报告里没提" 2 "这一次交回的报告里也没说为什么留" "" "$(handback_input SubagentHandback implementer "删完了")"
  expect_handback "交回之前拦：报告里只写了前缀相同的别的路径" 2 "编译目录  $own_area/unit-target" "" \
    "$(handback_input SubagentHandback implementer "没删 $own_area/unit-target-old：留给主 agent")"
  expect_handback "交回之前拦：只把路径当出处引一下" 2 "编译目录  $own_area/unit-target" "" \
    "$(handback_input SubagentHandback implementer "实测在副本 \`$own_area/unit-target\` 上跑，全绿")"
  expect_handback "交回报告里写了一行没删与全路径就放行" 0 "" "" "$(handback_input SubagentHandback implementer "没删 $own_area/unit-target：主 agent 要复跑")"
  expect_handback "全路径结尾带 / 也认" 0 "" "" "$(handback_input SubagentHandback implementer "没删 $own_area/unit-target/：主 agent 要复跑")"
  expect_handback "全路径后面紧跟汉字也认" 0 "" "" "$(handback_input SubagentHandback implementer "没删 $own_area/unit-target因为主 agent 要复跑")"
  expect_handback "别的工具的 PreToolUse 不判" 0 "" "" "$(handback_input Bash implementer "")"
  expect_handback "主 agent 的交回不判" 0 "" "" "$(handback_input SubagentHandback "" "")"
  expect_handback "找不到子 agent 的会话记录时不拦" 1 "找不到这个子 agent 自己的会话记录" "" "$(handback_input SubagentHandback ghost "")"
  # ── 收工时（SubagentStop）：拦下之后写了才算，只 du、Read 一下与前缀不算，删了重建的要重新说明 ──
  local kept_state="$scratch/kept-state"
  expect_handback "收工时拦：拦下之前提到的不算说明" 2 "编译目录  $own_area/unit-target" "" "$first_stop" "$kept_state"
  pause
  write_transcript call "$transcript" after-block-du "$(now_iso)" "$(now_iso)" Bash "$(json_of command "du -sh $own_area/unit-target")"
  write_transcript call "$transcript" after-block-read "$(now_iso)" "$(now_iso)" Read "$(json_of file_path "$own_area/unit-target/CACHEDIR.TAG")"
  write_transcript text "$transcript" "$(now_iso)" "没删 $own_area/unit-target-old：留给主 agent"
  expect_handback "拦下之后只 du、Read 一下、写了前缀相同的别的路径都不算说明" 2 "编译目录  $own_area/unit-target" "" "$first_stop" "$kept_state"
  pause
  write_transcript text "$transcript" "$(now_iso)" "没删：$own_area/unit-target，主 agent 要拿它复跑全部变异"
  expect_handback "拦下之后在回复里写了全路径就放行" 0 "" "" "$first_stop" "$kept_state"
  pause
  rm -rf "${own_area:?}/unit-target"
  make_build_directory "$own_area/unit-target"
  expect_handback "删了重建的，之前的说明管不到" 2 "编译目录  $own_area/unit-target" "" "$first_stop" "$kept_state"
  pause
  write_transcript call "$transcript" report-heredoc "$(now_iso)" "$(now_iso)" Bash \
    "$(json_of command "cat >> $own_area/report.md <<'EOF'
没删 $own_area/unit-target：重建的这一份留给主 agent 复跑
EOF")"
  expect_handback "拦下之后用 heredoc 写进报告里的那一行也算" 0 "" "" "$first_stop" "$kept_state"
  pause
  mkdir -p "$scratch/empty-state" && : > "$scratch/empty-state/selftest-$$-implementer"
  expect_handback "状态文件写到一半（空的）当没拦过、照拦" 2 "编译目录  $own_area/unit-target" "" "$first_stop" "$scratch/empty-state"
  write_transcript rejected "$transcript" rejected-handback "$(now_iso)" SubagentHandback "$(json_of message "没删 $own_area/unit-target：留给主 agent")"
  expect_handback "被拒掉的那次交回里写的不算" 2 "编译目录  $own_area/unit-target" "" "$first_stop"
  write_transcript call "$transcript" handback "$(now_iso)" "$(now_iso)" SubagentHandback "$(json_of message "没删 $own_area/unit-target：留给主 agent")"
  expect_handback "送达了的交回报告里写了的，收工时不再拦" 0 "" "" "$first_stop"
  # ── 直接调判定脚本：项目根的上级不判；会话记录读不了退 3 ──
  expect_judge() { # expect_judge <情形> <期望退出码> <会话记录> <项目根>
    local output exit_code
    output="$(env TMPDIR="$temporary_root" HOME="$fake_home" python3 "$PACKAGE_ROOT/scripts/handback-scratch.py" "$3" "$4" 2>&1)"
    exit_code=$?
    if [[ "$exit_code" == "$2" ]]; then passed=$((passed + 1)); else
      failed=$((failed + 1))
      printf '  ✗ 自检「%s」：判定脚本期望退出 %s，实测 %s\n' "$1" "$2" "$exit_code"   # gate-lint:detail
      printf '%s\n' "$output" | sed 's/^/      /'
    fi
  }
  expect_judge "项目根的上级哪怕是它建的仓副本也不判" 0 "$scratch/wrapper.jsonl" "$own_area/wrapper/project2"
  expect_judge "会话记录读不了时判不了" 3 "$scratch" "$project"
  # ── 判不了：会话记录格式变了、工具调用的时间戳认不出、取不到创建时间（换一个只会报 0 的 stat）──
  mkdir -p "$scratch/odd/subagents"
  write_transcript prompt "$scratch/odd/subagents/agent-odd.jsonl" "$prompt_at"
  write_transcript raw "$scratch/odd/subagents/agent-odd.jsonl" \
    "{\"type\": \"assistant\", \"timestamp\": \"$window_start\", \"message\": {\"items\": [{\"type\": \"tool_use\", \"id\": \"o1\", \"name\": \"Bash\", \"input\": {\"command\": \"CARGO_TARGET_DIR=$own_area/unit-target cargo test\"}}]}}"
  expect_handback "会话记录里的工具调用一次都认不出时不拦" 1 "一次工具调用都没认出来" "" "$(stop_input SubagentStop "$scratch/odd/subagents/agent-odd.jsonl")"
  write_transcript prompt "$scratch/odd/subagents/agent-bad-time.jsonl" "$prompt_at"
  write_transcript call "$scratch/odd/subagents/agent-bad-time.jsonl" b1 "昨天" "昨天" Bash "$(json_of command "CARGO_TARGET_DIR=$own_area/unit-target cargo test")"
  expect_handback "工具调用的时间戳认不出时不拦" 1 "认不出（时间戳认不出" "" "$(stop_input SubagentStop "$scratch/odd/subagents/agent-bad-time.jsonl")"
  mkdir -p "$scratch/fake-bin"
  # 调用形如 stat --printf=… -- 路径…：每个路径都报创建时间 0（不报 btime 的文件系统就是这样）
  printf '#!/usr/bin/env bash\nprintf "0\\t%%s\\0" "${@:3}"\n' > "$scratch/fake-bin/stat"
  chmod +x "$scratch/fake-bin/stat"
  PATH="$scratch/fake-bin:$PATH" expect_handback "取不到创建时间时不拦" 1 "取不到创建时间" "" "$first_stop"
  rm -rf "${scratch:?}"
  if (( failed > 0 )); then
    printf '  ✗ handback-scratch-check 自检：%s 种情形判错（共 %s 种）\n' "$failed" "$((passed + failed))"   # gate-lint:summary
    printf '%s\n' '     → 怎么办：看上面判错的那几种情形，修 handback-scratch-check.sh 或它调的 handback-scratch.py，再跑 bash handback-scratch-check.sh --selftest。'
    return 1
  fi
  printf '  ✓ handback-scratch-check 自检：%s 种情形判得都对\n' "$passed"
  return 0
}

if [[ "${1:-}" == --selftest ]]; then
  run_selftest
  exit $?
fi
judge_handback
exit $?
