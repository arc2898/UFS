// UFS vs ext3 Performance Comparison Suite
// Real-time benchmark runner with ext3 baseline comparisons
// Run with: zig build perf-compare

const std = @import("std");
const ufs = @import("ufs");
const serialization = ufs.serialization;
const integrity = ufs.integrity;
const compression = ufs.compression;
const utils = ufs.utils;
const reliability_test = @import("../../src/reliability_test.zig");

const Allocator = std.mem.Allocator;
const print = std.debug.print;

const BenchError = error{
    OutOfMemory,
    IoError,
};

// ============================================================================
// ext3 Baseline Performance Targets (from published benchmarks)
// ============================================================================

const Ext3Baseline = struct {
    // Microbenchmarks (ops/sec)
    const crc32c_4k_ops: f64 = 50_000_000;      // ~200 MB/s software
    const blake3_4k_ops: f64 = 15_000_000;      // ~60 MB/s scalar
    const lz4_compress_4k_ops: f64 = 2_000_000;  // ~8 MB/s
    const lz4_decompress_4k_ops: f64 = 8_000_000; // ~32 MB/s
    const zstd_compress_4k_ops: f64 = 500_000;   // ~2 MB/s
    const zstd_decompress_4k_ops: f64 = 2_000_000; // ~8 MB/s

    // Filesystem operations (ops/sec on 4K clusters)
    const create_file_ops: f64 = 50_000;
    const deconste_file_ops: f64 = 60_000;
    const read_4k_ops: f64 = 200_000;
    const write_4k_ops: f64 = 150_000;
    const mkdir_ops: f64 = 40_000;
    const rmdir_ops: f64 = 45_000;
    const readdir_100_entries_ops: f64 = 10_000;
    const stat_ops: f64 = 300_000;
    const sync_ops: f64 = 5_000;

    // Large file throughput (MB/s)
    const sequential_read_mb_s: f64 = 350;
    const sequential_write_mb_s: f64 = 300;
    const random_read_4k_mb_s: f64 = 50;
    const random_write_4k_mb_s: f64 = 40;

    // Metadata operations
    const xattr_set_ops: f64 = 80_000;
    const xattr_get_ops: f64 = 100_000;

    // Compression ratio targets
    const lz4_text_ratio: f64 = 0.35;  // 65% reduction
    const zstd_text_ratio: f64 = 0.25; // 75% reduction
};

// ============================================================================
// Benchmark Configuration
// ============================================================================

const BenchConfig = struct {
    iterations: usize = 10000,
    warmup_iterations: usize = 1000,
    data_sizes: []usize = &[_]usize{ 64, 256, 1024, 4096, 16384, 65536, 262144, 1048576 },
    thread_counts: []usize = &[_]usize{ 1, 2, 4, 8 },
};

const BenchResult = struct {
    name: []const u8,
    iterations: usize,
    total_ns: u64,
    min_ns: u64,
    max_ns: u64,
    avg_ns: f64,
    throughput_mb_s: f64,
    ops_per_sec: f64,
    vs_ext3_ratio: f64,       // >1.0 means faster than ext3
    ext3_baseline_ops: f64,
};

const ComparisonResult = struct {
    benchmark: []const u8,
    ufs_ops: f64,
    ext3_ops: f64,
    ratio: f64,
    status: []const u8, // "WIN", "LOSE", "TIE"
};

// ============================================================================
// Benchmark Harness
// ============================================================================

fn runBenchmark(
    name: []const u8,
    config: BenchConfig,
    ext3_baseline: f64,
    benchFn: fn(usize) !void,
) !ComparisonResult {
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
    const ufs_ops = 1_000_000_000.0 / avg_ns;
    const ratio = ufs_ops / ext3_baseline;

    var status: []const u8;
    if (ratio >= 1.1) status = "WIN";
    else if (ratio <= 0.9) status = "LOSE";
    else status = "TIE";

    return .{
        .benchmark = name,
        .ufs_ops = ufs_ops,
        .ext3_ops = ext3_baseline,
        .ratio = ratio,
        .status = status,
    };
}

fn runBenchmarkWithSize(
    name: []const u8,
    size: usize,
    config: BenchConfig,
    ext3_baseline: f64,
    benchFn: fn([]u8) !void,
) !ComparisonResult {
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
    const ufs_ops = 1_000_000_000.0 / avg_ns;
    const ratio = ufs_ops / ext3_baseline;

    var status: []const u8;
    if (ratio >= 1.1) status = "WIN";
    else if (ratio <= 0.9) status = "LOSE";
    else status = "TIE";

    return .{
        .benchmark = name,
        .ufs_ops = ufs_ops,
        .ext3_ops = ext3_baseline,
        .ratio = ratio,
        .status = status,
    };
}

