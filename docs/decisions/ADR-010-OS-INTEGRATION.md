# ADR-010: OS Integration Strategy

**Status:** Accepted
**Date:** 2026-11-13
**Deciders:** Project U Architecture Team

## Context

UFS must integrate natively with Windows 11, Linux, and macOS. Each OS has different driver architectures and requirements.

## Decision

**Thin platform-specific layers over shared Zig core. Each OS gets native integration appropriate to its architecture.**

### Windows 11: Native IFS Driver (Kernel Mode)

**Architecture:**
```
User Mode:          Kernel Mode:
┌─────────────┐     ┌──────────────────┐
│ ufsctl.exe  │────▶│ UFS.sys (IFS)    │
│ Mount-UFS.ps1│    │ ├─ Zig Core (DLL)│
│ Format-UFS  │    │ ├─ PAL (Block I/O) │
└─────────────┘     │ └─ IFS Glue      │
                    └──────────────────┘
```

**Implementation:**
- **Filesystem Driver**: `drivers/windows/UFS.sys` (C, WDK)
- **Zig Core**: Compiled as static library, linked into driver
- **PAL**: Windows storage stack (IRP_MJ_READ/WRITE, FLT_FUA)
- **IFS Glue**: IRP dispatch, VCB/FCB/CCB management, Fast I/O
- **Installation**: INF + PnPUtil, driver signing (test → production)
- **Mount Manager**: Registers with MountMgr for drive letters

**Key Windows IFS Requirements:**
- `DriverEntry` / `DriverUnload`
- `FsCreateSection` / `FsAcquireForSectionSynchronization`
- `FsMountVolume` / `FsUnmountVolume`
- IRP_MJ_CREATE/CLOSE/READ/WRITE/SET_INFO/QUERY_INFO/FSCTL
- Fast I/O: `FastIoRead`/`FastIoWrite`/`FastIoQueryBasicInfo`
- Cache Manager integration (CcInitializeCacheMap)
- Transaction support (TxF - optional)
- Security: `FsSecurityCallback`, SD mapping

**Signing:**
- Test: Test-signed driver, `bcdedit /set testsigning on`
- Production: EV certificate → Microsoft Attestation Signing → WHQL

### Linux: Dual Path (FUSE + Native VFS)

#### Path 1: FUSE (Early Development, User-Space)
```
┌─────────────────────────────────────────────────┐
│                    Userspace                    │
│  ufs-fuse (Zig→C→FUSE) ── libfuse ── FUSE kmod │
└─────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────┐
│                    Kernel                       │
│              VFS ── fuse.ko                     │
└─────────────────────────────────────────────────┘
```

- **Implementation**: `drivers/linux-fuse/` - Zig core + C FUSE glue
- **Pros**: No kernel code, easy debugging, portable
- **Cons**: Context switch overhead, no page cache integration, no mmap
- **Use**: Development, testing, non-root users, containers

#### Path 2: Native VFS (Production, Kernel Module)
```
┌─────────────────────────────────────────────────┐
│                    Kernel                       │
│  ufs.ko (C glue + Zig core static lib)          │
│  ├─ struct file_system_type                     │
│  ├─ super_operations                            │
│  ├─ inode_operations                            │
│  ├─ file_operations                             │
│  ├─ address_space_operations                    │
│  └─ export_operations                           │
└─────────────────────────────────────────────────┘
```

- **Implementation**: `drivers/linux/` - Minimal C glue + Zig core
- **Pros**: Full VFS integration, page cache, mmap, performance
- **Cons**: Kernel programming, version compatibility, signing
- **Kernel API**: `register_filesystem()`, VFS callbacks
- **Compatibility**: Target kernel 6.1+ (LTS), test on 6.6, 6.12

#### WSL 2 Development Workflow
- Build Zig core in WSL
- Build FUSE driver in WSL
- Build native module against WSL kernel headers
- Test with virtual disks (`losetup`, `nbd`)
- `wsl --mount --bare` for raw block device access

### macOS: FSKit File System Extension (User-Space)

