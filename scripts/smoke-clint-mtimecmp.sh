#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/env.sh"

MODEL="$ROOT/output/verilator/c906-linux"
SOURCE="$ROOT/platform/tests/clint-mtimecmp-smoke.S"
TB_SOURCE="$ROOT/openc906/smart_run/logical/tb/tb.v"
TEST_ROOT="$ROOT/output/tests"

[[ -x "$MODEL" ]] || {
    echo "CLINT smoke requires an existing Verilator model; run make rtl-linux" >&2
    exit 1
}

mkdir -p "$TEST_ROOT" "$ROOT/output/logs"
WORK="$(mktemp -d "$TEST_ROOT/clint-mtimecmp.XXXXXX")"

run_case() {
    local name="$1"
    local define="$2"
    local expected_report="$3"
    local expected_compare="$4"
    local case_dir="$WORK/$name"
    local elf="$case_dir/test.elf"
    local image="$case_dir/test.bin"
    local log="$ROOT/output/logs/clint-mtimecmp-$name.log"
    local runner_rc
    local -a cpp_flags=()

    mkdir -p "$case_dir"
    if [[ -n "$define" ]]; then
        cpp_flags+=("-D$define")
    fi
    riscv64-unknown-elf-gcc "${cpp_flags[@]}" \
        -march=rv64imac -mabi=lp64 -nostdlib -nostartfiles \
        -Wl,-Ttext=0 -Wl,--build-id=none -o "$elf" "$SOURCE"
    riscv64-unknown-elf-objcopy -O binary "$elf" "$image"
    "$ROOT/scripts/prepare-rtl-image.py" \
        --image "$image" --tb "$TB_SOURCE" --output "$case_dir"

    set +e
    "$ROOT/scripts/run-verilator-linux.py" \
        --model "$MODEL" --cwd "$case_dir" --log "$log" --timeout 60
    runner_rc=$?
    set -e
    # The generic runner returns 1 because this bare-metal case has no PID 1
    # marker.  The smart_run report and exact CLINT value decide this smoke.
    if ((runner_rc != 1)); then
        printf '[clint-smoke] %s: unexpected runner status %d\n' \
            "$name" "$runner_rc" >&2
        exit 1
    fi
    if ! grep -Fq "$expected_report" "$case_dir/run_case.report"; then
        printf '[clint-smoke] %s: expected %s; see %s\n' \
            "$name" "$expected_report" "$log" >&2
        exit 1
    fi
    if ! grep -Fq "$expected_compare" "$log"; then
        printf '[clint-smoke] %s: missing %s; see %s\n' \
            "$name" "$expected_compare" "$log" >&2
        exit 1
    fi
    printf '[clint-smoke] %s: %s, %s\n' \
        "$name" "$expected_report" "$expected_compare"
}

# A 64-bit store only reaches the low word of C906's 32-bit APB CLINT.
run_case single64 CLINT_SINGLE_64BIT_STORE \
    'TEST FAIL' 'cmp=0xffffffff12345678'

# The sequence selected by OpenSBI's thead,c900-clint quirk is correct.
run_case rv32 '' 'TEST PASS' 'cmp=0x0000000012345678'

printf '[clint-smoke] PASS: C906 requires the T-Head 32-bit CLINT path (%s)\n' \
    "$WORK"
