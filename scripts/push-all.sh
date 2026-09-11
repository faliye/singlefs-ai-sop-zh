#!/usr/bin/env bash
# 各语言仓一起验、一起推：推任何一个语言仓，都先把 I18N 里声明的全部语言仓验一遍，全过了才一起推。
#
#   启用（每个语言仓各一次）：git config core.hooksPath scripts/githooks
#   之后在任何一个语言仓里照常 git push，钩子 scripts/githooks/pre-push 会调本脚本
#   手动跑：push-all.sh [各语言仓所在目录]      验完连本仓一起推
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
# 都过了：先推其余语言仓，再推本仓（钩子模式下本仓由 git 自己接着推）。
# 其余仓的钩子看到 SOP_PUSH_ALL_INNER=1 就直接放行，不再反过来推本仓。
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# 在 git worktree 里推时，git 给钩子设的 GIT_DIR 是本仓的绝对路径，它压过 `git -C`：
# 不清掉的话，对其余语言仓的查验和 push 实际都落在本仓上。普通仓里推，钩子里没有 GIT_DIR
# （2026-09-11 两种都实测过）。自测里「在 git worktree 里推」那一例守着这一行。
# shellcheck disable=SC2046
unset $(git rev-parse --local-env-vars)

PKG="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
invoked_by_hook=0
[[ "${1:-}" == --from-hook ]] && { invoked_by_hook=1; shift; }
repositories_parent="${1:-$(dirname "$PKG")}"

i18n_value() { sed -n "s/^$1=//p" "$PKG/I18N"; }
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
  howto "按上面每一项的「怎么办」修完，再在任何一个语言仓里 git push"
  exit 1
fi
ok "${#languages[@]} 个语言仓都验过：同在 master、工作区干净、VERSION 都是 $reference_version、门禁全绿"

head1 "各语言仓一起推"
pushed_languages=()
for language in "${languages[@]}"; do
  [[ "$language" == "$this_language" ]] && continue
  repository="$(repository_of "$language")"
  push_log="$work_directory/push-$language.log"
  if SOP_PUSH_ALL_INNER=1 git -C "$repository" push origin master > "$push_log" 2>&1; then
    pushed_languages+=("$language")
    ok "$language：已推（$(git -C "$repository" rev-parse --short HEAD)）"
  else
    bad "$language：推送失败，git 的原话："
    sed 's/^/        /' "$push_log"
    howto "已经推上去的：${pushed_languages[*]:-无}；$this_language 这次没推。" \
          "修好 $language 的推送（多半是远端有本地没有的提交：先 git -C $repository pull --rebase）" \
          "再在任何一个语言仓里 git push，已经推上去的仓会显示 up-to-date"
    exit 1
  fi
done

if (( invoked_by_hook )); then
  ok "其余 ${#pushed_languages[@]} 个语言仓已推，放行 $this_language 这次推送"
  exit 0
fi
if SOP_PUSH_ALL_INNER=1 git -C "$PKG" push origin master; then
  ok "$this_language：已推，${#languages[@]} 个语言仓同在 $reference_version"
else
  bad "$this_language：推送失败；其余 ${#pushed_languages[@]} 个语言仓已经推上去了"
  howto "修好 $this_language 的推送后重跑本脚本，已经推上去的仓会显示 up-to-date"
  exit 1
fi
