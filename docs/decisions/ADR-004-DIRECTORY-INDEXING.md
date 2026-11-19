# ADR-004: Directory Indexing

**Status:** Accepted
**Date:** 2026-11-13
**Deciders:** Project U Architecture Team

## Context

UFS needs a directory structure that scales to millions of entries, supports fast lookup/creation/deletion, and works cross-platform with case sensitivity/preservation semantics.

## Decision

**UFS uses a hybrid directory structure: linear array for small directories, B+ tree for large directories, with case-folding support.**

### Directory Structure

#### Small Directories (≤ 64 entries)
- Linear array of directory entries in inode's inline data area
- Sorted by name (case-folded for case-insensitive volumes)
- O(n) lookup, but n ≤ 64 is fast
- No separate metadata blocks needed

#### Large Directories (> 64 entries)
- B+ tree rooted in inode
- Leaf nodes: directory entries
- Internal nodes: separator keys (case-folded names) + child pointers
- Order: ~128 entries per node (4 KB block)

### Directory Entry Format

```
Dirent {
    u64 inode;              // Target inode number
    u16 name_length;        // Bytes (UTF-8)
    u8  file_type;          // REG, DIR, SYMLINK, etc.
    u8  flags;              // CASE_FOLDED, HIDDEN, etc.
    u8  name[];             // UTF-8 bytes (not null-terminated)
    // Padding to 8-byte alignment
}
```

### Case Sensitivity Handling

**Volume-wide setting at format time (in superblock):**
- `CASE_SENSITIVE`: Linux-style, "File" ≠ "file"
- `CASE_INSENSITIVE`: Windows/macOS default, "File" = "file" (but case-preserving)

**Implementation:**
- Case-insensitive volumes: All names stored in original case, but B+ tree keys are case-folded (Unicode NFD + lowercase)
- Lookup: Case-fold query name, search tree
- Creation: Check for case-folded collision → error if exists
- Enumeration: Returns original case names
- Case-folding: Unicode 15.0 Default Case Folding (no locale-specific)

**Rationale:** Case-insensitive is safer for cross-platform (Windows/macOS default). Case-sensitive available for Linux-native volumes.

### Windows Reserved Names

- On case-insensitive volumes: Reject creation of CON, PRN, AUX, NUL, COM1-9, LPT1-9 (case-insensitive match)
- On case-sensitive volumes: Allow (Linux semantics)
- Stored as metadata flag for cross-platform awareness

### Unicode Normalization

- **Storage**: UTF-8, no normalization (preserve user bytes)
- **Comparison**: NFD + case-fold for case-insensitive volumes
- **Rationale**: NFD matches macOS APFS behavior; preserves user intent

### Directory Operations

| Operation | Small Dir | Large Dir |
|-----------|-----------|-----------|
| Lookup | Linear scan | B+ tree search (O(log n)) |
| Create | Insert sorted | B+ tree insert (split if needed) |
| Delete | Remove, compact | B+ tree delete (merge if needed) |
| Rename | Update + resort | Delete + insert (atomic in transaction) |
| Enumerate | Linear | In-order tree traversal |

### Metadata Capsule Integration

Each directory entry references a **metadata capsule** for the file's extended attributes:
- Capsule ID stored in inode (not in dirent)
- Dirent only has inode number + name + type
- Capsules managed separately (see ADR-008)

### Performance Targets

| Operation | Target (NVMe) | Target (HDD) |
|-----------|---------------|--------------|
| Lookup (1M entries) | < 50 μs | < 5 ms |
| Create | < 100 μs | < 10 ms |
| Delete | < 100 μs | < 10 ms |
| Enumerate (1M) | < 10 ms | < 100 ms |

## Alternatives Considered

| Alternative | Pros | Cons | Decision |
|-------------|------|------|----------|
| HTree (ext4) | Proven, hash-based | Hash collisions, no ordering | Rejected |
| Linear only | Simple | O(n) fails at scale | Rejected |
| Hash table | O(1) avg | No ordering, resize complexity | Rejected |
| **B+ tree (XFS/ReFS style)** | Ordered, O(log n), range queries | More complex | **Accepted** |
| Hybrid linear + B+ tree | Best of both | Transition logic | **Accepted** |

## Consequences

### Positive
- Scales to millions of entries (B+ tree depth ~3-4 for 1M entries)
- Ordered enumeration (ls, readdir) efficient
- Range queries supported (prefix search)
- Case-insensitive with case-preservation (Windows/macOS compatible)
- Unicode-aware comparison
- Small directory optimization (no extra blocks)

### Negative
- B+ tree implementation complexity
- Case-folding requires Unicode data (ICU or embedded tables)
- Transition at 64 entries adds edge cases
- Windows reserved names add check overhead

## Implementation Notes

1. **Core Engine**: `core/directory/` - B+ tree, linear array, case-folding
2. **Unicode**: Embedded Unicode 15.0 case folding table (~50 KB) or ICU dependency
3. **Transition**: At 64 entries, convert linear → B+ tree (in transaction)
4. **Reverse Transition**: At 32 entries after deletes, convert B+ tree → linear
5. **Testing**: Property-based tests for case-folding, collision detection

## Reversibility

**Moderate** - Directory format is on-disk. Changing requires:
- Migration tool
- Superblock version bump
- But algorithm can be tuned (threshold, node size) without format change

**Locked: PARTIAL** (format for structures, adjustable for thresholds)

---

*ADR-004: Directory Indexing*