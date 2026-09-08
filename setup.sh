#!/usr/bin/env bash
# Bootstrap a reproducible OpenC906 Linux development tree.
# All downloaded sources, local tools, caches and build outputs stay below
# this directory. Only missing host packages may be installed system-wide.

set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$PROJECT_ROOT/versions.lock"

INSTALL_HOST_DEPS=1
SKIP_IVERILOG=0
SKIP_VERILATOR=0

usage() {
    cat <<'EOF'
Usage: ./setup.sh [options]

Options:
  --no-install-host-deps  Do not use apt/sudo; fail if a host tool is missing
  --skip-iverilog         Do not install the project-local Icarus Verilog
  --skip-verilator        Do not install the project-local Verilator
  -h, --help              Show this help
EOF
}

while (($#)); do
    case "$1" in
        --no-install-host-deps) INSTALL_HOST_DEPS=0 ;;
        --skip-iverilog) SKIP_IVERILOG=1 ;;
        --skip-verilator) SKIP_VERILATOR=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

log() { printf '[setup] %s\n' "$*"; }
die() { printf '[setup] ERROR: %s\n' "$*" >&2; exit 1; }

mkdir -p "$PROJECT_ROOT/.cache/downloads" "$PROJECT_ROOT/.toolchain" \
    "$PROJECT_ROOT/output"

host_commands=(
    git make gcc g++ python3 curl xz bc bison flex cpio rsync file dtc patch
    riscv64-linux-gnu-gcc riscv64-linux-gnu-objcopy
    riscv64-unknown-elf-gcc riscv64-unknown-elf-objcopy
)

missing=()
for command_name in "${host_commands[@]}"; do
    command -v "$command_name" >/dev/null 2>&1 || missing+=("$command_name")
done

