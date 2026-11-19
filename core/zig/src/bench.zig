// UFS Benchmarks
// Performance benchmarks for core operations

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

pub const BenchError = error{
    OutOfMemory,
    IoError,
};

// ============================================================================
// Benchmark Configuration
// ============================================================================

pub const BenchConfig = struct {
    iterations: usize = 10000,
    warmup_iterations: usize = 1000,
    data_sizes: []usize = &[_]usize{ 64, 256, 1024, 4096, 16384, 65536, 262144, 1048576 },
    thread_counts: []usize = &[_]usize{ 1, 2, 4, 8 },
};

pub const BenchResult = struct {
    name: []const u8,
    iterations: usize,
    total_ns: u64,
    min_ns: u64,
    max_ns: u64,
    avg_ns: f64,
    throughput_mb_s: f64,
    ops_per_sec: f64,
};

// ============================================================================
// Benchmark Harness
// ============================================================================

pub fn runBenchmark(
    name: []const u8,
    config: BenchConfig,
    benchFn: fn(usize) !void,
) !BenchResult {
    var results = std.ArrayList(u64).init(std.testing.allocator);
    defer results.deinit();

    // Warmup
    for (0..config.warmup_iterations) |_| {
        _ = benchFn(0);
    }

    // Timed runs
    var total_ns: u64 = 0;
    var min_ns: u64 = u64.MAX;
    var max_ns: u64 = 0;

    for (0..config.iterations) |i| {
        const start = std.time.nanoTimestamp();
        try benchFn(i);
        const end = std.time.nanoTimestamp();
        const elapsed = end - start;

        try results.append(elapsed);
        total_ns += elapsed;
        if (elapsed < min_ns) min_ns = elapsed;
        if (elapsed > max_ns) max_ns = elapsed;
    }

    const avg_ns = @as(f64, @floatFromInt(total_ns)) / @as(f64, @floatFromInt(config.iterations));
    const ops_per_sec = 1_000_000_000.0 / avg_ns;

    return .{
        .name = name,
        .iterations = config.iterations,
        .total_ns = total_ns,
        .min_ns = min_ns,
        .max_ns = max_ns,
        .avg_ns = avg_ns,
        .throughput_mb_s = 0, // Set by caller if applicable
        .ops_per_sec = ops_per_sec,
    };
}

pub fn runBenchmarkWithSize(
    name: []const u8,
    size: usize,
    config: BenchConfig,
    benchFn: fn([]u8) !void,
) !BenchResult {
    var data = try std.testing.allocator.alloc(u8, size);
    defer std.testing.allocator.free(data);

    // Initialize with random data
    var rng = std.Random.DefaultPrng.init(0x3B635D3B);
    for (data) |*b| {
        b.* = rng.random();
    }

    var results = std.ArrayList(u64).init(std.testing.allocator);
    defer results.deinit();

    // Warmup
    for (0..config.warmup_iterations) |_| {
        _ = benchFn(data);
    }

    var total_ns: u64 = 0;
    var min_ns: u64 = u64.MAX;
    var max_ns: u64 = 0;

    for (0..config.iterations) |_| {
        const start = std.time.nanoTimestamp();
        try benchFn(data);
        const end = std.time.nanoTimestamp();
        const elapsed = end - start;

        try results.append(elapsed);
        total_ns += elapsed;
        if (elapsed < min_ns) min_ns = elapsed;
        if (elapsed > max_ns) max_ns = elapsed;
    }

    const avg_ns = @as(f64, @floatFromInt(total_ns)) / @as(f64, @floatFromInt(config.iterations));
    const ops_per_sec = 1_000_000_000.0 / avg_ns;
    const throughput_mb_s = (@as(f64, @floatFromInt(size)) / 1_048_576.0) * ops_per_sec;

    return .{
        .name = name,
        .iterations = config.iterations,
        .total_ns = total_ns,
        .min_ns = min_ns,
        .max_ns = max_ns,
        .avg_ns = avg_ns,
        .throughput_mb_s = throughput_mb_s,
        .ops_per_sec = ops_per_sec,
    };
}

