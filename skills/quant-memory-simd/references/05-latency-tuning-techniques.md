# 低延迟专项：缺页、预热、TLB Shootdown 与意外降频

> 内容整理自 Denis Bakhvalov《现代 CPU 上的性能分析与优化》第 12 章 12.4「低延迟调优技术」（weedge 维护的中文翻译版），按交易系统场景重写并补充实操细节。

**统领这四项技术的一条原则：宁可多占内存、宁可牺牲整体吞吐，也要把热路径上所有"延迟不确定"的操作提前到启动阶段做掉。**

这与通用服务端优化的方向相反。通用服务追求内存占用小、按需分配、把资源还给系统；交易进程要的是**关键路径上不发生任何需要内核介入的事**——不缺页、不刷 TLB、不重新取指、不改频率。内存和吞吐是用来换确定性的筹码。

---

## 1. 消除小缺页错误（Minor Page Faults）

### 1.1 机制：先承诺，后交付

`malloc` / `mmap` 返回时，内核**只修改了进程的 VMA 记录**，并没有分配物理页。直到代码第一次真正访问该页，才触发缺页异常（`#PF`），由内核找一个物理页帧、清零、填入页表项、返回用户态重新执行那条指令。

- 这叫 **minor fault**（次要缺页）：不涉及磁盘 I/O，但仍是一次完整的内核陷入。
- 代价：**零点几到几微秒**。对 tick-to-trade 只有几微秒预算的路径，一次就够把 p99.9 打穿。
- **五级页表比四级页表更慢**：page walk 多一层，未命中时的地址翻译成本上升。开启 5-level paging 的新机器上这项成本更值得关注。
- 另有 **major fault**（需要从磁盘/swap 读回）：交易机上稳态必须为 0，靠 `mlockall` + `vm.swappiness=0` 保证。出现一次就是事故。

### 1.2 检测

**判定标准：HFT 场景下，进入交易时段后缺页数非零就算问题。** 启动阶段的缺页是预期的（我们正是要把它赶到那里去）。

```bash
# 1) 实时观察：按线程看每个刷新间隔的缺页增量
top -H -p <PID>
#    按 f 进入字段选择，勾选 vMn（本刷新间隔内的 minor fault 增量）
#    老版本 top 只有累计值 nMin/nMaj，需要自己做差

# 2) 定量：挂到运行中的进程上统计
perf stat -e page-faults,minor-faults,major-faults -p <PID> -- sleep 10

# 3) 定位到代码行：哪一行在制造缺页
perf record -e page-faults -g -p <PID> -- sleep 10
perf report --stdio
```

第 3 条是关键——`page-faults` 是软件事件，可以像采样 CPU 周期一样采样它，直接给出制造缺页的调用栈。常见的意外来源：日志缓冲扩容、`std::vector` 第一次写入尾部、线程栈向下生长、延迟初始化的静态对象、`std::function` 的堆分配。

### 1.3 规避：三层做法

#### 第一层：启动时预分配并逐页写一遍（pre-faulting）

```cpp
// 强制物理页提前就位
void prefault(void* base, size_t bytes, size_t page = 4096) {
    auto* p = static_cast<volatile char*>(base);
    for (size_t off = 0; off < bytes; off += page)
        p[off] = 0;          // 必须是"写"
}
```

**必须是写，不能只读。** Linux 对匿名内存的只读缺页会映射到全局共享的零页（shared zero page），物理页并没有真正分给你；等到真正写入时会再触发一次 COW 缺页——预热等于白做。用 `memset` 或按页步进写一个字节都可以，但不要用只读遍历"预热"。

同样要覆盖：内存池的全部槽位、环形日志缓冲、行情解包缓冲、订单模板数组、**线程栈**（`mlockall(MCL_FUTURE)` 会覆盖之后创建的线程栈，见第三层）。

#### 第二层：让分配器不再把内存还给内核

即使预分配过了，只要分配器在运行期归还内存，下次再要就得重新缺页。glibc 的三个开关：

