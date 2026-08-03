---
name: quant-market-data
description: 行情与交易数据的工程处理 — 多数据源(order/snap/trans)按时间归并、数据依赖 DAG 与拓扑排序/环检测、CSV↔二进制列存转换、增量计算与提前计算、高频数据清洗(不规则采样、买卖方向判定 Tick Rule/Lee-Ready/BVC、bid-ask bounce 与中间价)、报单时序竞争分析、服务访问日志分析、期货逐日盯市。Use for market data pipeline, tick data, order book snapshot, 逐笔委托/成交, data merge, timestamp ordering, dependency graph, topological sort, csv to binary, columnar format, incremental computation, rolling window, data cleaning, resampling, trade sign, mid price, 逐日盯市, mark to market, log analysis.
license: CC-BY-4.0
metadata:
  version: "1.0.0"
  source: "trading-system-notes-Chinese.md 《交易系统开发》张智炫"
---

# 行情与交易数据处理（Market Data Engineering）

这一层的错误不会让程序崩溃，只会让**回测结果和实盘不一致**——这是量化项目里代价最高的一类 bug。因此本 skill 的纪律是：**每条规则都必须在回测与实盘两侧用同一份代码实现**。

---

## 1. 多源数据流归并

交易所同时发布逐笔委托（order）、快照（snapshot）、逐笔成交（trans）三路流。回测要还原"我们当时收到的顺序"。

**核心规则：**
1. 按发布时间排序。
2. **同一时间戳必须有确定的 tie-break 顺序**（笔记中的约定：`trans → snap → order`），且必须是**稳定排序**，保证同源同时间的多条记录保持原始先后。
3. tie-break 规则一旦定下，回测与实盘的重放器必须完全一致。

**实现**：k 路归并（k=3）用最小堆或直接三路比较，`O(N log k)`；不要 concat 后全量排序（`O(N log N)` 且丢失稳定性控制）。流式处理，不要全量载入内存。

**易错点**：时间戳精度（毫秒 vs 微秒 vs 纳秒）、跨零点、集合竞价段的时间戳可能相同或倒退、交易所时间与本地时间混用。**统一在入口处归一化为自 epoch 起的整数纳秒**。

> 参考：`references/01-stream-merge.md`

---

## 2. 数据依赖与更新顺序

因子/数据集之间存在依赖（`m1 → m1plus`，`m1plus + m1a → m1plus2`）。给定依赖描述，要输出合法更新顺序并检出错误依赖。

- **拓扑排序**（Kahn 算法：入度为 0 入队，逐层剥离）给出更新顺序。
- **环检测**：Kahn 结束后仍有未输出节点 → 存在环；要**报出环上的具体节点**而不只是"有环"，否则用户无法定位。
- **确定性**：入度相同的节点用名字排序或输入顺序打破平局，否则每次输出顺序不同，无法做 diff。

**规模化建议**（百万级依赖）：
- 邻接表用 CSR（压缩稀疏行）扁平数组，而非 `unordered_map<string, vector<string>>`；名字先 intern 成整数 id。
- 增量更新：只重算受影响的下游子图（从变更节点做正向 BFS），而不是全图重排。
- 并行：拓扑分层后同层并行执行。
- 持久化依赖图的哈希，用于判断是否需要重建。

> 参考：`references/02-data-dependency.md`

---

## 3. CSV ↔ 二进制列存

CSV 解析通常是回测的头号瓶颈（浮点解析 + 内存分配）。

**转换纪律：**
- 一次性转成二进制，之后所有回测读二进制。
- **列式布局**（SoA）：`time[]`、`price[]`、`qty[]` 分开存。回测通常只用少数几列，列存能少读一个数量级的数据。
- 定长 POD + 显式 `#pragma pack` 或对齐设计；写入 magic + version + schema hash 头，防止格式漂移读错。
- 价格存**整数定点**（分/厘），不存 `double`。
- 时间存 int64 纳秒。
- 读取用 `mmap` 而非 `fread`，零拷贝 + 让 OS 管理页缓存。
- 大文件加简单压缩（列内 delta + varint 或 zstd 分块），但要实测解压是否比 I/O 更贵 —— NVMe 上常常不压缩更快。

**解析加速**：手写解析器（`from_chars`、SIMD 查找分隔符）比 `sscanf`/`stringstream` 快 10~50 倍。

> 参考：`references/03-csv-binary-conversion.md`

---

## 4. 增量计算与提前计算

**这是行情处理最重要的性能杠杆。** 每来一个 tick 就重算整个窗口是 `O(N·W)`；增量维护是 `O(N)`。

| 指标 | 增量方法 |
|---|---|
| 滚动求和/均值 | 加新减旧 |
| 滚动方差/标准差 | Welford 增量（**不要**用 `E[x²]-E[x]²`，浮点抵消会出负方差） |
| 滚动最大/最小 | 单调双端队列，均摊 O(1) |
| 滚动中位数/分位数 | 双堆 / 有序结构 / t-digest |
| EMA | 天然增量，见 `quant-strategy-math` |
| 订单簿最优价 | 维护而非重扫，见 `quant-trading-systems` |

