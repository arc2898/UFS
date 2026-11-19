#!/bin/bash
# UFS Linux Kernel Module Build Script
# Builds the kernel module and installs it
# Usage: ./build_linux.sh [debug|release] [clean|install|dkms|package]

set -euo pipefail

BUILD_TYPE="${1:-release}"
ACTION="${2:-build}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ZIG_DIR="$SCRIPT_DIR/../zig"
KDIR="/lib/modules/$(uname -r)/build"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check kernel headers
check_kernel_headers() {
    if [[ ! -d "$KDIR/include/linux" ]]; then
        log_error "Kernel headers not found at $KDIR"
        log_info "Install with: sudo apt-get install linux-headers-$(uname -r)"
        exit 1
    fi
}

# Build Zig core library
build_zig_core() {
    log_info "Building Zig core library for Linux..."
    cd "$ZIG_DIR"

    local target="x86_64-linux-gnu.2.17"
    if [[ "$BUILD_TYPE" == "debug" ]]; then
        zig build -Dtarget="$target" -Doptimize=Debug -Dstrip=false
    else
        zig build -Dtarget="$target" -Doptimize=ReleaseFast -Dstrip=true
    fi

    local lib_path="$ZIG_DIR/zig-out/lib/libufs_core.a"
    if [[ ! -f "$lib_path" ]]; then
        log_error "Zig core library not found at $lib_path"
        exit 1
    fi

    # Copy to kernel module directory
    cp "$lib_path" "$SCRIPT_DIR/"

    log_info "Zig core library built: $lib_path"
}

# Build kernel module
build_module() {
    log_info "Building UFS kernel module..."
    cd "$SCRIPT_DIR"
    check_kernel_headers

    local make_flags="KDIR=$KDIR"
    if [[ "$BUILD_TYPE" == "debug" ]]; then
        make_flags+=" debug"
    else
        make_flags+=" release"
    fi

    make $make_flags

    if [[ ! -f "ufs.ko" ]]; then
        log_error "Kernel module not built"
        exit 1
    fi

    log_info "Kernel module built: ufs.ko"
}

# Install module
install_module() {
    log_info "Installing UFS kernel module..."
    cd "$SCRIPT_DIR"
    check_kernel_headers

    make KDIR="$KDIR" install

    log_info "Module installed. Run 'sudo modprobe ufs' to load."
}

# Uninstall module
uninstall_module() {
    log_info "Uninstalling UFS kernel module..."
    cd "$SCRIPT_DIR"
    make KDIR="$KDIR" uninstall
    log_info "Module uninstalled"
}

# DKMS installation
dkms_install() {
    log_info "Installing via DKMS..."
    cd "$SCRIPT_DIR"

    local version="1.0.0"
    if [[ -f VERSION ]]; then
        version=$(cat VERSION)
    fi

    # Create DKMS source tree
    local dkms_dir="/usr/src/ufs-$version"
    sudo mkdir -p "$dkms_dir"
    sudo cp -r . "$dkms_dir/"
    sudo rm -f "$dkms_dir/ufs.ko" "$dkms_dir/*.o" "$dkms_dir/*.mod.c" "$dkms_dir/Module.symvers"

    # Create dkms.conf
    sudo tee "$dkms_dir/dkms.conf" > /dev/null <<EOF
PACKAGE_NAME="ufs"
PACKAGE_VERSION="$version"
BUILT_MODULE_NAME="ufs"
DEST_MODULE_LOCATION="/kernel/fs/ufs"
AUTOINSTALL="yes"
MAKE[0]="'make' KDIR=/lib/modules/\${kernelver}/build"
CLEAN="make clean"
EOF

    sudo dkms add -m ufs -v "$version"
    sudo dkms build -m ufs -v "$version"
    sudo dkms install -m ufs -v "$version"

    log_info "DKMS installation complete"
}

