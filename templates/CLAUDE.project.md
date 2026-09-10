# <项目名>

<三到五行：这个项目是什么、现在在哪个里程碑、跟 singlefs 主线什么关系。别写更长。>

## 规则（始终生效）

@.claude/singlefs-ai-sop/rules/engineering-philosophy.md
@.claude/singlefs-ai-sop/rules/sop-first.md
@.claude/singlefs-ai-sop/rules/show-me-test.md
@.claude/singlefs-ai-sop/rules/machine-first.md
@.claude/singlefs-ai-sop/rules/code-discipline.md
@.claude/singlefs-ai-sop/rules/writing-discipline.md
@.claude/singlefs-ai-sop/rules/design-doc-discipline.md
@.claude/singlefs-ai-sop/rules/kb-discipline.md
@.claude/singlefs-ai-sop/rules/test-discipline.md
@.claude/singlefs-ai-sop/rules/evidence-discipline.md
@.claude/singlefs-ai-sop/rules/verify-before-claiming.md
@.claude/singlefs-ai-sop/rules/pushback-discipline.md
@.claude/singlefs-ai-sop/rules/command-safety.md
@.claude/singlefs-ai-sop/rules/session-wrapup.md

**文件系统设计特有的规则**（事务、崩溃一致性、盘上格式那一类）放 `.claude/rules/`，
在这里一起 `@` 引用。别往共享 SOP 上放，那边只放协作规范。

（上面那些 `@.claude/singlefs-ai-sop/...` 是 [singlefs-ai-sop](.claude/singlefs-ai-sop/README.md) 发下来的共享规则。
**改它们等于同时改掉每个参与者的下限**，要改就去改上游并抬 `VERSION`，不许在项目里就地改。）

## 项目本地事实

| 文件 | 内容 |
|---|---|
| `.claude/kb/decisions.md` | 设计决策：定了什么、为什么、还没定什么 |
| `.claude/kb/experiments.md` | 实验记录：问题、先写死的判据、对照与变异、复跑命令 |
| `.claude/kb/invariants.md` | 不变量清单，checker 是它的可执行形式 |
| `.claude/kb/prior-art.md` | 他家方案调研，含来源与口径 |
| `.claude/kb/pitfalls.md` | 避坑清单，每做设计决定回来对一遍 |
| `.claude/kb/checks-owed.md` | 欠的检查：知道要拦什么但还拦不了的，含前置 |
| `records/` | 建设过程 |

## 门禁

门禁是为了**把每一份提交抬到值得花人时间去看那条线上**，不是为了把谁挡在外面。
它不按来源区分提交的人，只区分带证据的和不带的。

```bash
bash .claude/scripts/gate.sh          # 准入门禁，提交前必跑
GATE_QEMU=1 bash .claude/scripts/gate.sh   # 再加 QEMU harness 自检

bash .claude/scripts/check.sh         # 快速反馈（格式/lint/构建/单测）
bash .claude/scripts/lkmm.sh          # 内存序（herd7 + litmus/）
bash .claude/scripts/qemu.sh --selftest    # QEMU harness 自检
bash .claude/scripts/gate-lint.sh     # 门禁自身：每条拒绝是否都给了下一步
bash .claude/scripts/shell-lint.sh    # shell 纪律：按模式杀进程、子 shell 赋值往外带值
bash .claude/scripts/naming-lint.sh   # 命名纪律：.rs 里的单字母名与常见缩写
bash .claude/scripts/env.sh           # 环境自检
```

**Gate proves evidence requirements, not semantic correctness.**
绿了只说明证据要求满足了，不代表语义是对的——`gate.sh` 每次都会列出还没实现的阶段。

## 本项目的特殊性

<一到三条，只写会改变做法的。展开的判据放 kb，这里只留个指路。>

## 一句话版本

<三到四句，每句写一条这个项目最容易翻车的判据。通用纪律别抄进来，它们在 rules 里。>
