#!/usr/bin/env bash
# 各语言仓一起验、一起推：先把 I18N 里声明的全部语言仓验一遍，验完才连远端，逐个推验过的那个提交。
#
#   push-all.sh [各语言仓所在目录]      推 master 只走这一条路
#   钩子 scripts/githooks/pre-push 拒绝直接 git push master，指回这里（每个语言仓各启用一次：
#   git config core.hooksPath scripts/githooks）。
#
# 为什么先验、后连远端：git push 是先连上远端、再跑 pre-push 钩子的。验证（三个仓的整道门禁）要十几分钟，
# 放在钩子里跑，那条连接就一直闲着，会被掐断：2026-09-25 推 0.0.57 时 zh 的连接在验完之后 Broken pipe，
# en、ja 已推、zh 没上去。所以验证放在任何一次连接之前，每个仓的 push 都在验完之后新开连接。
#
# 为什么要它（CLAUDE.md：改规则就得把所有已发布的语言版本一起改、一起合并）：
# 推送是一个仓一个仓推的，门禁只在本地跑、看不见远端。实测（2026-09-11）：0.0.41 只推了 zh，
# en / ja 各落后两个提交，远端上三种语言说的不是同一版规矩，而没有任何东西报警。
#
# 验什么，任何一项不过就拒绝这次推送，一个仓都不推：
#   1. 每个语言仓都在（兄弟目录，同 i18n-sync.sh 的约定）
#   2. 每个仓在 master 上、工作区干净——推出去的是提交，门禁验的是工作区，两者得是同一份
#   3. 每个仓的 VERSION 相同
#   4. 每个仓的 scripts/gate.sh 全绿
#   5. 验完到推之间，每个仓的 HEAD 没变、工作区仍干净——推出去的就是验过的那个提交，
#      推的时候写成 <验过的提交>:refs/heads/master，不推「推的那一刻的 master」
# 都过了：先推其余语言仓，最后推本仓。每次 push 都带 SOP_PUSH_ALL_INNER=1，钩子看到它就直接放行。
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# 从 git 钩子、或 git worktree 里带着 GIT_DIR 调本脚本时，GIT_DIR 指向本仓，它压过 `git -C`：
# 不清掉的话，对其余语言仓的查验和 push 实际都落在本仓上（2026-09-11 实测）。
# 自测里「带着 GIT_DIR 在 git worktree 里跑」那一例守着这一行。
# shellcheck disable=SC2046
unset $(git rev-parse --local-env-vars)

PKG="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repositories_parent="${1:-$(dirname "$PKG")}"

