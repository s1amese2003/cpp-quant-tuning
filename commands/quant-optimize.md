---
description: 以量化交易为背景，对指定代码/热路径做延迟优化（先测量、后归因、再改一处）
argument-hint: <文件路径、函数名或问题描述>
---

对以下目标做量化交易场景下的延迟优化：**$ARGUMENTS**

严格按下列顺序执行，**不许跳步**：

## 1. 定位路径
读 `quant-dev-playbook` skill，判定这段代码属于热路径（tick-to-trade）、温路径还是冷路径，并说明它的延迟预算。**如果是冷路径，明确告诉用户不值得做微优化**，并给出更合适的方向（算法复杂度、I/O、并行）。

## 2. 建立基准
检查项目里是否已有可复现的延迟基准。没有的话，先按 `quant-perf-analysis` 的模板搭一个：
- 真实/回放行情作输入（不是随机数）
- 绑核 + 预热 + TSC 打点 + 预分配结果数组
- 输出 p50 / p99 / p99.9 / max
- A/B 交替执行

先跑出 before 数据再动手改。

## 3. 归因
- 有 `perf` 可用就跑 `perf stat --topdown` 与 `perf stat -e cycles,instructions,branch-misses,cache-misses,LLC-load-misses,dTLB-load-misses`；怀疑 false sharing 时跑 `perf c2c`。
- 没有 perf（如 Windows 开发机）就基于代码做静态归因，并**明确标注结论未经测量验证**。
- 用 Roofline 判定 memory-bound 还是 core-bound。

## 4. 按优先级改，一次一处
参考 `quant-latency-core` 的优化顺序：数据布局 → 分支 → 运行时分派 → 循环 → 函数边界 → 算术 → intrinsics。
按需加载 `quant-memory-simd`、`quant-lockfree-ipc`、`quant-system-tuning`。

每处改动单独提交/单独复测，不要打包一堆改动。

## 5. 验证
- 复测同一基准，报告 before/after 的 p50/p99/p99.9/max。
- 关键函数看汇编确认编译器真的做了预期的事。
- **p99.9 没改善就当作没改善**，并如实说明、必要时回滚。
- 跑现有测试，确认语义未变（尤其是定点数、边界条件）。

## 6. 输出
最终给出：
- 改动清单 + 每一处的收益归因
- before/after 数据表
- 放弃的优化项与原因
- 引入的新风险（可移植性、可读性、UB 风险如 `__restrict__`）
