# singlefs-ai-sop-zh

**中文** | [English](https://github.com/faliye/singlefs-ai-sop-en) | [日本語](https://github.com/faliye/singlefs-ai-sop-ja)

**贡献者治理规范与门禁工具（Contributor Governance），独立分发。**

**它管的是「项目怎么跟 AI 协作」**：提交要带什么证据、文档怎么写才不会被检索误读、
决策记在哪、门禁拒绝时必须给出什么。这几件事跟你在做什么系统没关系。

> **实现上 AI 友好，审核上人类友好。**

**它不管的是：文件系统该怎么设计。** 事务、崩溃一致性、盘上格式这一类纪律属于项目本地，
放在项目自己的 `.claude/rules/` 里。一条内容该放上游还是放项目本地，判据在 [CLAUDE.md](CLAUDE.md) 的「分工判据」一节：
**拿不准就放项目本地**。

**这份 README 不是规范来源。** 规范正文是 `CLAUDE.md` 加 `rules/`；README 只指路，不定规矩。

## 使用者

**只有一个。** 这个仓不为「将来别的项目也许用得上」做设计：那种设想没有对照，只会让规矩越写越松。

使用者把这个仓的一份副本放在自己的 `.claude/singlefs-ai-sop/`，每个参与者拿到的是同一份规矩、同一套门禁脚本、同一批 skill；
项目自己的规则、决策与验证手段都留在项目里。
副本不带这个仓自己的 `CLAUDE.md`（同步时排除它）：留在副本里会被当成目录级 CLAUDE.md，
项目里只要读一份副本里的规则，这份 `CLAUDE.md` 连同它 `@` 的全部规则就整份注入进那个上下文。

装完之后项目根会多一个 `.singlefs-ai-sop-version`，门禁拿它跟这套包的 `VERSION` 比，对不上就红：规矩变过了，先读一遍再跑。

## 本仓的变更门槛

这份 SOP 是所有参与者共用的地基，改它的门槛比改项目里任何一处都高。想加或改一条，先过三关：

| 关 | 问什么 |
|---|---|
| 1 | **它管的是协作吗**。文件系统设计特有的放项目自己的 `.claude/rules/`，拿不准就放项目本地 |
| 2 | **它能变成一个会失败的检查吗**。变不成的先留在项目 kb 里当待议（见 [rules/sop-first.md](rules/sop-first.md)） |
| 3 | **写得出拒绝时的下一步吗**。写不出就先别加这条检查。形式由 `scripts/gate-lint.sh` 强制 |

三关都靠人判断，门禁只管第 3 关的形式：门禁证明证据够不够，不证明语义对不对。
该看的信号是**改得勤不勤**：这份东西老是变，说明它的设计有问题。

- **日常活儿不在这个仓。** 设计决策、不变量、实验、项目本地规则都在项目自己的 `.claude/` 下。
- **版本号**：`0.x` 表示还没定型，随时会改，项目那边要跟着动；到了 `1.0.0` 之后，`rules/` 应该很少再改。
- **改了规范本体就抬 `VERSION`**，下游靠版本戳发现规矩变了。「规范本体」管哪些路径，以 `scripts/version-discipline.sh` 里的 `GOVERNED` 为准，没抬由它判红。
- **改了规则还要重译**，各语言同版本，由 `scripts/i18n-sync.sh` 判。

## 里面有什么

| 路径 | 内容 |
|---|---|
| `CLAUDE.md` | **共享规范的入口。** 对话语言、分工判据，以及 `@` 引用 `rules/` 的那份清单 |
| `rules/` | **规矩本身。** 一条一篇，都要能落到某个会失败的检查上 |
| `scripts/` | **门禁脚本，这个仓最重要的部分。** 规矩的可执行形式 |
| `skills/` | Claude Code skill：怎么跑门禁、怎么记决策 |
| `agents/` | 共享 subagent 定义。**已纳入治理，当前为空**，约定见 `agents/INDEX.md` |
| `templates/` | 项目侧 `CLAUDE.md` 与 `kb/` 的骨架 |
| `install.sh` | 把这套东西接进一个项目 |
| `GLOSSARY.md` | 术语的跨语言对照表，各语言仓共用一份 |
| `I18N` / `MANIFEST.sha256` | 语言族配置；规则清单（译本的对账依据）|
| `VERSION` | 规范版本号。门禁会检查项目声明的版本跟这套包一不一致 |

## 装到一个项目里

```bash
# 用安装器（会问你要哪种语言，装完顺带跑一次门禁）
git clone https://github.com/faliye/singlefs-ai-sop-install
bash singlefs-ai-sop-install/sop-install.sh --lang zh --dest <你的项目>

# 或者手动：自己 clone 对应语言的仓，再跑 install.sh
cd <你的项目>
git clone https://github.com/faliye/singlefs-ai-sop-zh .claude/singlefs-ai-sop
bash .claude/singlefs-ai-sop/install.sh
```

`install.sh` 会铺下面这些东西，**每一步都回读确认，失败就非零退出**：

| 落点 | 内容 |
|---|---|
| `CLAUDE.md`（项目根） | 一层薄壳 + `@` 引用共享规范 |
| `.claude/kb/` | kb 骨架七篇 |
| `.claude/scripts/*.sh` | 包装，`exec` 到共享脚本；里面不写逻辑 |
| `.claude/skills/*/SKILL.md` | 桩，frontmatter 加一句指向共享正文 |
| `.claude/agents/*.md` | agent 桩，同上（`agents/` 现在是空的，所以暂时不会铺） |
| `.singlefs-ai-sop-version`（项目根） | 版本戳 |

**已存在的文件一律不覆盖**，只报告差异。版本戳只在**没有一份落后于上游**时才刷新。

kb 骨架、skill 桩这些是给项目改的。项目把接管的那几份写进 `.claude/install-owned`，一行一条 `<相对路径>  # 为什么`：
`install.sh` 不再拿它们跟上游比，登记了的那份项目删掉了也不会被再铺回来。**代价是此后上游对它们的改动都不会再送到。**
清单坏了（没写理由、或者写了 `install.sh` 根本不铺的路径）当场判红，版本戳不刷新。

项目更新完副本，跑一次 `bash .claude/scripts/gate.sh`，版本对不上会报出来。

## 为什么规范要独立成仓

[rules/show-me-test.md](rules/show-me-test.md) 那条准入铁律（判据是自动化验证）只有在大家跑的是同一套门禁时才成立。
各项目各维护一份 `.claude`，迟早有人说「我这边是过的」，提交的人也就不知道自己该验到什么程度。

## 多语言

**多语言只是分发方式，不是几套不同的规范。** 开发者按自己的语言挑版本，装哪种语言的仓就用哪种语言干活，AI 也不用再翻一道。
项目只装其中一份，装出来的规则、skill、agent 桩、kb 骨架全是那一种语言。

一种语言一个仓，项目安装时只 clone 自己那一种，目录名统一成 `.claude/singlefs-ai-sop`，所以 `@` 引用的路径和脚本包装一个字都不用改：

| 仓 | 语言 |
|---|---|
| [singlefs-ai-sop-en](https://github.com/faliye/singlefs-ai-sop-en) | 英语（默认版本） |
| [singlefs-ai-sop-zh](https://github.com/faliye/singlefs-ai-sop-zh) | 中文（清单与脚本放在这儿） |
| [singlefs-ai-sop-ja](https://github.com/faliye/singlefs-ai-sop-ja) | 日语 |

更多语言版本开发中。

`I18N` 里 `this=` 是本仓的语言，`default=en` 是默认版本，`languages=` 是已发布的语言，`reference=` 指明清单与门禁脚本维护在哪一个仓（现在是中文仓）。

**中文之外的版本先用机器翻译铺开，规范定版之前会做精确翻译。**
**各语言读起来不一致时，以 `scripts/` 的实际行为为准。**

### 一次贡献要覆盖全部已发布语言

**不管你用哪种语言写，提交都必须同时改到所有已发布的语言版本，一起合并。** 只带自己那一种语言的提交不收：
只要有一次「先改这份，别的下次再说」就会分叉，而用另一种语言的人不知道自己读的是旧的。
哪一份写得不清楚就改哪一份，顺便回头看看别的版本是不是也不清楚。
各版本说的是不是同一件事，由改的人自己保证；门禁只看得出哪几篇哈希对不上。

对账靠 `MANIFEST.sha256`，里面记着每一份含给人读的散文的文本的路径和哈希：`CLAUDE.md`、`rules/`、`agents/`、`skills/`、`templates/`。

- 判据只有一条：**里面有没有给人读的散文。** 有就翻译，没有就原样复制；两边都不沾的会被 `scripts/manifest.sh` 的覆盖率检查拦下来。
- 改了清单覆盖的任何一篇，就要跑 `bash scripts/manifest.sh --update`，否则门禁会红。
- 其余语言的仓各存一份 `SOURCE-MANIFEST.sha256`，比两份清单就知道哪几篇落后了。它不用手抄：在本仓跑 `bash scripts/i18n-sync.sh --update`，
  逐篇溯源都对上的译本仓，它照本仓的清单刷新；有一篇没重译就不抄，并列出是哪几篇。

## 许可

双许可：[Apache-2.0](LICENSE-APACHE) 或 [MIT](LICENSE-MIT)，任选其一。

除非你另外声明，你有意提交并被本项目采纳的贡献，按 Apache-2.0 的定义，
都按上面这个双许可授权，不附加额外条款。
