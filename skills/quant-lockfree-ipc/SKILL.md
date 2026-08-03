---
name: quant-lockfree-ipc
description: 交易系统的无锁并发与进程间通信 — SPSC/SPMC 无锁队列与 micro-batching、共享内存队列、双缓冲+原子索引、自定义自旋锁、wait-free 编程、内存序(acquire/release)、C++20 协程调度、线程安全缓存/队列、socket 与 TCP/UDP/组播。Use for lock-free queue, ring buffer, SPSC, SPMC, shared memory, IPC, atomic, memory_order, CAS, spinlock, false sharing in queues, wait-free, coroutine scheduler, thread-safe cache, 无锁队列, 共享内存, 内存序, 自旋锁, 协程, 组播行情, or designing producer/consumer paths between market-data and strategy threads.
license: CC-BY-4.0
metadata:
  version: "1.0.0"
  source: "trading-system-notes-Chinese.md 《交易系统开发》张智炫"
---

# 无锁并发与 IPC（Lock-free & IPC）

交易系统的线程模型基本固定：**行情线程 → 策略线程 → 报单线程**，加上旁路的日志/监控线程。本 skill 处理这些边界上的数据传递。

**第一原则**：先问"能不能不通信"。单线程跑完整条 tick-to-trade 链路（run-to-completion）几乎总是比多线程 + 队列更快、更确定。只有当单核放不下（多交易所、多品种）时才拆线程。

---

## 1. 选型决策表

| 场景 | 方案 |
|---|---|
| 一个生产者 → 一个消费者，同进程 | **SPSC 环形队列**（最快，无 CAS，只需 acquire/release） |
| 一个生产者 → N 个消费者，每个都要全量数据（行情分发） | **SPMC 广播环**（消费者各持独立读游标，不修改共享状态） |
| 一个生产者 → N 个消费者，任务分摊 | MPMC 队列或分片 SPSC（优先分片） |
| 跨进程行情分发 | **共享内存 SPMC 环**（`/dev/shm` + `mmap`），最低延迟的 IPC |
| 只需要最新快照，不需要每条 | **双缓冲 + 原子索引**（读者永不阻塞，天然 wait-free 读） |
| 需要跨机器 | UDP 组播（行情）+ TCP（报单），见第 6 节 |
| 冷路径任务队列 | 直接用锁，别过度设计 |

---

## 2. SPSC 环形队列要点

```
容量取 2 的幂          → idx & (N-1) 代替取模
head/tail 各自 alignas(64) → 消除 false sharing（最经典的性能 bug）
缓存对端游标的本地副本  → 减少跨核读取共享变量的次数
store(release) / load(acquire) → x86 上是零成本，别用 seq_cst
数据槽位定长 POD       → 避免构造/析构和间接寻址
```

**内存序速查**（x86-64）：
- 生产者：写数据 → `tail.store(next, release)`
- 消费者：`tail.load(acquire)` → 读数据 → `head.store(next, release)`
- `seq_cst` 在 x86 上会生成 `mfence`/`lock` 前缀，**真实开销约 20~30 cycles**，热路径禁用。
- 不要用 `relaxed` 传递数据可见性；只有纯计数器（统计）才用 `relaxed`。

### Micro-batching

队列的每次 `push/pop` 都有固定开销（原子操作、cache line 转移）。当上游是突发流量（行情快照、逐笔成交批）时：

- 生产者积攒 N 条或 T 微秒后一次性发布（只更新一次 tail）。
- 消费者一次 `load` 后连续消费到本地缓存的 tail，中间不再读共享变量。

**这是吞吐与延迟的显式取舍**：batch 变大，吞吐上升、尾延迟上升。交易系统通常取"消费者侧自适应批"—— 空闲时逐条处理（最低延迟），积压时自动成批（追赶）。这样不牺牲低负载下的延迟。

> 参考：`references/01-lockfree-queue-micro-batching.md`

---

## 3. 共享内存 SPMC（跨进程行情分发）

结构：
```
[ header: 对齐到 cache line 的 write_seq, 元数据 ]
[ slot 0 ][ slot 1 ] ... [ slot N-1 ]   ← N 为 2 的幂，定长 POD
```

**发布协议（seqlock 变体）**，读者永不阻塞写者：
1. 写者：`seq++`（变奇数，release）→ 写数据 → `seq++`（变偶数，release）
2. 读者：读 `seq`（acquire）→ 读数据 → 再读 `seq`，若不等或为奇数则重试

要点：
- 共享内存段用大页 + `mlock`，避免缺页与换出。
- **消费者慢导致覆盖**是设计的一部分：读者检测到序号跳变即知道自己被甩开，应该重新同步快照而不是阻塞写者。行情分发宁可丢也不能堵。
- 进程崩溃后共享内存中的锁会成为孤儿 —— 这正是**不要在共享内存里放 mutex** 的原因，只放原子序号。
- 布局要用 `#pragma pack` 或显式定长字段，保证不同编译单元/进程的 ABI 一致；加一个 magic + version 字段做启动校验。

> 参考：`references/02-spmc-shared-memory-queue.md`

---

## 4. 双缓冲 + 原子索引

适用于"只关心最新值"的场景：参数热更新、风控限额表、最新快照。

