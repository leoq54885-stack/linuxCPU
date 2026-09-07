# C906 cache 最小性能实验（2026-09-07）

范围：只做短时退休速度验证，不跑完整 PID 1，不修改 Linux 配置或 UART 时序。
基于 main 1469c16，实验分支 exp/cache-enable。原始结果在
`output/benchmarks/20260907-cache-minimal/`（不提交 Git）。

## 实现与环境

- WSL2 / i9-14900HX，绑逻辑 CPU 14，单线程 Verilator 5.050，timing，FAST_UART=0。
- 同一个 `output/verilator/cache-probe/c906-linux` 用于全部测量。
- `scripts/toolchain-bin/verilator` 默认优先选择本地 5.050；旧版安装作为缺失时的回退。
- 只在 OpenSBI `fw_platform_init()` 中匹配 `xuantie,open-c906-smart-run` 后启用 cache。
  顺序来自上游 `smart_run/tests/lib/crt0.s`，并增加 fence / fence.i。
- 模式：off；i（mhcr 设置 1）；id（设置 7，I/D-cache + 写分配）；
  full（设置 0x7f，另设 mhint=0x610c，加入预测器、预取等）。
- mhcr 读回包含硬连线位，因此四组采样分别为 0x108、0x109、0x10f、0x17f。
- 固件、RAM 文件按模式隔离。RAM loader 使用固定 16 MiB 长度，保证一个模型
  能读入不同大小的固件。采样同时输出退休数、周期数和 mhcr。
- 开关默认仍为 off；full 属于未经完整启动验收的实验配置。

原 Linux Image SHA256：
`28c93c5098358614fd537640ac9cb0956acaa0d9f859ca234fd3f42526158b71`。
原 fw_payload.bin 与重建 off 固件完全相同，SHA256：
`087b0bf4624c64730db7d75a429b7e892cc98c28eac68328d991a70e75f509ca`。
Image、DTB 和原默认固件均保留；未重建 Linux。

本次共用模型 SHA256：
`b1bc162c03c4e2f77c11306004150476431115acdc62a3ef905773c44bd8786c`。
有效 full 固件 SHA256：
`1b08fc44ae840bdc2d8b38f416f0990282bc8a16b9aa540bebbf5d716603964c`。

## 一分钟结果

每组从复位运行 60 秒，排除前 10 秒，使用余下首末采样点计算吞吐。
运行顺序为 full、off、i、id，各组模型线程峰值均为 1、短测 pass=true。

| 模式 | 退休指令/小时 | 相对 off | 采样 CPI | 仿真周期/宿主秒 |
|---|---:|---:|---:|---:|
| off | 872 万 | 1.00× | 40.45 | 97,984 |
| i | 2,923 万 | 3.35× | 12.12 | 98,419 |
| id | 2.30 亿 | 26.42× | 1.23 | 78,518 |
| full | 2.79 亿 | 31.99× | 1.36 | 105,013 |

full 一分钟累计退休 447 万条，已输出 Linux 启动横幅，mhcr 在 10,000 retired
采样点已经开启。其主要收益来自周期/指令的下降。id 与 full 进入的阶段不同，
且宿主周期吞吐有波动，不能据此精确归因预测器或预取的独立收益。

这些是启动前缀的速度，不是全程平均速度；固定墙钟时间使各组结束于不同阶段。
若机械地用 107.3M / 77,489 retired/s 外推，约为 23 分钟，但这不构成完整启动
耗时预测，更不是完整功能验收。

反向短测按 off、full 顺序各运行 30 秒，仍排除前 10 秒，结果分别为
983 万条/小时、3.45 亿条/小时，full/off = 35.14×，两组 pass=true。
有效文件为 early-off-r2.json / early-full-r2.json。较短窗口覆盖的启动阶段
不同，因此不与一分钟数据合并求平均；它用于确认数量级收益可重复。
本轮只做了两次 full/off 对照，符合用户限定的最小实验范围。

## 初始化位置与限制

最初将操作放在 generic_early_init，四组各 60 秒都没有到达该调用点，cache 位
均未启用；这些日志为 off-r1 / i-r1 / id-r1 / full-r1，不作为开启 cache 的性能证据。
随后移到更早的 fw_platform_init。有效日志和 JSON 使用 early- 前缀。

按用户要求停止在短测，不验证 PID 1。D-cache 打开后，现有异常诊断写入 RAM
可能尚未写回，testbench 直接读取 RAM 有可见性限制；本次没有修改该诊断路径。
未覆盖长时间 cache 一致性、完整用户态路径或所有 cache maintenance 行为。

## 复现

构建各模式到独立目录（MODE 取 off、i、id、full）：

```bash
MODE=full
LINUXCPU_CACHE_MODE="$MODE" \
LINUXCPU_OPENSBI_OUTPUT="$PWD/output/opensbi-cache-early-$MODE" \
LINUXCPU_JOBS=8 scripts/build-opensbi.sh

scripts/prepare-rtl-image.py \
  --image "output/opensbi-cache-early-$MODE/platform/generic/firmware/fw_payload.bin" \
  --tb openc906/smart_run/logical/tb/tb.v \
  --output "output/benchmarks/20260907-cache-minimal/ram-early-$MODE"
```

共用模型构建一次（先准备好 off 固件；默认包装器选择 5.050）：

```bash
LINUXCPU_CACHE_MODE=off \
LINUXCPU_OPENSBI_OUTPUT="$PWD/output/opensbi-cache-early-off" \
LINUXCPU_VERILATOR_VARIANT=cache-probe LINUXCPU_JOBS=8 \
scripts/build-verilator-linux.sh
```

串行测试，避免构建或其他仿真同时竞争 CPU：

```bash
python3 scripts/benchmark-verilator.py \
  --model output/verilator/cache-probe/c906-linux \
  --cwd "output/benchmarks/20260907-cache-minimal/ram-early-$MODE" \
  --firmware "output/opensbi-cache-early-$MODE/platform/generic/firmware/fw_payload.bin" \
  --output-dir output/benchmarks/cache-recheck --label "$MODE" \
  --duration 60 --warmup 10 --cpus 14
```

每份 JSON 保存模型/固件 SHA256、构建参数、样本、宿主信息、错误检查和吞吐。
当前 output/sim 可被构建步骤重新生成；测量始终使用隔离的 ram-early-* 目录。
