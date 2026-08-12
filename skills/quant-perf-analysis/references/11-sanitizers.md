# Sanitizers：编译时注入的运行时检测

**核心纪律：内存错误、数据竞争、未初始化读取、未定义行为这四类问题，禁止只靠读代码下结论，必须用 sanitizer 实际跑出来。**

原因很直接：这四类 bug 的共同特征是**症状与病因在时空上分离**。越界写坏的是别人的数据，几十万次 tick 之后才在另一个模块崩溃；数据竞争只在特定的核数、编译器版本、指令调度下暴露；未初始化读在 `-O0` 下"碰巧"是 0，在 `-O3` 下变成栈上的残留价格。代码审阅能提出假设，但**不能证伪**——只有插桩运行能。

Sanitizer 由编译器在生成代码时注入检查（shadow memory、影子状态机、检查桩），运行时由对应 runtime 库汇报，因此它看到的是**真实执行的地址与线程交错**，而不是我们脑内的模型。

---

## 1. 四种 sanitizer 对照

| Sanitizer | 编译选项 | 检测什么 | CPU 开销 | 内存开销 | 编译器 |
|---|---|---|---|---|---|
| **ASan**（AddressSanitizer） | `-fsanitize=address` | 堆/栈/全局越界、use-after-free、use-after-return、use-after-scope、double free、无效 free、内存泄漏（LSan） | ~2× | ~2–3×（shadow = 1/8 地址空间） | GCC ≥ 4.8 / Clang |
| **TSan**（ThreadSanitizer） | `-fsanitize=thread` | 数据竞争、锁顺序反转（部分死锁）、线程泄漏、误用 `pthread` API | 5–15× | 5–10× | GCC ≥ 4.8 / Clang |
| **MSan**（MemorySanitizer） | `-fsanitize=memory` | 读取未初始化内存 | ~3× | ~2× | **仅 Clang** |
| **UBSan**（UndefinedBehaviorSanitizer） | `-fsanitize=undefined` | 有符号溢出、除零、空指针解引用、错位对齐访问、移位越界、非法 bool/enum 值、float→int 溢出、VLA 负长度、`__builtin_unreachable` 抵达 | 极低（可 <20%，minimal runtime <1%） | 忽略不计 | GCC ≥ 4.9 / Clang |

### 互斥关系

```
ASan + UBSan + LSan   ✅ 可以同时开（常用组合）
TSan + 任何其他        ❌ 互斥，单独构建
MSan + 任何其他        ❌ 互斥，且要求所有依赖（含 libc++）都用 MSan 编译
```

所以标准做法是维护**三个独立的构建目标**：`build-asan`、`build-tsan`、`build-msan`（或 `build-ubsan` 合并进 asan）。

---

## 2. 编译与运行

### 通用编译选项

```bash
# ASan + UBSan + LeakSanitizer（默认组合）
g++ -std=c++20 -g -O1 -fno-omit-frame-pointer \
    -fsanitize=address,undefined \
    -fsanitize-address-use-after-scope \
    -fno-sanitize-recover=all \
    src/*.cpp -o build-asan/app

# TSan（单独构建）
g++ -std=c++20 -g -O1 -fno-omit-frame-pointer \
    -fsanitize=thread \
    src/*.cpp -o build-tsan/app

# MSan（仅 Clang，且依赖库必须同样插桩）
clang++ -std=c++20 -g -O1 -fno-omit-frame-pointer \
    -fsanitize=memory -fsanitize-memory-track-origins=2 \
    -stdlib=libc++ \
    src/*.cpp -o build-msan/app
```

要点：

- **`-O1` 而不是 `-O0`**。`-O0` 太慢，且内联缺失会改变栈布局；`-O1` 是官方推荐的折中。也可以用 `-O2`，但栈帧信息会变差。
- **`-g -fno-omit-frame-pointer` 必须有**，否则报告只有地址没有行号。
- **`-fno-sanitize-recover=all`** 让第一次报错就退出。CI 里必须加，否则错误被淹没在后续级联报告里。
- 链接也要带 `-fsanitize=...`（runtime 库在链接期注入）。CMake 里同时设 `COMPILE_OPTIONS` 和 `LINK_OPTIONS`。
- MSan 的 `-fsanitize-memory-track-origins=2` 会把"未初始化值是在哪里产生的"也打出来，开销翻倍但通常是唯一能定位的方式。

