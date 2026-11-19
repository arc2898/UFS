# UFS vs Other File Systems — Comparative Analysis

**Version:** 1.0
**Date:** 2026-11-14
**Status:** Reference Document

---

## Executive Summary

UFS (U Filesystem) is designed as a **cross-platform universal filesystem** with a unique focus on **metadata portability** via Metadata Capsules. Unlike existing filesystems that are OS-native first, UFS targets identical on-disk format across Windows, Linux, macOS, and UEFI.

| Dimension | UFS | NTFS | ext4 | APFS | ZFS | Btrfs | F2FS | exFAT | ReFS | XFS |
|-----------|-----|------|------|------|-----|-------|------|-------|------|-----|
| **Primary Target** | Universal (Win/Lin/Mac/UEFI) | Windows | Linux | macOS/iOS | Solaris/FreeBSD/Linux | Linux | Flash/SSD | Removable | Windows Server | Linux |
| **On-Disk Format** | Identical everywhere | Windows-only | Linux-only | Apple-only | Platform-specific | Linux-only | Linux-only | Universal | Windows-only | Linux-only |
| **Max Volume** | 256 TB | 256 TB (8 PB theoretical) | 1 EB | 8 EB | 256 ZB | 16 EB | 16 TB | 128 PB | 35 PB | 8 EB |
| **Max File** | 16 EB | 16 EB | 16 TB | 8 EB | 16 EB | 16 EB | 4 TB | 128 PB | 35 PB | 8 EB |
| **Metadata Portability** | **Native (Capsules)** | None | None | None | None | None | None | None | None | None |
| **Compression** | LZ4/ZSTD (per-extent) | LZNT1 (sparse) | None* | LZFSE/Zlib | LZ4/ZSTD/gzip | zlib/LZO/ZSTD | LZO/ZSTD | None | None | None |
| **Integrity** | CRC32C (meta) + BLAKE3 (data) | None** | CRC32C (meta) | Fletcher64 | SHA256/Blake3 | CRC32C | None | None | None | CRC32C (meta) |
| **Snapshots** | v2 | VSS | LVM | Native | Native | Native | None | None | VSS | None* |
| **Deduplication** | v2 | Dedup (Server) | None* | None | Native | Native | None | None | Dedup (Server) | None |
| **Encryption** | v2 (per-file) | EFS/BitLocker | fscrypt/LUKS | Native (APFS) | Native (ZFS) | fscrypt | fscrypt | None | BitLocker | fscrypt |
| **Journaling** | Logical redo (ordered data) | Logical redo | Physical redo | Copy-on-write | Copy-on-write | Copy-on-write | Log-structured | None | Logical redo | Physical redo |

*Available via external layers (VDO, LVM, dm-integrity, etc.)
**NTFS has $LOG_FILE but no data checksums

---

## Detailed Comparison Matrix

### 1. Architecture Philosophy

| Aspect | UFS | NTFS | ext4 | APFS | ZFS | Btrfs |
|--------|-----|------|------|------|-----|-------|
| **Core Philosophy** | Universal portability first | Windows integration | Linux stability | Apple ecosystem | Data integrity + volume mgmt | Copy-on-write + features |
| **Layering** | Single-layer (no VFS deps) | Kernel IFS | VFS + block | APFS container | ZPL + SPA + VDEV | Single B-tree |
| **Cluster/Block** | 4KB default (configurable) | 4KB (cluster) | 4KB (block) | Variable (container) | 4KB-1MB (recordsize) | 4KB-64KB (nodesize) |
| **Allocation Groups** | **Yes (1GB default, parallel)** | No (single MFT zone) | Yes (block groups) | No (container-wide) | Yes (metaslabs/vdevs) | Yes (block groups) |
| **Inode Model** | Per-AG table (512 default) | MFT (dynamic) | Fixed per group | Dynamic (B-tree) | Dynamic (dnodes) | Dynamic (B-tree) |

### 2. On-Disk Format & Portability

