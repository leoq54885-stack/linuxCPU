#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/env.sh"

OPENSBI_OUTPUT="${LINUXCPU_OPENSBI_OUTPUT:-$ROOT/output/opensbi-c906}"
CACHE_MODE="${LINUXCPU_CACHE_MODE:-off}"
if [[ "$CACHE_MODE" != off && -z "${LINUXCPU_OPENSBI_OUTPUT:-}" ]]; then
    OPENSBI_OUTPUT="$ROOT/output/opensbi-cache-$CACHE_MODE"
fi
case "$CACHE_MODE" in
    off) CACHE_MHCR=0; CACHE_MHINT=0 ;;
    i) CACHE_MHCR=1; CACHE_MHINT=0 ;;
    id) CACHE_MHCR=7; CACHE_MHINT=0 ;;
    full) CACHE_MHCR=0x7f; CACHE_MHINT=0x610c ;;
    *) echo "LINUXCPU_CACHE_MODE must be off, i, id, or full" >&2; exit 2 ;;
esac
LINUX_IMAGE="$ROOT/output/linux/arch/riscv/boot/Image"
DT_SOURCE="$ROOT/platform/dts/open-c906-smart-run.dts"
DTB="$ROOT/output/dts/open-c906-smart-run.dtb"
JOBS="${LINUXCPU_JOBS:-$(nproc)}"
OPENSBI_PATCH="$ROOT/patches/opensbi/0001-add-rtl-fatal-diagnostics.patch"
PATCH_APPLIED=0
CACHE_PATCH="$ROOT/patches/opensbi/0002-smart-run-cache-experiment.patch"
CACHE_PATCH_APPLIED=0

cleanup() {
    if ((CACHE_PATCH_APPLIED == 1)); then
        git -C "$ROOT/opensbi" apply --reverse "$CACHE_PATCH"
    fi
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

git -C "$ROOT/opensbi" apply --check "$CACHE_PATCH"
git -C "$ROOT/opensbi" apply "$CACHE_PATCH"
CACHE_PATCH_APPLIED=1

printf '[opensbi] cache=%s text=0x00000000 payload=0x00200000 fdt=0x00f00000 quiet=1\n' "$CACHE_MODE"
make -C "$ROOT/opensbi" O="$OPENSBI_OUTPUT" \
    PLATFORM=generic \
    PLATFORM_DEFCONFIG=../../../../configs/opensbi-c906-defconfig \
    "platform-cflags-y=-DLINUXCPU_C906_MHCR=$CACHE_MHCR -DLINUXCPU_C906_MHINT=$CACHE_MHINT" \
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
printf '%s\n' "$CACHE_MODE" > "$OPENSBI_OUTPUT/cache-mode"
