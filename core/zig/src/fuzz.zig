// UFS Fuzzing Infrastructure
// AFL++/libFuzzer compatible fuzz targets for all parsers

const std = @import("std");
const serialization = @import("serialization.zig");
const metadata = @import("metadata.zig");
const allocation = @import("allocation.zig");
const directory = @import("directory.zig");
const journal = @import("journal.zig");
const integrity = @import("integrity.zig");
const compression = @import("compression.zig");
const version = @import("version.zig");
const crypto = @import("crypto.zig");
const blockdev = @import("blockdev.zig");
const utils = @import("utils.zig");
const Allocator = std.mem.Allocator;

pub const FuzzError = error{
    InvalidInput,
    AllocationFailed,
};

// ============================================================================
// Fuzz Target Entry Points (for libFuzzer/AFL++)
// ============================================================================

// These are called by the fuzzer with arbitrary input data
// Return 0 on success, non-zero on crash (which the fuzzer detects)

export fn LLVMFuzzerTestOneInput(data: [*c]const u8, size: c_int) c_int {
    const input = data[0..@as(usize, @intCast(size))];
    _ = fuzzAll(input);
    return 0;
}

// ============================================================================
// Main Fuzz Dispatcher
// ============================================================================

fn fuzzAll(input: []const u8) !void {
    // Try each parser with the input
    // We don't care about success/failure, just that they don't crash

    // 1. Serialization reader (most fundamental)
    _ = fuzzSerializationReader(input);

    // 2. Metadata capsule
    _ = fuzzMetadataCapsule(input);

    // 3. Superblock / Volume format
    _ = fuzzSuperblock(input);

    // 4. AG Header
    _ = fuzzAGHeader(input);

    // 5. Inode
    _ = fuzzInode(input);

    // 6. Extent tree node
    _ = fuzzExtentNode(input);

    // 7. Free extent tree node
    _ = fuzzFreeExtentNode(input);

    // 8. Directory (linear + B-tree)
    _ = fuzzDirectory(input);

    // 9. Journal transaction
    _ = fuzzJournalTransaction(input);

    // 10. Compression
    _ = fuzzCompression(input);

    // 11. Integrity (CRC32C, BLAKE3)
    _ = fuzzIntegrity(input);

    // 12. Version/Feature flags
    _ = fuzzVersion(input);

    // 13. Crypto metadata
    _ = fuzzCrypto(input);

    // 14. Block device operations
    _ = fuzzBlockDevice(input);
}

// ============================================================================
// Individual Fuzz Targets
// ============================================================================

fn fuzzSerializationReader(input: []const u8) !void {
    var reader = serialization.createReader(input);
    // Try to read various primitive types until exhaustion
    while (!reader.eof()) {
        _ = reader.readU8() catch break;
        _ = reader.readU16() catch break;
        _ = reader.readU32() catch break;
        _ = reader.readU64() catch break;
        _ = reader.readI8() catch break;
        _ = reader.readI16() catch break;
        _ = reader.readI32() catch break;
        _ = reader.readI64() catch break;

        // Try string reads
        if (reader.remaining() >= 2) {
            const len = std.mem.readInt(u16, input[reader.offset..reader.offset+2], .little);
            if (len < 1024 && reader.remaining() >= 2 + len) {
                _ = reader.readString(std.testing.allocator) catch break;
            } else {
                break;
            }
        }

        // Try var bytes
        if (reader.remaining() >= 4) {
            const len = std.mem.readInt(u32, input[reader.offset..reader.offset+4], .little);
            if (len < 4096 && reader.remaining() >= 4 + len) {
                _ = reader.readVarBytes(std.testing.allocator) catch break;
            } else {
                break;
            }
        }
    }
}

fn fuzzMetadataCapsule(input: []const u8) !void {
    var reader = serialization.createReader(input);
    _ = metadata.MetadataCapsule.deserialize(&reader, std.testing.allocator) catch return;
}

fn fuzzSuperblock(input: []const u8) !void {
    if (input.len < 256) return;
    var reader = serialization.createReader(input);
    _ = version.VolumeFormat.deserialize(&reader, std.testing.allocator) catch return;
}

