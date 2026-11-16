---
name: gate
description: 跑本项目的准入门禁。提交代码前、判断一个改动能不能收时用它——包含门禁各阶段的含义、怎么判读结果、哪些"失败"是环境问题而不是代码问题。
---

# 准入门禁

规则在 `rules/show-me-test.md`。**这里只写怎么跑、怎么看结果、哪些失败是假的。**

## 跑

```bash
bash .claude/scripts/gate.sh          # 全套，提交前必跑
bash .claude/scripts/check.sh         # 只跑格式/lint/构建/单元测试，快速反馈
bash .claude/scripts/env.sh           # 只做环境自检
GATE_BASE=<commit> bash .claude/scripts/gate.sh   # 指定 diff 基准
bash .claude/scripts/gate.sh --staged # 只拿 HEAD + 暂存区跑：几个会话共写一个仓时用，红的就是这次提交带进来的
```

## 阶段与判读

每个阶段红的时候自己打出卡在哪、下一步做什么，照它做。各阶段红了说明什么、规则在哪：

| 阶段 | 失败意味着 | 规则 |
|---|---|---|
| 规范版本 | 项目的 `.singlefs-ai-sop-version` 跟 singlefs-ai-sop 的 `VERSION` 对不上。**先读一遍规则改了什么**，再跑 `install.sh` 更新戳 | |
| 副本与上游同版本 | 跑的不是项目里那份副本（改跑 `bash .claude/scripts/gate.sh`），或者副本的 `VERSION` 与兄弟目录里上游仓的不同：副本落后就从上游重拷一份再跑 `install.sh`，上游比副本旧就先更新或提交上游那一版 | |
| 门禁自检 | 有条拒绝没给出路，或者扫一批对象的检查成功时没报数 | `rules/sop-first.md`「每一条拒绝都必须给出下一步」、`rules/show-me-test.md`「门禁不许假装通过」 |
| 准入与运行条件 | 有脚本的 `admission:` / `run-condition:` 声明、`preflight` 调用或 `preflight_record_success` 不合规，或者排除表、登记表指向不存在的路径。库与样本登记进 `.claude/preflight-exclude` | `rules/preflight-discipline.md` |
| 门禁判别力 | 样本判出来跟预期不一样：**门禁自己坏了**，先修它，别的先放着 | |
| shell 纪律 | 脚本里有 `shell-lint.sh` 的 S1 到 S10 禁的写法 | `rules/command-safety.md` |
| 脚本执行位 | 暂存区里有 `.sh` 不是 `100755`，或者暂存区里的模式与工作区的执行位不一致：用 `git update-index --chmod=+x <路径>`（或 `-x`）改。射程里有空目录也判红：要留的放一个 `.keep` 再 `git add` | |
| 本地阶段判别力 | `.claude/gate.d/fixtures/<阶段>/` 下有样本判错：退出码不对，或者输出里找不到 `want=` 那一句。先判是阶段坏了还是样本写错了，再修那一边；没配样本的阶段记「本次未跑」 | |
| 链接指向 | 文档里的相对链接指到不存在的路径（相对路径按链接所在文件的目录算），或者「第 <数字> 节」超出了目标文档的 `##` 节数、目标读不出来。「第 <数字> 节」改成指小节标题。原样保存的证据目录登记进 `.claude/doc-lint-exclude` | |
| 历史条目编号 | 这一次新增的历史条目在同一个「`##` 节 + 日期 + 点名词」下撞了「（其 <序号>）」的号。改成下一个没被占的号，不改别人已提交的那条 | `rules/kb-discipline.md` 第 8 条「正文只写现状，历史放文末的「历史版本」」 |
| 工具层的闸 | `.claude/hooks/` 或副本 `scripts/claude-hooks/` 里有钩子没在 `.claude/settings.json` 注册、带 `--selftest` 的自证没过、`hook-events` 里的事件没挂全，或者写了工具名的没挂在认得它的 matcher 上。照钩子文件头的写法注册 | `rules/sop-first.md`「加门禁或钩子之前，先找已有的」 |
| 项目根的新条目 | 项目根下新加的文件或目录没在 `.claude/root-entries` 登记，或者登记表写得不合规。先挪进已有的目录；确实要放根下，向用户申请，同意了再登记 | `rules/command-safety.md`「项目根下不新建文件与目录」 |
| 软链接 | 仓里有软链接没在项目根的 `.claude/soft-link-exempt` 登记，或者豁免表写得不合规。换成拷贝或写明真实路径再删掉软链接；确实要留就登记 | `rules/command-safety.md`「仓里不放软链接」 |
| 门禁查重 | 这一次新加或改动的门禁与钩子没写 `gate-similar` / `hook-events`、该点名的没点全、理由太短，或者加进来的行与已有的一份整段相同。先跑 `python3 .claude/singlefs-ai-sop/scripts/gate-overlap.py --list` 找管同一件事的，能并就并 | `rules/sop-first.md`「加门禁或钩子之前，先找已有的」 |
| 转发计时 | `.rs` 与 `.py` 里有读子进程输出的循环一边给行打时间戳、一边把行转打出去。先照规则改；时间戳确实不进计时结论的，在循环头写 `// relay-timing-lint:allow <理由>`（Python 写 `#`） | `rules/show-me-test.md`「分段计时在被测进程里计，不在转发输出的循环里计」 |
| 同名定义 | `.py` 里同一作用域、或 `.sh` 里同一个文件顶格写了两个同名的定义。改名或删掉一个；有意覆盖的在后一个定义那一行写 `# duplicate-definitions:allow <理由>` | `rules/code-discipline.md`「同一作用域里一个名字只定义一次」 |
| 代号 | 这一次新加的 `.md` 行里拿代号指东西（`5a`、`10g`、`SC02` 这类）。写出它是什么；命令、文件名放进反引号；项目自己有登记位的编号体系在 `.claude/code-names` 登记 | `rules/writing-discipline.md`「不写缩写，不用代号指东西」 |
| 编号与简称 | 源码注释、脚本、记录里引的「编号（简称）」与 kb 登记位的简称对不上。照登记位（各正文首行 `## D<序号> 简称 —— 状态`）抄简称 | `rules/kb-discipline.md` 第 5 条「编号只能做索引，不能做称呼」 |
| 文档铁律 | 正文里混了历史陈述，kb 里引用编号没带简称，或者 CLAUDE.md 没把规则一条条 @ 进来 | `rules/design-doc-discipline.md` 第 1 条、`rules/kb-discipline.md` 第 5 条、`rules/writing-discipline.md` |
| 文档铁律的未实现清单 | `doc-lint.sh --not-impl` 跑失败了，汇总末尾的未实现清单会少掉它那几条。单跑 `bash .claude/singlefs-ai-sop/scripts/doc-lint.sh --not-impl` 看原因（退 78 是它的准入与运行条件不满足） | |
| 规则纪律（项目本地） | 项目的 `.claude/rules/`（没有这个目录时是 `.claude/agents/`）、项目 `CLAUDE.md`、agent 定义或 skill 正文不合规。还没回扫的文件逐个登记进 `.claude/rules-lint-exclude` | `rules/rules-discipline.md` |
| 命名纪律 | `.rs` 里我们声明的名字用了单字母或常见缩写，或者 `.claude/abbreviations`、`.claude/naming-lint-exclude` 写得不合规 | `rules/code-discipline.md` |
| Show me test | 改了 `crates/*/src` 或 `crates/*/build.rs` 却没带测试。**这条不许绕** | `rules/show-me-test.md` |
| 构建与单测 | 真的坏了，或者 cargo 没装。clippy 按 `-D warnings` 判，另外封闭集合的枚举上不许写 `_ =>` | |
| 规则清单 | 项目里：装的副本被改过或没拷全，从上游重拷一份副本再跑 `install.sh`。SOP 仓里：清单跟规则不同步，或者有面向人的文本既没进清单也没豁免，改完跑 `bash scripts/manifest.sh --update`。装的是英文、日文副本时这一项退 77，记「本次未跑」：清单只在参照仓（中文仓）里维护，译本仓跟没跟上由中文仓的「各语言同步」判 | |
| 项目登记的未实现手段 | `.claude/gate-not-implemented.tsv` 有一行少了键或说明，或者键与共享键、别的行重名。一行写成 `键<制表符>缺的是什么<制表符>覆盖之后仍要提醒的话`，一个键只登记一处 | |
| 项目本地阶段 | `.claude/gate.d/` 里某个本地检查红了，或者读不了；「覆盖声明（…）」红，是 `# gate-covers:` 写了清单里没有的项 | |
| 工作区跑的过程中没变 | 门禁跑的这段时间里工作区的文件变了，各阶段读到的不是同一版。等改动停下再跑，或者用 `--staged` | |
| 跑完没留下临时文件 | 某个阶段（或它起的测试、装置）在这一轮的 `TMPDIR` 里建了东西、跑完没删。让建它的一方跑完自己删。有别的阶段判红时这一项记本次未判，临时目录整个留着给你看现场（只留最近 3 个） | `rules/command-safety.md`「测试镜像一律放临时目录」 |

