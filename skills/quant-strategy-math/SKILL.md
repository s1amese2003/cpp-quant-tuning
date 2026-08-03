---
name: quant-strategy-math
description: 策略研究与数值计算 — 对数收益率与百分比非对称性、趋势/波动率状态识别、移动窗口指标平稳性、信息熵评估指标、正则化线性模型(Ridge/Lasso/ElasticNet)、差分进化非线性寻优、廉价训练偏差估计、参数关系与敏感性曲线、无偏交易模拟、收益统计分析、置换检验验证策略、资产成本基础(ACB)、数值计算工具、EMA/EMASTDEV 时间平滑、Avellaneda-Stoikov 做市、交易系统定点数。Use for return calculation, log return, volatility regime, rolling statistics, feature/factor evaluation, overfitting, walk-forward, parameter optimization, sensitivity analysis, backtest bias, Sharpe, drawdown, permutation test, market making, inventory risk, fixed point arithmetic, 因子, 回测, 过拟合, 参数寻优, 做市, 定点数.
license: CC-BY-4.0
metadata:
  version: "1.0.0"
  source: "trading-system-notes-Chinese.md 《交易系统开发》张智炫"
---

# 策略研究与数值计算（Strategy Math）

本 skill 的核心立场：**大多数"有效"的策略是过拟合的产物。** 因此所有工具的用法都围绕一个问题 —— 怎么证明这个结果不是噪声。

工程侧的对应纪律见 `quant-market-data`（数据正确性）与 `quant-dev-playbook`（实盘/回测一致性）。

---

## 1. 收益率：先把基本量算对

- **永远用对数收益** `r = ln(P_t / P_{t-1})` 做统计与建模。
  - 百分比收益不对称：−50% 之后需要 +100% 才回本；简单收益的均值会系统性高估复合增长。
  - 对数收益可加：多期收益 = 各期之和，便于聚合与时间尺度换算。
  - 换回简单收益：`R = exp(r) − 1`。**报告给业务方时要转回简单收益**，因为对数收益不直观。
- 组合层面简单收益可加（跨资产），对数收益不可加。**跨时间用对数，跨资产用简单** —— 混用是常见错误。
- 含分红/拆股的价格必须用复权序列，否则会凭空造出跳空信号。

> 参考：`references/01-log-returns.md`

---

## 2. 波动率与市场状态

- 波动率是**状态变量**而非常数。趋势/震荡、高波动/低波动的切换会让固定参数策略在换状态时集中亏损。
- 常用刻画：滚动标准差、EWMA 波动率、Parkinson/Garman-Klass（用高低价，效率更高）、已实现波动率（高频平方和）。
- 状态识别：阈值分段、HMM、聚类。**注意状态标签本身有前视偏差** —— 用全样本拟合的状态划分去回测是作弊的，必须滚动估计。
- 用途：仓位缩放（波动率目标化）、做市报价宽度、止损宽度。

> 参考：`references/02-trend-volatility-regimes.md`、`references/03-rolling-window-stationarity.md`

---

## 3. 指标/因子评估

- **平稳性优先**：非平稳的指标在样本外必然失效。差分、比值化、标准化（用滚动而非全样本的均值方差！）。
- **信息熵**：衡量指标的信息含量与区分度，可用于筛掉"取值高度集中/几乎无变化"的伪因子。
- 评估指标要看：IC/RankIC 的均值与稳定性、分组单调性、换手率与成本后收益，而不只是回测曲线。
- **用滚动窗口标准化时窗口内只能用过去的数据**。用 `mean(全样本)` 标准化是最隐蔽也最常见的前视偏差。

> 参考：`references/03-rolling-window-stationarity.md`、`references/04-information-entropy.md`

---

## 4. 建模：从最简单的开始

**默认首选正则化线性模型**（Ridge / Lasso / ElasticNet）：