| Feature | UFS | NTFS | ext4 | APFS | ZFS | Btrfs | exFAT |
|---------|-----|------|------|------|-----|-------|-------|
| **Endianness** | Little (all platforms) | Little | Little | Little | Native | Little | Little |
| **Serialization** | **Explicit canonical** | Raw structs | Raw structs | Raw structs | Raw structs | Raw structs | Raw structs |
| **Versioning** | Major.Minor.Rev + feature flags | Version numbers | Feature flags | Version + features | Pool version + features | Disk format version | Version |
| **Cross-platform Mount** | **Native all platforms** | Read-only (Linux/Mac) | None | None (Linux read-only) | Platform-specific | None | **Universal** |
| **Metadata Preservation** | **Lossless (Capsules)** | Loses on non-Windows | Loses on non-Linux | Loses on non-Mac | Loses on non-ZFS | Loses on non-Linux | Minimal |

### 3. Metadata & Namespaces

| Namespace | UFS | NTFS | ext4 | APFS | ZFS | Btrfs |
|-----------|-----|------|------|------|-----|-------|
| **POSIX (mode/uid/gid/time)** | Native (POSIX_BASE) | Partial (via usermap) | Native | Native | Native | Native |
| **POSIX ACL** | Native (POSIX_ACL) | Yes (NT ACL ↔ POSIX) | Yes (xattr) | Yes (NFSv4) | Yes (NFSv4) | Yes (xattr) |
| **Extended Attributes** | Native (POSIX_XATTR) | Limited (ADS) | Yes (xattr) | Yes (xattr) | Yes (xattr) | Yes (xattr) |
| **Windows SDDL** | Native (WINDOWS_SD) | **Native** | No | No | No | No |
| **Windows ADS** | Native (WINDOWS_ADS) | **Native** | No | No | No | No |
| **Windows Reparse** | Native (WINDOWS_REPARSE) | **Native** | No | No | No | No |
| **macOS xattr** | Native (MACOS_XATTR) | No | No | **Native** | No | No |
| **macOS Finder** | Native (MACOS_FINDER) | No | No | **Native** | No | No |
| **macOS Resource Fork** | Native (MACOS_RESOURCE) | No | No | **Native** | No | No |
| **Opaque/Unknown** | **Preserved (OPAQUE)** | Lost | Lost | Lost | Lost | Lost |

**UFS Innovation:** Metadata Capsules provide a **single extensible container** that stores all platform metadata simultaneously. Unknown entries are preserved opaquely — a macOS-created file keeps its Windows SDDL when moved to Windows, and vice versa.

### 4. Allocation & Space Management

| Mechanism | UFS | NTFS | ext4 | APFS | ZFS | Btrfs | F2FS |
|-----------|-----|------|------|------|-----|-------|------|
| **Free Space** | **Hybrid: B+ tree + Bitmap** | Bitmap + MFT | Bitmap + buddy | Bitmap (container) | Metaslab allocator | B+ tree (free space) | Log-structured (segments) |
| **Parallel Alloc** | **Yes (per-AG)** | No | Yes (per block group) | No | Yes (per vdev) | Yes (per block group) | No (sequential log) |
| **Extent-based** | **Yes (B+ tree)** | Yes (MFT runs) | Yes (extent tree) | Yes (B-tree) | Yes (dnodes) | Yes (B-tree) | No (log blocks) |
| **Inline Extents** | ≤4 in inode | Resident in MFT | Inline data | Inline (small) | Inline (small) | Inline (small) | N/A |
| **Sparse Files** | Native (UNINITIALIZED) | Native | Native | Native | Native | Native | Native |
| **Preallocation** | fallocate + extent tree | SetFileValidData | fallocate | fcntl | fallocate | fallocate | fallocate |
| **TRIM/Discard** | Yes (async batched) | Yes | Yes | Yes | Yes | Yes | Yes (segment-based) |

### 5. Journaling & Crash Consistency

| Property | UFS | NTFS | ext4 | APFS | ZFS | Btrfs | XFS | ReFS |
|----------|-----|------|------|------|-----|-------|-----|------|
| **Type** | **Logical redo (metadata-only)** | Logical redo | Physical redo | Copy-on-write | Copy-on-write | Copy-on-write | Physical redo | Logical redo |
| **Data Mode** | **Ordered (data flush → journal)** | Ordered | Ordered/Writeback | N/A (CoW) | N/A (CoW) | N/A (CoW) | Ordered | Ordered |
| **Portable Replay** | **Yes (same Zig code)** | No | No | No | No | No | No | No |
| **Idempotent Replay** | **Yes** | Yes | Partial | N/A | N/A | N/A | No | Yes |
| **Checkpointing** | Every 100 txns / 1s / 75% | Periodic | Periodic | N/A | N/A | N/A | Periodic | Periodic |
| **Recovery Time** | <2s (1TB NVMe) | ~5-30s | ~1-10s | Instant | Instant | Instant | ~1-10s | ~5-30s |
| **Torn Write Detection** | CRC32C per txn | Sequence numbers | Journal checksum | CoW atomicity | CoW atomicity | CoW atomicity | CRC32C per block | CRC32C per txn |

