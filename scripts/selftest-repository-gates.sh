# 被 scripts/selftest.sh 在原位 source 的一段：仓级门禁与钩子的判别力（编号与简称、转发计时、同名定义、代码文件长度、工具层的闸、
# 门禁查重、收工钩子、项目根的新条目、软链接、代号、历史条目编号、本地阶段判别力、脚本执行位，以及几道不带 I18N 的包照常判）。
# 不单独跑：要用 selftest.sh 里先定义好的断言器、样本跑法与 temporary_directory、SCRIPTS 这些变量；
# 拆出来是因为一个代码文件不算注释不超过 2000 行（rules/code-discipline.md「一个代码文件不超过 2000 行」）。

# ── 编号与简称：源码注释与记录里引的简称与登记位不符 ──────
number_name_project="$temporary_directory/number-name"; mkdir -p "$number_name_project/.claude/kb/decisions" "$number_name_project/src"
printf '## D1 数据可移动性 —— 已定\n\n正文。\n' > "$number_name_project/.claude/kb/decisions/01-a.md"
printf '// 照 D1（数据可移动性）办。\n' > "$number_name_project/src/a.rs"
run_scripted "number-name-sync/简称与登记位一致时通过" 0 "编号与简称一致" -- \
  bash "$SCRIPTS/number-name-sync.sh" "$number_name_project"
printf '// 照 D1（**数据可移动性**）办，再照 D1（`数据可移动性`）。\n' > "$number_name_project/src/a.rs"
run_scripted "number-name-sync/简称带强调标记与反引号照 doc-lint 的规整法算一致" 0 "编号与简称一致" -- \
  bash "$SCRIPTS/number-name-sync.sh" "$number_name_project"
printf '// 照 D1（数据可 移动性）办。\n' > "$number_name_project/src/a.rs"
run_scripted "number-name-sync/简称里多一处空白仍判不符" 1 "登记处是「数据可移动性」" -- \
  bash "$SCRIPTS/number-name-sync.sh" "$number_name_project"
printf '// 照 D1（旧名字）办。\n' > "$number_name_project/src/a.rs"
run_scripted "number-name-sync/简称与登记位不符判红" 1 "登记处是「数据可移动性」" -- \
  bash "$SCRIPTS/number-name-sync.sh" "$number_name_project"
# 不符超过 15 处时默认只列前 15 处并给出看全量的开关；NUMBER_NAME_SYNC_VERBOSE=1 逐处全列
for number_name_line_index in $(seq 1 16); do printf '// 第 %s 处照 D1（旧名字）办。\n' "$number_name_line_index"; done > "$number_name_project/src/a.rs"
run_scripted "number-name-sync/超过 15 处默认截断并指出全量开关" 1 "另有 1 处；全量清单：NUMBER_NAME_SYNC_VERBOSE=1" -- \
  bash "$SCRIPTS/number-name-sync.sh" "$number_name_project"
run_scripted "number-name-sync/全量开关下第 16 处也列出来" 1 "src/a.rs:16  D1 写的「旧名字」" -- \
  env NUMBER_NAME_SYNC_VERBOSE=1 bash "$SCRIPTS/number-name-sync.sh" "$number_name_project"
mkdir -p "$temporary_directory/number-name-none"
run_scripted "number-name-sync/没有 kb 退 77" 77 "" -- \
  bash "$SCRIPTS/number-name-sync.sh" "$temporary_directory/number-name-none"
run_scripted "number-name-sync/仓根不在要给出路" 2 "找不到仓根" -- bash "$SCRIPTS/number-name-sync.sh" "$temporary_directory/number-name-no-such-root"
# 登记了自定义 kb 目录（rules/kb-discipline.md）：登记位与扫描范围都跟着它走，不是默认的 .claude/kb
number_name_project="$temporary_directory/number-name-registered"; mkdir -p "$number_name_project/crates/checker/invariants/decisions" "$number_name_project/src" "$number_name_project/.claude"
printf 'crates/checker/invariants  # 不变量与决策挪到 checker 旁边\n' > "$number_name_project/.claude/kb-directories"
printf '## D1 数据可移动性 —— 已定\n\n正文。\n' > "$number_name_project/crates/checker/invariants/decisions/01-a.md"
printf '// 照 D1（旧名字）办。\n' > "$number_name_project/src/a.rs"
run_scripted "number-name-sync/登记了自定义 kb 目录就在那里认登记位" 1 "登记处是「数据可移动性」" -- \
  bash "$SCRIPTS/number-name-sync.sh" "$number_name_project"
printf '// 照 D1（数据可移动性）办。\n' > "$number_name_project/src/a.rs"
printf '登记位自己目录里的「D1（旧名字）」不该被扫\n' > "$number_name_project/crates/checker/invariants/decisions/02-ref.md"
run_scripted "number-name-sync/登记的 kb 目录自己排除在扫描范围外" 0 "编号与简称一致" -- \
  bash "$SCRIPTS/number-name-sync.sh" "$number_name_project"
# 三种语言各有一处登记位：引用对同一种语言的登记位比。三份都带语言后缀，哪个语言仓里跑都是三组
number_name_languages_project="$temporary_directory/number-name-languages"; mkdir -p "$number_name_languages_project/.claude/kb/decisions" "$number_name_languages_project/docs"
printf '## D1 数据可移动性 —— 已定\n\n正文。\n' > "$number_name_languages_project/.claude/kb/decisions/01-a.zh.md"
printf '## D1 Data mobility —— decided\n\nBody.\n' > "$number_name_languages_project/.claude/kb/decisions/01-a.en.md"
printf '## D1 データ移動性 —— 決定済み\n\n本文。\n' > "$number_name_languages_project/.claude/kb/decisions/01-a.ja.md"
printf '照 D1（数据可移动性）办。\n' > "$number_name_languages_project/docs/note.zh.md"
printf 'Per D1（Data mobility）.\n' > "$number_name_languages_project/docs/note.en.md"
printf 'D1（データ移動性）に従う。\n' > "$number_name_languages_project/docs/note.ja.md"
run_scripted "number-name-sync/译文的引用对同一种语言的登记位比，三种语言各自一致时通过" 0 "编号与简称一致" -- \
  bash "$SCRIPTS/number-name-sync.sh" "$number_name_languages_project"
printf 'Per D1（数据可移动性）.\n' > "$number_name_languages_project/docs/note.en.md"
run_scripted "number-name-sync/译文里写了别的语言的简称判红" 1 "docs/note.en.md:1  D1 写的「数据可移动性」，登记处是「Data mobility」" -- \
  bash "$SCRIPTS/number-name-sync.sh" "$number_name_languages_project"
printf 'nope  # 登记的目录不存在\n' > "$number_name_project/.claude/kb-directories"
run_scripted "number-name-sync/kb 目录登记指到不存在的路径判红" 2 "登记的目录不存在：nope" -- \
  bash "$SCRIPTS/number-name-sync.sh" "$number_name_project"
number_name_project="$temporary_directory/number-name-copy"; make_installed_copy "$number_name_project" demo-sop; mkdir -p "$number_name_project/.claude/kb/decisions" "$number_name_project/src" "$number_name_project/.claude/demo-sop/rules"
printf '## D1 数据可移动性 —— 已定\n' > "$number_name_project/.claude/kb/decisions/01-a.md"; printf '// 照 D1（数据可移动性）办。\n' > "$number_name_project/src/a.rs"
printf '照 D1（别的名字）办。\n' > "$number_name_project/.claude/demo-sop/rules/a.md"
run_scripted "number-name-sync/副本按 I18N 的 family 认、不扫" 0 "扫 1 个文件" -- bash "$number_name_project/.claude/demo-sop/scripts/number-name-sync.sh" "$number_name_project"

# ── 转发计时：它自己的红绿样本还判得对吗 ──────────────
run_scripted "relay-timing-lint/自证 16 个样本判得对" 0 "自证：16 个红绿样本判得对" -- \
  python3 "$SCRIPTS/relay-timing-lint.py" --selftest
# 不给仓库根时判当前目录所在的仓：按本文件的位置往上数两层的话，装在包里时数到的是包根的上一层，被判的仓一个文件都没扫
relay_timing_scenario_directory="$temporary_directory/relay-timing-root"; mkdir -p "$relay_timing_scenario_directory/outer/nested/package/scripts" "$relay_timing_scenario_directory/project/research"
cp "$SCRIPTS/relay-timing-lint.py" "$SCRIPTS/preflight.py" "$SCRIPTS/proc.py" "$SCRIPTS/evidence-exclude.py" "$SCRIPTS/source-files.py" "$relay_timing_scenario_directory/outer/nested/package/scripts/"
git -C "$relay_timing_scenario_directory/project" init -q
printf 'import subprocess\nimport time\n\n\ndef relay():\n    process = subprocess.Popen(["child"], stdout=subprocess.PIPE, text=True)\n    for line in process.stdout:\n        print(time.monotonic(), line)\n' \
  > "$relay_timing_scenario_directory/project/research/relay.py"
run_scripted "relay-timing-lint/不给仓库根时判当前目录所在的仓" 1 "research/relay.py:7" -- \
  bash -c 'cd "$1/research" && python3 "$2/relay-timing-lint.py" --check' relay_default_root "$relay_timing_scenario_directory/project" "$relay_timing_scenario_directory/outer/nested/package/scripts"

# ── 同名定义：红绿样本与弄坏开关 ──────────────────────
run_scripted "duplicate-definitions/自证 15 个样本判得对、4 个弄坏开关都红" 0 "自证：15 个红绿样本判得对；4 个弄坏开关逐个打开" -- \
  python3 "$SCRIPTS/duplicate-definitions.py" --selftest
duplicate_definitions_project="$temporary_directory/duplicate-definitions"; mkdir -p "$duplicate_definitions_project/scripts" "$duplicate_definitions_project/evidence" "$duplicate_definitions_project/.claude"
printf 'def closure_names(tree):\n    return []\n\n\ndef closure_names(closure):\n    return closure\n' > "$duplicate_definitions_project/scripts/library.py"
printf 'report() {\n  echo first\n}\nreport() {\n  echo second\n}\n' > "$duplicate_definitions_project/scripts/stage.sh"
printf 'def frozen():\n    pass\n\n\ndef frozen():\n    pass\n' > "$duplicate_definitions_project/evidence/old.py"
printf 'evidence/  # 原样保存的证据\n' > "$duplicate_definitions_project/.claude/doc-lint-exclude"
run_scripted "duplicate-definitions/python 与 shell 的同名定义都报出来" 1 "scripts/library.py:5  closure_names" "scripts/stage.sh:4  report" "evidence 里 1 个（冻结证据）" -- \
  python3 "$SCRIPTS/duplicate-definitions.py" --check "$duplicate_definitions_project"
printf 'def closure_names(tree):\n    return []\n' > "$duplicate_definitions_project/scripts/library.py"
printf 'report() {\n  echo first\n}\n' > "$duplicate_definitions_project/scripts/stage.sh"
run_scripted "duplicate-definitions/改名之后判绿、冻结证据不判" 0 "扫了 python 1 个、shell 1 个文件，2 个定义" -- \
  python3 "$SCRIPTS/duplicate-definitions.py" --check "$duplicate_definitions_project"
run_scripted "duplicate-definitions/一个文件都没有退 77" 77 "本轮无对象可判" -- \
  python3 "$SCRIPTS/duplicate-definitions.py" --check "$duplicate_definitions_project/.claude"

# ── 代码文件长度：一个代码文件不算注释不超过 2000 行 ──────────────
run_scripted "code-length/自证 29 个样本判得对、7 个弄坏开关都红" 0 "29 个样本判得对" "7 个弄坏开关逐个打开" -- \
  python3 "$SCRIPTS/code-length.py" --selftest
code_length_project="$temporary_directory/code-length"; mkdir -p "$code_length_project/src" "$code_length_project/evidence" "$code_length_project/.claude"
awk 'BEGIN { for (line_index = 0; line_index < 2001; line_index++) print "let value = 1;" }' > "$code_length_project/src/long.rs"
awk 'BEGIN { for (line_index = 0; line_index < 3000; line_index++) print "# 说明"; print "echo hi" }' > "$code_length_project/src/commented.sh"
cp "$code_length_project/src/long.rs" "$code_length_project/evidence/frozen.rs"
printf 'evidence/  # 原样保存的证据\n' > "$code_length_project/.claude/doc-lint-exclude"
run_scripted "code-length/不算注释超过 2000 行的判红、注释多的不判、冻结证据不扫" 1 "src/long.rs  2001 行" "有 1 个代码文件" "evidence 里 1 个（冻结证据）" -- \
  python3 "$SCRIPTS/code-length.py" --check "$code_length_project"
sed -i '1d' "$code_length_project/src/long.rs"
run_scripted "code-length/正好 2000 行判绿" 0 "查了 2 个代码文件" "最长的是 src/long.rs（2000 行）" -- \
  python3 "$SCRIPTS/code-length.py" --check "$code_length_project"
