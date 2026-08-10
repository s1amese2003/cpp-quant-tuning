# Mutex 转读写锁（Mutex-to-RWLock）

Mutex 保护的临界区中**绝大多数操作只读取**数据时，所有读者在高核数下被强制串行化——即使它们之间完全不冲突。此时 rwlock 是直接有效的替代方案。

---

## 适用条件

### ✅ 应该转换

- 临界区的常见路径只做读取（查找、搜索、缓存查询、状态检查、配置读取）
- 写入发生在罕见分支（新条目创建、偶尔更新、配置变更）
- 读写比 > ~75%（rwlock 的额外原子开销在此阈值后被并发收益覆盖）
- 高核数场景（8+ 核并行访问同一数据）

### ❌ 不应转换

- 临界区极短（< 几十 ns）——rwlock 的原子计数开销可能比 mutex 的串行化更贵。**必须实测**
- 读写比接近 50/50 —— rwlock 的写饥饿问题会恶化
- 单线程或低核数场景 —— mutex 的 fast path 足够快

---

## 诊断

### 内核 mutex

```bash
perf report --stdio | grep -E 'osq_lock|mutex_lock|__mutex_lock_slowpath'
```

- `osq_lock`（Optimistic Spin Queue）——mutex 的自旋阶段。高占比说明大量线程在 mutex 上旋转等待
- `__mutex_lock_slowpath` —— 进入睡眠路径
- `native_queued_spin_lock_slowpath` 出现在 mutex_lock 调用链下

### 用户空间 pthread mutex

```bash
perf report --stdio | grep -E 'pthread_mutex_lock|__lll_lock_wait|futex_wait|futex_wake'
```

### 锁统计（内核 mutex）

```bash
perf lock stat -- <workload>
```

看目标锁的 `contentions` vs `acquisitions` 和 `wait_total` vs `hold_total`：
- `contentions/acquisitions` 高 → 锁争用频繁
- `wait_total >> hold_total` → 等锁时间远超持有时间 → 典型 mutex 瓶颈

### IPC 信号

```bash
perf stat -e instructions,cycles -C <cores> -a sleep 5
# IPC 随核数显著下降，但用户空间工作量不变 → 增量 cycle 全是锁串行化
```

---

## Mutex 在高核数下的开销机制

Linux 内核 mutex 三段获取：

1. **Fast path**：单次 LOCK CMPXCHG，mutex 空闲时直接成功
2. **Midpath (OSQ)**：在 per-CPU MCS node 上乐观自旋，等待 owner 释放
3. **Slow path**：加入等待队列，调用 `schedule()` 睡眠

N 个读者场景：
```
Thread 1: [LOCK CMPXCHG → M state] read [unlock → store]
Thread 2:  ← 等待(RFO pending) → [LOCK CMPXCHG] read [unlock]
Thread 3:  ← 等待 ─────────────── ← 等待 → [LOCK] read [unlock]
...
Thread N:  ← 等完前面 N-1 个
```

每个读者的获取都需要 RFO（Read-For-Ownership）——获取 mutex cache line 的独占权。即使所有线程只做读取，cache line 在所有核心之间弹跳。

内核 mutex 的 midpath 自旋还会因每个读者持有锁时间短但等待者多，导致巨量自旋 cycle 浪费。`osq_lock` 出现在 perf top 里就是这个现象的签名。

---

## 修复

### 用户空间

```c
// Before
pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;

void reader() {
    pthread_mutex_lock(&lock);
    result = lookup_cache(key);     // 只读
    pthread_mutex_unlock(&lock);
}

// After
pthread_rwlock_t rwlock = PTHREAD_RWLOCK_INITIALIZER;

void reader() {
    pthread_rwlock_rdlock(&rwlock);   // 多读者并发
    result = lookup_cache(key);
    pthread_rwlock_unlock(&rwlock);
}

void writer() {
    pthread_rwlock_wrlock(&rwlock);   // 互斥
    insert_cache(key, value);
    pthread_rwlock_unlock(&rwlock);
}
```

### 内核空间

- 不睡眠的临界区：`rwlock_t`（spin-based，类似 `spinlock_t` 但允许多读者）
- 可能睡眠的临界区：`rw_semaphore`（`down_read`/`down_write`）

---

## 陷阱与预防

### 1. 写者饥饿

持续不断的新读者可以无限期阻止写者获取锁。解决方案：

```c
pthread_rwlockattr_t attr;
pthread_rwlockattr_setkind_np(&attr,
    PTHREAD_RWLOCK_PREFER_WRITER_NONRECURSIVE_NP);
pthread_rwlock_init(&rwlock, &attr);
```

### 2. rwlock 自身开销

`pthread_rwlock_rdlock` 内部需要原子递增 reader count。在无竞争时，mutex 的 `LOCK CMPXCHG` 快于 rwlock 的 `LOCK INC` + 状态检查。**临界区 < ~50ns 时 rwlock 可能比 mutex 更慢**。

### 3. 不要升级锁

不要尝试 `rdlock → 检查条件 → 需要写 → 升级为 wrlock`。POSIX rwlock 不支持锁升级（可能导致死锁）。正确做法是释放 rdlock 后获取 wrlock，并重新检查条件（数据可能已变）。

### 4. 检查宏/RAII 包装

如果项目用 RAII 包装了 mutex (`std::lock_guard`/`std::unique_lock`)，需要写对应的 rwlock RAII 包装。C++17 有 `std::shared_lock`（读锁）+ `std::unique_lock`（写锁），但底层仍需 `pthread_rwlock_t` 或 `std::shared_mutex`。

---

## 验证

```bash
# 修复前后分别跑
perf lock stat -- <workload> 2>&1 | grep <lock_name>
# 确认 wait_total 下降、contentions 下降

perf stat -e instructions,cycles -C <cores> -a <workload>
# 确认 IPC 回升
```
