---
name: quant-trading-systems
description: 交易系统业务组件的设计与实现 — 订单管理系统(OMS)、订单簿数据结构、FIX 协议引擎、ZeroMQ 消息中间件、OMS/EMS/PMS/RMS 分层、订单簿历史查询、maker-only 撮合器、K线生成器、订单分配求解器、智能订单路由(SOR)、自成交保护(STP)、限流器、Lezer/Tree-sitter、分布式共识、交易所协议分层与序列一致性、预序列化订单、CoDEL 自适应丢弃。Use for order management, order book, matching engine, FIX, ZeroMQ, OMS EMS PMS RMS, kline/candlestick, smart order routing, self-trade prevention, rate limiter, token bucket, load shedding, sequence gap, snapshot recovery, 订单簿, 撮合, 报单, 风控, 限流, 协议, or designing any trading-system component.
license: CC-BY-4.0
metadata:
  version: "1.0.0"
  source: "trading-system-notes-Chinese.md 《交易系统开发》张智炫"
---

# 交易系统业务组件（Trading System Components）

设计交易组件时的排序原则：**先保证语义正确与失效可控，再谈延迟。** 一个快但会漏单/重复报单的 OMS 是负资产。

---

## 1. 订单簿（Order Book）

热路径上最核心的数据结构，选型决定整体延迟。

| 方案 | 结构 | 适用 |
|---|---|---|
| **价格数组直接寻址** | `level[(px − base) / tick]` 定长数组 | 价格范围有限（股票、期货）—— **最快，首选** |
| **有序数组 + 二分** | 紧凑，缓存友好 | 价格范围大但档位稀疏 |
| **跳表 / 平衡树** | 指针追逐 | 加密货币等价格范围极大的场景，不得已才用 |
| `std::map` | ❌ | 任何热路径都不要用 |

**要点：**
- 最优买卖价（BBO）单独缓存并增量维护，不要每次扫数组。用位图 + `tzcnt`/`lzcnt` 找最近的非空档位。
- 每档的订单队列用**侵入式链表 + 池化节点**（订单对象本身含 prev/next），保证 FIFO 优先级且撤单 O(1)。
- 订单 id → 订单指针用开放寻址哈希（线性探测），不用 `unordered_map`。
- **快照 + 增量**：处理序列号跳变时能触发快照重建（见第 6 节）。
- 深度更新与成交要保证顺序一致，不能先应用成交后应用簿更新。

> 参考：`references/02-order-book-design.md`、`references/06-orderbook-history-query.md`

---

## 2. OMS 与系统分层

```
Strategy → EMS(执行) → RMS(风控·前置) → 网关 → 交易所
              ↓             ↑
             OMS(订单状态机·唯一真相源)
              ↓
             PMS(持仓/PnL)
```

| 组件 | 职责 | 关键约束 |
|---|---|---|
| **OMS** | 订单全生命周期状态机、唯一真相源 | 状态转换必须是幂等的、可持久化的、可恢复的 |
| **EMS** | 执行算法（TWAP/VWAP/SOR）、母单拆子单 | 母子单关系可追溯 |
| **RMS** | 报单前校验（限额、自成交、频率、涨跌停） | **必须在热路径上同步执行**，异步风控等于没有风控 |
| **PMS** | 持仓、成本、浮动/已实现盈亏 | 与 OMS 的成交流严格对账 |

### OMS 状态机纪律

- 状态转换表显式枚举，非法转换要报警而非静默忽略。
- **回报乱序是常态**：可能先收到成交回报再收到"已接受"。用交易所序列号/时间戳排序，或设计成对乱序不敏感的状态机。
- **超时**：报单发出后无回报要有超时处理（查询而非重发；重发会造成重复下单）。
- **恢复**：进程重启后必须能从持久化日志 + 交易所查询重建全部在途订单状态。
- 本地 id ↔ 交易所 id 双向映射，本地 id 单调递增且**跨重启不重复**（用时间戳高位 + 序号）。

