# Verilator 单线程仿真性能调查情况说明
 
## 1. 说明目的
 
本项目使用 Verilator 运行 OpenC906 RTL，并启动 OpenSBI、Linux 和最小用户空间。当前主要问题是单次 Linux 启动耗时过长。
 
多线程实验已经确认负扩展：C906 单核 RTL 可并行粒度不足，线程同步和调度成本超过并行收益。因此，本阶段把重点转向单线程性能，调查以下问题：
 
1. `--timing` 是否构成主要性能瓶颈；
2. 去掉 timing 支持能否显著提高单线程速度；
3. 实验实现和测量方法是否正确；
4. 当前框架内还有哪些单线程优化空间。
 
本文合并并修正以下两份阶段性文档：
 
- `docs/verilator-timing-bottleneck.md`
- `docs/notiming-experiment-result.md`
 
## 2. 当前问题与基线
 
### 2.1 启动耗时
 
历史上，i5-1135G7 使用旧模型启动到 PID 1 约需 5 天，最终执行约 107M 条指令。i9-14900HX、Verilator 5.050 的单线程早期稳定速度约为 2708 retired/s，速度明显提高，但完整启动仍以小时计。
 
完整成功日志显示：
 
- Linux 在来宾时间约 62.8 秒到达 PID 1；
- 设备树 timebase 为 100 MHz；
- 对应约 62.8 亿个 CPU 周期；
- 全程平均约 45～60 周期/retired；
- 最终约 107.3M retired，与上述周期数量相符。
 
因此，启动墙钟时间由两个因素共同决定：
 
```text
启动墙钟时间 = 到 PID 1 所需仿真周期数 / 单线程每秒仿真周期数
```
 
当前同时存在两个压力：
 
1. Linux 到 PID 1 需要执行数十亿个 RTL 周期；
2. 每个周期都要计算完整 C906、缓存、MMU、LSU、总线、RAM 和外设逻辑。
 
### 2.2 Verilator 版本与多线程结论
 
相同 RTL 和固件下已有数据如下：
 
| Verilator/模型 | 稳态 retired/s | 相对 5.020 t1 |
|---|---:|---:|
| 5.020 t1 | 912.6 | 1.00x |
| 5.050 t1 | 2708.4 | 2.97x |
| 5.050 t2，自动分区 | 1274.4 | 1.40x |
| 5.050 t2，Thread PGO | 1592.9 | 1.75x |
| 5.050 t2，实际 6 mtask | 2031.3 | 2.23x |
| 5.050 t4，自动分区 | 988.1 | 1.08x |
 
Verilator 5.050 的单线程提升约 3 倍，伴随 `UNOPTFLAT` 数量从 117 降到 6。多线程仍然慢于 5.050 单线程，当前不再继续投入 t2/t4 参数扫描。
 
## 3. timing 瓶颈假设
 
原构建使用 `--timing`，原因是 testbench 用 `#` 延时生成时钟和复位：
 
```verilog
forever begin
  #(`CLK_PERIOD/2) clk = ~clk;
end
```
 
原 C++ 主循环按事件时间槽推进：
 
```cpp
while (!contextp->gotFinish() && !stopRequested) {
    topp->eval();
    if (!topp->eventsPending()) break;
    contextp->time(topp->nextTimeSlot());
}
```
 
阶段性假设认为：
 
- `--timing` 会生成 C++20 协程和动态延迟队列；
- 每个时间步需要经过 timing 调度器；
- 去掉 timing 后可恢复更轻量的时钟沿驱动方式；
- 单线程和多线程性能都应获得明显改善。
 
这个方向值得实验，但“整个 C906 退化为传统动态事件仿真”的表述过重。后续生成代码和 profile 证明，timing 只给含延时或动态事件控制的部分增加协程与调度，C906 主体仍然由 Verilator 静态生成的 NBA 逻辑执行。
 
## 4. no-timing 实验修改
 
实验代码位于 `exp/no-timing` 分支。主要修改如下。
 
### 4.1 `scripts/prepare-rtl-image.py`
 
增加 `apply_verilator_timing_mode()`，根据 `VERILATOR_NO_TIMING` 生成双模式 testbench：
 
- timing 模式保留 testbench 内部时钟和复位；
- notiming 模式把 `clk`、`jclk`、`rst_b`、`jrst_b` 暴露为顶层输入；
- notiming 模式移除两个 `forever #` 时钟块；
- notiming 模式由 C++ 驱动复位波形；
- `#MAX_RUN_TIME` 改为等价的周期计数器保护。
 
### 4.2 `scripts/verilator-main.cpp`
 
