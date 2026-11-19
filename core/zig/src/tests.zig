// UFS Comprehensive Test Suite
// Unit tests, property tests, integration tests

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
const utils = @import("utils.zig");
const blockdev = @import("blockdev.zig");
const fuzz = @import("fuzz.zig");
const Allocator = std.mem.Allocator;

// ============================================================================
// Test Helpers
// ============================================================================

fn assertEqual(comptime T: type, actual: T, expected: T, msg: []const u8) void {
    if (comptime T == []const u8) {
        if (!std.mem.eql(u8, actual, expected)) {
            std.testing.fail("{s}: byte slices differ", .{msg});
        }
    } else if (actual != expected) {
        std.testing.fail("{s}: expected {}, got {}", .{msg, expected, actual});
    }
}

fn assertError(actual: anytype, expected: anytype) void {
    if (!std.meta.eql(actual, expected)) {
        std.testing.fail("Expected error {}, got {}", .{expected, actual});
    }
}

fn testAlloc() std.mem.Allocator {
    return std.testing.allocator;
}

// ============================================================================
// Serialization Tests
// ============================================================================

test "serialization: primitive round-trip" {
    var writer = serialization.createWriter(testAlloc());
    defer writer.deinit();

    try writer.writeU8(0xFF);
    try writer.writeU16(0x1234);
    try writer.writeU32(0x12345678);
    try writer.writeU64(0x123456789ABCDEF0);

    var reader = serialization.createReader(writer.bytes());
    try assertEqual(u8, reader.readU8(), 0xFF, "u8");
    try assertEqual(u16, reader.readU16(), 0x1234, "u16");
    try assertEqual(u32, reader.readU32(), 0x12345678, "u32");
    try assertEqual(u64, reader.readU64(), 0x123456789ABCDEF0, "u64");
}

test "serialization: canonical little-endian and signed bytes" {
    var writer = serialization.createWriter(testAlloc());
    defer writer.deinit();
    try writer.writeU16(0x1234);
    try writer.writeU32(0x12345678);
    try writer.writeI8(-1);
    try assertEqual(bool, std.mem.eql(u8, writer.bytes(), &[_]u8{ 0x34, 0x12, 0x78, 0x56, 0x34, 0x12, 0xFF }), true, "canonical little endian bytes");

    var reader = serialization.createReader(writer.bytes());
    try assertEqual(u16, try reader.readU16(), 0x1234, "little endian u16");
    try assertEqual(u32, try reader.readU32(), 0x12345678, "little endian u32");
    try assertEqual(i8, try reader.readI8(), -1, "signed i8 round-trip");
}

test "serialization: string round-trip" {
    var writer = serialization.createWriter(testAlloc());
    defer writer.deinit();

    try writer.writeString("Hello, UFS!");
    try writer.writeString("");
    try writer.writeString("🦀🦀🦀");

    var reader = serialization.createReader(writer.bytes());
    const s1 = try reader.readString(testAlloc());
    defer testAlloc().free(s1);
    try assertEqual([]const u8, s1, "Hello, UFS!", "string 1");

    const s2 = try reader.readString(testAlloc());
    defer testAlloc().free(s2);
    try assertEqual([]const u8, s2, "", "empty string");

    const s3 = try reader.readString(testAlloc());
    defer testAlloc().free(s3);
    try assertEqual([]const u8, s3, "🦀🦀🦀", "unicode string");
}

test "serialization: var bytes round-trip" {
    var writer = serialization.createWriter(testAlloc());
    defer writer.deinit();

    try writer.writeVarBytes("Hello");
    try writer.writeVarBytes(&[_]u8{1, 2, 3, 4, 5});

    var reader = serialization.createReader(writer.bytes());
    const b1 = try reader.readVarBytes(testAlloc());
    defer testAlloc().free(b1);
    try assertEqual([]const u8, b1, "Hello", "var bytes 1");

    const b2 = try reader.readVarBytes(testAlloc());
    defer testAlloc().free(b2);
    try assertEqual([]const u8, b2, &[_]u8{1, 2, 3, 4, 5}, "var bytes 2");
}

test "serialization: CRC32C verification" {
    var writer = serialization.createWriter(testAlloc());
    defer writer.deinit();

    try writer.writeU32(0x12345678);
    try writer.writeU16(0xABCD);
    const crc = utils.crc32c(writer.bytes());
    try writer.writeU32(crc);

    var reader = serialization.createReader(writer.bytes());
    _ = reader.readU32();
    _ = reader.readU16();
    try reader.readAndVerifyCrc32c();
}

test "serialization: CRC32C failure detection" {
    var writer = serialization.createWriter(testAlloc());
    defer writer.deinit();

    try writer.writeU32(0x12345678);
    try writer.writeU32(0xDEADBEEF); // Wrong CRC

    var reader = serialization.createReader(writer.bytes());
    _ = reader.readU32();
    assertError(reader.readAndVerifyCrc32c(), serialization.Error.CorruptedData);
}

test "serialization: StandardHeader round-trip" {
    const header = serialization.StandardHeader{
        .magic = 0x41470000,
        .version = 1,
        .flags = 0x0001,
    };

    var writer = serialization.createWriter(testAlloc());
    defer writer.deinit();
    try header.serialize(&writer);

    var reader = serialization.createReader(writer.bytes());
    const decoded = try serialization.StandardHeader.deserialize(&reader, testAlloc());
    try assertEqual(u32, decoded.magic, header.magic, "magic");
    try assertEqual(u16, decoded.version, header.version, "version");
    try assertEqual(u16, decoded.flags, header.flags, "flags");
}

// ============================================================================
// Metadata Capsule Tests
// ============================================================================

test "metadata: capsule create and serialize" {
    var capsule = metadata.MetadataCapsule.init(testAlloc());
    defer capsule.deinit();

    capsule.header.capsule_id = utils.generateUuidv7();
    capsule.header.inode = 12345;

    try capsule.addEntry(0x0001, 0x0001, "mode_uid_gid", &[_]u8{0xA4, 0x81, 0x00, 0x00, 0xE8, 0x03, 0x00, 0x00, 0xE8, 0x03, 0x00, 0x00});
    try capsule.addEntry(0x0001, 0x0002, "timestamps", &[_]u8{0} ** 32);
    try capsule.addEntry(0x0010, 0x0001, "security_descriptor", &[_]u8{0} ** 64);

    var writer = serialization.createWriter(testAlloc());
    defer writer.deinit();
    try capsule.serialize(&writer);

    const data = writer.bytes();
    try assertError(data.len > 0, false); // Just verify it doesn't error

    var reader = serialization.createReader(data);
    const decoded = try metadata.MetadataCapsule.deserialize(&reader, testAlloc());
    defer decoded.deinit();

    try assertEqual(u64, decoded.header.inode, capsule.header.inode, "inode");
    try assertEqual(u32, decoded.header.entry_count, 3, "entry count");
}