fn fuzzAGHeader(input: []const u8) !void {
    if (input.len < allocation.AGHeader.SIZE) return;
    var reader = serialization.createReader(input);
    _ = allocation.AGHeader.deserialize(&reader, std.testing.allocator) catch return;
}

fn fuzzInode(input: []const u8) !void {
    if (input.len < 256) return;
    // Inode is 256 bytes fixed
    var reader = serialization.createReader(input);
    // Try to parse as much as possible
    _ = reader.readU32() catch return; // magic
    _ = reader.readU16() catch return; // version
    _ = reader.readU16() catch return; // flags
    _ = reader.readU64() catch return; // inode_number
    _ = reader.readU64() catch return; // generation
    _ = reader.readU64() catch return; // capsule_id
    _ = reader.readU32() catch return; // mode
    _ = reader.readU32() catch return; // uid
    _ = reader.readU32() catch return; // gid
    _ = reader.readU32() catch return; // link_count
    _ = reader.readU32() catch return; // flags2
    _ = reader.readU32() catch return; // reserved1
    _ = reader.readU64() catch return; // size
    _ = reader.readU64() catch return; // allocated_size
    _ = reader.readU64() catch return; // atime
    _ = reader.readU64() catch return; // mtime
    _ = reader.readU64() catch return; // ctime
    _ = reader.readU64() catch return; // extent_tree_root
    _ = reader.readU16() catch return; // extent_count
    _ = reader.readU16() catch return; // extent_tree_height
    _ = reader.readU32() catch return; // reserved2
    _ = reader.readU16() catch return; // compression_algo
    _ = reader.readU16() catch return; // compression_level
    _ = reader.readU32() catch return; // encryption_key_id
    _ = reader.readU64() catch return; // reserved3
    _ = reader.readU64() catch return; // capsule_offset
    _ = reader.readU32() catch return; // capsule_size
    _ = reader.readU32() catch return; // capsule_flags
    // Skip reserved (112 bytes)
    if (reader.remaining() >= 112) {
        reader.offset += 112;
    }
    _ = reader.readU32() catch return; // crc32c
}

fn fuzzExtentNode(input: []const u8) !void {
    if (input.len < 16) return;
    var reader = serialization.createReader(input);
    _ = reader.readU32() catch return; // magic
    _ = reader.readU16() catch return; // version
    _ = reader.readU16() catch return; // flags
    _ = reader.readU16() catch return; // entry_count
    _ = reader.readU16() catch return; // max_entries
    _ = reader.readU16() catch return; // is_leaf
    _ = reader.readU16() catch return; // level

    const entry_count = @as(usize, @intCast(@min(@as(u16, @intCast(1000)), @as(u16, @intCast(reader.remaining() / 32)))));
    for (0..entry_count) |_| {
        _ = reader.readU64() catch return; // logical_offset / max_logical_offset
        _ = reader.readU64() catch return; // physical_block / child_block
        _ = reader.readU32() catch return; // length
        _ = reader.readU16() catch return; // compression_algo
        _ = reader.readU16() catch return; // flags
        _ = reader.readU32() catch return; // original_length
        _ = reader.readU32() catch return; // compressed_length
        _ = reader.readU32() catch return; // crc32c_header
        if (reader.remaining() >= 32) {
            reader.offset += 32; // blake3_hash
        }
    }
    _ = reader.readU32() catch return; // crc32c
}

fn fuzzFreeExtentNode(input: []const u8) !void {
    if (input.len < 16) return;
    var reader = serialization.createReader(input);
    _ = reader.readU32() catch return; // magic
    _ = reader.readU16() catch return; // version
    _ = reader.readU16() catch return; // flags
    _ = reader.readU16() catch return; // entry_count
    _ = reader.readU16() catch return; // max_entries
    _ = reader.readU16() catch return; // is_leaf
    _ = reader.readU16() catch return; // level

    const entry_count = @as(usize, @intCast(@min(@as(u16, @intCast(1000)), @as(u16, @intCast(reader.remaining() / 16)))));
    for (0..entry_count) |_| {
        _ = reader.readU64() catch return; // start_cluster / max_start_cluster
        _ = reader.readU64() catch return; // length / child_block
    }
    _ = reader.readU32() catch return; // crc32c
}

