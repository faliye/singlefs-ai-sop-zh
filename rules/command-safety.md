<!-- doc-lint:rule-definition -->
# 进程与命令规范

脚本里的写法由 `scripts/shell-lint.sh` 判（S1 到 S10），每一节点名的钩子与门禁阶段判其余的；各自认哪些写法，以脚本为准。
钩子在 `.claude/settings.json` 上注册，写法在各钩子的文件头。

## 退不回去的操作，动手前先想一遍

判据：**这一步做完，还能不能退回去？**

| 类型 | 例子 | 怎么办 |
|---|---|---|
| **丢掉未提交的改动** | `git checkout <文件>`、`git restore`、`git reset --hard`、`git clean` | 先 `git stash` 或 `cp` 一份出去；只在明确要丢掉这个文件的全部未提交改动时才用 |
| **直接删数据** | `rm -rf`、`> 文件`、`sed -i`、`rsync --delete`、`mkfs`、`dd` | 先看清目标（`ls`/`git status`/`lsblk`），变量路径加 `${VAR:?}` 守卫 |

- **临时试验在副本里做**，不在工作区改了再撤。
- **脚本里不许出现 git 的撤销命令。** 要回到干净状态，先 `git stash`，或者把整个仓拷一份出来在副本上做。
- **`rm -rf` 作用在变量路径上要加空值守卫**：写 `rm -rf "${build_directory:?}/cache"`。`rm -rf "$build_directory"` 这种后面不跟路径的不用加。
- 路径由几段变量拼成的，拼的那一行每一段都带守卫（`dir="${root:?}/${name:?}/x"`）；路径固定的写字面的绝对路径。`scripts/shell-lint.sh` 的 S5 判拼的那一行有一段没带守卫的。

## 项目根下不新建文件与目录

项目根下（仓根那一层）不新建文件或目录：草稿与日志放 `$TMPDIR` 或会话的草稿目录，脚本、记录、产物放项目定好的目录。
删掉之后再建也算新建，被 `.gitignore` 忽略的也算。`.git`、`.claude`、`CLAUDE.md`、`.singlefs-ai-sop-version` 不用登记。

确实要在根下建：

1. 先向用户申请：要建的名字、里面放什么、为什么不能放进已有的目录。
2. 用户同意了，在项目根的 `.claude/root-entries` 登记一行 `<名字>  # 理由`：名字只写根下那一层，不带别的 `/`；理由写放什么、为什么在根下，至少 4 个字；一个名字只登记一行。
3. 再建。登记表与新建的条目在同一次提交里提交。
4. 条目删掉了，登记那一行同一次删掉。

工具每次都会重建的（编译目录这类），登记一次就行。

钩子 `scripts/claude-hooks/root-entry-guard.sh` 在写之前拒绝、在 Bash 命令跑完之后报多出来的条目，改登记表要用户确认；门禁阶段「项目根的新条目」（`scripts/root-entries.py`）判相对 diff 基准新加的条目与登记表的写法。
用户同意没有、理由成不成立，靠 review。

## 仓里不放软链接

仓里（项目根往下，`.git` 除外）不放软链接：跟踪的、没跟踪的、被忽略的都算。用到别处的文件，拷一份进来，或者在用到它的地方写明真实路径。
本包的仓与装了本包的每个项目都照这一条，各自在自己的项目根下登记。

确实要留的，在项目根的 `.claude/soft-link-exempt` 登记一行 `<相对项目根的路径>  # 理由`：路径不带开头的 `/`，不带 `.` 与 `..`；理由写它指向哪、为什么不能换成拷贝，至少 4 个字；一条路径只登记一行。
软链接删掉或换成普通文件，登记那一行同一次删掉。

门禁阶段「软链接」（`scripts/soft-links.py`）判。

## `pkill -f` / `killall` 一律禁用

- **停进程**：先 `ps` 看清楚，再用写死的 pid 另起一条命令去杀；或者 `scripts/proc.py stop 进程号`（先 TERM，过 `--grace` 秒、默认 10 秒还在再 KILL；要停的是发出命令的进程自己或它的祖先时拒绝）。
- **等进程结束**：不用 `pgrep -f`。自己起的后台任务用 `wait "$pid"`；别的用写死的 pid：`until ! kill -0 "$pid" 2>/dev/null; do sleep 5; done`；不是自己起的，让起它的一方把 pid 写进文件。
- **pid 没记下来**：`scripts/proc.py find 可执行文件名 [--argument 参数]` 找进程号，再 `scripts/proc.py wait 进程号 --timeout 秒`（到点没退出，退出码 3）。
- **统计类**：用 `/proc` 里的结构化信息，排掉自己这一支进程树。

脚本里由 `scripts/shell-lint.sh` 的 S2、S3 判，手敲的命令由钩子 `scripts/claude-hooks/pattern-process-guard.sh` 在执行前拒绝，两处是同一份判据。

## 并行不许把失败吃掉

- 收束只有两种写法：起的时候记 `pids+=($!)`、收的时候逐个 `wait "$pid"` 取退出码；或者每一项各写一个退出码文件，收的时候按派活的顺序逐个判。
- 不用不带参数的 `wait`，不在后台体里写 `|| bad=1` 再由父进程读 `$bad`。退出码确实在别处收了的，在那一行写 `# shell-lint:exit-collected <怎么收的>`。
- 每一项的输出写自己的文件，不直接往 stdout 写；收的时候按派活的顺序回读。
- 派出去多少项，收回来多少项：收的时候数一遍，对不上就整道红。
- 改成并行之后，拿一个必红的输入喂一次，看它还红不红。

