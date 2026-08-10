# Annotate 模式扫描

对 `perf annotate` 输出的汇编做系统化反模式检查。一个函数可能匹配多个模式。

---

## 前置条件

- 二进制有 debug symbols（`-g`），否则只能看汇编地址
- 先跑 **Check CPU capabilities**：`grep -m1 'flags' /proc/cpuinfo | tr ' ' '\n' | grep -E '^(avx|avx2|avx512f)'` 确定向量宽度层级
- 如果有 `perf stat` 的 IPC 和 cache-miss 率，传入以提高模式 3 和 6 的置信度

---

## 执行

```bash
perf annotate --stdio -l -s <function_name> 2>/dev/null | tee /tmp/annotate_<fn>.txt
```

输出包含源码行（带 within-function 百分比）、汇编指令（带 per-instruction 百分比）、以及源码↔汇编的交织。

---

## 七种模式详解

### 模式 1: Scalar FP — 完全未向量化

**信号**：热指令全部是标量浮点变体——`vmovsd`、`vaddsd`、`vmulsd`、`vfmadd*sd`、`vcvtsd*`——且**没有任何** packed 指令（`vaddpd`、`vmulps`、`vfmadd*ps` 等）。

**置信度**：标量指令占 > 50% 且零条 packed → 高。

**最常见阻断器**：非单位步长的内层循环。如行优先矩阵的列遍历：
```c
for (int j = 0; j < N; j++)
    for (int i = 0; i < N; i++)
        dst[j] += A[i * N + j] * src[i];  // i*N+j: stride=N，编译器无法向量化
```
修复：交换循环顺序使内层步长为 1。

**修复方向**：先检查循环步长和别名（`restrict`），再考虑 SIMD 上转换。

---

### 模式 2: Narrow SIMD — 寄存器宽度不足

**信号**：packed 指令使用 `xmm` 寄存器（128-bit SSE）但 CPU 支持 AVX2 或 AVX-512；或 `ymm` 寄存器（256-bit）在支持 AVX-512 的 CPU 上。

**置信度**：CPU 能力确认支持更宽 + packed 指令在热路径（> 20%）→ 高。

**修复方向**：SIMD 上转换（zipper 算法），每次翻倍向量宽度。

---

### 模式 3: Serial Accumulator — 串行累加器

**信号**：**单一** FP 指令（`vaddss`/`vaddpd`/`vfmadd213ps`/`vfmadd213pd`）独占 > 40% 样本，且**至少一个**子条件成立：
- IPC < 0.5（来自 `perf stat`）
- Cache-miss 率 < 2%
- 指令的源操作数与目的操作数相同寄存器（`vaddss %xmm0, %xmm1, %xmm0`）——明显的依赖链

**置信度**：两个以上子条件成立 → 高；只有独占信号无 `perf stat` → 中。

**修复方向**：并行累加器——4~8 个独立累加器变量打断依赖链后合并。

---

### 模式 4: Horizontal Reduction — 水平归约反模式

**信号**：`shufps`、`addss` 或 `unpckhps` 出现在 `mulps`/`mulss` **之后 3~5 条指令内**。这是编译器将 SIMD 乘法结果做水平归约的签名特征。

**置信度**：该指令簇合计 > 10% → 高。

**修复方向**：并行累加器（水平归约变体）。

---

### 模式 5: Test-and-Set Spin (`lock cmpxchg`)

**信号**：`lock cmpxchg`、`lock xchg` 或 `lock cmpxchg8b` 出现在循环体中（同一或相邻源码行重复出现），占 > 10% 样本。

**置信度**：明显在循环内 → 高；无可见循环上下文 → 中。

**修复方向**：TTAS——在 CAS 之前先用普通 load 检查锁是否释放。

---

### 模式 6: Memory Load Pressure — 内存加载压力

**信号**：load 指令（`vmovsd`/`vmovups`/`movq`/`vmovdqu`/`movaps`）总计 > 30% 样本，但无明显对应计算指令。

**置信度**：中——可能是 cache miss，也可能是数据依赖导致的流水线停顿。加上 `perf stat` 的高 cache-miss 率可提高置信度。

**修复方向**：结构性问题——检查 cache locality、working set 大小、预取机会。不属于已有的简单修复模式。

---

### 模式 7: Atomic Counter Contention — 原子计数竞争

**信号**：`lock add`/`lock inc`/`lock xadd`/`lock sub` 在热路径 > 10%。

**关键区分**（与模式 5 区分）：
- `lock cmpxchg` / `lock xchg` → spinlock/CAS 循环 → 归模式 5
- `lock add` / `lock inc` → **检查后续指令**：
  - 紧跟条件分支（`jz`/`jnz`/`je`）检查结果 → 用 add 实现的锁 → 归模式 5
  - 结果完全被忽略（无分支、无测试，直落） → 统计计数 → Per-thread 累加

**置信度**：明确不在 CAS 重试循环 + 函数名或字段名暗示计数（`count`/`hits`/`stat`/`total`） → 高。

**修复方向**：Per-thread 统计聚合——每线程本地累加，定期/结束时合并。

---

## 格式输出

```markdown
### Pattern scan — `<function_name>`

| Pattern | Evidence | 修复方向 |
|---------|----------|---------|
| Scalar FP | `vaddsd` at 95%; no packed inst | SIMD 上转换 + 检查循环步长 |
| Serial accumulator | `vaddss` 独占 95%, IPC 0.4 | 并行累加器 |
```

无匹配：`No anti-patterns detected in <function_name>.`
