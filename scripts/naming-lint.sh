#!/usr/bin/env bash
# admission: always 判的是此刻全仓的文本，几秒跑完；每一轮门禁都现判，上一轮的结论不替这一轮作保
# run-condition: command gawk
# 命名纪律里机器判得了的那一半（rules/code-discipline.md 的「名字」一节）。
#
#   naming-lint.sh <项目根>
#
# 退出码：0 通过；1 判红（配置不合规或名字违规）；3 没有 .rs 可查（与 show-me-test 同约定，gate.sh 记本次未跑）。
#
# 扫每个 .rs 里我们自己声明的名字：文件名、函数、参数、let / for / match / 闭包里的绑定、类型、字段、枚举成员、
# 常量、模块、泛型参数、生命周期、标签、use-as 别名、宏与宏变量。判两条：
#   N1 单字母：整个名字或拆开后的一段是单个字母（后面跟数字也算）。名字中间的 a 是英语冠词（is_not_a_directory）不判，
#      打头或结尾的 a 是代号照判（a_levels、side_a）。
#   N2 缩写：拆开后有一段在 ABBR_TABLE 里而项目没登记。按下划线和大小写边界拆段（HTTPServer → http、server），
#      去掉尾部数字再查（crc32 按 crc 查），复数也认。
# 不判：外部定的名字（trait 实现里的方法名、关联类型与关联常量，extern 块，Cargo 定的 lib.rs、main.rs、mod.rs、build.rs；
#   trait 实现的参数和函数体照查）；当一段出现的 Rust 关键字与基本类型（as_mut、to_u64），语言规范是它们的定义。
#   语义（名字起得好不好、一个概念是不是全仓一个名字）与认不出的形态（跨行的 let 模式、宏展开出来的名字、
#   写在一行里的 trait 实现、一行写完的 macro_rules）判不了，不等于通过，靠 review。
# 项目侧两份配置，一行一条，`#` 后面写理由，理由不许省：
#   .claude/abbreviations         登记过的领域缩写：<缩写>  # <全称与含义>
#                                 项目自己的编号：<字母><数字>  # <登记在哪张表>（登记 e<数字> 之后 e12_x 合法）
#   .claude/naming-lint-exclude   不扫的目录或单个 .rs：<相对路径>  # 为什么（回扫旧代码时按文件列，改完删行）
# 行内豁免：那一行写 `// naming-lint:external <为什么这个名字不归我们定>`，理由同样不许省。
#
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight "${BASH_SOURCE[0]}" "$@"; set -- ${PREFLIGHT_ARGUMENTS[@]+"${PREFLIGHT_ARGUMENTS[@]}"}

PROJECT_ROOT="${1:-$(project_root)}"
[[ -d "$PROJECT_ROOT" ]] || die "找不到项目根：$PROJECT_ROOT" \
  "把项目根作为第一个参数传进来： bash scripts/naming-lint.sh <项目根>"
if [[ "$PROJECT_ROOT" != "/" ]]; then PROJECT_ROOT="${PROJECT_ROOT%/}"; fi

# gate.sh 当阶段跑时已经打过同名标题（GATE_IN_STAGE 由 run_stage 设）
[[ -n "${GATE_IN_STAGE:-}" ]] || head1 "命名纪律"