- 金融数据信噪比极低（日频 R² 通常 < 0.01），复杂模型的容量几乎全用来拟合噪声。
- Ridge 处理共线性（因子间高度相关是常态），Lasso 做特征选择，ElasticNet 折中。
- 正则强度用**时间序列交叉验证**（walk-forward）选，**绝不能用随机 K-fold** —— 随机划分会让未来数据进入训练集。
- 系数符号应该和经济直觉一致；符号翻转通常是过拟合或数据泄漏的信号。

只有当线性模型在样本外稳定有效之后，才考虑非线性。

> 参考：`references/05-regularized-linear-models.md`

---

## 5. 参数寻优：警惕优化本身

- **差分进化（DE）**适合非凸、不可导、有噪声的策略参数寻优。但**优化得越充分，过拟合越严重**。
- **廉价训练偏差估计**：训练集上的最优表现天然乐观。用 bootstrap/重采样估计这个乐观偏差的量级，从回测结果中扣掉再看是否还有超额。
- **参数关系分析 + 敏感性曲线**：这是判断策略真伪最有效的工具。
  - 画出目标函数关于每个参数的曲线。
  - **好的策略参数曲线是平台状（plateau）**：最优点附近有宽阔的高原。
  - **孤立尖峰 = 过拟合**，样本外必然失效。宁可选高原中心的次优参数，也不要选尖峰上的最优参数。
  - 二维参数用热力图看是否存在连片的稳定区域。
- 参数数量要有预算：每多一个自由参数，就需要显著更多的样本外证据。

> 参考：`references/06-differential-evolution.md`、`references/07-cheap-training-bias.md`、`references/08-parameter-relationships.md`、`references/09-parameter-sensitivity-curves.md`

---

## 6. 无偏回测

回测偏差清单（每一条都能凭空造出收益）：

| 偏差 | 表现 | 防范 |
|---|---|---|
| **前视偏差** | 用了当时拿不到的数据 | 所有指标滚动计算；bar 未收盘不可用；数据入库时间 ≠ 事件时间 |
| **幸存者偏差** | 只用现存合约/股票 | 用含退市的完整universe |
| **成本缺失** | 忽略手续费、滑点、冲击 | 显式建模；高频策略成本常超过毛收益 |
| **成交假设过乐观** | 假设挂单必成交 | 建模队列位置与对手方成交量（见 `quant-trading-systems`） |
| **数据窥探** | 反复在同一份数据上试 | 留出真正的 holdout；记录尝试次数用于多重检验校正 |
| **重采样偏差** | 用了 t+1 的信息插值 | 见 `quant-market-data` 第 5 节 |

> 参考：`references/10-unbiased-trade-simulation.md`

---

## 7. 结果验证

### 收益统计
报告必须包含：年化收益、年化波动、Sharpe、最大回撤与回撤持续期、胜率、盈亏比、换手率、成本后净收益、按年/按状态分组的稳定性。
**单一 Sharpe 数字没有意义** —— 要看它在不同时间段是否稳定。

### 置换检验（Permutation Test）
判断"这个策略的收益是不是运气"的最直接方法，且不依赖分布假设：

1. 把策略信号（或收益序列）随机打乱 N 次（如 1000 次），保持其他一切不变。
2. 每次计算目标指标（如年化 Sharpe）。
3. 看真实策略的指标在这 N 个随机结果中的分位数 = p 值。
4. **p > 0.05 就当作没有证据**，不管回测曲线多漂亮。

变体：打乱信号时保留自相关结构（block permutation），否则会低估随机基线。

**多重检验校正**：如果你试了 100 组参数，那么最好的那组的 p 值必须做 Bonferroni/FDR 校正，否则 5% 的显著性水平下必然有 5 个"显著"的伪策略。

> 参考：`references/11-return-statistics.md`、`references/12-permutation-tests.md`

---

## 8. 做市与库存管理

**Avellaneda-Stoikov** 是做市定价的基准框架：

```
保留价格 r = s − q·γ·σ²·(T−t)          # q=库存, γ=风险厌恶
最优价差 δ = γ·σ²·(T−t) + (2/γ)·ln(1 + γ/k)
报价 = r ± δ/2
```

