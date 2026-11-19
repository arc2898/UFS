# UFS v1 On-Disk Format Specification

**Version:** 1.0 (Draft)
**Date:** 2026-11-14
**Status:** Specification Phase

---

## 1. Overview

This document defines the complete byte-level on-disk format for UFS v1. All structures use the canonical serialization defined in ADR-001 (little-endian, explicit widths, no padding, CRC32C per structure).

### 1.1 Design Constants

| Constant | Value | Description |
|----------|-------|-------------|
| `MAGIC_UFS` | 0x55465300 | "UFS\0" - Primary superblock magic |
| `MAGIC_JOURNAL` | 0x4A55524E | "JURN" - Journal superblock magic |
| `MAGIC_TRANSACTION` | 0x54584E00 | "TXN\0" - Journal transaction magic |
| `MAGIC_AG` | 0x41470000 | "AG\0\0" - Allocation group header magic |
| `MAGIC_INODE` | 0x494E4F00 | "INO\0" - Inode magic |
| `MAGIC_EXTENT` | 0x45585400 | "EXT\0" - Extent tree node magic |
| `MAGIC_DIR_SMALL` | 0x44495200 | "DIR\0" - Linear directory magic |
| `MAGIC_DIR_TREE` | 0x44545200 | "DTR\0" - B+ tree directory magic |
| `MAGIC_FREE_TREE` | 0x46524500 | "FRE\0" - Free extent tree magic |
| `MAGIC_CAPSULE` | 0x43415053 | "CAPS" - Metadata capsule magic |
| `VERSION_MAJOR` | 1 | Format major version |
| `VERSION_MINOR` | 0 | Format minor version |
| `VERSION_REVISION` | 0 | Format revision |
| `DEFAULT_CLUSTER_SIZE` | 4096 | Default cluster size in bytes |
| `DEFAULT_AG_SIZE` | 1,073,741,824 | Default AG size in clusters (1 GB at 4KB) |
| `DEFAULT_INODES_PER_AG` | 512 | Default inodes per allocation group |

---

