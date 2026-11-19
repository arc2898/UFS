# UFS v1.0 - Build & Test Guide

> **Status:** Experimental and not production-ready. Platform-driver source files and build scripts do not establish functional or safe filesystem support. Use disposable regular-file images only.

## Quick Start (WSL - Recommended for Linux/UEFI/FUSE)

```bash
# In WSL (Ubuntu 22.04+)
export UFS_ROOT="/path/to/UFS"  # replace with the actual checkout path
cd "$UFS_ROOT"
chmod +x scripts/wsl_setup.sh
./scripts/wsl_setup.sh

# After setup completes (restart shell or source ~/.bashrc)
source ~/.bashrc

# Run integration tests
chmod +x scripts/test_ufs.sh
./scripts/test_ufs.sh
```

## Windows Build (Native)

```powershell
# In PowerShell as Administrator
cd <path-to-UFS>
Set-ExecutionPolicy Bypass -Scope Process -Force
.\scripts\windows_setup.ps1

# Then in VS Developer Command Prompt:
cd core\zig\drivers\windows
nmake /f Makefile
candle.exe ufs.wxs
light.exe ufs.wixobj -ext WixUIExtension -o ufs.msi
```

## macOS Build (On Mac)

```bash
# On macOS 13+ with Xcode
cd /path/to/UFS/core/zig/drivers/macos
chmod +x build_macos.sh
./build_macos.sh release all
```

## What Each Script Does

### `scripts/wsl_setup.sh` (Linux/WSL)
- Installs all system packages (build-essential, fuse3, dkms, qemu, ovmf, etc.)
- Downloads and installs Zig 0.13.0
- Clones and builds EDK2 (for UEFI driver + OVMF)
- Builds UFS Zig core library (`libufs_core.a`)
- Builds FUSE driver (`ufs-fuse`)
- Builds UEFI driver (`UFS.efi`) via EDK2
- Builds and installs Linux DKMS kernel module
- Creates 512MB test disk image formatted with UFS

### `scripts/windows_setup.ps1` (Windows)
- Installs Chocolatey, Zig, Git, CMake, Visual Studio Build Tools, Windows SDK, WiX
- Builds UFS Zig core library (`libufs_core.lib`)
- Prepares Windows driver build directory with headers and library
- Documents WDK installation (manual from Microsoft)
- Documents test signing vs production EV certificate signing

### `scripts/test_ufs.sh` (Integration Tests)
Runs 9 test suites:
1. **FUSE Mount/Unmount** - Basic mount verification
2. **Basic File Ops** - Create/read/write/delete, mkdir, symlinks, hardlinks, rename, xattrs
3. **Large File I/O** - 10MB and 100MB files
4. **Concurrent Access** - 10 parallel writers/readers
5. **Crash Recovery** - Kill -9 during write, remount, verify data integrity
6. **Stress Test** - 1000 files create/read/delete
7. **UEFI QEMU** - Boot test with OVMF
8. **Linux Kernel Module** - Mount via kernel driver
9. **Performance** - Run `ufs_perf_compare` benchmark

## Prerequisites

| Platform | Requirements |
|----------|--------------|
| **WSL** | Ubuntu 22.04+, 4GB+ RAM, 10GB+ disk |
| **Windows** | Windows 10/11, Admin rights, EV cert for production |
| **macOS** | macOS 13+ (Ventura), Xcode 15+, Apple Developer ID |
| **UEFI Test** | QEMU + OVMF (built by wsl_setup.sh) |

## Key Outputs After Build

| Artifact | Location | Use |
|----------|----------|-----|
| Zig Core Lib | `core/zig/zig-out/lib/libufs_core.a` | Link into all drivers |
| FUSE Driver | `core/zig/zig-out/bin/ufs-fuse` | Linux/macOS user-space mount |
| UEFI Driver | `core/zig/drivers/uefi/output/UFS.efi` | Bootloader, EFI shell |
| Linux DKMS | `/lib/modules/$(uname -r)/kernel/fs/ufs/ufs.ko` | Kernel mount |
| Windows Driver | `core/zig/drivers/windows/ufs.sys` | IFS kernel driver |
| Windows MSI | `core/zig/drivers/windows/ufs.msi` | Installer |
| macOS FileProvider | `core/zig/drivers/macos/.build/release/UFSFileProvider` | FileProvider extension |
| Test Image | `~/ufs_test.img` | 512MB UFS formatted image |

