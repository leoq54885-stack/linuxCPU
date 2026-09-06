#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
THREADS="${LINUXCPU_VERILATOR_THREADS:-1}"
VARIANT="${LINUXCPU_VERILATOR_VARIANT:-default}"
if [[ ! "$THREADS" =~ ^[1-9][0-9]*$ ]]; then
    echo "LINUXCPU_VERILATOR_THREADS must be a positive integer" >&2
    exit 2
fi
MODEL_ROOT="$ROOT/output/verilator"
if [[ "$VARIANT" != default ]]; then
    MODEL_ROOT="$MODEL_ROOT/$VARIANT"
fi
if [[ "$THREADS" == 1 ]]; then
    MODEL="$MODEL_ROOT/c906-linux"
else
    MODEL="$MODEL_ROOT/c906-linux-t$THREADS"
fi
SIM_OUTPUT="$ROOT/output/sim"
LOG="$ROOT/output/logs/c906-linux-verilator.log"
TIMEOUT_SECONDS="${LINUXCPU_LINUX_SIM_TIMEOUT:-0}"
"$ROOT/scripts/build-verilator-linux.sh" --if-needed
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
