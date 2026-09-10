#!/usr/bin/env bash
# 命名纪律里机器判得了的那一半（rules/code-discipline.md 的「名字」一节）。
#
#   naming-lint.sh <项目根>
#
# 扫项目里每个 .rs 文件，只看**我们自己声明的名字**：文件名、函数、参数、let / for / match /
# 闭包里的绑定、类型、字段、枚举成员、常量、模块、泛型参数、生命周期、标签、use-as 别名、
# 宏与宏变量。判两条：
#   N1 单字母：整个名字是一个字母，或者拆开后有一段是单个字母（后面跟数字也算）
#              —— i、T、'a、x_offset、t0。名字中间的 a 是英语冠词（is_not_a_directory），不判；
#              打头或结尾的 a 照判（a_levels、side_a），那是代号
#   N2 缩写：拆开后有一段在下面的缩写词表里，而项目没登记它 —— cnt、blk_hdr、CRC32Table
# 名字按下划线和大小写边界拆段：BlkHdr → blk、hdr；HTTPServer → http、server。
# 查词表时去掉尾部数字（crc32 按 crc 查），复数也认（args 按 arg 查）。
#
# 不判的，说清楚：
#   - 名字起得好不好、一个概念是不是全仓一个名字：语义，靠 review
#   - 外部定下的名字：trait 实现里的方法名、关联类型、关联常量（impl Display 里的 fmt），
#     extern 块里的整块声明，以及 Cargo 定的文件名 lib.rs、main.rs、mod.rs、build.rs。trait 实现的参数和函数体照查——那些名字是我们起的
#   - Rust 关键字与基本类型当一段出现（as_mut、to_u64）：语言规范就是它们那一处权威定义
#   - 认不出的形态（跨行的 let 模式、宏展开出来的名字、写在一行里的 trait 实现、
#     一行写完的 macro_rules）：认不出不等于通过，交给 review
#
# 项目侧两份配置，一行一条，`#` 后面写理由，理由不许省：
#   .claude/abbreviations         登记过的领域缩写：<缩写>  # <全称与含义>
#                                 项目自己的编号：<字母><数字>  # <登记在哪张表>（e<数字> 让 e57_x 合法）
#   .claude/naming-lint-exclude   不扫的目录或单个 .rs：<相对路径>  # 为什么（回扫旧代码时按文件列，改完删行）
# 行内豁免：那一行写 `// naming-lint:external <为什么这个名字不归我们定>`，理由同样不许省。
#
# 默认不扫 target/、.git/、.claude/（工具、样本、装进来的 SOP 副本），以及 $ROOT/scripts/fixtures/。
# 后一条写成相对 ROOT 的前缀：selftest 拿样本目录当 ROOT 跑时，样本照查
# （写成 */fixtures/* 的话样本永远被跳过，自检就成了摆设——doc-lint 踩过）。
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="${1:-$(project_root)}"
[[ -d "$ROOT" ]] || die "找不到项目根：$ROOT" \
  "把项目根作为第一个参数传进来： bash scripts/naming-lint.sh <项目根>"
if [[ "$ROOT" != "/" ]]; then ROOT="${ROOT%/}"; fi

# gate.sh 当阶段跑时已经打过同名标题（GATE_IN_STAGE 由 run_stage 设）
[[ -n "${GATE_IN_STAGE:-}" ]] || head1 "命名纪律"

