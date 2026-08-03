---
description: 生成或校验交易机的系统层调优方案（BIOS/内核参数/核隔离/中断/频率/大页），含验证脚本
argument-hint: [机器用途描述，如「行情+策略单机，16 核，双 NUMA」]
---

目标机器：**$ARGUMENTS**
（上面为空则按"一台通用低延迟交易机"处理，并在输出中列出你所假设的核数/NUMA 拓扑。）

读 `quant-system-tuning`，然后按下面结构输出。

## 0. 先探测现状（如果能在目标机上执行）
```bash
lscpu -e=CPU,CORE,SOCKET,NODE
cat /proc/cmdline
cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor | sort -u
cat /proc/interrupts | head -30
grep -o 'constant_tsc\|nonstop_tsc' /proc/cpuinfo | sort -u
numactl --hardware
systemctl is-active irqbalance
cat /sys/kernel/mm/transparent_hugepage/enabled
```
如果无法访问目标机，基于用户描述给方案，并**明确标注哪些数值需要在目标机上核对**。

## 1. 核分配表
输出一张表：哪些核给热路径线程、哪些给温路径、哪些留给内核与中断、哪些兄弟超线程要离线。
- 避开 core 0 / core 1
- 热路径线程与网卡在同一 NUMA 节点

## 2. BIOS 清单
C-States / C1E / SpeedStep / Turbo / SMT / CPU Ratio 的推荐值与理由。

## 3. 内核启动参数
给出完整的 `GRUB_CMDLINE_LINUX_DEFAULT` 行，`isolcpus` / `nohz_full` / `rcu_nocbs` 覆盖同一批核，含 C-State 关闭与大页预留，并逐项注释作用。

## 4. 运行时配置脚本
一个幂等的 `tune.sh`：停 irqbalance、迁移 IRQ、设 governor、sysctl（swappiness/numa_balancing/watchdog）、关 THP、workqueue cpumask。**必须幂等且可重复执行**。

## 5. 进程启动方式
`numactl` + `taskset` 的启动命令，以及代码里应该做的事（`pthread_setaffinity_np`、`SCHED_FIFO` 优先级、`mlockall`）。
**提醒 `sched_rt_runtime_us` 的死锁风险**。

## 6. 验证脚本
`verify.sh`：跑 `cyclictest` 并给出验收阈值；检查隔离核的 `context-switches`/`cpu-migrations`/`page-faults` 是否为 0；确认绑核与 NUMA 本地性。
**明确写出"未通过验证前，业务延迟数据不可信"。**

## 7. 风险提示
逐条说明每项配置的代价：`idle=poll` 的功耗与散热、关 Turbo 的吞吐损失、`SCHED_FIFO` 锁死机器的风险、静态配置需要重启。

## 交付
所有配置写成**纳入版本控制的脚本**（不要让用户手工敲），并提醒手工配置的机器一定会漂移。
