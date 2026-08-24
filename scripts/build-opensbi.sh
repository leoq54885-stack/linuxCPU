#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/env.sh"

OPENSBI_OUTPUT="$ROOT/output/opensbi-c906"
LINUX_IMAGE="$ROOT/output/linux/arch/riscv/boot/Image"
DT_SOURCE="$ROOT/platform/dts/open-c906-smart-run.dts"
DTB="$ROOT/output/dts/open-c906-smart-run.dtb"
JOBS="${LINUXCPU_JOBS:-$(nproc)}"
OPENSBI_PATCH="$ROOT/patches/opensbi/0001-add-rtl-fatal-diagnostics.patch"
PATCH_APPLIED=0

cleanup() {
    if ((PATCH_APPLIED == 1)); then
        git -C "$ROOT/opensbi" apply --reverse "$OPENSBI_PATCH"
    fi
}
trap cleanup EXIT

[[ -f "$LINUX_IMAGE" ]] || "$ROOT/scripts/build-linux.sh"
if [[ ! -f "$DTB" || "$DT_SOURCE" -nt "$DTB" || \
      "$ROOT/scripts/build-dtb.sh" -nt "$DTB" ]]; then
    "$ROOT/scripts/build-dtb.sh"
fi

if git -C "$ROOT/opensbi" apply --check "$OPENSBI_PATCH"; then
    git -C "$ROOT/opensbi" apply "$OPENSBI_PATCH"
    PATCH_APPLIED=1
elif ! git -C "$ROOT/opensbi" apply --reverse --check "$OPENSBI_PATCH"; then
    echo "OpenSBI source has changes that conflict with the project patch" >&2
    exit 1
fi

printf '[opensbi] text=0x00000000 payload=0x00200000 fdt=0x00f00000 quiet=1\n'
make -C "$ROOT/opensbi" O="$OPENSBI_OUTPUT" \
    PLATFORM=generic \
    PLATFORM_DEFCONFIG=../../../../configs/opensbi-c906-defconfig \
    CROSS_COMPILE=riscv64-linux-gnu- \
    FW_TEXT_START=0x0 FW_PAYLOAD_OFFSET=0x200000 \
    FW_OPTIONS=0x1 \
    FW_PAYLOAD_FDT_ADDR=0x00f00000 \
    FW_PAYLOAD_PATH="$LINUX_IMAGE" FW_FDT_PATH="$DTB" \
    -j"$JOBS"

firmware="$OPENSBI_OUTPUT/platform/generic/firmware/fw_payload.bin"
[[ -f "$firmware" ]] || { echo "OpenSBI payload was not generated" >&2; exit 1; }

size="$(stat -c %s "$firmware")"
((size <= 16 * 1024 * 1024)) || {
    printf '[opensbi] firmware is %d bytes, larger than 16MiB RTL RAM\n' "$size" >&2
    exit 1
}
ls -lh "$firmware"
"$ROOT/scripts/verify-firmware-dtb.sh" "$firmware" \
    "$OPENSBI_OUTPUT/platform/generic/firmware/fw_payload.elf" "$DTB"
