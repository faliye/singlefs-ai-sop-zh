#!/usr/bin/env bash
# admission: always 判的是此刻各语言仓跟没跟上，兄弟目录里的仓随时在变
# run-condition: command git sha256sum
# 各语言文本必须同步：改了任何一份，声明的每种语言都要跟上。
# this 标明本仓是哪种语言；reference 标明参照仓——清单与门禁脚本在那一份里维护，
# 其余语言的仓拿到的是它的原样复制。default 是给使用者的默认版本。
#
#   i18n-sync.sh [各语言仓所在目录]        默认找本仓的兄弟目录
#   i18n-sync.sh --update [目录]           把共享部分原样复制到各语言仓；逐篇溯源都对上的译本仓，
#                                          顺手把本仓 MANIFEST.sha256 抄成它的 SOURCE-MANIFEST.sha256
#   i18n-sync.sh --stamp <语言> <篇>...    给已重译好的那几篇盖上溯源标记
#
# --stamp 要求把篇目一个个写出来，不提供「全部盖章」。一个 for 循环照样能把所有篇目刷绿：
# 盖章是盖的人的承诺，这里只抬高「顺手全刷」的成本；机器管不了「真的重译了没」，盖完的 warn 是这道检查的全部余量。
#
# 检查什么：对 LANGUAGES 里声明的每种语言，
#   1. 那个语言的仓在不在  —— 不在则「无法检查」，按失败处理，不静默放过
#   2. 它抄走的清单是不是当前清单
#   3. VERSION 与本仓完全一致 —— 一个升级三个升级，版本由 bump.sh 一次抬全部
#   4. 共享部分（install.sh、scripts/、GLOSSARY.md）与本仓逐字节一致
#   5. SKILL.md 与 agents 定义的第 1 行没被溯源标记压住 —— frontmatter 的 `---` 必须还在第 1 行
#   6. 清单里每一篇在那个仓里有没有对应文件
#   7. 每一篇译文首行的 generated-from 哈希是不是当前源文 —— 只比清单会漏掉「抄了清单却没重译」
#   已声明的语言缺文件或落后，都判失败。
#
# 共享部分复制而不是只放一份：项目安装时只 clone 自己那一种语言的仓，那个仓里没有门禁脚本就等于装不了。
# 什么进共享、什么进清单，判据见 scripts/manifest.sh「什么进清单，什么不进」。
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight "${BASH_SOURCE[0]}" "$@"; set -- ${PREFLIGHT_ARGUMENTS[@]+"${PREFLIGHT_ARGUMENTS[@]}"}

PACKAGE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPDATE=0
STAMP_LANGUAGE=""
STAMP_FILES=()
if [[ "${1:-}" == "--stamp" ]]; then
  shift
  STAMP_LANGUAGE="${1:-}"; shift || true
  STAMP_FILES=("$@")
  set --
elif [[ "${1:-}" == "--update" ]]; then
  UPDATE=1; shift
fi
LANGUAGE_REPOSITORIES_PARENT="${1:-$(dirname "$PACKAGE_ROOT")}"
MANIFEST_FILE="$PACKAGE_ROOT/MANIFEST.sha256"
I18N_FILE="$PACKAGE_ROOT/I18N"

