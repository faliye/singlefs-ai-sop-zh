<!-- doc-lint:rule-definition -->
# singlefs-ai-sop-zh

**贡献者治理规范和门禁工具（Contributor Governance）。**
管的是**项目怎么跟 AI 协作**，不管文件系统怎么设计。
只有 singlefs 一个使用者。在这个仓里干活，同样受这些规则管。

改规范本体**必须同时抬 `VERSION`**，否则项目那边的门禁会报版本对不上。
**哪些路径算「规范本体」，以 `scripts/version-discipline.sh` 里的 `GOVERNED` 为准**，
清单只有那一处，这里不再抄一份。
抬了版本就在 `CHANGELOG.md` 顶部给这一版写一节，每一版一节、不许跳号，由 `scripts/changelog-lint.sh` 判。

## 对话语言

**在这个仓里干活，对话和产出一律用中文。** 装的是哪种语言的仓就用哪种语言，
为什么这么做、有哪些语言，见 [README](README.md) 的「多语言」一节，这里不重复。

**各语言版本读起来不一致时，不看语种，以 `scripts/` 的实际行为为准。**

**改规则就得把所有已发布的语言版本一起改、一起合并**，一致性由改的人自己保证：
门禁只看得出哈希对不上，看不出各版本说的是不是一回事。

**什么要翻译、什么原样复制**，判据是「里面有没有给人读的散文」。
清单在 `scripts/manifest.sh`（`translated_paths` 和 `not_translated_re` 两张表）。
两边都不沾的文本会被覆盖率检查拦下来。

## 规则（始终生效）

@rules/engineering-philosophy.md
@rules/sop-first.md
@rules/show-me-test.md
@rules/machine-first.md
@rules/doc-discipline.md
@rules/design-doc-discipline.md
@rules/kb-discipline.md
@rules/test-discipline.md
@rules/evidence-discipline.md
@rules/verify-before-claiming.md
@rules/pushback-discipline.md
@rules/command-safety.md
@rules/writing-economy.md
@rules/writing-style.md
@rules/session-wrapup.md

## 分工判据

**这套 SOP 是给 singlefs 做的，只有它一个使用者，不假设别的项目也能用。**
所以判据不是「别的项目会不会也需要」——根本没有别的项目可看，
这个问题谁都能答「会」，答完什么都往上游塞。

一条内容该放哪，看它管的是什么：

- **管协作**：提交要带什么证据、文档怎么写、决策记在哪、门禁拒绝时给什么下一步。
  → 放这个仓。方法论进 `rules/`，流程进 `skills/`，能跑的进 `scripts/`。
- **管文件系统怎么设计**：事务、崩溃一致性、盘上格式这一类系统特有的纪律。
  → 放项目本地。设计决策进 `kb/decisions.md`，不变量进 `kb/invariants.md`，
  **项目自己的规则进 `.claude/rules/`**，项目专用脚本留在 `.claude/scripts/`。

**拿不准就放项目本地。** 一条不该上游的规矩上了游，此后每一轮工作都要绕开它；
放项目本地放错了，改回来只动一个文件。

## 接法

项目不复制这个仓的内容，每一层各有各的接法（**不用符号链接**）：

| 层 | 接法 |
|---|---|
| rules | 项目 `CLAUDE.md` 用 `@.claude/singlefs-ai-sop/rules/x.md` 引用，项目里不留副本 |
| 项目本地规则 | 放 `.claude/rules/x.md`，项目 `CLAUDE.md` 里用 `@.claude/rules/x.md` 引用。不上游 |
| skills | 项目 `.claude/skills/<名>/SKILL.md` 是**桩**：frontmatter + 指向共享正文 |
| agents | 项目 `.claude/agents/<名>.md` 是**桩**，同上。约定见 `agents/INDEX.md` |
| scripts | 项目 `.claude/scripts/x.sh` 是**包装**：设好环境后 `exec` 共享脚本 |

桩和包装里不写正文，也不写逻辑。正文只该有一处，写进桩里就多出第二处，两处早晚说不同的话。
