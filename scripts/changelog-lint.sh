#!/usr/bin/env bash
# CHANGELOG 连续性：每一版都有自己的一节，最新一节就是 VERSION。
#
# 版本纪律（version-discipline.sh）只管「改了规范本体就抬 VERSION」，不管 CHANGELOG 跟没跟上。
# 实测（0.0.39）：VERSION 从 0.0.35 抬到 0.0.39，CHANGELOG 只写了 0.0.37–0.0.39，
# 0.0.36 的两处规则改动没有任何一节记着——zh / en / ja 三仓一起跳号，全部门禁照绿，
# 是逐段对 diff 才看出来的。
#
#   changelog-lint.sh <SOP 仓根>
#
# 判的是**整份文件**，不是 diff 窗口：历史本来就连续，不用去猜「上次抬到了哪」。查四条：
#   1. 二级标题只许是版本节 `## x.y.z — YYYY-MM-DD`；最后一节可以是不带日期的收尾
#      （「0.0.21 及更早」——各语言仓措辞不同，所以只认「版本号后面跟着别的字、没有日期」）
#   2. 最新一节 = VERSION
#   3. 相邻两节是紧后一版，不许跳号、重复、倒序
#   4. 一节都没有不算通过
#
# 只对 SOP 仓本身有意义（gate.sh 在 ROOT 是 SOP 仓时才调它），各语言仓各判各的 CHANGELOG。
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="${1:-$(project_root)}"
[[ -d "$ROOT" ]] || die "找不到仓根：$ROOT" \
  "把 SOP 仓根作为第一个参数传进来： bash scripts/changelog-lint.sh <仓根>"
CL="$ROOT/CHANGELOG.md"

[[ -n "${GATE_IN_STAGE:-}" ]] || head1 "CHANGELOG 连续"

[[ -f "$CL" ]] || die "缺 CHANGELOG.md（$CL）" \
  "每次抬 VERSION，都在 CHANGELOG.md 顶部给这一版写一节 ## x.y.z — YYYY-MM-DD，说清改了什么。"
