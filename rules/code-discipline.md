<!-- doc-lint:rule-definition -->
# 编码纪律

写代码时照着做。放宽的只有为了让人脑装得下而做的压缩，把含义写明白这件事一点都不放宽。

管的是这个项目里我们自己写的全部代码与文本，不分语言、不分目录：产品代码、测试、实验代码、脚本、配置与构建文件，以及文档（README、设计说明、kb、规则、skill、agent 定义、commit message、门禁的失败信息）。
例子用 Rust 写；别的语言照同一条判据，换成那门语言里对应的写法。
文档照两样：提到的名字照「名字」一节起；文字照「注释里不写缩写，不用代号指东西」那一条写。
门禁查到哪一步，见「门禁管哪一半」。

## 名字：光看名字，就说得出它是什么、做什么

**判据：不看注释、不看调用点、不看实现，光看这个名字，说不说得出它是什么、做什么、不做什么。**
说不出就改名。起不出这样的名字，先想清楚这段代码要做什么。

管的是**我们自己声明的每一个名字**：变量、参数、函数、方法、类型、字段、枚举成员、常量、
模块、文件、泛型参数、生命周期、闭包参数、循环变量、测试函数、宏。
外部定下的名字不归我们管：实现 `Display` 就得叫 `fmt`。

| 规矩 | 细则 |
|---|---|
| **长度不设限** | 没有「名字要短」这一条 |
| **不用缩写** | `cnt`、`idx`、`buf`、`tmp` 一律写全。例外只有登记过的领域缩写，见「缩写登记表」 |
| **不用单字母** | 循环变量、闭包参数、泛型参数、生命周期、错误绑定都算：`i` → `stripe_index`，`T` → `Key`，`'a` → `'journal`，`Err(e)` → `Err(error)` |
| **前置条件和作用范围写进名字** | `write_node` 什么都没说；`append_verified_node_to_journal` 说了三件事：追加不覆盖、入参验过、落在日志区 |
| **单位写清** | 类型表达得了就交给类型（`LogicalAddress`、`Duration`）；表达不了就写进名字：`offset_in_blocks`，不是 `offset` |
| **布尔写成判断句** | 说清哪一边为真：`is_checksum_verified`，不是 `flag`、`status`、`ok` |
| **测试名写场景和预期** | `crash_between_data_write_and_commit_keeps_previous_generation`，不是 `test_commit`、`it_works` |
| **一个语义概念全仓一个名字** | 单位是语义概念，不是词：同一个概念不许这里叫 `generation`、那里叫 `epoch`；两个概念哪怕底层含义相近（盘上记的代号、事务生命周期里的代号），也不许共用一个名字，各自带上角色：`committed_generation`、`transaction_generation` |
| **名字自己站得住，不靠模块路径补全** | 写 `block::BlockAddress`，不写 `block::Address`。类型名因此连成一套人工命名空间（`BlockAddress`、`JournalAddress`、`LogicalAddress`……），照这样写 |
| **不拿序号、位置当名字** | 函数、变量、参数、类型、字段、常量、模块、文件，每一种名字都一样：`layer0`、`stream_0`、`step2`、`phase_1`、`first_item` 这类只说「第几个」的名字不许用，写成它做什么、管什么：`stream_0` → `metadata_journal_stream`，`layer0` → `checksum_verification_layer`。几个实例确实只差位置的，放进一个集合，用带类型的下标区分（`stream_index: StreamIndex`），不分别起带号的名字。登记过的项目编号带简称照用，见「缩写登记表」 |
| **换了含义就换名字** | 同名遮蔽只在含义不变时用；原始数据变成验过的、字节数变成块数，就起新名字 |
| **同一作用域里一个名字只定义一次** | 同一个文件的同一个作用域（模块、类体、函数体；shell 是整个文件）里，函数、方法、类不许同名定义两次。新加一个定义之前，按名字在那个文件里搜一遍；撞了就改名，或者删掉一个。property 的 setter、`@overload`、singledispatch 的 `register` 不算 |

### 缩写不许用，判据是有没有一处权威定义

**判据是「有没有一处权威定义」，不是「大家看不看得懂」。**
Rust 的关键字和基本类型名（`mut`、`fn`、`str`、`u64`）不算缩写，语言规范就是它们那一处定义；
项目自己的领域缩写（`lba`、`crc`）要登记了才能用。

### 缩写登记表

项目根的 `.claude/abbreviations`，一行一条，`#` 后面写全称和含义：

```text
lba  # logical block address：逻辑块地址，文件系统给块编的号
crc  # cyclic redundancy check：循环冗余校验
```

登记表就是这个缩写唯一的权威定义，别处照它用，不另写一份。
**单字母不许登记。**