pub fn printResult(result: BenchResult) void {
    std.debug.print("{s: <40} | {d:>10} iters | avg: {d:>10} ns | {d:>10.2f} ops/s", .{
        result.name, result.iterations, @as(u64, @intCast(result.avg_ns)), result.ops_per_sec,
    });
    if (result.throughput_mb_s > 0) {
        std.debug.print(" | {d:>8.2f} MB/s", .{result.throughput_mb_s});
    }
    std.debug.print("\n", .{});
}

pub fn printComparison(name: []const u8, results: []BenchResult) void {
    std.debug.print("\n=== {s} ===\n", .{name});
    std.debug.print("{s: <40} | {s:>12} | {s:>12} | {s:>12}\n", .{"Benchmark", "Avg (ns)", "Ops/sec", "MB/s"});
    std.debug.print("{s}\n", .{std.fmt.repeat("-", 80)});
    for (results) |r| {
        std.debug.print("{s: <40} | {d:>12} | {d:>12.2f} | {d:>12.2f}\n", .{
            r.name, @as(u64, @intCast(r.avg_ns)), r.ops_per_sec, r.throughput_mb_s,
        });
    }
}

// ============================================================================
// Serialization Benchmarks
// ============================================================================

pub fn benchSerializationWrite(config: BenchConfig) !void {
    var writer = serialization.createWriter(std.testing.allocator);
    defer writer.deinit();

    try runBenchmark("Serialization Write (primitives)", config, fn (_: usize) !void {
        writer.reset();
        try writer.writeU8(0xFF);
        try writer.writeU16(0xFFFF);
        try writer.writeU32(0xFFFFFFFF);
        try writer.writeU64(0xFFFFFFFFFFFFFFFF);
        try writer.writeU32(utils.crc32c(writer.bytes()));
    });
}

pub fn benchSerializationRead(config: BenchConfig) !void {
    var writer = serialization.createWriter(std.testing.allocator);
    defer writer.deinit();

    try writer.writeU8(0xFF);
    try writer.writeU16(0xFFFF);
    try writer.writeU32(0xFFFFFFFF);
    try writer.writeU64(0xFFFFFFFFFFFFFFFF);
    try writer.writeU32(utils.crc32c(writer.bytes()));
    const data = writer.bytes();

    try runBenchmark("Serialization Read (primitives)", config, fn (_: usize) !void {
        var reader = serialization.createReader(data);
        _ = reader.readU8();
        _ = reader.readU16();
        _ = reader.readU32();
        _ = reader.readU64();
        _ = reader.readU32();
    });
}

pub fn benchSerializationStruct(config: BenchConfig) !void {
    // Benchmark superblock serialization
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

    try runBenchmark("Serialization Write (Superblock)", config, fn (_: usize) !void {
        var writer = serialization.createWriter(std.testing.allocator);
        defer writer.deinit();
        try sb.serialize(&writer);
    });

    var writer = serialization.createWriter(std.testing.allocator);
    defer writer.deinit();
    try sb.serialize(&writer);
    const data = writer.bytes();

    try runBenchmark("Serialization Read (Superblock)", config, fn (_: usize) !void {
        var reader = serialization.createReader(data);
        _ = version.VolumeFormat.deserialize(&reader, std.testing.allocator);
    });
}

// ============================================================================
// Integrity Benchmarks
// ============================================================================

pub fn benchCRC32C(config: BenchConfig) !void {
    for (config.data_sizes) |size| {
        var data = try std.testing.allocator.alloc(u8, size);
        defer std.testing.allocator.free(data);
        var rng = std.Random.DefaultPrng.init(0xC753A0BB);
        for (data) |*b| b.* = rng.random();

        const result = try runBenchmarkWithSize("CRC32C", size, config, fn (buf: []u8) !void {
            _ = integrity.Crc32c.compute(buf);
        });
        printResult(result);
    }
}