fn runBenchmarkThroughput(
    name: []const u8,
    size: usize,
    config: BenchConfig,
    ext3_mb_s: f64,
    benchFn: fn([]u8) !void,
) !ComparisonResult {
    var data = try std.testing.allocator.alloc(u8, size);
    defer std.testing.allocator.free(data);

    var rng = std.Random.DefaultPrng.init(0x3B635D3B);
    for (data) |*b| b.* = rng.random();

    var results = std.ArrayList(u64).init(std.testing.allocator);
    defer results.deinit();

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
    const ufs_mb_s = (@as(f64, @floatFromInt(size)) / 1_048_576.0) * (1_000_000_000.0 / avg_ns);
    const ratio = ufs_mb_s / ext3_mb_s;

    var status: []const u8;
    if (ratio >= 1.1) status = "WIN";
    else if (ratio <= 0.9) status = "LOSE";
    else status = "TIE";

    return .{
        .benchmark = name,
        .ufs_ops = ufs_mb_s,
        .ext3_ops = ext3_mb_s,
        .ratio = ratio,
        .status = status,
    };
}

fn printComparison(result: ComparisonResult) void {
    const status_color = switch (result.status) {
        "WIN" => "\x1b[32m",    // Green
        "LOSE" => "\x1b[31m",   // Red
        else => "\x1b[33m",     // Yellow
    };
    const reset = "\x1b[0m";

    print("{s: <45} | UFS: {d:>12.2f} | ext3: {d:>12.2f} | Ratio: {d:>6.2f}x | {s}{s:>4}{s}\n",
        .{result.benchmark, result.ufs_ops, result.ext3_ops, result.ratio, status_color, result.status, reset});
}

fn printSection(title: []const u8) void {
    print("\n\x1b[1m=== {s} ===\x1b[0m\n", .{title});
    print("{s: <45} | {s:>14} | {s:>14} | {s:>10} | {s:>4}\n", .{"Benchmark", "UFS (ops/s)", "ext3 (ops/s)", "Ratio", "✓"});
    print("{s}\n", .{std.fmt.repeat("-", 100)});
}

// ============================================================================
// Microbenchmarks
// ============================================================================

