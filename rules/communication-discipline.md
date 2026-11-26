<!-- doc-lint:rule-definition -->
# 沟通纪律

**管的是**：agent 对用户、agent 与 agent 之间的对话。
写给第三方读的产出（邮件、公告、对外文档）按它的读者写，不在射程里。

各节点名的钩子在 `.claude/settings.json` 上注册，写法在各钩子的文件头；各自认哪些说法，以钩子为准。

## 不写客套

回复与消息里不写：寒暄、道谢、道歉、夸提问、「好的」「当然」「很高兴」、结尾问「还需要别的吗」。

收工钩子 `scripts/claude-hooks/courtesy-phrase-check.sh` 判：这一轮最后一条回复里有词表（`COURTESY_PHRASES`）里的说法就拦下，要它删掉重写。反引号、「」、引号与代码块里的不判。词表只有中文。

## 推测先去核实，再回答

回复里有推测的说法（「可能是」「应该是」「大概」「估计是」「似乎」「我记得」这类），或者自己标明是推测、没核实的说法（「推测」「推论」「这是推的」「没核实」「没量过」这类），先去核实，再回答：

1. 读文件、跑命令、查记录，拿到结果。
2. 把那一句改写成核实过的结论，带上依据（路径、命令与它的输出）。
3. 验不了的（要等用户给信息、说的是还没发生的事），在那一行写「未验证：<为什么验不了>」，理由至少 4 个字。

收工钩子 `scripts/claude-hooks/courtesy-phrase-check.sh` 判：这一轮最后一条回复里有词表（`SPECULATION_PHRASES`）里的说法、同一行又没写「未验证：」的就拦下，要它核实后重写。反引号、「」、引号与代码块里的不判。词表只有中文。
核实做没做、「未验证：」的理由成不成立，靠 review。

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
- 编号已被别的正在跑的会话占着时，起得晚的一方换号，起得早的一方不动。
- 标题有 Claude Code 自动起的就用它；还没有时取用户提示的开头起一段（按显示宽度截到 40，汉字算 2）。不留只有 `(编号)` 的标题。
- 编号后面的正文一旦写下就不换；编号被去掉了就补回去。
- 子 agent 与不是交互式的会话不写。

钩子 `scripts/claude-hooks/session-number-title.sh`（写法在 `scripts/session-number-title.py`）在 SessionStart 与 UserPromptSubmit 上做这一条；取不到新编号时怎么办以它为准。

## 会话启动与压缩之后的检测

会话启动、恢复、清空与压缩之后的检测只报不改，由钩子 `scripts/claude-hooks/session-checks.sh`（判定在 `scripts/session-checks.py`）在 PreCompact 与 SessionStart 上做：

- 压缩之前往写摘要的附加说明里写一句：摘要整份用本包的语言写，用户说的话、命令、路径与代码照原样引。
- 压缩之后先补一段对齐提示，用本包的语言写，经 `additionalContext` 注入。开头单独一段要求从这一条回复起，回复、工具调用之间的插话、发给别的会话与子 agent 的消息、写进文件的文字一律用本包的语言，不跟着摘要、系统提示与工具输出换语言；后面是分支与未提交的路径数、派出过的子 agent 先看还在不在跑、接续的状态以记录为准。
- 项目要检的项登记在 `.claude/session-checks/`：一项一个可执行文件，文件头写 `# session-check-sources: <startup resume clear compact 里的几个>` 与 `# session-check-timeout: <秒>`，带 `--selftest` 的自证要过。项目的检查项不另写钩子。
- 检查项退 0 的输出拼进上下文；退非 0、超时、起不来、文件头写错，照常放行，写一行「没查成」，检出记录追加一行。

检查项的文件头、执行位与 `--selftest` 由门禁阶段「工具层的闸」（`scripts/hooks-registered.sh`）判。检查项的输出说得对不对，靠写检查项的人。
