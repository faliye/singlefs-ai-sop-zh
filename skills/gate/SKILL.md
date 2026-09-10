---
name: gate
description: 跑 singlefs 的准入门禁。提交代码前、判断一个改动能不能收时用它——包含门禁各阶段的含义、怎么判读结果、哪些"失败"是环境问题而不是代码问题。
---

# 准入门禁

规则在 `rules/show-me-test.md`。**这里只写怎么跑、怎么看结果、哪些失败是假的。**

## 跑

```bash
bash .claude/scripts/gate.sh          # 全套，提交前必跑
bash .claude/scripts/check.sh         # 只跑格式/lint/构建/单测，快速反馈
bash .claude/scripts/env.sh           # 只做环境自检
GATE_BASE=<commit> bash .claude/scripts/gate.sh   # 指定 diff 基准
```

## 阶段与判读

| 阶段 | 失败意味着 |
|---|---|
| 规范版本 | 项目的 `.singlefs-ai-sop-version` 跟 singlefs-ai-sop 的 `VERSION` 对不上。**先读一遍规则改了什么**，再跑 `install.sh` 更新戳 |
| 门禁自检 | 有条拒绝没给出路（`bad` 后面缺 `howto`，或者 `die` 只带了一句话） |
| 门禁判别力 | 样本判出来跟预期不一样——**门禁自己坏了**，先修它，别的先放着 |
| shell 纪律 | 脚本里有按模式匹配杀进程，或者靠子 shell 的赋值往外带值 |
| 文档铁律 | 正文里混了历史陈述，或者 kb 里引用编号没带简称。见 `rules/doc-discipline.md` |
| Show me test | 改了 `crates/*/src` 却没带测试。**这条不许绕**，见 `rules/show-me-test.md` |
| 构建与单测 | 真的坏了，或者 cargo 没装 |
| 项目本地阶段 | `.claude/gate.d/` 里某个本地检查红了，或者读不了 |
| LKMM | litmus 的判定跟声明对不上，或者某条 Never 没有配对的对照组 |

**只在 SOP 仓自己跑的三个阶段**（消费项目看不到）：各语言同步、版本纪律、CHANGELOG 连续。

「规则清单」两边都跑，但问的不是一件事：在 SOP 仓里它问「清单跟规则同不同步」，
在项目里它比对的是**你装的那份副本**——副本被改过或者没拷全，这一项就红。

## 未实现的阶段

`gate.sh` 每次都会列出**尚未实现**的门禁阶段（模型对拍 / 崩溃点重放 / QEMU 压测）。

**这不是提示噪音，是判读结果的必要前提**：门禁全绿只说明「文档合规 + 有测试 + 单测过」，
**不构成任何崩溃一致性证据**。在崩溃点重放接进来之前，
任何「写路径验证过了」的说法都是假的。

## 常见假失败

| 现象 | 真因 |
|---|---|
| Show me test 说「无对象可判」 | 工作区跟基准没差别。**这既不是通过也不是失败**，改点东西再跑，或者用 `GATE_BASE=<ref>` 指定基准 |
| 「未检查副本是否落后上游」 | 上游仓不在兄弟目录里，这一项**查不了**。汇总里会单独列出来，别把它当成通过 |
| 构建阶段说 cargo 没装 | 环境问题。跑 `env.sh` 看看全貌，装好工具链再来 |
| doc-lint 把规则文档自己也报了 | 那个文件缺 `<!-- doc-lint:rule-definition -->` 标记 |
| Show me test 说没测试，可我明明写了 | 测试写在 `crates/*/src/` 里，又没加 `#[cfg(test)]`/`#[test]` 这类标注，脚本认不出来 |

## 门禁自己也要能失败

改了 `gate.sh` 或 `doc-lint.sh` 之后，**必须造一个应该被拦的输入验证它真的会红**：

```bash
# 造一个该被拦的样本，喂给 doc-lint，确认它真的红
d=$(mktemp -d); mkdir -p "$d/kb"
printf '# 决策\n\n节点大小 16K（原为 4K）。\n\n## 历史版本\n\n### 2026-01-01\n- 建档。\n' \
  > "$d/kb/decisions.md"
bash .claude/singlefs-ai-sop/scripts/doc-lint.sh "$d"; echo "退出码 $? —— 应为 1"
rm -rf "$d"
```

⚠️ **样本要另建一个目录，别往真的 kb 文件尾巴上 `>>`。**
`>>` 追加的内容落在「## 历史版本」后面，而正文扫描在历史节那一行就停了。
退出码是 0，看着像「检查没做事」，其实是样本造错了地方——
这是在这份 skill 自己的例子上实测到的。

改完检查还要跑一遍 `bash .claude/singlefs-ai-sop/scripts/selftest.sh`。
它拿 `scripts/fixtures/` 下的样本证明每条检查现在还红得起来。
**加一条检查就配一个样本**，`want=` 要写这条检查自己的消息。
写成几条检查共用的片段，等于没盯住（见 `rules/show-me-test.md`）。

按 `rules/show-me-test.md`：证明不了会红的检查，等于没写。
