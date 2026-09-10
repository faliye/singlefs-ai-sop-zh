#!/usr/bin/env bash
# 快速本地检查：格式 / lint / 构建 / 单测。
# 这是快速反馈，**不是准入标准**。准入标准见 gate.sh。
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="${1:-$(project_root)}"
cd "$ROOT"

command -v cargo >/dev/null 2>&1 || die "cargo 缺失" \
  "装 Rust 工具链：" \
  "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
[[ -f Cargo.toml ]] || die "$ROOT 下没有 Cargo.toml" \
  "本脚本只做 Rust 项目的快速反馈。确认你在项目根，或先建 workspace 的 Cargo.toml。"

head1 "cargo fmt --check"
cargo fmt --all -- --check || die "格式不合规" \
  "跑 cargo fmt --all 让它自己改完，再重跑本脚本。"
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
cargo clippy --all-targets --all-features -- -D warnings "${CODE_DISCIPLINE_LINTS[@]}" \
  || die "clippy 有告警（按 -D warnings 视为错误），或者踩了编码纪律的某一条" \
  "上面每条告警都指着文件和行号，逐条改。编码纪律那几条的写法见 rules/code-discipline.md。" \
  "确有必要保留的，在那一处写 #[allow(<lint>, reason = \"为什么\")]，理由写进 reason——" \
  "不要整仓关掉 -D warnings（rules/command-safety.md：警告是最便宜的信号）。"
ok "clippy 通过"

head1 "cargo build"
cargo build --all-targets || die "构建失败" \
  "上面是 rustc 的报错，从第一条改起——后面的多半是它的连锁反应。"
ok "构建通过"

head1 "cargo test"
cargo test --all || die "单测失败" \
  "上面列出了失败的用例名。单跑一个看细节：" \
  "cargo test --all <用例名> -- --nocapture" \
  "改代码还是改断言，先想清楚是哪一种——直接改断言等于把测试关掉。"
ok "单测通过"