run_scripted "code-length/一个代码文件都没有退 77" 77 "本轮无对象可判" -- \
  python3 "$SCRIPTS/code-length.py" --check "$code_length_project/.claude"

# ── 工具层的闸：钩子注册着没有、自证过不过 ──────────────
hooks_project="$temporary_directory/hooks-registered"; mkdir -p "$hooks_project/.claude/hooks"
printf '#!/usr/bin/env bash\n[[ "${1:-}" == --selftest ]] && { echo "  自证：查了 2 种情形"; exit 0; }\nexit 0\n' > "$hooks_project/.claude/hooks/guard.sh"
chmod +x "$hooks_project/.claude/hooks/guard.sh"
# 包自带的钩子也要注册：pattern-process-guard 挂 PreToolUse（rules/command-safety.md），
# gate-reuse-check 可选，注册了就挂 Stop 与 SubagentStop（rules/sop-first.md「谁来查」），
# handback-scratch-check 挂交回工具的 PreToolUse 与 SubagentStop（rules/command-safety.md「子 agent 交回之前，删掉自己建的编译目录与仓副本」）
hooks_registered_settings() { # hooks_registered_settings <gate-reuse-check 挂在哪：yes 两个都挂 / no 只挂 Stop / none 不注册>
  local gate_reuse_on_subagent_stop='' gate_reuse_on_stop='{"type":"command","command":"bash gate-reuse-check.sh"},'
  [[ "$1" == yes ]] && gate_reuse_on_subagent_stop='{"type":"command","command":"bash gate-reuse-check.sh"},'
  [[ "$1" == none ]] && gate_reuse_on_stop=''
  printf '{"hooks":{"PreToolUse":[{"matcher":"Write","hooks":[{"type":"command","command":"bash guard.sh"},{"type":"command","command":"bash pattern-process-guard.sh"}]},{"matcher":"Write|Edit|MultiEdit|NotebookEdit","hooks":[{"type":"command","command":"bash root-entry-guard.sh"},{"type":"command","command":"bash code-length-guard.sh"}]},{"matcher":"Bash","hooks":[{"type":"command","command":"bash root-entry-guard.sh"}]},{"matcher":"Agent|Task|SendMessage","hooks":[{"type":"command","command":"bash borrowed-convention-guard.sh"}]},{"matcher":"SendMessage","hooks":[{"type":"command","command":"bash message-target-guard.sh"}]},{"matcher":"SubagentHandback","hooks":[{"type":"command","command":"bash handback-scratch-check.sh"}]}],"PostToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"bash root-entry-guard.sh"},{"type":"command","command":"bash discarded-output-count-check.sh"}]}],"SessionStart":[{"hooks":[{"type":"command","command":"bash session-number-title.sh"},{"type":"command","command":"bash session-checks.sh"}]}],"UserPromptSubmit":[{"hooks":[{"type":"command","command":"bash session-number-title.sh"}]}],"Stop":[{"hooks":[%s{"type":"command","command":"bash courtesy-phrase-check.sh"},{"type":"command","command":"bash unanswered-message-check.sh"}]}],"SubagentStop":[{"hooks":[%s{"type":"command","command":"bash handback-scratch-check.sh"},{"type":"command","command":"bash courtesy-phrase-check.sh"}]}]}}\n' \
    "$gate_reuse_on_stop" "$gate_reuse_on_subagent_stop" > "$hooks_project/.claude/settings.json"
}
hooks_registered_settings yes
run_scripted "hooks-registered/注册着且自证过就通过" 0 "个钩子都注册着" -- \
  bash "$SCRIPTS/hooks-registered.sh" "$hooks_project"
# 会话检查项（rules/communication-discipline.md「会话启动与压缩之后的检测」）：文件头没写超时的那一项要红，写对了放行
mkdir -p "$hooks_project/.claude/session-checks"
printf '#!/usr/bin/env bash\n# session-check-sources: startup\nexit 0\n' > "$hooks_project/.claude/session-checks/oom"
chmod +x "$hooks_project/.claude/session-checks/oom"
run_scripted "hooks-registered/会话检查项文件头没写超时判红" 1 "会话检查项没过" "oom：文件头没写对 # session-check-timeout" -- \
  bash "$SCRIPTS/hooks-registered.sh" "$hooks_project"
printf '#!/usr/bin/env bash\n# session-check-sources: startup\n# session-check-timeout: 5\nexit 0\n' > "$hooks_project/.claude/session-checks/oom"
run_scripted "hooks-registered/会话检查项写对了放行" 0 "会话检查项 1 项文件头都写对了" -- \
  bash "$SCRIPTS/hooks-registered.sh" "$hooks_project"
rm -rf "${hooks_project:?}/.claude/session-checks"
hooks_registered_settings no
run_scripted "hooks-registered/声明的事件没挂全判红" 1 "gate-reuse-check.sh→SubagentStop" -- \
  bash "$SCRIPTS/hooks-registered.sh" "$hooks_project"
# 副本里声明了 # hook-registration: optional 的钩子，项目可以不注册；成功那句要逐个列出没注册的
hooks_registered_settings none
run_scripted "hooks-registered/可选钩子不注册放行并列出" 0 "1 个可选钩子没注册：gate-reuse-check.sh" -- \
  bash "$SCRIPTS/hooks-registered.sh" "$hooks_project"
# 项目自己的钩子写 optional 不算数：不用就连文件删掉
printf '#!/usr/bin/env bash\n# hook-registration: optional 项目自己的钩子也想不注册\nexit 0\n' > "$hooks_project/.claude/hooks/unused-guard.sh"
run_scripted "hooks-registered/项目自己的钩子写可选也要注册" 1 "unused-guard.sh  要挂的事件" -- \
  bash "$SCRIPTS/hooks-registered.sh" "$hooks_project"
rm -f "$hooks_project/.claude/hooks/unused-guard.sh"
# 声明了只在某个工具上触发（<事件>:<工具名>）的，注册在别的 matcher 上等于没挂：钩子一次都不会为那个工具触发
hooks_registered_settings yes
python3 - "$hooks_project/.claude/settings.json" <<'SETTINGS'
import json, sys
with open(sys.argv[1], encoding='utf-8') as settings_file:
    settings = json.load(settings_file)
for entry in settings['hooks']['PreToolUse']:
    if entry.get('matcher') == 'SubagentHandback':
        entry['matcher'] = 'Bash'
with open(sys.argv[1], 'w', encoding='utf-8') as settings_file:
    json.dump(settings, settings_file)
SETTINGS
run_scripted "hooks-registered/挂在别的 matcher 上判红" 1 "handback-scratch-check.sh→PreToolUse:SubagentHandback" -- \
  bash "$SCRIPTS/hooks-registered.sh" "$hooks_project"
# 按文件名的边界认：注册的是 old-guard.sh，不等于 guard.sh 注册着
printf '{"hooks":{"PreToolUse":[{"matcher":"Write","hooks":[{"type":"command","command":"bash .claude/hooks/old-guard.sh"},{"type":"command","command":"bash pattern-process-guard.sh"}]},{"matcher":"Write|Edit|MultiEdit|NotebookEdit","hooks":[{"type":"command","command":"bash root-entry-guard.sh"},{"type":"command","command":"bash code-length-guard.sh"}]},{"matcher":"Bash","hooks":[{"type":"command","command":"bash root-entry-guard.sh"}]},{"matcher":"Agent|Task|SendMessage","hooks":[{"type":"command","command":"bash borrowed-convention-guard.sh"}]},{"matcher":"SendMessage","hooks":[{"type":"command","command":"bash message-target-guard.sh"}]}],"PostToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"bash root-entry-guard.sh"}]}],"Stop":[{"hooks":[{"type":"command","command":"bash gate-reuse-check.sh"}]}],"SubagentStop":[{"hooks":[{"type":"command","command":"bash gate-reuse-check.sh"},{"type":"command","command":"bash handback-scratch-check.sh"}]}]}}\n' > "$hooks_project/.claude/settings.json"
run_scripted "hooks-registered/名字是别的钩子名的一截也不算注册" 1 "没在 settings.json 里注册" "guard.sh  要挂的事件" -- \
  bash "$SCRIPTS/hooks-registered.sh" "$hooks_project"
printf '{ 坏掉的 JSON\n' > "$hooks_project/.claude/settings.json"
run_scripted "hooks-registered/settings.json 读不了时说清是文件坏了" 1 "读不了（不是合法的 JSON" -- \
  bash "$SCRIPTS/hooks-registered.sh" "$hooks_project"
printf '{"hooks":{"PreToolUse":[]}}\n' > "$hooks_project/.claude/settings.json"
run_scripted "hooks-registered/一条都没注册时判红" 1 "一条钩子都没注册" -- \
  bash "$SCRIPTS/hooks-registered.sh" "$hooks_project"
printf '{"hooks":{"PreToolUse":[{"matcher":"Write","hooks":[{"type":"command","command":"bash other.sh"}]}]}}\n' > "$hooks_project/.claude/settings.json"
run_scripted "hooks-registered/钩子没被注册到时判红" 1 "没在 settings.json 里注册" -- \
  bash "$SCRIPTS/hooks-registered.sh" "$hooks_project"
# 自证会红的钩子：注册着也不算数——自证就是这道闸「会拒绝」的证据
printf '#!/usr/bin/env bash\n[[ "${1:-}" == --selftest ]] && { echo "  自证：有一种情形没拦住"; exit 1; }\nexit 0\n' > "$hooks_project/.claude/hooks/guard.sh"
hooks_registered_settings yes
run_scripted "hooks-registered/钩子自证没过时判红" 1 "个钩子的自证没过" -- \
  bash "$SCRIPTS/hooks-registered.sh" "$hooks_project"
# 有钩子（装进来的副本自带三个）却没有 settings.json：等于一个都没注册，判红；一个钩子都没有才是无对象可判
mkdir -p "$temporary_directory/hooks-none"
run_scripted "hooks-registered/有钩子却没有 settings.json 判红" 1 "它们一个都没注册" -- \
  bash "$SCRIPTS/hooks-registered.sh" "$temporary_directory/hooks-none"
make_hooks_package() { # make_hooks_package <目录>：只带判注册那几份脚本的最小包，claude-hooks/ 放什么由调用方定
  mkdir -p "$1/scripts"
  cp "$SCRIPTS/lib.sh" "$SCRIPTS/preflight.py" "$SCRIPTS/preflight.sh" "$SCRIPTS/proc.py" "$SCRIPTS/hooks-registered.sh" "$SCRIPTS/hook-registrations.py" "$1/scripts/"
}
hooks_scenario_directory="$temporary_directory/hooks-no-package"; make_hooks_package "$hooks_scenario_directory/package"; mkdir -p "$hooks_scenario_directory/project"
run_scripted "hooks-registered/一个钩子都没有退 77" 77 "一个钩子都没有" -- bash "$hooks_scenario_directory/package/scripts/hooks-registered.sh" "$hooks_scenario_directory/project"
# 读某一个钩子的注册失败，不许报成「没注册」：出路会指错地方
hooks_scenario_directory="$temporary_directory/hooks-reader-fails"; make_hooks_package "$hooks_scenario_directory/package"; mkdir -p "$hooks_scenario_directory/package/scripts/claude-hooks" "$hooks_scenario_directory/project/.claude"
printf '#!/usr/bin/env bash\n# hook-events: Stop\nexit 0\n' > "$hooks_scenario_directory/package/scripts/claude-hooks/sample-hook.sh"
printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"bash sample-hook.sh"}]}]}}\n' > "$hooks_scenario_directory/project/.claude/settings.json"
printf 'import sys\nif sys.argv[1:2] == ["--for"]:\n    sys.exit(1)\nprint("Stop\\t\\tbash sample-hook.sh")\n' > "$hooks_scenario_directory/package/scripts/hook-registrations.py"
run_scripted "hooks-registered/读注册失败不报成没注册" 1 "个钩子的注册读不出来" -- bash "$hooks_scenario_directory/package/scripts/hooks-registered.sh" "$hooks_scenario_directory/project"
# 可选的理由太短：判不了该不该放行，判红
hooks_scenario_directory="$temporary_directory/hooks-optional-short"; make_hooks_package "$hooks_scenario_directory/package"; mkdir -p "$hooks_scenario_directory/package/scripts/claude-hooks" "$hooks_scenario_directory/project/.claude"
printf '#!/usr/bin/env bash\n# hook-events: Stop\n# hook-registration: optional 不必\nexit 0\n' > "$hooks_scenario_directory/package/scripts/claude-hooks/sample-hook.sh"
printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"bash other-hook.sh"}]}]}}\n' > "$hooks_scenario_directory/project/.claude/settings.json"
run_scripted "hooks-registered/可选的理由太短判红" 1 "理由不到 8 个字：sample-hook.sh" -- bash "$hooks_scenario_directory/package/scripts/hooks-registered.sh" "$hooks_scenario_directory/project"
# 项目登记了自定义钩子目录：没有这份登记时默认目录是空的，会退 77（无对象可判）；读了登记才找得到这个钩子、判它没注册
hooks_scenario_directory="$temporary_directory/hooks-registered-directory"; make_hooks_package "$hooks_scenario_directory/package"; mkdir -p "$hooks_scenario_directory/project/scripts/guards" "$hooks_scenario_directory/project/.claude"
printf 'scripts/guards  # 工程脚本统一挪进项目仓根 scripts/\n' > "$hooks_scenario_directory/project/.claude/hooks-directory"
printf '#!/usr/bin/env bash\nexit 0\n' > "$hooks_scenario_directory/project/scripts/guards/guard.sh"
run_scripted "hooks-registered/登记了自定义钩子目录就扫那里" 1 "而 $hooks_scenario_directory/project/scripts/guards 与装进来的副本里共有" "它们一个都没注册" -- bash "$hooks_scenario_directory/package/scripts/hooks-registered.sh" "$hooks_scenario_directory/project"

