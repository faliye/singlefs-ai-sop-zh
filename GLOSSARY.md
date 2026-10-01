# 术语表 / Glossary / 用語集

**这一份各语言仓共用，原样复制，不翻译。** 它本身就是那张对照表——
把它翻译成 N 份，等于把同一张表抄了 N 份，而那正是它要防的事。

**所以说明这一列写成三语并排**（`中文<br>English<br>日本語`）。
判据跟别处一样：**给人读的散文，得让读它的人读得懂**；
而对照关系是跟语言无关的数据，只能有一处。两件事在同一张表里，各按各的规矩办。

译文必须照这里的对应关系翻，不许各篇自己造词。新术语先加到这里，再去译文里用。
**三语少一段，`scripts/doc-lint.sh` 判红**——「先加中文，别的下次补」会分叉，
而用另一种语言的人根本不知道自己看的是残缺的。

> **Shared verbatim across every language repository; never translated.** It *is* the
> mapping. Each note carries all three languages, separated by `<br>`, because prose
> written for people has to be readable by the person reading it — while the
> correspondence itself is language-neutral data and may exist in only one place.
> Add a term here first, then use it in the translated rules. A note missing one of the
> three languages is failed by `scripts/doc-lint.sh`.

> **全言語リポジトリで共有し、原様のまま複製する。翻訳しない。** これ自体が対訳表である。
> 注は三言語を `<br>` で並べる——人が読む散文は、読む人に読めなければ意味がないからだ。
> 一方、対応関係そのものは言語に依らないデータであり、一箇所にしか存在してはならない。
> 新しい用語はまずここに追加し、それから訳文で使う。
> 三言語のいずれかが欠けた注は `scripts/doc-lint.sh` が赤にする。

