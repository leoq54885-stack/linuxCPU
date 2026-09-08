# linuxCPU

基于 OpenC906 与 smart_run SoC 的 Linux RTL 仿真工程，支持 **Verilator** 和 **Cadence Incisive**。提供源码准备、内核与固件构建、RTL 编译及启动用户态的完整流程。

启动链：OpenC906 → OpenSBI → Linux → 内嵌 initramfs → `/init`（PID 1）。

## 环境与版本

| 用途 | 已验证环境 |
|---|---|
| 软件构建主机 | Ubuntu 24.04 x86-64，支持 WSL2；Python 3.12.3、GCC 13.3.0、DTC 1.7.0 |
| RISC-V 工具链 | `riscv64-linux-gnu-gcc` 13.3.0；`riscv64-unknown-elf-gcc` 13.2.0 |
| Verilator 仿真 | Verilator 5.050，单线程，timing 模式 |
| Cadence 仿真 | CentOS 7.9 x86-64，Python 3.6.8，Incisive 15.20-p001（64 位 `irun`），已配置许可证 |
| 独立 RTL 冒烟 | Icarus Verilog / VVP 12.0 |

Cadence 采用构建主机生成软件、仿真主机编译 RTL 的交付方式。CentOS 端只需 Python 3.6+ 和 Cadence 环境，直接使用离线运行包。

源码提交由 [versions.lock](versions.lock) 固定。

## 系统配置

| 项目 | 配置 |
|---|---|
| CPU | OpenC906，RV64GC，M/S/U 模式，Sv39 MMU |
| SoC | smart_run，16 MiB RAM，CLINT、PLIC、UART |
| 时钟与串口 | 100 MHz；UART 地址 `0x10015000`，115200 波特率 |
| Linux | 7.2-rc7，trim 配置，HZ=250，串口控制台与 UNIX98 PTY |
| 用户态 | 工程自有静态 `/init`，内嵌于内核 initramfs |
| 交付配置 | full-cache、真实 UART、正常启动固件 |

硬件描述见 [设备树](platform/dts/open-c906-smart-run.dts)，内核选项见 [配置片段](configs/linux-c906-minimal.fragment)。

## 准备构建主机

首次准备需要网络；`setup.sh` 通过 `sudo` 安装缺少的主机依赖，并下载固定源码及基础工具。

```bash
git clone https://github.com/leoq54885-stack/linuxCPU.git
cd linuxCPU
./setup.sh
source env.sh
```

Verilator 5.050 安装在 `.toolchain/verilator-5.050-install/` 时，项目包装器优先选择它。也可指定已有安装：

```bash
export LINUXCPU_VERILATOR_BIN=/path/to/verilator-5.050/bin/verilator
```

`make doctor` 检查构建主机源码、工具及平台配置。

## 共用构建配置

在构建主机的项目根目录设置：

```bash
export LINUXCPU_CACHE_MODE=full
export LINUXCPU_LINUX_PROFILE=trim
export LINUXCPU_FAST_UART=0
export LINUXCPU_DIAG_TEST=none
export LINUXCPU_JOBS=8
```

这些变量在当前 shell 中生效。新终端重新设置；Cadence 运行包已固化构建时配置，可查看包内 `provenance.json`。

## Verilator 构建与运行

```bash
export LINUXCPU_VERILATOR_THREADS=1
export LINUXCPU_LINUX_SIM_TIMEOUT=0
make build
make run
```

默认 `SIM=verilator`，也可显式执行 `make build SIM=verilator` 和 `make run SIM=verilator`。

日志位于 `output/logs/c906-linux-verilator.log`，每次运行覆盖。限时运行示例：

```bash
LINUXCPU_LINUX_SIM_TIMEOUT=120 make run
```

## Cadence 构建与运行

### Ubuntu 打包，CentOS 仿真

在已设置共用配置的构建主机执行：

```bash
make cadence-package
```

命令构建 Linux、OpenSBI、RAM 镜像和 RTL 快照，打印压缩包与校验文件的位置。每次生成独立目录，保留之前的包与日志；最新包通过 `output/cadence/latest` 访问。包内只包含仿真输入、符号文件和运行器。

将同目录下的 `linuxcpu-cadence.tar.gz` 与 `linuxcpu-cadence.tar.gz.sha256` 传到 CentOS。加载本机 Cadence/许可证环境后：

```bash
command -v irun
sha256sum -c linuxcpu-cadence.tar.gz.sha256
tar xzf linuxcpu-cadence.tar.gz
cd linuxcpu-cadence
python3 cadence.py check
python3 cadence.py build --timeout 600
python3 cadence.py probe --timeout 120
```

短跑达到时间上限返回 **124**。查看 `work/probe.json` 的退休指令速度及 `work/probe.log` 的启动进度。完整运行：

