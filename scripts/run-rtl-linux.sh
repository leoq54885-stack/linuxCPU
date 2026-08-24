#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/env.sh"

SIM_OUTPUT="$ROOT/output/sim"
VVP="$SIM_OUTPUT/c906-linux.vvp"
LOG="$ROOT/output/logs/c906-linux-iverilog.log"

[[ -f "$VVP" ]] || "$ROOT/scripts/build-rtl-linux.sh"
mkdir -p "$ROOT/output/logs"

printf '[rtl-linux-iverilog] running Icarus/VVP; timeout=%ss\n' \
    "${LINUXCPU_LINUX_SIM_TIMEOUT:-1800}"
(
    cd "$SIM_OUTPUT"
    timeout "${LINUXCPU_LINUX_SIM_TIMEOUT:-1800}" vvp -l "$LOG" "$VVP"
)
