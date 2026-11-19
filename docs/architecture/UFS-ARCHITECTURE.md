# UFS Architecture

**Project:** Project U (U Filesystem - UFS)
**Version:** 1.0 (Draft)
**Date:** 2026-11-13
**Status:** Architecture Definition Phase

---

## 1. Overview

UFS (U Filesystem) is a modern, cross-platform filesystem designed for universal interoperability between Windows, Linux, and macOS. Its central innovation is **Metadata Capsules** - structured, extensible containers that preserve all file metadata losslessly when moving volumes between operating systems.

### Design Principles

1. **One Disk Format** - Identical on-disk structure across all platforms
2. **Shared Core Engine** - 95%+ of logic in portable Zig
3. **Native Integration** - Platform-specific drivers (IFS, VFS, FSKit)
4. **Crash Consistency** - Portable logical journaling with ordered data
5. **Data Integrity** - Dual-layer checksums (CRC32C metadata, BLAKE3 data)
6. **Transparent Compression** - Per-extent LZ4/ZSTD with integrity
4. **Adaptive Storage** - Media-aware policies (deferred to v2)
7. **Future-Proof** - Extensible versioning and feature flags

---

## 2. High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           UFS ARCHITECTURE                                  │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐       │
│  │   Windows   │  │    Linux    │  │   macOS     │  │    UEFI     │       │
│  │   11+       │  │  (6.1+)     │  │  (13+)      │  │  (x64/ARM)  │       │
│  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘       │
│         │                │                │                │               │
│  ┌──────▼────────────────▼────────────────▼────────────────▼──────┐       │
│  │                    PLATFORM INTEGRATION LAYER                  │       │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────────┐  │       │
│  │  │ IFS Drv  │  │ VFS Mod  │  │ FSKit Ext│  │  UEFI App    │  │       │
│  │  │ (C+Zig)  │  │ (C+Zig)  │  │(Swift+Zig)│  │  (Zig)       │  │       │
│  │  └────┬─────┘  └────┬─────┘  └────┬─────┘  └──────┬───────┘  │       │
│  └───────│─────────────│─────────────│───────────────│──────────┘       │
│          │             │             │               │                  │
│  ┌───────▼─────────────▼─────────────▼───────────────▼──────────┐       │
│  │                      ZIG CORE ENGINE                         │       │
│  │  ┌─────────┐┌─────────┐┌─────────┐┌─────────┐┌───────────┐ │       │
│  │  │Serializ.││Metadata ││Allocati.││ Journal ││ Directory │ │       │
│  │  │         ││Capsules ││  (AGs)  ││(Logical)││  (B+Tree) │ │       │
│  │  └────┬────┘└────┬────┘└────┬────┘└────┬────┘└─────┬─────┘ │       │
│  │  ┌─────▼─────────▼──────────▼─────────▼──────────▼────┐   │       │
│  │  │ Compression │ Integrity │ Version │ BlockDev  │      │   │       │
│  │  │  Pipeline   │ (CRC32C/  │ Control │  Abstract │      │   │       │
│  │  │ (LZ4/ZSTD)  │  BLAKE3)  │         │  Interface│      │   │       │
│  │  └─────────────┴───────────┴─────────┴───────────┘   │       │
│  └─────────────────────────────────────────────────────────┘       │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 3. On-Disk Format Overview

### Volume Layout

```
┌────────────────────────────────────────────────────────────────────┐
│                        UFS VOLUME                                  │
├────────────────────────────────────────────────────────────────────┤
│                                                                    │
│  Sector 0:              ┌────────────────────────────────────┐   │
│  ┌──────────────────┐   │         PRIMARY SUPERBLOCK         │   │
│  │  BOOT SECTOR     │   │  (Magic, Version, Feature Flags,   │   │
│  │  (BPB + Boot)    │   │   Volume UUID, Size, Block Size,   │   │
│  └──────────────────┘   │   Root Inode, Journal Loc, AGs,    │   │
│                         │   Checksums, Clean Flag)           │   │
│  ┌──────────────────┐   └────────────────────────────────────┘   │
│  │  RESERVED        │                                            │
│  │  (Backup Super)  │   ┌────────────────────────────────────┐   │
│  └──────────────────┘   │         JOURNAL AREA               │   │
│                         │  (Circular Log, Checkpoints,       │   │
│  ┌──────────────────┐   │   Transaction Chain)               │   │
│  │  ALLOCATION      │   └────────────────────────────────────┘   │
│  │  GROUP 0         │                                            │
│  │  ┌────────────┐  │   ┌────────────────────────────────────┐   │
│  │  │ AG Header  │  │   │     ALLOCATION GROUP 1...N         │   │
│  │  │ Free Tree  │  │   │  ┌──────────────────────────────┐  │   │
│  │  │ Bitmap     │  │   │  │ AG Header                    │  │   │
│  │  │ Inode Tbl  │  │   │  │ Free Extent Tree             │  │   │
│  │  │ Data Blocks│  │   │  │ Allocation Bitmap            │  │   │
│  │  └────────────┘  │   │  │ Inode Table                  │  │   │
│  └──────────────────┘   │  │ Data Blocks                  │  │   │
│                         │  └──────────────────────────────┘  │   │
│  ┌──────────────────┐   └────────────────────────────────────┘   │
│  │  ALLOCATION      │                                            │
│  │  GROUP 1         │   ┌────────────────────────────────────┐   │
│  │  (same struct)   │   │      BACKUP SUPERBLOCKS            │   │
│  └──────────────────┘   │  (At fixed offsets: 64KB, 64MB,    │   │
│         ...             │   256GB, 1TB, end-64KB)            │   │
│                         └────────────────────────────────────┘   │
│                                                                    │
└────────────────────────────────────────────────────────────────────┘
```

