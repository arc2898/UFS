// Integrity Module
// Dual-layer checksums: CRC32C + BLAKE3

const std = @import("std");

pub const IntegrityError = @import("../src/integrity.zig").IntegrityError;
pub const ChecksumAlgorithm = @import("../src/integrity.zig").ChecksumAlgorithm;
pub const Crc32c = @import("../src/integrity.zig").Crc32c;
pub const Blake3 = @import("../src/integrity.zig").Blake3;
pub const Blake3Simd = @import("../src/integrity.zig").Blake3Simd;
pub const IntegrityVerifier = @import("../src/integrity.zig").IntegrityVerifier;
pub const ExtentHeader = @import("../src/integrity.zig").ExtentHeader;
pub const SuperblockVerifier = @import("../src/integrity.zig").SuperblockVerifier;
pub const Superblock = @import("../src/integrity.zig").Superblock;
pub const BatchVerifier = @import("../src/integrity.zig").BatchVerifier;
pub const AGHeader = @import("../src/integrity.zig").AGHeader;

pub const Allocator = std.mem.Allocator;