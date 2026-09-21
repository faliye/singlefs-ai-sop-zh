#!/usr/bin/env bash
# 编号与简称在 doc-lint 够不到的地方也要一致。
#
# `doc-lint.sh` 管的是 markdown。而编号引用还散在**源码注释、脚本、记录**里，
# 那些地方没有任何东西在看：编号在引用处只剩一个符号，含义能被悄悄改掉而没有一个字别扭
# （rules/kb-discipline.md 第 5 条：编号只能做索引，不能做称呼）。
# 原是使用者项目的一个本地阶段，判据通用，收归这里。
#
# 登记位：kb 里各条目正文的首行 `## <编号> <简称> —— <状态>`，与 doc-lint 的「登记标题」同形态。
# 射程：默认扫仓根下的 .rs / .sh / .py / .md（kb 自己与冻结证据除外），也可以把目录作为参数给。
# 冻结证据按项目根的 .claude/doc-lint-exclude 绕开：那是原样保存的输入，
# 里面的旧简称是当时写的，要改只能连同重跑一起改（rules/evidence-discipline.md）。
#
# 用法：
#   number-name-sync.sh [仓根] [要扫的目录…]
# kb 目录不存在、或一个文件都没扫到时退 77（本次无对象可判），不报绿。
set -uo pipefail
ROOT="${1:-.}"
cd "$ROOT" 2>/dev/null || exit 2
shift 2>/dev/null || true
[[ -d .claude/kb ]] || exit 77
export NUMBER_NAME_DIRS="$*"

python3 - <<'PY'
import re, glob, os, sys

truth = {}
for pat, pre in (('.claude/kb/experiments/*.md', 'E'), ('.claude/kb/decisions/*.md', 'D')):
    for f in glob.glob(pat):
        t = open(f, encoding='utf-8').read().split('\n', 1)[0]
        m = re.match(r'## (' + pre + r'\d+) (.+?)\s*——', t)
        if m:
            truth[m.group(1)] = m.group(2).strip()

def excluded_dirs():
    """冻结证据的清单与 doc-lint 共用一份（rules/evidence-discipline.md）。"""
    out = []
    try:
        with open('.claude/doc-lint-exclude', encoding='utf-8') as handle:
            for line in handle:
                line = line.split('#')[0].strip()
                if line:
                    out.append(line.rstrip('/') + '/')
    except OSError:
        pass
    return tuple(out)


SKIP_DIRS = {'.git', 'node_modules', 'target'}


def package_dir():
    """装进项目的 SOP 副本不扫：它是上游的文件，判它等于在项目侧判上游。"""
    for candidate in ('.claude/singlefs-ai-sop/I18N',):
        try:
            with open(candidate, encoding='utf-8') as handle:
                for line in handle:
                    if line.startswith('family='):
                        return '.claude/' + line.split('=', 1)[1].strip() + '/'
        except OSError:
            pass
    return '.claude/singlefs-ai-sop/'


SKIP_PREFIX = ('.claude/kb/', package_dir()) + excluded_dirs()
# 默认只看**源码注释与记录**（.rs / .md）。脚本（.sh / .py）里写 `D1（简称）` 多半是
# 格式说明或样本数据，不是对某条编号的引用——扫它们假红压倒真红（实测于使用者项目）。
# 项目要扩就把目录作为参数传进来。
SCANNED_SUFFIXES = ('.rs', '.md')
given = [d for d in os.environ.get('NUMBER_NAME_DIRS', '').split() if d]
roots = given or ['.']
targets = []
for start in roots:
    for directory, subdirectories, files in os.walk(start):
        subdirectories[:] = [d for d in subdirectories if d not in SKIP_DIRS and d != 'fixtures']
        for name in files:
            if not name.endswith(SCANNED_SUFFIXES):
                continue
            path = os.path.normpath(os.path.join(directory, name))
            if any(path.startswith(prefix) for prefix in SKIP_PREFIX):
                continue
            targets.append(path)

bad = []
for f in sorted(set(targets)):
    for i, line in enumerate(open(f, encoding='utf-8', errors='ignore'), 1):
        # 简称本身可以含一层全角括号（D14 的「双轨（大小文件 / 持久临时）」）。
        # naive 的 [^）]* 吃到第一个「）」就停，于是**没有任何写法能让这类引用通过**——
        # 实测 2026-09-06：records/ 里写对的 D14 引用被判红，只能退回裸编号绕开。
        for num, nm in re.findall(r'([ED]\d+)（((?:[^（）]|（[^（）]*）)*)）', line):
            if num in truth and truth[num] != nm:
                bad.append((f, i, num, nm, truth[num]))

if bad:
    print('  ✗ 编号的简称与登记位不符：')
    for f, i, num, nm, want in bad[:15]:
        print(f'     {f}:{i}  {num} 写的「{nm[:24]}」，登记处是「{want[:24]}」')
    if len(bad) > 15:
        print(f'     …… 另有 {len(bad)-15} 处')
    print('     → 简称照登记位抄（各正文首行 `## D<n> 简称 —— 状态`）。')
    print('     → 若是「）」写成了半角「)」，括注不闭合，正则会一路吃到下一个右括号。')
    print('     → 冻结证据目录不在扫描范围：那是原样保存的输入，改它等于让产物对不上输入。')
    sys.exit(1)

n = len(set(targets))
if n == 0:
    sys.exit(77)
print(f'  ✓ 编号与简称一致（扫 {n} 个文件，冻结证据按证据链原样保留）')
PY
