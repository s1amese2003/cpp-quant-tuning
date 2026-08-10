---
name: quant-memory-simd
description: 交易系统的内存管理与向量化 — 内存池/对象池/arena、大页(HugePages/THP)、TLB 优化、缓存预取与预热(__builtin_prefetch)、SIMD 向量化(AVX2/AVX-512、intrinsics、自动向量化诊断)。Use when the task involves memory pool, object pool, arena allocator, 预分配, huge pages, THP, TLB miss, prefetch, cache warming, SIMD, AVX, intrinsics, vectorization, 向量化, batch factor computation, or eliminating malloc/new from a hot path.
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

## 2. 大页（Huge Pages）

订单簿、历史行情缓存、大数组一旦超出 TLB 覆盖范围，每次访问都可能多一次 page walk（数百 cycles）。

**判断是否需要**：`perf stat -e dTLB-load-misses,dTLB-store-misses ./app`。miss 率显著（>1%）或工作集 > 数十 MB 时，上大页。

**两条路径：**

| 方式 | 特点 | 适用 |
|---|---|---|
| **显式 HugeTLB**（`hugetlbfs` / `MAP_HUGETLB`） | 启动时预留，绝不被拆分或换出，行为确定 | 生产交易进程 —— **推荐** |
| **THP（透明大页）** | 内核自动合并，无需改代码 | 开发/回测；生产上 `defrag` 会引入不可预测停顿，通常设为 `madvise` 或 `never` |

生产建议：内核启动参数预留 hugepages（`hugepagesz=2M hugepages=N`），进程用 `mmap(..., MAP_HUGETLB)` 或 `madvise(MADV_HUGEPAGE)` 拿到，且 **NUMA 本地分配**（配合 `quant-system-tuning`）。

同时锁定内存防止换出：`mlockall(MCL_CURRENT | MCL_FUTURE)`。

> 参考：`references/02-huge-pages.md`

---

## 3. 预取与缓存预热

### 显式预取 `__builtin_prefetch(addr, rw, locality)`

只在**能提前足够多周期、且硬件预取器无法识别的访问模式**下有效：

- ✅ 有效：遍历一个索引数组去随机访问订单表 —— 提前预取下 N 个目标。
- ✅ 有效：处理消息批时预取下一条消息的头部。
- ❌ 无效：顺序遍历数组（硬件预取器已经做了，显式预取只会浪费指令槽）。
- ❌ 有害：预取距离过近（数据还没到就用了）或过远（被驱逐）。典型有效距离 8~32 个元素，**必须实测调参**。

### 缓存预热（cache warming）

交易系统特有技巧：在等待行情的空闲期，周期性地"空跑"一遍报单路径（不真正发单），把代码（I-cache）、跳转预测器、数据结构（D-cache）、以及网卡发送队列保持在热状态。否则第一笔真实报单会承受几十 μs 的冷启动惩罚。

实现要点：用一个 `if (dry_run) return;` 在最后一步拦截，保证前面所有代码路径真实执行；预热频率高于 cache 驱逐周期（通常 ms 级）。

> 参考：`references/03-prefetch-warmup-vectorization.md`

---

## 4. SIMD 向量化

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
- AVX-512 在部分 Intel 型号上触发降频，对**混合负载**的交易机器可能净亏；实测整机延迟而非单函数吞吐。
- 混用 AVX 与 SSE 代码时注意 `_mm256_zeroupper()`，否则有状态切换惩罚。
- 尾部处理（n 不是向量宽度整数倍）用标量循环或掩码指令，别忘了写测试。
- 数据要对齐到向量宽度（32B/64B）才能用 `load_ps` 而非 `loadu_ps`；用 `alignas(64)` 或对齐分配器。

### 4a. CPU 运行时分派

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

---

## 5. 检查清单

- [ ] 热路径上 `perf stat -e page-faults` 在稳态下为 0？
- [ ] 所有池/缓冲区在启动时预分配并 touch 过？
- [ ] `mlockall` 已调用，`vm.swappiness=0`？
- [ ] dTLB miss 率是否证明需要大页？大页是否 NUMA 本地？
- [ ] 池耗尽的处理是"背压/告警"而不是"fallback 到 malloc"？
- [ ] 显式预取的距离经过实测调参，而不是拍脑袋？
- [ ] 向量化前先看了 `-fopt-info-vec-missed`？
- [ ] SIMD 版本有与标量版本的一致性测试（含尾部与边界）？

---

## references/ 索引

| 文件 | 内容 |
|---|---|
| `01-memory-pool.md` | 内存池实现与设计 |
| `02-huge-pages.md` | 大页内存 |
| `03-prefetch-warmup-vectorization.md` | 缓存预取、预热与向量化 |
| `04-cpu-dispatch.md` | CPU 运行时分派：target_clones 与 __builtin_cpu_supports |
