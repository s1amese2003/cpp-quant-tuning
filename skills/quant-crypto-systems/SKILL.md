---
name: quant-crypto-systems
description: 数字货币量化系统 — Uniswap v2 恒定乘积与 v3 集中流动性/tick 数学、CEX 订单簿方案、三角套利、crypto quant trading workflow、Binance U 本位合约多因子、Gemini 标的 BBO 监控、Polymarket 预测市场机器人、crypto 交易系统监控告警。Use for crypto, DeFi, AMM, Uniswap, liquidity pool, slippage, impermanent loss, tick math, DEX, CEX, Binance, perpetual futures, funding rate, triangular arbitrage, orderbook websocket, BBO monitoring, Polymarket, prediction market, on-chain, 数字货币, 套利, 做市, 永续合约, 监控.
license: CC-BY-4.0
metadata:
  version: "1.0.0"
  source: "trading-system-notes-Chinese.md 《交易系统开发》张智炫"
---

# 数字货币量化系统（Crypto Quant Systems）

与传统市场的关键差异，决定了设计取舍：

| 维度 | 传统市场 | Crypto |
|---|---|---|
| 交易时间 | 有开收盘 | **7×24，没有"收盘价"，没有维护窗口** |
| 接入 | 专线 + 二进制协议 | 多数是 WebSocket/REST（延迟 ms 级），少数有低延迟通道 |
| 数据质量 | 交易所强保障 | **丢包、乱序、序列跳变、限流是常态** |
| 结算 | T+1/T+0 集中清算 | 链上结算 + 交易所内部账本，跨所资金划转慢 |
| 对手方风险 | 极低 | **交易所可能跑路/宕机/穿仓分摊** |
| 场所 | 少数 | CEX + DEX 数十上百个，价格分散 |

所以 crypto 量化的工程重心是：**多场所连接的鲁棒性 + 资金/风险管理**，而不是纳秒级延迟（除非做特定的低延迟通道）。

---

## 1. CEX 接入

### 订单簿维护（最容易出错的地方）
标准流程：
1. 订阅增量 depth 流，**先缓存**。
2. 拉 REST 快照。
3. 丢弃快照 lastUpdateId 之前的增量。
4. 校验增量的 `U <= lastUpdateId+1 <= u`（Binance 语义），不满足 → **整个流程重来**。
5. 之后每条增量校验 `prev_u == last_u`，跳变即重建。

**纪律：宁可重建也不要带着不确定的簿继续跑。** 一个错误的簿会让策略在幻觉价格上下单。

其他要点：
- WebSocket 断线重连要有指数退避 + 抖动，重连后必须重建簿。
- 心跳/pong 超时检测，交易所经常静默断连。
- 本地维护"数据新鲜度"时间戳，超过阈值即停止交易并告警。
- 多所行情用统一的内部结构归一化（symbol、精度、方向、时间戳）。

### 下单
- 精度：每个 symbol 的 tickSize / stepSize / minNotional 不同，**下单前本地校验并按规则取整**，否则被拒。
- 限流：见 `quant-trading-systems` 的限流器；crypto 交易所的权重制限流（不同接口不同权重）要按权重计费。
- 幂等：用 `clientOrderId` 保证重试不会重复下单。
- **永续合约**：资金费率（funding）按周期结算，是持仓成本也可能是收益来源；标记价格 ≠ 最新成交价，强平按标记价触发 —— 风控必须用标记价。

> 参考：`references/03-cex-orderbook.md`、`references/06-binance-usdm-multifactor.md`、`references/07-gemini-bbo-monitor.md`

---

## 2. DEX / AMM 数学

### Uniswap v2：恒定乘积
```
x · y = k
输出量  dy = (y · dx · (1−fee)) / (x + dx · (1−fee))
价格冲击随 dx/x 增大而非线性上升
```
- 滑点完全由池子深度决定，**可以精确预计算** —— 这是 DEX 相对 CEX 的一个优势。
- 无常损失：提供流动性时，价格偏离越大损失越大，`IL = 2√r/(1+r) − 1`（r 为价格变化倍数）。

### Uniswap v3：集中流动性
- 流动性分布在 tick 区间内，`price = 1.0001^tick`。
- 跨区间交易要**逐区间累加**，每跨一个已初始化 tick，流动性 L 发生变化。
- 计算量大且要处理 tick bitmap 查找；实现时用整数数学（Q64.96 定点）避免精度问题 —— 与链上合约结果必须**逐 wei 一致**，否则模拟出的报价不可用。
- LP 头寸是范围订单，等价于一段区间内的做市；价格离开区间后头寸变成单边资产。

> 参考：`references/01-uniswap-v2.md`、`references/02-uniswap-v3.md`

---

## 3. 套利

### 三角套利
在同一交易所内 `A→B→C→A` 的路径上寻找 `∏ 汇率 > 1 + 总成本`。

