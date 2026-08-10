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

## 9. 多核扩展性分析（Scaling Analysis）

当加线程不加吞吐、甚至吞吐下降时，需要系统化的扩展性诊断。**单次 perf 看热点是不够的**——瓶颈函数在单核时可能完全不突出，只在多核时爆炸。

### 流程总览

```
Phase 0: 线程检测 + scaling sweep（可选）→ 找到拐点
Phase 1: 双剖面对比（1 核 top15 vs N 核 top15）→ 识别"跳变函数"
Phase 2: 跳变函数源码 + 内联判断
Phase 3: 聚焦 c2c（只看跳变函数涉及的 cache line）
Phase 4: 瓶颈分类 → 对应修复策略
Phase 5: 应用修复
Phase 6: 迭代（修完一个再跑一次——前一个瓶颈会掩盖后面的）
```

### Phase 0: 线程检测

```bash
ldd <binary> | grep -E 'libpthread|libgomp|libtbb|libomp'
grep -r 'OMP_NUM_THREADS\|pthread_create\|std::thread\|#pragma omp' <src> 2>/dev/null | head -5
```

如果无线程库且源码无多线程 API，跳过本 section —— 扩展性问题不适用。

### Phase 0b: Scaling Sweep

线程数 1, 2, N/4, N/2, N 各跑一次测吞吐，同时为 1 核、N/2、N 收集 `perf record`：

```bash
# 每个核数的吞吐
taskset -c 0-<N-1> <command> 2>&1 | grep -E '<metric>'

# 锚点 perf record（吞吐测量与 record 分开跑，perf record 有开销）
taskset -c 0 perf record -g -o perf_1core.data -- <command>
taskset -c 0-<half-1> perf record -g -o perf_halfcore.data -- <command>
taskset -c 0-<N-1> perf record -g -o perf_ncore.data -- <command>
```

**Sweep 表格式**：

| Cores | Score | Score factor | Scaling factor |
|-------|-------|-------------|----------------|
| 1     | 12.3  | 1.00×       | —              |
| 2     | 22.1  | 1.80×       | 0.90×/core     |
| N     | 71.0  | 5.77×       | 0.29×/core     |

- **Score factor** = Score(N) / Score(1)
- **Scaling factor** = (Score(N) − Score(prev)) / (N − prev) / Score(1)
- 找到 **scaling factor 首次跌破 0.80** 的拐点，作为 Phase 1 目标核数。

1-vs-N 吞吐比 < 1.05（改善不到 5%）→ 负载几乎确定不是多线程的，不要继续本 flow。

### Phase 1: 双剖面对比

```bash
perf report -i perf_1core.data --stdio --no-children -n \
    --sort=comm,dso,sym 2>/dev/null \
    | grep -E '^\s+[0-9]+\.[0-9]+%' | head -15 > top15_1core.txt

perf report -i perf_ncore.data --stdio --no-children -n \
    --sort=comm,dso,sym 2>/dev/null \
    | grep -E '^\s+[0-9]+\.[0-9]+%' | head -15 > top15_ncore.txt
```

并排输出为 delta 表：

| N-core rank | Function | N-core % | 1-core rank | 1-core % | Rank Δ | % Δ |
|-------------|----------|----------|-------------|----------|--------|-----|
| **1** | **`spin_lock`** | **12.3%** | **8** | **2.1%** | **▲7** | **+10.2%** |
| 2 | `some_func` | 8.5% | 5 | 6.2% | ▲3 | +2.3% |

**跳变函数（Jumper）识别阈值**（满足任一即标记）：

| 条件 | 阈值 |
|---|---|
| 排名上升 | ≥ 3 位 |
| 占比倍率 | ≥ 2× |
| 绝对占比增加 | ≥ 3% |
| 新进入 top15 | 占比 ≥ 2%（原 top15 中不存在） |

**如果跳变函数超过 ~7 个**：用中点剖面（N/2 vs N 对比）替代 1 vs N，过滤掉低核噪声，保留高核区真正的瓶颈。

### Phase 3 & 4: 聚焦 c2c + 瓶颈分类

对跳变函数涉及的 cache line 做 `perf c2c`（见第 11 节），只保留访问函数匹配 jumpers 的 cache line。然后分类：

| 模式 | 信号 | 修复策略 |
|---|---|---|
| **False sharing** | 同一 cache line 上不同 offset 被不同线程写 | `alignas(64)` 隔离字段 |
| **cmpxchg / TAS spin** | `lock cmpxchg` 在循环内 + 函数名含 spin_lock/mutex | TTAS（见 `quant-lockfree-ipc` 第 5 节） |
| **真共享 — 统计计数** | `lock add/inc` 在计数器 + 同 offset + 字段名含 count/total/hits | Per-thread 累加（见 `quant-latency-core` 数据布局） |
| **真共享 — 数据** | 同 offset 多线程读写 + 非计数器 | 原子操作/RCU/更细锁粒度 |
| **无 c2c 信号** | 跳变函数不出现在 c2c hot lines | 回到第 5 节做 compute/branch 分析 |