fn fuzzDirectory(input: []const u8) !void {
    // Try linear directory first
    var reader = serialization.createReader(input);
    _ = directory.LinearDirectory.deserialize(&reader, std.testing.allocator) catch {
        // Try B-tree directory
        var reader2 = serialization.createReader(input);
        _ = fuzzBTreeDirectory(&reader2) catch return;
    };
}

fn fuzzBTreeDirectory(reader: *serialization.Reader(void)) !void {
    _ = reader.readU32() catch return; // magic
    _ = reader.readU16() catch return; // version
    _ = reader.readU16() catch return; // flags
    _ = reader.readU16() catch return; // entry_count
    _ = reader.readU16() catch return; // max_entries
    _ = reader.readU16() catch return; // is_leaf
    _ = reader.readU16() catch return; // level

    const entry_count = @as(usize, @intCast(@min(@as(u16, @intCast(1000)), @as(u16, @intCast(reader.remaining() / 24)))));
    for (0..entry_count) |_| {
        _ = reader.readU64() catch return; // key_hash
        _ = reader.readU64() catch return; // child/inode
        if (reader.remaining() >= 2) {
            const name_len = std.mem.readInt(u16, reader.data[reader.offset..reader.offset+2], .little);
            if (name_len < 256 && reader.remaining() >= 2 + name_len) {
                reader.offset += 2 + name_len;
            }
        }
    }
    _ = reader.readU32() catch return; // crc32c
}

fn fuzzJournalTransaction(input: []const u8) !void {
    if (input.len < journal.TransactionHeader.BASE_SIZE) return;
    var reader = serialization.createReader(input);
    _ = journal.TransactionHeader.deserialize(&reader, std.testing.allocator) catch return;

    // Try to parse operations
    var ops_read: u32 = 0;
    while (ops_read < 1000 && reader.remaining() > 0) {
        _ = reader.readU8() catch break; // op_type
        const payload_len = @as(usize, @intCast(@min(@as(u32, @intCast(4096)), reader.readU32() catch break)));
        if (reader.remaining() >= payload_len) {
            reader.offset += payload_len;
        } else {
            break;
        }
        ops_read += 1;
    }
    _ = reader.readU32() catch return; // crc32c
}

fn fuzzCompression(input: []const u8) !void {
    // Test incompressible detector
    _ = compression.IncompressibleDetector.quickCheck(input);
    _ = compression.IncompressibleDetector.isIncompressible(input, 256);

    // Test compression context creation (with NONE algorithm to avoid FFI)
    var ctx = compression.CompressionContext.init(std.testing.allocator, compression.CompressionAlgorithm.NONE, 0) catch return;
    defer ctx.deinit();

    var output = std.testing.allocator.alloc(u8, input.len + 16) catch return;
    defer std.testing.allocator.free(output);

    _ = ctx.compress(input, output) catch return;

    // Test decompression round-trip
    var decompressed = std.testing.allocator.alloc(u8, input.len) catch return;
    defer std.testing.allocator.free(decompressed);
    _ = ctx.decompress(input, decompressed, input.len) catch return;
}

fn fuzzIntegrity(input: []const u8) !void {
    // CRC32C
    _ = integrity.Crc32c.compute(input);
    _ = integrity.Crc32c.computeHw(input);
    if (input.len >= 8) {
        _ = integrity.Crc32c.combine(0, 0, input.len);
    }

    // BLAKE3
    _ = integrity.Blake3.hash(input);
    _ = integrity.Blake3Simd.hash(input);
    _ = integrity.Blake3Simd.hashMany(&[_][]const u8{input, input});

    // Hasher streaming
    var hasher = integrity.Blake3.Hasher.init();
    hasher.update(input);
    _ = hasher.finalize();

    // Keyed
    var key: [32]u8 = undefined;
    @memset(&key, 0x42);
    _ = integrity.Blake3.hashKeyed(key, input);

    // Derive key
    _ = integrity.Blake3.deriveKey("context", input);
}

