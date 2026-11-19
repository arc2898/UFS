#!/bin/bash
# UFS UEFI Driver Build Script
# Builds the UEFI driver using EDK2
# Usage: ./build_uefi.sh [debug|release] [clean|build|package|test]

set -euo pipefail

BUILD_TYPE="${1:-release}"
ACTION="${2:-build}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EDK2_DIR="${EDK2_DIR:-$HOME/edk2}"
WORKSPACE_DIR="$SCRIPT_DIR/../../.."
ZIG_DIR="$SCRIPT_DIR/../zig"
UFS_CORE_LIB="$ZIG_DIR/zig-out/lib/libufs_core.a"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check EDK2 installation
check_edk2() {
    if [[ ! -f "$EDK2_DIR/EdkSetup.sh" ]]; then
        log_error "EDK2 not found at $EDK2_DIR"
        log_info "Set EDK2_DIR environment variable or install EDK2"
        log_info "Install: git clone https://github.com/tianocore/edk2.git && cd edk2 && git submodule update --init && make -C BaseTools"
        exit 1
    fi
}

# Build Zig core library
build_zig_core() {
    log_info "Building Zig core library for UEFI..."
    cd "$ZIG_DIR"

    # UEFI target - freestanding, no standard library
    local target="x86_64-freestanding"
    if [[ "$BUILD_TYPE" == "debug" ]]; then
        zig build -Dtarget="$target" -Doptimize=Debug -Dstrip=false
    else
        zig build -Dtarget="$target" -Doptimize=ReleaseFast -Dstrip=true
    fi

    if [[ ! -f "$UFS_CORE_LIB" ]]; then
        log_error "Zig core library not found at $UFS_CORE_LIB"
        exit 1
    fi

    # Copy to UEFI driver directory
    mkdir -p "$SCRIPT_DIR/UFS/Library"
    cp "$UFS_CORE_LIB" "$SCRIPT_DIR/UFS/Library/"

    # Copy headers
    mkdir -p "$SCRIPT_DIR/UFS/Include"
    cp "$ZIG_DIR/src/ufs.h" "$SCRIPT_DIR/UFS/Include/"

    log_info "Zig core library built for UEFI: $UFS_CORE_LIB"
}

# Setup EDK2 workspace
setup_workspace() {
    log_info "Setting up EDK2 workspace..."

    cd "$EDK2_DIR"
    source EdkSetup.sh

    # Create symlink to UFS package
    local pkg_dir="$EDK2_DIR/UFS"
    if [[ ! -L "$pkg_dir" ]]; then
        ln -sf "$SCRIPT_DIR" "$pkg_dir"
        log_info "Linked UFS package to EDK2 workspace"
    fi
}

# Build UEFI driver
build_driver() {
    log_info "Building UFS UEFI driver..."
    cd "$EDK2_DIR"
    source EdkSetup.sh

    local target="DEBUG"
    if [[ "$BUILD_TYPE" == "release" ]]; then
        target="RELEASE"
    fi

    build -p UFS/UFS.dsc -a X64 -t GCC5 -b "$target"

    local output="$EDK2_DIR/Build/UFS/${target}_GCC5/X64/UFS.efi"
    if [[ ! -f "$output" ]]; then
        log_error "UEFI driver not found at $output"
        exit 1
    fi

    # Copy to output directory
    mkdir -p "$SCRIPT_DIR/output"
    cp "$output" "$SCRIPT_DIR/output/UFS.efi"

    log_info "UEFI driver built: $output"
    log_info "Copied to: $SCRIPT_DIR/output/UFS.efi"
}

# Create test image for QEMU
create_test_image() {
    log_info "Creating test disk image..."
    cd "$SCRIPT_DIR"

    local img="output/test_ufs.img"
    mkdir -p output
    if [[ -L "$img" || -e "$img" ]]; then
        log_error "Refusing to overwrite existing test-image path: $img"
        return 1
    fi

    # Create a private 100MB image without clobbering an existing path.
    umask 077
    dd if=/dev/zero of="$img" bs=1M count=100 2>/dev/null

    # Format with UFS (using mkufs from core tools)
    if command -v mkufs &> /dev/null; then
        mkufs -l "UEFITEST" -c 4096 -C lz4 "$img"
    else
        log_warn "mkufs not in PATH, skipping format"
    fi

    log_info "Test image created: $img"
}

# Run QEMU test
test_qemu() {
    log_info "Testing with QEMU..."
    cd "$SCRIPT_DIR"

    local ovmf="$EDK2_DIR/Build/OvmfX64/DEBUG_GCC5/FV/OVMF.fd"
    if [[ ! -f "$ovmf" ]]; then
        log_warn "OVMF not found, building..."
        build -p OvmfPkg/OvmfPkgX64.dsc -a X64 -t GCC5 -b DEBUG
        ovmf="$EDK2_DIR/Build/OvmfX64/DEBUG_GCC5/FV/OVMF.fd"
    fi

    qemu-system-x86_64 \
        -bios "$ovmf" \
        -drive file=output/test_ufs.img,format=raw,if=virtio \
        -drive file=output/UFS.efi,format=raw,if=virtio \
        -net none \
        -nographic \
        -serial stdio \
        -monitor none \
        -no-reboot \
        -display none
}

# Package for distribution
package() {
    log_info "Creating UEFI driver package..."
    cd "$SCRIPT_DIR"

    local pkg_dir="output/package"
    rm -rf "$pkg_dir"
    mkdir -p "$pkg_dir/EFI/BOOT"

    # Copy driver as BOOTX64.EFI (standard boot location)
    cp "output/UFS.efi" "$pkg_dir/EFI/BOOT/BOOTX64.EFI"

    # Create startup.nsh for testing
    cat > "$pkg_dir/startup.nsh" <<'EOF'
@echo -off
echo UFS UEFI Driver Test
echo ====================
echo.
echo Available commands:
echo   ufs_info    - Show UFS volume info
echo   ufs_mount   - Mount UFS volume
echo   ufs_ls      - List directory
echo.
fs0:
ls
EOF

    # Create zip package
    cd output
    zip -r "ufs-uefi-1.0.0.zip" package/
    log_info "Package created: output/ufs-uefi-1.0.0.zip"
}

# Clean
clean_all() {
    log_info "Cleaning build artifacts..."
    cd "$EDK2_DIR"
    if [[ -f "EdkSetup.sh" ]]; then
        source EdkSetup.sh
        build -p UFS/UFS.dsc -a X64 -t GCC5 clean
    fi
    cd "$SCRIPT_DIR"
    rm -rf output/
    log_info "Clean complete"
}

# Main
main() {
    log_info "UFS UEFI Driver Build Script"
    log_info "Build type: $BUILD_TYPE"
    log_info "Action: $ACTION"

    case "$ACTION" in
        build)
            check_edk2
            build_zig_core
            setup_workspace
            build_driver
            ;;
        test)
            check_edk2
            build_zig_core
            setup_workspace
            build_driver
            create_test_image
            test_qemu
            ;;
        package)
            build_zig_core
            setup_workspace
            build_driver
            package
            ;;
        clean)
            clean_all
            ;;
        all)
            check_edk2
            build_zig_core
            setup_workspace
            build_driver
            create_test_image
            package
            ;;
        *)
            log_error "Unknown action: $ACTION"
            echo "Usage: $0 [debug|release] [build|test|package|clean|all]"
            exit 1
            ;;
    esac
}

main "$@"