增加 `LINUXCPU_NO_TIMING` 控制的主循环：
 
- 每个循环代表 5 ns 半周期；
- `clk` 每步翻转；
- `jclk` 每四步翻转；
- `rst_b` 在 100 ns 拉低、200 ns释放；
- `jrst_b` 在 400 ns 拉低、800 ns释放；
- 每个半周期调用一次 `eval()`；
- 手动推进 `$time`。
 
波形相位与原 testbench 一致。原计划曾提出将未使用的 `jclk` 接常量，实际实验为了保持行为一致仍然翻转 `jclk`，所以 JTAG/TDT 静态裁剪尚未实施。
 
### 4.3 `scripts/build-verilator-linux.sh`
 
增加 `LINUXCPU_VERILATOR_TIMING`：
 
- `timing`：传入 `--timing`；
- `notiming`：传入 `--no-timing -DVERILATOR_NO_TIMING -CFLAGS -DLINUXCPU_NO_TIMING`；
- timing 模式进入构建签名；
- 两个模型使用独立输出目录。
 
首次 notiming 构建发现 `axi2ahb.v` 仍有三个 `assign #1`，Verilator 5.050 要求显式指定 `--no-timing` 才会忽略这些延时。补充该参数后构建成功。
 
## 5. 原始实验条件与数据
 
### 5.1 条件
 
- CPU：i9-14900HX；
- 环境：WSL2；
- Verilator：5.050；
- 模型线程数：1；
- CPU affinity：14；
- timing 模型：`output/verilator/v5.050-base/c906-linux`；
- notiming 模型：`output/verilator/notiming/c906-linux`；
- 每轮 120 秒，前 10 秒作为 warmup；
- 固件 SHA256 相同；
- `LINUXCPU_FAST_UART=0`。
 
### 5.2 原始 A/B 数据
 
| 轮次 | timing retired/s | notiming retired/s | 配对差值 |
|---|---:|---:|---:|
| r1 | 2395.8 | 2642.4 | +10.3% |
| r2 | 2621.5 | 2583.1 | -1.5% |
| 平均 | 2508.7 | 2612.8 | +4.2% |
 
两轮 timing 自身相差约 9.4%，高于平均收益。原始数据能够说明未出现显著提速，无法证明精确收益为 4.2%。
 
### 5.3 功能检查
 
原实验比较了：
 
- 前 32 条逐条退休 PC；
- 后续每 10000 条退休一次的 PC；
- 前 48 个采样点；
- UART 输出前缀。
 
两种模型采样结果一致，说明启动前缀保持一致。该检查属于稀疏轨迹验证，不能代替完整周期等价或最终 PID 1 验收。
 
## 6. 受控复测
 
为排除 timing 基线来自旧构建签名的疑问，使用当前工作树和同一 Verilator 5.050 重建了独立的 `timing-control` 模型。
 
对旧 timing 模型和新模型的生成 C++ 做逐文件比较，有效逻辑一致，差异仅为 testbench 条件编译引起的源码行号变化。两者 `.text` 大小也相同。因此，旧 build-info 字段较少没有形成实质性实验偏差。
 
补充三轮 60 秒交错测试，结果如下：
 
| 轮次 | timing retired/s | notiming retired/s | 配对差值 |
|---|---:|---:|---:|
| r1 | 2220.4 | 2143.7 | -3.45% |
| r2 | 2124.9 | 2297.2 | +8.11% |
| r3 | 2514.4 | 2763.0 | +9.89% |
| 均值 | 2286.6 | 2401.3 | +5.02% |
| 中位数 | 2220.4 | 2297.2 | +3.46% |
 
组内变异系数：
 
- timing：8.9%；
- notiming：13.4%。
 
受控复测受到 WSL 宿主负载、频率和 SMT sibling 竞争影响，只用于确认收益量级。结果再次表明 no-timing 收益处于几个百分点范围，远低于数量级优化。
 
原始与补充数据位于：
 
- `output/benchmarks/20260906-notiming-ab/`
- `output/benchmarks/20260906-controlled-notiming-ab/`
 
## 7. 生成代码调查
 
### 7.1 timing 模型
 
Verilator stats 显示：
 
- 13 个常量延时；
- 7 个 timing 协程；
- `Combined CFuncs` 为 15；
- Active 调度区域大小约 1392；
- NBA 调度区域大小约 374267；
- 6 个被压制的 `UNOPTFLAT`。
 
7 个协程主要来自：
 
1. `clk` 时钟生成；
2. `jclk` 时钟生成；
3. `rst_b` 复位序列；
4. `jrst_b` 复位序列；
5. 最大仿真时间保护；
6. testbench 看门狗；
7. testbench 成功/失败检测。
 
