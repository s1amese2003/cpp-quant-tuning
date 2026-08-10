# 分支概率测量

`[[likely]]`/`__builtin_expect` 只是给编译器的**静态**提示。要知道运行时分支的真实概率，需要实测。两个互补方法：Intel PMU 事件（最准确）和 GCC 静态估计（快速代理）。

---

## 方法 A: Intel PMU（最准确，仅 Intel CPU）

### 前置检查

```bash
grep -q 'vendor_id.*GenuineIntel' /proc/cpuinfo || echo "NOT Intel — PMU method not available"
```

### Step 1: 记录分支事件

```bash
perf record -c 1000 \
  -e '{BR_INST_RETIRED.NEAR_TAKEN:upp,BR_INST_RETIRED.NOT_TAKEN:upp,cycles:u}' \
  -o /tmp/branch.data ./binary
```

- `:upp` = user-space, precise, precise-IP — 减少采样偏移
- `-c 1000` 采样周期；短期负载可降到 `-c 100`
- 事件组 `{...}` 确保三个事件在同一采样点计数

### Step 2: Annotate

```bash
perf annotate --source --no-vmlinux -l -n --stdio -i /tmp/branch.data > /tmp/branch.annotate
```

每行格式：`NEAR_TAKEN  NOT_TAKEN  CYCLES :  ADDR:  MNEMONIC`

### Step 3: Macrofusion 修正

x86 CPU 可将 `cmp`/`test` 与后续条件跳转融合为一个微操作。此时 PMU 把两个计数都归到 `cmp` 而非跳转指令。

修正方法：
- 找到紧邻条件跳转前、有非零 col1/col2 但本身非跳转的指令
- 把计数从该指令搬到条件跳转
- 清零该指令的计数

### Step 4: 计算 Taken%

对每个条件跳转：
```
taken% = 100 × NEAR_TAKEN / (NEAR_TAKEN + NOT_TAKEN)
```

用 `addr2line` 解析地址到源码行：
```bash
addr2line -e ./binary ADDR1 ADDR2 ...
```

### Step 5: 输出格式

按 sample 数降序排列：

| Taken% | Samples | Source line | Branch target | Assembly |
|-------:|--------:|------------:|--------------:|----------|
| 91.2% | 607094  | :11         | :18           | `ja ...`  |
| 0.3%  | 412     | :27         | :42           | `je ...`  |

### Step 6: 解读

| Taken% | 含义 | 行动 |
|--------|------|------|
| < 0.1% | 强冷分支 | 目标 callee 标 `[[gnu::cold]]` |
| ~50% | 不可预测 | 考虑 `cmov` 消除分支 |
| > 99.9% | 强热分支 | `[[likely]]` 确认 |
| 0% 或 100% | 完全可预测 | 分支预测器无开销，不是优化目标 |

---

## 方法 B: GCC 静态估计（无 workload / 跨平台）

不需要跑 workload，GCC 用启发式规则估算。也可用于对比 perf 数据找分歧。

### Step 1: 编译时 dump profile-estimate

```bash
mkdir -p dump/
gcc -g -fdump-tree-profile_estimate-lineno -dumpdir dump/ foo.c -o foo
ls dump/*.profile_estimate
```

### Step 2: 读 dump 文件

文件命名格式：`<source>.NNNt.profile_estimate`。打开后搜索函数名：

```
;; Function process_data (process_data, ...)

  [foo.c:11:8] if (_2 == 0)
    goto <bb 3>; [50.00%]
  else
    goto <bb 5>; [50.00%]
```

`[X.XX%]` 是 GCC 对该边的估计概率。

### Step 3: 与 perf 数据对比

| 情况 | 含义 | 行动 |
|------|------|------|
| GCC 热 / perf 冷 | 编译器误判 | 标 `[[unlikely]]` 或 callee 标 `[[gnu::cold]]`，收益大 |
| GCC 冷 / perf 热 | 编译器误判反向 | 标 `[[likely]]` |
| GCC ~50-50 / perf 强偏 | 数据依赖行为，编译器无法静态推断 | 手动标分支提示或 `cmov` |

---

## 通用注意事项

- 分支概率是 **workload-dependent**：用真实行情回放，不要用合成数据。合成数据的分支分布与生产完全不同。
- 每次代码改动后重测——编译器可能因代码布局变化而改变分支序列。
- `__builtin_expect` 和 `[[likely]]`/`[[unlikely]]` 影响编译器布局但不改变 CPU 动态预测器。动态预测器的训练来自于实际执行历史——静态提示只帮助编译器做代码布局。
