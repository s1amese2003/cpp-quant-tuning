---
name: quant-memory-simd
description: 交易系统的内存管理与向量化 — 内存池/对象池/arena、大页(HugePages/THP)、消除小缺页(pre-faulting/mallopt/mlockall)、TLB 优化与 TLB shootdown 规避、缓存预取与预热(__builtin_prefetch、dry-run warming)、SIMD 向量化(AVX2/AVX-512、intrinsics、自动向量化诊断)与 AVX 降频规避。Use when the task involves memory pool, object pool, arena allocator, 预分配, huge pages, THP, page fault, minor fault, 缺页, pre-fault, mlockall, mallopt, TLB miss, TLB shootdown, IPI, INVLPG, numa_balancing, prefetch, cache warming, 缓存预热, SIMD, AVX, AVX-512 downclocking, 降频, mprefer-vector-width, intrinsics, vectorization, 向量化, batch factor computation, or eliminating malloc/new from a hot path.
license: CC-BY-4.0
metadata:
  version: "1.0.0"
  source: "trading-system-notes-Chinese.md 《交易系统开发》张智炫"
---

# 内存管理与向量化（Memory & SIMD）

热路径上**一次 `malloc` 就可能毁掉整个延迟预算**：glibc malloc 在竞争或需要向内核要页时，尾延迟可达数十 μs。本 skill 处理"把不确定性从内存路径上移除"以及"用 SIMD 榨干计算带宽"两件事。

---

## 1. 内存分配：三层策略

| 层 | 手段 | 适用 |
|---|---|---|
| **零分配** | 全部对象在启动时预分配为定长数组/`std::array`，运行期只做索引 | 订单槽位、价格档、消息 buffer —— 首选 |
| **池化** | 固定大小对象池（free-list）/ arena（bump pointer + 批量释放） | 生命周期不定但类型固定的对象（订单、成交回报） |
| **回退** | 自定义 allocator 包装的 STL 容器 | 温路径；热路径出现即缺陷 |

### 内存池设计要点

- **固定块大小 + free list**：分配/释放都是 O(1) 且无锁（单线程池）或用 CAS（多线程池）。
- **每线程一个池**，避免跨线程释放导致的锁与 false sharing。跨线程释放用回收队列，由拥有者线程批量回收。
- **块大小对齐到 cache line**，池的元数据（free list 头指针）与数据区分离。
- **容量上限即背压信号**：池耗尽不应该 fallback 到 `malloc`（那会引入不可预测延迟），而应触发限流/告警。这是交易系统与通用服务的关键区别。
- **启动时 touch 一遍所有页**（写 0），把缺页中断消耗在启动阶段而非交易时段。

> 参考：`references/01-memory-pool.md`

---

## 2. 消除小缺页错误（Minor Page Faults）

`malloc` 返回时内核**只改了 VMA 记录，没给物理页**。直到第一次真正访问该页才触发缺页异常，由内核找页帧、清零、填页表——**零点几到几微秒**，五级页表比四级更慢。热路径上一次就够打穿 p99.9。

**判定标准：进入交易时段后缺页数非零即问题。** 启动期的缺页是预期的，我们正是要把它赶到那里。

### 检测三件套

```bash
top -H -p <PID>          # 按 f 勾选 vMn 列：本刷新间隔内的 minor fault 增量
perf stat -e page-faults,minor-faults,major-faults -p <PID> -- sleep 10
perf record -e page-faults -g -p <PID> -- sleep 10 && perf report   # ← 定位到代码行
```

第三条最有用：`page-faults` 是软件事件，可以像采样 CPU 周期一样采样，直接给出制造缺页的调用栈。常见意外来源：日志缓冲扩容、`vector` 首次写尾部、线程栈生长、延迟初始化的静态对象。

### 规避：三层

**一层 —— 启动时预分配并逐页写：**

```cpp
auto* p = static_cast<volatile char*>(base);
for (size_t off = 0; off < bytes; off += 4096) p[off] = 0;   // 必须是「写」
```

**只读遍历无效**：Linux 对匿名内存的只读缺页映射到全局共享零页，物理页并没真给你，真正写入时还要再来一次 COW 缺页。这是最常见的假预热。

**二层 —— 让分配器不再把内存还给内核**（必须在任何分配之前调用）：

