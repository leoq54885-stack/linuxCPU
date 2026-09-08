# OpenC906 Linux — Cadence 运行包

本包包含 RTL、预生成 RAM、固件/内核符号及运行器。配置见 `provenance.json`，输入校验见 `manifest.json`。

## 环境

验收环境为 CentOS 7.9 x86-64、Python 3.6.8、Cadence Incisive 15.20-p001（64 位 `irun`）。先加载本机 Cadence 和许可证环境，使 `command -v irun` 可用。目标机只进行 RTL 编译和仿真，软件镜像由 Ubuntu 构建主机生成。

## 编译与运行

在解压后的包目录运行：

```bash
python3 cadence.py check
python3 cadence.py build --timeout 600
python3 cadence.py probe --timeout 120
```

短跑达到时间上限返回 124；查看 `work/probe.json` 中的退休速度及 `work/probe.log` 中的启动进度。full-cache 的 `mhcr` 应为 `0x17f`。完整启动：

```bash
python3 cadence.py run --timeout 0
```

出现 `linuxCPU: PID 1 is alive on OpenC906 RTL` 后返回 0；fatal、停滞或提前退出返回非零。`Ctrl-C` 结束进程组。直接调用运行器时 build 默认 600 秒，probe/run 默认 120 秒；`--timeout 0` 表示墙钟不限时。

`work/` 保存编译库、临时文件、各操作的 `.log` 和 `.json`。同一操作会覆盖上一份日志，需保留时先复制。`--irun /path/to/irun` 可指定工具路径。需要层次信号读取权限时，以 `build --access-read` 重新编译。

## 运行配置与空间

编译使用 `-top tb`、`-default_ext verilog` 和头文件搜索路径；保持 RTL timing、真实 UART 和早期 fatal mailbox 诊断。波形生成已关闭。

默认空间参数：

| 参数 | 默认值 | 含义 |
|---|---|---|
| `--file-mib` | 256 | 子进程单文件硬上限；同时禁止 core dump |
| `--log-mib` | 32 | 运行器日志上限 |
| `--dir-mib` | 2048 | 包目录大小检查上限，每秒检查 |
| `--free-mib` | 4096 | 虚拟机所在分区空闲下限 |

达到限制会终止仿真。目录检查可能在轮询间超额；宿主机薄置备磁盘余量需在宿主机监控，严格总量限制可由管理员配置配额或固定容量文件系统。

更新 RTL、内核或固件时，在源码项目重新执行 `make cadence-package`。每份包是独立快照，重新生成后重新编译。
