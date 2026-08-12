---
name: quant-dev-playbook
description: 量化交易系统开发的总入口与路由表 — 任何写代码、评审、调优的量化任务都先读这里。Entry point for quantitative trading development: establishes hot-path vs cold-path rules, latency budgets, determinism and fixed-point defaults, then routes to the specialised quant-* skills. Trigger on 量化 / 交易系统 / 低延迟 / 行情 / 订单 / 撮合 / 策略 / 回测 / 调优, or on trading system, HFT, market data, order book, matching engine, execution, tick-to-trade, latency optimization, and on any request to write or optimize C++ that runs inside a trading loop.
license: CC-BY-4.0
metadata:
  version: "1.0.0"
  source: "trading-system-notes-Chinese.md 《交易系统开发》张智炫"
---

# 量化开发总纲（Quant Development Playbook）

本 skill 组的**前提假设**：所有代码编写与调优都发生在量化交易的语境下。因此默认目标函数不是"平均吞吐"，而是**尾延迟 + 确定性 + 正确性**，且三者的优先级是：

> **正确性 > 确定性（p99.9 抖动）> 中位延迟 > 吞吐 > 开发便利性**

任何优化建议如果牺牲了左边去换右边，必须显式说明并让用户确认。

---

## 1. 先分路径，再谈优化

拿到任何一段代码，**第一件事是判定它在哪条路径上**。规则完全不同，用错规则是量化项目里最常见的浪费。

| 路径 | 定义 | 典型代码 | 延迟量级 | 规则 |
|---|---|---|---|---|
| **热路径 / tick-to-trade** | 从收到行情到发出报单的关键链路 | 解包、订单簿更新、信号计算、风控校验、报单序列化、网卡写入 | 100ns ~ 数 μs | 见第 2 节的硬性禁令，逐指令抠 |
| **温路径** | 与热路径共享进程/缓存，但不在关键链路 | 持仓/PnL 更新、参数热加载、心跳、内部对账 | 数 μs ~ ms | 禁止污染热路径的 cache / 抢占热路径的核 |
| **冷路径** | 离线或非交易时段 | 回测、数据落盘、csv↔binary、日报、参数寻优 | 秒 ~ 小时 | 以吞吐、可读性、可复现为准，**不要**在这里做微优化 |

判定不明确时，问一句："这段代码在一次 tick 到报单之间会被执行吗？"

**反模式**：在回测框架里做 `__builtin_prefetch` 和内联汇编；在 tick-to-trade 路径上用 `std::shared_ptr` 和 `std::function`。两者都是把力气用错地方。

---

## 2. 热路径硬性禁令

以下在热路径中默认**禁止**，出现即视为缺陷（除非有实测数据支撑的例外）：

| 禁止 | 原因 | 替代 |
|---|---|---|
| `new` / `malloc` / 容器扩容 | 不可预测的 μs 级停顿、锁、缺页 | 预分配内存池 → `quant-memory-simd` |
| 异常抛出、RTTI、`dynamic_cast` | 展开表查找不可预测 | 错误码 / `std::expected` 风格返回 |
| 虚函数用于分派热点 | 间接跳转 + 无法内联 | CRTP / `std::variant` / 模板 → `quant-latency-core` |
| 互斥锁、条件变量 | 系统调用、优先级反转 | 无锁 SPSC/SPMC 队列、双缓冲 → `quant-lockfree-ipc` |
| 同步 I/O、`printf`、字符串格式化 | 系统调用 + 锁 | 二进制环形日志，冷线程落盘 |
| `std::string` / `std::map` / `std::unordered_map` | 堆分配、指针追逐、cache miss | 定长 buffer、扁平数组、开放寻址 |
| `double` 表示价格/金额 | 累加误差、比较不可靠、不可复现 | 定点整数 → `quant-strategy-math` 第 17 节 |
| `std::chrono::system_clock` 做延迟测量 | 分辨率与开销不足 | `rdtscp` / `TSC` → `quant-perf-analysis` |
| 运行时 `if` 判定不变的配置 | 分支预测污染 | 编译期分派、模板参数 |
| 数据结构跨 cache line、生产者消费者共享行 | false sharing | `alignas(64)` 填充 → `quant-latency-core` |

---

## 3. 优化工作流（不许跳步）

```
1) 定基准   写可复现的延迟基准，记录 p50/p99/p99.9/max，而不是平均值
2) 测量     perf / TMA 定位瓶颈类别（前端 / 后端 / 分支 / 访存）
3) 归因     Roofline 判定 memory-bound 还是 core-bound
4) 改一处   一次只改一个变量
5) 复测     同一基准复测；未达显著改善则回滚
6) 看汇编   关键函数 objdump / Compiler Explorer 确认编译器真的做了你以为的事
```

**没有第 1 步就没有第 4 步。** 如果用户要求"直接优化"而没有基准，先用 30 行代码把基准搭起来（`quant-perf-analysis` 有模板），再动手。