```c
mallopt(M_MMAP_MAX,       0);   // 大块分配不走 mmap（munmap 还会触发 TLB shootdown，见第 4 节）
mallopt(M_TRIM_THRESHOLD, -1);  // free 后不把 brk 堆还给内核
mallopt(M_ARENA_MAX,      1);   // 单 arena，代价是放弃 glibc 的多线程分配扩展性
```

**三层 —— `mlockall(MCL_CURRENT | MCL_FUTURE)`**：`MCL_FUTURE` 会覆盖之后创建的**线程栈**，这是它最有价值之处。需要 `CAP_IPC_LOCK` 或 `ulimit -l unlimited`。**不要用 `MCL_ONFAULT`**——它只锁已触及的页，正好绕开我们要的效果。

jemalloc（`retain:true,dirty_decay_ms:-1,muzzy_decay_ms:-1`）、tcmalloc、mimalloc 内置了同类开关，比拧 glibc 旋钮直接；但**换分配器不替代"热路径零分配"**。Windows 对应：`VirtualLock` + `VirtualFree(MEM_DECOMMIT)`（不要 `MEM_RELEASE`）。

> 参考：`references/05-latency-tuning-techniques.md` 第 1 节

---

## 3. 大页（Huge Pages）

订单簿、历史行情缓存、大数组一旦超出 TLB 覆盖范围，每次访问都可能多一次 page walk（数百 cycles）。

**判断是否需要**：`perf stat -e dTLB-load-misses,dTLB-store-misses ./app`。miss 率显著（>1%）或工作集 > 数十 MB 时，上大页。

**两条路径：**

| 方式 | 特点 | 适用 |
|---|---|---|
| **显式 HugeTLB**（`hugetlbfs` / `MAP_HUGETLB`） | 启动时预留，绝不被拆分或换出，行为确定 | 生产交易进程 —— **推荐** |
| **THP（透明大页）** | 内核自动合并，无需改代码 | 开发/回测；生产上 `defrag` 会引入不可预测停顿，通常设为 `madvise` 或 `never` |

生产建议：内核启动参数预留 hugepages（`hugepagesz=2M hugepages=N`），进程用 `mmap(..., MAP_HUGETLB)` 或 `madvise(MADV_HUGEPAGE)` 拿到，且 **NUMA 本地分配**（配合 `quant-system-tuning`）。

同时锁定内存防止换出：`mlockall(MCL_CURRENT | MCL_FUTURE)`。

大页把缺页次数除以 512，但单次 fault 要清零整整 2MiB，**更贵**——所以上了大页更要在启动期把页全部预 fault 掉。

> 参考：`references/02-huge-pages.md`

---

## 4. TLB Shootdown：被别人打断

L1/L2/LLC 的跨核一致性由**硬件** MESI 维护；**TLB 没有硬件一致性协议**。某核改了页表项后，内核必须发**处理器间中断（IPI）**通知其他核执行 `INVLPG` 使旧翻译失效——这就是 TLB shootdown。

**危害的本质：你的交易线程可以完全没做过任何内存映射操作，仍然被打断。** 绑核、`SCHED_FIFO`、忙轮询都挡不住 IPI。用户态页表变更的 IPI 按 `mm_cpumask` 发送，因此**多线程进程内部最严重**（所有线程共享 mm）；别的进程改自己的用户页一般不波及你，但内核地址空间变更（页迁移、大页规整、模块加载）是全局的。

**触发源：**

| 显式（你的代码） | 隐式（系统替你做） |
|---|---|
| `munmap`（含 `free` 大块时 glibc 内部调用、`dlclose`） | THP 的 `khugepaged` 合并与大页拆分 |
| `mprotect`（JIT、guard page、部分 GC） | `kcompactd` 与直接内存规整 |
| `madvise(MADV_DONTNEED/MADV_FREE)`（分配器归还内存的标准手段） | 自动 NUMA balancing（采样与迁移两步都触发） |
| | KSM 同页合并、page cache 回写、同机 JVM/Go 的 GC |

**检测：**

```bash
watch -n5 -d "grep TLB /proc/interrupts"    # 按核对比；隔离核那列应基本不动
perf trace -e munmap,mprotect,madvise -p <PID>
```

**必须先分清 TLB miss 和 TLB shootdown**：miss 是自己工作集超出 TLB 覆盖（解法是大页），shootdown 是被别人打断（解法是冻结地址空间）。用错解法没有效果。

