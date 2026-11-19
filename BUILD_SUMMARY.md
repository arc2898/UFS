# UFS Filesystem - Engineering Status (Unverified / Experimental)

## Status and limitations

This repository is an experimental implementation, not a production-ready filesystem. The platform driver sources and feature lists below describe intended or partial work; their presence does not establish that they compile, mount, or pass conformance testing. No production-readiness claim should be made until reproducible builds, crash-injection tests, corruption recovery tests, and platform interoperability tests pass.

Encryption algorithms are currently fail-closed: AES-GCM, ChaCha20-Poly1305, AES-XTS, and file-key wrapping return `UnsupportedAlgorithm` until vetted implementations are integrated and verified against known-answer tests. Password-based key derivation remains separate from data encryption.

## Intended architecture
Shared-core and platform-driver goals include:
- **Linux VFS** (DKMS kernel module)
- **FUSE** (userspace, Linux/macOS/WSL)
- **Windows IFS** (kernel driver)
- **macOS FileProvider** (userspace)
- **UEFI** (boot driver + application)

## Core Architecture (Zig)

### Source Files: `core/zig/src/`

| File | Purpose | Key Features |
|------|---------|--------------|
| `journal.zig` | Logical redo journal | 18 operation types, checkpointing, full recovery with AG manager, merkle tree integrity |
| `c_api.zig` | Thread-safe C API | No global state, 60+ exported functions, all platform drivers use this |
| `version.zig` | Volume format | Complete on-disk layout, feature flags (INCOMPAT/COMPAT_RO/COMPAT_RW) |
| `allocation.zig` | Hybrid allocator | B+tree + bitmap, 1GB allocation groups, parallel allocation |
| `directory.zig` | Hybrid directories | Linear array (≤64 entries) + B+tree, case-insensitive with preservation |
| `xattr.zig` | Metadata capsules | 16 namespaces (POSIX, Windows, macOS, UFS internal, Opaque) |
| `compression.zig` | Per-extent compression | LZ4/ZSTD with entropy-based incompressible detection |
| `integrity.zig` | Dual-layer integrity | CRC32C (metadata, HW accelerated) + BLAKE3 (data, 256-bit SIMD) |
| `crypto.zig` | KDF scaffolding; data encryption disabled | AES-256-GCM, ChaCha20-Poly1305, AES-256-XTS identifiers only |
| `blockdev.zig` | Block abstraction | File-backed, virtio, NVMe, loop, UEFI BlockIo |
| `serialization.zig` | Canonical serialization | Little-endian, explicit widths, no padding, CRC32C per structure |
| `utils.zig` | Utilities | UUIDv7, timestamps, CRC32C, BLAKE3, endian helpers |

### Journal System (Implementation present; not yet independently validated)
- **Operation Types**: 18 types (CREATE_INODE through FALLOCATE)
- **Checkpointing**: `JournalWriter.checkpoint()` for atomic commits
- **Recovery**: `RecoveryEngine.recoverFull()` replays from last checkpoint with AG context
- **Verification**: `RecoveryEngine.verifyJournal()` validates CRC on all transactions
- **Merkle Tree**: BLAKE3 hash chain for transaction integrity
- **C API**: `ufs_needs_recovery()`, `ufs_recover()`, `ufs_verify_journal()`

### C API (Declared surface; thread-safety and ABI require validation)
```
ufs_format()          ufs_mount()           ufs_unmount()
ufs_sync()            ufs_statfs()          ufs_checkpoint()
ufs_create_inode()    ufs_lookup()          ufs_getattr()
ufs_setattr()         ufs_delete_inode()    ufs_unlink_dirent()
ufs_link_dirent()     ufs_opendir()         ufs_readdir()
ufs_closedir()        ufs_mkdir()           ufs_rmdir()
ufs_rename()          ufs_symlink()         ufs_readlink()
ufs_open()            ufs_close()           ufs_read()
ufs_write()           ufs_seek()            ufs_truncate()
ufs_fallocate()       ufs_fsync()           ufs_get_extents()
ufs_setxattr()        ufs_getxattr()        ufs_listxattr()
ufs_removexattr()     ufs_get_volume_uuid() ufs_set_volume_label()
ufs_get_volume_label() ufs_get_features()   ufs_set_feature()
ufs_scrub()           ufs_needs_recovery()  ufs_recover()
ufs_verify_journal()  ufs_set_compression() ufs_get_compression()
ufs_set_encryption()  ufs_strerror()        ufs_timestamp()
ufs_generate_uuidv7() ufs_crc32c()          ufs_blake3()
ufs_block_device_open() ufs_block_device_close()
```

