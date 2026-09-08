# Upstream patches

需要修改 `openc906`、`opensbi`、`linux` 或 `buildroot` 时，将可重复应用的补丁
按仓库名保存在子目录中。禁止把唯一改动只留在被 `.gitignore` 忽略的 checkout。

构建脚本会临时应用所需补丁，并在退出时自动反向还原，以保证固定版本的上游
checkout 始终保持干净。

- `openc906/0001-mark-smart-run-uart-device.patch`：RAM 最后一页从复位起为
  强序不可缓存诊断页；其余 RAM 可缓存，UART 仍位于强序不可缓存窗口。
- `opensbi/0001-add-rtl-fatal-diagnostics.patch`：在 OpenSBI 致命停机路径保留
  testbench 所需的异常现场，并覆盖无需栈的早期汇编停机路径。协议常量见
  `platform/diagnostics/linuxcpu_diag.h`，短通道检查见 `scripts/smoke-fatal-diagnostics.sh`。
- `opensbi/0002-smart-run-cache-experiment.patch`：只对 smart_run 板，在
  `fw_platform_init` 中按官方 crt0 顺序启用 cache。`LINUXCPU_CACHE_MODE`
  可选 `off`（默认）、`i`、`id`、`full`；开启组默认使用独立固件输出目录。
  用户已验收 cache 开启后约42分钟启动到 PID 1。
- `opensbi/0003-fatal-diagnostic-test-hooks.patch`：仅显式设置
  `LINUXCPU_DIAG_TEST=early|hang|trap` 时应用，用于串口初始化前的真实路径验收。
  默认 none，注入镜像与普通镜像隔离。
