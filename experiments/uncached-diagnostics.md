# Cache 开启后的 fatal 诊断通道

分支：`fix/uncached-diagnostics`，基于 cache 提交 b3c511e。
用户已验收 cache 方案约42分钟到达 PID 1。本修复的真实故障和完整启动验收
留给用户；本轮不做 Linux 精简或性能参数实验。

## 方案

旧方案写入 0x007ff000 普通 RAM，testbench 直接读 RAM 数组，无法看到尚未
写回的 D-cache 数据。volatile/fence 不等于 cache clean；该页也未在 DTS 中
保留，存在被 Linux 分配覆盖的隐患。

现在把物理 RAM 最后一页 0x00fff000–0x00ffffff 用作专用 mailbox：

- RTL sysmap 从复位起设置 Strong Order=1、Cacheable=0、Bufferable=0。
  调整现有强序区域下界即可，UART/PLIC/CLINT 保持原有属性；一起变成强序的
  中间地址空洞没有实际 smart_run RAM。
- DTS reserved-memory/no-map 排除 Linux 分配和普通线性映射。固件/镜像
  准备脚本拒绝覆盖此页，嵌入 DTB 校验也强制检查预留页。
- 每条记录先清完成字、写内容、fence、最后写版本化 magic。
  testbench 只解码完成记录，不再把零值或部分写入当成现场。
- fatal 路径清 MPRV/MIE，使用 M 模式物理地址并避免普通机器中断打断。
  记录保留故障状态；fatal 不恢复执行。最早期汇编路径完全不使用栈。
- 不需要 cache clean、串口初始化、新外设或占用 scratch CSR。
  代价是4 KiB RAM（16 MiB 的约0.024%）及少量 testbench 观察逻辑。

状态记录中的全 cache 清理方案改动较少，但仍依赖 cache maintenance 路径
正常工作，也不能独自解决未预留内存、部分记录与早期汇编入口的问题，因此
本次采用固定不可缓存页。

## 协议 v1

常量源为 `platform/diagnostics/linuxcpu_diag.h`，固件和生成器共用。
每项是 RV64 的8字节字，完成字最后写入。

| 页内偏移 | 生产者 | 顺序字段 | 完成字偏移 |
|---|---|---|---|
| 0x000 | sbi_trap_error | rc, cause, tval, tval2, tinst, mepc, mstatus, ra, sp | 0x048 |
| 0x080 | sbi_hart_hang | ra, sp, mcause, mepc, mtval, mstatus | 0x0b0 |
| 0x100 | _start_hang | mcause, mepc, mtval, mstatus, ra, sp | 0x130 |

trap 来自保存的 trap frame；hang/early 是进入停机路径时的现场。
hang/early 的 mcause 等可能来自先前异常，不能仅凭这些值判定停机原因。

testbench 每类记录首次完成时输出 `[fatal-diag] begin ...`、各字段和实时
硬件 M/S 异常 CSR，最后输出 `[fatal-diag] complete kind=trap|hang|early`。
运行器保存日志、停止模型并返回1，即使 CPU 一直退休。benchmark 也将该标记
判为失败，不能把错误死循环当成性能成功。

无退休看门狗保留，触发时打印 live CSR、PC、总线/定时器及有效记录；没有
完成字时明确显示 absent or incomplete。

边界：CPU 必须还能执行诊断存储、RAM 事务必须能完成；总线损坏或尚未设置
临时 mtvec 的最早指令故障不能保证提交记录。live CSR 只是读取时的最近状态，
也可能被后续异常覆盖。C 路径仍依赖可读的栈/trap frame；汇编 early 路径不依赖它们。

## 已完成验证

- 5.050 t1 timing 模型 `output/verilator/diag-mailbox/c906-linux` 构建通过。
- 正常 full-cache 固件及 early/hang/trap 三个注入配置均编译通过；DTB 精确
  匹配和 no-map 预留检查通过。反汇编核对了 early 路径地址、MPRV/MIE 与提交顺序。
- `scripts/smoke-fatal-diagnostics.sh` 两项短通道检查通过：cache 开启
  （mhcr=0x17f）、无串口、无 clean 时，完整记录的 rc/cause/tval/mepc 与预设值
  一致，约54 retired 即被识别；无完成字的部分记录在两秒内不被误报，程序
  持续退休且没有 RTL 错误。
- 日志：`output/tests/fatal-diag.l2l3VE/`。测试人工产生协议记录，不冒充
  OpenSBI 真实异常路径验收；注入固件仅构建，没有运行。
- Python/Shell 语法检查通过；构建后上游 OpenC906/OpenSBI checkout 已还原。

## 用户验收

正常模型重建，不运行 Linux：

```bash
LINUXCPU_CACHE_MODE=full LINUXCPU_DIAG_TEST=none \
LINUXCPU_OPENSBI_OUTPUT="$PWD/output/opensbi-diag-full" \
LINUXCPU_VERILATOR_VARIANT=diag-mailbox LINUXCPU_JOBS=8 \
scripts/build-verilator-linux.sh
```

短通道检查：

```bash
scripts/smoke-fatal-diagnostics.sh
```

真实路径注入：CASE 可取 early、hang、trap。默认 none，不应用测试补丁。
各注入默认使用独立固件目录。不要同时准备不同镜像，它们会更新 output/sim。

```bash
CASE=early
LINUXCPU_CACHE_MODE=full LINUXCPU_DIAG_TEST="$CASE" \
scripts/prepare-rtl-linux.sh

scripts/run-verilator-linux.py \
  --model output/verilator/diag-mailbox/c906-linux --cwd output/sim \
  --log "output/logs/diag-$CASE.log" --timeout 120
```

预期返回1，出现对应 kind 的完整记录，不是等待超时返回124。
early 在 fw_platform_init 的 cache 初始化后、C trap handler/串口初始化前
执行非法指令，走 _start_hang。hang/trap 在 generic_early_init 的串口初始化前
分别调用 sbi_hart_hang / 执行非法指令，后者走 C trap handler。
early/trap 预期 cause=2，mepc 可用对应注入目录中的 fw_payload.elf 定位。

恢复普通镜像并自行启动验收，使用专门日志避免覆盖旧成功日志：

```bash
LINUXCPU_CACHE_MODE=full LINUXCPU_DIAG_TEST=none \
LINUXCPU_OPENSBI_OUTPUT="$PWD/output/opensbi-diag-full" \
scripts/prepare-rtl-linux.sh

scripts/run-verilator-linux.py \
  --model output/verilator/diag-mailbox/c906-linux --cwd output/sim \
  --log output/logs/diag-linux-validation.log --timeout 0
```

正常启动应无 complete kind 标记，仍以 PID 1 标记返回0。新 sysmap 必须配新模型，
不要复用原 cache-probe 模型。当前已准备好普通 diag-full 镜像，未启动长跑。