fn runMicrobenchmarks(config: BenchConfig) ![]ComparisonResult {
    var results = std.ArrayList(ComparisonResult).init(std.testing.allocator);
    defer results.deinit();

    printSection("Microbenchmarks: Core Primitives");

    // Serialization
    {
        var writer = serialization.createWriter(std.testing.allocator);
        defer writer.deinit();

        const r = try runBenchmark("Serialization Write (primitives)", config, 100_000_000, fn (_: usize) !void {
            writer.reset();
            try writer.writeU8(0xFF);
            try writer.writeU16(0xFFFF);
            try writer.writeU32(0xFFFFFFFF);
            try writer.writeU64(0xFFFFFFFFFFFFFFFF);
            try writer.writeU32(utils.crc32c(writer.bytes()));
        });
        try results.append(r);
        printComparison(r);
    }

    {
        var writer = serialization.createWriter(std.testing.allocator);
        defer writer.deinit();
        try writer.writeU8(0xFF);
        try writer.writeU16(0xFFFF);
        try writer.writeU32(0xFFFFFFFF);
        try writer.writeU64(0xFFFFFFFFFFFFFFFF);
        try writer.writeU32(utils.crc32c(writer.bytes()));
        const data = writer.bytes();

        const r = try runBenchmark("Serialization Read (primitives)", config, 150_000_000, fn (_: usize) !void {
            var reader = serialization.createReader(data);
            _ = reader.readU8();
            _ = reader.readU16();
            _ = reader.readU32();
            _ = reader.readU64();
            _ = reader.readU32();
        });
        try results.append(r);
        printComparison(r);
    }

    // CRC32C
    for (config.data_sizes) |size| {
        if (size != 4096) continue;
        var data = try std.testing.allocator.alloc(u8, size);
        defer std.testing.allocator.free(data);
        var rng = std.Random.DefaultPrng.init(0xC753A0BB);
        for (data) |*b| b.* = rng.random();

        const r = try runBenchmarkWithSize("CRC32C (4K)", size, config, Ext3Baseline.crc32c_4k_ops, fn (buf: []u8) !void {
            _ = integrity.Crc32c.compute(buf);
        });
        try results.append(r);
        printComparison(r);
    }

    // BLAKE3
    for (config.data_sizes) |size| {
        if (size != 4096) continue;
        var data = try std.testing.allocator.alloc(u8, size);
        defer std.testing.allocator.free(data);
        var rng = std.Random.DefaultPrng.init(0x6CF8F5EA);
        for (data) |*b| b.* = rng.random();

        const r = try runBenchmarkWithSize("BLAKE3 (4K)", size, config, Ext3Baseline.blake3_4k_ops, fn (buf: []u8) !void {
            _ = integrity.Blake3.hash(buf);
        });
        try results.append(r);
        printComparison(r);
    }

    // Compression
    for (config.data_sizes) |size| {
        if (size != 4096) continue;
        var data = try std.testing.allocator.alloc(u8, size);
        defer std.testing.allocator.free(data);
        var rng = std.Random.DefaultPrng.init(0xA9EFF13B);
        for (data) |*b| b.* = rng.random();

        // LZ4 Compress
        {
            const r = try runBenchmarkWithSize("LZ4 Compress (4K)", size, config, Ext3Baseline.lz4_compress_4k_ops, fn (buf: []u8) !void {
                var ctx = try compression.CompressionContext.init(std.testing.allocator, compression.CompressionAlgorithm.LZ4, 3);
                defer ctx.deinit();
                var output = try std.testing.allocator.alloc(u8, buf.len + 16);
                defer std.testing.allocator.free(output);
                _ = ctx.compress(buf, output);
            });
            try results.append(r);
            printComparison(r);
        }

        // LZ4 Decompress
        {
            var ctx = try compression.CompressionContext.init(std.testing.allocator, compression.CompressionAlgorithm.LZ4, 3);
            defer ctx.deinit();
            var compressed = try std.testing.allocator.alloc(u8, size + 16);
            defer std.testing.allocator.free(compressed);
            const comp_result = try ctx.compress(data, compressed);

            const r = try runBenchmarkWithSize("LZ4 Decompress (4K)", size, config, Ext3Baseline.lz4_decompress_4k_ops, fn (buf: []u8) !void {
                var output = try std.testing.allocator.alloc(u8, buf.len);
                defer std.testing.allocator.free(output);
                _ = ctx.decompress(compressed[0..comp_result.compressed_size], output, buf.len);
            });
            try results.append(r);
            printComparison(r);
        }

        // ZSTD Compress
        {
            const r = try runBenchmarkWithSize("ZSTD Compress (4K)", size, config, Ext3Baseline.zstd_compress_4k_ops, fn (buf: []u8) !void {
                var ctx = try compression.CompressionContext.init(std.testing.allocator, compression.CompressionAlgorithm.ZSTD, 3);
                defer ctx.deinit();
                var output = try std.testing.allocator.alloc(u8, buf.len + 16);
                defer std.testing.allocator.free(output);
                _ = ctx.compress(buf, output);
            });
            try results.append(r);
            printComparison(r);
        }

        // ZSTD Decompress
        {
            var ctx = try compression.CompressionContext.init(std.testing.allocator, compression.CompressionAlgorithm.ZSTD, 3);
            defer ctx.deinit();
            var compressed = try std.testing.allocator.alloc(u8, size + 16);
            defer std.testing.allocator.free(compressed);
            const comp_result = try ctx.compress(data, compressed);

            const r = try runBenchmarkWithSize("ZSTD Decompress (4K)", size, config, Ext3Baseline.zstd_decompress_4k_ops, fn (buf: []u8) !void {
                var output = try std.testing.allocator.alloc(u8, buf.len);
                defer std.testing.allocator.free(output);
                _ = ctx.decompress(compressed[0..comp_result.compressed_size], output, buf.len);
            });
            try results.append(r);
            printComparison(r);
        }
    }

    // UUID/Timestamp
    {
        const r = try runBenchmark("UUIDv7 Generate", config, 5_000_000, fn (_: usize) !void {
            _ = utils.generateUuidv7();
        });
        try results.append(r);
        printComparison(r);
    }

    {
        const r = try runBenchmark("Timestamp (ns)", config, 100_000_000, fn (_: usize) !void {
            _ = utils.timestamp();
        });
        try results.append(r);
        printComparison(r);
    }

    return results.toOwnedSlice();
}

