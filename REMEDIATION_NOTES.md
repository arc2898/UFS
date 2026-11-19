# UFS remediation notes

## Scope

This pass addresses defects found by static inspection of the uploaded archive. The original ZIP is preserved; changes are made in the working copy.

## Changes made

- Replaced the placeholder BLAKE3 mixers in `src/utils.zig` and `src/integrity.zig` with Zig's standard-library BLAKE3 implementation.
- Added a BLAKE3 empty-input known-answer test and edge-case path utility tests.
- Repaired malformed path helper loops and handled empty paths, root paths, trailing separators, dotfiles, and compound extensions.
- Changed random-byte allocation to take an allocator and return an error union instead of leaking page-allocator memory or silently returning an empty slice.
- Added missing `Self = @This()` and `Allocator = std.mem.Allocator` declarations where source referenced undeclared identifiers.
- Replaced removed/deprecated `std.mem.set` and `std.mem.copy` calls with `@memset` and `@memcpy`.
- Added an owned-slice transfer to the serialization writer and fixed serialization helpers that returned memory owned by a writer that was immediately deinitialized.
- Corrected integrity-verifier receiver parameters and buffer ownership at call sites.
- Disabled the handwritten AES-GCM, ChaCha20-Poly1305, AES-XTS and file-key wrapping paths because the source implementations were incomplete/incorrect. These now fail closed with `UnsupportedAlgorithm`; no encryption capability is claimed.
- Repaired test-suite aggregation so a failed test does not terminate the suite under `set -e`, and prevented the integration script from overwriting block devices or other special files.
- Corrected the Zig 0.13 download URL and removed machine-specific Windows user paths from the quick-start documentation.
- Updated the build summary to describe the repository as experimental and unverified rather than production-ready.

## Validation performed

- Shell syntax validation: `bash -n scripts/*.sh` passed.
- Zig compilation and Zig tests: not run because the Zig compiler is not installed in this execution environment.
- Native FUSE, kernel, Windows, macOS, and UEFI integration: not run.

## Remaining high-risk work

- Compile the entire Zig workspace with the pinned Zig 0.13 toolchain and resolve all compiler diagnostics.
- Replace or remove placeholder/stub code in the filesystem core, journal replay, allocation, directory indexing, and platform adapters.
- Implement vetted AEAD and XTS support only with known-answer vectors, nonce/tweak uniqueness guarantees, and authenticated metadata; keep encryption disabled until then.
- Add power-loss crash injection, block-device fault injection, fuzzing, and fsck recovery tests.
- Validate every serialized on-disk structure against the format specification and ensure no compatibility-breaking layout changes are made without a format version change.
- Run filesystem exercisers and multi-platform interoperability tests on disposable disk images.
- Corrected Zig 0.13 standard-library API usage for BLAKE3 KDF, HMAC-SHA256, and file-open flags.
- Replaced non-existent string `.format(...)` calls in stress/benchmark code with `std.fmt.allocPrint` using scoped arena allocators.
- Removed invalid `try ... catch` combinations and repaired relative imports in the performance tool.
- Removed a circular import from the core module and supplied executable entry points for standalone benchmark/fuzz targets.
- Reworked the block-cache container to use the correct `AutoHashMap` API, allocator ownership, dirty-writeback error propagation, protected active entries, and safe eviction/free ordering.
- Corrected package manifest metadata and package paths.


## Final verification pass follow-up

- Wired the documented `bench`, `fuse-test`, and `perf-compare` targets; the benchmark/test targets run their executables.
- Made `zig build tools` install its executables into `zig-out/bin`, matching the setup/test scripts. Added the individual `mkufs`, `ufsck`, `ufsinfo`, and `ufsctl` targets and the documented fuzz-build target.
- Made `zig build fuse` install `ufs-fuse` into `zig-out/bin` and its shared C API runtime library into `zig-out/lib`; the `drivers` target uses that install step too. Added the documented per-platform driver scaffold targets.
- Added refusal checks to setup/test scripts so fixed test-image paths are not overwritten or followed through symlinks; standalone test runners default to process-unique image names.
- Removed remaining machine-specific project-root paths from Windows/WSL setup and verification scripts/documentation.
- Moved the block-device forward declaration before its first use in `ufs.h`, fixing the C forward-declaration order and using a named geometry struct so the header parses in both C and C++.
- Made the userspace FUSE test image uniquely named and exclusively created, initialized its contents to zero, and scheduled cleanup; added an overwrite refusal to the UEFI test-image generator.

## Verification rerun — 2026-11-19

- Bash syntax: passed for 9 shell scripts.
- Public C API header: passed strict GCC and Clang syntax checks as C11 and C++17 with warnings treated as errors.
- Zig imports: checked 130 relative imports across 42 Zig files; no missing paths.
- Documented Zig build targets: checked 18 distinct command targets; all map to declared or helper-generated build steps.
- Repository verification script: 59 passed, 0 failed, 2 skipped. Both skips are the Zig compiler presence check and Zig compilation/build check.
- Zig executable, FUSE 3 development package, and Linux kernel build headers are unavailable in this environment. Therefore Zig code, live FUSE, kernel module, Windows, macOS, and UEFI builds/tests have not been executed.
- Static checks do not establish filesystem correctness or production safety. Encryption remains deliberately disabled pending a vetted implementation.
