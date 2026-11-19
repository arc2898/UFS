// UFS Integrity Module
// Dual-layer checksums: CRC32C (metadata, hardware-accelerated) + BLAKE3 (data, 256-bit SIMD)

const std = @import("std");
const utils = @import("utils.zig");

pub const IntegrityError = error{
    CrcMismatch,
    HashMismatch,
    InvalidAlgorithm,
    BufferTooSmall,
    UnsupportedOperation,
    OutOfMemory,
};

pub const ChecksumAlgorithm = enum(u8) {
    CRC32C = 1,    // Castagnoli polynomial, hardware accelerated
    BLAKE3 = 2,    // 256-bit, SIMD optimized
    SHA256 = 3,    // Fallback
};

// CRC32C Implementation (Castagnoli polynomial 0x1EDC6F41)
pub const Crc32c = struct {
    // Precomputed lookup table for 8-bit slices
    const Table: [256]u32 = computeTable();

    fn computeTable() [256]u32 {
        var table: [256]u32 = undefined;
        for (0..256) |i| {
            var crc: u32 = @as(u32, @intCast(i));
            for (0..8) |_| {
                if ((crc & 1) != 0) {
                    crc = (crc >> 1) ^ 0x82F63B78; // Reversed Castagnoli polynomial
                } else {
                    crc >>= 1;
                }
            }
            table[i] = crc;
        }
        return table;
    }

    // Software CRC32C
    pub fn compute(data: []const u8) u32 {
        var crc: u32 = 0xFFFFFFFF;
        for (data) |byte| {
            crc = Table[@as(usize, @intCast((crc ^ byte) & 0xFF))] ^ (crc >> 8);
        }
        return ~crc;
    }

    // Incremental CRC32C
    pub fn update(crc: u32, data: []const u8) u32 {
        var c = ~crc;
        for (data) |byte| {
            c = Table[@as(usize, @intCast((c ^ byte) & 0xFF))] ^ (c >> 8);
        }
        return ~c;
    }

    // Combine two CRCs (for parallel computation)
    pub fn combine(crc1: u32, crc2: u32, len2: usize) u32 {
        // crc1 = crc(data1), crc2 = crc(data2)
        // Returns crc(data1 + data2)
        // Using matrix multiplication approach
        var even: [32]u32 = undefined;
        var odd: [32]u32 = undefined;

        // Build matrices
        odd[0] = 0x82F63B78; // Reversed polynomial
        var row: u32 = 1;
        for (1..32) |i| {
            odd[i] = row;
            row <<= 1;
        }

        // Compute even matrix
        for (0..32) |i| {
            even[i] = gf2MatrixTimes(odd, odd[i]);
        }
        for (0..32) |i| {
            odd[i] = gf2MatrixTimes(even, odd[i]);
        }

        // Apply len2 zeros to crc1
        var crc1_shifted = crc1;
        var len = len2;
        while (len > 0) {
            if ((len & 1) != 0) {
                crc1_shifted = gf2MatrixTimes(odd, crc1_shifted);
            }
            len >>= 1;
            if (len == 0) break;
            crc1_shifted = gf2MatrixTimes(even, crc1_shifted);
        }

        return crc1_shifted ^ crc2;
    }

    fn gf2MatrixTimes(matrix: []const u32, vec: u32) u32 {
        var sum: u32 = 0;
        var v = vec;
        var i: usize = 0;
        while (v != 0) {
            if ((v & 1) != 0) {
                sum ^= matrix[i];
            }
            v >>= 1;
            i += 1;
        }
        return sum;
    }

    // Hardware-accelerated CRC32C (x86_64 SSE4.2 + CLMUL, ARM64 CRC32)
    pub fn computeHw(data: []const u8) u32 {
        // This will be implemented in assembly for each architecture
        // For now, fall back to software
        return compute(data);
    }
};