// ============================================================================
// Filesystem Operation Benchmarks (using CrashSimulator as block device)
// ============================================================================

fn runFilesystemBenchmarks(config: BenchConfig) ![]ComparisonResult {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var results = std.ArrayList(ComparisonResult).init(std.testing.allocator);
    defer results.deinit();

    printSection("Filesystem Operations: UFS vs ext3");

    // Create test filesystem
    var sim = try reliability_test.CrashSimulator.init(allocator, 500 * 1024 * 1024, 4096);
    defer sim.deinit();

    const block_dev = reliability_test.createBlockDeviceFromSimulator(&sim);
    try ufs.format(block_dev, "PerfTest", 4096, ufs.CompressionAlgorithm.LZ4, 4096, 8);

    const fs = try ufs.mount(block_dev, ufs.MountOptions{});
    defer fs.unmount();

    var rng = std.Random.DefaultPrng.init(0x46EC2698);

    // Create file
    {
        const r = try runBenchmark("Create File (4K)", config, Ext3Baseline.create_file_ops, fn (_: usize) !void {
            const file = try fs.open(2, try std.fmt.allocPrint(allocator, "bench_create_{d}.dat", .{rng.random()}), ufs.O_CREAT | ufs.O_RDWR, 0644);
            file.close() catch {};
        });
        try results.append(r);
        printComparison(r);
    }

    // Pre-create files for read/write benchmarks
    const test_files = 1000;
    for (0..test_files) |i| {
        const file = try fs.open(2, try std.fmt.allocPrint(allocator, "rw_test_{d}.dat", .{i}), ufs.O_CREAT | ufs.O_RDWR, 0644);
        var data: [4096]u8 = undefined;
        for (&data) |*b| b.* = rng.random();
        try file.writeAll(&data);
        file.close() catch {};
    }

    // Read 4K
    {
        const r = try runBenchmark("Read 4K File", config, Ext3Baseline.read_4k_ops, fn (_: usize) !void {
            const idx = rng.random().intRangeAtMost(u32, 0, test_files - 1);
            const file = try fs.open(2, try std.fmt.allocPrint(allocator, "rw_test_{d}.dat", .{idx}), ufs.O_RDONLY, 0);
            var buf: [4096]u8 = undefined;
            _ = file.read(&buf) catch {};
            file.close() catch {};
        });
        try results.append(r);
        printComparison(r);
    }

    // Write 4K
    {
        const r = try runBenchmark("Write 4K File", config, Ext3Baseline.write_4k_ops, fn (_: usize) !void {
            const idx = rng.random().intRangeAtMost(u32, 0, test_files - 1);
            const file = try fs.open(2, try std.fmt.allocPrint(allocator, "rw_test_{d}.dat", .{idx}), ufs.O_RDWR, 0);
            var data: [4096]u8 = undefined;
            for (&data) |*b| b.* = rng.random();
            _ = file.writeAll(&data) catch {};
            file.close() catch {};
        });
        try results.append(r);
        printComparison(r);
    }

    // Mkdir
    {
        const r = try runBenchmark("Create Directory", config, Ext3Baseline.mkdir_ops, fn (_: usize) !void {
            fs.mkdir(2, try std.fmt.allocPrint(allocator, "bench_dir_{d}", .{rng.random()}), 0755) catch {};
        });
        try results.append(r);
        printComparison(r);
    }

    // Rmdir
    {
        // Pre-create dirs
        for (0..100) |i| {
            fs.mkdir(2, try std.fmt.allocPrint(allocator, "rmdir_test_{d}", .{i}), 0755) catch {};
        }

        const r = try runBenchmark("Remove Directory", config, Ext3Baseline.rmdir_ops, fn (_: usize) !void {
            fs.rmdir(2, try std.fmt.allocPrint(allocator, "rmdir_test_{d}", .{rng.random().intRangeAtMost(u32, 0, 99)})) catch {};
        });
        try results.append(r);
        printComparison(r);
    }

    // Readdir
    {
        const r = try runBenchmark("Readdir (100 entries)", config, Ext3Baseline.readdir_100_entries_ops, fn (_: usize) !void {
            var count = 0;
            _ = fs.iterateDir(2, {}, fn (_: ufs.DirEntry) !void { count += 1; }) catch {};
        });
        try results.append(r);
        printComparison(r);
    }

    // Stat
    {
        const r = try runBenchmark("Stat File", config, Ext3Baseline.stat_ops, fn (_: usize) !void {
            const idx = rng.random().intRangeAtMost(u32, 0, test_files - 1);
            var info = ufs.InodeInfo{};
            _ = fs.getattr(2, try std.fmt.allocPrint(allocator, "rw_test_{d}.dat", .{idx}), &info) catch {};
        });
        try results.append(r);
        printComparison(r);
    }

    // Sync
    {
        const r = try runBenchmark("Sync Filesystem", config, Ext3Baseline.sync_ops, fn (_: usize) !void {
            _ = fs.sync();
        });
        try results.append(r);
        printComparison(r);
    }

    // Extended attributes
    {
        const r = try runBenchmark("Set Xattr", config, Ext3Baseline.xattr_set_ops, fn (_: usize) !void {
            const idx = rng.random().intRangeAtMost(u32, 0, test_files - 1);
            _ = fs.setxattr(2, try std.fmt.allocPrint(allocator, "rw_test_{d}.dat", .{idx}), ufs.NAMESPACE_POSIX_XATTR, 0, "user.bench", "value", 5, 0) catch {};
        });
        try results.append(r);
        printComparison(r);
    }

    {
        const r = try runBenchmark("Get Xattr", config, Ext3Baseline.xattr_get_ops, fn (_: usize) !void {
            const idx = rng.random().intRangeAtMost(u32, 0, test_files - 1);
            var buf: [100]u8 = undefined;
            var out_size: usize = 0;
            _ = fs.getxattr(2, try std.fmt.allocPrint(allocator, "rw_test_{d}.dat", .{idx}), ufs.NAMESPACE_POSIX_XATTR, 0, "user.bench", &buf, buf.len, &out_size) catch {};
        });
        try results.append(r);
        printComparison(r);
    }

    return results.toOwnedSlice();
}

