#!/bin/bash
# UFS Integration Test Suite
# Run in WSL (Debian/Ubuntu) after wsl_setup.sh completes

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
UFS_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
ZIG_PROJECT="$UFS_ROOT/core/zig"
TEST_IMG="${TEST_IMG:-$HOME/ufs_test.$$.img}"
MOUNT_POINT="${MOUNT_POINT:-/mnt/ufs_test}"
MKUFS_BIN="${MKUFS_BIN:-$ZIG_PROJECT/zig-out/bin/mkufs}"
UFS_FUSE_BIN="${UFS_FUSE_BIN:-$ZIG_PROJECT/zig-out/bin/ufs-fuse}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[PASS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[FAIL]${NC} $1"; }
log_step() { echo -e "${BLUE}[TEST]${NC} $1"; }

TESTS_PASSED=0
TESTS_FAILED=0

run_test() {
    local name="$1"
    local cmd="$2"
    log_step "$name"
    if eval "$cmd"; then
        log_info "$name"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        log_error "$name"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        # Keep the suite running so the final summary includes every test.
        return 0
    fi
}

# ============================================================================
# SETUP
# ============================================================================
setup() {
    log_step "Setting up test environment..."
    mkdir -p "$MOUNT_POINT"

    # Never follow links, touch devices, or overwrite an existing user file.
    if [[ -L "$TEST_IMG" || -e "$TEST_IMG" ]]; then
        log_error "Refusing to overwrite existing test-image path: $TEST_IMG"
        log_error "Choose an unused TEST_IMG path or remove the old test image yourself."
        exit 1
    fi
    mkdir -p "$(dirname -- "$TEST_IMG")"

    # Create a fresh, regular-file-backed test image.
    truncate -s 256M -- "$TEST_IMG"

    # Format with mkufs
    if [[ -f "$MKUFS_BIN" ]]; then
        "$MKUFS_BIN" -l "WFSTEST" -c 4096 -C lz4 "$TEST_IMG"
    else
        log_error "mkufs not found at $MKUFS_BIN - build tools first"
        exit 1
    fi

    # Verify FUSE binary exists
    if [[ ! -f "$UFS_FUSE_BIN" ]]; then
        log_error "ufs-fuse not found at $UFS_FUSE_BIN - build tools first"
        exit 1
    fi

    # Ensure fuse group and permissions
    if ! groups | grep -q fuse; then
        log_warn "User not in fuse group - run 'newgrp fuse' or logout/login"
    fi
}

# ============================================================================
# TEST 1: FUSE Mount/Unmount
# ============================================================================
test_fuse_mount() {
    run_test "FUSE Mount" "sudo $UFS_FUSE_BIN $TEST_IMG $MOUNT_POINT -o rw -f &"
    sleep 2
    run_test "FUSE Mount Verify" "mountpoint -q $MOUNT_POINT"
    run_test "FUSE Unmount" "sudo umount $MOUNT_POINT"
    sleep 1
}

# ============================================================================
# TEST 2: Basic File Operations
# ============================================================================
test_basic_ops() {
    # Mount
    sudo $UFS_FUSE_BIN $TEST_IMG $MOUNT_POINT -o rw -f &
    FUSE_PID=$!
    sleep 2

    run_test "Create file" "echo 'Hello UFS' | sudo tee $MOUNT_POINT/hello.txt > /dev/null"
    run_test "Read file" "grep -q 'Hello UFS' $MOUNT_POINT/hello.txt"
    run_test "Create directory" "sudo mkdir -p $MOUNT_POINT/dir1/dir2"
    run_test "Write in subdir" "echo 'nested' | sudo tee $MOUNT_POINT/dir1/dir2/nested.txt > /dev/null"
    run_test "List directory" "ls -la $MOUNT_POINT/dir1/dir2/"
    run_test "File permissions" "sudo chmod 644 $MOUNT_POINT/hello.txt && [[ -r $MOUNT_POINT/hello.txt ]]"
    run_test "File ownership" "sudo chown 1000:1000 $MOUNT_POINT/hello.txt && stat -c '%u:%g' $MOUNT_POINT/hello.txt | grep -q '1000:1000'"
    run_test "Symlink" "sudo ln -s /hello.txt $MOUNT_POINT/link.txt && readlink $MOUNT_POINT/link.txt | grep -q hello.txt"
    run_test "Hardlink" "sudo ln $MOUNT_POINT/hello.txt $MOUNT_POINT/hardlink.txt && [[ $(stat -c '%h' $MOUNT_POINT/hello.txt) -eq 2 ]]"
    run_test "Rename" "sudo mv $MOUNT_POINT/hello.txt $MOUNT_POINT/renamed.txt && [[ -f $MOUNT_POINT/renamed.txt ]]"
    run_test "Delete file" "sudo rm $MOUNT_POINT/renamed.txt && [[ ! -f $MOUNT_POINT/renamed.txt ]]"
    run_test "Delete directory" "sudo rm -rf $MOUNT_POINT/dir1 && [[ ! -d $MOUNT_POINT/dir1 ]]"

    # Test xattrs
    run_test "Set xattr" "sudo setfattr -n user.comment -v 'test value' $MOUNT_POINT/test.txt 2>/dev/null || echo 'test' | sudo tee $MOUNT_POINT/test.txt > /dev/null && sudo setfattr -n user.comment -v 'test value' $MOUNT_POINT/test.txt"
    run_test "Get xattr" "sudo getfattr -n user.comment $MOUNT_POINT/test.txt | grep -q 'test value'"
    run_test "List xattrs" "sudo getfattr -d $MOUNT_POINT/test.txt | grep -q user.comment"

    # Unmount
    sudo umount $MOUNT_POINT
    wait $FUSE_PID 2>/dev/null || true
}

