#!/usr/bin/env bash
# 各语言文本必须同步：改了任何一份，声明的每种语言都要跟上。
# this 标明本仓是哪种语言；reference 标明参照仓——清单与门禁脚本在那一份里维护，
# 其余语言的仓拿到的是它的原样复制。default 是给使用者的默认版本。
#
#   i18n-sync.sh [各语言仓所在目录]        默认找本仓的兄弟目录
#   i18n-sync.sh --update [目录]           把共享部分原样复制到各语言仓；逐篇溯源都对上的译本仓，
#                                          顺手把本仓 MANIFEST.sha256 抄成它的 SOURCE-MANIFEST.sha256
#   i18n-sync.sh --stamp <语言> <篇>...    给已重译好的那几篇盖上溯源标记
#
# --stamp 要求把篇目一个个写出来，不提供「全部盖章」。
# 说清楚它的边界：一个 for 循环照样能把所有篇目刷绿（对抗测试实测），
# 盖章本质上是盖的人的承诺，这里只抬高「顺手全刷」的成本、并逼你把篇目名打一遍。
# 机器管不了「真的重译了没」——所以盖完的 warn 不是客套，是这道检查的全部余量。
#
# 检查什么：对 LANGUAGES 里声明的每种语言，
#   1. 那个语言的仓在不在  —— 不在则「无法检查」，按失败处理，不静默放过
#   2. 它抄走的清单是不是当前清单
#   3. 共享部分（install.sh、scripts/、GLOSSARY.md）与本仓逐字节一致
#   4. 清单里每一篇在那个仓里有没有对应文件
#   5. 每一篇译文首行的 generated-from 哈希是不是当前源文 —— 只比清单会漏掉
#      「抄了清单却没重译」：门禁绿，而用那种语言的人拿到的是旧规则
#
# 共享部分为什么要复制而不是只放一份：项目安装时只 clone 自己那一种语言的仓，
# 那个仓里没有门禁脚本就等于装不了。复制是**生成**的，不是手抄的——
# 手抄的重复会分叉，生成的不会（rules/machine-first.md）。
#
# 什么该进共享、什么该进清单，判据只有一条：**里面有没有面向人的散文**。
# 有就翻译（进清单），没有就复制（进 SHARED）。谁都不沾的文本文件由
# scripts/manifest.sh 的覆盖率检查拦下——「忘了纳入」不许静默通过。
#
# 判据（按 kb-discipline「矛盾比空白更糟」定，但对已声明的语言收紧）：
#   已声明的语言缺文件或落后 —— 都失败。声明了却不跟，等于给人一份过期的规则。
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PKG="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPDATE=0
STAMP_LANG=""
STAMP_FILES=()
if [[ "${1:-}" == "--stamp" ]]; then
  shift
  STAMP_LANG="${1:-}"; shift || true
  STAMP_FILES=("$@")
  set --
elif [[ "${1:-}" == "--update" ]]; then
  UPDATE=1; shift
fi
ROOT="${1:-$(dirname "$PKG")}"
MF="$PKG/MANIFEST.sha256"
CF="$PKG/I18N"

# 溯源标记不能一律拍在第 1 行，也不能一律用 HTML 注释：
#   - SKILL.md 的 YAML frontmatter 必须从第 1 行开始，插到它前面 skill 当场装不上
#   - .litmus 不认 <!-- -->，herd7 会语法报错
# 所以位置与包裹形式都按文件类型定。判据落在这两个函数上，别处不许再写一份。
stamp_wrap() { # stamp_wrap <路径> <内容> → 带注释包裹的整行
  case "$1" in
    *.litmus) printf '(* %s *)' "$2" ;;
    *)        printf '<!-- %s -->' "$2" ;;
  esac
}
stamp_re() { # stamp_re <路径> → 匹配「这一行是溯源标记」的正则
  case "$1" in
    *.litmus) printf '^(\\* generated-from: ' ;;
    *)        printf '^<!-- generated-from: ' ;;
  esac
}
stamp_at() { # stamp_at <文件> → 标记应当在的行号
  case "$1" in
    # litmus 的首行必须是 `C <名>`：herd7 的 sublexer 在第 1 行就要读到它，
    # 前面搁任何东西都是 "splitter error in sublexer first line"（实跑 herd7 实测）。
    *.litmus) printf '2'; return 0 ;;
  esac
  awk 'NR==1 && $0 != "---" { print 1; found=1; exit }
       NR==1 { fm=1; next }
       fm && $0 ~ /^---[[:space:]]*$/ { print NR+1; found=1; exit }
       END { if (!found) print 1 }' "$1"
}
# 从一份译文里读出溯源标记的路径与哈希（读不到就什么都不打印）。
# 用 awk 不用 sed：两种包裹形式要写成交替，而 sed 的 BRE 里 \| 会跟分隔符撞车——
# 写成 sed 时它静默匹配不上，是靠盖章后的回读断言才抓出来的（写这段时实测）。
stamp_read() { # stamp_read <文件>
  local ln; ln="$(stamp_at "$1")"
  awk -v L="$ln" 'NR==L {
      if ($0 ~ /^(<!--|\(\*) generated-from: .+ sha256:[0-9a-f]{64} (-->|\*\))$/) {
        t = $0
        sub(/^(<!--|\(\*) generated-from: /, "", t)
        i = index(t, " sha256:")
        printf "%s %s\n", substr(t, 1, i - 1), substr(t, i + 8, 64)
      }
    }' "$1"
}

