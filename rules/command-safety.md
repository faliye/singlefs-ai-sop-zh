<!-- doc-lint:rule-definition -->
# 进程与命令规范

有十条是会红的检查，由 `scripts/shell-lint.sh` 判：
**按模式匹配杀进程**（`pkill -f`、`killall`）、**`pgrep -f`**、**靠子 shell 里的赋值往外带值**、
**脚本里用 git 的撤销命令**、**`rm -rf` 作用在没守卫的变量路径上**、**不带参数的 `wait`**、**设了 `pipefail` 的脚本里以 `grep -q` 收尾的管道**、**拿文件大小判 `/proc`、`/sys`、cgroupfs 下的文件空不空**、**`$*` 与 `$@` 的去前缀模式里带空格**、**往人看的输出里按字节截**。
测试装置跑完删没删自己建的镜像，由 `gate.sh` 的「跑完没留下临时文件」判。
项目根下新建没登记的文件与目录，由钩子 `scripts/claude-hooks/root-entry-guard.sh` 与 `gate.sh` 的「项目根的新条目」判。
仓里没登记的软链接，由 `gate.sh` 的「软链接」判。
命令丢了输出又判计数或空，由钩子 `scripts/claude-hooks/discarded-output-count-check.sh` 记录并提醒。
子 agent 交回之前没删的编译目录与仓副本，由钩子 `scripts/claude-hooks/handback-scratch-check.sh` 判。

## 退不回去的操作，动手前先想一遍

判据：**这一步做完，还能不能退回去？**

| 类型 | 例子 | 怎么办 |
|---|---|---|
| **丢掉未提交的改动** | `git checkout <文件>`、`git restore`、`git reset --hard`、`git clean` | 先 `git stash` 或 `cp` 一份出去；只在明确要丢掉这个文件的全部未提交改动时才用 |
| **直接删数据** | `rm -rf`、`> 文件`、`sed -i`、`rsync --delete`、`mkfs`、`dd` | 先看清目标（`ls`/`git status`/`lsblk`），变量路径加 `${VAR:?}` 守卫 |

**临时试验在副本里做**，别在工作区改了再撤。

**脚本里一律不许出现 git 的撤销命令。** 要在脚本里回到干净状态，就先 `git stash`，
或者把整个仓拷一份出来在副本上做。

**`rm -rf` 作用在变量路径上要加空值守卫**：写成 `rm -rf "${build_directory:?}/cache"`，不写 `rm -rf "$build_directory/cache"`。
`rm -rf "$build_directory"` 这种后面不跟路径的不用管。

路径由几段变量拼成的（`"$a/$b"`、`"${root}/${name}"`），其中一段为空就可能落到别处，`${拼成的变量:?}` 只挡整串为空：拼的那一行每一段都带守卫（`dir="${root:?}/${name:?}/x"`），路径固定的写字面的绝对路径。
`scripts/shell-lint.sh` 的 S5 判这一条：`rm -rf` 的参数是这份文件里拼出来的变量，而拼的那一行有一段没带守卫，判红。

## 项目根下不新建文件与目录

项目根下（仓根那一层）不新建文件或目录。新东西放进已有的目录：草稿与日志放 `$TMPDIR` 或会话的草稿目录，脚本、记录、产物放项目定好的目录。
删掉之后再建也算新建。被 `.gitignore` 忽略的同样算。本包自己要放在根下的 `.git`、`.claude`、`CLAUDE.md`、`.singlefs-ai-sop-version` 不用登记。

确实要在根下建：

1. 先向用户申请：说清要建的名字、里面放什么、为什么不能放进已有的目录。
2. 用户同意了，在项目根的 `.claude/root-entries` 登记一行 `<名字>  # 理由`：名字只写根下那一层，不带别的 `/`；理由写放什么、为什么在根下，至少 4 个字；一个名字只登记一行。
3. 再建。登记表与新建的条目在同一次提交里提交。
4. 条目删掉了，登记表里那一行同一次删掉。

工具每次都会重建的（编译目录这类），登记一次就行。