### Key Structures

| Structure | Location | Size | Redundancy |
|-----------|----------|------|------------|
| Primary Superblock | Sector 1 (offset 512) | 4 KB | Backups at fixed offsets |
| Journal | Configurable (after superblock) | 64 MB default | Circular, checkpointed |
| Allocation Groups | Distributed | 1 GB each (config) | Independent metadata |
| Inode Table | Per AG | 128 KB per 512 inodes | Rebuildable from extent trees |
| Free Extent Tree | Per AG | Variable | Rebuildable from bitmap |
| Allocation Bitmap | Per AG | 1 bit/cluster | Primary free space tracker |

---

## 4. Core Subsystems

### 4.1 Serialization Layer (ADR-001)
- Canonical little-endian binary encoding
- Explicit field widths, no padding
- CRC32C on every structure
- Versioned with feature flags

### 4.2 Metadata Capsules (ADR-007) - **CENTRAL INNOVATION**
- Extensible, namespaced containers
- Namespaces: POSIX, Windows, macOS, UFS internal, Opaque
- Bidirectional translation per platform
- Stored inline (small) or as extent (large)
- Unknown entries preserved opaquely

### 4.3 Block Allocation (ADR-003)
- Allocation Groups (1 GB default) for parallelism
- Hybrid free space: Extent B-tree + Bitmap
- Media-aware policies (HDD/SATA/NVMe/USB/SD)
- Per-extent compression metadata
- Extent trees in inodes (inline ≤ 4 extents)

### 4.4 Journaling (ADR-002)
- Logical redo journal (metadata-only, ordered data)
- Self-describing operations (not physical blocks)
- Portable recovery algorithm (same on all platforms)
- Idempotent replay with CRC32C + Merkle chain
- Checkpointing every 100 txns or 1 second

### 4.5 Directory Indexing (ADR-004)
- Hybrid: Linear (≤ 64 entries) + B+ tree (> 64)
- Case-insensitive with case-preservation (configurable)
- Unicode NFD + case-fold for comparison
- Windows reserved name enforcement

### 4.6 Compression (ADR-005)
- Per-extent: LZ4 (fast), ZSTD (balanced), ZSTD_HIGH (max)
- Integrated pipeline: Compress → BLAKE3 → Encrypt → Write
- Heuristics avoid compressing incompressible data
- Random access via extent index

### 4.7 Integrity (ADR-006)
- Metadata: CRC32C (hardware accelerated)
- Data: BLAKE3 (256-bit, SIMD)
- Journal: CRC32C per transaction
- Scrub: Online, checkpointable, reports corruption

### 4.8 Versioning (ADR-008)
- Major.Minor.Revision format version
- Feature flags: INCOMPAT / COMPAT_RO / COMPAT_RW
- Mount decision algorithm for safety
- Reserved space for evolution

---

## 5. Platform Integration (ADR-010)

### Windows 11: Native IFS Driver
- Kernel-mode filesystem driver (`UFS.sys`)
- Zig core as static library
- IRP dispatch, Fast I/O, Cache Manager
- Mount Manager integration
- Test signing → Production EV cert + Attestation

### Linux: FUSE + Native VFS
- **FUSE**: Development, user-space, portable
- **VFS Kernel Module**: Production, page cache, mmap
- WSL 2 development workflow
- Target kernel 6.1+ LTS

### macOS: FSKit Extension (13+)
- User-space File System Extension
- Swift + Zig core dynamic library
- Developer ID + Notarization
- No KEXT (deprecated)