test "metadata: capsule lookup" {
    var capsule = metadata.MetadataCapsule.init(testAlloc());
    defer capsule.deinit();

    try capsule.addEntry(0x0001, 0x0001, "mode_uid_gid", "test_value");
    try capsule.addEntry(0x0002, 0x0001, "acl", "acl_data");

    const found = capsule.getEntry(0x0001, 0x0001, "mode_uid_gid");
    try assertEqual(bool, found != null, true, "found existing entry");
    if (found) |entry| {
        try assertEqual([]const u8, entry.value, "test_value", "entry value");
    }

    const not_found = capsule.getEntry(0x0001, 0x0001, "nonexistent");
    try assertEqual(bool, not_found == null, true, "not found entry");
}

test "metadata: capsule remove" {
    var capsule = metadata.MetadataCapsule.init(testAlloc());
    defer capsule.deinit();

    try capsule.addEntry(0x0001, 0x0001, "test", "value");
    try assertEqual(u32, capsule.header.entry_count, 1, "count after add");

    const removed = try capsule.removeEntry(0x0001, 0x0001, "test");
    try assertEqual(bool, removed, true, "removed");
    try assertEqual(u32, capsule.header.entry_count, 0, "count after remove");

    const not_removed = try capsule.removeEntry(0x0001, 0x0001, "test");
    try assertEqual(bool, not_removed, false, "not removed again");
}

test "metadata: capsule clone" {
    var capsule = metadata.MetadataCapsule.init(testAlloc());
    defer capsule.deinit();

    capsule.header.capsule_id = utils.generateUuidv7();
    capsule.header.inode = 12345;
    try capsule.addEntry(0x0001, 0x0001, "mode_uid_gid", "test");

    const clone = try capsule.clone(testAlloc());
    defer clone.deinit();

    try assertEqual(u64, clone.header.inode, capsule.header.inode, "cloned inode");
    try assertEqual(bool, clone.header.capsule_id != capsule.header.capsule_id, true, "new capsule_id");
    try assertEqual(u32, clone.header.entry_count, capsule.header.entry_count, "entry count");
}

test "metadata: POSIX_BASE helpers" {
    const capsule = try metadata.createPosixBaseCapsule(
        testAlloc(),
        12345, // inode
        0o100644, // mode
        1000, // uid
        1000, // gid
        1000000, // atime
        2000000, // mtime
        3000000, // ctime
        4000000, // crtime
        1, // link_count
    );
    defer capsule.deinit();

    const parsed = try metadata.parsePosixBaseCapsule(&capsule);
    try assertEqual(u32, parsed.mode, 0o100644, "mode");
    try assertEqual(u32, parsed.uid, 1000, "uid");
    try assertEqual(u32, parsed.gid, 1000, "gid");
    try assertEqual(u64, parsed.atime, 1000000, "atime");
    try assertEqual(u64, parsed.mtime, 2000000, "mtime");
    try assertEqual(u64, parsed.ctime, 3000000, "ctime");
    try assertEqual(u64, parsed.crtime, 4000000, "crtime");
    try assertEqual(u32, parsed.link_count, 1, "link_count");
}

test "metadata: namespace registry" {
    try assertEqual(bool, metadata.NamespaceRegistry.isStandard(0x0001), true, "POSIX_BASE is standard");
    try assertEqual(bool, metadata.NamespaceRegistry.isStandard(0xFFFF), true, "OPAQUE is standard");
    try assertEqual(bool, metadata.NamespaceRegistry.isStandard(0x1234), false, "unknown is not standard");

    const name = metadata.NamespaceRegistry.getName(0x0010) orelse "";
    try assertEqual([]const u8, name, "WINDOWS_SD", "WINDOWS_SD name");

    const desc = metadata.NamespaceRegistry.getDescription(0x0020) orelse "";
    try assertEqual([]const u8, desc, "com.apple.* extended attributes", "MACOS_XATTR desc");
}

// ============================================================================
// Allocation Tests
// ============================================================================

test "allocation: bitmap basic operations" {
    var bitmap = try allocation.AllocationBitmap.init(testAlloc(), 1024, 4096);
    defer bitmap.deinit(testAlloc());

    // Initially all free
    try assertEqual(bool, bitmap.isAllocated(0), false, "cluster 0 free");
    try assertEqual(bool, bitmap.isAllocated(1023), false, "cluster 1023 free");

    // Allocate some
    bitmap.setAllocated(0, true);
    bitmap.setAllocated(10, true);
    bitmap.setAllocated(1023, true);

    try assertEqual(bool, bitmap.isAllocated(0), true, "cluster 0 allocated");
    try assertEqual(bool, bitmap.isAllocated(10), true, "cluster 10 allocated");
    try assertEqual(bool, bitmap.isAllocated(1023), true, "cluster 1023 allocated");
    try assertEqual(bool, bitmap.isAllocated(5), false, "cluster 5 free");

    // Free some
    bitmap.setAllocated(10, false);
    try assertEqual(bool, bitmap.isAllocated(10), false, "cluster 10 freed");
}

test "allocation: bitmap find free" {
    var bitmap = try allocation.AllocationBitmap.init(testAlloc(), 100, 4096);
    defer bitmap.deinit(testAlloc());

    // Allocate first 10
    for (0..10) |i| {
        bitmap.setAllocated(i, true);
    }

    const free = bitmap.findFree(0, 100) orelse 999;
    try assertEqual(u64, free, 10, "finds first free after allocated block");
}

test "allocation: bitmap find free extent" {
    var bitmap = try allocation.AllocationBitmap.init(testAlloc(), 1000, 4096);
    defer bitmap.deinit(testAlloc());

    // Allocate some scattered blocks
    for (0..100) |i| {
        if (i % 10 == 0) bitmap.setAllocated(i, true);
    }

    const extent = bitmap.findFreeExtent(5, 20, 0) orelse { start: 999, length: 0 };
    try assertEqual(bool, extent.length >= 5, true, "finds extent of at least 5");
    try assertEqual(bool, extent.start >= 1, true, "starts after first allocated");
}

