#!/usr/bin/env bash
# Source this file for interactive development. Project scripts source it themselves.

LINUXCPU_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export LINUXCPU_ROOT
export CODE_BASE_PATH="$LINUXCPU_ROOT/openc906/C906_RTL_FACTORY"

if command -v riscv64-unknown-elf-gcc >/dev/null 2>&1; then
    TOOL_EXTENSION="$(dirname "$(command -v riscv64-unknown-elf-gcc)")"
    export TOOL_EXTENSION
fi

export CROSS_COMPILE="${CROSS_COMPILE:-riscv64-linux-gnu-}"
export ARCH="${ARCH:-riscv}"
export PATH="$LINUXCPU_ROOT/scripts/toolchain-bin:$PATH"
