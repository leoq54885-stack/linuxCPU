# Upstream patches

需要修改 `openc906`、`opensbi`、`linux` 或 `buildroot` 时，将可重复应用的补丁
按仓库名保存在子目录中。禁止把唯一改动只留在被 `.gitignore` 忽略的 checkout。

构建脚本会临时应用所需补丁，并在退出时自动反向还原，以保证固定版本的上游
checkout 始终保持干净。

- `openc906/0001-mark-smart-run-uart-device.patch`：保留 16 MiB RAM 的普通
  可缓存属性，把 `0x10015000` UART 放入 C906 已有的强序、不可缓存外设窗口。
- `opensbi/0001-add-rtl-fatal-diagnostics.patch`：在 OpenSBI 致命停机路径保留
  testbench 所需的异常现场，不改变正常启动路径。
- `opensbi/0002-smart-run-cache-experiment.patch`：只对 smart_run 板，在
  `fw_platform_init` 中按官方 crt0 顺序启用 cache。`LINUXCPU_CACHE_MODE`
  可选 `off`（默认）、`i`、`id`、`full`；开启组默认使用独立固件输出目录。
  当前仅用于短时性能实验，未完成 Linux/PID 1 验收。开启 D-cache 后，现有
  testbench 直接读取 RAM 的异常诊断可能看不到尚未写回的缓存数据。