**项目自己的编号**（kb 里登记的实验号、决策号这类）当名字的一段用时，按「字母加数字」这一整类登记：

```text
e<数字>  # 实验编号，登记在 .claude/kb/experiments.md
```

登记之后 `e57_field_authority` 里的 `e57` 就不算单字母。编号在名字里同样要带着简称
（`kb-discipline.md` 第 5 条「编号只能做索引，不能做称呼」）：写 `e57_field_authority`，不写光秃秃的 `e57`。

### 语义放在哪：注释 < 名字 < 类型

同一件事的三种写法，从差到好：

```rust
// 一、语义在注释里 —— 最差
// dim0: 民族  dim1: 性别  dim2: 年龄段
pop[i][j][k]

// 二、语义在名字里
number_of_china_people[han][woman][teenager_18_to_24]

// 三、语义在类型里 —— 最好，写错维度直接编译不过
number_of_china_people[Ethnicity::Han][Gender::Woman][AgeBand::Teenager18To24]
```

**类型能表达的交给类型，类型表达不了的写进名字，都别写进注释。**

## 分支：穷举写全，不写通配臂

```rust
enum Medium {
    Rotational,
    SolidState,
    Zoned { zone_size_in_bytes: u32 },
}

fn node_size_in_bytes(medium: &Medium) -> u32 {
    match medium {                                  // 没有 `_ =>` 通配臂：新增一种 Medium 不补这里就编译不过
        Medium::Rotational                   => 64 * 1024,
        Medium::SolidState                   => 16 * 1024,
        Medium::Zoned { zone_size_in_bytes } => (*zone_size_in_bytes).min(256 * 1024),
    }
}
```

**判据不是「分支多不多」，是「漏了一种情形谁先发现」**：要让编译器先发现，不是生产环境。

- **封闭集合的枚举，`match` 不写 `_ =>`。** 我们自己的枚举默认是封闭集合：有几种情形由我们说了算。
- **语义上允许未知值的**（盘上读到的、协议里收到的、以后还会加新值的编码），把「未知」做成一个显式成员
  （`Unrecognized(raw_code)`），`match` 照样穷举，也不写通配臂。
- **真正开放的只有两种**：外部的枚举（别的库的、标了 `#[non_exhaustive]` 的），以及我们对外承诺、
  要给以后留演进余地的公开 API（见「什么时候不套用」）。确实需要通配臂时，
  在那一处写 `#[allow(clippy::wildcard_enum_match_arm, reason = "…")]`。
- **工作区内部用的枚举不标 `#[non_exhaustive]`。**
- **封闭的集合（有几种情形由我们说了算）用 `enum` 加穷举 `match`，不用 trait 对象。**
  两种情形之间的交互（状态转移、两两比较）可以写成对元组的穷举 `match`。开放的集合（插件、测试替身）照旧用 trait。
- **只有一个实现的 trait 不抽。** 至少有两个真实现（对拍用的模型也算一个）才抽 trait；
  不为「以后好换」而抽。
- **穷举 `match` 的臂数不算复杂度。** 要限的是彼此独立的条件。

## 类型：让非法状态写不出来

```rust
#[derive(Clone, Copy, PartialEq, Eq)] pub struct LogicalAddress(pub u64);
#[derive(Clone, Copy, PartialEq, Eq)] pub struct PhysicalAddress(pub u64);
fn read_block(address: PhysicalAddress) -> Block;   // read_block(LogicalAddress(value)) 编译不过

struct RawNode(Vec<u8>);        // 刚从盘上读出来，未验证
struct VerifiedNode(Vec<u8>);   // 校验和已比对通过
impl RawNode {
    fn verify(self, expected_checksum: Checksum) -> Result<VerifiedNode, CorruptBlock> { /* ... */ }
}
fn walk(node: &VerifiedNode) { /* ... */ }   // 想跳过验证就构造不出入参
```

- 同一种底层类型承载不同含义（逻辑地址、物理地址、代号；字节数、块数），各给一个 newtype。
- 「验没验过」「落没落盘」这类状态做成类型，不做成布尔字段。**边界上验一次**，换成带着证明的类型，
  往里就信类型，不在每一层重复检查。
- **布尔参数换成枚举**：`write(node, true)` 写成 `write(node, Durability::Synced)`。
- **有不变量的字段私有**，只能从检查过的构造函数进来；
  没有不变量的字段直接公开，不写样板 getter / setter。
- **带不变量的类型不实现 `Default`。**
- **构造我们自己的结构体时，每个字段都写出来**，不用 `..Default::default()`。
  必填的字段不交给 builder 在运行期查，写成构造函数参数；只有真可选的才进 builder。
- **会丢值的数值转换不用 `as`**：会丢值的方向用 `try_from` 并处理失败，不会丢值的方向用 `from`。