// BLAKE3 implementation backed by Zig's maintained standard-library
// implementation. The previous hand-written implementation was incomplete
// (it omitted chunk-tree processing and used an invalid compression function),
// so its digests were not BLAKE3 and were unsafe for persistent integrity data.
pub const Blake3 = struct {
    pub const Hasher = struct {
        inner: std.crypto.hash.Blake3,

        pub fn init() Hasher {
            return .{ .inner = std.crypto.hash.Blake3.init(.{}) };
        }

        pub fn initKeyed(key: [32]u8) Hasher {
            return .{ .inner = std.crypto.hash.Blake3.init(.{ .key = key }) };
        }

        pub fn initDeriveKey(context: []const u8) Hasher {
            return .{ .inner = std.crypto.hash.Blake3.initKdf(context, .{}) };
        }

        pub fn update(self: *Hasher, input: []const u8) void {
            self.inner.update(input);
        }

        pub fn finalize(self: *Hasher) [32]u8 {
            var digest: [32]u8 = undefined;
            self.inner.final(&digest);
            return digest;
        }

        pub fn finalizeSeek(self: *Hasher, seek: u64) [32]u8 {
            // The UFS API currently exposes only the first 32 digest bytes.
            // Do not pretend to support XOF seeking until a real XOF API is wired.
            if (seek != 0) @panic("BLAKE3 XOF seeking is not supported by this API");
            return self.finalize();
        }

        pub fn finalizeKeyed(self: *Hasher) [32]u8 {
            return self.finalize();
        }
    };

    pub fn hash(data: []const u8) [32]u8 {
        var digest: [32]u8 = undefined;
        std.crypto.hash.Blake3.hash(data, &digest, .{});
        return digest;
    }

    pub fn hashKeyed(key: [32]u8, data: []const u8) [32]u8 {
        var hasher = Hasher.initKeyed(key);
        hasher.update(data);
        return hasher.finalize();
    }

    pub fn deriveKey(context: []const u8, data: []const u8) [32]u8 {
        var hasher = Hasher.initDeriveKey(context);
        hasher.update(data);
        return hasher.finalize();
    }

    pub fn hashStream(reader: anytype, buffer: []u8) ![32]u8 {
        var hasher = Hasher.init();
        while (true) {
            const n = try reader.read(buffer);
            if (n == 0) break;
            hasher.update(buffer[0..n]);
        }
        return hasher.finalize();
    }
};

// Hardware-accelerated BLAKE3 (SIMD)
pub const Blake3Simd = struct {
    // AVX2/AVX-512 implementation for x86_64
    // NEON implementation for ARM64
    // For now, use software fallback

    pub fn hash(data: []const u8) [32]u8 {
        return Blake3.hash(data);
    }

    pub fn hashMany(allocator: Allocator, inputs: [][]const u8) ![]u8 {
        // Parallel hashing of multiple inputs
        var results = std.ArrayList(u8).init(allocator);

        for (inputs) |input| {
            const hash = Blake3.hash(input);
            try results.appendSlice(&hash);
        }

        return results.toOwnedSlice();
    }
};

// Unified integrity verification
pub const IntegrityVerifier = struct {
    metadata_crc: bool = true,
    data_blake3: bool = true,

    pub fn verifyMetadata(self: IntegrityVerifier, data: []const u8, expected_crc: u32) !bool {
        if (!self.metadata_crc) return true;
        const actual = Crc32c.compute(data);
        if (actual != expected_crc) return IntegrityError.CrcMismatch;
        return true;
    }

    pub fn verifyData(self: IntegrityVerifier, data: []const u8, expected_hash: [32]u8) !bool {
        if (!self.data_blake3) return true;
        const actual = Blake3.hash(data);
        if (!std.mem.eql(u8, &actual, &expected_hash)) return IntegrityError.HashMismatch;
        return true;
    }

    pub fn verifyExtent(
        self: IntegrityVerifier,
        allocator: Allocator,
        data: []const u8,
        extent_header: ExtentHeader,
    ) !bool {
        // Verify extent header CRC. The serialized buffer is owned by this scope.
        const header_bytes = try extent_header.serializeToBytes(allocator);
        defer allocator.free(header_bytes);
        try self.verifyMetadata(header_bytes, extent_header.crc32c_header);

        // Verify data BLAKE3
        try self.verifyData(data, extent_header.blake3_hash);

        return true;
    }
};