## Troubleshooting

### Zig Build Fails
```bash
# Check Zig version
zig version
# Should be 0.13.0

# Clean rebuild
cd core/zig
rm -rf zig-out .zig-cache
zig build -Doptimize=ReleaseFast
```

### FUSE Mount Fails
```bash
# Check FUSE3 installed
pkg-config --libs fuse3

# Allow user mounts
echo "user_allow_other" | sudo tee -a /etc/fuse.conf
# Then mount with: -o allow_other
```

### DKMS Build Fails
```bash
# Check kernel headers
ls /lib/modules/$(uname -r)/build

# Rebuild
sudo dkms remove ufs/1.0.0 --all
sudo dkms add "$UFS_ROOT/core/zig/drivers/linux"
sudo dkms build ufs/1.0.0
sudo dkms install ufs/1.0.0
```

### UEFI QEMU Hangs
```bash
# Increase timeout, check OVMF path
ls ~/edk2/Build/OvmfX64/DEBUG_GCC5/FV/OVMF.fd

# Debug with serial output
qemu-system-x86_64 -bios OVMF.fd -drive file=test.img,format=raw -serial stdio -display none
```

### Windows Driver Signing
```powershell
# Test signing (dev only)
bcdedit /set testsigning on
# Restart

# Production signing (requires EV cert from DigiCert/Sectigo/GlobalSign)
signtool sign /v /ac cross.cer /s My /n "Your Company" /tr http://timestamp.digicert.com /td sha256 /fd sha256 ufs.sys
```

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                    UFS Zig Core (95% shared)                 │
├─────────────────────────────────────────────────────────────┤
│  Journal/Recovery  │  Allocation Groups  │  Directories     │
│  Metadata Capsules │  Compression        │  Integrity       │
│  Version/Features  │  Block Device       │  Crypto          │
└─────────────────────────────────────────────────────────────┘
                              │
          ┌───────────────────┼───────────────────┐
          ▼                   ▼                   ▼
    ┌───────────┐       ┌───────────┐       ┌───────────┐
    │   FUSE    │       │  Linux    │       │  Windows  │
    │ (user)    │       │  VFS (K)  │       │  IFS (K)  │
    └───────────┘       └───────────┘       └───────────┘
          │                   │                   │
          ▼                   ▼                   ▼
    ┌───────────────────────────────────────────────────────┐
    │                    Block Device                        │
    │  (file, /dev/sdX, NVMe, virtio, EFI_BLOCK_IO, etc.)   │
    └───────────────────────────────────────────────────────┘
```

## Performance Targets (vs ext4/XFS/ZFS/btrfs/NTFS/ReFS/APFS)

| Metric | Target |
|--------|--------|
| Sequential Read | ≥ 95% of raw device |
| Sequential Write | ≥ 90% of raw device |
| Random Read (4K) | ≥ 80% of ext4 |
| Random Write (4K) | ≥ 85% of ext4 |
| Metadata Ops (create/unlink) | ≤ 1.2x ext4 |
| Mount Time | < 500ms on 1TB |
| Recovery Time | < 2s typical |

## Next Steps After Successful Build

1. **Real Hardware Test** - Format USB drive: `mkufs -l "USB" -c 4096 /dev/sdX`
2. **Cross-FS Benchmark** - Run `perf-compare` against ext4/XFS/NTFS
3. **Long-Running Stress** - Run `test_ufs.sh` overnight
4. **UEFI Boot Test** - Copy `UFS.efi` to ESP as `BOOTX64.EFI`
5. **Windows Install** - Run MSI, format drive, verify in Explorer
6. **macOS Test** - Install FileProvider + Kext, mount in Finder