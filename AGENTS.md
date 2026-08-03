# 量化开发 Agent 指令（AGENTS.md）

> 本文件是**跨工具的 skills 入口**。Codex CLI、Cursor、Windsurf、Cline、Amp、Jules 等读取 `AGENTS.md` 的
> agent 工具会自动加载本文；Claude Code 通过 plugin 机制加载 `skills/`，两条路径指向同一批内容。

## 0. 全局前提

**所有代码编写、评审与调优都以量化交易开发为背景。** 默认目标函数不是"平均吞吐"，而是：

```
正确性 > 确定性（p99.9 抖动）> 中位延迟 > 吞吐 > 开发便利性
```

任何用左边换右边的建议，必须显式说明并让用户确认。

默认平台：**Linux x86-64 / C++20 / GCC 或 Clang**。笔记中大量系统配置（isolcpus、cpuset、hugepages、
SCHED_FIFO、perf）是 Linux 专有 —— 在 Windows/macOS 上工作时必须显式标注哪些建议不适用。

## 1. 使用方式（给 agent 的操作指令）

1. **任何量化相关任务开始时，先读 `skills/quant-dev-playbook/SKILL.md`。** 它给出路径判定
   （热/温/冷）、热路径硬性禁令、优化工作流与路由表。
2. 按第 2 节的路由表，**只加载当前任务需要的那一两个 `SKILL.md`**，不要一次读完全部。
3. 需要具体实现细节、完整代码或原始论述时，再按该 SKILL.md 末尾的 `references/` 索引读取对应文件。
   `references/` 是原始笔记的逐字副本，体量大，**按需读取，不要整目录加载**。
4. `commands/*.md` 是可直接复用的工作流提示词（优化、评审、设计、基准、调机），
   在 Claude Code 中是 slash command，在 Codex 中可放入 `~/.codex/prompts/`，
   在其他工具中可直接复制其正文作为提示词。

## 2. 路由表

| 任务类型 | 加载 |
|---|---|
| **入口/不确定时** | `skills/quant-dev-playbook/SKILL.md` |
| 热路径 C++ 微优化：数据布局、cache、分支、内联、模板/CRTP、循环、指针别名、传参、位运算 | `skills/quant-latency-core/SKILL.md` |
| 内存池、大页、TLB、预取、缓存预热、SIMD/向量化 | `skills/quant-memory-simd/SKILL.md` |
| 无锁队列、SPSC/SPMC、共享内存 IPC、内存序、双缓冲、自旋锁、wait-free、协程、socket | `skills/quant-lockfree-ipc/SKILL.md` |
| CPU 亲和/NUMA、核隔离、实时优先级、中断绑定、C-State、内核与 BIOS 调优 | `skills/quant-system-tuning/SKILL.md` |
| perf、TMA、Roofline、编译选项、看汇编、rdtsc 延迟测量、性能指标 | `skills/quant-perf-analysis/SKILL.md` |
| 行情数据管道、流归并、依赖 DAG、csv↔binary、增量计算、高频数据清洗、盯市 | `skills/quant-market-data/SKILL.md` |
| 订单簿、OMS/EMS/PMS/RMS、FIX、撮合、K线、SOR、限流、自成交保护、协议与序列一致性 | `skills/quant-trading-systems/SKILL.md` |
| 收益率、波动率状态、因子评估、正则化模型、参数寻优、置换检验、做市、定点数 | `skills/quant-strategy-math/SKILL.md` |
| Uniswap v2/v3、CEX 订单簿、三角套利、永续合约、crypto 监控 | `skills/quant-crypto-systems/SKILL.md` |

跨领域任务按 **数据 → 系统 → 延迟 → 验证** 串联。
例："做一个低延迟订单簿" = `quant-trading-systems`（结构选型）+ `quant-latency-core`（布局与分支）+ `quant-perf-analysis`（验证）。

## 3. 不读 skill 也必须遵守的底线

即使没有加载任何 SKILL.md，在本仓库语境下产出的量化代码必须满足：

- **价格、数量、金额用定点整数**，不用 `double`。
- **时间戳统一为 int64 纳秒**，并标明来源（交易所 / 本地 / 硬件时间戳）。
- **热路径（tick-to-trade）上禁止**：`new`/`malloc`、异常、RTTI、虚函数分派、`std::function`、
  `std::string`/`std::map`/`std::unordered_map`、互斥锁、同步 I/O、字符串格式化。
- **生产者与消费者分别写入的变量必须 `alignas(64)` 隔离**（避免 false sharing）。
- **滚动统计用增量算法**；方差用 Welford，不用 `E[x²] − E[x]²`。
- **回测代码不得使用当时拿不到的数据**（未收盘 bar、全样本均值方差、`t+1` 插值）。
- **性能结论必须给 p50/p99/p99.9/max + 样本数 + 硬件与内核配置**，不接受"快了 30%"。
- **不确定状态下 fail-safe**：对账不上、数据陈旧、连接异常时停止开新仓，而不是继续交易。
- 未经测量的性能判断必须**显式标注为未验证**。

## 4. 目录

```
skills/<name>/SKILL.md          # 10 个 skill 的主文件（先读这个）
skills/<name>/references/       # 94 个原始笔记章节，按需读取
commands/*.md                   # 5 个工作流提示词
agents/quant-perf-reviewer.md   # 性能评审 subagent 定义
tools/split-notes.ps1           # 从源笔记重新生成 references/
trading-system-notes-Chinese.md # 源笔记（《交易系统开发》张智炫）
```
