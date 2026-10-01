---
name: gate
description: 跑本项目的准入门禁。提交代码前、判断一个改动能不能收时用它——包含门禁各阶段的含义、怎么判读结果、哪些"失败"是环境问题而不是代码问题。
---

# 准入门禁

规则在 `rules/show-me-test.md`。**这里只写怎么跑、怎么看结果、哪些失败是假的。**

## 跑

```bash
bash .claude/scripts/gate.sh          # 全套，提交前必跑
bash .claude/scripts/check.sh         # 只跑格式/lint/构建/单测，快速反馈
bash .claude/scripts/env.sh           # 只做环境自检
GATE_BASE=<commit> bash .claude/scripts/gate.sh   # 指定 diff 基准
bash .claude/scripts/gate.sh --staged # 只拿 HEAD + 暂存区跑：几个会话共写一个仓时用，红的就是这次提交带进来的
```

## 阶段与判读

| 阶段 | 失败意味着 |
|---|---|
| 规范版本 | 项目的 `.singlefs-ai-sop-version` 跟 singlefs-ai-sop 的 `VERSION` 对不上。**先读一遍规则改了什么**，再跑 `install.sh` 更新戳 |
| 副本与上游同版本 | 跑的不是项目里那份副本，或者副本的 `VERSION` 与兄弟目录里上游仓的不同。跑的不是副本就改跑 `bash .claude/scripts/gate.sh`；副本落后就从上游重拷一份副本再跑 `install.sh`；上游比副本旧就先更新或提交上游那一版。兄弟目录里没有上游仓时这一项记「本次未检查」，见「常见假失败」 |
| 门禁自检 | 有条拒绝没给出路（`bad` 后面缺 `howto`、`die` 只带一句话、直接打印的 `✗` 后面没有 `→`），或者扫一批对象的检查成功时没报数。形态见 `rules/sop-first.md` |
| 准入与运行条件 | 有脚本开头没写 `admission:` / `run-condition:`、写法认不出、写在第一行代码之后、`inputs-changed` 登记的路径不在、开头没先调 `preflight`、写了 `inputs-changed` 却没调 `preflight_record_success`，或者排除表、登记表指向不存在的路径。照 `rules/preflight-discipline.md` 补；库与样本登记进 `.claude/preflight-exclude` |
| 门禁判别力 | 样本判出来跟预期不一样——**门禁自己坏了**，先修它，别的先放着 |
| shell 纪律 | 脚本里有 `pkill -f` / `killall` / `pgrep -f`、靠子 shell 的赋值往外带值、git 的撤销命令、`rm -rf` 作用在没守卫的变量路径上、不带参数的 `wait`，或者设了 `pipefail` 的脚本里以 `grep -q` 收尾的管道。见 `rules/command-safety.md` |
| 脚本执行位 | 暂存区里有 `.sh` 不是 `100755`，或者暂存区里的模式与工作区的执行位不一致（手工暂存时写死了 `100644`）。用 `git update-index --chmod=+x <路径>`（或 `-x`）改暂存区里的模式。射程里有空目录也判红：git 存不下空目录，要留的放一个 `.keep` 再 `git add` |
| 本地阶段判别力 | `.claude/gate.d/fixtures/<阶段>/` 下有样本判错：退出码不对，或者输出里找不到 `want=` 那一句。先判是阶段坏了还是样本写错了，再修那一边；没配样本的阶段记「本次未跑」 |
| 链接指向 | 文档里的相对链接指到不存在的路径，或者「第 N 节」超出了目标文档的 `##` 节数、目标读不出来。相对路径按链接所在文件的目录算；「第 N 节」改成指小节标题。原样保存的证据目录登记进 `.claude/doc-lint-exclude` 绕开 |
| 历史条目编号 | 这一次新增的历史条目在同一个「`##` 节 + 日期 + 点名词」下撞了「（其 N）」的号。查那一块已用到的最大号，把自己这条改成下一个没被占的号，不改别人已提交的那条。见 `rules/session-wrapup.md` 第 4 条 |
| 工具层的闸 | `.claude/hooks/` 或副本 `scripts/claude-hooks/` 里有钩子没在 `.claude/settings.json` 注册、带 `--selftest` 的自证没过、`hook-events` 里的事件没挂全，或者写了工具名的没挂在认得它的 matcher 上。照钩子文件头的写法注册；见 `rules/sop-first.md`「加门禁或钩子之前，先找已有的」 |
| 门禁查重 | 这一次新加或改动的门禁与钩子没写 `gate-similar` / `hook-events`、该点名的已有门禁或钩子没点全、理由太短，或者加进来的行与已有的一份整段相同。先跑 `python3 .claude/singlefs-ai-sop/scripts/gate-overlap.py --list` 找管同一件事的，能并就并；见 `rules/sop-first.md`「加门禁或钩子之前，先找已有的」 |
| 转发计时 | `research/`、`crates/` 下有读子进程输出的循环一边给行打时间戳、一边把行转打出去。改成在被测进程里计时、把数写进结果行，或者先把输出整份读完再转打，见 `rules/test-discipline.md`「分段计时在被测进程里计，不在转发输出的循环里计」；时间戳确实不进计时结论的，在循环头写 `// relay-timing-lint:allow <理由>`（Python 写 `#`） |
| 编号与简称 | 源码注释、脚本、记录里引的「编号（简称）」与 kb 登记位的简称对不上。照登记位（各正文首行 `## D<n> 简称 —— 状态`）抄简称；见 `rules/kb-discipline.md` 第 5 条 |
| 文档铁律 | 正文里混了历史陈述，kb 里引用编号没带简称，或者 CLAUDE.md 没把规则一条条 @ 进来。见 `rules/writing-discipline.md` |
| 文档铁律的未实现清单 | `doc-lint.sh --not-impl` 跑失败了，汇总末尾的未实现清单会少掉它那几条。单跑 `bash .claude/singlefs-ai-sop/scripts/doc-lint.sh --not-impl` 看原因（退 78 是它的准入与运行条件不满足） |
| 规则纪律（项目本地） | 项目的 `.claude/rules/`（没有这个目录时是 `.claude/agents/`）、项目 `CLAUDE.md`、agent 定义或 skill 正文里有记录小节、论证小节、带日期的行、解释性段落与半句、词法说明，或者没带劝阻句的历史链接。照 `rules/rules-discipline.md` 改；还没回扫的文件逐个登记进 `.claude/rules-lint-exclude` |
| 命名纪律 | `.rs` 里我们声明的名字用了单字母或常见缩写，或者 `.claude/abbreviations`、`.claude/naming-lint-exclude` 写得不合规。见 `rules/code-discipline.md` |
| Show me test | 改了 `crates/*/src` 或 `crates/*/build.rs` 却没带测试。**这条不许绕**，见 `rules/show-me-test.md` |
| 构建与单测 | 真的坏了，或者 cargo 没装。clippy 按 `-D warnings` 判，另外封闭集合的枚举上不许写 `_ =>` |
| 规则清单 | 项目里：装的副本被改过或没拷全，从上游重拷一份副本再跑 `install.sh`。SOP 仓里：清单跟规则不同步，或者有面向人的文本既没进清单也没豁免，改完跑 `bash scripts/manifest.sh --update` |
| 项目登记的未实现手段 | `.claude/gate-not-implemented.tsv` 有一行少了键或说明，或者键与共享键、别的行重名。一行写成 `键<制表符>缺的是什么<制表符>覆盖之后仍要提醒的话`，一个键只登记一处 |
| 项目本地阶段 | `.claude/gate.d/` 里某个本地检查红了，或者读不了；「覆盖声明（…）」红，是 `# gate-covers:` 写了清单里没有的项 |
| 工作区跑的过程中没变 | 门禁跑的这段时间里工作区的文件变了（自己还在改，或者别的会话在改），各阶段读到的不是同一版。等改动停下再跑，或者用 `--staged` |
| 跑完没留下临时文件 | 某个阶段（或它起的测试、装置）在这一轮的 `TMPDIR` 里建了东西、跑完没删，名字与大小列在那一段里。让建它的一方跑完自己删；有意跨轮复用的缓存放 `${GATE_CROSS_RUN_TMPDIR:-${TMPDIR:-/tmp}}` 下。有别的阶段判红时这一项记本次未判，临时目录整个留着给你看现场（只留最近 3 个，更早的由之后跑的那一轮删掉）。见 `rules/command-safety.md`「测试镜像一律放临时目录」 |
| 规则纪律 | 只在 SOP 仓跑。本包的 `rules/`、`CLAUDE.md`、`agents/*.md`、`skills/*/SKILL.md` 违反了 `rules/rules-discipline.md` 能落成字面的那几条，照那份改 |
| 各语言同步 | 只在 SOP 仓跑。某个译本仓找不到、共享部分或清单没跟上，或者某篇译文首行的溯源哈希不是当前源文。共享部分跑 `bash scripts/i18n-sync.sh --update`；译文按当前源文重译后跑 `bash scripts/i18n-sync.sh --stamp <语言> <篇目>…` |
| 版本纪律 | 只在 SOP 仓跑。改了 `scripts/version-discipline.sh` 的 `GOVERNED` 管的路径却没抬 `VERSION`，或者 `VERSION` 降了 |
| CHANGELOG 连续 | 只在 SOP 仓跑。`CHANGELOG.md` 最新一节不是 `VERSION`，相邻两节跳号、重复或倒序，或者有不是版本节的二级标题。给每一版补一节 |

