# UFS Technical Research Report

**Project:** Project U (U Filesystem - UFS)
**Date:** 2026-11-13
**Status:** Research Phase - Initial Findings

---

## Executive Summary

This document consolidates deep technical research on existing filesystems to inform the design of UFS (U Filesystem). Research covers NTFS, ext4, APFS, ZFS, Btrfs, F2FS, exFAT, ReFS, XFS, and others. The goal is to identify unsolved problems and architect a genuinely useful, high-performance, reliable, portable filesystem.

---

## 1. Filesystem Architecture Analysis

### 1.1 NTFS (New Technology File System) - Windows Native

**On-Disk Format:**
- Volume Boot Record (VBR) at sector 0 with BIOS Parameter Block (BPB)
- No traditional superblock; critical metadata in Master File Table ($MFT)
- $MFT: Relational database stored as a file, mirrored by $MFTMirr (first 4 records)
- MFT records: 1-4 KB, contain header + variable-length attributes
- Key attributes: $STANDARD_INFORMATION, $FILE_NAME, $DATA, $INDEX_ROOT, $INDEX_ALLOCATION, $BITMAP, $ATTRIBUTE_LIST, $REPARSE_POINT, $EA, $SECURITY_DESCRIPTOR
- Directory structure: B+ trees with case-insensitive Unicode collation
- Free space: $BITMAP attribute of $Bitmap system file (1 bit per cluster)
- Extent allocation: Runlists (VCN→LCN mapping), supports sparse files

**Journaling/Recovery:**
- Write-ahead metadata-only journal ($LogFile) based on Log File Service (LFS)
- Redo/undo log for metadata only (file data not journaled)
- Circular log with restart areas, infinite log concept
- Transaction commit: write records → flush → apply in-place → commit record → flush
- Recovery: Analysis → Redo → Undo passes
- Checkpointing: Periodic Restart Area writes
- USN Journal separate (application-level change tracking)

**Integrity:**
- USA (Update Sequence Array) per 512-byte sector in MFT records
- Detects torn writes but not bit rot
- No CRC32C, Fletcher, SHA, or BLAKE3 for metadata or data
- Self-healing: Windows 8+ online chkdsk /scan /spotfix (metadata only)
- Offline chkdsk repairs MFT, directory, allocation mismatches

**Compression:**
- LZNT1 (LZ77 + Huffman), per-file or per-directory inheritance
- Compression units: 16 clusters (64 KB for 4 KB clusters)
- Transparent to applications
- CPU-bound, write amplification on partial updates

**Flash/SSD Optimizations:**
- TRIM/discard via FSCTL_DELETE_NOTIFICATION (since Windows 7)
- No filesystem-level wear leveling
- No ZNS support
- $LogFile and $MFT hotspots cause uneven wear

**Cross-Platform Limitations:**
- Linux: NTFS-3G (FUSE) - mature but no journal replay, limited ACL mapping, no ADS/reparse points
- Linux NTFS3 (kernel, 5.15+) - better performance, similar feature gaps
- macOS: Read-only native, write via third-party (Paragon/Tuxera)
- Metadata lost on non-Windows: ADS, full ACLs, reparse points, EFS, USN journal, quotas

**Performance:**
- Sequential: Near raw device speed
- Random I/O: Good if MFT cached
- Metadata latency: Higher (MFT allocation + $Bitmap + $LogFile flushes)
- Max volume: 256 TB (4 KB clusters) / 8 PB (64 KB clusters)
- Max file: 16 EB
- Max files: ~4 billion (32-bit file reference)

**Key Weaknesses:**
1. No data checksums
2. Metadata-only journaling
3. In-place MFT updates → write amplification, SSD wear hotspots
4. Fixed $MFT location (cannot defragment)
5. No COW, no snapshots at FS level
6. Dated LZNT1 compression
7. Poor cross-platform write support
8. Offline chkdsk required for repair

---

### 1.2 ext4 (Fourth Extended Filesystem) - Linux Native