```bash
python3 cadence.py run --timeout 0
```

包内 `work/` 保存编译库、临时文件、日志与统计。每次运行覆盖同类操作的日志；需要保留时先复制。更新软件或 RTL 后，重新生成包并编译。新包请解压到新目录。

### 同机安装了构建工具和 Cadence

```bash
export LINUXCPU_LINUX_SIM_TIMEOUT=0
make build SIM=cadence
make run SIM=cadence
```

也可用 `make build-cadence`、`make run-cadence`、`make probe-cadence`。这些命令默认选择最新包。`LINUXCPU_CADENCE_OUTPUT` 可指定包目录；打包时应指定新目录，运行时指向已有包。

仅重新编译已有包：

```bash
python3 output/cadence/latest/cadence.py build --timeout 600
```

### 运行与空间限制

两种仿真器均在出现以下标记后以状态码 0 退出：

```text
linuxCPU: PID 1 is alive on OpenC906 RTL
```

`Ctrl-C` 停止仿真。`--timeout 0` 或项目入口的 `LINUXCPU_LINUX_SIM_TIMEOUT=0` 表示墙钟不限时。直接调用 `cadence.py` 时，build 默认 600 秒，probe/run 默认 120 秒。

Cadence 默认关闭波形和 core dump；子进程单文件上限 256 MiB，运行器日志上限 32 MiB，包目录大小每秒检查（上限 2 GiB），虚拟机分区空闲下限 4 GiB。限额选项见 [运行包说明](scripts/cadence/README.md)。薄置备虚拟磁盘还需在宿主机监控实际余量；严格总量限制可配置文件系统配额。

## 常用配置参数

| 变量 | 用途 | 默认值 |
|---|---|---|
| `LINUXCPU_CACHE_MODE` | `off` / `i` / `id` / `full` | `off`，交付示例显式设为 `full` |
| `LINUXCPU_LINUX_PROFILE` | `trim` / `baseline` | `trim` |
| `LINUXCPU_JOBS` | 软件与 Verilator 编译任务数 | `nproc` |
| `LINUXCPU_VERILATOR_THREADS` | Verilator 仿真线程数 | `1` |
| `LINUXCPU_VERILATOR_BIN` | Verilator 路径 | 项目包装器 |
| `LINUXCPU_IRUN_BIN` | 项目 Cadence 入口使用的工具路径 | `irun` |
| `LINUXCPU_LINUX_SIM_TIMEOUT` | 项目运行入口时限，秒；0 为不限时 | `0` |
| `LINUXCPU_CADENCE_BUILD_TIMEOUT` | Cadence RTL 编译时限，秒 | `600` |
| `LINUXCPU_CADENCE_PROBE_TIMEOUT` | Cadence 短跑时限，秒 | `120` |
| `LINUXCPU_CADENCE_OUTPUT` | 指定 Cadence 包目录 | 打包时新建目录；运行时选最新包 |

## 常用命令

| 命令 | 功能 |
|---|---|
| `make doctor` | 检查构建主机环境与平台配置 |
| `make smoke` / `make smoke-clint` | MMU 冒烟 / CLINT 定向检查 |
| `make dts` / `make linux` / `make firmware` | 构建设备树 / Linux / OpenSBI payload |
| `make build` / `make run` | Verilator 构建 / 运行 |
| `make build SIM=cadence` / `make run SIM=cadence` | Cadence 打包并编译 / 运行 |
| `make cadence-package` | 构建并生成离线 Cadence 包 |
| `make check-cadence` / `make probe-cadence` | 包校验 / 固定时长短跑 |
| `make test-cadence` | 本地打包逻辑与运行器测试 |
| `make perf-smoke` | Verilator 固定时长性能探针 |
| `make rtl-linux-iverilog` / `make run-iverilog` | Icarus 构建 / 运行 |
| `make status` | 查看工程与上游源码状态 |

## 工程目录

| 路径 | 内容 |
|---|---|
| `configs/` | Linux 与 OpenSBI 配置 |
| `platform/` | 设备树、诊断接口和定向测试 |
| `rootfs/` | `/init` 源码与 initramfs 清单 |
| `patches/` | 上游源码补丁 |
| `scripts/` | 构建、运行和检查脚本 |
| `scripts/cadence/` | Cadence 打包器、运行器、包内说明及测试 |
| `output/linux/` | Linux Image、vmlinux 和生成配置 |
| `output/opensbi-cache-full/` | full-cache OpenSBI 固件 |
| `output/verilator/` | Verilator 模型 |
| `output/sim/` | Verilator / Icarus RAM 镜像与 testbench |
| `output/cadence/` | Cadence 独立运行包、压缩包与最新包入口 |
| `output/logs/` | Verilator / Icarus 日志 |
