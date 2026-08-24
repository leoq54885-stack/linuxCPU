#!/usr/bin/env bash
# QEMU functional verification for the LinuxCPU software stack.
#
# This script verifies that OpenSBI + Linux + minimal initramfs can boot
# to PID 1 on QEMU's riscv virt machine.  It proves the software is
# correct before investing hours in RTL simulation.
#
# Prerequisites:
#   - qemu-system-riscv64 (system install or set QEMU_BIN env var)
#   - riscv64-linux-gnu-gcc (installed by ../setup.sh)
#   - Linux Image built by ../scripts/build-linux.sh (or make linux)
#   - OpenSBI fw_jump.elf built by ../scripts/build-opensbi.sh (or make firmware)
#
# Usage:
#   ./run-qemu.sh              # build initramfs, boot QEMU, check for PID 1
#   ./run-qemu.sh --keep       # do not kill QEMU after success (interactive)
#
# Exit codes:
#   0  PID 1 marker found in output
#   1  PID 1 marker not found within timeout
#   2  prerequisite missing

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- locate QEMU ---
QEMU_BIN="${QEMU_BIN:-}"
if [[ -z "$QEMU_BIN" ]]; then
    if command -v qemu-system-riscv64 >/dev/null 2>&1; then
        QEMU_BIN="$(command -v qemu-system-riscv64)"
    elif [[ -x "$PROJECT_ROOT/../tools/qemu/install/bin/qemu-system-riscv64" ]]; then
        QEMU_BIN="$PROJECT_ROOT/../tools/qemu/install/bin/qemu-system-riscv64"
    else
        echo "[qemu-test] ERROR: qemu-system-riscv64 not found." >&2
        echo "[qemu-test] Install with: sudo apt-get install -y qemu-system-riscv64" >&2
        exit 2
    fi
fi

# --- locate build outputs ---
LINUX_IMAGE="$PROJECT_ROOT/output/linux/arch/riscv/boot/Image"
OPENSBI_FW="$PROJECT_ROOT/output/opensbi-c906/platform/generic/firmware/fw_jump.elf"

if [[ ! -f "$LINUX_IMAGE" ]]; then
    echo "[qemu-test] ERROR: Linux Image not found at $LINUX_IMAGE" >&2
    echo "[qemu-test] Run 'make linux' first." >&2
    exit 2
fi
if [[ ! -f "$OPENSBI_FW" ]]; then
    echo "[qemu-test] ERROR: OpenSBI fw_jump.elf not found at $OPENSBI_FW" >&2
    echo "[qemu-test] Run 'make firmware' first." >&2
    exit 2
fi

# --- build initramfs ---
echo "[qemu-test] Building initramfs..."
INITRAMFS_DIR="$SCRIPT_DIR/initramfs"
mkdir -p "$INITRAMFS_DIR/dev" "$INITRAMFS_DIR/proc" "$INITRAMFS_DIR/sys"

CC="${CROSS_COMPILE:-riscv64-linux-gnu-}gcc"
if ! command -v "$CC" >/dev/null 2>&1; then
    echo "[qemu-test] ERROR: $CC not found." >&2
    exit 2
fi

"$CC" -static -nostdlib -Os -fno-builtin \
    -o "$INITRAMFS_DIR/init" \
    "$PROJECT_ROOT/rootfs/init.c"
chmod 755 "$INITRAMFS_DIR/init"

INITRAMFS_CPIO="$SCRIPT_DIR/initramfs.cpio"
( cd "$INITRAMFS_DIR" && find . | cpio -H newc -o ) > "$INITRAMFS_CPIO" 2>/dev/null
echo "[qemu-test] initramfs.cpio: $(du -h "$INITRAMFS_CPIO" | cut -f1)"

# --- boot QEMU ---
LOG="$SCRIPT_DIR/qemu-output.log"
TIMEOUT=60

echo "[qemu-test] Booting QEMU (timeout ${TIMEOUT}s)..."
echo "[qemu-test]   QEMU:    $QEMU_BIN"
echo "[qemu-test]   Kernel:  $LINUX_IMAGE"
echo "[qemu-test]   OpenSBI: $OPENSBI_FW"
echo "[qemu-test]   initrd:  $INITRAMFS_CPIO"

KEEP=0
if [[ "${1:-}" == "--keep" ]]; then
    KEEP=1
fi

if [[ "$KEEP" -eq 1 ]]; then
    exec "$QEMU_BIN" \
        -machine virt -nographic -smp 1 -m 256M \
        -kernel "$LINUX_IMAGE" \
        -initrd "$INITRAMFS_CPIO" \
        -append "console=ttyS0,115200 rdinit=/init"
fi

"$QEMU_BIN" \
    -machine virt -nographic -smp 1 -m 256M \
    -kernel "$LINUX_IMAGE" \
    -initrd "$INITRAMFS_CPIO" \
    -append "console=ttyS0,115200 rdinit=/init" \
    > "$LOG" 2>&1 &
QEMU_PID=$!

# --- wait for PID 1 marker ---
RESULT=1
for i in $(seq 1 "$TIMEOUT"); do
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        break
    fi
    if grep -q "PID 1 is alive" "$LOG" 2>/dev/null; then
        RESULT=0
        break
    fi
    sleep 1
done

kill "$QEMU_PID" 2>/dev/null || true
wait "$QEMU_PID" 2>/dev/null || true

# --- report ---
if [[ "$RESULT" -eq 0 ]]; then
    echo ""
    echo "[qemu-test] SUCCESS: PID 1 marker found."
    grep -A2 "reached minimal" "$LOG" | head -3
    exit 0
else
    echo ""
    echo "[qemu-test] FAIL: PID 1 marker not found within ${TIMEOUT}s."
    echo "[qemu-test] Last 20 lines of log:"
    tail -20 "$LOG" >&2
    exit 1
fi
