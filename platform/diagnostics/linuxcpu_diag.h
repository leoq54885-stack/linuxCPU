/* SPDX-License-Identifier: BSD-2-Clause
 * RV64 smart_run fatal mailbox, protocol v1. Shared firmware/testbench constants.
 * This page must be reserved and strongly ordered / non-cacheable at reset.
 */
#ifndef LINUXCPU_DIAG_H
#define LINUXCPU_DIAG_H
#define LINUXCPU_DIAG_BASE        0x00fff000
#define LINUXCPU_DIAG_TRAP_OFFSET 0x000
#define LINUXCPU_DIAG_HANG_OFFSET 0x080
#define LINUXCPU_DIAG_EARLY_OFFSET 0x100
#define LINUXCPU_DIAG_TRAP_MAGIC  0x4c43395452415031
#define LINUXCPU_DIAG_HANG_MAGIC  0x4c433948414e4731
#define LINUXCPU_DIAG_EARLY_MAGIC 0x4c43394541524c31
#endif
