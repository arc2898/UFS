# ADR-003: Block Allocation Strategy

**Status:** Accepted
**Date:** 2026-11-13
**Deciders:** Project U Architecture Team

## Context

UFS needs a block allocation strategy that works across HDDs, SATA SSDs, NVMe SSDs, USB flash, and SD cards. Requirements:
- Fast allocation/deallocation
- Low fragmentation
- Efficient free space tracking
- Media-aware behavior (sequential on HDD, parallel on NVMe, minimal writes on USB/SD)
- Support for large volumes (up to 256 TB+)
- Extent-based allocation for large files

## Decision

**UFS uses extent-based allocation with allocation groups and a hybrid free space tracker (B-tree + bitmap).**

### Allocation Group Architecture

- Volume divided into **Allocation Groups (AGs)** of configurable size (default 1 GB)
- Each AG manages its own free space independently (reduces lock contention)
- AG count scales with volume size (minimum 4 AGs, maximum 4096 AGs)
- Per-AG metadata: free space tree, allocation bitmap, statistics

### Free Space Tracking (Hybrid)

#### Primary: Extent B-Tree (per AG)
```
FreeExtentTree (B+ tree):
    Key: (starting_block, length)
    Value: empty (existence = free)
    Operations: find_first_fit, find_best_fit, insert, delete, split, merge
```

- Efficient for large free extents
- Supports find_first_fit (HDD) and find_best_fit (SSD) policies
- Logarithmic complexity for all operations

#### Secondary: Allocation Bitmap (per AG)
- 1 bit per cluster (cluster = allocation unit, default 4 KB)
- Used for: small allocations (< 64 KB), fragmentation analysis, TRIM batching
- Updated lazily (batch commits) for performance

#### Cluster Size
- **Default**: 4 KB (matches page size, NVMe sector, common SSD erase block fraction)
- **Configurable**: 4 KB, 8 KB, 16 KB, 32 KB, 64 KB, 128 KB
- **Selection**: Based on volume size and expected workload
  - < 32 GB: 4 KB
  - 32 GB - 2 TB: 4 KB or 8 KB
  - > 2 TB: 8 KB or 16 KB (reduces metadata overhead)

### Allocation Policies (Media-Aware)

| Media Type | Policy | Rationale |
|------------|--------|-----------|
| HDD (rotational) | First-fit, large extents, locality | Minimize seeks, sequential writes |
| SATA SSD | Best-fit, moderate extents | Reduce fragmentation, GC-friendly |
| NVMe SSD | Best-fit, parallel AGs, minimal flush | Leverage parallelism, low latency |
| USB Flash | First-fit, large extents, batch metadata | Minimize writes, no TRIM assumption |
| SD Card | First-fit, large extents, sync-on-close | Power-loss safety, no TRIM |

Policy selected at mount time via device characterization (see ADR-011).

### Extent Representation

```
Extent {
    u64 logical_offset;    // File-relative block offset
    u64 physical_block;    // Absolute block address
    u32 length;            // Number of clusters
    u16 flags;             // COMPRESSED, ENCRYPTED, SPARSE, etc.
    u16 compression_algo;  // If COMPRESSED: LZ4=1, ZSTD=2
    u32 crc32c;            // Checksum of compressed data (if applicable)
}
```

- Stored in inode (inline for ≤ 4 extents) or extent tree (B+ tree)
- Extent tree key: logical_offset
- Supports sparse files (holes = missing extents)
- Compression per-extent (not per-file)

### Allocation Algorithm

```
ALLOCATE(inode, logical_offset, length, policy):
    1. Determine target AG (inode preferred AG or policy)
    2. Search AG's free extent tree:
       - HDD: first-fit (lowest physical_block)
       - SSD: best-fit (smallest extent >= length)
    3. If found:
       a. Split extent if larger than needed
       b. Update free extent tree
       c. Update bitmap (lazy)
       d. Add extent to inode's extent tree
       e. Return physical_block
    4. If not found in preferred AG:
       a. Search other AGs (round-robin or least-used)
       b. If still not found → ENOSPC
```

### Deallocation Algorithm

```
DEALLOCATE(inode, logical_offset, length):
    1. Remove extent from inode's extent tree
    2. For each AG affected:
       a. Insert freed extent into free extent tree
       b. Merge with adjacent free extents
       c. Update bitmap (lazy)
    3. If TRIM supported and policy enables:
       a. Batch TRIM commands for freed ranges
       b. Issue asynchronously
```

### Special Handling

#### Small Files (< 4 extents)
- Extents stored inline in inode (no extent tree allocation)
- Fast path for metadata-only operations

#### Large Files (≥ 4 extents)
- Extent tree (B+ tree) rooted in inode
- Tree nodes stored as metadata blocks

#### Preallocation
- `fallocate()` / `FALLOC_FL_KEEP_SIZE`: Allocate extents, mark as uninitialized
- Uninitialized extents: logical blocks mapped, physical blocks zeroed on first write
- Reduces fragmentation for streaming writes

#### Reservation
- Per-inode reservation for append-heavy workloads
- Reserved extents tracked in inode metadata

## Alternatives Considered

| Alternative | Pros | Cons | Decision |
|-------------|------|------|----------|
| Pure bitmap (ext2/3, FAT) | Simple | Slow for large volumes, fragmentation | Rejected |
| Pure B-tree extent (XFS) | Scalable | Complex, no small-allocation optimization | Rejected |
| Buddy system (mballoc) | Fast, good for large | Complex, fragmentation over time | Rejected |
| Log-structured (F2FS) | Flash-optimized | GC complexity, not HDD-friendly | Rejected |
| **Hybrid: Extent B-tree + Bitmap per AG** | Best of both, media-aware policies | More complex than single approach | **Accepted** |

## Consequences

### Positive
- Extent-based: Efficient for large files, natural compression boundary
- Allocation groups: Parallelism on NVMe, reduced lock contention
- Hybrid tracker: Fast large allocations (B-tree), fast small allocations (bitmap)
- Media-aware policies: Optimized for each storage type
- Per-extent compression: Granular, random-access friendly
- Sparse file support: Native via missing extents

### Negative
- More complex than pure bitmap
- B-tree maintenance overhead (splits/merges)
- AG count tuning needed for small volumes
- Free extent tree fragmentation over time (periodic defrag needed)

## Implementation Notes

1. **Core Engine**: `core/allocation/` - AG manager, free extent tree, bitmap, policies
2. **B-Tree**: Reusable B+ tree implementation (also used for directories)
3. **Policy Engine**: Pluggable, selected at mount via device characterization
4. **TRIM Batching**: Async worker per AG, configurable batch size/delay
5. **Statistics**: Per-AG fragmentation score, allocation latency histogram

## Reversibility

**Moderate** - Allocation metadata format is on-disk. Changing requires:
- Migration tool (relayout free space structures)
- Superblock version bump
- But allocation algorithm can be tuned per-policy without format change

**Locked: PARTIAL** (format for structures, adjustable for policies)

---

*ADR-003: Block Allocation Strategy*