# ── 门禁查重：新加的门禁与钩子先对过已有的，不整段抄 ──────
overlap_repository="$temporary_directory/gate-overlap"; mkdir -p "$overlap_repository/.claude/gate.d" "$overlap_repository/.claude/hooks"
git -C "$overlap_repository" init -q
overlap_block() { # overlap_block [行数，默认 9]：一段每行都不一样、每行都算有信息的行
  local step; for ((step = 1; step <= ${1:-9}; step++)); do printf 'echo "第 %s 步：核对登记表里的第 %s 行"\n' "$step" "$step"; done
}
rich_identifiers() { local index; for ((index = 1; index <= 25; index++)); do printf 'registry_column_%02d ' "$index"; done; }
{ printf '#!/usr/bin/env bash\n# gate-stage: 已有的样本阶段\n'; overlap_block; } > "$overlap_repository/.claude/gate.d/10-existing.sh"
{ printf '#!/usr/bin/env bash\n# gate-stage: 早就抄了一份的旧阶段\n'; overlap_block; } > "$overlap_repository/.claude/gate.d/16-legacy-copy.sh"
printf '#!/usr/bin/env bash\n# gate-stage: 另一个旧阶段\necho "只判一件不相干的事"\n' > "$overlap_repository/.claude/gate.d/15-plain.sh"
{ printf '#!/usr/bin/env bash\n# gate-stage: 标识符很多的旧阶段\n'; for identifier in $(rich_identifiers); do printf 'check_column "%s"\n' "$identifier"; done; } > "$overlap_repository/.claude/gate.d/30-rich.sh"
printf '#!/usr/bin/env bash\n# admission: always 样本钩子，每次调都要判\n# run-condition: none 样本钩子没有环境要求\n# 已有的钩子\necho "拦 Bash 里的一种写法"\n' > "$overlap_repository/.claude/hooks/old-guard.sh"
overlap_settings() { # overlap_settings <新钩子挂的事件> <新钩子的 matcher> [新钩子的命令]：已有钩子挂在 PreToolUse 的 Bash|Write 上
  local existing_hook_entry new_hook_entry
  existing_hook_entry='{"matcher":"Bash|Write","hooks":[{"type":"command","command":"bash .claude/hooks/old-guard.sh"}]}'
  new_hook_entry="$(printf '{"matcher":"%s","hooks":[{"type":"command","command":"%s"}]}' "$2" "${3:-bash .claude/hooks/new-guard.sh}")"
  # 同一个事件要放进同一个数组：JSON 里写两个同名的键，后一个会把已有钩子的注册整个盖掉
  if [[ "$1" == PreToolUse ]]; then
    printf '{"hooks":{"PreToolUse":[%s,%s]}}\n' "$existing_hook_entry" "$new_hook_entry"
  else
    printf '{"hooks":{"PreToolUse":[%s],"%s":[%s]}}\n' "$existing_hook_entry" "$1" "$new_hook_entry"
  fi > "$overlap_repository/.claude/settings.json"
}
overlap_settings PostToolUse Bash
git -C "$overlap_repository" add -A; git -C "$overlap_repository" -c user.name=t -c user.email=t@t commit -qm base
overlap_check=(env GATE_DIFF_BASE="$(git -C "$overlap_repository" rev-parse HEAD)" python3 "$SCRIPTS/gate-overlap.py")
# 存量里就有的整段相同（10 与 16）不判：它们都不在这一次的改动里
run_scripted "gate-overlap/没有新加或改动门禁时退 77" 77 "这一次没有新加或改动门禁与钩子" -- "${overlap_check[@]}" "$overlap_repository"
# 说明列取的是真正的说明行：old-guard.sh 的头几行是 admission: / run-condition:，说明「已有的钩子」排在它们后面
run_scripted "gate-overlap/--list 列出已有的与触发点，说明列跳过准入与运行条件" 0 "old-guard.sh" "PreToolUse[Bash|Write]" "已有的样本阶段" "已有的钩子" -- \
  python3 "$SCRIPTS/gate-overlap.py" --list "$overlap_repository"
# 本包的阶段是按 gate.sh 里调脚本的那个变量名认出来的：gate.sh 改了变量名而这里没跟上，本包的门禁一份都列不出来
run_scripted "gate-overlap/--list 认得出本包 gate.sh 调的阶段" 0 $'门禁\tscripts/doc-lint.sh' $'门禁\tscripts/show-me-test.sh' -- \
  python3 "$SCRIPTS/gate-overlap.py" --list "$SCRIPTS/.."
printf '#!/usr/bin/env bash\necho "新判据：只看一件别的事"\n' > "$overlap_repository/.claude/gate.d/20-new.sh"
run_scripted "gate-overlap/新阶段没写 gate-similar 判红" 1 "20-new.sh 是新加的，没写 gate-similar" "按字面最像的几份" -- \
  "${overlap_check[@]}" "$overlap_repository"
printf '#!/usr/bin/env bash\n# gate-similar: 10-existing.sh 它判登记表，这一道判别的事\necho "新判据：只看一件别的事"\n' > "$overlap_repository/.claude/gate.d/20-new.sh"
run_scripted "gate-overlap/写明比过谁就通过" 0 "新加的门禁与钩子 1 个（.claude/gate.d/20-new.sh）" -- "${overlap_check[@]}" "$overlap_repository"
printf '#!/usr/bin/env bash\n# gate-similar: 99-nowhere.sh 它判登记表，这一道判别的事\necho "新判据：只看一件别的事"\n' > "$overlap_repository/.claude/gate.d/20-new.sh"
run_scripted "gate-overlap/点名的不存在判红" 1 "「99-nowhere.sh」不是已有的门禁或钩子" -- "${overlap_check[@]}" "$overlap_repository"
printf '#!/usr/bin/env bash\n# gate-similar: 10-existing.sh 不同\necho "新判据：只看一件别的事"\n' > "$overlap_repository/.claude/gate.d/20-new.sh"
run_scripted "gate-overlap/理由太短判红" 1 "理由不到 8 个字" -- "${overlap_check[@]}" "$overlap_repository"
# 字面上很像的已有一份：写「无」不算，要点名
{ printf '#!/usr/bin/env bash\n# gate-similar: 无 查过全表，没有管同一件事的\n'; printf ': %s\n' "$(rich_identifiers)"; } > "$overlap_repository/.claude/gate.d/20-new.sh"
run_scripted "gate-overlap/字面上很像的没点名判红" 1 "30-rich.sh  字面上很像" -- "${overlap_check[@]}" "$overlap_repository"
# 像的字样只在注释里、代码是另一套标识符（20 个，正好够算重合）：不算字面上很像；注释也算的话重合过 0.5
other_identifiers() { local index; for ((index = 1; index <= 20; index++)); do printf 'other_column_%02d ' "$index"; done; }
{ printf '#!/usr/bin/env bash\n# gate-similar: 无 查过全表，没有管同一件事的\n'; printf '# 说明里提到 check_column gate-stage %s\n' "$(rich_identifiers)"; printf ': %s\n' "$(other_identifiers)"; } > "$overlap_repository/.claude/gate.d/20-new.sh"
run_scripted "gate-overlap/只在注释里像的不算字面上很像" 0 "新加的门禁与钩子 1 个（.claude/gate.d/20-new.sh）" -- "${overlap_check[@]}" "$overlap_repository"
# 新阶段整段抄了已有的一份：写了声明也红
{ printf '#!/usr/bin/env bash\n# gate-similar: 10-existing.sh 它只判登记表里的行号\n'; overlap_block; } > "$overlap_repository/.claude/gate.d/20-new.sh"
run_scripted "gate-overlap/新阶段整段抄已有的判红" 1 "20-new.sh:3-11 与 .claude/gate.d/10-existing.sh:3 起（连续 9 行相同）" -- \
  "${overlap_check[@]}" "$overlap_repository"
# 门槛钉在 CLONE_MINIMUM_LINES：7 行不判，8 行判；多敲几个空格也还是同一行
{ printf '#!/usr/bin/env bash\n# gate-similar: 10-existing.sh 它只判登记表里的行号\n'; overlap_block 7; } > "$overlap_repository/.claude/gate.d/20-new.sh"
run_scripted "gate-overlap/整段相同不到门槛不判" 0 "没有整段相同" -- "${overlap_check[@]}" "$overlap_repository"
{ printf '#!/usr/bin/env bash\n# gate-similar: 10-existing.sh 它只判登记表里的行号\n'; overlap_block 8; } > "$overlap_repository/.claude/gate.d/20-new.sh"
run_scripted "gate-overlap/整段相同到了门槛判红" 1 "连续 8 行相同" -- "${overlap_check[@]}" "$overlap_repository"
{ printf '#!/usr/bin/env bash\n# gate-similar: 10-existing.sh 它只判登记表里的行号\n'; overlap_block | sed 's/ /   /g'; } > "$overlap_repository/.claude/gate.d/20-new.sh"
run_scripted "gate-overlap/多敲空格绕不过整段相同" 1 "连续 9 行相同" -- "${overlap_check[@]}" "$overlap_repository"
{ printf '#!/usr/bin/env bash\n# gate-similar: 10-existing.sh 它只判登记表里的行号\n# gate-overlap:copy-kept 10-existing.sh 样本要两份各自独立跑\n# gate-overlap:copy-kept 16-legacy-copy.sh 这一份也是样本，要各自独立跑\n'; overlap_block; } > "$overlap_repository/.claude/gate.d/20-new.sh"
run_scripted "gate-overlap/写了 copy-kept 就放行并报出来" 0 "按 copy-kept 留着两份的" -- "${overlap_check[@]}" "$overlap_repository"
{ printf '#!/usr/bin/env bash\n# gate-similar: 10-existing.sh 它只判登记表里的行号\n# gate-overlap:copy-kept 99-nowhere.sh 样本要两份各自独立跑\n'; overlap_block; } > "$overlap_repository/.claude/gate.d/20-new.sh"
run_scripted "gate-overlap/copy-kept 点名不存在判红" 1 "copy-kept 有 1 处写得不对" -- "${overlap_check[@]}" "$overlap_repository"
# 抄了装进来的共享脚本也算：对照范围含本包的 scripts/
{ printf '#!/usr/bin/env bash\n# gate-similar: 10-existing.sh 它只判登记表里的行号\n'; sed -n '/^diff_base()/,/^}/p' "$SCRIPTS/lib.sh"; } > "$overlap_repository/.claude/gate.d/20-new.sh"
run_scripted "gate-overlap/抄共享脚本也判红" 1 "lib.sh" "整段相同" -- "${overlap_check[@]}" "$overlap_repository"
rm -f "$overlap_repository/.claude/gate.d/20-new.sh"
# 往已有的阶段里贴一整段：不是新文件，加进来的行照样判
cp "$overlap_repository/.claude/gate.d/15-plain.sh" "$temporary_directory/overlap-15-plain.sh"
overlap_block >> "$overlap_repository/.claude/gate.d/15-plain.sh"
run_scripted "gate-overlap/往已有的阶段里贴一整段判红" 1 "15-plain.sh:4-12" -- "${overlap_check[@]}" "$overlap_repository"
cp "$temporary_directory/overlap-15-plain.sh" "$overlap_repository/.claude/gate.d/15-plain.sh"
# 只动了存量重复旁边的一行：窗口里没有一整段是这一次加的，不判
cp "$overlap_repository/.claude/gate.d/16-legacy-copy.sh" "$temporary_directory/overlap-16-legacy-copy.sh"
printf 'echo "旧阶段里补的一行，和谁都不一样"\n' >> "$overlap_repository/.claude/gate.d/16-legacy-copy.sh"
run_scripted "gate-overlap/存量重复旁边改一行不判" 0 "改过的 1 份脚本" -- "${overlap_check[@]}" "$overlap_repository"
cp "$temporary_directory/overlap-16-legacy-copy.sh" "$overlap_repository/.claude/gate.d/16-legacy-copy.sh"
# 两份都改过：旧的那份只加了一行，新的那份整段是新加的——要报整段那一侧
cp "$overlap_repository/.claude/gate.d/10-existing.sh" "$temporary_directory/overlap-10-existing.sh"
printf 'echo "第 10 步：核对登记表里的第 10 行"\n' >> "$overlap_repository/.claude/gate.d/10-existing.sh"
{ printf '#!/usr/bin/env bash\n# gate-similar: 10-existing.sh 它只判登记表里的行号\n'; overlap_block 10; } > "$overlap_repository/.claude/gate.d/25-copy.sh"
run_scripted "gate-overlap/两份都改过时报整段那一侧" 1 "连续 10 行相同" -- "${overlap_check[@]}" "$overlap_repository"
cp "$temporary_directory/overlap-10-existing.sh" "$overlap_repository/.claude/gate.d/10-existing.sh"; rm -f "$overlap_repository/.claude/gate.d/25-copy.sh"
# 新钩子与已有钩子挂在同一个触发点上：写「无」不算，要点名
overlap_settings PreToolUse Bash
printf '#!/usr/bin/env bash\n# hook-events: PreToolUse\n# gate-similar: 无 查过全表，没有管同一件事的\necho "拦 Bash 里的另一种写法"\n' > "$overlap_repository/.claude/hooks/new-guard.sh"
run_scripted "gate-overlap/同触发点的钩子没点名判红" 1 "old-guard.sh  挂在同一个触发点上：PreToolUse[Bash|Write]" -- \
  "${overlap_check[@]}" "$overlap_repository"
