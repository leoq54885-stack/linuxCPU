#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
action="${1:-}"
shift || true

case "$action" in
    package|build)
        source "$ROOT/env.sh"
        if [[ "${LINUXCPU_FAST_UART:-0}" != 0 ]]; then
            echo 'Cadence delivery uses the real UART; set LINUXCPU_FAST_UART=0' >&2
            exit 2
        fi
        if [[ -n "${LINUXCPU_CADENCE_OUTPUT:-}" && -e "$LINUXCPU_CADENCE_OUTPUT" ]]; then
            echo 'LINUXCPU_CADENCE_OUTPUT already exists; choose a new directory' >&2
            exit 2
        fi
        # Rebuild incrementally so profile/configuration changes reach the payload.
        "$ROOT/scripts/build-linux.sh"
        "$ROOT/scripts/build-opensbi.sh"
        cache="${LINUXCPU_CACHE_MODE:-off}"
        diag="${LINUXCPU_DIAG_TEST:-none}"
        firmware="$ROOT/output/opensbi-c906"
        [[ "$cache" == off ]] || firmware="$ROOT/output/opensbi-cache-$cache"
        [[ "$diag" == none ]] || firmware="$ROOT/output/opensbi-diag-test-$cache-$diag"
        firmware="${LINUXCPU_OPENSBI_OUTPUT:-$firmware}"
        linux="${LINUXCPU_LINUX_OUTPUT:-$ROOT/output/linux}"
        dtb="${LINUXCPU_DTS_OUTPUT:-$ROOT/output/dts}/open-c906-smart-run.dtb"
        "$ROOT/scripts/verify-firmware-dtb.sh" "$firmware/platform/generic/firmware/fw_payload.bin" \
            "$firmware/platform/generic/firmware/fw_payload.elf" "$dtb"
        options=()
        [[ -z "${LINUXCPU_CADENCE_OUTPUT:-}" ]] || options+=(--output "$LINUXCPU_CADENCE_OUTPUT")
        python3 "$ROOT/scripts/cadence/package.py" --firmware-dir "$firmware" --linux-dir "$linux" \
            --dtb "$dtb" --cache "$cache" --profile "${LINUXCPU_LINUX_PROFILE:-trim}" --diag "$diag" "${options[@]}"
        [[ "$action" != package ]] || exit 0
        ;;
    run|probe|check) ;;
    *) echo "Usage: $0 {package|build|run|probe|check} [runner options]" >&2; exit 2 ;;
esac

bundle="${LINUXCPU_CADENCE_OUTPUT:-$ROOT/output/cadence/latest}"
if [[ ! -f "$bundle/cadence.py" ]]; then
    echo 'Cadence bundle missing; run make cadence-package or set LINUXCPU_CADENCE_OUTPUT' >&2
    exit 2
fi
options=(--irun "${LINUXCPU_IRUN_BIN:-irun}")
case "$action" in
    build) options+=(--timeout "${LINUXCPU_CADENCE_BUILD_TIMEOUT:-600}") ;;
    run) options+=(--timeout "${LINUXCPU_LINUX_SIM_TIMEOUT:-0}") ;;
    probe) options+=(--timeout "${LINUXCPU_CADENCE_PROBE_TIMEOUT:-120}") ;;
esac
exec python3 "$bundle/cadence.py" "$action" "${options[@]}" "$@"
