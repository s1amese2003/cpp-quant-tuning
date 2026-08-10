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

## 9. 条件变量惊群（CV Thundering Herd）

当 `notify_all()` 或循环 `notify_one()` 唤醒远超实际可消费任务数的线程时，**浪费的唤醒在高核数下成为主导开销**。这个问题被 `perf lock stat` 漏掉（锁持有/等待时间正常），但 `perf trace -e futex` 会暴露真相。

### 识别信号

**源码侧**：
- `pthread_cond_broadcast(&cv)` 或 `cv.notify_all()` 叫醒整个线程池，但只有少量线程有活干
- `notify_one()` 放在循环里逐个唤醒 N 个线程（O(N) 个 futex 系统调用）
- dispatcher 无差别唤醒所有线程：`for (i = 0; i < nthreads; i++) wake(thread[i])`
- worker 被唤醒后 `sched_yield()` 或立即重新阻塞 —— 白被叫醒

**perf 侧**：
```bash
perf trace -e futex -p <PID> 2>&1 | grep WAKE
# 看 freq 和 val：高频 FUTEX_WAKE + val=INT_MAX → 广播惊群；
# 高频 val=1 bursts → notify_one 循环

perf stat -e context-switches -C <isolated_cores> -a sleep 10
# 上下文切换率随等待线程数线性增长
```

**与锁竞争的区分**：

| 症状 | 锁竞争 | CV 惊群 |
|------|--------|---------|
| `perf top` 热符号 | `native_queued_spin_lock_slowpath` | `futex_wake`, `try_to_wake_up` |
| `perf lock stat` wait_total | 高 | 正常 |
| context-switch 率 | 中等 | 极高 |
| futex WAKE 频率 | 低 | 高 |
| IPC | 随核数缓慢下降 | 崩溃式下降（核在忙调度而非计算） |

### 为什么会慢

`notify_all()` 唤醒 N 个 waiter 的时间线：
```
t0: notify_all() → N 个线程同时变为 runnable
t1: 所有 N 个争抢 mutex（CV 语义强制）→ 1 个获胜，N-1 个立即阻塞在 mutex 上
t2: N-1 个失败者各付一次完整 futex 往返（唤醒→调度→尝试获取→失败→休眠）
t3: 线程逐个被唤醒，大多数检查 predicate 后发现无工作，再次休眠
```

每次 `notify_all` 的成本：O(N) 上下文切换 + O(N) futex 系统调用 + O(N) IPI（核间中断）+ mutex cache line 的 RFO 风暴。

### 修复策略

**策略 1: 精确唤醒**（首选）
只唤醒实际有工作可做的线程。如果只有 J 个 job，只唤醒 J 个 worker（用 `notify_one()` J 次或每个 worker 有独立 CV）。

**策略 2: 工作窃取**
worker 醒来后在共享队列中取任务，没取到就继续睡。适合任务数不固定的场景。

**策略 3: 分层唤醒**
先唤醒少量线程；如果仍有积压，被唤醒的线程负责唤醒下一批（级联）。

### 验证

修复后用 `perf trace -e futex` 确认 WAKE 频率显著下降；`perf stat -e context-switches` 确认 cs/s 降回合理水平。

> 参考：`references/10-cv-thundering-herd.md`

---

## 10. Mutex 转读写锁（Mutex-to-RWLock）

一个 mutex 保护的数据被大量线程**只读**访问（查找、搜索、状态查询），只有极少数路径写。在高核数下，所有读者在 mutex 上串行化，即使它们之间完全不冲突。

### 识别信号

**源码侧**：
- `pthread_mutex_lock()` 保护的临界区，常见路径只做读操作
- 写入只发生在罕见分支（创建新条目、插入、更新）
- 读写比 > ~75%（这是 rwlock 开始胜出的交叉阈值）

**perf 侧**：
```bash
# 内核 mutex：看 osq_lock（Optimistic Spin Queue，mutex 自旋阶段）
# 用户空间 pthread mutex：看 pthread_mutex_lock / __lll_lock_wait
perf report --stdio --no-children | grep -E 'osq_lock|mutex_lock|pthread_mutex|futex_wait'

# 确认锁特征：contention 高、wait 远大于 hold
perf lock stat -- <workload>
```

**关键信号**：IPC 随核数增加而显著下降，但用户空间的 workload 没变——多出来的 cycles 都是锁串行化开销。

### 为什么会慢

即使 N 个线程都只做只读操作，mutex 对每个线程都要做 LOCK CMPXCHG（RFO），把锁的 cache line 拉到 Modified 状态。每个读者必须等前一个读者释放锁后才能获取：

```
Mutex + N readers（全部串行化）：
Thread 1: [LOCK CMPXCHG → M] read [unlock → store]
Thread 2:  ← 等待(RFO pending) → [LOCK CMPXCHG → M] read [unlock]
...
Thread N:  ← 等完前面 N-1 个
```

### 修复

```cpp
// 改前
pthread_mutex_t m = PTHREAD_MUTEX_INITIALIZER;
pthread_mutex_lock(&m);
value = lookup(key);   // 只读操作
pthread_mutex_unlock(&m);

// 改后
pthread_rwlock_t rw = PTHREAD_RWLOCK_INITIALIZER;
pthread_rwlock_rdlock(&rw);    // 多个读者可并发
value = lookup(key);
pthread_rwlock_unlock(&rw);

// 写路径用 wrlock（互斥）
pthread_rwlock_wrlock(&rw);
insert(key, value);
pthread_rwlock_unlock(&rw);
```

### 陷阱

- **rwlock 本身有开销**（内部有原子计数器），临界区极短时（< 几十 ns）rwlock 可能比 mutex 更慢。**必须实测**。
- 写者可能被饿死（读者不断涌入）。如果写延迟也有硬性要求，考虑 `pthread_rwlockattr_setkind_np` 设置写者优先。
- **不要**在内核态不睡眠的临界区用 `rwlock_t`（那是 spin-based 的，不是睡眠锁）；需要睡眠的内核上下文用 `rw_semaphore`。

> 参考：`references/11-mutex-to-rwlock.md`

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
| `10-cv-thundering-herd.md` | 条件变量惊群：notify_all 过度唤醒的诊断与修复 |
| `11-mutex-to-rwlock.md` | Mutex 转读写锁：读为主场景的并发优化 |
