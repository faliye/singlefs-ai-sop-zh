<!-- doc-lint:rule-definition -->
# 准入与运行条件：先判能不能跑，再跑

**每个脚本在开头写明什么时候该调它、什么时候不能调它，开跑之前先判：条件不满足就拒绝执行，带 `--force` 才照跑。**

管全部脚本：本包的 `install.sh` 与 `scripts/`（含 `scripts/claude-hooks/`、`scripts/githooks/`），
项目的 `.claude/gate.d/`、`.claude/scripts/`、`.claude/hooks/`，以及项目在 `.claude/preflight-dirs` 里登记的目录——
实验脚本、实验二进制的源文件放在哪，就登记哪。每个目录只算它自己那一层，子目录另登记一行。
`.claude/preflight-dirs` 一行一条 `<目录>  # 放的是什么`；没有实验的项目也建这个文件，写一行注释说明。

不判的三类：被 source 或 import 的库、样本、只 exec 共享脚本的包装（install.sh 铺的那几行，夹了别的逻辑就照普通脚本判）。
库与样本逐个登记进排除表：本包的在 `scripts/preflight-lint.py` 的 `PACKAGE_EXCLUDED`，项目的在 `.claude/preflight-exclude`，
一行一条 `<路径>  # 理由`，理由至少 4 个字。还没改完的脚本也逐个登记进去，改完一个删一行，排除只缩不涨。

## 两类条件

| 条件 | 回答什么 | 典型的 |
|---|---|---|
| 准入 `admission:` | 什么时候该调它：这一次调有没有意义 | 代码、决策与跑前登记自上次成功跑完以来没变，重跑得不到新信息 |
| 运行 `run-condition:` | 什么时候不能调它：环境撑不撑得住、会不会把结果弄脏 | 缺工具、缺设备或权限、同一个脚本已有实例在跑 |

每个脚本两类各至少写一行；写了几行，全部满足才算满足。实验的准入写 `inputs-changed`，登记它的结果取决于的全部输入：代码、决策、跑前登记。

## 写法

写在文件头的注释块里（`#!` 之后、第一行代码之前；shell 与 python 用 `#`，Rust 用 `//`，Rust 的内属性 `#![…]` 可以夹在里面），一行一条：

| 写法 | 满足的条件 |
|---|---|
| `admission: always <理由>` | 每次调都有意义。理由写清凭什么，例如它判的是此刻全仓的样子 |
| `admission: inputs-changed <路径…> [env:<变量名>…] [arguments]` | 脚本自己与登记的输入自上次成功跑完以来变过。路径相对仓根，`./`、`../` 开头的相对脚本所在目录；`env:<变量名>` 与 `arguments` 把环境变量、这一次的参数算进输入。写了几行就合成一份输入 |
| `admission: check <命令> :: <不满足时怎么办>` | 命令退出码为 0 |
| `run-condition: none <理由>` | 没有环境要求 |
| `run-condition: command <可执行文件名…>` | 都在 `PATH` 上 |
| `run-condition: single-instance` | 没有别的进程在跑同一个脚本 |
| `run-condition: check <命令> :: <不满足时怎么办>` | 命令退出码为 0 |

`always`、`none` 的理由与 `check` 的出路至少 8 个字。
`check` 的命令用 `bash -c` 在仓根跑（不在 git 仓里时在脚本所在目录），环境里有 `PREFLIGHT_SCRIPT` 与 `PREFLIGHT_SCRIPT_DIRECTORY`，读不到调用方的标准输入。
不在 git 仓里时判不了输入变没变，照跑，也不记指纹。
声明的解析与现判只在 `scripts/preflight.py` 一处，写法以它为准。

## 开头先判

| 语言 | 写法 |
|---|---|
| shell | `source lib.sh`（不 source lib.sh 的钩子 source `preflight.sh`）之后、第一件干活的事之前照抄：`preflight "${BASH_SOURCE[0]}" "$@"; set -- ${PREFLIGHT_ARGUMENTS[@]+"${PREFLIGHT_ARGUMENTS[@]}"}`。它之前只许 `set <选项>`、`shopt`、`source`、整行只是赋值且不读参数的行、`unset` |
| python | 先 `sys.dont_write_bytecode = True`，再 import 本包的 `scripts/preflight.py`；`if __name__ == '__main__':` 的第一句调 `preflight(__file__)`，没有这一段的，放在模块里第一句干活的语句之前。在它之前的顶层语句不许读参数、读标准输入、起子进程、开文件 |
| Rust 与别的语言 | `main` 的第一句调名叫 `preflight` 的函数：它直接起 `python3 <规范副本>/scripts/preflight.py check <源文件的绝对路径> [--force] -- <参数…>`（不经 `sh -c`），退出码不是 0 就原样退出；stdout 那一行以 `met` 起头时记下它最后一段的指纹，以 `forced` 起头时把最后一段摘要当成 `PREFLIGHT_FORCED` |

写了 `inputs-changed` 的，成功跑完、退出之前调 `preflight_record_success`（Rust 执行 `preflight.py record <源文件> --fingerprint <开跑时的指纹> -- <参数…>`）。
记的是开跑时判的那份指纹；收尾时输入已经变了（跑的过程中有人改了）、这一次是强制跑的、跑失败了，都不记。

## 不满足时

- 没带 `--force`：逐条打出没满足的条件与出路，退出码 78，一步都不做。没有 `python3` 判不了条件，也按不满足办。退出码 78 只用于这一种拒绝。
- 带了 `--force`：照跑，逐条打出没满足的条件，`PREFLIGHT_FORCED` 置成它们的摘要。
  写产物的脚本把 `PREFLIGHT_FORCED` 写进产物；引用这份产物时写明它是强制跑的。
- 条件写坏了（认不出的写法、理由太短）判不了：脚本退 1，门禁把那个阶段记失败。

## gate.sh 怎么编排

- 起每个阶段之前先判它的条件；不满足就不起它，汇总里记「本次未跑」并列出没满足的条件。
- `gate.sh --force` 把 `--force` 转给条件没满足的阶段；这样跑过的阶段在汇总里记「强制跑过」，
  不记通过，也不算覆盖了未实现清单里的哪一项。
- 起不起只信门禁的预判：阶段起了之后退 78，一律按失败记。
- 这一轮有阶段强制跑过，或者因为「输入没变」之外的原因没起，就不前移 gate-ok，末句也不说「全部通过」；
  门禁的退出码只看有没有阶段判红。

## 门禁管哪一半

门禁阶段「准入与运行条件」（`scripts/preflight-lint.py`）判：两类声明齐不齐、写法认不认得、写没写在第一行代码之前、
`inputs-changed` 登记的路径在不在、开头先调了 `preflight` 没有（shell 还要它之前 source 过 lib.sh 或 preflight.sh）、
写了 `inputs-changed` 的调没调 `preflight_record_success`、排除表与登记表指不指得到。
项目没有 `.claude/preflight-dirs` 时，汇总里把实验脚本这一类记成「本次未查」。

管不了的：条件写得对不对、全不全（`inputs-changed` 漏了一份输入、`check` 判的不是真要的那件事）、
`always` 与 `none` 的理由成不成立、产物里写没写强制标记、写在 `preflight` 那一行之后的声明（运行时也不认它）。这几样靠 review。