### Phase 6: 迭代

**多个瓶颈几乎总是同时存在。** 修完一个后回到 Phase 1 重新采集双剖面——第一个瓶颈会掩盖后面的。函数排序可能改变，不要假设第一轮的列表仍然有效。重复直到无函数超过跳变阈值或扩展性可接受。

> 参考：`references/08-scaling-analysis.md`

---

## 10. Annotate 模式扫描

`perf annotate` 的输出包含丰富的性能反模式信号。对任何 ≥ 20% 的热点函数，按以下清单**系统扫描**其汇编输出：

```bash
perf annotate --stdio -l -s <function_name> 2>/dev/null | tee /tmp/annotate_<fn>.txt
```

### 七种模式检查

按顺序逐一检查，一个函数可能匹配多个：

**模式 1: Scalar FP — 完全未向量化**
- 信号：热指令全是 `vaddsd`/`vmulsd`/`vmovsd` 等标量变体，无任何 packed 指令（`vaddpd`/`vmulps`/`vfmadd*ps`）
- 置信度：标量指令 > 50% 且零条 packed → 高
- 最可能的向量化阻断器：**非单位步长的内层循环**（如列优先矩阵访问时 `base + k*stride`），修法是循环重排使最内层步长为 1

**模式 2: Narrow SIMD — 寄存器宽度不足**
- 信号：packed 指令使用 `xmm` 在支持 AVX2/AVX-512 的 CPU 上，或 `ymm` 在支持 AVX-512 上
- 检查 `/proc/cpuinfo` 的 `avx2`/`avx512f` 标志确认 CPU 能力

**模式 3: Serial Accumulator — 串行累加器**
- 信号：单一 FP 指令（`vaddss`/`vaddpd`/`vfmadd213ps`）独占 > 40% 样本，且 IPC ≪ 1 或 cache-miss 率低，或目的寄存器 = 源寄存器形成明显的依赖链
- 修复：并行累加器（4~8 个独立变量后合并）

**模式 4: Horizontal Reduction — 水平归约反模式**
- 信号：`shufps`/`addss`/`unpckhps` 紧跟在 `mulps`/`mulss` 之后（3~5 条指令内），这是编译器将 SIMD 乘法结果做水平归约的特征
- 修复：并行累加器的水平归约变体

**模式 5: Test-and-Set Spin (`lock cmpxchg`)**
- 信号：`lock cmpxchg`/`lock xchg` 出现在循环体内且 > 10% 样本
- 修复：TTAS（先 load 读，不释放才 CAS）

**模式 6: Memory Load Pressure — 内存加载压力**
- 信号：load 指令（`vmovsd`/`vmovups`/`movq`/`vmovdqu`）总和 > 30% 且无明显对应计算
- 可能是 cache miss → 加上 `perf stat` 的 cache-miss 率交叉验证

**模式 7: Atomic Counter Contention — 原子计数竞争**
- 信号：`lock add`/`lock inc`/`lock xadd` 在热路径 > 10%，且无 `cmpxchg` 重试循环（否则属于模式 5）
- 关键区分：如果 `lock add` 后紧跟条件分支检查结果 → 这是用 add 实现的锁 → 归模式 5；如果结果完全被忽略（无分支、无测试）→ 统计计数 → Per-thread 累加

### 输出格式

```
### Pattern scan — `<function_name>`

| Pattern | Evidence | 修复方向 |
|---------|----------|---------|
| Scalar FP | `vaddsd` at 95%; no packed inst | SIMD 上转换 + 检查循环步长 |
| Serial accumulator | `vaddss` 独占 95%, IPC 0.4 | 并行累加器 |
```

无匹配时输出：`No anti-patterns detected.`

> 参考：`references/09-annotate-pattern-scan.md`

---

## 11. c2c 深入：Offset 判别法

`perf c2c` 是定位多线程 cache line 竞争的关键工具，但解读门槛高。核心方法：

### False vs True Sharing：看 Offset 列

在 c2c 报告的 "Shared Cache Line Distribution Pareto" 节，每条 cache line 下每个 accessor 都有一个 **Offset** 列（字节偏移）。

**Offset 是 definitive discriminator——先看它，再看源码：**

- **不同 accessor 的 Offset 不同** → **False sharing**：不同字段落在同一条 cache line 上，线程并非真正共享数据
- **所有 accessor 的 Offset 相同** → **True sharing**：多个线程真正在竞争同一个字段

### 操作步骤

```bash
# 1) 记录（-g 保留调用链用于 Pareto 分析）
perf c2c record -g -- <application>

# 2) 生成报告（--double-cl 匹配硬件预取器 128B 粒度；--full-symbols 防截断）
perf c2c report --full-symbols --stdio --double-cl > c2c_report.txt

# 3) 提取热 cache line 表
grep -A 20 "Shared Data Cache Line Table" c2c_report.txt | \
    grep -v "^#" | grep -v "^=" | grep -E "^\s+[0-9]"
```