**规避**：源码层热/温路径都不调那三个系统调用（"内存池只借不还"的另一半理由）；**启动期把 `mmap`/`dlopen` 做完，交易时段地址空间冻结**（可用 `/proc/self/maps` 的行数与哈希做断言）。系统层见 `quant-system-tuning` 第 6 节。

**与大页的取舍**：大页减少 TLB 压力，但 THP 的动态合并/拆分本身就是 shootdown 源 —— **要大页的收益，不要 THP 的机制**：启动预留 hugetlb + `transparent_hugepage=never`。

> 参考：`references/05-latency-tuning-techniques.md` 第 3 节

---

## 5. 预取与缓存预热

### 显式预取 `__builtin_prefetch(addr, rw, locality)`

只在**能提前足够多周期、且硬件预取器无法识别的访问模式**下有效：

- ✅ 有效：遍历一个索引数组去随机访问订单表 —— 提前预取下 N 个目标。
- ✅ 有效：处理消息批时预取下一条消息的头部。
- ❌ 无效：顺序遍历数组（硬件预取器已经做了，显式预取只会浪费指令槽）。
- ❌ 有害：预取距离过近（数据还没到就用了）或过远（被驱逐）。典型有效距离 8~32 个元素，**必须实测调参**。

### 缓存预热（cache warming）

**问题的本质是不对称**：读行情/更新订单簿每秒执行数万次，**恒热**；信号触发 → 风控 → 序列化 → 发单每天只跑几十到几百次，**每次都冷**。最需要快的那一刻，恰好是这段代码最冷的时候——这是一场"谁先到交易所"的竞速。

冷启动惩罚同时来自好几层：L1i/uop cache（取指停顿）、BTB/分支预测器（每个分支约 15~20 cycles 误预测）、L1d/L2（订单模板、合约表、风控参数全 miss）、iTLB/dTLB（额外 page walk）、网卡 TX 描述符环与 DMA 缓冲。

对策：空闲期用模拟数据周期性"空跑"整条下单路径，只为让它留在缓存里，不产生任何副作用。

```cpp
inline void send_order(const Order& o, bool dry_run) {
    encode(tx_buf_, o);                  // 真实执行
    risk_check(o);                       // 真实执行
    if (dry_run) [[unlikely]] return;    // ← 唯一拦截点，尽可能靠后
    nic_write(tx_buf_, len_);
}
```

**四条决定成败的纪律：**

1. **必须用运行时 flag，不能用编译期分派。** 写成 `template<bool DryRun>` 或 `if constexpr` 会生成两份独立代码，预热热的是 dry-run 那一份，真实发单走的是另一份——I-cache 里热的是错误地址。**这是本 skill 组中唯一明确反对编译期分派的场景。**
2. **拦截点唯一，且必须在自有代码内**——不要进了厂商 SDK 再拦截，对方内部状态机中途返回可能留下不一致，甚至真把包发出去。
3. **预热数据要有真实形状**（真实合约、真实价格档）。价格全填 0 会走到不同分支、触及不同 cache line，预热的是另一条路径。
4. **确认无副作用**：不递增真实序列号、不改订单状态机、不写业务日志、不占用真实 order id。

调参：逐步拉长预热间隔，看第一笔真实报单的 p99 从哪个间隔开始抬头，取该值的一半（经验值 ms 级）。预热本身占用热核，必须在确认没有待处理行情之后再跑。

> 参考：`references/03-prefetch-warmup-vectorization.md`、`references/05-latency-tuning-techniques.md` 第 2 节

---

## 6. SIMD 向量化

### 何时值得

先看 Roofline（`quant-perf-analysis`）：只有 **core-bound 且计算密度足够**时向量化才有收益。memory-bound 的循环向量化后仍然卡在带宽上。

交易场景的典型可向量化点：
- 多档位价格/数量的批量比较与聚合
- 因子批量计算（滚动均值、方差、相关性）
- 行情批解包中的定长字段转换
- 大规模回测中的逐 bar 计算

### 优先级

```
1. 让编译器自动向量化   —— 改数据布局(SoA)、消除别名(__restrict__)、去掉循环内分支与函数调用
2. 用 -fopt-info-vec-missed 看编译器为什么没做，然后针对性修复
3. #pragma omp simd / #pragma GCC ivdep 给提示
4. intrinsics 手写      —— 最后手段
```