**UFS Advantage:** Logical operations (not physical blocks) + portable recovery algorithm means **identical recovery on all platforms**. No kernel dependencies.

### 6. Compression

| Feature | UFS | NTFS | ext4* | APFS | ZFS | Btrfs | F2FS |
|---------|-----|------|-------|------|-----|-------|------|
| **Algorithms** | **LZ4, ZSTD, ZSTD_HIGH** | LZNT1 (legacy) | LZO/ZSTD (via VDO) | LZFSE, Zlib | LZ4, ZSTD, gzip, ZLE | zlib, LZO, ZSTD | LZO, ZSTD |
| **Granularity** | **Per-extent** | Per-file (sparse) | Per-block (VDO) | Per-file | Per-record | Per-extent | Per-block |
| **Random Access** | **Yes (extent index)** | Limited | Yes (VDO) | Yes | Yes | Yes | Yes |
| **Incompressible Detect** | **Entropy + signatures** | Heuristic | Heuristic | Heuristic | Heuristic | Heuristic | Heuristic |
| **Pipeline** | Compress → BLAKE3 → Encrypt | Compress only | VDO layer | Compress only | Compress → Checksum | Compress → Checksum | Compress only |
| **Transparent** | **Yes** | Yes (NTFS) | Yes (VDO) | Yes | Yes | Yes | Yes |

*ext4 compression requires VDO (Virtual Data Optimizer) layer

### 7. Data Integrity

| Layer | UFS | NTFS | ext4 | APFS | ZFS | Btrfs | XFS | ReFS |
|-------|-----|------|------|------|-----|-------|-----|------|
| **Metadata** | **CRC32C (HW accel)** | None* | CRC32C | Fletcher64 | SHA256/Blake3 | CRC32C | CRC32C | CRC32C |
| **User Data** | **BLAKE3 (256-bit SIMD)** | None | None** | None | SHA256/Blake3 | CRC32C (optional) | None | None |
| **Journal** | CRC32C per txn | Sequence # | Checksum | N/A | N/A | N/A | CRC32C | CRC32C |
| **Scrub** | Online, checkpointable | chkdsk (offline) | e2scrub (offline) | N/A (CoW) | **Online scrub** | **Online scrub** | xfs_scrub (offline) | ReFSUtil (offline) |
| **Self-healing** | v2 (mirror/raid) | No | No | No | **Yes (redundancy)** | **Yes (redundancy)** | No | **Yes (mirror)** |
| **Bit Rot Detection** | **BLAKE3 on read** | No | No | No | **Checksum on read** | **Checksum on read** | No | No |

*NTFS has no metadata checksums; relies on hardware RAID
**ext4 can use dm-integrity for data checksums

### 8. Directory Indexing

| Feature | UFS | NTFS | ext4 | APFS | ZFS | Btrfs | XFS | F2FS |
|---------|-----|------|------|------|-----|-------|-----|------|
| **Structure** | **Hybrid: Linear (≤64) + B+ tree** | B+ tree | HTree (hashed B-tree) | B-tree | B-tree (ZAP) | B-tree | B+ tree | Log + hash |
| **Case Handling** | **Insensitive + preserving (config)** | Insensitive + preserving | Sensitive | Insensitive + preserving | Sensitive* | Sensitive | Sensitive | Sensitive |
| **Unicode** | **NFD + case-fold (U15.0)** | UTF-16 | UTF-8 (bytes) | UTF-8 (NFD) | UTF-8 | UTF-8 | UTF-8 | UTF-8 |
| **Reserved Names** | **Windows list enforced** | Enforced | None | None | None | None | None | None |
| **Max Entries** | 2^32-1 | 2^32-1 | 2^32-1 | 2^64-1 | 2^64-1 | 2^64-1 | 2^64-1 | 2^32-1 |