## Platform Drivers

### Linux VFS (DKMS) - `core/zig/drivers/linux/`
| File | Description |
|------|-------------|
| `ufs_linux.c` | Complete VFS implementation (860+ lines) |
| `Kconfig` | Kernel config options (10 features) |
| `Makefile` | Build system with Zig core linking |
| `dkms.conf` | DKMS packaging for all distros |
| `config_check` | Pre-build kernel compatibility checker |
| `VERSION` | 1.0.0 |

**VFS Operations Implemented:**
- Super: mount, kill_sb, statfs, sync_fs, freeze, unfreeze, remount, show_options
- Inode: alloc, free, write, evict, iget (with capsule loading)
- File: open, release, read, write, llseek, fsync, ioctl (flags, version, compression)
- Dir: lookup, create, mkdir, rmdir, unlink, rename, link, symlink, get_link
- Xattr: get, set, list (all 16 namespaces via capsules)
- Address space: readpage, readpages, writepage, writepages, bmap, direct_IO
- Module params: read_only, case_insensitive, compression, integrity_check, journal_size

### FUSE Driver - `core/zig/drivers/fuse/ufs_fuse.c`
- **libfuse3** compatible (FUSE_USE_VERSION 35)
- 22 operations: getattr, readdir, open, read, write, release, mkdir, rmdir, unlink, rename, create, truncate, utimens, statfs, init, destroy, fsync, setxattr, getxattr, listxattr, removexattr, symlink, readlink, link
- Permission checks (uid/gid/other)
- Mount options: ro/rw, uid/gid/umask, compression, integrity
- Auto-recovery on mount
- Thread-safe via fuse_context private_data

### Windows IFS - `core/zig/drivers/windows/`
| File | Description |
|------|-------------|
| `ufs_ifs.c` | Installable File System driver |
| `ufs_fsd.c` | File System Driver core |
| `ufs_metadata.c` | Metadata capsule handling |
| `ufs_ioctl.c` | FSCTL/IOCTL interface |
| `Makefile` | Build with WiX for MSI |

### UEFI Driver - `core/zig/drivers/uefi/`
| File | Description |
|------|-------------|
| `UFS.dsc` | EDK2 package definition |
| `UFS.inf` | Module definition (DXE_DRIVER) |
| `ufs_uefi.c` | Full C implementation (750+ lines) |
| `UfsBlockIo.c` | Block I/O Protocol |
| `UfsSimpleFs.c` | Simple File System Protocol |
| `UfsFileProtocol.c` | File Protocol (read/write/open/close/delete/getinfo/setinfo/flush) |
| `UfsDevicePath.c` | Device Path Protocol |
| `UfsRecovery.c` | UEFI recovery engine |
| `UfsBootLoader.c` | Boot loader (\EFI\BOOT\BOOTX64.EFI) |
| `UfsCoreWrapper.c` | Zig core integration |
| `build_uefi.sh` | Build script (debug/release/test/package) |
| `main.zig` | Architecture definition |

**UEFI Protocols Implemented:**
- Driver Binding (Supported/Start/Stop)
- Block I/O (ReadBlocks/WriteBlocks/FlushBlocks)
- Disk I/O (ReadDisk/WriteDisk)
- Simple File System (OpenVolume)
- File Protocol (Open/Close/Delete/Read/Write/GetPosition/SetPosition/GetInfo/SetInfo/Flush)
- Device Path
- Component Name 2
- Load File 2 (for boot)
- HII Config Access (setup menu)