```c
#include <malloc.h>
// 必须在任何分配之前调用——放在 main() 最开头，注意静态对象的构造更早
mallopt(M_MMAP_MAX,       0);   // 大块分配不走 mmap
mallopt(M_TRIM_THRESHOLD, -1);  // free 之后不把 brk 堆还给内核
mallopt(M_ARENA_MAX,      1);   // 只用一个 arena
```

各自的理由：

| 参数 | 不设会怎样 |
|---|---|
| `M_MMAP_MAX=0` | 大块分配走 `mmap`，`free` 时 `munmap` 归还——不仅撤销了 `mlock`，还会触发 **TLB shootdown**（见第 3 节） |
| `M_TRIM_THRESHOLD=-1` | 堆顶空闲超过阈值时 glibc 调 `brk` 收缩，下次增长又要重新缺页 |
| `M_ARENA_MAX=1` | 多线程下 glibc 为每个核开独立 arena，每个 arena 各自 `mmap`，制造更多映射与归还 |

**副作用要说清**：`M_ARENA_MAX=1` 牺牲的正是 glibc 分配器的多线程扩展性。对"热路径零分配"的交易进程这是免费的；但如果温路径（对账、日志、监控）确实有多线程分配压力，要实测其吞吐影响后再决定。

#### 第三层：锁住物理内存

```cpp
if (mlockall(MCL_CURRENT | MCL_FUTURE) != 0)
    /* 需要 CAP_IPC_LOCK，或 ulimit -l unlimited */;
```

- `MCL_CURRENT` 锁当前所有映射，`MCL_FUTURE` 锁之后新建的映射——**后者会覆盖之后创建的线程栈**，这是它最有价值的地方。
- 配合 `vm.swappiness=0`，以及给二进制 `setcap CAP_IPC_LOCK+ep`。
- **不要用 `MCL_ONFAULT`**：它只锁"已经触及"的页，正好绕开我们想要的"提前把页钉住"的效果。

#### Windows 对应

| Linux | Windows |
|---|---|
| 预分配 + 逐页写 | `VirtualAlloc(..., MEM_COMMIT, ...)` 后同样要写一遍 |
| `mlockall` | `VirtualLock`（先用 `SetProcessWorkingSetSize` 抬高工作集上限，否则锁不了多少） |
| 不归还内核 | 释放时用 `VirtualFree(..., MEM_DECOMMIT)`，**不要用 `MEM_RELEASE`**（后者归还地址空间） |

#### 换分配器更省事

jemalloc / tcmalloc / mimalloc 都内置了这类能力，比拧 glibc 的旋钮直接：

```bash
# jemalloc：保留虚拟内存，关闭 dirty/muzzy 页的衰减归还
MALLOC_CONF="retain:true,dirty_decay_ms:-1,muzzy_decay_ms:-1"

# mimalloc：启动时预留大页
MIMALLOC_RESERVE_HUGE_OS_PAGES=4
```

但注意：**换分配器不能替代"热路径零分配"这条纪律。** 它只是把温路径和启动期的不确定性压低，热路径上仍然一次 `malloc` 都不该有。

### 1.4 与大页的关系

大页把缺页次数直接除以 512（一次 2MiB fault 顶 512 次 4KiB fault），但**单次 fault 更贵**——内核要清零整整 2MiB。所以上了大页反而更应该在启动期把页全部预 fault 掉，否则第一次触碰某个 2MiB 区域的停顿比 4KiB 时更长。

---

## 2. 缓存预热（Cache Warming）

### 2.1 问题的不对称性

这是交易系统特有的结构性问题：

| 路径 | 执行频率 | 缓存状态 |
|---|---|---|
| 收行情、解包、更新订单簿 | 每秒数万次 | **恒热** |
| 信号触发 → 风控 → 序列化 → 发单 | 每天几十到几百次 | **每次都是冷的** |

真正需要最快的那一刻，恰好是这段代码最冷的时候。冷启动惩罚同时来自好几层：

| 层 | 冷了会怎样 |
|---|---|
| L1i / uop cache | 取指停顿，整条函数链要从 L2/LLC/内存重新取 |
| BTB / 分支预测器 | 每个分支一次误预测，约 15~20 cycles，累加起来很可观 |
| L1d / L2 | 订单模板、合约静态表、风控参数全部 miss |
| iTLB / dTLB | 额外的 page walk |
| 网卡 TX 描述符环、DMA 缓冲、PCIe 写路径 | 首包比稳态慢 |