trim() { local text="$1"; text="${text#"${text%%[![:space:]]*}"}"; printf '%s' "${text%"${text##*[![:space:]]}"}"; }
failure_count=0

# ── 不扫的目录 ──────────────────────────────────────────
# 排除的目录里名字没人管，所以每条要写理由、一律报出来：静悄悄少扫一批文件，和这道检查没实现长得一样。
# 默认那几处（target/、.git/、.claude/、$PROJECT_ROOT/scripts/fixtures/）在 lib.sh 的 rust_source_files 里，与「构建与单测」共用；这里只追加排除表里的。
# 样本目录写成相对 PROJECT_ROOT 的前缀：写成 */fixtures/* 的话 selftest 拿样本目录当 PROJECT_ROOT 跑时样本全被跳过，自证成了摆设。
EXCLUDED_PATH_ARGUMENTS=()
EXCLUDE_FILE="$PROJECT_ROOT/.claude/naming-lint-exclude"
excluded_paths=(); excluded_reasons=(); excluded_file_counts=()
if [[ -f "$EXCLUDE_FILE" ]]; then
  exclude_line_number=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    exclude_line_number=$((exclude_line_number+1))
    [[ -z "${line//[[:space:]]/}" || "${line#"${line%%[![:space:]]*}"}" == \#* ]] && continue
    if [[ "$line" != *\#* ]]; then
      bad ".claude/naming-lint-exclude:$exclude_line_number  这一条没写理由：$line"
      howto "格式： research/  # 实验代码与产物一一对应，改名要连同重跑" \
            "理由不许省：排除一个目录，那里面的名字就没人管了（rules/code-discipline.md）。"
      failure_count=$((failure_count+1)); continue
    fi
    excluded_path="$(trim "${line%%#*}")"; excluded_reason="$(trim "${line#*#}")"
    excluded_path="${excluded_path%/}"
    if [[ -z "$excluded_reason" ]]; then
      bad ".claude/naming-lint-exclude:$exclude_line_number  # 后面是空的，等于没写理由"
      howto "在 # 后面写清为什么这批代码的名字不归这道检查管。"
      failure_count=$((failure_count+1)); continue
    fi
    if [[ -z "$excluded_path" || "$excluded_path" == "." || "$excluded_path" == /* || "$excluded_path" == *..* ]]; then
      bad ".claude/naming-lint-exclude:$exclude_line_number  路径不合法：「$excluded_path」"
      howto "只收项目根之下的相对子目录，例： research/" \
            "不收 . 、绝对路径、含 .. 的路径——那些一行就能把整棵树排掉。"
      failure_count=$((failure_count+1)); continue
    fi
    # 一条排除可以是单个 .rs：回扫旧代码时没改完的文件逐个列进来，改完一个删一行，排除只缩不涨。
    if [[ -f "$PROJECT_ROOT/$excluded_path" && "$excluded_path" == *.rs ]]; then
      EXCLUDED_PATH_ARGUMENTS+=(-not -path "$PROJECT_ROOT/$excluded_path")
      excluded_paths+=("$excluded_path"); excluded_reasons+=("$excluded_reason"); excluded_file_counts+=(1)
      continue
    fi
    if [[ ! -d "$PROJECT_ROOT/$excluded_path" ]]; then
      bad ".claude/naming-lint-exclude:$exclude_line_number  目录或 .rs 文件不存在：$excluded_path"
      howto "路径拼错了就改对；那批代码已经挪走、删了或改完了，就把这一行删掉。" \
            "留着的排除项会让人以为还有东西在被绕开。"
      failure_count=$((failure_count+1)); continue
    fi
    excluded_file_count="$(find "$PROJECT_ROOT/$excluded_path" -name '*.rs' -type f -not -path '*/target/*' | wc -l)"
    if [[ "$excluded_file_count" -eq 0 ]]; then
      bad ".claude/naming-lint-exclude:$exclude_line_number  $excluded_path 下一个 .rs 都没有，这条排除没有作用"
      howto "删掉这一行。不起作用的排除项只会让人以为那批文件被绕开了。"
      failure_count=$((failure_count+1)); continue
    fi
    EXCLUDED_PATH_ARGUMENTS+=(-not -path "$PROJECT_ROOT/$excluded_path/*")
    excluded_paths+=("$excluded_path/"); excluded_reasons+=("$excluded_reason"); excluded_file_counts+=("$excluded_file_count")
  done < "$EXCLUDE_FILE"
fi

# ── 命名回扫排除表 ──────────────────────────────────────
# 回扫旧代码与脚本时没改完的文件逐个列进来，改完一个删一行，排除只缩不涨；路径不存在判红。
SWEEP_EXCLUDE_FILE="$PROJECT_ROOT/.claude/naming-sweep-exclude"
if [[ -f "$SWEEP_EXCLUDE_FILE" ]]; then
  sweep_line_number=0
  while IFS= read -r sweep_line || [[ -n "$sweep_line" ]]; do
    sweep_line_number=$((sweep_line_number+1))
    [[ -z "${sweep_line//[[:space:]]/}" || "${sweep_line#"${sweep_line%%[![:space:]]*}"}" == \#* ]] && continue
    if [[ "$sweep_line" != *\#* ]]; then
      bad ".claude/naming-sweep-exclude:$sweep_line_number  这一条没写理由：$sweep_line"
      howto "在 # 后面写清为什么这批名字暂不回扫。"
      failure_count=$((failure_count+1)); continue
    fi
    sweep_path="${sweep_line%%#*}"; sweep_reason="${sweep_line#*#}"
    sweep_path="${sweep_path#"${sweep_path%%[![:space:]]*}"}"; sweep_path="${sweep_path%"${sweep_path##*[![:space:]]}"}"
    sweep_reason="${sweep_reason#"${sweep_reason%%[![:space:]]*}"}"; sweep_reason="${sweep_reason%"${sweep_reason##*[![:space:]]}"}"
    if [[ -z "$sweep_reason" ]]; then
      bad ".claude/naming-sweep-exclude:$sweep_line_number  # 后面是空的，等于没写理由"
      howto "在 # 后面写清为什么这批名字暂不回扫。"
      failure_count=$((failure_count+1)); continue
    fi
    if [[ -z "$sweep_path" || "$sweep_path" == "." || "$sweep_path" == /* || "$sweep_path" == *..* ]]; then
      bad ".claude/naming-sweep-exclude:$sweep_line_number  路径不合法：「$sweep_path」"
      howto "只收项目根之下的相对路径或目录，例： scripts/fixtures/" \
            "不收 . 、绝对路径、含 .. 的路径。"
      failure_count=$((failure_count+1)); continue
    fi
    if [[ ! -e "$PROJECT_ROOT/$sweep_path" ]]; then
      bad ".claude/naming-sweep-exclude:$sweep_line_number  路径不存在：$sweep_path"
      howto "路径拼错了就改对；那批文件已经删了或改完了，就把这一行删掉。" \
            "留着的排除项会让人以为还有东西在被绕开。"
      failure_count=$((failure_count+1)); continue
    fi
  done < "$SWEEP_EXCLUDE_FILE"
fi

# ── 缩写登记表 ──────────────────────────────────────────
# 登记表是缩写唯一的权威定义：不写含义的、单字母的、登记两遍的都判红，它们让「这个缩写指什么」答不上来。
ABBREVIATIONS_FILE="$PROJECT_ROOT/.claude/abbreviations"
declare -A REGISTERED=()
declare -A NUMBERED=()
numbered_registration_pattern='^([a-z])<数字>$'
if [[ -f "$ABBREVIATIONS_FILE" ]]; then
  abbreviation_line_number=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    abbreviation_line_number=$((abbreviation_line_number+1))
    [[ -z "${line//[[:space:]]/}" || "${line#"${line%%[![:space:]]*}"}" == \#* ]] && continue
    if [[ "$line" != *\#* ]]; then
      bad ".claude/abbreviations:$abbreviation_line_number  这一条没写全称和含义：$line"
      howto "格式： lba  # logical block address：逻辑块地址" \
            "登记表就是这个缩写唯一的权威定义，不写含义等于没登记（rules/code-discipline.md）。"
      failure_count=$((failure_count+1)); continue
    fi
    token="$(trim "${line%%#*}")"; meaning="$(trim "${line#*#}")"
    if [[ -z "$meaning" ]]; then
      bad ".claude/abbreviations:$abbreviation_line_number  # 后面是空的，等于没写含义：$token"
      howto "在 # 后面写全称，以及它在这个项目里指什么。"
      failure_count=$((failure_count+1)); continue
    fi
    # 项目自己的编号：登记的是「这个字母加数字」一整类，权威定义在登记它的那张表里；登记之后 e12_x 里的 e12 不算单字母。
    if [[ "$token" =~ $numbered_registration_pattern ]]; then
      letter="${BASH_REMATCH[1]}"
      if [[ -n "${NUMBERED[$letter]:-}" ]]; then
        bad ".claude/abbreviations:$abbreviation_line_number  重复登记：$token（第 ${NUMBERED[$letter]} 行已经登记过）"
        howto "一种编号只许有一处定义，删掉其中一行（rules/kb-discipline.md：矛盾比空白更糟）。"
        failure_count=$((failure_count+1)); continue
      fi
      NUMBERED[$letter]="$abbreviation_line_number"; continue
    fi
    if [[ "$token" =~ ^[a-z][0-9]*$ ]]; then
      bad ".claude/abbreviations:$abbreviation_line_number  单字母不许登记：$token"
      howto "一个字母没有唯一的含义，登记了也说不清它指什么。" \
            "把用到它的名字写全（rules/code-discipline.md 的「名字」一节）。"
      failure_count=$((failure_count+1)); continue
    fi
    if [[ ! "$token" =~ ^[a-z][a-z0-9]*$ ]]; then
      bad ".claude/abbreviations:$abbreviation_line_number  缩写要写成小写字母开头的一段字母数字：「$token」"
      howto "登记的是名字拆开之后的一段，一律小写，例： lba、crc32c。" \
            "名字里写成 Lba、LBA 的，拆段之后都按 lba 查。"
      failure_count=$((failure_count+1)); continue
    fi
    if [[ -n "${REGISTERED[$token]:-}" ]]; then
      bad ".claude/abbreviations:$abbreviation_line_number  重复登记：$token（第 ${REGISTERED[$token]} 行已经登记过）"
      howto "一个缩写只许有一处定义，删掉其中一行（rules/kb-discipline.md：矛盾比空白更糟）。"
      failure_count=$((failure_count+1)); continue
    fi
    REGISTERED[$token]="$abbreviation_line_number"
  done < "$ABBREVIATIONS_FILE"
fi

rust_files=()
while IFS= read -r rust_file; do rust_files+=("$rust_file"); done < <(rust_source_files "$PROJECT_ROOT" ${EXCLUDED_PATH_ARGUMENTS[@]+"${EXCLUDED_PATH_ARGUMENTS[@]}"} | sort)

if [[ ${#excluded_paths[@]} -gt 0 ]]; then
  total_excluded=0; for excluded_index in "${!excluded_paths[@]}"; do total_excluded=$((total_excluded+excluded_file_counts[excluded_index])); done
  warn "按 .claude/naming-lint-exclude 不扫 $total_excluded 个 .rs —— 那里面的名字没人管："
  for excluded_index in "${!excluded_paths[@]}"; do warn "  ${excluded_paths[$excluded_index]}  （${excluded_file_counts[$excluded_index]} 个）—— ${excluded_reasons[$excluded_index]}"; done
fi
if [[ $failure_count -gt 0 ]]; then
  bad "命名纪律的配置有 $failure_count 处不合规，名字这一轮没有查"   # gate-lint:summary
  exit 1
fi
if [[ ${#rust_files[@]} -eq 0 ]]; then
  warn "没有要查的 .rs 文件（${#rust_files[@]} 个），本阶段无对象可判（这不是通过）"
  # 退 3 而不退 0：退 0 在汇总里与「判过了」分不出，而这一轮一个名字都没看（rules/show-me-test.md「门禁不许假装通过」）。
  exit 3
fi

# ── 缩写词表：<缩写> <该写成什么> ─────────────────────────
# 只列最常见的那些，词表外的缩写照样违规，只是这道检查看不见（rules/code-discipline.md）。
# 不收 Rust 关键字（mut、fn、ref、impl……）；不收本身是英语单词的（off、opt、mid），turn_off、opt_in 会被误拒，门禁一误拒人就绕过它。
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
# 逐行剥掉注释、字符串、字符字面量（生命周期留着）再认声明处；块栈记着在哪种块里：字段只在 struct 体、枚举成员只在 enum 体里认，trait 实现里的方法名与 extern 块不判。
# 输出一行一条，第一段是标签：VIOLATION 违规 / MISSING_REASON 标记缺理由 / EXEMPTED 被行内豁免的行 / DECLARATION_TOTAL 声明总数。
NAMING_AWK="$(cat <<'AWK'
BEGIN {
  item_count = split(ENVIRON["NAMING_ABBR"], table_rows, "\n")
  for (item_index = 1; item_index <= item_count; item_index++) {
    if (table_rows[item_index] ~ /^[ \t]*$/) continue
    abbreviation = table_rows[item_index]; sub(/[ \t].*$/, "", abbreviation)
    full_form = table_rows[item_index]; sub(/^[^ \t]+[ \t]+/, "", full_form)
    ABBREVIATION_FULL_FORM[abbreviation] = full_form
  }
  item_count = split(ENVIRON["NAMING_ALLOW"], table_rows, " ")
  for (item_index = 1; item_index <= item_count; item_index++) if (table_rows[item_index] != "") REGISTERED_ABBREVIATION[table_rows[item_index]] = 1
  item_count = split(ENVIRON["NAMING_NUMBERED"], table_rows, " ")
  for (item_index = 1; item_index <= item_count; item_index++) if (table_rows[item_index] != "") NUMBERED_LETTER[table_rows[item_index]] = 1
  item_count = split("mut ref box true false self Self crate super in if else as dyn impl move where", keyword_list, " ")
  for (item_index = 1; item_index <= item_count; item_index++) PATTERN_KEYWORD[keyword_list[item_index]] = 1
  item_count = split("self Self super crate static _", keyword_list, " ")
  for (item_index = 1; item_index <= item_count; item_index++) NOT_A_DECLARED_NAME[keyword_list[item_index]] = 1
  item_count = split("block expr ident item lifetime literal meta pat pat_param path stmt tt ty vis", keyword_list, " ")
  for (item_index = 1; item_index <= item_count; item_index++) MACRO_FRAGMENT_SPECIFIER[keyword_list[item_index]] = 1
  item_count = split("lib main mod build", keyword_list, " ")
  for (item_index = 1; item_index <= item_count; item_index++) CARGO_FILE[keyword_list[item_index]] = 1
  root_prefix = ENVIRON["NAMING_ROOT"] "/"
  total_declarations = 0
}

FNR == 1 {
  relative_path = FILENAME
  if (index(relative_path, root_prefix) == 1) relative_path = substr(relative_path, length(root_prefix) + 1)
  block_comment_depth = 0; in_string_literal = 0; raw_string_hash_count = -1
  block_stack_depth = 0; pending_block_kind = ""; impl_header_text = ""; bracket_depth = 0
  in_function_signature = 0; signature_parameters_started = 0; signature_bracket_depth = 0; signature_angle_depth = 0; parameter_text = ""
  in_use_declaration = 0
  delete judged_names
  file_stem = relative_path; sub(/^.*\//, "", file_stem); sub(/\.rs$/, "", file_stem)
  if (!(file_stem in CARGO_FILE)) judge_name(file_stem, "文件名")
}

{
  raw_line = $0
  code_line = strip_comments_and_literals(raw_line)
  is_exempted_line = 0
  if (raw_line ~ /naming-lint:external/) {
    exemption_reason = raw_line; sub(/.*naming-lint:external/, "", exemption_reason)
    gsub(/\*\//, "", exemption_reason); gsub(/^[ \t:：]+|[ \t]+$/, "", exemption_reason)
    if (exemption_reason == "") printf "MISSING_REASON\t%s\t%d\n", relative_path, FNR
    else { is_exempted_line = 1; printf "EXEMPTED\t%s\t%d\t%s\n", relative_path, FNR, exemption_reason }
  }
  block_context = (block_stack_depth > 0) ? block_stack[block_stack_depth] : "file"
  if (!is_exempted_line && block_context != "extern") {
    if (block_context != "macro") judge_declarations_on_line(code_line, block_context)
    judge_macro_variables(code_line)
  }
  track_block_stack(code_line)
}

END { printf "DECLARATION_TOTAL\t%d\n", total_declarations }

# ── 剥注释、字符串、字符字面量 ─────────────────────────
function strip_comments_and_literals(line,    stripped_text, position, line_length, character, two_characters, raw_quote_start, hash_end, previous_character) {
  stripped_text = ""; line_length = length(line); position = 1
  while (position <= line_length) {
    character = substr(line, position, 1)
    if (block_comment_depth > 0) {
      two_characters = substr(line, position, 2)
      if (two_characters == "*/") { block_comment_depth--; position += 2; continue }
      if (two_characters == "/*") { block_comment_depth++; position += 2; continue }
      position++; continue
    }
    if (in_string_literal) {
      if (character == "\\") { position += 2; continue }
      if (character == "\"") { in_string_literal = 0; stripped_text = stripped_text "\""; position++; continue }
      position++; continue
    }
    if (raw_string_hash_count >= 0) {
      if (character == "\"" && substr(line, position + 1, raw_string_hash_count) == repeated_hash_marks(raw_string_hash_count)) {
        stripped_text = stripped_text "\""; position += 1 + raw_string_hash_count; raw_string_hash_count = -1; continue
      }
      position++; continue
    }
    two_characters = substr(line, position, 2)
    if (two_characters == "//") break
    if (two_characters == "/*") { block_comment_depth = 1; position += 2; continue }
    previous_character = (stripped_text == "") ? "" : substr(stripped_text, length(stripped_text), 1)
    if (previous_character !~ /[A-Za-z0-9_]/) {
      raw_quote_start = 0
      if (character == "r") raw_quote_start = position + 1
      else if (character == "b" && substr(line, position + 1, 1) == "r") raw_quote_start = position + 2
      if (raw_quote_start > 0) {
        hash_end = raw_quote_start; while (substr(line, hash_end, 1) == "#") hash_end++
        if (substr(line, hash_end, 1) == "\"") { raw_string_hash_count = hash_end - raw_quote_start; stripped_text = stripped_text "\""; position = hash_end + 1; continue }
        if (character == "r" && hash_end == raw_quote_start + 1 && substr(line, hash_end, 1) ~ /[A-Za-z_]/) { position = hash_end; continue }
      }
    }
    if (character == "\"") { in_string_literal = 1; stripped_text = stripped_text "\""; position++; continue }
    if (character == "'") {
      if (substr(line, position + 1, 1) == "\\") {
        hash_end = index(substr(line, position + 3), "'")
        if (hash_end > 0) { stripped_text = stripped_text "''"; position = position + 3 + hash_end; continue }
      } else if (substr(line, position + 2, 1) == "'" && substr(line, position + 1, 1) != "'") {
        stripped_text = stripped_text "''"; position += 3; continue
      }
    }
    stripped_text = stripped_text character; position++
  }
  return stripped_text
}
function repeated_hash_marks(hash_count,    marks) { marks = ""; while (hash_count-- > 0) marks = marks "#"; return marks }

# ── 块栈：这一行之后我们在哪种块里 ──────────────────────
function starts_item(text_before_word) {
  return text_before_word ~ /^[ \t]*$/ || text_before_word ~ /[;{}\]][ \t]*$/ ||
         text_before_word ~ /(^|[^A-Za-z0-9_])(pub|unsafe|default)[ \t]*$/ || text_before_word ~ /pub\([^)]*\)[ \t]*$/
}
function track_block_stack(code_line,    position, word_end, code_length, character, word, text_before_word, text_after_word, block_kind) {
  code_length = length(code_line); position = 1
  while (position <= code_length) {
    character = substr(code_line, position, 1)
    if (character ~ /[A-Za-z_]/) {
      word_end = position; while (word_end <= code_length && substr(code_line, word_end, 1) ~ /[A-Za-z0-9_]/) word_end++
      word = substr(code_line, position, word_end - position)
      text_before_word = substr(code_line, 1, position - 1)
      text_after_word = substr(code_line, word_end)
      if (text_before_word !~ /[A-Za-z0-9_'$]$/) {
        if (word == "fn" && text_after_word ~ /^[ \t]+[A-Za-z_]/) { pending_block_kind = "fn"; impl_header_text = ""; bracket_depth = 0 }
        else if (word == "impl" && pending_block_kind != "fn" && starts_item(text_before_word)) { pending_block_kind = "impl"; impl_header_text = ""; bracket_depth = 0 }
        else if ((word == "struct" || word == "union") && text_after_word ~ /^[ \t]+[A-Za-z_]/) { pending_block_kind = "struct"; bracket_depth = 0 }
        else if (word == "enum" && text_after_word ~ /^[ \t]+[A-Za-z_]/) { pending_block_kind = "enum"; bracket_depth = 0 }
        else if (word == "trait" && text_after_word ~ /^[ \t]+[A-Za-z_]/) { pending_block_kind = "trait"; bracket_depth = 0 }
        else if (word == "mod" && text_after_word ~ /^[ \t]+[A-Za-z_]/) { pending_block_kind = "mod"; bracket_depth = 0 }
        else if (word == "macro_rules") { pending_block_kind = "macro"; bracket_depth = 0 }
        else if (word == "extern" && text_after_word ~ /^[ \t]*(""[ \t]*)?\{/) { pending_block_kind = "extern"; bracket_depth = 0 }
      }
      if (pending_block_kind == "impl") impl_header_text = impl_header_text " " word
      position = word_end; continue
    }
    if (pending_block_kind == "impl") impl_header_text = impl_header_text character
    if (character == "(" || character == "[") bracket_depth++
    else if (character == ")" || character == "]") { if (bracket_depth > 0) bracket_depth-- }
    else if (character == "{") {
      block_kind = "block"
      if (pending_block_kind == "impl") block_kind = (impl_header_text ~ /[^A-Za-z0-9_]for[ \t]/) ? "trait_impl" : "impl"
      else if (pending_block_kind != "") block_kind = pending_block_kind
      else if (block_stack_depth > 0 && block_stack[block_stack_depth] == "enum") block_kind = "fields"
      block_stack[++block_stack_depth] = block_kind
      pending_block_kind = ""; impl_header_text = ""; bracket_depth = 0
    }
    else if (character == "}") { if (block_stack_depth > 0) block_stack_depth--; pending_block_kind = ""; impl_header_text = "" }
    else if (character == ";" && bracket_depth == 0) { pending_block_kind = ""; impl_header_text = "" }
    position++
  }
  if (pending_block_kind == "impl") impl_header_text = impl_header_text " "
}

# ── 这一行声明了哪些名字 ────────────────────────────────
function judge_declarations_on_line(code_line, block_context,    remaining_code, text_after_match, name_match, generics_text, field_line) {
  # 上一行的函数签名还没收尾（参数分几行写）
  if (in_function_signature) scan_parameters(code_line)

  remaining_code = code_line
  while (match(remaining_code, /(^|[^A-Za-z0-9_])fn[ \t]+([A-Za-z_][A-Za-z0-9_]*)/, name_match)) {
    if (block_context != "trait_impl") judge_name(name_match[2], "函数")
    text_after_match = substr(remaining_code, RSTART + RLENGTH)
    if (text_after_match ~ /^[ \t]*</) { generics_text = angle_bracket_content(text_after_match); judge_generics(generics_text); text_after_match = substr(text_after_match, ANGLE_CLOSING_POSITION + 1) }
    in_function_signature = 1; signature_parameters_started = 0; signature_bracket_depth = 0; signature_angle_depth = 0; parameter_text = ""
    scan_parameters(text_after_match)
    remaining_code = text_after_match
  }

  remaining_code = code_line
  while (match(remaining_code, /(^|[^A-Za-z0-9_])(struct|enum|union|trait|type)[ \t]+([A-Za-z_][A-Za-z0-9_]*)/, name_match)) {
    text_after_match = substr(remaining_code, RSTART + RLENGTH)
    if (!(block_context == "trait_impl" && name_match[2] == "type")) judge_name(name_match[3], "类型")
    if (text_after_match ~ /^[ \t]*</) { generics_text = angle_bracket_content(text_after_match); judge_generics(generics_text); text_after_match = substr(text_after_match, ANGLE_CLOSING_POSITION + 1) }
    if ((name_match[2] == "struct" || name_match[2] == "union") && match(text_after_match, /\{/)) same_line_fields(substr(text_after_match, RSTART + 1))
    if (name_match[2] == "enum" && match(text_after_match, /\{/)) same_line_variants(substr(text_after_match, RSTART + 1))
    remaining_code = text_after_match
  }
  if (match(code_line, /(^|[^A-Za-z0-9_])impl[ \t]*</)) { generics_text = angle_bracket_content(substr(code_line, RSTART + RLENGTH - 1)); judge_generics(generics_text) }

  if (match(code_line, /^[ \t]*(pub(\([^)]*\))?[ \t]+)?(const|static)[ \t]+(mut[ \t]+)?([A-Za-z_][A-Za-z0-9_]*)[ \t]*:/, name_match))
    if (block_context != "trait_impl") judge_name(name_match[5], "常量")
  if (match(code_line, /^[ \t]*(pub(\([^)]*\))?[ \t]+)?mod[ \t]+([A-Za-z_][A-Za-z0-9_]*)/, name_match)) judge_name(name_match[3], "模块")
  if (match(code_line, /macro_rules![ \t]*([A-Za-z_][A-Za-z0-9_]*)/, name_match)) judge_name(name_match[1], "宏")

  # use … as 别名（跨行的 use 组也认）
  if (code_line ~ /^[ \t]*(pub(\([^)]*\))?[ \t]+)?use[ \t]/) in_use_declaration = 1
  if (in_use_declaration) {
    remaining_code = code_line
    while (match(remaining_code, /(^|[^A-Za-z0-9_])as[ \t]+([A-Za-z_][A-Za-z0-9_]*)/, name_match)) { judge_name(name_match[2], "别名"); remaining_code = substr(remaining_code, RSTART + RLENGTH) }
    if (code_line ~ /;/) in_use_declaration = 0
  }

  remaining_code = code_line
  while (match(remaining_code, /'([A-Za-z_][A-Za-z0-9_]*):[ \t]*(loop|while|for|\{)/, name_match)) { judge_name("'" name_match[1], "标签"); remaining_code = substr(remaining_code, RSTART + RLENGTH) }

  remaining_code = code_line
  while (match(remaining_code, /(^|[^A-Za-z0-9_])let[ \t]+/)) {
    text_after_match = substr(remaining_code, RSTART + RLENGTH)
    bind_pattern(pattern_head(text_after_match), "变量")
    remaining_code = text_after_match
  }

  remaining_code = code_line
  while (match(remaining_code, /(^|[^A-Za-z0-9_])for[ \t]+/)) {
    text_after_match = substr(remaining_code, RSTART + RLENGTH)
    if (match(text_after_match, /[ \t]in([ \t]|$)/)) {
      generics_text = substr(text_after_match, 1, RSTART - 1)
      if (generics_text !~ /[{};=<]/) bind_pattern(generics_text, "循环变量")
    }
    remaining_code = text_after_match
  }

  judge_closure_parameters(code_line)
  if (code_line !~ /macro_rules!/) judge_match_arm_bindings(code_line)

  if (block_context == "struct" || block_context == "fields") { field_line = code_line; sub(/^[ \t]*(#\[[^]]*\][ \t]*)+/, "", field_line); same_line_fields(field_line) }
  if (block_context == "enum") { field_line = code_line; sub(/^[ \t]*(#\[[^]]*\][ \t]*)+/, "", field_line); variant_item(field_line) }
}

function judge_macro_variables(code_line,    remaining_code, name_match) {
  remaining_code = code_line
  while (match(remaining_code, /\$([A-Za-z_][A-Za-z0-9_]*)[ \t]*:[ \t]*([a-z_]+)/, name_match)) {
    if (name_match[2] in MACRO_FRAGMENT_SPECIFIER) judge_name(name_match[1], "宏变量")
    remaining_code = substr(remaining_code, RSTART + RLENGTH)
  }
}

# 从文本开头的 < 起，取出配对的 <…> 里面的内容；ANGLE_CLOSING_POSITION 是收尾的 > 在 text 里的位置
function angle_bracket_content(text,    position, text_length, character, nesting_depth, content_start) {
  text_length = length(text); nesting_depth = 0; content_start = 0; ANGLE_CLOSING_POSITION = text_length
  for (position = 1; position <= text_length; position++) {
    character = substr(text, position, 1)
    if (character == "<") { nesting_depth++; if (nesting_depth == 1) content_start = position + 1 }
    else if (character == ">" && substr(text, position - 1, 1) != "-") {
      nesting_depth--
      if (nesting_depth == 0) { ANGLE_CLOSING_POSITION = position; return substr(text, content_start, position - content_start) }
    }
  }
  return (content_start > 0) ? substr(text, content_start) : ""
}

function judge_generics(generics_text,    item_count, items, item_index, item, name_match) {
  item_count = split_top_level_commas(generics_text, items)
  for (item_index = 1; item_index <= item_count; item_index++) {
    item = items[item_index]; sub(/^[ \t]+/, "", item)
    if (match(item, /^'([A-Za-z_][A-Za-z0-9_]*)/, name_match)) judge_name("'" name_match[1], "生命周期")
    else if (match(item, /^const[ \t]+([A-Za-z_][A-Za-z0-9_]*)/, name_match)) judge_name(name_match[1], "泛型参数")
    else if (match(item, /^([A-Za-z_][A-Za-z0-9_]*)/, name_match)) judge_name(name_match[1], "泛型参数")
  }
}

# 按顶层逗号切开（括号、方括号、花括号、尖括号里的逗号不算；-> 的 > 不算）
function split_top_level_commas(text, items,    position, text_length, character, nesting_depth, item, item_count) {
  nesting_depth = 0; item = ""; item_count = 0; text_length = length(text)
  for (position = 1; position <= text_length; position++) {
    character = substr(text, position, 1)
    if (character == "(" || character == "[" || character == "{" || character == "<") nesting_depth++
    else if (character == ")" || character == "]" || character == "}") nesting_depth--
    else if (character == ">" && substr(text, position - 1, 1) != "-") nesting_depth--
    else if (character == "," && nesting_depth == 0) { items[++item_count] = item; item = ""; continue }
    item = item character
  }
  if (item ~ /[^ \t]/) items[++item_count] = item
  return item_count
}

# 模式到哪儿为止：顶层的 =（不是 == / =>）、单冒号（类型标注）、分号，或者多出来的右括号
function pattern_head(text,    position, text_length, character, nesting_depth, next_char, previous_character) {
  nesting_depth = 0; text_length = length(text)
  for (position = 1; position <= text_length; position++) {
    character = substr(text, position, 1); next_char = substr(text, position + 1, 1); previous_character = substr(text, position - 1, 1)
    if (character == "(" || character == "[" || character == "{") nesting_depth++
    else if (character == ")" || character == "]" || character == "}") { if (nesting_depth == 0) return substr(text, 1, position - 1); nesting_depth-- }
    else if (nesting_depth == 0 && character == "=" && next_char != "=" && next_char != ">") return substr(text, 1, position - 1)
    else if (nesting_depth == 0 && character == ":" && next_char != ":" && previous_character != ":") return substr(text, 1, position - 1)
    else if (nesting_depth == 0 && character == ";") return substr(text, 1, position - 1)
  }
  return text
}

# 从模式里挑出绑定：跳过路径段、字段名、变体名、关键字、方法调用
function bind_pattern(pattern, name_kind,    remaining_pattern, consumed, name, text_before_name, text_after_name) {
  remaining_pattern = pattern; consumed = ""
  while (match(remaining_pattern, /[A-Za-z_][A-Za-z0-9_]*/)) {
    name = substr(remaining_pattern, RSTART, RLENGTH)
    text_before_name = consumed substr(remaining_pattern, 1, RSTART - 1)
    text_after_name = substr(remaining_pattern, RSTART + RLENGTH)
    consumed = text_before_name name
    remaining_pattern = text_after_name
    if (text_before_name ~ /(::|\.|'|\$|[0-9])[ \t]*$/) continue
    if (text_after_name ~ /^[ \t]*(::|\(|\{|!)/) continue
    if (text_after_name ~ /^[ \t]*:([^:]|$)/) continue
    if (name ~ /^[A-Z]/) continue
    if (name in PATTERN_KEYWORD) continue
    judge_name(name, name_kind)
  }
}

# 函数参数：可能跨行，括号配对着读，读到收尾的 ) 为止
function scan_parameters(text,    position, text_length, character) {
  text_length = length(text)
  for (position = 1; position <= text_length; position++) {
    character = substr(text, position, 1)
    if (!signature_parameters_started) {
      if (character == "(") { signature_parameters_started = 1; signature_bracket_depth = 1; signature_angle_depth = 0; parameter_text = ""; continue }
      if (character == "{" || character == ";") { in_function_signature = 0; return }
      continue
    }
    if (character == "(" || character == "[" || character == "{") signature_bracket_depth++
    else if (character == "<") signature_angle_depth++
    else if (character == ">" && substr(text, position - 1, 1) != "-") { if (signature_angle_depth > 0) signature_angle_depth-- }
    else if (character == ")" || character == "]" || character == "}") {
      signature_bracket_depth--
      if (signature_bracket_depth == 0) { judge_parameter_chunk(parameter_text); parameter_text = ""; in_function_signature = 0; return }
    }
    else if (character == "," && signature_bracket_depth == 1 && signature_angle_depth == 0) { judge_parameter_chunk(parameter_text); parameter_text = ""; continue }
    parameter_text = parameter_text character
  }
  parameter_text = parameter_text " "
}
function judge_parameter_chunk(chunk) { if (chunk ~ /[^ \t]/) bind_pattern(pattern_head(chunk), "参数") }

# 闭包参数 |left, right: Value|：开头那根 | 前面得是 ( , = { move return 或者行首
function judge_closure_parameters(code_line,    position, code_length, closing_bar_offset, text_before_bar, closure_parameter_text, items, item_count, item_index) {
  code_length = length(code_line)
  for (position = 1; position <= code_length; position++) {
    if (substr(code_line, position, 1) != "|") continue
    if (substr(code_line, position + 1, 1) == "|") { position++; continue }
    text_before_bar = substr(code_line, 1, position - 1); sub(/[ \t]+$/, "", text_before_bar)
    if (!(text_before_bar == "" || text_before_bar ~ /[(,={]$/ || text_before_bar ~ /(^|[^A-Za-z0-9_])(move|return)$/)) continue
    closing_bar_offset = index(substr(code_line, position + 1), "|")
    if (closing_bar_offset == 0) return
    closure_parameter_text = substr(code_line, position + 1, closing_bar_offset - 1)
    delete items
    item_count = split_top_level_commas(closure_parameter_text, items)
    for (item_index = 1; item_index <= item_count; item_index++)
      bind_pattern(pattern_head(items[item_index]), "闭包参数")
    position = position + closing_bar_offset
  }
}

# match 臂：=> 往回找到模式的起点（顶层的 , { ( [ 或者行首），守卫 if 之后的不算
function judge_match_arm_bindings(code_line,    remaining_code, position, scan_position, character, nesting_depth, pattern_start, pattern) {
  remaining_code = code_line
  while ((position = index(remaining_code, "=>")) > 0) {
    nesting_depth = 0; pattern_start = 1
    for (scan_position = position - 1; scan_position >= 1; scan_position--) {
      character = substr(remaining_code, scan_position, 1)
      if (character == ")" || character == "]" || character == "}") nesting_depth++
      else if (character == "(" || character == "[" || character == "{") { if (nesting_depth == 0) { pattern_start = scan_position + 1; break } nesting_depth-- }
      else if (character == "," && nesting_depth == 0) { pattern_start = scan_position + 1; break }
    }
    pattern = substr(remaining_code, pattern_start, position - pattern_start)
    sub(/^[ \t]*\|/, "", pattern)
    if (match(pattern, /(^|[^A-Za-z0-9_])if[ \t]/)) pattern = substr(pattern, 1, RSTART)
    bind_pattern(pattern, "匹配绑定")
    remaining_code = substr(remaining_code, position + 2)
  }
}

# struct 体里的字段（一行里写几个也认）
function same_line_fields(text,    remaining_text, field_match) {
  remaining_text = text
  while (match(remaining_text, /(^|[,{])[ \t]*(pub(\([^)]*\))?[ \t]+)?([A-Za-z_][A-Za-z0-9_]*)[ \t]*:([^:]|$)/, field_match)) {
    judge_name(field_match[4], "字段")
    remaining_text = substr(remaining_text, RSTART + RLENGTH)
  }
}

# enum 头所在那一行里就写了成员：enum Choice { First, Second(u8), Third { value: u8 } }
function same_line_variants(text,    position, text_length, character, nesting_depth, item) {
  nesting_depth = 0; item = ""; text_length = length(text)
  for (position = 1; position <= text_length; position++) {
    character = substr(text, position, 1)
    if (character == "(" || character == "{" || character == "[" || character == "<") nesting_depth++
    else if (character == ")" || character == "]") nesting_depth--
    else if (character == ">" && substr(text, position - 1, 1) != "-") nesting_depth--
    else if (character == "}") { if (nesting_depth == 0) { variant_item(item); return } nesting_depth-- }
    else if (character == "," && nesting_depth == 0) { variant_item(item); item = ""; continue }
    item = item character
  }
  variant_item(item)
}
function variant_item(item,    variant_match) {
  if (match(item, /^[ \t]*(#\[[^]]*\][ \t]*)*([A-Za-z_][A-Za-z0-9_]*)/, variant_match)) {
    judge_name(variant_match[2], "枚举成员")
    if (match(item, /\{/)) same_line_fields(substr(item, RSTART + 1))
  }
}

# ── 判一个名字 ──────────────────────────────────────────
function judge_name(name, name_kind,    core_name, judged_key, snake_case_name, part_count, parts, part_index, part, part_without_digits, singular_stem, reason) {
  core_name = name; sub(/^'/, "", core_name); sub(/^r#/, "", core_name)
  if (core_name == "" || (core_name in NOT_A_DECLARED_NAME)) return
  judged_key = FNR SUBSEP name_kind SUBSEP name
  if (judged_key in judged_names) return
  judged_names[judged_key] = 1
  total_declarations++
  gsub(/^_+|_+$/, "", core_name)
  if (core_name == "") return
  if (length(core_name) == 1) { print_violation(name_kind, name, "单字母"); return }
  snake_case_name = gensub(/([a-z0-9])([A-Z])/, "\\1_\\2", "g", core_name)
  snake_case_name = gensub(/([A-Z]+)([A-Z][a-z])/, "\\1_\\2", "g", snake_case_name)
  part_count = split(tolower(snake_case_name), parts, /_+/)
  reason = ""
  for (part_index = 1; part_index <= part_count; part_index++) {
    part = parts[part_index]
    if (part == "" || part ~ /^[0-9]+$/) continue
    if (part ~ /^[uif](8|16|32|64|128)$/) continue
    part_without_digits = part; sub(/[0-9]+$/, "", part_without_digits)
    singular_stem = (part_without_digits ~ /..s$/) ? substr(part_without_digits, 1, length(part_without_digits) - 1) : ""
    if ((part in REGISTERED_ABBREVIATION) || (part_without_digits in REGISTERED_ABBREVIATION) || (singular_stem != "" && (singular_stem in REGISTERED_ABBREVIATION))) continue
    if (part == "a" && part_index > 1 && part_index < part_count) continue
    if (part ~ /^[a-z][0-9]+$/ && (substr(part, 1, 1) in NUMBERED_LETTER)) continue
    if (part ~ /^[a-z][0-9]*$/) { reason = reason (reason == "" ? "" : "；") "「" part "」是单字母" (part ~ /[0-9]/ ? "加数字" : ""); continue }
    if (part_without_digits in ABBREVIATION_FULL_FORM) { reason = reason (reason == "" ? "" : "；") "「" part "」是缩写，写全：" ABBREVIATION_FULL_FORM[part_without_digits]; continue }
    if (singular_stem != "" && (singular_stem in ABBREVIATION_FULL_FORM)) { reason = reason (reason == "" ? "" : "；") "「" part "」是缩写的复数，写全：" ABBREVIATION_FULL_FORM[singular_stem]; continue }
  }
  if (reason != "") print_violation(name_kind, name, reason)
}
function print_violation(name_kind, name, reason) { printf "VIOLATION\t%s\t%d\t%s\t%s\t%s\n", relative_path, FNR, name_kind, name, reason }
AWK
)"

report_file="$(mktemp)"; trap 'rm -f "$report_file"' EXIT
NAMING_ABBR="$ABBR_TABLE" NAMING_ALLOW="${!REGISTERED[*]}" NAMING_NUMBERED="${!NUMBERED[*]}" NAMING_ROOT="$PROJECT_ROOT" \
  awk "$NAMING_AWK" "${rust_files[@]}" > "$report_file" \
  || die "naming-lint 自己的扫描程序出错了（awk 退出码非零）" \
         "这是本脚本的缺陷，不是被查代码的问题。把上面 awk 的报错连同文件名报给维护 singlefs-ai-sop 的人。"

violation_lines=(); mark_lines=(); exempt_lines=(); declaration_count=0
while IFS=$'\t' read -r record_tag record_fields; do
  case "$record_tag" in
    VIOLATION)
      IFS=$'\t' read -r record_file record_line_number record_name_kind record_name record_reason <<<"$record_fields"
      violation_lines+=("$record_file:$record_line_number  $record_name_kind $record_name —— $record_reason") ;;
    MISSING_REASON)
      IFS=$'\t' read -r record_file record_line_number <<<"$record_fields"
      mark_lines+=("$record_file:$record_line_number  naming-lint:external 后面没写理由") ;;
    EXEMPTED)
      IFS=$'\t' read -r record_file record_line_number record_reason <<<"$record_fields"
      exempt_lines+=("$record_file:$record_line_number —— $record_reason") ;;
    DECLARATION_TOTAL) declaration_count="$record_fields" ;;
  esac
done < "$report_file"

if [[ ${#exempt_lines[@]} -gt 0 ]]; then
  warn "按 naming-lint:external 豁免 ${#exempt_lines[@]} 行（名字是外部定的）："
  for exempt_line in "${exempt_lines[@]}"; do warn "  $exempt_line"; done
fi
if [[ ${#mark_lines[@]} -gt 0 ]]; then
  for mark_line in "${mark_lines[@]}"; do say "        $mark_line"; done
  bad "${#mark_lines[@]} 处 naming-lint:external 没写理由，那几行照常查"
  howto "在标记后面写清为什么这个名字不归我们定，例： // naming-lint:external 字段名照外部格式的规范原样写" \
        "没有理由的豁免等于把这一行的检查关掉，而看的人不知道为什么。"
  failure_count=$((failure_count+1))
fi
if [[ ${#violation_lines[@]} -gt 0 ]]; then
  for violation_line in "${violation_lines[@]}"; do say "        $violation_line"; done
  bad "${#violation_lines[@]} 处名字不合命名纪律（查了 ${#rust_files[@]} 个 .rs 文件、$declaration_count 个声明的名字）"
  howto "照 rules/code-discipline.md 的「名字」一节改：缩写写全，单字母按它是什么来命名，名字长不要紧。" \
        "项目自己的领域缩写（lba、crc 这类）确实要用，就登记进 .claude/abbreviations：<缩写>  # <全称与含义>" \
        "名字是外部定的（外部格式的字段名这类），在那一行写 // naming-lint:external <为什么>" \
        "「e57」这类是项目登记过的编号，就在 .claude/abbreviations 登记 e<数字>  # <登记在哪张表>"
  failure_count=$((failure_count+1))
fi
[[ $failure_count -eq 0 ]] || exit 1
ok "命名纪律通过：查了 ${#rust_files[@]} 个 .rs 文件、$declaration_count 个声明的名字"