关键列：**Index**（0-based，对应 Pareto 节）、**Tot Hitm**（总 HITM 占比）、**LclHitm/RmtHitm**（本地/远端 NUMA）。

默认忽略 Tot Hitm < 5% 的项。

### c2c 报告标注规范

分析结果时，**在结构体定义上标注每个字段的字节偏移**（`/* +0xNN */`），直接对应 c2c 的 Offset 列：

```c
struct order_slot {
    uint64_t order_id;       /* +0x00 */
    int64_t  price;          /* +0x08 */
    int32_t  qty;            /* +0x10 */
    // ← cache line 边界 (64B)
    uint64_t write_seq;      /* +0x40 — 被生产者写 */
    uint64_t read_seq;       /* +0x48 — 被消费者写 ← 与 write_seq 同一行 → false sharing! */
};
```

**在访问代码行上标注读写**：`s->write_seq++;  /* ◄ write */`

**函数显示规则**：
- ≤ 20 行 → 显示完整函数体
- > 20 行 → 显示签名 + 开头上下文 + `...` + 关键行周围 ≥ 3 行上下文 + `...` + 结尾 `}`

> 参考：`references/02-tma-methodology.md` 中也有 c2c 相关内容

---

## 12. 分支概率测量

`[[likely]]`/`__builtin_expect` 只是给编译器的静态提示。要知道**实际运行时**分支的真实概率，需要测量。

### 方法 A: Intel PMU 事件（最准确，仅 Intel CPU）

```bash
# 先确认 Intel CPU
grep -q 'vendor_id.*GenuineIntel' /proc/cpuinfo || echo "NOT Intel"

# 用 BR_INST_RETIRED 事件记录
perf record -c 1000 \
  -e '{BR_INST_RETIRED.NEAR_TAKEN:upp,BR_INST_RETIRED.NOT_TAKEN:upp,cycles:u}' \
  -o /tmp/branch.data ./binary

# annotate 看每个分支的 taken/not-taken 计数
perf annotate --source --no-vmlinux -l -n --stdio -i /tmp/branch.data
```

输出每行列格式：`NEAR_TAKEN  NOT_TAKEN  CYCLES :  ADDR:  MNEMONIC`

**计算每个条件跳转的 taken%**：`taken% = 100 × NEAR_TAKEN / (NEAR_TAKEN + NOT_TAKEN)`

### Macrofusion 修正

x86 上 `cmp`/`test` 可能与后续条件跳转融合为一个微操作，此时 PMU 把计数归到 `cmp` 而非跳转指令。解决办法：找到紧邻条件跳转前、有非零计数但本身非跳转的指令，把计数搬到跳转指令上。

### 结果解读

| Taken% | 含义 |
|-------|------|
| < 0.1% | 强冷分支 → 被调用的函数应标 `[[gnu::cold]]` |
| ~50% | 不可预测 → 考虑 `cmov` 消除分支 |
| > 99.9% | 强热分支 → `[[likely]]` 确认 |

将结果按 sample 数降序排列输出表格（每行一个分支、taken%、源码行、跳转目标、汇编助记符）。

### 方法 B: GCC 静态估计（无 workload 时，跨平台）

如果不方便跑 workload（或非 Intel CPU），取 GCC 编译期估计作为代理：

```bash
# 编译时加这两个 flag
gcc -g -fdump-tree-profile_estimate-lineno -dumpdir dump/ foo.c -o foo

# 查看 dump 文件
ls dump/*.profile_estimate
```

dump 内容示例：
```
[foo.c:11:8] if (_2 == 0)
  goto <bb 3>; [50.00%]
else
  goto <bb 5>; [50.00%]
```

`[X.XX%]` 是 GCC 的估计概率。**与 perf 实测对比**可发现编译器判断错误的分支——那些是 `[[likely]]`/`[[unlikely]]` 标注的最大收益点。

| 情况 | 含义 |
|---|---|
| GCC 热 / perf 冷 | 编译器误判 → 标 `[[unlikely]]` 或 `[[gnu::cold]]` 收益大 |
| GCC 冷 / perf 热 | 需要 `[[likely]]` |
| GCC ~50/50 / perf 强偏 | 数据依赖行为，编译器看不出来 → 必须手动标注分支提示或 `cmov` |

> 参考：`references/10-branch-probability.md`

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
| `08-scaling-analysis.md` | 多核扩展性分析：sweep、双剖面对比、跳变函数识别与迭代 |
| `09-annotate-pattern-scan.md` | Annotate 模式扫描：7 种汇编反模式的信号、置信度与修复方向 |
| `10-branch-probability.md` | 分支概率测量：Intel PMU 事件与 GCC 静态估计 |
