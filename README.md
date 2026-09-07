# linuxCPU

在真实 OpenC906 RTL 上启动最小 RISC-V Linux 的可复现工程。主仿真器是
Verilator 5.050（本地安装存在时默认优先选择）；Icarus Verilog/VVP 用于官方基线和慢速独立
交叉验证。

## 快速开始

支持的基准主机为 Ubuntu 24.04 x86-64，建议至少预留 10 GiB 空间。首次执行
需要联网，缺少基础编译包时需要 `sudo`。

```bash
git clone https://github.com/leoq54885-stack/linuxCPU.git
cd linuxCPU
./setup.sh
make smoke
make build
make run
```

- `make smoke`：用 Icarus/VVP 运行 OpenC906 官方 MMU RTL 用例。
- `make smoke-clint`：在 Verilator 模型中对比 CLINT 的错误 64 位写与正确 32 位
  `mtimecmp` 更新序列。
- `make perf-smoke`：固定墙钟时间运行 RTL 启动探针，保存 retired/s、线程、迁核
  等 JSON 指标，不等待完整 Linux 启动。
- `make build`：构建极简 `/init`、Linux、OpenSBI、DTB，并编译 Verilator RTL 模型。
- `make run`：运行 OpenC906 RTL，检测到 PID 1 验收标记后自动成功退出。
- `make rtl-linux-iverilog`、`make run-iverilog`：同一镜像的慢速 Icarus 路径。
- `make doctor`：核对上游 commit、本地工具版本和关键 RTL 集成。

RTL 首次编译需要数分钟；RTL 仿真 Linux 比指令级仿真慢很多。可用环境变量
调整并行度和运行超时。Verilator Linux 路径默认不设宿主超时；将
`LINUXCPU_LINUX_SIM_TIMEOUT` 设为正整数可用于限时探针，`0` 明确表示不设
宿主超时：

```bash
LINUXCPU_JOBS=8 make build
LINUXCPU_LINUX_SIM_TIMEOUT=2 make run       # 两秒启动探针
LINUXCPU_LINUX_SIM_TIMEOUT=0 make run       # 不限时完整运行
```

手动长跑建议明确分成“重建”和“运行”两步，避免误用旧模型：

```bash
cd /path/to/linuxCPU
LINUXCPU_FAST_UART=0 LINUXCPU_JOBS=8 make rtl-linux
LINUXCPU_FAST_UART=0 LINUXCPU_LINUX_SIM_TIMEOUT=0 make run
```

第二条命令会在当前终端持续输出，同时覆盖写入
`output/logs/c906-linux-verilator.log`；`Ctrl-C` 可以安全停止本次仿真。
`0` 只禁用 Python 运行器的宿主时间限制，不会屏蔽 testbench 的错误、模型退出
或 PID 1 成功标记。
运行脚本会校验模型的项目输入签名和 `LINUXCPU_FAST_UART` 模式，签名缺失或
不匹配时先自动重建；OpenC906 上游工作树存在已跟踪文件修改时则拒绝运行，
因此不会把未记录的本地 RTL 改动和历史模型混用。

Verilator 长跑必须绑核到空闲 P 核，否则进程在逻辑核间漂移导致缓存反复失效，
性能损失可达 40% 以上。启动后尽快绑核（在线绑核有效，无需重启）：

```bash
PID=$(pgrep -n -f 'output/verilator/c906-linux')
taskset -pc 9 $PID    # 选一个空闲 P 核
```

性能实验、多线程模型构建和已确认的负扩展原因见
[Verilator 仿真性能冒烟与多核排查](docs/simulation-performance.md)。实验确认
Verilator 5.050 单线程约为 5.020 的 2.97 倍；但 5.050 的 t2/t4 仍然负扩展，
普通主机多线程路线已止损。本机默认优先使用已安装的 5.050；旧版包仍保留为
安装回退。可用 `LINUXCPU_VERILATOR_BIN` 显式指定版本，或用
`LINUXCPU_VERILATOR_VARIANT` 隔离实验模型。
`LINUXCPU_VERILATOR_THREADS=N` 可生成并存的 tN 实验模型。固定时长冒烟示例：

```bash
LINUXCPU_PERF_SMOKE_SECONDS=120 LINUXCPU_PERF_CPUS=9 make perf-smoke
```

