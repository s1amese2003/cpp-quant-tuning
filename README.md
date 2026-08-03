# cpp-quant-tuning

> 量化交易系统开发与调优的 **Agent Skills** 包 —— 10 个 skill、94 篇参考资料、5 个工作流命令、1 个性能评审 subagent。
> 可通过 **Claude Code marketplace** 一键导入，同时兼容 **Codex CLI / Cursor / Windsurf / Cline** 等读取 `AGENTS.md` 的 agent 工具。

**核心设定：所有代码编写、评审与调优都以量化开发需求为背景。** 默认目标函数不是"平均吞吐"，而是

```
正确性 > 确定性（p99.9 抖动）> 中位延迟 > 吞吐 > 开发便利性
```

内容整理自《交易系统开发》（张智炫）—— 见 [`trading-system-notes-Chinese.md`](trading-system-notes-Chinese.md)，
原始出处 <https://github.com/zzxscodes/trading-system-notes>。

---

## 安装

### Claude Code（marketplace，推荐）

```
/plugin marketplace add s1amese2003/cpp-quant-tuning
/plugin install cpp-quant-tuning@cpp-quant-tuning
```

本地开发/试用：

```
/plugin marketplace add d:/cpp-quant-tuning
/plugin install cpp-quant-tuning@cpp-quant-tuning
```

安装后自动获得 10 个 skill（按任务描述自动触发）、5 个 slash command、1 个 subagent。

### Codex CLI

```bash
./tools/install.sh codex
# Windows:
powershell -ExecutionPolicy Bypass -File tools\install.ps1 -Target codex
```

脚本做三件事：
1. `skills/` → `$CODEX_HOME/skills/`
2. `commands/*.md` → `$CODEX_HOME/prompts/`（在 Codex 中以 `/quant-review` 等调用）
3. 在 `$CODEX_HOME/AGENTS.md` 追加一段引用 —— **这是所有 Codex 版本都生效的路径**，即使你的版本尚未支持 `skills/` 目录，agent 也会被指引去读 `quant-dev-playbook`。

### Cursor / Windsurf / Cline / Amp / 其他读 AGENTS.md 的工具

本仓库根目录的 [`AGENTS.md`](AGENTS.md) 本身就是完整入口（含路由表与底线规则）。

```bash
# 推荐：作为 submodule 挂进你的项目，便于更新
git submodule add git@github.com:s1amese2003/cpp-quant-tuning.git .agent/cpp-quant-tuning
```

然后在你项目的 `AGENTS.md` / `.cursorrules` 中加一行：

```
量化相关任务先读 .agent/cpp-quant-tuning/skills/quant-dev-playbook/SKILL.md，再按其路由表加载对应 skill。
```

或直接拷贝：

```bash
./tools/install.sh generic /path/to/project/.agent/skills
```

### 任意工具（手动）

`skills/*/SKILL.md` 是标准 Agent Skill 格式（YAML frontmatter + Markdown 正文），
`references/` 是按需加载的深度资料。任何支持"读文件"的 agent 都能用 —— 把
[`AGENTS.md`](AGENTS.md) 的内容贴给它即可。

---

## 内容

### Skills

| Skill | 覆盖 | 参考篇数 |
|---|---|---|
| [`quant-dev-playbook`](skills/quant-dev-playbook/SKILL.md) | **总入口**：热/温/冷路径判定、热路径硬性禁令、优化工作流、路由表、交付标准 | — |
| [`quant-latency-core`](skills/quant-latency-core/SKILL.md) | 数据布局与 cache line、false sharing、分支优化、内联与内联汇编、编译期多态(CRTP)、循环优化、指针别名、传参、强度削弱、位域、边界检查消除 | 19 |
| [`quant-memory-simd`](skills/quant-memory-simd/SKILL.md) | 内存池/arena、大页与 TLB、`mlockall`、预取、缓存预热、SIMD 向量化与 CPU 分派 | 3 |
| [`quant-lockfree-ipc`](skills/quant-lockfree-ipc/SKILL.md) | SPSC/SPMC 无锁队列、micro-batching、共享内存 seqlock、双缓冲、自旋锁、wait-free、内存序、C++20 协程、socket/TCP/UDP/组播 | 9 |
| [`quant-system-tuning`](skills/quant-system-tuning/SKILL.md) | CPU 亲和与 NUMA、`isolcpus`/`nohz_full`/`rcu_nocbs`、超线程、`SCHED_FIFO`、中断隔离、C-State 与锁频、BIOS、`cyclictest` 验收 | 5 |
| [`quant-perf-analysis`](skills/quant-perf-analysis/SKILL.md) | Roofline、TMA、perf 配方（含 `perf c2c`）、编译器选项与 PGO/LTO、看汇编、`rdtscp` 延迟测量、交易性能指标 | 7 |
| [`quant-market-data`](skills/quant-market-data/SKILL.md) | 多源流归并、依赖 DAG 与环检测、CSV↔列式二进制、增量计算与 Welford、高频数据清洗（Lee-Ready/BVC/微观价格）、报单竞速分析、逐日盯市 | 8 |
| [`quant-trading-systems`](skills/quant-trading-systems/SKILL.md) | 订单簿结构选型、OMS 状态机、OMS/EMS/PMS/RMS 分层、FIX、快照+增量与序列一致性、预序列化订单、撮合器、K线、SOR、STP、限流器、CoDEL | 17 |
| [`quant-strategy-math`](skills/quant-strategy-math/SKILL.md) | 对数收益、波动率状态、因子评估、正则化线性模型、差分进化、参数敏感性（平台 vs 尖峰）、无偏回测、置换检验、Avellaneda-Stoikov、定点数 | 17 |
| [`quant-crypto-systems`](skills/quant-crypto-systems/SKILL.md) | CEX 订单簿同步与重建、Uniswap v2/v3 数学、三角套利（含每腿成本与取整）、永续合约与资金费、7×24 监控与对账 | 9 |