trim() { local text="$1"; text="${text#"${text%%[![:space:]]*}"}"; printf '%s' "${text%"${text##*[![:space:]]}"}"; }
fails=0

# ── 不扫的目录 ──────────────────────────────────────────
# 排除一个目录，那里面的名字就没人管了，所以每条都要写明为什么，而且一律报出来：
# 静悄悄少扫一批文件，和这道检查没实现长得一模一样。判法与 doc-lint 的排除表同一套。
EXCL=(-not -path '*/target/*' -not -path "$ROOT/.git/*" -not -path "$ROOT/.claude/*"
      -not -path "$ROOT/scripts/fixtures/*")
EXFILE="$ROOT/.claude/naming-lint-exclude"
expaths=(); exwhys=(); exns=()
if [[ -f "$EXFILE" ]]; then
  exline=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    exline=$((exline+1))
    [[ -z "${line//[[:space:]]/}" || "${line#"${line%%[![:space:]]*}"}" == \#* ]] && continue
    if [[ "$line" != *\#* ]]; then
      bad ".claude/naming-lint-exclude:$exline  这一条没写理由：$line"
      howto "格式： research/  # 实验代码与产物一一对应，改名要连同重跑" \
            "理由不许省：排除一个目录，那里面的名字就没人管了（rules/code-discipline.md）。"
      fails=$((fails+1)); continue
    fi
    expath="$(trim "${line%%#*}")"; exwhy="$(trim "${line#*#}")"
    expath="${expath%/}"
    if [[ -z "$exwhy" ]]; then
      bad ".claude/naming-lint-exclude:$exline  # 后面是空的，等于没写理由"
      howto "在 # 后面写清为什么这批代码的名字不归这道检查管。"
      fails=$((fails+1)); continue
    fi
    if [[ -z "$expath" || "$expath" == "." || "$expath" == /* || "$expath" == *..* ]]; then
      bad ".claude/naming-lint-exclude:$exline  路径不合法：「$expath」"
      howto "只收项目根之下的相对子目录，例： research/" \
            "不收 . 、绝对路径、含 .. 的路径——那些一行就能把整棵树排掉。"
      fails=$((fails+1)); continue
    fi
    # 一条排除可以是目录，也可以是单个 .rs 文件。后者用来回扫旧代码：还没改完的文件逐个列进来，
    # 改完一个删一行，新文件照查——排除的范围只缩不涨。
    if [[ -f "$ROOT/$expath" && "$expath" == *.rs ]]; then
      EXCL+=(-not -path "$ROOT/$expath")
      expaths+=("$expath"); exwhys+=("$exwhy"); exns+=(1)
      continue
    fi
    if [[ ! -d "$ROOT/$expath" ]]; then
      bad ".claude/naming-lint-exclude:$exline  目录或 .rs 文件不存在：$expath"
      howto "路径拼错了就改对；那批代码已经挪走、删了或改完了，就把这一行删掉。" \
            "留着的排除项会让人以为还有东西在被绕开。"
      fails=$((fails+1)); continue
    fi
    exn="$(find "$ROOT/$expath" -name '*.rs' -type f -not -path '*/target/*' | wc -l)"
    if [[ "$exn" -eq 0 ]]; then
      bad ".claude/naming-lint-exclude:$exline  $expath 下一个 .rs 都没有，这条排除没有作用"
      howto "删掉这一行。不起作用的排除项只会让人以为那批文件被绕开了。"
      fails=$((fails+1)); continue
    fi
    EXCL+=(-not -path "$ROOT/$expath/*")
    expaths+=("$expath/"); exwhys+=("$exwhy"); exns+=("$exn")
  done < "$EXFILE"
fi

# ── 缩写登记表 ──────────────────────────────────────────
# 登记表就是这个缩写唯一的权威定义（rules/kb-discipline.md：同一个事实只许有一处）。
# 所以不写含义的、单字母的、登记两遍的，都判红：它们让「这个缩写指什么」答不上来。
ABFILE="$ROOT/.claude/abbreviations"
declare -A REGISTERED=()
declare -A NUMBERED=()
numbered_re='^([a-z])<数字>$'
if [[ -f "$ABFILE" ]]; then
  abline=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    abline=$((abline+1))
    [[ -z "${line//[[:space:]]/}" || "${line#"${line%%[![:space:]]*}"}" == \#* ]] && continue
    if [[ "$line" != *\#* ]]; then
      bad ".claude/abbreviations:$abline  这一条没写全称和含义：$line"
      howto "格式： lba  # logical block address：逻辑块地址" \
            "登记表就是这个缩写唯一的权威定义，不写含义等于没登记（rules/code-discipline.md）。"
      fails=$((fails+1)); continue
    fi
    token="$(trim "${line%%#*}")"; meaning="$(trim "${line#*#}")"
    if [[ -z "$meaning" ]]; then
      bad ".claude/abbreviations:$abline  # 后面是空的，等于没写含义：$token"
      howto "在 # 后面写全称，以及它在这个项目里指什么。"
      fails=$((fails+1)); continue
    fi
    # 项目自己的编号（kb 里登记的 E57、D22 这类）：登记的是「这个字母加数字」这一整类，
    # 权威定义在登记它的那张表里。登记之后 e57_field_authority 里的 e57 不再算单字母。
    if [[ "$token" =~ $numbered_re ]]; then
      letter="${BASH_REMATCH[1]}"
      if [[ -n "${NUMBERED[$letter]:-}" ]]; then
        bad ".claude/abbreviations:$abline  重复登记：$token（第 ${NUMBERED[$letter]} 行已经登记过）"
        howto "一种编号只许有一处定义，删掉其中一行（rules/kb-discipline.md：矛盾比空白更糟）。"
        fails=$((fails+1)); continue
      fi
      NUMBERED[$letter]="$abline"; continue
    fi
    if [[ "$token" =~ ^[a-z][0-9]*$ ]]; then
      bad ".claude/abbreviations:$abline  单字母不许登记：$token"
      howto "一个字母没有唯一的含义，登记了也说不清它指什么。" \
            "把用到它的名字写全（rules/code-discipline.md 的「名字」一节）。"
      fails=$((fails+1)); continue
    fi
    if [[ ! "$token" =~ ^[a-z][a-z0-9]*$ ]]; then
      bad ".claude/abbreviations:$abline  缩写要写成小写字母开头的一段字母数字：「$token」"
      howto "登记的是名字拆开之后的一段，一律小写，例： lba、crc32c。" \
            "名字里写成 Lba、LBA 的，拆段之后都按 lba 查。"
      fails=$((fails+1)); continue
    fi
    if [[ -n "${REGISTERED[$token]:-}" ]]; then
      bad ".claude/abbreviations:$abline  重复登记：$token（第 ${REGISTERED[$token]} 行已经登记过）"
      howto "一个缩写只许有一处定义，删掉其中一行（rules/kb-discipline.md：矛盾比空白更糟）。"
      fails=$((fails+1)); continue
    fi
    REGISTERED[$token]="$abline"
  done < "$ABFILE"
fi

files=()
while IFS= read -r f; do files+=("$f"); done < <(find "$ROOT" -name '*.rs' -type f "${EXCL[@]}" | sort)

if [[ ${#expaths[@]} -gt 0 ]]; then
  total_excluded=0; for i in "${!expaths[@]}"; do total_excluded=$((total_excluded+exns[i])); done
  warn "按 .claude/naming-lint-exclude 不扫 $total_excluded 个 .rs —— 那里面的名字没人管："
  for i in "${!expaths[@]}"; do warn "  ${expaths[$i]}  （${exns[$i]} 个）—— ${exwhys[$i]}"; done
fi
if [[ $fails -gt 0 ]]; then
  bad "命名纪律的配置有 $fails 处不合规，名字这一轮没有查"   # gate-lint:summary
  exit 1
fi
if [[ ${#files[@]} -eq 0 ]]; then
  ok "没有要查的 .rs 文件（${#files[@]} 个），本阶段不适用"
  exit 0
fi

# ── 缩写词表：<缩写> <该写成什么> ─────────────────────────
# 只列最常见的那些。**词表外的缩写照样违规**，只是这道检查看不见（rules/code-discipline.md）。
# 不收 Rust 关键字（mut、fn、ref、impl、mod、dyn、str……）：语言规范是它们那一处定义。
# 不收本身就是英语单词的（off、opt、mid）：turn_off、opt_in 会被误拒，门禁一误拒人就绕过它。
ABBR_TABLE="$(cat <<'TABLE'
acc accumulator / account
ack acknowledgement
addr address
agg aggregate
alloc allocation / allocator
alt alternative
arg argument
arr array
attr attribute
auth authentication / authorization（两个意思，必须写全）
avg average
blk block
buf buffer
calc calculate / calculation
cap capacity / capability / upper_limit（几个意思，必须写全）
cb callback
cfg configuration
chk check
cksum checksum
cmd command
cmp compare / comparison
cnt count
col column
cond condition
conf configuration
config configuration
conn connection
cow copy_on_write（std 的 Cow 是 clone-on-write，两者别混）
crc cyclic_redundancy_check
csum checksum
ctl control
ctr counter
ctx context
cur current / cursor
curr current
db database
dec decrement / decimal
decl declaration
def definition / default
del delete / delta / delimiter
desc description / descriptor / descending
dest destination
dev device
dir directory / direction
doc document
dst destination
dup duplicate
elem element
env environment
eq equal
err error
evt event
exec execute
expr expression
ext extent / extension / external（文件系统里三个都常见）
fd file_descriptor
fmt format
freq frequency
fs file_system
func function
gb gigabyte / gibibyte（1000 还是 1024 要写清）
gen generation / generator
hdr header
hi high / upper
id identifier
idx index
inc increment / include
info information
init initialize / initial
ino inode_number
io input_output
iter iterator
kb kilobyte / kibibyte / knowledge_base（几个意思，必须写全）
lba logical_block_address
len length（字节数还是个数要写清）
lhs left_hand_side
lib library
lim limit
ln line / natural_logarithm
lo low / lower
loc location / lines_of_code
lsn log_sequence_number
lvl level
max maximum
mb megabyte / mebibyte（1000 还是 1024 要写清）
mem memory
mgr manager
min minimum / minute
misc miscellaneous
ms milliseconds
msg message
neg negative
nr number
ns nanoseconds / namespace
num number / numerator
nxt next
obj object
op operation / operator
opts options
os operating_system
param parameter
pba physical_block_address
pct percent
perf performance
pkt packet
pos position / positive
prev previous
proc process / procedure
ptr pointer
pwd password / working_directory
qty quantity
rcv receive
rec record / receive / recursive
req request
res result / resource / response
resp response
ret return_value
rhs right_hand_side
sb superblock
sec second / section
seq sequence / sequential
sig signal / signature
sock socket
spec specification
src source
srv server
stat statistic / status
stmt statement
sys system
sz size
tb terabyte / table
tbl table
temp temporary / temperature
tmp temporary
ts timestamp
tx transaction / transmit
txn transaction
us microseconds
usr user
util utility
val value
var variable
ver version
wal write_ahead_log
TABLE
)"

# ── 扫描程序 ────────────────────────────────────────────
# 一行一行读，先剥掉注释、字符串、字符字面量（生命周期留着），再在剩下的代码里认声明处。
# 代码块用一个栈记着「现在在哪种块里」：字段只在 struct 体里认，枚举成员只在 enum 体里认，
# trait 实现里的方法名不判，extern 块整块不判。
# 输出一行一条：V 违规 / M 标记缺理由 / X 被行内豁免的行 / S 声明总数。
NAMING_AWK="$(cat <<'AWK'
BEGIN {
  n = split(ENVIRON["NAMING_ABBR"], rows, "\n")
  for (i = 1; i <= n; i++) {
    if (rows[i] ~ /^[ \t]*$/) continue
    key = rows[i]; sub(/[ \t].*$/, "", key)
    val = rows[i]; sub(/^[^ \t]+[ \t]+/, "", val)
    ABBR[key] = val
  }
  n = split(ENVIRON["NAMING_ALLOW"], rows, " ")
  for (i = 1; i <= n; i++) if (rows[i] != "") ALLOW[rows[i]] = 1
  n = split(ENVIRON["NAMING_NUMBERED"], rows, " ")
  for (i = 1; i <= n; i++) if (rows[i] != "") NUMBERED_LETTER[rows[i]] = 1
  n = split("mut ref box true false self Self crate super in if else as dyn impl move where", words, " ")
  for (i = 1; i <= n; i++) PATKW[words[i]] = 1
  n = split("self Self super crate static _", words, " ")
  for (i = 1; i <= n; i++) NONAME[words[i]] = 1
  n = split("block expr ident item lifetime literal meta pat pat_param path stmt tt ty vis", words, " ")
  for (i = 1; i <= n; i++) FRAGMENT[words[i]] = 1
  n = split("lib main mod build", words, " ")
  for (i = 1; i <= n; i++) CARGO_FILE[words[i]] = 1
  root = ENVIRON["NAMING_ROOT"] "/"
  total_decls = 0
}

FNR == 1 {
  rel = FILENAME
  if (index(rel, root) == 1) rel = substr(rel, length(root) + 1)
  blockdepth = 0; instr = 0; rawhashes = -1
  sp = 0; pending = ""; hdrbuf = ""; pdepth = 0
  sig = 0; sigstarted = 0; sigdepth = 0; sigangle = 0; parambuf = ""
  inuse = 0
  delete seen
  base = rel; sub(/^.*\//, "", base); sub(/\.rs$/, "", base)
  if (!(base in CARGO_FILE)) judge(base, "文件名")
}

{
  raw = $0
  code = strip(raw)
  skipline = 0
  if (raw ~ /naming-lint:external/) {
    why = raw; sub(/.*naming-lint:external/, "", why)
    gsub(/\*\//, "", why); gsub(/^[ \t:：]+|[ \t]+$/, "", why)
    if (why == "") printf "M\t%s\t%d\n", rel, FNR
    else { skipline = 1; printf "X\t%s\t%d\t%s\n", rel, FNR, why }
  }
  ctx = (sp > 0) ? stack[sp] : "file"
  if (!skipline && ctx != "extern") {
    if (ctx != "macro") declarations(code, ctx)
    macro_vars(code)
  }
  track(code)
}

END { printf "S\t%d\n", total_decls }

# ── 剥注释、字符串、字符字面量 ─────────────────────────
function strip(line,    out, i, n, c, two, j, k, prevc) {
  out = ""; n = length(line); i = 1
  while (i <= n) {
    c = substr(line, i, 1)
    if (blockdepth > 0) {
      two = substr(line, i, 2)
      if (two == "*/") { blockdepth--; i += 2; continue }
      if (two == "/*") { blockdepth++; i += 2; continue }
      i++; continue
    }
    if (instr) {
      if (c == "\\") { i += 2; continue }
      if (c == "\"") { instr = 0; out = out "\""; i++; continue }
      i++; continue
    }
    if (rawhashes >= 0) {
      if (c == "\"" && substr(line, i + 1, rawhashes) == hashes(rawhashes)) {
        out = out "\""; i += 1 + rawhashes; rawhashes = -1; continue
      }
      i++; continue
    }
    two = substr(line, i, 2)
    if (two == "//") break
    if (two == "/*") { blockdepth = 1; i += 2; continue }
    prevc = (out == "") ? "" : substr(out, length(out), 1)
    if (prevc !~ /[A-Za-z0-9_]/) {
      j = 0
      if (c == "r") j = i + 1
      else if (c == "b" && substr(line, i + 1, 1) == "r") j = i + 2
      if (j > 0) {
        k = j; while (substr(line, k, 1) == "#") k++
        if (substr(line, k, 1) == "\"") { rawhashes = k - j; out = out "\""; i = k + 1; continue }
        if (c == "r" && k == j + 1 && substr(line, k, 1) ~ /[A-Za-z_]/) { i = k; continue }
      }
    }
    if (c == "\"") { instr = 1; out = out "\""; i++; continue }
    if (c == "'") {
      if (substr(line, i + 1, 1) == "\\") {
        k = index(substr(line, i + 3), "'")
        if (k > 0) { out = out "''"; i = i + 3 + k; continue }
      } else if (substr(line, i + 2, 1) == "'" && substr(line, i + 1, 1) != "'") {
        out = out "''"; i += 3; continue
      }
    }
    out = out c; i++
  }
  return out
}
function hashes(count,    text) { text = ""; while (count-- > 0) text = text "#"; return text }

# ── 块栈：这一行之后我们在哪种块里 ──────────────────────
function item_start(before) {
  return before ~ /^[ \t]*$/ || before ~ /[;{}\]][ \t]*$/ ||
         before ~ /(^|[^A-Za-z0-9_])(pub|unsafe|default)[ \t]*$/ || before ~ /pub\([^)]*\)[ \t]*$/
}
function track(code,    i, j, n, c, word, before, after, kind) {
  n = length(code); i = 1
  while (i <= n) {
    c = substr(code, i, 1)
    if (c ~ /[A-Za-z_]/) {
      j = i; while (j <= n && substr(code, j, 1) ~ /[A-Za-z0-9_]/) j++
      word = substr(code, i, j - i)
      before = substr(code, 1, i - 1)
      after = substr(code, j)
      if (before !~ /[A-Za-z0-9_'$]$/) {
        if (word == "fn" && after ~ /^[ \t]+[A-Za-z_]/) { pending = "fn"; hdrbuf = ""; pdepth = 0 }
        else if (word == "impl" && pending != "fn" && item_start(before)) { pending = "impl"; hdrbuf = ""; pdepth = 0 }
        else if ((word == "struct" || word == "union") && after ~ /^[ \t]+[A-Za-z_]/) { pending = "struct"; pdepth = 0 }
        else if (word == "enum" && after ~ /^[ \t]+[A-Za-z_]/) { pending = "enum"; pdepth = 0 }
        else if (word == "trait" && after ~ /^[ \t]+[A-Za-z_]/) { pending = "trait"; pdepth = 0 }
        else if (word == "mod" && after ~ /^[ \t]+[A-Za-z_]/) { pending = "mod"; pdepth = 0 }
        else if (word == "macro_rules") { pending = "macro"; pdepth = 0 }
        else if (word == "extern" && after ~ /^[ \t]*(""[ \t]*)?\{/) { pending = "extern"; pdepth = 0 }
      }
      if (pending == "impl") hdrbuf = hdrbuf " " word
      i = j; continue
    }
    if (pending == "impl") hdrbuf = hdrbuf c
    if (c == "(" || c == "[") pdepth++
    else if (c == ")" || c == "]") { if (pdepth > 0) pdepth-- }
    else if (c == "{") {
      kind = "block"
      if (pending == "impl") kind = (hdrbuf ~ /[^A-Za-z0-9_]for[ \t]/) ? "trait_impl" : "impl"
      else if (pending != "") kind = pending
      else if (sp > 0 && stack[sp] == "enum") kind = "fields"
      stack[++sp] = kind
      pending = ""; hdrbuf = ""; pdepth = 0
    }
    else if (c == "}") { if (sp > 0) sp--; pending = ""; hdrbuf = "" }
    else if (c == ";" && pdepth == 0) { pending = ""; hdrbuf = "" }
    i++
  }
  if (pending == "impl") hdrbuf = hdrbuf " "
}

# ── 这一行声明了哪些名字 ────────────────────────────────
function declarations(code, ctx,    work, rest, m, g, line) {
  # 上一行的函数签名还没收尾（参数分几行写）
  if (sig) scan_params(code)

  # 函数名、它的泛型参数、它的参数
  work = code
  while (match(work, /(^|[^A-Za-z0-9_])fn[ \t]+([A-Za-z_][A-Za-z0-9_]*)/, m)) {
    if (ctx != "trait_impl") judge(m[2], "函数")
    rest = substr(work, RSTART + RLENGTH)
    if (rest ~ /^[ \t]*</) { g = angle(rest); judge_generics(g); rest = substr(rest, ANGLE_END + 1) }
    sig = 1; sigstarted = 0; sigdepth = 0; sigangle = 0; parambuf = ""
    scan_params(rest)
    work = rest
  }

  # 类型：struct / enum / union / trait / type，以及它们的泛型参数
  work = code
  while (match(work, /(^|[^A-Za-z0-9_])(struct|enum|union|trait|type)[ \t]+([A-Za-z_][A-Za-z0-9_]*)/, m)) {
    rest = substr(work, RSTART + RLENGTH)
    if (!(ctx == "trait_impl" && m[2] == "type")) judge(m[3], "类型")
    if (rest ~ /^[ \t]*</) { g = angle(rest); judge_generics(g); rest = substr(rest, ANGLE_END + 1) }
    if ((m[2] == "struct" || m[2] == "union") && match(rest, /\{/)) same_line_fields(substr(rest, RSTART + 1))
    if (m[2] == "enum" && match(rest, /\{/)) same_line_variants(substr(rest, RSTART + 1))
    work = rest
  }
  if (match(code, /(^|[^A-Za-z0-9_])impl[ \t]*</)) { g = angle(substr(code, RSTART + RLENGTH - 1)); judge_generics(g) }

  # 常量、模块、宏
  if (match(code, /^[ \t]*(pub(\([^)]*\))?[ \t]+)?(const|static)[ \t]+(mut[ \t]+)?([A-Za-z_][A-Za-z0-9_]*)[ \t]*:/, m))
    if (ctx != "trait_impl") judge(m[5], "常量")
  if (match(code, /^[ \t]*(pub(\([^)]*\))?[ \t]+)?mod[ \t]+([A-Za-z_][A-Za-z0-9_]*)/, m)) judge(m[3], "模块")
  if (match(code, /macro_rules![ \t]*([A-Za-z_][A-Za-z0-9_]*)/, m)) judge(m[1], "宏")

  # use … as 别名（跨行的 use 组也认）
  if (code ~ /^[ \t]*(pub(\([^)]*\))?[ \t]+)?use[ \t]/) inuse = 1
  if (inuse) {
    work = code
    while (match(work, /(^|[^A-Za-z0-9_])as[ \t]+([A-Za-z_][A-Za-z0-9_]*)/, m)) { judge(m[2], "别名"); work = substr(work, RSTART + RLENGTH) }
    if (code ~ /;/) inuse = 0
  }

  # 标签
  work = code
  while (match(work, /'([A-Za-z_][A-Za-z0-9_]*):[ \t]*(loop|while|for|\{)/, m)) { judge("'" m[1], "标签"); work = substr(work, RSTART + RLENGTH) }

  # let / if let / while let
  work = code
  while (match(work, /(^|[^A-Za-z0-9_])let[ \t]+/)) {
    rest = substr(work, RSTART + RLENGTH)
    bind_pattern(pattern_head(rest), "变量")
    work = rest
  }

  # for <模式> in
  work = code
  while (match(work, /(^|[^A-Za-z0-9_])for[ \t]+/)) {
    rest = substr(work, RSTART + RLENGTH)
    if (match(rest, /[ \t]in([ \t]|$)/)) {
      g = substr(rest, 1, RSTART - 1)
      if (g !~ /[{};=<]/) bind_pattern(g, "循环变量")
    }
    work = rest
  }

  closures(code)
  if (code !~ /macro_rules!/) match_arms(code)

  # 字段与枚举成员：只在 struct / enum 体里认
  if (ctx == "struct" || ctx == "fields") { line = code; sub(/^[ \t]*(#\[[^]]*\][ \t]*)+/, "", line); same_line_fields(line) }
  if (ctx == "enum") { line = code; sub(/^[ \t]*(#\[[^]]*\][ \t]*)+/, "", line); variant_item(line) }
}

function macro_vars(code,    work, m) {
  work = code
  while (match(work, /\$([A-Za-z_][A-Za-z0-9_]*)[ \t]*:[ \t]*([a-z_]+)/, m)) {
    if (m[2] in FRAGMENT) judge(m[1], "宏变量")
    work = substr(work, RSTART + RLENGTH)
  }
}

# 从文本开头的 < 起，取出配对的 <…> 里面的内容；ANGLE_END 是收尾的 > 在 text 里的位置
function angle(text,    i, n, c, depth, start) {
  n = length(text); depth = 0; start = 0; ANGLE_END = n
  for (i = 1; i <= n; i++) {
    c = substr(text, i, 1)
    if (c == "<") { depth++; if (depth == 1) start = i + 1 }
    else if (c == ">" && substr(text, i - 1, 1) != "-") {
      depth--
      if (depth == 0) { ANGLE_END = i; return substr(text, start, i - start) }
    }
  }
  return (start > 0) ? substr(text, start) : ""
}

function judge_generics(g,    n, items, i, item, m) {
  n = split_top(g, items)
  for (i = 1; i <= n; i++) {
    item = items[i]; sub(/^[ \t]+/, "", item)
    if (match(item, /^'([A-Za-z_][A-Za-z0-9_]*)/, m)) judge("'" m[1], "生命周期")
    else if (match(item, /^const[ \t]+([A-Za-z_][A-Za-z0-9_]*)/, m)) judge(m[1], "泛型参数")
    else if (match(item, /^([A-Za-z_][A-Za-z0-9_]*)/, m)) judge(m[1], "泛型参数")
  }
}

# 按顶层逗号切开（括号、方括号、花括号、尖括号里的逗号不算；-> 的 > 不算）
function split_top(text, out,    i, n, c, depth, item, count) {
  depth = 0; item = ""; count = 0; n = length(text)
  for (i = 1; i <= n; i++) {
    c = substr(text, i, 1)
    if (c == "(" || c == "[" || c == "{" || c == "<") depth++
    else if (c == ")" || c == "]" || c == "}") depth--
    else if (c == ">" && substr(text, i - 1, 1) != "-") depth--
    else if (c == "," && depth == 0) { out[++count] = item; item = ""; continue }
    item = item c
  }
  if (item ~ /[^ \t]/) out[++count] = item
  return count
}

# 模式到哪儿为止：顶层的 =（不是 == / =>）、单冒号（类型标注）、分号，或者多出来的右括号
function pattern_head(text,    i, n, c, depth, next_char, prev_char) {
  depth = 0; n = length(text)
  for (i = 1; i <= n; i++) {
    c = substr(text, i, 1); next_char = substr(text, i + 1, 1); prev_char = substr(text, i - 1, 1)
    if (c == "(" || c == "[" || c == "{") depth++
    else if (c == ")" || c == "]" || c == "}") { if (depth == 0) return substr(text, 1, i - 1); depth-- }
    else if (depth == 0 && c == "=" && next_char != "=" && next_char != ">") return substr(text, 1, i - 1)
    else if (depth == 0 && c == ":" && next_char != ":" && prev_char != ":") return substr(text, 1, i - 1)
    else if (depth == 0 && c == ";") return substr(text, 1, i - 1)
  }
  return text
}

# 从模式里挑出绑定：跳过路径段、字段名、变体名、关键字、方法调用
function bind_pattern(pattern, kind,    rest, consumed, name, before, after) {
  rest = pattern; consumed = ""
  while (match(rest, /[A-Za-z_][A-Za-z0-9_]*/)) {
    name = substr(rest, RSTART, RLENGTH)
    before = consumed substr(rest, 1, RSTART - 1)
    after = substr(rest, RSTART + RLENGTH)
    consumed = before name
    rest = after
    if (before ~ /(::|\.|'|\$|[0-9])[ \t]*$/) continue
    if (after ~ /^[ \t]*(::|\(|\{|!)/) continue
    if (after ~ /^[ \t]*:([^:]|$)/) continue
    if (name ~ /^[A-Z]/) continue
    if (name in PATKW) continue
    judge(name, kind)
  }
}

# 函数参数：可能跨行，括号配对着读，读到收尾的 ) 为止
function scan_params(text,    i, n, c) {
  n = length(text)
  for (i = 1; i <= n; i++) {
    c = substr(text, i, 1)
    if (!sigstarted) {
      if (c == "(") { sigstarted = 1; sigdepth = 1; sigangle = 0; parambuf = ""; continue }
      if (c == "{" || c == ";") { sig = 0; return }
      continue
    }
    if (c == "(" || c == "[" || c == "{") sigdepth++
    else if (c == "<") sigangle++
    else if (c == ">" && substr(text, i - 1, 1) != "-") { if (sigangle > 0) sigangle-- }
    else if (c == ")" || c == "]" || c == "}") {
      sigdepth--
      if (sigdepth == 0) { param_chunk(parambuf); parambuf = ""; sig = 0; return }
    }
    else if (c == "," && sigdepth == 1 && sigangle == 0) { param_chunk(parambuf); parambuf = ""; continue }
    parambuf = parambuf c
  }
  parambuf = parambuf " "
}
function param_chunk(chunk) { if (chunk ~ /[^ \t]/) bind_pattern(pattern_head(chunk), "参数") }

# 闭包参数 |a, b: T|：开头那根 | 前面得是 ( , = { move return 或者行首
function closures(code,    i, n, k, prev, params, items, count, index_of_item) {
  n = length(code)
  for (i = 1; i <= n; i++) {
    if (substr(code, i, 1) != "|") continue
    if (substr(code, i + 1, 1) == "|") { i++; continue }
    prev = substr(code, 1, i - 1); sub(/[ \t]+$/, "", prev)
    if (!(prev == "" || prev ~ /[(,={]$/ || prev ~ /(^|[^A-Za-z0-9_])(move|return)$/)) continue
    k = index(substr(code, i + 1), "|")
    if (k == 0) return
    params = substr(code, i + 1, k - 1)
    delete items
    count = split_top(params, items)
    for (index_of_item = 1; index_of_item <= count; index_of_item++)
      bind_pattern(pattern_head(items[index_of_item]), "闭包参数")
    i = i + k
  }
}

# match 臂：=> 往回找到模式的起点（顶层的 , { ( [ 或者行首），守卫 if 之后的不算
function match_arms(code,    work, position, j, c, depth, start, pattern) {
  work = code
  while ((position = index(work, "=>")) > 0) {
    depth = 0; start = 1
    for (j = position - 1; j >= 1; j--) {
      c = substr(work, j, 1)
      if (c == ")" || c == "]" || c == "}") depth++
      else if (c == "(" || c == "[" || c == "{") { if (depth == 0) { start = j + 1; break } depth-- }
      else if (c == "," && depth == 0) { start = j + 1; break }
    }
    pattern = substr(work, start, position - start)
    sub(/^[ \t]*\|/, "", pattern)
    if (match(pattern, /(^|[^A-Za-z0-9_])if[ \t]/)) pattern = substr(pattern, 1, RSTART)
    bind_pattern(pattern, "匹配绑定")
    work = substr(work, position + 2)
  }
}

# struct 体里的字段（一行里写几个也认）
function same_line_fields(text,    rest, m) {
  rest = text
  while (match(rest, /(^|[,{])[ \t]*(pub(\([^)]*\))?[ \t]+)?([A-Za-z_][A-Za-z0-9_]*)[ \t]*:([^:]|$)/, m)) {
    judge(m[4], "字段")
    rest = substr(rest, RSTART + RLENGTH)
  }
}

# enum 头所在那一行里就写了成员：enum Choice { First, Second(u8), Third { value: u8 } }
function same_line_variants(text,    i, n, c, depth, item) {
  depth = 0; item = ""; n = length(text)
  for (i = 1; i <= n; i++) {
    c = substr(text, i, 1)
    if (c == "(" || c == "{" || c == "[" || c == "<") depth++
    else if (c == ")" || c == "]") depth--
    else if (c == ">" && substr(text, i - 1, 1) != "-") depth--
    else if (c == "}") { if (depth == 0) { variant_item(item); return } depth-- }
    else if (c == "," && depth == 0) { variant_item(item); item = ""; continue }
    item = item c
  }
  variant_item(item)
}
function variant_item(item,    m) {
  if (match(item, /^[ \t]*(#\[[^]]*\][ \t]*)*([A-Za-z_][A-Za-z0-9_]*)/, m)) {
    judge(m[2], "枚举成员")
    if (match(item, /\{/)) same_line_fields(substr(item, RSTART + 1))
  }
}

# ── 判一个名字 ──────────────────────────────────────────
function judge(name, kind,    core, key, lowered, n, parts, i, part, stripped, stem, reason) {
  core = name; sub(/^'/, "", core); sub(/^r#/, "", core)
  if (core == "" || (core in NONAME)) return
  key = FNR SUBSEP kind SUBSEP name
  if (key in seen) return
  seen[key] = 1
  total_decls++
  gsub(/^_+|_+$/, "", core)
  if (core == "") return
  if (length(core) == 1) { violation(kind, name, "单字母"); return }
  lowered = gensub(/([a-z0-9])([A-Z])/, "\\1_\\2", "g", core)
  lowered = gensub(/([A-Z]+)([A-Z][a-z])/, "\\1_\\2", "g", lowered)
  n = split(tolower(lowered), parts, /_+/)
  reason = ""
  for (i = 1; i <= n; i++) {
    part = parts[i]
    if (part == "" || part ~ /^[0-9]+$/) continue
    if (part ~ /^[uif](8|16|32|64|128)$/) continue
    stripped = part; sub(/[0-9]+$/, "", stripped)
    stem = (stripped ~ /..s$/) ? substr(stripped, 1, length(stripped) - 1) : ""
    if ((part in ALLOW) || (stripped in ALLOW) || (stem != "" && (stem in ALLOW))) continue
    if (part == "a" && i > 1 && i < n) continue
    if (part ~ /^[a-z][0-9]+$/ && (substr(part, 1, 1) in NUMBERED_LETTER)) continue
    if (part ~ /^[a-z][0-9]*$/) { reason = reason (reason == "" ? "" : "；") "「" part "」是单字母" (part ~ /[0-9]/ ? "加数字" : ""); continue }
    if (stripped in ABBR) { reason = reason (reason == "" ? "" : "；") "「" part "」是缩写，写全：" ABBR[stripped]; continue }
    if (stem != "" && (stem in ABBR)) { reason = reason (reason == "" ? "" : "；") "「" part "」是缩写的复数，写全：" ABBR[stem]; continue }
  }
  if (reason != "") violation(kind, name, reason)
}
function violation(kind, name, reason) { printf "V\t%s\t%d\t%s\t%s\t%s\n", rel, FNR, kind, name, reason }
AWK
)"

report="$(mktemp)"; trap 'rm -f "$report"' EXIT
NAMING_ABBR="$ABBR_TABLE" NAMING_ALLOW="${!REGISTERED[*]}" NAMING_NUMBERED="${!NUMBERED[*]}" NAMING_ROOT="$ROOT" \
  awk "$NAMING_AWK" "${files[@]}" > "$report" \
  || die "naming-lint 自己的扫描程序出错了（awk 退出码非零）" \
         "这是本脚本的缺陷，不是被查代码的问题。把上面 awk 的报错连同文件名报给维护 singlefs-ai-sop 的人。"

viol_lines=(); mark_lines=(); exempt_lines=(); ndecl=0
while IFS=$'\t' read -r tag field1 field2 field3 field4 field5; do
  case "$tag" in
    V) viol_lines+=("$field1:$field2  $field3 $field4 —— $field5") ;;
    M) mark_lines+=("$field1:$field2  naming-lint:external 后面没写理由") ;;
    X) exempt_lines+=("$field1:$field2 —— $field3") ;;
    S) ndecl="$field1" ;;
  esac
done < "$report"

if [[ ${#exempt_lines[@]} -gt 0 ]]; then
  warn "按 naming-lint:external 豁免 ${#exempt_lines[@]} 行（名字是外部定的）："
  for exempt_line in "${exempt_lines[@]}"; do warn "  $exempt_line"; done
fi
if [[ ${#mark_lines[@]} -gt 0 ]]; then
  for mark_line in "${mark_lines[@]}"; do say "        $mark_line"; done
  bad "${#mark_lines[@]} 处 naming-lint:external 没写理由，那几行照常查"
  howto "在标记后面写清为什么这个名字不归我们定，例： // naming-lint:external 字段名照外部格式的规范原样写" \
        "没有理由的豁免等于把这一行的检查关掉，而看的人不知道为什么。"
  fails=$((fails+1))
fi
if [[ ${#viol_lines[@]} -gt 0 ]]; then
  for viol_line in "${viol_lines[@]}"; do say "        $viol_line"; done
  bad "${#viol_lines[@]} 处名字不合命名纪律（查了 ${#files[@]} 个 .rs 文件、$ndecl 个声明的名字）"
  howto "照 rules/code-discipline.md 的「名字」一节改：缩写写全，单字母按它是什么来命名，名字长不要紧。" \
        "项目自己的领域缩写（lba、crc 这类）确实要用，就登记进 .claude/abbreviations：<缩写>  # <全称与含义>" \
        "名字是外部定的（外部格式的字段名这类），在那一行写 // naming-lint:external <为什么>" \
        "「e57」这类是项目登记过的编号，就在 .claude/abbreviations 登记 e<数字>  # <登记在哪张表>"
  fails=$((fails+1))
fi
[[ $fails -eq 0 ]] || exit 1
ok "命名纪律通过：查了 ${#files[@]} 个 .rs 文件、$ndecl 个声明的名字"