printf '#!/usr/bin/env bash\n# hook-events: PreToolUse\n# gate-similar: old-guard.sh 它拦的是另一类命令，拒绝时要写的出路不同\necho "拦 Bash 里的另一种写法"\n' > "$overlap_repository/.claude/hooks/new-guard.sh"
run_scripted "gate-overlap/同触发点的钩子点了名就通过" 0 "new-guard.sh" -- "${overlap_check[@]}" "$overlap_repository"
printf '#!/usr/bin/env bash\n# gate-similar: old-guard.sh 它拦的是另一类命令，拒绝时要写的出路不同\necho "拦 Bash 里的另一种写法"\n' > "$overlap_repository/.claude/hooks/new-guard.sh"
run_scripted "gate-overlap/新钩子没写 hook-events 判红" 1 "没写 hook-events" -- "${overlap_check[@]}" "$overlap_repository"
# 事件不同、matcher 不相交，都不算同一个触发点
printf '#!/usr/bin/env bash\n# hook-events: PreToolUse\n# gate-similar: 无 查过全表，没有管同一件事的\necho "拦 Edit 里的一种写法"\n' > "$overlap_repository/.claude/hooks/new-guard.sh"
overlap_settings PreToolUse Edit
run_scripted "gate-overlap/matcher 不相交的钩子写「无」可以" 0 "new-guard.sh" -- "${overlap_check[@]}" "$overlap_repository"
printf '#!/usr/bin/env bash\n# hook-events: PostToolUse\n# gate-similar: 无 查过全表，没有管同一件事的\necho "Bash 跑完之后记一笔"\n' > "$overlap_repository/.claude/hooks/new-guard.sh"
overlap_settings PostToolUse Bash
run_scripted "gate-overlap/事件不同的钩子写「无」可以" 0 "new-guard.sh" -- "${overlap_check[@]}" "$overlap_repository"
rm -f "$overlap_repository/.claude/hooks/new-guard.sh"
# 钩子不在 .claude/hooks/、也不是 .sh：注册命令指到它，它就是钩子
mkdir -p "$overlap_repository/.claude/tools"
printf '# 拦 Bash 里的另一种写法\nprint("拦")\n' > "$overlap_repository/.claude/tools/new-guard.py"
overlap_settings PreToolUse Bash 'python3 \"$CLAUDE_PROJECT_DIR\"/.claude/tools/new-guard.py'
run_scripted "gate-overlap/注册命令指到的别处的钩子也判" 1 ".claude/tools/new-guard.py 是新加的，没写 gate-similar" -- "${overlap_check[@]}" "$overlap_repository"
# python 的文档串同注释：像的字样只在文档串里，不算字面上很像
{ printf '# hook-events: PreToolUse\n# gate-similar: old-guard.sh 它拦的是另一类命令，拒绝时要写的出路不同\n'
  printf '"""说明里提到 check_column gate-stage bash %s"""\n' "$(rich_identifiers)"; printf 'print("%s")\n' "$(other_identifiers)"; } > "$overlap_repository/.claude/tools/new-guard.py"
run_scripted "gate-overlap/只在文档串里像的不算字面上很像" 0 "new-guard.py" -- "${overlap_check[@]}" "$overlap_repository"
rm -rf "${overlap_repository:?}/.claude/tools"; overlap_settings PostToolUse Bash
run_scripted "gate-overlap/外层的 diff 基准漏进来判不了" 3 "解析不到提交" -- \
  env GATE_DIFF_BASE=0000000000000000000000000000000000000000 python3 "$SCRIPTS/gate-overlap.py" "$overlap_repository"
mkdir -p "$temporary_directory/overlap-no-git/.claude/gate.d"
run_scripted "gate-overlap/不在 git 仓里退 77" 77 "不在 git 仓里" -- python3 "$SCRIPTS/gate-overlap.py" "$temporary_directory/overlap-no-git"
# 项目登记了自定义门禁目录与钩子目录（rules/sop-first.md）：新加的门禁要去那里找，不是默认的 .claude/gate.d。
# 不读登记的话，scripts/gates/ 下的新文件不算门禁，这一轮会报「没有新加或改动门禁与钩子」而不是「没写 gate-similar」
overlap_repository="$temporary_directory/gate-overlap-registered-directory"; mkdir -p "$overlap_repository/scripts/gates" "$overlap_repository/.claude"
git -C "$overlap_repository" init -q
printf 'scripts/gates  # 工程脚本统一挪进项目仓根 scripts/\n' > "$overlap_repository/.claude/gate-directory"
printf '#!/usr/bin/env bash\n# gate-stage: 已有的样本阶段\necho 已有\n' > "$overlap_repository/scripts/gates/10-existing.sh"
git -C "$overlap_repository" add -A; git -C "$overlap_repository" -c user.name=t -c user.email=t@t commit -qm base
printf '#!/usr/bin/env bash\n# gate-stage: 新阶段\necho 新\n' > "$overlap_repository/scripts/gates/20-new.sh"
run_scripted "gate-overlap/登记了自定义门禁目录就在那里找新加的" 1 "scripts/gates/20-new.sh 是新加的，没写 gate-similar" -- \
  env GATE_DIFF_BASE="$(git -C "$overlap_repository" rev-parse HEAD)" python3 "$SCRIPTS/gate-overlap.py" "$overlap_repository"

# ── 收工钩子：agent 这一轮新建了门禁或钩子，收工前先自检能不能复用已有的 ──
run_scripted "gate-reuse-check/自证的每种情形都判得对" 0 "gate-reuse-check 自证：15 种情形判得都对" -- \
  bash "$SCRIPTS/claude-hooks/gate-reuse-check.sh" --selftest

# ── 项目根的新条目：根下新加的文件与目录要登记（rules/command-safety.md「项目根下不新建文件与目录」）──
run_scripted "root-entry-guard/自证的每种情形都判得对" 0 "root-entry-guard 自证：15 种情形判得都对" -- \
  bash "$SCRIPTS/claude-hooks/root-entry-guard.sh" --selftest
root_entries_repository="$temporary_directory/root-entries"; mkdir -p "$root_entries_repository/.claude" "$root_entries_repository/docs"
git -C "$root_entries_repository" init -q
printf 'build/\n' > "$root_entries_repository/.gitignore"; printf '说明\n' > "$root_entries_repository/docs/a.md"
git -C "$root_entries_repository" add -A; git -C "$root_entries_repository" -c user.name=t -c user.email=t@t commit -qm base
root_entries_base="$(git -C "$root_entries_repository" rev-parse HEAD)"
printf '新说明\n' > "$root_entries_repository/docs/b.md"
run_scripted "root-entries/只往已有目录里加文件时通过" 0 "相对基准新加 0 个" -- \
  env GATE_DIFF_BASE="$root_entries_base" python3 "$SCRIPTS/root-entries.py" "$root_entries_repository"
mkdir -p "$root_entries_repository/None" "$root_entries_repository/build"; printf 'x\n' > "$root_entries_repository/None/out.txt"; printf 'x\n' > "$root_entries_repository/build/out.o"
run_scripted "root-entries/根下新加没登记的目录判红" 1 "项目根下新加了 1 个没登记的条目：None" -- \
  env GATE_DIFF_BASE="$root_entries_base" python3 "$SCRIPTS/root-entries.py" "$root_entries_repository"
git -C "$root_entries_repository" add None/out.txt
run_scripted "root-entries/暂存了的新条目照样判红" 1 "项目根下新加了 1 个没登记的条目：None" -- \
  env GATE_DIFF_BASE="$root_entries_base" python3 "$SCRIPTS/root-entries.py" "$root_entries_repository"
printf 'None  # 用户同意放在根下的输出目录\nbuild/  # 编译目录，被 .gitignore 忽略\n' > "$root_entries_repository/.claude/root-entries"
run_scripted "root-entries/登记了就通过，被忽略的登记项不在也不红" 0 "相对基准新加 2 个，都登记了" "登记表 2 条都指得到" -- \
  env GATE_DIFF_BASE="$root_entries_base" python3 "$SCRIPTS/root-entries.py" "$root_entries_repository"
printf 'None  # 用户同意放在根下的输出目录\nghost  # 早就删掉的目录\n' > "$root_entries_repository/.claude/root-entries"
run_scripted "root-entries/登记的条目不在、也不被忽略判红" 1 "不在项目根下、也不被 .gitignore 覆盖：ghost" -- \
  env GATE_DIFF_BASE="$root_entries_base" python3 "$SCRIPTS/root-entries.py" "$root_entries_repository"
printf 'None\n' > "$root_entries_repository/.claude/root-entries"
run_scripted "root-entries/登记行没写理由判红" 1 "行写坏了" ".claude/root-entries:1 没写理由" -- \
  env GATE_DIFF_BASE="$root_entries_base" python3 "$SCRIPTS/root-entries.py" "$root_entries_repository"
printf 'None/out.txt  # 用户同意放在根下的输出目录\n' > "$root_entries_repository/.claude/root-entries"
run_scripted "root-entries/登记的名字不止一层判红" 1 "名字不是项目根下的一层" -- \
  env GATE_DIFF_BASE="$root_entries_base" python3 "$SCRIPTS/root-entries.py" "$root_entries_repository"
printf 'None  # 输出目录\nNone  # 又登记一次的输出目录\n' > "$root_entries_repository/.claude/root-entries"
run_scripted "root-entries/重复登记判红" 1 ".claude/root-entries:2 重复登记：None" -- \
  env GATE_DIFF_BASE="$root_entries_base" python3 "$SCRIPTS/root-entries.py" "$root_entries_repository"
mkdir -p "$temporary_directory/root-entries-not-git"
run_scripted "root-entries/不在 git 仓里退 77" 77 "不在 git 仓里" -- \
  python3 "$SCRIPTS/root-entries.py" "$temporary_directory/root-entries-not-git"

# ── 软链接：仓里不放软链接，确实要留的登记进项目根的 .claude/soft-link-exempt（rules/command-safety.md「仓里不放软链接」）──
soft_links_repository="$temporary_directory/soft-links"; mkdir -p "$soft_links_repository/.claude" "$soft_links_repository/docs"
git -C "$soft_links_repository" init -q
printf 'build/\n' > "$soft_links_repository/.gitignore"; printf '说明\n' > "$soft_links_repository/docs/a.md"
git -C "$soft_links_repository" add -A; git -C "$soft_links_repository" -c user.name=t -c user.email=t@t commit -qm base
run_scripted "soft-links/没有软链接时通过并报扫了多少" 0 "软链接 0 个，都登记了" "豁免表 0 条都指得到" -- \
  python3 "$SCRIPTS/soft-links.py" "$soft_links_repository"
ln -s a.md "$soft_links_repository/docs/untracked-link.md"
mkdir -p "$soft_links_repository/build"; ln -s ../docs "$soft_links_repository/build/ignored-directory-link"
ln -s docs/a.md "$soft_links_repository/tracked-link.md"; git -C "$soft_links_repository" add tracked-link.md
run_scripted "soft-links/跟踪的、没跟踪的、被忽略的软链接逐个列出路径" 1 "仓里有 3 个软链接没在 .claude/soft-link-exempt 登记" \
  "docs/untracked-link.md  （没跟踪的，指向 a.md）" "build/ignored-directory-link  （没跟踪的，指向 ../docs）" "tracked-link.md  （跟踪的，指向 docs/a.md）" -- \
  python3 "$SCRIPTS/soft-links.py" "$soft_links_repository"
printf 'docs/untracked-link.md  # 文档里引的旧文件名\n./build/ignored-directory-link/  # 编译目录里工具建的\ntracked-link.md  # 对外约定的入口名\n' > "$soft_links_repository/.claude/soft-link-exempt"
run_scripted "soft-links/都登记了就通过" 0 "软链接 3 个，都登记了" "豁免表 3 条都指得到" -- \
  python3 "$SCRIPTS/soft-links.py" "$soft_links_repository"
