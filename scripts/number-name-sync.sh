#!/usr/bin/env bash
# gate-similar: doc-lint.sh 它判 markdown 里的「编号（简称）」；这一道把同一条判据延到 kb 之外的源码注释与记录。登记标题的解析两边各写了一份，没抽成共用：doc-lint 那份在 awk 里、按 markdown 的结构认，抽出来要先把它从 awk 里拆出来
# gate-similar: link-targets.py 它判文档里的相对链接与节序号，判的对象与判法都不同；读 .claude/doc-lint-exclude 的那一段两边都调 evidence-exclude.py，不各抄一份
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
REPOSITORY_ROOT="${1:-.}"
if ! cd "$REPOSITORY_ROOT" 2>/dev/null; then
  echo "  ✗ 找不到仓根：$REPOSITORY_ROOT" >&2
  echo "     → 怎么办：把仓根作为第一个参数传进来： bash scripts/number-name-sync.sh <仓根> [要扫的目录…]" >&2
  exit 2
fi
shift 2>/dev/null || true

# kb 目录登记（rules/kb-discipline.md）：.claude/kb-directories 一行一条，相对项目根，`#` 后写理由；
# 没有这份文件时就是默认的 .claude/kb。
# gate-overlap:copy-kept lib.sh 的 kb_directories 判法相同，这里不调它：这份脚本只声明 run-condition: command python3，
# source lib.sh 会额外带上它对 GNU awk 的硬要求，给这一道加一个它没声明过的环境依赖。
KB_DIRECTORIES=()
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
    KB_DIRECTORIES+=("${kb_path%/}")
  done < .claude/kb-directories
fi
if ((${#KB_DIRECTORIES[@]})); then KB_SCAN_DIRECTORIES=("${KB_DIRECTORIES[@]}"); else KB_SCAN_DIRECTORIES=(.claude/kb); fi
kb_any_exists=0
for kb_scan_directory in "${KB_SCAN_DIRECTORIES[@]}"; do [[ -d "$kb_scan_directory" ]] && kb_any_exists=1; done
((kb_any_exists)) || exit 77
export NUMBER_NAME_KB_DIRS="${KB_SCAN_DIRECTORIES[*]}"
export NUMBER_NAME_DIRS="$*"

python3 - <<'PY'
import re, glob, os, sys
sys.dont_write_bytecode = True
sys.path.insert(0, os.environ['NUMBER_NAME_PACKAGE_SCRIPTS'])
from preflight import load_package_module
PACKAGE_FAMILY = load_package_module('package_family', 'package-family.py')
EVIDENCE_EXCLUDE = load_package_module('evidence_exclude', 'evidence-exclude.py')

KB_SCAN_DIRECTORIES = [directory for directory in os.environ.get('NUMBER_NAME_KB_DIRS', '.claude/kb').split() if directory]

# 比对前与 doc-lint.sh 判「名字不符」同一个规整法：去掉强调标记 * 与 `，连续空白压成一个，去掉两端空白
def normalized_short_name(text):
    return re.sub(r'[ \t]+', ' ', re.sub(r'[*`]', '', text)).strip()

registered_short_name_by_number = {}
for kb_directory in KB_SCAN_DIRECTORIES:
  for registry_glob, number_prefix in ((os.path.join(kb_directory, 'experiments', '*.md'), 'E'), (os.path.join(kb_directory, 'decisions', '*.md'), 'D')):
    for registry_file in glob.glob(registry_glob):
        first_line = open(registry_file, encoding='utf-8').read().split('\n', 1)[0]
        heading_match = re.match(r'## (' + number_prefix + r'\d+) (.+?)\s*——', first_line)
        if heading_match:
            registered_short_name_by_number[heading_match.group(1)] = heading_match.group(2).strip()



SKIPPED_DIRECTORY_NAMES = {'.git', 'node_modules', 'target'}


# 装进项目的 SOP 副本不扫：它是上游的文件，判它等于在项目侧判上游。
SKIPPED_PATH_PREFIXES = tuple(directory.rstrip('/') + '/' for directory in KB_SCAN_DIRECTORIES) + (PACKAGE_FAMILY.installed_package_directory(),) + EVIDENCE_EXCLUDE.frozen_evidence_prefixes('.')
# 不扫 .sh / .py：脚本里的 `D1（简称）` 多半是格式说明或样本数据，扫它们假红压倒真红（实测）。
SCANNED_SUFFIXES = ('.rs', '.md')
given_directories = [directory for directory in os.environ.get('NUMBER_NAME_DIRS', '').split() if directory]
scan_roots = given_directories or ['.']
scanned_files = []
for scan_root in scan_roots:
    for directory, subdirectories, file_names in os.walk(scan_root):
        subdirectories[:] = [subdirectory for subdirectory in subdirectories if subdirectory not in SKIPPED_DIRECTORY_NAMES and subdirectory != 'fixtures']
        for name in file_names:
            if not name.endswith(SCANNED_SUFFIXES):
                continue
            path = os.path.normpath(os.path.join(directory, name))
            if any(path.startswith(prefix) for prefix in SKIPPED_PATH_PREFIXES):
                continue
            scanned_files.append(path)

mismatches = []
for scanned_file in sorted(set(scanned_files)):
    for line_number, line in enumerate(open(scanned_file, encoding='utf-8', errors='ignore'), 1):
        # 简称可以含一层全角括号：[^）]* 吃到第一个「）」就停，这类引用怎么写都判红（实测）。
        for number, written_short_name in re.findall(r'([ED]\d+)（((?:[^（）]|（[^（）]*）)*)）', line):
            if number in registered_short_name_by_number and normalized_short_name(registered_short_name_by_number[number]) != normalized_short_name(written_short_name):
                mismatches.append((scanned_file, line_number, number, written_short_name, registered_short_name_by_number[number]))

if mismatches:
    print('  ✗ 编号的简称与登记位不符：')
    # 默认只列前 15 处；NUMBER_NAME_SYNC_VERBOSE=1 逐处全列、不截断写的那一段（同 doc-lint 的 DOC_LINT_VERBOSE）
    is_verbose = os.environ.get('NUMBER_NAME_SYNC_VERBOSE') == '1'
    listed_mismatches = mismatches if is_verbose else mismatches[:15]
    for scanned_file, line_number, number, written_short_name, registered_short_name in listed_mismatches:
        written_text = written_short_name if is_verbose else written_short_name[:24]
        print(f'     {scanned_file}:{line_number}  {number} 写的「{written_text}」，登记处是「{registered_short_name}」')
    if len(mismatches) > len(listed_mismatches):
        print(f'     …… 另有 {len(mismatches)-len(listed_mismatches)} 处；全量清单：NUMBER_NAME_SYNC_VERBOSE=1')
    print('     → 简称照登记位抄（各正文首行 `## D<n> 简称 —— 状态`）。')
    print('     → 若是「）」写成了半角「)」，括注不闭合，正则会一路吃到下一个右括号。')
    print('     → 冻结证据目录不在扫描范围：那是原样保存的输入，改它等于让产物对不上输入。')
    sys.exit(1)

scanned_file_count = len(set(scanned_files))
if scanned_file_count == 0:
    sys.exit(77)
print(f'  ✓ 编号与简称一致（扫 {scanned_file_count} 个文件，冻结证据按证据链原样保留）')
PY