ver=""
[[ -f "$ROOT/VERSION" ]] && ver="$(tr -d '[:space:]' < "$ROOT/VERSION")"
[[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "VERSION 读不出 x.y.z（读到「${ver:-空}」）" \
  "用 bash scripts/bump.sh <x.y.z> 写 VERSION，不要手改。"

newer_than() { # newer_than <甲> <乙> → 甲比乙新则返回 0
  [[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" == "$1" ]]
}

successor_of() { # successor_of <旧> <新> → 新是旧的紧后一版则返回 0
  local o1 o2 o3 n1 n2 n3
  IFS=. read -r o1 o2 o3 <<< "$1"
  IFS=. read -r n1 n2 n3 <<< "$2"
  # 三种紧后逐条写全，不写通用路径
  if ((10#$n1 == 10#$o1 && 10#$n2 == 10#$o2 && 10#$n3 == 10#$o3 + 1)); then return 0; fi  # 补丁 +1
  if ((10#$n1 == 10#$o1 && 10#$n2 == 10#$o2 + 1 && 10#$n3 == 0)); then return 0; fi        # 次版本 +1，补丁归 0
  if ((10#$n1 == 10#$o1 + 1 && 10#$n2 == 0 && 10#$n3 == 0)); then return 0; fi             # 主版本 +1，其余归 0
  return 1
}

# 缺版本的消息要报**几版、哪几版**，而且只报列得全的：跨了主/次版本时中间有哪些版本
# 推不出来，照实说列不全，不报一个错的数（rules/verify-before-claiming.md：说出口的不许比核过的宽）。
between() { # between <旧> <新> → 打印严格夹在中间的版本（空格分隔）；列不全时返回 1
  local o1 o2 o3 n1 n2 n3 k
  IFS=. read -r o1 o2 o3 <<< "$1"
  IFS=. read -r n1 n2 n3 <<< "$2"
  if successor_of "$1" "$2"; then return 0; fi
  if ((10#$o1 != 10#$n1 || 10#$o2 != 10#$n2)); then return 1; fi
  for ((k = 10#$o3 + 1; k < 10#$n3; k++)); do printf '%s.%s.%s ' "$n1" "$n2" "$k"; done
}

check_pair() { # check_pair <上一节版本> <它的行号> <这一节版本> <它的行号> → 合规则返回 0
  local newer="$1" newer_ln="$2" older="$3" older_ln="$4" mid suffix
  if [[ "$newer" == "$older" ]]; then
    bad "CHANGELOG.md:$older_ln  $older 有两节（另一节在第 $newer_ln 行）"
    howto "一个版本只写一节：把两节内容合进一节，删掉多出来的那个标题。"
    return 1
  fi
  if newer_than "$older" "$newer"; then
    bad "CHANGELOG.md:$newer_ln  顺序反了：$newer 写在了 $older 上面"
    howto "新版本在上、旧版本在下，把这两节对调。"
    return 1
  fi
  if successor_of "$older" "$newer"; then return 0; fi
  if mid="$(between "$older" "$newer")"; then suffix="，缺 $(wc -w <<< "$mid") 版：${mid% }"
  else suffix="（跨了主/次版本，中间缺哪几版列不全）"; fi
  bad "CHANGELOG.md:$newer_ln  跳号：$older 之后直接到了 $newer$suffix"
  howto "每一版都要有自己的一节——跳过去的那一版，改了什么就没有任何地方记着。" \
        "补上 ## x.y.z — YYYY-MM-DD；日期取那一版实际改动的日子，拿不准就在正文里写明是推的。"
  return 1
}

# 每个二级标题一行：<行号> <类别> <版本>。围栏代码块里的 ## 不是标题。
# 类别：dated 正式版本节 / tail 不带日期的收尾 / malformed 带版本号但格式不对 / other 不是版本节
mapfile -t HEADS < <(awk '
  /^```/ { fence = !fence; next }
  fence || !/^## / { next }
  !match($0, /^## ([0-9]+\.[0-9]+\.[0-9]+)/, m) { print NR, "other", "-"; next }
  /^## [0-9]+\.[0-9]+\.[0-9]+ — [0-9]{4}-[0-9]{2}-[0-9]{2}$/ { print NR, "dated", m[1]; next }
  /[0-9]{4}-[0-9]{2}-[0-9]{2}/ || /^## [0-9.]+[[:space:]]*—/ { print NR, "malformed", m[1]; next }
  /^## [0-9]+\.[0-9]+\.[0-9]+[[:space:]]+[^[:space:]]/ { print NR, "tail", m[1]; next }
  { print NR, "malformed", m[1] }
' "$CL")

fails=0; n=0; top=""; top_ln=""; prev=""; prev_ln=""
last=$(( ${#HEADS[@]} - 1 ))
for idx in "${!HEADS[@]}"; do
  read -r ln kind v <<< "${HEADS[$idx]}"
  case "$kind" in
    dated) ;;
    tail)
      if [[ $idx -ne $last ]]; then
        bad "CHANGELOG.md:$ln  不带日期的收尾节只许是最后一节：$(sed -n "${ln}p" "$CL")"
        howto "中间的版本节要写成 ## $v — YYYY-MM-DD；「x.y.z 及更早」这种收尾只放在文件末尾。"
        fails=$((fails+1))
      fi ;;
    malformed)
      bad "CHANGELOG.md:$ln  版本节标题格式不对：$(sed -n "${ln}p" "$CL")"
      howto "写成 ## x.y.z — YYYY-MM-DD：中间是破折号 —，前后各一个空格，日期后面不跟别的字。"
      fails=$((fails+1)) ;;
    other)
      bad "CHANGELOG.md:$ln  二级标题不是版本节：$(sed -n "${ln}p" "$CL")"
      howto "CHANGELOG 的 ## 只留给版本节，本检查靠它数版本。" \
            "说明文字放在第一节版本之前；版本节里要分小节就用 ###。"
      fails=$((fails+1))
      continue ;;
    *)
      die "changelog-lint 内部错误：不认识的标题类别「$kind」" \
          "这是本脚本自己的缺陷：awk 那段加了类别，这里的 case 没跟上。" ;;
  esac
  n=$((n+1))
  if [[ -z "$prev" ]]; then
    top="$v"; top_ln="$ln"
  elif ! check_pair "$prev" "$prev_ln" "$v" "$ln"; then
    fails=$((fails+1))
  fi
  prev="$v"; prev_ln="$ln"
done

if [[ $n -eq 0 ]]; then
  bad "CHANGELOG.md 里一节版本记录都没有"
  howto "每一版在顶部写一节 ## x.y.z — YYYY-MM-DD。一节都没有时这项检查什么也没查，不算通过。"
  fails=$((fails+1))
elif [[ "$top" != "$ver" ]]; then
  if newer_than "$ver" "$top"; then
    if mid="$(between "$top" "$ver")"; then
      bad "VERSION 是 $ver，CHANGELOG 最新一节还停在 $top（第 $top_ln 行）：缺 $(( $(wc -w <<< "$mid") + 1 )) 版：${mid}$ver"
    else
      bad "VERSION 是 $ver，CHANGELOG 最新一节还停在 $top（第 $top_ln 行）：至少缺 $ver（跨了主/次版本，中间缺哪几版列不全）"
    fi
    howto "在 CHANGELOG.md 顶部给缺的每一版补一节 ## x.y.z — YYYY-MM-DD，写清那一版改了什么。" \
          "抬了 VERSION 却不写，项目那边看得到「规矩变了」，却查不到变了什么。"
  else
    bad "CHANGELOG 最新一节是 $top（第 $top_ln 行），比 VERSION（$ver）还新"
    howto "要么这一版忘了抬 VERSION： bash scripts/bump.sh $top" \
          "要么那一节写早了：先拿掉，等真正抬版本时再写。"
  fi
  fails=$((fails+1))
fi

say ""
if [[ $fails -gt 0 ]]; then
  bad "CHANGELOG 连续性检查失败：$fails 处（共 $n 个版本节）"   # gate-lint:summary
  exit 1
fi
ok "CHANGELOG 连续：$n 个版本节，最新一节 $top 与 VERSION 一致，相邻两节都是紧后一版"
