#!/bin/bash
# UFS WSL Test Runner - Execute this inside Debian WSL
# This script runs all the setup and tests in sequence

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[x]${NC} $1"; }
step() { echo -e "${BLUE}[>]${NC} $1"; }

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
UFS_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
ZIG_PROJECT="$UFS_ROOT/core/zig"
ZIG_BIN="$HOME/.local/zig/zig"

# Check if we're in WSL
if ! grep -q microsoft /proc/version 2>/dev/null; then
    error "This script must be run inside WSL (Debian/Ubuntu)"
    exit 1
fi

step "Starting UFS WSL test run..."

# Check Zig
if [[ ! -f "$ZIG_BIN" ]]; then
    warn "Zig not found at $ZIG_BIN"
    warn "Run wsl_setup.sh first to install Zig and build everything"
    exit 1
fi

log "Zig version: $("$ZIG_BIN" version)"

# Build Zig core if needed
if [[ ! -f "$ZIG_PROJECT/zig-out/lib/libufs_core.a" ]]; then
    step "Building Zig core library..."
    cd "$ZIG_PROJECT"
    "$ZIG_BIN" build -Doptimize=ReleaseFast
fi

# Build tools if needed
if [[ ! -f "$ZIG_PROJECT/zig-out/bin/mkufs" ]]; then
    step "Building UFS tools..."
    cd "$ZIG_PROJECT"
    "$ZIG_BIN" build tools -Doptimize=ReleaseFast
fi

# Build FUSE if needed
if [[ ! -f "$ZIG_PROJECT/zig-out/bin/ufs-fuse" ]]; then
    step "Building FUSE driver..."
    cd "$ZIG_PROJECT"
    "$ZIG_BIN" build fuse -Doptimize=ReleaseFast
fi

# Build Linux DKMS module if not installed
if ! lsmod | grep -q ufs; then
    if [[ -f /lib/modules/$(uname -r)/kernel/fs/ufs/ufs.ko ]]; then
        step "Loading existing UFS kernel module..."
        sudo modprobe ufs
    else
        warn "UFS kernel module not built. Building via DKMS..."
        LINUX_DIR="$ZIG_PROJECT/drivers/linux"
        cd "$LINUX_DIR"
        mkdir -p include
        cp "$ZIG_PROJECT/src/ufs.h" include/
        mkdir -p lib
        cp "$ZIG_PROJECT/zig-out/lib/libufs_core.a" lib/
        sudo dkms add .
        sudo dkms build ufs/1.0.0
        sudo dkms install ufs/1.0.0
        sudo modprobe ufs
    fi
fi

# Create test image
TEST_IMG="${TEST_IMG:-$HOME/ufs_test.$$.img}"
step "Creating test image..."
if [[ -L "$TEST_IMG" || -e "$TEST_IMG" ]]; then
    error "Refusing to overwrite existing test-image path: $TEST_IMG"
    error "Set TEST_IMG to an unused path or remove the old test image yourself."
    exit 1
fi
mkdir -p "$(dirname -- "$TEST_IMG")"
umask 077
dd if=/dev/zero of="$TEST_IMG" bs=1M count=256 status=none

step "Formatting test image with mkufs..."
"$ZIG_PROJECT/zig-out/bin/mkufs" -l "WFSTEST" -c 4096 -C lz4 "$TEST_IMG"

# Run tests
step "Running FUSE tests..."

MOUNT_POINT="/mnt/ufs_test"
mkdir -p "$MOUNT_POINT"

# Test 1: FUSE Mount
log "Test 1: FUSE Mount/Unmount"
sudo "$ZIG_PROJECT/zig-out/bin/ufs-fuse" "$TEST_IMG" "$MOUNT_POINT" -o rw -f &
FUSE_PID=$!
sleep 2
mountpoint -q "$MOUNT_POINT" && log "  Mount OK" || { error "  Mount FAILED"; exit 1; }
sudo umount "$MOUNT_POINT"
wait $FUSE_PID 2>/dev/null || true
log "  Unmount OK"

