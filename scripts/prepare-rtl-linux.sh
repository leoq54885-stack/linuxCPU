#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SMART="$ROOT/openc906/smart_run"
SIM_OUTPUT="$ROOT/output/sim"
OPENSBI_OUTPUT="${LINUXCPU_OPENSBI_OUTPUT:-$ROOT/output/opensbi-c906}"
CACHE_MODE="${LINUXCPU_CACHE_MODE:-off}"
if [[ "$CACHE_MODE" != off && -z "${LINUXCPU_OPENSBI_OUTPUT:-}" ]]; then
    OPENSBI_OUTPUT="$ROOT/output/opensbi-cache-$CACHE_MODE"
fi
DIAG_TEST="${LINUXCPU_DIAG_TEST:-none}"
if [[ "$DIAG_TEST" != none && -z "${LINUXCPU_OPENSBI_OUTPUT:-}" ]]; then
    OPENSBI_OUTPUT="$ROOT/output/opensbi-diag-test-$CACHE_MODE-$DIAG_TEST"
fi
FIRMWARE="$OPENSBI_OUTPUT/platform/generic/firmware/fw_payload.bin"
LINUX_IMAGE="$ROOT/output/linux/arch/riscv/boot/Image"
DT_SOURCE="$ROOT/platform/dts/open-c906-smart-run.dts"
DTB="$ROOT/output/dts/open-c906-smart-run.dtb"

firmware_stale=0
if [[ ! -f "$FIRMWARE" || ! -f "$OPENSBI_OUTPUT/cache-mode" || ! -f "$OPENSBI_OUTPUT/diag-test" ]]; then
    firmware_stale=1
elif [[ "$(<"$OPENSBI_OUTPUT/cache-mode")" != "$CACHE_MODE" ]]; then
    firmware_stale=1
elif [[ "$(<"$OPENSBI_OUTPUT/diag-test")" != "$DIAG_TEST" ]]; then
    firmware_stale=1
else
    for input in "$LINUX_IMAGE" "$DT_SOURCE" "$DTB" \
        "$ROOT/scripts/build-dtb.sh" "$ROOT/scripts/build-opensbi.sh" \
        "$ROOT/patches/opensbi/0001-add-rtl-fatal-diagnostics.patch" \
        "$ROOT/patches/opensbi/0002-smart-run-cache-experiment.patch" \
        "$ROOT/patches/opensbi/0003-fatal-diagnostic-test-hooks.patch" \
        "$ROOT/platform/diagnostics/linuxcpu_diag.h" \
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
    "$OPENSBI_OUTPUT/platform/generic/firmware/fw_payload.elf" "$DTB"
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