**只在 SOP 仓自己跑的四个阶段**（消费项目看不到）：

| 阶段 | 失败意味着 |
|---|---|
| 规则纪律 | 本包的 `rules/`、`CLAUDE.md`、`agents/*.md`、`skills/*/SKILL.md` 违反了 `rules/rules-discipline.md` 能落成字面的那几条 |
| 各语言同步 | 某个译本仓找不到、共享部分或清单没跟上，或者某篇译文首行的溯源哈希不是当前源文。共享部分跑 `bash scripts/i18n-sync.sh --update`；译文按当前源文重译后跑 `bash scripts/i18n-sync.sh --stamp <语言> <篇目>…` |
| 版本纪律 | 改了 `scripts/version-discipline.sh` 的 `GOVERNED` 管的路径却没抬 `VERSION`，或者 `VERSION` 降了 |
| CHANGELOG 连续 | `CHANGELOG.md` 最新一节不是 `VERSION`，相邻两节跳号、重复或倒序，或者有不是版本节的二级标题。给每一版补一节 |

## 未实现的阶段

`gate.sh` 每次都会列出共享门禁**没实现**的验证手段：最终判据、shell 脚本的命名纪律，以及项目自己登记在项目根 `.claude/gate-not-implemented.tsv` 里的那几项。
最终判据与项目登记的那几项只能由项目在 `.claude/gate.d/` 里接：接上的阶段在头部写 `# gate-covers: <那一项>`，这一轮跑了且通过，那一项才换到「由项目本地阶段覆盖」下面。