# Test 2: Basic Ops
log "Test 2: Basic File Operations"
sudo "$ZIG_PROJECT/zig-out/bin/ufs-fuse" "$TEST_IMG" "$MOUNT_POINT" -o rw -f &
FUSE_PID=$!
sleep 2

echo 'Hello UFS' | sudo tee "$MOUNT_POINT/hello.txt" > /dev/null
grep -q 'Hello UFS' "$MOUNT_POINT/hello.txt" && log "  Create/Read OK" || error "  Create/Read FAILED"
sudo mkdir -p "$MOUNT_POINT/dir1/dir2"
echo 'nested' | sudo tee "$MOUNT_POINT/dir1/dir2/nested.txt" > /dev/null
[[ -f "$MOUNT_POINT/dir1/dir2/nested.txt" ]] && log "  Nested dir OK" || error "  Nested dir FAILED"
sudo ln -s /hello.txt "$MOUNT_POINT/link.txt"
readlink "$MOUNT_POINT/link.txt" | grep -q hello.txt && log "  Symlink OK" || error "  Symlink FAILED"
sudo ln "$MOUNT_POINT/hello.txt" "$MOUNT_POINT/hardlink.txt"
[[ $(stat -c '%h' "$MOUNT_POINT/hello.txt") -eq 2 ]] && log "  Hardlink OK" || error "  Hardlink FAILED"
sudo mv "$MOUNT_POINT/hello.txt" "$MOUNT_POINT/renamed.txt"
[[ -f "$MOUNT_POINT/renamed.txt" ]] && log "  Rename OK" || error "  Rename FAILED"
sudo rm "$MOUNT_POINT/renamed.txt"
[[ ! -f "$MOUNT_POINT/renamed.txt" ]] && log "  Delete OK" || error "  Delete FAILED"
sudo rm -rf "$MOUNT_POINT/dir1"
[[ ! -d "$MOUNT_POINT/dir1" ]] && log "  Rmdir OK" || error "  Rmdir FAILED"

# xattrs
echo 'test' | sudo tee "$MOUNT_POINT/test.txt" > /dev/null
sudo setfattr -n user.comment -v 'test value' "$MOUNT_POINT/test.txt"
sudo getfattr -n user.comment "$MOUNT_POINT/test.txt" | grep -q 'test value' && log "  xattr OK" || error "  xattr FAILED"

sudo umount "$MOUNT_POINT"
wait $FUSE_PID 2>/dev/null || true

# Test 3: Large I/O
log "Test 3: Large File I/O"
sudo "$ZIG_PROJECT/zig-out/bin/ufs-fuse" "$TEST_IMG" "$MOUNT_POINT" -o rw -f &
FUSE_PID=$!
sleep 2

sudo dd if=/dev/zero of="$MOUNT_POINT/large.bin" bs=1M count=10 2>/dev/null
[[ $(stat -c%s "$MOUNT_POINT/large.bin") -eq 10485760 ]] && log "  10MB OK" || error "  10MB FAILED"
sudo dd if=/dev/zero of="$MOUNT_POINT/xlarge.bin" bs=1M count=100 2>/dev/null
[[ $(stat -c%s "$MOUNT_POINT/xlarge.bin") -eq 104857600 ]] && log "  100MB OK" || error "  100MB FAILED"

sudo umount "$MOUNT_POINT"
wait $FUSE_PID 2>/dev/null || true

# Test 4: Crash Recovery
log "Test 4: Crash Recovery (SIGKILL)"
sudo "$ZIG_PROJECT/zig-out/bin/ufs-fuse" "$TEST_IMG" "$MOUNT_POINT" -o rw -f &
FUSE_PID=$!
sleep 2

echo 'pre-crash data' | sudo tee "$MOUNT_POINT/crash_test.txt" > /dev/null
sync
sudo kill -9 $FUSE_PID 2>/dev/null || true
sleep 1