要点：
- **库存 q 把中间价推向减仓方向** —— 这是模型的核心，也是做市不爆仓的关键。
- `σ` 要用实时估计（EWMA），不是历史常数。
- `T−t` 在永续做市中要替换成一个固定的时间尺度或库存半衰期，否则收盘临近时价差会退化。
- 实盘必须加：硬库存上限、最大回撤熔断、行情异常时撤单、对手方毒性检测（adverse selection）。
- 模型给出的是**起点**，实际参数要用第 5 节的敏感性分析校准。

> 参考：`references/16-avellaneda-stoikov.md`

---

## 9. 数值实现

### 定点数（交易系统必须）
- 价格、数量、金额一律用**整数定点**（如价格以 1e-4 元为单位存 int64）。
- 理由：`double` 的 `0.1 + 0.2 != 0.3`，比较、累加、对账都会出错；不同机器/编译选项下结果不可复现。
- 实现：定义 `struct Price { int64_t raw; static constexpr int64_t SCALE = 10000; }`，重载运算符，**乘除时先扩宽到 `__int128` 再缩放**防溢出。
- 与交易所字符串协议转换时用整数解析，不要经过 `double`。
- 舍入规则要与交易所一致（通常按 tick 向下/向上取整，方向与买卖有关）。

### 其他
- EMA / EMASTDEV：天然增量，`ema = α·x + (1−α)·ema`；标准差用增量形式避免二次遍历。注意**初始化偏差**（前几个值需要 bias correction 或用足够长的预热期）。
- ACB（资产成本基础）：加权平均成本法，买入摊薄成本、卖出不改变单位成本。与期货逐日盯市规则不同（见 `quant-market-data`）。
- 数值稳定：方差用 Welford；求和用 Kahan 或定点；比较浮点永远带容差（但价格用定点就不需要）。

> 参考：`references/17-fixed-point-arithmetic.md`、`references/15-ema-emastdev.md`、`references/13-adjusted-cost-base.md`、`references/14-numerical-toolkit.md`

---

## 10. 检查清单

- [ ] 跨时间用对数收益，跨资产用简单收益，没有混用？
- [ ] 所有滚动统计只用过去数据？标准化没有用全样本均值方差？
- [ ] 交叉验证是 walk-forward，不是随机 K-fold？
- [ ] 先试过正则化线性模型？
- [ ] 参数敏感性曲线是平台而不是尖峰？
- [ ] 成本（手续费+滑点+冲击）已建模？成本后仍有超额？
- [ ] 做过置换检验？p 值做了多重检验校正？
- [ ] 价格金额用定点整数？
- [ ] 研究代码（Python）与实盘代码（C++）跑同一份数据得到同样的信号？

---

## references/ 索引

| 文件 | 内容 |
|---|---|
| `01-log-returns.md` | 对数收益率与百分比非对称性 |
| `02-trend-volatility-regimes.md` | 市场趋势和波动率的状态变化 |
| `03-rolling-window-stationarity.md` | 基于移动窗口的指标平稳性优化 |
| `04-information-entropy.md` | 交易指标评估的信息熵 |
| `05-regularized-linear-models.md` | 正则化线性模型：首选模型 |
| `06-differential-evolution.md` | 差分进化优化：非线性参数寻优 |
| `07-cheap-training-bias.md` | 廉价训练偏差估计 |
| `08-parameter-relationships.md` | 参数关系分析 |
| `09-parameter-sensitivity-curves.md` | 参数敏感性曲线 |
| `10-unbiased-trade-simulation.md` | 无偏交易模拟 |
| `11-return-statistics.md` | 交易收益统计分析 |
| `12-permutation-tests.md` | 置换检验验证策略收益 |
| `13-adjusted-cost-base.md` | 资产成本基础（ACB）计算 |
| `14-numerical-toolkit.md` | 数值计算工具 |
| `15-ema-emastdev.md` | EMA 和 EMASTDEV（时间平滑） |
| `16-avellaneda-stoikov.md` | Avellaneda-Stoikov 做市策略 |
| `17-fixed-point-arithmetic.md` | 交易系统的定点数 |
