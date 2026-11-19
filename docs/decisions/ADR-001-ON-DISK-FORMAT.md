# ADR-001: On-Disk Format Serialization

**Status:** Accepted
**Date:** 2026-11-13
**Deciders:** Project U Architecture Team

## Context

UFS requires a deterministic, platform-independent on-disk format. We must avoid writing raw Zig/C structs directly to storage due to:
- Compiler-dependent padding/alignment
- Endianness differences (x86-64 little-endian, ARM64 little-endian, potential big-endian)
- Structure layout changes across compiler versions
- No schema evolution capability

## Decision

**All on-disk structures shall be explicitly serialized using a canonical binary encoding.**

### Encoding Rules

1. **Byte Order**: Little-endian (all target platforms are LE)
2. **Integer Types**: Explicit widths (u8, u16, u32, u64, i8, i16, i32, i64)
3. **Alignment**: No padding - fields packed sequentially
4. **Strings**: Length-prefixed (u16 length + UTF-8 bytes), max 65535 bytes
5. **Variable-Length Data**: Length-prefixed (u32 length + bytes)
6. **Optional Fields**: Presence bitmap (u64) followed by present fields
7. **Extensibility**: Reserved fields (zeroed on write, ignored on read) + feature flags
8. **Checksums**: Every structure ends with CRC32C (Castagnoli) of all preceding bytes
9. **Magic Numbers**: Every major structure starts with 4-byte magic identifier

### Structure Layout Template

```
struct Header {
    u32 magic;           // Unique per structure type
    u16 version;         // Structure version
    u16 flags;           // Feature flags
    u32 size;            // Total size including this header and checksum
    u64 crc32c;          // CRC32C of all bytes before this field
}
```

### Versioning Strategy

- **Major version**: Incompatible format change (requires migration tool)
- **Minor version**: Backward-compatible addition (new optional fields)
- **Feature flags**: Optional capabilities (compression, encryption, checksums)
- **Compatibility flags**: 
  - `COMPAT_RO`: Safe to mount read-only if unknown
  - `COMPAT_RW`: Safe to mount read-write if unknown
  - `INCOMPAT`: Must understand to mount

## Alternatives Considered

| Alternative | Pros | Cons | Decision |
|-------------|------|------|----------|
| Raw struct serialization (Zig `@bitCast`) | Simple, fast | Compiler-dependent, not portable, no evolution | Rejected |
| Protocol Buffers | Schema evolution, multi-language | Overhead, not designed for mmap/random access | Rejected |
| Cap'n Proto | Zero-copy, schema evolution | Complexity, not standard in kernel | Rejected |
| Custom TLV (Type-Length-Value) | Extensible, self-describing | Overhead for fixed structures | Partial - for metadata capsules only |
| **Explicit canonical serialization** | Deterministic, portable, evolvable, fast | Manual implementation | **Accepted** |

## Consequences

### Positive
- Deterministic across all platforms and compilers
- Supports schema evolution via versioning and feature flags
- Enables mmap-friendly access (fixed offsets for known versions)
- Clear specification for third-party implementations
- CRC32C enables corruption detection

### Negative
- Manual serialization/deserialization code required
- More verbose than raw structs
- Must maintain Zig and C implementations in sync

## Implementation Notes

1. **Zig Core**: `core/serialization/` module with `read()`/`write()` for each structure
2. **C Bindings**: Generated header with packed structs + serialization functions
3. **Testing**: Round-trip tests for every structure; fuzzing of deserialization
3. **Documentation**: Each structure documented with byte layout diagram

## Reversibility

**Hard to change** - This is a format-affecting decision. Changing serialization requires:
- Migration tool for existing volumes
- Coordinated update of all OS drivers
- Version bump in superblock

**Locked: YES** (format-affecting)

---

*ADR-001: On-Disk Format Serialization*