**数值稳定性警告**：加新减旧的滚动和在长时间运行后会累积浮点误差。解决：用定点整数，或每 N 步做一次全量重算校正（并断言与增量值的偏差在容忍范围内）。

**提前计算**：交易时段外能算的全部提前算好 —— tick size 表、合约乘数、涨跌停价、手续费率、查找表、预分配的槽位。热路径只做查表。

> 参考：`references/04-incremental-precomputation.md`

---

## 5. 高频数据清洗

原始 tick 数据不能直接喂给模型，四类问题：

### (1) 时间不规则 → 重采样
- **收盘价采样**：取区间内最后一条有效报价（低频回测够用）。
- **线性插值**：`q̂_t = q_last + (q_next − q_last)·(t − t_last)/(t_next − t_last)`。**注意这是前视偏差的来源** —— 用了 `t_next` 的信息，只能用于分析，绝不能用于生成交易信号。
- **成交量采样 / dollar bar**：按累计成交量（如每 50 手）切 bar，统计性质远好于时间 bar（更接近正态、异方差更小）。

### (2) 无买卖方向标识 → 推断
- **Tick Rule**：价格上涨=买方发起，下跌=卖方发起，相等则继承上一次非零方向。
- **Lee-Ready**：先比中间价（>中点=买，<中点=卖），落在中点用 Tick Rule 补。准确率优于纯 Tick Rule。
- **BVC（Bulk Volume Classification）**：`Pr(V=B) = Z((p_τ − p_{τ-1}) / (σ·ΔP))`，给出概率而非硬分类，适合聚合成交量。

**选型**：有报价数据用 Lee-Ready；只有成交数据用 Tick Rule；做 VPIN/订单流不平衡类因子用 BVC。

### (3) bid-ask bounce 噪声 → 中间价
- 中间价 `(bid + ask)/2`，时间戳取买卖价中**较新的那一侧**。
- 进阶：微观价格（size-weighted）`(bid·ask_size + ask·bid_size)/(bid_size + ask_size)` —— 注意是**交叉加权**，量大的一侧把价格推向对面，这才是对未来价格更好的预测。

### (4) 异常值
- 涨跌停、集合竞价、临时停牌、错价（fat finger）、交易所补发/撤销。
- 规则：**标记而不是删除**。删除会让回测看不到真实的极端情形；打标签让策略自己决定是否规避。

> 参考：`references/05-hft-data-cleaning.md`

---

## 6. 报单时序竞争分析

多台服务器对同一合约同时报单，谁先到交易所决定成交。分析方法：

- 按 `(时间点, 合约)` 分组，统计各服务器的到达先后比例。
- **时间对齐是关键**：不同服务器的本地时钟有偏差。必须用交易所回报中的时间戳或 PTP 同步的硬件时间戳，否则统计的是时钟偏差不是真实竞速。
- 输出应包含样本数与置信区间 —— "A 比 B 快 55%" 在 n=20 时毫无意义。
- 用途：定位是哪一段（网络路径、机器配置、代码版本）造成落后。

> 参考：`references/06-order-timing-race.md`、`references/07-access-log-analysis.md`

---

## 7. 期货逐日盯市

- 每日结算按**结算价**（通常是加权均价，不是收盘价）重算浮盈浮亏并划转现金。
- 持仓成本基础在结算后重置为结算价 —— 这与股票的 ACB 逻辑不同（见 `quant-strategy-math` 的 ACB 一节）。
- 保证金、追保、强平的触发顺序要按交易所规则实现，不能自己简化。
- 合约换月、乘数变更、交割规则要显式建模。

**回测正确性**：不做逐日盯市的期货回测会高估资金效率与收益率。

> 参考：`references/08-futures-mark-to-market.md`

---

## 8. 检查清单

- [ ] 所有时间统一为 int64 纳秒，来源（交易所/本地/硬件）明确标注？
- [ ] 同时间戳的 tie-break 规则确定且稳定？回测与实盘一致？
- [ ] 价格用定点整数？
- [ ] 滚动统计用增量算法？方差用 Welford？有数值漂移校正？
- [ ] 采样/插值是否引入了前视偏差？
- [ ] 异常数据是打标而非删除？
- [ ] 二进制格式有 magic + version + schema hash？
- [ ] 回测与实盘共用同一份数据处理代码（而不是两套实现）？

---

## references/ 索引

| 文件 | 内容 |
|---|---|
| `01-stream-merge.md` | 任务一：数据流合并 |
| `02-data-dependency.md` | 任务二：数据依赖问题 |
| `03-csv-binary-conversion.md` | 任务三：csv ↔ binary |
| `04-incremental-precomputation.md` | 任务四：增量计算与提前计算 |
| `05-hft-data-cleaning.md` | 任务五：高频数据问题处理 |
| `06-order-timing-race.md` | 任务六：报单时序竞争分析 |
| `07-access-log-analysis.md` | 任务七：服务访问日志分析 |
| `08-futures-mark-to-market.md` | 任务八：期货逐日盯市处理 |