**只在 SOP 仓自己跑的四个阶段**（消费项目看不到）：规则纪律、各语言同步、版本纪律、CHANGELOG 连续。

「规则清单」两边都跑，但问的不是一件事：在 SOP 仓里它问「清单跟规则同不同步」，
在项目里它比对的是**你装的那份副本**——副本被改过或者没拷全，这一项就红。
装的是 en / ja 副本时这一项退 77，汇总记「本次未跑」：清单只在参照仓（zh）里维护，译本仓跟没跟上由 zh 仓的「各语言同步」判。

## 未实现的阶段

`gate.sh` 每次都会列出共享门禁**没实现**的验证手段：最终判据、shell 脚本的命名纪律，以及项目自己登记在项目根 `.claude/gate-not-implemented.tsv` 里的那几项（一行一条：键、缺的是什么、覆盖之后仍要提醒的话）。
最终判据与项目登记的那几项只能由项目在 `.claude/gate.d/` 里接：接上的阶段在头部写 `# gate-covers: <那一项>`，这一轮跑了且通过，那一项才换到「由项目本地阶段覆盖」下面。

**这不是提示噪音，是判读结果的必要前提**：门禁全绿只说明「文档合规 + 有测试 + 单测过」，
外加「由项目本地阶段覆盖」那一栏里各阶段各自验到的范围。
项目登记的手段没有阶段覆盖时，任何「那一样验证过了」的说法都是假的；
有阶段覆盖，也只说到那个阶段自己验到的范围为止（登记表第三列写的提醒句，`gate.sh` 在收尾照打）。

