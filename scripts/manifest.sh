#!/usr/bin/env bash
# admission: always 判的是此刻规范文本与清单对不对得上，一秒跑完
# run-condition: command sha256sum
# 规则清单：给译文仓对账用的唯一接口。
# 译文各自成仓，生成时抄走这份清单，之后比两份清单就知道哪几篇过期了。
#
#   manifest.sh            校验清单是否与当前规范文本一致，并查覆盖率（门禁用）
#   manifest.sh --update   重新生成 MANIFEST.sha256（改了清单覆盖的任何一篇之后跑）
#
# 为什么 CLAUDE.md 也在清单里：它是规范正文，且规定了对话语言。
# 不进清单的话，改了它译本仓不会知道，各语言就会悄悄说不同的话。
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight "${BASH_SOURCE[0]}" "$@"; set -- ${PREFLIGHT_ARGUMENTS[@]+"${PREFLIGHT_ARGUMENTS[@]}"}

PACKAGE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST_FILE="$PACKAGE_ROOT/MANIFEST.sha256"
I18N_FILE="$PACKAGE_ROOT/I18N"

# 清单只在参照仓里生成与校验；别的语言仓的对账依据是 SOURCE-MANIFEST.sha256。
# `|| true`：I18N 不在时 sed 退 2，set -e 会当场把脚本带走、一个字都不打。
THIS_LANGUAGE="$(sed -n 's/^this=//p' "$I18N_FILE" 2>/dev/null || true)"
REFERENCE_LANGUAGE="$(sed -n 's/^reference=//p' "$I18N_FILE" 2>/dev/null || true)"
# 校验退 77（本仓没有清单可判）；--update 是动作不是判定：什么也不做、退 0，bump.sh 照常往下走。
if [[ -n "$THIS_LANGUAGE" && -n "$REFERENCE_LANGUAGE" && "$THIS_LANGUAGE" != "$REFERENCE_LANGUAGE" ]]; then
  head1 "规则清单"
  if [[ "${1:-}" == "--update" ]]; then
    ok "本仓是 $THIS_LANGUAGE 版，清单只在 $REFERENCE_LANGUAGE 仓生成，--update 什么也没做"
    exit 0
  fi
  warn "本仓是 $THIS_LANGUAGE 版，清单以 $REFERENCE_LANGUAGE 仓为准，本阶段无对象可判（这不是通过）"
  exit 77
fi

# ── 什么进清单，什么不进 ────────────────────────────────
# 判据只有一条：**里面有没有面向人的散文。** 有就翻译（进清单），没有就复制。
# 两张表都要显式列全，不列的由下面的覆盖率检查拦下。
#
# translated_paths：逐篇翻译、逐篇溯源。skills/ 与 templates/ 也在内：
#   templates/CLAUDE.project.md 会被 install.sh 写成使用者项目根的 CLAUDE.md。
# `|| true` 不能省：目录不存在时 find 退出码非 0，2>/dev/null 只藏消息不藏退出码，
# set -e + pipefail 下 `--update` 会退 1 而一个字都不打印。
translated_paths() {
  cd "$PACKAGE_ROOT" || return 1
  echo CLAUDE.md
  find rules      -maxdepth 1 -name '*.md'                    2>/dev/null || true
  find agents     -maxdepth 1 -name '*.md'                    2>/dev/null || true
  find skills     -maxdepth 2 -name '*.md'                    2>/dev/null || true
  find templates  -name '*.md'       2>/dev/null || true
}

# not_translated_re：显式豁免 + 理由。改这张表就是改分发策略，不许顺手加。
#   README.md      各语言仓各自的门面，只指路不定规矩（README 里写明了这一点）
#   CHANGELOG.md   历史文件，各仓记各仓的
#   GLOSSARY.md    各语言并列的**一张**对照表，翻译它等于每种语言各抄一份。
#                  它的说明列自带三语（zh<br>en<br>ja），少一段 doc-lint 判红——
#                  所以它不翻译也没有语言缺口
not_translated_re='^(README\.md|CHANGELOG\.md|GLOSSARY\.md)$'

# cd 要落在 generate_manifest 自己身上：translated_paths 在管道里跑，它的 cd 只在子 shell 里生效，
# 而 xargs sha256sum 在原来的当前目录里；从仓根跑时看不出来。
# 排序显式钉成 C：清单的行序是判据的一部分，locale 一换（lib.sh 那三个 UTF-8 名字都没有时会沿用用户的）
# 各语言仓与副本之间就凭空多出「清单不一致」「SOURCE-MANIFEST 落后」的假红。
generate_manifest() { cd "$PACKAGE_ROOT" && translated_paths | LC_ALL=C sort | xargs sha256sum; }

