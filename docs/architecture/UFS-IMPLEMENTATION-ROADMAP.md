# UFS Implementation Roadmap

**Project:** Project U (U Filesystem - UFS)
**Version:** 1.0
**Date:** 2026-11-13
**Status:** Planning Phase

---

## Milestone Overview

| Milestone | Focus | Duration | Target Date |
|-----------|-------|----------|-------------|
| M0 | Environment & Repository Setup | 1 week | 2026-11-20 |
| M1 | Research & Architecture | 2 weeks | 2026-12-04 |
| M2 | On-Disk Format Specification | 2 weeks | 2026-12-18 |
| M3 | Shared Zig Engine | 6 weeks | 2026-01-29 |
| M4 | Image Tools (mkufs, ufsck, ufsinfo) | 3 weeks | 2026-02-19 |
| M5 | FUSE Driver (First Usable FS) | 4 weeks | 2026-03-19 |
| M6 | Linux Native VFS Driver | 4 weeks | 2026-04-16 |
| M7 | Windows 11 IFS Driver | 8 weeks | 2026-06-11 |
| M8 | macOS FSKit Extension | 6 weeks | 2026-07-23 |
| M9 | UEFI Boot Support | 3 weeks | 2026-08-13 |
| M10 | Reliability & Performance | 6 weeks | 2026-09-24 |
| M11 | Release Candidate | 4 weeks | 2026-10-22 |

**Total Estimated: ~40 weeks (10 months)**

---

## Milestone 0: Environment & Repository Setup

**Duration:** 1 week  
**Target:** 2026-11-20

### Objectives
- [ ] Verify development environment (Windows 11, WSL 2, Zig, Git, WDK)
- [ ] Install Zig 0.13.x in WSL and Windows
- [ ] Install NASM (x86-64) and GAS (ARM64)
- [ ] Install Windows Driver Kit (WDK) with IFS samples
- [ ] Install UEFI development tools (GNU-EFI, OVMF)
- [ ] Create Git repository with proper structure
- [ ] Set up CI/CD pipeline (GitHub Actions)
- [ ] Create development documentation

### Exit Criteria
- [ ] Zig compiles on Windows and WSL
- [ ] WDK samples build (FastFAT)
- [ ] Can create and boot UEFI application in QEMU
- [ ] Git repository initialized with README, LICENSE, CONTRIBUTING
- [ ] CI runs `zig build` and `zig test` on push

---

## Milestone 1: Research & Architecture

**Duration:** 2 weeks  
**Target:** 2026-12-04

### Objectives
- [ ] Complete filesystem architecture research (NTFS, ext4, APFS, ZFS, Btrfs, F2FS, exFAT, ReFS, XFS)
- [ ] Cross-platform metadata interoperability analysis
- [ ] Storage device behavior research (HDD, SATA SSD, NVMe, USB, SD)
- [ ] Journaling and crash recovery mechanisms comparison
- [ ] Compression engine evaluation (LZ4, ZSTD, LZO)
- [ ] Data integrity algorithms evaluation (CRC32C, BLAKE3, SHA256)
- [ ] Identify central innovation (Metadata Capsules)
- [ ] Produce Architecture Decision Records (ADRs 001-011)

### Deliverables
- [ ] `docs/architecture/UFS-TECHNICAL-RESEARCH.md`
- [ ] `docs/architecture/UFS-INNOVATION-REPORT.md`
- [ ] `docs/architecture/UFS-ARCHITECTURE.md`
- [ ] `docs/architecture/UFS-OS-INTEGRATION.md`
- [ ] `docs/architecture/UFS-BOOT-ARCHITECTURE.md`
- [ ] `docs/decisions/ADR-001` through `ADR-011`

### Exit Criteria
- [ ] All research documents complete and reviewed
- [ ] ADRs accepted by architecture team
- [ ] Innovation report validates Metadata Capsules as central innovation
- [ ] Clear technical specifications for all subsystems