## 2. Volume Layout

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              UFS VOLUME                                     │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  Sector 0 (512 bytes):     ┌──────────────────────────────────────────┐   │
│  ┌─────────────────────┐   │           PRIMARY SUPERBLOCK             │   │
│  │    BOOT SECTOR      │   │  (Offset: 1 cluster = 4096 bytes)        │   │
│  │  (BPB + Boot Code)  │   │  Magic, Version, Feature Flags,          │   │
│  └─────────────────────┘   │  Volume UUID, Size, Cluster Size,        │   │
│                            │  Root Inode, Journal Loc, AGs,           │   │
│  Sector 1-7 (reserved):    │  Checksums, Clean Flag)                  │   │
│  ┌─────────────────────┐   └──────────────────────────────────────────┘   │
│  │    RESERVED         │                                                 │
│  │  (Backup Super #0)  │   ┌──────────────────────────────────────────┐   │
│  └─────────────────────┘   │             JOURNAL AREA                 │   │
│                            │  (Configurable offset, default after     │   │
│  ┌─────────────────────┐   │   superblock, 64 MB default)             │   │
│  │  ALLOCATION GROUP 0 │   │  Journal Superblock + Circular Log       │   │
│  │  ┌───────────────┐  │   │  + Checkpoint Records                    │   │
│  │  │ AG Header     │  │   └──────────────────────────────────────────┘   │
│  │  │ Free Tree     │  │                                                 │
│  │  │ Bitmap        │  │   ┌──────────────────────────────────────────┐   │
│  │  │ Inode Table   │  │   │         ALLOCATION GROUP 1...N           │   │
│  │  │ Data Blocks   │  │   │  ┌────────────────────────────────────┐  │   │
│  │  └───────────────┘  │   │  │ AG Header                          │  │   │
│  └─────────────────────┘   │  │ Free Extent Tree (B+ tree)         │  │   │
│                            │  │ Allocation Bitmap                  │  │   │
│  ┌─────────────────────┐   │  │ Inode Table                        │  │   │
│  │  ALLOCATION GROUP 1 │   │  │ Data Blocks                        │  │   │
│  │  (same structure)   │   │  └────────────────────────────────────┘  │   │
│  └─────────────────────┘   └──────────────────────────────────────────┘   │
│         ...                                                            │   │
│                                                                        │   │
│   ┌────────────────────────────────────────────────────────────────┐   │
│   │              BACKUP SUPERBLOCKS (fixed offsets)                │   │
│   │  64 KB, 64 MB, 256 GB, 1 TB, Volume_End - 64 KB               │   │
│   └────────────────────────────────────────────────────────────────┘   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 2.1 Cluster Addressing

- All block addresses are **cluster-relative** (not byte offsets)
- Cluster 0 = byte offset 0 (boot sector)
- Cluster 1 = byte offset `cluster_size` (primary superblock)
- Maximum addressable clusters: 2^64 - 1
- Maximum volume size: 256 TB (at 4KB clusters)

---

## 3. Primary Superblock

**Location:** Cluster 1 (byte offset `cluster_size`)
**Size:** Exactly 1 cluster (4096 bytes default)
**Redundancy:** Backup copies at fixed offsets

### 3.1 Structure Definition

```zig
Superblock {
    // Header (8 bytes)
    u32 magic;                    // 0x55465300 ("UFS\0")
    u16 version_major;            // 1
    u16 version_minor;            // 0
    u32 version_revision;         // 0
    
    // Feature Flags (12 bytes)
    u32 feature_incompat;         // INCOMPAT_* bits
    u32 feature_compat_ro;        // COMPAT_RO_* bits
    u32 feature_compat_rw;        // COMPAT_RW_* bits
    
    // Volume Geometry (24 bytes)
    u64 volume_size;              // Total clusters in volume
    u32 cluster_size;             // Bytes per cluster (4096 default)
    u32 sector_size;              // Physical sector size (512/4096)
    
    // Volume Identity (80 bytes)
    u8[16] volume_uuid;           // UUIDv7 (time-ordered)
    u8[64] volume_label;          // UTF-8, null-terminated
    
    // Key Locations (40 bytes)
    u64 root_inode;               // Inode number of root directory
    u64 journal_offset;           // Cluster offset of journal area
    u64 journal_size;             // Journal size in clusters
    u32 ag_count;                 // Number of allocation groups
    u32 ag_size;                  // Clusters per AG
    u64 ag_table_offset;          // Cluster offset of AG table (if external)
    u64 first_ag_offset;          // Cluster offset of first AG
    
    // Backup Superblock Offsets (64 bytes)
    u64[8] backup_sb_offsets;     // Cluster offsets of backup superblocks
    
    // Runtime State (17 bytes)
    u64 generation;               // Incremented on each mount
    u8 clean_flag;                // 0=dirty, 1=clean, 2=needs_check
    u8[7] reserved;               // Zeroed
    
    // Checksum (4 bytes)
    u32 crc32c;                   // CRC32C of all preceding bytes
}
```

**Total Size:** 256 bytes (padded to cluster boundary)

### 3.2 Feature Flag Definitions

#### Incompatible Features (INCOMPAT)
| Bit | Name | Description |
|-----|------|-------------|
| 0 | ENCRYPTION | Per-file encryption active |
| 1 | SNAPSHOTS | Snapshot support enabled |
| 2 | DEDUP | Deduplication enabled |
| 3 | QUOTAS | Quota enforcement active |
| 4 | ZNS | Zoned namespace support |
| 5 | CASE_INSENSITIVE | Volume is case-insensitive |
| 6 | VERITY | fs-verity style integrity |

#### Read-Only Compatible (COMPAT_RO)
| Bit | Name | Description |
|-----|------|-------------|
| 0 | COMPRESSION_LZ4 | LZ4 compressed extents present |
| 1 | COMPRESSION_ZSTD | ZSTD compressed extents present |
| 2 | COMPRESSION_ZSTD_HIGH | ZSTD high compression present |
| 3 | CASE_INSENSITIVE | Case-insensitive dir indexing |
| 4 | METADATA_CSUMS | Metadata checksums enabled |
| 5 | PROJECT_QUOTA | Project quota tracking |
| 6 | INLINE_DATA | Inline data in inodes |

#### Read-Write Compatible (COMPAT_RW)
| Bit | Name | Description |
|-----|------|-------------|
| 0 | XATTR | Extended attributes |
| 1 | ACL | POSIX ACLs |
| 2 | WINDOWS_META | Windows metadata namespaces |
| 3 | MACOS_META | macOS metadata namespaces |
| 4 | SYMLINKS | Symbolic links |
| 5 | HARDLINKS | Hard links |
| 6 | REPARSE | Reparse points |
| 7 | SPARSE | Sparse files |

### 3.3 Backup Superblock Locations

| Index | Offset (clusters) | Description |
|-------|-------------------|-------------|
| 0 | 16 | 64 KB (16 × 4KB) |
| 1 | 16,384 | 64 MB |
| 2 | 67,108,864 | 256 GB |
| 3 | 268,435,456 | 1 TB |
| 4 | `volume_size - 16` | End - 64 KB |
| 5-7 | 0 | Reserved (zero = not present) |

---

## 4. Journal Area

**Location:** `journal_offset` clusters from volume start
**Size:** `journal_size` clusters (default 16,384 = 64 MB)

### 4.1 Journal Superblock

**Location:** First cluster of journal area
**Size:** 1 cluster

```zig
JournalSuperblock {
    u32 magic;                // 0x4A55524E ("JURN")
    u16 version;              // 1
    u16 flags;                // JournalFlags bitfield
    u64 start_txn;            // First valid transaction ID
    u64 end_txn;              // Last valid transaction ID
    u64 last_checkpoint;      // Byte offset of last checkpoint
    u64 size;                 // Journal size in bytes
    u32 crc32c;               // CRC32C of all above
    // Padding to cluster size
}
```

### 4.2 Transaction Record

```zig
Transaction {
    u32 magic;                // 0x54584E00 ("TXN\0")
    u64 txid;                 // Monotonically increasing
    u64 timestamp;            // Nanoseconds since epoch
    u32 operation_count;      // Number of operations
    u32 flags;                // Transaction flags
    Operation[operation_count] operations;  // Variable
    u32 crc32c;               // CRC32C of all above
}
```

### 4.3 Operation Types

| Type | Value | Payload Structure |
|------|-------|-------------------|
| CREATE_INODE | 1 | `OpCreateInode` |
| DELETE_INODE | 2 | `OpDeleteInode` |
| UPDATE_INODE_META | 3 | `OpUpdateInodeMeta` |
| LINK_DIRENT | 4 | `OpLinkDirent` |
| UNLINK_DIRENT | 5 | `OpUnlinkDirent` |
| RENAME_DIRENT | 6 | `OpRenameDirent` |
| ALLOCATE_EXTENT | 7 | `OpAllocateExtent` |
| DEALLOCATE_EXTENT | 8 | `OpDeallocateExtent` |
| UPDATE_BITMAP | 9 | `OpUpdateBitmap` |
| UPDATE_SUPERBLOCK | 10 | `OpUpdateSuperblock` |
| CHECKPOINT | 11 | `OpCheckpoint` |
| SET_XATTR | 12 | `OpSetXattr` |
| REMOVE_XATTR | 13 | `OpRemoveXattr` |
| UPDATE_CAPSULE | 14 | `OpUpdateCapsule` |

### 4.4 Operation Payloads

```zig
OpCreateInode {
    u64 inode;              // New inode number
    u64 parent;             // Parent directory inode
    u16 name_len;           // Name length
    u8[name_len] name;      // UTF-8 name
    u32 mode;               // File mode/permissions
    u32 uid;                // Owner UID
    u32 gid;                // Owner GID
    u64 capsule_id;         // Metadata capsule UUID
}

OpLinkDirent {
    u64 parent;             // Parent directory inode
    u16 name_len;
    u8[name_len] name;
    u64 child;              // Child inode
    u8 file_type;           // FILE_TYPE_*
}

OpAllocateExtent {
    u64 inode;              // File inode
    u64 logical_offset;     // Logical cluster offset in file
    u64 physical_block;     // Physical cluster on disk
    u32 length;             // Cluster count
    u16 compression_algo;   // COMPRESSION_*
}

OpUpdateInodeMeta {
    u64 inode;
    u32 field_mask;         // Bitmask of changed fields
    u32 mode;
    u32 uid;
    u32 gid;
    u64 size;               // File size in bytes
    u64 atime;              // Access time (ns)
    u64 mtime;              // Modify time (ns)
    u64 ctime;              // Change time (ns)
    u32 flags;              // Inode flags
    u64 capsule_id;         // Updated capsule
}

OpCheckpoint {
    u64 superblock_generation;
    u32 ag_count;
    u64[ag_count] ag_generations;
}
```

---

## 5. Allocation Groups

Each AG is a self-contained unit of allocation with independent metadata.

### 5.1 AG Header

**Location:** First cluster of each AG
**Size:** 1 cluster

```zig
AGHeader {
    u32 magic;              // 0x41470000 ("AG\0\0")
    u16 version;            // 1
    u16 flags;              // AG flags
    u32 ag_index;           // 0-based AG index
    u64 ag_offset;          // Cluster offset of this AG start
    u32 ag_size;            // Clusters in this AG
    u32 cluster_size;       // Bytes per cluster
    u64 free_clusters;      // Free cluster count
    u64 free_extents;       // Free extent count
    u64 free_tree_root;     // Cluster of free extent tree root
    u64 bitmap_offset;      // Cluster offset of allocation bitmap
    u64 inode_table_offset; // Cluster offset of inode table
    u32 inode_count;        // Total inodes in this AG
    u32 free_inodes;        // Free inode count
    u64 generation;         // Incremented on each modification
    u32 crc32c;             // CRC32C of all above
}
```

### 5.2 Allocation Bitmap

**Location:** `bitmap_offset` clusters from AG start
**Size:** `ceil(ag_size / 8)` bytes, rounded up to cluster boundary
**Format:** 1 bit per cluster (0 = free, 1 = allocated)
- Bit 0 of byte 0 = cluster 0 of AG
- Little-endian bit ordering within bytes

### 5.3 Inode Bitmap

**Location:** Immediately before inode table
**Size:** `ceil(inode_count / 8)` bytes, rounded up to cluster boundary
**Format:** 1 bit per inode (0 = free, 1 = allocated)

### 5.4 Inode Table

**Location:** `inode_table_offset` clusters from AG start
**Size:** `inode_count × 256` bytes (1 cluster per 16 inodes at 4KB)

Each inode is exactly 256 bytes:

```zig
Inode {
    // Header (12 bytes)
    u32 magic;              // 0x494E4F00 ("INO\0")
    u16 version;            // 1
    u16 flags;              // InodeFlags bitfield
    
    // Identity (24 bytes)
    u64 inode_number;       // Absolute inode number
    u64 generation;         // Inode generation
    u64 capsule_id;         // Metadata capsule UUID
    
    // File Info (24 bytes)
    u32 mode;               // File type + permissions
    u32 uid;                // Owner UID
    u32 gid;                // Owner GID
    u32 link_count;         // Hard link count
    u32 flags2;             // Extended flags
    u32 reserved1;
    
    // Size & Timestamps (40 bytes)
    u64 size;               // File size in bytes
    u64 allocated_size;     // Allocated size in bytes
    u64 atime;              // Access time (ns since epoch)
    u64 mtime;              // Modify time (ns since epoch)
    u64 ctime;              // Change time (ns since epoch)
    
    // Extent Tree Root (16 bytes)
    u64 extent_tree_root;   // Cluster of extent tree root (0 = inline)
    u16 extent_count;       // Number of extents
    u16 extent_tree_height; // Tree height (0 = inline)
    u32 reserved2;
    
    // Compression/Encryption (16 bytes)
    u16 compression_algo;   // Default for new extents
    u16 compression_level;  // Default level
    u32 encryption_key_id;  // Key ID if encrypted
    u64 reserved3;
    
    // Capsule Reference (16 bytes)
    u64 capsule_offset;     // Cluster offset of capsule (0 = inline)
    u32 capsule_size;       // Capsule size in bytes
    u32 capsule_flags;      // CapsuleFlags
    
    // Reserved for expansion (112 bytes)
    u8[112] reserved;
    
    // Checksum (4 bytes)
    u32 crc32c;
}
```

### 5.5 Inode Flags

| Bit | Name | Value | Description |
|-----|------|-------|-------------|
| 0 | COMPRESSED | 0x0001 | File has compressed extents |
| 1 | ENCRYPTED | 0x0002 | File is encrypted |
| 2 | SPARSE | 0x0004 | File has sparse extents |
| 3 | IMMUTABLE | 0x0008 | Cannot be modified |
| 4 | APPEND_ONLY | 0x0010 | Append-only file |
| 5 | NOATIME | 0x0020 | Don't update atime |
| 6 | NODUMP | 0x0040 | Exclude from backups |
| 7 | SYNC | 0x0080 | Synchronous writes |
| 8 | CASE_INSENSITIVE | 0x0100 | Case-insensitive dir |
| 9 | HAS_CAPSULE | 0x0200 | Has metadata capsule |

---

## 6. Extent Trees

Extent trees are B+ trees mapping logical file offsets to physical clusters.

### 6.1 Extent Tree Node

**Size:** 1 cluster

```zig
ExtentNode {
    u32 magic;              // 0x45585400 ("EXT\0")
    u16 version;            // 1
    u16 flags;              // Node flags
    u16 entry_count;        // Number of entries
    u16 max_entries;        // Max entries (fixed per cluster size)
    u16 is_leaf;            // 1 = leaf, 0 = internal
    u16 level;              // Tree level (0 = leaf)
    ExtentEntry[entry_count] entries;
    u32 crc32c;
}
```

### 6.2 Extent Entry (Leaf)

```zig
ExtentEntry {
    u64 logical_offset;     // Starting logical cluster in file
    u64 physical_block;     // Starting physical cluster on disk
    u32 length;             // Cluster count
    u16 compression_algo;   // COMPRESSION_*
    u16 flags;              // ExtentFlags
    u32 original_length;    // Uncompressed cluster count
    u32 compressed_length;  // Compressed cluster count
    u32 crc32c_header;      // CRC32C of extent header
    u8[32] blake3_hash;     // BLAKE3 of compressed data
}
```

### 6.3 Extent Entry (Internal)

```zig
ExtentEntryInternal {
    u64 max_logical_offset; // Max logical offset in subtree
    u64 child_block;        // Child node cluster
}
```

### 6.4 Inline Extents

If `extent_count ≤ 4` and `extent_tree_root == 0`, extents are stored inline in the inode (in `reserved` space).

---

## 7. Free Extent Tree

B+ tree tracking free space within an AG, keyed by starting cluster.

### 7.1 Free Extent Node

```zig
FreeExtentNode {
    u32 magic;              // 0x46524500 ("FRE\0")
    u16 version;
    u16 flags;
    u16 entry_count;
    u16 max_entries;
    u16 is_leaf;
    u16 level;
    FreeEntry[entry_count] entries;
    u32 crc32c;
}
```

### 7.2 Free Entry (Leaf)

```zig
FreeEntry {
    u64 start_cluster;      // Starting cluster (AG-relative)
    u64 length;             // Cluster count
}
```

### 7.3 Free Entry (Internal)

```zig
FreeEntryInternal {
    u64 max_start_cluster;  // Max start in subtree
    u64 child_block;        // Child node cluster (AG-relative)
}
```

---

## 8. Directories

Hybrid structure: linear array (≤ 64 entries) or B+ tree (> 64).

### 8.1 Linear Directory

**Stored:** Inline in parent inode's data area (or as single extent)

```zig
LinearDirectory {
    u32 magic;              // 0x44495200 ("DIR\0")
    u16 version;
    u16 entry_count;
    DirEntry[entry_count] entries;
    u32 crc32c;
}
```

### 8.2 Directory Entry

```zig
DirEntry {
    u64 inode;              // Child inode number
    u16 name_length;
    u8 file_type;           // FILE_TYPE_*
    u8 flags;               // Entry flags
    u8[name_length] name;   // UTF-8, case-preserved
    // Padding to 8-byte boundary
}
```

### 8.3 File Types

| Value | Name | Description |
|-------|------|-------------|
| 1 | REG | Regular file |
| 2 | DIR | Directory |
| 3 | SYMLINK | Symbolic link |
| 4 | CHRDEV | Character device |
| 5 | BLKDEV | Block device |
| 6 | FIFO | Named pipe |
| 7 | SOCKET | Unix socket |
| 8 | REPARSE | Reparse point |

### 8.4 B+ Tree Directory

**Root:** Referenced from parent inode's extent tree (special extent with `flags` bit set)

```zig
DirTreeNode {
    u32 magic;              // 0x44545200 ("DTR\0")
    u16 version;
    u16 flags;
    u16 entry_count;
    u16 max_entries;
    u16 is_leaf;
    u16 level;
    DirTreeEntry[entry_count] entries;
    u32 crc32c;
}
```

### 8.5 Dir Tree Entry (Leaf)

```zig
DirTreeEntry {
    u64 key_hash;           // FNV-1a hash of case-folded name
    u64 inode;              // Child inode
    u16 name_length;
    u8[name_length] name;   // Full name for collision resolution
}
```

### 8.6 Dir Tree Entry (Internal)

```zig
DirTreeEntryInternal {
    u64 max_key_hash;       // Max hash in subtree
    u64 child_block;        // Child node cluster
}
```

### 8.7 Case Handling

- Comparison: Unicode NFD + case-fold (Unicode 15.0)
- Storage: Case-preserved (original UTF-8)
- Windows reserved names rejected: CON, PRN, AUX, NUL, COM1-9, LPT1-9
- Trailing dots/spaces rejected

---

## 9. Metadata Capsules

Extensible, namespaced containers for cross-platform metadata.

### 9.1 Capsule Header

```zig
CapsuleHeader {
    u32 magic;              // 0x43415053 ("CAPS")
    u16 version;            // 1
    u16 flags;              // CapsuleFlags
    u64 capsule_id;         // UUIDv7
    u64 inode;              // Owning inode
    u32 entry_count;
    u32 size;               // Total size including header
    u32 crc32c;             // CRC32C of all entries + header
}
```

### 9.2 Capsule Flags

| Bit | Name | Description |
|-----|------|-------------|
| 0 | INLINE | Stored inline in inode |
| 1 | COMPRESSED | Capsule data compressed |
| 2 | ENCRYPTED | Capsule data encrypted |
| 3 | SIGNED | Cryptographically signed |

### 9.3 Capsule Entry

```zig
CapsuleEntry {
    u16 namespace;          // Namespace ID
    u16 type;               // Type within namespace
    u16 flags;              // Entry flags
    u16 name_length;
    u32 value_length;
    u8[name_length] name;   // Entry name (UTF-8)
    u8[value_length] value; // Entry value (binary)
    u32 crc32c;             // CRC32C of name + value
}
```

### 9.4 Standard Namespaces

| ID | Name | Description |
|----|------|-------------|
| 0x0001 | POSIX_BASE | mode, uid, gid, timestamps, link_count |
| 0x0002 | POSIX_ACL | NFSv4 ACL |
| 0x0003 | POSIX_XATTR | Extended attributes (user.*, system.*, etc.) |
| 0x0004 | POSIX_CAPS | File capabilities |
| 0x0010 | WINDOWS_SD | Security Descriptor (binary SDDL) |
| 0x0011 | WINDOWS_ADS | Alternate Data Streams |
| 0x0012 | WINDOWS_REPARSE | Reparse points |
| 0x0013 | WINDOWS_EFS | EFS encryption |
| 0x0014 | WINDOWS_USN | USN Journal |
| 0x0015 | WINDOWS_OBJID | Object ID |
| 0x0016 | WINDOWS_ATTRS | FILE_ATTRIBUTE_* |
| 0x0020 | MACOS_XATTR | com.apple.* extended attributes |
| 0x0021 | MACOS_FINDER | Finder metadata (tags, labels) |
| 0x0022 | MACOS_RESOURCE | Resource fork |
| 0x0023 | MACOS_QUARANTINE | Quarantine attributes |
| 0x0024 | MACOS_FIRMLINK | Firmlink |
| 0x0025 | MACOS_TIMESTAMP | Creation time |
| 0x8000 | UFS_INTERNAL | Compression, checksums, extent refs |
| 0xFFFF | OPAQUE | Unknown/opaque metadata |

### 9.5 POSIX_BASE Entry Types

| Type | Name | Value Format |
|------|------|--------------|
| 0x0001 | mode_uid_gid | u32 mode, u32 uid, u32 gid |
| 0x0002 | timestamps | u64 atime, mtime, ctime, crtime |
| 0x0003 | link_count | u32 link_count |

---

## 10. Compression

### 10.1 Algorithms

| ID | Name | Description |
|----|------|-------------|
| 0 | NONE | No compression |
| 1 | LZ4 | Fast compression (LZ4 frame format) |
| 2 | ZSTD | Balanced (ZSTD level 3) |
| 3 | ZSTD_HIGH | Maximum ratio (ZSTD level 12) |

### 10.2 Pipeline

```
Plaintext Data → Compress (LZ4/ZSTD) → BLAKE3 Checksum → Encrypt (if enabled) → Write
```

### 10.3 Incompressible Detection

- Sample first 256 bytes
- Shannon entropy > 7.5 bits/byte → store uncompressed
- Known compressed signatures (PK, gzip, BZh, XZ, LZ4, ZSTD) → store uncompressed

---

## 11. Integrity

### 11.1 Metadata: CRC32C (Castagnoli)

- Polynomial: 0x1EDC6F41 (reversed: 0x82F63B78)
- Initial: 0xFFFFFFFF
- Final XOR: 0xFFFFFFFF
- Hardware accelerated (SSE4.2, ARM CRC32, CLMUL)

### 11.2 Data: BLAKE3

- 256-bit output
- SIMD optimized (AVX2, NEON)
- Used for: extent data, journal transactions, capsules

### 11.3 Verification Points

| Structure | Checksum | Verified On |
|-----------|----------|-------------|
| Superblock | CRC32C | Mount, periodic scrub |
| AG Header | CRC32C | Mount, allocation |
| Inode | CRC32C | Inode read/write |
| Extent Node | CRC32C | Tree traversal |
| Directory | CRC32C | Directory read |
| Journal Transaction | CRC32C | Replay, verification |
| Capsule | CRC32C | Capsule read |
| Extent Data | BLAKE3 | Read, scrub |

---

## 12. Versioning & Compatibility

### 12.1 Mount Decision Algorithm

```
IF (volume.incompat & ~supported_incompat) != 0:
    REJECT (cannot mount read-only or read-write)
ELSE IF (volume.compat_ro & ~supported_compat_ro) != 0:
    MOUNT READ-ONLY
ELSE:
    MOUNT READ-WRITE
    IGNORE unknown compat_rw features
```

### 12.2 Format Evolution Rules

1. **Major version bump**: Requires migration tool, all bets off
2. **Minor version bump**: Backward-compatible additions only
3. **New INCOMPAT bit**: Cannot mount without support
4. **New COMPAT_RO bit**: Can mount read-only, not read-write
5. **New COMPAT_RW bit**: Can mount read-write, feature ignored

---

## 13. Limits & Constraints

| Limit | Value | Notes |
|-------|-------|-------|
| Max volume size | 256 TB | 64-bit cluster addressing, 4KB clusters |
| Max file size | 16 EB | 64-bit file size field |
| Max files per volume | 4 billion | 32-bit inode reference per AG |
| Max files per AG | 4 billion | 32-bit inode_count |
| Max extents per file | 2^32-1 | 32-bit extent_count |
| Max directory entries | 2^32-1 | 32-bit entry_count |
| Max xattr size | 64 KB | Per attribute |
| Max capsule size | 1 MB | Inline: 256 bytes |
| Max pathname | 4096 bytes | Component: 255 bytes |
| Cluster size | 512, 1024, 2048, 4096, 8192, 16384, 32768, 65536 | Power of 2 |
| AG size | 1 MB - 1 TB | Multiple of cluster size |

---

## 14. Boot Sector (Sector 0)

Standard MBR/GPT compatible boot sector for UEFI/BIOS recognition.

```zig
BootSector {
    u8[3] jump;             // 0xEB 0x3C 0x90 (jmp short)
    u8[8] oem_id;           // "UFS     "
    u16 bytes_per_sector;   // 512
    u8 sectors_per_cluster; // cluster_size / 512
    u16 reserved_sectors;   // 1 (superblock at sector 1)
    u8 fat_count;           // 0 (not FAT)
    u16 root_dir_entries;   // 0
    u16 total_sectors_16;   // 0
    u8 media_descriptor;    // 0xF8
    u16 sectors_per_fat_16; // 0
    u16 sectors_per_track;  // 63
    u16 heads;              // 255
    u32 hidden_sectors;     // 0
    u32 total_sectors_32;   // volume_size * cluster_size / 512
    // Extended BPB (FAT32 style but for UFS)
    u32 sectors_per_fat_32; // 0
    u16 flags;              // 0
    u16 fs_version;         // 0
    u32 root_cluster;       // 2 (first data cluster)
    u16 fs_info_sector;     // 1 (superblock sector)
    u16 backup_boot_sector; // 6
    u8[12] reserved;
    u8 drive_number;        // 0x80
    u8 reserved1;           // 0
    u8 boot_signature;      // 0x29
    u32 volume_id;          // Low 32 bits of UUID
    u8[11] volume_label;    // "UFS VOLUME "
    u8[8] fs_type;          // "UFS     "
    u8[420] boot_code;      // Bootloader code or zeros
    u16 boot_signature;     // 0xAA55
}
```

---

## 15. Example: Minimal Volume (1 GB)

```
Cluster size: 4096 bytes
Volume size: 262,144 clusters (1 GB)
AG size: 262,144 clusters (1 AG)
Inodes per AG: 512
Journal size: 16,384 clusters (64 MB)

Layout:
Cluster 0:          Boot Sector (512B) + zeros
Cluster 1:          Primary Superblock
Clusters 2-17:      Reserved / Backup SB #0 (cluster 16)
Clusters 18-16,398: Journal Area (16,384 clusters)
Cluster 16,399:     AG 0 Header
Clusters 16,400-16,401: Allocation Bitmap (2 clusters = 8192 bits)
Cluster 16,402:     Inode Bitmap (1 cluster)
Clusters 16,403-16,434: Inode Table (32 clusters = 512 inodes × 256B)
Clusters 16,435+:   Data Blocks
Cluster 262,128:    Backup SB #4 (end - 16)
```

---

## 16. CRC32C Computation Example

For any structure, the CRC32C covers all bytes **before** the `crc32c` field:

```zig
fn computeCrc32c(data: []const u8) u32 {
    var crc: u32 = 0xFFFFFFFF;
    for (data) |byte| {
        crc = TABLE[(crc ^ byte) & 0xFF] ^ (crc >> 8);
    }
    return ~crc;
}

// Verify:
const stored_crc = structure.crc32c;
const computed_crc = computeCrc32c(structure_bytes[0..offset_of_crc32c]);
assert(stored_crc == computed_crc);
```

---

## 17. Changelog

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2026-11-14 | Initial complete specification |

---

*End of UFS v1 On-Disk Format Specification*