### 运行时环境变量

```bash
export ASAN_SYMBOLIZER_PATH=$(which llvm-symbolizer)   # 没有它报告全是地址

ASAN_OPTIONS="detect_leaks=1:halt_on_error=1:abort_on_error=1:\
detect_stack_use_after_return=1:check_initialization_order=1:strict_init_order=1:\
strict_string_checks=1:log_path=asan.log" ./build-asan/app

TSAN_OPTIONS="halt_on_error=1:history_size=7:second_deadlock_stack=1:\
suppressions=tsan.supp:log_path=tsan.log" ./build-tsan/app

UBSAN_OPTIONS="print_stacktrace=1:halt_on_error=1" ./build-ubsan/app

MSAN_OPTIONS="halt_on_error=1:poison_in_dtor=1" ./build-msan/app
```

常用项说明：

| 选项 | 作用 |
|---|---|
| `detect_stack_use_after_return=1` | 抓"返回局部变量地址"，默认关闭，务必打开 |
| `check_initialization_order=1` + `strict_init_order=1` | 抓跨 TU 的静态初始化顺序问题（交易系统里常见于全局配置/合约表） |
| `history_size=7` (TSan) | 记录更长的访问历史，报告能给出**两次冲突访问的完整栈**；默认值经常导致 "failed to restore the stack" |
| `second_deadlock_stack=1` | 死锁报告里给出第二个锁的获取栈 |
| `suppressions=` | 屏蔽第三方库的已知误报（**只用于第三方，自己的代码不许屏蔽**） |
| `log_path=` | 报告写文件而不是 stderr，避免与业务日志交织 |

---

## 3. 症状 → sanitizer 选择表

拿到一个 bug，先按症状定位到工具，不要凭直觉猜代码。

| 症状 | 首选 | 备选 |
|---|---|---|
| 段错误、偶发崩溃、堆损坏、`free(): invalid pointer` | **ASan** | Valgrind memcheck |
| 数据结构字段被莫名改写、订单簿价位错乱且无对应行情 | **ASan** | ASan + 手动毒化 |
| 进程 RSS 持续增长 | **ASan/LSan**（`detect_leaks=1`） | heaptrack、massif |
| 多线程结果不可复现、只在高核数/高负载出现、加 `printf` 就好了 | **TSan** | Helgrind |
| 队列计数器/序列号偶尔跳变、消费者读到半写入的结构 | **TSan** | `perf c2c` 交叉验证 |
| 结果依赖优化等级（`-O0` 对、`-O2` 错） | **UBSan** | MSan |
| 结果依赖编译器版本或平台 | **UBSan** | — |
| 数值偶尔出现巨大/负数（定点价格、PnL） | **UBSan**（`signed-integer-overflow`） | 单元测试边界值 |
| Valgrind 报 "uninitialised value"、字段读出来是垃圾 | **MSan** | ASan（不覆盖此类） |
| 类型双关、`reinterpret_cast` 后行为怪异、错位访问 | **UBSan**（`alignment`, `object-size`）+ `-fstrict-aliasing` 告警 | — |

**关键**：ASan 不检测未初始化读，MSan 不检测越界，TSan 不检测内存错误。选错工具会得到"干净"的结果并据此做出错误结论。

---

## 4. 强制调试工作流

遇到上述四类问题，按此顺序执行，**不许跳步、不许用"看代码觉得是 X"替代第 2 步**：

```
0) 症状分类        用第 3 节的表选 sanitizer；不确定就先 ASan+UBSan，再 TSan
1) 建插桩构建      -g -O1 -fno-omit-frame-pointer + 对应 -fsanitize，与 Release 目标分离
2) 复现            用能触发的最小输入跑；跑不出来见第 5 节的"复现不出来怎么办"
3) 读第一条报告    sanitizer 报告有级联性，第 2 条以后往往是第 1 条的后果
4) 只修第一条      一次改一处，附上报告片段作为证据
5) 复跑到 clean    直到 sanitizer 沉默；然后跑完整回放数据再确认一次
6) 回 Release 复测 性能验证必须在无插桩的 Release 构建上做（见第 6 节）
7) 进 CI          把这次的复现用例固化成回归测试，并入 sanitizer 构建的 CI job
```

