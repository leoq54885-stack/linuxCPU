#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODEL="$ROOT/output/verilator/c906-linux"
BUILD_INFO="$ROOT/output/verilator/c906-linux.build-info"
SIM_OUTPUT="$ROOT/output/sim"
LOG="$ROOT/output/logs/c906-linux-verilator.log"
TIMEOUT_SECONDS="${LINUXCPU_LINUX_SIM_TIMEOUT:-0}"
OPENC906_PATCH="$ROOT/patches/openc906/0001-mark-smart-run-uart-device.patch"
FAST_UART="${LINUXCPU_FAST_UART:-0}"

if [[ -n "$(git -C "$ROOT/openc906" status --porcelain --untracked-files=no)" ]]; then
    echo "OpenC906 tracked worktree has local changes; rebuild inputs are not reproducible" >&2
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
EXPECTED_BUILD_INFO="$(printf 'LINUXCPU_FAST_UART=%s\nPROJECT_INPUT_SHA256=%s' \
    "$FAST_UART" "$PROJECT_INPUT_SHA256")"

if [[ ! -x "$MODEL" || ! -f "$BUILD_INFO" ]] || \
   [[ "$(cat "$BUILD_INFO" 2>/dev/null)" != "$EXPECTED_BUILD_INFO" ]]; then
    printf '[rtl-linux] model is missing or stale; rebuilding it first\n'
    "$ROOT/scripts/build-verilator-linux.sh"
fi
"$ROOT/scripts/prepare-rtl-linux.sh"

if [[ "$TIMEOUT_SECONDS" == 0 ]]; then
    printf '[rtl-linux] running Verilator/OpenC906; host timeout=disabled\n'
else
    printf '[rtl-linux] running Verilator/OpenC906; host timeout=%ss\n' \
        "$TIMEOUT_SECONDS"
fi
exec "$ROOT/scripts/run-verilator-linux.py" \
    --model "$MODEL" --cwd "$SIM_OUTPUT" --log "$LOG" \
    --timeout "$TIMEOUT_SECONDS"
