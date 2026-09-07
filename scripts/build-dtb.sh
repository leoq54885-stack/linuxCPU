#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT/platform/dts/open-c906-smart-run.dts"
OUTPUT_DIR="${LINUXCPU_DTS_OUTPUT:-$ROOT/output/dts}"
OUTPUT="$OUTPUT_DIR/open-c906-smart-run.dtb"
ROUNDTRIP="$OUTPUT_DIR/open-c906-smart-run.roundtrip.dts"

mkdir -p "$OUTPUT_DIR"
dtc -Wno-interrupt_provider -I dts -O dtb -o "$OUTPUT" "$SOURCE"
dtc -I dtb -O dts -o "$ROUNDTRIP" "$OUTPUT"

if ! grep -Fq 'compatible = "thead,c900-plic";' "$ROUNDTRIP"; then
    echo "DTB does not identify the integrated PLIC as thead,c900-plic" >&2
    exit 1
fi
if ! grep -Fq 'compatible = "thead,c900-clint";' "$ROUNDTRIP"; then
    echo "DTB does not identify the 32-bit C906 CLINT as thead,c900-clint" >&2
    exit 1
fi
printf '[dtb] %s\n' "$OUTPUT"
