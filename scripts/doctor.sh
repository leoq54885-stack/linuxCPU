#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/versions.lock"
source "$ROOT/env.sh"

passed=0
failed=0

ok() { printf '  [OK]   %s\n' "$1"; passed=$((passed + 1)); }
bad() { printf '  [FAIL] %s\n' "$1"; failed=$((failed + 1)); }

check_command() {
    local name="$1"
    if command -v "$name" >/dev/null 2>&1; then
        ok "$name: $(command -v "$name")"
    else
        bad "$name is missing"
    fi
}

check_repo() {
    local name="$1" expected="$2"
    if [[ ! -d "$ROOT/$name/.git" ]]; then
        bad "$name checkout is missing"
        return
    fi
    local actual
    actual="$(git -C "$ROOT/$name" rev-parse HEAD 2>/dev/null || true)"
    if [[ "$actual" == "$expected" ]]; then
        ok "$name: $actual"
    else
        bad "$name is at $actual, expected $expected"
    fi
    if [[ -z "$(git -C "$ROOT/$name" status --porcelain --untracked-files=no)" ]]; then
        ok "$name tracked worktree is clean"
    else
        bad "$name tracked worktree has local changes"
    fi
}

printf 'linuxCPU environment check\n'
if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    ok "project Git repository"
else
    bad "linuxCPU is not a Git repository"
fi

check_repo openc906 "$OPENC906_COMMIT"
check_repo opensbi "$OPENSBI_COMMIT"
check_repo linux "$LINUX_COMMIT"
check_repo buildroot "$BUILDROOT_COMMIT"

for command_name in make python3 timeout dtc riscv64-linux-gnu-gcc \
    riscv64-linux-gnu-objcopy riscv64-linux-gnu-nm \
    riscv64-unknown-elf-gcc iverilog vvp verilator; do
    check_command "$command_name"
done

iverilog_ver="$(iverilog -V 2>&1 || true)"
if printf '%s' "$iverilog_ver" | grep -q 'version 12\.0'; then
    ok "Icarus Verilog version 12.0"
else
    bad "Icarus Verilog is not the pinned 12.0 release"
fi

verilator_ver="$(verilator --version 2>&1 || true)"
if printf '%s' "$verilator_ver" | grep -q 'Verilator 5\.020'; then
    ok "Verilator version 5.020"
else
    bad "Verilator is not the pinned 5.020 release"
fi

if grep -q 'clint_top  x_clint_top' \
    "$ROOT/openc906/C906_RTL_FACTORY/gen_rtl/cpu/rtl/openC906.v" 2>/dev/null; then
    ok "OpenC906 integrated CLINT present"
else
    bad "OpenC906 integrated CLINT not found"
fi
if grep -q 'plic_top #' \
    "$ROOT/openc906/C906_RTL_FACTORY/gen_rtl/cpu/rtl/openC906.v" 2>/dev/null; then
    ok "OpenC906 integrated PLIC present"
else
    bad "OpenC906 integrated PLIC not found"
fi

if grep -Fq 'compatible = "thead,c900-plic";' \
    "$ROOT/platform/dts/open-c906-smart-run.dts" 2>/dev/null; then
    ok "DTS enables the T-Head PLIC integration path"
else
    bad "DTS does not identify the PLIC as thead,c900-plic"
fi
if grep -Fq 'compatible = "thead,c900-clint";' \
    "$ROOT/platform/dts/open-c906-smart-run.dts" 2>/dev/null; then
    ok "DTS selects the 32-bit T-Head CLINT integration path"
else
    bad "DTS does not identify the CLINT as thead,c900-clint"
fi
if grep -Fq '#define THEAD_PLIC_CTRL_REG 0x1ffffc' \
    "$ROOT/opensbi/lib/utils/irqchip/plic.c" 2>/dev/null && \
   grep -Fq 'PLIC_FLAG_THEAD_DELEGATION' \
    "$ROOT/opensbi/lib/utils/irqchip/fdt_irqchip_plic.c" 2>/dev/null; then
    ok "OpenSBI has T-Head PLIC S-mode delegation support"
else
    bad "OpenSBI T-Head PLIC delegation support not found"
fi
if grep -Fq 'static const struct timer_mtimer_quirks thead_clint_quirks' \
    "$ROOT/opensbi/lib/utils/timer/fdt_timer_mtimer.c" 2>/dev/null && \
   grep -Fq '.clint_without_mtime' \
    "$ROOT/opensbi/lib/utils/timer/fdt_timer_mtimer.c" 2>/dev/null && \
   grep -Fq '{ .compatible = "thead,c900-clint"' \
    "$ROOT/opensbi/lib/utils/timer/fdt_timer_mtimer.c" 2>/dev/null; then
    ok "OpenSBI has the T-Head CLINT 32-bit/no-MTIME quirk"
else
    bad "OpenSBI T-Head CLINT quirk not found"
fi

printf '\nResult: %d passed, %d failed\n' "$passed" "$failed"
((failed == 0))