| 中文 | English | 日本語 | 说明 / Note / 注 |
|---|---|---|---|
| 门禁 | gate | ゲート | 自动化准入检查的总称<br>umbrella term for the automated acceptance checks<br>自動受入検査の総称 |
| 准入标准 | acceptance criterion | 受入基準 | 决定 patch 收不收的依据，由项目定<br>what decides whether a patch is taken; set by the project<br>パッチを受け取るか否かの根拠。プロジェクトが決める |
| 参照仓 | reference repository | 参照リポジトリ | 清单与门禁脚本维护在哪个仓；不等于权威<br>where the manifest and gate scripts are maintained; not the authority<br>マニフェストとゲートスクリプトの維持先。権威とは別 |
| 会失败的检查 | failing check | 失敗しうる検査 | 与「提醒句」相对<br>as opposed to a reminder sentence<br>「注意書き」の対語 |
| 出路 | remedy | 対処 | 每条拒绝必须带的下一步<br>the next step every rejection must carry<br>拒否のたびに必ず添える次の一手 |
| 准入条件 | admission condition | 受付条件 | 什么时候该调一个脚本：这一次调有没有意义，写在文件头的 `admission:`<br>when a script should be called — whether this call can tell anything new; the `admission:` lines at its head<br>いつスクリプトを呼ぶべきか——今回呼ぶ意味があるか。冒頭の `admission:` 行 |
| 运行条件 | run condition | 実行条件 | 什么时候不能调一个脚本：环境撑不撑得住，写在文件头的 `run-condition:`<br>when a script must not be called — whether the environment can carry it; the `run-condition:` lines at its head<br>いつスクリプトを呼んではならないか——環境が持ちこたえるか。冒頭の `run-condition:` 行 |
| 强制跑 | forced run | 強制実行 | 条件没满足、带 `--force` 照跑的那一次；结果不记通过<br>a run made with `--force` although a condition was not met; its result is not recorded as a pass<br>条件を満たさないまま `--force` で走らせた回。結果は合格と記録しない |
| 证据 | evidence | 根拠 | acceptance is evidence-bound 里的那个<br>the one in "acceptance is evidence-bound"<br>"acceptance is evidence-bound" のそれ |
| 口径 | measurement basis | 計測条件 | 一个数字是怎么测出来的<br>how a number was measured<br>その数値がどう測られたか |
| 实测 / 推理 | measured / inferred | 実測 / 推論 | kb 里每条结论二选一标注<br>every kb conclusion is marked one or the other<br>kb の結論はどちらかを明記する |
| 判别力 | discriminating power | 判別力 | 被测对象坏掉时这条检查真的会红<br>the check really goes red when the thing under test breaks<br>被検査対象が壊れたとき実際に赤くなること |
| 盲区 | blind spot | 盲点 | 断言或变异没盯住的代码<br>code that no assertion or mutation watches<br>言明やミューテーションが見張っていないコード |
| 变异测试 | mutation testing | ミューテーションテスト | 把被测代码改坏，验证断言真的会红<br>break the code under test to prove the assertions go red<br>被検査コードを壊し、言明が赤くなることを確かめる |
| 变异清单 | mutation list | ミューテーションリスト | 入库的「改了哪里 → 哪条断言红」<br>a checked-in list of "what was changed → which assertion went red"<br>「どこを変えた → どの言明が赤くなった」の記録 |
| 等价变异 | equivalent mutant | 等価ミュータント | 与原式同值，永远抓不到；不算盲区<br>same value on all inputs, never catchable; not a blind spot<br>全入力で同値。捕まらないが盲点ではない |
| 对照组 | control case | 対照群 | 与被测的臂并排跑、用来判读结果的那一组：阳性对照（结果已知，证明这次测量分得出差别）或真实基线<br>the group run alongside the arm under test to read its result: a positive control (outcome known, showing the measurement can tell a difference) or a real baseline<br>被検のアームと並べて走らせ、結果を読むための組：陽性対照（結果が分かっており、今回の測定が差を見分けられることを示す）か実ベースライン |
| 快档 | quick tier | 高速段 | 每次改完就跑的那一档：按项目定的快慢判据归为快的用例，加上对拍、剪枝自证、钉回来的红例这几类<br>the tier run after every change: cases the project's quick/slow criterion classes as quick, plus differentials, pruning self-checks and pinned-back reds<br>変更のたびに走らせる段：プロジェクトの速い・遅いの判定基準で速いとされたケースと、突き合わせ・枝刈りの自己検査・固定し戻した赤の例 |
| 慢档 | slow tier | 低速段 | 按快慢判据归为慢的用例：穷举、长时间随机、真设备、外部工具这类；跟着全量跑<br>cases the quick/slow criterion classes as slow — exhaustive, long random, real device, external tools; run with the full run<br>速い・遅いの判定基準で遅いとされたケース：網羅、長時間ランダム、実デバイス、外部ツールの類。全量と一緒に走る |
| 全量 | full run | 全量 | 测试入口脚本不带参数、规模变量没设过时跑的范围：快档加慢档<br>what a test entry script runs with no arguments and no scale variable set: the quick tier plus the slow tier<br>テストの入口スクリプトを引数なし・規模変数未設定で走らせたときの範囲：高速段と低速段 |
| 钉回快档 | pin back into the quick tier | 高速段に固定し戻す | 全量出的红，按原输入缩到最小做成快档用例，修好之后留作回归<br>turn a red from the full run into a quick-tier case on its minimised original input, kept as a regression after the fix<br>全量で出た赤を、元の入力を最小化して高速段のケースにし、修正後も回帰として残す |
| 自证 | self-test | 自己検査 | 脚本证明自己有效的那份测试（`--selftest`、同包测试或红绿样本）：每种判定喂已知答案，每个弄坏开关打开都要红<br>the test by which a script proves itself valid (`--selftest`, in-package tests or red/green fixtures): known answers for every verdict, red for every break switch<br>スクリプトが自らの有効性を示すテスト（`--selftest`、同じパッケージのテスト、赤緑の標本）：判定ごとに既知の答え、壊しスイッチごとに赤 |
| 弄坏开关 | break switch | 壊しスイッチ | 只给自证用的开关，打开就把脚本的某一处判法改坏，证明自证会红<br>a switch used only by the self-test that breaks one part of the script's judging, proving the self-test goes red<br>自己検査専用のスイッチ。スクリプトの判定の一箇所を壊し、自己検査が赤くなることを示す |
| 不变量 | invariant | 不変条件 | 项目的检查是它的可执行形式<br>the project's checks are its executable form<br>プロジェクトの検査がその実行可能な形 |
| 欠账表 | debt table | 負債表 | 项目 kb 里的 `checks-owed.md`：已经知道要拦什么、还没立的检查，一周合一批评估<br>`checks-owed.md` in the project kb: checks we know we want but have not built yet, assessed in a weekly batch<br>プロジェクト kb の `checks-owed.md`：止めたいと分かっているがまだ立てていない検査。週に一度まとめて評価する |
| 确定性模型 | deterministic model | 決定的モデル | 无随机源、真实 I/O、并发、时钟；跑 N 遍必然一致<br>no randomness, real I/O, concurrency or clock; N runs are identical<br>乱数・実 I/O・並行・時計を持たない。N 回走らせても同一 |
| 规范本体 | governed paths | 規範本体 | 改了必须抬 `VERSION` 的那些路径<br>the paths whose change requires a `VERSION` bump<br>変更したら `VERSION` を上げねばならないパス群 |
| 译本 | translation | 訳本 | 生成物，不是平行版本<br>a product, not a parallel edition<br>生成物であって並行版ではない |
| 编号 | number | 番号 | 指代某条决策/不变量/欠检查的符号，如 D1、I-3.1<br>the symbol standing for a decision, invariant or owed check, e.g. D1, I-3.1<br>判断・不変条件・借り検査を指す記号（D1、I-3.1 など） |
| 简称 | short name | 簡称 | 编号的短名，引用处每次都要带着它<br>a number's short name, carried at every citation<br>番号の短い名。引用のたびに添える |
| 登记位 | registration site | 登録箇所 | 编号唯一的说明处：登记表的一行，或带破折号的标题<br>a number's single site of definition: a registry row, or a heading with a dash<br>番号を説明する唯一の箇所：登録表の一行、または破折号つき見出し |
| 登记表 | registry table | 登録表 | 上方带 `doc-lint:registry` 标记的那张表<br>the table preceded by a `doc-lint:registry` marker<br>`doc-lint:registry` 標記が直前に付く表 |
| 登记标题 | registry heading | 登録見出し | `## D1 数据可移动性 —— 已定` 这种形态<br>the `## D1 <short name> —— <state>` shape<br>`## D1 <簡称> —— <状態>` の形 |
| 裸引用 | bare citation | 裸の引用 | 只写编号、不带简称的引用<br>a citation with the number but no short name<br>番号だけで簡称を伴わない引用 |
| 位置指代 | positional reference | 位置の指代 | 「如上所述」「见下节」这类指文档里位置的说法；kb、规则、`CLAUDE.md`、agent 定义与 skill 正文里禁止<br>"as stated above", "see the section below" and the like — pointing at a position in the document; forbidden in kb, rules, `CLAUDE.md`, agent definitions and skill bodies<br>「前述のとおり」「次節参照」の類。文書内の位置を指す書き方。kb・規則・`CLAUDE.md`・agent 定義・skill 本文では禁止 |
| 自称 | self-reference | 自己参照 | 「本节」「本条」这类指着「此处」的写法；kb、规则、`CLAUDE.md`、agent 定义与 skill 正文里禁止，kb 里另禁「本决策」「该实验」这类<br>"this section", "this clause" — pointing at "here"; forbidden in kb, rules, `CLAUDE.md`, agent definitions and skill bodies, and in kb also "this decision", "that experiment" and the like<br>「本節」「本条」のように「ここ」を指す書き方。kb・規則・`CLAUDE.md`・agent 定義・skill 本文では禁止。kb ではさらに「本決定」「当該実験」の類も禁止 |
| 缩写 | abbreviation | 略語 | 我们声明的名字里不许用；登记过的领域缩写与 Rust 的关键字、基本类型名除外<br>not allowed in any name we declare; registered domain abbreviations and Rust keywords and primitive type names excepted<br>自前で宣言する名前には使わない。登録済みの領域略語と Rust のキーワード・基本型の名前は除く |
| 缩写登记表 | abbreviation registry | 略語登録表 | 项目根的 `.claude/abbreviations`，每个领域缩写唯一的权威定义<br>`.claude/abbreviations` at the project root: the single authoritative definition of each domain abbreviation<br>プロジェクト直下の `.claude/abbreviations`。領域略語ごとの唯一の権威ある定義 |
| 路径数 | path count | 経路数 | 穷尽覆盖控制流需要多少用例；不含循环状态与数据<br>how many cases exhaustive control-flow coverage needs; loop state and data not included<br>制御フローの網羅に必要なケース数。ループの状態とデータは含まない |
| 通配臂 | wildcard arm | ワイルドカードアーム | `match` 里的 `_ =>`；封闭集合的枚举上不许写<br>the `_ =>` arm of a `match`; not allowed on enums that are closed sets<br>`match` の `_ =>`。閉じた集合の列挙型には書かない |
| 分支 | branch（实现分支） | 分岐 | **不是 git branch**，是代码路径<br>**not a git branch** — a code path<br>**git branch ではなく**、コード経路 |

## 三句核心表述 / The three core statements / 三つの中核文

英文是原文，中日文是译文，**不要反过来改英文**。
The English is the original; the Chinese and Japanese are translations — **do not edit
the English to match them.**
英語が原文であり、中国語と日本語は訳である。**英語のほうを直してはならない。**

> **Make every submitted patch review-worthy.**
> 让每一份提交都值得被 review。
> 提出されたすべてのパッチを、レビューに値するものにする。

> **Contribution throughput may be unbounded; acceptance throughput is evidence-bound.**
> 投稿吞吐可以无限，接收吞吐受证据约束。
> 投稿のスループットは無限でありうるが、受入のスループットは根拠に縛られる。

> **Gate proves evidence requirements, not semantic correctness.**
> 门禁证明的是证据要求被满足，不是代码语义正确。
> ゲートが証明するのは根拠要件の充足であって、意味的な正しさではない。

以及工程理念那一句 / and the one from the engineering philosophy / そして工学理念の一句：

> **实现上 AI 友好，审核上人类友好。**
> AI-friendly to implement, human-friendly to review.
> 実装は AI に優しく、レビューは人間に優しく。