// ============================================================================
// Large File Throughput Benchmarks
// ============================================================================

fn runThroughputBenchmarks(config: BenchConfig) ![]ComparisonResult {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var results = std.ArrayList(ComparisonResult).init(std.testing.allocator);
    defer results.deinit();

    printSection("Large File Throughput (MB/s)");

    var sim = try reliability_test.CrashSimulator.init(allocator, 1024 * 1024 * 1024, 4096); // 1GB
    defer sim.deinit();

    const block_dev = reliability_test.createBlockDeviceFromSimulator(&sim);
    try ufs.format(block_dev, "ThroughputTest", 4096, ufs.CompressionAlgorithm.LZ4, 8192, 16);

    const fs = try ufs.mount(block_dev, ufs.MountOptions{});
    defer fs.unmount();

    var rng = std.Random.DefaultPrng.init(0xC08C29ED);

    // Sequential write - 100MB file
    {
        const file_size = 100 * 1024 * 1024;
        const file = try fs.open(2, "seq_write.dat", ufs.O_CREAT | ufs.O_RDWR, 0644);
        defer file.close() catch {};

        const r = try runBenchmarkThroughput("Sequential Write (100MB)", file_size, config, Ext3Baseline.sequential_write_mb_s, fn (_: []u8) !void {
            var chunk: [1024 * 1024]u8 = undefined;
            for (&chunk) |*b| b.* = rng.random();
            var written: u64 = 0;
            while (written < file_size) {
                const to_write = @min(chunk.len, @intCast(file_size - written));
                try file.writeAll(chunk[0..to_write]);
                written += to_write;
            }
        });
        try results.append(r);
        printComparison(r);
    }

    // Sequential read
    {
        const file_size = 100 * 1024 * 1024;
        const file = try fs.open(2, "seq_write.dat", ufs.O_RDONLY, 0);
        defer file.close() catch {};

        const r = try runBenchmarkThroughput("Sequential Read (100MB)", file_size, config, Ext3Baseline.sequential_read_mb_s, fn (_: []u8) !void {
            var chunk: [1024 * 1024]u8 = undefined;
            var read_total: u64 = 0;
            while (read_total < file_size) {
                const to_read = @min(chunk.len, @intCast(file_size - read_total));
                const n = try file.read(chunk[0..to_read]);
                if (n == 0) break;
                read_total += n;
            }
        });
        try results.append(r);
        printComparison(r);
    }

    // Random 4K read (create test file first)
    {
        const test_file = "random_4k.dat";
        const file_size = 50 * 1024 * 1024; // 50MB
        {
            const file = try fs.open(2, test_file, ufs.O_CREAT | ufs.O_RDWR, 0644);
            defer file.close() catch {};
            var chunk: [1024 * 1024]u8 = undefined;
            for (&chunk) |*b| b.* = rng.random();
            var written: u64 = 0;
            while (written < file_size) {
                const to_write = @min(chunk.len, @intCast(file_size - written));
                try file.writeAll(chunk[0..to_write]);
                written += to_write;
            }
        }

        const r = try runBenchmarkThroughput("Random 4K Read (50MB)", 4096 * 1000, config, Ext3Baseline.random_read_4k_mb_s, fn (_: []u8) !void {
            const file = try fs.open(2, test_file, ufs.O_RDONLY, 0);
            defer file.close() catch {};
            var buf: [4096]u8 = undefined;
            for (0..1000) |_| {
                const offset = rng.random().intRangeAtMost(u64, 0, file_size - 4096);
                try file.seek(@intCast(offset), ufs.SEEK_SET);
                _ = file.read(&buf) catch {};
            }
        });
        try results.append(r);
        printComparison(r);
    }

    // Random 4K write
    {
        const test_file = "random_4k_write.dat";
        const file_size = 50 * 1024 * 1024;
        {
            const file = try fs.open(2, test_file, ufs.O_CREAT | ufs.O_RDWR, 0644);
            defer file.close() catch {};
            var chunk: [1024 * 1024]u8 = undefined;
            for (&chunk) |*b| b.* = rng.random();
            var written: u64 = 0;
            while (written < file_size) {
                const to_write = @min(chunk.len, @intCast(file_size - written));
                try file.writeAll(chunk[0..to_write]);
                written += to_write;
            }
        }

        const r = try runBenchmarkThroughput("Random 4K Write (50MB)", 4096 * 1000, config, Ext3Baseline.random_write_4k_mb_s, fn (_: []u8) !void {
            const file = try fs.open(2, test_file, ufs.O_RDWR, 0);
            defer file.close() catch {};
            var buf: [4096]u8 = undefined;
            for (&buf) |*b| b.* = rng.random();
            for (0..1000) |_| {
                const offset = rng.random().intRangeAtMost(u64, 0, file_size - 4096);
                try file.seek(@intCast(offset), ufs.SEEK_SET);
                _ = file.writeAll(&buf) catch {};
            }
        });
        try results.append(r);
        printComparison(r);
    }

    return results.toOwnedSlice();
}

