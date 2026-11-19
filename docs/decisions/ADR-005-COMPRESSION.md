# ADR-005: Compression Architecture

**Status:** Accepted
**Date:** 2026-11-13
**Deciders:** Project U Architecture Team

## Context

UFS requires transparent compression that is cross-platform, performant, and integrates with integrity checking. Must support multiple algorithms and per-extent granularity.

## Decision

**UFS implements per-extent transparent compression with algorithm negotiation, integrated with integrity pipeline.**

### Compression Pipeline

```
Write Path:
  User Data → [Compress] → [Checksum BLAKE3] → [Encrypt optional] → Write Extent

Read Path:
  Read Extent → [Verify Checksum] → [Decrypt optional] → [Decompress] → User Data
```

### Supported Algorithms

| Algorithm | ID | Use Case | Speed | Ratio |
|-----------|-----|----------|-------|-------|
| None | 0 | Incompressible, performance-critical | N/A | 1.0x |
| LZ4 | 1 | Default "fast" profile | ~3 GB/s | ~2.1x |
| ZSTD | 2 | Default "balanced" profile | ~500 MB/s | ~2.8x |
| ZSTD_HIGH | 3 | "maximum" profile (archival) | ~100 MB/s | ~3.5x |

### Per-Extent Granularity

- Each extent independently compressed or not
- Extent metadata stores: `compression_algo` (u16), `original_length` (u32), `compressed_length` (u32)
- Inline extents (in inode): Compressed data stored directly
- Non-inline extents: Compressed data in data blocks
- Random access: Decompress only needed extent(s)

### Compression Profiles (Mount Options / Per-File)

| Profile | Algorithm | When Applied |
|---------|-----------|--------------|
| `none` | None | Never |
| `fast` | LZ4 | Heuristically compressible data |
| `balanced` | ZSTD (level 3) | Default |
| `maximum` | ZSTD (level 12) | Archival, cold data |

### Heuristics for Automatic Profiles

1. **First 4 KB**: Compress sample, if ratio < 1.05 → mark extent `NONE`
2. **Extension heuristic**: Known incompressible extensions (.jpg, .mp4, .zip, .gz) → default `NONE`
3. **Per-file override**: `chattr +c` (compress) or `chattr -c` (no compress)
4. **Per-directory inheritance**: Directory flag → new files inherit

### Compression Metadata (per extent)

```
CompressedExtentHeader {
    u16 algorithm;          // 0=none, 1=LZ4, 2=ZSTD, 3=ZSTD_HIGH
    u16 flags;              // Reserved
    u32 original_length;    // Uncompressed bytes
    u32 compressed_length;  // Compressed bytes (≤ original)
    u32 crc32c;             // CRC32C of compressed data
    // Followed by compressed data (or uncompressed if algorithm=0)
}
```

### Integrity Integration

- **Checksum covers COMPRESSED data** (not uncompressed)
- BLAKE3 used for data integrity (256-bit, fast, SIMD)
- CRC32C for quick corruption detection in extent header
- On read: Verify BLAKE3 → if fail, report corruption, don't decompress
- On write: Compress → BLAKE3 → write

### Fallback Behavior

- If compression expands data (compressed ≥ original): Store uncompressed, algorithm=0
- If decompression fails (corruption): Return EIO, don't silently return garbage
- If algorithm unsupported: Return EOPNOTSUPP (graceful degradation)

### Cross-Platform Requirements

- LZ4 and ZSTD are portable C libraries (BSD/MIT licenses)
- Identical decompression on Windows, Linux, macOS, UEFI
- No OS-specific compression APIs used
- Zig bindings to reference implementations

### Performance Considerations

- **Async compression**: Offload to thread pool for large writes
- **Batch decompression**: Read-ahead decompresses multiple extents
- **CPU vs I/O tradeoff**: On fast NVMe, compression may not help; heuristic adapts
- **Memory**: Compression buffers pooled (per-thread)

## Alternatives Considered

| Alternative | Pros | Cons | Decision |
|-------------|------|------|----------|
| Per-file (NTFS) | Simple | All-or-nothing, no random access to compressed | Rejected |
| Per-block (ZFS) | Fine granularity | High metadata overhead | Rejected |
| **Per-extent** | Natural boundary, random access, variable ratio | Slight complexity | **Accepted** |
| LZO | Fast | Worse ratio than LZ4 | Rejected |
| LZNT1 (NTFS) | Windows native | Slow, poor ratio, not portable | Rejected |
| **LZ4 + ZSTD** | Industry standard, portable, tunable | Two libraries | **Accepted** |

## Consequences

### Positive
- Transparent to applications
- Per-extent: Random access, partial reads efficient
- Algorithm negotiation: Future-proof
- Integrated checksums: Corruption detection before decompression
- Cross-platform: Same algorithms everywhere
- Heuristics: Avoid CPU waste on incompressible data

### Negative
- Two compression libraries (code size)
- Heuristics may misclassify
- Compression adds latency to write path
- Random write to compressed extent = read-modify-write (decompress, modify, recompress)

## Implementation Notes

1. **Core Engine**: `core/compression/` - algorithm registry, heuristics, pipeline
2. **Dependencies**: `lz4` (C), `zstd` (C) - statically linked
3. **Zig Bindings**: Thin wrappers around C APIs
4. **Testing**: Round-trip for all algorithms, corruption injection, performance benchmarks
5. **UEFI**: Decompression only (read-only), minimal code size

## Reversibility

**Moderate** - Compression metadata in extent format. Adding algorithms requires:
- New algorithm ID
- Decoder in all platforms
- But existing volumes readable without new algorithms

**Locked: PARTIAL** (extent format, extensible algorithms)

---

*ADR-005: Compression Architecture*