sudo "$ZIG_PROJECT/zig-out/bin/ufs-fuse" "$TEST_IMG" "$MOUNT_POINT" -o rw -f &
FUSE_PID=$!
sleep 2

grep -q 'pre-crash data' "$MOUNT_POINT/crash_test.txt" && log "  Data survived crash OK" || error "  Data survived crash FAILED"
echo 'post-crash data' | sudo tee "$MOUNT_POINT/post_crash.txt" > /dev/null && log "  Write after recovery OK" || error "  Write after recovery FAILED"

sudo umount "$MOUNT_POINT"
wait $FUSE_PID 2>/dev/null || true

# Test 5: Stress (1000 files)
log "Test 5: Stress Test (1000 files)"
sudo "$ZIG_PROJECT/zig-out/bin/ufs-fuse" "$TEST_IMG" "$MOUNT_POINT" -o rw -f &
FUSE_PID=$!
sleep 2

for i in {1..1000}; do
    echo "file $i" | sudo tee "$MOUNT_POINT/stress_$i.txt" > /dev/null
done
[[ $(ls "$MOUNT_POINT"/stress_*.txt | wc -l) -eq 1000 ]] && log "  Create 1000 OK" || error "  Create 1000 FAILED"

for i in {1..1000}; do
    sudo cat "$MOUNT_POINT/stress_$i.txt" > /dev/null
done
log "  Read 1000 OK"

sudo rm "$MOUNT_POINT"/stress_*.txt
[[ $(ls "$MOUNT_POINT"/stress_*.txt 2>/dev/null | wc -l) -eq 0 ]] && log "  Delete 1000 OK" || error "  Delete 1000 FAILED"

sudo umount "$MOUNT_POINT"
wait $FUSE_PID 2>/dev/null || true

# Test 6: Linux Kernel Module (if loaded)
if lsmod | grep -q ufs; then
    log "Test 6: Linux Kernel Module"
    sudo mount -t ufs "$TEST_IMG" "$MOUNT_POINT"
    [[ -f "$MOUNT_POINT/crash_test.txt" ]] && log "  Kernel mount OK" || error "  Kernel mount FAILED"
    echo 'kernel write' | sudo tee "$MOUNT_POINT/kernel_test.txt" > /dev/null && log "  Kernel write OK" || error "  Kernel write FAILED"
    sudo umount "$MOUNT_POINT"
    log "  Kernel unmount OK"
else
    warn "Test 6: Linux Kernel Module - SKIPPED (module not loaded)"
    warn "  Run: sudo modprobe ufs"
fi

# Test 7: UEFI QEMU (if available)
if [[ -f "$ZIG_PROJECT/drivers/uefi/output/UFS.efi" ]] && [[ -f "$HOME/edk2/Build/OvmfX64/DEBUG_GCC5/FV/OVMF.fd" ]]; then
    log "Test 7: UEFI QEMU (30s timeout)"
    timeout 30 qemu-system-x86_64 \
        -bios "$HOME/edk2/Build/OvmfX64/DEBUG_GCC5/FV/OVMF.fd" \
        -drive file="$TEST_IMG",format=raw,if=virtio \
        -drive file="$ZIG_PROJECT/drivers/uefi/output/UFS.efi",format=raw,if=virtio \
        -net none -nographic -serial stdio -monitor none -no-reboot -display none \
        2>&1 | head -30 || true
    log "  UEFI QEMU test completed"
else
    warn "Test 7: UEFI QEMU - SKIPPED (not built)"
fi

# Cleanup
rm -f "$TEST_IMG"

echo ""
echo "========================================="
echo -e "${GREEN}All tests completed successfully!${NC}"
echo "========================================="
echo ""
echo "Next steps:"
echo "  - Test on real USB: sudo mkufs -l USBTEST -c 4096 /dev/sdX"
echo "  - Benchmark: cd $ZIG_PROJECT && $ZIG_BIN build perf-compare"
echo "  - Windows IFS: Run scripts/windows_setup.ps1 in Admin PowerShell"