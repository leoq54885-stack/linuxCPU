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
THREADS="${LINUXCPU_VERILATOR_THREADS:-1}"
VERILATOR_BIN="${LINUXCPU_VERILATOR_BIN:-verilator}"
VARIANT="${LINUXCPU_VERILATOR_VARIANT:-default}"
PROFILE="${LINUXCPU_VERILATOR_PROFILE:-none}"
PGO_INPUT="${LINUXCPU_VERILATOR_PGO_INPUT:-}"
MAX_MTASKS="${LINUXCPU_VERILATOR_MAX_MTASKS:-}"
EXTRA_CFLAGS="${LINUXCPU_VERILATOR_CFLAGS:-}"
EXTRA_LDFLAGS="${LINUXCPU_VERILATOR_LDFLAGS:-}"
OPENC906_PATCH="$ROOT/patches/openc906/0001-mark-smart-run-uart-device.patch"
FAST_UART="${LINUXCPU_FAST_UART:-0}"
PATCH_APPLIED=0
BUILD_ONLY_IF_NEEDED=0

if [[ "${1:-}" == "--if-needed" ]]; then
    BUILD_ONLY_IF_NEEDED=1
    shift
fi
if (($#)); then
    echo "Usage: $0 [--if-needed]" >&2
    exit 2
fi

if [[ ! "$THREADS" =~ ^[1-9][0-9]*$ ]]; then
    echo "LINUXCPU_VERILATOR_THREADS must be a positive integer" >&2
    exit 2
fi
if [[ ! "$VARIANT" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "LINUXCPU_VERILATOR_VARIANT must contain only letters, digits, '.', '_' or '-'" >&2
    exit 2
fi
if [[ "$PROFILE" != none && "$PROFILE" != exec && "$PROFILE" != pgo ]]; then
    echo "LINUXCPU_VERILATOR_PROFILE must be one of: none, exec, pgo" >&2
    exit 2
fi
if [[ -n "$MAX_MTASKS" && ! "$MAX_MTASKS" =~ ^[1-9][0-9]*$ ]]; then
    echo "LINUXCPU_VERILATOR_MAX_MTASKS must be a positive integer" >&2
    exit 2
fi
if [[ ! -x "$VERILATOR_BIN" ]] && ! command -v "$VERILATOR_BIN" >/dev/null 2>&1; then
    echo "Verilator executable not found: $VERILATOR_BIN" >&2
    exit 2
fi

if [[ "$VARIANT" != default ]]; then
    VERILATOR_OUTPUT="$VERILATOR_OUTPUT/$VARIANT"
fi

if [[ "$THREADS" == 1 ]]; then
    # Use an explicit t1 directory.  Older copied artifacts may contain
    # absolute VERILATOR_ROOT dependencies that cannot be rebuilt in place.
    MODEL_DIR="$VERILATOR_OUTPUT/obj-t1"
    MODEL="$VERILATOR_OUTPUT/c906-linux"
    BUILD_INFO="$VERILATOR_OUTPUT/c906-linux.build-info"
else
    MODEL_DIR="$VERILATOR_OUTPUT/obj-t$THREADS"
    MODEL="$VERILATOR_OUTPUT/c906-linux-t$THREADS"
    BUILD_INFO="$VERILATOR_OUTPUT/c906-linux-t$THREADS.build-info"
fi

VERILATOR_VERSION="$($VERILATOR_BIN --version)"
PROFILE_FLAGS=()
if [[ "$PROFILE" == exec ]]; then
    PROFILE_FLAGS+=(--prof-exec)
elif [[ "$PROFILE" == pgo ]]; then
    PROFILE_FLAGS+=(--prof-pgo)
fi
if [[ -n "$PGO_INPUT" ]]; then
    PGO_INPUT="$(realpath "$PGO_INPUT")"
    if [[ ! -f "$PGO_INPUT" ]]; then
        echo "Thread PGO input not found: $PGO_INPUT" >&2
        exit 2
    fi
    PROFILE_FLAGS+=("$PGO_INPUT")
fi
if [[ -n "$MAX_MTASKS" ]]; then
    PROFILE_FLAGS+=(--threads-max-mtasks "$MAX_MTASKS")
fi
if [[ -n "$EXTRA_CFLAGS" ]]; then
    PROFILE_FLAGS+=(-CFLAGS "$EXTRA_CFLAGS")
fi
if [[ -n "$EXTRA_LDFLAGS" ]]; then
    PROFILE_FLAGS+=(-LDFLAGS "$EXTRA_LDFLAGS")
fi

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
        "$ROOT/scripts/verilator-main.cpp" \
        "$ROOT/scripts/build-verilator-linux.sh" \
        "$ROOT/versions.lock" | sha256sum | cut -d' ' -f1
)"
EXPECTED_BUILD_INFO="$(printf 'LINUXCPU_FAST_UART=%s\nPROJECT_INPUT_SHA256=%s\nLINUXCPU_VERILATOR_THREADS=%s\nLINUXCPU_VERILATOR_VARIANT=%s\nLINUXCPU_VERILATOR_PROFILE=%s\nLINUXCPU_VERILATOR_PGO_INPUT=%s\nLINUXCPU_VERILATOR_MAX_MTASKS=%s\nLINUXCPU_VERILATOR_CFLAGS=%s\nLINUXCPU_VERILATOR_LDFLAGS=%s\nVERILATOR_VERSION=%s' \
    "$FAST_UART" "$PROJECT_INPUT_SHA256" "$THREADS" "$VARIANT" "$PROFILE" \
    "$PGO_INPUT" "$MAX_MTASKS" "$EXTRA_CFLAGS" "$EXTRA_LDFLAGS" "$VERILATOR_VERSION")"

if ((BUILD_ONLY_IF_NEEDED == 1)) && [[ -x "$MODEL" && -f "$BUILD_INFO" ]] && \
   [[ "$(cat "$BUILD_INFO")" == "$EXPECTED_BUILD_INFO" ]]; then
    printf '[rtl-linux] reusing current t%s model: %s\n' "$THREADS" "$MODEL"
    exit 0
fi

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
printf '[rtl-linux] Verilator: %s\n' "$VERILATOR_VERSION"
printf '[rtl-linux] experiment variant: %s, profile: %s\n' "$VARIANT" "$PROFILE"
printf '[rtl-linux] maximum mtasks: %s\n' "${MAX_MTASKS:-automatic}"
printf '[rtl-linux] extra CFLAGS/LDFLAGS: %s / %s\n' \
    "${EXTRA_CFLAGS:-none}" "${EXTRA_LDFLAGS:-none}"
printf '[rtl-linux] runtime simulation threads: %s\n' "$THREADS"
(
    cd "$SMART/work"
    "$VERILATOR_BIN" \
        --cc --exe --build --timing --top-module tb \
        "$ROOT/scripts/verilator-main.cpp" \
        --Mdir "$MODEL_DIR" -o "$MODEL" --build-jobs "$JOBS" \
        --threads "$THREADS" --stats "${PROFILE_FLAGS[@]}" \
        -O3 -CFLAGS -O3 -CFLAGS "-DLINUXCPU_MODEL_THREADS=$THREADS" \
        --x-initial 0 --x-assign 0 \
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
printf '%s\n' "$EXPECTED_BUILD_INFO" > "$BUILD_INFO"
printf '[rtl-linux] build info: %s\n' "$BUILD_INFO"