// ============================================================================
// Compression Ratio Benchmarks
// ============================================================================

fn runCompressionRatioBenchmarks() ![]ComparisonResult {
    var results = std.ArrayList(ComparisonResult).init(std.testing.allocator);
    defer results.deinit();

    printSection("Compression Ratios (lower is better)");

    // Text data (highly compressible)
    var text_data = try std.testing.allocator.alloc(u8, 100 * 1024);
    defer std.testing.allocator.free(text_data);
    const lorem = "Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. ";
    for (text_data, 0..) |*b, i| {
        b.* = lorem[i % lorem.len];
    }

    // LZ4
    {
        var ctx = try compression.CompressionContext.init(std.testing.allocator, compression.CompressionAlgorithm.LZ4, 3);
        defer ctx.deinit();
        var output = try std.testing.allocator.alloc(u8, text_data.len + 16);
        defer std.testing.allocator.free(output);
        const comp = try ctx.compress(text_data, output);
        const ratio = @as(f64, @floatFromInt(comp.compressed_size)) / @as(f64, @floatFromInt(text_data.len));
        const r = ComparisonResult{
            .benchmark = "LZ4 Text Ratio",
            .ufs_ops = ratio,
            .ext3_ops = Ext3Baseline.lz4_text_ratio,
            .ratio = Ext3Baseline.lz4_text_ratio / ratio, // inverse: UFS wins if smaller ratio
            .status = if (ratio < Ext3Baseline.lz4_text_ratio * 0.9) "WIN" else if (ratio > Ext3Baseline.lz4_text_ratio * 1.1) "LOSE" else "TIE",
        };
        try results.append(r);
        printComparison(r);
    }

    // ZSTD
    {
        var ctx = try compression.CompressionContext.init(std.testing.allocator, compression.CompressionAlgorithm.ZSTD, 3);
        defer ctx.deinit();
        var output = try std.testing.allocator.alloc(u8, text_data.len + 16);
        defer std.testing.allocator.free(output);
        const comp = try ctx.compress(text_data, output);
        const ratio = @as(f64, @floatFromInt(comp.compressed_size)) / @as(f64, @floatFromInt(text_data.len));
        const r = ComparisonResult{
            .benchmark = "ZSTD Text Ratio",
            .ufs_ops = ratio,
            .ext3_ops = Ext3Baseline.zstd_text_ratio,
            .ratio = Ext3Baseline.zstd_text_ratio / ratio,
            .status = if (ratio < Ext3Baseline.zstd_text_ratio * 0.9) "WIN" else if (ratio > Ext3Baseline.zstd_text_ratio * 1.1) "LOSE" else "TIE",
        };
        try results.append(r);
        printComparison(r);
    }

    return results.toOwnedSlice();
}