```cpp
T buffers[2];
std::atomic<size_t> cur;   // 读者读 buffers[cur]，写者写 buffers[1-cur] 后翻转
```

- 写者：写 `1-cur` → `atomic_thread_fence(release)` → `cur.store(next, relaxed)`
- 读者：`cur.load(relaxed)` → `atomic_thread_fence(acquire)` → 读

**陷阱**：读者持有指针期间写者可能翻转两次覆盖它。安全用法是读者**立刻拷贝出需要的字段**，或用三缓冲 + 引用计数（epoch）保证 in-flight 读者不被覆盖。参数表这类低频更新场景，双缓冲足够；高频更新必须上三缓冲/RCU。

> 参考：`references/03-double-buffer-atomic-index.md`

---

## 5. 自旋锁、wait-free 与协程

### 自旋锁

只在**临界区极短（< 100ns）且线程已绑核**时才优于 mutex。实现要点：
- **TTAS**（test-test-and-set）：先 `load` 自旋，失败才 `exchange`，避免 cache line 乒乓。
- 自旋体内加 `_mm_pause()` / `__builtin_ia32_pause()`，降低超线程兄弟核的竞争与功耗。
- 有界自旋 + 退避到 `sched_yield()`/futex，防止在核不够时活锁。
- **绝不**在持有自旋锁时做系统调用、分配内存或可能缺页的操作。

### wait-free

保证每个线程在有限步内完成，无论其他线程如何。交易系统里真正需要 wait-free 的是**读路径**（不能因为写者被抢占而卡住行情处理）。典型手段：seqlock 读、双缓冲读、单写者多读者的原子发布。

写路径通常 lock-free（CAS 循环）就够了。

### C++20 协程

价值在于**冷/温路径的异步逻辑**（订单状态机、重连、多腿套利的等待逻辑）写起来是同步风格。
**不要**把协程放进 tick-to-trade 热路径：`co_await` 的挂起/恢复涉及帧的堆分配（除非 HALO 优化生效）和间接跳转。若要用，必须自定义 `promise_type` 的 `operator new` 走内存池，并在汇编层确认帧被省略。

> 参考：`references/04-custom-spinlock.md`、`references/06-wait-free-programming.md`、`references/05-cpp20-coroutine-scheduler.md`

---

## 6. 网络与 socket

| 用途 | 协议 | 关键配置 |
|---|---|---|
| 行情接收 | UDP 组播 | `SO_RCVBUF` 调大、`SO_REUSEPORT` 多队列、内核旁路（DPDK/ef_vi/onload）视需求 |
| 报单 | TCP | `TCP_NODELAY`（关 Nagle）、`TCP_QUICKACK`、预连接预热、`SO_BUSY_POLL` |
| 内部 | 共享内存 | 见第 3 节 |

其他要点：
- **忙轮询 vs 阻塞**：热路径用 `recvmmsg` 忙轮询或 `epoll` + busy-poll，别用阻塞 + 线程唤醒（唤醒延迟数 μs 且抖动大）。
- `sendmsg` 的系统调用开销 ~1μs 级；报单路径考虑预序列化（见 `quant-trading-systems`）把序列化提前，只留 write。
- 组播丢包与乱序是常态：必须有序列号检查 + 快照重建路径。
- 时间戳：用 `SO_TIMESTAMPING` 拿硬件时间戳来测真实网络延迟，而不是用户态时钟。

> 参考：`references/09-sockets-tcp-udp.md`

---

## 7. 线程安全容器

`references/07-thread-safe-cache.md` 与 `08-thread-safe-queue.md` 给出了通用实现。用于交易系统时注意：

- 通用线程安全缓存（分片锁 + LRU）适合**温路径**（合约静态信息、参数缓存），不要放热路径。
- 热路径的"缓存"应该是启动时构建好的只读扁平表，通过双缓冲做热更新。

---

## 8. 检查清单

- [ ] 能否用单线程 run-to-completion 消除这个队列？
- [ ] 生产者/消费者游标是否 `alignas(64)` 分离？
- [ ] 内存序是否是最弱的正确选择（不是 `seq_cst`）？
- [ ] 队列满/空时的行为定义了吗？（行情丢弃 + 告警 vs 报单阻塞 + 背压，两者策略相反）
- [ ] 共享内存里没有 mutex，只有原子序号？有 magic/version 校验？
- [ ] 消费者被甩开时能检测到并重新同步？
- [ ] 自旋锁有 pause + 有界自旋？
- [ ] 有 ThreadSanitizer / 压力测试覆盖并发路径？

---

## references/ 索引

| 文件 | 内容 |
|---|---|
| `01-lockfree-queue-micro-batching.md` | lock-free queue 与 micro-batching |
| `02-spmc-shared-memory-queue.md` | SPMC 共享内存无锁队列应用 |
| `03-double-buffer-atomic-index.md` | 双数组 + 原子索引 |
| `04-custom-spinlock.md` | 自定义自旋锁实现 |
| `05-cpp20-coroutine-scheduler.md` | C++20 协程调度框架 |
| `06-wait-free-programming.md` | wait-free 编程 |
| `07-thread-safe-cache.md` | 线程安全缓存实现 |
| `08-thread-safe-queue.md` | 线程安全队列实现 |
| `09-sockets-tcp-udp.md` | socket 技术及 TCP/UDP |