**先看诊断再动手**：`g++ -O3 -march=native -fopt-info-vec-missed` 会直接告诉你"因为可能存在别名 / 因为循环次数未知 / 因为有函数调用"而放弃向量化，修这些比手写 intrinsics 划算得多。

### 手写 intrinsics 的纪律

- 用 `-march=native` 会让二进制无法在旧机器上跑；生产上用**运行时 CPU 分派**（`__builtin_cpu_supports("avx512f")`）+ 多版本函数（`__attribute__((target_clones(...)))`）。
- AVX-512 在部分 Intel 型号上触发降频，对**混合负载**的交易机器可能净亏；实测整机延迟而非单函数吞吐（见 6b）。
- 混用 AVX 与 SSE 代码时注意 `_mm256_zeroupper()`，否则有状态切换惩罚。
- 尾部处理（n 不是向量宽度整数倍）用标量循环或掩码指令，别忘了写测试。
- 数据要对齐到向量宽度（32B/64B）才能用 `load_ps` 而非 `loadu_ps`；用 `alignas(64)` 或对齐分配器。

### 6a. CPU 运行时分派

手写 intrinsics 面临一个基本矛盾：编译时 `-march=native` 会让二进制在旧机器上崩，不用又浪费新指令。解决方案是**生成同一函数的多个 ISA 版本，运行时检测 CPU 后选最快的**。

**决策树**：

| 场景 | 机制 |
|------|------|
| 纯 C/C++ 循环，让编译器自动向量化 | **`target_clones`** |
| 手写 `_mm_*`/`_mm256_*` intrinsics 或内联汇编 | **`__builtin_cpu_supports`** |
| 跨编译器 / 非 x86 | `__builtin_cpu_supports`（可移植退化为 `false`） |

#### 机制 A: `target_clones`（编译器驱动）

编译器自动为每个 ISA 级别生成一份函数克隆体，运行时由 IFUNC resolver 选择：

```c
// 前提：函数内不要有手写 intrinsics——target_clones 不会升级已有 intrinsics
// 必须 non-static + noinline（否则 IFUNC 不会被生成）
#ifndef __target_clones
#  ifdef __x86_64__
#    define __target_clones \
         __attribute__((noinline, target_clones("default", "avx2,fma", "avx512f")))
#  else
#    define __target_clones   /* 非 x86 无操作 */
#  endif
#endif

__target_clones
void compute_factor(const float *src, float *dst, int n) {
    // 纯 C 循环——编译器为 avx2、avx512f、default 各生成一份
    for (int i = 0; i < n; i++)
        dst[i] = src[i] * alpha + beta;
}
```

**`target_clones` 的 ISA 字符串**（用特性名，不是微架构级别名！`x86-64-v3`/`x86-64-v4` 在 GCC 的 target_clones 属性中不被接受）：

| Clone 字符串 | 启用 |
|-------------|------|
| `"default"` | 基线（x86-64 上即 SSE2），**必须放最后作为 fallback** |
| `"avx2,fma"` | AVX2 + FMA（Haswell+） |
| `"avx512f"` | AVX-512F（Skylake-X / Ice Lake+） |

#### 机制 B: `__builtin_cpu_supports`（手动分派）

对手写 intrinsics 的多版本函数做显式 dispatch：

```c
typedef void (*compute_func)(const float*, float*, int);

void compute_scalar(const float *src, float *dst, int n) { /* 标量实现 */ }

void compute_avx2(const float *src, float *dst, int n) {
    // __attribute__((target("avx2"))) 确保此函数只用 AVX2 指令
    // 里面可以用 _mm256_* intrinsics
}

void compute_avx512(const float *src, float *dst, int n) {
    // __attribute__((target("avx512f")))
    // 里面可以用 _mm512_* intrinsics
}

// 启动时解析一次，存到函数指针
compute_func resolve_compute(void) {
    if (__builtin_cpu_supports("avx512f"))  return compute_avx512;
    if (__builtin_cpu_supports("avx2"))     return compute_avx2;
    return compute_scalar;
}
```

**关键纪律**：
- 每个 `_mm256_*` 版本的函数必须标注 `__attribute__((target("avx2")))`，`_mm512_*` 版本必须标注 `__attribute__((target("avx512f")))`。否则编译器可能在该函数内生成不支持的指令。
- dispatch 解析只在启动时做一次，存到函数指针或 `std::function`（注意 `std::function` 有间接调用开销——热路径上直接调函数指针）。
- **不要**用 `#ifdef __AVX2__` 做编译期条件编译：这样生成的二进制在非 AVX2 机器上会静默跑标量路径或直接崩。