`axi2ahb.v` 的三个 `assign #1` 也通过 DelayScheduler 处理。
 
### 7.2 notiming 模型
 
notiming 模型：
 
- 没有 `VlDelayScheduler`；
- 没有 timing 协程；
- `Combined CFuncs` 降为 2；
- Active 调度区域大小约 263；
- NBA 调度区域大小约 375805；
- 三个 `assign #1` 延时被忽略；
- 时钟边沿由 ICO 区域检测。
 
### 7.3 对原静态分析的修正
 
原报告曾认为 timing 模型把 C906 核心逻辑放在 Act 区域，notiming 模型把同一逻辑移动到 NBA 区域。生成代码表明该判断错误：
 
- 两种模型的 C906 主体都主要位于 `eval_nba()`；
- timing 的 `act_sequent__TOP__1/2` 主要对应 `axi2ahb.v` 的延时赋值；
- timing 的 Act 区域还负责协程 ready/resume 和 testbench timing 事件；
- notiming 删除了这些延时调度，但没有删除昂贵的 C906 NBA 主体。
 
因此，no-timing 减少的是主体周围的调度开销，核心计算量基本保留。
 
### 7.4 eval 调用频率
 
notiming 主循环严格每 5 ns 调用一次 `eval()`，每个完整 `clk` 周期两次。
 
timing 主循环按 DelayScheduler 的下一个时间槽调用 `eval()`：
 
- 时钟边沿保证每周期至少两次；
- `assign #1` 在相关信号变化时可增加中间时间槽；
- 调用次数取决于运行期事件，不能无条件写成每周期固定两次。
 
## 8. profile 结果
 
本次补充了 `--prof-c --prof-cfuncs` 的 timing/notiming 调用关系调查。该插桩会拆分大量生成函数并显著降低运行速度，因此 profile 百分比不用于估计生产模型的精确耗时占比，调用次数和调用结构仍可用于判断调度路径。
 
观察结果：
 
| 模型 | `eval()` 调用 | NBA 主体调用 | NBA/`eval()` |
|---|---:|---:|---:|
| timing | 214658 | 429281 | 约 2.00 |
| notiming | 153960 | 307887 | 约 2.00 |
 
两种模型都在一次 `eval()` 中执行约两轮 NBA 主体。timing 增加了 TriggerScheduler、DelayScheduler 和 Active 区域调用；notiming 仍保留相同量级的 NBA 收敛计算。
 
profile 的主要调用链集中于：
 
- C906 IFU、IDU、LSU、MMU 和向量/浮点逻辑；
- cache、SRAM 与 AXI/AHB 逻辑；
- PLIC 等 SoC 模块；
- 大规模 NBA 组合与时序函数。
 
这与 stats 中两个模型约 374K～376K 的 NBA 区域规模一致。
 
profile 产物位于：
 
- `output/verilator/gprof-timing/`
- `output/verilator/gprof-notiming/`
- `output/benchmarks/gprof-timing/`
- `output/benchmarks/gprof-notiming/`
 
## 9. 实验操作评价
 
### 9.1 正确部分
 
1. 显式使用 `--no-timing`；
2. C++ 时钟和复位波形与原 testbench 对齐；
3. timing/notiming 使用相同 Verilator、固件、线程数和主要编译参数；
4. 使用独立输出目录，避免模型互相覆盖；
5. 构建签名纳入 timing 模式；
6. 进行了启动前缀功能对照；
7. 使用绑核和交错 A/B 降低宿主波动影响。
 
没有发现能够解释“大幅收益被实现错误吞掉”的问题。
 
### 9.2 局限与需修正内容
 
1. 原始样本只有两轮，达不到项目约定的至少三轮；
2. WSL 环境下组内波动达到 9%～13%，当前数据无法证明 4% 或 5% 的精确收益；
3. 固定顺序总是 timing 后接 notiming，应进一步使用 AB/BA 反转或随机顺序；
4. CPU 14 与 CPU 15 属于同一物理核，仍需控制 sibling 竞争；
5. `retired/s` 混合了仿真器周期吞吐和来宾 IPC；
6. 固定墙钟测试会让更快模型进入更后的启动阶段，结束区间不完全相同；
7. 前 48 个 PC 采样只能证明启动前缀一致；
8. 三个 `assign #1` 在 notiming 中变为零延时，完整时序等价仍缺长期验证；
9. 原报告对 Act/NBA 核心逻辑归属的判断需要按本文修正；
10. 原报告对 timing `eval()` 频率的描述需要增加运行期事件限定。
 
