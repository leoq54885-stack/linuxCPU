#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIRMWARE="${1:-$ROOT/output/opensbi-c906/platform/generic/firmware/fw_payload.bin}"
FIRMWARE_ELF="${2:-$ROOT/output/opensbi-c906/platform/generic/firmware/fw_payload.elf}"
DTB="${3:-$ROOT/output/dts/open-c906-smart-run.dtb}"

for input in "$FIRMWARE" "$FIRMWARE_ELF" "$DTB"; do
    [[ -f "$input" ]] || {
        printf '[firmware-dtb] missing input: %s\n' "$input" >&2
        exit 1
    }
done

symbol_address() {
    local symbol="$1"
    riscv64-linux-gnu-nm -n "$FIRMWARE_ELF" | \
        awk -v wanted="$symbol" '
            $3 == wanted {
                value = $1
                matches++
            }
            END {
                if (matches != 1)
                    exit 1
                print value
            }
        '
}

fw_start_hex="$(symbol_address _fw_start)"
fw_fdt_hex="$(symbol_address fw_fdt_bin)"
fw_start=$((16#$fw_start_hex))
fw_fdt=$((16#$fw_fdt_hex))
fdt_offset=$((fw_fdt - fw_start))
dtb_size="$(stat -c %s "$DTB")"

if ((fdt_offset < 0)); then
    echo "[firmware-dtb] invalid fw_fdt_bin offset" >&2
    exit 1
fi

if ! cmp --silent --bytes="$dtb_size" --ignore-initial="$fdt_offset:0" \
    "$FIRMWARE" "$DTB"; then
    echo "[firmware-dtb] embedded DTB does not match the generated DTB" >&2
    exit 1
fi

if ! grep -aFq 'thead,c900-plic' "$DTB"; then
    echo "[firmware-dtb] embedded DTB lacks the C906 PLIC compatible" >&2
    exit 1
fi
if ! grep -aFq 'thead,c900-clint' "$DTB"; then
    echo "[firmware-dtb] embedded DTB lacks the 32-bit C906 CLINT compatible" >&2
    exit 1
fi

diag_node=/reserved-memory/fatal-diagnostics@fff000
if [[ "$(fdtget -tx "$DTB" "$diag_node" reg)" != '0 fff000 0 1000' ]] || \
   ! fdtget "$DTB" "$diag_node" no-map >/dev/null; then
    echo '[firmware-dtb] reserved no-map diagnostic page at 0x00fff000 is missing' >&2
    exit 1
fi

printf '[firmware-dtb] exact match: offset=0x%x size=%d compatible=thead,c900-plic,thead,c900-clint\n' \
    "$fdt_offset" "$dtb_size"
