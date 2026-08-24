#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "${1:-rtl-smoke}" in
    rtl-smoke)
        shift || true
        exec "$ROOT/scripts/smoke-c906.sh" "$@"
        ;;
    linux)
        shift || true
        exec "$ROOT/scripts/build-linux.sh" "$@"
        ;;
    firmware)
        shift || true
        exec "$ROOT/scripts/build-opensbi.sh" "$@"
        ;;
    rtl-linux)
        shift || true
        exec "$ROOT/scripts/build-verilator-linux.sh" "$@"
        ;;
    rtl-linux-iverilog)
        shift || true
        exec "$ROOT/scripts/build-rtl-linux.sh" "$@"
        ;;
    *)
        printf 'Usage: %s {rtl-smoke|linux|firmware|rtl-linux|rtl-linux-iverilog}\n' "$0" >&2
        exit 2
        ;;
esac
