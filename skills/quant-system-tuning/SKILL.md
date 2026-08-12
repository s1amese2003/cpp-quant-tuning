---
name: quant-system-tuning
description: 低延迟交易机的系统层调优 — CPU 亲和性与 NUMA、isolcpus/cpuset 核隔离、超线程处理、实时线程优先级(SCHED_FIFO)、中断(IRQ)绑定与隔离、TLB shootdown 与页表变更类内核特性、C-State/P-State 与频率锁定、系统静默(nohz_full/rcu_nocbs)、内核参数与 BIOS 配置。Use for CPU pinning, taskset, isolcpus, cpuset, NUMA, numactl, numa_balancing, hyper-threading, SCHED_FIFO, RT priority, IRQ affinity, IPI, TLB shootdown, THP, KSM, compaction, C-states, turbo, tickless, nohz_full, kernel boot params, BIOS settings, jitter, 延迟抖动, 核隔离, 系统静默, or when latency measurements are noisy and the machine itself must be tuned first.
license: CC-BY-4.0
metadata:
  version: "1.0.0"
  source: "trading-system-notes-Chinese.md 《交易系统开发》张智炫"
---

# 交易机系统层调优（System Tuning）

**在系统噪声消除之前测出来的 p99 是调度器的指标，不是你代码的指标。** 任何延迟优化项目都应该先做这一层，否则后续所有测量都不可信。

平台假设：**Linux x86-64**。以下配置在 Windows/macOS 上不适用，跨平台开发时要显式说明。

---

## 1. 执行顺序

```
BIOS 层        → 关节能、关 C-State、锁频率、按需关 SMT
内核启动参数    → isolcpus / nohz_full / rcu_nocbs / 关 C-State / 大页预留
运行时系统配置  → IRQ 亲和、cpufreq governor、swappiness、watchdog、THP
进程/线程层    → taskset / numactl / pthread_setaffinity_np / SCHED_FIFO / mlockall
验证          → cyclictest 测抖动，确认底噪已降下来再测业务延迟
```

跳过前三步直接调第四步是无效的：内核仍会往你的"专用核"上派时钟中断、RCU 回调和 kworker。

---

## 2. 核隔离与绑定

### 四种手段的层级

| 手段 | 层级 | 隔离强度 | 动态性 |
|---|---|---|---|
| `isolcpus=` 启动参数 | 内核 | **强** | 静态（需重启） |
| `cpuset` (cgroup) | 内核 | **强** | 动态 |
| `taskset` | 进程 | 弱 | 动态 |
| `pthread_setaffinity_np` | 线程 | 弱 | 动态 |

生产做法：`isolcpus` + `nohz_full` + `rcu_nocbs` 三件套指定同一批核，再用 `pthread_setaffinity_np` 在代码里把具体线程钉上去。

```
GRUB_CMDLINE_LINUX_DEFAULT="... isolcpus=4-11 nohz_full=4-11 rcu_nocbs=4-11 \
    intel_idle.max_cstate=0 processor.max_cstate=1 idle=poll intel_pstate=disable \
    nosoftlockup mce=ignore_ce audit=0 nmi_watchdog=0 \
    hugepagesz=2M hugepages=2048 default_hugepagesz=2M transparent_hugepage=never"
```

### 绑核纪律

- **避开 core 0（以及 core 1）**：内核默认把系统任务派到 core 0，社区也报告过 core 1 的类似问题。热路径线程不要绑这两个。
- **超线程**：同物理核的两个逻辑核共享 ALU/FPU 与 L1/L2。兄弟核跑 AVX 宽指令会阻塞交易线程，也会污染 L1。
  - 保守做法：BIOS 关 SMT（牺牲整机吞吐）。
  - 精细做法：BIOS 保留 SMT，用 `lscpu -e=CPU,CORE,SOCKET` 找出兄弟核，把兄弟核 `echo 0 > /sys/devices/system/cpu/cpuN/online` 离线，只离线交易核的兄弟；非实时任务照常用其他核的超线程。**BIOS 全局关 SMT 会让这种精细控制失效**。
- **NUMA**：交易线程、它的内存池、以及网卡中断必须在**同一 NUMA 节点**。跨节点访问延迟约 1.5~2 倍。用 `numactl --cpunodebind=0 --membind=0 ./app` 启动，`lstopo` 确认网卡挂在哪个节点。

> 参考：`references/01-cpu-affinity-numa.md`

---

## 3. 线程优先级

- 热路径线程用 `SCHED_FIFO`（优先级 80~90 区间），**不要用 99**（留给内核的 watchdog/迁移线程，抢占它们会挂机器）。
- 必须同时设 `RLIMIT_RTTIME` 或保留 `sched_rt_runtime_us`，否则死循环的 RT 线程会锁死整个核，连 ssh 都进不去。开发机上尤其重要。
- 忙轮询线程 + `SCHED_FIFO` + 隔离核 = 该核 100% 占用，这是**预期行为**，不是 bug。
- 非实时的日志/监控线程用 `SCHED_OTHER` 并绑到非隔离核，nice 值调高。

> 参考：`references/02-realtime-thread-priority.md`

---

## 4. 中断隔离

隔离核上不应该有任何中断。

```bash
# 1) 关掉 irqbalance，否则它会把中断重新撒回隔离核
systemctl stop irqbalance && systemctl disable irqbalance

# 2) 把所有中断默认打到管理核
for irq in /proc/irq/*/smp_affinity_list; do echo 0-3 > $irq 2>/dev/null; done

# 3) 行情网卡的队列中断绑到与交易线程同 NUMA 的邻近核（不是交易核本身）
#    交易线程忙轮询时甚至可以不依赖中断

# 4) 检查残留
cat /proc/interrupts   # 观察隔离核那几列是否还在增长
```

