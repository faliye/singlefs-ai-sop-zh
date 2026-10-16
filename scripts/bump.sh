#!/usr/bin/env bash
# admission: always 由人决定什么时候抬（改了规范本体、要提交的时候）；新号是不是比旧号大由它自己判
# run-condition: command git sed
# 一次升所有语言的 VERSION —— 版本一致不靠自觉，靠没有别的路可走。
#
#   bump.sh <新版本>            升 I18N 里声明的全部语言
#   bump.sh <新版本> --root <各语言仓所在目录>   译本仓不在兄弟目录时指定
#
# 为什么不让人手改 VERSION：每个仓各改一次，漏一个就是各语言版本不一。
# 而版本不一时，项目侧只会看到自己那一份，看不出别人已经变了。
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight "${BASH_SOURCE[0]}" "$@"; set -- ${PREFLIGHT_ARGUMENTS[@]+"${PREFLIGHT_ARGUMENTS[@]}"}
PACKAGE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
I18N_FILE="$PACKAGE_ROOT/I18N"

NEW_VERSION=""
LANGUAGE_REPOSITORIES_PARENT="$(dirname "$PACKAGE_ROOT")"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)
      [[ $# -ge 2 ]] || die "--root 后面要跟目录路径" "用法: bump.sh <x.y.z> [--root <各语言仓所在目录>]"
      LANGUAGE_REPOSITORIES_PARENT="$2"
      shift 2
      ;;
    --root=*)
      LANGUAGE_REPOSITORIES_PARENT="${1#*=}"
      shift
      ;;
    -*)
      die "认不出的参数：$1" "用法: bump.sh <x.y.z> [--root <各语言仓所在目录>]"
      ;;
    *)
      if [[ -z "$NEW_VERSION" ]]; then
        NEW_VERSION="$1"
      else
        die "收到了多余的位置参数：$1" "用法: bump.sh <x.y.z> [--root <各语言仓所在目录>]"
      fi
      shift
      ;;
  esac
done

[[ "$NEW_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { bad "用法: bump.sh <x.y.z> [--root <各语言仓所在目录>]"
  howto "版本号必须是三段数字，例： bash scripts/bump.sh 1.1.0"; exit 1; }
[[ -f "$I18N_FILE" ]] || die "缺 I18N" \
  "I18N 声明了语言族与已发布的语言，没有它就不知道要升哪几个仓。" \
  "从参照仓拷一份过来，或照 README 的「多语言」一节新建。"
FAMILY="$(sed -n 's/^family=//p' "$I18N_FILE")"
LANGUAGES="$(sed -n 's/^languages=//p' "$I18N_FILE")"
OLD_VERSION="$(cat "$PACKAGE_ROOT/VERSION" 2>/dev/null || echo '?')"

head1 "升版本 $OLD_VERSION → $NEW_VERSION"
# 先全部检查存在，再动手——避免升到一半
for language in $LANGUAGES; do
  language_repository="$LANGUAGE_REPOSITORIES_PARENT/$FAMILY-$language"
  [[ -d "$language_repository" ]] || { bad "$language  找不到 $language_repository"
    howto "所有声明的语言仓都要在场才能升版本，否则会升出互相不一致的几份。" \
          "先把缺的仓 clone 下来，或用 --root 指定它们所在的目录。"; exit 1; }
done
bumped_count=0
for language in $LANGUAGES; do
  language_repository="$LANGUAGE_REPOSITORIES_PARENT/$FAMILY-$language"
  printf '%s\n' "$NEW_VERSION" > "$language_repository/VERSION"
  [[ "$(cat "$language_repository/VERSION")" == "$NEW_VERSION" ]] || die "$language 回读不一致" \
    "写进去的和读出来的不一样，多半是磁盘满了或该目录只读。" \
    "先看 df -h 与该目录的权限，修好后重跑 bump.sh——" \
    "此刻各仓版本已经不一致，不修完不要提交。"
  ok "$FAMILY-$language  → $NEW_VERSION"
  bumped_count=$((bumped_count+1))
done
bash "$PACKAGE_ROOT/scripts/manifest.sh" --update >/dev/null
ok "清单已重新生成；$bumped_count 个语言仓的 VERSION 升到了 $NEW_VERSION"
say ""
warn "记得：改了规则就要重译，只升版本不重译等于把过期译本标成最新。"
