#!/bin/bash
# UFS Build Verification Script
# Run this in WSL to verify all components build correctly

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PASS=0
FAIL=0
SKIP=0

check() {
    local name="$1"
    local path="$2"
    if [[ -f "$path" ]]; then
        echo -e "${GREEN}[PASS]${NC} $name: $path"
        PASS=$((PASS + 1))
    else
        echo -e "${RED}[FAIL]${NC} $name: $path (NOT FOUND)"
        FAIL=$((FAIL + 1))
    fi
}

check_dir() {
    local name="$1"
    local path="$2"
    if [[ -d "$path" ]]; then
        echo -e "${GREEN}[PASS]${NC} $name: $path"
        PASS=$((PASS + 1))
    else
        echo -e "${RED}[FAIL]${NC} $name: $path (NOT FOUND)"
        FAIL=$((FAIL + 1))
    fi
}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
UFS_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
ZIG_PROJECT="$UFS_ROOT/core/zig"
ZIG_BIN="${ZIG_BIN:-$HOME/.local/zig/zig}"

echo "========================================="
echo "UFS Build Verification"
echo "========================================="
echo ""

# Check Zig installation
echo "--- Zig Installation ---"
if [[ -f "$ZIG_BIN" ]]; then
    echo -e "${GREEN}[PASS]${NC} Zig binary: $("$ZIG_BIN" version)"
    PASS=$((PASS + 1))
else
    echo -e "${YELLOW}[SKIP]${NC} Zig not found at $ZIG_BIN; compile checks unavailable"
    SKIP=$((SKIP + 1))
fi

# Check Zig project structure
echo ""
echo "--- Zig Core Source ---"
check_dir "src directory" "$ZIG_PROJECT/src"
check "journal.zig" "$ZIG_PROJECT/src/journal.zig"
check "c_api.zig" "$ZIG_PROJECT/src/c_api.zig"
check "version.zig" "$ZIG_PROJECT/src/version.zig"
check "allocation.zig" "$ZIG_PROJECT/src/allocation.zig"
check "directory.zig" "$ZIG_PROJECT/src/directory.zig"
check "compression.zig" "$ZIG_PROJECT/src/compression.zig"
check "integrity.zig" "$ZIG_PROJECT/src/integrity.zig"
check "blockdev.zig" "$ZIG_PROJECT/src/blockdev.zig"
check "serialization.zig" "$ZIG_PROJECT/src/serialization.zig"
check "utils.zig" "$ZIG_PROJECT/src/utils.zig"
check "crypto.zig" "$ZIG_PROJECT/src/crypto.zig"
check "main.zig" "$ZIG_PROJECT/src/main.zig"
check "bench.zig" "$ZIG_PROJECT/src/bench.zig"
check "tests.zig" "$ZIG_PROJECT/src/tests.zig"
check "integration_test.zig" "$ZIG_PROJECT/src/integration_test.zig"
check "reliability_test.zig" "$ZIG_PROJECT/src/reliability_test.zig"
check "fuzz.zig" "$ZIG_PROJECT/src/fuzz.zig"

# Check ufs.h header
echo ""
echo "--- C API Header ---"
check "ufs.h" "$ZIG_PROJECT/src/ufs.h"

# Check build artifacts (if built)
echo ""
echo "--- Build Artifacts ---"
if [[ -x "$ZIG_BIN" ]]; then
    echo "Running Zig build validation..."
    if (cd "$ZIG_PROJECT" && "$ZIG_BIN" build); then
        echo -e "${GREEN}[PASS]${NC} Zig build"
        PASS=$((PASS + 1))
    else
        echo -e "${RED}[FAIL]${NC} Zig build"
        FAIL=$((FAIL + 1))
    fi
else
    echo -e "${YELLOW}[SKIP]${NC} Zig build (compiler unavailable)"
    SKIP=$((SKIP + 1))
fi

# Check Linux driver
echo ""
echo "--- Linux DKMS Driver ---"
check_dir "linux driver dir" "$ZIG_PROJECT/drivers/linux"
check "ufs_linux.c" "$ZIG_PROJECT/drivers/linux/ufs_linux.c"
check "Kconfig" "$ZIG_PROJECT/drivers/linux/Kconfig"
check "Makefile" "$ZIG_PROJECT/drivers/linux/Makefile"
check "dkms.conf" "$ZIG_PROJECT/drivers/linux/dkms.conf"
check "config_check" "$ZIG_PROJECT/drivers/linux/config_check"
check "VERSION" "$ZIG_PROJECT/drivers/linux/VERSION"

