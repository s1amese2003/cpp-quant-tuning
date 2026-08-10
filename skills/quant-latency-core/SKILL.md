---
name: quant-latency-core
description: 交易热路径 C++ 编码与微优化 — 内存布局/cache line/false sharing、分支消除、内联与内联汇编、编译期多态(CRTP/模板)、循环优化、指针别名与 restrict、函数传参、强度削弱、位域位运算、边界检查消除、组合优于继承。Use when writing or optimizing C++ on a trading hot path, or when the task mentions cache miss, false sharing, branch misprediction, inline, template/CRTP/虚函数, loop unrolling, pointer aliasing, struct layout/对齐, bit manipulation, 分支预测, 数据布局, or "make this function faster".
license: CC-BY-4.0
metadata:
  version: "1.0.0"
  source: "trading-system-notes-Chinese.md 《交易系统开发》张智炫"
---

# 热路径 C++ 微优化（Latency Core）

适用范围：**tick-to-trade 关键链路**上的函数。冷路径（回测、落盘、报表）不要套用本 skill，见 `quant-dev-playbook` 的路径判定。

优化前先确认已有可复现基准与 perf 数据（`quant-perf-analysis`）。凭直觉改热路径是负收益。

---

## 1. 优化顺序（收益从大到小）

绝大多数交易系统的延迟问题按这个顺序解决，**不要倒着做**：

```
1. 数据布局 / 访存模式      ← 通常 60%+ 的收益在这里
2. 消除不可预测分支
3. 消除运行时分派（虚函数 → 编译期）
4. 循环结构与向量化机会
5. 函数边界（内联、传参、ABI）
6. 算术强度削弱、位运算
7. 内联汇编 / intrinsics    ← 最后手段，收益最小、维护成本最高
```

理由：现代 x86 乱序核心能藏住算术开销，藏不住 cache miss 和分支预测失败。一次 L3 miss ≈ 200+ cycles，一次分支预测失败 ≈ 15~20 cycles，一次多余的整数乘法 ≈ 3 cycles。

---

## 2. 数据布局检查清单

**这是最高优先级的一节。** 拿到一个热点结构体，逐条检查：

- [ ] **热字段与冷字段分离**。订单结构里 `order_id/price/qty/side` 是热的，`client_tag/create_time_str/备注` 是冷的。混在一起会让每次访问都拖入无用字节。拆成 `OrderHot` + `OrderCold`，用 index 关联。
- [ ] **单次访问的数据落在同一条 cache line（64B）**。检查 `sizeof` 和成员偏移（`offsetof`），避免热字段跨行。
- [ ] **成员按大小降序排列**，消除编译器插入的 padding。
- [ ] **SoA vs AoS**：批量只读某一列（如遍历全部档位的 price）用 SoA；每次要整条记录用 AoS。订单簿的价格档通常 SoA 更快。
- [ ] **false sharing**：任何被两个线程分别写入的变量，必须 `alignas(64)` 隔离。生产者的 `write_idx` 和消费者的 `read_idx` 放在同一 cache line 是无锁队列最经典的性能 bug。
- [ ] **指针追逐（pointer chasing）**：链表、`std::map`、`std::unordered_map` 在热路径上是禁止的。改用扁平数组 + 索引、开放寻址哈希、或按价格档做直接寻址数组（`price_level[(px - base) / tick]`）。
- [ ] **顺序访问**：硬件预取器只对顺序/固定步长有效。随机跳转的访问模式要么改布局，要么显式预取（`quant-memory-simd`）。

> 参考：`references/01-memory-model-cache-pipeline.md`、`references/02-memory-alignment-layout.md`

---

## 3. 分支

交易代码里分支多且数据依赖强（价格比较、方向判断、风控检查），分支预测失败是第二大延迟源。

**处理策略，按优先级：**

1. **把分支移出热路径**：配置类判断（是否开启某风控、是哪个交易所）用模板参数或函数指针在启动时定死，而不是每 tick 判一次。
2. **让分支可预测**：把稳定成立的条件（99.9% 的报单不触发风控）用 `[[likely]]` / `__builtin_expect` 标注，让编译器把冷分支移出主流程。
3. **消除分支**：条件赋值改 `cmov`（三目运算 / `std::min` / `std::max`）、查表、算术化（`x * cond`）、位掩码。
4. **分支合并/提前退出**：多条件判断按"最可能为假"的顺序排列，尽早短路。

**注意**：`cmov` 不是万灵药 —— 它把控制依赖变成数据依赖，如果被消除的分支本来预测率就很高（>95%），改成 `cmov` 反而变慢。必须实测。

