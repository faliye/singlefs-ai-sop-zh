#!/usr/bin/env bash
# 用 LKMM 判内存序结论：herd7 给模型判定。
#
#   lkmm.sh [项目根]                  跑 <项目根>/litmus/*.litmus
#   lkmm.sh [项目根] --static-only    只跑不需要 herd7 的检查；全过也退 3——它不是通过
#
# 每个 .litmus 必须在文件里声明期望判定：
#
#   (* singlefs-expect: Never *)      坏结果必须不可能发生
#   (* singlefs-expect: Sometimes *)  坏结果可能发生（对照组用）
#
# 每条 Never 还要声明它模拟的是哪段代码，一行一个锚点（写者、读者各一行也行），
# 锚点后面空一格可以写注释：
#
#   singlefs-models: crates/<crate>/src/<文件>.rs::<函数名>
#   singlefs-models: none —— <为什么它不对应代码>
#
# 判定与声明不符 → 失败。没有声明 → 失败（不许「跑了但没人看结果」）。
#
# 会失败的检查（都是踩过的坑，做成拒绝执行而不是提醒句）：
#   1. 用了 rN 却没有 `int rN;` 声明 —— herd7 不管，klitmus7 会在生成 C 之后
#      才报 undeclared，那时已经很难定位。这里提前拦。
#   2. init 块里给 atomic_t 形参赋初值不带类型 —— herd7 照跑且判定正确，
#      只有 klitmus7 会炸。也就是说这个错能一路混过模型判定，必须在这里拦。
#   3. 每条 Never 必须有**自己的**对照组：同名前缀 `<名>-*.litmus`、声明 Sometimes，
#      而且**内容就是它去掉屏障的形态**（判据在 is_fence_removal_of）。
#      全局数出一条 Sometimes 不算数——对抗测试实测：10 条互不相关的 Never
#      曾靠 1 条无关的 Sometimes 全部过闸。只按文件名认也不够：换一个 exists、换一个读者的
#      「对照组」照样过闸，名字前缀撞车时（a 与 a-b）a-b 的对照还会被算成 a 的。
#      「屏障挡住了」还是「本来就撞不上」，只有同一条测试去掉屏障才回答得了。
#   4. 每条 Never 都要绑到代码。herd7 只判 litmus 写下的那个形态：代码改了发布顺序而 litmus 没跟，
#      判定照样是 Never，门禁照样绿。所以锚点指的文件与 `fn` 要在，而且 crates/ 下要有一个 .rs
#      写出这个 litmus 的文件名——那是读它、拿它跟代码今天的形态比的测试。测得对不对门禁判不了，要人看。
#   5. 没有 herd7 直接失败，不静默跳过。
#
# 1–4 都排在 herd7 探测之前：它们不需要 herd7，
# 该红的先红出来（selftest 的样本也靠这一点才喂得进去）。
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

STATIC_ONLY=0; ROOT=""
for argument in "$@"; do
  case "$argument" in
    --static-only) STATIC_ONLY=1 ;;
    *) ROOT="$argument" ;;
  esac
done
ROOT="${ROOT:-$(project_root)}"
# 绝对化：失败信息里的 rel 要靠 ${f#$ROOT/} 剥前缀，而 FILES 是 readlink -f 出来的绝对路径。
# ROOT 是相对路径时剥不掉，报出来的就是一长串绝对路径——看的人得自己找哪一段是项目内路径。
[[ -d "$ROOT" ]] && ROOT="$(cd "$ROOT" && pwd)"
LITMUS_DIR="$ROOT/litmus"
KTREE="${SINGLEFS_KERNEL_TREE:-}"

head1 "LKMM（herd7）"

[[ -d "$LITMUS_DIR" ]] || { bad "没有 $LITMUS_DIR 目录"
  howto "并发相关的改动要有 litmus：照 templates/litmus/ 那对现成的抄，" \
        "放进 <项目根>/litmus/。没有并发改动就不该跑到这条检查。"; exit 1; }