### macOS FileProvider - `core/zig/drivers/macos/UFSFileProvider.swift`
- FileProviderExtension for Finder integration
- NSFileProviderEnumerator for directory enumeration
- NSFileProviderItem for file metadata

## Build System

### WSL Setup - `scripts/wsl_setup.sh`
Installs: build-essential, git, cmake, pkg-config, libfuse3-dev, libblkid-dev, uuid-dev, linux-headers, dkms, kmod, qemu, ovmf, wget, curl, python3, clang, llvm, lld, libssl-dev, zlib1g-dev, liblz4-dev, libzstd-dev, xxd, hexdump, libaio-dev, liburing-dev

Builds: Zig 0.13.0, EDK2 (OVMF), UFS Zig core, Tools (mkufs/ufsck/ufsinfo/ufsctl), FUSE driver, UEFI driver, Linux DKMS module

Creates: Test image (512MB), formats with mkufs (-l "WFSTEST" -c 4096 -C lz4)

### Test Suite - `scripts/test_ufs.sh` (11 Tests)
1. **FUSE Mount/Unmount** - Basic mount verification
2. **Basic File Ops** - CRUD, symlinks, hardlinks, xattrs, permissions
3. **Large File I/O** - 10MB, 100MB files
4. **Concurrent Access** - Multi-threaded read/write
5. **Crash Recovery** - SIGKILL + remount verify data survives
6. **Stress Test** - 1000 files create/read/delete
7. **UEFI QEMU** - Boot test with OVMF (30s timeout)
8. **Linux Kernel Module** - Native VFS mount test
9. **Performance Benchmark** - vs ext4/XFS
10. **FUSE Comprehensive** - All 22 operations + edge cases
11. **FUSE Edge Cases** - Sparse files, unlink-open, offsets

### Windows Setup - `scripts/windows_setup.ps1`
- Test signing enable
- WiX Toolset install
- WDK setup for IFS driver
- MSI creation with EV certificate support

## Quick Start (Debian WSL)

```bash
cd /path/to/UFS
chmod +x scripts/wsl_setup.sh scripts/test_ufs.sh scripts/run_wsl_tests.sh
./scripts/wsl_setup.sh          # Full build (5-10 min)
source ~/.bashrc
./scripts/test_ufs.sh           # All 11 integration tests
```

### Individual Components
```bash
# Zig core library
cd core/zig && ~/.local/zig/zig build -Doptimize=ReleaseFast

# Tools (mkufs, ufsck, ufsinfo, ufsctl)
~/.local/zig/zig build tools -Doptimize=ReleaseFast

# FUSE driver
~/.local/zig/zig build fuse -Doptimize=ReleaseFast

# UEFI driver
cd core/zig/drivers/uefi && ./build_uefi.sh release build

# Linux DKMS
cd core/zig/drivers/linux
mkdir -p include lib
cp ../zig/src/ufs.h include/
cp ../zig/zig-out/lib/libufs_core.a lib/
sudo dkms add . && sudo dkms build ufs/1.0.0 && sudo dkms install ufs/1.0.0
sudo modprobe ufs
```

## On-Disk Format (v1.0)