// ============================================================================
// Crash Recovery Benchmark
// ============================================================================

fn runCrashRecoveryBenchmark(config: BenchConfig) ![]ComparisonResult {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var results = std.ArrayList(ComparisonResult).init(std.testing.allocator);
    defer results.deinit();

    printSection("Crash Recovery Performance");

    // Simulate recovery time
    var sim = try reliability_test.CrashSimulator.init(allocator, 100 * 1024 * 1024, 4096);
    defer sim.deinit();

    const block_dev = reliability_test.createBlockDeviceFromSimulator(&sim);
    try ufs.format(block_dev, "RecoveryTest", 4096, ufs.CompressionAlgorithm.LZ4, 1024, 4);

    // Write some data
    {
        const fs = try ufs.mount(block_dev, ufs.MountOptions{});
        defer fs.unmount();
        for (0..100) |i| {
            const file = try fs.open(2, try std.fmt.allocPrint(allocator, "file_{d}.dat", .{i}), ufs.O_CREAT | ufs.O_RDWR, 0644);
            var data: [4096]u8 = undefined;
            for (&data) |*b| b.* = @as(u8, @intCast(i % 256));
            try file.writeAll(&data);
            file.close() catch {};
        }
        try fs.sync();
    }

    // Simulate crash
    sim.enableCrashSimulation(true);
    sim.setCrashPoint(10);

    {
        const fs = try ufs.mount(block_dev, ufs.MountOptions{});
        defer fs.unmount();
        for (100..200) |i| {
            const file = fs.open(2, try std.fmt.allocPrint(allocator, "file_{d}.dat", .{i}), ufs.O_CREAT | ufs.O_RDWR, 0644) catch continue;
            var data: [4096]u8 = undefined;
            for (&data) |*b| b.* = @as(u8, @intCast(i % 256));
            file.writeAll(&data) catch {};
            file.close() catch {};
        }
    }

    sim.enableCrashSimulation(false);

    // Measure recovery time (mount with replay)
    const config2 = BenchConfig{ .iterations = 10, .warmup_iterations = 0 };
    {
        const r = try runBenchmark("Journal Recovery Mount", config2, 1000.0, fn (_: usize) !void {
            const fs = try ufs.mount(block_dev, ufs.MountOptions{});
            fs.unmount();
        });
        try results.append(r);
        printComparison(r);
    }

    return results.toOwnedSlice();
}

// ============================================================================
// Print Summary
// ============================================================================