# 逐篇溯源：列出译本仓里与当前清单对不上的篇目，一行一条「<哪种对不上>: <路径>」，全对上时什么都不打印。
# 判据只写这一处：--update 决定能不能替译本仓抄 SOURCE-MANIFEST，与下面第 5 项逐篇比对，用的是同一个函数。
stale_articles() { # stale_articles <译本仓>
  local repo="$1" hash path tf gp gh
  while read -r hash path; do
    tf="$repo/$path"
    [[ -f "$tf" ]] || { printf '缺: %s\n' "$path"; continue; }
    # 没有标记时 stamp_read 无输出，read 返回非 0 —— set -e 会让脚本在这里静默退出，
    # 而「静默退出」正是本门禁要拦的那种失败。所以吃掉退出码，靠 $gh 空不空判。
    gp=''; gh=''
    read -r gp gh < <(stamp_read "$tf") || true
    if [[ -z "$gh" ]]; then
      printf '首行缺 generated-from 标记: %s\n' "$path"
    elif [[ "$gp" != "$path" ]]; then
      printf '溯源标记指向别的源文（%s）: %s\n' "$gp" "$path"
    elif [[ "$gh" != "$hash" ]]; then
      printf '译自旧版源文，需重译: %s\n' "$path"
    fi
  done < "$MF"
}

# 原样复制到各语言仓的部分：**只有不含面向人的散文的东西**——脚本与配置。
# 别的一律走清单逐篇翻译。
#
# skills/ 与 templates/ 曾经在这里，于是日语仓里的 skill 正文和项目骨架全是中文，
# 而 templates/CLAUDE.project.md 会被 install.sh 写成使用者项目根的 CLAUDE.md——
# 与「用日文的不必读中文」直接冲突。现在它们在清单里，逐篇翻译、逐篇溯源。
#
# GLOSSARY.md 留在这里：它本身就是各语言并列的一张对照表，翻译它等于把同一张表
# 抄成 N 份，而那正是它要防的事。它的说明列自带三语，所以不翻译也没有语言缺口。
SHARED=(install.sh scripts GLOSSARY.md)

# gate.sh 当阶段跑时它已打过同名标题，别打两遍（GATE_IN_STAGE 由 run_stage 设）
[[ -n "${GATE_IN_STAGE:-}" ]] || head1 "各语言同步"

[[ -f "$CF" ]] || { ok "未声明语言族，本阶段不适用"; exit 0; }
FAMILY="$(sed -n 's/^family=//p' "$CF")"
THIS="$(sed -n 's/^this=//p' "$CF")"
REF="$(sed -n 's/^reference=//p' "$CF")"
LANGS="$(sed -n 's/^languages=//p' "$CF")"
[[ -n "$FAMILY" && -n "$THIS" && -n "$REF" && -n "$LANGS" ]] || {
  bad "I18N 配置不完整"
  howto "五行都要有：family=<族名>  this=<本仓语言>  reference=<参照仓语言>" \
        "default=<默认版本语言>  languages=<空格分隔>"; exit 1; }
if [[ "$THIS" != "$REF" ]]; then
  ok "本仓是 $THIS 版，同步以 $REF 仓为准，本阶段不适用"
  exit 0
fi
[[ -f "$MF" ]] || { bad "缺 MANIFEST.sha256"; howto "跑： bash scripts/manifest.sh --update"; exit 1; }