后续性能实验应同时记录：
 
```text
simulated cycles / host second
固定周期区间的宿主耗时
固定 retired 区间的宿主耗时
到固定 UART/内核/PID 1 里程碑的宿主耗时
```
 
## 10. 根因结论
 
### 10.1 timing 的实际影响
 
`--timing` 确实引入以下成本：
 
- C++20 协程；
- DelayScheduler；
- TriggerScheduler；
- Active/Inactive 区域检查；
- `eventsPending()` 和 `nextTimeSlot()`；
- `assign #1` 的延迟事件。
 
这些成本真实存在，但只占每个时间步外围工作的一部分。
 
### 10.2 主导成本
 
主导成本来自完整 C906/SoC 的大规模静态生成逻辑：
 
- timing 和 notiming 的 NBA 区域都约为 37.5 万规模；
- 两种模型每次 `eval()` 都有约两轮 NBA 主体执行；
- 去掉协程后，C906、缓存、MMU、LSU、总线、RAM 和外设计算仍然存在；
- 62.8 亿个启动周期进一步放大了每周期成本。
 
因此，`--timing` 不是当前单线程速度的主要瓶颈。no-timing 的收益处于 0～10% 范围，当前数据中心值约为 3%～5%。
 
### 10.3 对多线程结论的影响
 
no-timing 会缩小 Active/timing 调度部分，但不会改变 C906 主体的依赖结构和大规模 NBA 计算。现有证据不足以支持重新投入普通主机 t2/t4 参数扫描，多线程负扩展结论保持不变。
 
## 11. 当前框架内的后续方向
 
后续工作分为两类，测量指标必须分开。
 
### 11.1 提高每秒仿真周期数
 
按优先级建议：
 
1. 定位剩余 6 个 `UNOPTFLAT`，确认是否造成额外收敛；
2. 对生产模型做低扰动 profile，按 IFU/LSU/cache/RAM/总线模块归因；
3. 测试 `-Os`、`-O2`、`-O3`、Clang、LTO 和编译器 PGO；
4. 独立测试 `--no-assert --x-assign fast --x-initial fast`，并承担相应验证风险；
5. 在确认 JTAG 未使用后，把 `jclk`、JTAG 输入和 TDT/debug 模块静态 tie-off；
6. 裁剪 Linux 启动不需要的 testbench 和 SoC 逻辑；
7. 在保持 CPU RTL 的前提下，评估 RAM、总线或外设的仿真专用行为模型。
 
`--output-split-cfuncs`主要用于降低编译资源消耗，运行时通常有损失，不列为优先性能方案。
 
### 11.2 减少到 PID 1 所需周期数
 
完整启动的大部分时间消耗在内核初始化和设备注册阶段。已有日志显示：
 
- `CONFIG_VT=y` 注册约 63 个虚拟终端；
- legacy PTY 注册约 512 个设备；
- 合计约 575 个本平台不需要的 tty 设备；
- 每个设备都经过 device model、sysfs、devtmpfs 和 uevent 流程；
- PLIC 输出到串口驱动输出之间存在数千万 retired 的静默注册阶段。
 
建议：
 
1. 关闭 `CONFIG_VT`；
2. 关闭 legacy PTY，保留 ttyS0 和必要的 UNIX98 PTY；
3. 将 `CONFIG_HZ=250` 调整为 `CONFIG_HZ=100`；
4. 减少无用驱动、总线和设备枚举；
5. 降低启动期 printk/console 输出；
6. 重新用“到固定语义里程碑的墙钟时间”评估 `FAST_UART=1`；
7. 精简 initramfs 和 init 路径。
 
这类优化会改变来宾执行的指令数和周期数，不能再用 retired/s 单独评价。
 
## 12. 阶段性结论
 
1. no-timing 实验实现主体正确；
2. 原 timing 根因假设高估了动态调度的影响；
3. C906 主体在两种模型中都主要位于 NBA 静态生成逻辑；
4. 去掉 timing 只减少外围调度，实测收益约几个百分点；
5. 当前启动慢的核心原因是约 62.8 亿个周期与昂贵的完整 RTL 每周期计算叠加；
6. 单线程路线仍有空间，应同时优化“每秒周期数”和“到 PID 1 的周期数”；
7. 在保持完整 Verilator RTL 框架的条件下，编译参数微调无法提供数量级收益；
8. 若目标要求数倍以上稳定提升，应优先削减 Linux 启动工作量、裁剪未使用 RTL，并评估更高层次行为模型；
9. 若要求严格周期等价并追求数量级提升，应转向 GSIM、FPGA/FireSim 或其他硬件加速方案。