这是一场"谁先到交易所"的竞速，几微秒的冷启动惩罚就能决定成交与否。

### 2.2 做法：周期性空跑

在等行情的空闲期，用**模拟数据**跑一遍完整的下单路径，只为让它留在缓存里，不产生任何实际副作用。

```cpp
// 拦截点必须唯一，且尽可能靠后
inline void send_order(const Order& o, bool dry_run) {
    encode(tx_buf_, o);          // 真实执行
    risk_check(o);               // 真实执行
    update_local_state(o);       // 真实执行（写到影子结构，见下）
    if (dry_run) [[unlikely]] return;   // ← 唯一拦截点
    nic_write(tx_buf_, len_);
}
```

### 2.3 实现纪律（这几条决定预热是真有效还是自我安慰）

1. **拦截点必须放在最后一步之前，且全局唯一。** 目的是让前面每一条指令、每一个分支都真实执行过。拦得越早，预热的覆盖面越小。

2. **必须用运行时 flag，不能用编译期分派。** 这条反直觉但关键：如果写成 `template<bool DryRun>`，编译器会生成两份独立的代码，预热跑的是 dry-run 那一份，真实发单走的是另一份——I-cache 里热的是错误的地址。CRTP、`if constexpr`、宏特化在这里全是陷阱。这是本仓库中**唯一**一处明确反对编译期分派的场景。

3. **预热数据要有真实形状。** 用真实合约、真实价格档位、真实报单类型。价格全填 0 会走到不同的分支、触及不同的 cache line，预热的是另一条路径。

4. **不能有副作用。** 不递增真实序列号、不改订单状态机、不写业务日志、不占用真实 order id（需要 id 的话，从保留段里取）。状态更新写到影子结构上，或者跑完回滚。

5. **拦截点必须在自有代码内。** 不要"进了厂商 SDK 或交易所 API 再拦截"——对方内部有状态机，中途返回可能留下不一致状态，甚至真的把包发出去。

6. **频率要高于缓存驱逐周期。** 经验值 ms 级。调参方法：逐步拉长预热间隔，看第一笔真实报单的 p99 从哪个间隔开始抬头，取该值的一半。

7. **预热本身要计入 CPU 预算。** 它占用的是热核。必须在"确认当前没有待处理行情"之后再跑，否则预热挤掉真实行情处理，得不偿失。

> 原书未给代码示例，指向了 CppCon 2018 的一场关于 cache warming 的 lightning talk。

---

## 3. 避免 TLB 驱逐（TLB Shootdown）

### 3.1 为什么 TLB 和数据缓存不是一回事

L1/L2/LLC 的跨核一致性由**硬件** MESI/MESIF 协议维护，软件完全无感。

**TLB 没有硬件一致性协议。** 某个核修改了页表项之后，其他核 TLB 里缓存的旧翻译不会自动失效——必须由**内核用软件**去通知：向所有可能缓存了该 PTE 的核发送**处理器间中断（IPI）**，目标核在中断上下文里执行 `INVLPG`（或整表刷新）使对应条目失效。这个过程就叫 **TLB shootdown**。

代价与危害：

- 目标核**无论正在做什么都会被打断**——包括你那个绑了核、开了 `SCHED_FIFO`、正在忙轮询行情的交易线程。
- IPI 往返 + 中断处理，微秒量级；核数越多，广播面越大。
- **最关键的一点：你的交易线程可以完全没做过任何内存映射操作，仍然被打断。** 只要同进程的另一个线程调了 `munmap`，你就在受害名单里。

作用范围的一个重要细节：用户态页表变更的 IPI 是按 `mm_cpumask` 发送的，只发给**共享同一地址空间**的那些核。所以：

- **多线程进程内部问题最严重**——所有线程共享 mm，一个线程的地址空间变更打断所有其他线程。
- 别的进程改它自己的用户页，一般不会 shootdown 到你。
- 但**内核地址空间的变更**（`vmalloc`、内核模块加载、页迁移、大页规整）会波及全局。