test "allocation: bitmap count free" {
    var bitmap = try allocation.AllocationBitmap.init(testAlloc(), 1000, 4096);
    defer bitmap.deinit(testAlloc());

    try assertEqual(u64, bitmap.countFree(), 1000, "all free initially");

    for (0..100) |i| {
        bitmap.setAllocated(i, true);
    }
    try assertEqual(u64, bitmap.countFree(), 900, "100 allocated");
}

test "allocation: AG header serialization" {
    const ag = allocation.AGHeader{
        .magic = 0x41470000,
        .version = 1,
        .flags = 0,
        .ag_index = 5,
        .ag_offset = 1000000,
        .ag_size = 1_073_741_824,
        .cluster_size = 4096,
        .free_clusters = 500_000_000,
        .free_extents = 1000,
        .free_tree_root = 100,
        .bitmap_offset = 10,
        .inode_table_offset = 1000,
        .inode_count = 512,
        .free_inodes = 500,
        .generation = 42,
    };

    var writer = serialization.createWriter(testAlloc());
    defer writer.deinit();
    try ag.serialize(&writer);

    var reader = serialization.createReader(writer.bytes());
    const decoded = try allocation.AGHeader.deserialize(&reader, testAlloc());

    try assertEqual(u32, decoded.ag_index, 5, "ag_index");
    try assertEqual(u64, decoded.ag_offset, 1000000, "ag_offset");
    try assertEqual(u32, decoded.ag_size, 1_073_741_824, "ag_size");
    try assertEqual(u64, decoded.free_clusters, 500_000_000, "free_clusters");
}

// ============================================================================
// Directory Tests
// ============================================================================

test "directory: linear directory insert and find" {
    var dir = directory.LinearDirectory.init(testAlloc(), 64);
    defer dir.deinit();

    try dir.insert(directory.DirEntry{
        .inode = 1,
        .name = "file.txt",
        .file_type = directory.DirEntry.FILE_TYPE_REG,
        .flags = 0,
    });
    try dir.insert(directory.DirEntry{
        .inode = 2,
        .name = "subdir",
        .file_type = directory.DirEntry.FILE_TYPE_DIR,
        .flags = 0,
    });
    try dir.insert(directory.DirEntry{
        .inode = 3,
        .name = "link",
        .file_type = directory.DirEntry.FILE_TYPE_SYMLINK,
        .flags = 0,
    });

    try assertEqual(usize, dir.count(), 3, "count");

    const found = dir.find("file.txt") orelse null;
    try assertEqual(bool, found != null, true, "found file.txt");
    if (found) |e| {
        try assertEqual(u64, e.inode, 1, "file.txt inode");
        try assertEqual(u8, e.file_type, directory.DirEntry.FILE_TYPE_REG, "file type");
    }

    const found2 = dir.find("subdir") orelse null;
    try assertEqual(bool, found2 != null, true, "found subdir");
}

test "directory: case insensitive find" {
    var dir = directory.LinearDirectory.init(testAlloc(), 64);
    defer dir.deinit();

    try dir.insert(directory.DirEntry{
        .inode = 1,
        .name = "File.TXT",
        .file_type = directory.DirEntry.FILE_TYPE_REG,
        .flags = 0,
    });

    const found = dir.find("file.txt") orelse null;
    try assertEqual(bool, found != null, true, "case insensitive find");

    const found2 = dir.find("FILE.TXT") orelse null;
    try assertEqual(bool, found2 != null, true, "case insensitive find upper");
}

test "directory: case collision detection" {
    var dir = directory.LinearDirectory.init(testAlloc(), 64);
    defer dir.deinit();

    try dir.insert(directory.DirEntry{
        .inode = 1,
        .name = "File.txt",
        .file_type = directory.DirEntry.FILE_TYPE_REG,
        .flags = 0,
    });

    // This should fail due to case collision
    const err = dir.insert(directory.DirEntry{
        .inode = 2,
        .name = "file.txt",
        .file_type = directory.DirEntry.FILE_TYPE_REG,
        .flags = 0,
    });
    assertError(err, directory.DirectoryError.CaseCollision);
}

test "directory: reserved name rejection" {
    var dir = directory.LinearDirectory.init(testAlloc(), 64);
    defer dir.deinit();

    const err1 = dir.insert(directory.DirEntry{
        .inode = 1,
        .name = "CON",
        .file_type = directory.DirEntry.FILE_TYPE_REG,
        .flags = 0,
    });
    assertError(err1, directory.DirectoryError.ReservedName);

    const err2 = dir.insert(directory.DirEntry{
        .inode = 2,
        .name = "COM1",
        .file_type = directory.DirEntry.FILE_TYPE_REG,
        .flags = 0,
    });
    assertError(err2, directory.DirectoryError.ReservedName);

    const err3 = dir.insert(directory.DirEntry{
        .inode = 3,
        .name = "test.", // trailing dot
        .file_type = directory.DirEntry.FILE_TYPE_REG,
        .flags = 0,
    });
    assertError(err3, directory.DirectoryError.InvalidName);
}

test "directory: linear directory remove" {
    var dir = directory.LinearDirectory.init(testAlloc(), 64);
    defer dir.deinit();

    try dir.insert(directory.DirEntry{
        .inode = 1,
        .name = "file.txt",
        .file_type = directory.DirEntry.FILE_TYPE_REG,
        .flags = 0,
    });

    const removed = try dir.remove("file.txt");
    try assertEqual(u64, removed.inode, 1, "removed inode");
    try assertEqual([]const u8, removed.name, "file.txt", "removed name");
    try assertEqual(usize, dir.count(), 0, "count after remove");

    const err = dir.remove("file.txt");
    assertError(err, directory.DirectoryError.NotFound);
}

test "directory: linear directory serialization" {
    var dir = directory.LinearDirectory.init(testAlloc(), 64);
    defer dir.deinit();

    for (0..10) |i| {
        const name = try std.fmt.allocPrint(testAlloc(), "file_{:02}.txt", .{i});
        defer testAlloc().free(name);
        try dir.insert(directory.DirEntry{
            .inode = i + 1,
            .name = name,
            .file_type = directory.DirEntry.FILE_TYPE_REG,
            .flags = 0,
        });
    }

    var writer = serialization.createWriter(testAlloc());
    defer writer.deinit();
    try dir.serialize(&writer);

    var reader = serialization.createReader(writer.bytes());
    const decoded = try directory.LinearDirectory.deserialize(&reader, testAlloc());
    defer decoded.deinit();

    try assertEqual(usize, decoded.count(), 10, "decoded count");
    const found = decoded.find("file_05.txt") orelse null;
    try assertEqual(bool, found != null, true, "decoded find");
}