# Check FUSE driver
echo ""
echo "--- FUSE Driver ---"
check_dir "fuse driver dir" "$ZIG_PROJECT/drivers/fuse"
check "ufs_fuse.c" "$ZIG_PROJECT/drivers/fuse/ufs_fuse.c"

# Check Windows driver
echo ""
echo "--- Windows IFS Driver ---"
check_dir "windows driver dir" "$ZIG_PROJECT/drivers/windows"
check "ufs_ifs.c" "$ZIG_PROJECT/drivers/windows/ufs_ifs.c"
check "ufs_fsd.c" "$ZIG_PROJECT/drivers/windows/ufs_fsd.c"
check "ufs_metadata.c" "$ZIG_PROJECT/drivers/windows/ufs_metadata.c"
check "ufs_ioctl.c" "$ZIG_PROJECT/drivers/windows/ufs_ioctl.c"
check "Makefile" "$ZIG_PROJECT/drivers/windows/Makefile"

# Check UEFI driver
echo ""
echo "--- UEFI Driver ---"
check_dir "uefi driver dir" "$ZIG_PROJECT/drivers/uefi"
check "UFS.dsc" "$ZIG_PROJECT/drivers/uefi/UFS.dsc"
check "UFS.inf" "$ZIG_PROJECT/drivers/uefi/UFS.inf"
check "ufs_uefi.c" "$ZIG_PROJECT/drivers/uefi/ufs_uefi.c"
check "UfsBlockIo.c" "$ZIG_PROJECT/drivers/uefi/UfsBlockIo.c"
check "UfsSimpleFs.c" "$ZIG_PROJECT/drivers/uefi/UfsSimpleFs.c"
check "UfsFileProtocol.c" "$ZIG_PROJECT/drivers/uefi/UfsFileProtocol.c"
check "UfsDevicePath.c" "$ZIG_PROJECT/drivers/uefi/UfsDevicePath.c"
check "UfsRecovery.c" "$ZIG_PROJECT/drivers/uefi/UfsRecovery.c"
check "UfsBootLoader.c" "$ZIG_PROJECT/drivers/uefi/UfsBootLoader.c"
check "UfsCoreWrapper.c" "$ZIG_PROJECT/drivers/uefi/UfsCoreWrapper.c"
check "build_uefi.sh" "$ZIG_PROJECT/drivers/uefi/build_uefi.sh"
check "main.zig" "$ZIG_PROJECT/drivers/uefi/main.zig"

# Check scripts
echo ""
echo "--- Build & Test Scripts ---"
check "wsl_setup.sh" "$UFS_ROOT/scripts/wsl_setup.sh"
check "test_ufs.sh" "$UFS_ROOT/scripts/test_ufs.sh"
check "run_wsl_tests.sh" "$UFS_ROOT/scripts/run_wsl_tests.sh"
check "windows_setup.ps1" "$UFS_ROOT/scripts/windows_setup.ps1"
check "config_check" "$UFS_ROOT/core/zig/drivers/linux/config_check"
check "WSL_QUICKSTART.md" "$UFS_ROOT/scripts/WSL_QUICKSTART.md"
check "BUILD_README.md" "$UFS_ROOT/BUILD_README.md"
check "BUILD_SUMMARY.md" "$UFS_ROOT/BUILD_SUMMARY.md"

# Check documentation
echo ""
echo "--- Documentation ---"
check_dir "docs" "$UFS_ROOT/docs"
check "UFS-FORMAT-V1.md" "$UFS_ROOT/docs/specifications/UFS-FORMAT-V1.md"
check "UFS-COMPARISON.md" "$UFS_ROOT/docs/architecture/UFS-COMPARISON.md"

# Check tracking
echo ""
echo "--- Tracking ---"
check_dir "tracking" "$UFS_ROOT/tracking"

# Summary
echo ""
echo "========================================="
echo "Verification Summary"
echo "========================================="
echo -e "Passed: ${GREEN}$PASS${NC}"
echo -e "Failed: ${RED}$FAIL${NC}"
echo -e "Skipped: ${YELLOW}$SKIP${NC}"
echo ""

if [[ $FAIL -eq 0 && $SKIP -eq 0 ]]; then
    echo -e "${GREEN}All verification checks passed!${NC}"
    echo ""
    echo "Ready to build. Run:"
    echo "  cd $UFS_ROOT"
    echo "  ./scripts/wsl_setup.sh"
    exit 0
elif [[ $FAIL -eq 0 ]]; then
    echo -e "${YELLOW}Static checks passed; one or more build checks were skipped.${NC}"
    echo "Install the required toolchain and rerun this script for full verification."
    exit 2
else
    echo -e "${RED}Verification failures detected. Resolve them before building.${NC}"
    exit 1
fi