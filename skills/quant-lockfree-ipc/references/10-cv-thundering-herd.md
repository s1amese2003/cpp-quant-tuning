# 条件变量惊群（CV Thundering Herd）

`notify_all()` 或循环 `notify_one()` 唤醒远超实际可消费任务量的线程时，浪费的唤醒在高核数下成为主导开销。这是**与锁竞争不同的问题类别**——`perf lock stat` 显示正常，但 `futex_wake` 爆炸。

---

## 源码信号

### 明确的反模式

```cpp
// 反模式 1: 无差别广播
// dispatcher 不知道有多少 job，直接叫醒所有人
void dispatch_jobs() {
    enqueue_jobs();
    cv.notify_all();   // 100 个 worker 被叫醒，只有 3 个有活干
}

// 反模式 2: notify_one 循环
void wake_workers(int n) {
    for (int i = 0; i < n; i++)
        cv.notify_one();   // O(n) futex syscall，每轮 5µs
}

// 反模式 3: 过度唤醒
// worker 醒来发现没活，yield 或重新阻塞
void worker_loop() {
    while (running) {
        wait_for_work();
        if (!has_work()) {
            sched_yield();   // 白被叫醒了
            continue;
        }
        process();
    }
}
```

### 间接信号

- `pthread_cond_broadcast` 或 `cv.notify_all()` 叫醒线程池，但实际 job 数远小于线程数
- worker 代码里 `sched_yield()` 或醒来后立即 `wait()` —— 说明经常被叫醒但无事可做
- N 个线程等待同一个 CV，且 dispatcher 从不控制被唤醒数量

---

## Perf 诊断

### Step 1: 查符号

```bash
perf report --stdio --no-children | grep -E 'futex_wake|try_to_wake_up|pthread_cond|wake_up_q'
```

热符号是 `futex_wake`/`try_to_wake_up` 而非 `spin_lock_slowpath` → 这是 CV 问题，不是锁问题。

### Step 2: 看 futex WAKE 模式

```bash
perf trace -e futex -p <PID> 2>&1 | grep WAKE | head -50
```

- 高频 `FUTEX_WAKE, val=INT_MAX` → `notify_all()` 广播惊群
- 高频 `val=1` bursts → `notify_one()` 循环

### Step 3: 上下文切换率

```bash
perf stat -e context-switches -C <isolated_cores> -a sleep 10
# 高核数下 cs/s 远超实际工作率，说明大量无效唤醒
```

---

## 与锁竞争的区别

| 症状 | 锁竞争 | CV 惊群 |
|------|--------|---------|
| 热符号 | `native_queued_spin_lock_slowpath`、`osq_lock` | `futex_wake`、`try_to_wake_up`、`__pthread_cond_broadcast` |
| `perf lock stat` wait_total | 高 | 正常 |
| context-switch 率 | 中低（等待者睡眠后稳定） | 极高（无效唤醒→立即再睡→再唤醒） |
| IPC | 随核数缓慢下降 | 崩溃式下降（核忙调度而非计算） |
| CPU 利用率 | 低（等锁） | 高但无产出（忙唤醒/调度） |

---

## 时间线详解

当 `notify_all()` 叫醒 N 个 waiter 时：

```
t0: notify_all() → 内核把 N 个线程移出等待队列 → N 个变为 runnable
t1: 调度器把 N 个线程分到 N 个核上（可能抢占正在干活的核）
t2: 所有 N 个争抢 mutex（CV 语义强制获取 mutex 后才能离开 wait）
    → 1 个赢，N-1 个立刻阻塞在 mutex 上
t3: N-1 个失败者各付一次完整 futex 往返：
    唤醒 → 调度到核上 → 试图获取 mutex → 失败 → futex_wait 休眠
t4: 线程逐个被唤醒、检查 predicate、多数发现无工作、再休眠
```

每 `notify_all` 的 cost：O(N) context switches + O(N) futex syscalls + O(N) IPI（核间中断）+ mutex cache line 的 RFO 风暴。

以 160 个线程为例：如果每次 notify 的成本 ~800µs，而实际处理只需 50µs → 94% 时间在无效唤醒上。

---

## 修复策略

### 策略 1: 精确唤醒（首选，改动最小）

只唤醒实际有工作可做的线程：

```cpp
// Before: 无差别广播
cv.notify_all();

// After: 只唤醒 J 个
int to_wake = std::min(pending_jobs, idle_workers);
for (int i = 0; i < to_wake; i++)
    cv.notify_one();
```

或每个 worker 有独立 CV，dispatcher 只 signal 有工作的那几个。

### 策略 2: 工作窃取

Worker 醒来后从共享队列取任务，没取到就继续 wait。Dispatcher 只放任务 + signal 一个 worker（或少量 worker），被唤醒的 worker 处理完后如果队列还有任务，负责叫醒下一个。

```cpp
void worker_loop() {
    while (running) {
        wait_on_cv();
        while (auto job = shared_queue.try_pop()) {
            process(job);
        }
        // 如果队列还有积压，signal 下一个 worker
        if (!shared_queue.empty())
            cv.notify_one();
    }
}
```

### 策略 3: 分层唤醒（级联）

先唤醒 K 个（K << N）；如果 J > K，被唤醒的线程检测到积压后负责唤醒下一层。

```cpp
void after_processing() {
    if (pending_jobs > threshold)
        cv.notify_one();  // 级联唤醒下一个
}
```

---

## 验证

### 修复前基线

```bash
perf trace -e futex -p <PID> 2>&1 | grep WAKE | wc -l   # WAKE 频率
perf stat -e context-switches -a -C <cores> sleep 10       # cs/s
```

### 修复后验收

- `perf trace` 的 WAKE 频率应与实际 job 处理数成正比，不再放量增长
- `perf stat -e context-switches` 的 cs/s 应与工作率成正比
- `perf report` 中 `futex_wake`/`try_to_wake_up` 消失或显著下降
- IPC 回升到正常范围（CPU 在做实际计算而非调度开销）
