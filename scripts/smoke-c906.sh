#!/usr/bin/env bash
# Compile the RTL and run the upstream MMU smoke case without modifying openc906.

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/env.sh"

SMART="$ROOT/openc906/smart_run"
WORK="$SMART/work"
REBUILD=0

if [[ "${1:-}" == "--rebuild" ]]; then
    REBUILD=1
elif (($#)); then
    echo "Usage: $0 [--rebuild]" >&2
    exit 2
fi

"$ROOT/scripts/doctor.sh"
mkdir -p "$WORK" "$ROOT/output/logs"

if ((REBUILD == 1)) || [[ ! -f "$WORK/xuantie_core.vvp" ]]; then
    printf '[smoke] elaborating OpenC906 RTL with Icarus Verilog\n'
    make -C "$SMART" compile SIM=iverilog SHELL=/bin/bash
else
    printf '[smoke] reusing %s\n' "$WORK/xuantie_core.vvp"
fi

printf '[smoke] staging the MMU case\n'
find "$WORK" -maxdepth 1 -type f \
    ! -name 'xuantie_core.vvp' ! -name '*.vcd' -delete
cp "$SMART/tests/cases/MMU/"* "$WORK/"
find "$SMART/tests/lib" -maxdepth 1 -type f -exec cp -t "$WORK" {} +
cp "$SMART/tests/bin/Srec2vmem" "$WORK/Srec2vmem"
chmod +x "$WORK/Srec2vmem"

# The upstream test predates current GNU naming. CSR 0x7c0 is mxstatus.
# Only generated work files are adjusted; the pinned source checkout stays clean.
sed -i 's/\<mxstatus\>/0x7c0/g' "$WORK/crt0.s" "$WORK/C906_mmu_basic.s"
# The MMU case is assembly-only and does not use libc/libm. Ubuntu's bare-metal
# GCC intentionally ships without those libraries, so remove the legacy links.
sed -i 's/^LINKLIBS = -lc -lgcc/LINKLIBS = -lgcc/' "$WORK/Makefile"
sed -i 's/ -lm[[:space:]]*$/ /' "$WORK/Makefile"
sed -i 's/-nostartfiles/-nostdlib/' "$WORK/Makefile"
sed -i 's#CONVERT[[:space:]]*=../tests/bin/Srec2vmem#CONVERT = ./Srec2vmem#' "$WORK/Makefile"

make -C "$WORK" clean
make -C "$WORK" all \
    CPU_ARCH_FLAG_0=c906fd \
    ENDIAN_MODE=little-endian \
    CASENAME=MMU \
    FILE=C906_mmu_basic \
    FLAG_MARCH=-march=rv64imafdc \
    FLAG_ABI=-mabi=lp64d

printf '[smoke] running the MMU case\n'
(
    cd "$WORK"
    timeout "${LINUXCPU_SIM_TIMEOUT:-900}" \
        vvp -l "$ROOT/output/logs/c906-mmu-smoke.log" xuantie_core.vvp
)

cp "$WORK/run_case.report" "$ROOT/output/logs/c906-mmu-smoke.report"

if grep -q 'TEST PASS' "$WORK/run_case.report"; then
    printf '[smoke] PASS: OpenC906 MMU case\n'
else
    printf '[smoke] FAIL: see %s and %s\n' \
        "$WORK/run_case.report" "$ROOT/output/logs/c906-mmu-smoke.log" >&2
    exit 1
fi
