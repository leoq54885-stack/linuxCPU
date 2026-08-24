# OpenC906 smart_run platform

这里保存 C906 smart_run 的设备树、OpenSBI 平台代码和 RTL overlay。

OpenC906 顶层已经包含 CLINT 与 PLIC；适配工作应确认其地址和连接，不重复实现
中断控制器。

当前 RTL 已确认：

- C906 内部 APB 基址：`0x4000000000`
- PLIC：内部 APB 偏移 `0`，256 个输入槽位
- CLINT：内部 APB 偏移 `0x04000000`
- UART：`0x10015000`，外部中断输入 0 映射到 PLIC source 16
- `mtime` 来源及仿真 CPU 时钟：100 MHz