```
Superblock (cluster 0):
  Magic: 0x55465300 ("UFS\0")
  Version: 1.0.0
  Cluster size: 4096 (default)
  Volume size: clusters
  AG count: 4 (default 1GB each)
  AG size: clusters per AG
  Journal offset/size: clusters
  Feature flags: INCOMPAT/COMPAT_RO/COMPAT_RW
  UUIDv7: 16 bytes
  Label: 64 bytes
  CRC32C

Journal Area:
  Superblock (magic: 0x4A55524E "JURN")
  Transactions (circular):
    Header (magic: 0x54584E00 "TXN\0")
    Operations (variable)
    CRC32C

Allocation Groups (1GB each):
  AG Header (generation, free/inode counts, bitmaps)
  Inode Bitmap
  Cluster Bitmap
  Inode Table (256 bytes per inode)
  Capsule Area
  Data Clusters

Inode (256 bytes):
  Magic: 0x494E4F00 ("INO\0")
  Version, flags, inode#, generation
  Capsule ID (BLAKE3 of capsule)
  Mode, uid, gid, link_count
  Size, allocated_size
  Times (atime, mtime, ctime, crtime) - nanoseconds
  Extent tree root (inline for small files)
  Compression, encryption
  Capsule offset/size
  CRC32C

Capsules (per inode):
  POSIX_BASE (mode, uid, gid, times, links)
  POSIX_ACL (access/default ACLs)
  POSIX_XATTR (user.* extended attrs)
  POSIX_CAPS (capabilities)
  WINDOWS_SD (security descriptor)
  WINDOWS_ADS (alternate data streams)
  WINDOWS_REPARSE (reparse points)
  WINDOWS_EFS (encrypted files)
  WINDOWS_USN (USN journal)
  WINDOWS_OBJID (object IDs)
  WINDOWS_ATTRS (DOS attributes)
  MACOS_XATTR (extended attrs)
  MACOS_FINDER (Finder info)
  MACOS_RESOURCE (resource fork)
  MACOS_QUARANTINE (quarantine flag)
  MACOS_FIRMLINK (firmlink target)
  MACOS_TIMESTAMP (extra timestamps)
  UFS_INTERNAL (internal metadata)
  OPAQUE (application data)

Directory (linear array → B+tree):
  Header (magic, version, entry_count, CRC)
  Entries: inode#, name_len, type, flags, name, padding
```

## Feature Flags

### INCOMPAT (must understand to mount RW)
- COMPRESSION (1) - per-extent LZ4/ZSTD
- CASE_INSENSITIVE (2) - Unicode 15.0 case folding
- ENCRYPTION (4) - AES-256-GCM/ChaCha20-Poly1305 (v2)
- LARGE_INODES (8) - >256 byte inodes

### COMPAT_RO (can mount RO without understanding)
- SNAPSHOTS (1) - read-only snapshots
- QUOTA (2) - disk quotas
- EXTENDED_ATTRS (4) - xattr support
- METADATA_CAPSULES (8) - 16 namespace capsules

### COMPAT_RW (can mount RW without understanding)
- REFLINK (1) - copy-on-write clones
- DEDUP (2) - block deduplication
- FAST_COMMIT (4) - fast journal commits

## Performance Targets

| Metric | Target |
|--------|--------|
| Format time (1TB) | < 2 seconds |
| Mount time (1TB) | < 500ms |
| Small file create | < 100μs |
| Sequential read (SSD) | > 3 GB/s |
| Sequential write (SSD) | > 2 GB/s |
| Random 4K read (SSD) | > 500K IOPS |
| Random 4K write (SSD) | > 300K IOPS |
| Recovery time (dirty shutdown) | < 1 second |
| Memory overhead (per TB) | < 50 MB |

## Testing Checklist

### Unit Tests (Zig)
```bash
cd core/zig && ~/.local/zig/zig test src/journal.zig
~/.local/zig/zig test src/c_api.zig
~/.local/zig/zig test src/allocation.zig
~/.local/zig/zig test src/directory.zig
~/.local/zig/zig test src/compression.zig
~/.local/zig/zig test src/integrity.zig
```

### Integration Tests (WSL)
```bash
./scripts/test_ufs.sh          # All 11 test suites
./scripts/run_wsl_tests.sh     # Quick smoke test
```

### Real Hardware
```bash
# USB stick
sudo ./core/zig/zig-out/bin/mkufs -l "USBTEST" -c 4096 /dev/sdX
sudo mount -t ufs /dev/sdX /mnt/test

# NVMe
sudo ./core/zig/zig-out/bin/mkufs -l "NVME" -c 4096 -C zstd /dev/nvme0n1p1
sudo mount -t ufs /dev/nvme0n1p1 /mnt/test
```