pub fn benchBLAKE3(config: BenchConfig) !void {
    for (config.data_sizes) |size| {
        var data = try std.testing.allocator.alloc(u8, size);
        defer std.testing.allocator.free(data);
        var rng = std.Random.DefaultPrng.init(0x6CF8F5EA);
        for (data) |*b| b.* = rng.random();

        const result = try runBenchmarkWithSize("BLAKE3", size, config, fn (buf: []u8) !void {
            _ = integrity.Blake3.hash(buf);
        });
        printResult(result);
    }
}

pub fn benchIntegrityCombined(config: BenchConfig) !void {
    for (config.data_sizes) |size| {
        var data = try std.testing.allocator.alloc(u8, size);
        defer std.testing.allocator.free(data);
        var rng = std.Random.DefaultPrng.init(0x4FD316C6);
        for (data) |*b| b.* = rng.random();

        const result = try runBenchmarkWithSize("CRC32C+BLAKE3", size, config, fn (buf: []u8) !void {
            _ = integrity.Crc32c.compute(buf);
            _ = integrity.Blake3.hash(buf);
        });
        printResult(result);
    }
}

// ============================================================================
// Compression Benchmarks
// ============================================================================

pub fn benchCompression(config: BenchConfig) !void {
    const algorithms = [_]compression.CompressionAlgorithm{
        .LZ4, .ZSTD, .ZSTD_HIGH,
    };

    for (config.data_sizes) |size| {
        var data = try std.testing.allocator.alloc(u8, size);
        defer std.testing.allocator.free(data);
        var rng = std.Random.DefaultPrng.init(0xA9EFF13B);
        for (data) |*b| b.* = rng.random();

        for (algorithms) |algo| {
            const result = try runBenchmarkWithSize(
                "Compress: " ++ @tagName(algo),
                size,
                config,
                fn (buf: []u8) !void {
                    var ctx = try compression.CompressionContext.init(std.testing.allocator, algo, 3);
                    defer ctx.deinit();
                    var output = try std.testing.allocator.alloc(u8, buf.len + 16);
                    defer std.testing.allocator.free(output);
                    _ = ctx.compress(buf, output);
                },
            );
            printResult(result);
        }

        // Decompression benchmarks
        for (algorithms) |algo| {
            var ctx = try compression.CompressionContext.init(std.testing.allocator, algo, 3);
            defer ctx.deinit();
            var compressed = try std.testing.allocator.alloc(u8, size + 16);
            defer std.testing.allocator.free(compressed);
            const comp_result = try ctx.compress(data, compressed);

            const result = try runBenchmarkWithSize(
                "Decompress: " ++ @tagName(algo),
                size,
                config,
                fn (buf: []u8) !void {
                    var output = try std.testing.allocator.alloc(u8, buf.len);
                    defer std.testing.allocator.free(output);
                    _ = ctx.decompress(compressed[0..comp_result.compressed_size], output, buf.len);
                },
            );
            printResult(result);
        }
    }
}

pub fn benchIncompressibleDetection(config: BenchConfig) !void {
    for (config.data_sizes) |size| {
        // Compressible data
        var compressible = try std.testing.allocator.alloc(u8, size);
        defer std.testing.allocator.free(compressible);
        for (compressible, 0..) |*b, i| {
            b.* = @as(u8, @intCast(i % 4)); // Highly compressible
        }

        // Incompressible data
        var incompressible = try std.testing.allocator.alloc(u8, size);
        defer std.testing.allocator.free(incompressible);
        var rng = std.Random.DefaultPrng.init(0x40223546);
        for (incompressible) |*b| b.* = rng.random();

        const r1 = try runBenchmarkWithSize("IncompressibleDetect (compressible)", size, config, fn (buf: []u8) !void {
            _ = compression.IncompressibleDetector.quickCheck(buf);
        });
        printResult(r1);

        const r2 = try runBenchmarkWithSize("IncompressibleDetect (random)", size, config, fn (buf: []u8) !void {
            _ = compression.IncompressibleDetector.quickCheck(buf);
        });
        printResult(r2);
    }
}

