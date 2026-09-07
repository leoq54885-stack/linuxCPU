#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/env.sh"

LINUX_SOURCE="$ROOT/linux"
LINUX_OUTPUT="${LINUXCPU_LINUX_OUTPUT:-$ROOT/output/linux}"
ROOTFS_OUTPUT="${LINUXCPU_ROOTFS_OUTPUT:-$ROOT/output/rootfs}"
PROFILE="${LINUXCPU_LINUX_PROFILE:-trim}"
if [[ "$PROFILE" != baseline && "$PROFILE" != trim ]]; then
    echo 'LINUXCPU_LINUX_PROFILE must be baseline or trim' >&2
    exit 2
fi
CONFIG_ONLY=0
if [[ "${1:-}" == --config-only ]]; then
    CONFIG_ONLY=1
    shift
fi
if (($#)); then
    echo 'Usage: build-linux.sh [--config-only]' >&2
    exit 2
fi
INIT_BINARY="$ROOTFS_OUTPUT/init"
INITRAMFS_LIST="$ROOTFS_OUTPUT/initramfs.list"
JOBS="${LINUXCPU_JOBS:-$(nproc)}"

mkdir -p "$LINUX_OUTPUT" "$ROOTFS_OUTPUT"

printf '[linux] building freestanding PID 1\n'
riscv64-linux-gnu-gcc \
    -march=rv64imafdc -mabi=lp64d -Os -static -nostdlib \
    -ffreestanding -fno-builtin -fno-stack-protector \
    -fno-asynchronous-unwind-tables \
    -Wl,--build-id=none -Wl,-e,_start -Wl,-z,max-page-size=4096 \
    -o "$INIT_BINARY" "$ROOT/rootfs/init.c"

sed "s#@INIT_PATH@#$INIT_BINARY#" \
    "$ROOT/rootfs/initramfs.list.in" > "$INITRAMFS_LIST"

printf '[linux] generating minimal kernel configuration\n'
make -C "$LINUX_SOURCE" O="$LINUX_OUTPUT" ARCH=riscv \
    CROSS_COMPILE=riscv64-linux-gnu- tinyconfig

config="$LINUX_SOURCE/scripts/config"
config_args=(--file "$LINUX_OUTPUT/.config")

for symbol in \
    64BIT MMU RISCV_SBI RISCV_ISA_C FPU \
    ERRATA_THEAD ERRATA_THEAD_MAE \
    OF OF_EARLY_FLATTREE IRQ_DOMAIN RISCV_INTC RISCV_TIMER SIFIVE_PLIC \
    TTY SERIAL_8250 SERIAL_8250_CONSOLE SERIAL_OF_PLATFORM \
    BLK_DEV_INITRD BINFMT_ELF PRINTK PRINTK_TIME \
    DEVTMPFS DEVTMPFS_MOUNT PROC_FS SYSFS TMPFS \
    EXPERT EMBEDDED CC_OPTIMIZE_FOR_SIZE; do
    "$config" "${config_args[@]}" --enable "$symbol"
done

for symbol in SMP MODULES PCI NET WERROR ERRATA_THEAD_CMO; do
    "$config" "${config_args[@]}" --disable "$symbol"
done

if [[ "$PROFILE" == trim ]]; then
    # The board has a serial console; avoid eager creation of unused TTYs.
    "$config" "${config_args[@]}" --disable VT --disable LEGACY_PTYS --enable UNIX98_PTYS
fi

"$config" "${config_args[@]}" --set-str INITRAMFS_SOURCE "$INITRAMFS_LIST"
"$config" "${config_args[@]}" --set-str CMDLINE \
    "earlycon=uart8250,mmio32,0x10015000 console=ttyS0,115200 rdinit=/init"
"$config" "${config_args[@]}" --enable CMDLINE_EXTEND

make -C "$LINUX_SOURCE" O="$LINUX_OUTPUT" ARCH=riscv \
    CROSS_COMPILE=riscv64-linux-gnu- olddefconfig

for required in CONFIG_ERRATA_THEAD=y CONFIG_ERRATA_THEAD_MAE=y; do
    grep -qx "$required" "$LINUX_OUTPUT/.config" || {
        printf '[linux] required C906 option was not selected: %s\n' "$required" >&2
        exit 1
    }
done

if [[ "$PROFILE" == trim ]]; then
    for required in '# CONFIG_VT is not set' '# CONFIG_LEGACY_PTYS is not set' \
        CONFIG_UNIX98_PTYS=y CONFIG_TTY=y CONFIG_SERIAL_8250_CONSOLE=y \
        CONFIG_SERIAL_OF_PLATFORM=y; do
        grep -qx "$required" "$LINUX_OUTPUT/.config" || {
            printf '[linux] trim configuration check failed: %s\n' "$required" >&2
            exit 1
        }
    done
fi
printf '[linux] profile=%s config=%s\n' "$PROFILE" "$LINUX_OUTPUT/.config"
((CONFIG_ONLY == 0)) || exit 0

printf '[linux] compiling Image with %s jobs\n' "$JOBS"
make -C "$LINUX_SOURCE" O="$LINUX_OUTPUT" ARCH=riscv \
    CROSS_COMPILE=riscv64-linux-gnu- -j"$JOBS" Image

image="$LINUX_OUTPUT/arch/riscv/boot/Image"
[[ -f "$image" ]] || { echo "Linux Image was not generated" >&2; exit 1; }

printf '[linux] outputs:\n'
ls -lh "$INIT_BINARY" "$image"
printf '[linux] load address: 0x00200000\n'