### UEFI: Boot Application
- `UFS.efi` with Simple File System Protocol
- Reads bootloader/kernel from UFS volume
- Includes recovery tool

---

## 6. Data Flow Examples

### File Create (Cross-Platform)
```
1. App calls CreateFile() / open() / create()
2. Platform driver → Zig core: create_inode(parent, name, type, capsule)
3. Zig core:
   a. Allocate inode in AG
   b. Create metadata capsule with POSIX_BASE + platform entries
   c. Add dirent to parent directory (B+ tree)
   d. Allocate extent if initial data
   e. Build journal transaction
4. Journal commit (ordered data mode):
   a. Write data blocks → flush
   b. Write transaction to journal → flush
   c. Update checkpoint
5. Return success
```

### File Read (With Compression + Integrity)
```
1. App calls ReadFile() / read()
2. Platform driver → Zig core: read_extent(inode, offset, length)
3. Zig core:
   a. Lookup extent in inode's extent tree
   b. Read compressed data from disk
   c. Verify BLAKE3 checksum
   d. Decompress (LZ4/ZSTD)
   e. Return plaintext
3. Platform driver returns data to app
```

### Cross-Platform Mount
```
1. Volume formatted on Windows → capsules have WINDOWS_* entries
2. Eject, mount on Linux:
   a. Linux driver reads superblock, detects UFS
   b. Reads capsules, translates WINDOWS_SD → xattr "system.ntfs_sd"
   c. WINDOWS_ADS → xattr "user.ntfs_ads.$name"
   d. POSIX_BASE → native mode/uid/gid/timestamps
3. User creates file on Linux → adds POSIX_ACL, POSIX_XATTR
4. Eject, mount on macOS:
   a. macOS driver translates POSIX_ACL → NFSv4 ACL
   b. POSIX_XATTR → com.apple.* xattrs
   c. WINDOWS_* entries preserved as opaque xattrs
5. Eject, mount on Windows:
   a. All entries translated back losslessly
```

---

## 7. Crash Recovery Guarantees

| Scenario | Guarantee |
|----------|-----------|
| Power loss during data write | Data either fully written or not at all (ordered mode) |
| Power loss during journal commit | Transaction atomic (all or nothing) |
| Power loss during checkpoint | Recovery resumes from last valid checkpoint |
| Interrupted recovery | Idempotent - safe to restart |
| Corrupted journal record | Detected by CRC32C, truncated at last valid |
| Torn metadata write | Detected by CRC32C on read |
| Bit rot on data | Detected by BLAKE3 on read |

---

## 8. Security Model

- **Permissions**: Stored in capsules (POSIX_BASE.mode + POSIX_ACL + WINDOWS_SD)
- **Encryption**: v2 (per-file, hardware-backed keys)
- **Secure Delete**: Not guaranteed (wear leveling, over-provisioning)
- **Parser Safety**: All parsers fuzzed, bounds-checked, no unbounded allocations
- **Malformed Metadata**: Treated as hostile input, rejected with EINVAL

---

## 9. Performance Targets

| Metric | Target (NVMe) | Target (SATA SSD) | Target (HDD) |
|--------|---------------|-------------------|--------------|
| Sequential Read | > 90% device | > 90% device | > 80% device |
| Sequential Write | > 85% device | > 85% device | > 70% device |
| Random 4K Read (QD32) | > 500K IOPS | > 100K IOPS | > 200 IOPS |
| Random 4K Write (QD32) | > 300K IOPS | > 80K IOPS | > 150 IOPS |
| Metadata Create | < 50 μs | < 100 μs | < 5 ms |
| Mount Time (1 TB) | < 500 ms | < 1 s | < 2 s |
| Recovery Time (1 TB) | < 2 s | < 5 s | < 10 s |
| Compression Overhead | < 5% CPU | < 10% CPU | < 15% CPU |

---

## 10. Limitations (v1)

1. **No snapshots/clones** - Deferred to v2
2. **No native encryption** - Deferred to v2 (format encryption-ready)
3. **No deduplication** - Deferred to v2
4. **No quotas** - Deferred to v2
5. **Adaptive storage policies** - Basic only, full in v2
6. **ZNS support** - Deferred to v2
7. **RAID integration** - External (mdadm, Storage Spaces, APFS)
8. **Maximum volume** - 256 TB (64-bit block addressing, 4 KB clusters)
9. **Maximum file** - 16 EB (64-bit file size)
10. **Maximum files** - 4 billion (32-bit inode reference)

---

*End of UFS Architecture Document*