# 清单必须是新鲜的：本脚本所有对账都以 MANIFEST 为基准，清单陈旧时
# 「译文与清单一致」是对着旧账本回声——实测出过「规则改了、清单没更新、
# 各语言同步照样全绿」的假绿。先让 manifest.sh 验一遍，陈旧即无法判定。
if [[ -z "$STAMP_LANG" ]] && ! GATE_IN_STAGE=1 bash "$(dirname "${BASH_SOURCE[0]}")/manifest.sh" >/dev/null 2>&1; then
  bad "MANIFEST.sha256 陈旧，译文新旧无法判定"
  howto "先跑 bash scripts/manifest.sh 看哪几篇对不上，改完跑 --update 刷新清单，" \
        "再回来跑各语言同步。对着陈旧清单对账，绿的没有意义。"
  exit 1
fi

if [[ -n "$STAMP_LANG" ]]; then
  head1 "盖溯源标记（$STAMP_LANG）"
  [[ ${#STAMP_FILES[@]} -gt 0 ]] || { bad "--stamp 没给篇目"
    howto "把已按当前源文重译好的篇目一个个写出来：" \
          "bash scripts/i18n-sync.sh --stamp en rules/sop-first.md rules/kb-discipline.md" \
          "没有「全部盖章」这条路——那等于把逐篇溯源这道检查关掉。"; exit 1; }
  repo="$ROOT/$FAMILY-$STAMP_LANG"
  [[ -d "$repo/.git" ]] || { bad "$STAMP_LANG  找不到 git 仓 $repo"
    howto "只往 git 仓里写——写错地方无从回退。确认语言代号没拼错，" \
          "并把该语言仓 clone 成本仓的兄弟目录（--stamp 只认兄弟目录，不收路径参数）。"; exit 1; }
  for path in "${STAMP_FILES[@]}"; do
    hash="$(awk -v p="$path" '$2==p {print $1}' "$MF")"
    [[ -n "$hash" ]] || { bad "$path 不在 MANIFEST.sha256 里"
      howto "只有清单里的篇目才需要溯源标记。核对路径拼写，或先跑：" \
            "bash scripts/manifest.sh --update"; exit 1; }
    tf="$repo/$path"
    [[ -f "$tf" ]] || { bad "$STAMP_LANG 仓里没有 $path"
      howto "先把这一篇译出来再盖章。盖在不存在的文件上无从谈起。"; exit 1; }
    line="$(stamp_wrap "$path" "generated-from: $path sha256:$hash")"
    at="$(stamp_at "$tf")"
    if sed -n "${at}p" "$tf" | grep -q "$(stamp_re "$path")"; then
      sed -i "${at}s|.*|$line|" "$tf"
    else
      sed -i "${at}i $line" "$tf"
    fi
    # 回读确认：替换匹配不上不会报错，只会什么都不做（rules/command-safety.md）
    read -r gp gh < <(stamp_read "$tf") || true
    [[ "$gp" == "$path" && "$gh" == "$hash" ]] || { bad "$path 盖章后回读不一致"
      howto "多半是这份译文的 frontmatter 没闭合，或首行本来就有别的注释。" \
            "打开 $tf 看第 $at 行，手工改成： $line"; exit 1; }
    ok "$path"
  done
  say ""
  warn "盖章的含义是「这一篇已按当前源文重译过」。没重译就盖，是在给旧规则贴新标签。"
  exit 0
fi

fails=0
for lang in $LANGS; do
  [[ "$lang" == "$THIS" ]] && continue   # 本仓就是这一种语言，不用跟自己对账
  repo="$ROOT/$FAMILY-$lang"
  if [[ ! -d "$repo" ]]; then
    bad "$lang  找不到译本仓 $repo"
    howto "克隆到本仓的兄弟目录，或指定位置：" \
          "bash scripts/i18n-sync.sh /path/to/repos" \
          "找不到就无法检查——按失败处理，不静默放过（rules/show-me-test.md）。"
    fails=$((fails+1)); continue
  fi
  sm="$repo/SOURCE-MANIFEST.sha256"
  # --update 顺手替译本仓刷新 SOURCE-MANIFEST，但只在逐篇溯源全都对上时。
  # 以前这一步靠人手抄，漏抄时 --update 整个被下面的「落后」拒掉，共享部分一份都没同步过去
  # （2026-09-11 发 0.0.42 时实测卡在这里）。不能无条件抄：抄了清单却没重译，译本仓就被说成跟上了。
  if [[ $UPDATE -eq 1 ]] && ! cmp -s "$MF" "$sm"; then
    [[ -d "$repo/.git" ]] || { bad "$lang  $repo 不是 git 仓，拒绝往里写 SOURCE-MANIFEST"
      howto "只往 git 仓里写——写错地方无从回退。" \
            "确认路径，或用 bash scripts/i18n-sync.sh --update /path/to/repos 指定。"
      fails=$((fails+1)); continue; }
    articles="$(stale_articles "$repo")"
    if [[ -n "$articles" ]]; then
      bad "$lang  还有 $(grep -c . <<< "$articles") 篇译文没跟上当前源文，SOURCE-MANIFEST 不替它抄"
      sed 's/^/        /' <<< "$articles"
      howto "按当前源文重译这几篇并盖章： bash scripts/i18n-sync.sh --stamp $lang <篇目>…" \
            "再跑 bash scripts/i18n-sync.sh --update，逐篇对上了它自己抄 SOURCE-MANIFEST。"
      fails=$((fails+1)); continue
    fi
    cp "$MF" "$sm"
    cmp -s "$MF" "$sm" || { bad "$lang  SOURCE-MANIFEST 抄完回读与本仓清单对不上"
      howto "看 $sm 是不是只读、或者磁盘满了；修好后重跑 bash scripts/i18n-sync.sh --update"
      fails=$((fails+1)); continue; }
    ok "$lang  SOURCE-MANIFEST 已照本仓清单刷新（$(wc -l < "$MF") 篇逐篇溯源都对得上）"
  fi
  if [[ ! -f "$sm" ]]; then
    bad "$lang  译本仓缺 SOURCE-MANIFEST.sha256"
    howto "跑 bash scripts/i18n-sync.sh --update：逐篇溯源都对上时，它自己把本仓的 MANIFEST.sha256 抄成这个名字。"
    fails=$((fails+1)); continue
  fi
  if ! diff -q "$MF" "$sm" >/dev/null 2>&1; then
    bad "$lang  落后：与清单不一致"
    # ⚠️ 尾部 || true 不能省：diff 有差异时退出码是 1，set -e + pipefail 会把整个
    # 脚本在这里带走——howto 打不出来、后面的语言也不查了（对抗测试实测，
    # 崩在真实数据上）。诊断管道只活在失败分支里，正是样本从没跑过的那条路。
    # 不截断：截断的话，重译的人照着列表做完仍然红，而他看不出还差哪几篇
    # （本轮实测：20 篇里只显示了 10 篇）。
    diff "$MF" "$sm" | grep '^<' | awk '{print $3}' | sed 's/^/        待重译: /' || true
    howto "把上面这几篇在该语言仓里重译并盖章（--stamp），再跑 bash scripts/i18n-sync.sh --update，它逐篇对上后自己抄 SOURCE-MANIFEST。" \
          "只抄清单不重译拦得住：下一项逐篇比对译文首行的 generated-from 哈希。"
    fails=$((fails+1)); continue
  fi
  # 版本必须完全一致：一个升级三个升级
  tv="$(cat "$repo/VERSION" 2>/dev/null || echo '')"
  bv="$(cat "$PKG/VERSION" 2>/dev/null || echo '')"
  if [[ "$tv" != "$bv" ]]; then
    bad "$lang  版本不一致：$lang ${tv:-无} / 本仓 ${bv:-无}"
    howto "所有语言必须同版本。用这条命令一次升全部，不要手改单个 VERSION：" \
          "bash scripts/bump.sh <x.y.z>"
    fails=$((fails+1)); continue
  fi

  if [[ $UPDATE -eq 1 ]]; then
    [[ -d "$repo/.git" ]] || { bad "$lang  $repo 不是 git 仓，拒绝往里写"
      howto "共享部分是覆盖式写入，只往 git 仓里写——写错地方无从回退。" \
            "确认路径，或用 bash scripts/i18n-sync.sh --update /path/to/repos 指定。"
      fails=$((fails+1)); continue; }
    for item in "${SHARED[@]}"; do
      rm -rf "${repo:?}/$item"
      cp -a "$PKG/$item" "$repo/$item"
    done
    # I18N 只有 this= 一行按语言不同，其余照抄——各仓分头维护它必然漂
    sed "s/^this=.*/this=$lang/" "$CF" > "$repo/I18N"
    ok "$lang  共享部分已同步（${#SHARED[@]} 项 + I18N）"
  fi

  sdiff=""
  for item in "${SHARED[@]}"; do
    diff -rq "$PKG/$item" "$repo/$item" >/dev/null 2>&1 || sdiff+="$item "
  done
  if [[ -n "$sdiff" ]]; then
    bad "$lang  共享部分与本仓不一致：$sdiff"
    for item in $sdiff; do
      # || true 同上：diff 非零 + pipefail 会把脚本带走，howto 全丢
      diff -rq "$PKG/$item" "$repo/$item" 2>&1 | sed 's/^/        /' | head -4 || true
    done
    howto "共享部分是原样复制过去的，不翻译。一条命令同步全部语言：" \
          "bash scripts/i18n-sync.sh --update" \
          "手改那边的副本没有意义——下次同步会把它覆盖掉。"
    fails=$((fails+1)); continue
  fi

  # 溯源标记不许压住文件本身的头：SKILL.md 的 frontmatter 必须从第 1 行起，
  # .litmus 的第 1 行必须是 `C <名>`。两样被压住都不报错——skill 安静地装不上，
  # litmus 是 herd7 的 "splitter error in sublexer first line"（都实测过）。
  # 位置由 stamp_at 决定，这里查的是结果：这两类文件的第 1 行还是不是它该有的样子。
  headbad=0
  while read -r _h path; do
    tf="$repo/$path"
    [[ -f "$tf" ]] || continue
    case "$path" in
      */INDEX.md)
        : ;;   # 层的索引，不是 agent 定义，没有 frontmatter
      */SKILL.md|agents/*.md|*/agents/*.md)
        head -1 "$tf" | grep -qx -- '---' || {
          headbad=$((headbad+1)); say "        frontmatter 不在第 1 行: $path"; } ;;
      *.litmus)
        head -1 "$tf" | grep -qE '^[A-Za-z]+[[:space:]]+[A-Za-z0-9_.-]+' || {
          headbad=$((headbad+1)); say "        第 1 行不是 litmus 头: $path"; }
        # 包裹形式也要对：litmus 不认 <!-- -->，herd7 会当场语法报错。
        # 位置对了而形式错了，读回来照样能解析（stamp_read 两种都认），
        # 于是只有真去跑 herd7 才会发现——所以在这里查。
        sed -n '2p' "$tf" | grep -q '^<!-- generated-from: ' && {
          headbad=$((headbad+1)); say "        litmus 里用了 HTML 注释包裹溯源标记: $path"; } ;;
    esac
  done < "$MF"
  if [[ $headbad -gt 0 ]]; then
    bad "$lang  $headbad 篇的第 1 行被压住了"
    howto "溯源标记不能拍在这两类文件的第 1 行：" \
          "SKILL.md / agents 定义 —— frontmatter 必须从第 1 行起，标记放它之后；" \
          "*.litmus —— 第 1 行必须是 \`C <名>\`，标记放第 2 行。" \
          "位置由 i18n-sync.sh 的 stamp_at 决定；重盖一次： bash scripts/i18n-sync.sh --stamp $lang <篇目>"
    fails=$((fails+1)); continue
  fi

  # 逐篇溯源：译文首行记着它译自源文的哪个版本。
  # 只比两份清单的话，「抄了清单却没重译」会绿——那是最危险的一种绿：
  # 版本号、清单、门禁三样都说「最新」，而那一篇正文还是旧的。
  articles="$(stale_articles "$repo")"
  [[ -z "$articles" ]] || sed 's/^/        /' <<< "$articles"
  miss="$(grep -c '^缺: ' <<< "$articles" || true)"
  stale="$(grep -c -v -e '^缺: ' -e '^$' <<< "$articles" || true)"
  if [[ $miss -gt 0 ]]; then
    bad "$lang  清单一致但缺 $miss 个文件"
    howto "补齐这几篇译文。声明了这种语言却不给全，等于给人一份残缺的规则。"
    fails=$((fails+1))
  elif [[ $stale -gt 0 ]]; then
    bad "$lang  $stale 篇译文的溯源标记与源文对不上"
    howto "上面这几篇按当前源文重译，然后把译文首行改成：" \
          "<!-- generated-from: <源文路径> sha256:<源文哈希> -->" \
          "源文哈希取本仓 MANIFEST.sha256 里对应那一行的前半截。"
    fails=$((fails+1))
  else
    ok "$lang  与清单一致（$(wc -l < "$MF") 篇），逐篇溯源对得上，共享部分一致"
  fi
done

say ""
[[ $fails -eq 0 ]] || { bad "各语言同步失败：$fails 种语言未跟上"; exit 1; }   # gate-lint:summary
ok "声明的所有语言都与清单一致"
