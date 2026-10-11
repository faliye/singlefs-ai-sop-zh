#!/usr/bin/env bash
# gate-similar: doc-lint.sh 它判 markdown 里的「编号（简称）」；这一道把同一条判据延到 kb 之外的源码注释与记录。登记标题的解析两边各写了一份，没抽成共用：doc-lint 那份在 awk 里、按 markdown 的结构认，抽出来要先把它从 awk 里拆出来
# gate-similar: link-targets.py 读 .claude/doc-lint-exclude 的函数，它、这一道与 relay-timing-lint.py 各写了一份，三份已经分叉（结尾斜杠的处理不同），抽成共用要先定哪一份的行为对，没在加查重门禁的这一次动它们；SOP 副本目录两边都从 package-family.py 取
# admission: always 判的是此刻仓里的源码注释与记录，几秒跑完；每一轮门禁都现判
# run-condition: command python3
# 编号与简称在 doc-lint 够不到的地方也要一致。
#
# doc-lint.sh 只管 kb 里的 markdown；这一道管 kb 之外的源码注释（.rs）与记录（.md）
# （rules/kb-discipline.md 第 5 条：编号只能做索引，不能做称呼）。
#
# 登记位：只读 kb 目录（.claude/kb-directories 登记，没登记就是 .claude/kb）下 experiments/*.md（E 编号）与
#   decisions/*.md（D 编号）各文件的首行 `## <编号> <简称> —— <状态>`，与 doc-lint 的「登记标题」同形态。别处登记的编号这一道不认。
# 射程：默认扫仓根下的 .rs / .md（SCANNED_SUFFIXES；kb 目录、装进项目的 SOP 副本、fixtures 与冻结证据除外），
#   也可以把目录作为参数给，后缀照样只认这两种。
# 冻结证据按项目根的 .claude/doc-lint-exclude 绕开：原样保存的输入，要改只能连同重跑一起改（rules/evidence-discipline.md）。
#
# 用法：
#   number-name-sync.sh [仓根] [要扫的目录…]
# kb 目录不存在、或一个文件都没扫到时退 77（本次无对象可判），不报绿。
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/preflight.sh"
preflight "${BASH_SOURCE[0]}" "$@"; set -- ${PREFLIGHT_ARGUMENTS[@]+"${PREFLIGHT_ARGUMENTS[@]}"}
NUMBER_NAME_PACKAGE_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export NUMBER_NAME_PACKAGE_SCRIPTS
ROOT="${1:-.}"
if ! cd "$ROOT" 2>/dev/null; then
  echo "  ✗ 找不到仓根：$ROOT" >&2
  echo "     → 怎么办：把仓根作为第一个参数传进来： bash scripts/number-name-sync.sh <仓根> [要扫的目录…]" >&2
  exit 2
fi
shift 2>/dev/null || true

# kb 目录登记（rules/kb-discipline.md）：.claude/kb-directories 一行一条，相对项目根，`#` 后写理由；
# 没有这份文件时就是默认的 .claude/kb。
# gate-overlap:copy-kept lib.sh 的 kb_directories 判法相同，这里不调它：这份脚本只声明 run-condition: command python3，
# source lib.sh 会额外带上它对 GNU awk 的硬要求，给这一道加一个它没声明过的环境依赖。
KB_DIRS=()
if [[ -f .claude/kb-directories ]]; then
  kb_line_number=0
  while IFS= read -r kb_raw_line || [[ -n "$kb_raw_line" ]]; do
    kb_line_number=$((kb_line_number + 1))
    kb_stripped="${kb_raw_line#"${kb_raw_line%%[![:space:]]*}"}"
    [[ -z "$kb_stripped" || "$kb_stripped" == \#* ]] && continue
    kb_path="${kb_raw_line%%#*}"; kb_path="${kb_path%"${kb_path##*[![:space:]]}"}"; kb_path="${kb_path#"${kb_path%%[![:space:]]*}"}"
    kb_reason="${kb_raw_line#*#}"
    if [[ "$kb_raw_line" != *'#'* || -z "${kb_reason//[[:space:]]/}" || -z "$kb_path" ]]; then
      echo "  ✗ .claude/kb-directories:$kb_line_number 没写理由，或路径是空的：$kb_raw_line" >&2
      echo "     → 怎么办：一行一条： <相对项目根的路径>  # 为什么（理由不许省）。" >&2
      exit 2
    fi
    if [[ ! -d "$kb_path" ]]; then
      echo "  ✗ .claude/kb-directories:$kb_line_number 登记的目录不存在：$kb_path" >&2
      echo "     → 怎么办：改对路径（相对项目根），或删掉这一行。" >&2
      exit 2
    fi
    KB_DIRS+=("${kb_path%/}")
  done < .claude/kb-directories
fi
if ((${#KB_DIRS[@]})); then KB_SCAN_DIRS=("${KB_DIRS[@]}"); else KB_SCAN_DIRS=(.claude/kb); fi
kb_any_exists=0
for kb_scan_dir in "${KB_SCAN_DIRS[@]}"; do [[ -d "$kb_scan_dir" ]] && kb_any_exists=1; done
((kb_any_exists)) || exit 77
export NUMBER_NAME_KB_DIRS="${KB_SCAN_DIRS[*]}"
export NUMBER_NAME_DIRS="$*"

python3 - <<'PY'
import re, glob, os, sys
sys.dont_write_bytecode = True
sys.path.insert(0, os.environ['NUMBER_NAME_PACKAGE_SCRIPTS'])
from preflight import load_package_module
PACKAGE_FAMILY = load_package_module('package_family', 'package-family.py')

KB_SCAN_DIRS = [d for d in os.environ.get('NUMBER_NAME_KB_DIRS', '.claude/kb').split() if d]

truth = {}
for kb_dir in KB_SCAN_DIRS:
  for pat, pre in ((os.path.join(kb_dir, 'experiments', '*.md'), 'E'), (os.path.join(kb_dir, 'decisions', '*.md'), 'D')):
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


# 装进项目的 SOP 副本不扫：它是上游的文件，判它等于在项目侧判上游。
SKIP_PREFIX = tuple(d.rstrip('/') + '/' for d in KB_SCAN_DIRS) + (PACKAGE_FAMILY.installed_package_directory(),) + excluded_dirs()
# 不扫 .sh / .py：脚本里的 `D1（简称）` 多半是格式说明或样本数据，扫它们假红压倒真红（实测）。
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
        # 简称可以含一层全角括号：[^）]* 吃到第一个「）」就停，这类引用怎么写都判红（实测）。
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