fn fuzzVersion(input: []const u8) !void {
    // Parse version string
    if (input.len > 0 && input.len < 64) {
        _ = version.Version.parse(input) catch {};
    }

    // Feature flags
    var reader = serialization.createReader(input);
    _ = version.FeatureFlags.deserialize(&reader, std.testing.allocator) catch return;

    // Mount compatibility check
    const flags = version.FeatureFlags{};
    _ = flags.checkCompatibility(version.SupportedFeatures.INCOMPAT, version.SupportedFeatures.COMPAT_RO, version.SupportedFeatures.COMPAT_RW);
}

fn fuzzCrypto(input: []const u8) !void {
    // Encryption metadata
    var reader = serialization.createReader(input);
    _ = crypto.EncryptionMetadata.deserialize(&reader, std.testing.allocator) catch return;

    // Volume key manager
    if (input.len >= 32) {
        var key: [32]u8 = undefined;
        @memcpy(&key, input[0..32]);
        _ = crypto.VolumeKeyManager.createFromPassword("test", crypto.VolumeKeyManager.KeyDerivationParams{
            .salt = key,
        }) catch return;
    }
}

fn fuzzBlockDevice(input: []const u8) !void {
    // Test geometry parsing
    var reader = serialization.createReader(input);
    _ = reader.readU64() catch return; // cylinders
    _ = reader.readU32() catch return; // heads
    _ = reader.readU32() catch return; // sectors_per_track
    _ = reader.readU32() catch return; // bytes_per_sector
}

// ============================================================================
// Structure-Aware Fuzzing (for AFL++ with dictionaries)
// ============================================================================

// These generate valid-ish structures for deeper fuzzing

pub fn generateValidSuperblock(allocator: Allocator) ![]u8 {
    var writer = serialization.createWriter(allocator);
    defer writer.deinit();

    const sb = version.VolumeFormat{
        .version = version.Version.CURRENT,
        .features = version.FeatureFlags{},
        .creation_time = utils.timestamp(),
        .last_mount_time = utils.timestamp(),
        .last_write_time = utils.timestamp(),
        .mount_count = 0,
        .max_mount_count = 20,
        .check_interval = 180 * 24 * 60 * 60,
        .last_check_time = utils.timestamp(),
        .creator_os = version.VolumeFormat.OS_LINUX,
        .default_mount_opts = 0,
    };

    try sb.serialize(&writer);
    return try writer.toOwnedSlice();
}

pub fn generateValidAGHeader(allocator: Allocator) ![]u8 {
    var writer = serialization.createWriter(allocator);
    defer writer.deinit();

    const ag = allocation.AGHeader{
        .magic = 0x41470000,
        .version = 1,
        .flags = 0,
        .ag_index = 0,
        .ag_offset = 0,
        .ag_size = 1_073_741_824,
        .cluster_size = 4096,
        .free_clusters = 1_073_741_824,
        .free_extents = 1,
        .free_tree_root = 0,
        .bitmap_offset = 1,
        .inode_table_offset = 10,
        .inode_count = 512,
        .free_inodes = 512,
        .generation = 1,
    };

    try ag.serialize(&writer);
    try writer.align(4096);
    const crc = utils.crc32c(writer.bytes());
    try writer.writeU32(crc);

    return try writer.toOwnedSlice();
}