`scripts/shell-lint.sh` 的 S6 判不带参数的 `wait`。

## `/proc`、`/sys`、cgroupfs 下的文件，读内容判空不空

这几处的文件大小不反映内容。判空不空、有没有进程，读出内容再判：`[[ -n "$(< "$cgroup_directory/cgroup.procs")" ]]`；
不用 `[ -s 文件 ]`、`stat` 的 `%s`、`find` 的 `-size` 与 `-empty`。

`scripts/shell-lint.sh` 的 S8 判 shell 里这三种写法作用在字面以 `/proc/`、`/sys/` 开头、或文件名是 `cgroup.<名字>` 的路径上的；别的语言靠 review。

## 子 shell 里的赋值传不回父进程

`exit_code="$(run_one ...)"` 里，`run_one` 内部给变量的赋值在父进程里是空的。**要传值就落到文件或者走参数。**
`scripts/shell-lint.sh` 判。

## 管道里的退出码不是你想要的那个

`命令 | head` 之后的 `$?`、`命令 | grep 模式 && 后续动作`，判的都是管道最后一段。
想判前一段，用 `${PIPESTATUS[0]}`，或者先把输出落到变量或文件里，判完退出码再处理。

`scripts/shell-lint.sh` 的 S7 判：设了 `pipefail` 的脚本里以 `grep -q` 收尾的管道。改成先落到变量，再 `grep -q 模式 <<<"$变量"`。

## 测试镜像一律放临时目录

- 镜像不放仓库里；路径从环境变量取，默认落到 `${TMPDIR:-/tmp}`。
- **建镜像的装置在测试结束时自己删掉它**：成功、失败、panic 都删。Rust 用 Drop 守卫，shell 用 `trap … EXIT`。
- 要留着看现场，由显式的环境变量打开，留下时打印路径。
- 门禁阶段判红时可以把现场留在 `$TMPDIR` 里，出路里点它的路径。
- 有意跨轮复用的缓存（编译产物这类）放 `${GATE_CROSS_RUN_TMPDIR:-${TMPDIR:-/tmp}}` 下或项目定的位置，不放 `$TMPDIR`。

`gate.sh` 的阶段「跑完没留下临时文件」判：每一轮给各阶段一个自己的 `TMPDIR`，收尾时里面还剩东西就红。有别的阶段判红时，这一轮的临时目录整个留着、打印路径，看完自己删。
路径写死 `/tmp` 的装置、门禁之外手跑的测试，它看不见。

## `$*` 与 `$@` 的去前缀、去后缀逐个参数各做一次

`${*#模式}`、`${@#模式}`（与 `##`、`%`、`%%`）对每个参数各去一次再拼起来。
要对拼好的整串去，先拼成一串：`joined="$*"`，再写 `"${joined#* -- }"`。

`scripts/shell-lint.sh` 的 S9 判：这几种写法的模式里带空格。

## 往人看的输出里按字符截，不按字节截

`cut -c`、`cut -b`、`head -c`、`tail -c` 都按字节数。截给人看的文字（失败行、说明、日志摘录）用 `scripts/lib.sh` 的 `clip_text <字节数>`。
只截 ASCII 的（十六进制摘要这类）照旧按字节截，在那一行写 `# shell-lint:bytes-ok <理由>`。

`scripts/shell-lint.sh` 的 S10 判同一行里截了又往外打的；截出来先存进变量、别的行再打的靠 review。

## 拿来下结论的命令不丢输出

- 要据一条命令说「零命中」「没出错」「退出码说明了什么」的，这条命令不丢 stderr，也不丢 stdout（`2>/dev/null`、`&>/dev/null`、`>/dev/null 2>&1` 都算丢）。
- `grep -c 模式 文件 2>/dev/null || echo 0` 这一类写法打出的 0 不当零命中。
- 空输出、0 先确认命令真跑成了：同一条命令末尾接 `; echo rc=$?`，看退出码与报错。

可选钩子 `scripts/claude-hooks/discarded-output-count-check.sh` 在命令跑完之后记录并提醒，不拒绝；命令里写了 `# discarded-output: <为什么可以丢>` 的只记不提醒。

## 子 agent 交回之前，删掉自己建的编译目录与仓副本

- **删**：这一次自己建的编译目录（`target`、`CARGO_TARGET_DIR` 指的目录、别的带 `CACHEDIR.TAG` 的缓存）与仓副本（clone、拷出来的仓、git worktree）。
  工作树在它的源仓里用 `git worktree remove --force <路径>` 删；其余 `rm -rf`。
- **不删**：报告、要入库的产物、主 agent 还要核的复跑材料；前任、主 agent 或别的 agent 建的，哪怕在同一个草稿目录里；项目根里的（项目自己的 `target`、Claude Code 建在项目里的 worktree），那些归主 agent。
- 删之前先 `du -sh`，交回报告里写一行删了哪些、各多大。
- 没删的，在交回报告里逐个写一行「没删 <全路径>：<为什么>」。只把路径当出处引一下（「在副本 … 上跑的」）不算。

钩子 `scripts/claude-hooks/handback-scratch-check.sh` 在交回之前与 SubagentStop 上拦。它认不出的照样要删：路径只在变量里的、脚本内部建了而调用里没提到的、自己建的目录下面隔了不止一层的、不带 `.git` 也没在里面编过的源码副本、脱离出去的进程（`nohup`、`setsid`、`&`）建的。