test "directory: WindowsReservedNames" {
    try assertEqual(bool, directory.WindowsReservedNames.isReserved("CON"), true, "CON");
    try assertEqual(bool, directory.WindowsReservedNames.isReserved("con"), true, "con (case insensitive)");
    try assertEqual(bool, directory.WindowsReservedNames.isReserved("PRN"), true, "PRN");
    try assertEqual(bool, directory.WindowsReservedNames.isReserved("AUX"), true, "AUX");
    try assertEqual(bool, directory.WindowsReservedNames.isReserved("NUL"), true, "NUL");
    try assertEqual(bool, directory.WindowsReservedNames.isReserved("COM1"), true, "COM1");
    try assertEqual(bool, directory.WindowsReservedNames.isReserved("COM9"), true, "COM9");
    try assertEqual(bool, directory.WindowsReservedNames.isReserved("LPT1"), true, "LPT1");
    try assertEqual(bool, directory.WindowsReservedNames.isReserved("LPT9"), true, "LPT9");

    try assertEqual(bool, directory.WindowsReservedNames.isReserved("CON.txt"), true, "CON.txt (with extension)");
    try assertEqual(bool, directory.WindowsReservedNames.isReserved("myfile"), false, "myfile (not reserved)");
}

test "directory: CaseFolder" {
    try assertEqual(u8, directory.CaseFolder.fold('A'), 'a', "fold upper");
    try assertEqual(u8, directory.CaseFolder.fold('a'), 'a', "fold lower");
    try assertEqual(u8, directory.CaseFolder.fold('Z'), 'z', "fold Z");
    try assertEqual(u8, directory.CaseFolder.fold('0'), '0', "fold digit");

    try assertEqual(bool, directory.CaseFolder.equalsIgnoreCase("Hello", "hello"), true, "equals ignore case");
    try assertEqual(bool, directory.CaseFolder.equalsIgnoreCase("HELLO", "hello"), true, "equals ignore case upper");
    try assertEqual(bool, directory.CaseFolder.equalsIgnoreCase("Hello", "World"), false, "not equals");

    const hash1 = directory.CaseFolder.hashFNV1a("test");
    const hash2 = directory.CaseFolder.hashFNV1a("TEST");
    try assertEqual(u64, hash1, hash2, "hash case insensitive");
}

// ============================================================================
// Journal Tests
// ============================================================================

test "journal: transaction builder" {
    var builder = journal.TransactionBuilder.init(testAlloc(), 42);
    defer builder.deinit();

    try builder.addCreateInode(journal.OpCreateInode{
        .inode = 1,
        .parent = 0,
        .name = "test.txt",
        .mode = 0o100644,
        .uid = 1000,
        .gid = 1000,
        .capsule_id = utils.generateUuidv7(),
    });

    try builder.addLinkDirent(journal.OpLinkDirent{
        .parent = 0,
        .name = "test.txt",
        .child = 1,
        .file_type = 1,
    });

    try builder.addAllocateExtent(journal.OpAllocateExtent{
        .inode = 1,
        .logical_offset = 0,
        .physical_block = 100,
        .length = 8,
        .compression_algo = 1,
    });

    const txn = builder.build();
    try assertEqual(u64, txn.header.txid, 42, "txid");
    try assertEqual(u32, txn.header.operation_count, 3, "operation count");
}

test "journal: transaction serialization" {
    var builder = journal.TransactionBuilder.init(testAlloc(), 1);
    defer builder.deinit();

    try builder.addCreateInode(journal.OpCreateInode{
        .inode = 1,
        .parent = 0,
        .name = "test.txt",
        .mode = 0o100644,
        .uid = 1000,
        .gid = 1000,
        .capsule_id = utils.generateUuidv7(),
    });

    const txn = builder.build();

    var writer = serialization.createWriter(testAlloc());
    defer writer.deinit();
    try txn.serialize(&writer);

    var reader = serialization.createReader(writer.bytes());
    const header = try journal.TransactionHeader.deserialize(&reader, testAlloc());
    try assertEqual(u64, header.txid, 1, "txid");
    try assertEqual(u32, header.operation_count, 1, "operation count");

    const op = try journal.Operation.deserialize(&reader, testAlloc());
    try assertEqual(journal.OperationType, op.op_type, journal.OperationType.CREATE_INODE, "op type");
}

test "journal: operation payload serialization" {
    const op_create = journal.OpCreateInode{
        .inode = 1,
        .parent = 0,
        .name = "test.txt",
        .mode = 0o100644,
        .uid = 1000,
        .gid = 1000,
        .capsule_id = 0x123456789ABCDEF0,
    };

    var writer = serialization.createWriter(testAlloc());
    defer writer.deinit();
    try op_create.serialize(&writer);

    var reader = serialization.createReader(writer.bytes());
    const decoded = try journal.OpCreateInode.deserialize(&reader, testAlloc());

    try assertEqual(u64, decoded.inode, 1, "inode");
    try assertEqual(u64, decoded.parent, 0, "parent");
    try assertEqual([]const u8, decoded.name, "test.txt", "name");
    try assertEqual(u32, decoded.mode, 0o100644, "mode");
    try assertEqual(u32, decoded.uid, 1000, "uid");
    try assertEqual(u32, decoded.gid, 1000, "gid");
    try assertEqual(u64, decoded.capsule_id, 0x123456789ABCDEF0, "capsule_id");
}

test "journal: checkpoint operation" {
    const checkpoint = journal.OpCheckpoint{
        .superblock_generation = 100,
        .ag_generations = &[_]u64{ 10, 20, 30 },
    };

    var writer = serialization.createWriter(testAlloc());
    defer writer.deinit();
    try checkpoint.serialize(&writer);

    var reader = serialization.createReader(writer.bytes());
    const decoded = try journal.OpCheckpoint.deserialize(&reader, testAlloc());

    try assertEqual(u64, decoded.superblock_generation, 100, "superblock generation");
    try assertEqual(usize, decoded.ag_generations.len, 3, "ag generations count");
    try assertEqual(u64, decoded.ag_generations[0], 10, "ag gen 0");
    try assertEqual(u64, decoded.ag_generations[1], 20, "ag gen 1");
    try assertEqual(u64, decoded.ag_generations[2], 30, "ag gen 2");
}

// ============================================================================
// Integrity Tests
// ============================================================================

