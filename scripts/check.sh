#!/usr/bin/env bash
# admission: always 每一轮门禁都现编现测：编译器、依赖与构建缓存的状态不在任何输入清单里
# run-condition: command cargo
# 快速本地检查：格式 / lint / 构建 / 单测。
# 这是快速反馈，**不是准入标准**。准入标准见 gate.sh。
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight "${BASH_SOURCE[0]}" "$@"; set -- ${PREFLIGHT_ARGUMENTS[@]+"${PREFLIGHT_ARGUMENTS[@]}"}

ROOT="${1:-$(project_root)}"
cd "$ROOT"

command -v cargo >/dev/null 2>&1 || die "cargo 缺失" \
  "装 Rust 工具链：" \
  "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
[[ -f Cargo.toml ]] || die "$ROOT 下没有 Cargo.toml" \
  "本脚本只做 Rust 项目的快速反馈。确认你在项目根，或先建 workspace 的 Cargo.toml。"

# 项目给 cargo 挂的前缀（内存上限这类包装）：项目根的 .claude/cargo-command-prefix，一行 `<命令与参数>  # 理由`，按空白切成词、不认引号，相对路径从项目根算。
# 这里起的每一条 cargo 都经它，各自一份上限；文件在而读不出一条能用的前缀就判红，不退回无包装去跑（rules/command-safety.md）。
CARGO_COMMAND=(cargo)
CARGO_PREFIX_FILE="$ROOT/$CARGO_COMMAND_PREFIX_FILE"
CARGO_PREFIX_NOTE=()
if [[ -f "$CARGO_PREFIX_FILE" ]]; then
  prefix_lines=()
  while IFS= read -r prefix_line || [[ -n "$prefix_line" ]]; do
    if [[ -z "${prefix_line//[[:space:]]/}" || "${prefix_line#"${prefix_line%%[![:space:]]*}"}" == \#* ]]; then continue; fi
    prefix_lines+=("$prefix_line")
  done < "$CARGO_PREFIX_FILE"
  [[ ${#prefix_lines[@]} -eq 1 ]] || die "$CARGO_PREFIX_FILE 要正好一行前缀（注释行除外），现在是 ${#prefix_lines[@]} 行" \
    "写成一行： systemd-run --user --scope --quiet -p MemoryMax=24G  # 为什么要这个前缀" \
    "不要前缀就删掉这个文件；写坏了不会退回无包装去跑。"
  prefix_words=()
  read -r -a prefix_words <<< "${prefix_lines[0]%%#*}"
  prefix_reason="${prefix_lines[0]#*#}"
  [[ "${prefix_lines[0]}" == *'#'* && -n "${prefix_reason//[[:space:]]/}" ]] || die "$CARGO_PREFIX_FILE 那一行没写理由：${prefix_lines[0]}" \
    "在行尾写 # 为什么要这个前缀；理由不许省。"
  [[ ${#prefix_words[@]} -gt 0 ]] || die "$CARGO_PREFIX_FILE 那一行只有理由，没有前缀命令" \
    "写成一行： <命令与参数>  # 理由；相对路径从项目根算。"
  command -v "${prefix_words[0]}" >/dev/null 2>&1 || die "$CARGO_PREFIX_FILE 的前缀命令找不到：${prefix_words[0]}" \
    "装上它、把它放进 PATH，或写成从项目根算起的路径；前缀起不来就不跑 cargo，不退回无包装去跑。"
  # 第一个词之后的也要查：前缀常是「解释器 + 脚本路径」，脚本缺了时 bash 退 127，被下面的 fmt 报成「格式不合规」。
  # 像路径的词（带 /，或以 .sh / .py 结尾）从项目根算起都要存在。选项与赋值（--working-directory=/x、CARGO_TARGET_DIR=/x）不是路径，不查。
  missing_prefix_paths=()
  for prefix_word in "${prefix_words[@]:1}"; do
    case "$prefix_word" in
      -*|*=*) ;;
      */*|*.sh|*.py) [[ -e "$prefix_word" ]] || missing_prefix_paths+=("$prefix_word") ;;
    esac
  done
  [[ ${#missing_prefix_paths[@]} -eq 0 ]] || die "$CARGO_PREFIX_FILE 的前缀里有 ${#missing_prefix_paths[@]} 个路径不存在：${missing_prefix_paths[*]}" \
    "相对路径从项目根（$ROOT）算；路径写错了就改对，那份脚本删了就把前缀一起改掉。前缀起不来就不跑 cargo，不退回无包装去跑。"
  # 前缀先空跑一次：它自己起不来（比如没有 user systemd、排不上队）时，退出码是它的，不该挂在「格式不合规」这句下面
  prefix_probe_exit_code=0
  "${prefix_words[@]}" true || prefix_probe_exit_code=$?
  [[ $prefix_probe_exit_code -eq 0 ]] || die "$CARGO_PREFIX_FILE 的前缀起不来：空跑 ${prefix_words[*]} true 退出码 $prefix_probe_exit_code" \
    "这是前缀自己的失败，还没轮到 cargo：退出码的含义看前缀自己的说明，修好再跑。" \
    "不要这个前缀了就删掉这个文件；前缀起不来就不跑 cargo，不退回无包装去跑。"
  CARGO_COMMAND=("${prefix_words[@]}" cargo)
  CARGO_PREFIX_NOTE=("这一条 cargo 是经项目的前缀跑的（${prefix_words[*]}，登记在 $CARGO_PREFIX_FILE）：" \
                     "退出码是前缀自己的（比如撞了内存上限、排不上队）时，含义看它自己的说明，不是 cargo 的判定。")
  say "  cargo 经项目的前缀跑：${prefix_words[*]}"
fi
run_cargo() { "${CARGO_COMMAND[@]}" "$@"; }

head1 "cargo fmt --check"
run_cargo fmt --all -- --check || die "格式不合规（退出码 $?）" \
  "跑 cargo fmt --all 让它自己改完，再重跑本脚本。" ${CARGO_PREFIX_NOTE[@]+"${CARGO_PREFIX_NOTE[@]}"}
ok "格式通过"

head1 "cargo clippy"
# 编码纪律里能交给 clippy 的那几条（rules/code-discipline.md「门禁管哪一半」），一条对一条：
CODE_DISCIPLINE_LINTS=(
  -D clippy::wildcard_enum_match_arm          # 封闭集合的枚举不写 _ =>
  -D clippy::allow_attributes_without_reason  # #[allow] 要写 reason = "…"
  -D clippy::cast_possible_truncation         # 会丢值的 as 转换：截断
  -D clippy::cast_sign_loss                   # 会丢值的 as 转换：丢符号
  -D clippy::cast_possible_wrap               # 会丢值的 as 转换：回绕
  -D clippy::undocumented_unsafe_blocks       # unsafe 块要有 // SAFETY:
  -D clippy::shadow_unrelated                 # 换了含义的同名遮蔽
)
run_cargo clippy --all-targets --all-features -- -D warnings "${CODE_DISCIPLINE_LINTS[@]}" \
  || die "clippy 有告警（按 -D warnings 视为错误），或者踩了编码纪律的某一条（退出码 $?）" \
  "上面每条告警都指着文件和行号，逐条改。编码纪律那几条的写法见 rules/code-discipline.md。" \
  "确有必要保留的，在那一处写 #[allow(<lint>, reason = \"为什么\")]，理由写进 reason——" \
  "不要整仓关掉 -D warnings（rules/command-safety.md「脚本改文件之后要回读确认，警告是免费的信号」）。" ${CARGO_PREFIX_NOTE[@]+"${CARGO_PREFIX_NOTE[@]}"}
ok "clippy 通过"

head1 "cargo build"
run_cargo build --all-targets || die "构建失败（退出码 $?）" \
  "上面是 rustc 的报错，从第一条改起——后面的多半是它的连锁反应。" ${CARGO_PREFIX_NOTE[@]+"${CARGO_PREFIX_NOTE[@]}"}
ok "构建通过"

head1 "cargo test"
# 输出一边照打一边留一份，数一数跑了几条测试：一条都没跑也是退 0，而「单测通过」读起来与跑过了一模一样
test_output="$(mktemp)"
trap 'rm -f "${test_output:?}"' EXIT
if run_cargo test --all 2>&1 | tee "$test_output"; then
  cargo_test_exit_code=0
else
  cargo_test_exit_code="${PIPESTATUS[0]}"
fi
[[ $cargo_test_exit_code -eq 0 ]] || die "单测失败（退出码 $cargo_test_exit_code）" \
  "上面列出了失败的用例名。单跑一个看细节：" \
  "cargo test --all <用例名> -- --nocapture" \
  "改代码还是改断言，先想清楚是哪一种——直接改断言等于把测试关掉。" ${CARGO_PREFIX_NOTE[@]+"${CARGO_PREFIX_NOTE[@]}"}
# 每个测试二进制（含文档测试）打一行 `test result: ok. N passed; M failed; …`，跑了的条数是各行 passed 与 failed 之和
test_count=0; test_binary_count=0
while IFS= read -r test_result_line; do
  if [[ "$test_result_line" =~ ([0-9]+)\ passed\;\ ([0-9]+)\ failed\; ]]; then
    test_count=$((test_count + BASH_REMATCH[1] + BASH_REMATCH[2])); test_binary_count=$((test_binary_count + 1))
  fi
done < <(grep '^test result: ' "$test_output" || true)
[[ $test_count -gt 0 ]] || die "cargo test 退了 0，却一条测试都没跑（test result 行里的 passed 与 failed 加起来是 0）" \
  "给代码写测试：同文件里加 #[cfg(test)] mod tests，或者在 tests/ 下放集成测试。" \
  "一条都没跑的「单测通过」与跑过了在输出里长得一样（rules/show-me-test.md「扫到 0 项也不是通过」）。"
ok "单测通过（$test_binary_count 个测试二进制，共 $test_count 条测试）"
