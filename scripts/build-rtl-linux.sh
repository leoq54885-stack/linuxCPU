#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/env.sh"

SIM_OUTPUT="$ROOT/output/sim"
SMART="$ROOT/openc906/smart_run"
FIRMWARE="$ROOT/output/opensbi-c906/platform/generic/firmware/fw_payload.bin"
OPENC906_PATCH="$ROOT/patches/openc906/0001-mark-smart-run-uart-device.patch"
PATCH_APPLIED=0

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

printf '[rtl-linux-iverilog] elaborating Linux-capable OpenC906 testbench\n'
(
    cd "$SMART/work"
    iverilog -o "$SIM_OUTPUT/c906-linux.vvp" -Diverilog=1 -g2012 \
        -DIVERILOG_SIM -DNO_DUMP \
        -f "$CODE_BASE_PATH/gen_rtl/filelists/C906_asic_rtl.fl" \
        -f "$CODE_BASE_PATH/gen_rtl/filelists/tdt_dmi_top_rtl.fl" \
        -c ../logical/filelists/smart.fl \
        -c "$SIM_OUTPUT/tb-linux.fl"
)

ls -lh "$SIM_OUTPUT/c906-linux.vvp" "$FIRMWARE"
