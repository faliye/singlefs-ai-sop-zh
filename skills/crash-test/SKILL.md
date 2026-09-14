---
name: crash-test
description: 跑 singlefs 的验证套件——LKMM 内存序、QEMU/KVM 压测、崩溃点重放、模型对拍。判断写路径对不对、或要给并发改动补验证时用它。
---

# 验证套件

规则在 `rules/test-discipline.md` 与 `rules/show-me-test.md`。

## 四种验证的分工

| 手段 | 验什么 | 谁来提供 |
|---|---|---|
| **LKMM（herd7）** | 并发路径的内存序：无锁结构、屏障、跨核可见性 | 共享脚本 `lkmm.sh`，门禁的「LKMM」阶段 |
| **QEMU/KVM** | 真实负载下的端到端行为，准入的最终判据 | 项目本地：虚机装置和门禁阶段都在项目里 |
| 崩溃点重放 | 任意断电点能否恢复 | 项目本地 |
| 模型对拍 | 功能正确性：操作序列结果对不对 | 项目本地 |

后三样要被测对象自己的录制流、镜像格式和 checker，共享门禁带不了。
项目在 `.claude/gate.d/` 里接上一样，就在那个阶段头部写明它覆盖的是哪一项：

```bash
# gate-stage: 层 0 崩溃点重放（第一个事务的全部崩溃状态）
# gate-covers: 崩溃点重放
```

能写的键只有 `模型对拍`、`崩溃点重放`、`QEMU 真实负载`、`QEMU 崩溃注入` 这几个，写错一个字判红。
这个阶段这一轮跑了且通过，`gate.sh` 末尾的未实现清单才把那一项换到「由项目本地阶段覆盖」下面。
覆盖只说明「有一个阶段在做这件事，这次过了」；它覆盖到多大范围，看那个阶段自己的名字和说明。
这一轮无对象可判的阶段退出码写 77：记「本次未跑」，不记通过，也不算覆盖。

## LKMM

```bash
bash .claude/scripts/lkmm.sh
SINGLEFS_KERNEL_TREE=/path/to/linux bash .claude/scripts/lkmm.sh   # 指定内核树
bash .claude/scripts/lkmm.sh --static-only    # 只跑不需要 herd7 的检查，全过也退 3，不算通过
```

每个 `litmus/*.litmus` 必须声明期望判定，脚本拿 herd7 的 `Observation` 行比对：

```
(* singlefs-expect: Never *)      坏结果必须不可能发生
(* singlefs-expect: Sometimes *)  坏结果可能发生（对照组）
```

### 对照组：同一条测试去掉屏障

**每条 Never 都要配一个对照组**，否则判出 Never 也分不清是「屏障挡住了」还是「这个模式本来就撞不上」。

配对先按文件名找：`x.litmus` 的对照组叫 `x-<后缀>.litmus`（惯例是 `x-nofence.litmus`），声明 Sometimes。
再按内容认：去掉注释和首行之后逐行比，对照组只许比原测试少几行屏障（`smp_wmb`、`smp_rmb`、`smp_mb` 等），
或者把 `smp_store_release` / `smp_load_acquire` 放宽成 `WRITE_ONCE` / `READ_ONCE`，至少一处。
exists、init、读者一个字都不许改：改了，它回答的就是另一个问题。全局有几条 Sometimes 更不算数。

### 绑到代码

herd7 判的是 litmus 写下的那个形态。代码改了发布顺序而 litmus 没跟，判定照样是 Never，门禁照样绿。
所以每条 Never 要在文件头写明它模拟的是哪段代码，一行一个锚点，锚点后面空一格可以写注释：

```
(*
 * singlefs-expect: Never
 * singlefs-models: crates/<crate>/src/transaction.rs::publish_first_file 写者
 * singlefs-models: crates/<crate>/src/recovery.rs::choose_root 读者
 *)
```

脚本查三样：文件在；里面有这个 `fn`；`crates/` 下有一个 `.rs` 写出这个 litmus 的文件名。
最后那一样就是绑定测试：读这个 litmus，拿它的写者 / 读者次序跟代码今天实际发出的次序比
（例：录制写请求流，按步骤分类后逐项比）。门禁按文件名认它，测得对不对要人看。

不对应任何代码的（比如模板那一对）写 `singlefs-models: none —— <为什么>`，理由不许空。

### 两个只有 klitmus7 才会炸的坑

脚本会提前拦：用了 `rN` 必须有 `int rN;`；init 块里给 `atomic_t` 形参赋初值必须带类型。

## QEMU

共享门禁不带虚机装置。挂几块盘、塞什么二进制、结果怎么抓、设备侧要不要独立录制，
都跟被测对象绑在一起，所以装置和它的门禁阶段都放在项目里。

装置要守的规矩在 `rules/command-safety.md`：虚机 pid 写进文件、按写死的 pid 清理；结果抓取要有条数闸；
退出码要能如实传回宿主——装置自带一个必然失败的用例，认不出失败就是装置坏了。
找不到能读的内核就直接失败，不退回软件模拟：那样慢到没法用，看着却像在跑。

门禁阶段接上之后，只跑了真实负载的写 `# gate-covers: QEMU 真实负载`；
做到了崩溃注入、跑完 checker 全绿的，另写 `# gate-covers: QEMU 崩溃注入`，那才是准入的最终判据。

## 为什么崩溃点重放不能用别的代替

**单测全绿、模型对拍全过、checker 一声不吭——这三样加起来也不算崩溃一致性的证据。**

它们验的是「正常走完一遍，状态对不对」。崩溃一致性问的是另一件事：
**在任意一个写请求之后断电，重启还能不能收场。** 这只能把每个崩溃点都试一遍才知道。

实现它需要（按依赖顺序）：磁盘格式第一版（见项目 `kb/decisions.md` 里盘上格式那几条）→ mkfs + checker
→ 事务提交路径 → 块层写记录（`dm-log-writes`）。

## 判读纪律

- **「没复现问题」不等于「没问题」。** 想说崩溃一致性成立，
  得先说清这一轮枚举了多少个崩溃点，是不是全部。
- **checker 不报错，也可能是那条检查压根没实现。** 先看 `kb/invariants.md` 的状态列。
- **判定结果读不到，这一轮就作废**，绝不能当成通过。`lkmm.sh` 读不到 `Observation` 直接失败；
  项目的虚机装置读不到退出标记也一样。
