# UFS Image Tools

This directory contains the userspace tools for creating, checking, inspecting, and controlling UFS filesystems.

## Tools

### mkufs - Create UFS Volume
Creates a new UFS filesystem on a block device or file.

```bash
# Build
zig build mkufs

# Usage
./zig-out/bin/mkufs <device> [options]

# Options
  -L, --label <label>          Volume label (max 255 chars)
  -U, --uuid <uuid>            Volume UUID (UUIDv4 or UUIDv7 format)
  -c, --cluster-size <size>    Cluster size: 512, 1k, 2k, 4k, 8k, 16k, 32k, 64k (default: 4k)
  --compression <algo>         Compression: none, lz4, zstd, zstd-high (default: lz4)
  -J, --journal-size <size>    Journal size in clusters (default: auto, 1% of volume)
  -A, --ag-count <count>       Number of allocation groups (default: auto, 1 per GB)
  -b, --block-size <size>      Physical block size (default: auto-detect)
  -f, --force                  Force format without confirmation
  -v, --verbose                Verbose output
  -n, --dry-run                Show what would be done without writing
  -h, --help                   Show this help

# Examples
mkufs ufs.img -L "MyVolume" -c 4k
mkufs /dev/sdb1 -L "Data" --compression zstd -J 128M -f -v
mkufs ufs.img --dry-run -L "Test" -v
```

### ufsck - Filesystem Checker
Validates and optionally repairs UFS filesystem structures.

```bash
# Build
zig build ufsck

# Usage
./zig-out/bin/ufsck <device> [options]

# Options
  -y, --repair           Attempt to repair errors (requires -f)
  -f, --force            Force repair without confirmation
  -v, --verbose          Verbose output
  -D, --check-data       Verify file data checksums (BLAKE3)
  -j, --json             Output results as JSON
  -p, --progress         Show progress bar
  -h, --help             Show this help
```

### ufsinfo - Filesystem Inspector
Displays detailed information about UFS filesystem structures.

```bash
# Build
zig build ufsinfo

# Usage
./zig-out/bin/ufsinfo <device> [options]

# Options
  -s, --superblock      Show superblock info (default)
  -j, --journal         Show journal info
  -a, --ags             Show allocation group info
  -t, --tree            Show directory tree
  -e, --extents         Show extent map for inode (use with -i)
  -c, --capsules        Show metadata capsules for inode (use with -i)
  -i, --inode <num>     Inode number for -e/-c
  --all                 Show all information
  --json                Output as JSON
  -h, --help            Show this help
```

### ufsctl - Volume Control
Management utility for mounted UFS volumes.

```bash
# Build
zig build ufsctl

# Usage
./zig-out/bin/ufsctl <device> <command> [options]

# Commands
  mount                    Mount volume (requires kernel driver/FUSE)
  unmount                  Unmount volume
  feature <type> <bit> <on|off>  Manage feature flags
                                 type: incompat, compat-ro, compat-rw
  compression <algo>       Set default compression: none, lz4, zstd, zstd-high
  scrub                    Start integrity scrub
  stats                    Show volume statistics
  label [new-label]        Show or set volume label
  checkpoint               Force journal checkpoint

# Options
  -v, --verbose            Verbose output
  -h, --help               Show this help
```

## Building All Tools

```bash
# Build all tools
zig build tools

# Individual tools
zig build mkufs
zig build ufsck
zig build ufsinfo
zig build ufsctl
```

## Testing

```bash
# Create a test image
dd if=/dev/zero of=test.img bs=1M count=100
zig-out/bin/mkufs test.img -L "TestVolume" -v

# Inspect it
zig-out/bin/ufsinfo test.img --all

# Check it
zig-out/bin/ufsck test.img -v

# Control it
zig-out/bin/ufsctl test.img stats
zig-out/bin/ufsctl test.img label "NewLabel"
```

## Architecture

All tools are built on the shared UFS core library (`ufs_core`) which provides:
- On-disk format parsing/serialization
- Block device abstraction
- Metadata capsule handling
- Allocation group management
- Journal structures
- Integrity verification (CRC32C, BLAKE3)
- Compression (LZ4, ZSTD)

The tools are designed to work offline (without mounting) where possible, using only the core library's parsing and validation functions.

## Integration with Core Library

Each tool imports the core library:
```zig
const ufs = @import("ufs");
```

And uses the shared types and constants from `main.zig`:
- Magic numbers
- Version constants
- Feature flags
- On-disk structure layouts
- Namespace IDs