**Architecture (macOS 13+ Ventura):**
```
┌─────────────────────────────────────────────────┐
│                    Userspace                    │
│  UFS Extension (Swift + Zig core)               │
│  ├─ FileSystemExtension                         │
│  ├─ FileSystemHandler                           │
│  └─ VolumeHandler                               │
└─────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────┐
│                    Kernel                       │
│              VFS ── FSKit framework             │
└─────────────────────────────────────────────────┘
```

- **Implementation**: `drivers/macos/` - Swift FSKit extension + Zig core (dynamic lib)
- **Pros**: Supported by Apple, no KEXT, user-space debugging
- **Cons**: macOS 13+ only, user-space (context switches)
- **FSKit APIs**: `FileSystemExtension`, `VolumeHandler`, `FileHandle`
- **Entitlements**: `com.apple.developer.filesystem-extension`
- **Distribution**: App Store or Developer ID + Notarization

**Legacy (macOS < 13):** Not supported (KEXT deprecated, no FSKit)

### UEFI: Standalone Boot Application

**Architecture:**
```
┌─────────────────────────────────────────────────┐
│              UEFI Environment                   │
│  UFS.efi (Zig compiled for UEFI)                │
│  ├─ Simple File System Protocol                 │
│  ├─ Block I/O Protocol                          │
│  └─ Loaded Image Protocol                       │
└─────────────────────────────────────────────────┘
```

- **Implementation**: `boot/uefi/` - Zig target `x86_64-unknown-uefi` / `aarch64-unknown-uefi`
- **Protocols**: `EFI_SIMPLE_FILE_SYSTEM_PROTOCOL` for bootloader access
- **Bootloader**: Reads kernel/initrd from UFS volume
- **Recovery**: Includes `ufsck` for pre-boot repair

### Shared Core Integration Pattern

```
                    ┌─────────────────┐
                    │   Zig Core      │
                    │  (static lib)   │
                    └────────┬────────┘
                             │
         ┌───────────────────┼───────────────────┐
         ▼                   ▼                   ▼
┌─────────────────┐ ┌─────────────────┐ ┌─────────────────┐
│  Windows IFS    │ │  Linux VFS      │ │  macOS FSKit    │
│  C Glue Layer   │ │  C Glue Layer   │ │  Swift Glue     │
└─────────────────┘ └─────────────────┘ └─────────────────┘
```

**Glue Layer Responsibilities:**
- Translate OS callbacks → Zig core calls
- Manage OS-specific objects (IRPs, inodes, file handles)
- Handle memory allocation (OS allocator → Zig allocator)
- Error code translation (NTSTATUS ↔ errno ↔ FSKit errors)
- Locking (OS locks → Zig mutexes)

### Driver Signing Requirements

| Platform | Development | Production |
|----------|-------------|------------|
| Windows | Test signing | EV cert + Microsoft Attestation |
| Linux | Unsigned (local) | DKMS / distro kernel signing |
| macOS | Developer ID | Developer ID + Notarization |
| UEFI | None | Optional (Secure Boot) |

## Alternatives Considered

| Alternative | Pros | Cons | Decision |
|-------------|------|------|----------|
| FUSE only (all platforms) | Portable | Slow, no page cache, no mmap | Rejected |
| Network FS (SMB/NFS) | Cross-platform | Not local FS, latency | Rejected |
| **Native per-platform** | Performance, integration | Platform-specific code | **Accepted** |

## Consequences

### Positive
- Native performance on each platform
- Full OS feature integration (ACLs, xattrs, compression, snapshots)
- Proper driver lifecycle management
- Meets user expectations for "native filesystem"

### Negative
- 3× platform-specific glue code
- Different release cycles per platform
- Kernel programming expertise needed (Windows/Linux)
- Signing/certification costs

## Implementation Notes

1. **Core First**: Build and test Zig core with FUSE on Linux
2. **Windows IFS**: Study FastFAT sample, Microsoft IFS docs
3. **Linux VFS**: Target 6.1+ LTS, use `fs/` kernel API
4. **macOS FSKit**: Requires Apple Developer Program ($99/yr)
5. **UEFI**: Zig UEFI target, test in QEMU/OVMF

## Reversibility

**Moderate** - Glue layers are platform-specific. Core unchanged.
Changing integration method (e.g., FUSE→VFS) only affects glue.

**Locked: NO** (implementation detail)

---

*ADR-010: OS Integration Strategy*