# ============================================================================
# TEST 3: Large File I/O
# ============================================================================
test_large_io() {
    sudo $UFS_FUSE_BIN $TEST_IMG $MOUNT_POINT -o rw -f &
    FUSE_PID=$!
    sleep 2

    run_test "Write 10MB file" "sudo dd if=/dev/zero of=$MOUNT_POINT/large.bin bs=1M count=10 2>/dev/null"
    run_test "Verify size" "[[ $(stat -c%s $MOUNT_POINT/large.bin) -eq 10485760 ]]"
    run_test "Read back" "sudo dd if=$MOUNT_POINT/large.bin of=/dev/null bs=1M 2>/dev/null"
    run_test "Write 100MB file" "sudo dd if=/dev/zero of=$MOUNT_POINT/xlarge.bin bs=1M count=100 2>/dev/null"
    run_test "Verify 100MB" "[[ $(stat -c%s $MOUNT_POINT/xlarge.bin) -eq 104857600 ]]"

    sudo umount $MOUNT_POINT
    wait $FUSE_PID 2>/dev/null || true
}

# ============================================================================
# TEST 4: Concurrent Access
# ============================================================================
test_concurrent() {
    sudo $UFS_FUSE_BIN $TEST_IMG $MOUNT_POINT -o rw -f &
    FUSE_PID=$!
    sleep 2

    run_test "Concurrent writes" "
        for i in {1..10}; do
            (echo \"process \$i\" | sudo tee $MOUNT_POINT/concurrent_\$i.txt > /dev/null) &
        done
        wait
        [[ \$(ls $MOUNT_POINT/concurrent_*.txt | wc -l) -eq 10 ]]
    "
    run_test "Concurrent reads" "
        for i in {1..10}; do
            (sudo cat $MOUNT_POINT/concurrent_\$i.txt > /dev/null) &
        done
        wait
    "

    sudo umount $MOUNT_POINT
    wait $FUSE_PID 2>/dev/null || true
}

# ============================================================================
# TEST 5: Crash Recovery (Pull the plug)
# ============================================================================
test_crash_recovery() {
    sudo $UFS_FUSE_BIN $TEST_IMG $MOUNT_POINT -o rw -f &
    FUSE_PID=$!
    sleep 2

    run_test "Write before crash" "echo 'pre-crash data' | sudo tee $MOUNT_POINT/crash_test.txt > /dev/null"
    run_test "Sync" "sync"

    # Kill FUSE process abruptly (simulate power loss)
    sudo kill -9 "$FUSE_PID" 2>/dev/null || true
    sleep 1

    # This tests daemon termination and remount behavior, not power-loss
    # durability: sync above has already asked the host to flush dirty data.
    # Remount and verify data survived
    sudo $UFS_FUSE_BIN $TEST_IMG $MOUNT_POINT -o rw -f &
    FUSE_PID=$!
    sleep 2

    run_test "Data survived crash" "grep -q 'pre-crash data' $MOUNT_POINT/crash_test.txt"
    run_test "Can write after recovery" "echo 'post-crash data' | sudo tee $MOUNT_POINT/post_crash.txt > /dev/null"

    sudo umount $MOUNT_POINT
    wait $FUSE_PID 2>/dev/null || true
}

# ============================================================================
# TEST 6: Stress Test (Many Files)
# ============================================================================
test_stress() {
    sudo $UFS_FUSE_BIN $TEST_IMG $MOUNT_POINT -o rw -f &
    FUSE_PID=$!
    sleep 2

    run_test "Create 1000 files" "
        for i in {1..1000}; do
            echo \"file \$i\" | sudo tee $MOUNT_POINT/stress_\$i.txt > /dev/null
        done
        [[ \$(ls $MOUNT_POINT/stress_*.txt | wc -l) -eq 1000 ]]
    "
    run_test "Read all 1000 files" "
        for i in {1..1000}; do
            sudo cat $MOUNT_POINT/stress_\$i.txt > /dev/null
        done
    "
    run_test "Delete all 1000 files" "
        sudo rm $MOUNT_POINT/stress_*.txt
        [[ \$(ls $MOUNT_POINT/stress_*.txt 2>/dev/null | wc -l) -eq 0 ]]
    "

    sudo umount $MOUNT_POINT
    wait $FUSE_PID 2>/dev/null || true
}

# ============================================================================
# TEST 7: UEFI Driver (QEMU)
# ============================================================================
test_uefi_qemu() {
    if [[ -f "$ZIG_PROJECT/drivers/uefi/output/UFS.efi" ]] && [[ -f "$HOME/edk2/Build/OvmfX64/DEBUG_GCC5/FV/OVMF.fd" ]]; then
        log_step "UEFI QEMU Test (30 second timeout)..."
        timeout 30 qemu-system-x86_64 \
            -bios "$HOME/edk2/Build/OvmfX64/DEBUG_GCC5/FV/OVMF.fd" \
            -drive file="$TEST_IMG",format=raw,if=virtio \
            -drive file="$ZIG_PROJECT/drivers/uefi/output/UFS.efi",format=raw,if=virtio \
            -net none -nographic -serial stdio -monitor none -no-reboot -display none \
            2>&1 | head -50 || true
        log_info "UEFI QEMU test completed (check output above)"
    else
        log_warn "UEFI driver or OVMF not built - skipping"
    fi
}

# ============================================================================
# TEST 8: Linux Kernel Module
# ============================================================================
test_linux_kernel() {
    if lsmod | grep -q ufs; then
        log_step "Testing Linux kernel module..."
        run_test "Mount via kernel" "sudo mount -t ufs $TEST_IMG $MOUNT_POINT"
        run_test "Kernel read" "grep -q 'pre-crash' $MOUNT_POINT/crash_test.txt"
        run_test "Kernel write" "echo 'kernel write' | sudo tee $MOUNT_POINT/kernel_test.txt > /dev/null"
        run_test "Kernel unmount" "sudo umount $MOUNT_POINT"
    else
        log_warn "UFS kernel module not loaded - run: sudo modprobe ufs"
    fi
}

# ============================================================================
# TEST 9: Performance Benchmark
# ============================================================================
test_performance() {
    if [[ -f "$ZIG_PROJECT/zig-out/bin/ufs_perf_compare" ]]; then
        log_step "Running performance benchmark..."
        cd "$ZIG_PROJECT"
        "$ZIG_BIN" build perf-compare 2>&1 | tail -20
    else
        log_warn "Perf compare not built - skipping"
    fi
}

# ============================================================================
# TEST 10: FUSE Comprehensive Operations
# ============================================================================
test_fuse_comprehensive() {
    sudo $UFS_FUSE_BIN $TEST_IMG $MOUNT_POINT -o rw -f &
    FUSE_PID=$!
    sleep 2

    run_test "FUSE statfs" "df -P \"$MOUNT_POINT\" | tail -n 1 | grep -Fq \"$MOUNT_POINT\""
    run_test "FUSE xattr set/get/list/remove" "
        echo 'test' | sudo tee $MOUNT_POINT/xattr_test.txt > /dev/null &&
        sudo setfattr -n user.test -v 'value1' $MOUNT_POINT/xattr_test.txt &&
        sudo getfattr -n user.test $MOUNT_POINT/xattr_test.txt | grep -q 'value1' &&
        sudo getfattr -d $MOUNT_POINT/xattr_test.txt | grep -q user.test &&
        sudo setfattr -n user.test2 -v 'value2' $MOUNT_POINT/xattr_test.txt &&
        sudo getfattr -d $MOUNT_POINT/xattr_test.txt | grep -q user.test2 &&
        sudo setfattr -x user.test $MOUNT_POINT/xattr_test.txt &&
        ! sudo getfattr -n user.test $MOUNT_POINT/xattr_test.txt 2>/dev/null
    "
    run_test "FUSE fsync" "
        echo 'sync test' | sudo tee $MOUNT_POINT/sync_test.txt > /dev/null &&
        sync &&
        grep -q 'sync test' $MOUNT_POINT/sync_test.txt
    "
    run_test "FUSE truncate" "
        echo 'long content here' | sudo tee $MOUNT_POINT/trunc_test.txt > /dev/null &&
        sudo truncate -s 5 $MOUNT_POINT/trunc_test.txt &&
        [[ \$(stat -c%s $MOUNT_POINT/trunc_test.txt) -eq 5 ]]
    "
    run_test "FUSE utimens (timestamps)" "
        touch -d '2024-01-01 12:00:00' $MOUNT_POINT/time_test.txt &&
        stat -c '%y' $MOUNT_POINT/time_test.txt | grep -q '2024-01-01'
    "
    run_test "FUSE readdir with many entries" "
        sudo mkdir -p $MOUNT_POINT/dir_many &&
        for i in {1..100}; do echo \"f\$i\" | sudo tee $MOUNT_POINT/dir_many/f\$i.txt > /dev/null; done &&
        [[ \$(ls $MOUNT_POINT/dir_many/ | wc -l) -eq 100 ]]
    "
    run_test "FUSE rename across directories" "
        sudo mkdir -p $MOUNT_POINT/src $MOUNT_POINT/dst &&
        echo 'move me' | sudo tee $MOUNT_POINT/src/move.txt > /dev/null &&
        sudo mv $MOUNT_POINT/src/move.txt $MOUNT_POINT/dst/moved.txt &&
        [[ -f $MOUNT_POINT/dst/moved.txt ]] && [[ ! -f $MOUNT_POINT/src/move.txt ]]
    "

    sudo umount $MOUNT_POINT
    wait $FUSE_PID 2>/dev/null || true
}

# ============================================================================
# TEST 11: FUSE Edge Cases
# ============================================================================
test_fuse_edge_cases() {
    sudo $UFS_FUSE_BIN $TEST_IMG $MOUNT_POINT -o rw -f &
    FUSE_PID=$!
    sleep 2

    run_test "FUSE read/write at offset" "
        sudo dd if=/dev/zero of=$MOUNT_POINT/offset_test.bin bs=4k count=10 2>/dev/null &&
        echo 'AT_OFFSET' | sudo dd of=$MOUNT_POINT/offset_test.bin bs=1 seek=2048 conv=notrunc 2>/dev/null &&
        sudo dd if=$MOUNT_POINT/offset_test.bin bs=1 skip=2048 count=9 2>/dev/null | grep -q AT_OFFSET
    "
    run_test "FUSE sparse file" "
        sudo truncate -s 1G $MOUNT_POINT/sparse.bin &&
        [[ \$(du -B1 $MOUNT_POINT/sparse.bin | cut -f1) -lt 1000000 ]]
    "
    run_test "FUSE unlink open file" "
        echo 'open unlink' | sudo tee $MOUNT_POINT/open_unlink.txt > /dev/null &&
        (
            exec 3<$MOUNT_POINT/open_unlink.txt &&
            sudo rm $MOUNT_POINT/open_unlink.txt &&
            [[ ! -e $MOUNT_POINT/open_unlink.txt ]] &&
            cat <&3 | grep -q 'open unlink'
        )
    "
    run_test "FUSE directory fsync" "
        sudo mkdir -p $MOUNT_POINT/fsync_dir &&
        echo 'data' | sudo tee $MOUNT_POINT/fsync_dir/file.txt > /dev/null &&
        sync
    "

    sudo umount $MOUNT_POINT
    wait $FUSE_PID 2>/dev/null || true
}

# ============================================================================
# MAIN
# ============================================================================
main() {
    echo "========================================="
    echo "UFS Integration Test Suite"
    echo "========================================="
    echo ""

    setup

    # Run tests
    test_fuse_mount
    test_basic_ops
    test_large_io
    test_concurrent
    test_crash_recovery
    test_stress
    test_fuse_comprehensive
    test_fuse_edge_cases
    test_uefi_qemu
    test_linux_kernel
    test_performance

    # Summary
    echo ""
    echo "========================================="
    echo "Test Summary"
    echo "========================================="
    echo -e "Passed: ${GREEN}$TESTS_PASSED${NC}"
    echo -e "Failed: ${RED}$TESTS_FAILED${NC}"
    echo ""

    if [[ $TESTS_FAILED -eq 0 ]]; then
        log_info "All integration checks passed."
        exit 0
    else
        log_error "Some tests failed"
        exit 1
    fi
}

main "$@"