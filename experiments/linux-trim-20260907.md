# Linux 设备注册精简：第一轮

分支 `exp/linux-trim` 从干净的 `17e8eda` 创建，包含已验证的 cache 方案及仍由
用户验收的诊断修复。这里只精简 Linux，未修改 RTL、UART 时序、HZ 或诊断协议。

## 修改

`scripts/build-linux.sh` 增加 trim（本分支默认）和 baseline 配置档。

| 配置 | baseline | trim |
|---|---|---|
| CONFIG_VT | y | n |
| CONFIG_LEGACY_PTYS | y，256对 | n |
| CONFIG_UNIX98_PTYS | y | y |
| 串口控制台 / OF serial | y | y |
| CONFIG_HZ | 250 | 250 |

VT 关闭后，INPUT、SERIO、HID、AT 键盘、PS/2 鼠标及 dummy console 等依赖
随配置解析一起移除。保留 printk、devtmpfs、proc/sysfs、MMU、SBI 和原 PID 1。

源码依据：

- `linux/drivers/tty/pty.c` 的 legacy_pty_init 注册两个各256设备的 driver；
  未设置 TTY_DRIVER_DYNAMIC_DEV，因此 tty_register_driver 会逐个注册512设备。
- `linux/drivers/tty/vt/vt.c` 注册 MAX_NR_CONSOLES=63 个终端，另有 tty0 等设施。
- UNIX98 PTY 使用 TTY_DRIVER_DYNAMIC_DEV，无需在启动时预注册所有可能的 PTY。

代价：不再支持 VT 屏幕/键盘控制台及 BSD legacy PTY；保留 ttyS0 和现代 PTY。
当前 smart_run 平台没有这些被移除的输入硬件，极简 PID 1 仅使用标准输出。

## 隔离及验证

所有产物位于 `output/experiments/linux-trim/`：

- `baseline/.config`：原构建配方仅生成配置，不编译第二套控制内核。
- `kernel/`：精简 .config、vmlinux 和 Image。
- `rootfs/`、`dts/`、`opensbi/`、`sim/`：独立的软件及 RAM 镜像。
- `c906-linux`：已有 5.050 diag-mailbox 模型的独立副本，没有重建/覆盖原模型。
- `probe/trim.json`、`probe/trim.log`：唯一一次120秒启动前缀检查。

Linux 构建限制4线程、CPU 0–7；短测绑定 CPU 10。用户的诊断验收可能同时运行，
宿主墙钟速度不用于做精确 A/B 结论。

实际结果：

- Linux/OpenSBI 编译通过，嵌入 DTB 与诊断预留页校验通过。
- 配置检查通过：VT/legacy PTY 关闭，UNIX98 PTY/串口保留；其余已存在数值/
  字符串配置没有变化，HZ=250。旧 Image 的原 .config 已不在本机，配置对照
  来自同版本源码及原配方，不声称重现旧 Image 的所有构建元数据。
- Image 由现存旧版的 2,138,624 字节减至 1,922,048 字节，缩小216,576字节，约10.1%。
- 链接后无 con_init/vty_init/legacy_pty_init，保留 pty_init 与 serial8250_init。
- 120.03秒检查退休5.63M条，pass=true，无 RTL/fatal 错误；已打印 Linux、
  Machine model 和 SBI 检测信息，重建串口内容未见 panic/Oops。
- 该短测没有到达待优化的设备注册阶段，也没有到 PID 1，不能证明实际加速幅度。
  精简会改变工作量和所处启动阶段，retired/s 不适合直接当本次加速比。
- 实验前后核对原 Image、默认 DTB、diag-full 固件、output/sim/ram00.bin 和
  原 diag-mailbox 模型，SHA256 均未改变。未触碰正在验收的日志。

Image SHA256：`8577f67cbb57943e3d9e1a1245ee34d8f3a84bf0610359638d17c626b668c6f4`

固件 SHA256：`f1fd320e09501fa4009e3b5a605f04cf088165b7985c91aea62ddbd69576cdfe`

模型 SHA256：`0fc3abdbae3ecc14de72d8d273f0f0e4b12421128e529b8d11cb17d3df700a02`

## 预估加速：约1.5–1.9倍，待用户完整验收

从已成功的 cache-on 日志 `output/logs/c906-linux-verilator.log` 提取 UART 里程碑，
用最近的退休采样估计周期边界：

- PLIC 输出结束：约82,815,224 cycles，18,075,292 retired。
- 8250 驱动输出开始：约200,635,211 cycles，37,720,603 retired。
- 区间约117,819,987 cycles，占总225,566,109 cycles 的52.23%。

该区间包含大量 tty 设备注册，但也包含其他初始化。它不是对 VT/PTY 的独占
耗时测量。假定本次省掉其中60%–90%的工作，且宿主每秒周期吞吐相近：

| 假设省掉该区间的比例 | 总启动加速 | 原42分钟对应耗时 |
|---|---:|---:|
| 60% | 1.46× | 28.8分钟 |
| 80% | 1.72× | 24.4分钟 |
| 90% | 1.89× | 22.3分钟 |

因此把1.5–1.9倍作为实验预期，约22–29分钟，不能写成已测得的结果。
即使整个区间都消失，单算此区间也只有约2.09倍；前段 VT 相关工作可能另有
收益，但串口等固定开销仍然存在。现有证据不支持保证2–3倍。

## 复现和后续验收

在项目根目录执行；子 shell 限定环境变量作用范围，所有输出隔离：

```bash
(
  export LINUXCPU_LINUX_PROFILE=trim
  export LINUXCPU_LINUX_OUTPUT="$PWD/output/experiments/linux-trim/kernel"
  export LINUXCPU_ROOTFS_OUTPUT="$PWD/output/experiments/linux-trim/rootfs"
  export LINUXCPU_DTS_OUTPUT="$PWD/output/experiments/linux-trim/dts"
  export LINUXCPU_OPENSBI_OUTPUT="$PWD/output/experiments/linux-trim/opensbi"
  export LINUXCPU_CACHE_MODE=full LINUXCPU_DIAG_TEST=none LINUXCPU_JOBS=4
  scripts/build-linux.sh
  scripts/build-opensbi.sh
  scripts/prepare-rtl-image.py \
    --image "$LINUXCPU_OPENSBI_OUTPUT/platform/generic/firmware/fw_payload.bin" \
    --tb openc906/smart_run/logical/tb/tb.v \
    --output output/experiments/linux-trim/sim
)
```

本机已有上述产物。用户之后验收时可以直接运行独立模型及镜像，日志也隔离：

```bash
taskset -c 10 scripts/run-verilator-linux.py \
  --model output/experiments/linux-trim/c906-linux \
  --cwd output/experiments/linux-trim/sim \
  --log output/experiments/linux-trim/linux-validation.log --timeout 0
```

选择空闲核心，避免与其他验收争用。最终按到 PID 1 的墙钟时间和周期数评估，
并确认 ttyS0 正常工作。此轮不继续改 HZ、printk、FAST_UART 或更多驱动。
