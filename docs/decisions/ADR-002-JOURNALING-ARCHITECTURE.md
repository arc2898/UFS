# ADR-002: Journaling Architecture

**Status:** Accepted
**Date:** 2026-11-13
**Deciders:** Project U Architecture Team

## Context

UFS requires crash-consistent metadata updates with portable recovery across Windows, Linux, macOS, and UEFI. The journaling architecture must support:
- Portable replay (same algorithm on all platforms)
- Metadata-only journaling with ordered data writes (performance/integrity balance)
- Idempotent replay (safe to interrupt/restart)
- Corruption detection (per-record checksums + chain verification)
- Efficient checkpointing

## Decision

**UFS uses a logical redo journal (write-ahead logging) with metadata-only journaling and ordered data mode.**

### Journal Design

#### Transaction Structure
```
Transaction {
    u64 txid;              // Monotonically increasing transaction ID
    u64 timestamp;         // Wall-clock time (ns since 1970)
    u32 operation_count;   // Number of operations
    Operation[] operations; // Variable-length operations
    u32 crc32c;            // CRC32C of all above
}
```

#### Operation Types (Logical, Not Physical)
```
enum OperationType {
    CREATE_INODE = 1,
    DELETE_INODE = 2,
    UPDATE_INODE_METADATA = 3,    // timestamps, permissions, flags
    LINK_DIRENT = 4,              // parent_inode, name, child_inode, type
    UNLINK_DIRENT = 5,            // parent_inode, name
    RENAME_DIRENT = 6,            // old_parent, old_name, new_parent, new_name
    ALLOCATE_EXTENT = 7,          // inode, logical_offset, physical_block, length
    DEALLOCATE_EXTENT = 8,        // inode, logical_offset, length
    UPDATE_ALLOCATION_BITMAP = 9, // block_range, allocated/free
    UPDATE_SUPERBLOCK = 10,       // generation, checkpoint pointer
    CHECKPOINT = 11,              // Marks commit point
}
```

Each operation is self-describing with all necessary context for replay.

#### Journal Layout
```
Journal Area (fixed location, configurable size, default 64 MB):
├── Journal Superblock (magic, version, start_txn, end_txn, checksum)
├── Transaction 1
├── Transaction 2
├── ...
├── Transaction N
├── Free Space (circular buffer)
└── Checkpoint Records (periodic snapshots of recovery state)
```

#### Commit Protocol (Ordered Data Mode)
1. **Data Write**: Write all new/updated file data blocks to final location
2. **Flush Data**: Issue FLUSH/FUA for data blocks
3. **Journal Write**: Write transaction (metadata operations only) to journal
4. **Flush Journal**: Issue FLUSH/FUA for journal
5. **Checkpoint**: Update journal superblock with new commit pointer
6. **Acknowledge**: Return success to caller

#### Recovery Algorithm (Portable)
```
RECOVER():
    1. Read journal superblock
    2. If clean unmount flag set → return (no recovery needed)
    3. Find last valid checkpoint record
    4. Scan forward from checkpoint to end of valid transactions
    5. For each transaction:
        a. Verify CRC32C
        b. Verify txid sequence (no gaps)
        c. Replay operations in order (idempotent)
    6. Mark volume clean
    7. Write new journal superblock
```

#### Idempotent Replay
Operations designed to be safely replayed multiple times:
- `CREATE_INODE`: Check if inode exists with same ID → skip
- `DELETE_INODE`: Check if inode exists → delete if present
- `LINK_DIRENT`: Check if dirent exists with same target → skip
- `ALLOCATE_EXTENT`: Check if extent already allocated at location → skip
- All operations include generation numbers for conflict detection

#### Checkpointing
- **Trigger**: Every N transactions (default 100) OR every T milliseconds (default 1000ms) OR journal 75% full
- **Content**: Current allocation bitmap state, inode table pointers, dirty page list
- **Write**: New checkpoint record + flush + update journal superblock

#### Corruption Handling
- Per-transaction CRC32C detects torn writes
- Merkle tree over transaction chain detects reordering/deletion
- On corruption: Truncate at last valid transaction, alert user
- Recovery can be interrupted and resumed (state in checkpoint)

## Alternatives Considered

| Alternative | Pros | Cons | Decision |
|-------------|------|------|----------|
| Physical redo journal (NTFS-style) | Simple replay | Not portable (block addresses), in-place updates | Rejected |
| Undo journal | Easy rollback | Larger journal, complex | Rejected |
| Full data+metadata journal (ext4 journal mode) | Maximum integrity | 2x write amplification | Rejected |
| Copy-on-write (ZFS/Btrfs) | No journal needed | Complex, high memory, no portable recovery | Rejected |
| **Logical redo journal (metadata-only, ordered data)** | Portable, efficient, proven (XFS, ReFS) | Ordered data requires flush discipline | **Accepted** |

## Consequences

### Positive
- Portable recovery: same Zig code runs on Windows/Linux/macOS/UEFI
- Metadata-only: Lower write amplification than full journaling
- Ordered data: File data consistent after crash (no stale data exposure)
- Logical operations: Self-describing, no block address dependencies
- Idempotent: Safe to interrupt/restart recovery
- Corruption detection: Per-transaction CRC32C + Merkle chain

### Negative
- Ordered data requires FLUSH/FUA discipline (correctness critical)
- Logical operations larger than physical block writes
- Journal space management adds complexity
- Must handle FLUSH/FUA unavailable on some devices (conservative fallback)

## Implementation Notes

1. **Core Engine**: `core/journal/` - transaction builder, journal writer, recovery engine
2. **Block Device Abstraction**: `flush()` and `write_fua()` operations required
3. **Checkpoint State**: In-memory dirty page tracking for efficient checkpoints
4. **Testing**: Crash simulation framework (power loss at every protocol step)
5. **UEFI**: Recovery binary built as standalone UEFI application

## Reversibility

**Hard to change** - Journal format is on-disk format. Changing requires:
- Migration tool
- Coordinated driver updates
- Superblock version bump

**Locked: YES** (format-affecting)

---

*ADR-002: Journaling Architecture*