pub fn generateValidInode(allocator: Allocator) ![]u8 {
    var writer = serialization.createWriter(allocator);
    defer writer.deinit();

    try writer.writeU32(0x494E4F00); // magic
    try writer.writeU16(1); // version
    try writer.writeU16(0); // flags
    try writer.writeU64(1); // inode_number
    try writer.writeU64(1); // generation
    try writer.writeU64(utils.generateUuidv7()); // capsule_id
    try writer.writeU32(0o100644); // mode
    try writer.writeU32(1000); // uid
    try writer.writeU32(1000); // gid
    try writer.writeU32(1); // link_count
    try writer.writeU32(0); // flags2
    try writer.writeU32(0); // reserved1
    try writer.writeU64(0); // size
    try writer.writeU64(0); // allocated_size
    try writer.writeU64(utils.timestamp()); // atime
    try writer.writeU64(utils.timestamp()); // mtime
    try writer.writeU64(utils.timestamp()); // ctime
    try writer.writeU64(0); // extent_tree_root
    try writer.writeU16(0); // extent_count
    try writer.writeU16(0); // extent_tree_height
    try writer.writeU32(0); // reserved2
    try writer.writeU16(0); // compression_algo
    try writer.writeU16(0); // compression_level
    try writer.writeU32(0); // encryption_key_id
    try writer.writeU64(0); // reserved3
    try writer.writeU64(0); // capsule_offset
    try writer.writeU32(0); // capsule_size
    try writer.writeU32(0); // capsule_flags
    // Reserved 112 bytes
    for (0..112) |_| {
        try writer.writeU8(0);
    }
    // CRC32C
    try writer.align(256);
    const crc = utils.crc32c(writer.bytes());
    try writer.writeU32(crc);

    return try writer.toOwnedSlice();
}

pub fn generateValidJournalTransaction(allocator: Allocator) ![]u8 {
    var writer = serialization.createWriter(allocator);
    defer writer.deinit();

    const txn = journal.Transaction{
        .header = journal.TransactionHeader{
            .txid = 1,
            .timestamp = utils.timestamp(),
            .operation_count = 1,
            .flags = 0,
        },
        .operations = &[_]journal.Operation{{
            .op_type = journal.OperationType.CREATE_INODE,
            .payload = &[_]u8{},
        }},
    };

    try txn.serialize(&writer);
    try writer.align(8);
    const crc = utils.crc32c(writer.bytes());
    try writer.writeU32(crc);

    return try writer.toOwnedSlice();
}

// ============================================================================
// Fuzz Dictionary Entries (for AFL++ -dict=)
// ============================================================================

// Magic numbers that should be in the dictionary
const MAGIC_DICTIONARY = [
    "UFS\0",        // 0x55465300
    "JURN",         // 0x4A55524E
    "TXN\0",        // 0x54584E00
    "AG\0\0",       // 0x41470000
    "INO\0",        // 0x494E4F00
    "EXT\0",        // 0x45585400
    "DIR\0",        // 0x44495200
    "DTR\0",        // 0x44545200
    "FRE\0",        // 0x46524500
    "CAPS",         // 0x43415053
];

// Operation types
const OP_DICTIONARY = [
    "\x01", // CREATE_INODE
    "\x02", // DELETE_INODE
    "\x03", // UPDATE_INODE_META
    "\x04", // LINK_DIRENT
    "\x05", // UNLINK_DIRENT
    "\x06", // RENAME_DIRENT
    "\x07", // ALLOCATE_EXTENT
    "\x08", // DEALLOCATE_EXTENT
    "\x09", // UPDATE_BITMAP
    "\x0A", // UPDATE_SUPERBLOCK
    "\x0B", // CHECKPOINT
    "\x0C", // SET_XATTR
    "\x0D", // REMOVE_XATTR
    "\x0E", // UPDATE_CAPSULE
];

// Compression algorithms
const COMP_DICTIONARY = [
    "\x00\x00", // NONE
    "\x01\x00", // LZ4
    "\x02\x00", // ZSTD
    "\x03\x00", // ZSTD_HIGH
];

// ============================================================================
// Fuzz Test Harness (for zig test)
// ============================================================================

test "fuzz serialization reader" {
    // Empty input
    try fuzzSerializationReader(&[_]u8{});

    // Random data
    var rng = std.Random.DefaultPrng.init(0xDEADBEEF);
    var buf: [1024]u8 = undefined;
    for (&buf) |*b| {
        b.* = rng.random();
    }
    try fuzzSerializationReader(&buf);
}

test "fuzz metadata capsule" {
    // Empty
    try fuzzMetadataCapsule(&[_]u8{});

    // Generated valid capsule
    const capsule = try generateValidMetadataCapsule(std.testing.allocator);
    defer std.testing.allocator.free(capsule);
    try fuzzMetadataCapsule(capsule);
}