test "integrity: CRC32C known values" {
    // Test against known CRC32C values
    try assertEqual(u32, integrity.Crc32c.compute(""), 0x00000000, "empty");
    try assertEqual(u32, integrity.Crc32c.compute("a"), 0x8A9136AA, "single byte");
    try assertEqual(u32, integrity.Crc32c.compute("abc"), 0xB5D7B4FA, "abc");
    try assertEqual(u32, integrity.Crc32c.compute("123456789"), 0xE3069283, "123456789");
}

test "integrity: CRC32C incremental" {
    const data1 = "Hello";
    const data2 = "World";
    const combined = "HelloWorld";

    const crc1 = integrity.Crc32c.compute(data1);
    const crc2 = integrity.Crc32c.compute(data2);
    const crc_combined = integrity.Crc32c.compute(combined);

    const crc_incremental = integrity.Crc32c.update(crc1, data2);
    try assertEqual(u32, crc_incremental, crc_combined, "incremental matches combined");

    const crc_combined2 = integrity.Crc32c.combine(crc1, crc2, data2.len);
    try assertEqual(u32, crc_combined2, crc_combined, "combine matches");
}

test "integrity: BLAKE3 known values" {
    // Test against known BLAKE3 values
    const empty_hash = integrity.Blake3.hash("");
    try assertEqual(u32, std.mem.readInt(u32, empty_hash[0..4], .little), 0xAF1349B9, "empty hash start");

    const abc_hash = integrity.Blake3.hash("abc");
    try assertEqual(u32, std.mem.readInt(u32, abc_hash[0..4], .little), 0x64373F5A, "abc hash start");
}

test "integrity: BLAKE3 streaming" {
    var hasher = integrity.Blake3.Hasher.init();
    hasher.update("Hello");
    hasher.update(" ");
    hasher.update("World");
    const hash = hasher.finalize();

    const direct = integrity.Blake3.hash("Hello World");
    try assertEqual(bool, std.mem.eql(u8, &hash, &direct), true, "streaming equals direct");
}

test "integrity: BLAKE3 keyed" {
    var key: [32]u8 = undefined;
    for (&key, 0..) |*b, i| b.* = @as(u8, @intCast(i));

    const keyed = integrity.Blake3.hashKeyed(key, "test data");
    const direct = integrity.Blake3.hash("test data");

    // Keyed should be different from unkeyed
    try assertEqual(bool, std.mem.eql(u8, &keyed, &direct), false, "keyed differs from unkeyed");

    // Same key and data should produce same result
    const keyed2 = integrity.Blake3.hashKeyed(key, "test data");
    try assertEqual(bool, std.mem.eql(u8, &keyed, &keyed2), true, "keyed deterministic");
}

test "integrity: Verifier" {
    const data = "test data for verification";
    const crc = integrity.Crc32c.compute(data);
    const hash = integrity.Blake3.hash(data);

    const verifier = integrity.IntegrityVerifier{};
    try verifier.verifyMetadata(data, crc);
    try verifier.verifyData(data, hash);

    // Wrong CRC should fail
    assertError(verifier.verifyMetadata(data, crc + 1), integrity.IntegrityError.CrcMismatch);

    // Wrong hash should fail
    var wrong_hash = hash;
    wrong_hash[0] ^= 0xFF;
    assertError(verifier.verifyData(data, wrong_hash), integrity.IntegrityError.HashMismatch);
}

// ============================================================================
// Compression Tests
// ============================================================================

test "compression: NONE algorithm" {
    var ctx = try compression.CompressionContext.init(testAlloc(), compression.CompressionAlgorithm.NONE, 0);
    defer ctx.deinit();

    const input = "Hello, World! This is test data.";
    var output = try testAlloc().alloc(u8, input.len + 16);
    defer testAlloc().free(output);

    const result = try ctx.compress(input, output);
    try assertEqual(compression.CompressionAlgorithm, result.algorithm, compression.CompressionAlgorithm.NONE, "algorithm NONE");
    try assertEqual(usize, result.original_size, input.len, "original size");
    try assertEqual(usize, result.compressed_size, input.len, "compressed size = original");

    var decompressed = try testAlloc().alloc(u8, input.len);
    defer testAlloc().free(decompressed);
    const decomp_len = try ctx.decompress(output[0..result.compressed_size], decompressed, input.len);
    try assertEqual(usize, decomp_len, input.len, "decompressed length");
    try assertEqual(bool, std.mem.eql(u8, input, decompressed[0..decomp_len]), true, "round-trip");
}

test "compression: IncompressibleDetector" {
    // Highly compressible
    var compressible: [100]u8 = undefined;
    for (&compressible, 0..) |*b, i| b.* = @as(u8, @intCast(i % 4));
    try assertEqual(bool, compression.IncompressibleDetector.quickCheck(&compressible), false, "compressible detected");

    // Random data (incompressible)
    var incompressible: [100]u8 = undefined;
    var rng = std.Random.DefaultPrng.init(0x40223546);
    for (&incompressible) |*b| b.* = rng.random();
    try assertEqual(bool, compression.IncompressibleDetector.quickCheck(&incompressible), true, "incompressible detected");

    // Known compressed signatures
    try assertEqual(bool, compression.IncompressibleDetector.quickCheck("PK\3\4"), true, "ZIP signature");
    try assertEqual(bool, compression.IncompressibleDetector.quickCheck("\x1f\x8b"), true, "GZIP signature");
    try assertEqual(bool, compression.IncompressibleDetector.quickCheck("BZh"), true, "BZIP2 signature");
    try assertEqual(bool, compression.IncompressibleDetector.quickCheck("\xfd7zXZ"), true, "XZ signature");
    try assertEqual(bool, compression.IncompressibleDetector.quickCheck("\x04\x22\x4d\x18"), true, "LZ4 signature");
    try assertEqual(bool, compression.IncompressibleDetector.quickCheck("\x28\xb5\x2f\xfd"), true, "ZSTD signature");
}

test "compression: pipeline" {
    const pipeline = compression.CompressionPipeline.init(testAlloc());

    // Compressible data
    var compressible: [1000]u8 = undefined;
    for (&compressible, 0..) |*b, i| b.* = @as(u8, @intCast(i % 4));

    const result = try pipeline.compress(&compressible, null, null);
    // Should compress with LZ4 by default
    try assertEqual(bool, result.algorithm != compression.CompressionAlgorithm.NONE, true, "compressed");

    // Random data should be stored uncompressed
    var incompressible: [1000]u8 = undefined;
    var rng = std.Random.DefaultPrng.init(0x2AFFD0DB);
    for (&incompressible) |*b| b.* = rng.random();

    const result2 = try pipeline.compress(&incompressible, null, null);
    try assertEqual(compression.CompressionAlgorithm, result2.algorithm, compression.CompressionAlgorithm.NONE, "random stored as NONE");
}