printf 'docs/untracked-link.md\n/tracked-link.md  # 绝对路径写法\nbuild/ignored-directory-link  # 短\nbuild/ignored-directory-link  # 又登记一次的编译目录链接\n' > "$soft_links_repository/.claude/soft-link-exempt"
run_scripted "soft-links/豁免表的行写坏了判红" 1 "有 3 行写坏了" "soft-link-exempt:1 没写理由" "soft-link-exempt:2 路径不是相对项目根的" "soft-link-exempt:3 理由不到 4 个字" -- \
  python3 "$SCRIPTS/soft-links.py" "$soft_links_repository"
printf 'docs/untracked-link.md  # 文档里引的旧文件名\nbuild/ignored-directory-link  # 编译目录里工具建的\nbuild/ignored-directory-link  # 又登记一次的编译目录链接\ntracked-link.md  # 对外约定的入口名\n' > "$soft_links_repository/.claude/soft-link-exempt"
run_scripted "soft-links/同一条路径登记两次判红" 1 "soft-link-exempt:3 重复登记：build/ignored-directory-link" -- \
  python3 "$SCRIPTS/soft-links.py" "$soft_links_repository"
printf 'docs/untracked-link.md  # 文档里引的旧文件名\nbuild/ignored-directory-link  # 编译目录里工具建的\ntracked-link.md  # 对外约定的入口名\ndocs/a.md  # 登记成软链接的普通文件\nghost  # 早就删掉的软链接\n' > "$soft_links_repository/.claude/soft-link-exempt"
run_scripted "soft-links/登记的路径不是软链接判红" 1 "豁免表里有 2 条登记的路径不是软链接：docs/a.md、ghost" -- \
  python3 "$SCRIPTS/soft-links.py" "$soft_links_repository"
printf 'docs/untracked-link.md  # 文档里引的旧文件名\nbuild/ignored-directory-link  # 编译目录里工具建的\n' > "$soft_links_repository/.claude/soft-link-exempt"
rm "$soft_links_repository/tracked-link.md"
run_scripted "soft-links/暂存区里是软链接、工作区里删了照样判红" 1 "tracked-link.md  （跟踪的，暂存区里是软链接，工作区里不是）" -- \
  python3 "$SCRIPTS/soft-links.py" "$soft_links_repository"
# --staged 的里层：临时树里只有跟踪的，没跟踪的软链接只在源仓工作区里
soft_links_staged_tree="$temporary_directory/soft-links-staged-tree"; mkdir -p "$soft_links_staged_tree/docs"
git -C "$soft_links_staged_tree" init -q; printf '说明\n' > "$soft_links_staged_tree/docs/a.md"
soft_links_source="$temporary_directory/soft-links-source"; mkdir -p "$soft_links_source/docs"; ln -s a.md "$soft_links_source/docs/only-in-source.md"
run_scripted "soft-links/--staged-from 把源仓工作区里没跟踪的一起判" 1 "docs/only-in-source.md  （没跟踪的，指向 a.md（在源仓工作区里））" "源仓工作区也扫了" -- \
  python3 "$SCRIPTS/soft-links.py" "$soft_links_staged_tree" --staged-from "$soft_links_source"
soft_links_not_git="$temporary_directory/soft-links-not-git"; mkdir -p "$soft_links_not_git"; ln -s /etc/hostname "$soft_links_not_git/hostname-link"
run_scripted "soft-links/不在 git 仓里照样扫文件系统" 1 "不在 git 仓里：只扫了文件系统" "hostname-link  （没跟踪的，指向 /etc/hostname）" -- \
  python3 "$SCRIPTS/soft-links.py" "$soft_links_not_git"

# ── 代号：新加的行里拿代号指东西 ──────────────────────
run_scripted "code-name-lint/自证 21 个样本判得对、10 个弄坏开关都红" 0 "自证：21 个红绿样本判得对；10 个弄坏开关逐个打开" -- \
  python3 "$SCRIPTS/code-name-lint.py" --selftest
code_name_repository="$temporary_directory/code-name"; mkdir -p "$code_name_repository/records" "$code_name_repository/.claude"
git -C "$code_name_repository" init -q
printf '# 记录\n\n旧行里的 5a 不回扫。\n' > "$code_name_repository/records/old.md"
git -C "$code_name_repository" add -A; git -C "$code_name_repository" -c user.name=t -c user.email=t@t commit -qm init
run_scripted "code-name-lint/没有新加的行退 77" 77 "本阶段无对象可判" -- \
  python3 "$SCRIPTS/code-name-lint.py" --check "$code_name_repository"
printf '\n新加：9g 另报一处，SC02 还红着，MR18 已登记。\n' >> "$code_name_repository/records/old.md"
run_scripted "code-name-lint/新加的行里的代号判红、旧行不判" 1 "records/old.md:5  9g" "records/old.md:5  SC02" "records/old.md:5  MR18" "有 3 处拿代号" -- \
  python3 "$SCRIPTS/code-name-lint.py" --check "$code_name_repository"
printf 'MR[0-9]+  # 变异名，登记在 kb 的变异表\n' > "$code_name_repository/.claude/code-names"
run_scripted "code-name-lint/登记过的编号体系不判" 1 "有 2 处拿代号" "登记的编号体系 1 条" -- \
  python3 "$SCRIPTS/code-name-lint.py" --check "$code_name_repository"
printf 'MR[0-9+  # 变异名，登记在 kb 的变异表\nSC[0-9]+\n' > "$code_name_repository/.claude/code-names"
run_scripted "code-name-lint/登记表正则写坏、没写理由判红" 1 "code-names:1 正则写坏了" "code-names:2 没写理由" -- \
  python3 "$SCRIPTS/code-name-lint.py" --check "$code_name_repository"
# 一份 .md 自己用 doc-lint:not-numbers 声明过的标号，只在这一份里放行
code_name_declared_repository="$temporary_directory/code-name-declared"; mkdir -p "$code_name_declared_repository/records"
git -C "$code_name_declared_repository" init -q
printf '<!-- doc-lint:not-numbers PQ14 -->\n# 实验页\n' > "$code_name_declared_repository/records/experiment.md"
printf '# 记录\n' > "$code_name_declared_repository/records/schedule.md"
git -C "$code_name_declared_repository" add -A; git -C "$code_name_declared_repository" -c user.name=t -c user.email=t@t commit -qm init
printf '\nPQ14 那一格照旧。\n' >> "$code_name_declared_repository/records/experiment.md"
printf '\nPQ14 那一格照旧。\n' >> "$code_name_declared_repository/records/schedule.md"
run_scripted "code-name-lint/本页声明过的标号只在本页放行" 1 "records/schedule.md:3  PQ14" "有 1 处拿代号" -- \
  python3 "$SCRIPTS/code-name-lint.py" --check "$code_name_declared_repository"

# ── 历史条目编号：本次新增的条目撞了已有的号 ──────────────
# 样本是中文的：在英文、日文仓里跑自证也要按中文判，语言由 HISTORY_ORDINAL_LANG 钉住。
export HISTORY_ORDINAL_LANG=zh
history_repository="$temporary_directory/history-ordinal"; mkdir -p "$history_repository/.claude/kb"
git -C "$history_repository" init -q
printf '# 变更史\n\n### 2026-09-17（其一）：建档\n- 起点。\n' > "$history_repository/.claude/kb/decisions-history.md"
git -C "$history_repository" add -A; git -C "$history_repository" -c user.name=t -c user.email=t@t commit -qm init
run_scripted "history-ordinal/没有新增条目时通过" 0 "没有撞号" -- \
  bash "$SCRIPTS/history-ordinal.sh" "$history_repository"
printf '\n### 2026-09-17（其一）：又一条\n- 撞号了。\n' >> "$history_repository/.claude/kb/decisions-history.md"
run_scripted "history-ordinal/新增的条目撞号判红" 1 "处撞号" -- \
  bash "$SCRIPTS/history-ordinal.sh" "$history_repository"
# 用相对路径起它：cd 到仓根之后，键提取器照样要找得到
run_scripted "history-ordinal/相对路径起也找得到键提取器" 1 "处撞号" -- \
  bash -c 'cd "$1" && bash scripts/history-ordinal.sh "$2"' history_ordinal_relative "$SCRIPTS/.." "$history_repository"
run_scripted "history-ordinal/没有变更史文件退 77" 77 "" -- \
  bash "$SCRIPTS/history-ordinal.sh" "$temporary_directory"
# 窗口按这一轮的 diff 基准算，不只和 HEAD 比：撞号的条目先提交、再跑门禁，只和 HEAD 比就落在窗口外看不见
history_repository="$temporary_directory/history-committed"; mkdir -p "$history_repository/.claude/kb"; git -C "$history_repository" init -q
printf '# 变更史\n\n### 2026-09-17（其一）：建档\n- 起点。\n' > "$history_repository/.claude/kb/decisions-history.md"
git -C "$history_repository" add -A; git -C "$history_repository" -c user.name=t -c user.email=t@t commit -qm init
history_diff_base_commit="$(git -C "$history_repository" rev-parse HEAD)"
printf '\n### 2026-09-17（其一）：又一条\n- 先提交了再跑门禁。\n' >> "$history_repository/.claude/kb/decisions-history.md"
git -C "$history_repository" add -A; git -C "$history_repository" -c user.name=t -c user.email=t@t commit -qm 撞号
run_scripted "history-ordinal/撞号先提交再跑也看得见" 1 "处撞号" -- env GATE_DIFF_BASE="$history_diff_base_commit" bash "$SCRIPTS/history-ordinal.sh" "$history_repository"
run_scripted "history-ordinal/外层的 diff 基准解析不到就判不了" 1 "在这个仓里解析不到提交" -- \
  env GATE_DIFF_BASE=0000000000000000000000000000000000000000 bash "$SCRIPTS/history-ordinal.sh" "$history_repository"
# 搬进实验史新文件的存量撞号不是新撞号：基准那一侧的清单漏了 experiments-history/ 的话，搬过去的条目全被当成新写的
history_repository="$temporary_directory/history-moved-experiments"; mkdir -p "$history_repository/.claude/kb/experiments-history"; git -C "$history_repository" init -q
printf '# 实验史\n\n### 2026-09-10（其一）：甲\n- 存量。\n\n### 2026-09-10（其一）：乙\n- 存量撞号。\n' > "$history_repository/.claude/kb/experiments-history/2026-08.md"
git -C "$history_repository" add -A; git -C "$history_repository" -c user.name=t -c user.email=t@t commit -qm init
git -C "$history_repository" mv .claude/kb/experiments-history/2026-08.md .claude/kb/experiments-history/2026-09.md
run_scripted "history-ordinal/搬进实验史新文件的存量撞号不算新撞号" 0 "没有撞号" "存量 1 处撞号" -- bash "$SCRIPTS/history-ordinal.sh" "$history_repository"
run_scripted "history-ordinal/仓根不在要给出路" 1 "找不到仓根" -- bash "$SCRIPTS/history-ordinal.sh" "$temporary_directory/history-no-such-root"
# 登记了自定义 kb 目录（rules/kb-discipline.md）：默认的 .claude/kb 不存在也不报「无对象可判」，扫登记的那个目录
history_repository="$temporary_directory/history-registered-kb-directory"; mkdir -p "$history_repository/crates/checker/invariants" "$history_repository/.claude"; git -C "$history_repository" init -q
printf 'crates/checker/invariants  # 不变量挪到 checker 旁边\n' > "$history_repository/.claude/kb-directories"
printf '# 不变量变更史\n\n### 2026-09-17（其一）：建档\n- 起点。\n' > "$history_repository/crates/checker/invariants/history.md"
git -C "$history_repository" add -A; git -C "$history_repository" -c user.name=t -c user.email=t@t commit -qm init
printf '\n### 2026-09-17（其一）：又一条\n- 撞号了。\n' >> "$history_repository/crates/checker/invariants/history.md"
run_scripted "history-ordinal/登记了自定义 kb 目录就扫那里" 1 "处撞号" -- \
  bash "$SCRIPTS/history-ordinal.sh" "$history_repository"
run_scripted "history-ordinal/非中文的仓报未实现退 77，不报没有撞号" 77 "en 未实现" -- \
  env HISTORY_ORDINAL_LANG=en bash "$SCRIPTS/history-ordinal.sh" "$history_repository"
unset HISTORY_ORDINAL_LANG

