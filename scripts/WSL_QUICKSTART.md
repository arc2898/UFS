# UFS WSL Quickstart Guide

## Prerequisites
- Windows 10/11 with WSL 2
- Debian WSL distribution installed
- Administrator PowerShell for Windows setup

## Quick Start (Run in Debian WSL)

```bash
# 1. Navigate to UFS project
cd "$UFS_ROOT"  # set UFS_ROOT to the checkout directory first

# 2. Make scripts executable
chmod +x scripts/wsl_setup.sh
chmod +x scripts/test_ufs.sh

# 3. Run full setup (installs Zig, EDK2, builds everything)
./scripts/wsl_setup.sh

# 4. Reload shell for PATH changes
source ~/.bashrc

# 5. Run integration tests
./scripts/test_ufs.sh
```

## What Gets Built

| Component | Output Location |
|-----------|-----------------|
| Zig Core Library | `core/zig/zig-out/lib/libufs_core.a` |
| mkufs | `core/zig/zig-out/bin/mkufs` |
| ufsck | `core/zig/zig-out/bin/ufsck` |
| ufsinfo | `core/zig/zig-out/bin/ufsinfo` |
| ufsctl | `core/zig/zig-out/bin/ufsctl` |
| FUSE Driver | `core/zig/zig-out/bin/ufs-fuse` |
| UEFI Driver | `core/zig/drivers/uefi/output/UFS.efi` |
| Linux DKMS Module | `/lib/modules/$(uname -r)/kernel/fs/ufs/ufs.ko` |

## Test Suite Coverage (11 Tests)

1. **FUSE Mount/Unmount** - Basic mount verification
2. **Basic File Ops** - CRUD, symlinks, hardlinks, xattrs, permissions
3. **Large File I/O** - 10MB, 100MB files
4. **Concurrent Access** - Multi-threaded read/write
5. **Process-Termination Recovery Smoke Test** - SIGKILL + remount (not a power-loss durability test)
6. **Stress Test** - 1000 files create/read/delete
7. **UEFI QEMU** - Boot test with OVMF
8. **Linux Kernel Module** - Native VFS mount test
9. **Performance Benchmark** - vs ext4/XFS
10. **FUSE Comprehensive** - Intended operation coverage; verify actual coverage against the driver before relying on it
11. **FUSE Edge Cases** - Sparse files, unlink-open, offsets

## Linux Kernel Module (DKMS)

The DKMS module source advertises the following intended capabilities; none should be considered production-ready until the module builds, loads, and passes kernel/filesystem stress and crash testing:
- Full VFS implementation (inode, file, dir, super operations)
- All 16 metadata capsule namespaces
- Journal recovery on mount
- Compression (LZ4/ZSTD)
- CRC32C + BLAKE3 integrity
- Per-extent compression with entropy detection

### Manual DKMS Commands

```bash
# Add module to DKMS
sudo dkms add "$UFS_ROOT/core/zig/drivers/linux"

# Build for current kernel
sudo dkms build ufs/1.0.0

# Install
sudo dkms install ufs/1.0.0

# Load module
sudo modprobe ufs

# Verify
lsmod | grep ufs
dmesg | grep -i ufs
```

### Kernel Module Testing

```bash
# Create test image
dd if=/dev/zero of=/tmp/ufs_test.img bs=1M count=512
~/ufs_test.img

# Format
"$UFS_ROOT/core/zig/zig-out/bin/mkufs" -l "TEST" -c 4096 /tmp/ufs_test.img

# Mount via kernel
mkdir -p /mnt/ufs_test
sudo mount -t ufs /tmp/ufs_test.img /mnt/ufs_test

# Test
echo "kernel test" | sudo tee /mnt/ufs_test/kernel.txt
cat /mnt/ufs_test/kernel.txt

# Unmount
sudo umount /mnt/ufs_test
```

## FUSE Driver Testing

