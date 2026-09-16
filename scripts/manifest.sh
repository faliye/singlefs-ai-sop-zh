#!/usr/bin/env bash
# 规则清单：给译文仓对账用的唯一接口。
#
#   manifest.sh            校验清单是否与当前规范文本一致，并查覆盖率（门禁用）
#   manifest.sh --update   重新生成 MANIFEST.sha256（改了清单覆盖的任何一篇之后跑）
#
# 为什么 CLAUDE.md 也在清单里：它是规范正文，且规定了对话语言。
# 不进清单的话，改了它译本仓不会知道，各语言就会悄悄说不同的话。
#
# 为什么要有它：译文不放在本仓（那会让 SOP 随语言数线性膨胀）。
# 译文各自成仓，生成时抄走这份清单；之后只要比两份清单就知道哪几篇过期了。
# 本仓因此只多一个小文件，仍然是单语言、薄的。
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PKG="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MF="$PKG/MANIFEST.sha256"
CF="$PKG/I18N"

# 清单只在参照仓里生成与校验。别的语言仓拿到的是原样复制的脚本，
# 它们那边的对账依据是 SOURCE-MANIFEST.sha256，不是这份。
# `|| true`：I18N 不在时 sed 退 2，set -e 会当场把脚本带走、一个字都不打（审核实测）。
THIS="$(sed -n 's/^this=//p' "$CF" 2>/dev/null || true)"
REF="$(sed -n 's/^reference=//p' "$CF" 2>/dev/null || true)"
if [[ -n "$THIS" && -n "$REF" && "$THIS" != "$REF" ]]; then
  head1 "规则清单"
  ok "本仓是 $THIS 版，清单以 $REF 仓为准，本阶段不适用"
  exit 0
fi

# ── 什么进清单，什么不进 ────────────────────────────────
# 判据只有一条：**里面有没有面向人的散文。** 有就翻译（进清单），没有就复制。
# 两张表都要显式列全——不列的那些由下面的覆盖率检查拦下，「忘了纳入」不许静默通过。
#
# TRANSLATED：逐篇翻译、逐篇溯源。
#   skills/ 与 templates/ 曾经走复制，于是日语仓的 skill 正文与项目骨架全是中文，
#   而 templates/CLAUDE.project.md 会被 install.sh 写成使用者项目根的 CLAUDE.md。
# `|| true` 不能省：目录不存在时 find 退出码非 0，而 2>/dev/null 只藏消息不藏退出码——
# 在 set -e + pipefail 下整条 gen 会被带走，`--update` 退出码 1 而**一个字都不打印**
# （selftest 拿一个没有 agents/ 的样本仓喂进来才露出来）。
translated_paths() {
  cd "$PKG" || return 1
  echo CLAUDE.md
  find rules      -maxdepth 1 -name '*.md'                    2>/dev/null || true
  find agents     -maxdepth 1 -name '*.md'                    2>/dev/null || true
  find skills     -maxdepth 2 -name '*.md'                    2>/dev/null || true
  find templates  -name '*.md'       2>/dev/null || true
}

# NOT_TRANSLATED：显式豁免 + 理由。改这张表就是改分发策略，不许顺手加。
#   README.md      各语言仓各自的门面，只指路不定规矩（README 里写明了这一点）
#   CHANGELOG.md   历史文件，各仓记各仓的
#   GLOSSARY.md    各语言并列的**一张**对照表，翻译它等于抄成 N 份。
#                  它的说明列自带三语（zh<br>en<br>ja），少一段 doc-lint 判红——
#                  所以它不翻译也没有语言缺口
not_translated_re='^(README\.md|CHANGELOG\.md|GLOSSARY\.md)$'

# cd 要落在 gen 自己身上：translated_paths 在管道里跑，它的 cd 只在子 shell 里生效，
# 而 xargs sha256sum 在原来的 cwd 里。从仓根跑时 cwd 恰好就是 PKG，所以看不出来——
# selftest 拿样本仓一喂就露了（rules/command-safety.md：子 shell 里的赋值传不回父进程）。
# 排序显式钉成 C：清单的行序就是判据的一部分，locale 一换（lib.sh 那三个 UTF-8 名字都没有时会沿用用户的）
# 行序就变，各语言仓与副本之间凭空多出「清单不一致」「SOURCE-MANIFEST 落后」的假红。
gen() { cd "$PKG" && translated_paths | LC_ALL=C sort | xargs sha256sum; }

# ── 覆盖率：面向人的文本，两边都不沾就红 ────────────────
# 这条是「空缺」的可机检形态：新加一份 .md 而忘了决定它翻不翻译，
# 门禁当场问你要一个答案，而不是让它悄悄留在共享区里说中文。
coverage() {
  local listed missed
  # agents/ 已纳入治理但可能还没有内容。空是**状态**，不是通过——
  # 「没有」和「忘了」在目录里长得一模一样（rules/kb-discipline.md：空白比错误更危险）。
  if [[ -d "$PKG/agents" ]]; then
    local n; n="$(find "$PKG/agents" -maxdepth 1 -name '*.md' -not -name 'INDEX.md' | wc -l)"
    [[ "$n" -eq 0 ]] && warn "本层已纳入治理，当前为空：agents/（约定见 agents/INDEX.md）"
  fi
  listed="$(translated_paths | LC_ALL=C sort -u)"
  missed="$(cd "$PKG" && find . -name '*.md' \
              | sed 's|^\./||' \
              | grep -v '^scripts/fixtures/' \
              | grep -vE "$not_translated_re" \
              | LC_ALL=C sort -u \
              | comm -23 - <(printf '%s\n' "$listed" | LC_ALL=C sort -u))"
  [[ -z "$missed" ]] && return 0
  bad "有面向人的文本既没进清单、也没显式豁免："
  printf '%s\n' "$missed" | sed 's/^/        /'
  howto "每一份都要有个归属，二选一（判据：里面有没有面向人的散文）：" \
        "有 → 加进 scripts/manifest.sh 的 translated_paths，跑 --update，然后翻译它" \
        "没有 → 加进 not_translated_re **并在旁边写明理由**" \
        "不许放着不管：放着就等于让用别的语言的人拿到一份他读不懂的东西。"
  return 1
}

if [[ "${1:-}" == "--update" ]]; then
  head1 "更新规则清单"
  gen > "$MF"
  ok "$MF  $(wc -l < "$MF") 条"
  say "        译文仓下次生成时抄走它，对账就靠这份。"
  exit 0
fi

head1 "规则清单"
[[ -f "$MF" ]] || { bad "缺 MANIFEST.sha256"
  howto "跑： bash scripts/manifest.sh --update"; exit 1; }

cov=0; coverage || cov=1

if [[ $cov -eq 0 ]] && diff <(gen) "$MF" >/dev/null 2>&1; then
  ok "清单与规范文本一致（$(wc -l < "$MF") 条），且没有漏归属的文本"
  exit 0
fi
[[ $cov -eq 0 ]] || exit 1

bad "MANIFEST.sha256 与规范文本不一致"
# || true 不能省：diff 有差异时退出码 1 + pipefail 会把脚本在这里带走，
# 下面的 howto 打不出来（对抗测试实测，崩在真实数据上）
diff <(gen) "$MF" | grep -E '^[<>]' | sed 's/^/        /' | head -20 || true
howto "改了规范正文或规则就要更新清单，否则各语言译文无从知道自己过期了：" \
      "bash scripts/manifest.sh --update" \
      "" \
      "清单不是装饰——它是译文仓唯一的对账依据。清单停滞 =" \
      "所有译文都显示「最新」，而它们其实已经过期。"
exit 1