---

## Milestone 2: On-Disk Format Specification

**Duration:** 2 weeks  
**Target:** 2026-12-18

### Objectives
- [ ] Define complete v1 on-disk format
- [ ] Superblock (primary + backups)
- [ ] Journal area structure
- [ ] Allocation group layout
- [ ] Inode structure
- [ ] Extent tree (B+ tree)
- [ ] Directory structure (linear + B+ tree)
- [ ] Free extent tree
- [ ] Metadata capsule format
- [ ] Journal transaction format
- [ ] Feature flags and versioning
- [ ] Cluster size selection logic
- [ ] Limits and constraints

### Deliverables
- [ ] `docs/specifications/UFS-FORMAT-V1.md` (complete byte-level specification)

### Exit Criteria
- [ ] Format specification is complete and unambiguous
- [ ] All structures have: magic, version, CRC32C, reserved space
- [ ] Versioning strategy defined (major/minor/revision + feature flags)
- [ ] Migration path for future versions documented
- [ ] Reviewed by independent reviewer

---

## Milestone 3: Shared Zig Engine

**Duration:** 6 weeks  
**Target:** 2026-01-29

### Objectives
Build the portable Zig core library implementing all filesystem logic.

### Components

#### Week 1-2: Foundation
- [ ] Serialization layer (canonical binary encoding)
- [ ] Block device abstraction interface
- [ ] Error handling framework
- [ ] Logging and diagnostics
- [ ] Unit test framework setup
- [ ] Property-based testing infrastructure

#### Week 2-3: Metadata & Allocation
- [ ] Metadata capsule parser/serializer
- [ ] Namespace registry
- [ ] Translation framework (stub)
- [ ] Allocation group manager
- [ ] Free extent B+ tree
- [ ] Allocation bitmap
- [ ] Extent tree (B+ tree)

#### Week 3-4: Directory & Inode
- [ ] Directory B+ tree
- [ ] Linear directory (≤64 entries)
- [ ] Inode structure and operations
- [ ] Case-folding (Unicode 15.0)
- [ ] Windows reserved name handling

#### Week 4-5: Journal & Recovery
- [ ] Transaction builder
- [ ] Journal writer (circular buffer)
- [ ] Recovery engine (portable)
- [ ] Checkpointing
- [ ] Idempotent replay
- [ ] Merkle tree over transaction chain

#### Week 5-6: Compression, Integrity & Polish
- [ ] Compression pipeline (LZ4, ZSTD)
- [ ] Integrity: CRC32C (HW + SW), BLAKE3
- [ ] Feature flags and versioning
- [ ] Fuzzing all parsers
- [ ] Benchmarks
- [ ] Documentation

### Exit Criteria
- [ ] All core modules compile and pass unit tests
- [ ] Property-based tests for all data structures
- [ ] Fuzzing finds zero crashes in parsers
- [ ] Serialization round-trip tests pass
- [ ] Recovery engine passes crash simulation tests
- [ ] Code coverage > 80%
- [ ] No `unsafe` Zig in core (only FFI boundaries)

---

## Milestone 4: Image Tools

**Duration:** 3 weeks  
**Target:** 2026-02-19

### Objectives
Build user-space tools for creating, checking, and inspecting UFS volumes.

### Tools

#### mkufs (Format)
- [ ] Create UFS volume on file/device
- [ ] Options: label, UUID, cluster size, compression, journal size, AG count
- [ ] Safety: confirmation prompts, device detection
- [ ] Progress reporting

#### ufsck (Check/Repair)
- [ ] Metadata validation (CRC32C)
- [ ] Data integrity check (BLAKE3)
- [ ] Free space consistency
- [ ] Directory structure validation
- [ ] Journal replay verification
- [ ] Repair mode (metadata only, with `--repair` flag)
- [ ] Report generation (JSON + human)

