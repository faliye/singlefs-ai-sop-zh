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
| 准入判据 | acceptance criterion | 受入判定基準 | 决定 patch 收不收的依据<br>what decides whether a patch is taken<br>パッチを受け取るか否かの根拠 |
| 参照仓 | reference repository | 参照リポジトリ | 清单与门禁脚本维护在哪个仓；不等于权威<br>where the manifest and gate scripts are maintained; not the authority<br>マニフェストとゲートスクリプトの維持先。権威とは別 |
| 会失败的检查 | failing check | 失敗しうる検査 | 与「提醒句」相对<br>as opposed to a reminder sentence<br>「注意書き」の対語 |
| 出路 | remedy | 対処 | 每条拒绝必须带的下一步<br>the next step every rejection must carry<br>拒否のたびに必ず添える次の一手 |
| 证据 | evidence | 根拠 | acceptance is evidence-bound 里的那个<br>the one in "acceptance is evidence-bound"<br>"acceptance is evidence-bound" のそれ |
| 口径 | measurement basis | 計測条件 | 一个数字是怎么测出来的<br>how a number was measured<br>その数値がどう測られたか |
| 实测 / 推理 | measured / inferred | 実測 / 推論 | kb 里每条结论二选一标注<br>every kb conclusion is marked one or the other<br>kb の結論はどちらかを明記する |
| 判别力 | discriminating power | 判別力 | 被测对象坏掉时这条检查真的会红<br>the check really goes red when the thing under test breaks<br>被検査対象が壊れたとき実際に赤くなること |
| 盲区 | blind spot | 盲点 | 有检查但没有样本盯着<br>a check with no fixture watching it<br>検査はあるが見張る標本が無い箇所 |
| 变异测试 | mutation testing | ミューテーションテスト | 把被测代码改坏，验证断言真的会红<br>break the code under test to prove the assertions go red<br>被検査コードを壊し、言明が赤くなることを確かめる |
| 变异清单 | mutation list | ミューテーションリスト | 入库的「改了哪里 → 哪条断言红」<br>a checked-in list of "what was changed → which assertion went red"<br>「どこを変えた → どの言明が赤くなった」の記録 |
| 等价变异 | equivalent mutant | 等価ミュータント | 与原式同值，永远抓不到；不算盲区<br>same value on all inputs, never catchable; not a blind spot<br>全入力で同値。捕まらないが盲点ではない |
| 对照组 | control case | 対照ケース | litmus 里去掉屏障的那一份<br>the litmus with the barrier removed<br>バリアを外したほうの litmus |
| 不变量 | invariant | 不変条件 | checker 是它的可执行形式<br>the checker is its executable form<br>checker がその実行可能な形 |
| 崩溃点重放 | crash-point replay | クラッシュ点リプレイ | 在每个可能的断电点截断重放<br>truncate and replay at every possible power-cut point<br>あり得る断電点ごとに切り詰めて再生する |
| 模型对拍 | model-based differential testing | モデル対照テスト | 与内存里的理想实现比对<br>compare against an ideal in-memory implementation<br>メモリ上の理想実装と突き合わせる |
| 确定性模型 | deterministic model | 決定的モデル | 无随机源、真实 I/O、并发、时钟；跑 N 遍必然一致<br>no randomness, real I/O, concurrency or clock; N runs are identical<br>乱数・実 I/O・並行・時計を持たない。N 回走らせても同一 |
| 规范本体 | governed paths | 規範本体 | 改了必须抬 `VERSION` 的那些路径<br>the paths whose change requires a `VERSION` bump<br>変更したら `VERSION` を上げねばならないパス群 |
| 译本 | translation | 訳本 | 生成物，不是平行版本<br>a product, not a parallel edition<br>生成物であって並行版ではない |
| 编号 | number | 番号 | 指代某条决策/不变量/欠检查的符号，如 D1、I-3.1<br>the symbol standing for a decision, invariant or owed check, e.g. D1, I-3.1<br>判断・不変条件・借り検査を指す記号（D1、I-3.1 など） |
| 简称 | short name | 簡称 | 编号的短名，引用处每次都要带着它<br>a number's short name, carried at every citation<br>番号の短い名。引用のたびに添える |
| 登记位 | registration site | 登録箇所 | 编号唯一的说明处：登记表的一行，或带破折号的标题<br>a number's single site of definition: a registry row, or a heading with a dash<br>番号を説明する唯一の箇所：登録表の一行、または破折号つき見出し |
| 登记表 | registry table | 登録表 | 上方带 `doc-lint:registry` 标记的那张表<br>the table preceded by a `doc-lint:registry` marker<br>`doc-lint:registry` 標記が直前に付く表 |
| 登记标题 | registry heading | 登録見出し | `## D1 数据可移动性 —— 已定` 这种形态<br>the `## D1 <short name> —— <state>` shape<br>`## D1 <簡称> —— <状態>` の形 |
| 裸引用 | bare citation | 裸の引用 | 只写编号、不带简称的引用<br>a citation with the number but no short name<br>番号だけで簡称を伴わない引用 |
| 上下文指代 | dangling reference | 文脈依存の参照 | 「如上所述」这类，kb 里禁止<br>"as stated above" and the like; forbidden in kb<br>「前述のとおり」の類。kb では禁止 |
| 自指称呼 | self-reference | 自己参照 | 「本条」「该决策」这类指着「此处」的写法，kb 里禁止<br>"this entry", "that decision" — pointing at "here"; forbidden in kb<br>「本項」「当該判断」のように「ここ」を指す書き方。kb では禁止 |
| 缩写 | abbreviation | 略語 | 我们声明的名字里不许用；登记过的领域缩写与 Rust 关键字除外<br>not allowed in any name we declare; registered domain abbreviations and Rust keywords excepted<br>自前で宣言する名前には使わない。登録済みの領域略語と Rust のキーワードは除く |
| 缩写登记表 | abbreviation registry | 略語登録表 | 项目根的 `.claude/abbreviations`，每个领域缩写唯一的权威定义<br>`.claude/abbreviations` at the project root: the single authoritative definition of each domain abbreviation<br>プロジェクト直下の `.claude/abbreviations`。領域略語ごとの唯一の権威ある定義 |
| 上下文约束 | context constraints | 文脈の制約 | 名字里带的前置条件与作用范围<br>the preconditions and scope carried in a name<br>名前に載せる前提条件と作用範囲 |
| 路径数 | path count | 経路数 | 穷尽覆盖控制流需要多少用例；不含循环状态与数据<br>how many cases exhaustive control-flow coverage needs; loop state and data not included<br>制御フローの網羅に必要なケース数。ループの状態とデータは含まない |
| 通配臂 | wildcard arm | ワイルドカードアーム | `match` 里的 `_ =>`；封闭集合的枚举上不许写<br>the `_ =>` arm of a `match`; not allowed on enums that are closed sets<br>`match` の `_ =>`。閉じた集合の列挙型には書かない |
| 分支 | branch（实现分支） | 分岐 | **不是 git branch**，是代码路径<br>**not a git branch** — a code path<br>**git branch ではなく**、コード経路 |
| 意图日志 | intent log | インテントログ | 无界操作的「写意图 → 分批 → 可续做」<br>"write intent → batch → resumable" for unbounded operations<br>非有界操作の「意図を書く → 分割 → 再開可能」 |
| 无界操作 | unbounded operation | 非有界操作 | 可能修改无限多项的操作<br>an operation that may touch unboundedly many items<br>無限個の項目を変えうる操作 |
| 幂等 | idempotent | 冪等 | 续做时重复执行不出错<br>re-running on resume does no harm<br>再開時に重複実行しても壊れない |
| 事务层 | transaction layer | トランザクション層 | 所有结构共用的那一个<br>the single one shared by every structure<br>全構造が共有する唯一の層 |
| 反向索引 | reverse index / backpointer | 逆引きインデックス | 物理位置 → 逻辑引用<br>physical location → logical reference<br>物理位置 → 論理参照 |
| 记账 | accounting | 会計 | 空间统计，事务的副产品<br>space accounting, a by-product of the transaction<br>容量集計。トランザクションの副産物 |
| 爆炸半径 | blast radius | 影響範囲 | 一处损坏波及多大<br>how far one piece of damage reaches<br>一箇所の破損がどこまで及ぶか |
| 可重建性 | reconstructability | 再構築可能性 | 全盘扫描能否重建<br>whether a full scan can rebuild it<br>全走査で再構築できるか |

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