## 注释、断言、常量、重复

- **注释只写「为什么这样」**，不写「这在做什么」。
  约束写进类型、名字或断言，不写进注释。
- **注释里指别的文件的位置，写函数名、标题或唯一的锚串，不写行号。**
- **注释里不写缩写，不用代号指东西。** 缩写写全，例外只有登记过的领域缩写（见「缩写登记表」）；
  不用 `a`、`b`、`c`、`layer0`、`stream_0`、「层 0」「第一项」这类只说字母、序号、位置的代称，也不把几样东西略写成「a b c」一列：
  每一样写出它是什么、做什么，例如「第一项」写成「校验和那一项」。
- **文档注释写类型表达不了的契约**：会返回哪些错、什么时候 panic、`unsafe` 要调用方保证什么。
  复述名字的文档注释删掉。
- **每个 `unsafe` 块上面写 `// SAFETY:`**，说清为什么安全。
- **不变量写成断言**，不只写进文档。
- **魔法数字写成命名常量**：一个数只许有一处定义，名字或类型里带上单位。
- **重复要生成，不许手抄。** 宏和 `build.rs` 是生成的正路，只做生成、不藏逻辑，
  生成出来的东西要有测试盯着。
- **用不到的代码删掉**，注释掉的代码也删。
  编译器报的 `never used` 当错误处理。
- **`TODO` 写清缺什么、为什么现在不做。** 欠着的检查记进项目 kb 的欠账表，代码里指过去。

## 什么时候不套用

**这些细则对「删得掉的东西」随便用，对「删不掉的东西」要另说。**
写进对外承诺的东西（磁盘格式、协议、公开 API），判据单独定，不能拿一句「显式更安全」推过去。

## 门禁管哪一半

| 细则 | 谁查 |
|---|---|
| 单字母名、常见缩写 | `scripts/naming-lint.sh`（门禁阶段「命名纪律」）：扫项目里每个 `.rs`，只看我们声明的名字 |
| 封闭集合的枚举不写 `_ =>` | clippy `wildcard_enum_match_arm`；声明开放的，在那一处 allow 并写 reason |
| `#[allow]` 要写 `reason = "…"` | clippy `allow_attributes_without_reason` |
| 会丢值的 `as` 转换 | clippy `cast_possible_truncation`、`cast_sign_loss`、`cast_possible_wrap` |
| `unsafe` 块要有 `// SAFETY:` | clippy `undocumented_unsafe_blocks` |
| 含义无关的同名遮蔽 | clippy `shadow_unrelated` |
| `.py` 与 `.sh` 里同一作用域同名定义两次 | `scripts/duplicate-definitions.py`（门禁阶段「同名定义」）：扫全仓，冻结证据不扫，shell 只判顶格写的定义；按顺序重定义是有意的，在后一个定义那一行写 `# duplicate-definitions:allow <理由>`。赋值盖掉函数、import 进来的名字被 def 盖掉、跨文件的同名，它认不出，靠 review |
| 警告按错误处理 | clippy `-D warnings` |
| 名字说没说清、一个概念是不是一个名字、函数是不是只做一件事、注释写的是不是为什么、注释里有没有引别的文件的行号、名字与注释里有没有拿序号或位置当代称、注释里有没有缩写、错误成员是不是按调用方的决定分的、循环的状态有没有写清、`..Default::default()` | review |
| `.rs` 以外的代码（shell、python 这类）与文档里的名字、缩写、代称 | **还没做成检查**，`gate.sh` 把它列在未实现的阶段里（键「命名纪律（shell）」） |

clippy 那几条由 `scripts/check.sh` 带着跑，也就是门禁的「构建与单测」阶段；项目根没有 `Cargo.toml` 时这一阶段不跑。

`naming-lint.sh` 的缩写词表只列最常见的那些，**词表外的缩写照样违规**，只是门禁看不见。
它认不出的形态（跨行的模式、宏展开出来的名字）不判，交给 review，认不出不等于通过。
trait 实现里的方法名、关联类型，以及 `extern` 块里的声明，名字是外部定的，不查。

项目侧两份配置，一行一条，`#` 后面写理由，理由不许省：

| 文件 | 管什么 |
|---|---|
| `.claude/abbreviations` | 登记过的领域缩写，格式见「缩写登记表」 |
| `.claude/naming-lint-exclude` | 不扫的目录或单个 `.rs` 文件，写明为什么排除；指向不存在的路径、或者一个 `.rs` 都没排到，都判红。回扫旧代码时把还没改完的文件逐个列进来，改完一个删一行：排除只缩不涨，新文件照查 |

别的外部定名（外部格式的字段名这类），在那一行写 `// naming-lint:external <为什么这个名字不归我们定>`，
只豁免这一行，理由同样不许省。
