#!/bin/bash
# UFS WSL Setup Script
# Run this in WSL (Ubuntu 22.04+ recommended) to set up the complete build environment

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
UFS_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }

# Detect WSL
if ! grep -q microsoft /proc/version 2>/dev/null; then
    log_warn "Not running in WSL - some steps may differ"
fi

# ============================================================================
# 1. SYSTEM PACKAGES (Debian/Ubuntu compatible)
# ============================================================================
log_step "Installing system packages..."
sudo apt-get update
sudo apt-get install -y \
    build-essential \
    git \
    cmake \
    pkg-config \
    libfuse3-dev \
    libblkid-dev \
    uuid-dev \
    linux-headers-$(uname -r) \
    dkms \
    kmod \
    qemu-system-x86 \
    ovmf \
    wget \
    curl \
    unzip \
    python3 \
    python3-pip \
    clang \
    llvm \
    lld \
    libssl-dev \
    zlib1g-dev \
    liblz4-dev \
    libzstd-dev \
    xxd \
    bsdextrautils \
    libaio-dev \
    liburing-dev

# Ensure fuse group exists and user is in it
sudo groupadd -f fuse
sudo usermod -a -G fuse $USER
log_warn "You may need to logout/login or run 'newgrp fuse' for group changes to take effect"

# ============================================================================
# 2. ZIG INSTALLATION
# ============================================================================
log_step "Installing Zig..."
ZIG_VERSION="0.13.0"
ZIG_DIR="$HOME/.local/zig"
ZIG_BIN="$ZIG_DIR/zig"