// ============================================================================
// Metadata Capsule Benchmarks
// ============================================================================

pub fn benchCapsuleSerialization(config: BenchConfig) !void {
    const makeCapsule = fn() !metadata.MetadataCapsule {
        var capsule = metadata.MetadataCapsule.init(std.testing.allocator);
        capsule.header.capsule_id = utils.generateUuidv7();
        capsule.header.inode = 12345;

        // Add typical entries
        try capsule.addEntry(0x0001, 0x0001, "mode_uid_gid", &[_]u8{0xA4, 0x81, 0x00, 0x00, 0xE8, 0x03, 0x00, 0x00, 0xE8, 0x03, 0x00, 0x00});
        try capsule.addEntry(0x0001, 0x0002, "timestamps", &[_]u8{0} ** 32);
        try capsule.addEntry(0x0001, 0x0003, "link_count", &[_]u8{1, 0, 0, 0});
        try capsule.addEntry(0x0010, 0x0001, "security_descriptor", &[_]u8{0} ** 64);
        try capsule.addEntry(0x0020, 0x0001, "com.apple.FinderInfo", &[_]u8{0} ** 32);

        return capsule;
    };

    const capsule = try makeCapsule();
    defer capsule.deinit();

    try runBenchmark("Capsule Serialize", config, fn (_: usize) !void {
        var writer = serialization.createWriter(std.testing.allocator);
        defer writer.deinit();
        try capsule.serialize(&writer);
    });

    var writer = serialization.createWriter(std.testing.allocator);
    defer writer.deinit();
    try capsule.serialize(&writer);
    const data = writer.bytes();

    try runBenchmark("Capsule Deserialize", config, fn (_: usize) !void {
        var reader = serialization.createReader(data);
        _ = metadata.MetadataCapsule.deserialize(&reader, std.testing.allocator);
    });
}

pub fn benchCapsuleLookup(config: BenchConfig) !void {
    var capsule = metadata.MetadataCapsule.init(std.testing.allocator);
    capsule.header.capsule_id = utils.generateUuidv7();
    capsule.header.inode = 12345;

    // Add 50 entries
    for (0..50) |i| {
        const name = try std.fmt.allocPrint(std.testing.allocator, "entry_{}", .{i});
        defer std.testing.allocator.free(name);
        try capsule.addEntry(0xFFFF, 0x0001, name, &[_]u8{0} ** 32);
    }
    defer capsule.deinit();

    try runBenchmark("Capsule Lookup (50 entries)", config, fn (_: usize) !void {
        _ = capsule.getEntry(0xFFFF, 0x0001, "entry_25");
    });
}

// ============================================================================
// Allocation Bitmap Benchmarks
// ============================================================================

pub fn benchAllocationBitmap(config: BenchConfig) !void {
    for (config.data_sizes) |size| {
        if (size > 1_000_000) continue; // Skip huge sizes

        var bitmap = try allocation.AllocationBitmap.init(std.testing.allocator, size, 4096);
        defer bitmap.deinit(std.testing.allocator);

        // Set half as allocated
        for (0..size / 2) |i| {
            bitmap.setAllocated(i, true);
        }

        const r1 = try runBenchmarkWithSize("Bitmap FindFree", size, config, fn (_: []u8) !void {
            _ = bitmap.findFree(0, size);
        });
        printResult(r1);

        const r2 = try runBenchmarkWithSize("Bitmap FindFreeExtent", size, config, fn (_: []u8) !void {
            _ = bitmap.findFreeExtent(8, 128, 0);
        });
        printResult(r2);

        const r3 = try runBenchmarkWithSize("Bitmap CountFree", size, config, fn (_: []u8) !void {
            _ = bitmap.countFree();
        });
        printResult(r3);
    }
}

