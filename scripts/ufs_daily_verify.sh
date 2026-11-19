#!/bin/bash
# UFS Daily Verification Script
# Run via cron: 0 2 * * * /path/to/ufs_daily_verify.sh
# Or manually: ./ufs_daily_verify.sh

set -euo pipefail

# Resolve the project root from this script unless explicitly overridden.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
UFS_ROOT="${UFS_ROOT:-$(cd -- "$SCRIPT_DIR/.." && pwd)}"
LOG_DIR="$UFS_ROOT/logs"
DATE=$(date +%Y%m%d_%H%M%S)
LOG_FILE="$LOG_DIR/verify_$DATE.log"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Create log directory
mkdir -p "$LOG_DIR"

# Start logging
{
    echo "=== UFS Daily Verification Started at $(date) ==="
    echo "UFS_ROOT: $UFS_ROOT"
    echo "Log file: $LOG_FILE"
    echo ""

    cd "$UFS_ROOT/core/zig"

    # Check if Zig is available
    if ! command -v zig &> /dev/null; then
        echo "ERROR: zig not found in PATH"
        exit 1
    fi

    echo "Zig version: $(zig version)"
    echo ""

    # Run unit tests
    echo "Running unit tests..."
    if zig build test 2>&1; then
        echo "UNIT TESTS: PASSED"
    else
        echo "UNIT TESTS: FAILED"
        exit 1
    fi
    echo ""

    # Run integration tests
    echo "Running integration tests..."
    if zig build integration-test 2>&1; then
        echo "INTEGRATION TESTS: PASSED"
    else
        echo "INTEGRATION TESTS: FAILED"
        exit 1
    fi
    echo ""

    # Run reliability tests
    echo "Running reliability tests..."
    if zig build test-reliability 2>&1; then
        echo "RELIABILITY TESTS: PASSED"
    else
        echo "RELIABILITY TESTS: FAILED"
        exit 1
    fi
    echo ""

    # Run continuous verification (subset for daily runs)
    echo "Running continuous verification cycle..."
    if zig build test-reliability -- --test-filter continuous 2>&1; then
        echo "CONTINUOUS VERIFICATION: PASSED"
    else
        echo "CONTINUOUS VERIFICATION: FAILED"
        exit 1
    fi
    echo ""

    # Run benchmarks
    echo "Running benchmarks..."
    if zig build bench 2>&1; then
        echo "BENCHMARKS: PASSED"
    else
        echo "BENCHMARKS: FAILED"
        exit 1
    fi
    echo ""

    # Run performance regression detection
    echo "Running performance regression detection..."
    if zig build test-reliability -- --test-filter "performance: regression" 2>&1; then
        echo "PERFORMANCE REGRESSION: PASSED"
    else
        echo "PERFORMANCE REGRESSION: FAILED"
        exit 1
    fi
    echo ""

    # Build FUSE driver to verify it compiles
    echo "Building FUSE driver..."
    if zig build fuse 2>&1; then
        echo "FUSE DRIVER BUILD: PASSED"
    else
        echo "FUSE DRIVER BUILD: FAILED"
        exit 1
    fi
    echo ""

    # Run FUSE integration tests
    echo "Running FUSE integration tests..."
    if zig build fuse-test 2>&1; then
        echo "FUSE INTEGRATION TESTS: PASSED"
    else
        echo "FUSE INTEGRATION TESTS: FAILED"
        exit 1
    fi
    echo ""

    # Run performance comparison vs ext3
    echo "Running performance comparison vs ext3..."
    if zig build perf-compare 2>&1; then
        echo "PERFORMANCE COMPARISON: PASSED (UFS >= ext3)"
    else
        echo "PERFORMANCE COMPARISON: FAILED (UFS < ext3 in majority)"
        exit 1
    fi
    echo ""

    echo "=== UFS Daily Verification Completed at $(date) ==="
    echo "All checks passed!"

} 2>&1 | tee "$LOG_FILE"

# Check exit status
if [ ${PIPESTATUS[0]} -eq 0 ]; then
    log_info "Daily verification completed successfully"
    log_info "Log saved to: $LOG_FILE"
else
    log_error "Daily verification failed"
    log_error "Log saved to: $LOG_FILE"
    exit 1
fi

# Cleanup old logs (keep 30 days)
find "$LOG_DIR" -name "verify_*.log" -mtime +30 -delete 2>/dev/null || true

log_info "Log cleanup complete (kept last 30 days)"