if ((${#missing[@]})); then
    if ((INSTALL_HOST_DEPS == 0)); then
        die "missing host commands: ${missing[*]}"
    fi
    command -v apt-get >/dev/null 2>&1 || \
        die "missing host commands (${missing[*]}) and apt-get is unavailable"
    packages=(
        git make gcc g++ python3 curl xz-utils bc bison flex cpio rsync file patch
        device-tree-compiler libncurses-dev
        gcc-riscv64-linux-gnu g++-riscv64-linux-gnu
        binutils-riscv64-linux-gnu gcc-riscv64-unknown-elf
        binutils-riscv64-unknown-elf
    )
    if ((EUID == 0)); then
        apt-get update
        apt-get install -y "${packages[@]}"
    else
        command -v sudo >/dev/null 2>&1 || \
            die "sudo is required to install missing host packages: ${missing[*]}"
        sudo apt-get update
        sudo apt-get install -y "${packages[@]}"
    fi
fi

ensure_repo() {
    local name="$1" url="$2" commit="$3"
    local destination="$PROJECT_ROOT/$name"

    if [[ -e "$destination" && ! -d "$destination/.git" ]]; then
        die "$destination exists but is not a Git checkout"
    fi

    if [[ ! -d "$destination/.git" ]]; then
        log "fetching $name at $commit"
        git init -q "$destination"
        git -C "$destination" remote add origin "$url"
        git -C "$destination" fetch --depth 1 origin "$commit"
        git -C "$destination" checkout -q --detach FETCH_HEAD
    fi

    local actual origin
    actual="$(git -C "$destination" rev-parse HEAD)"
    origin="$(git -C "$destination" remote get-url origin)"
    [[ "$actual" == "$commit" ]] || \
        die "$name is at $actual; expected $commit. Move it aside and rerun setup."
    [[ "$origin" == "$url" ]] || \
        die "$name origin is $origin; expected $url"
    log "$name: $actual"
}

ensure_local_exclude() {
    local repository="$1" pattern="$2"
    local exclude_file="$PROJECT_ROOT/$repository/.git/info/exclude"
    grep -Fxq "$pattern" "$exclude_file" 2>/dev/null || \
        printf '%s\n' "$pattern" >> "$exclude_file"
}

ensure_repo openc906 "$OPENC906_URL" "$OPENC906_COMMIT"
ensure_repo opensbi "$OPENSBI_URL" "$OPENSBI_COMMIT"
ensure_repo linux "$LINUX_URL" "$LINUX_COMMIT"
ensure_repo buildroot "$BUILDROOT_URL" "$BUILDROOT_COMMIT"
ensure_local_exclude openc906 /smart_run/work/
mkdir -p "$PROJECT_ROOT/openc906/smart_run/work"

install_local_iverilog() {
    local install_root="$PROJECT_ROOT/.toolchain/iverilog"
    local cache_file="$PROJECT_ROOT/.cache/downloads/$IVERILOG_DEB_FILE"

    if [[ -x "$install_root/usr/bin/iverilog" ]]; then
        if "$install_root/usr/bin/iverilog" \
            -B "$install_root/usr/lib/x86_64-linux-gnu/ivl" -V 2>&1 | \
            grep -q 'version 12\.0'; then
            log "Icarus Verilog 12.0 already installed locally"
            return
        fi
        die "$install_root contains an unexpected Icarus version"
    fi

    command -v apt-get >/dev/null 2>&1 || \
        die "apt-get is needed for the pinned local Icarus package on the supported Ubuntu host"
    command -v dpkg-deb >/dev/null 2>&1 || die "dpkg-deb is required"

    if [[ ! -f "$cache_file" ]]; then
        log "downloading Icarus Verilog $IVERILOG_DEB_VERSION into .cache"
        (
            cd "$PROJECT_ROOT/.cache/downloads"
            apt-get download "iverilog=$IVERILOG_DEB_VERSION"
        )
        local downloaded
        downloaded="$(find "$PROJECT_ROOT/.cache/downloads" -maxdepth 1 -type f \
            -name 'iverilog_*_amd64.deb' -print -quit)"
        [[ -n "$downloaded" ]] || die "Icarus package download did not produce a .deb"
        [[ "$downloaded" == "$cache_file" ]] || mv "$downloaded" "$cache_file"
    fi

    printf '%s  %s\n' "$IVERILOG_DEB_SHA256" "$cache_file" | sha256sum --check --status || \
        die "checksum mismatch for $cache_file"
    mkdir -p "$install_root"
    dpkg-deb -x "$cache_file" "$install_root"
    [[ -x "$install_root/usr/bin/iverilog" ]] || die "local Icarus extraction failed"
    log "Icarus Verilog installed under .toolchain"
}

if ((SKIP_IVERILOG == 0)); then
    install_local_iverilog
fi

install_local_verilator() {
    local install_root="$PROJECT_ROOT/.toolchain/verilator"
    local cache_file="$PROJECT_ROOT/.cache/downloads/$VERILATOR_DEB_FILE"

    if [[ -x "$install_root/usr/bin/verilator_bin" ]]; then
        if VERILATOR_ROOT="$install_root/usr/share/verilator" \
            "$install_root/usr/bin/verilator_bin" --version 2>&1 | \
            grep -q 'Verilator 5\.020'; then
            log "Verilator 5.020 already installed locally"
            return
        fi
        die "$install_root contains an unexpected Verilator version"
    fi

    command -v apt-get >/dev/null 2>&1 || \
        die "apt-get is needed for the pinned local Verilator package on the supported Ubuntu host"
    command -v dpkg-deb >/dev/null 2>&1 || die "dpkg-deb is required"

    if [[ ! -f "$cache_file" ]]; then
        log "downloading Verilator $VERILATOR_DEB_VERSION into .cache"
        (
            cd "$PROJECT_ROOT/.cache/downloads"
            apt-get download "verilator=$VERILATOR_DEB_VERSION"
        )
        local downloaded
        downloaded="$(find "$PROJECT_ROOT/.cache/downloads" -maxdepth 1 -type f \
            -name 'verilator_*_amd64.deb' -print -quit)"
        [[ -n "$downloaded" ]] || die "Verilator package download did not produce a .deb"
        [[ "$downloaded" == "$cache_file" ]] || mv "$downloaded" "$cache_file"
    fi

    printf '%s  %s\n' "$VERILATOR_DEB_SHA256" "$cache_file" | \
        sha256sum --check --status || die "checksum mismatch for $cache_file"
    mkdir -p "$install_root"
    dpkg-deb -x "$cache_file" "$install_root"
    [[ -x "$install_root/usr/bin/verilator_bin" ]] || \
        die "local Verilator extraction failed"
    log "Verilator installed under .toolchain"
}

if ((SKIP_VERILATOR == 0)); then
    install_local_verilator
fi

"$PROJECT_ROOT/scripts/doctor.sh"
log "ready; use 'make smoke' for the baseline or 'make build' for Linux RTL"