**On-Disk Format:**
- Block groups with superblock backup, group descriptors, bitmaps, inode table, data blocks
- Primary superblock at offset 1024 bytes (block 1), redundant copies per group
- Group descriptors: block/inode bitmaps, inode table, free counts, flags, checksums
- Inodes: 256 bytes fixed, extent tree (60 bytes inline for 15 extents) or legacy indirect blocks
- Extent tree: Header (magic 0xF30A) + entries (ee_block, ee_len, ee_start_hi/lo), depth up to 5
- Directory: Linear (small) or HTree (hashed B-tree, half_md4/tea hash) for large dirs
- Free space: Per-group bitmaps, mballoc (multi-block allocator) with buddy system + preallocation

**Journaling/Recovery:**
- Dedicated journal inode (default #8) with extents, uses JBD2
- Three modes: journal (full data+metadata), ordered (metadata only, data before commit), writeback (metadata only, data after commit)
- Transaction: Handle credits blocks → descriptor block → data blocks → revoke records → commit block (with checksum)
- Checkpointing: kjournald2 writes committed transactions, updates journal superblock
- Recovery: Read journal superblock → scan from s_start → replay valid transactions → handle revokes

**Integrity:**
- CRC32C (Castagnoli) for metadata (superblock, group descriptors, inode tables, extent trees, directory blocks, journal blocks)
- Hardware accelerated (SSE4.2/ARM NEON)
- Superblock, group descriptors, inode tables, extent trees have checksums (metadata_csum feature)
- NO native data checksums
- e2fsck -D verifies directory checksums, e2scrub for periodic scrubbing
- Self-healing: metadata only via e2fsck, orphan inode list recovers unlinked open files

**Compression:**
- NO native compression in mainline kernel
- Experimental patches (ext4-compress, LZ4/ZSTD per-extent) never upstreamed
- Workarounds: compFUSEd (FUSE overlay), compressed loop devices

**Flash/SSD Optimizations:**
- TRIM/discard: Full support via FITRIO ioctl, mount -o discard (async batched) or discard=sync
- Batched discard (discard=async) since kernel 5.10
- No filesystem-level wear leveling
- mballoc + delayed allocation reduce write amplification
- NO ZNS support (ext4 assumes random-write block device)

**Cross-Platform Limitations:**
- Linux: Native, full read-write
- Windows: Read-only via WSL2, no native driver (Ext2Fsd unmaintained)
- macOS: Read-only via fuse-ext2/ext4fuse, commercial Paragon ExtFS for read-write
- FreeBSD: Read-only, experimental write
- Metadata lost: xattrs, ACLs, SELinux labels, project quotas, inline data, encryption contexts, fs-verity

**Performance:**
- Sequential: ~90-95% device throughput
- Random I/O: Good metadata (extent tree O(log n) ~3-5 levels)
- Metadata ops: create/unlink ~5-10μs, stat ~1-2μs, rename ~10-20μs
- Memory: Inode cache (~1KB/inode), dentry cache, page cache, journal (128MB-4GB)
- Scalability: 1EB volume, 16TB file, ~4B files (32-bit inode count), ~10M dir entries
- Bottlenecks: Single journal (serializes metadata), global block allocation lock

**Key Weaknesses:**
1. NO native compression
2. NO native data checksums
3. NO ZNS support
4. Journal bottleneck on metadata-heavy workloads
5. No snapshots/clones
6. No built-in RAID
7. Fragmentation over time
8. Fixed inode table at mkfs
9. Poor cross-platform support
10. Offline e2fsck required (minutes to hours)

---

### 1.3 ZFS (Zettabyte File System) - Cross-Platform (OpenZFS)

**On-Disk Format:**
- Pool (zpool) → vdevs (mirror/raidz) → metaslabs → blocks
- Uberblock: Pool config, root dataset pointer, transaction group (txg) number, checksum
- Multiple uberblock copies (4) at different offsets for redundancy
- DMU (Data Management Unit): Object sets, dnodes, bonus buffers
- Dnode: 512 bytes, up to 3 block pointers inline, can spill to indirect blocks
- Block pointer: 128 bytes, contains checksum (Fletcher-2/4, SHA256, BLAKE3), compression, dedup, physical birth time, gang block support
- Copy-on-write: Never overwrite live data, write new blocks, update pointers atomically via txg commit
- SPA (Storage Pool Allocator): Metaslabs with space maps (log-structured free space tracking)

**Journaling/Recovery:**
- NO traditional journal - uses transaction groups (txg) with COW
- Txg: Open → Quiescing → Syncing → Synced
- Sync phase: Write all dirty data/metadata → write new uberblock → flush
- On mount: Read all uberblock copies, pick highest valid txg, no replay needed
- ZIL (ZFS Intent Log): Synchronous write log for POSIX fsync/O_SYNC (separate from COW)

**Integrity:**
- End-to-end checksums: Fletcher-2/4, SHA256, BLAKE3 (per-block, configurable)
- Checksum in block pointer, verified on every read
- Self-healing: Mirror/raidz reads alternate copy on checksum mismatch, repairs automatically
- Scrub: zpool scrub reads all data, verifies checksums, repairs
- RAID-Z: Parity + checksum = detection + correction

**Compression:**
- LZ4 (default, fast), ZSTD (higher ratio), LZJB, GZIP
- Per-dataset or per-file (compression=on/lz4/zstd/...)
- Transparent, random access via block pointer
- No write amplification (COW writes new compressed block)

**Flash/SSD Optimizations:**
- TRIM/discard: Full support, automatic on free
- SLOG (Separate Intent Log) on fast NVMe for sync writes
- L2ARC (Level 2 ARC) on SSD for read cache
- No ZNS native support (work in progress)
- Write amplification: COW can increase, but metaslab allocator optimizes for sequential writes

**Cross-Platform:**
- Linux: Native kernel module (OpenZFS)
- FreeBSD: Native
- macOS: OpenZFS on macOS (FUSE-based, maturing)
- Windows: No native driver (experimental ports only)
- Feature flags/compat properties for version negotiation

**Performance:**
- Sequential: Near raw device (RAID-Z overhead)
- Random I/O: ARC (adaptive replacement cache) very effective
- Metadata: Dnode/indirect blocks cached in ARC
- Memory: ARC consumes available RAM (tunable), typically 50%+ of system memory
- Scalability: 256 quadrillion zettabytes (theoretical), billions of files
- Dedup: RAM-intensive (DDT in memory)

**Key Weaknesses:**
1. High memory requirements (ARC + DDT)
2. No native encryption in early versions (now native)
3. No online shrink (only grow)
4. RAID-Z expansion limited (recently added)
5. Windows support non-existent
6. License incompatibility (CDDL vs GPL) prevents Linux kernel inclusion
7. Complexity of administration

---

### 1.4 APFS (Apple File System) - macOS/iOS Native

**On-Disk Format:**
- Container (partition) → Volumes (share space)
- Container superblock (nx_sb_t) at fixed offset
- Volume superblock (apfs_superblock_t) per volume
- Copy-on-write B-trees for all metadata (extent, inode, directory, snapshot, xattr)
- Object IDs (64-bit) for all filesystem objects
- Extents: Contiguous ranges with physical block address, length, flags
- Encryption: Per-volume or per-file (multi-key), integrated into metadata
- Snapshots: Read-only volume references, space-efficient
- Clones: Writable snapshot copies (copy-on-write)

**Journaling/Recovery:**
- COW for metadata (no traditional journal)
- Redo log for data (apfs_log_t) for crash consistency of non-COW data
- Transaction: Checkpoint creates new root nodes for all B-trees
- Recovery: Find latest valid checkpoint, verify checksums, mount
- Fusion drive support: Tiered storage (SSD + HDD)

**Integrity:**
- Fletcher-64 checksums for all metadata blocks
- Per-block checksums in B-tree nodes
- NO data checksums by default (optional with encryption)
- Space verification: apfs_fsck (fsck_apfs)

**Compression:**
- LZFSE (Apple's LZSS variant, optimized for Apple Silicon)
- Per-file transparent compression
- Random access via extent map

**Flash/SSD Optimizations:**
- Designed for flash from ground up
- TRIM/discard integrated
- I/O coalescing, write aggregation
- No ZNS support (Apple controls hardware)

**Cross-Platform:**
- macOS: Native, full features
- iOS/iPadOS: Native
- Linux: Read-only (apfs-fuse, linux-apfs-rw experimental)
- Windows: Read-only (Paragon, commercial), no native
- Metadata loss: Resource forks, Finder metadata, quarantine attrs, clones, snapshots

**Performance:**
- Optimized for Apple Silicon unified memory
- Low latency metadata ops
- Snapshots/clones near-instant
- Fusion drive tiering transparent

**Key Weaknesses:**
1. Apple-only ecosystem
2. No data checksums (unless encrypted)
3. No native Linux/Windows write support
4. Case-insensitive by default (NFD normalization causes issues)
5. No quotas
6. Repair tool limited

---

### 1.5 Btrfs (B-tree File System) - Linux

**On-Disk Format:**
- COW B-trees for everything (extent, inode, directory, root, chunk, device, free space)
- Superblock at multiple fixed offsets (64KB, 64MB, 256GB, 1TB)
- Chunk allocator: Block groups (data, metadata, system) with RAID profiles
- Extents: Inline in inode B-tree or extent tree
- Subvolumes: Independent filesystem roots within same pool
- Snapshots: Subvolume snapshots (writable)

**Journaling/Recovery:**
- COW B-trees, no separate journal
- Log tree for fsync (records pending changes)
- Transaction commit: Update root tree pointers atomically
- Recovery: Find latest consistent roots, replay log tree if needed

**Integrity:**
- CRC32C for all metadata and data (configurable)
- Self-healing on mirror/raid1/raid10 profiles
- Scrub: btrfs scrub (reads all, verifies, repairs)

**Compression:**
- LZO (default), ZSTD (since 5.1), LZ4
- Per-file (chattr +c), per-mount (compress=zstd), per-subvolume
- Transparent, random access

**Flash/SSD Optimizations:**
- TRIM/discard
- SSD mount option (spread allocations)
- No ZNS native

**Cross-Platform:**
- Linux: Native
- Other: No native support

**Key Weaknesses:**
1. RAID5/6 write hole (not fixed)
2. Fragmentation on COW workloads
3. ENOSPC issues (metadata space exhaustion)
4. No Windows/macOS support
5. Complexity of repair

---

### 1.6 F2FS (Flash-Friendly File System) - Linux/Flash

**On-Disk Format:**
- Log-structured on flash
- 6 areas: Superblock, CP (checkpoint), SIT (Segment Info Table), NAT (Node Address Table), SSA (Segment Summary Area), Main Area
- Sections → Segments (512 KB) → Blocks (4 KB)
- Node blocks: Inode, direct/indirect node blocks
- NAT maps inode→node block location
- SIT tracks segment validity for garbage collection
- Active logs: Hot (data), Warm (metadata), Cold (dirty)

**Journaling/Recovery:**
- Checkpointing: Periodic CP blocks with NAT/SIT snapshots
- Recovery: Read latest valid checkpoint, roll forward
- No traditional journal

**Integrity:**
- CRC32 for metadata
- No data checksums

**Compression:**
- LZO, LZ4, ZSTD (per-file)
- Cluster-based compression

**Flash/SSD Optimizations:**
- **Designed for flash from ground up**
- Multi-head logging (hot/warm/cold)
- Adaptive garbage collection
- TRIM/discard
- ZNS support (recent)
- Wear leveling via segment rotation

**Cross-Platform:**
- Linux: Native
- Android: Widely used
- Other: Limited

**Key Weaknesses:**
1. No native data checksums
2. Garbage collection latency spikes
3. Limited cross-platform
4. Small file performance varies

---

### 1.7 exFAT - Cross-Platform Flash

**On-Disk Format:**
- Boot sector + FAT + Cluster heap
- Simple allocation bitmap
- No journaling
- Max volume: 128 PB, max file: 16 EB
- Timestamps: 10ms resolution, UTC

**Limitations:**
- No permissions, no ACLs
- No compression, no encryption
- No integrity/checksums
- No hard links, no symlinks (reparse points only)
- Fragmentation issues
- Patent encumbered (Microsoft)

---

### 1.8 ReFS (Resilient File System) - Windows Server

**On-Disk Format:**
- B+ trees for all metadata (like NTFS but COW)
- Allocate-on-write (similar to COW)
- Integrity streams: Per-file checksums (optional)
- No legacy NTFS features (no EFS, no compression, no hard links, no object IDs, no quotas, no 8.3 names)

**Journaling/Recovery:**
- No journal - allocate-on-write + checksums
- Salvage: Online repair without downtime

**Key Weaknesses:**
1. Windows Server only
2. Missing many NTFS features
3. No cross-platform
4. No compression (removed)

---

### 1.9 XFS - Linux High-Performance

**On-Disk Format:**
- Allocation groups (AGs) for parallelism
- B+ trees for extents, inodes, directories, free space
- Dynamic inode allocation (no fixed inode table)
- Journal: Separate log (internal or external device)
- Delayed allocation

**Journaling/Recovery:**
- Metadata journal (redo log)
- Logical logging (operations not physical blocks)
- Recovery: Replay log

**Integrity:**
- CRC32C for metadata (since v5)
- No data checksums

**Key Weaknesses:**
1. No native compression
2. No snapshots/clones (requires LVM)
3. No data checksums
4. No Windows/macOS support
5. Cannot shrink

---

### 1.10 UDF (Universal Disk Format) - Optical/Cross-Platform

**On-Disk Format:**
- Designed for optical media (CD/DVD/BD)
- Multiple partition types
- Metadata: File entry, extended file entry
- Supports POSIX permissions, ACLs, xattrs
- No journaling (read-only/media)

**Limitations:**
- Not for random-write media
- No crash recovery
- Performance poor on HDD/SSD

---

## 2. Cross-Platform Metadata Interoperability Analysis

### 2.1 Metadata Models Comparison

| Feature | Windows (NTFS) | Linux (ext4) | macOS (APFS) |
|---------|---------------|--------------|--------------|
| Permissions | ACLs (SDDL) | POSIX rwx + ACLs | POSIX + ACLs |
| Owner/Group | SID | uid/gid | uid/gid |
| Timestamps | 100ns, 1601 epoch | ns, 1970 epoch | ns, 1970 epoch |
| Creation Time | Yes | ext4: yes (recent) | Yes |
| Extended Attrs | Alternate Data Streams | xattrs (namespaces) | xattrs (com.apple.*) |
| Resource Forks | N/A | N/A | Yes (as xattr) |
| Symlinks | Reparse points | Native | Native |
| Hard Links | Yes | Yes | Yes |
| Firlinks | N/A | N/A | Yes |
| Sparse Files | Yes | Yes | Yes |
| Compression | LZNT1 (per-file) | None native | LZFSE (per-file) |
| Encryption | EFS (per-file) | fscrypt (per-dir) | APFS native (per-vol/file) |
| Quotas | Yes | Yes (project) | No |
| Snapshots | VSS (block) | LVM/btrfs/ZFS | APFS native |
| Case Sensitivity | Insensitive, preserving | Sensitive | Insensitive (NFD) |
| Reserved Names | CON, PRN, AUX... | None | Unix-like |

### 2.2 Semantic Conflicts

1. **Case Sensitivity**: "File.txt" vs "file.txt" - collision on case-insensitive FS
2. **Timestamp Epoch/Resolution**: 1601 vs 1970, 100ns vs ns
3. **Permission Mapping**: Windows ACLs (DACL/SACL) ↔ POSIX ACLs - lossy
4. **Alternate Data Streams ↔ xattrs ↔ Resource Forks**: Different semantics
5. **Reparse Points ↔ Symlinks ↔ Firmlinks**: Different behaviors
6. **Windows Reserved Names**: Cannot create on Windows, valid on Linux/macOS

### 2.3 Current Solutions Failures

- **exFAT**: No permissions, ACLs, timestamps beyond FAT limits, no compression, no integrity
- **NTFS on Linux**: Loses ADS, security descriptor mapping incomplete, case sensitivity issues
- **APFS on Linux**: Read-only, no snapshot support, limited xattr
- **ext4 on Windows**: No native driver, permission mapping lossy
- **UDF**: Limited metadata, no journaling, designed for optical
- **Network FS (SMB/NFS)**: Not local filesystem solutions

---

## 3. Storage Device Behavior Analysis

### 3.1 Mechanical HDDs
- Physical geometry: platters, heads, tracks, sectors
- Seek time + rotational latency = ~5-10ms random, sequential ~100-200 MB/s
- Sequential vs random gap ~100-200x
- Zone bit recording (outer tracks faster)
- Write caching (volatile, FUA support)
- SMR complications (sequential write zones)

### 3.2 SATA SSDs
- NAND: pages (4-16 KB), blocks (256 KB-4 MB), planes, dies
- Read ~50μs, program ~200-500μs, erase ~2-5ms
- Write amplification from garbage collection
- TRIM/discard essential
- Over-provisioning critical
- SLC/MLC/TLC/QLC endurance differences
- DRAM vs DRAM-less controllers
- NCQ depth 32

### 3.3 NVMe SSDs
- PCIe, queue pairs (64K queues × 64K depth)
- Namespace support
- Commands: read, write, flush, dataset management (TRIM)
- ZNS: Sequential write zones, explicit zone management
- KV command set
- Endurance groups, NVM sets
- Thermal management, power states
- Predictable latency QoS

### 3.4 USB Flash Drives
- USB 2.0/3.x/4 bandwidth/latency
- Typically NO TRIM support
- Unpredictable controller quality
- Primitive wear leveling
- No power loss protection
- Removal without warning
- Write cache unreliable

### 3.5 SD Cards
- SD/SDHC/SDXC/SDUC capacity tiers
- UHS-I/II/III speeds
- A1/A2 (application performance), V6-V90 (video)
- NO TRIM, CMD42 discard limited
- Power loss = corruption risk
- Physical write protect switch
- Wear leveling varies wildly

### 3.6 Filesystem Implications
- Block size alignment: 512e vs 4Kn
- Allocation unit vs erase block size
- Write patterns: Sequential preferred on flash
- Metadata update frequency/location critical
- Journal placement (dedicated vs intermixed)
- Checkpoint frequency vs durability vs performance
- Compression: CPU vs write amplification trade-off
- Read-ahead/prefetch media-dependent

---

## 4. Journaling and Crash Recovery Comparison

### 4.1 Redo Journaling (Metadata-Only)
- **NTFS**: $LogFile, LFS-based, redo/undo for metadata
- **ext4 (ordered)**: JBD2, metadata journal, data before commit
- **XFS**: Metadata journal, logical logging
- **ReFS**: Redo logging with checksums

### 4.2 Undo Journaling
- **ext4 (journal)**: Full data+metadata journal
- **Btrfs/ZFS**: Not traditional - COW with intent log

### 4.3 Copy-on-Write
- **ZFS**: Transaction groups, COW tree, no separate journal
- **Btrfs**: COW B-trees, log tree for fsync
- **APFS**: COW metadata, clones for files
- **F2FS**: Log-structured, node/segment architecture

### 4.4 Key Design Questions for UFS

1. **Physical vs Logical Logging**: Block addresses vs operations
2. **Metadata-Only vs Full Data Journaling**: Performance vs integrity
3. **Ordered Data Mode Semantics**: Data before metadata commit
4. **Checkpoint Frequency**: Time-based, transaction-count, or size-based
5. **Journal Space Management**: Circular, segmented, log-structured
6. **Atomic Transaction Guarantees**: What constitutes a transaction
7. **Recovery Interruption Safety**: Idempotent replay
8. **Corrupt Journal Detection**: Per-record checksums + Merkle tree?
9. **Generation Numbers vs LSN vs Transaction IDs**: Recovery state tracking
10. **Storage Flush/FUA/Barriers**: Durability acknowledgment

### 4.5 Mandatory Crash Scenarios
- Power loss during file creation/deletion/rename
- Power loss during directory updates
- Power loss during compression
- Power loss during journal commit/checkpoint
- Interrupted journal replay
- Corrupted journal records
- Incomplete metadata updates
- Unsafe device removal

---

## 5. Compression Engine Analysis

### 5.1 Algorithms

| Algorithm | Speed | Ratio | Use Case |
|-----------|-------|-------|----------|
| LZ4 | Very Fast | ~2:1 | Real-time, metadata |
| ZSTD | Fast | ~3:1 | Balanced, configurable |
| LZO | Fast | ~2:1 | Kernel legacy |
| LZNT1 | Medium | ~2:1 | NTFS legacy |
| LZFSE | Fast (ARM) | ~2.5:1 | Apple Silicon |
| BLAKE3 | N/A | N/A | Checksumming |

### 5.2 Requirements for UFS
- Per-file or per-extent compression
- Compression metadata (original size, compressed size, algorithm ID, version)
- Checksums on compressed data
- Corruption detection
- Fallback to uncompressed when expansion
- Random access via extent index with decompression hints
- Streaming support
- Cross-platform identical decompression
- Profiles: Disabled, Fast (LZ4), Balanced (ZSTD), Maximum (ZSTD high)

---

## 6. Data Integrity and Reliability

### 6.1 Checksum Algorithms

| Algorithm | Speed | Strength | Hardware Accel |
|-----------|-------|----------|----------------|
| CRC32C | Very Fast | 32-bit | SSE4.2, ARM NEON |
| Fletcher-64 | Fast | 64-bit | Software |
| SHA256 | Medium | 256-bit | SHA-NI, ARMv8 |
| BLAKE3 | Very Fast | 256-bit | SIMD, multi-thread |

### 6.2 Scope of Checksumming
- **Metadata only**: ext4, NTFS (USA), XFS, APFS (Fletcher-64)
- **Metadata + Data**: ZFS, Btrfs, ReFS (integrity streams)
- **Journal**: ext4, ZFS (ZIL), NTFS (USA)

### 6.3 Repair Mechanisms
- **ZFS**: Mirror/raidz self-heal on read, scrub for proactive
- **Btrfs**: Mirror self-heal, scrub
- **ReFS**: Salvage (online repair)
- **NTFS/ext4**: Offline chkdsk/e2fsck only
- **APFS**: fsck_apfs (limited)

---

## 7. Identified Gaps and Opportunities

### 7.1 Problems Not Adequately Solved

1. **Universal Metadata Interoperability**: No filesystem preserves all metadata when moving between Windows/Linux/macOS
2. **Portable Crash Recovery**: Journal replay is OS-specific (Windows driver vs Linux kernel vs macOS FSKit)
3. **Adaptive Storage Behavior**: Filesystems assume one storage behavior; real devices vary wildly
4. **Integrated Compression + Integrity**: Compression and checksums are separate layers; compressed data corruption is silent
5. **Cross-Platform Native Drivers**: No filesystem has native read-write drivers on all three major OSes

### 7.2 Innovation Candidates

See UFS-INNOVATION-REPORT.md for detailed analysis.

---

## 8. Sources

### Primary Technical Sources
1. **Windows**: Microsoft IFS Documentation, Windows Internals (Yosifovich/Russinovich), NTFS-3G source, Linux NTFS3 source
2. **Linux**: kernel.org filesystem docs (ext4, btrfs, f2fs, xfs), e2fsprogs docs, Linux kernel source (fs/ext4, fs/btrfs, fs/f2fs)
3. **Apple**: APFS Reference (developer.apple.com), xnu source (github.com/apple-oss-distributions/xnu)
4. **ZFS**: OpenZFS docs (openzfs.github.io), OpenZFS source (github.com/openzfs/zfs), "The ZFS Filesystem" (Bonwick 2003)
5. **Standards**: NVMe spec, SATA spec, SD spec, USB spec, UEFI spec
6. **Academic**: 
   - "Journaling the ext2 File System" (Best 1999)
   - "XFS: A High-Performance Journaling File System" (Sweeney 1996)
   - "The ZFS Filesystem" (Bonwick 2003)
   - "F2FS: Flash-Friendly File System" (Kim 2015)
   - "Log File Service (LFS)" (Rosenblum & Ousterhout 1992)
   - "Understanding the Robustness of SSDs Under Power Fault" (FAST)
   - "A Measurement Study of Flash Drive Performance" (FAST)

---

*End of Technical Research Report*