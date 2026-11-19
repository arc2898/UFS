# ADR-007: Cross-Platform Metadata (Metadata Capsules)

**Status:** Accepted
**Date:** 2026-11-13
**Deciders:** Project U Architecture Team

## Context

UFS's central innovation is universal metadata interoperability. No existing filesystem preserves all metadata when moving between Windows, Linux, and macOS. UFS solves this with **Metadata Capsules** - structured, extensible containers that losslessly represent platform-specific metadata.

## Decision

**UFS uses Metadata Capsules: versioned, namespaced, extensible containers that store all file metadata in a platform-agnostic format, with bidirectional translation to each OS's native metadata model.**

### Capsule Structure

```
MetadataCapsule {
    u32 magic;              // 0x43415053 ("CAPS")
    u16 version;            // Capsule format version
    u16 flags;              // CAPSULE_FLAG_*
    u64 capsule_id;         // Unique ID (UUIDv7)
    u64 inode;              // Owning inode
    u32 entry_count;        // Number of entries
    CapsuleEntry[] entries; // Variable-length entries
    u32 crc32c;             // CRC32C of all above
}
```

### Capsule Entry Format

```
CapsuleEntry {
    u16 namespace;          // Namespace ID (see below)
    u16 type;               // Type within namespace
    u16 flags;              // ENTRY_FLAG_*
    u16 name_length;        // UTF-8 name length
    u32 value_length;       // Value length
    u8  name[];             // UTF-8 name
    u8  value[];            // Binary value (format per namespace/type)
    u32 crc32c;             // CRC32C of entry
}
```

### Namespaces (Extensible Registry)

| Namespace ID | Name | Platform Origin | Description |
|-------------|------|----------------|-------------|
| 0x0001 | POSIX_BASE | Linux/Unix | mode, uid, gid, timestamps, link count |
| 0x0002 | POSIX_ACL | Linux | NFSv4 ACLs |
| 0x0003 | POSIX_XATTR | Linux | user.*, trusted.*, security.*, system.* |
| 0x0004 | POSIX_CAPS | Linux | File capabilities |
| 0x0010 | WINDOWS_SD | Windows | Security Descriptor (SDDL binary) |
| 0x0011 | WINDOWS_ADS | Windows | Alternate Data Streams (named extents) |
| 0x0012 | WINDOWS_REPARSE | Windows | Reparse points (symlinks, junctions, mount points) |
| 0x0013 | WINDOWS_EFS | Windows | EFS encryption metadata |
| 0x0014 | WINDOWS_USN | Windows | USN Journal entry |
| 0x0015 | WINDOWS_OBJID | Windows | Object ID |
| 0x0016 | WINDOWS_ATTRS | Windows | FILE_ATTRIBUTE_* flags |
| 0x0020 | MACOS_XATTR | macOS | com.apple.* extended attributes |
| 0x0021 | MACOS_FINDER | macOS | Finder metadata (tags, labels, comments, icons) |
| 0x0022 | MACOS_RESOURCE | macOS | Resource fork (as named extent) |
| 0x0023 | MACOS_QUARANTINE | macOS | Quarantine attributes |
| 0x0024 | MACOS_FIRMLINK | macOS | Firmlink metadata |
| 0x0025 | MACOS_TIMESTAMP | macOS | Creation time (separate from POSIX) |
| 0x8000 | UFS_INTERNAL | UFS | Internal: compression, checksums, extent refs |
| 0xFFFF | OPAQUE | Any | Unknown metadata preserved opaquely |

### Translation Layer (Per Platform)

#### Windows IFS Driver
```
CAPSULE → Windows:
  POSIX_BASE.mode → FILE_ATTRIBUTE_* + DACL (simplified)
  POSIX_ACL → DACL (best-effort mapping)
  WINDOWS_SD → Full SDDL (lossless)
  WINDOWS_ADS → $DATA:$StreamName (lossless)
  WINDOWS_REPARSE → Reparse point (lossless)
  MACOS_RESOURCE → $DATA:AFP_Resource (preserved)
  MACOS_FINDER → Opaque xattr (preserved)
  OPAQUE → Preserved as-is
```

