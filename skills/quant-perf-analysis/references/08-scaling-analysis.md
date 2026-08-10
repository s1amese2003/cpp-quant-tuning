# 多核扩展性分析（Scaling Analysis）

当加线程不加吞吐、甚至吞吐下降时，单次 perf 看热点是不够的。瓶颈函数在单核时可能完全不突出，只在多核时爆炸。

---

## Scaling Sweep 完整流程

### Step 1: 确认多线程

```bash
ldd <binary> | grep -E 'libpthread|libgomp|libtbb|libomp'
grep -r 'pthread_create\|std::thread\|OMP_NUM_THREADS\|#pragma omp' <src> 2>/dev/null | head -5
```

如果二进制不链接任何线程库且源码无多线程 API → 扩展性问题不适用，跳过。

### Step 2: 跑 Sweep

核数序列：1, 2, nproc/4, nproc/2, nproc（去重）。

**每个核数跑两次**——一次测纯吞吐（不加 perf），一次带 perf record（开销会歪曲吞吐数）：

```bash
# 吞吐
taskset -c 0-<N-1> <command> 2>&1 | grep -E '<metric_pattern>'

# 锚点的 perf record（只收集 1核、N/2、N 三个锚点）
taskset -c 0 perf record -g -o perf_1core.data -- <command>
taskset -c 0-<half-1> perf record -g -o perf_halfcore.data -- <command>
taskset -c 0-<N-1> perf record -g -o perf_ncore.data -- <command>
```

如果在相邻两点间 scaling factor 骤降（< 0.80/核），插入中点重新测试。

### Step 3: 格式化 Sweep 表

| Cores | Score | Score factor | Scaling factor |
|-------|-------|-------------|----------------|
| 1     | 12.3  | 1.00×       | —              |
| 2     | 22.1  | 1.80×       | 0.90×/core     |
| 5     | 48.6  | 3.95×       | 0.79×/core     |
| 10    | 67.2  | 5.46×       | 0.55×/core     |
| 20    | 71.0  | 5.77×       | 0.29×/core     |

- **Score factor** = Score(N) / Score(1)
- **Scaling factor** = (Score(N) − Score(prev)) / (N − prev) / Score(1)

找到 **scaling factor 首次跌破 0.80** 的拐点——这是 Phase 1 双剖面的目标核数。

如果 1-vs-N 吞吐比 < 1.05（不到 5% 改善），负载几乎确定不是多线程的，停止分析。

---

## 双剖面对比（Dual-Profile）

### Step 1: 提取 Top-15

```bash
perf report -i perf_1core.data --stdio --no-children -n \
    --sort=comm,dso,sym 2>/dev/null \
    | grep -E '^\s+[0-9]+\.[0-9]+%' | head -15 > top15_1core.txt

perf report -i perf_ncore.data --stdio --no-children -n \
    --sort=comm,dso,sym 2>/dev/null \
    | grep -E '^\s+[0-9]+\.[0-9]+%' | head -15 > top15_ncore.txt
```

### Step 2: Delta 表

并排对比，标注跳变函数（**加粗**）：

| N-core rank | Function | N-core % | 1-core rank | 1-core % | Rank Δ | % Δ |
|-------------|----------|----------|-------------|----------|--------|-----|
| **1** | **`spin_lock`** | **12.3%** | **8** | **2.1%** | **▲7** | **+10.2%** |
| 2 | `compute` | 8.5% | 5 | 6.2% | ▲3 | +2.3% |

### Step 3: 跳变函数阈值（满足任一即可）

| 条件 | 阈值 |
|---|---|
| 排名上升 | ≥ 3 位 |
| 占比倍率 | ≥ 2× |
| 绝对占比增加 | ≥ 3 个百分点 |
| 新进入 top15 | 占比 ≥ 2%（对比方 top15 中不存在） |

### 中点剖面（当跳变函数过多时）

如果 1-vs-N delta 中出现 > 7 个跳变函数，用 N/2 核作为新 baseline：

```bash
HALF=$(( $(nproc) / 2 ))
taskset -c 0-$((HALF-1)) perf record -g -o perf_mid.data -- <command>
# 对比 N 核 vs N/2 核，过滤掉低核噪声
```

---

## 聚焦 c2c + 瓶颈分类

### Step 1: 收集 c2c

```bash
perf c2c record -g -- <command>
perf c2c report --full-symbols --stdio --double-cl > c2c_report.txt
```

### Step 2: 过滤到跳变函数

只保留 accessor 函数匹配 jumpers 的 cache line。忽略其余——目标是关联扩展瓶颈到具体 cache line。

### Step 3: 瓶颈分类表

| 模式 | 信号 | 修复策略 |
|------|------|---------|
| **False sharing** | 同一 cache line 上不同 offset 被不同线程写 | `alignas(64)` 隔离字段 |
| **cmpxchg / TAS spin** | `lock cmpxchg` 在循环内；函数名含 spin_lock/mutex/cas | TTAS（先 load 再 CAS） |
| **真共享 — 统计计数** | `lock add/inc` 在计数器上；字段名含 count/total/hits | Per-thread 累加，结束时合并 |
| **真共享 — 数据** | 同 offset 多线程读写；非计数器、非锁 | 原子操作/RCU/更细锁粒度/RW 锁 |
| **无 c2c 信号** | 跳变函数不出现在 c2c hot lines | 回退到 compute/branch 分析 |

---

## 迭代

多个瓶颈几乎总是同时存在。修完一个后回到 Phase 1 重新采集——第一个瓶颈会掩盖后面的。

**不要假设第一轮的跳变列表在第二轮仍然有效**：函数的排序可能完全改变。

迭代终止条件：无函数超过跳变阈值，或扩展性已可接受（scaling factor 接近 1.0/核）。

### 迭代完成后

如果最初跑了 sweep，在优化后的二进制上重跑完整的 sweep，生成对比报告：

| Cores | Score (baseline) | Score (optimized) | Improvement |
|-------|-----------------|-------------------|-------------|
| 1     | 12.3            | 18.1              | +47%        |
| 20    | 71.0            | 148.2             | +109%       |
