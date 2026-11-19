Name:           ufs-dkms
Version:        1.0.0
Release:        1%{?dist}
Summary:        UFS (Universal Filesystem) kernel module - DKMS source

License:        MIT
URL:            https://github.com/ufs-project/ufs
Source0:        ufs-%{version}.tar.gz

BuildArch:      noarch
BuildRequires:  dkms, kernel-devel, kernel-headers
Requires:       dkms, kernel-devel

%description
UFS (Universal Filesystem) is a cross-platform filesystem designed for
Windows, Linux, macOS, and UEFI environments. It features Metadata
Capsules for lossless cross-platform metadata preservation, logical
redo journaling, per-extent compression (LZ4/ZSTD), and dual-layer
integrity (CRC32C metadata + BLAKE3 data).

This package contains the DKMS source for building the UFS kernel
module automatically for each installed kernel.

%prep
%autosetup -n ufs-%{version}

%build
# Build happens at install time via DKMS
# We just verify the source is valid
test -f Makefile
test -f dkms.conf
test -f ufs_linux.c

%install
# Create DKMS source tree
mkdir -p %{buildroot}/usr/src/ufs-%{version}
cp -r * %{buildroot}/usr/src/ufs-%{version}/
# Remove build artifacts
rm -f %{buildroot}/usr/src/ufs-%{version}/ufs.ko
rm -f %{buildroot}/usr/src/ufs-%{version}/*.o
rm -f %{buildroot}/usr/src/ufs-%{version}/*.mod.c
rm -f %{buildroot}/usr/src/ufs-%{version}/Module.symvers
rm -rf %{buildroot}/usr/src/ufs-%{version}/.tmp_versions
rm -rf %{buildroot}/usr/src/ufs-%{version}/build

# Fix dkms.conf version
sed -i "s/@VERSION@/%{version}/g" %{buildroot}/usr/src/ufs-%{version}/dkms.conf

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

%changelog
* Thu Nov 14 2024 UFS Project <ufs@example.com> - 1.0.0-1
- Initial DKMS package for UFS filesystem