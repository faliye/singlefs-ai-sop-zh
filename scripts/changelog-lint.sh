#!/usr/bin/env bash
# admission: always 判的是此刻 CHANGELOG 与 VERSION 对不对得上，一秒跑完；每一轮门禁都现判
# run-condition: command git gawk
# CHANGELOG 连续性：每一版都有自己的一节，最新一节就是 VERSION。
#
# version-discipline.sh 只管抬没抬 VERSION，不管 CHANGELOG 跟没跟上（实测过三仓一起跳号、全部门禁照绿）。
#
#   changelog-lint.sh <SOP 仓根>
#
# 判整份文件，不是 diff 窗口：历史本来就连续，不用猜「上次抬到了哪」。查五条：
#   1. 二级标题只许是版本节 `## x.y.z — YYYY-MM-DD`；最后一节可以是不带日期的收尾
#      （「0.0.21 及更早」——各语言仓措辞不同，所以只认「版本号后面跟着别的字、没有日期」）
#   2. 最新一节 = VERSION
#   3. 相邻两节是紧后一版，不许跳号、重复、倒序
#   4. 一节都没有不算通过
#   5. 版本节的日期不许是编的：早于本仓第一个提交出宽限、或晚于最晚时区的今天，判红（lib.sh 的 date_out_of_range）
#
# 只对 SOP 仓本身有意义（gate.sh 只在被判的仓是 SOP 仓时才调它），各语言仓各判各的 CHANGELOG。
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight "${BASH_SOURCE[0]}" "$@"; set -- ${PREFLIGHT_ARGUMENTS[@]+"${PREFLIGHT_ARGUMENTS[@]}"}

REPOSITORY_ROOT="${1:-$(project_root)}"
[[ -d "$REPOSITORY_ROOT" ]] || die "找不到仓根：$REPOSITORY_ROOT" \
  "把 SOP 仓根作为第一个参数传进来： bash scripts/changelog-lint.sh <仓根>"
CHANGELOG_FILE="$REPOSITORY_ROOT/CHANGELOG.md"

[[ -n "${GATE_IN_STAGE:-}" ]] || head1 "CHANGELOG 连续"

[[ -f "$CHANGELOG_FILE" ]] || die "缺 CHANGELOG.md（$CHANGELOG_FILE）" \
  "每次抬 VERSION，都在 CHANGELOG.md 顶部给这一版写一节 ## x.y.z — YYYY-MM-DD，说清改了什么。"
