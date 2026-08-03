---
name: quant-perf-analysis
description: 交易系统的性能测量与瓶颈定位 — Roofline 模型判定 memory-bound/core-bound、TMA 自顶向下分析、perf 事件采样、编译器优化选项与内建函数、检查生成的汇编、静态/动态链接、特殊硬件指令、基于 rdtsc/TSC 的时钟周期级延迟测量、交易系统性能指标(tick-to-trade、p99.9、抖动)。Use for perf, profiling, TMA, roofline, IPC, cache-misses, branch-misses, benchmark, latency measurement, rdtsc, TSC, percentile, p99, jitter, 火焰图, 汇编, compiler flags, godbolt, PGO, LTO, 性能瓶颈, 延迟测量, or before/after any optimization to prove it worked.
license: CC-BY-4.0
metadata:
  version: "1.0.0"
  source: "trading-system-notes-Chinese.md 《交易系统开发》张智炫"
---

# 性能测量与瓶颈定位（Performance Analysis）

**没有测量的优化是猜测。** 本 skill 提供从"整机噪声"到"具体汇编指令"的完整定位链路。

前置条件：系统层已静默（`quant-system-tuning`），否则测量结果是噪声。

---

## 1. 交易系统该测什么

通用服务看吞吐和平均延迟；交易系统**只有尾延迟和抖动有意义**。

| 指标 | 含义 | 说明 |
|---|---|---|
| **tick-to-trade** | 网卡收到行情 → 网卡发出报单 | 最终指标；用硬件时间戳（`SO_TIMESTAMPING`）或交换机镜像口测才准确 |
| 分段延迟 | 解包 / 簿更新 / 信号 / 风控 / 序列化 / 发送 | 用 TSC 打点，定位是哪一段 |
| **p99.9 / p99.99 / max** | 尾延迟 | **首要优化目标**，平均值几乎无用 |
| jitter | p99 − p50 | 确定性的度量 |
| 吞吐（msg/s） | 峰值承载 | 只用来确认不会在开盘瞬间崩，不是优化目标 |

**报告格式要求**：永远给 `p50 / p99 / p99.9 / max + 样本数 + 硬件与内核配置`，不要只给一个数字。

> 参考：`references/05-trading-perf-metrics.md`

---

## 2. 延迟测量：TSC 打点

```cpp
static inline uint64_t rdtscp_now() noexcept {
    unsigned aux;
    return __rdtscp(&aux);          // 有序化，包含 CPUID 之外的 load fence 语义
}
```

要点：
- 用 `rdtscp`（或 `lfence; rdtsc`）而非裸 `rdtsc`，否则乱序执行会让打点漂移。
- 必须确认 CPU 有 `constant_tsc` + `nonstop_tsc`（`grep -o 'constant_tsc\|nonstop_tsc' /proc/cpuinfo`），否则频率变化会让 TSC 不可比 —— 这也是必须锁频的原因之一。
- **测量开销本身**：先测空测量循环的开销（通常 20~30 cycles）并从结果中扣除。
- cycles → ns 换算：用一次校准（对比 `clock_gettime(CLOCK_MONOTONIC)` 跑 1 秒）得到 TSC 频率，不要用标称主频。
- **不要在热路径上做 `printf` 或直接算百分位**。打点只写入预分配的环形数组（`uint64_t`），交易结束后离线统计。
- 跨核比较时间戳要小心 TSC 同步（同 socket 通常同步，跨 socket 不保证）。

> 参考：`references/06-latency-measurement-cycles.md`

---

## 3. Roofline：先分类，再动手

```
算术强度 I = 浮点运算数 / 访存字节数   (FLOP/Byte)
性能上界 = min(峰值算力, I × 内存带宽)
```

- **落在斜坡上 → memory-bound**：提高算术强度（数据压缩、SoA、分块复用）、改善局部性、上大页、预取。加更多 SIMD 没用。
- **落在平台上 → core-bound**：减少指令数（内联、强度削弱）、提高 ILP（多累加器、打断依赖链）、向量化。
- **离屋顶越远，优化空间越大**。

交易系统的现实：热路径通常是 **memory-bound + 分支密集**，而不是 FLOP 密集。因子批量计算、回测才可能 core-bound。所以先查 cache/TLB，再谈 SIMD。

> 参考：`references/01-roofline-model.md`

---

## 4. TMA：自顶向下定位

Roofline 说"大方向"，TMA 说"具体是哪一层"。

```
              Slots
       ┌────────┴────────┐
   Retiring          Not Retiring
                  ┌──────┴──────┐
            Front-End Bound   Bad Speculation / Back-End Bound
                                       ┌──────┴──────┐
                                 Core Bound      Memory Bound
                                                 (L1/L2/L3/DRAM/Store)
```

```bash
perf stat --topdown -a -C 8 sleep 10          # 一级分类
perf stat -e cycles,instructions,branch-misses,cache-misses,\
LLC-load-misses,dTLB-load-misses,stalled-cycles-frontend,stalled-cycles-backend ./app
```

对应处方：

