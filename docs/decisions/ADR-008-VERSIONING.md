# ADR-008: Versioning and Feature Flags

**Status:** Accepted
**Date:** 2026-11-13
**Deciders:** Project U Architecture Team

## Context

UFS must evolve its on-disk format over time while maintaining backward/forward compatibility. Clear versioning rules are needed for:
- Format evolution without breaking existing volumes
- Feature negotiation between driver and volume
- Safe mount decisions (read-only vs read-write vs refuse)

## Decision

**UFS uses a three-tier versioning system: Format Version + Feature Flags + Compatibility Flags.**

### Format Version (Superblock)

```
struct FormatVersion {
    u16 major;    // Incompatible changes (requires migration)
    u16 minor;    // Backward-compatible additions
    u32 revision; // Bug fixes, no format changes
}
```

**Rules:**
- **Major**: Incompatible format change (e.g., new extent format, capsule restructure)
  - Older drivers MUST refuse mount (read-only or read-write)
  - Migration tool required
- **Minor**: New optional structures, new namespaces, new algorithms
  - Older drivers CAN mount read-write if compat flags allow
  - New features simply unavailable
- **Revision**: No on-disk format change
  - Purely informational

### Feature Flags (Superblock)

```
enum FeatureFlag {
    // Compatibility categories
    COMPAT_RO      = 0x00000001, // Safe to mount read-only if unknown
    COMPAT_RW      = 0x00000002, // Safe to mount read-write if unknown
    INCOMPAT       = 0x00000004, // MUST understand to mount
    
    // Specific features
    FEATURE_COMPRESSION_LZ4     = 0x00010000,
    FEATURE_COMPRESSION_ZSTD    = 0x00020000,
    FEATURE_ENCRYPTION          = 0x00040000,
    FEATURE_SNAPSHOTS           = 0x00080000,
    FEATURE_DEDUPLICATION       = 0x00100000,
    FEATURE_QUOTAS              = 0x00200000,
    FEATURE_CASE_INSENSITIVE    = 0x00400000,
    FEATURE_METADATA_CHECKSUMS  = 0x00800000,
    FEATURE_DATA_CHECKSUMS      = 0x01000000,
    FEATURE_ZNS                 = 0x02000000,
}
```

**Mount Decision Algorithm:**
```
MOUNT(volume, flags):
    1. Read superblock
    2. If volume.major > driver.major:
         If (flags & FORCE_RO) → mount read-only
         Else → REFUSE (incompatible major version)
    3. If (volume.incompat & ~driver.supported_incompat) != 0:
         If (flags & FORCE_RO) → mount read-only
         Else → REFUSE (unknown incompatible feature)
    4. If (volume.compat_ro & ~driver.supported_compat_ro) != 0:
         → Mount read-only (unknown RO-compatible feature)
    5. If (volume.compat_rw & ~driver.supported_compat_rw) != 0:
         → Mount read-write (unknown RW-compatible feature)
    6. → Mount read-write (all features understood or safely ignored)
```

### Feature Flag Categories

| Category | Examples | Unknown Driver Behavior |
|----------|----------|------------------------|
| `INCOMPAT` | New extent format, capsule restructure, encryption | Refuse mount (or RO with force) |
| `COMPAT_RO` | New metadata namespace, new compression algo, snapshots (read) | Mount read-only |
| `COMPAT_RW` | New xattr namespace, quota format | Mount read-write |

### Driver Capability Advertisement

Each driver reports:
```
struct DriverCapabilities {
    u16 max_major_version;
    u16 max_minor_version;
    u32 supported_incompat;
    u32 supported_compat_ro;
    u32 supported_compat_rw;
}
```

### Upgrade/Downgrade Rules

| Operation | Allowed? | Conditions |
|-----------|----------|------------|
| Minor version upgrade | Yes | Add new COMPAT_RO/RW features |
| Major version upgrade | Yes | Migration tool runs first |
| Feature enable (COMPAT_RW) | Yes | Online, no restructuring |
| Feature enable (COMPAT_RO) | Yes | Requires remount RO |
| Feature enable (INCOMPAT) | No | Requires reformat/migration |
| Feature disable | Yes | Clear flag, orphaned structures ignored |
| Minor version downgrade | Yes | If no new features used |
| Major version downgrade | No | Never |

### Reserved Space for Evolution

- Superblock: 1 KB reserved (current ~512 bytes used)
- AG header: 256 bytes reserved
- Inode: 64 bytes reserved
- Capsule: Extensible by design
- Journal: Versioned transaction format

## Alternatives Considered

| Alternative | Pros | Cons | Decision |
|-------------|------|------|----------|
| Single version number | Simple | Can't express partial compatibility | Rejected |
| ext4-style (compat/incompat/ro_compat) | Proven | Only 3 categories | Extended |
| **Three-tier + feature flags** | Granular, explicit, extensible | More complex | **Accepted** |

## Consequences

### Positive
- Clear mount-time safety decisions
- Supports gradual feature rollout
- Older drivers can safely mount newer volumes (RO or RW)
- Explicit incompatibility signaling
- Migration path for major changes

### Negative
- More complex mount logic
- Must maintain driver capability tables
- Feature flag registry must be coordinated

## Implementation Notes

1. **Superblock**: Version + feature flags at fixed offsets
2. **Core Library**: `core/version/` - mount decision logic, capability negotiation
3. **Driver Integration**: Each driver implements `DriverCapabilities`
4. **Tools**: `mkufs` sets initial flags, `ufsctl` enables/disables features
5. **Testing**: Matrix of driver versions × volume versions

## Reversibility

**Hard** - Versioning is in superblock (primary metadata). Changes require:
- Superblock format change
- All drivers updated
- Migration tool for major version changes

**Locked: YES** (format-affecting)

---

*ADR-008: Versioning and Feature Flags*