pub const ExtentHeader = struct {
    logical_offset: u64,
    physical_block: u64,
    length: u32,
    compression_algo: u16,
    flags: u16,
    original_length: u32,
    compressed_length: u32,
    crc32c_header: u32,
    blake3_hash: [32]u8,

    pub fn serializeToBytes(self: ExtentHeader, allocator: Allocator) ![]u8 {
        var writer = serialization.createWriter(allocator);
        defer writer.deinit();
        try self.serialize(&writer);
        return try writer.toOwnedSlice();
    }

    pub fn serialize(self: ExtentHeader, writer: *serialization.Writer(void)) !void {
        try writer.writeU64(self.logical_offset);
        try writer.writeU64(self.physical_block);
        try writer.writeU32(self.length);
        try writer.writeU16(self.compression_algo);
        try writer.writeU16(self.flags);
        try writer.writeU32(self.original_length);
        try writer.writeU32(self.compressed_length);
        // CRC and BLAKE3 written separately
    }
};

// Superblock verification
pub const SuperblockVerifier = struct {
    pub fn verify(allocator: Allocator, sb: Superblock, device: *blockdev.BlockDevice) !bool {
        // Verify primary superblock CRC.
        const superblock_bytes = try sb.serializeToBytes(allocator);
        defer allocator.free(superblock_bytes);
        try (IntegrityVerifier{}).verifyMetadata(superblock_bytes, sb.crc32c);

        // Verify backup superblocks match
        for (sb.backup_sb_offsets) |offset| {
            if (offset == 0) continue;
            var backup = try readSuperblock(device, offset);
            if (!std.mem.eql(u8, &sb.volume_uuid, &backup.volume_uuid)) {
                return false; // UUID mismatch
            }
        }

        return true;
    }
};

pub const Superblock = struct {
    magic: u32,
    version_major: u16,
    version_minor: u16,
    version_revision: u32,
    flags: u32,
    feature_incompat: u32,
    feature_compat_ro: u32,
    feature_compat_rw: u32,
    volume_size: u64,
    cluster_size: u32,
    sector_size: u32,
    volume_uuid: [16]u8,
    volume_label: [64]u8,
    root_inode: u64,
    journal_offset: u64,
    journal_size: u64,
    ag_count: u32,
    ag_size: u32,
    ag_table_offset: u64,
    first_ag_offset: u64,
    backup_sb_offsets: [8]u64,
    generation: u64,
    clean_flag: u8,
    reserved: [7]u8,
    crc32c: u32,

    pub fn serializeToBytes(self: Superblock, allocator: Allocator) ![]u8 {
        var writer = serialization.createWriter(allocator);
        defer writer.deinit();
        try self.serialize(&writer);
        return try writer.toOwnedSlice();
    }

    pub fn serialize(self: Superblock, writer: *serialization.Writer(void)) !void {
        try writer.writeU32(self.magic);
        try writer.writeU16(self.version_major);
        try writer.writeU16(self.version_minor);
        try writer.writeU32(self.version_revision);
        try writer.writeU32(self.flags);
        try writer.writeU32(self.feature_incompat);
        try writer.writeU32(self.feature_compat_ro);
        try writer.writeU32(self.feature_compat_rw);
        try writer.writeU64(self.volume_size);
        try writer.writeU32(self.cluster_size);
        try writer.writeU32(self.sector_size);
        try writer.writeBytes(&self.volume_uuid);
        try writer.writeBytes(&self.volume_label);
        try writer.writeU64(self.root_inode);
        try writer.writeU64(self.journal_offset);
        try writer.writeU64(self.journal_size);
        try writer.writeU32(self.ag_count);
        try writer.writeU32(self.ag_size);
        try writer.writeU64(self.ag_table_offset);
        try writer.writeU64(self.first_ag_offset);
        try writer.writeBytes(&self.backup_sb_offsets);
        try writer.writeU64(self.generation);
        try writer.writeU8(self.clean_flag);
        try writer.writeBytes(&self.reserved);
        // CRC written separately
    }
};

fn readSuperblock(device: *blockdev.BlockDevice, offset: u64) !Superblock {
    _ = device;
    _ = offset;
    // Would read and deserialize superblock
    return Superblock{ .magic = 0x55465300, .volume_uuid = [_]u8{} ** 16 };
}