已验证的里程碑（HZ=250 旧配置，i5-1135G7 单核约 93.5 万 retired/h）：

| 里程碑 | retired 指令 | 串口输出 |
|---|---|---|
| PLIC mapped | ~24.5M | `riscv-plic: ... mapped 256 interrupts` |
| 8250 driver | ~93.6M | `Serial: 8250/16550 driver` |
| ttyS0 注册 | ~97.5M | `ttyS0 at MMIO 0x10015000 ... is a 16550A` |
| Run /init | ~107M | `Run /init as init process` |
| PID 1 alive | ~107.3M | `linuxCPU: PID 1 is alive on OpenC906 RTL` |

本轮最终在 i5-1135G7 单核上连续运行约 5 天，使用未经加速的 UART RTL 和
HZ=250 内核，于 retired 107.3M 到达 PID 1。逐字符 UART 诊断会把可读串口文本
打散在原始日志中；运行器会同时从 `THR write data=xx` 重建串口字节流，因此仍能
识别成功标记并自动退出。完整验收日志与开发记录见：

- [笔记本成功日志](log/c906-linux-verilator-laptop-success.log)
- [仿真器外设与调试记录](log/仿真器外设与调试记录)
- [笔记本部署记录](log/笔记本部署记录)

镜像准备还会检查 Linux、DTS 和 DTB 是否比 OpenSBI payload 更新；有更新时
自动重建固件。准备脚本通过 ELF 中的 `fw_fdt_bin` 符号定位嵌入设备树，并将
`fw_payload.bin` 中的对应字节与生成 DTB 精确比较；DTB 还必须包含
`thead,c900-plic` 和 `thead,c900-clint`，否则拒绝启动仿真。这一检查用于防止
误用早期 PLIC 只标成 `riscv,plic0`，或把 C906 的 32 位、无 MMIO MTIME 的
CLINT 错标成 SiFive `riscv,clint0` 的旧镜像。

Linux testbench overlay 会把上游面向短裸机用例的 50,000-cycle 无退休看门狗
改为 2,000,000 cycles。100 MHz、HZ=250 时，一个正常 timer tick 是
400,000 cycles；新阈值允许合法的 `WFI` idle 跨过多个 tick，同时仍能在 timer
链路失效时结束仿真。日志中的 `[timer-diag]` 会记录 `mtimecmp` 更新、MTIP/STIP
边沿；若看门狗最终触发，还会输出 `mtime`、`mtimecmp`、差值、pending/enable
状态和累计事件数，用于区分 timer 未编程、未到期或中断未转发。

默认模型使用上游 UART RTL 和真实 115200 波特率时序。只有显式设置
`LINUXCPU_FAST_UART=1` 时才启用“发送器始终就绪”的实验性 overlay；该选项
不作为跑通 Linux 的验收依据。

构建 RTL 模型时会临时应用项目的 OpenC906 系统映射补丁：16 MiB RAM 的
最后4 KiB（`0x00fff000`）保留为强序、不可缓存的 fatal 诊断页，其余 RAM
仍可缓存。UART 也位于强序不可缓存窗口。固件无需初始化串口即可提交
诊断记录，testbench 立即输出，运行器返回失败。协议、限制和故障注入验收见
[诊断通道说明](experiments/uncached-diagnostics.md)。构建后上游 checkout 自动还原。

## 启动链和验收

```text
OpenC906 reset @ 0x0
  -> OpenSBI（M-mode）
  -> Linux Image @ 0x00200000（S-mode）
  -> 内核内嵌 initramfs
  -> /init（PID 1）
```

最终自动验收标记为：

```text
linuxCPU: PID 1 is alive on OpenC906 RTL
```

当前第一阶段使用 smart_run 原有 16 MiB RAM、C906 内建 CLINT/PLIC 和
`0x10015000` UART。极简 PID 1 是项目自有的无 libc 静态程序，用于尽量缩短
RTL 首次启动时间；BusyBox shell 可作为通过该里程碑后的下一层功能。

## 可选的软件栈快速检查

`QEMUtest/run-qemu.sh` 可以在 QEMU `virt` 机器上快速检查 Linux Image、OpenSBI
和极简 initramfs 是否能执行到同一个 PID 1 标记。它只验证软件栈，不执行
OpenC906 RTL，也不作为本项目的 RTL 验收证据。
