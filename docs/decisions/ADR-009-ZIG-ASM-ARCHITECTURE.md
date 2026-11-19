# ADR-009: Zig + Assembly Architecture

**Status:** Accepted
**Date:** 2026-11-13
**Deciders:** Project U Architecture Team

## Context

UFS implementation uses Zig as primary language with selective Assembly for performance-critical paths. Need clear boundaries between portable core and platform-specific code.

## Decision

**Zig implements 95%+ of filesystem logic. Assembly used only for measured bottlenecks with portable Zig fallback.**

### Language Responsibilities

| Component | Language | Rationale |
|-----------|----------|-----------|
| On-disk format (de/serialization) | Zig | Portable, type-safe, comptime validation |
| Block device abstraction | Zig | Platform impls behind interface |
| Metadata capsules | Zig | Complex parsing, safety-critical |
| Allocation (AG, extent tree, bitmap) | Zig | Algorithmic, not hardware-specific |
| Journal (transactions, recovery) | Zig | Logic-heavy, correctness-critical |
| Directory B+ tree | Zig | Algorithmic |
| Compression pipeline | Zig + C (lz4/zstd) | Orchestration in Zig, algorithms in C |
| Integrity (CRC32C, BLAKE3) | Zig + Assembly | Hot paths in Assembly |
| Zig core build | Zig | Self-hosting |
| Platform drivers | C/C++/Swift/Rust | OS ABI requirements |

### Assembly Usage (Selective, Measured)

| Function | Architecture | Justification |
|----------|--------------|---------------|
| CRC32C (Castagnoli) | x86-64 (SSE4.2), ARM64 (CRC32) | 10-20x speedup vs software |
| BLAKE3 (core rounds) | x86-64 (AVX2/AVX-512), ARM64 (NEON/SVE) | 5-10x speedup |
| Memory operations (copy/set) | x86-64 (AVX2), ARM64 (NEON) | Compiler may not vectorize |
| Atomic primitives | x86-64 (LOCK), ARM64 (LDAXR/STLXR) | Correctness on weak memory |
| Boot entry points | x86-64, ARM64 UEFI | ABI requirements |

**Rule**: Every Assembly function has a pure Zig implementation as fallback. Assembly selected at compile-time via `target.cpu.arch`.

### Zig Core Architecture

```
core/
├── serialization/     # Canonical binary encoding (ADR-001)
├── metadata/          # Capsules, namespaces, translation (ADR-007)
├── allocation/        # AGs, extent trees, bitmaps (ADR-003)
├── journal/           # Transactions, recovery (ADR-002)
├── compression/       # Pipeline, heuristics (ADR-005)
├── integrity/         # CRC32C, BLAKE3, scrub (ADR-006)
├── directory/         # B+ tree, linear, case-fold (ADR-004)
├── version/           # Format versioning (ADR-008)
├── blockdev/          # Abstract block device interface
├── crypto/            # Encryption primitives (v2)
└── utils/             # Logging, errors, testing
```

### Platform Abstraction Layer (PAL)

Each platform implements:
```
interface BlockDevice {
    read(offset: u64, buffer: []u8) !void
    write(offset: u64, buffer: []const u8) !void
    flush() !void
    write_fua(offset: u64, buffer: []const u8) !void  // Force Unit Access
    trim(offset: u64, length: u64) !void
    get_sector_size() u32
    get_physical_sector_size() u32
    get_size() u64
    is_rotational() bool
    is_trim_supported() bool
    get_nvme_info() ?NvmeInfo
}
```

### Build System

- **Zig**: `zig build` for core library (static + dynamic)
- **C**: CMake for platform drivers (Windows INF, Linux kernel module, macOS FSKit)
- **Assembly**: NASM (x86-64) / GAS (ARM64) via Zig build.zig
- **Cross-compilation**: Zig targets for all platforms

### FFI Boundaries

| Boundary | From | To | Mechanism |
|----------|------|-----|-----------|
| Core → Windows IFS | Zig | C | Zig `extern "c"` functions, C headers |
| Core → Linux VFS | Zig | C | Zig `extern "c"`, kernel module C glue |
| Core → Linux FUSE | Zig | C | Zig `extern "c"`, libfuse C API |
| Core → macOS FSKit | Zig | Swift | Zig `extern "c"` → C bridge → Swift |
| Core → UEFI | Zig | UEFI C | Zig `extern "efiapi"` |

### Memory Safety

- Zig: Bounds checking in debug/release-safe, optional in release-fast
- Assembly: Manual verification, extensive testing
- C glue: Minimal, validated inputs from Zig
- No `unsafe` Zig in core (only in FFI boundaries)

### Testing Strategy

- **Unit**: Zig test blocks for every core module
- **Integration**: FUSE driver for cross-platform testing
- **Fuzzing**: Zig `std.fuzz` for all parsers
- **Property-based**: `std.testing.property` for algorithms
- **Benchmark**: Built-in benchmarking for hot paths

## Alternatives Considered

| Alternative | Pros | Cons | Decision |
|-------------|------|------|----------|
| Pure C | Universal ABI | No safety, manual memory, no comptime | Rejected |
| Pure Rust | Safety, ecosystem | No Windows kernel support, no UEFI | Rejected |
| C++ | Performance, ABI | Complexity, no memory safety | Rejected |
| **Zig + selective Assembly** | Safety, comptime, C ABI, cross-compile, Assembly where needed | Newer language, smaller ecosystem | **Accepted** |

## Consequences

### Positive
- Single source of truth for filesystem logic
- Memory safety in 95% of code
- Compile-time validation of on-disk structures
- Easy cross-compilation for all targets
- Assembly only where measured beneficial
- Portable fallback for all Assembly

### Negative
- Zig learning curve for team
- FFI glue code for each platform
- Zig compiler must be available in build env
- Assembly maintenance for multiple architectures

## Implementation Notes

1. **Core Build**: `zig build-lib -static -O ReleaseFast -target x86_64-windows` etc.
2. **Assembly**: Separate `.asm`/`.S` files, assembled to `.o`, linked by Zig
3. **CPU Detection**: Runtime CPU feature detection for Assembly dispatch
4. **CI**: Build matrix for all target platforms

## Reversibility

**Moderate** - Language choice affects all implementation. Changing requires:
- Rewrite of core library
- But on-disk format unchanged
- Platform drivers can stay if FFI stable

**Locked: NO** (implementation detail, not format-affecting)

---

*ADR-009: Zig + Assembly Architecture*