### UEFI Boot Test
```bash
cd core/zig/drivers/uefi
./build_uefi.sh release test   # QEMU with OVMF
```

## Production Deployment

### Linux (DKMS)
```bash
# Build for target kernel
sudo dkms build ufs/1.0.0 -k 6.8.0-31-generic
sudo dkms install ufs/1.0.0 -k 6.8.0-31-generic

# Sign for Secure Boot
sudo kmodsign sha512 /path/to/MOK.priv /path/to/MOK.der /lib/modules/$(uname -r)/kernel/fs/ufs/ufs.ko
```

### Windows (MSI)
```powershell
# Requires EV certificate
.\scripts\windows_setup.ps1
cd core/zig/drivers/windows
# Build with WiX using EV cert
```

### macOS (FileProvider)
```bash
# Build Swift package
cd core/zig/drivers/macos
swift build -c release
# Sign with Developer ID
codesign --sign "Developer ID Application: ..." .build/release/UFSFileProvider
```

## Cross-Platform Metadata Preservation

| Metadata | Linux | Windows | macOS | UEFI |
|----------|-------|---------|-------|------|
| Permissions (POSIX) | ✓ | via SD | ✓ | - |
| ACLs | ✓ | ✓ (SD) | ✓ | - |
| xattrs (user.*) | ✓ | ✓ (ADS) | ✓ | - |
| Capabilities | ✓ | - | - | - |
| Windows SD | via xattr | ✓ | via xattr | - |
| Alternate Streams | via xattr | ✓ | via xattr | - |
| Reparse Points | via xattr | ✓ | via xattr | - |
| EFS | via xattr | ✓ | via xattr | - |
| USN Journal | via xattr | ✓ | via xattr | - |
| Object IDs | via xattr | ✓ | via xattr | - |
| DOS Attributes | via xattr | ✓ | via xattr | - |
| Finder Info | via xattr | via xattr | ✓ | - |
| Resource Fork | via xattr | via xattr | ✓ | - |
| Quarantine | via xattr | via xattr | ✓ | - |
| Firmlinks | via xattr | via xattr | ✓ | - |
| Extra Timestamps | ✓ | ✓ | ✓ | - |

## Known Limitations (v1.0)

1. **Encryption**: Stubbed (returns UNSUPPORTED_FEATURE) - planned for v2
2. **Quotas**: Config option exists but not implemented
3. **Snapshots**: Feature flag defined but not implemented
4. **Reflink/Dedup**: Feature flags defined but not implemented
5. **B+tree Directories**: Falls back to linear array for >64 entries (B+tree skeleton exists)
6. **Extent Trees**: Inline extents only for small files (full tree planned)
7. **Multi-AG Allocation**: Only AG 0 fully implemented in C API
8. **Compression Levels**: ZSTD_HIGH (level 3) not fully tuned

## Next Steps for Production

1. **Real Hardware Validation**
   - Test on USB 2.0/3.0/3.1, NVMe, SATA SSD/HDD
   - Test power loss scenarios (pull plug during write)
   - Test with bad blocks / failing drives

2. **Stress Testing**
   - 24+ hour continuous I/O (fio, iozone)
   - Concurrent multi-process access
   - Filesystem full / ENOSPC handling

3. **Security Audit**
   - Fuzzing (AFL on C API)
   - Buffer overflow checks
   - Privilege escalation review

4. **Performance Tuning**
   - Journal commit batching
   - Read-ahead optimization
   - Write-back caching
   - Parallel AG allocation

5. **Distribution Packaging**
   - Debian/Ubuntu: `apt install ufs-dkms`
   - Fedora/RHEL: `dnf install kmod-ufs`
   - Arch: `pacman -S ufs-dkms`
   - openSUSE: `zypper in ufs-kmp-default`
   - Windows: MSI with EV cert
   - macOS: Notarized pkg installer

---

**Version**: 1.0.0
**Date**: 2026-11-14
**License**: MIT/BSD (Zig core), GPLv2 (Linux kernel module)