#!/usr/bin/env bash
# admission: always 每一轮门禁都现编现测：编译器、依赖与构建缓存的状态不在任何输入清单里
# run-condition: command cargo
# 快速本地检查：格式 / lint / 构建 / 单测。
# 这是快速反馈，**不是准入标准**。准入标准见 gate.sh。
#
# clippy 按特性组合各跑一趟：不带特性与 --all-features 看到的代码不是同一份（#[cfg(feature)] 圈起来的一边另一趟编不到），
# 只跑 --all-features 的话，不带特性那一趟里没人调用的函数（dead_code）之类的告警谁也看不见。
#   默认两趟：不带特性（`default`）、`--all-features`。
#   项目登记：项目根的 .claude/clippy-feature-combinations，一行一个组合 `<特性参数>  # 理由`，按空白切成词、不认引号；
#     不带特性写 `default`，别的写 cargo 的特性参数（`--all-features`、`--no-default-features`、`--features a,b`）；
#     登记了就只跑登记的这几趟，不再另加默认的两趟；理由不许省；文件在而读不出一个组合就判红，不退回默认去跑。
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight "${BASH_SOURCE[0]}" "$@"; set -- ${PREFLIGHT_ARGUMENTS[@]+"${PREFLIGHT_ARGUMENTS[@]}"}

ROOT="${1:-$(project_root)}"
cd "$ROOT"

command -v cargo >/dev/null 2>&1 || die "cargo 缺失" \
  "装 Rust 工具链：" \
  "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
[[ -f Cargo.toml ]] || die "$ROOT 下没有 Cargo.toml" \
  "本脚本只做 Rust 项目的快速反馈。确认你在项目根，或先建 workspace 的 Cargo.toml。"

head1 "cargo fmt --check"
cargo fmt --all -- --check || die "格式不合规（退出码 $?）" \
  "跑 cargo fmt --all 让它自己改完，再重跑本脚本。"
ok "格式通过"

head1 "cargo clippy"
# 要跑的特性组合：登记了照登记的，没登记就是默认的两趟。每个组合是一串 cargo 特性参数，`default` 表示不带。
CLIPPY_FEATURE_COMBINATIONS=("default" "--all-features")
CLIPPY_COMBINATIONS_FILE="$ROOT/$CLIPPY_FEATURE_COMBINATIONS_FILE"
if [[ -f "$CLIPPY_COMBINATIONS_FILE" ]]; then
  CLIPPY_FEATURE_COMBINATIONS=()
  while IFS= read -r combination_line || [[ -n "$combination_line" ]]; do
    if [[ -z "${combination_line//[[:space:]]/}" || "${combination_line#"${combination_line%%[![:space:]]*}"}" == \#* ]]; then continue; fi
    combination_reason="${combination_line#*#}"
    [[ "$combination_line" == *'#'* && -n "${combination_reason//[[:space:]]/}" ]] || die "$CLIPPY_COMBINATIONS_FILE 有一行没写理由：$combination_line" \
      "在行尾写 # 为什么要跑这个组合；理由不许省。"
    combination_words=()
    read -r -a combination_words <<< "${combination_line%%#*}"
    [[ ${#combination_words[@]} -gt 0 ]] || die "$CLIPPY_COMBINATIONS_FILE 有一行只有理由，没有特性参数：$combination_line" \
      "写成 <特性参数>  # 理由；不带特性写 default，其余写 cargo 的特性参数（--all-features、--no-default-features、--features a,b）。"
    if [[ "${combination_words[0]}" != default && "${combination_words[0]}" != -* ]]; then
      die "$CLIPPY_COMBINATIONS_FILE 的特性参数认不出：${combination_words[*]}" \
        "不带特性写 default，其余以 - 开头，照 cargo 的特性参数写（--all-features、--no-default-features、--features a,b）。"
    fi
    [[ "${combination_words[0]}" != default || ${#combination_words[@]} -eq 1 ]] || die "$CLIPPY_COMBINATIONS_FILE 里 default 后面还带了参数：${combination_words[*]}" \
      "default 就是不带特性参数；要带参数就去掉 default，只写参数。"
    CLIPPY_FEATURE_COMBINATIONS+=("${combination_words[*]}")
  done < "$CLIPPY_COMBINATIONS_FILE"
  [[ ${#CLIPPY_FEATURE_COMBINATIONS[@]} -gt 0 ]] || die "$CLIPPY_COMBINATIONS_FILE 里没有一个能用的组合（注释行和空行不算）" \
    "每行写一个： default  # 理由，或 --all-features  # 理由；不要这份登记了就删掉文件，改回默认的两趟。"
fi
# CHECK_BREAK 只给自证弄坏判据用，其余时候不设：single-clippy-pass 把 clippy 改回只跑 --all-features 一趟（登记了也不看），
# selftest 的「check/不带特性才有的告警要红」要因此红。
case "${CHECK_BREAK:-}" in
  '') ;;
  single-clippy-pass) CLIPPY_FEATURE_COMBINATIONS=("--all-features") ;;
  *) die "CHECK_BREAK 的值不认：${CHECK_BREAK}" "只认 single-clippy-pass；不是在自证里弄坏判据的话，不要设这个变量。" ;;
esac
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
for clippy_combination in "${CLIPPY_FEATURE_COMBINATIONS[@]}"; do
  clippy_feature_arguments=()
  [[ "$clippy_combination" == default ]] || read -r -a clippy_feature_arguments <<< "$clippy_combination"
  say "  clippy 特性组合：$clippy_combination"
  cargo clippy --all-targets ${clippy_feature_arguments[@]+"${clippy_feature_arguments[@]}"} -- -D warnings "${CODE_DISCIPLINE_LINTS[@]}" \
    || die "clippy 有告警（按 -D warnings 视为错误），或者踩了编码纪律的某一条（特性组合：$clippy_combination；退出码 $?）" \
    "上面每条告警都指着文件和行号，逐条改。编码纪律那几条的写法见 rules/code-discipline.md。" \
    "确有必要保留的，在那一处写 #[allow(<lint>, reason = \"为什么\")]，理由写进 reason——" \
    "不要整仓关掉 -D warnings（rules/command-safety.md「脚本改文件之后要回读确认，警告是免费的信号」）。"
done
ok "clippy 通过（${#CLIPPY_FEATURE_COMBINATIONS[@]} 趟特性组合：${CLIPPY_FEATURE_COMBINATIONS[*]}）"

head1 "cargo build"
cargo build --all-targets || die "构建失败（退出码 $?）" \
  "上面是 rustc 的报错，从第一条改起——后面的多半是它的连锁反应。"
ok "构建通过"

head1 "cargo test"
# 输出一边照打一边留一份，数一数跑了几条测试：一条都没跑也是退 0，而「单测通过」读起来与跑过了一模一样
test_output="$(mktemp)"
trap 'rm -f "${test_output:?}"' EXIT
if cargo test --all 2>&1 | tee "$test_output"; then
  cargo_test_exit_code=0
else
  cargo_test_exit_code="${PIPESTATUS[0]}"
fi
[[ $cargo_test_exit_code -eq 0 ]] || die "单测失败（退出码 $cargo_test_exit_code）" \
  "上面列出了失败的用例名。单跑一个看细节：" \
  "cargo test --all <用例名> -- --nocapture" \
  "改代码还是改断言，先想清楚是哪一种——直接改断言等于把测试关掉。"
# 每个测试二进制（含文档测试）打一行 `test result: ok. <通过数> passed; <失败数> failed; …`，跑了的条数是各行 passed 与 failed 之和
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