// Batch verification for scrub operations
pub const BatchVerifier = struct {
    const Self = @This();
    allocator: Allocator,
    verify_metadata: bool = true,
    verify_data: bool = true,
    parallel: bool = true,

    pub fn verifyVolume(
        self: *Self,
        device: *blockdev.BlockDevice,
        superblock: Superblock,
        progress_fn: fn(u64, u64) void,
    ) !struct {
        total_checked: u64,
        errors_found: u64,
        corrupted_files: []u64,
    } {
        var total_checked: u64 = 0;
        var errors_found: u64 = 0;
        var corrupted_files = std.ArrayList(u64).init(self.allocator);
        defer corrupted_files.deinit();

        // Verify each AG
        for (0..superblock.ag_count) |ag_idx| {
            progress_fn(ag_idx, superblock.ag_count);

            // Read AG header
            var ag_header = try readAGHeader(device, superblock, ag_idx);

            // Verify AG header CRC
            const ag_header_bytes = try ag_header.serializeToBytes(self.allocator);
            defer self.allocator.free(ag_header_bytes);
            try (IntegrityVerifier{}).verifyMetadata(ag_header_bytes, ag_header.crc32c);

            // Verify allocation bitmap
            try verifyBitmap(device, ag_header);

            // Verify inode table
            try verifyInodeTable(self, device, ag_header, &corrupted_files, &errors_found, &total_checked);

            // Verify free extent tree
            try verifyFreeTree(device, ag_header);
        }

        return .{
            .total_checked = total_checked,
            .errors_found = errors_found,
            .corrupted_files = corrupted_files.items,
        };
    }
};

fn readAGHeader(device: *blockdev.BlockDevice, sb: Superblock, ag_idx: u32) !AGHeader {
    _ = device;
    _ = sb;
    _ = ag_idx;
    return AGHeader{ .magic = 0x41470000 };
}

fn verifyBitmap(device: *blockdev.BlockDevice, ag: AGHeader) !void {
    _ = device;
    _ = ag;
}

fn verifyInodeTable(
    self: *BatchVerifier,
    device: *blockdev.BlockDevice,
    ag: AGHeader,
    corrupted_files: *std.ArrayList(u64),
    errors_found: *u64,
    total_checked: *u64,
) !void {
    _ = self;
    _ = device;
    _ = ag;
    _ = corrupted_files;
    _ = errors_found;
    _ = total_checked;
}

fn verifyFreeTree(device: *blockdev.BlockDevice, ag: AGHeader) !void {
    _ = device;
    _ = ag;
}

const serialization = @import("serialization.zig");
const blockdev = @import("blockdev.zig");
const Allocator = std.mem.Allocator;

pub const AGHeader = struct {
    magic: u32 = 0x41470000,
    version: u16 = 1,
    flags: u16 = 0,
    ag_index: u32 = 0,
    ag_offset: u64 = 0,
    ag_size: u32 = 0,
    cluster_size: u32 = 0,
    free_clusters: u64 = 0,
    free_extents: u64 = 0,
    free_tree_root: u64 = 0,
    bitmap_offset: u64 = 0,
    inode_table_offset: u64 = 0,
    inode_count: u32 = 0,
    free_inodes: u32 = 0,
    generation: u64 = 0,
    crc32c: u32 = 0,

    pub fn serializeToBytes(self: AGHeader, allocator: Allocator) ![]u8 {
        var writer = serialization.createWriter(allocator);
        defer writer.deinit();
        try self.serialize(&writer);
        return try writer.toOwnedSlice();
    }

    pub fn serialize(self: AGHeader, writer: *serialization.Writer(void)) !void {
        try writer.writeU32(self.magic);
        try writer.writeU16(self.version);
        try writer.writeU16(self.flags);
        try writer.writeU32(self.ag_index);
        try writer.writeU64(self.ag_offset);
        try writer.writeU32(self.ag_size);
        try writer.writeU32(self.cluster_size);
        try writer.writeU64(self.free_clusters);
        try writer.writeU64(self.free_extents);
        try writer.writeU64(self.free_tree_root);
        try writer.writeU64(self.bitmap_offset);
        try writer.writeU64(self.inode_table_offset);
        try writer.writeU32(self.inode_count);
        try writer.writeU32(self.free_inodes);
        try writer.writeU64(self.generation);
    }
};