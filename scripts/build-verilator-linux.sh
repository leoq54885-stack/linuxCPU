#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/env.sh"

SMART="$ROOT/openc906/smart_run"
SIM_OUTPUT="$ROOT/output/sim"
VERILATOR_OUTPUT="$ROOT/output/verilator"
MODEL_DIR="$VERILATOR_OUTPUT/obj"
MODEL="$VERILATOR_OUTPUT/c906-linux"
BUILD_INFO="$VERILATOR_OUTPUT/c906-linux.build-info"
JOBS="${LINUXCPU_JOBS:-$(nproc)}"
OPENC906_PATCH="$ROOT/patches/openc906/0001-mark-smart-run-uart-device.patch"
FAST_UART="${LINUXCPU_FAST_UART:-0}"
PATCH_APPLIED=0

if [[ -n "$(git -C "$ROOT/openc906" status --porcelain --untracked-files=no)" ]]; then
    echo "OpenC906 tracked worktree must be clean before building" >&2
    exit 1
fi

PROJECT_INPUT_SHA256="$(
    sha256sum \
        "$OPENC906_PATCH" \
        "$ROOT/scripts/prepare-rtl-image.py" \
        "$ROOT/scripts/prepare-rtl-linux.sh" \
        "$ROOT/scripts/prepare-sim-uart.py" \
        "$ROOT/scripts/build-verilator-linux.sh" \
        "$ROOT/versions.lock" | sha256sum | cut -d' ' -f1
)"

cleanup() {
    if ((PATCH_APPLIED == 1)); then
        git -C "$ROOT/openc906" apply --reverse "$OPENC906_PATCH"
    fi
}
trap cleanup EXIT

if git -C "$ROOT/openc906" apply --check "$OPENC906_PATCH"; then
    git -C "$ROOT/openc906" apply "$OPENC906_PATCH"
    PATCH_APPLIED=1
elif ! git -C "$ROOT/openc906" apply --reverse --check "$OPENC906_PATCH"; then
    echo "OpenC906 source has changes that conflict with the project patch" >&2
    exit 1
fi

"$ROOT/scripts/prepare-rtl-linux.sh"
mkdir -p "$MODEL_DIR"

printf '[rtl-linux] compiling the real OpenC906 RTL with Verilator\n'
(
    cd "$SMART/work"
    verilator \
        --binary --top-module tb \
        --Mdir "$MODEL_DIR" -o "$MODEL" --build-jobs "$JOBS" \
        -O3 -CFLAGS -O3 --x-initial 0 --x-assign 0 \
        -Wno-fatal -Wno-BLKANDNBLK -Wno-TIMESCALEMOD -Wno-WIDTH \
        -Wno-MULTIDRIVEN -Wno-UNOPTFLAT -Wno-IMPLICIT -Wno-UNSIGNED \
        -Wno-CMPCONST -Wno-CASEINCOMPLETE \
        -Diverilog=1 -DIVERILOG_SIM -DNO_DUMP \
        -f "$CODE_BASE_PATH/gen_rtl/filelists/C906_asic_rtl.fl" \
        -f "$CODE_BASE_PATH/gen_rtl/filelists/tdt_dmi_top_rtl.fl" \
        -f "$SMART/logical/filelists/smart.fl" \
        -f "$SIM_OUTPUT/tb-linux.fl"
)

ls -lh "$MODEL" "$ROOT/output/opensbi-c906/platform/generic/firmware/fw_payload.bin"
printf 'LINUXCPU_FAST_UART=%s\nPROJECT_INPUT_SHA256=%s\n' \
    "$FAST_UART" "$PROJECT_INPUT_SHA256" > "$BUILD_INFO"
printf '[rtl-linux] build info: %s\n' "$BUILD_INFO"