#### Linux VFS/FUSE
```
CAPSULE → Linux:
  POSIX_BASE → mode, uid, gid, timestamps (lossless)
  POSIX_ACL → POSIX ACL (lossless)
  POSIX_XATTR → xattrs (lossless)
  WINDOWS_SD → xattr "system.ntfs_sd" (preserved)
  WINDOWS_ADS → xattr "user.ntfs_ads.$name" (preserved)
  WINDOWS_REPARSE → xattr "system.ntfs_reparse" (preserved)
  MACOS_RESOURCE → xattr "user.macos_resource" (preserved)
  MACOS_FINDER → xattr "user.macos_finder.*" (preserved)
  OPAQUE → Preserved as-is
```

#### macOS FSKit
```
CAPSULE → macOS:
  POSIX_BASE → mode, uid, gid, timestamps (lossless)
  POSIX_ACL → NFSv4 ACL (lossless)
  MACOS_XATTR → com.apple.* xattrs (lossless)
  MACOS_FINDER → Finder metadata (lossless)
  MACOS_RESOURCE → Resource fork (lossless)
  MACOS_QUARANTINE → com.apple.quarantine (lossless)
  WINDOWS_SD → xattr "com.microsoft.ntfs_sd" (preserved)
  WINDOWS_ADS → xattr "com.microsoft.ntfs_ads.$name" (preserved)
  OPAQUE → Preserved as-is
```

### Conflict Resolution

| Conflict | Detection | Resolution |
|----------|-----------|------------|
| Case collision | Case-insensitive volume, "File" vs "file" | Error on create, explicit user choice |
| Reserved name | Windows reserved name on case-insensitive | Error on create |
| Timestamp precision | ns (Linux/macOS) vs 100ns (Windows) | Store highest precision, truncate on read |
| Permission model | ACL vs POSIX mode | Store both, translate on read |

### Capsule Lifecycle

1. **Create**: New inode → empty capsule (POSIX_BASE populated)
2. **Modify**: Platform API → translate to capsule entries → update capsule
3. **Read**: Platform API → translate from capsule entries → return
4. **Delete**: Inode deleted → capsule freed
5. **Preserve**: Unknown entries never dropped, only translated

### Storage

- **Small capsules** (≤ 256 bytes): Stored inline in inode
- **Large capsules**: Stored as extent (compressed, checksummed)
- **Capsule ID**: UUIDv7 (time-ordered, unique)
- **Reference counting**: Multiple hard links share capsule (copy-on-write)

### Versioning

- Capsule format version in capsule header
- Namespace/type registry versioned separately
- New namespaces/types added without breaking old readers
- Unknown entries preserved opaquely (forward compatibility)

## Alternatives Considered

| Alternative | Pros | Cons | Decision |
|-------------|------|------|----------|
| Native metadata only | Simple | No cross-platform preservation | Rejected |
| exFAT-style (no metadata) | Compatible | Loses everything | Rejected |
| NTFS on Linux approach | Partial | Loses ADS, ACLs, reparse points | Rejected |
| **Metadata Capsules** | Lossless round-trip, extensible | Complexity, translation layer | **Accepted** |

## Consequences

### Positive
- **Lossless cross-platform metadata**: The #1 UFS innovation
- **Extensible**: New platforms/metadata types via new namespaces
- **Forward compatible**: Unknown entries preserved
- **Explicit conflicts**: Errors not silent loss
- **Single source of truth**: Capsule is canonical

### Negative
- Translation layer complexity (3 platforms × ~20 namespaces)
- Capsule storage overhead (~200-500 bytes typical)
- Unicode normalization edge cases
- Windows reserved names require create-time checks

## Implementation Notes

1. **Core Engine**: `core/metadata/` - capsule parser, namespace registry, translation framework
2. **Platform Layers**: `drivers/windows/metadata.c`, `drivers/linux/metadata.c`, `drivers/macos/metadata.swift`
3. **Unicode**: ICU or embedded case-folding tables
4. **Testing**: Round-trip test matrix (Win→Lin→Mac→Win × all metadata types)
5. **Fuzzing**: Malformed capsules, namespace collisions

## Reversibility

**Hard** - Capsule format is core on-disk structure. Changing requires:
- Migration tool
- All platform drivers updated
- Superblock version bump

**Locked: YES** (format-affecting, central innovation)

---

*ADR-007: Cross-Platform Metadata (Metadata Capsules)*