# `|| true`：I18N 不在时 sed 退 2，在 set -e 下会把脚本带走，下面那句带出路的 die 就永远打不出来。
i18n_value() { sed -n "s/^$1=//p" "$PKG/I18N" 2>/dev/null || true; }
family="$(i18n_value family)"; this_language="$(i18n_value this)"
read -r -a languages <<< "$(i18n_value languages)"
[[ -n "$family" && ${#languages[@]} -gt 0 ]] || die "读不出 $PKG/I18N 里的 family 或 languages" \
  "I18N 要有 family=<仓名前缀> 与 languages=<语言…> 两行，写法见 i18n-sync.sh"

repository_of() { # 本仓就用本仓自己的路径，不要求它也在兄弟目录里
  if [[ "$1" == "$this_language" ]]; then printf '%s' "$PKG"
  else printf '%s' "$repositories_parent/$family-$1"; fi
}

work_directory="$(mktemp -d)"; trap 'rm -rf "${work_directory:?}"' EXIT
failures=0; reference_language=""; reference_version=""
declare -A verified_head=()

head1 "各语言仓一起验"
for language in "${languages[@]}"; do
  repository="$(repository_of "$language")"
  if ! git -C "$repository" rev-parse --git-dir >/dev/null 2>&1; then
    bad "$language：找不到语言仓 $repository"
    howto "把 $family-$language clone 到 $repositories_parent 下，或把各语言仓所在的目录作为参数传进来"
    failures=$((failures+1)); continue
  fi
  branch="$(git -C "$repository" symbolic-ref --quiet --short HEAD || echo '（游离 HEAD）')"
  if [[ "$branch" != master ]]; then
    bad "$language：当前在 $branch，不在 master"
    howto "在 $repository 里切回 master 再推；别的分支不走这条一起推的路"
    failures=$((failures+1))
  fi
  if [[ -n "$(git -C "$repository" status --porcelain)" ]]; then
    bad "$language：工作区不干净，推出去的提交和门禁验的工作区不是同一份"
    howto "在 $repository 里把改动提交或挪走（git stash）再推；git -C $repository status 看是哪些"
    failures=$((failures+1))
  fi
  verified_head[$language]="$(git -C "$repository" rev-parse HEAD)"
  version="$(cat "$repository/VERSION" 2>/dev/null || true)"
  if [[ -z "$reference_language" ]]; then
    reference_language="$language"; reference_version="$version"
  elif [[ "$version" != "$reference_version" ]]; then
    bad "$language：VERSION 是 ${version:-（空）}，而 $reference_language 是 $reference_version"
    howto "用 scripts/bump.sh <版本> 一次升全部语言，别一个仓一个仓手改"
    failures=$((failures+1))
  fi
done

if (( failures == 0 )); then
  for language in "${languages[@]}"; do
    repository="$(repository_of "$language")"
    gate_log="$work_directory/gate-$language.log"
    if ( cd "$repository" && bash scripts/gate.sh "$repository" ) > "$gate_log" 2>&1; then
      ok "$language：门禁全绿（输出 $(wc -l < "$gate_log") 行）"
    else
      bad "$language：门禁没过，末尾 15 行："
      tail -n 15 "$gate_log" | sed 's/^/        /'
      howto "在 $repository 里跑 bash scripts/gate.sh 看红在哪，修完提交后重推"
      failures=$((failures+1))
    fi
  done
else
  warn "前面有 $failures 项不过，各仓的门禁这次没跑"
fi

if (( failures > 0 )); then
  bad "一个仓都没推：$failures 项不过"
  howto "按上面每一项的「怎么办」修完，再跑 bash scripts/push-all.sh"
  exit 1
fi

# 验完到推之间有人提交、或改了工作区，推出去的就不是验过的那一份。门禁要跑十几分钟，这段时间足够别的会话动手。
for language in "${languages[@]}"; do
  repository="$(repository_of "$language")"
  if [[ "$(git -C "$repository" rev-parse HEAD)" != "${verified_head[$language]}" ]]; then
    bad "$language：验完之后 HEAD 变了（验的是 ${verified_head[$language]:0:7}，现在是 $(git -C "$repository" rev-parse --short HEAD)），推的就不是验过的那一份"
    howto "等改动停下，再跑一次 bash scripts/push-all.sh，让它把现在的 HEAD 重新验一遍"
    failures=$((failures+1))
  elif [[ -n "$(git -C "$repository" status --porcelain)" ]]; then
    bad "$language：验完之后工作区又有了改动"
    howto "把改动提交或挪走（git stash），再跑一次 bash scripts/push-all.sh"
    failures=$((failures+1))
  fi
done
if (( failures > 0 )); then
  bad "一个仓都没推：验完之后有 $failures 个仓变了"
  howto "按上面每一项的「怎么办」处理完，重跑 bash scripts/push-all.sh"
  exit 1
fi
ok "${#languages[@]} 个语言仓都验过：同在 master、工作区干净、VERSION 都是 $reference_version、门禁全绿"

# 验完才连远端：每个仓的 push 都在这里新开连接，推的是验过的那个提交。本仓排在最后。
head1 "各语言仓一起推"
push_order=()
for language in "${languages[@]}"; do [[ "$language" == "$this_language" ]] || push_order+=("$language"); done
push_order+=("$this_language")
pushed_languages=()
for language in "${push_order[@]}"; do
  repository="$(repository_of "$language")"
  push_log="$work_directory/push-$language.log"
  if SOP_PUSH_ALL_INNER=1 git -C "$repository" push origin "${verified_head[$language]}:refs/heads/master" > "$push_log" 2>&1; then
    pushed_languages+=("$language")
    ok "$language：已推（${verified_head[$language]:0:7}）"
  else
    bad "$language：推送失败，git 的原话："
    sed 's/^/        /' "$push_log"
    howto "已经推上去的：${pushed_languages[*]:-无}；排在 $language 后面的都没推。" \
          "修好 $language 的推送（多半是远端有本地没有的提交：先 git -C $repository pull --rebase，连接断了就直接重跑）" \
          "再跑 bash scripts/push-all.sh，已经推上去的仓会显示 up-to-date"
    exit 1
  fi
done
ok "${#languages[@]} 个语言仓都推上去了，同在 $reference_version"