| 谁判 | 判什么 |
|---|---|
| 钩子 `scripts/claude-hooks/root-entry-guard.sh` | Write、Edit、NotebookEdit 要写到根下一个还不存在、也没登记的条目里，执行前拒绝；改登记表（这几种工具，或 Bash 命令里写到它）要用户在界面上确认；Bash 命令跑完，根下多出没登记的条目，报给 agent，要它挪走或去申请 |
| 门禁阶段「项目根的新条目」（`scripts/root-entries.py`） | 相对 diff 基准，根下新加的条目（跟踪的，与没被忽略的未跟踪的）每个都要登记；登记行没写理由、理由太短、名字不止一层、重复，或登记的条目不在、也不被 `.gitignore` 覆盖，判红 |

钩子在 `.claude/settings.json` 上注册，写法在它的文件头。

管不了的：用户同意没有、理由成不成立，靠 review；被忽略的条目门禁不判，只有钩子看得到；Bash 里建的，钩子在命令跑完之后才报；Bash 写登记表的写法拼在变量里或写在解释器里的，认不出，不要求确认。

## 仓里不放软链接

仓里（项目根往下，`.git` 除外）不放软链接：跟踪的、没跟踪的、被 `.gitignore` 忽略的都算。用到别处的文件，拷一份进来，或者在用到它的地方写明真实路径。
本包的仓与装了本包的每个项目都照这一条，各自在自己的项目根下登记。

确实要留的软链接：

1. 在项目根的 `.claude/soft-link-exempt` 登记一行 `<相对项目根的路径>  # 理由`：路径不带开头的 `/`，不带 `.` 与 `..`；理由写它指向哪、为什么不能换成拷贝或写明路径，至少 4 个字；一条路径只登记一行。
2. 软链接删掉了，或换成了普通文件，登记那一行同一次删掉。

门禁阶段「软链接」（`scripts/soft-links.py`）判：工作区里的软链接，与暂存区里模式是 `120000` 的条目，没登记的逐个列出路径判红；`gate.sh --staged` 时连源仓工作区里的一起判。
豁免表的行没写理由、理由太短、路径不是相对项目根的、重复，或登记的路径不是软链接，判红。

管不了的：理由成不成立，靠 review；`.git` 目录里的不判。

## `pkill -f` / `killall` 一律禁用

要停进程就先 `ps` 列出来看清楚，再用**写死的 pid** 另起一条命令去杀；
也可以交给 `scripts/proc.py stop 进程号`：它先发 TERM，过 `--grace` 秒（默认 10）还在再发 KILL，要停的是发出命令的进程自己或它的祖先时拒绝。
统计类的改用 `/proc` 里的结构化信息，并且排掉自己这一支进程树。

**等待循环里同样不用 `pgrep -f`**（`until ! pgrep -f "进程名"; do sleep 5; done` 这种）。
等一个进程结束，用它**写死的 pid**：`until ! kill -0 "$pid" 2>/dev/null; do sleep 5; done`；
等自己起的后台任务用 `wait`；不是自己起的（别的脚本拉起来的守护进程之类），让起它的一方把 pid 写进文件再等。
pid 没记下来的，用 `scripts/proc.py find 可执行文件名 [--argument 参数]` 找进程号：它按可执行文件名逐字比，不拿模式串去比整条命令行，也不列发出这条命令的那一支进程；
拿到进程号再 `scripts/proc.py wait 进程号 --timeout 秒` 等它退出，到点还没退出就列出还活着的、退出码 3。
`scripts/shell-lint.sh` 的 S3 那条对脚本里命令位置上的每一处 `pgrep -f` 都红（`if` / `while` / `until` / `!` / `coproc` 后面也算命令位置），
不看同一行还有没有 `kill`。
手敲的命令由 `scripts/claude-hooks/pattern-process-guard.sh` 在执行前拒绝，判据与 shell-lint 的 S2（按模式匹配杀进程）、S3（`pgrep -f`）是同一份（`scripts/lib.sh` 的 `PATTERN_KILL_RE`、`PATTERN_PGREP_RE`），
拒绝时给出按进程号办事的写法。它是 Claude Code 的 PreToolUse 钩子，项目在 `.claude/settings.json` 的 `hooks.PreToolUse` 里注册一次：

```json
{"matcher": "Bash", "hooks": [{"type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR\"/.claude/singlefs-ai-sop/scripts/claude-hooks/pattern-process-guard.sh"}]}
```

没注册的会话里，手敲的命令仍然只靠这一条文字。

## 并行不许把失败吃掉