### 3a. 冷函数标注 `[[gnu::cold]]`

热函数中频繁调用但极少真正执行的错误处理/罕见路径函数，即使调用本身开销不大，也会通过**间接方式**拖慢热路径：

1. **I-cache 污染**：冷函数的指令与热路径指令交织在一起，每次热路径执行都会把冷指令拖进 I-cache，驱逐有用的热代码
2. **分支预测器压力**：编译器不知道分支的概率分布，生成通用分支序列；标注 `cold` 后编译器会生成"几乎不跳转"的形式，CPU 静态分支预测器可以正确预判

**识别信号**（扫描热点函数的 callees）：
- 函数体主要操作是 `fprintf`/`perror`/`exit`/`abort`/`throw`
- 只在 `if (ret < 0)` / `if (errno != 0)` / `if (!ptr)` 等错误守卫中被调用
- 函数名为 `report_error`/`log_warn`/`fatal`/`die`/`panic`/`oom_handler`
- 在 `default:` case 中处理"不应出现"的取值

**语法**：

```cpp
// C++11+ 首选
[[gnu::cold]] void report_error(const char* msg);

// C 或老标准
__attribute__((cold)) void report_error(const char* msg);
```

**标注到定义上，不仅是声明**。编译器在 caller 的编译单元需要看到这个属性才能做代码重排。

**验证方法**：对比标注前后的 `objdump -d`，确认冷函数被移到了热函数 `ret` 指令之后（而不是穿插在热路径中间）。也可以用第 12 节的分支概率测量确认那个分支的 `taken%` 确实接近 0。

**不需要 profiling 数据就可以标注**：只要函数体的语义是"仅限错误/罕见路径"，无条件标注。这不会影响正确性，最坏情况（如果分支实际很热）也只是 C++ 标准允许的 QoI 退化的极小 case。

> 参考：`references/03-branch-optimization.md`

---

## 4. 消除运行时多态

交易系统里典型的滥用：`class Strategy { virtual void on_tick() = 0; }`、`std::function<void(const Tick&)>` 回调链、`Exchange` 基类多态。

替代方案（按适用场景选）：

| 场景 | 方案 |
|---|---|
| 编译期已知的策略/交易所类型 | 模板参数 + CRTP |
| 有限的类型集合，运行时才知道 | `std::variant` + `std::visit`（编译器生成跳转表，可内联各分支） |
| 回调 | 模板化的函数对象，避免 `std::function` 的类型擦除与可能的堆分配 |
| 组合行为 | **组合优于继承**：把行为拆成无状态的 policy 类作为模板参数 |
| 常量计算 | `constexpr` / `consteval`，把 tick size 表、合约乘数表、查找表在编译期算好 |

> 参考：`references/04-composition-over-inheritance.md`、`references/05-compile-time-polymorphism.md`、`references/15-design-patterns.md`

---

## 5. 循环

订单簿遍历、多档位聚合、因子批量计算是主要循环场景。

- **循环不变量外提**：把 `book.levels()` 这类调用提到循环外（编译器常因指针别名而无法自动外提）。
- **展开**：让编译器做（`#pragma GCC unroll N`）；手工展开只在实测有效时保留。
- **多累加器**：浮点求和的依赖链会串行化，用 4~8 个独立累加器打断依赖链后再合并 —— 这是因子计算最常见的免费提速。
- **循环交换 / 分块（tiling）**：多维遍历时保证最内层是连续内存维度；大矩阵按 L2 大小分块。
- **循环分裂/融合**：分裂让每个循环体足够简单以便向量化；融合减少遍历次数与访存。
- **边界**：把 `for (i = 0; i < v.size(); ++i)` 中的 `size()` 提前取出，避免别名导致每轮重载。

> 参考：`references/06-loop-optimization.md`

---

## 6. 指针与别名

编译器无法证明两个指针不重叠时，会保守地反复重载内存，这会毁掉循环优化和向量化。

- 热点函数的入参用 `__restrict__` 标注（确认确实不重叠，否则是 UB）。
- 避免通过 `char*` / `void*` 反复重解释同一块内存。
- 类型双关用 `std::bit_cast`（C++20）或 `memcpy`，**不要**用 `reinterpret_cast` 解引用不同类型（严格别名 UB，`-O3` 下会出真 bug）。
- 局部变量优于反复解引用成员指针：`auto* lvl = &levels_[i];` 一次取出，循环内用局部量。

> 参考：`references/07-pointer-access-optimization.md`、`references/10-raw-memory-bit-representation.md`

---