// ============================================================================
// Directory Benchmarks
// ============================================================================

pub fn benchLinearDirectory(config: BenchConfig) !void {
    for (config.data_sizes) |entry_count| {
        if (entry_count > 64) continue;

        var dir = directory.LinearDirectory.init(std.testing.allocator, 64);
        defer dir.deinit();

        // Pre-populate
        for (0..entry_count) |i| {
            const name = try std.fmt.allocPrint(std.testing.allocator, "file_{:04}", .{i});
            defer std.testing.allocator.free(name);
            try dir.insert(directory.DirEntry{
                .inode = i + 1,
                .name = name,
                .file_type = directory.DirEntry.FILE_TYPE_REG,
                .flags = 0,
            });
        }

        const r1 = try runBenchmark("LinearDir Find", config, fn (_: usize) !void {
            _ = dir.find("file_0030");
        });
        printResult(r1);

        const r2 = try runBenchmark("LinearDir Iterate", config, fn (_: usize) !void {
            var count = 0;
            try dir.iterate(fn (_: directory.DirEntry) !void { count += 1; });
        });
        printResult(r2);
    }
}

pub fn benchDirectorySerialization(config: BenchConfig) !void {
    var dir = directory.LinearDirectory.init(std.testing.allocator, 64);
    defer dir.deinit();

    for (0..64) |i| {
        const name = try std.fmt.allocPrint(std.testing.allocator, "file_{:04}", .{i});
        defer std.testing.allocator.free(name);
        try dir.insert(directory.DirEntry{
            .inode = i + 1,
            .name = name,
            .file_type = directory.DirEntry.FILE_TYPE_REG,
            .flags = 0,
        });
    }

    try runBenchmark("Directory Serialize (64 entries)", config, fn (_: usize) !void {
        var writer = serialization.createWriter(std.testing.allocator);
        defer writer.deinit();
        try dir.serialize(&writer);
    });

    var writer = serialization.createWriter(std.testing.allocator);
    defer writer.deinit();
    try dir.serialize(&writer);
    const data = writer.bytes();

    try runBenchmark("Directory Deserialize (64 entries)", config, fn (_: usize) !void {
        var reader = serialization.createReader(data);
        _ = directory.LinearDirectory.deserialize(&reader, std.testing.allocator);
    });
}

// ============================================================================
// Journal Benchmarks
// ============================================================================

pub fn benchTransactionBuilder(config: BenchConfig) !void {
    try runBenchmark("Transaction Build (5 ops)", config, fn (_: usize) !void {
        var builder = journal.TransactionBuilder.init(std.testing.allocator, 1);
        defer builder.deinit();

        try builder.addCreateInode(journal.OpCreateInode{
            .inode = 1, .parent = 0, .name = "test", .mode = 0o100644,
            .uid = 1000, .gid = 1000, .capsule_id = utils.generateUuidv7(),
        });
        try builder.addLinkDirent(journal.OpLinkDirent{
            .parent = 0, .name = "test", .child = 1, .file_type = 1,
        });
        try builder.addAllocateExtent(journal.OpAllocateExtent{
            .inode = 1, .logical_offset = 0, .physical_block = 100,
            .length = 8, .compression_algo = 1,
        });
        try builder.addUpdateInodeMeta(journal.OpUpdateInodeMeta{
            .inode = 1, .field_mask = 0xFF, .mode = 0o100644,
            .uid = 1000, .gid = 1000, .size = 4096,
            .atime = utils.timestamp(), .mtime = utils.timestamp(),
            .ctime = utils.timestamp(), .flags = 0, .capsule_id = utils.generateUuidv7(),
        });
        try builder.addCheckpoint(journal.OpCheckpoint{
            .superblock_generation = 1, .ag_generations = &[_]u64{1, 1, 1},
        });

        _ = builder.build();
    });
}