> 参考：`references/01-order-management-system.md`、`references/05-oms-ems-pms-rms.md`

---

## 3. 协议与网关

### FIX 引擎
- 会话层（SeqNum、心跳、Logon/Logout、ResendRequest、GapFill）与应用层分离。
- SeqNum 持久化，**重启后必须正确恢复**，否则会被交易所踢出会话。
- 解析：预编译 tag 表 + 定长 buffer 就地解析，不要每字段构造 `std::string`。
- 热路径上用二进制协议（SBE/ITCH/OUCH）优于 FIX 文本；FIX 保留给非延迟敏感通道。

### 交易所协议分层与序列一致性
- **增量流 + 周期快照**是行业标准。收到序列号跳变时：暂存增量 → 拉快照 → 用快照序列号丢弃过期增量 → 回放暂存的增量 → 恢复正常。
- 组播 A/B 双线：同一份数据两路发送，用序列号去重取先到者。这是**最有效的降低尾延迟手段之一**。
- 交易所时间戳可能回退或重复，不要当作严格单调。

### 预序列化订单
报单路径上把序列化提前到"行情到来之前"：
- 启动时为每个可能的（合约, 方向, 价格档）预生成消息模板。
- 热路径只 patch 变化的字段（价格、数量、client id、checksum）然后 `write`。
- 可把 tick-to-trade 中的序列化开销从数百 ns 降到几十 ns。
- 代价：模板占内存、字段布局变更时要同步更新，需有一致性测试。

> 参考：`references/03-fix-protocol-engine.md`、`references/15-exchange-protocol-layering.md`、`references/16-pre-serialized-orders.md`

---

## 4. 撮合器与 K 线

### maker-only 撮合器
用于内部模拟/回测撮合。要点：价格-时间优先、只挂不吃（post-only，会吃单则拒绝或改价）、部分成交处理、撤改单的队列位置规则（改量减少保留位置，改价或增量到队尾）。

**回测撮合的诚实性**：不要假设自己的挂单一定能成交。至少要建模队列位置（前面有多少量）和对手方吃单量，否则回测收益是虚的。见 `quant-strategy-math` 的无偏模拟一节。

### K 线生成器
- 按时间/成交量/成交额切 bar；**bar 边界的归属规则**（左闭右开）必须与数据供应商一致。
- 增量维护 OHLCV，不要缓存全部 tick。
- **未完成 bar 与已完成 bar 要区分**，策略用未完成 bar 的收盘价 = 前视偏差。
- 空 bar 的处理（补前值 vs 跳过）要在回测与实盘一致。

> 参考：`references/07-maker-only-matching-engine.md`、`references/08-kline-generator.md`

---

## 5. 执行与路由

### 求解器（订单分配）
把目标仓位在多个渠道/账户间最优分配。输入：各场所深度、滑点模型、手续费、延迟与成交率。方法从简到繁：贪心按有效价格排序 → LP → QP（考虑冲击成本的二次项）。
**微秒级预算下**：贪心 + 预计算的有效价格表通常够用；LP/QP 放到温路径周期性求解，热路径查结果。

### SOR
母单拆子单，两阶段范式：
- **Aggressive**：按有效成本（价格 + 手续费 + 预期滑点）排序扫对手档。
- **Passive**：按各场所历史被动成交率、返佣权重分配挂单量。
费率符号约定要统一（笔记约定：正费率 = 对己方不利）。

### 自成交保护（STP）
自己的买单吃到自己的卖单在多数市场是违规的。策略：
- **Cancel Newest / Cancel Oldest / Cancel Both / Decrement**，按交易所规则选。
- 本地预检：报单前查自己在对手方向的挂单价位，命中则拦截或改价。
- 多账户/多策略共用通道时，STP 必须在**汇聚点**做，各策略自查是不够的。

> 参考：`references/09-solver.md`、`references/10-smart-order-router.md`、`references/11-self-trade-prevention.md`

---

## 6. 过载保护