### Slash Commands

| 命令 | 用途 |
|---|---|
| `/quant-optimize <目标>` | 按"定基准 → 归因 → 改一处 → 复测"的流程优化热路径 |
| `/quant-review [范围]` | 按热路径禁令 / 并发正确性 / 数值正确性 / 失效模式四轴评审 |
| `/quant-design <组件>` | 设计交易组件：先定语义与失效模式，再定结构 |
| `/quant-bench <目标>` | 生成 TSC 打点 + 绑核 + 预热 + 百分位 + A/B 交替的基准脚手架 |
| `/quant-tune-host [描述]` | 生成交易机的 BIOS/内核/中断/频率调优方案与验证脚本 |

### Subagent

`quant-perf-reviewer` —— 只读的低延迟代码性能与正确性评审专家，输出按严重度排序的发现清单。

---

## 设计说明

**渐进式加载（progressive disclosure）**：每个 `SKILL.md` 是可操作的决策程序与检查清单（约 150~250 行），
原始笔记按 94 个章节切分进各 skill 的 `references/`，只在需要具体实现时才读。
这样 agent 不会为了一个分支优化问题把 1.4MB 笔记全部载入上下文。

**一份内容，两条加载路径**：Claude Code 走 `.claude-plugin/` + `skills/` 的插件机制；
其他工具走根目录 `AGENTS.md`。两者指向同一批 `skills/` 文件，没有副本需要同步。

**references 可重新生成**：内容是源笔记的逐字副本，由脚本按 `tools/section-map.json` 切分。
上游笔记更新后重跑即可：

```bash
powershell -ExecutionPolicy Bypass -File tools\split-notes.ps1
# 或
pwsh -File tools/split-notes.ps1
```

脚本会报告"映射了但源里找不到的小节"和"源里有但没被任何 skill 收录的小节"，便于维护。

---

## 目录结构

```
.claude-plugin/
  marketplace.json          # Claude Code marketplace 定义
  plugin.json               # 插件清单
skills/
  quant-dev-playbook/SKILL.md
  quant-*/SKILL.md          # 10 个 skill
  quant-*/references/*.md   # 94 篇原始章节
commands/*.md               # 5 个 slash command
agents/quant-perf-reviewer.md
tools/
  split-notes.ps1           # 从源笔记重新生成 references/
  section-map.json          # 章节 -> skill 映射
  install.sh / install.ps1  # Codex / Cursor / 通用安装
AGENTS.md                   # 跨工具入口（Codex/Cursor/Windsurf/Cline...）
trading-system-notes-Chinese.md   # 源笔记
```

---

## 平台说明

Skills 中大量系统配置（`isolcpus`、`cpuset`、hugepages、`SCHED_FIFO`、`perf`、`cyclictest`）
是 **Linux x86-64 专有**。在 Windows/macOS 上开发时，agent 会被要求显式标注哪些建议不适用，
并给出仅用于功能验证、**不可用于延迟结论**的降级方案。

## 许可与致谢

内容源自 [zzxscodes/trading-system-notes](https://github.com/zzxscodes/trading-system-notes)（张智炫）。
本仓库的 skill 编排、检查清单与工作流以 CC-BY-4.0 发布；`references/` 的版权归原作者。