**做对的关键（大部分实现都错在这）：**
- 用**盘口的可成交价与可成交量**，不是中间价。买用 ask，卖用 bid，且要看深度能吃多少。
- **手续费按每一腿计算**，三腿累计（如 0.1%×3 = 0.3%），很多"机会"扣完手续费就没了。
- 精度取整会吃掉利润：每一腿按 stepSize 取整后重算实际可得量。
- **执行风险**：三腿不是原子的，第一腿成交后价格可能变。要么用 IOC 并接受部分失败后的对冲成本，要么只在利润 > 失败成本时出手。
- 机会窗口通常 < 100ms，检测与下单要在同一进程内完成，不要走消息队列。

跨所套利额外要考虑：资金划转时间（分钟~小时）、提币限额、两边都要预置资金（资金效率折半）。

> 参考：`references/04-triangular-arbitrage.md`

---

## 4. 工作流与因子

标准 crypto quant workflow（见 `references/05-quant-trading-workflow.md`）：
```
数据采集(多所归一化) → 存储(列存/时序库) → 因子计算 → 回测(含成本与资金费)
  → 参数验证(置换检验，见 quant-strategy-math) → 纸上交易 → 小资金实盘 → 扩容
```

**crypto 特有的回测坑：**
- 资金费率必须计入 —— 长期持有永续的成本/收益可能超过策略本身的 alpha。
- 交易所历史数据经常有缺口与错价，回测前要做数据质量报告。
- 币种上下架频繁，universe 要按时间点动态确定（幸存者偏差在 crypto 尤其严重）。
- 早期数据的流动性极差，回测时的成交假设要按当时的真实深度。

多因子（U 本位合约）：动量、资金费率、基差、订单流不平衡、持仓量变化。因子评估方法见 `quant-strategy-math`。

> 参考：`references/05-quant-trading-workflow.md`、`references/06-binance-usdm-multifactor.md`、`references/08-polymarket-bot.md`

---

## 5. 监控（crypto 系统的生命线）

7×24 无人值守运行，监控不是可选项。必须覆盖：

| 层 | 监控项 | 动作 |
|---|---|---|
| 连接 | WS 心跳、重连次数、REST 错误率、限流剩余额度 | 告警 + 自动重连 |
| 数据 | 行情新鲜度、序列跳变次数、簿重建次数、跨所价差异常 | **超阈值即停止交易** |
| 交易 | 下单成功率、拒单原因分布、成交延迟、滑点 vs 预期 | 告警 |
| 风险 | 持仓 vs 限额、保证金率、未实现盈亏、单日回撤 | 熔断/强制平仓 |
| 对账 | 本地持仓 vs 交易所持仓、本地余额 vs 交易所余额 | **不一致立即停机** |
| 系统 | 进程存活、内存、磁盘、时钟偏移 | 告警 |

**设计原则：**
- **默认安全（fail-safe）**：任何不确定状态（对账不上、数据陈旧、连接异常）都应该停止开新仓，而不是继续跑。
- 定期对账（分钟级）是发现"策略以为自己有仓位但实际没有"这类致命 bug 的唯一手段。
- 告警要分级，避免告警疲劳；能自动处理的（重连、重建簿）不要打扰人。
- 时钟同步（NTP/PTP）：crypto 交易所会拒绝时间戳偏差过大的请求。

> 参考：`references/09-crypto-system-monitoring.md`

---

## 6. 检查清单

- [ ] 订单簿有严格的序列号校验与重建路径？
- [ ] 数据陈旧检测存在，超时即停止交易？
- [ ] 下单前按 tickSize/stepSize/minNotional 本地校验？
- [ ] `clientOrderId` 保证重试幂等？
- [ ] 永续合约的风控用标记价而非最新价？资金费率计入成本？
- [ ] 套利用可成交价+深度，扣了每腿手续费与取整损耗？
- [ ] 回测的 universe 按时间点动态确定（无幸存者偏差）？
- [ ] 有分钟级持仓/余额对账，不一致即停机？
- [ ] 交易所对手方风险有分散（不把资金全放一家）？
- [ ] AMM 报价模拟与链上合约结果逐 wei 一致？

---

## references/ 索引

| 文件 | 内容 |
|---|---|
| `01-uniswap-v2.md` | Uniswap v2 |
| `02-uniswap-v3.md` | Uniswap v3 |
| `03-cex-orderbook.md` | CEX 订单簿方案 |
| `04-triangular-arbitrage.md` | 三角套利 |
| `05-quant-trading-workflow.md` | quant trading workflow |
| `06-binance-usdm-multifactor.md` | Binance U 本位合约多因子 |
| `07-gemini-bbo-monitor.md` | Gemini 标的 BBO 监控 |
| `08-polymarket-bot.md` | Polymarket 市场机器人 |
| `09-crypto-system-monitoring.md` | crypto 交易系统的监控 |
