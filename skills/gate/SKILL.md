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
| 门禁自检 | 有条拒绝没给出路（`bad` 后面缺 `howto`、`die` 只带一句话、直接打印的 `✗` 后面没有 `→`），或者扫一批对象的检查成功时没报数。形态见 `rules/sop-first.md` |
| 门禁判别力 | 样本判出来跟预期不一样——**门禁自己坏了**，先修它，别的先放着 |
| shell 纪律 | 脚本里有 `pkill -f` / `killall` / `pgrep -f`、靠子 shell 的赋值往外带值、git 的撤销命令，或者 `rm -rf` 作用在没守卫的变量路径上。见 `rules/command-safety.md` |
| 文档铁律 | 正文里混了历史陈述，kb 里引用编号没带简称，或者 CLAUDE.md 没把规则一条条 @ 进来。见 `rules/writing-discipline.md` |
| 命名纪律 | `.rs` 里我们声明的名字用了单字母或常见缩写，或者 `.claude/abbreviations`、`.claude/naming-lint-exclude` 写得不合规。见 `rules/code-discipline.md` |
| Show me test | 改了 `crates/*/src` 却没带测试。**这条不许绕**，见 `rules/show-me-test.md` |
| 构建与单测 | 真的坏了，或者 cargo 没装。clippy 按 `-D warnings` 判，另外封闭集合的枚举上不许写 `_ =>` |
| 项目本地阶段 | `.claude/gate.d/` 里某个本地检查红了，或者读不了；「覆盖声明（…）」红，是 `# gate-covers:` 写了清单里没有的项 |
| 工作区跑的过程中没变 | 门禁跑的这段时间里工作区的文件变了（自己还在改，或者别的会话在改），各阶段读到的不是同一版。等改动停下再跑，或者用 `--staged` |

**只在 SOP 仓自己跑的三个阶段**（消费项目看不到）：各语言同步、版本纪律、CHANGELOG 连续。

「规则清单」两边都跑，但问的不是一件事：在 SOP 仓里它问「清单跟规则同不同步」，
在项目里它比对的是**你装的那份副本**——副本被改过或者没拷全，这一项就红。
装的是 en / ja 副本时这一项报「不适用」：清单只在参照仓（zh）里维护，译本仓跟没跟上由 zh 仓的「各语言同步」判。

## 未实现的阶段

`gate.sh` 每次都会列出共享门禁**没实现**的验证手段：模型对拍、崩溃点重放、最终判据，
以及 shell 脚本的命名纪律。前三样只能由项目在 `.claude/gate.d/` 里接：模型对拍要被测对象的理想模型，崩溃点重放要它自己的录制流与 checker，最终判据由项目定；
接上的阶段在头部写 `# gate-covers: <那一项>`，这一轮跑了且通过，那一项才换到「由项目本地阶段覆盖」下面。

**这不是提示噪音，是判读结果的必要前提**：门禁全绿只说明「文档合规 + 有测试 + 单测过」，
外加「由项目本地阶段覆盖」那一栏里各阶段各自验到的范围。
崩溃点重放没有阶段覆盖时，任何「写路径验证过了」的说法都是假的；
有阶段覆盖，也只说到那个阶段枚举过的写路径为止。

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
# 造一个该被拦的样本，喂给 doc-lint，确认它真的红
d=$(mktemp -d); mkdir -p "$d/kb"
printf '# 决策\n\n节点大小 16K（原为 4K）。\n\n## 历史版本\n\n### %s\n- 建档。\n' "$(date +%F)" \
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
