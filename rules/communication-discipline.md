<!-- doc-lint:rule-definition -->
# 沟通纪律

**管的是**：agent 对用户、agent 与 agent 之间的对话。
写给第三方读的产出（邮件、公告、对外文档）按它的读者写，不在射程里。

各节点名的钩子在 `.claude/settings.json` 上注册，写法在各钩子的文件头；各自认哪些说法，以钩子为准。

## 不写客套

回复与消息里不写：寒暄、道谢、道歉、夸提问、「好的」「当然」「很高兴」、结尾问「还需要别的吗」。

收工钩子 `scripts/claude-hooks/courtesy-phrase-check.sh` 判：这一轮最后一条回复里有词表（`COURTESY_PHRASES`）里的说法就拦下，要它删掉重写。反引号、「」、引号与代码块里的不判。词表只有中文。

## 转述别处的做法，带出处或原文

派给子 agent 的提示、发给别的会话的消息里，说「与 X 同口径」「照 X 那一份」「同 `X`」的那一句，同一句里要带三样之一：

- `路径:行号`（或路径、「同文件」加「第 N 行」）；
- 原文引用：「」里至少 6 个字，或者以冒号收尾、下一行是 `>` 起头的引用行；
- 路径加反引号里的函数名，或「」里的标题。

拿不准原文是什么，先读一遍再派。只写出你理解的内容（「同一口径：取限定名」）不算出处。

钩子 `scripts/claude-hooks/borrowed-convention-guard.sh`（判定在 `scripts/borrowed-convention.py`，认的借用说法以它的 `BORROW_PHRASES` 为准）在派子 agent 与 SendMessage 之前判，没带的拒绝。出处指得对不对，它不判。

## 收工前核一遍别的会话发来的消息

收工之前核一次：这个会话收到的别的会话的消息，每一条要么已经回给它，要么在回复里写一行「不回 <会话名>：<理由>」，理由至少 4 个字。
子 agent 交回的报告、没带会话名而来源是 unknown 的通知（任务服务的结果通知这类）不算。

收工钩子 `scripts/claude-hooks/unanswered-message-check.sh`（判定在 `scripts/unanswered-message.py`）判，没回也没写「不回」的逐条列出、拦下收工。

## 找别的会话，只找正在跑的

要找别的会话（问谁在管、发消息、转交问题），只看 `ListAgents` 列出来的正在跑的会话，名字照它那一行抄。
不按会话记录的日期去捞会话，不给已经停了的会话发消息；要找的会话不在列表里，要说的事报给用户。

钩子 `scripts/claude-hooks/message-target-guard.sh`（判定在 `scripts/message-target.py`）在 SendMessage 之前判：对象长得像会话名而本机没有正在跑的会话对得上，就拒绝。子 agent 名、队友名不判。
别的机器上、云端的会话，照 `ListAgents` 那一行的名字与 `[ref]` 发。

## 会话标题开头写编号

每个会话启动、恢复时，会话标题开头写会话编号，格式 `(编号) 标题`。

- 编号取 Claude Code 给会话起的默认名 `<目录名>-<编号>` 里的那一段。
- 标题有 Claude Code 自动起的就用它；还没有时取用户提示的开头起一段（按显示宽度截到 40，汉字算 2）。不留只有 `(编号)` 的标题。
- 编号后面的正文一旦写下就不换；编号被去掉了就补回去。
- 子 agent 与不是交互式的会话不写。

钩子 `scripts/claude-hooks/session-number-title.sh`（写法在 `scripts/session-number-title.py`）在 SessionStart 与 UserPromptSubmit 上做这一条；取不到新编号时怎么办以它为准。