# 路径必须绝对化：下面要 cd 进内核树跑 herd7（模型文件是相对路径引的），
# 相对路径 cd 之后就找不着了
mapfile -t FILES < <(find "$LITMUS_DIR" -name '*.litmus' -exec readlink -f {} \; | sort)
[[ ${#FILES[@]} -gt 0 ]] || { bad "$LITMUS_DIR 下没有 .litmus 文件"
  howto "照 templates/litmus/ 那对现成的抄一对进来（Never + 去屏障的 Sometimes 对照），" \
        "或者删掉空的 litmus/ 目录。"; exit 1; }

# ── 静态检查：期望声明 / 寄存器声明 / atomic_t 初值类型 ──
fails=0
declare -A EXPECT
for f in "${FILES[@]}"; do
  rel="${f#"$ROOT"/}"
  exp="$(sed -n 's/.*singlefs-expect:[[:space:]]*\([A-Za-z]*\).*/\1/p' "$f" | head -1)"
  case "$exp" in
    Never|Sometimes|Always) EXPECT["$f"]="$exp" ;;
    *) bad "$rel 缺 (* singlefs-expect: Never|Sometimes *) 声明"
       howto "在文件头注释块里写明期望判定。没有声明 = 跑了但没人看结果，不算验证。"
       fails=$((fails+1)); continue ;;
  esac
  for r in $(grep -oE '\br[0-9]+\b' "$f" | sort -u); do
    grep -qE "^[[:space:]]*int[[:space:]]+$r[[:space:]]*;" "$f" \
      || { bad "$rel 用了 $r 但没有 'int $r;'（klitmus7 会在生成 C 之后才报）"
           howto "在用到 $r 的进程体开头补一行 'int $r;'。"
           fails=$((fails+1)); }
  done
  init="$(awk '/^\{/{f=1} f{print} f&&/\}/{exit}' "$f")"
  for v in $(grep -oE 'atomic_t[[:space:]]*\*[[:space:]]*[A-Za-z_][A-Za-z0-9_]*' "$f" \
             | sed -E 's/.*\*[[:space:]]*//' | sort -u); do
    printf '%s\n' "$init" | grep -qE "(^|[^[:alnum:]_])$v[[:space:]]*=" || continue
    printf '%s\n' "$init" | grep -qE "atomic_t[[:space:]]+$v[[:space:]]*=" \
      || { bad "$rel init 里 '$v = ...' 要写成 'atomic_t $v = ...'（只有 klitmus7 会炸）"
           howto "init 块里给 atomic_t 形参赋初值必须带类型，照 templates/litmus/ 的写法。"
           fails=$((fails+1)); }
  done
done
[[ $fails -eq 0 ]] || { bad "静态检查未过：$fails 项"; exit 1; }   # gate-lint:summary

# ── 对照组是不是「这一条去掉屏障的形态」──
# 判据只写在这一处。去掉行首起的 (* … *) 注释、首行 `C <名>` 与空行之后逐行比，比的时候不看空白：
# 对照组只许比原测试少几行屏障，或者把 smp_store_release / smp_load_acquire 放宽成
# WRITE_ONCE / READ_ONCE，至少一处；exists、init、读者一个字都不许改。
# 注释只认行首起的那种：代码里的 `WRITE_ONCE(*x, 1)` 也有「(*」，当成注释开头会吞掉整段代码。
# 是 → 退 0；不是 → 退 1，stdout 打印第一处不同。
is_fence_removal_of() { # is_fence_removal_of <Never 那条> <候选对照组>
  python3 - "$1" "$2" <<'PY'
import re
import sys

FENCE_STATEMENT = re.compile(
    r'^(smp_mb|smp_wmb|smp_rmb|smp_mb__before_atomic|smp_mb__after_atomic'
    r'|smp_mb__after_spinlock|smp_mb__after_unlock_lock|synchronize_rcu)\(\);$')


def statements(path):
    text = open(path, encoding='utf-8').read()
    # 注释换成同样多的换行，报出来的行号才对得上原文件
    text = re.sub(r'^[ \t]*\(\*.*?\*\)', lambda comment: '\n' * comment.group(0).count('\n'),
                  text, flags=re.S | re.M)
    kept = []
    for line_number, line in enumerate(text.splitlines(), start=1):
        shown = line.strip()
        if shown:
            kept.append((line_number, shown, re.sub(r'\s+', '', shown)))
    if kept and kept[0][1].startswith('C '):
        kept = kept[1:]
    return kept


def relaxed(compact):
    compact = re.sub(r'smp_store_release\((\w+),', r'WRITE_ONCE(*\1,', compact)
    return re.sub(r'smp_load_acquire\((\w+)\)', r'READ_ONCE(*\1)', compact)


never_statements = statements(sys.argv[1])
control_statements = statements(sys.argv[2])
never_position = control_position = weakened_count = 0
while never_position < len(never_statements):
    never_number, never_shown, never_compact = never_statements[never_position]
    control_statement = (control_statements[control_position]
                         if control_position < len(control_statements) else None)
    if control_statement and control_statement[2] == never_compact:
        never_position += 1
        control_position += 1
    elif FENCE_STATEMENT.match(never_compact):
        weakened_count += 1
        never_position += 1
    elif (control_statement and relaxed(never_compact) != never_compact
          and relaxed(never_compact) == control_statement[2]):
        weakened_count += 1
        never_position += 1
        control_position += 1
    else:
        where_in_control = (f'对照组第 {control_statement[0]} 行「{control_statement[1]}」'
                            if control_statement else '对照组已经到头')
        print(f'第一处不同：原测试第 {never_number} 行「{never_shown}」，{where_in_control}')
        sys.exit(1)
if control_position < len(control_statements):
    extra_number, extra_shown = control_statements[control_position][:2]
    print(f'对照组第 {extra_number} 行「{extra_shown}」在原测试里没有')
    sys.exit(1)
if weakened_count == 0:
    print('一处屏障都没去掉，内容与原测试相同')
    sys.exit(1)
PY
}

