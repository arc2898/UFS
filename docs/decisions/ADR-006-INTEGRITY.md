# ADR-006: Data Integrity and Checksumming

**Status:** Accepted
**Date:** 2026-11-13
**Deciders:** Project U Architecture Team

## Context

UFS prioritizes data integrity. Must detect corruption (bit rot, torn writes, misdirected writes) and provide controlled repair. Checksums must be fast, portable, and cover both metadata and data.

## Decision

**UFS uses a dual-layer checksum strategy: CRC32C for metadata (fast, hardware-accelerated), BLAKE3 for data (strong, fast, SIMD).**

### Checksum Algorithms

| Layer | Algorithm | Polynomial/Construction | Hardware Accel | Strength |
|-------|-----------|------------------------|----------------|----------|
| Metadata | CRC32C (Castagnoli) | 0x1EDC6F41 | SSE4.2, ARM NEON, CRC32C | 32-bit |
| Data | BLAKE3 | BLAKE3 (256-bit) | AVX2, AVX-512, NEON, SVE | 256-bit |
| Journal | CRC32C | Same as metadata | Same | 32-bit |
| Superblock | CRC32C + BLAKE3 | Dual | Both | 32+256-bit |

### Scope of Checksumming

#### Metadata (All Structures)
- Superblock (primary + backups)
- Allocation group headers
- Free extent trees (B-tree nodes)
- Allocation bitmaps
- Inode tables
- Extent trees (inode + separate)
- Directory B+ trees
- Journal transactions
- Checkpoint records
- Metadata capsules

#### Data (Optional but Default ON)
- All file data extents (compressed or uncompressed)
- Per-extent BLAKE3 stored in extent metadata
- Verified on every read
- `nodatachecksum` mount option to disable (performance)

#### Journal
- Per-transaction CRC32C
- Merkle tree over transaction chain (periodic checkpoints)

### Checksum Placement

**Metadata Structures:**
```
[Structure Fields...][u32 crc32c]
```
CRC32C covers all bytes before the checksum field.

**Data Extents:**
```
Extent Metadata {
    ...
    u16 compression_algo;
    u32 original_length;
    u32 compressed_length;
    u32 crc32c_header;      // CRC32C of header fields
    u8  blake3_hash[32];    // BLAKE3 of compressed data
}
```
BLAKE3 covers the compressed data payload.

### Verification Points

| Operation | Metadata Check | Data Check |
|-----------|----------------|------------|
| Mount | Superblock, AG headers | No |
| Read | On access (inode, dir, extent tree) | On read (if enabled) |
| Write | After modification, before flush | After compress, before write |
| Scrub | All metadata | All data |
| Recovery | Journal transactions | No (data not journaled) |

### Corruption Handling

#### Detection
- **Metadata**: CRC32C mismatch → EIO, structure marked corrupt
- **Data**: BLAKE3 mismatch → EIO, extent marked corrupt
- **Journal**: CRC32C mismatch → truncate at last valid

#### Repair (Controlled, Not Automatic)
- **Metadata**: `ufsck` can rebuild from redundant copies (superblock backups, extent tree from inode)
- **Data**: No automatic repair (no redundancy at FS level)
  - User notified with file path, extent range
  - `ufsck --salvage` can copy readable portions, zero corrupted ranges
  - Redundancy at block level (RAID, mirror) handles repair

#### Redundancy (Future)
- v2: Optional mirror copies of critical metadata
- v2: RAID-like profiles (mirror, raidz) at allocation group level

### Scrub Operation

```
ufsck --scrub:
  1. Read all metadata structures, verify CRC32C
  2. Read all data extents, verify BLAKE3
  3. Report: corrupt metadata structures, corrupt data extents
  4. Optionally: --repair metadata (rebuild from redundant info)
```

- Runs online (background, low priority)
- Checkpointable (resume after interrupt)
- Progress reporting

### Performance

- **CRC32C**: ~10-20 GB/s/core (hardware accelerated)
- **BLAKE3**: ~5-10 GB/s/core (SIMD), multi-threaded scaling
- **Overhead**: ~1-3% CPU on typical workloads
- **Metadata**: Negligible (small structures, cached)
- **Data**: Proportional to read throughput

## Alternatives Considered

| Alternative | Pros | Cons | Decision |
|-------------|------|------|----------|
| CRC32C only | Fast, hardware | 32-bit collision risk for data | Rejected |
| SHA256 | Strong | Slow (no SIMD on all platforms) | Rejected |
| BLAKE2b | Fast, SIMD | Superseded by BLAKE3 | Rejected |
| **CRC32C (meta) + BLAKE3 (data)** | Right tool for each layer | Two algorithms | **Accepted** |
| Fletcher-64 | Simple | No hardware accel, weaker | Rejected |
| xxHash | Fast | Not cryptographic, collision risk | Rejected |

## Consequences

### Positive
- Strong data integrity (256-bit BLAKE3)
- Fast metadata integrity (CRC32C hardware)
- Corruption detected at read time (not scrub time)
- Portable algorithms (reference implementations in C/Zig)
- Dual-layer: right strength for right purpose

### Negative
- Two checksum implementations to maintain
- BLAKE3 larger code than CRC32C
- Data checksum storage overhead: 32 bytes/extent + 4 bytes header
- CPU cost on read path (mitigated by SIMD)

## Implementation Notes

1. **Core Engine**: `core/integrity/` - CRC32C (hardware + software fallback), BLAKE3 (Rust reference ported to C/Zig)
2. **SIMD**: Runtime dispatch (AVX2, NEON, scalar fallback)
3. **Verification**: Inline in read path, async in scrub
4. **Testing**: Bit-flip injection, truncated writes, misdirected writes
5. **UEFI**: CRC32C only (BLAKE3 for data if needed for boot)

## Reversibility

**Moderate** - Checksum fields in on-disk structures. Adding algorithms requires:
- New algorithm IDs in extent metadata
- Decoders on all platforms
- But existing volumes verifiable with current algorithms

**Locked: PARTIAL** (structure format, extensible algorithms)

---

*ADR-006: Data Integrity and Checksumming*