收束只有两种写法：起的时候记 `pids+=($!)`、收的时候逐个 `wait "$pid"` 取退出码；
或者并行的每一项各写一个退出码文件，收的时候按派活时那张表的顺序逐个判。
不用不带参数的 `wait`，也不在后台体里写 `|| bad=1` 再由父进程读 `$bad`。

`scripts/shell-lint.sh` 的 S6 判这一条：命令位置上不带参数的 `wait` 判红。
退出码确实在别处收了的，在那一行写 `# shell-lint:exit-collected <怎么收的>`，理由不许省。

**并行的每一项，输出不许直接往 stdout 写。** 每项写自己的文件，收的时候按派活的顺序回读。

**派出去多少项，就要收回来多少项。** 收的时候数一遍，与派出去的条数对不上就整道红。

**改成并行之后要重新证明它红得出来**：拿一个必红的输入喂进去，看并行版本还红不红。

## `/proc`、`/sys`、cgroupfs 下的文件，读内容判空不空

这几处的文件大小不反映内容：procfs 与 cgroupfs 报 0，sysfs 报 4096。
判空不空、有没有进程，读出内容再判：`[[ -n "$(< "$cgroup_directory/cgroup.procs")" ]]`；不用 `[ -s 文件 ]`、`stat` 的 `%s`、`find` 的 `-size` 与 `-empty`。

`scripts/shell-lint.sh` 的 S8 判这一条：这三种写法作用在字面以 `/proc/`、`/sys/` 开头、或文件名是 `cgroup.<名字>` 的路径上判红。
路径全在变量里、文件名也认不出的不判；shell 以外的语言（python 的 `os.path.getsize`、`st_size` 这类）不判，靠 review。

## 子 shell 里的赋值传不回父进程

`exit_code="$(run_one ...)"` 这种写法里，`run_one` 内部给变量的赋值**在父进程里是空的**。
**要传值就落到文件或者走参数，别靠变量。** 它是 `scripts/shell-lint.sh` 里会红的一项。

## 管道里的退出码不是你想要的那个

`命令 | head` 之后的 `$?`、`命令 | grep 模式 && 后续动作`，判的都是管道最后一段，不是 `命令`。

**做法**：想判前一段成没成，用 `${PIPESTATUS[0]}`，或者干脆别接管道——
先把输出落到变量或文件里，判完退出码再处理。

`scripts/shell-lint.sh` 的 S7 判其中一种：设了 `pipefail` 的脚本里，以 `grep -q` 收尾的管道（`… | grep -q 模式`）判红。
改法：先把前段的输出落到变量，再 `grep -q 模式 <<<"$变量"`；这种没有前段的写法不判。

## 测试镜像一律放临时目录

不许放在仓库里。镜像路径统一从环境变量取，默认落到 `${TMPDIR:-/tmp}`。

**建镜像的装置在测试结束时自己删掉它**：成功、失败、panic 都删。Rust 用 Drop 守卫，shell 用 `trap … EXIT`。
要留着看现场，由显式的开关（环境变量）打开，留下时打印路径；没打开就删。
门禁阶段判红时可以把现场留在 `$TMPDIR` 里，出路里点它的路径。
有意跨轮复用的缓存（编译产物这类）不是镜像：放 `${GATE_CROSS_RUN_TMPDIR:-${TMPDIR:-/tmp}}` 下或项目定的位置，不放 `$TMPDIR`。

`gate.sh` 判这一条：每一轮给各阶段一个这一轮自己的 `TMPDIR`，收尾时看里面还剩什么（阶段「跑完没留下临时文件」）：
别的阶段都绿，剩下的判红、列出名字与大小，退出时替它们删掉；有阶段判红，这一项记本次未判，这一轮的临时目录整个留着、打印路径，看完自己删。
判红时这样留着的只留最近 3 个，更早的由之后跑的那一轮删掉。
它看不见的：路径写死 `/tmp`、不走 `TMPDIR` 的装置，门禁之外手跑的测试，以及门禁被打断之后还在跑的子进程建的。

## `$*` 与 `$@` 的去前缀、去后缀逐个参数各做一次

`${*#模式}`、`${@#模式}`（与 `##`、`%`、`%%`）对每个参数各去一次再拼起来；模式里带空格时它想去的那一段只在拼好的串里，一处都去不掉。
要对拼好的整串去，先拼成一串再去：`joined="$*"`，再写 `"${joined#* -- }"`。

`scripts/shell-lint.sh` 的 S9 判这一条：这几种写法的模式里带空格就判红。