## 7. 函数与内联

- 热路径函数放头文件，标 `inline`；跨 TU 的用 LTO（`-flto`）。
- `__attribute__((always_inline))` 只用在实测证明编译器判断错误时；滥用会撑爆 I-cache，反而变慢。
- **无法内联的调用**（虚函数、动态库、函数指针）：考虑 PLT 消除（`-fno-plt`）、静态链接、或把调用提出循环。
- **传参**：`sizeof <= 16` 且平凡可复制的按值传（走寄存器）；大结构按 `const&`；不要对小 POD 用 `const&`（多一次间接寻址）。
- 返回大对象靠 RVO/NRVO，别手工"优化"成输出参数从而破坏 RVO。
- `noexcept` 标注让编译器省掉展开路径的代码。

> 参考：`references/08-function-optimization.md`、`references/11-non-inlinable-call-optimization.md`、`references/12-inline-and-inline-asm.md`、`references/16-parameter-passing.md`

---

## 8. 算术与位运算

- 除法/取模是最贵的整数运算（20~40 cycles）。价格档位换算 `(px - base) / tick` 里的 `tick` 若是常量，编译器会转成乘法+移位；若是运行时变量，自己预存 `reciprocal` 或限制为 2 的幂。
- 环形队列容量取 2 的幂，`idx & (N-1)` 代替 `%`。
- 位域压缩订单状态/标志位，让整个订单头挤进一条 cache line；但注意位域读写可能生成多条指令，只在确实省下 cache miss 时用。
- `popcount` / `tzcnt` / `lzcnt` 做档位掩码扫描（找最优价档）比循环快一个数量级。
- 浮点：`-ffast-math` **禁止**用于金额与 PnL；只在明确的信号计算模块局部用 `#pragma GCC optimize` 开启。

> 参考：`references/09-strength-reduction-arithmetic.md`、`references/14-bitfields-and-bit-ops.md`、`references/13-hpc-macros.md`

---

## 9. 边界检查与其他

- `std::vector::operator[]` 在 release 下无检查，但 `at()` 有；热路径统一用 `operator[]` 并在入口处做一次前置校验。
- 通过给编译器"不变量提示"（`__builtin_assume`、`if (n == 0) __builtin_unreachable()`）消除循环内的重复边界检查。
- 自定义 `string`：交易场景的 symbol/instrument id 是短定长的，用 `std::array<char, 8>` 或自定义 SSO 类型，禁止 `std::string`。
- **Magic Static**：函数内 `static` 局部对象每次访问都有线程安全的 guard 检查；热路径改用显式初始化或 `inline constexpr`。

> 参考：`references/17-bounds-check-elimination.md`、`references/18-custom-string.md`、`references/19-magic-static.md`

---

## 10. 验证

每一处改动都要回答：

1. perf 上哪个事件改善了？（`cache-misses`、`branch-misses`、`stalled-cycles-backend`）
2. p99.9 改善了还是只有 p50 改善了？（只改善 p50 对交易系统价值很低）
3. 汇编上确认编译器真的做了这件事（`-S -masm=intel` 或 Compiler Explorer）。

---

## references/ 索引

| 文件 | 内容 |
|---|---|
| `01-memory-model-cache-pipeline.md` | 内存模型、缓存层级、流水线 |
| `02-memory-alignment-layout.md` | 内存对齐与典型布局优化 |
| `03-branch-optimization.md` | 分支优化与分支预测 |
| `04-composition-over-inheritance.md` | 组合优先于继承 |
| `05-compile-time-polymorphism.md` | 编译期多态与编译期计算 |
| `06-loop-optimization.md` | 循环优化 |
| `07-pointer-access-optimization.md` | 指针访存优化 |
| `08-function-optimization.md` | 函数的潜在优化 |
| `09-strength-reduction-arithmetic.md` | 强度削弱与算术优化 |
| `10-raw-memory-bit-representation.md` | 直接操作内存二进制表示 |
| `11-non-inlinable-call-optimization.md` | 无法内联的函数调用优化 |
| `12-inline-and-inline-asm.md` | 内联及内联汇编 |
| `13-hpc-macros.md` | HPC 辅助宏 |
| `14-bitfields-and-bit-ops.md` | 位域与位运算 |
| `15-design-patterns.md` | 常用设计模式 |
| `16-parameter-passing.md` | C++ 函数传参问题及优化 |
| `17-bounds-check-elimination.md` | C++ 边界检查优化技术 |
| `18-custom-string.md` | 自定义 string 实现 |
| `19-magic-static.md` | 避免使用有开销的 Magic Static |