### 3.2 触发源

**显式——你的代码直接调用的：**

| 系统调用 | 常见来源 |
|---|---|
| `munmap` | `free` 大块时 glibc 内部调用（这是 `M_MMAP_MAX=0` 的第二个理由）、共享内存卸载、`dlclose` |
| `mprotect` | JIT、guard page 逻辑、某些 GC、`std::pmr` 的部分实现 |
| `madvise(MADV_DONTNEED / MADV_FREE)` | 分配器归还内存的标准手段（jemalloc/tcmalloc 默认行为） |

**隐式——你没写，但系统会替你做的：**

- **透明大页（THP）**：`khugepaged` 后台合并 4KiB 页为 2MiB，以及大页被拆分时。
- **内存规整**：`kcompactd` 与直接规整（direct compaction）移动物理页。
- **自动 NUMA balancing**：内核周期性地把页面标记为不可访问来采样访问来源，再据此迁移页面——**采样和迁移两步都触发 shootdown**。
- **页面回收与 page cache 回写**、**KSM 同页合并**。
- 同机上跑着的 JVM / Go 进程的 GC（通过 `madvise` 大量归还内存）。

### 3.3 检测

```bash
# 按核对比 TLB shootdown 中断计数，-d 高亮变化
watch -n5 -d "grep TLB /proc/interrupts"
```

**读法**：找到延迟关键线程所在的那一列。如果它的 TLB 计数明显高于其他核、或持续快速增长，就有人在打断它。隔离核上的理想值是几乎不动。

补充手段：

```bash
perf stat -e tlb:tlb_flush -a -- sleep 10              # 全系统 flush 次数
perf trace -e munmap,mprotect,madvise -p <PID>          # 抓自己进程的显式触发
perf stat -e dTLB-load-misses,iTLB-load-misses -p <PID> # 区分"被 shootdown" vs "本核 TLB 不够用"
```

最后一条很重要：**TLB miss 和 TLB shootdown 是两个不同的问题**。miss 是自己工作集超出 TLB 覆盖范围，解法是大页；shootdown 是被别人打断，解法是冻结地址空间。用错解法没有效果。

**原书案例**：某核的 TLB shootdown 计数异常暴涨，定位到自动 NUMA balancing，`sysctl -w kernel.numa_balancing=0` 关掉后解决。

### 3.4 规避

**源码层：**

- 热路径与温路径都不调 `munmap` / `mprotect` / `madvise`。"内存池只借不还、耗尽即背压"这条规则的另一半理由就在这里。
- 分配器配置成不归还内核（见 1.3 第二层）。
- **启动期把所有 `mmap`、`dlopen`、共享内存挂载做完，进入交易时段后地址空间冻结**。这条可以写成断言：记下 `/proc/self/maps` 的行数与哈希，交易时段周期性校验没有变化。

**系统层：**

```bash
transparent_hugepage=never                       # 启动参数；改用显式 hugetlb 预留
sysctl -w kernel.numa_balancing=0                # 关自动 NUMA 迁移
echo 0 > /sys/kernel/mm/ksm/run                  # 关同页合并
sysctl -w vm.compaction_proactiveness=0          # 关主动内存规整（Linux 5.9+）
```

同机不要跑 GC 语言的进程；确实要跑的监控/日志进程绑到非隔离核，并注意它们的内存归还行为。

### 3.5 与大页的取舍

大页减少 TLB 条目压力（一条目覆盖 2MiB），但 **THP 的动态合并与拆分本身就是 shootdown 的来源**。结论很明确：

> **要大页的收益，不要 THP 的机制** —— 启动参数预留 hugetlb（`hugepagesz=2M hugepages=N`），进程用 `MAP_HUGETLB` 拿，同时 `transparent_hugepage=never`。

---

## 4. 防止意外的内核降频（AVX 引起的节流）

### 4.1 机制

Intel Skylake-SP ~ Ice Lake-SP 世代：执行"重型" AVX 指令（512 位，或 256 位的重型浮点/乘法）会让核心切换到更低的**频率许可级别**（turbo license L1/L2），降频数百 MHz。