# ── 本地阶段判别力：项目在 .claude/gate.d/ 里接的阶段，自己会不会红 ──
stage_selftest_project="$temporary_directory/stage-selftest"; mkdir -p "$stage_selftest_project/.claude/gate.d/fixtures/10-demo.sh/red" "$stage_selftest_project/.claude/gate.d/fixtures/10-demo.sh/green"
# 样本阶段里不写 ✗ / ✓：gate-lint 扫的是本文件的字面，写了就成了「一处没有出路的拒绝」
printf '#!/usr/bin/env bash\n[[ -f "${1:-.}/bad.txt" ]] && { echo "  拒绝：有 bad.txt"; exit 1; }\necho "  通过：没有 bad.txt"\n' > "$stage_selftest_project/.claude/gate.d/10-demo.sh"
printf 'exit=1\nwant=有 bad.txt\n' > "$stage_selftest_project/.claude/gate.d/fixtures/10-demo.sh/red/expect"
: > "$stage_selftest_project/.claude/gate.d/fixtures/10-demo.sh/red/bad.txt"
printf 'exit=0\n' > "$stage_selftest_project/.claude/gate.d/fixtures/10-demo.sh/green/expect"
run_scripted "stage-selftest/样本判得对就通过" 0 "有用例的阶段判得都对" -- \
  bash "$SCRIPTS/stage-selftest.sh" "$stage_selftest_project/.claude/gate.d"
# 外层 gate.sh 导出的 GATE_DIFF_BASE 是真仓的提交号，漏进样本就成了临时仓里不存在的提交：样本看得到它就判错
printf '#!/usr/bin/env bash\n[[ -n "${GATE_DIFF_BASE:-}" ]] && { echo "  拒绝：看得到外层的基准"; exit 1; }\n[[ -f "${1:-.}/bad.txt" ]] && { echo "  拒绝：有 bad.txt"; exit 1; }\necho "  通过：没有 bad.txt"\n' > "$stage_selftest_project/.claude/gate.d/10-demo.sh"
run_scripted "stage-selftest/样本看不到外层的 GATE_DIFF_BASE" 0 "有用例的阶段判得都对" -- \
  env GATE_DIFF_BASE=0000000000000000000000000000000000000000 bash "$SCRIPTS/stage-selftest.sh" "$stage_selftest_project/.claude/gate.d"
# 阶段坏成恒绿时必须红：把那个阶段改成永远 exit 0，红样本当场判错
printf '#!/usr/bin/env bash\necho "  通过：没有 bad.txt"\n' > "$stage_selftest_project/.claude/gate.d/10-demo.sh"
run_scripted "stage-selftest/阶段变恒绿时判红" 1 "期望退出 1，实测 0" -- \
  bash "$SCRIPTS/stage-selftest.sh" "$stage_selftest_project/.claude/gate.d"
# red / green 之外、带 expect 的样本目录也要跑：摆一个目录名不是 red / green、期望又写错了的样本，它必须判错
printf '#!/usr/bin/env bash\n[[ -f "${1:-.}/bad.txt" ]] && { echo "  拒绝：有 bad.txt"; exit 1; }\necho "  通过：没有 bad.txt"\n' > "$stage_selftest_project/.claude/gate.d/10-demo.sh"
mkdir -p "$stage_selftest_project/.claude/gate.d/fixtures/10-demo.sh/third"; : > "$stage_selftest_project/.claude/gate.d/fixtures/10-demo.sh/third/bad.txt"
printf 'exit=0\n' > "$stage_selftest_project/.claude/gate.d/fixtures/10-demo.sh/third/expect"
run_scripted "stage-selftest/red 与 green 之外的样本目录也跑" 1 "third            期望退出 0，实测 1" -- \
  bash "$SCRIPTS/stage-selftest.sh" "$stage_selftest_project/.claude/gate.d"
rm -f "$stage_selftest_project/.claude/gate.d/fixtures/10-demo.sh/third/expect"
run_scripted "stage-selftest/样本目录没有 expect 要判错" 1 "样本目录里没有 expect" -- \
  bash "$SCRIPTS/stage-selftest.sh" "$stage_selftest_project/.claude/gate.d"
printf 'want=x\n' > "$stage_selftest_project/.claude/gate.d/fixtures/10-demo.sh/third/expect"
run_scripted "stage-selftest/expect 里没写 exit= 要判错" 1 "expect 里没有 exit=<退出码>" -- \
  bash "$SCRIPTS/stage-selftest.sh" "$stage_selftest_project/.claude/gate.d"
rm -rf "${stage_selftest_project:?}/.claude/gate.d/fixtures/10-demo.sh/third"
# 新形态：一道阶段一个目录 <门禁目录>/<名>/<名>.sh，用例是同目录下的 *.case.sh，头部写 expect-exit / expect-want
stage_selftest_project="$temporary_directory/stage-selftest-nested"; mkdir -p "$stage_selftest_project/.claude/gate.d/my-stage"
printf '#!/usr/bin/env bash\n[[ -f "${1:-.}/bad.txt" ]] && { echo "  拒绝：有 bad.txt"; exit 1; }\necho "  通过：没有 bad.txt"\n' > "$stage_selftest_project/.claude/gate.d/my-stage/my-stage.sh"
printf '#!/usr/bin/env bash\n# expect-exit: 1\n# expect-want: 有 bad.txt\ntouch bad.txt\n' > "$stage_selftest_project/.claude/gate.d/my-stage/red.case.sh"
printf '#!/usr/bin/env bash\n# expect-exit: 0\n' > "$stage_selftest_project/.claude/gate.d/my-stage/green.case.sh"
run_scripted "stage-selftest/新形态：嵌套阶段配同目录下的用例就通过" 0 "有用例的阶段判得都对（2 个用例）" -- \
  bash "$SCRIPTS/stage-selftest.sh" "$stage_selftest_project/.claude/gate.d"
run_scripted "stage-selftest/新形态：--list-items 认嵌套阶段" 0 my-stage -- \
  bash "$SCRIPTS/stage-selftest.sh" "$stage_selftest_project/.claude/gate.d" --list-items
# 新旧两种形态同时存在时各自判各自的
cp -r "$stage_selftest_project/.claude/gate.d/my-stage" "$stage_selftest_project/.claude/gate.d/my-stage-copy"
mv "$stage_selftest_project/.claude/gate.d/my-stage-copy/my-stage.sh" "$stage_selftest_project/.claude/gate.d/my-stage-copy/my-stage-copy.sh"
mkdir -p "$stage_selftest_project/.claude/gate.d/fixtures/10-demo.sh/red" "$stage_selftest_project/.claude/gate.d/fixtures/10-demo.sh/green"
printf '#!/usr/bin/env bash\n[[ -f "${1:-.}/bad.txt" ]] && { echo "  拒绝：有 bad.txt"; exit 1; }\necho "  通过：没有 bad.txt"\n' > "$stage_selftest_project/.claude/gate.d/10-demo.sh"
printf 'exit=1\nwant=有 bad.txt\n' > "$stage_selftest_project/.claude/gate.d/fixtures/10-demo.sh/red/expect"
: > "$stage_selftest_project/.claude/gate.d/fixtures/10-demo.sh/red/bad.txt"
printf 'exit=0\n' > "$stage_selftest_project/.claude/gate.d/fixtures/10-demo.sh/green/expect"
run_scripted "stage-selftest/新旧两种形态过渡期并存" 0 "有用例的阶段判得都对（6 个用例）" -- \
  bash "$SCRIPTS/stage-selftest.sh" "$stage_selftest_project/.claude/gate.d"
# 用例文件没写 # expect-exit: 判不了该红还是该绿，要判错
printf '#!/usr/bin/env bash\ntouch bad.txt\n' > "$stage_selftest_project/.claude/gate.d/my-stage/malformed.case.sh"
run_scripted "stage-selftest/新形态：用例没写 expect-exit 要判错" 1 "malformed" "用例文件没写 # expect-exit" -- \
  bash "$SCRIPTS/stage-selftest.sh" "$stage_selftest_project/.claude/gate.d" --item my-stage
# 扁平的 <名>.sh 与嵌套的 <名>/<名>.sh 撞名：--item 分不清点的是哪一道，判红
cp "$stage_selftest_project/.claude/gate.d/10-demo.sh" "$stage_selftest_project/.claude/gate.d/my-stage.sh"
run_scripted "stage-selftest/新旧两种形态撞名判红" 1 "有同名的阶段" "my-stage" -- \
  bash "$SCRIPTS/stage-selftest.sh" "$stage_selftest_project/.claude/gate.d"
rm -f "$stage_selftest_project/.claude/gate.d/my-stage.sh"
# 没有本地阶段目录、或目录里没有阶段时退 77（本次无对象可判），不许报绿，而且要说出是哪一种：gate.sh 的跳过说明让人看它的输出
run_scripted "stage-selftest/没有本地阶段目录退 77 并说出来" 77 "没有门禁目录" "这不是通过" -- \
  bash "$SCRIPTS/stage-selftest.sh" "$temporary_directory/stage-selftest-none"
mkdir -p "$temporary_directory/stage-selftest-empty"
run_scripted "stage-selftest/阶段目录里没有阶段退 77 并说出来" 77 "下没有本地阶段（扁平的" "这不是通过" -- \
  bash "$SCRIPTS/stage-selftest.sh" "$temporary_directory/stage-selftest-empty"
# 写了准入与运行条件的阶段带 --force 喂样本：它的条件（这里是一条永远不满足的）不挡判别力自证（rules/preflight-discipline.md）
stage_selftest_project="$temporary_directory/stage-selftest-conditions"; mkdir -p "$stage_selftest_project/.claude/gate.d/fixtures/10-demo.sh/red" "$stage_selftest_project/.claude/gate.d/fixtures/10-demo.sh/green" "$stage_selftest_project/.claude/singlefs-ai-sop/scripts"
cp "$SCRIPTS/lib.sh" "$SCRIPTS/preflight.py" "$SCRIPTS/preflight.sh" "$SCRIPTS/proc.py" "$stage_selftest_project/.claude/singlefs-ai-sop/scripts/"
printf '#!/usr/bin/env bash\n# admission: always 样本：每次调都有意义\n# run-condition: check false :: 样本：这条条件永远不满足\nsource "$(dirname "${BASH_SOURCE[0]}")/../singlefs-ai-sop/scripts/lib.sh"\npreflight "${BASH_SOURCE[0]}" "$@"; set -- ${PREFLIGHT_ARGUMENTS[@]+"${PREFLIGHT_ARGUMENTS[@]}"}\n[[ -f "${1:-.}/bad.txt" ]] && { echo "  拒绝：有 bad.txt"; exit 1; }\necho "  通过：没有 bad.txt"\n' > "$stage_selftest_project/.claude/gate.d/10-demo.sh"
printf 'exit=1\nwant=有 bad.txt\n' > "$stage_selftest_project/.claude/gate.d/fixtures/10-demo.sh/red/expect"
: > "$stage_selftest_project/.claude/gate.d/fixtures/10-demo.sh/red/bad.txt"
printf 'exit=0\n' > "$stage_selftest_project/.claude/gate.d/fixtures/10-demo.sh/green/expect"
run_scripted "stage-selftest/写了条件的阶段带 --force 喂样本" 0 "有用例的阶段判得都对" -- \
  bash "$SCRIPTS/stage-selftest.sh" "$stage_selftest_project/.claude/gate.d"
# 没配样本的阶段逐个用 report_not_run 报出来（门禁下进汇总的「本次未跑」），不只在这一段里 warn 一句
stage_selftest_project="$temporary_directory/stage-selftest-no-case"; mkdir -p "$stage_selftest_project/.claude/gate.d/fixtures/10-demo.sh/red" "$stage_selftest_project/.claude/gate.d/fixtures/10-demo.sh/green"
printf '#!/usr/bin/env bash\n[[ -f "${1:-.}/bad.txt" ]] && { echo "  拒绝：有 bad.txt"; exit 1; }\necho "  通过：没有 bad.txt"\n' > "$stage_selftest_project/.claude/gate.d/10-demo.sh"
printf 'exit=1\nwant=有 bad.txt\n' > "$stage_selftest_project/.claude/gate.d/fixtures/10-demo.sh/red/expect"
: > "$stage_selftest_project/.claude/gate.d/fixtures/10-demo.sh/red/bad.txt"
printf 'exit=0\n' > "$stage_selftest_project/.claude/gate.d/fixtures/10-demo.sh/green/expect"
printf '#!/usr/bin/env bash\necho "  通过：没有样本的阶段"\n' > "$stage_selftest_project/.claude/gate.d/20-nosample.sh"
run_scripted "stage-selftest/没有样本的阶段逐个报本次未跑" 0 "本次未跑（这不是通过）：20-nosample 没有判别力用例" -- \
  bash "$SCRIPTS/stage-selftest.sh" "$stage_selftest_project/.claude/gate.d"