*ZFS can be case-insensitive via property

### 9. Platform Integration

| Platform | UFS | NTFS | ext4 | APFS | ZFS | Btrfs |
|----------|-----|------|------|------|-----|-------|
| **Windows** | **Native IFS Driver (kernel)** | **Native** | WSL2 / ext4fs | Read-only (3rd party) | OpenZFS (beta) | WSL2 only |
| **Linux** | **FUSE + Native VFS (kernel)** | FUSE (ntfs-3g) / kernel (paragon) | **Native** | fuse-apfs (read-only) | **Native (kernel)** | **Native (kernel)** |
| **macOS** | **FSKit Extension (user-space)** | Read-only (ntfs-3g) | fuse-ext2 (read-only) | **Native** | OpenZFS (kernel ext) | No |
| **UEFI** | **Native UFS.efi (Simple FS)** | Limited | Limited | Limited | No | No |
| **FreeBSD** | Planned | Read-only | Read-only | No | **Native** | No |
| **Android** | Planned | No | **Native** | No | No | **Native (F2FS preferred)** |

### 10. Performance Characteristics (Target)

| Workload | UFS Target | NTFS | ext4 | APFS | ZFS | Btrfs | XFS |
|----------|------------|------|------|------|-----|-------|-----|
| **Seq Read (NVMe)** | >90% device | ~95% | ~95% | ~95% | ~90% | ~90% | ~95% |
| **Seq Write (NVMe)** | >85% device | ~90% | ~90% | ~90% | ~85% | ~80% | ~90% |
| **Rand 4K Read QD32** | >500K IOPS | ~400K | ~500K | ~500K | ~400K | ~300K | ~500K |
| **Rand 4K Write QD32** | >300K IOPS | ~300K | ~350K | ~350K | ~250K | ~200K | ~350K |
| **Metadata Create** | <50 μs | ~100 μs | ~50 μs | ~50 μs | ~200 μs | ~150 μs | ~50 μs |
| **Mount Time (1TB)** | <500ms | ~2-5s | ~1-3s | ~1-2s | ~5-10s | ~3-5s | ~1-2s |
| **Recovery (1TB)** | <2s | ~10-30s | ~2-10s | Instant | Instant | Instant | ~2-10s |
| **Compression CPU** | <5% | ~10% | ~15% (VDO) | ~5% | ~5% | ~10% | ~10% |
| **Memory Overhead** | <50MB + 1KB/inode | ~100MB | ~50MB | ~100MB | **High (ARC)** | **High** | ~100MB |

### 11. Advanced Features

| Feature | UFS | NTFS | ext4 | APFS | ZFS | Btrfs | ReFS |
|---------|-----|------|------|------|-----|-------|------|
| **Snapshots** | v2 | VSS (block) | LVM | **Native** | **Native** | **Native** | VSS |
| **Clones** | v2 | No | No | **Native** | **Native** | **Native** | No |
| **Deduplication** | v2 | Server only | VDO | No | **Native** | **Native** | Server only |
| **Quotas** | v2 | Yes | Yes (project) | No | **Native** | **Native** | Yes |
| **RAID** | External | Storage Spaces | mdadm | APFS Fusion | **Native (RAID-Z)** | **Native** | Storage Spaces |
| **Tiering** | v2 (media-aware) | Storage Spaces | dm-cache | No | **Native (L2ARC/SLOG)** | **Native (bcache)** | Storage Spaces |
| **Subvolumes** | No | No | No | **Containers** | **Datasets** | **Subvolumes** | No |
| **Send/Recv** | No | No | No | No | **Native** | **Native** | No |
| **Reflink (CoW copy)** | No | No | No | **Native** | **Native** | **Native** | No |
| **fs-verity** | v2 (INCOMPAT_VERITY) | No | Yes | No | No | No | No |

### 12. Security Model