# 溯源标记不能一律拍在第 1 行：SKILL.md 与 agents 定义的 YAML frontmatter 必须从第 1 行开始，
# 插到它前面 skill 当场装不上。所以位置按有没有 frontmatter 定，判据落在 stamp_at 一处，别处不许再写一份。
stamp_wrap() { # stamp_wrap <路径> <内容> → 带注释包裹的整行
  printf '<!-- %s -->' "$2"
}
stamp_line_pattern() { # stamp_line_pattern <路径> → 匹配「这一行是溯源标记」的正则
  printf '^<!-- generated-from: '
}
stamp_at() { # stamp_at <文件> → 标记应当在的行号
  awk 'NR==1 && $0 != "---" { print 1; stamp_line_found=1; exit }
       NR==1 { inside_frontmatter=1; next }
       inside_frontmatter && $0 ~ /^---[[:space:]]*$/ { print NR+1; stamp_line_found=1; exit }
       END { if (!stamp_line_found) print 1 }' "$1"
}
# 从一份译文里读出溯源标记的路径与哈希（读不到就什么都不打印）。
# 用 awk 不用 sed：sed 的 BRE 里 \| 会跟分隔符撞车，静默匹配不上。
stamp_read() { # stamp_read <文件>
  local stamp_line_number; stamp_line_number="$(stamp_at "$1")"
  awk -v stamp_line_number="$stamp_line_number" 'NR==stamp_line_number {
      if ($0 ~ /^<!-- generated-from: .+ sha256:[0-9a-f]{64} -->$/) {
        stamp_text = $0
        sub(/^<!-- generated-from: /, "", stamp_text)
        sha_marker_position = index(stamp_text, " sha256:")
        printf "%s %s\n", substr(stamp_text, 1, sha_marker_position - 1), substr(stamp_text, sha_marker_position + 8, 64)
      }
    }' "$1"
}

# 逐篇溯源：列出译本仓里与当前清单对不上的篇目，一行一条「<哪种对不上>: <路径>」，全对上时什么都不打印。
# 判据只写这一处：--update 决定能不能替译本仓抄 SOURCE-MANIFEST，与「逐篇比对译文首行的 generated-from 哈希」那一项，用的是同一个函数。
stale_articles() { # stale_articles <译本仓>
  local translation_repository="$1" hash path translation_file stamped_source_path stamped_source_hash
  while read -r hash path; do
    translation_file="$translation_repository/$path"
    [[ -f "$translation_file" ]] || { printf '缺: %s\n' "$path"; continue; }
    # 没有标记时 stamp_read 无输出，read 返回非 0，set -e 会让脚本在这里静默退出；吃掉退出码，靠 $stamped_source_hash 空不空判。
    stamped_source_path=''; stamped_source_hash=''
    read -r stamped_source_path stamped_source_hash < <(stamp_read "$translation_file") || true
    if [[ -z "$stamped_source_hash" ]]; then
      printf '首行缺 generated-from 标记: %s\n' "$path"
    elif [[ "$stamped_source_path" != "$path" ]]; then
      printf '溯源标记指向别的源文（%s）: %s\n' "$stamped_source_path" "$path"
    elif [[ "$stamped_source_hash" != "$hash" ]]; then
      printf '译自旧版源文，需重译: %s\n' "$path"
    fi
  done < "$MANIFEST_FILE"
}

# 原样复制到各语言仓的部分：只有不含面向人的散文的东西（脚本与配置），别的一律走清单逐篇翻译。
# GLOSSARY.md 例外留在这里：它本身就是各语言并列的一张对照表，说明列自带三语。
SHARED=(install.sh scripts GLOSSARY.md .gitignore)

# gate.sh 当阶段跑时它已打过同名标题，别打两遍（GATE_IN_STAGE 由 run_stage 设）
[[ -n "${GATE_IN_STAGE:-}" ]] || head1 "各语言同步"

# 无对象可判（没声明语言族、本仓不是参照仓、languages= 里除了本仓没有别的语言）退 77：gate.sh 记「本次未跑」，不记通过。
# --update / --stamp 是动作，不是判定：在这几种仓里跑是跑错了地方，照 manifest.sh --update 的办法说清楚，不退 77。
[[ -f "$I18N_FILE" ]] || {
  if [[ $UPDATE -eq 1 || -n "$STAMP_LANGUAGE" ]]; then
    die "没有 I18N，不知道本仓是哪种语言、要同步到哪几个仓，--update / --stamp 什么也没做" \
      "到参照仓（zh）里跑： bash scripts/i18n-sync.sh --update 或 --stamp <语言> <篇>…"
  fi
  warn "未声明语言族（没有 I18N），本阶段无对象可判（这不是通过）"; exit 77; }
