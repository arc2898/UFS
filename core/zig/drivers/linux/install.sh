#!/bin/bash
# UFS Universal Linux Installer
# Detects distribution and installs UFS kernel module via DKMS
# Usage: sudo ./install.sh [options]

set -euo pipefail

VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="${SCRIPT_DIR}"

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

usage() {
    cat <<EOF
UFS Universal Linux Installer v${VERSION}

Usage: sudo $0 [OPTIONS]

Options:
    --dkms              Install via DKMS (default, recommended)
    --package           Build and install distribution package (deb/rpm)
    --module-sign       Sign kernel module for Secure Boot
    --sign-key PATH     Path to signing private key
    --sign-cert PATH    Path to signing certificate
    --kernel KERNEL     Target kernel version (default: running kernel)
    --force             Skip confirmation prompts
    --uninstall         Remove UFS module
    --help              Show this help

Examples:
    sudo $0                      # Install via DKMS
    sudo $0 --package            # Build .deb/.rpm and install
    sudo $0 --module-sign --sign-key key.priv --sign-cert key.x509
    sudo $0 --uninstall          # Remove completely

Supported distributions:
    - Ubuntu/Debian/Mint (DKMS, .deb)
    - Fedora/RHEL/CentOS/Rocky/Alma (DKMS, .rpm)
    - Arch/Manjaro (DKMS, PKGBUILD)
    - openSUSE (DKMS)
    - Gentoo (DKMS)
    - Any with DKMS support

EOF
}

# Detect Linux distribution
detect_distro() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        DISTRO_ID="${ID}"
        DISTRO_VERSION="${VERSION_ID}"
        DISTRO_NAME="${PRETTY_NAME}"
    elif [[ -f /etc/redhat-release ]]; then
        DISTRO_ID="rhel"
        DISTRO_NAME="$(cat /etc/redhat-release)"
    elif [[ -f /etc/arch-release ]]; then
        DISTRO_ID="arch"
        DISTRO_NAME="Arch Linux"
    else
        DISTRO_ID="unknown"
        DISTRO_NAME="Unknown Linux"
    fi

    log_info "Detected: ${DISTRO_NAME} (${DISTRO_ID})"
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

# Check DKMS is installed
check_dkms() {
    if ! command -v dkms &> /dev/null; then
        log_error "DKMS not installed. Installing..."
        install_dkms
    fi
    log_info "DKMS version: $(dkms --version)"
}

# Install DKMS based on distribution
install_dkms() {
    case "${DISTRO_ID}" in
        ubuntu|debian|linuxmint|pop|elementary|zorin)
            apt-get update && apt-get install -y dkms build-essential linux-headers-$(uname -r)
            ;;
        fedora|rhel|centos|rocky|almalinux)
            dnf install -y dkms kernel-devel-$(uname -r) kernel-headers-$(uname -r) gcc make
            ;;
        arch|manjaro|endeavouros|garuda)
            pacman -Sy --needed dkms linux-headers
            ;;
        opensuse*|sles)
            zypper install -y dkms kernel-devel kernel-default-devel gcc make
            ;;
        gentoo)
            emerge --ask sys-kernel/dkms
            ;;
        *)
            log_error "Unsupported distribution for automatic DKMS install: ${DISTRO_ID}"
            log_info "Please install DKMS manually and re-run"
            exit 1
            ;;
    esac
}

# Check kernel headers
check_kernel_headers() {
    local kernel_ver="${TARGET_KERNEL:-$(uname -r)}"
    local headers_dir="/lib/modules/${kernel_ver}/build"

    if [[ ! -d "${headers_dir}/include/linux" ]]; then
        log_error "Kernel headers not found for ${kernel_ver}"
        log_info "Install with:"
        case "${DISTRO_ID}" in
            ubuntu|debian|linuxmint|pop|elementary|zorin)
                echo "  apt-get install linux-headers-${kernel_ver}"
                ;;
            fedora|rhel|centos|rocky|almalinux)
                echo "  dnf install kernel-devel-${kernel_ver} kernel-headers-${kernel_ver}"
                ;;
            arch|manjaro|endeavouros|garuda)
                echo "  pacman -S linux-headers"
                ;;
            opensuse*|sles)
                echo "  zypper install kernel-devel kernel-default-devel"
                ;;
        esac
        exit 1
    fi
    log_info "Kernel headers found: ${headers_dir}"
}

# Build Zig core library
build_zig_core() {
    log_step "Building Zig core library..."
    cd "${SOURCE_DIR}/../../zig"

    if [[ ! -f "build.zig" ]]; then
        log_error "Zig source not found at ${SOURCE_DIR}/../../zig"
        exit 1
    fi

    zig build -Dtarget=x86_64-linux-gnu.2.17 -Doptimize=ReleaseFast -Dstrip=true

    if [[ ! -f "zig-out/lib/libufs_core.a" ]]; then
        log_error "Zig core library build failed"
        exit 1
    fi

    # Copy to driver directory
    cp zig-out/lib/libufs_core.a "${SOURCE_DIR}/"
    log_info "Zig core library built and copied"
}