| Aspect | UFS | NTFS | ext4 | APFS | ZFS | Btrfs |
|--------|-----|------|------|------|-----|-------|
| **Permissions** | Capsules (POSIX + SDDL + ACL) | SDDL + SACL | POSIX + ACL | POSIX + ACL | POSIX + ACL | POSIX + ACL |
| **Encryption** | v2 (per-file, HW keys) | EFS (per-file) + BitLocker (volume) | fscrypt (per-dir) + LUKS | **Native (per-file/extent)** | **Native (per-dataset)** | fscrypt |
| **Key Mgmt** | v2 (volume master → file keys) | DPAPI / TPM | Kernel keyring | Secure Enclave | ZFS key hierarchy | Kernel keyring |
| **Secure Delete** | Not guaranteed* | Not guaranteed | Not guaranteed | Not guaranteed | Not guaranteed | Not guaranteed |
| **Parser Hardening** | **Fuzzed, bounded, no unbounded alloc** | Kernel parser | Kernel parser | Kernel parser | Kernel parser | Kernel parser |

*Wear leveling on SSDs makes secure delete impossible at FS level

### 13. Tooling & Ecosystem

| Tool | UFS | NTFS | ext4 | APFS | ZFS | Btrfs | XFS |
|------|-----|------|------|------|-----|-------|-----|
| **Format** | mkufs | format / mkfs.ntfs | mkfs.ext4 | diskutil / newfs_apfs | zpool create | mkfs.btrfs | mkfs.xfs |
| **Check/Repair** | ufsck | chkdsk | e2fsck | fsck_apfs | zpool scrub | btrfs check | xfs_repair |
| **Inspect** | ufsinfo | nfi / fsutil | debugfs / dumpe2fs | apfs.util | zdb | btrfs inspect | xfs_db |
| **Admin** | ufsctl | fsutil | tune2fs / resize2fs | diskutil | zfs / zpool | btrfs | xfs_admin / xfs_growfs |
| **Benchmarks** | ufsbench | DiskSpd | fio | fio | fio | fio | fio |
| **Fuzzing** | **Integrated (all parsers)** | Syzkaller | Syzkaller | Limited | Limited | Syzkaller | Syzkaller |

---

## UFS Unique Value Propositions

### 1. **Metadata Capsules — The Central Innovation**

```
Scenario: Create file on Windows → Edit on Linux → View on macOS → Back to Windows

NTFS on Linux:     Loses ADS, reparse points, EFS, USN, Object ID
ext4 on Windows:   Loses POSIX ACLs, xattrs, capabilities
APFS on Linux:     Loses Finder tags, resource forks, quarantine, firmlinks
exFAT everywhere:  Loses everything except basic timestamps

UFS:               **Preserves ALL metadata losslessly**
                   - Windows SDDL → Linux xattr "system.ntfs_sd" → macOS opaque xattr → Windows SDDL
                   - POSIX ACL ↔ NFSv4 ACL ↔ macOS ACL
                   - Unknown namespaces stored as OPAQUE, never discarded
```

### 2. **Portable Recovery — Same Algorithm Everywhere**

- Logical redo journal with self-describing operations
- Recovery code in Zig core runs identically on Windows IFS, Linux VFS, macOS FSKit, UEFI
- No platform-specific recovery paths

### 3. **Single Source of Truth — Shared Zig Core**

| Component | Traditional Approach | UFS Approach |
|-----------|---------------------|--------------|
| On-disk format | C structs per OS | **Canonical serialization (Zig)** |
| Journal replay | C per kernel | **Single Zig implementation** |
| Compression | C per kernel | **Single Zig + FFI to LZ4/ZSTD** |
| Integrity | C per kernel | **Single Zig (CRC32C + BLAKE3)** |
| Capsule parsing | C per kernel | **Single Zig** |
| Allocation | C per kernel | **Single Zig** |
| Directory indexing | C per kernel | **Single Zig** |

**Result:** 95%+ code reuse, consistent behavior, single test suite.

### 4. **Modern Defaults, No Legacy Baggage**

| Legacy Constraint | NTFS/ext4/APFS | UFS |
|-------------------|----------------|-----|
| MBR boot sector | Required | Optional (GPT native) |
| 32-bit timestamps | Yes (2038 problem) | **64-bit nanosecond (year 2554)** |
| Fixed inode table | ext4 | **Dynamic per-AG** |
| Single journal | All | **Per-AG checkpoints + global journal** |
| No data checksums | All but ZFS/Btrfs | **BLAKE3 on all data** |
| Case sensitivity fixed | Per-FS | **Configurable per-volume** |
| Compression algorithm | Fixed (LZNT1/LZFSE) | **Pluggable (LZ4/ZSTD)** |

