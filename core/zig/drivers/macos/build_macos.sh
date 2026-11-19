#!/bin/bash
# UFS macOS Build Script
# Builds both Kernel Extension (FSKit) and FileProvider Extension
# Usage: ./build_macos.sh [debug|release] [clean]

set -euo pipefail

BUILD_TYPE="${1:-release}"
ACTION="${2:-build}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

# Build Zig core library first
build_zig_core() {
    log_info "Building Zig core library..."
    cd "$ZIG_DIR"

    if [[ "$BUILD_TYPE" == "debug" ]]; then
        zig build -Doptimize=Debug -Dstrip=false
    else
        zig build -Doptimize=ReleaseFast -Dstrip=true
    fi

    if [[ ! -f "$UFS_CORE_LIB" ]]; then
        log_error "Zig core library not found at $UFS_CORE_LIB"
        exit 1
    fi

    log_info "Zig core library built: $UFS_CORE_LIB"
}

# Build FileProvider Extension (Swift)
build_fileprovider() {
    log_info "Building FileProvider Extension..."
    cd "$SCRIPT_DIR"

    if [[ "$ACTION" == "clean" ]]; then
        swift package clean
        return
    fi

    local config_flag=""
    if [[ "$BUILD_TYPE" == "debug" ]]; then
        config_flag="--configuration debug"
    else
        config_flag="--configuration release"
    fi

    # Ensure zig library is available
    mkdir -p .build/artifacts
    cp "$UFS_CORE_LIB" .build/artifacts/

    swift build $config_flag

    log_info "FileProvider Extension built successfully"
}

# Build Kernel Extension (Xcode)
build_kext() {
    log_info "Building Kernel Extension (FSKit)..."
    cd "$SCRIPT_DIR/UFSKext"

    if [[ "$ACTION" == "clean" ]]; then
        xcodebuild clean -scheme UFSKext
        return
    fi

    local config="Release"
    if [[ "$BUILD_TYPE" == "debug" ]]; then
        config="Debug"
    fi

    # Copy zig library
    mkdir -p "../zig-out/lib"
    cp "$UFS_CORE_LIB" "../zig-out/lib/"

    xcodebuild \
        -scheme UFSKext \
        -configuration "$config" \
        -derivedDataPath "../build/kext" \
        CODE_SIGN_IDENTITY="" \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGNING_ALLOWED=NO \
        OTHER_LDFLAGS="-L../zig-out/lib -lufs_core" \
        HEADER_SEARCH_PATHS="../zig/src" \
        build

    log_info "Kernel Extension built successfully"
}

# Create distribution package
package() {
    log_info "Creating distribution package..."
    cd "$SCRIPT_DIR"

    local pkg_dir="build/pkg"
    rm -rf "$pkg_dir"
    mkdir -p "$pkg_dir"/{Library/Extensions,Library/FileProvider}

    # Copy built artifacts
    if [[ -f ".build/release/UFSFileProvider" ]]; then
        cp ".build/release/UFSFileProvider" "$pkg_dir/Library/FileProvider/"
    fi

    if [[ -d "build/kext/Build/Products/Release/UFSKext.kext" ]]; then
        cp -R "build/kext/Build/Products/Release/UFSKext.kext" "$pkg_dir/Library/Extensions/"
    fi

    # Create installer package
    pkgbuild \
        --root "$pkg_dir" \
        --identifier "com.ufs.filesystem" \
        --version "1.0.0" \
        --install-location "/" \
        "UFS-1.0.0.pkg"

    log_info "Package created: UFS-1.0.0.pkg"
}

# Sign artifacts (requires Apple Developer ID)
sign() {
    log_info "Signing artifacts..."

    if [[ -z "${DEVELOPER_ID}" ]]; then
        log_warn "DEVELOPER_ID not set, skipping signing"
        return
    fi

    # Sign FileProvider
    if [[ -f ".build/release/UFSFileProvider" ]]; then
        codesign --force --options runtime --sign "${DEVELOPER_ID}" \
            --entitlements Sources/UFSFileProvider/Resources/Entitlements.plist \
            ".build/release/UFSFileProvider"
    fi

    # Sign Kext
    if [[ -d "build/kext/Build/Products/Release/UFSKext.kext" ]]; then
        codesign --force --sign "${DEVELOPER_ID}" \
            "build/kext/Build/Products/Release/UFSKext.kext"
    fi

    log_info "Signing complete"
}

# Notarize (requires Apple ID and app-specific password)
notarize() {
    log_info "Submitting for notarization..."

    if [[ -z "${APPLE_ID}" || -z "${APP_PASSWORD}" ]]; then
        log_warn "APPLE_ID/APP_PASSWORD not set, skipping notarization"
        return
    fi

    xcrun notarytool submit "UFS-1.0.0.pkg" \
        --apple-id "${APPLE_ID}" \
        --password "${APP_PASSWORD}" \
        --team-id "${TEAM_ID}" \
        --wait

    xcrun stapler staple "UFS-1.0.0.pkg"

    log_info "Notarization complete"
}

# Main
main() {
    log_info "UFS macOS Build Script"
    log_info "Build type: $BUILD_TYPE"
    log_info "Action: $ACTION"

    case "$ACTION" in
        build)
            build_zig_core
            build_fileprovider
            build_kext
            package
            ;;
        clean)
            build_fileprovider
            build_kext
            rm -rf build/
            log_info "Clean complete"
            ;;
        sign)
            sign
            ;;
        notarize)
            notarize
            ;;
        all)
            build_zig_core
            build_fileprovider
            build_kext
            package
            sign
            notarize
            ;;
        *)
            log_error "Unknown action: $ACTION"
            echo "Usage: $0 [debug|release] [build|clean|sign|notarize|all]"
            exit 1
            ;;
    esac
}

main "$@"