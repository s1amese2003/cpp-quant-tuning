---
description: 为指定函数/路径生成低延迟基准测试脚手架（TSC 打点、绑核、预热、百分位统计、A/B 交替）
argument-hint: <要测的函数、文件或路径描述>
---

为 **$ARGUMENTS** 生成延迟基准。

读 `quant-perf-analysis` 的测量纪律，然后产出一个**可直接编译运行**的基准程序，必须满足：

## 硬性要求
1. **TSC 打点**：`__rdtscp`（或 `lfence; rdtsc`），启动时校准 TSC 频率（对比 `CLOCK_MONOTONIC` 跑 1 秒），不要用标称主频。
2. **扣除测量开销**：先测空循环的打点开销并从结果中减去。
3. **预热**：至少 10k 次迭代丢弃，让 I-cache / D-cache / 分支预测器进入稳态。
4. **绑核**：`pthread_setaffinity_np` 绑到可配置的核；可选 `SCHED_FIFO`。提示用户先做 `quant-system-tuning` 的静默配置。
5. **预分配结果数组**：`std::vector<uint64_t>` 提前 `reserve` 并 touch，循环内只写数组，**不做任何 I/O 或统计计算**。
6. **防优化消除**：`benchmark::DoNotOptimize` 或 `asm volatile("" : : "r,m"(x) : "memory")`。
7. **输出百分位**：p50 / p90 / p99 / p99.9 / p99.99 / max / 样本数，单位 ns（同时给 cycles）。**不要输出平均值作为主指标**。
8. **A/B 交替执行**：若有两个实现，交替运行而不是先跑完 A 再跑 B，消除机器状态漂移；重复至少 3 轮并报告轮间方差。
9. **真实输入**：优先用回放行情/真实数据文件；只能用合成数据时**在输出里显著标注**，因为合成数据的分支分布不真实。

## 同时产出
- 编译命令（`-O3 -march=native -g -fno-omit-frame-pointer`）
- 运行前的环境检查脚本：`constant_tsc`/`nonstop_tsc` 是否存在、governor 是否 performance、目标核是否隔离
- 配套的 `perf stat` 命令行
- 结果记录模板（硬件型号、内核版本、编译器版本、内核启动参数、日期）

## 平台说明
基准脚手架默认 **Linux x86-64**。如果当前是 Windows/macOS 开发环境，明确告知用户哪些部分（绑核、`SCHED_FIFO`、`perf`）需要在 Linux 上运行，并提供一个降级版本用于本地功能验证（但**标注其数据不可用于延迟结论**）。