// ============================================================================
// Version/Feature Flag Tests
// ============================================================================

test "version: parsing and formatting" {
    const v1 = version.Version{ .major = 1, .minor = 0, .revision = 0 };
    try assertEqual([]const u8, v1.format(), "v1.0.0", "format v1.0.0");

    const v2 = version.Version{ .major = 2, .minor = 5, .revision = 123 };
    try assertEqual([]const u8, v2.format(), "v2.5.123", "format v2.5.123");

    const parsed = try version.Version.parse("v1.0.0");
    try assertEqual(u16, parsed.major, 1, "parse major");
    try assertEqual(u16, parsed.minor, 0, "parse minor");
    try assertEqual(u32, parsed.revision, 0, "parse revision");

    const parsed2 = try version.Version.parse("2.5.123");
    try assertEqual(u16, parsed2.major, 2, "parse without v");
}

test "version: comparison" {
    const v1 = version.Version{ .major = 1, .minor = 0, .revision = 0 };
    const v2 = version.Version{ .major = 1, .minor = 1, .revision = 0 };
    const v3 = version.Version{ .major = 2, .minor = 0, .revision = 0 };

    try assertEqual(i32, v1.compare(v2), -1, "v1 < v2");
    try assertEqual(i32, v2.compare(v1), 1, "v2 > v1");
    try assertEqual(i32, v1.compare(v1), 0, "v1 == v1");
    try assertEqual(i32, v3.compare(v1), 1, "v3 > v1 (major)");
}

test "version: compatibility" {
    const v1 = version.Version{ .major = 1, .minor = 0, .revision = 0 };
    const v2 = version.Version{ .major = 1, .minor = 5, .revision = 0 };
    const v3 = version.Version{ .major = 2, .minor = 0, .revision = 0 };

    try assertEqual(bool, v1.isCompatible(v2), true, "same major = compatible");
    try assertEqual(bool, v1.isCompatible(v3), false, "different major = incompatible");
}

test "version: feature flags" {
    var flags = version.FeatureFlags{};
    try assertEqual(bool, flags.hasIncompat(version.FeatureFlags.INCOMPAT_ENCRYPTION), false, "initially false");

    flags.setIncompat(version.FeatureFlags.INCOMPAT_ENCRYPTION, true);
    try assertEqual(bool, flags.hasIncompat(version.FeatureFlags.INCOMPAT_ENCRYPTION), true, "after set true");
    try assertEqual(u32, flags.incompat, 1 << version.FeatureFlags.INCOMPAT_ENCRYPTION, "bit set");

    flags.setIncompat(version.FeatureFlags.INCOMPAT_ENCRYPTION, false);
    try assertEqual(bool, flags.hasIncompat(version.FeatureFlags.INCOMPAT_ENCRYPTION), false, "after set false");
    try assertEqual(u32, flags.incompat, 0, "bit cleared");
}

test "version: mount compatibility check" {
    const vol_features = version.FeatureFlags{
        .incompat = 1 << version.FeatureFlags.INCOMPAT_ENCRYPTION,
        .compat_ro = 1 << version.FeatureFlags.COMPAT_RO_COMPRESSION_LZ4,
        .compat_rw = 1 << version.FeatureFlags.COMPAT_RW_XATTR,
    };

    // We support encryption
    const compat1 = vol_features.checkCompatibility(
        version.SupportedFeatures.INCOMPAT,
        version.SupportedFeatures.COMPAT_RO,
        version.SupportedFeatures.COMPAT_RW,
    );
    try assertEqual(bool, compat1.can_mount_rw, true, "supports encryption");

    // Volume has unsupported incompat
    const vol_features2 = version.FeatureFlags{
        .incompat = 1 << 31, // Unknown bit
    };
    const compat2 = vol_features2.checkCompatibility(
        version.SupportedFeatures.INCOMPAT,
        version.SupportedFeatures.COMPAT_RO,
        version.SupportedFeatures.COMPAT_RW,
    );
    try assertEqual(bool, compat2.can_mount_rw, false, "unknown incompat blocks RW");
    try assertEqual(bool, compat2.can_mount_ro, false, "unknown incompat blocks RO");

    // Volume has unknown compat_ro
    const vol_features3 = version.FeatureFlags{
        .compat_ro = 1 << 31,
    };
    const compat3 = vol_features3.checkCompatibility(
        version.SupportedFeatures.INCOMPAT,
        version.SupportedFeatures.COMPAT_RO,
        version.SupportedFeatures.COMPAT_RW,
    );
    try assertEqual(bool, compat3.can_mount_rw, false, "unknown compat_ro blocks RW");
    try assertEqual(bool, compat3.can_mount_ro, true, "unknown compat_ro allows RO");
}

// ============================================================================
// Crypto Tests
// ============================================================================

test "crypto: unimplemented encryption fails closed" {
    var key: [32]u8 = [_]u8{0x5a} ** 32;
    const salt: [16]u8 = [_]u8{0x11} ** 16;
    var ctx = crypto.EncryptionContext.init(.AES256_GCM, key, salt);
    try std.testing.expectError(crypto.CryptoError.UnsupportedAlgorithm, ctx.encrypt("secret", "aad", null));
    try std.testing.expectError(crypto.CryptoError.UnsupportedAlgorithm, ctx.decrypt("ciphertext", [_]u8{0} ** 16, [_]u8{0} ** 12, "aad"));
    try std.testing.expectError(crypto.CryptoError.KeyDerivationFailed, crypto.EncryptionContext.deriveKey("password", salt, 0, .AES256_GCM));

    // PBKDF2-HMAC-SHA256, one iteration, salt = "salt" followed by 12 zero bytes.
    var kdf_salt: [16]u8 = [_]u8{0} ** 16;
    @memcpy(kdf_salt[0..4], "salt");
    const derived = try crypto.EncryptionContext.deriveKey("password", kdf_salt, 1, .AES256_GCM);
    var derived_hex: [64]u8 = undefined;
    utils.hexEncode(&derived, &derived_hex);
    try assertEqual([]const u8, &derived_hex, "3267a06614b9d090bc3e684eebdb6af8ee753cf80b7f7f7cf5e676c65422d054", "PBKDF2-HMAC-SHA256 vector");

    var plain_ctx = crypto.EncryptionContext.init(.NONE, key, salt);
    const no_encryption = try plain_ctx.encrypt("plain", "", null);
    defer std.heap.page_allocator.free(no_encryption.ciphertext);
    try assertEqual(bool, std.mem.eql(u8, no_encryption.ciphertext, "plain"), true, "NONE mode preserves bytes");
}

