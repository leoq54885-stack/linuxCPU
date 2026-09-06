# Verilator 仿真性能冒烟与多核排查

## 结论（2026-09-04）

Verilator 5.050 单线程是当前最快且风险最小的候选配置；普通主机多线程已经达到
止损条件，不再继续增加线程或细调 mtask。5.050 与 5.020 使用同一固件、从复位
开始且绑定相同 CPU 14 的结果如下：

| Verilator/模型 | 实际 mtask | 稳态 retired/s | 相对 5.050 t1 | 相对 5.020 t1 |
|---|---:|---:|---:|---:|
| 5.020 t1 | 串行 | 912.6 | 0.34x | 1.00x |
| 5.050 t1 | 串行 | **2708.4** | **1.00x** | **2.97x** |
| 5.050 t2，自动分区 | 25 | 1274.4 | 0.47x | 1.40x |
| 5.050 t2，Thread PGO | 25 | 1592.9 | 0.59x | 1.75x |
| 5.050 t2，实际 6 mtask（上限 8） | 6 | 2031.3 | 0.75x | 2.23x |
| 5.050 t2，实际退化为 1 mtask | 1 | 2622.0 | 0.97x | 2.87x |
| 5.050 t4，自动分区 | 48 | 988.1 | 0.36x | 1.08x |

最后一项 t2 虽创建两个宿主线程，但调度器发出 `UNOPTTHREADS` 且只生成一个
mtask，所以不是多核加速。`-march=native -mtune=native` 的 5.050 t1 只有
2301.5 retired/s，比默认 5.050 t1 慢约 15%，也不采用。

5.050 execution profile 进一步确认：自动 t2 的静态调度预测 1.96x，实测并行区
只有 0.986x，等待占 44.11%。Thread PGO 将等待降至 34.76%，实测仍只有 1.04x。
剩余损失是当前 RTL 每个时序步的依赖、同步及多线程代码布局成本，不是线程未
启动或绑核错误。增加线程无法补偿这些固定成本。

新版的单线程大幅提升来自代码生成/优化变化：相同 RTL 下，被抑制的
`UNOPTFLAT` 从 5.020 的 117 个降到 5.050 的 6 个。新旧模型前 40 个退休诊断
采样（一直到 retired=80000）的 PC 逐项一致；这证明了启动前缀的一致性，但不
替代最终 PID 1 验收。实验文件位于：

- `output/benchmarks/20260903-v5.050-baseline/`
- `output/benchmarks/20260903-v5.050-prof/`
- `output/benchmarks/20260903-v5.050-pgo-result/`
- `output/benchmarks/20260903-v5.050-mtask-sweep/`

旁路安装的 5.050 位于 `.toolchain/verilator-5.050-install/`，没有覆盖项目原来的
5.020。构建/运行候选单线程模型：

```bash
V=.toolchain/verilator-5.050-install/bin/verilator
LINUXCPU_VERILATOR_BIN="$PWD/$V" \
LINUXCPU_VERILATOR_VARIANT=v5.050-base \
LINUXCPU_VERILATOR_THREADS=1 make rtl-linux

LINUXCPU_VERILATOR_BIN="$PWD/$V" \
LINUXCPU_VERILATOR_VARIANT=v5.050-base \
LINUXCPU_VERILATOR_THREADS=1 make run
```

以下保留最初 5.020 基线和问题发现过程。

### Verilator 5.020 基线（2026-09-03）

在本机
i9-14900HX/WSL2、Verilator 5.020 上，同一镜像从复位开始运行 90 秒的结果为：

| 模型 | CPU affinity | 峰值线程 | 稳态 retired/s | 相对 t1 |
|---|---:|---:|---:|---:|
| t1 | CPU 14 | 1 | 912.6 | 1.00x |
| t1 | CPU 0-15 | 1 | 913.3 | 1.00x |
| t2 | CPU 12,14（不同物理核） | 2 | 551.5 | 0.60x |
| t4 | CPU 8,10,12,14（不同物理核） | 4 | 374.7 | 0.41x |

原始 JSON 和模型输出保存在
`output/benchmarks/20260903-multicore-root-cause/`（`output/` 不提交 Git）。

多核负扩展有两个独立原因：

1. 原构建的 `--build-jobs` 只并行 C++ 编译，不会并行仿真；原模型的
   `Vtb::threads()` 明确返回 1。
