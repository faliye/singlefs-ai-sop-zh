<!-- doc-lint:rule-definition -->
# 沟通纪律

**管的是**：agent 对用户、agent 与 agent 之间的对话。

## 不写客套

回复与消息里不写：寒暄、道谢、道歉、夸提问、「好的」「当然」「很高兴」、结尾问「还需要别的吗」。

收工钩子 `scripts/claude-hooks/courtesy-phrase-check.sh` 判这一条：这一轮最后一条回复里有词表里的说法，就拦下收工，要它删掉重写；同一条回复只拦一次。
它认的说法以那个钩子的 `COURTESY_PHRASES` 为准；反引号、「」、引号与代码块里的不判。词表只有中文，英文、日文的回复不判。
项目在 `.claude/settings.json` 的 `Stop` 与 `SubagentStop` 上各注册一次，写法在那个钩子的文件头。

## 转述别处的做法，带出处或原文

派给子 agent 的提示、发给别的会话的消息里，说「与 X 同口径」「照 X 那一份」「同 `X`」的那一句，同一句里要带下面三样之一：

- `路径:行号`（或路径、「同文件」加「第 N 行」）；
- 原文引用：「」里至少 6 个字，或者以冒号收尾、下一行是 `>` 起头的引用行；
- 路径加反引号里的函数名，或「」里的标题。

拿不准原文是什么，先读一遍再派。只写出你理解的内容（「同一口径：取限定名」）不算出处。

钩子 `scripts/claude-hooks/borrowed-convention-guard.sh`（判定在 `scripts/borrowed-convention.py`）判这一条：派子 agent（Agent、Task）与 SendMessage 之前判，借用句同一句里没有出处或原文就拒绝。
它认的借用说法以 `scripts/borrowed-convention.py` 的 `BORROW_PHRASES` 为准，不在里面的说法不判；出处指得对不对、原文抄得对不对，它不判。
项目在 `.claude/settings.json` 上注册它，写法在那个钩子的文件头。

## 射程与例外

写给第三方读的产出（邮件、公告、对外文档）按它的读者写，不在射程里。