## 往人看的输出里按字符截，不按字节截

GNU 的 `cut` 带 `-c` 或 `-b`、`head` 与 `tail` 带 `-c` 都按字节数；多字节字截在中间会留下半个字，读输出的一方按 UTF-8 解时报坏字节。
截给人看的文字（失败行、说明、日志摘录）照 `scripts/lib.sh` 的 `clip_text <字节数>` 截：先按字节截，再丢掉不成字的尾巴。
只截 ASCII 的（十六进制摘要这类）照旧按字节截，在那一行写 `# shell-lint:bytes-ok <理由>`。

`scripts/shell-lint.sh` 的 S10 判这一条：同一行里有这几种按字节截的写法，又往外打（`say`、`bad`、`howto`、`echo`、`printf` 或 `✗`），而没有那一行标记，判红。
截出来先存进变量、在别的行再打的，它认不出，靠 review。

## 拿来下结论的命令不丢输出

要据一条命令说「零命中」「没出错」「退出码说明了什么」的，这条命令不把 stderr 丢进 `/dev/null`，也不丢 stdout（`2>/dev/null`、`&>/dev/null`、`>/dev/null 2>&1` 都算丢）。
`grep -c 模式 文件 2>/dev/null || echo 0` 这一类写法打出的 0 不当零命中。

空输出、0 先确认命令真跑成了：看它的退出码（同一条命令末尾接 `; echo rc=$?`）与报错，跑成了再当零命中。

钩子 `scripts/claude-hooks/discarded-output-count-check.sh` 判其中一半：Bash 命令跑完之后判，命令里丢了输出、同一条命令又在判计数或空（`grep -c`、`wc -l`、`test -z`、`[ -z`、`|| echo 0` 这类），记进检出记录并提醒一句，不拒绝。
它认的写法以那个钩子的 `DISCARD_FORMS`、`COUNT_FORMS` 为准；命令里写了 `# discarded-output: <为什么可以丢>` 的只记不提醒。据那条命令下没下结论，它不判。
项目可以不注册它（文件头写了 `# hook-registration: optional`），注册的写法在那个钩子的文件头。

## 子 agent 交回之前，删掉自己建的编译目录与仓副本

子 agent 在草稿目录里拷的仓副本、用自己的 `CARGO_TARGET_DIR` 编出来的编译目录，交回之前由它自己删掉：

- **删**：这一次自己建的编译目录（`target`、`CARGO_TARGET_DIR` 指的目录，以及别的带 `CACHEDIR.TAG` 的缓存）与仓副本（clone、拷出来的仓、git worktree）。
  工作树在它的源仓里用 `git worktree remove --force <路径>` 删，源仓里的登记一起清掉；其余 `rm -rf`。
- **不删**：报告、要入库的产物、主 agent 还要核的复跑材料；前任、主 agent 或别的 agent 建的，哪怕在同一个草稿目录里；
  项目根里的（项目自己的 `target`、Claude Code 建在项目里的 worktree），那些归主 agent。
- 删之前先 `du -sh` 记下大小，交回报告里写一行删了哪些、各多大。
- 没删的，在交回报告里逐个写一行「没删 <全路径>：<为什么>」。只把路径当出处引一下（「在副本 … 上跑的」）不算。

钩子 `scripts/claude-hooks/handback-scratch-check.sh` 查这一条，挂两处：

- 交回工具（`SubagentHandback`）的 PreToolUse：交回之前拦。临时目录里、在这个子 agent 自己的某次工具调用还没结束时建的、
  它的调用里提到过的编译目录、工作树与仓副本还在，这一次交回的报告里又没有写它的那一行，就不让交回，把清单交给它。
- SubagentStop：没经交回工具就收工时兜底。送达了的交回报告里写了那一行的不拦（被拒掉的那次不算）；
  拦下之后，回复里或写下的报告里写了那一行再收工，就放行（只 du、ls、Read 一下不算）。

项目在 `.claude/settings.json` 上注册这两处，写法在那个钩子的文件头。
它认不出的照样要删：路径只在变量里的、脚本内部建了而调用里没提到的、自己建的目录下面隔了不止一层的、
不带 `.git` 也没在里面编过的源码副本、调用返回之后才由脱离出去的进程（`nohup`、`setsid`、`&`）建的。报告里那一行写没写，它不查。