# Create Debian package
package_deb() {
    log_info "Creating Debian package..."
    cd "$SCRIPT_DIR"

    local version="1.0.0"
    local arch="amd64"
    local pkg_dir="build/pkg"
    local pkg_name="ufs-dkms_${version}-1_${arch}"

    rm -rf "$pkg_dir"
    mkdir -p "$pkg_dir"/{DEBIAN,usr/src/ufs-$version}

    # Copy source
    cp -r . "$pkg_dir/usr/src/ufs-$version/"
    rm -f "$pkg_dir/usr/src/ufs-$version/ufs.ko" "$pkg_dir/usr/src/ufs-$version/*.o"

    # Create control file
    cat > "$pkg_dir/DEBIAN/control" <<EOF
Package: ufs-dkms
Version: $version-1
Architecture: $arch
Maintainer: UFS Project <ufs@example.com>
Description: UFS (Universal Filesystem) kernel module
 UFS is a cross-platform filesystem with Metadata Capsules,
 logical redo journaling, and per-extent compression.
Depends: dkms, linux-headers-generic | linux-headers-\$(uname -r)
Section: kernel
Priority: optional
EOF

    # Create postinst
    cat > "$pkg_dir/DEBIAN/postinst" <<'EOF'
#!/bin/bash
set -e
dkms add -m ufs -v 1.0.0
dkms build -m ufs -v 1.0.0
dkms install -m ufs -v 1.0.0
depmod -a
EOF
    chmod +x "$pkg_dir/DEBIAN/postinst"

    # Create prerm
    cat > "$pkg_dir/DEBIAN/prerm" <<'EOF'
#!/bin/bash
set -e
dkms remove -m ufs -v 1.0.0 --all
depmod -a
EOF
    chmod +x "$pkg_dir/DEBIAN/prerm"

    dpkg-deb --build "$pkg_dir" "${pkg_name}.deb"
    log_info "Debian package created: ${pkg_name}.deb"
}

# Create RPM package
package_rpm() {
    log_info "Creating RPM package..."
    cd "$SCRIPT_DIR"

    local version="1.0.0"
    local rpm_dir="build/rpm"
    mkdir -p "$rpm_dir"/{SOURCES,SPECS,BUILD,RPMS,SRPMS}

    # Create source tarball
    tar czf "$rpm_dir/SOURCES/ufs-$version.tar.gz" --exclude="build" --exclude=".git" .

    # Create spec file
    cat > "$rpm_dir/SPECS/ufs-dkms.spec" <<EOF
Name:           ufs-dkms
Version:        $version
Release:        1%{?dist}
Summary:        UFS (Universal Filesystem) kernel module
License:        MIT
URL:            https://github.com/ufs-project/ufs
Source0:        ufs-$version.tar.gz
BuildArch:      noarch
Requires:       dkms, kernel-devel

%description
UFS is a cross-platform filesystem with Metadata Capsules,
logical redo journaling, and per-extent compression.

%prep
%autosetup -n ufs-$version

%build
# Build happens at install time via DKMS

%install
mkdir -p %{buildroot}/usr/src/ufs-%{version}
cp -r * %{buildroot}/usr/src/ufs-%{version}/
rm -f %{buildroot}/usr/src/ufs-%{version}/ufs.ko

%post
dkms add -m ufs -v %{version}
dkms build -m ufs -v %{version}
dkms install -m ufs -v %{version}
depmod -a

%preun
dkms remove -m ufs -v %{version} --all
depmod -a

%files
/usr/src/ufs-%{version}
EOF

    rpmbuild --define "_topdir $rpm_dir" -ba "$rpm_dir/SPECS/ufs-dkms.spec"
    log_info "RPM package created in $rpm_dir/RPMS"
}

# Clean
clean_all() {
    log_info "Cleaning build artifacts..."
    cd "$SCRIPT_DIR"
    make KDIR="$KDIR" clean
    rm -rf build/
    rm -f libufs_core.a
    log_info "Clean complete"
}

# Main
main() {
    log_info "UFS Linux Kernel Module Build Script"
    log_info "Build type: $BUILD_TYPE"
    log_info "Action: $ACTION"

    case "$ACTION" in
        build)
            build_zig_core
            build_module
            ;;
        install)
            build_zig_core
            build_module
            install_module
            ;;
        uninstall)
            uninstall_module
            ;;
        dkms)
            build_zig_core
            dkms_install
            ;;
        deb)
            build_zig_core
            package_deb
            ;;
        rpm)
            build_zig_core
            package_rpm
            ;;
        clean)
            clean_all
            ;;
        all)
            build_zig_core
            build_module
            install_module
            ;;
        *)
            log_error "Unknown action: $ACTION"
            echo "Usage: $0 [debug|release] [build|install|uninstall|dkms|deb|rpm|clean|all]"
            exit 1
            ;;
    esac
}

main "$@"