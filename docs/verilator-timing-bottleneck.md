# Verilator 仿真性能瓶颈分析与进展

## 问题

i5-1135G7 单核跑 OpenC906 到 Linux PID 1 用了 5 天，约 107M 条指令，折合每秒 260 条。i9-14900HX 上用 Verilator 5.050 单核约 2708 retired/s，仍然很慢。多线程比单线程更慢（t2 降到 t1 的 60%，t4 降到 41%）。

## 已有排查

`docs/simulation-performance.md` 记录了多线程负扩展的排查过程：

- Verilator 5.020 的 `--binary` main 没设 context 线程数，默认 `hardware_concurrency()`，创建了过多线程。已用自定义 `verilator-main.cpp` 修复。
- 修复后多线程仍更慢。t2 只有 21 个 mtask、40 条依赖边，并行粒度不够，同步开销盖过收益。
- 5.050 单线程比 5.020 快约 3 倍（UNOPTFLAT 从 117 降到 6），但 t2/t4 仍负扩展。
- 结论是"普通主机多线程已止损"，建议转向 FPGA/FireSim。

这份文档把多线程负扩展归因于"RTL 依赖、同步及可并行粒度"，没有检查 `--timing` 编译选项的影响。

## 新发现的根因

`scripts/build-verilator-linux.sh` 第 151 行传了 `--timing`。原因是 `output/sim/tb-linux.v` 用 Verilog `#` 延时生成时钟：

```verilog
forever begin
  #(`CLK_PERIOD/2) clk = ~clk;
end
```

`verilator-main.cpp` 的主循环也是事件驱动写法：

```cpp
while (!contextp->gotFinish() && !stopRequested) {
    topp->eval();
    if (!topp->eventsPending()) break;
    contextp->time(topp->nextTimeSlot());
}
```

Verilator 的速度来自把设计编译成静态调度的 `eval()`，每个时钟沿调一次。开了 `--timing` 后改用协程和动态事件队列处理 `#` 延时，每个时间步都过调度器。stats 文件确认有 13 处 `#const` 延时进入了 timing 调度。

这也解释了多线程负扩展：timing 模式下动态调度区域是串行的，能并行的只有中间组合逻辑部分，对单核 C906 来说太小，线程同步开销盖过收益。之前文档里"等待占 44%"的数据与此吻合。

## 换 Cadence 会不会快

不会。Xcelium 是事件驱动仿真器，永远运行在类似 `--timing` 的模式下，对可综合 RTL 通常比调优好的 Verilator 慢。现在的 Verilator 用法恰好退化成了事件驱动模式。

## 待办

1. **时钟改由 C++ 驱动**：删掉 `tb-linux.v` 里两个 `forever #` 块，`clk`/`jclk` 改成顶层输入，在 `verilator-main.cpp` 里手动翻转。`jclk` 在 Linux 启动中用不到，可以接常量。
2. **去掉 `--timing`**：复位序列里的 `#100`、`#400` 改成周期计数器实现。RTL 里的 `#` 延时在非 timing 模式下会被忽略，对功能无影响。
3. **主循环改成标准写法**：`clk=1; eval(); clk=0; eval();` 循环，去掉 `nextTimeSlot()`。
4. 多线程等改完上面三条再测。
5. 迭代调试时开 `LINUXCPU_FAST_UART=1`，最终验收时关掉。UART 按真实 115200 波特率工作时，每个字节消耗 8680 个时钟周期。