### 限流器
交易所对报单/撤单频率有硬限制，超限会被封禁。
- **令牌桶**优于漏桶（允许突发，符合交易需求）。
- 必须**本地限流 + 追踪交易所返回的剩余额度**双保险；只信本地计数会因为时钟/网络偏差超限。
- 分级：不同接口（下单/撤单/查询）独立配额。
- 触限时的行为要明确：排队 vs 拒绝 vs 降级。**报单通常应拒绝并告警**，排队会让报单在过时价格上成交。

### CoDEL 自适应丢弃
与限流互补：限流管**发送速率**，CoDEL 管**数据陈旧度**。

单线程链路落后行情时，继续处理队列里的过时包只会让延迟雪上加霜。用**驻留时间**（出队时刻 − 入队时刻）判断拥堵：
- 驻留 < target（如 5μs）→ 正常，退出丢弃模式。
- 驻留持续超标超过 interval（如 100μs）→ 进入丢弃模式，主动丢弃过期行情以排空积压。

**关键**：行情可以丢，**报单回报不能丢**。两条流的过载策略必须分开设计。

> 参考：`references/12-rate-limiter.md`、`references/17-codel-load-shedding.md`

---

## 7. 中间件与分布式

- **ZeroMQ**：适合温路径（策略间通信、监控、控制面）。PUB/SUB 有慢消费者丢消息的语义，正好符合行情分发；但它的延迟（数十 μs）不适合热路径 —— 热路径用共享内存（`quant-lockfree-ipc`）。
- **分布式共识**：只在需要多活/故障切换时引入。共识的代价是延迟，**绝不放在报单路径上**。典型做法：交易路径单活 + 共识只做状态复制与选主。
- **Lezer / Tree-sitter**：用于策略 DSL、配置语言的增量解析，属于工具链层。

> 参考：`references/04-zeromq-middleware.md`、`references/14-distributed-consensus.md`、`references/13-lezer-tree-sitter.md`

---

## 8. 检查清单

- [ ] 订单簿是扁平数组/侵入式链表，不是 `std::map`？
- [ ] BBO 增量维护而非每次扫描？
- [ ] OMS 状态机对乱序回报和超时有定义？重启可恢复？
- [ ] 本地订单 id 跨重启不重复？
- [ ] 风控在报单路径上**同步**执行？
- [ ] 序列号跳变有快照重建路径？A/B 双线去重？
- [ ] 限流器同时用本地计数和交易所剩余额度？
- [ ] 行情与回报的过载策略分开（可丢 vs 不可丢）？
- [ ] STP 在多策略汇聚点做？
- [ ] 回测撮合建模了队列位置，而不是假设必成交？

---

## references/ 索引

| 文件 | 内容 |
|---|---|
| `01-order-management-system.md` | 订单管理系统 |
| `02-order-book-design.md` | 订单簿设计 |
| `03-fix-protocol-engine.md` | 消息传输协议引擎（FIX） |
| `04-zeromq-middleware.md` | 消息中间件（zmq） |
| `05-oms-ems-pms-rms.md` | OMS、EMS、PMS、RMS |
| `06-orderbook-history-query.md` | 订单簿历史查询 |
| `07-maker-only-matching-engine.md` | maker-only 撮合器 |
| `08-kline-generator.md` | K 线生成器 |
| `09-solver.md` | 求解器（订单分配等） |
| `10-smart-order-router.md` | 智能订单路由（SOR） |
| `11-self-trade-prevention.md` | 自成交保护机制 |
| `12-rate-limiter.md` | 限流器 |
| `13-lezer-tree-sitter.md` | Lezer / Tree-sitter |
| `14-distributed-consensus.md` | 分布式交易系统共识模型 |
| `15-exchange-protocol-layering.md` | 交易所协议分层与序列一致性 |
| `16-pre-serialized-orders.md` | 预序列化订单 |
| `17-codel-load-shedding.md` | 自适应负载丢弃器（CoDEL） |