| TMA 类别 | 常见成因（交易场景） | 处方 |
|---|---|---|
| Front-End Bound | 代码体积大、I-cache miss、内联过度 | 减少内联、冷代码 `__attribute__((cold))` 移出、缓存预热 |
| Bad Speculation | 数据依赖的价格/方向分支 | `quant-latency-core` 第 3 节 |
| Core Bound | 长依赖链（链表遍历）、除法、端口竞争 | 多累加器、强度削弱、扁平化数据结构 |
| Memory Bound | cache miss、TLB miss、false sharing | 数据布局、大页、预取、`alignas(64)` |
| Retiring 高但仍慢 | 就是指令太多 | 算法层面减少工作量 |

**注意**：TMA 不适用于本身有严重缺陷的代码（会指向错误方向）；先把明显问题（O(n²)、每 tick 分配）修掉再用。

> 参考：`references/02-tma-methodology.md`

---

## 5. 常用 perf 配方

```bash
# 热点函数
perf record -F 999 -g --call-graph=dwarf -- ./app && perf report --stdio

# 精确到源码行/指令
perf annotate -s hot_function

# 缓存行竞争 / false sharing（最有价值的交易系统诊断之一）
perf c2c record -a -- sleep 10 && perf c2c report

# 调度噪声（隔离是否生效）
perf sched record -- sleep 5 && perf sched latency

# 系统调用（热路径上不该有）
perf trace -p <PID>
strace -c -p <PID>
```

`perf c2c` 找 HITM（跨核 cache line 争抢）能直接暴露无锁队列里的 false sharing，值得优先跑。

---

## 6. 编译器

### 基线选项

```
-O3 -march=native -mtune=native -fno-plt -fno-semantic-interposition
-flto -fno-exceptions -fno-rtti        # 视项目约束
-g -fno-omit-frame-pointer             # 保留符号与栈回溯，方便 perf
```

- **`-ffast-math` 默认禁用**。它允许浮点重排，会破坏金额/PnL 的可复现性。若确需，只在特定信号计算函数上用 `#pragma GCC optimize` 局部开启，并加数值一致性测试。
- `-march=native` 生成的二进制不能跨机器；生产用统一的目标微架构（如 `-march=skylake-avx512`）或运行时分派。
- **PGO**：交易系统收益明显（分支布局按真实行情分布优化）。流程：`-fprofile-generate` → 用**真实回放行情**跑 → `-fprofile-use`。用合成数据做 PGO 会适得其反。
- **静态链接**优于动态：消除 PLT 间接跳转、避免运行时符号解析、启动即确定。代价是二进制大、安全补丁要重编。交易系统通常选静态。

### 诊断

```bash
g++ -O3 -march=native -fopt-info-vec-missed -fopt-info-inline-missed ...   # 为什么没优化
g++ -S -masm=intel -O3 foo.cpp -o -                                        # 看汇编
objdump -d --no-show-raw-insn -M intel binary | less
```

**关键纪律**：任何"我以为编译器会内联/向量化/消除这个"的判断，都必须去 Compiler Explorer 或 `objdump` 确认。编译器经常因为别名、异常路径、`volatile` 而放弃你以为的优化。

> 参考：`references/03-compiler-optimization.md`、`references/04-special-hardware-instructions.md`

---

## 7. 基准测试模板

热路径基准的最小要求：

```
1. 输入是真实/回放行情，不是随机数（分支分布完全不同）
2. 绑核 + SCHED_FIFO + 预热（至少 10k 次迭代丢弃）
3. 用 TSC 记录每次迭代，存到预分配数组
4. 离线算 p50/p99/p99.9/max
5. 用 benchmark::DoNotOptimize / asm volatile("" ::: "memory") 防止被优化掉
6. 交替运行 A/B 版本（interleaved），消除机器状态漂移
7. 至少重复 3 轮，报告轮间方差
```

**第 6 条常被忽略**：先跑完 A 再跑 B 会把机器温度/频率漂移算进结论。

---

## 8. 检查清单

- [ ] 系统噪声已消除（`cyclictest` 达标）？
- [ ] 报告的是 p99.9 而不是平均值？
- [ ] TSC 是 constant + nonstop，频率已校准？
- [ ] 测量开销已扣除？
- [ ] 先跑了 `perf stat --topdown` 分类，而不是直接猜？
- [ ] 跑过 `perf c2c` 排查 false sharing？
- [ ] 关键函数的汇编亲眼看过？
- [ ] 基准用的是真实行情回放？A/B 交替执行？

---

## references/ 索引

| 文件 | 内容 |
|---|---|
| `01-roofline-model.md` | Roofline 模型、Memory Bound / Core Bound 优化 |
| `02-tma-methodology.md` | TMA 自顶向下分析方法 |
| `03-compiler-optimization.md` | 编译器选项、提示、内建函数、看汇编、静态/动态链接 |
| `04-special-hardware-instructions.md` | 特殊硬件指令 |
| `05-trading-perf-metrics.md` | 交易系统性能衡量的核心要点 |
| `06-latency-measurement-cycles.md` | 延迟测量（时钟周期） |
| `07-system-design-articles.md` | 系统设计优质文章索引 |