FAMILY="$(sed -n 's/^family=//p' "$I18N_FILE")"
THIS_LANGUAGE="$(sed -n 's/^this=//p' "$I18N_FILE")"
REFERENCE_LANGUAGE="$(sed -n 's/^reference=//p' "$I18N_FILE")"
LANGUAGES="$(sed -n 's/^languages=//p' "$I18N_FILE")"
[[ -n "$FAMILY" && -n "$THIS_LANGUAGE" && -n "$REFERENCE_LANGUAGE" && -n "$LANGUAGES" ]] || {
  bad "I18N 配置不完整"
  howto "五行都要有：family=<族名>  this=<本仓语言>  reference=<参照仓语言>" \
        "default=<默认版本语言>  languages=<空格分隔>"; exit 1; }
if [[ "$THIS_LANGUAGE" != "$REFERENCE_LANGUAGE" ]]; then
  if [[ $UPDATE -eq 1 ]]; then ok "本仓是 $THIS_LANGUAGE 版，共享部分从 $REFERENCE_LANGUAGE 仓复制过来，--update 什么也没做"; exit 0; fi
  if [[ -n "$STAMP_LANGUAGE" ]]; then
    die "本仓是 $THIS_LANGUAGE 版，溯源标记要在参照仓（$REFERENCE_LANGUAGE）里盖" \
      "到 $FAMILY-$REFERENCE_LANGUAGE 仓里跑： bash scripts/i18n-sync.sh --stamp <语言> <篇>…"
  fi
  warn "本仓是 $THIS_LANGUAGE 版，同步以 $REFERENCE_LANGUAGE 仓为准，本阶段无对象可判（这不是通过）"
  exit 77
fi
[[ -f "$MANIFEST_FILE" ]] || { bad "缺 MANIFEST.sha256"; howto "跑： bash scripts/manifest.sh --update"; exit 1; }

# 所有对账都以 MANIFEST 为基准：清单陈旧时「规则改了、清单没更新、各语言同步照样全绿」。先让 manifest.sh 验一遍，陈旧即无法判定。
if [[ -z "$STAMP_LANGUAGE" ]] && ! GATE_IN_STAGE=1 bash "$(dirname "${BASH_SOURCE[0]}")/manifest.sh" >/dev/null 2>&1; then
  bad "MANIFEST.sha256 陈旧，译文新旧无法判定"
  howto "先跑 bash scripts/manifest.sh 看哪几篇对不上，改完跑 --update 刷新清单，" \
        "再回来跑各语言同步。对着陈旧清单对账，绿的没有意义。"
  exit 1
fi