2. Verilator 5.020 的 `--binary` main 没有设置 `VerilatedContext` 的线程数，
   context 会默认为 `hardware_concurrency()`。本机实测 t1/t2 都创建 16 个线程，
   即使模型只需要 1/2 个。上游到
   [5.044](https://github.com/verilator/verilator-announce/issues/81) 才修复这个问题
   （verilator#6841）。项目现在使用 `scripts/verilator-main.cpp`，显式令 context
   线程数与 `--threads N` 相等。

修正隐藏线程池后，多线程仍更慢。t2 的 Verilator 统计只有 21 个 mtask、40 条
依赖边；同时 OpenC906 RTL 有 117 个被压制的 `UNOPTFLAT` 警告。每个时序事件
都要进行线程派发、依赖等待和收敛同步，而单个 mtask 的工作量不足以摊销这些
固定成本。t2 使用约两个满核，吞吐却只有 t1 的 60%；t4 进一步下降，证明瓶颈
是调度/同步和可并行粒度，不是缺少 CPU 配额。

## 标准性能冒烟流程

性能结果只有在模型、镜像、宿主负载和 CPU 拓扑可比时才有意义。每次实验遵守
以下约定：

1. 工作树和 `openc906` 子仓库保持干净；记录 commit、Verilator 版本、`lscpu`
   和是否运行于 VM/WSL。
2. 使用同一个 `LINUXCPU_FAST_UART` 模式；多核实验不要同时改 Linux 配置、固件
   或 RTL。
3. 从复位开始跑固定墙钟时间，不跑到 PID 1。默认 120 秒，前 10 秒作为 warmup；
   至少应看到两个 10k retirement 采样点。
4. tN 模型绑到 N 个不同物理核，不使用同一物理核的 SMT sibling。可从
   `/sys/devices/system/cpu/cpu*/topology/thread_siblings_list` 查看配对。
5. 配置按交错顺序各跑至少 3 次，例如 t1、t2、t1、t2；比较
   `retired_per_wall_second_stable` 的中位数。差异小于 5% 视为噪声。
6. 同时检查 `peak_host_threads`、`migrations`、`context_switches` 和模型日志。
   线程数不等于 N、日志出现 RTL error/stall、或未达到 `min-retired` 时，本次样本
   无效。

单线程标准冒烟：

```bash
LINUXCPU_VERILATOR_THREADS=1 LINUXCPU_JOBS=8 make rtl-linux
LINUXCPU_VERILATOR_THREADS=1 \
LINUXCPU_PERF_SMOKE_SECONDS=120 \
LINUXCPU_PERF_CPUS=14 \
make perf-smoke
```

两线程实验（先构建一次，模型与 t1 并存）：

```bash
LINUXCPU_VERILATOR_THREADS=2 LINUXCPU_JOBS=8 make rtl-linux
LINUXCPU_VERILATOR_THREADS=2 \
LINUXCPU_PERF_SMOKE_SECONDS=120 \
LINUXCPU_PERF_CPUS=12,14 \
make perf-smoke
```

每次运行输出两个文件：`tN.log` 是原始模型日志，`tN.json` 包含吞吐、affinity、
观测到的 CPU、线程峰值、CPU 时间和调度计数。用独立目录保存重复样本：

```bash
LINUXCPU_PERF_OUTPUT=output/benchmarks/my-experiment/t1-r1 \
LINUXCPU_PERF_CPUS=14 make perf-smoke
```

正常 `make run` 也会在每个 10k retirement 点输出 `[rtl-speed]`，给出窗口和累计
retired/s；这些行属于宿主监控，不改变 RTL 模型或来宾软件。

## 后续策略

1. 完整 Linux/PID 1 验收使用 5.050 t1 候选模型，同时保留 5.020 成功日志作为
   结果对照；在跑到 PID 1 前不替换锁定工具链。
2. 多个独立测试仍可各占一个物理核并行跑，以提升总吞吐；这和加速单条仿真是
   两个问题。
3. 不再投入 t2/t4、Thread PGO 或 `--threads-max-mtasks` 参数扫描。若必须进一步
   数量级降低单条启动延迟，下一技术路线应是 GSIM 兼容性 PoC 或 FPGA/FireSim，
   而不是更多普通 x86 线程。
4. 参考 Verilator 官方的
   [执行 profiling 与性能建议](https://verilator.org/guide/latest/simulating.html#benchmarking-optimization)。

Verilator 官方也明确说明：`--threads 1` 是单线程模型，`--threads N` 才会生成
最多 N 路并行模型；过度订阅会显著恶化性能，线程应放在同一低延迟缓存/NUMA
域内。详见[多线程模型说明](https://verilator.org/guide/latest/verilating.html#multithreading)。