# ── 每条 Never 都要有自己的对照组 ──
n_never=0; n_some=0
for f in "${FILES[@]}"; do
  [[ "${EXPECT[$f]}" == Never ]] && n_never=$((n_never+1))
  [[ "${EXPECT[$f]}" == Sometimes ]] && n_some=$((n_some+1))
done
for f in "${FILES[@]}"; do
  [[ "${EXPECT[$f]}" == Never ]] || continue
  base="${f%.litmus}"; rel="${f#"$ROOT"/}"
  paired=0; rejected_candidates=()
  for g in "${FILES[@]}"; do
    [[ "$g" == "$base"-*.litmus && "${EXPECT[$g]}" == Sometimes ]] || continue
    if difference="$(is_fence_removal_of "$f" "$g")"; then paired=1; break; fi
    rejected_candidates+=("$(basename "$g")：$difference")
  done
  [[ $paired -eq 1 ]] && continue
  fails=$((fails+1))
  if [[ ${#rejected_candidates[@]} -eq 0 ]]; then
    bad "$rel  没有配对的对照组"
    say "        全局有几条 Sometimes 不算数：对照必须是这一条去掉屏障的形态，"
    say "        否则分不清「屏障挡住了」还是「这个模式本来就撞不上」。"
    howto "复制 $(basename "$f") 为 $(basename "$base")-nofence.litmus，删掉里面的屏障" \
          "（smp_wmb / smp_rmb 等），声明改成 (* singlefs-expect: Sometimes *)。" \
          "它判 Sometimes，原来那条的 Never 才有判别力。"
  else
    bad "$rel  没有配对的对照组：同名前缀的 Sometimes 都不是它去掉屏障的形态"
    for rejected_candidate in "${rejected_candidates[@]}"; do say "        $rejected_candidate"; done
    howto "对照组只许比原测试少几行屏障（smp_wmb / smp_rmb / smp_mb 等），或者把 smp_store_release /" \
          "smp_load_acquire 放宽成 WRITE_ONCE / READ_ONCE；exists、init、读者一个字都不许改——改了它回答的就是另一个问题。" \
          "从 $(basename "$f") 复制一份重新删屏障，别在旧的对照组上修。"
  fi
done
[[ $fails -eq 0 ]] || { bad "对照组检查未过：$fails 项"; exit 1; }   # gate-lint:summary

# ── 每条 Never 都要绑到代码 ──
n_bound=0; n_unbound=0
for f in "${FILES[@]}"; do
  [[ "${EXPECT[$f]}" == Never ]] || continue
  rel="${f#"$ROOT"/}"; litmus_name="$(basename "$f")"
  declarations=()
  while IFS= read -r declaration; do declarations+=("$declaration"); done \
    < <(sed -n 's/.*singlefs-models:[[:space:]]*//p' "$f" | sed -E 's/[[:space:]]*\*\)[[:space:]]*$//; s/[[:space:]]+$//')
  if [[ ${#declarations[@]} -eq 0 ]]; then
    bad "$rel  缺 singlefs-models 声明：说不出它模拟的是哪段代码"
    howto "在文件头注释块里写一行 singlefs-models: crates/<crate>/src/<文件>.rs::<函数名>，写者、读者各一行也行；" \
          "不对应任何代码就写 singlefs-models: none —— <为什么>。"
    fails=$((fails+1)); continue
  fi
  none_count=0; anchor_count=0; anchor_failed=0; none_reason=""
  for declaration in "${declarations[@]}"; do
    if [[ "$declaration" =~ ^none([^A-Za-z0-9_].*)?$ ]]; then
      none_count=$((none_count+1))
      none_reason="$(printf '%s' "${BASH_REMATCH[1]}" | sed -E 's/^[[:space:]—–:：-]+//')"
      continue
    fi
    anchor_count=$((anchor_count+1))
    anchor="${declaration%%[[:space:]]*}"      # 锚点后面空一格可以写注释
    anchor_path="${anchor%::*}"; anchor_function="${anchor##*::}"
    if [[ "$anchor" != *::* || -z "$anchor_path" || ! "$anchor_function" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      bad "$rel  singlefs-models 写成了「$declaration」：认不出文件与函数"
      howto "格式： singlefs-models: <仓内路径>::<函数名>，例如 crates/core/src/transaction.rs::publish；" \
            "不对应代码就写 singlefs-models: none —— <为什么>。"
      anchor_failed=1; continue
    fi
    if [[ ! -f "$ROOT/$anchor_path" ]]; then
      bad "$rel  singlefs-models 指的 $anchor_path 不存在"
      howto "代码搬了家或改了名，就跟着改这一行；那段同步逻辑整个删了，这条 litmus 也该跟着删或改写。"
      anchor_failed=1; continue
    fi
    if ! grep -qE "(^|[^A-Za-z0-9_])fn[[:space:]]+$anchor_function([^A-Za-z0-9_]|$)" "$ROOT/$anchor_path"; then
      bad "$rel  $anchor_path 里没有 fn $anchor_function"
      howto "函数改了名就跟着改这一行。改名多半也动了同步的形态，回头对一遍 litmus 的写者和读者。"
      anchor_failed=1; continue
    fi
  done
  if [[ $anchor_failed -eq 1 ]]; then fails=$((fails+1)); continue; fi
  if [[ $none_count -gt 0 && $anchor_count -gt 0 ]]; then
    bad "$rel  singlefs-models 既写了 none 又写了锚点"
    howto "二选一：它对应代码，就删掉 none 那一行；不对应，就删掉锚点。"
    fails=$((fails+1)); continue
  fi
  if [[ $none_count -gt 0 ]]; then
    if [[ -z "$none_reason" ]]; then
      bad "$rel  singlefs-models: none 没写理由"
      howto "写成 singlefs-models: none —— <为什么它不对应代码>。理由不许省：" \
            "不对应代码的 Never 证明的只是一个抽象形态，读的人要知道它凭什么可以不对应。"
      fails=$((fails+1)); continue
    fi
    n_unbound=$((n_unbound+1)); continue
  fi
  # 锚点都在，还要有一个测试读这个 litmus。门禁按文件名认它
  if ! grep -rqF --include='*.rs' -- "$litmus_name" "$ROOT/crates" 2>/dev/null; then
    bad "$rel  crates/ 下没有一个 .rs 写出 $litmus_name —— 没有测试把它和代码对上"
    howto "写一个测试读这个 litmus，拿它的写者 / 读者次序跟代码今天实际发出的次序比" \
          "（例：录制写请求流，按步骤分类后逐项比）。测试里要写出文件名 $litmus_name，门禁按文件名认。" \
          "herd7 只判 litmus 写下的形态：代码改了顺序而 litmus 没跟，判定照样是 Never。"
    fails=$((fails+1)); continue
  fi
  n_bound=$((n_bound+1))
done
[[ $fails -eq 0 ]] || { bad "代码绑定检查未过：$fails 项"; exit 1; }   # gate-lint:summary

if [[ $STATIC_ONLY -eq 1 ]]; then
  say ""
  warn "静态检查全过：$n_never 条 Never 每条都有内容对得上的对照组，$n_bound 条绑到代码、$n_unbound 条声明不对应代码；共 $n_some 条 Sometimes"
  warn "herd7 判定没跑（--static-only），退出码 3——这不是通过"
  exit 3
fi

# ── herd7 ──
if ! command -v herd7 >/dev/null 2>&1 && command -v opam >/dev/null 2>&1; then
  export OPAMROOT="${OPAMROOT:-$HOME/.opam}"
  eval "$(opam env --root="$OPAMROOT" --set-root 2>/dev/null)" || true
fi
command -v herd7 >/dev/null 2>&1 || {
  bad "herd7 缺失"
  howto "opam install herdtools7" \
        "（装完若命令仍找不到，先 eval \"\$(opam env)\"）"
  exit 1
}

# ── 内核树（herd7 要在 tools/memory-model 里跑，模型文件是相对路径引的）──
if [[ -z "$KTREE" ]]; then
  for c in "$ROOT/../linux" "$HOME/linux" "$HOME/linux-bug-fix/linux"; do
    [[ -d "$c/tools/memory-model" ]] && { KTREE="$c"; break; }
  done
fi
# 按需取：委托给 fetch-deps.sh，取树的逻辑只有那一份实现
if [[ -z "$KTREE" || ! -d "$KTREE/tools/memory-model" ]]; then
  CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/singlefs/linux-memory-model"
  if [[ -d "$CACHE/tools/memory-model" ]]; then
    KTREE="$CACHE"
  elif [[ -z "${SINGLEFS_NO_FETCH:-}" ]]; then
    bash "$(dirname "${BASH_SOURCE[0]}")/fetch-deps.sh" --kernel || exit 1
    [[ -d "$CACHE/tools/memory-model" ]] && KTREE="$CACHE"
  fi
fi

[[ -n "$KTREE" && -d "$KTREE/tools/memory-model" ]] || {
  bad "找不到带 tools/memory-model 的内核树"
  howto "herd7 要在内核树的 tools/memory-model 里跑（模型文件是相对路径引的）。" \
        "指一棵 Linux 源码树：" \
        "SINGLEFS_KERNEL_TREE=/path/to/linux bash .claude/scripts/lkmm.sh"
  exit 1
}
KTREE="$(readlink -f "$KTREE")"
ok "内核树 $KTREE"
ok "herd7  $(herd7 -version 2>&1 | head -1)"

# ── 跑 ──
say ""
cd "$KTREE/tools/memory-model"
for f in "${FILES[@]}"; do
  rel="litmus/$(basename "$f")"   # 此时已 cd 进内核树，不能再算相对路径
  want="${EXPECT[$f]}"
  out="$(timeout 300 herd7 -conf linux-kernel.cfg "$f" 2>&1)" || {
    bad "$rel  herd7 执行失败"; printf '%s\n' "$out" | tail -5 | sed 's/^/        /'
    howto "看上面的报错。多半是 litmus 语法问题，照 litmus/ 现有文件的格式改；" \
          "超时（300s）则是状态空间太大，把进程数或变量数减下来。"
    fails=$((fails+1)); continue
  }
  got="$(printf '%s\n' "$out" | sed -n 's/^Observation[[:space:]]\+[^[:space:]]\+[[:space:]]\+\([A-Za-z]*\).*/\1/p' | head -1)"
  if [[ -z "$got" ]]; then
    bad "$rel  读不到 Observation 行 —— 判定不明，整条作废"
    printf '%s\n' "$out" | tail -5 | sed 's/^/        /'; fails=$((fails+1))
    howto "多半是 litmus 语法错。最常见的一处：进程签名后面不能跟行内注释，" \
          "注释只能写在文件头的 (* ... *) 块里。照 litmus/ 现有文件的格式改。"
  elif [[ "$got" == "$want" ]]; then
    ok "$rel  $got（符合声明）"
  else
    bad "$rel  期望 $want，实际 $got"
    printf '%s\n' "$out" | grep -E '^(States|Condition|Observation)' | sed 's/^/        /' || true
    howto "两种可能，别急着改声明：" \
      "① 代码或模型真的少了屏障 → 这正是这条测试要抓的东西，去补屏障" \
      "② 这条声明本来就写错了   → 改 (* singlefs-expect: ... *)" \
      "先想清楚是哪一种。直接把声明改成实际值，等于把测试关掉。"
    fails=$((fails+1))
  fi
done

say ""
[[ $fails -eq 0 ]] || { bad "LKMM 未通过：$fails 项"; exit 1; }   # gate-lint:summary
ok "LKMM 通过（$n_never 条 Never：每条都有内容对得上的对照组，$n_bound 条绑到代码、$n_unbound 条声明不对应代码；共 $n_some 条 Sometimes）"