```bash
# Mount
mkdir -p /mnt/ufs_fuse
"$UFS_ROOT/core/zig/zig-out/bin/ufs-fuse" /tmp/ufs_test.img /mnt/ufs_fuse -o rw,debug -f

# In another terminal, test
echo "fuse test" > /mnt/ufs_fuse/fuse.txt
cat /mnt/ufs_fuse/fuse.txt

# Unmount
fusermount -u /mnt/ufs_fuse
```

## UEFI Driver Testing (QEMU)

```bash
cd "$UFS_ROOT"  # set UFS_ROOT to the checkout directory first/core/zig/drivers/uefi
./build_uefi.sh release test
```

## Troubleshooting

### FUSE Permission Denied
```bash
# Add user to fuse group (run once)
sudo usermod -a -G fuse $USER
# Then logout/login or:
newgrp fuse
```

### DKMS Build Fails
```bash
# Check kernel headers
sudo apt-get install linux-headers-$(uname -r)

# Check config
sudo "$UFS_ROOT/core/zig/drivers/linux"/config_check
```

### Zig Build Fails
```bash
# Clean and rebuild
cd "$UFS_ROOT"  # set UFS_ROOT to the checkout directory first/core/zig
rm -rf zig-out
~/.local/zig/zig build -Doptimize=ReleaseFast
```

### UEFI Build Fails
```bash
# Rebuild EDK2 BaseTools
cd ~/edk2
make -C BaseTools clean
make -C BaseTools
source EdkSetup.sh
build -p OvmfPkg/OvmfPkgX64.dsc -a X64 -t GCC5 -b DEBUG
```

## Windows Setup (Optional - for IFS driver)

Run in Administrator PowerShell:
```powershell
# Enable test signing for driver development
bcdedit /set testsigning on

# Install WiX for MSI creation
winget install WiXToolset.WiX

# Run Windows setup
.\scripts\windows_setup.ps1
```

## Real Hardware Testing

After all tests pass in WSL:

```bash
# Find USB device
lsblk

# Format USB (REPLACE /dev/sdX WITH YOUR DEVICE)
sudo "$UFS_ROOT/core/zig/zig-out/bin/mkufs" -l "USBTEST" -c 4096 /dev/sdX

# Mount and test
sudo mount -t ufs /dev/sdX /mnt/usb_test
# or
sudo "$UFS_ROOT/core/zig/zig-out/bin/ufs-fuse" /dev/sdX /mnt/usb_test -o rw
```

## Architecture Notes

### Shared Zig Core (architecture goal: high code reuse)
```
core/zig/src/
├── journal.zig       # Logical redo journal + recovery
├── c_api.zig         # Thread-safe C API (no globals)
├── version.zig       # VolumeFormat + on-disk layout
├── alloc.zig         # Hybrid B+tree + bitmap allocator
├── dir.zig           # Hybrid directories (array + B+tree)
├── xattr.zig         # 16 namespace metadata capsules
├── compress.zig      # LZ4/ZSTD + entropy detection
├── integrity.zig     # CRC32C (metadata) + BLAKE3 (data)
├── block.zig         # Block device abstraction
└── ufs.zig           # Main filesystem logic
```

### Platform Drivers (5% each)
```
core/zig/drivers/
├── linux/ufs_linux.c      # Linux VFS (DKMS)
├── fuse/ufs_fuse.c        # FUSE 3 (userspace)
├── windows/ufs_ifs.c      # Windows IFS (kernel)
├── uefi/*.c               # UEFI Boot Services
└── macos/UFSFileProvider  # macOS FileProvider
```

## Next Steps After Testing

1. **Real hardware**: Test on USB/NVMe
2. **Benchmarks**: Run `zig build perf-compare` in core/zig
3. **Windows IFS**: Build with WiX + EV cert
4. **macOS**: Build FileProvider extension
5. **CI/CD**: Set up GitHub Actions for multi-platform builds

## Support

- Check `BUILD_README.md` for detailed build instructions
- Check `docs/architecture/UFS-COMPARISON.md` for design rationale
- Check `docs/specifications/UFS-FORMAT-V1.md` for on-disk format