# 一个阶段都没配样本：一个样本都没判，是无对象可判，不许报「判得都对」
stage_selftest_project="$temporary_directory/stage-selftest-no-samples"; mkdir -p "$stage_selftest_project/.claude/gate.d/fixtures"
printf '#!/usr/bin/env bash\necho "  通过"\n' > "$stage_selftest_project/.claude/gate.d/10-demo.sh"
run_scripted "stage-selftest/一个阶段都没配样本退 77" 77 "一个用例都没判" -- bash "$SCRIPTS/stage-selftest.sh" "$stage_selftest_project/.claude/gate.d"
# --item 只喂点名那几道：另摆一道坏成恒绿的阶段，没点名它时整趟要绿（证明它没被起），点名它时要红
stage_selftest_project="$temporary_directory/stage-selftest-item"; mkdir -p "$stage_selftest_project/.claude/gate.d/fixtures/10-demo.sh/red" "$stage_selftest_project/.claude/gate.d/fixtures/10-demo.sh/green" "$stage_selftest_project/.claude/gate.d/fixtures/30-broken.sh/red"
printf '#!/usr/bin/env bash\n[[ -f "${1:-.}/bad.txt" ]] && { echo "  拒绝：有 bad.txt"; exit 1; }\necho "  通过：没有 bad.txt"\n' > "$stage_selftest_project/.claude/gate.d/10-demo.sh"
printf 'exit=1\nwant=有 bad.txt\n' > "$stage_selftest_project/.claude/gate.d/fixtures/10-demo.sh/red/expect"
: > "$stage_selftest_project/.claude/gate.d/fixtures/10-demo.sh/red/bad.txt"
printf 'exit=0\n' > "$stage_selftest_project/.claude/gate.d/fixtures/10-demo.sh/green/expect"
printf '#!/usr/bin/env bash\necho "  通过：恒绿"\n' > "$stage_selftest_project/.claude/gate.d/30-broken.sh"
printf 'exit=1\nwant=有 bad.txt\n' > "$stage_selftest_project/.claude/gate.d/fixtures/30-broken.sh/red/expect"
: > "$stage_selftest_project/.claude/gate.d/fixtures/30-broken.sh/red/bad.txt"
printf '#!/usr/bin/env bash\necho "  通过：没有样本的阶段"\n' > "$stage_selftest_project/.claude/gate.d/20-nosample.sh"
run_scripted "stage-selftest/--item 只喂点名的阶段" 0 "点名的 1 道阶段判得都对（2 个用例）：10-demo" -- \
  bash "$SCRIPTS/stage-selftest.sh" "$stage_selftest_project/.claude/gate.d" --item 10-demo.sh
run_scripted "stage-selftest/--item 一个值里用空格隔开两道，每道都摘 .sh" 1 "30-broken                    red              期望退出 1，实测 0" -- \
  bash "$SCRIPTS/stage-selftest.sh" "$stage_selftest_project/.claude/gate.d" --item "10-demo.sh 30-broken.sh"
run_scripted "stage-selftest/--item 点名旧形态阶段不带 .sh 也认" 0 "点名的 1 道阶段判得都对（2 个用例）：10-demo" -- \
  bash "$SCRIPTS/stage-selftest.sh" "$stage_selftest_project/.claude/gate.d" --item 10-demo
run_scripted "stage-selftest/--item 点名坏阶段要红" 1 "30-broken                    red              期望退出 1，实测 0" -- \
  bash "$SCRIPTS/stage-selftest.sh" "$stage_selftest_project/.claude/gate.d" --item 30-broken.sh
run_scripted "stage-selftest/--item 写错退 2 并列出可点名的阶段" 2 "--item nope：" "       10-demo" "       30-broken" -- \
  bash "$SCRIPTS/stage-selftest.sh" "$stage_selftest_project/.claude/gate.d" --item nope.sh
run_scripted "stage-selftest/--item 缺阶段名退 2" 2 "--item （缺阶段名）" -- \
  bash "$SCRIPTS/stage-selftest.sh" "$stage_selftest_project/.claude/gate.d" --item
run_scripted "stage-selftest/--list-items 只列配了样本的阶段" 0 "10-demo" "30-broken" -- \
  bash "$SCRIPTS/stage-selftest.sh" "$stage_selftest_project/.claude/gate.d" --list-items
# 并行喂用例：成功句报并行度；并行度写坏退 2；派出去的没收全判红（弄坏开关 lose-one-result）；并行之后坏阶段照样红
run_scripted "stage-selftest/成功句报并行度（--jobs）" 0 "点名的 1 道阶段判得都对（2 个用例）：10-demo；没点名的这一趟不喂；并行度 3" -- \
  bash "$SCRIPTS/stage-selftest.sh" "$stage_selftest_project/.claude/gate.d" --item 10-demo --jobs 3
run_scripted "stage-selftest/并行度从 STAGE_SELFTEST_JOBS 取" 0 "并行度 2" -- \
  env STAGE_SELFTEST_JOBS=2 bash "$SCRIPTS/stage-selftest.sh" "$stage_selftest_project/.claude/gate.d" --item 10-demo
run_scripted "stage-selftest/并行度不是正整数退 2" 2 "并行度「0」不是正整数" -- \
  bash "$SCRIPTS/stage-selftest.sh" "$stage_selftest_project/.claude/gate.d" --jobs 0
run_scripted "stage-selftest/--jobs 缺值退 2" 2 "不是正整数" -- \
  bash "$SCRIPTS/stage-selftest.sh" "$stage_selftest_project/.claude/gate.d" --jobs
run_scripted "stage-selftest/并行喂时坏阶段照样红" 1 "30-broken                    red              期望退出 1，实测 0" "10-demo                      red              判得对" -- \
  bash "$SCRIPTS/stage-selftest.sh" "$stage_selftest_project/.claude/gate.d" --jobs 4
run_scripted "stage-selftest/STAGE_SELFTEST_BREAK=lose-one-result 必须判红" 1 "只收回" "没收回的：10-demo/red" -- \
  env STAGE_SELFTEST_BREAK=lose-one-result bash "$SCRIPTS/stage-selftest.sh" "$stage_selftest_project/.claude/gate.d" --item 10-demo --jobs 4
# 用例共用一把锁的阶段：并行喂会撞（证明真的在同时跑），声明串行之后一条一条喂就不撞
stage_selftest_project="$temporary_directory/stage-selftest-serial"; mkdir -p "$stage_selftest_project/.claude/gate.d/fixtures/40-shared.sh/red" "$stage_selftest_project/.claude/gate.d/fixtures/40-shared.sh/green" "$stage_selftest_project/.claude/gate.d/fixtures/40-shared.sh/third"
write_shared_lock_stage() { # write_shared_lock_stage <第二行写什么>
  printf '#!/usr/bin/env bash\n%s\nshared_lock="$(dirname "$0")/shared.lock"\nmkdir "$shared_lock" 2>/dev/null || { echo "  拒绝：别的用例正占着锁"; exit 9; }\nsleep 1\nrmdir "$shared_lock"\n[[ -f "${1:-.}/bad.txt" ]] && { echo "  拒绝：有 bad.txt"; exit 1; }\necho "  通过：没有 bad.txt"\n' "$1" > "$stage_selftest_project/.claude/gate.d/40-shared.sh"
}
printf 'exit=1\nwant=有 bad.txt\n' > "$stage_selftest_project/.claude/gate.d/fixtures/40-shared.sh/red/expect"
: > "$stage_selftest_project/.claude/gate.d/fixtures/40-shared.sh/red/bad.txt"
printf 'exit=0\n' > "$stage_selftest_project/.claude/gate.d/fixtures/40-shared.sh/green/expect"
printf 'exit=0\n' > "$stage_selftest_project/.claude/gate.d/fixtures/40-shared.sh/third/expect"
write_shared_lock_stage '# 没声明串行'
run_scripted "stage-selftest/共用一把锁的用例并行喂会撞" 1 "实测 9" -- \
  bash "$SCRIPTS/stage-selftest.sh" "$stage_selftest_project/.claude/gate.d" --jobs 3
run_scripted "stage-selftest/--jobs 1 一条一条喂不撞" 0 "有用例的阶段判得都对（3 个用例）" "并行度 1" -- \
  bash "$SCRIPTS/stage-selftest.sh" "$stage_selftest_project/.claude/gate.d" --jobs 1
write_shared_lock_stage '# stage-selftest: serial 三条用例共用阶段目录下的同一把锁'
run_scripted "stage-selftest/声明串行的阶段一条一条喂" 0 "有用例的阶段判得都对（3 个用例）" "并行度 3，声明串行的阶段 1 道（40-shared）一条一条喂" -- \
  bash "$SCRIPTS/stage-selftest.sh" "$stage_selftest_project/.claude/gate.d" --jobs 3
write_shared_lock_stage '# stage-selftest: serial'
run_scripted "stage-selftest/串行声明没写理由要判错" 1 "（串行声明）" "后面没写理由" -- \
  bash "$SCRIPTS/stage-selftest.sh" "$stage_selftest_project/.claude/gate.d" --jobs 3

# ── 脚本执行位：暂存区里丢了可执行位，工作区那份还是可执行的 ──────
# 手工暂存时写死 100644 就是这个形态，而在工作区上跑的门禁一声不吭。
script_modes_repository="$temporary_directory/script-modes"; mkdir -p "$script_modes_repository/scripts"
git -C "$script_modes_repository" init -q
printf '#!/usr/bin/env bash\necho hi\n' > "$script_modes_repository/scripts/tool.sh"; chmod +x "$script_modes_repository/scripts/tool.sh"
git -C "$script_modes_repository" add -A; git -C "$script_modes_repository" -c user.name=t -c user.email=t@t commit -qm init
run_scripted "script-modes/模式与工作区一致时通过" 0 "暂存区里的模式与工作区一致" -- \
  bash "$SCRIPTS/script-modes.sh" "$script_modes_repository/scripts"
git -C "$script_modes_repository" update-index --chmod=-x scripts/tool.sh
run_scripted "script-modes/暂存区里丢了执行位判红" 1 ".sh 要可执行" -- \
  bash "$SCRIPTS/script-modes.sh" "$script_modes_repository/scripts"
# 射程写窄到一个脚本都没有时，不许报绿（rules/show-me-test.md：扫到 0 项也不是通过）
mkdir -p "$script_modes_repository/empty"
run_scripted "script-modes/扫到 0 个脚本判红" 1 "一个已跟踪的 .sh / .py 都没查到" -- \
  bash "$SCRIPTS/script-modes.sh" "$script_modes_repository/empty"
# 射程可能跨两个 git 仓：gate.sh --staged 把项目摊在临时 worktree 里，而装进来的 SOP 副本仍在真仓。
# 拿射程里排在最前的那个目录的仓根去 ls-files 另一个仓里的路径，git 直接 fatal、输出为空，这一条就报「一个都没查到」。
# 先还原 scripts/tool.sh 所在那个仓的执行位（「暂存区里丢了执行位判红」那一例改坏的），否则这一条永远红，测不到跨仓那件事
git -C "$script_modes_repository" update-index --chmod=+x scripts/tool.sh
other_script_modes_repository="$temporary_directory/script-modes-other"; mkdir -p "$other_script_modes_repository/tools"
git -C "$other_script_modes_repository" init -q
printf '#!/usr/bin/env bash\necho hi\n' > "$other_script_modes_repository/tools/other.sh"; chmod +x "$other_script_modes_repository/tools/other.sh"
git -C "$other_script_modes_repository" add -A; git -C "$other_script_modes_repository" -c user.name=t -c user.email=t@t commit -qm init
run_scripted "script-modes/射程跨两个仓时两边都查" 0 "查了 2 个脚本" -- \
  bash "$SCRIPTS/script-modes.sh" "$script_modes_repository/scripts" "$other_script_modes_repository/tools"
git -C "$other_script_modes_repository" update-index --chmod=-x tools/other.sh
run_scripted "script-modes/跨仓时第二个仓的红也要报出来" 1 "tools/other.sh" -- \
  bash "$SCRIPTS/script-modes.sh" "$script_modes_repository/scripts" "$other_script_modes_repository/tools"
# 射程里判不了的目录要逐个报出来，不能因为别的目录查到了东西就不吭声（项目里被 .gitignore 挡着的副本那一格每次都是 0 项）
script_modes_repository="$temporary_directory/script-modes"; mkdir -p "$temporary_directory/script-modes-outside-git"
run_scripted "script-modes/射程里不在 git 仓的目录要报出来" 0 "脚本执行位：$temporary_directory/script-modes-outside-git（不在 git 仓里）" -- \
  bash "$SCRIPTS/script-modes.sh" "$script_modes_repository/scripts" "$temporary_directory/script-modes-outside-git"
mkdir -p "$script_modes_repository/ignored-copy"; printf 'ignored-copy/\n' > "$script_modes_repository/.gitignore"; printf '#!/usr/bin/env bash\necho hi\n' > "$script_modes_repository/ignored-copy/tool.sh"
run_scripted "script-modes/射程里一个已跟踪脚本都没有的目录要报出来" 0 "$script_modes_repository/ignored-copy（一个已跟踪的 .sh / .py 都没有" -- \
  bash "$SCRIPTS/script-modes.sh" "$script_modes_repository/scripts" "$script_modes_repository/ignored-copy"
# 空目录 git 存不下：工作区里靠它过的样本，到了提交与 --staged 的临时树里就没有那个目录
mkdir -p "$script_modes_repository/scripts/fixtures/sample/rules"
run_scripted "script-modes/射程里有空目录判红" 1 "$script_modes_repository/scripts/fixtures/sample/rules 是空目录" "1 个空目录" -- \
  bash "$SCRIPTS/script-modes.sh" "$script_modes_repository/scripts"