pub fn benchJournalSerialization(config: BenchConfig) !void {
    var builder = journal.TransactionBuilder.init(std.testing.allocator, 1);
    defer builder.deinit();

    for (0..10) |_| {
        try builder.addCreateInode(journal.OpCreateInode{
            .inode = utils.generateUuidv7(), .parent = 0, .name = "test", .mode = 0o100644,
            .uid = 1000, .gid = 1000, .capsule_id = utils.generateUuidv7(),
        });
    }

    const txn = builder.build();

    try runBenchmark("Transaction Serialize (10 ops)", config, fn (_: usize) !void {
        var writer = serialization.createWriter(std.testing.allocator);
        defer writer.deinit();
        try txn.serialize(&writer);
    });

    var writer = serialization.createWriter(std.testing.allocator);
    defer writer.deinit();
    try txn.serialize(&writer);
    const data = writer.bytes();

    try runBenchmark("Transaction Deserialize (10 ops)", config, fn (_: usize) !void {
        var reader = serialization.createReader(data);
        _ = journal.TransactionHeader.deserialize(&reader, std.testing.allocator);
        // Parse operations
        for (0..10) |_| {
            _ = reader.readU8();
            const len = try reader.readU32();
            try reader.skip(len);
        }
        _ = reader.readU32();
    });
}

// ============================================================================
// UUID/Timestamp Benchmarks
// ============================================================================

pub fn benchUtils(config: BenchConfig) !void {
    try runBenchmark("UUIDv7 Generate", config, fn (_: usize) !void {
        _ = utils.generateUuidv7();
    });

    try runBenchmark("Timestamp (ns)", config, fn (_: usize) !void {
        _ = utils.timestamp();
    });

    try runBenchmark("Hex Encode (32 bytes)", config, fn (_: usize) !void {
        var input: [32]u8 = undefined;
        var output: [64]u8 = undefined;
        utils.hexEncode(&input, &output);
    });
}

// ============================================================================
// Main Benchmark Runner
// ============================================================================

pub fn runAllBenchmarks() !void {
    const config = BenchConfig{
        .iterations = 10000,
        .warmup_iterations = 1000,
    };

    std.debug.print("\n{'=' ** 80}\n", .{});
    std.debug.print("UFS Core Benchmarks\n");
    std.debug.print("{'=' ** 80}\n\n", .{});

    // Serialization
    std.debug.print("--- Serialization ---\n");
    try benchSerializationWrite(config);
    try benchSerializationRead(config);
    try benchSerializationStruct(config);

    // Integrity
    std.debug.print("\n--- Integrity ---\n");
    try benchCRC32C(config);
    try benchBLAKE3(config);
    try benchIntegrityCombined(config);

    // Compression
    std.debug.print("\n--- Compression ---\n");
    try benchCompression(config);
    try benchIncompressibleDetection(config);

    // Metadata
    std.debug.print("\n--- Metadata Capsules ---\n");
    try benchCapsuleSerialization(config);
    try benchCapsuleLookup(config);

    // Allocation
    std.debug.print("\n--- Allocation Bitmap ---\n");
    try benchAllocationBitmap(config);

    // Directory
    std.debug.print("\n--- Directory ---\n");
    try benchLinearDirectory(config);
    try benchDirectorySerialization(config);

    // Journal
    std.debug.print("\n--- Journal ---\n");
    try benchTransactionBuilder(config);
    try benchJournalSerialization(config);

    // Utils
    std.debug.print("\n--- Utilities ---\n");
    try benchUtils(config);

    std.debug.print("\n{'=' ** 80}\n", .{});
    std.debug.print("Benchmarks Complete\n");
    std.debug.print("{'=' ** 80}\n", .{});
}

// ============================================================================
// Test Entry Point
// ============================================================================

test "benchmarks" {
    try runAllBenchmarks();
}

pub fn main() !void {
    try runAllBenchmarks();
}