# 装进项目的副本（没有 .git）不带本仓的 CLAUDE.md（README「使用者」一节）：缺它不算没拷全，校验时两边都不比这一行
copy_left_out=""
if [[ ! -e "$PACKAGE_ROOT/.git" && ! -e "$PACKAGE_ROOT/CLAUDE.md" ]]; then copy_left_out="CLAUDE.md"; fi
generate_compared_manifest() { cd "$PACKAGE_ROOT" && translated_paths | awk -v left_out="$copy_left_out" '$0 != left_out' | LC_ALL=C sort | xargs sha256sum; }
compared_manifest() { awk -v left_out="$copy_left_out" '$2 != left_out' "$MANIFEST_FILE"; }

# ── 覆盖率：面向人的文本，两边都不沾就红 ────────────────
coverage() {
  local listed unassigned_texts
  # agents/ 空着要说出来：「没有」和「忘了」在目录里长得一模一样。
  if [[ -d "$PACKAGE_ROOT/agents" ]]; then
    local agent_definition_count; agent_definition_count="$(find "$PACKAGE_ROOT/agents" -maxdepth 1 -name '*.md' -not -name 'INDEX.md' | wc -l)"
    [[ "$agent_definition_count" -eq 0 ]] && warn "本层已纳入治理，当前为空：agents/（约定见 agents/INDEX.md）"
  fi
  listed="$(translated_paths | LC_ALL=C sort -u)"
  unassigned_texts="$(cd "$PACKAGE_ROOT" && find . -name '*.md' \
              | sed 's|^\./||' \
              | grep -v '^scripts/fixtures/' \
              | grep -vE "$not_translated_re" \
              | LC_ALL=C sort -u \
              | comm -23 - <(printf '%s\n' "$listed" | LC_ALL=C sort -u))"
  [[ -z "$unassigned_texts" ]] && return 0
  bad "有面向人的文本既没进清单、也没显式豁免："
  printf '%s\n' "$unassigned_texts" | sed 's/^/        /'
  howto "每一份都要有个归属，二选一（判据：里面有没有面向人的散文）：" \
        "有 → 加进 scripts/manifest.sh 的 translated_paths，跑 --update，然后翻译它" \
        "没有 → 加进 not_translated_re **并在旁边写明理由**" \
        "不许放着不管：放着就等于让用别的语言的人拿到一份他读不懂的东西。"
  return 1
}

if [[ "${1:-}" == "--update" ]]; then
  head1 "更新规则清单"
  generate_manifest > "$MANIFEST_FILE"
  ok "$MANIFEST_FILE  $(wc -l < "$MANIFEST_FILE") 条"
  say "        译文仓下次生成时抄走它，对账就靠这份。"
  exit 0
fi

head1 "规则清单"
[[ -f "$MANIFEST_FILE" ]] || { bad "缺 MANIFEST.sha256"
  howto "跑： bash scripts/manifest.sh --update"; exit 1; }

coverage_failed=0; coverage || coverage_failed=1

if [[ $coverage_failed -eq 0 ]] && diff <(generate_compared_manifest) <(compared_manifest) >/dev/null 2>&1; then
  compared_count="$(compared_manifest | grep -c .)"
  if [[ -n "$copy_left_out" ]]; then
    ok "清单与规范文本一致（比了 $compared_count 条；没比 1 条：$copy_left_out，副本不带它），且没有漏归属的文本"
  else
    ok "清单与规范文本一致（$compared_count 条），且没有漏归属的文本"
  fi
  exit 0
fi
[[ $coverage_failed -eq 0 ]] || exit 1

bad "MANIFEST.sha256 与规范文本不一致"
# || true 不能省：diff 有差异时退出码 1 + pipefail 会把脚本在这里带走，下面的 howto 打不出来
diff <(generate_compared_manifest) <(compared_manifest) | grep -E '^[<>]' | sed 's/^/        /' | head -20 || true
howto "改了规范正文或规则就要更新清单，否则各语言译文无从知道自己过期了：" \
      "bash scripts/manifest.sh --update" \
      "" \
      "清单不是装饰——它是译文仓唯一的对账依据。清单停滞 =" \
      "所有译文都显示「最新」，而它们其实已经过期。"
exit 1