#### ufsinfo (Inspect)
- [ ] Superblock dump
- [ ] Journal analysis
- [ ] AG statistics
- [ ] File/directory tree
- [ ] Extent maps
- [ ] Capsule inspection

#### ufsctl (Admin)
- [ ] Mount/unmount helpers
- [ ] Feature flag management
- [ ] Compression policy
- [ ] Scrub control
- [ ] Volume statistics

### Exit Criteria
- [ ] `mkufs` creates valid volumes mountable by FUSE driver
- [ ] `ufsck` detects injected corruption (bit flips, torn writes)
- [ ] `ufsck --repair` fixes metadata corruption safely
- [ ] `ufsinfo` displays all structures correctly
- [ ] All tools build on Windows, Linux, macOS
- [ ] Man pages / help text complete

---

## Milestone 5: FUSE Driver (First Usable FS)

**Duration:** 4 weeks  
**Target:** 2026-03-19

### Objectives
Build a working FUSE driver using the shared Zig core for cross-platform testing.

### Components
- [ ] FUSE low-level operations mapping
- [ ] PAL implementation (pread/pwrite/fsync/ioctl)
- [ ] Inode cache (libfuse handles)
- [ ] Directory enumeration
- [ ] Extended attributes (capsule translation)
- [ ] Memory mapping (if supported by FUSE)
- [ ] File locking (advisory)

### Testing
- [ ] Mount on Linux (WSL 2)
- [ ] Mount on macOS (macFUSE)
- [ ] Mount on Windows (WinFsp)
- [ ] Cross-platform interoperability test suite:
  - Format on Windows → write files → mount on Linux → verify → write → mount on macOS → verify → mount on Windows → verify
- [ ] Crash simulation (power loss during operations)
- [ ] Performance baseline

### Exit Criteria
- [ ] FUSE driver mounts volumes created by `mkufs`
- [ ] Read/write/create/delete/rename work correctly
- [ ] Metadata preserved across Windows→Linux→macOS→Windows
- [ ] Crash recovery works (kill -9 during write → mount → consistent)
- [ ] Performance within 20% of ext4 for metadata ops
- [ ] Zero memory leaks (valgrind/ASan clean)

---

## Milestone 6: Linux Native VFS Driver

**Duration:** 4 weeks  
**Target:** 2026-04-16

### Objectives
Build production-grade kernel module for Linux.

### Components
- [ ] `file_system_type` registration
- [ ] Superblock operations
- [ ] Inode operations (getattr, setattr, xattr, fiemap)
- [ ] File operations (read_iter, write_iter, mmap, fsync, fallocate)
- [ ] Directory operations (iterate, lookup, create, unlink, rename)
- [ ] Address space operations (readpage, writepage, writepages, write_begin/end)
- [ ] Page cache integration
- [ ] Memory mapping support
- [ ] Block I/O via `submit_bio()` / `blkdev_issue_*`
- [ ] REQ_FUA for durability
- [ ] Module parameters (mount options)

### WSL 2 Development Workflow
- [ ] Build against WSL kernel headers
- [ ] Test with loop devices
- [ ] Test with `wsl --mount --bare` for raw block access
- [ ] Test with nbd/qemu-nbd

### Testing
- [ ] xfstests (generic, ext4 subset)
- [ ] fsx-linux (filesystem exerciser)
- [ ] Crash simulation (dm-flakey, power-fail)
- [ ] Performance benchmarks (fio)
- [ ] Memory leak detection (kmemleak)

### Exit Criteria
- [ ] Kernel module loads/unloads cleanly
- [ ] Mounts UFS volumes read-write
- [ ] Passes xfstests generic/001-099 (or equivalent)
- [ ] Page cache + mmap works
- [ ] No kernel oops/panic in stress testing
- [ ] Performance ≥ ext4 for metadata, ≥ 90% for data
- [ ] Builds on kernel 6.1, 6.6, 6.12

---

## Milestone 7: Windows 11 IFS Driver

