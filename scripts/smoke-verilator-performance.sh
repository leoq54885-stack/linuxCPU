#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
THREADS="${LINUXCPU_VERILATOR_THREADS:-1}"
VARIANT="${LINUXCPU_VERILATOR_VARIANT:-default}"
DURATION="${LINUXCPU_PERF_SMOKE_SECONDS:-120}"
CPUS="${LINUXCPU_PERF_CPUS:-}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RESULT_DIR="${LINUXCPU_PERF_OUTPUT:-$ROOT/output/benchmarks/$STAMP}"

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
"$ROOT/scripts/build-verilator-linux.sh" --if-needed

"$ROOT/scripts/prepare-rtl-linux.sh"
args=(
    --model "$MODEL"
    --cwd "$ROOT/output/sim"
    --output-dir "$RESULT_DIR"
    --label "t${THREADS}"
    --duration "$DURATION"
)
if [[ -n "$CPUS" ]]; then
    args+=(--cpus "$CPUS")
fi
if [[ -n "${LINUXCPU_PROF_EXEC_FILE:-}" ]]; then
    args+=(--model-arg "+verilator+prof+exec+file+${LINUXCPU_PROF_EXEC_FILE}")
fi
if [[ -n "${LINUXCPU_PROF_EXEC_START:-}" ]]; then
    args+=(--model-arg "+verilator+prof+exec+start+${LINUXCPU_PROF_EXEC_START}")
fi
if [[ -n "${LINUXCPU_PROF_EXEC_WINDOW:-}" ]]; then
    args+=(--model-arg "+verilator+prof+exec+window+${LINUXCPU_PROF_EXEC_WINDOW}")
fi
if [[ -n "${LINUXCPU_PROF_VLT_FILE:-}" ]]; then
    args+=(--model-arg "+verilator+prof+vlt+file+${LINUXCPU_PROF_VLT_FILE}")
fi
exec "$ROOT/scripts/benchmark-verilator.py" "${args[@]}"
