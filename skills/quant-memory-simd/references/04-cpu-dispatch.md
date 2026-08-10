# CPU 运行时分派

手写 SIMD intrinsics 时，编译期 `-march=native` 让二进制绑定到编译机器，无法在旧 CPU 上运行。**运行时 CPU 分派**让同一二进制在所有机器上自动选择最快路径。

---

## 决策表

| 场景 | 推荐机制 |
|------|---------|
| 纯 C/C++ 循环，编译器自动向量化 | `target_clones` |
| 手写 `_mm_*`/`_mm256_*` intrinsics 或内联 asm | `__builtin_cpu_supports` |
| 现有代码已有 `target_clones`，需加新 ISA 级别 | 扩展 clone 列表 |
| 跨编译器 / 非 x86 目标 | `__builtin_cpu_supports`（更可移植） |

不确定时选 `__builtin_cpu_supports`——对所有场景有效，dispatch 逻辑显式可审计。

---

## 机制 A: `target_clones`（编译器驱动）

编译器为每个 ISA 级别生成函数克隆体，由 IFUNC resolver 在加载时选择。

### 硬限制

- `target_clones` **不会升级已有 intrinsics**。代码中写了 `_mm256_*`，编译器不会为 AVX-512 clone 自动升级到 `_mm512_*`。这种场景必须用机制 B。
- 函数必须 **non-static**（IFUNC resolver 需要外部符号）
- 函数必须有效 **noinline**——如果编译器在每处调用都内联了，IFUNC 不会被生成。始终配 `__attribute__((noinline))`

### ISA target strings

用**特性名**，不是微架构级别名。`x86-64-v3`/`x86-64-v4` 在 GCC 的 `target_clones` 属性中**不被接受**：

| Clone 字符串 | 启用指令集 | 最低 CPU |
|-------------|-----------|---------|
| `"default"` | SSE2（x86-64 基线） | 任意 x86-64 |
| `"avx2,fma"` | AVX2 + FMA | Haswell (2013) |
| `"avx512f"` | AVX-512F | Skylake-X (2017) / Ice Lake (2019) |

`"default"` 必须作为最后一个入口——它是 fallback。

### 项目级宏模板

放在共享 header 中，非 x86 上自动退化为空：

```c
#ifndef __target_clones
#  ifdef __x86_64__
#    define __target_clones \
         __attribute__((noinline, target_clones("default", "avx2,fma", "avx512f")))
#  else
#    define __target_clones   /* non-x86: no-op */
#  endif
#endif
```

### 使用

```c
__target_clones
void compute(const float *src, float *dst, int n) {
    // 纯 C 循环——编译器生成 default/AVX2/AVX-512 三份
    for (int i = 0; i < n; i++)
        dst[i] = fmaf(src[i], alpha, beta);
}
```

### 验证 clone 是否生成

```bash
nm ./binary | grep compute
# 应看到 compute.default, compute.avx2_fma, compute.avx512f 等
```

---

## 机制 B: `__builtin_cpu_supports`（手动分派）

对手写 intrinsics 的不同宽度版本做显式选择。

### 基础模板

```c
#include <stddef.h>

// 每个版本标注 target attribute
__attribute__((target("default")))
void compute_scalar(const float *src, float *dst, size_t n) {
    for (size_t i = 0; i < n; i++)
        dst[i] = src[i] * 2.0f;
}

__attribute__((target("avx2")))
void compute_avx2(const float *src, float *dst, size_t n) {
    // void 的 n 大小尾部分在调用处处理
    size_t i = 0;
    for (; i + 8 <= n; i += 8) {
        __m256 v = _mm256_loadu_ps(src + i);
        v = _mm256_add_ps(v, v);  // ×2
        _mm256_storeu_ps(dst + i, v);
    }
    // 尾部标量处理由外层 uniform call site 负责
}

__attribute__((target("avx512f")))
void compute_avx512(const float *src, float *dst, size_t n) {
    size_t i = 0;
    for (; i + 16 <= n; i += 16) {
        __m512 v = _mm512_loadu_ps(src + i);
        v = _mm512_add_ps(v, v);
        _mm512_storeu_ps(dst + i, v);
    }
}

// Dispatch — 启动时解析一次
typedef void (*compute_fn)(const float*, float*, size_t);

compute_fn resolve_compute(void) {
    if (__builtin_cpu_supports("avx512f"))  return compute_avx512;
    if (__builtin_cpu_supports("avx2"))     return compute_avx2;
    return compute_scalar;
}

// 全局函数指针，启动时赋值
static compute_fn compute_ptr = NULL;

void compute(const float *src, float *dst, size_t n) {
    if (__builtin_expect(compute_ptr == NULL, 0))
        compute_ptr = resolve_compute();
    compute_ptr(src, dst, n);
}
```

### 特征名字符串

GCC/Clang 接受的 `__builtin_cpu_supports` 参数（特性名用小写+点号，不同于 `/proc/cpuinfo` 的下划线）：

```
sse4.2    avx       avx2      avx512f   avx512dq
avx512bw  avx512vl  avx512vnni fma       bmi
bmi2      popcnt    aes       pclmul    sha
```

注意：`/proc/cpuinfo` 用下划线（`avx512f`），`__builtin_cpu_supports` 用点号（`"avx512f"` 不加点），两者格式不同。习惯上用 `/proc/cpuinfo` 的名字直接传给 `__builtin_cpu_supports` 通常也能工作，但文档不保证。

### 关键纪律

1. **每个 `_mm_*` 版本必须标注 `target` attribute**：含 `_mm256_*` 的函数标 `target("avx2")`，含 `_mm512_*` 的标 `target("avx512f")`。否则编译器可能用 baseline 编译该 TU 但函数内使用了 baseline 不支持的指令 → 编译错误或运行时 SIGILL。

2. **Dispatch 只在启动时跑一次**，结果存到函数指针。不要在热路径上做 CPU 检测。

3. **不要用 `#ifdef __AVX2__`**：这是编译期宏，生成的二进制如果在非 AVX2 机器上跑，会静默执行 scalar fallback（甚至直接 SIGILL）。运行时 dispatch 让同一二进制适配所有机器。

4. **标量尾部处理**：SIMD 版本处理 `n / width * width` 个元素后，调用方负责尾部标量处理。或者在每个 SIMD 函数内处理尾部（代码膨胀但调用方简单）。

---

## 两种机制对比

| 维度 | `target_clones` | `__builtin_cpu_supports` |
|------|----------------|--------------------------|
| 代码量 | 一份源码，编译器生成多份 | 手写多份 |
| ISA 控制 | 编译器决定向量化宽度 | 完全可控 |
| intrinsics | ❌ 不能升级已有 intrinsics | ✅ 最高版本可用任何指令 |
| 跨编译器 | GCC/Clang 均有 IFUNC 差异 | 主要编译器均支持 |
| 内联 | 必须 noinline | 可内联 dispatch wrapper |
| 调试 | clone 符号名在 objdump 可见 | 函数名直接对应 |