**Duration:** 8 weeks  
**Target:** 2026-06-11

### Objectives
Build production-grade Windows filesystem driver.

### Components

#### Week 1-2: Driver Framework
- [ ] DriverEntry / DriverUnload
- [ ] VCB/FCB/CCB management
- [ ] IRP dispatch table
- [ ] Device object creation
- [ ] Mount/Unmount (FsMountVolume/FsUnmountVolume)

#### Week 2-3: Core IRP Handlers
- [ ] IRP_MJ_CREATE / CLOSE
- [ ] IRP_MJ_READ / WRITE (sync + async)
- [ ] IRP_MJ_SET_INFORMATION / QUERY_INFORMATION
- [ ] IRP_MJ_DIRECTORY_CONTROL
- [ ] IRP_MJ_FILE_SYSTEM_CONTROL
- [ ] IRP_MJ_CLEANUP

#### Week 3-4: Fast I/O & Cache Manager
- [ ] Fast I/O callbacks (read, write, query info)
- [ ] Cache Manager integration (CcInitializeCacheMap, MdlRead/Write)
- [ ] Read-ahead / Write-behind
- [ ] Paging I/O support

#### Week 4-5: Advanced Features
- [ ] Security callback (ACLs → SD mapping)
- [ ] Alternate Data Streams (capsule → $DATA:$name)
- [ ] Reparse points (symlinks, junctions, mount points)
- [ ] Compression (LZNT1-compatible API, but UFS uses LZ4/ZSTD internally)
- [ ] Sparse files
- [ ] Hard links
- [ ] Transactional NTFS (TxF) - optional

#### Week 5-6: Volume Management
- [ ] Mount Manager integration
- [ ] Drive letter assignment
- [ ] Volume GUID paths
- [ ] Auto-mount on insert
- [ ] Safe removal handling

#### Week 6-7: Installation & Signing
- [ ] INF file
- [ ] Catalog file
- [ ] Test signing workflow
- [ ] PnPUtil installation scripts
- [ ] PowerShell install/unmount scripts (Install-UFS.ps1, Uninstall-UFS.ps1, Mount-UFS.ps1, Dismount-UFS.ps1)

#### Week 7-8: Testing & Polish
- [ ] WHQL test suite (subset)
- [ ] File Explorer integration (copy, paste, rename, delete)
- [ ] Application compatibility (Office, VS Code, compilers)
- [ ] Crash recovery (power loss simulation)
- [ ] Performance (DiskSpd, custom benchmarks)
- [ ] Driver Verifier stress testing

### Exit Criteria
- [ ] Driver loads on Windows 11 (22H2+)
- [ ] Volumes appear in File Explorer with drive letters
- [ ] Full read/write/create/delete/rename in Explorer
- [ ] Applications work normally (Office, browsers, dev tools)
- [ ] Safe eject works for removable media
- [ ] Test signing works; production signing path documented
- [ ] Crash recovery verified (power loss → remount → consistent)
- [ ] Performance within 15% of NTFS for typical workloads
- [ ] Driver Verifier clean (no violations)

---

## Milestone 8: macOS FSKit Extension

**Duration:** 6 weeks  
**Target:** 2026-07-23

### Objectives
Build File System Extension for macOS 13+ (Ventura+).

### Components
- [ ] FSKit extension target in Xcode
- [ ] FileSystemExtension protocol implementation
- [ ] VolumeHandler (statFS, sync)
- [ ] DirectoryHandle (enumerate, getChild, create, remove, rename)
- [ ] FileHandle (read, write, truncate, get/set attributes)
- [ ] Zig core dynamic library integration
- [ ] PAL via IOKit (IOMedia, IOBlockStorageDevice)
- [ ] Extended attributes (capsule ↔ com.apple.*)
- [ ] Resource fork support
- [ ] Finder metadata (tags, labels, comments)
- [ ] Quarantine attributes
- [ ] Entitlements and sandboxing
- [ ] Notarization workflow
- [ ] Distribution (App Store / Developer ID)

