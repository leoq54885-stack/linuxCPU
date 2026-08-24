#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "${1:-}" in
    smoke)
        shift
        exec "$ROOT/scripts/smoke-c906.sh" "$@"
        ;;
    linux)
        shift
        exec "$ROOT/scripts/run-verilator-linux.sh" "$@"
        ;;
    linux-iverilog)
        shift
        exec "$ROOT/scripts/run-rtl-linux.sh" "$@"
        ;;
    *)
        echo "Usage: $0 {smoke|linux|linux-iverilog}" >&2
        exit 2
        ;;
esac