**判读结果时带上这份清单**：门禁全绿只说明「文档合规 + 有测试 + 单元测试过」，外加「由项目本地阶段覆盖」那一栏里各阶段各自验到的范围。

- 项目登记的手段没有阶段覆盖时，不说「那一样验证过了」。
- 有阶段覆盖，也只说到那个阶段自己验到的范围为止（登记表里「覆盖之后仍要提醒的话」那一列，`gate.sh` 在收尾照打）。

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

改了 `scripts/` 里的检查之后，**必须造一个应该被拦的输入验证它真的会红**：

```bash
# 造一个该被拦的样本，喂给 doc-lint，确认它真的红：kb 文档缺了收尾的历史节（结构检查，哪种语言的仓都判）
sample_directory=$(mktemp -d); mkdir -p "$sample_directory/kb"
printf '# 决策\n\n节点大小 16K。\n' > "$sample_directory/kb/decisions.md"
bash .claude/singlefs-ai-sop/scripts/doc-lint.sh "$sample_directory"; echo "退出码 $? —— 应为 1"
rm -rf "$sample_directory"
```

- **样本要另建一个目录**，别往真的 kb 文件尾巴上 `>>`。
- 改完检查还要跑一遍 `bash .claude/singlefs-ai-sop/scripts/selftest.sh`：它拿 `scripts/fixtures/` 下的样本证明每条检查现在还红得起来。
- **加一条检查就配一个样本**，`want=` 要写这条检查自己的消息，不写成几条检查共用的片段。