# Install via DKMS
install_dkms_module() {
    log_step "Installing via DKMS..."

    local version="${VERSION}"
    local dkms_dir="/usr/src/ufs-${version}"

    # Create DKMS source directory
    mkdir -p "${dkms_dir}"

    # Copy source files
    rsync -a "${SOURCE_DIR}/" "${dkms_dir}/" \
        --exclude='.git' \
        --exclude='build' \
        --exclude='*.ko' \
        --exclude='*.o' \
        --exclude='*.mod.c' \
        --exclude='Module.symvers' \
        --exclude='.tmp_versions'

    # Fix dkms.conf version
    sed -i "s/@VERSION@/${version}/g" "${dkms_dir}/dkms.conf"

    # Add module signing if requested
    if [[ -n "${SIGN_KEY}" && -n "${SIGN_CERT}" ]]; then
        log_info "Configuring module signing..."
        cat >> "${dkms_dir}/dkms.conf" <<EOF

# Module signing for Secure Boot
MODULE_SIG_KEY="${SIGN_KEY}"
MODULE_SIG_CERT="${SIGN_CERT}"
EOF
    fi

    # Add to DKMS
    log_info "Adding to DKMS..."
    dkms add -m ufs -v "${version}"

    # Build
    log_info "Building module..."
    if [[ -n "${TARGET_KERNEL}" ]]; then
        dkms build -m ufs -v "${version}" -k "${TARGET_KERNEL}"
    else
        dkms build -m ufs -v "${version}"
    fi

    # Install
    log_info "Installing module..."
    if [[ -n "${TARGET_KERNEL}" ]]; then
        dkms install -m ufs -v "${version}" -k "${TARGET_KERNEL}"
    else
        dkms install -m ufs -v "${version}"
    fi

    depmod -a

    log_info "DKMS installation complete"
    log_info "Module will auto-rebuild on kernel updates"
}

# Build distribution package
build_package() {
    log_step "Building distribution package..."

    case "${DISTRO_ID}" in
        ubuntu|debian|linuxmint|pop|elementary|zorin)
            build_deb
            ;;
        fedora|rhel|centos|rocky|almalinux)
            build_rpm
            ;;
        arch|manjaro|endeavouros|garuda)
            build_arch
            ;;
        *)
            log_error "Package building not supported for ${DISTRO_ID}"
            log_info "Use --dkms instead"
            exit 1
            ;;
    esac
}

build_deb() {
    log_info "Building .deb package..."

    local pkg_dir="${SOURCE_DIR}/build/pkg"
    local pkg_name="ufs-dkms_${VERSION}-1_all"

    rm -rf "${pkg_dir}"
    mkdir -p "${pkg_dir}/DEBIAN"
    mkdir -p "${pkg_dir}/usr/src/ufs-${VERSION}"

    # Copy source
    rsync -a "${SOURCE_DIR}/" "${pkg_dir}/usr/src/ufs-${VERSION}/" \
        --exclude='.git' \
        --exclude='build' \
        --exclude='*.ko' \
        --exclude='*.o' \
        --exclude='*.mod.c' \
        --exclude='Module.symvers' \
        --exclude='.tmp_versions' \
        --exclude='debian' \
        --exclude='rpm' \
        --exclude='PKGBUILD'

    # Fix dkms.conf
    sed -i "s/@VERSION@/${VERSION}/g" "${pkg_dir}/usr/src/ufs-${VERSION}/dkms.conf"

    # Copy control file
    cp "${SOURCE_DIR}/debian/control" "${pkg_dir}/DEBIAN/"

    # Create postinst
    cat > "${pkg_dir}/DEBIAN/postinst" <<'EOF'
#!/bin/bash
set -e
dkms add -m ufs -v 1.0.0
dkms build -m ufs -v 1.0.0
dkms install -m ufs -v 1.0.0
depmod -a
EOF
    chmod +x "${pkg_dir}/DEBIAN/postinst"

    # Create prerm
    cat > "${pkg_dir}/DEBIAN/prerm" <<'EOF'
#!/bin/bash
set -e
dkms remove -m ufs -v 1.0.0 --all
depmod -a
EOF
    chmod +x "${pkg_dir}/DEBIAN/prerm"

    # Build package
    dpkg-deb --build "${pkg_dir}" "${SOURCE_DIR}/build/${pkg_name}.deb"

    log_info "Package built: ${SOURCE_DIR}/build/${pkg_name}.deb"
    log_info "Install with: dpkg -i ${pkg_name}.deb"
}