两个让它变成"毛刺"而不是"稳定代价"的性质：

1. **降频有滞后**：一条重型指令的影响持续数百微秒到约 1ms，期间**后续所有代码**——包括纯标量的报单序列化——都在低频运行。
2. **你没主动写 AVX 也会中招**：`-O3 -march=native` 下，编译器会自作主张地把 `memcpy`、结构体拷贝、`std::fill`、小循环、甚至字符串比较向量化成 `zmm`/`ymm` 指令。**这正是它"毫无征兆"的原因。**

### 4.2 检测

```bash
# 热路径二进制里到底有没有宽向量指令
objdump -d --no-show-raw-insn -M intel build/app | grep -c zmm
objdump -d --no-show-raw-insn -M intel build/app | grep -n 'zmm' | head

# 频率许可级别（Skylake-SP 系列事件）
perf stat -e core_power.lvl0_turbo_license,core_power.lvl1_turbo_license,\
core_power.lvl2_turbo_license -p <PID> -- sleep 10

# 实际频率是否偶发下沉
turbostat --interval 1
```

`lvl1`/`lvl2` 的计数非零，说明确实进过降频许可级别。

### 4.3 规避

```
-mprefer-vector-width=128     # 最保守
-mprefer-vector-width=256     # 通常的安全默认
```

用法纪律：

- **按 target 分开设，不要全局一刀切。** 热路径 TU 设 128 或 256；冷路径（回测、因子批算、历史数据转换）该用 512 就用 512——那里要的是吞吐。CMake 里对不同 target 用 `target_compile_options` 分别指定。
- 确实需要 AVX-512 的批处理放到**独立的物理核**上，并注意超线程兄弟核：兄弟核跑 AVX-512 会连累你的交易线程（见 `quant-system-tuning` 第 2 节的兄弟核离线做法）。
- 加了这个选项要复测：它会让 `memcpy` 之类的宽度受限，吞吐有实际损失。

### 4.4 时效性警告

**这是一条与硬件代次强绑定的建议。** Ice Lake 之后的 Intel（Sapphire Rapids / Emerald Rapids）以及 AMD Zen4 / Zen5，AVX-512 降频问题已基本消失。

所以：**先 `lscpu` 确认 CPU 型号，再决定要不要加。** 在新机器上无脑加 `-mprefer-vector-width=128`，等于白白放弃一半向量带宽换一个不存在的问题。

---

## 5. 检查清单

**缺页**
- [ ] 稳态下 `perf stat -e page-faults -p <PID>` 为 0？major fault 恒为 0？
- [ ] 预热是**写**而不是只读遍历（避免共享零页 + 后续 COW）？
- [ ] `mallopt` 三件套在任何分配之前调用？副作用（单 arena）已评估？
- [ ] `mlockall(MCL_CURRENT|MCL_FUTURE)` 成功返回，且有 `CAP_IPC_LOCK`/`ulimit -l`？
- [ ] 线程栈、日志缓冲、解包缓冲都在预热覆盖范围内？

**预热**
- [ ] 下单路径有周期性 dry-run，且拦截点唯一、位于最后一步之前？
- [ ] 用的是**运行时 flag** 而不是模板/`if constexpr`（否则预热的是另一份代码）？
- [ ] 预热数据是真实形状（真实合约、真实价格档）？
- [ ] 确认无副作用：不递增序列号、不改状态机、不占真实 order id？

**TLB**
- [ ] `grep TLB /proc/interrupts` 中，隔离核的计数基本不动？
- [ ] 交易时段内 `/proc/self/maps` 不再变化（地址空间已冻结）？
- [ ] THP、numa_balancing、KSM、主动规整全部关闭？
- [ ] 区分清楚了当前问题是 TLB **miss**（上大页）还是 **shootdown**（冻结映射）？

**降频**
- [ ] 确认过 CPU 型号是否属于会降频的世代？
- [ ] 热路径二进制 `objdump | grep zmm` 结果为 0（若目标世代会降频）？
- [ ] `-mprefer-vector-width` 只作用于热路径 target，未殃及冷路径吞吐？