### Testing
- [ ] Mount on macOS 13, 14, 15
- [ ] Finder integration (copy, paste, tags, preview)
- [ ] Time Machine backup
- [ ] Cross-platform metadata round-trip
- [ ] Performance benchmarks

### Exit Criteria
- [ ] Extension loads and mounts UFS volumes
- [ ] Finder operations work normally
- [ ] Metadata preserved: POSIX ↔ Windows ↔ macOS
- [ ] Notarized and distributable
- [ ] No kernel panics or extension crashes

---

## Milestone 9: UEFI Boot Support

**Duration:** 3 weeks  
**Target:** 2026-08-13

### Objectives
Build UEFI application for booting from UFS.

### Components
- [ ] Zig UEFI target build (x86_64, aarch64)
- [ ] EFI_SIMPLE_FILE_SYSTEM_PROTOCOL
- [ ] EFI_FILE_PROTOCOL (read-only)
- [ ] Driver Binding Protocol
- [ ] Block I/O via EFI_BLOCK_IO_PROTOCOL
- [ ] Read superblock, inodes, directories, file data
- [ ] Decompression (LZ4/ZSTD)
- [ ] BLAKE3 verification
- [ ] Boot configuration (ufs.cfg)
- [ ] Secure Boot signing
- [ ] QEMU/OVMF testing

### Exit Criteria
- [ ] UFS.efi loads in UEFI Shell
- [ ] Recognizes UFS partition
- [ ] Reads kernel/initrd from UFS volume
- [ ] Boots Linux kernel (test with minimal kernel)
- [ ] Secure Boot signed
- [ ] Works on x86-64 and ARM64 UEFI

---

## Milestone 10: Reliability & Performance

**Duration:** 6 weeks  
**Target:** 2026-09-24

### Objectives
Hardening, testing, and optimization.

### Crash Testing
- [ ] Block device simulator with fault injection
- [ ] Power loss at every journal protocol step
- [ ] Torn writes (partial sector)
- [ ] Failed flushes
- [ ] Corrupted journal records
- [ ] Interrupted recovery
- [ ] All scenarios pass 1000+ iterations

### Fuzz Testing
- [ ] Superblock parser
- [ ] Journal replay
- [ ] Directory traversal
- [ ] Extent management
- [ ] Compression decoding
- [ ] Capsule parsing
- [ ] Volume mounting
- [ ] AFL++ / libFuzzer integration

### Interoperability Testing
- [ ] Automated matrix: Win→Lin→Mac→Win (all permutations)
- [ ] Metadata preservation verification
- [ ] Conflict detection (case collision, reserved names)

### Performance Benchmarks
- [ ] fio: seq/random read/write, various block sizes, queue depths
- [ ] DiskSpd (Windows)
- [ ] xfstests performance suite
- [ ] Metadata ops: create, unlink, rename, stat, readdir
- [ ] Compression: ratio, CPU, throughput
- [ ] Mount/unmount time
- [ ] Recovery time
- [ ] Memory usage profiling

### Hardware Testing
- [ ] HDD (7200 RPM, 5400 RPM)
- [ ] SATA SSD (Samsung 870, WD Blue)
- [ ] NVMe SSD (Samsung 980/990, WD SN850)
- [ ] USB 3.0/3.1/3.2 Flash (multiple brands)
- [ ] SD cards (UHS-I, UHS-II, A1/A2)
- [ ] Virtual disks (VHDX, qcow2, raw)

### Exit Criteria
- [ ] Zero data loss in crash testing (1000+ iterations)
- [ ] Zero crashes in fuzzing (1M+ inputs)
- [ ] Interoperability matrix passes 100%
- [ ] Benchmarks published with raw data
- [ ] Performance targets met (see Architecture doc)
- [ ] No regressions on any tested hardware