current_version=""
[[ -f "$REPOSITORY_ROOT/VERSION" ]] && current_version="$(tr -d '[:space:]' < "$REPOSITORY_ROOT/VERSION")"
[[ "$current_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "VERSION 读不出 x.y.z（读到「${current_version:-空}」）" \
  "用 bash scripts/bump.sh <x.y.z> 写 VERSION，不要手改。"

newer_than() { # newer_than <候选版本> <对照版本> → 候选版本比对照版本新则返回 0
  [[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" == "$1" ]]
}

successor_of() { # successor_of <旧> <新> → 新是旧的紧后一版则返回 0
  local older_major older_minor older_patch newer_major newer_minor newer_patch
  IFS=. read -r older_major older_minor older_patch <<< "$1"
  IFS=. read -r newer_major newer_minor newer_patch <<< "$2"
  # 三种紧后逐条写全，不写通用路径
  if ((10#$newer_major == 10#$older_major && 10#$newer_minor == 10#$older_minor && 10#$newer_patch == 10#$older_patch + 1)); then return 0; fi  # 补丁 +1
  if ((10#$newer_major == 10#$older_major && 10#$newer_minor == 10#$older_minor + 1 && 10#$newer_patch == 0)); then return 0; fi        # 次版本 +1，补丁归 0
  if ((10#$newer_major == 10#$older_major + 1 && 10#$newer_minor == 0 && 10#$newer_patch == 0)); then return 0; fi             # 主版本 +1，其余归 0
  return 1
}

# 缺版本只报列得全的：跨了主/次版本时中间有哪些版本推不出来，照实说列不全，不报一个错的数。
between() { # between <旧> <新> → 打印严格夹在中间的版本（空格分隔）；列不全时返回 1
  local older_major older_minor older_patch newer_major newer_minor newer_patch patch_number
  IFS=. read -r older_major older_minor older_patch <<< "$1"
  IFS=. read -r newer_major newer_minor newer_patch <<< "$2"
  if successor_of "$1" "$2"; then return 0; fi
  if ((10#$older_major != 10#$newer_major || 10#$older_minor != 10#$newer_minor)); then return 1; fi
  for ((patch_number = 10#$older_patch + 1; patch_number < 10#$newer_patch; patch_number++)); do printf '%s.%s.%s ' "$newer_major" "$newer_minor" "$patch_number"; done
}

check_pair() { # check_pair <上一节版本> <它的行号> <这一节版本> <它的行号> → 合规则返回 0
  local newer="$1" newer_line_number="$2" older="$3" older_line_number="$4" missing_versions suffix
  if [[ "$newer" == "$older" ]]; then
    bad "CHANGELOG.md:$older_line_number  $older 有两节（另一节在第 $newer_line_number 行）"
    howto "一个版本只写一节：把两节内容合进一节，删掉多出来的那个标题。"
    return 1
  fi
  if newer_than "$older" "$newer"; then
    bad "CHANGELOG.md:$newer_line_number  顺序反了：$newer 写在了 $older 上面"
    howto "新版本在上、旧版本在下，把这两节对调。"
    return 1
  fi
  if successor_of "$older" "$newer"; then return 0; fi
  if missing_versions="$(between "$older" "$newer")"; then suffix="，缺 $(wc -w <<< "$missing_versions") 版：${missing_versions% }"
  else suffix="（跨了主/次版本，中间缺哪几版列不全）"; fi
  bad "CHANGELOG.md:$newer_line_number  跳号：$older 之后直接到了 $newer$suffix"
  howto "每一版都要有自己的一节——跳过去的那一版，改了什么就没有任何地方记着。" \
        "补上 ## x.y.z — YYYY-MM-DD；日期取那一版实际改动的日子，拿不准就在正文里写明是推的。"
  return 1
}

# 每个二级标题一行：<行号> <类别> <版本>。围栏代码块里的 ## 不是标题。
# 类别：dated 正式版本节 / tail 不带日期的收尾 / malformed 带版本号但格式不对 / other 不是版本节
mapfile -t HEADING_RECORDS < <(awk '
  /^```/ { fence = !fence; next }
  fence || !/^## / { next }
  !match($0, /^## ([0-9]+\.[0-9]+\.[0-9]+)/, version_match) { print NR, "other", "-"; next }
  /^## [0-9]+\.[0-9]+\.[0-9]+ — [0-9]{4}-[0-9]{2}-[0-9]{2}$/ { print NR, "dated", version_match[1]; next }
  /[0-9]{4}-[0-9]{2}-[0-9]{2}/ || /^## [0-9.]+[[:space:]]*—/ { print NR, "malformed", version_match[1]; next }
  /^## [0-9]+\.[0-9]+\.[0-9]+[[:space:]]+[^[:space:]]/ { print NR, "tail", version_match[1]; next }
  { print NR, "malformed", version_match[1] }
' "$CHANGELOG_FILE")

failure_count=0; version_section_count=0; newest_version=""; newest_line_number=""; previous_version=""; previous_line_number=""
# 日期的下界：这个仓第一个提交往前宽限几天。
CHANGELOG_START_DATE="$(project_start_date "$(dirname "$CHANGELOG_FILE")")"; CHANGELOG_START_DATE="${CHANGELOG_START_DATE:-$SOP_START_DATE}"
require_date_arithmetic
last_heading_index=$(( ${#HEADING_RECORDS[@]} - 1 ))
for heading_index in "${!HEADING_RECORDS[@]}"; do
  read -r line_number heading_kind section_version <<< "${HEADING_RECORDS[$heading_index]}"
  case "$heading_kind" in
    dated)
      # 判据在 lib.sh 的 date_out_of_range 一处，doc-lint 用同一个。
      section_date="$(sed -n "${line_number}p" "$CHANGELOG_FILE" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' || true)"
      section_date="${section_date%%$'\n'*}"
      if [[ -n "$section_date" ]] && section_date_reason="$(date_out_of_range "$section_date" "$CHANGELOG_START_DATE")"; then
        bad "CHANGELOG.md:$line_number  这一节的日期 $section_date 不可能：$section_date_reason"
        howto "写那一版实际改动的那一天。不知道是哪天就去查（git log 那几个提交），别填占位日期——" \
              "占位日期读起来和真日期一模一样，而后面每一个引用它的人都会当真。"
        failure_count=$((failure_count+1))
      fi ;;
    tail)
      if [[ $heading_index -ne $last_heading_index ]]; then
        bad "CHANGELOG.md:$line_number  不带日期的收尾节只许是最后一节：$(sed -n "${line_number}p" "$CHANGELOG_FILE")"
        howto "中间的版本节要写成 ## $section_version — YYYY-MM-DD；「x.y.z 及更早」这种收尾只放在文件末尾。"
        failure_count=$((failure_count+1))
      fi ;;
    malformed)
      bad "CHANGELOG.md:$line_number  版本节标题格式不对：$(sed -n "${line_number}p" "$CHANGELOG_FILE")"
      howto "写成 ## x.y.z — YYYY-MM-DD：中间是破折号 —，前后各一个空格，日期后面不跟别的字。"
      failure_count=$((failure_count+1)) ;;
    other)
      bad "CHANGELOG.md:$line_number  二级标题不是版本节：$(sed -n "${line_number}p" "$CHANGELOG_FILE")"
      howto "CHANGELOG 的 ## 只留给版本节，本检查靠它数版本。" \
            "说明文字放在第一节版本之前；版本节里要分小节就用 ###。"
      failure_count=$((failure_count+1))
      continue ;;
    *)
      die "changelog-lint 内部错误：不认识的标题类别「$heading_kind」" \
          "这是本脚本自己的缺陷：awk 那段加了类别，这里的 case 没跟上。" ;;
  esac
  version_section_count=$((version_section_count+1))
  if [[ -z "$previous_version" ]]; then
    newest_version="$section_version"; newest_line_number="$line_number"
  elif ! check_pair "$previous_version" "$previous_line_number" "$section_version" "$line_number"; then
    failure_count=$((failure_count+1))
  fi
  previous_version="$section_version"; previous_line_number="$line_number"
done

if [[ $version_section_count -eq 0 ]]; then
  bad "CHANGELOG.md 里一节版本记录都没有"
  howto "每一版在顶部写一节 ## x.y.z — YYYY-MM-DD。一节都没有时这项检查什么也没查，不算通过。"
  failure_count=$((failure_count+1))
elif [[ "$newest_version" != "$current_version" ]]; then
  if newer_than "$current_version" "$newest_version"; then
    if missing_versions="$(between "$newest_version" "$current_version")"; then
      bad "VERSION 是 $current_version，CHANGELOG 最新一节还停在 $newest_version（第 $newest_line_number 行）：缺 $(( $(wc -w <<< "$missing_versions") + 1 )) 版：${missing_versions}$current_version"
    else
      bad "VERSION 是 $current_version，CHANGELOG 最新一节还停在 $newest_version（第 $newest_line_number 行）：至少缺 $current_version（跨了主/次版本，中间缺哪几版列不全）"
    fi
    howto "在 CHANGELOG.md 顶部给缺的每一版补一节 ## x.y.z — YYYY-MM-DD，写清那一版改了什么。" \
          "抬了 VERSION 却不写，项目那边看得到「规矩变了」，却查不到变了什么。"
  else
    bad "CHANGELOG 最新一节是 $newest_version（第 $newest_line_number 行），比 VERSION（$current_version）还新"
    howto "要么这一版忘了抬 VERSION： bash scripts/bump.sh $newest_version" \
          "要么那一节写早了：先拿掉，等真正抬版本时再写。"
  fi
  failure_count=$((failure_count+1))
fi

say ""
if [[ $failure_count -gt 0 ]]; then
  bad "CHANGELOG 连续性检查失败：$failure_count 处（共 $version_section_count 个版本节）"   # gate-lint:summary
  exit 1
fi
ok "CHANGELOG 连续：$version_section_count 个版本节，最新一节 $newest_version 与 VERSION 一致，相邻两节都是紧后一版"