: > "$script_modes_repository/scripts/fixtures/sample/rules/.keep"
run_scripted "script-modes/空目录放了 .keep 就通过" 0 "没有空目录" -- \
  bash "$SCRIPTS/script-modes.sh" "$script_modes_repository/scripts"
printf 'scripts/build-cache/\n' >> "$script_modes_repository/.gitignore"; mkdir -p "$script_modes_repository/scripts/build-cache"
run_scripted "script-modes/被 .gitignore 挡着的空目录不判" 0 "没有空目录" -- \
  bash "$SCRIPTS/script-modes.sh" "$script_modes_repository/scripts"
# 符号链接形式的阶段：判它在暂存区里指向的那一份。链接本身的模式是 120000，判成「.sh 要可执行」的话给的出路对链接不起作用
make_linked_stage_repository() { # make_linked_stage_repository <目录> <指向的脚本在暂存区里的模式：+x 或 -x>
  git -C "$1" init -q 2>/dev/null || { mkdir -p "$1" && git -C "$1" init -q; }
  mkdir -p "$1/.claude/gate.d" "$1/.claude/stages"
  printf '#!/usr/bin/env bash\necho probe\n' > "$1/.claude/stages/probe.sh"; chmod +x "$1/.claude/stages/probe.sh"
  ln -s ../stages/probe.sh "$1/.claude/gate.d/65-linked.sh"
  git -C "$1" add -A; git -C "$1" update-index --chmod="$2" .claude/stages/probe.sh
}
linked_stage_repository="$temporary_directory/script-modes-link-ok"; mkdir -p "$linked_stage_repository"; make_linked_stage_repository "$linked_stage_repository" +x
run_scripted "script-modes/符号链接判它指向的那一份（可执行就过）" 0 "查了 1 个脚本" -- bash "$SCRIPTS/script-modes.sh" "$linked_stage_repository/.claude/gate.d"
linked_stage_repository="$temporary_directory/script-modes-link-bad"; mkdir -p "$linked_stage_repository"; make_linked_stage_repository "$linked_stage_repository" -x
run_scripted "script-modes/符号链接指向的那一份不可执行要红" 1 "指向的 .claude/stages/probe.sh 在暂存区里是 100644" -- bash "$SCRIPTS/script-modes.sh" "$linked_stage_repository/.claude/gate.d"

# 日期的下界只在被查目录本身是 git 仓顶层时才问 git。不这么限，`git -C` 会一路往上找：
# 目录嵌在一个更晚才开始的仓里时（SOP 副本放在项目的 .claude/ 下就是这种形状），拿外层仓的第一个提交当下界，
# 真日期会被判成不可能。这里造一个 2026-09-15 才开始的外层仓，里面的子目录写着 2026-09-01：
# 按外层仓算早出了 7 天的宽限，按这个包的起点算在宽限之内。
date_scenario_directory="$temporary_directory/date-walkup"; mkdir -p "$date_scenario_directory/outer/sub/kb"
git -C "$date_scenario_directory/outer" init -q
printf '起点\n' > "$date_scenario_directory/outer/README.md"; git -C "$date_scenario_directory/outer" add -A
GIT_AUTHOR_DATE="2026-09-15T00:00:00" GIT_COMMITTER_DATE="2026-09-15T00:00:00" \
  git -C "$date_scenario_directory/outer" -c user.name=t -c user.email=t@t commit -qm 起点
printf '# 决策\n\n正文只写现状。\n\n## 历史版本\n\n### 2026-09-01\n- 建档。\n' > "$date_scenario_directory/outer/sub/kb/a.md"
run_scripted "doc-lint/日期下界不往上找外层仓" 0 "文档铁律检查通过" -- \
  env DOC_LINT_LANG=zh bash "$SCRIPTS/doc-lint.sh" "$date_scenario_directory/outer/sub"

# 下界从第一个提交往前宽限 7 天：git init 之前做的工作会带着当时的日期进第一个提交。
# 两例钉住宽限的两边：之内放行，之外照样判红。
date_scenario_directory="$temporary_directory/date-grace"
for grace_side in within beyond; do
  mkdir -p "$date_scenario_directory/$grace_side/kb"; git -C "$date_scenario_directory/$grace_side" init -q
  printf '起点\n' > "$date_scenario_directory/$grace_side/README.md"; git -C "$date_scenario_directory/$grace_side" add -A
  GIT_AUTHOR_DATE="2026-09-15T00:00:00" GIT_COMMITTER_DATE="2026-09-15T00:00:00" \
    git -C "$date_scenario_directory/$grace_side" -c user.name=t -c user.email=t@t commit -qm 起点
done
printf '# 决策\n\n正文只写现状。\n\n## 历史版本\n\n### 2026-09-10\n- 建档。\n' > "$date_scenario_directory/within/kb/a.md"
printf '# 决策\n\n正文只写现状。\n\n## 历史版本\n\n### 2026-09-05\n- 建档。\n' > "$date_scenario_directory/beyond/kb/a.md"
run_scripted "doc-lint/第一个提交之前 7 天以内的日期放行" 0 "文档铁律检查通过" -- \
  env DOC_LINT_LANG=zh bash "$SCRIPTS/doc-lint.sh" "$date_scenario_directory/within"
run_scripted "doc-lint/早于第一个提交 7 天以上的日期判红" 1 "早于这个仓第一个提交（2026-09-15）7 天以上" -- \
  env DOC_LINT_LANG=zh bash "$SCRIPTS/doc-lint.sh" "$date_scenario_directory/beyond"

# 「今天」按最晚的时区（UTC+14）算。本机时钟是 UTC、人在东京时，东京凌晨写下的当天日期比 UTC 的今天晚一天。
# 用一个假 date 把时钟钉住：本机时钟上是 2026-09-16，UTC+14 已是 2026-09-17。退回只看本机时钟，「东京已到的日期放行」那一例就红。
date_scenario_directory="$temporary_directory/date-latest-zone"; mkdir -p "$date_scenario_directory/bin" "$date_scenario_directory/today/kb" "$date_scenario_directory/tomorrow/kb"
printf '#!/usr/bin/env bash\nif [[ "${1:-}" == "+%%F" ]]; then\n  case "${TZ:-}" in UTC-14|Etc/GMT-14) echo 2026-09-17 ;; *) echo 2026-09-16 ;; esac; exit 0\nfi\nexec %q "$@"\n' \
  "$(command -v date)" > "$date_scenario_directory/bin/date"
chmod +x "$date_scenario_directory/bin/date"
printf '# 决策\n\n正文只写现状。\n\n## 历史版本\n\n### 2026-09-17\n- 建档。\n' > "$date_scenario_directory/today/kb/a.md"
printf '# 决策\n\n正文只写现状。\n\n## 历史版本\n\n### 2026-09-18\n- 建档。\n' > "$date_scenario_directory/tomorrow/kb/a.md"
run_scripted "doc-lint/今天按最晚的时区算，东京已到的日期放行" 0 "文档铁律检查通过" -- \
  env PATH="$date_scenario_directory/bin:$PATH" DOC_LINT_LANG=zh bash "$SCRIPTS/doc-lint.sh" "$date_scenario_directory/today"
run_scripted "doc-lint/比最晚时区的今天还晚就判红" 1 "晚于今天（2026-09-17，按最晚的时区算）" -- \
  env PATH="$date_scenario_directory/bin:$PATH" DOC_LINT_LANG=zh bash "$SCRIPTS/doc-lint.sh" "$date_scenario_directory/tomorrow"

# 下界靠 date -d 做减法。不认 -d 的 date 算不出下界，下界要是静默变空，2026-01-01 就放行了：停下来说清楚。
date_scenario_directory="$temporary_directory/date-no-minus-d"; mkdir -p "$date_scenario_directory/bin" "$date_scenario_directory/project/kb"
printf '#!/usr/bin/env bash\nfor argument in "$@"; do [[ "$argument" == -d ]] && { echo "date: illegal option -- d" >&2; exit 1; }; done\nexec %q "$@"\n' \
  "$(command -v date)" > "$date_scenario_directory/bin/date"
chmod +x "$date_scenario_directory/bin/date"
printf '# 决策\n\n正文只写现状。\n\n## 历史版本\n\n### 2026-01-01\n- 建档。\n' > "$date_scenario_directory/project/kb/a.md"
run_scripted "doc-lint/date 不认 -d 时停下，不许静默放过" 1 "这台机器的 date 不认 -d" -- \
  env PATH="$date_scenario_directory/bin:$PATH" DOC_LINT_LANG=zh bash "$SCRIPTS/doc-lint.sh" "$date_scenario_directory/project"

# 浅克隆里「第一个提交」是截断处：拿它当下界，项目越老误判越多。这里完整历史从 2026-09-01 开始，浅克隆只看得到 2026-09-16。
date_scenario_directory="$temporary_directory/date-shallow"; mkdir -p "$date_scenario_directory/full"; git -C "$date_scenario_directory/full" init -q
printf '起点\n' > "$date_scenario_directory/full/README.md"; git -C "$date_scenario_directory/full" add -A
GIT_AUTHOR_DATE="2026-09-01T00:00:00" GIT_COMMITTER_DATE="2026-09-01T00:00:00" \
  git -C "$date_scenario_directory/full" -c user.name=t -c user.email=t@t commit -qm 起点
printf '又一行\n' >> "$date_scenario_directory/full/README.md"; git -C "$date_scenario_directory/full" add -A
GIT_AUTHOR_DATE="2026-09-16T00:00:00" GIT_COMMITTER_DATE="2026-09-16T00:00:00" \
  git -C "$date_scenario_directory/full" -c user.name=t -c user.email=t@t commit -qm 又一行
git clone -q --depth 1 "file://$date_scenario_directory/full" "$date_scenario_directory/shallow" 2>/dev/null
mkdir -p "$date_scenario_directory/shallow/kb"
printf '# 决策\n\n正文只写现状。\n\n## 历史版本\n\n### 2026-09-02\n- 建档。\n' > "$date_scenario_directory/shallow/kb/a.md"
run_scripted "doc-lint/浅克隆不拿截断处当第一个提交" 0 "文档铁律检查通过" -- \
  env DOC_LINT_LANG=zh bash "$SCRIPTS/doc-lint.sh" "$date_scenario_directory/shallow"

# en / ja 仓写实测日期的形态是 Measured ( 与 実測（。只认中文那种时，这两种一条都不查。
date_scenario_directory="$temporary_directory/date-forms"; mkdir -p "$date_scenario_directory/kb"
printf '# 决策\n\nMeasured (2099-01-01) 一次。\n\n## 历史版本\n' > "$date_scenario_directory/kb/en.md"
printf '# 决策\n\n実測（2099-01-01）一次。\n\n## 历史版本\n' > "$date_scenario_directory/kb/ja.md"
run_scripted "doc-lint/英日两种实测写法的日期也查" 1 "kb/en.md:3  日期 2099-01-01 不可能" "kb/ja.md:3  日期 2099-01-01 不可能" -- \
  env DOC_LINT_LANG=zh bash "$SCRIPTS/doc-lint.sh" "$date_scenario_directory"

# 包里没有 I18N 时照常判：sed 读不到文件退 2，赋值带着这个退出码，set -e 当场把脚本带走、一个字都不打。
# doc-lint 与 manifest 各一例；同一形态的另外六处带着 `|| true`。
no_i18n_scenario_directory="$temporary_directory/no-i18n-doc-lint"; mkdir -p "$no_i18n_scenario_directory/package/scripts" "$no_i18n_scenario_directory/project/kb"
cp "$SCRIPTS/lib.sh" "$SCRIPTS/preflight.py" "$SCRIPTS/preflight.sh" "$SCRIPTS/proc.py" "$SCRIPTS/doc-lint.sh" "$no_i18n_scenario_directory/package/scripts/"
printf '# 决策\n\n正文只写现状。\n\n## 历史版本\n' > "$no_i18n_scenario_directory/project/kb/a.md"
run_scripted "doc-lint/包里没有 I18N 也照常判" 0 "文档铁律检查通过" -- bash "$no_i18n_scenario_directory/package/scripts/doc-lint.sh" "$no_i18n_scenario_directory/project"
no_i18n_package="$temporary_directory/no-i18n-manifest"; mkdir -p "$no_i18n_package/scripts" "$no_i18n_package/rules"
cp "$SCRIPTS/lib.sh" "$SCRIPTS/preflight.py" "$SCRIPTS/preflight.sh" "$SCRIPTS/proc.py" "$SCRIPTS/manifest.sh" "$no_i18n_package/scripts/"
printf '# 规则\n\n正文。\n' > "$no_i18n_package/rules/a.md"; printf "# 包\\n" > "$no_i18n_package/CLAUDE.md"
run_scripted "manifest/包里没有 I18N 也照常判" 0 "清单与规范文本一致" -- \
  bash -c 'bash "$1/scripts/manifest.sh" --update >/dev/null && bash "$1/scripts/manifest.sh"' manifest_without_i18n "$no_i18n_package"

