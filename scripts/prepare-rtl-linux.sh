#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SMART="$ROOT/openc906/smart_run"
SIM_OUTPUT="$ROOT/output/sim"
FIRMWARE="$ROOT/output/opensbi-c906/platform/generic/firmware/fw_payload.bin"
LINUX_IMAGE="$ROOT/output/linux/arch/riscv/boot/Image"
DT_SOURCE="$ROOT/platform/dts/open-c906-smart-run.dts"
DTB="$ROOT/output/dts/open-c906-smart-run.dtb"

firmware_stale=0
if [[ ! -f "$FIRMWARE" ]]; then
    firmware_stale=1
else
    for input in "$LINUX_IMAGE" "$DT_SOURCE" "$DTB" \
        "$ROOT/scripts/build-dtb.sh" "$ROOT/scripts/build-opensbi.sh" \
        "$ROOT/configs/opensbi-c906-defconfig"; do
        if [[ -e "$input" && "$input" -nt "$FIRMWARE" ]]; then
            firmware_stale=1
            break
        fi
    done
fi
if ((firmware_stale == 1)); then
    printf '[rtl-linux] firmware is missing or stale; rebuilding it first\n'
    "$ROOT/scripts/build-opensbi.sh"
fi

"$ROOT/scripts/verify-firmware-dtb.sh" "$FIRMWARE" \
    "$ROOT/output/opensbi-c906/platform/generic/firmware/fw_payload.elf" "$DTB"
mkdir -p "$SIM_OUTPUT"

"$ROOT/scripts/prepare-rtl-image.py" \
    --image "$FIRMWARE" \
    --tb "$SMART/logical/tb/tb.v" \
    --output "$SIM_OUTPUT"

filelist=(
    '+libext+.v+.h+.V+.sv+'
    "+incdir+$SMART/logical/tb"
)
if [[ "${LINUXCPU_FAST_UART:-0}" == 1 ]]; then
    "$ROOT/scripts/prepare-sim-uart.py" \
        --input "$SMART/logical/uart/uart_apb_reg.v" \
        --output "$SIM_OUTPUT/uart_apb_reg-fast.v"
    filelist+=("$SIM_OUTPUT/uart_apb_reg-fast.v")
fi
filelist+=("$SIM_OUTPUT/tb-linux.v")
printf '%s\n' "${filelist[@]}" > "$SIM_OUTPUT/tb-linux.fl"