## 常见假失败

| 现象 | 真因 |
|---|---|
| Show me test 说「无对象可判」 | 工作区跟基准没差别。**这既不是通过也不是失败**，改点东西再跑，或者用 `GATE_BASE=<ref>` 指定基准 |
| 「未检查副本是否落后上游」 | 上游仓不在兄弟目录里，这一项**查不了**。汇总里会单独列出来，别把它当成通过 |
| 接了阶段，未实现清单里却还列着那一项 | 那个阶段头部没写 `# gate-covers:`，或者这一轮它退了 77、跑红了。只有跑过且通过才换下来 |
| 构建阶段说 cargo 没装 | 环境问题。跑 `env.sh` 看看全貌，装好工具链再来 |
| doc-lint 把规则文档里举的例子报了 | 那个文件缺 `<!-- doc-lint:rule-definition -->` 标记，或者例子没放在反引号 / 「」里。带了标记正文照查，只豁免这两种写法里的例子 |
| Show me test 说没测试，可我明明写了 | 测试写在 `crates/*/src/` 里，又没加 `#[cfg(test)]`/`#[test]` 这类标注，脚本认不出来 |

## 门禁自己也要能失败

改了 `gate.sh` 或 `doc-lint.sh` 之后，**必须造一个应该被拦的输入验证它真的会红**：

```bash
# 造一个该被拦的样本，喂给 doc-lint，确认它真的红：kb 文档缺了收尾的历史节（结构检查，哪种语言的仓都判）
d=$(mktemp -d); mkdir -p "$d/kb"
printf '# 决策\n\n节点大小 16K。\n' > "$d/kb/decisions.md"
bash .claude/singlefs-ai-sop/scripts/doc-lint.sh "$d"; echo "退出码 $? —— 应为 1"
rm -rf "$d"
```

⚠️ **样本要另建一个目录，别往真的 kb 文件尾巴上 `>>`。**
`>>` 追加的内容落在「## 历史版本」后面，而正文扫描在历史节那一行就停了。
退出码是 0，看着像「检查没做事」，其实是样本造错了地方。

改完检查还要跑一遍 `bash .claude/singlefs-ai-sop/scripts/selftest.sh`。
它拿 `scripts/fixtures/` 下的样本证明每条检查现在还红得起来。
**加一条检查就配一个样本**，`want=` 要写这条检查自己的消息。
写成几条检查共用的片段，等于没盯住（见 `rules/show-me-test.md`）。

按 `rules/show-me-test.md`：证明不了会红的检查，等于没写。