if [[ -n "$STAMP_LANGUAGE" ]]; then
  head1 "盖溯源标记（$STAMP_LANGUAGE）"
  [[ ${#STAMP_FILES[@]} -gt 0 ]] || { bad "--stamp 没给篇目"
    howto "把已按当前源文重译好的篇目一个个写出来：" \
          "bash scripts/i18n-sync.sh --stamp en rules/sop-first.md rules/kb-discipline.md" \
          "没有「全部盖章」这条路——那等于把逐篇溯源这道检查关掉。"; exit 1; }
  translation_repository="$LANGUAGE_REPOSITORIES_PARENT/$FAMILY-$STAMP_LANGUAGE"
  # `.git` 也可以是文件（git worktree）。只认目录的话，worktree 上做同步会被拒，理由还写成「不是 git 仓」。
  [[ -e "$translation_repository/.git" ]] || { bad "$STAMP_LANGUAGE  找不到 git 仓 $translation_repository"
    howto "只往 git 仓里写——写错地方无从回退。确认语言代号没拼错，" \
          "并把该语言仓 clone 成本仓的兄弟目录（--stamp 只认兄弟目录，不收路径参数）。"; exit 1; }
  for path in "${STAMP_FILES[@]}"; do
    hash="$(awk -v article_path="$path" '$2==article_path {print $1}' "$MANIFEST_FILE")"
    [[ -n "$hash" ]] || { bad "$path 不在 MANIFEST.sha256 里"
      howto "只有清单里的篇目才需要溯源标记。核对路径拼写，或先跑：" \
            "bash scripts/manifest.sh --update"; exit 1; }
    translation_file="$translation_repository/$path"
    [[ -f "$translation_file" ]] || { bad "$STAMP_LANGUAGE 仓里没有 $path"
      howto "先把这一篇译出来再盖章。盖在不存在的文件上无从谈起。"; exit 1; }
    stamp_line="$(stamp_wrap "$path" "generated-from: $path sha256:$hash")"
    stamp_line_number="$(stamp_at "$translation_file")"
    if sed -n "${stamp_line_number}p" "$translation_file" | grep -q "$(stamp_line_pattern "$path")"; then
      sed -i "${stamp_line_number}s|.*|$stamp_line|" "$translation_file"
    else
      sed -i "${stamp_line_number}i $stamp_line" "$translation_file"
    fi
    # 回读确认：替换匹配不上不会报错，只会什么都不做（rules/command-safety.md）
    read -r stamped_source_path stamped_source_hash < <(stamp_read "$translation_file") || true
    [[ "$stamped_source_path" == "$path" && "$stamped_source_hash" == "$hash" ]] || { bad "$path 盖章后回读不一致"
      howto "多半是这份译文的 frontmatter 没闭合，或首行本来就有别的注释。" \
            "打开 $translation_file 看第 $stamp_line_number 行，手工改成： $stamp_line"; exit 1; }
    ok "$path"
  done
  say ""
  warn "盖章的含义是「这一篇已按当前源文重译过」。没重译就盖，是在给旧规则贴新标签。"
  exit 0
fi

failed_language_count=0; compared_language_count=0
for language in $LANGUAGES; do
  [[ "$language" == "$THIS_LANGUAGE" ]] && continue   # 本仓就是这一种语言，不用跟自己对账
  compared_language_count=$((compared_language_count+1))
  translation_repository="$LANGUAGE_REPOSITORIES_PARENT/$FAMILY-$language"
  if [[ ! -d "$translation_repository" ]]; then
    bad "$language  找不到译本仓 $translation_repository"
    howto "克隆到本仓的兄弟目录，或指定位置：" \
          "bash scripts/i18n-sync.sh <各语言仓所在目录>" \
          "找不到就无法检查——按失败处理，不静默放过（rules/show-me-test.md）。"
    failed_language_count=$((failed_language_count+1)); continue
  fi
  source_manifest_file="$translation_repository/SOURCE-MANIFEST.sha256"
  # --update 顺手替译本仓刷新 SOURCE-MANIFEST（不抄的话，下面的「落后」会把整个 --update 拒掉），
  # 但只在逐篇溯源全都对上时：抄了清单却没重译，译本仓就被说成跟上了。
  if [[ $UPDATE -eq 1 ]] && ! cmp -s "$MANIFEST_FILE" "$source_manifest_file"; then
    # `.git` 也可以是文件（git worktree），与 lib.sh 的 project_root 同判。
    [[ -e "$translation_repository/.git" ]] || { bad "$language  $translation_repository 不是 git 仓，拒绝往里写 SOURCE-MANIFEST"
      howto "只往 git 仓里写——写错地方无从回退。" \
            "确认路径，或用 bash scripts/i18n-sync.sh --update <各语言仓所在目录> 指定。"
      failed_language_count=$((failed_language_count+1)); continue; }
    stale_article_list="$(stale_articles "$translation_repository")"
    if [[ -n "$stale_article_list" ]]; then
      bad "$language  还有 $(grep -c . <<< "$stale_article_list") 篇译文没跟上当前源文，SOURCE-MANIFEST 不替它抄"
      sed 's/^/        /' <<< "$stale_article_list"
      howto "按当前源文重译这几篇并盖章： bash scripts/i18n-sync.sh --stamp $language <篇目>…" \
            "再跑 bash scripts/i18n-sync.sh --update，逐篇对上了它自己抄 SOURCE-MANIFEST。"
      failed_language_count=$((failed_language_count+1)); continue
    fi
    cp "$MANIFEST_FILE" "$source_manifest_file"
    cmp -s "$MANIFEST_FILE" "$source_manifest_file" || { bad "$language  SOURCE-MANIFEST 抄完回读与本仓清单对不上"
      howto "看 $source_manifest_file 是不是只读、或者磁盘满了；修好后重跑 bash scripts/i18n-sync.sh --update"
      failed_language_count=$((failed_language_count+1)); continue; }
    ok "$language  SOURCE-MANIFEST 已照本仓清单刷新（$(wc -l < "$MANIFEST_FILE") 篇逐篇溯源都对得上）"
  fi
  if [[ ! -f "$source_manifest_file" ]]; then
    bad "$language  译本仓缺 SOURCE-MANIFEST.sha256"
    howto "跑 bash scripts/i18n-sync.sh --update：逐篇溯源都对上时，它自己把本仓的 MANIFEST.sha256 抄成这个名字。"
    failed_language_count=$((failed_language_count+1)); continue
  fi
  if ! diff -q "$MANIFEST_FILE" "$source_manifest_file" >/dev/null 2>&1; then
    bad "$language  落后：与清单不一致"
    # 尾部 || true 不能省：diff 有差异时退 1，set -e + pipefail 会把脚本在这里带走，howto 打不出来、后面的语言也不查了。
    # 不截断：截断的话，重译的人照着列表做完仍然红，看不出还差哪几篇。
    diff "$MANIFEST_FILE" "$source_manifest_file" | grep '^<' | awk '{print $3}' | sed 's/^/        待重译: /' || true
    howto "把上面这几篇在该语言仓里重译并盖章（--stamp），再跑 bash scripts/i18n-sync.sh --update，它逐篇对上后自己抄 SOURCE-MANIFEST。" \
          "只抄清单不重译拦得住：逐篇溯源那一项比对译文首行的 generated-from 哈希。"
    failed_language_count=$((failed_language_count+1)); continue
  fi
  translation_version="$(cat "$translation_repository/VERSION" 2>/dev/null || echo '')"
  this_version="$(cat "$PACKAGE_ROOT/VERSION" 2>/dev/null || echo '')"
  if [[ "$translation_version" != "$this_version" ]]; then
    bad "$language  版本不一致：$language ${translation_version:-无} / 本仓 ${this_version:-无}"
    howto "所有语言必须同版本。用这条命令一次升全部，不要手改单个 VERSION：" \
          "bash scripts/bump.sh <x.y.z>"
    failed_language_count=$((failed_language_count+1)); continue
  fi

  if [[ $UPDATE -eq 1 ]]; then
    [[ -e "$translation_repository/.git" ]] || { bad "$language  $translation_repository 不是 git 仓，拒绝往里写"
      howto "共享部分是覆盖式写入，只往 git 仓里写——写错地方无从回退。" \
            "确认路径，或用 bash scripts/i18n-sync.sh --update <各语言仓所在目录> 指定。"
      failed_language_count=$((failed_language_count+1)); continue; }
    for shared_item in "${SHARED[@]}"; do
      rm -rf "${translation_repository:?}/$shared_item"
      if [[ -e "$PACKAGE_ROOT/$shared_item" ]]; then
        cp -a "$PACKAGE_ROOT/$shared_item" "$translation_repository/$shared_item"
      fi
    done
    # I18N 只有 this= 一行按语言不同，其余照抄——各仓分头维护它必然漂
    sed "s/^this=.*/this=$language/" "$I18N_FILE" > "$translation_repository/I18N"
    ok "$language  共享部分已同步（${#SHARED[@]} 项 + I18N）"
  fi

  differing_shared_items=""
  for shared_item in "${SHARED[@]}"; do
    if [[ ! -e "$PACKAGE_ROOT/$shared_item" && ! -e "$translation_repository/$shared_item" ]]; then
      continue
    fi
    diff -rq "$PACKAGE_ROOT/$shared_item" "$translation_repository/$shared_item" >/dev/null 2>&1 || differing_shared_items+="$shared_item "
  done
  if [[ -n "$differing_shared_items" ]]; then
    bad "$language  共享部分与本仓不一致：$differing_shared_items"
    for shared_item in $differing_shared_items; do
      # || true 不能省：diff 非零 + pipefail 会把脚本带走，howto 全丢
      diff -rq "$PACKAGE_ROOT/$shared_item" "$translation_repository/$shared_item" 2>&1 | sed 's/^/        /' | head -4 || true
    done
    howto "共享部分是原样复制过去的，不翻译。一条命令同步全部语言：" \
          "bash scripts/i18n-sync.sh --update" \
          "手改那边的副本没有意义——下次同步会把它覆盖掉。"
    failed_language_count=$((failed_language_count+1)); continue
  fi

  # SKILL.md 与 agents 定义的第 1 行必须是 frontmatter 的 `---`：被溯源标记压住不报错，skill 安静地装不上。
  # 位置由 stamp_at 决定，这里查的是结果。
  covered_frontmatter_count=0
  while read -r _manifest_hash path; do
    translation_file="$translation_repository/$path"
    [[ -f "$translation_file" ]] || continue
    case "$path" in
      */INDEX.md)
        : ;;   # 层的索引，不是 agent 定义，没有 frontmatter
      */SKILL.md|agents/*.md|*/agents/*.md)
        head -1 "$translation_file" | grep -qx -- '---' || {
          covered_frontmatter_count=$((covered_frontmatter_count+1)); say "        frontmatter 不在第 1 行: $path"; } ;;
    esac
  done < "$MANIFEST_FILE"
  if [[ $covered_frontmatter_count -gt 0 ]]; then
    bad "$language  $covered_frontmatter_count 篇的第 1 行被压住了"
    howto "溯源标记不能拍在这类文件的第 1 行：" \
          "SKILL.md / agents 定义 —— frontmatter 必须从第 1 行起，标记放它之后；" \
          "位置由 i18n-sync.sh 的 stamp_at 决定；重盖一次： bash scripts/i18n-sync.sh --stamp $language <篇目>"
    failed_language_count=$((failed_language_count+1)); continue
  fi

  # 逐篇溯源：只比两份清单的话，「抄了清单却没重译」会绿。
  stale_article_list="$(stale_articles "$translation_repository")"
  [[ -z "$stale_article_list" ]] || sed 's/^/        /' <<< "$stale_article_list"
  missing_count="$(grep -c '^缺: ' <<< "$stale_article_list" || true)"
  stale_count="$(grep -c -v -e '^缺: ' -e '^$' <<< "$stale_article_list" || true)"
  if [[ $missing_count -gt 0 ]]; then
    bad "$language  清单一致但缺 $missing_count 个文件"
    howto "补齐这几篇译文。声明了这种语言却不给全，等于给人一份残缺的规则。"
    failed_language_count=$((failed_language_count+1))
  elif [[ $stale_count -gt 0 ]]; then
    bad "$language  $stale_count 篇译文的溯源标记与源文对不上"
    howto "上面这几篇按当前源文重译，然后把译文首行改成：" \
          "<!-- generated-from: <源文路径> sha256:<源文哈希> -->" \
          "源文哈希取本仓 MANIFEST.sha256 里对应那一行的前半截。"
    failed_language_count=$((failed_language_count+1))
  else
    ok "$language  与清单一致（$(wc -l < "$MANIFEST_FILE") 篇），逐篇溯源对得上，共享部分一致"
  fi
done

say ""
[[ $failed_language_count -eq 0 ]] || { bad "各语言同步失败：$failed_language_count 种语言未跟上"; exit 1; }   # gate-lint:summary
if [[ $compared_language_count -eq 0 ]]; then
  warn "languages=（$LANGUAGES）里除了本仓的 $THIS_LANGUAGE 没有别的语言，没有译本仓可比，本阶段无对象可判（这不是通过）"
  exit 77
fi
ok "除本仓外声明的 $compared_language_count 种语言都与清单一致"
