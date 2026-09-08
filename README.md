# linuxCPU

基于 OpenC906 与 smart_run SoC 的 Linux RTL 仿真工程，提供从源码准备、内核和固件构建到启动用户态的完整流程。

启动链为 OpenC906 → OpenSBI → Linux → 内嵌 initramfs → `/init`（PID 1）。

## 环境与系统配置

| 项目 | 配置 |
|---|---|
| 主机 | Ubuntu 24.04 x86-64，支持 WSL2 |
| 主仿真器 | Verilator 5.050，单线程，timing 模式 |
| RTL 冒烟工具 | Icarus Verilog / VVP 12.0 |
| 交叉工具链 | `riscv64-linux-gnu-gcc`、`riscv64-unknown-elf-gcc` |
| CPU | OpenC906，RV64GC，M/S/U 模式，Sv39 MMU |
| SoC | smart_run，16 MiB RAM，CLINT、PLIC、UART |
| 时钟与串口 | 100 MHz；UART 地址 `0x10015000`，115200 波特率 |
| Linux | 固定版本源码，trim 配置，HZ=250，串口控制台和 UNIX98 PTY |
| 用户态 | 工程自有的静态 `/init`，内嵌于内核 initramfs |

源码版本由 [versions.lock](versions.lock) 固定，硬件描述见
[设备树](platform/dts/open-c906-smart-run.dts)，内核配置见
[配置片段](configs/linux-c906-minimal.fragment)。

## 准备环境

首次准备需要网络访问；`setup.sh` 通过 `sudo` 安装缺少的主机依赖，并下载固定版本源码及基础工具。

```bash
git clone https://github.com/leoq54885-stack/linuxCPU.git
cd linuxCPU
./setup.sh
source env.sh
```

Verilator 5.050 可安装到 `.toolchain/verilator-5.050-install/`，项目会优先使用该路径。
使用其他安装路径时，通过 `LINUXCPU_VERILATOR_BIN` 指定可执行文件：

```bash
export LINUXCPU_VERILATOR_BIN=/path/to/verilator-5.050/bin/verilator
```

本地交付环境可直接运行 `make doctor` 检查源码版本、工具及平台配置。

## 构建与运行

在项目根目录设置运行配置，然后构建和启动：

```bash
export LINUXCPU_CACHE_MODE=full
export LINUXCPU_LINUX_PROFILE=trim
export LINUXCPU_VERILATOR_THREADS=1
export LINUXCPU_FAST_UART=0
export LINUXCPU_DIAG_TEST=none
export LINUXCPU_JOBS=8
export LINUXCPU_LINUX_SIM_TIMEOUT=0

make build
make run
```

这些环境变量在当前 shell 中生效；新终端执行构建或运行前，重新设置即可。

运行日志写入 `output/logs/c906-linux-verilator.log`，每次运行覆盖该文件。
到达以下标记后，运行器自动以状态码 0 退出：

```text
linuxCPU: PID 1 is alive on OpenC906 RTL
```

`Ctrl-C` 停止当前仿真。可指定空闲物理核运行，例如：

```bash
taskset -c 9 make run
```

### 常用配置参数

| 环境变量 | 用途 | 代码默认值 |
|---|---|---|
| `LINUXCPU_CACHE_MODE` | 缓存模式：`off` / `i` / `id` / `full`；交付运行配置为 `full` | `off` |
| `LINUXCPU_LINUX_PROFILE` | 内核配置：`trim` / `baseline` | `trim` |
| `LINUXCPU_JOBS` | 编译并行任务数 | `nproc` |
| `LINUXCPU_VERILATOR_THREADS` | 仿真线程数 | `1` |
| `LINUXCPU_VERILATOR_BIN` | Verilator 可执行文件路径 | 项目工具包装器 |
| `LINUXCPU_LINUX_SIM_TIMEOUT` | 宿主运行时限，单位秒；`0` 表示持续运行 | `0` |

例如，设置 120 秒运行时限：

```bash
LINUXCPU_LINUX_SIM_TIMEOUT=120 make run
```

### 常用命令

| 命令 | 功能 |
|---|---|
| `make doctor` | 检查环境与平台配置 |
| `make smoke` | 运行 OpenC906 官方 MMU RTL 冒烟用例 |
| `make smoke-clint` | 运行 CLINT 定向检查 |
| `make dts` | 构建设备树 |
| `make linux` | 构建 Linux 和内嵌用户态 |
| `make firmware` | 构建 OpenSBI 与 Linux payload |
| `make build` / `make rtl-linux` | 构建完整软件镜像与 Verilator 模型 |
| `make run` | 启动 Linux RTL 仿真 |
| `make perf-smoke` | 运行固定时长性能探针 |
| `make rtl-linux-iverilog` / `make run-iverilog` | 使用 Icarus 构建／运行 |
| `make status` | 查看工程与上游源码状态 |

## 工程目录

| 路径 | 内容 |
|---|---|
| `configs/` | Linux 配置片段 |
| `platform/` | 设备树、平台诊断接口和定向测试 |
| `rootfs/` | `/init` 源码与 initramfs 清单 |
| `patches/` | 上游源码补丁 |
| `scripts/` | 构建、运行和检查脚本 |
| `output/linux/` | Linux Image、vmlinux 和生成配置 |
| `output/opensbi-cache-full/` | full-cache 配置的 OpenSBI 固件 |
| `output/verilator/` | Verilator 模型 |
| `output/sim/` | 仿真 RAM 镜像与 testbench |
| `output/logs/` | 运行日志 |