fn printSummary(all_results: []ComparisonResult) void {
    print("\n\x1b[1m{'=' ** 100}\x1b[0m\n");
    print("\x1b[1m=== PERFORMANCE SUMMARY: UFS vs ext3 ===\x1b[0m\n");
    print("\x1b[1m{'=' ** 100}\x1b[0m\n\n");

    var wins = 0;
    var losses = 0;
    var ties = 0;

    for (all_results) |r| {
        switch (r.status) {
            "WIN" => wins += 1,
            "LOSE" => losses += 1,
            else => ties += 1,
        }
    }

    const total = wins + losses + ties;
    print("Total Benchmarks: {}\n", .{total});
    print("\x1b[32mWINS: {}\x1b[0m\n", .{wins});
    print("\x1b[33mTIES: {}\x1b[0m\n", .{ties});
    print("\x1b[31mLOSSES: {}\x1b[0m\n", .{losses});
    print("Win Rate: {:.1f}%\n", .{@as(f64, @floatFromInt(wins)) * 100.0 / @as(f64, @floatFromInt(total))});

    // Category breakdown
    print("\n\x1b[1mCategory Breakdown:\x1b[0m\n");
    const categories = [_]struct {
        name: []const u8,
        prefix: []const u8,
    }{
        .{ .name = "Microbenchmarks", .prefix = "Serialization" },
        .{ .name = "Microbenchmarks", .prefix = "CRC32C" },
        .{ .name = "Microbenchmarks", .prefix = "BLAKE3" },
        .{ .name = "Microbenchmarks", .prefix = "LZ4" },
        .{ .name = "Microbenchmarks", .prefix = "ZSTD" },
        .{ .name = "Microbenchmarks", .prefix = "UUIDv7" },
        .{ .name = "Microbenchmarks", .prefix = "Timestamp" },
        .{ .name = "Filesystem Ops", .prefix = "Create File" },
        .{ .name = "Filesystem Ops", .prefix = "Read" },
        .{ .name = "Filesystem Ops", .prefix = "Write" },
        .{ .name = "Filesystem Ops", .prefix = "Create Directory" },
        .{ .name = "Filesystem Ops", .prefix = "Remove Directory" },
        .{ .name = "Filesystem Ops", .prefix = "Readdir" },
        .{ .name = "Filesystem Ops", .prefix = "Stat" },
        .{ .name = "Filesystem Ops", .prefix = "Sync" },
        .{ .name = "Filesystem Ops", .prefix = "Xattr" },
        .{ .name = "Throughput", .prefix = "Sequential" },
        .{ .name = "Throughput", .prefix = "Random" },
        .{ .name = "Compression", .prefix = "Ratio" },
        .{ .name = "Recovery", .prefix = "Journal" },
    };

    for (categories) |cat| {
        var cw = 0, cl = 0, ct = 0;
        for (all_results) |r| {
            if (std.mem.startsWith(u8, r.benchmark, cat.prefix)) {
                switch (r.status) {
                    "WIN" => cw += 1,
                    "LOSE" => cl += 1,
                    else => ct += 1,
                }
            }
        }
        const ctotal = cw + cl + ct;
        if (ctotal > 0) {
            print("  {s: <20} | W:{d:>2} L:{d:>2} T:{d:>2} | Rate: {:.0f}%\n",
                .{cat.name, cw, cl, ct, @as(f64, @floatFromInt(cw)) * 100.0 / @as(f64, @floatFromInt(ctotal))});
        }
    }

    print("\n\x1b[1m{'=' ** 100}\x1b[0m\n");
    if (wins > losses) {
        print("\x1b[32m\x1b[1mRESULT: UFS OUTPERFORMS ext3 in majority of benchmarks!\x1b[0m\n");
    } else if (wins == losses) {
        print("\x1b[33m\x1b[1mRESULT: UFS MATCHES ext3 performance overall.\x1b[0m\n");
    } else {
        print("\x1b[31m\x1b[1mRESULT: ext3 outperforms UFS in majority of benchmarks.\x1b[0m\n");
    }
    print("\x1b[1m{'=' ** 100}\x1b[0m\n");
}

// ============================================================================
// Main Entry Point
// ============================================================================

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    print("\x1b[1m{'=' ** 100}\x1b[0m\n");
    print("\x1b[1mUFS vs ext3 PERFORMANCE COMPARISON SUITE\x1b[0m\n");
    print("\x1b[1m{'=' ** 100}\x1b[0m\n");
    print("Running real-time benchmarks with ext3 baseline comparisons...\n\n");

    const config = BenchConfig{
        .iterations = 10000,
        .warmup_iterations = 1000,
    };

    var all_results = std.ArrayList(ComparisonResult).init(allocator);
    defer all_results.deinit();

    // Run all benchmark suites
    {
        const micro = try runMicrobenchmarks(config);
        for (micro) |r| try all_results.append(r);
    }

    {
        const fs = try runFilesystemBenchmarks(config);
        for (fs) |r| try all_results.append(r);
    }

    {
        const tp = try runThroughputBenchmarks(config);
        for (tp) |r| try all_results.append(r);
    }

    {
        const cr = try runCompressionRatioBenchmarks();
        for (cr) |r| try all_results.append(r);
    }

    {
        const rc = try runCrashRecoveryBenchmark(config);
        for (rc) |r| try all_results.append(r);
    }

    printSummary(all_results.items);

    // Exit with appropriate code
    var wins = 0, losses = 0;
    for (all_results.items) |r| {
        if (r.status == "WIN") wins += 1;
        else if (r.status == "LOSE") losses += 1;
    }
    if (losses > wins) {
        std.process.exit(1);
    }
}

test "perf_compare" {
    try main();
}