---

## Milestone 11: Release Candidate

**Duration:** 4 weeks  
**Target:** 2026-10-22

### Objectives
Prepare v1.0 release candidate.

### Deliverables
- [ ] Source code (Git tag v1.0-rc1)
- [ ] Driver binaries (signed where applicable)
- [ ] Installation packages:
  - Windows: .msi or signed .inf + .cat + PowerShell
  - Linux: DKMS package, kernel module .ko
  - macOS: .appex in .app, notarized
- [ ] User tools: mkufs, ufsck, ufsinfo, ufsctl, ufsbench
- [ ] Documentation:
  - Architecture
  - On-disk specification
  - Installation guide
  - Formatting guide
  - Recovery guide
  - Developer guide
  - Known limitations
  - Release notes
- [ ] Compatibility matrix (OS versions, hardware)
- [ ] Test results (crash, fuzz, interop, benchmarks)
- [ ] Performance report

### Exit Criteria
- [ ] All v1 features implemented and tested
- [ ] Documentation complete and accurate
- [ ] Installation works on clean systems
- [ ] No critical/blocker bugs
- [ ] Release notes honest about limitations

---

## Resource Requirements

### Team Roles
| Role | Count | Responsibilities |
|------|-------|------------------|
| Systems Architect | 1 | Architecture, ADRs, cross-cutting |
| Zig Core Engineers | 2-3 | Core library, serialization, algorithms |
| Windows Driver Engineer | 1-2 | IFS driver, WDK, signing |
| Linux Kernel Engineer | 1-2 | VFS module, xfstests |
| macOS Engineer | 1 | FSKit, Swift, notarization |
| UEFI/Firmware Engineer | 1 | UEFI app, QEMU testing |
| QA/Testing Engineer | 1-2 | Crash sim, fuzzing, benchmarks, interop |
| DevOps/Build Engineer | 1 | CI/CD, cross-compilation, packaging |

### Infrastructure
- [ ] Windows 11 build machines (x64, ARM64)
- [ ] Linux build machines (x64, ARM64, kernel 6.1+)
- [ ] macOS build machines (Intel, Apple Silicon)
- [ ] Test hardware lab (HDD, SSD, NVMe, USB, SD)
- [ ] QEMU/OVMF CI runners
- [ ] Code signing certificates (EV, Apple Developer, Microsoft Attestation)

---

## Risk Mitigation

| Risk | Probability | Impact | Mitigation |
|------|-------------|--------|------------|
| Windows IFS complexity | High | High | Start early, study FastFAT, engage Microsoft IFS community |
| Linux kernel API changes | Medium | Medium | Target LTS kernels, abstract VFS glue |
| macOS FSKit immaturity | Medium | Medium | File feedback with Apple, fallback to macFUSE |
| Zig compiler bugs | Low | High | Pin Zig version, report upstream |
| Cross-platform metadata edge cases | High | High | Extensive test matrix, explicit conflict errors |
| Performance vs established FS | Medium | Medium | Profile early, optimize hot paths, realistic targets |
| Driver signing delays | Medium | High | Start EV cert process early, test signing for dev |

---

## Success Metrics (v1.0)

| Metric | Target |
|--------|--------|
| Cross-platform metadata round-trip | 100% preservation |
| Crash recovery success rate | 100% (1000+ simulations) |
| Fuzz testing crashes | 0 (1M+ inputs) |
| xfstests pass rate | > 95% generic tests |
| Windows app compatibility | Office, VS Code, browsers work |
| macOS Finder integration | Copy, tags, preview work |
| Sequential throughput (NVMe) | > 85% of raw device |
| Random 4K write (NVMe) | > 250K IOPS |
| Mount time (1 TB) | < 1 second |
| Recovery time (1 TB) | < 5 seconds |
| Memory overhead | < 50 MB base + 1 KB/inode |

---

*End of UFS Implementation Roadmap*