test "fuzz superblock" {
    const sb = try generateValidSuperblock(std.testing.allocator);
    defer std.testing.allocator.free(sb);
    try fuzzSuperblock(sb);
}

test "fuzz AG header" {
    const ag = try generateValidAGHeader(std.testing.allocator);
    defer std.testing.allocator.free(ag);
    try fuzzAGHeader(ag);
}

test "fuzz inode" {
    const inode = try generateValidInode(std.testing.allocator);
    defer std.testing.allocator.free(inode);
    try fuzzInode(inode);
}

test "fuzz journal transaction" {
    const txn = try generateValidJournalTransaction(std.testing.allocator);
    defer std.testing.allocator.free(txn);
    try fuzzJournalTransaction(txn);
}

test "fuzz all parsers with random data" {
    var rng = std.Random.DefaultPrng.init(0xCAFEBABE);
    for (0..100) |_| {
        var buf: [4096]u8 = undefined;
        for (&buf) |*b| {
            b.* = rng.random();
        }
        try fuzzAll(&buf);
    }
}

fn generateValidMetadataCapsule(allocator: Allocator) ![]u8 {
    var capsule = metadata.MetadataCapsule.init(allocator);
    defer capsule.deinit();

    capsule.header.capsule_id = utils.generateUuidv7();
    capsule.header.inode = 1;

    try capsule.addEntry(0x0001, 0x0001, "mode_uid_gid", &[_]u8{0xA4, 0x81, 0x00, 0x00, 0xE8, 0x03, 0x00, 0x00, 0xE8, 0x03, 0x00, 0x00});

    var writer = serialization.createWriter(allocator);
    defer writer.deinit();
    try capsule.serialize(&writer);
    return try writer.toOwnedSlice();
}

// ============================================================================
// Property-Based Testing Helpers
// ============================================================================

pub const PropertyTest = struct {
    pub fn serializationRoundTrip(
        allocator: Allocator,
        generate: fn(Allocator) ![]u8,
        parse: fn([]const u8, Allocator) !void,
    ) !void {
        for (0..100) |_| {
            const data = try generate(allocator);
            defer allocator.free(data);
            try parse(data, allocator);
        }
    }

    pub fn crc32cInvariant(data: []const u8) bool {
        const crc1 = integrity.Crc32c.compute(data);
        const crc2 = integrity.Crc32c.compute(data);
        return crc1 == crc2;
    }

    pub fn blake3Invariant(data: []const u8) bool {
        const h1 = integrity.Blake3.hash(data);
        const h2 = integrity.Blake3.hash(data);
        return std.mem.eql(u8, &h1, &h2);
    }

    pub fn compressionRoundTrip(
        allocator: Allocator,
        data: []const u8,
    ) !bool {
        var ctx = try compression.CompressionContext.init(allocator, compression.CompressionAlgorithm.LZ4, 3);
        defer ctx.deinit();

        var compressed = try allocator.alloc(u8, compression.lz4_compressBound(data.len));
        defer allocator.free(compressed);

        const result = try ctx.compress(data, compressed);

        if (result.algorithm == compression.CompressionAlgorithm.NONE) {
            return true; // Incompressible, stored as-is
        }

        var decompressed = try allocator.alloc(u8, data.len);
        defer allocator.free(decompressed);

        const decomp_len = try ctx.decompress(compressed[0..result.compressed_size], decompressed, data.len);
        return decomp_len == data.len and std.mem.eql(u8, data, decompressed[0..decomp_len]);
    }
};

// ============================================================================
// Fuzz Target Main (for standalone fuzzing binary)
// ============================================================================

pub fn fuzzMain() !void {
    // This would be the entry point for a standalone fuzzing binary
    // Read from stdin and fuzz
    var stdin = std.io.getStdIn().reader();
    var buffer = std.ArrayList(u8).init(std.heap.page_allocator);
    defer buffer.deinit();

    try stdin.readAll(buffer.writer());
    try fuzzAll(buffer.items);
}

pub fn main() !void {
    try fuzzMain();
}