build_rpm() {
    log_info "Building .rpm package..."

    local rpm_dir="${SOURCE_DIR}/build/rpm"
    mkdir -p "${rpm_dir}"/{SOURCES,SPECS,BUILD,RPMS,SRPMS}

    # Create source tarball
    tar czf "${rpm_dir}/SOURCES/ufs-${VERSION}.tar.gz" \
        -C "${SOURCE_DIR}/.." \
        --exclude='.git' \
        --exclude='build' \
        --exclude='*.ko' \
        --exclude='*.o' \
        zig/drivers/linux

    # Copy spec
    cp "${SOURCE_DIR}/rpm/ufs-dkms.spec" "${rpm_dir}/SPECS/"

    # Build RPM
    rpmbuild --define "_topdir ${rpm_dir}" -ba "${rpm_dir}/SPECS/ufs-dkms.spec"

    log_info "RPM built in ${rpm_dir}/RPMS"
}

build_arch() {
    log_info "Building Arch package..."

    local pkg_dir="${SOURCE_DIR}/build/arch"
    rm -rf "${pkg_dir}"
    mkdir -p "${pkg_dir}"

    # Copy PKGBUILD
    cp "${SOURCE_DIR}/PKGBUILD" "${pkg_dir}/"

    # Build
    cd "${pkg_dir}"
    makepkg -f --skippgpcheck

    log_info "Arch package built in ${pkg_dir}"
}

# Uninstall
uninstall_module() {
    log_step "Uninstalling UFS module..."

    # Remove from DKMS
    if dkms status | grep -q "ufs/${VERSION}"; then
        dkms remove -m ufs -v "${VERSION}" --all
        log_info "Removed from DKMS"
    fi

    # Remove any manually installed modules
    local kernel_ver="${TARGET_KERNEL:-$(uname -r)}"
    local mod_path="/lib/modules/${kernel_ver}/kernel/fs/ufs/ufs.ko"
    if [[ -f "${mod_path}" ]]; then
        rm -f "${mod_path}"
        log_info "Removed module: ${mod_path}"
    fi

    depmod -a

    # Remove DKMS source
    rm -rf "/usr/src/ufs-${VERSION}"

    log_info "Uninstall complete"
}

# Verify installation
verify_install() {
    log_step "Verifying installation..."

    # Check module loads
    if modprobe ufs; then
        log_info "Module loads successfully"

        # Check version
        local mod_info=$(modinfo ufs | grep "^version:")
        log_info "Module info: ${mod_info}"

        # Remove test load
        modprobe -r ufs
    else
        log_error "Module failed to load"
        return 1
    fi

    # Check DKMS status
    if dkms status | grep -q "ufs/${VERSION}"; then
        log_info "DKMS registration confirmed"
    else
        log_warn "DKMS registration not found"
    fi

    log_info "Verification complete"
}

# Main
main() {
    local action="install"
    local method="dkms"
    local force=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --dkms)
                method="dkms"
                shift
                ;;
            --package)
                method="package"
                shift
                ;;
            --module-sign)
                MODULE_SIGN=true
                shift
                ;;
            --sign-key)
                SIGN_KEY="$2"
                shift 2
                ;;
            --sign-cert)
                SIGN_CERT="$2"
                shift 2
                ;;
            --kernel)
                TARGET_KERNEL="$2"
                shift 2
                ;;
            --force)
                force=true
                shift
                ;;
            --uninstall)
                action="uninstall"
                shift
                ;;
            --help)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done

    echo "=========================================="
    echo "  UFS Universal Linux Installer v${VERSION}"
    echo "=========================================="
    echo ""

    check_root
    detect_distro

    if [[ "${action}" == "uninstall" ]]; then
        if [[ "${force}" != true ]]; then
            read -p "This will remove UFS completely. Continue? (y/N): " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                log_info "Aborted"
                exit 0
            fi
        fi
        uninstall_module
        exit 0
    fi

    if [[ "${force}" != true ]]; then
        read -p "Install UFS kernel module via ${method}? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Aborted"
            exit 0
        fi
    fi

    check_dkms
    check_kernel_headers
    build_zig_core

    if [[ "${method}" == "dkms" ]]; then
        install_dkms_module
    else
        build_package
    fi

    verify_install

    echo ""
    echo "=========================================="
    log_info "UFS installation complete!"
    echo "=========================================="
    echo ""
    echo "Next steps:"
    echo "  1. Load module: modprobe ufs"
    echo "  2. Format volume: mkufs /dev/sdX -L \"MyVolume\""
    echo "  3. Mount: mount -t ufs /dev/sdX /mnt"
    echo ""
    echo "Module will auto-rebuild on kernel updates via DKMS"
}

main "$@"