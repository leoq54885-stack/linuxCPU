#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/env.sh"
MODEL="${LINUXCPU_DIAG_MODEL:-$ROOT/output/verilator/diag-mailbox/c906-linux}"
[[ -x "$MODEL" ]] || { echo "Build the model first: LINUXCPU_VERILATOR_VARIANT=diag-mailbox scripts/build-verilator-linux.sh (or set LINUXCPU_DIAG_MODEL)" >&2; exit 1; }
mkdir -p "$ROOT/output/tests"
WORK="$(mktemp -d "$ROOT/output/tests/fatal-diag.XXXXXX")"
for case_name in committed partial; do
    mkdir -p "$WORK/$case_name"
    flags=()
    [[ "$case_name" != partial ]] || flags+=(-DDIAG_PARTIAL)
    riscv64-linux-gnu-gcc -march=rv64imac_zicsr_zifencei -mabi=lp64 \
        -static -no-pie -nostdlib -nostartfiles -I"$ROOT/platform/diagnostics" "${flags[@]}" \
        -Wl,-Ttext=0 -Wl,--build-id=none -o "$WORK/$case_name/test.elf" \
        "$ROOT/platform/tests/fatal-mailbox-smoke.S"
    riscv64-linux-gnu-objcopy -O binary "$WORK/$case_name/test.elf" "$WORK/$case_name/test.bin"
    "$ROOT/scripts/prepare-rtl-image.py" --image "$WORK/$case_name/test.bin" \
        --tb "$ROOT/openc906/smart_run/logical/tb/tb.v" --output "$WORK/$case_name"
    rc=0
    "$ROOT/scripts/run-verilator-linux.py" --model "$MODEL" --cwd "$WORK/$case_name" \
        --log "$WORK/$case_name/run.log" --timeout 2 > "$WORK/$case_name/runner.log" 2>&1 || rc=$?
    if [[ "$case_name" == committed ]]; then
        [[ "$rc" == 1 ]]
        rg -q 'complete kind=trap' "$WORK/$case_name/run.log"
        rg -q 'trap rc=0xfffffffffffffff9' "$WORK/$case_name/run.log"
        rg -q 'trap cause=0x0000000000000002' "$WORK/$case_name/run.log"
        rg -q 'trap tval=0x00000000deadbeef' "$WORK/$case_name/run.log"
        rg -q 'trap mepc=0x0000000011223344' "$WORK/$case_name/run.log"
    else
        [[ "$rc" == 124 ]]
        ! rg -q 'complete kind=' "$WORK/$case_name/run.log"
        ! rg -q '%Fatal|%Error|\* Error:' "$WORK/$case_name/run.log"
    fi
    rg -q 'mhcr=0x000000000000017f' "$WORK/$case_name/run.log"
    printf '[fatal-diag-smoke] %s PASS: %s\n' "$case_name" "$WORK/$case_name/run.log"
done