**报告要求**：结论必须引用 sanitizer 的实际输出（栈 + 地址 + shadow 字节 / 两个冲突访问的栈），而不是"我审阅后认为这里有竞争"。如果 sanitizer 没跑或跑不出来，明确说明"未经插桩验证，以下是假设"。

---

## 5. 复现不出来怎么办

Sanitizer 只能看到**实际执行到的路径**。沉默 ≠ 无 bug。提高复现率的手段：

**通用**
- 用**真实回放行情**而不是合成数据（分支/时序分布完全不同）。
- 跑满一整个交易日的回放，而不是几千条消息。
- 打开边界场景：涨跌停、集合竞价、断线重连、快照重建、队列打满。

**TSan 专用**
- 增加线程数与迭代轮数；在关键点插入随机 `sched_yield()` / 纳秒级随机 sleep 打乱交错。
- **临时取消绑核和实时优先级**——`isolcpus` + `SCHED_FIFO` 会让线程交错高度确定化，反而把竞争藏起来。插桩跑用普通调度。
- 用 `TSAN_OPTIONS=history_size=7` 拿到完整的双栈。
- 对"只在 N 核出现"的问题，同时跑 `perf c2c` 交叉验证竞争的是哪条 cache line（见本 skill 第 11 节）。

**ASan 专用**
- `detect_stack_use_after_return=1`、`quarantine_size_mb=1024`（延长释放块的隔离期，更容易抓到 use-after-free）。
- `malloc_context_size=30` 拿更深的分配栈。

**兜底**
- Valgrind memcheck / Helgrind：不需要重编，能抓到未插桩的第三方库，但慢 50–100×，且 **Helgrind 不理解 C++11 atomics，会对无锁队列大量误报**。只作为 sanitizer 之外的补充，不作替代。

---

## 6. 交易系统特有的坑

### 6.1 插桩构建绝不能用于延迟测量

TSan 会把延迟改变一个数量级并彻底改变线程交错，ASan 改变内存布局与 cache 行为。**任何 p50/p99 数字必须来自无插桩的 Release 构建。** 插桩构建只回答"对不对"，不回答"快不快"。

### 6.2 自定义内存池让 ASan 失明

热路径上禁止 `malloc`，所以对象都来自内存池/arena。ASan 只知道底层那一次大块分配，池内的越界与 use-after-free 它看不见。解决办法是手动毒化：

```cpp
#if defined(__SANITIZE_ADDRESS__) || __has_feature(address_sanitizer)
#  include <sanitizer/asan_interface.h>
#  define POOL_POISON(p, n)   __asan_poison_memory_region((p), (n))
#  define POOL_UNPOISON(p, n) __asan_unpoison_memory_region((p), (n))
#else
#  define POOL_POISON(p, n)   ((void)0)
#  define POOL_UNPOISON(p, n) ((void)0)
#endif

void* Pool::acquire() {
    void* p = free_list_.pop();
    POOL_UNPOISON(p, slot_size_);       // 交出去时解毒
    return p;
}
void Pool::release(void* p) {
    POOL_POISON(p, slot_size_);         // 收回时毒化 → 之后再访问即报 use-after-free
    free_list_.push(p);
}
```

MSan 对应的是 `__msan_allocated_memory()` / `__msan_poison()`。

**没做这一步的内存池，ASan 报告 clean 是没有意义的。**

### 6.3 TSan 与无锁代码

- TSan **理解 C++11/20 `std::atomic` 及其 `memory_order`**，能正确判定 acquire/release 建立的 happens-before。用标准原子写的 SPSC/SPMC 队列可以直接跑。
- TSan **不理解手写内联汇编屏障**（`asm volatile("" ::: "memory")`、`mfence`、自实现的 `lock cmpxchg` 自旋锁）。这类代码会产生**大量误报**。解决办法是显式注解同步边：

```cpp
#include <sanitizer/tsan_interface.h>
// 释放侧：告诉 TSan 此处发布了之前的所有写
__tsan_release(&slot);
// 获取侧：告诉 TSan 此处观察到了对应的发布
__tsan_acquire(&slot);
```