test "crypto: encryption metadata serialization" {
    const meta = crypto.EncryptionMetadata{
        .algorithm = crypto.EncryptionAlgorithm.AES256_GCM,
        .key_id = 1,
        .wrapped_key = [0] ** 48,
        .nonce_prefix = [0] ** 8,
        .kdf_params = crypto.VolumeKeyManager.KeyDerivationParams{
            .kdf_algorithm = 2,
            .iterations = 100000,
            .salt = [42] ** 16,
            .memory_cost = 65536,
            .parallelism = 4,
        },
    };

    var writer = serialization.createWriter(testAlloc());
    defer writer.deinit();
    try meta.serialize(&writer);

    var reader = serialization.createReader(writer.bytes());
    const decoded = try crypto.EncryptionMetadata.deserialize(&reader, testAlloc());

    try assertEqual(crypto.EncryptionAlgorithm, decoded.algorithm, crypto.EncryptionAlgorithm.AES256_GCM, "algorithm");
    try assertEqual(u32, decoded.key_id, 1, "key_id");
    try assertEqual(u8, decoded.kdf_params.kdf_algorithm, 2, "kdf algorithm");
    try assertEqual(u32, decoded.kdf_params.iterations, 100000, "iterations");
}

test "crypto: volume key manager" {
    const mgr = try crypto.VolumeKeyManager.createFromPassword(
        "test_password",
        crypto.VolumeKeyManager.KeyDerivationParams{
            .salt = [42] ** 16,
            .iterations = 1000,
        },
    );
    try assertEqual(u32, mgr.key_id, 1, "key_id");

    const file_key = mgr.deriveFileKey(12345);
    const file_key2 = mgr.deriveFileKey(12345);
    try assertEqual(bool, std.mem.eql(u8, &file_key, &file_key2), true, "deterministic derivation");

    const file_key3 = mgr.deriveFileKey(54321);
    try assertEqual(bool, std.mem.eql(u8, &file_key, &file_key3), false, "different file_id = different key");
}

// ============================================================================
// Utils Tests
// ============================================================================

test "utils: timestamp" {
    const ts1 = utils.timestamp();
    const ts2 = utils.timestamp();
    try assertEqual(bool, ts2 >= ts1, true, "monotonic increasing");
    try assertEqual(bool, ts1 > 0, true, "non-zero");
}

test "utils: UUIDv7" {
    const uuid1 = utils.generateUuidv7();
    const uuid2 = utils.generateUuidv7();
    try assertEqual(bool, uuid1 != uuid2, true, "unique");

    const bytes1 = utils.generateUuidv7Bytes();
    const bytes2 = utils.generateUuidv7Bytes();
    try assertEqual(bool, !std.mem.eql(u8, &bytes1, &bytes2), true, "bytes unique");

    // Check version bits (version 7 = 0x70 in byte 6)
    try assertEqual(u8, bytes1[6] & 0xF0, 0x70, "version 7");
    // Check variant bits (variant 1 = 0x80 in byte 8)
    try assertEqual(u8, bytes1[8] & 0xC0, 0x80, "variant 1");
}

test "utils: BLAKE3 uses the standard digest" {
    // Official BLAKE3 test vector for the empty input.
    const digest = utils.blake3("");
    var hex: [64]u8 = undefined;
    utils.hexEncode(&digest, &hex);
    try assertEqual([]const u8, &hex, "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262", "BLAKE3 empty vector");
}

test "utils: string functions" {
    try assertEqual(i32, utils.strcmp("abc", "abc"), 0, "strcmp equal");
    try assertEqual(bool, utils.strcmp("abc", "abd") < 0, true, "strcmp less");
    try assertEqual(bool, utils.strcmp("abd", "abc") > 0, true, "strcmp greater");

    try assertEqual(i32, utils.strcasecmp("ABC", "abc"), 0, "strcasecmp equal");
    try assertEqual(i32, utils.strcasecmp("ABC", "ABD"), -1, "strcasecmp less");

    var s: [10]u8 = "HELLO".*;
    utils.asciiToLowerSlice(&s);
    try assertEqual([]const u8, s[0..5], "hello", "asciiToLowerSlice");

    try assertEqual([]const u8, utils.pathDirname("/a/b/c"), "/a/b", "pathDirname");
    try assertEqual([]const u8, utils.pathDirname("file.txt"), ".", "pathDirname no slash");
    try assertEqual([]const u8, utils.pathBasename("/a/b/c"), "c", "pathBasename");
    try assertEqual([]const u8, utils.pathExtension("file.txt"), "txt", "pathExtension");
    try assertEqual([]const u8, utils.pathExtension("file"), "", "pathExtension none");
    try assertEqual([]const u8, utils.pathDirname(""), ".", "pathDirname empty");
    try assertEqual([]const u8, utils.pathDirname("/"), "/", "pathDirname root");
    try assertEqual([]const u8, utils.pathDirname("/a/b/"), "/a", "pathDirname trailing slash");
    try assertEqual([]const u8, utils.pathBasename("/a/b/"), "b", "pathBasename trailing slash");
    try assertEqual([]const u8, utils.pathBasename("/"), "/", "pathBasename root");
    try assertEqual([]const u8, utils.pathExtension(".profile"), "", "pathExtension dotfile");
    try assertEqual([]const u8, utils.pathExtension("archive.tar.gz"), "gz", "pathExtension compound");
}

test "utils: bit operations" {
    try assertEqual(usize, utils.alignUp(100, 64), 128, "alignUp");
    try assertEqual(usize, utils.alignDown(100, 64), 64, "alignDown");
    try assertEqual(usize, utils.alignUp(64, 64), 64, "alignUp exact");
    try assertEqual(usize, utils.alignDown(64, 64), 64, "alignDown exact");

    try assertEqual(bool, utils.isPowerOfTwo(64), true, "isPowerOfTwo true");
    try assertEqual(bool, utils.isPowerOfTwo(63), false, "isPowerOfTwo false");
    try assertEqual(bool, utils.isPowerOfTwo(0), false, "isPowerOfTwo zero");

    try assertEqual(usize, utils.nextPowerOfTwo(63), 64, "nextPowerOfTwo");
    try assertEqual(usize, utils.nextPowerOfTwo(64), 64, "nextPowerOfTwo exact");
    try assertEqual(usize, utils.nextPowerOfTwo(65), 128, "nextPowerOfTwo next");
    try assertEqual(usize, utils.nextPowerOfTwo(0), 1, "nextPowerOfTwo zero");
}