> 参考：`references/04-cpu-dispatch.md`

> 参考：`references/03-prefetch-warmup-vectorization.md`

### 6b. 意外的 AVX 降频

Skylake-SP ~ Ice Lake-SP 世代执行"重型" AVX（512 位，或 256 位的重型浮点/乘法）会切到更低的 turbo license，**降频数百 MHz 并持续数百 μs ~ 1ms**，期间后续所有代码（包括纯标量的报单序列化）都在低频跑。

**你没主动写 AVX-512 也会中招**——`-O3 -march=native` 下编译器会自作主张把 `memcpy`、结构体拷贝、`std::fill`、小循环甚至字符串比较向量化成 `zmm`/`ymm`。这正是它"毫无征兆"的原因。

```bash
objdump -d -M intel build/app | grep -c zmm                        # 热路径里到底有没有
perf stat -e core_power.lvl1_turbo_license,core_power.lvl2_turbo_license -p <PID> -- sleep 10
```

```
-mprefer-vector-width=128     # 最保守，热路径 TU
-mprefer-vector-width=256     # 通常的安全默认
```

**按 target 分开设，不要全局一刀切**：热路径限宽，冷路径（回测、因子批算）该用 512 就用 512。需要 AVX-512 的批处理放到独立物理核，并注意兄弟超线程会连累你（`quant-system-tuning` 第 2 节）。

**时效性警告**：Ice Lake 之后（Sapphire Rapids/Emerald Rapids）与 AMD Zen4/Zen5 上这个问题已基本消失。**先 `lscpu` 确认型号再决定**——在新机器上无脑加 `-mprefer-vector-width=128`，等于白白放弃一半向量带宽去换一个不存在的问题。

> 参考：`references/05-latency-tuning-techniques.md` 第 4 节、`quant-perf-analysis/references/03-compiler-optimization.md`

---

## 7. 检查清单

**缺页与锁页**
- [ ] 稳态下 `perf stat -e page-faults -p <PID>` 为 0？major fault 恒为 0？
- [ ] 所有池/缓冲区在启动时预分配并**写**过一遍（不是只读遍历——共享零页陷阱）？
- [ ] `mallopt` 三件套在任何分配之前调用？单 arena 的副作用已评估？
- [ ] `mlockall(MCL_CURRENT|MCL_FUTURE)` 成功返回，`vm.swappiness=0`，有 `CAP_IPC_LOCK`？

**TLB**
- [ ] dTLB miss 率是否证明需要大页？大页是否 NUMA 本地？
- [ ] `grep TLB /proc/interrupts` 中隔离核那列基本不动？
- [ ] 分清了当前是 TLB **miss**（上大页）还是 **shootdown**（冻结地址空间）？
- [ ] 交易时段内 `/proc/self/maps` 不再变化？

**池与预取**
- [ ] 池耗尽的处理是"背压/告警"而不是"fallback 到 malloc"？
- [ ] 显式预取的距离经过实测调参，而不是拍脑袋？

**预热**
- [ ] 下单路径有周期性 dry-run，拦截点唯一且靠后？
- [ ] 用的是**运行时 flag** 而非模板/`if constexpr`（否则预热的是另一份代码）？
- [ ] 预热数据是真实形状，且确认无副作用（序列号、状态机、order id）？

**向量化**
- [ ] 向量化前先看了 `-fopt-info-vec-missed`？
- [ ] SIMD 版本有与标量版本的一致性测试（含尾部与边界）？
- [ ] 确认过 CPU 世代是否会 AVX 降频？热路径 `objdump | grep zmm` 结果符合预期？

---

## references/ 索引

| 文件 | 内容 |
|---|---|
| `01-memory-pool.md` | 内存池实现与设计 |
| `02-huge-pages.md` | 大页内存 |
| `03-prefetch-warmup-vectorization.md` | 缓存预取、预热与向量化 |
| `04-cpu-dispatch.md` | CPU 运行时分派：target_clones 与 __builtin_cpu_supports |
| `05-latency-tuning-techniques.md` | 消除小缺页、缓存预热、TLB shootdown、AVX 意外降频（Bakhvalov 12.4） |