- 确实有意的、经过论证的 benign race（几乎不存在，绝大多数"benign"是错的）：

```cpp
__attribute__((no_sanitize("thread")))
uint64_t read_stat_relaxed() { ... }   // 必须在注释里写明为什么安全
```

  写这个标注等同于承诺"我已论证过"，必须留下理由。默认答案是改代码，不是加标注。

### 6.4 共享内存与 mmap

ASan 不追踪 `mmap`/`shm_open` 得到的区域，跨进程队列的越界它看不到。TSan 也不跨进程检测竞争。跨进程正确性要靠：magic/version 校验、序列号连续性断言、写入前后的 canary 字段，以及单进程模式下用 sanitizer 先把逻辑跑干净。

### 6.5 UBSan 正好抓定点数溢出

价格 × 数量的 `int64` 定点运算溢出是静默的，UBSan 的 `signed-integer-overflow` 直接报出来，且开销极低。这是把 UBSan 纳入常规构建的最强理由。

```bash
-fsanitize=signed-integer-overflow,shift,integer-divide-by-zero,bounds,alignment,null,return
```

### 6.6 生产环境可开启的最小检查

完整 sanitizer 不能上生产，但以下开销可接受：

```bash
# UBSan trap 模式：无 runtime 库，命中即 SIGILL，开销 <1%
-fsanitize=undefined -fsanitize-trap=undefined -fsanitize-minimal-runtime

# 标准库断言 + 栈保护
-D_GLIBCXX_ASSERTIONS -fstack-protector-strong -D_FORTIFY_SOURCE=3
```

`-D_GLIBCXX_ASSERTIONS` 会给 `vector::operator[]`、迭代器等加边界检查——热路径上要实测其影响后再决定，冷路径无脑开。

---

## 7. 抑制与忽略

```
# tsan.supp —— 只用于第三方库
race:^third_party::LegacyLogger::
called_from_lib:libvendor_md.so
```

```bash
# 编译期忽略清单
-fsanitize-ignorelist=sanitize-ignore.txt
```

**规则**：抑制只允许指向第三方二进制/源码。对自己的代码写抑制等于关掉检测，必须在 code review 里被拒绝。每条抑制项都要有注释说明来源与失效条件。

---

## 8. CMake 集成

```cmake
set(SANITIZER "" CACHE STRING "none|asan|tsan|msan")

if(SANITIZER STREQUAL "asan")
    set(SAN_FLAGS -fsanitize=address,undefined
                  -fsanitize-address-use-after-scope
                  -fno-sanitize-recover=all)
elseif(SANITIZER STREQUAL "tsan")
    set(SAN_FLAGS -fsanitize=thread -fno-sanitize-recover=all)
elseif(SANITIZER STREQUAL "msan")
    set(SAN_FLAGS -fsanitize=memory -fsanitize-memory-track-origins=2)
endif()

if(SAN_FLAGS)
    add_compile_options(-g -O1 -fno-omit-frame-pointer ${SAN_FLAGS})
    add_link_options(${SAN_FLAGS})
endif()
```

CI 里至少三个 job：`asan+ubsan`、`tsan`、`release`（跑基准）。TSan job 用回放行情跑满一日数据，不要只跑单测——单测的线程交错太规整。

---

## 9. 局限与补充工具

| 工具 | 补 sanitizer 的什么缺口 |
|---|---|
| `perf c2c` | TSan 说"有竞争"，c2c 说"是哪条 cache line、false 还是 true sharing" |
| Valgrind memcheck | 覆盖未插桩的第三方 `.so` |
| `-fanalyzer`（GCC）/ clang-tidy / cppcheck | 静态分析，覆盖没执行到的路径；与 sanitizer 互补而非替代 |
| 模糊测试（libFuzzer + ASan） | 自动生成触发路径，特别适合协议解析器（FIX、二进制行情解包） |
| Hardware ASan（ARM64 `-fsanitize=hwaddress`） | 开销远低于 ASan，可长时间挂机跑 |

**最后重申**：sanitizer clean 只证明"这次执行的这些路径上没发现问题"，不证明代码正确。它是**必要**条件，不是充分条件。但反过来，没跑 sanitizer 就断言"这里没有竞争/没有越界"，是没有依据的猜测。