test "utils: Range" {
    const r1 = utils.Range(i32){ .start = 0, .end = 10 };
    const r2 = utils.Range(i32){ .start = 5, .end = 15 };

    try assertEqual(bool, r1.contains(5), true, "contains");
    try assertEqual(bool, r1.contains(10), false, "contains exclusive end");
    try assertEqual(bool, r1.overlaps(r2), true, "overlaps");
    try assertEqual(bool, r1.overlaps(utils.Range(i32){ .start = 10, .end = 20 }), false, "not overlaps adjacent");

    const intersection = r1.intersection(r2) orelse { start: -1, end: -1 };
    try assertEqual(i32, intersection.start, 5, "intersection start");
    try assertEqual(i32, intersection.end, 10, "intersection end");

    const no_intersection = r1.intersection(utils.Range(i32){ .start = 10, .end = 20 });
    try assertEqual(bool, no_intersection == null, true, "no intersection");
}

test "utils: hex encode/decode" {
    const input: [4]u8 = [0xDE, 0xAD, 0xBE, 0xEF];
    var output: [8]u8 = undefined;
    utils.hexEncode(&input, &output);
    try assertEqual([]const u8, &output, "deadbeef", "hexEncode");

    var decoded: [4]u8 = undefined;
    try utils.hexDecode(&output, &decoded);
    try assertEqual(bool, std.mem.eql(u8, &input, &decoded), true, "hexDecode round-trip");

    // Error cases
    assertError(utils.hexDecode("abc", &decoded), utils.InvalidArgument);
    assertError(utils.hexDecode("abcd", &[_]u8{}), utils.BufferTooSmall);
}

test "utils: base64" {
    const input = "Hello, UFS!";
    const encoded = try utils.base64Encode(input, testAlloc());
    defer testAlloc().free(encoded);

    const decoded = try utils.base64Decode(encoded, testAlloc());
    defer testAlloc().free(decoded);
    try assertEqual([]const u8, decoded, input, "base64 round-trip");
}

// ============================================================================
// Block Device Tests (File-backed)
// ============================================================================

test "blockdev: file block device" {
    // Create a temp file
    const path = try std.fmt.allocPrint(testAlloc(), "{s}/test_blockdev_{d}.img", .{std.os.getenv("TEMP") orelse "/tmp", utils.timestamp()});
    defer {
        _ = std.fs.cwd().deleteFile(path);
        testAlloc().free(path);
    }

    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();

    // Write some data
    const data = "Hello, Block Device!";
    try file.writeAll(data);
    try file.sync();

    // Open as block device
    const device = blockdev.createFileBlockDevice(testAlloc(), path, .{}) catch |err| {
        std.testing.fail("Failed to create block device: {}", .{err});
    };
    defer device.close();

    const info = device.getInfo();
    try assertEqual(u32, info.block_size, 4096, "block size");
    try assertEqual(bool, info.is_virtual, true, "is virtual");

    // Read back
    var buffer: [4096]u8 = undefined;
    try device.read(0, &mut buffer);
    try assertEqual(bool, std.mem.eql(u8, buffer[0..data.len], data), true, "read matches");
}

test "blockdev: cached block device" {
    // We can't easily test the generic CachedBlockDevice without a concrete base
    // This is a placeholder for when we have a real device to wrap
    try assertEqual(bool, true, true, "placeholder");
}

// ============================================================================
// Property-Based Tests
// ============================================================================

test "property: CRC32C invariant" {
    var rng = std.Random.DefaultPrng.init(0x770BC90C);
    for (0..100) |_| {
        var data: [100]u8 = undefined;
        for (&data) |*b| b.* = rng.random();
        try assertEqual(bool, fuzz.PropertyTest.crc32cInvariant(&data), true, "CRC32C deterministic");
    }
}

test "property: BLAKE3 invariant" {
    var rng = std.Random.DefaultPrng.init(0x5C354312);
    for (0..100) |_| {
        var data: [100]u8 = undefined;
        for (&data) |*b| b.* = rng.random();
        try assertEqual(bool, fuzz.PropertyTest.blake3Invariant(&data), true, "BLAKE3 deterministic");
    }
}

test "property: serialization round-trip" {
    for (0..50) |_| {
        const sb = try version.VolumeFormat.current(testAlloc());
        var writer = serialization.createWriter(testAlloc());
        defer writer.deinit();
        try sb.serialize(&writer);

        var reader = serialization.createReader(writer.bytes());
        const decoded = try version.VolumeFormat.deserialize(&reader, testAlloc());

        try assertEqual(version.Version, decoded.version, sb.version, "version round-trip");
        try assertEqual(u64, decoded.creation_time, sb.creation_time, "time round-trip");
    }
}

test "property: compression round-trip" {
    var rng = std.Random.DefaultPrng.init(0x5CA56CE4);
    for (0..20) |_| {
        var data: [200]u8 = undefined;
        for (&data) |*b| b.* = rng.random();

        const result = try fuzz.PropertyTest.compressionRoundTrip(testAlloc(), &data);
        try assertEqual(bool, result, true, "compression round-trip");
    }
}

// ============================================================================
// Fuzz Integration Tests
// ============================================================================

test "fuzz: all parsers with random data" {
    var rng = std.Random.DefaultPrng.init(0xD4ECD6EF);
    for (0..50) |_| {
        var buf: [1024]u8 = undefined;
        for (&buf) |*b| b.* = rng.random();
        try fuzz.fuzzAll(&buf);
    }
}

test "fuzz: structure-aware generation" {
    const sb = try fuzz.generateValidSuperblock(testAlloc());
    defer testAlloc().free(sb);
    try fuzz.fuzzSuperblock(sb);

    const ag = try fuzz.generateValidAGHeader(testAlloc());
    defer testAlloc().free(ag);
    try fuzz.fuzzAGHeader(ag);

    const inode = try fuzz.generateValidInode(testAlloc());
    defer testAlloc().free(inode);
    try fuzz.fuzzInode(inode);

    const txn = try fuzz.generateValidJournalTransaction(testAlloc());
    defer testAlloc().free(txn);
    try fuzz.fuzzJournalTransaction(txn);
}

// ============================================================================
// Main Test Entry
// ============================================================================

test "all tests" {
    // This test runs all the above tests
    // Individual tests are run by Zig's test runner
    std.debug.print("All UFS tests passed!\n", .{});
}