if [[ ! -f "$ZIG_BIN" ]] || ! "$ZIG_BIN" version | grep -q "$ZIG_VERSION"; then
    log_info "Downloading Zig $ZIG_VERSION..."
    mkdir -p "$ZIG_DIR"
    cd /tmp
    wget -q "https://ziglang.org/download/${ZIG_VERSION}/zig-linux-x86_64-${ZIG_VERSION}.tar.xz"
    tar -xf "zig-linux-x86_64-${ZIG_VERSION}.tar.xz"
    mv "zig-linux-x86_64-${ZIG_VERSION}"/* "$ZIG_DIR/"
    rm -rf "zig-linux-x86_64-${ZIG_VERSION}"*
fi

export PATH="$ZIG_DIR:$PATH"
echo 'export PATH="$HOME/.local/zig:$PATH"' >> ~/.bashrc

log_info "Zig version: $("$ZIG_BIN" version)"

# ============================================================================
# 3. EDK2 SETUP (for UEFI driver)
# ============================================================================
log_step "Setting up EDK2..."
EDK2_DIR="$HOME/edk2"
if [[ ! -d "$EDK2_DIR" ]]; then
    log_info "Cloning EDK2..."
    git clone --depth 1 https://github.com/tianocore/edk2.git "$EDK2_DIR"
    cd "$EDK2_DIR"
    git submodule update --init
    make -C BaseTools
    source EdkSetup.sh
    # Build OVMF for QEMU testing
    build -p OvmfPkg/OvmfPkgX64.dsc -a X64 -t GCC5 -b DEBUG
    log_info "OVMF built at: $EDK2_DIR/Build/OvmfX64/DEBUG_GCC5/FV/OVMF.fd"
else
    log_info "EDK2 already exists at $EDK2_DIR"
fi

echo "export EDK2_DIR=$EDK2_DIR" >> ~/.bashrc

# ============================================================================
# 4. BUILD UFS ZIG CORE
# ============================================================================
log_step "Building UFS Zig core..."
ZIG_PROJECT="$UFS_ROOT/core/zig"

cd "$ZIG_PROJECT"
"$ZIG_BIN" build -Doptimize=ReleaseFast

if [[ -f "$ZIG_PROJECT/zig-out/lib/libufs_core.a" ]]; then
    log_info "Zig core library built successfully"
    log_info "Library: $ZIG_PROJECT/zig-out/lib/libufs_core.a"
else
    log_error "Zig core library not found!"
    exit 1
fi

# ============================================================================
# 5. BUILD TOOLS (mkufs, ufsck, ufsinfo, ufsctl)
# ============================================================================
log_step "Building UFS tools (mkufs, ufsck, ufsinfo, ufsctl)..."
cd "$ZIG_PROJECT"
"$ZIG_BIN" build tools -Doptimize=ReleaseFast

for tool in mkufs ufsck ufsinfo ufsctl; do
    if [[ -f "$ZIG_PROJECT/zig-out/bin/$tool" ]]; then
        log_info "$tool built: $ZIG_PROJECT/zig-out/bin/$tool"
    else
        log_warn "$tool not found at expected location"
    fi
done

# ============================================================================
# 6. BUILD FUSE DRIVER
# ============================================================================
log_step "Building FUSE driver..."
cd "$ZIG_PROJECT"
"$ZIG_BIN" build fuse -Doptimize=ReleaseFast

if [[ -f "$ZIG_PROJECT/zig-out/bin/ufs-fuse" ]]; then
    log_info "FUSE driver built: $ZIG_PROJECT/zig-out/bin/ufs-fuse"
else
    log_warn "FUSE driver not found at expected location"
fi

# ============================================================================
# 7. BUILD UEFI DRIVER
# ============================================================================
log_step "Building UEFI driver..."
UEFI_DRIVER_DIR="$ZIG_PROJECT/drivers/uefi"
cd "$UEFI_DRIVER_DIR"
chmod +x build_uefi.sh
./build_uefi.sh release build

if [[ -f "$UEFI_DRIVER_DIR/output/UFS.efi" ]]; then
    log_info "UEFI driver built: $UEFI_DRIVER_DIR/output/UFS.efi"
else
    log_warn "UEFI driver not found at expected location"
fi

# ============================================================================
# 8. BUILD LINUX DKMS MODULE
# ============================================================================
log_step "Building Linux DKMS module..."
LINUX_DRIVER_DIR="$ZIG_PROJECT/drivers/linux"
cd "$LINUX_DRIVER_DIR"

# Copy Zig headers and library for DKMS build
mkdir -p include
cp "$ZIG_PROJECT/src/ufs.h" include/
mkdir -p lib
cp "$ZIG_PROJECT/zig-out/lib/libufs_core.a" lib/

# Build with DKMS
sudo dkms add .
sudo dkms build ufs/1.0.0
sudo dkms install ufs/1.0.0

if lsmod | grep -q ufs; then
    log_info "UFS kernel module loaded"
else
    log_info "UFS kernel module built (not loaded yet)"
    log_info "Load with: sudo modprobe ufs"
fi

# ============================================================================
# 8. CREATE TEST DISK IMAGE
# ============================================================================
log_step "Creating test disk image..."
TEST_IMG="$HOME/ufs_test.img"
if [[ -L "$TEST_IMG" || -e "$TEST_IMG" ]]; then
    log_error "Refusing to overwrite existing test-image path: $TEST_IMG"
    log_error "Back up or remove the old image manually, then rerun setup."
    exit 1
fi
umask 077
dd if=/dev/zero of="$TEST_IMG" bs=1M count=512 status=none

# Format with mkufs (will be available after zig build tools)
if [[ -f "$ZIG_PROJECT/zig-out/bin/mkufs" ]]; then
    "$ZIG_PROJECT/zig-out/bin/mkufs" -l "WFSTEST" -c 4096 -C lz4 "$TEST_IMG"
    log_info "Test image created and formatted: $TEST_IMG"
else
    log_warn "mkufs not built yet - skipping format"
fi

# ============================================================================
# 10. SUMMARY
# ============================================================================
log_step "WSL Setup Complete!"
echo ""
echo "========================================="
echo "UFS Build Environment Ready"
echo "========================================="
echo ""
echo "Key paths:"
echo "  UFS Root:       $UFS_ROOT"
echo "  Zig Project:    $ZIG_PROJECT"
echo "  Zig Binary:     $ZIG_BIN"
echo "  EDK2:           $EDK2_DIR"
echo "  OVMF:           $EDK2_DIR/Build/OvmfX64/DEBUG_GCC5/FV/OVMF.fd"
echo "  Test Image:     $TEST_IMG"
echo ""
echo "Built binaries:"
echo "  mkufs:          $ZIG_PROJECT/zig-out/bin/mkufs"
echo "  ufs-fuse:       $ZIG_PROJECT/zig-out/bin/ufs-fuse"
echo "  ufsck:          $ZIG_PROJECT/zig-out/bin/ufsck"
echo "  ufsinfo:        $ZIG_PROJECT/zig-out/bin/ufsinfo"
echo "  ufsctl:         $ZIG_PROJECT/zig-out/bin/ufsctl"
echo "  UFS.efi:        $UEFI_DRIVER_DIR/output/UFS.efi"
echo ""
echo "Next commands to run:"
echo ""
echo "  # Test FUSE mount"
echo "  mkdir -p /mnt/ufs_test"
echo "  sudo $ZIG_PROJECT/zig-out/bin/ufs-fuse $TEST_IMG /mnt/ufs_test -o rw,debug -f"
echo ""
echo "  # Run all integration tests"
echo "  cd $UFS_ROOT"
echo "  ./scripts/test_ufs.sh"
echo ""
echo "  # Test UEFI in QEMU"
echo "  cd $UEFI_DRIVER_DIR"
echo "  ./build_uefi.sh release test"
echo ""
echo "  # Load Linux kernel module"
echo "  sudo modprobe ufs"
echo "  sudo mount -t ufs $TEST_IMG /mnt/ufs_test"
echo ""
echo "  # Run benchmarks"
echo "  cd $ZIG_PROJECT"
echo "  $ZIG_BIN build perf-compare"
echo ""
echo "Environment variables added to ~/.bashrc - restart shell or run:"
echo "  source ~/.bashrc"