同时处理：
- **RCU 回调**：`rcu_nocbs=` 把回调迁走。
- **timer tick**：`nohz_full=` 让隔离核在只有一个可运行任务时不收时钟中断。
- **kworker / kthread**：`echo 0-3 > /sys/devices/virtual/workqueue/cpumask`。
- **watchdog**：`kernel.nmi_watchdog=0`、`kernel.watchdog_cpumask`。

> 参考：`references/03-irq-isolation.md`、`references/04-system-quiescing.md`

---

## 5. 频率与节能

**目标是频率恒定，不是频率最高。** 抖动比绝对速度更伤交易系统。

| 项 | 设置 |
|---|---|
| BIOS C-States / C1E | Disabled |
| SpeedStep / Cool'n'Quiet | Disabled |
| Turbo Boost | **Disabled**（涨频不确定 + 热降频，宁可锁在标称频率） |
| CPU Ratio | 手动锁定 |
| Linux governor | `cpupower frequency-set -g performance` |
| 内核参数 | `intel_idle.max_cstate=0 processor.max_cstate=1 idle=poll` |

`idle=poll` 是最激进的（空闲时不进 C-State，直接轮询），功耗和发热显著上升，务必确认散热能撑住 —— 否则会触发热降频，反而制造抖动。

> 参考：`references/05-kernel-bios-tuning.md`

---

## 6. 其他系统项

```bash
vm.swappiness=0                 # 配合 mlockall
vm.stat_interval=120            # 降低统计线程唤醒频率
kernel.numa_balancing=0         # 关自动 NUMA 迁移
transparent_hugepage=never      # 用显式 hugetlb 代替（见 quant-memory-simd）
vm.compaction_proactiveness=0   # 关主动内存规整（Linux 5.9+）
kernel.sched_rt_runtime_us=-1   # 谨慎：允许 RT 线程 100% 占核，需配合看门狗
```

关闭：SELinux/AppArmor 的热路径审计、`auditd`、不必要的 `systemd` 定时器、`ksmd`、`kcompactd`。

### 这几项为什么是同一件事：TLB Shootdown

上面的 `numa_balancing` / `transparent_hugepage` / `compaction_proactiveness` / `ksmd` 不是四条独立的经验，它们**共享同一个危害机制**：都会变更页表，而 TLB 的跨核一致性**没有硬件协议**——内核必须发 IPI 让其他核执行 `INVLPG`，被通知的核无论在做什么都要停下来处理。**你的隔离核、`SCHED_FIFO`、忙轮询线程挡不住 IPI。**

```bash
# 按核对比 shootdown 计数；隔离核那一列应该基本不动
watch -n5 -d "grep TLB /proc/interrupts"
```

典型案例：某核 TLB shootdown 计数异常暴涨，定位到自动 NUMA balancing（它靠周期性取消页面映射来采样访问位置），`sysctl -w kernel.numa_balancing=0` 后恢复。

同机不要跑 GC 语言的进程（JVM/Go 会通过 `madvise` 大量归还内存）。应用侧的对应做法（`M_MMAP_MAX=0`、交易时段冻结地址空间）见 `quant-memory-simd` 第 4 节。

---

## 7. 验证

```bash
# 底噪抖动（隔离核应在个位数 μs 以内，理想 < 5μs）
cyclictest -p 90 -t1 -a 8 -n -m -D 60 -h 200

# 隔离核上是否还有中断/上下文切换
watch -n1 'cat /proc/interrupts'
perf stat -e context-switches,cpu-migrations,page-faults -C 8 -a sleep 10

# TLB shootdown：隔离核那一列应基本不动（页表变更类内核特性是否真关干净了）
watch -n5 -d 'grep TLB /proc/interrupts'

# 确认绑核生效
taskset -pc <PID>; ps -To pid,tid,psr,comm <PID>

# 确认 NUMA 本地
numastat -p <PID>
```

**验收标准**：稳态下隔离核的 `context-switches`、`cpu-migrations`、`page-faults` 都应为 0 或接近 0。达不到就别往下测业务延迟。

---

## 8. 检查清单

- [ ] BIOS：C-State/C1E/SpeedStep/Turbo 全关，频率锁定
- [ ] 启动参数：`isolcpus` + `nohz_full` + `rcu_nocbs` 覆盖同一批核
- [ ] `irqbalance` 已停用，中断已迁出隔离核
- [ ] 热路径线程绑在非 0/1 号、与网卡同 NUMA 的物理核上
- [ ] 兄弟超线程已离线（或 SMT 全关）
- [ ] governor = performance
- [ ] `mlockall` + `swappiness=0` + 大页预留
- [ ] 页表变更类特性全关（THP、numa_balancing、KSM、主动规整），`grep TLB /proc/interrupts` 隔离核列不增长
- [ ] `cyclictest` 抖动达标后才开始测业务延迟
- [ ] 所有配置写成脚本/ansible 并纳入版本控制（**手工敲过一遍的机器一定会漂移**）

---

## references/ 索引

| 文件 | 内容 |
|---|---|
| `01-cpu-affinity-numa.md` | CPU 亲和性及 NUMA 架构 |
| `02-realtime-thread-priority.md` | 实时线程优先级 |
| `03-irq-isolation.md` | 中断绑定及常见中断核心隔离 |
| `04-system-quiescing.md` | 系统静默配置步骤总结 |
| `05-kernel-bios-tuning.md` | Linux 内核调优和 BIOS 配置 |