---

## When to Choose UFS vs Alternatives

### Choose UFS When:
- **Cross-platform removable media** (USB, SD, external SSD) needing full metadata preservation
- **Dual-boot / multi-OS environments** sharing data partitions
- **UEFI boot partitions** requiring a readable filesystem
- **Long-term archival** with integrity verification (BLAKE3 scrub)
- **New projects** wanting modern defaults without legacy constraints

### Choose NTFS When:
- Windows-only internal drives
- Need Windows-specific features (BitLocker, VSS, quotas, dedup)
- Legacy application compatibility required

### Choose ext4 When:
- Linux-only servers
- Proven stability track record required
- Ecosystem tooling maturity critical

### Choose APFS When:
- macOS/iOS exclusive deployment
- Need snapshots/clones/encryption native to Apple ecosystem
- Fusion Drive / APFS container benefits needed

### Choose ZFS When:
- Data integrity paramount (enterprise storage)
- Native RAID, tiering, send/receive needed
- Memory available for ARC (recommend 1GB+ per TB)

### Choose Btrfs When:
- Linux-only with snapshots/subvolumes needed
- Native RAID acceptable (raid56 still experimental)
- Subvolume send/receive for backup

### Choose XFS When:
- Large files / high throughput on Linux
- Proven scalability (PB-scale) needed
- No snapshots/dedup needed

### Choose exFAT When:
- Maximum compatibility (cameras, game consoles, old OS)
- Simple files, no metadata requirements
- Flash media < 32GB (FAT32 alternative)

### Choose F2FS When:
- Raw flash / eMMC / SD cards (no FTL)
- Android / embedded Linux
- Log-structured benefits for wear leveling

---

## Migration & Interoperability

### UFS → Other FS
- **Metadata loss**: Capsules cannot be represented natively
- **Tool**: `ufsctl export-metadata` → JSON → target FS xattrs
- **Best effort**: POSIX_BASE → native; Windows/macOS → opaque xattrs

### Other FS → UFS
- **NTFS**: `mkufs --import-ntfs /dev/sdX` — preserves SDDL, ADS, reparse, timestamps
- **ext4**: `mkufs --import-ext4 /dev/sdX` — preserves mode, uid/gid, xattrs, ACLs
- **APFS**: `mkufs --import-apfs /dev/diskX` — preserves Finder tags, resource forks, quarantine
- **exFAT/FAT32**: Basic import only (timestamps, names)

### In-Place Conversion
- **Not supported** (different on-disk structures)
- Use `ufsck --repair` only on UFS volumes

---

## Future Roadmap (v2+)

| Feature | Target | Competitor Parity |
|---------|--------|-------------------|
| Snapshots/Clones | v2 | ZFS/Btrfs/APFS |
| Native Encryption | v2 | ZFS/APFS/NTFS |
| Deduplication | v2 | ZFS/Btrfs/ReFS |
| Quotas | v2 | All major FS |
| RAID Integration | v2 | ZFS/Btrfs |
| Reflink (CoW copy) | v2 | ZFS/Btrfs/APFS/XFS |
| fs-verity | v2 | ext4 |
| ZNS Support | v2 | F2FS |
| Project Quotas | v2 | ext4/XFS |
| Inline Data | v2 | ext4/Btrfs/ZFS |
| Case-Insensitive Volume | v1 (INCOMPAT) | NTFS/APFS |
| Online Resize | v2 | All major FS |
| Subvolumes/Datasets | v3 | ZFS/Btrfs/APFS |
| Send/Receive | v3 | ZFS/Btrfs |
| Tiering (L2ARC/SLOG) | v3 | ZFS |
| Erasure Coding | v3 | ZFS (RAID-Z) |

---

## Conclusion

UFS does not aim to replace ZFS for enterprise storage, or ext4/XFS for Linux servers, or APFS for Apple devices. **UFS fills a unique gap: a truly universal filesystem with lossless metadata portability across all major platforms.**

Its architecture — shared Zig core, logical journaling, Metadata Capsules, explicit serialization — is designed for **correctness across platforms first, performance second**. For the use case of "one filesystem that works everywhere with full metadata fidelity," UFS has no direct competitor.

---

*End of Comparative Analysis*