系统层噪声未消除时测出的数字不可信 —— 先过一遍 `quant-system-tuning` 的静默清单，否则 p99 测的是调度器不是你的代码。

### 正确性问题：Sanitizer 优先（硬性规则）

**以下四类问题禁止只靠读代码下结论，必须用 sanitizer 插桩跑出来：**

| 症状 | 工具 | 编译选项 |
|---|---|---|
| 越界、悬垂指针、use-after-free、double free、内存泄漏、偶发段错误 | **ASan** | `-fsanitize=address` |
| 数据竞争、只在多核/高负载出现的不一致、序列号跳变 | **TSan**（单独构建） | `-fsanitize=thread` |
| 读到未初始化内存、字段是垃圾值 | **MSan**（仅 Clang） | `-fsanitize=memory` |
| 有符号溢出（定点价格×数量）、除零、错位对齐、移位越界、`-O0` 对 `-O2` 错 | **UBSan** | `-fsanitize=undefined` |

统一加 `-g -O1 -fno-omit-frame-pointer -fno-sanitize-recover=all`，链接期同样带上。

理由：这四类 bug 的症状与病因在时空上分离，代码审阅只能提出假设、**不能证伪**。因此结论必须引用 sanitizer 的实际输出（栈 + 地址 + shadow 字节 / 冲突访问双栈）；未插桩验证时必须写明"以下是假设"。

两条必须记住的例外：**自定义内存池会让 ASan 失明**（需手动 `__asan_poison_memory_region`）；**插桩构建的延迟数字一律作废**，性能必须回 Release 复测。

完整方法见 `quant-perf-analysis` 第 13 节与 `references/11-sanitizers.md`。

---

## 4. 路由表

按任务类型加载对应 skill（不要一次性全读）：

| 任务 | Skill |
|---|---|
| 写/改热路径 C++：数据布局、分支、内联、模板、循环、位运算、传参 | **`quant-latency-core`** |
| 内存池、大页、对齐分配、预取、SIMD 向量化 | **`quant-memory-simd`** |
| 无锁队列、SPMC 共享内存、双缓冲、自旋锁、wait-free、协程、socket | **`quant-lockfree-ipc`** |
| CPU 亲和、NUMA、隔离核、实时优先级、中断绑定、内核/BIOS 调优 | **`quant-system-tuning`** |
| 性能分析：perf、TMA、Roofline、编译选项、看汇编、rdtsc 延迟测量 | **`quant-perf-analysis`** |
| 正确性诊断：内存错误、数据竞争、未初始化读、UB → Sanitizers 插桩调试 | **`quant-perf-analysis`**（第 13 节） |
| 行情/交易数据处理：流合并、增量计算、csv↔binary、脏数据、时序竞争、盯市 | **`quant-market-data`** |
| 业务组件设计：OMS、订单簿、FIX、撮合、K线、SOR、限流、自成交保护、协议 | **`quant-trading-systems`** |
| 策略与数值：收益率、波动率状态、EMA、正则化模型、参数寻优、置换检验、做市、定点数 | **`quant-strategy-math`** |
| 数字货币：Uniswap v2/v3、CEX 订单簿、三角套利、多因子、监控 | **`quant-crypto-systems`** |

跨领域任务按"数据 → 系统 → 延迟 → 验证"的顺序串联，例如"做一个低延迟订单簿"= `quant-trading-systems`（结构选型）+ `quant-latency-core`（布局与分支）+ `quant-perf-analysis`（验证）。

---

## 5. 交付标准

任何量化代码交付都应附带：

1. **路径标注** —— 这段代码属于热/温/冷路径，以及它的延迟预算。
2. **可复现基准** —— 命令 + 硬件/内核配置 + p50/p99/p99.9/max，而非"快了 30%"。
3. **正确性验证** —— 定点数无溢出、序列号无跳变、边界条件（涨跌停、集合竞价、断线重连、交易所时间戳回退）。
4. **失效模式** —— 队列满、行情断流、报单被拒、时钟回拨时的行为是什么。
5. **未做的取舍** —— 明确说明为可读性/工期放弃了哪些优化。

---

## 6. 语言与工具默认值

- **C++20**，GCC/Clang，`-O3 -march=native -fno-plt`；关闭 `-ffast-math` 除非明确接受浮点重排（金额计算永远不接受）。
- 构建：CMake；基准：Google Benchmark 或自写 rdtsc harness；分析：`perf` + Compiler Explorer。
- 目标平台默认 **Linux x86-64**。笔记中大量配置（isolcpus、cpuset、hugepages、SCHED_FIFO）是 Linux 专有；在 Windows/macOS 上开发时要明确标注哪些建议不适用。
- 策略研究侧允许 Python（pandas/numpy/scipy），但**上线路径必须是 C++**，且两侧要有一致性校验（同一份数据跑出同样的信号）。

---

## 参考资料

所有 `references/` 内容源自《交易系统开发》（张智炫）笔记，见仓库根目录 `trading-system-notes-Chinese.md`。
