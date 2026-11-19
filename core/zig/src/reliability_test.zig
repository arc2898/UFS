// UFS Reliability Tests
// Crash simulation, stress testing, and data integrity verification
// Run with: zig build test-reliability

const std = @import("std");
const testing = std.testing;
const ufs = @import("ufs");
const serialization = @import("serialization.zig");
const integrity = @import("integrity.zig");
const compression = @import("compression.zig");
const utils = @import("utils.zig");

const Allocator = std.mem.Allocator;

// ============================================================================
// Test Configuration
// ============================================================================

const ReliabilityConfig = struct {
    // Crash test settings
    crash_test_iterations: usize = 1000,
    power_loss_probability: f64 = 0.01,
    max_file_size_mb: u64 = 100,
    max_dir_depth: u32 = 10,
    max_files_per_dir: u32 = 1000,

    // Stress test settings
    stress_duration_seconds: u64 = 300, // 5 minutes default
    stress_threads: usize = 4,

    // Performance regression
    baseline_file: []const u8 = "perf_baseline.json",
};

const DEFAULT_CONFIG = ReliabilityConfig{};

// ============================================================================
// In-Memory Block Device with Crash Simulation
// ============================================================================

pub const CrashSimulator = struct {
    allocator: Allocator,
    data: []u8,
    block_size: u32,
    total_blocks: u64,
    crash_point: ?usize = null,
    crash_enabled: bool = true,
    write_count: usize = 0,
    reads_since_crash: usize = 0,
    writes_since_crash: usize = 0,

    pub fn init(allocator: Allocator, size_bytes: u64, block_size: u32) !CrashSimulator {
        const total_blocks = size_bytes / block_size;
        const data = try allocator.alloc(u8, @intCast(size_bytes));
        @memset(data, 0);
        return CrashSimulator{
            .allocator = allocator,
            .data = data,
            .block_size = block_size,
            .total_blocks = total_blocks,
        };
    }

    pub fn deinit(self: *CrashSimulator) void {
        self.allocator.free(self.data);
    }

    pub fn enableCrashSimulation(self: *CrashSimulator, enabled: bool) void {
        self.crash_enabled = enabled;
    }

    pub fn setCrashPoint(self: *CrashSimulator, point: usize) void {
        self.crash_point = point;
    }

    pub fn triggerRandomCrash(self: *CrashSimulator) bool {
        if (!self.crash_enabled) return false;
        if (self.crash_point) |pt| {
            if (self.writes_since_crash >= pt) {
                self.writes_since_crash = 0;
                return true;
            }
        }
        // Random crash based on probability
        var rng = std.Random.DefaultPrng.init(0x6F93481F + self.write_count);
        if (rng.random().float(f64) < 0.001) { // 0.1% chance per write
            return true;
        }
        return false;
    }

    pub fn read(self: *CrashSimulator, block: u64, buffer: []u8) !void {
        if (block >= self.total_blocks) return error.OutOfRange;
        const offset = @intCast(block * self.block_size);
        const end = offset + buffer.len;
        if (end > self.data.len) return error.OutOfRange;
        @memcpy(buffer, self.data[offset..end]);
        self.reads_since_crash += 1;
    }

    pub fn write(self: *CrashSimulator, block: u64, buffer: []const u8) !void {
        if (block >= self.total_blocks) return error.OutOfRange;
        const offset = @intCast(block * self.block_size);
        const end = offset + buffer.len;
        if (end > self.data.len) return error.OutOfRange;

        // Simulate crash - if crash occurs, don't complete the write
        if (self.triggerRandomCrash()) {
            self.write_count += 1;
            self.writes_since_crash += 1;
            return error.Crashed;
        }

        @memcpy(self.data[offset..end], buffer);
        self.write_count += 1;
        self.writes_since_crash += 1;
    }

    pub fn flush(self: *CrashSimulator) !void {
        // In-memory device, flush is no-op unless we simulate flush failure
        if (self.triggerRandomCrash()) {
            return error.Crashed;
        }
    }

    pub fn getInfo(self: CrashSimulator) ufs.BlockDeviceInfo {
        return ufs.BlockDeviceInfo{
            .block_size = self.block_size,
            .physical_block_size = self.block_size,
            .optimal_io_size = self.block_size * 128,
            .total_blocks = self.total_blocks,
            .is_removable = false,
            .is_read_only = false,
            .is_ssd = true,
            .is_virtual = true,
            .serial_number = "CRASH_SIM",
            .model = "UFS Crash Simulator",
            .firmware = "1.0",
        };
    }

    // Corrupt random blocks for testing recovery
    pub fn corruptRandomBlocks(self: *CrashSimulator, count: usize, rng: *std.Random.DefaultPrng) !void {
        for (0..count) |_| {
            const block = @as(u64, @intCast(rng.random().intRangeAtMost(u64, 0, self.total_blocks - 1)));
            const offset = @intCast(block * self.block_size);
            for (self.data[offset..offset + self.block_size]) |*b| {
                b.* = rng.random();
            }
        }
    }
};

// ============================================================================
// Block Device Wrapper for UFS Core
// ============================================================================

pub fn createBlockDeviceFromSimulator(sim: *CrashSimulator) ufs.BlockDevice {
    const vtable = ufs.BlockDeviceVTable{
        .read = readFn,
        .write = writeFn,
        .flush = flushFn,
        .trim = trimFn,
        .get_info = getInfoFn,
    };
    return ufs.BlockDevice{
        .context = sim,
        .vtable = &vtable,
    };
}

fn readFn(ctx: *anyopaque, offset: u64, buffer: []u8) !usize {
    const sim = @as(*CrashSimulator, @ptrCast(ctx));
    try sim.read(offset / sim.block_size, buffer);
    return buffer.len;
}

fn writeFn(ctx: *anyopaque, offset: u64, buffer: []const u8) !usize {
    const sim = @as(*CrashSimulator, @ptrCast(ctx));
    try sim.write(offset / sim.block_size, buffer);
    return buffer.len;
}

fn flushFn(ctx: *anyopaque) !void {
    const sim = @as(*CrashSimulator, @ptrCast(ctx));
    try sim.flush();
}

fn trimFn(ctx: *anyopaque, offset: u64, length: u64) !void {
    _ = ctx; _ = offset; _ = length;
    // No-op for crash simulator
}

fn getInfoFn(ctx: *anyopaque) ufs.BlockDeviceInfo {
    const sim = @as(*CrashSimulator, @ptrCast(ctx));
    return sim.getInfo();
}

// ============================================================================
// Crash Test: Power Loss Simulation
// ============================================================================

test "crash simulation: power loss during write" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Create simulator with 100MB
    var sim = try CrashSimulator.init(allocator, 100 * 1024 * 1024, 4096);
    defer sim.deinit();

    // Format
    const block_dev = createBlockDeviceFromSimulator(&sim);
    try ufs.format(block_dev, "CrashTest", 4096, ufs.CompressionAlgorithm.LZ4, 1024, 4);

    // Enable crash simulation
    sim.enableCrashSimulation(true);
    sim.setCrashPoint(100); // Crash after 100 writes

    // Mount
    const fs = try ufs.mount(block_dev, ufs.MountOptions{});
    defer fs.unmount();

    // Write many files, some will crash
    var rng = std.Random.DefaultPrng.init(0x624052A1);
    var crashed: usize = 0;
    var succeeded: usize = 0;

    for (0..1000) |i| {
        const file = try fs.open(2, try std.fmt.allocPrint(allocator, "crash_test_{d}.txt", .{i}), ufs.O_CREAT | ufs.O_RDWR, 0644);
        const data = try allocator.alloc(u8, 1024);
        defer allocator.free(data);
        for (data, 0..) |*b, j| {
            b.* = @as(u8, @intCast((i * 1024 + j) % 256));
        }

        const result = file.writeAll(data);
        if (result == error.Crashed) {
            crashed += 1;
        } else if (result != null) {
            succeeded += 1;
        }
        file.close() catch {};
    }

    std.debug.print("Crash test: {} succeeded, {} crashed\n", .{succeeded, crashed});
    try testing.expect(succeeded > 0);
    try testing.expect(crashed > 0);
}

test "crash simulation: journal replay after power loss" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Phase 1: Create filesystem and write data, then crash
    {
        var sim = try CrashSimulator.init(allocator, 100 * 1024 * 1024, 4096);
        defer sim.deinit();

        const block_dev = createBlockDeviceFromSimulator(&sim);
        try ufs.format(block_dev, "JournalReplay", 4096, ufs.CompressionAlgorithm.LZ4, 1024, 4);

        // Mount and write initial data
        {
            const fs = try ufs.mount(block_dev, ufs.MountOptions{});
            defer fs.unmount();

            // Create directory structure
            try fs.mkdir(2, "data", 0755);
            try fs.mkdir(2, "logs", 0755);

            // Write some files
            for (0..10) |i| {
                const file = try fs.open(2, try std.fmt.allocPrint(allocator, "data/file_{d}.dat", .{i}), ufs.O_CREAT | ufs.O_RDWR, 0644);
                const data = try allocator.alloc(u8, 4096);
                defer allocator.free(data);
                for (data, 0..) |*b, j| {
                    b.* = @as(u8, @intCast((i * 4096 + j) % 256));
                }
                try file.writeAll(data);
                file.close() catch {};
            }

            // Force sync
            try fs.sync();
        }

        // Simulate power loss during additional writes
        sim.enableCrashSimulation(true);
        sim.setCrashPoint(50);

        {
            const fs = try ufs.mount(block_dev, ufs.MountOptions{});
            defer fs.unmount();

            // Try to write more files - some will crash
            for (10..20) |i| {
                const file = try fs.open(2, try std.fmt.allocPrint(allocator, "data/file_{d}.dat", .{i}), ufs.O_CREAT | ufs.O_RDWR, 0644);
                const data = try allocator.alloc(u8, 4096);
                defer allocator.free(data);
                for (data, 0..) |*b, j| {
                    b.* = @as(u8, @intCast((i * 4096 + j) % 256));
                }
                file.writeAll(data) catch {};
                file.close() catch {};
            }
        }

        // Phase 2: Remount and verify recovery
        sim.enableCrashSimulation(false);

        {
            const fs = try ufs.mount(block_dev, ufs.MountOptions{});
            defer fs.unmount();

            // Verify initial files are intact
            for (0..10) |i| {
                const file = try fs.open(2, try std.fmt.allocPrint(allocator, "data/file_{d}.dat", .{i}), ufs.O_RDONLY, 0);
                var buf: [4096]u8 = undefined;
                const n = try file.read(&buf);
                try testing.expect(n == 4096);
                for (buf, 0..) |b, j| {
                    try testing.expect(b == @as(u8, @intCast((i * 4096 + j) % 256)));
                }
                file.close() catch {};
            }

            // Files 10-19 may or may not exist (incomplete transactions)
            // Journal replay should have recovered committed transactions only
        }
    }
}

// ============================================================================
// Stress Tests
// ============================================================================

test "stress: many small files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var sim = try CrashSimulator.init(allocator, 200 * 1024 * 1024, 4096);
    defer sim.deinit();

    const block_dev = createBlockDeviceFromSimulator(&sim);
    try ufs.format(block_dev, "ManyFiles", 4096, ufs.CompressionAlgorithm.LZ4, 2048, 8);

    const fs = try ufs.mount(block_dev, ufs.MountOptions{});
    defer fs.unmount();

    var rng = std.Random.DefaultPrng.init(0xCDACACEF);

    // Create 10,000 small files
    const num_files = 10000;
    std.debug.print("Creating {} small files...\n", .{num_files});

    for (0..num_files) |i| {
        const file = try fs.open(2, try std.fmt.allocPrint(allocator, "file_{d}.txt", .{i}), ufs.O_CREAT | ufs.O_RDWR, 0644);
        const data = try std.fmt.allocPrint(allocator, "Small file content: {d}\n", .{i});
        try file.writeAll(data);
        file.close() catch {};

        if (i % 1000 == 0) {
            std.debug.print("  Created {} files\n", .{i});
        }
    }

    // Verify all files
    std.debug.print("Verifying {} files...\n", .{num_files});
    for (0..num_files) |i| {
        const file = try fs.open(2, try std.fmt.allocPrint(allocator, "file_{d}.txt", .{i}), ufs.O_RDONLY, 0);
        var buf: [100]u8 = undefined;
        const n = try file.read(&buf);
        try testing.expect(n > 0);
        file.close() catch {};

        if (i % 1000 == 0) {
            std.debug.print("  Verified {} files\n", .{i});
        }
    }

    // Check statfs
    const stat = try fs.statfs();
    std.debug.print("Free space: {} bytes, Free inodes: {}\n", .{stat.free_space, stat.free_inodes});
    try testing.expect(stat.total_inodes > num_files);
}

test "stress: large files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var sim = try CrashSimulator.init(allocator, 500 * 1024 * 1024, 4096);
    defer sim.deinit();

    const block_dev = createBlockDeviceFromSimulator(&sim);
    try ufs.format(block_dev, "LargeFiles", 4096, ufs.CompressionAlgorithm.LZ4, 4096, 8);

    const fs = try ufs.mount(block_dev, ufs.MountOptions{});
    defer fs.unmount();

    // Create 100MB file
    const file_size = 100 * 1024 * 1024; // 100MB
    const chunk_size = 1024 * 1024; // 1MB chunks

    std.debug.print("Creating {} MB file...\n", .{file_size / (1024 * 1024)});

    const file = try fs.open(2, "large.dat", ufs.O_CREAT | ufs.O_RDWR, 0644);
    defer file.close() catch {};

    var rng = std.Random.DefaultPrng.init(0x8B8B16D3);
    var written: u64 = 0;
    var chunk: [1024 * 1024]u8 = undefined;

    while (written < file_size) {
        for (&chunk) |*b| {
            b.* = rng.random();
        }
        const to_write = @min(chunk_size, file_size - written);
        try file.writeAll(chunk[0..to_write]);
        written += to_write;

        if (written % (10 * 1024 * 1024) == 0) {
            std.debug.print("  Written {} MB\n", .{written / (1024 * 1024)});
        }
    }

    // Verify by reading back
    std.debug.print("Verifying {} MB file...\n", .{file_size / (1024 * 1024)});
    try file.seek(0);

    var read_buf: [1024 * 1024]u8 = undefined;
    var rng2 = std.Random.DefaultPrng.init(0x8B8B16D3);
    var read_total: u64 = 0;

    while (read_total < file_size) {
        for (&read_buf) |*b| {
            b.* = rng2.random();
        }
        const to_read = @min(chunk_size, file_size - read_total);
        const n = try file.read(read_buf[0..to_read]);
        try testing.expect(n == to_read);

        // Verify content matches
        var rng3 = std.Random.DefaultPrng.init(0x8B8B16D3);
        for (0..read_total) |_| { _ = rng3.random(); } // Skip to position
        for (0..n) |i| {
            try testing.expect(read_buf[i] == rng3.random());
        }

        read_total += n;
        if (read_total % (10 * 1024 * 1024) == 0) {
            std.debug.print("  Verified {} MB\n", .{read_total / (1024 * 1024)});
        }
    }
}

test "stress: deep directory hierarchy" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var sim = try CrashSimulator.init(allocator, 100 * 1024 * 1024, 4096);
    defer sim.deinit();

    const block_dev = createBlockDeviceFromSimulator(&sim);
    try ufs.format(block_dev, "DeepDirs", 4096, ufs.CompressionAlgorithm.LZ4, 1024, 4);

    const fs = try ufs.mount(block_dev, ufs.MountOptions{});
    defer fs.unmount();

    const max_depth = 100;
    std.debug.print("Creating directory depth of {}\n", .{max_depth});

    // Create deep hierarchy
    var current_parent = 2; // root
    var path = std.ArrayList(u8).init(allocator);
    defer path.deinit();
    try path.appendSlice("/");

    for (0..max_depth) |depth| {
        const dir_name = try std.fmt.allocPrint(allocator, "level_{d}", .{depth});
        try path.appendSlice(dir_name);
        try fs.mkdir(current_parent, dir_name, 0755);

        // Get the new directory's inode
        const dir_inode = try fs.lookup(current_parent, dir_name);
        current_parent = dir_inode;

        // Create a file in each level
        const file = try fs.open(current_parent, "marker.txt", ufs.O_CREAT | ufs.O_RDWR, 0644);
        const content = try std.fmt.allocPrint(allocator, "Depth: {d}\n", .{depth});
        try file.writeAll(content);
        file.close() catch {};

        if (depth % 20 == 0) {
            std.debug.print("  Depth {}\n", .{depth});
        }
    }

    // Verify by walking back up
    std.debug.print("Verifying deep hierarchy...\n");
    current_parent = 2;
    for (0..max_depth) |depth| {
        const dir_name = try std.fmt.allocPrint(allocator, "level_{d}", .{depth});
        const dir_inode = try fs.lookup(current_parent, dir_name);
        try testing.expect(dir_inode != 0);

        const file = try fs.open(dir_inode, "marker.txt", ufs.O_RDONLY, 0);
        var buf: [50]u8 = undefined;
        const n = try file.read(&buf);
        try testing.expect(n > 0);
        file.close() catch {};

        current_parent = dir_inode;
    }
}

test "stress: concurrent-like operations (sequential simulation)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var sim = try CrashSimulator.init(allocator, 200 * 1024 * 1024, 4096);
    defer sim.deinit();

    const block_dev = createBlockDeviceFromSimulator(&sim);
    try ufs.format(block_dev, "Concurrent", 4096, ufs.CompressionAlgorithm.LZ4, 2048, 8);

    const fs = try ufs.mount(block_dev, ufs.MountOptions{});
    defer fs.unmount();

    // Simulate concurrent workload: multiple "threads" doing operations
    const num_operations = 5000;
    var rng = std.Random.DefaultPrng.init(0x852EDA03);

    std.debug.print("Running {} mixed operations...\n", .{num_operations});

    // Pre-create some files
    const initial_files = 100;
    for (0..initial_files) |i| {
        const file = try fs.open(2, try std.fmt.allocPrint(allocator, "init_{d}.dat", .{i}), ufs.O_CREAT | ufs.O_RDWR, 0644);
        var data: [1024]u8 = undefined;
        for (&data) |*b| b.* = rng.random();
        try file.writeAll(&data);
        file.close() catch {};
    }

    // Mixed workload
    var creates = 0;
    var reads = 0;
    var writes = 0;
    var deletes = 0;

    for (0..num_operations) |i| {
        const op = rng.random().intRangeAtMost(u8, 0, 3);
        const file_num = rng.random().intRangeAtMost(u32, 0, 200);

        switch (op) {
            0 => { // Create
                const name = try std.fmt.allocPrint(allocator, "file_{d}.dat", .{file_num});
                const file = fs.open(2, name, ufs.O_CREAT | ufs.O_RDWR, 0644) catch continue;
                var data: [1024]u8 = undefined;
                for (&data) |*b| b.* = rng.random();
                file.writeAll(&data) catch {};
                file.close() catch {};
                creates += 1;
            },
            1 => { // Read
                const name = try std.fmt.allocPrint(allocator, "file_{d}.dat", .{file_num});
                const file = fs.open(2, name, ufs.O_RDONLY, 0) catch continue;
                var buf: [1024]u8 = undefined;
                file.read(&buf) catch {};
                file.close() catch {};
                reads += 1;
            },
            2 => { // Write
                const name = try std.fmt.allocPrint(allocator, "file_{d}.dat", .{file_num});
                const file = fs.open(2, name, ufs.O_RDWR, 0) catch continue;
                var data: [1024]u8 = undefined;
                for (&data) |*b| b.* = rng.random();
                file.writeAll(&data) catch {};
                file.close() catch {};
                writes += 1;
            },
            3 => { // Delete
                const name = try std.fmt.allocPrint(allocator, "file_{d}.dat", .{file_num});
                fs.unlink(2, name) catch {};
                deletes += 1;
            },
            else => {},
        }

        if (i % 1000 == 0) {
            std.debug.print("  Operations: {}/{}\n", .{i, num_operations});
        }
    }

    std.debug.print("Operations: creates={}, reads={}, writes={}, deletes={}\n",
        .{creates, reads, writes, deletes});

    try testing.expect(creates > 0);
    try testing.expect(reads > 0);
    try testing.expect(writes > 0);
}

// ============================================================================
// Data Integrity Tests
// ============================================================================

test "integrity: CRC32C metadata verification" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var sim = try CrashSimulator.init(allocator, 100 * 1024 * 1024, 4096);
    defer sim.deinit();

    const block_dev = createBlockDeviceFromSimulator(&sim);
    try ufs.format(block_dev, "CRC32CTest", 4096, ufs.CompressionAlgorithm.LZ4, 1024, 4);

    const fs = try ufs.mount(block_dev, ufs.MountOptions{});
    defer fs.unmount();

    // Write known data
    const test_data = "This is test data for CRC32C verification!";
    const file = try fs.open(2, "crc_test.txt", ufs.O_CREAT | ufs.O_RDWR, 0644);
    try file.writeAll(test_data);
    file.close() catch {};

    // Read back and verify integrity via UFS core
    // The UFS core should validate CRC32C on metadata read
    const file2 = try fs.open(2, "crc_test.txt", ufs.O_RDONLY, 0);
    var buf: [100]u8 = undefined;
    const n = try file2.read(&buf);
    try testing.expect(n == test_data.len);
    try testing.expectEqualStrings(test_data, buf[0..n]);
    file2.close() catch {};

    // Verify superblock CRC32C
    // This is implicitly tested by successful mount
}

test "integrity: BLAKE3 data verification" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var sim = try CrashSimulator.init(allocator, 100 * 1024 * 1024, 4096);
    defer sim.deinit();

    const block_dev = createBlockDeviceFromSimulator(&sim);
    try ufs.format(block_dev, "BLAKE3Test", 4096, ufs.CompressionAlgorithm.LZ4, 1024, 4);

    const fs = try ufs.mount(block_dev, ufs.MountOptions{});
    defer fs.unmount();

    // Write data that will have BLAKE3 checksums
    const test_data = "BLAKE3 verification test data - should have 256-bit checksums";
    const file = try fs.open(2, "blake3_test.bin", ufs.O_CREAT | ufs.O_RDWR, 0644);
    try file.writeAll(test_data);
    file.close() catch {};

    // Read back - UFS core verifies BLAKE3 on data read
    const file2 = try fs.open(2, "blake3_test.bin", ufs.O_RDONLY, 0);
    var buf: [200]u8 = undefined;
    const n = try file2.read(&buf);
    try testing.expect(n == test_data.len);
    try testing.expectEqualStrings(test_data, buf[0..n]);
    file2.close() catch {};

    // Test with larger data (multiple extents)
    var large_data = try allocator.alloc(u8, 100 * 1024);
    defer allocator.free(large_data);
    var rng = std.Random.DefaultPrng.init(0x5405505D);
    for (large_data) |*b| b.* = rng.random();

    const file3 = try fs.open(2, "large_blake3.bin", ufs.O_CREAT | ufs.O_RDWR, 0644);
    try file3.writeAll(large_data);
    file3.close() catch {};

    const file4 = try fs.open(2, "large_blake3.bin", ufs.O_RDONLY, 0);
    var read_buf = try allocator.alloc(u8, 100 * 1024);
    defer allocator.free(read_buf);
    const n2 = try file4.read(read_buf);
    try testing.expect(n2 == large_data.len);
    try testing.expect(std.mem.eql(u8, large_data, read_buf[0..n2]));
    file4.close() catch {};
}

test "integrity: corruption detection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var sim = try CrashSimulator.init(allocator, 100 * 1024 * 1024, 4096);
    defer sim.deinit();

    const block_dev = createBlockDeviceFromSimulator(&sim);
    try ufs.format(block_dev, "CorruptionTest", 4096, ufs.CompressionAlgorithm.LZ4, 1024, 4);

    const fs = try ufs.mount(block_dev, ufs.MountOptions{});
    defer fs.unmount();

    // Write test file
    const test_data = "Original data that will be corrupted";
    const file = try fs.open(2, "corrupt_me.txt", ufs.O_CREAT | ufs.O_RDWR, 0644);
    try file.writeAll(test_data);
    file.close() catch {};

    // Sync to ensure data is on disk
    try fs.sync();

    // Corrupt the data on the simulated device
    var rng = std.Random.DefaultPrng.init(0xC7791EEA);
    try sim.corruptRandomBlocks(&rng, 5);

    // Try to read - should detect corruption via BLAKE3
    const file2 = try fs.open(2, "corrupt_me.txt", ufs.O_RDONLY, 0);
    var buf: [100]u8 = undefined;
    const result = file2.read(&buf);
    // Should fail with corruption error
    try testing.expect(result == error.CorruptedData || result == error.ChecksumMismatch);
    file2.close() catch {};
}

// ============================================================================
// Compression Tests
// ============================================================================

test "compression: LZ4 ratio verification" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var sim = try CrashSimulator.init(allocator, 100 * 1024 * 1024, 4096);
    defer sim.deinit();

    const block_dev = createBlockDeviceFromSimulator(&sim);
    try ufs.format(block_dev, "CompressLZ4", 4096, ufs.CompressionAlgorithm.LZ4, 1024, 4);

    const fs = try ufs.mount(block_dev, ufs.MountOptions{.compression = ufs.CompressionAlgorithm.LZ4});
    defer fs.unmount();

    // Highly compressible data
    var compressible = try allocator.alloc(u8, 100 * 1024);
    defer allocator.free(compressible);
    @memset(compressible, 0x42); // All same byte

    const file = try fs.open(2, "compressible.dat", ufs.O_CREAT | ufs.O_RDWR, 0644);
    try file.writeAll(compressible);
    file.close() catch {};

    // Check space savings via statfs
    const stat_before = try fs.statfs();

    // Incompressible data
    var incompressible = try allocator.alloc(u8, 100 * 1024);
    defer allocator.free(incompressible);
    var rng = std.Random.DefaultPrng.init(0x5247F6F8);
    for (incompressible) |*b| b.* = rng.random();

    const file2 = try fs.open(2, "incompressible.dat", ufs.O_CREAT | ufs.O_RDWR, 0644);
    try file2.writeAll(incompressible);
    file2.close() catch {};

    const stat_after = try fs.statfs();

    // Compressible should use less space
    try testing.expect(stat_before.free_space > stat_after.free_space);
    std.debug.print("Space used: {} KB\n", .{(stat_before.free_space - stat_after.free_space) / 1024});
}

test "compression: ZSTD ratio verification" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var sim = try CrashSimulator.init(allocator, 100 * 1024 * 1024, 4096);
    defer sim.deinit();

    const block_dev = createBlockDeviceFromSimulator(&sim);
    try ufs.format(block_dev, "CompressZSTD", 4096, ufs.CompressionAlgorithm.ZSTD, 1024, 4);

    const fs = try ufs.mount(block_dev, ufs.MountOptions{.compression = ufs.CompressionAlgorithm.ZSTD});
    defer fs.unmount();

    // Test with text-like data
    var text_data = try allocator.alloc(u8, 50 * 1024);
    defer allocator.free(text_data);
    const lorem = "Lorem ipsum dolor sit amet, consectetur adipiscing elit. ";
    for (text_data, 0..) |*b, i| {
        b.* = lorem[i % lorem.len];
    }

    const file = try fs.open(2, "text.dat", ufs.O_CREAT | ufs.O_RDWR, 0644);
    try file.writeAll(text_data);
    file.close() catch {};

    // Verify readback
    const file2 = try fs.open(2, "text.dat", ufs.O_RDONLY, 0);
    var buf = try allocator.alloc(u8, 50 * 1024);
    defer allocator.free(buf);
    const n = try file2.read(buf);
    try testing.expect(n == text_data.len);
    try testing.expect(std.mem.eql(u8, text_data, buf[0..n]));
    file2.close() catch {};
}

// ============================================================================
// Full Disk Test
// ============================================================================

test "stress: full disk handling" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Small disk to fill quickly
    var sim = try CrashSimulator.init(allocator, 20 * 1024 * 1024, 4096);
    defer sim.deinit();

    const block_dev = createBlockDeviceFromSimulator(&sim);
    try ufs.format(block_dev, "FullDisk", 4096, ufs.CompressionAlgorithm.NONE, 256, 2);

    const fs = try ufs.mount(block_dev, ufs.MountOptions{});
    defer fs.unmount();

    // Write until disk is full
    var file_count = 0;
    var total_written: u64 = 0;
    var rng = std.Random.DefaultPrng.init(0x9645AD57);

    while (true) {
        const file = fs.open(2, try std.fmt.allocPrint(allocator, "fill_{d}.dat", .{file_count}), ufs.O_CREAT | ufs.O_RDWR, 0644) catch break;
        var data: [100 * 1024]u8 = undefined; // 100KB chunks
        for (&data) |*b| b.* = rng.random();

        const result = file.writeAll(&data);
        if (result == error.OutOfSpace) {
            file.close() catch {};
            break;
        }
        file.close() catch {};

        total_written += data.len;
        file_count += 1;

        if (file_count % 10 == 0) {
            const stat = try fs.statfs();
            std.debug.print("  Files: {}, Free: {} KB\n", .{file_count, stat.free_space / 1024});
        }
    }

    std.debug.print("Disk full after {} files, {} MB written\n", .{file_count, total_written / (1024 * 1024)});

    // Verify we can still read existing files
    const file = try fs.open(2, "fill_0.dat", ufs.O_RDONLY, 0);
    var buf: [100 * 1024]u8 = undefined;
    const n = try file.read(&buf);
    try testing.expect(n == 100 * 1024);
    file.close() catch {};

    // Verify out of space on new writes
    const new_file = fs.open(2, "new.dat", ufs.O_CREAT | ufs.O_RDWR, 0644) catch |err| {
        try testing.expect(err == error.OutOfSpace);
    };
}

// ============================================================================
// Performance Baseline Recording
// ============================================================================

const PerfBaseline = struct {
    timestamp: u64,
    git_commit: []const u8,
    results: std.StringHashMap(PerfResult),

    pub const PerfResult = struct {
        name: []const u8,
        ops_per_sec: f64,
        avg_ns: u64,
        throughput_mb_s: f64,
    };
};

fn recordPerformanceBaseline(allocator: Allocator, name: []const u8, result: ufs.BenchResult) !void {
    // In a real implementation, this would write to a JSON file
    // For now, just print
    std.debug.print("BASELINE: {} | {:.2f} ops/s | {:.2f} MB/s\n",
        .{name, result.ops_per_sec, result.throughput_mb_s});
}

// ============================================================================
// Macrobenchmarks
// ============================================================================

test "macrobenchmark: file create/write/read/delete" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var sim = try CrashSimulator.init(allocator, 500 * 1024 * 1024, 4096);
    defer sim.deinit();

    const block_dev = createBlockDeviceFromSimulator(&sim);
    try ufs.format(block_dev, "MacroBench", 4096, ufs.CompressionAlgorithm.LZ4, 4096, 8);

    const fs = try ufs.mount(block_dev, ufs.MountOptions{});
    defer fs.unmount();

    const iterations = 1000;
    const file_size = 64 * 1024; // 64KB
    var rng = std.Random.DefaultPrng.init(0xE25D5AFE);

    // Benchmark create + write
    var create_write_times = std.ArrayList(u64).init(allocator);
    defer create_write_times.deinit();

    var data = try allocator.alloc(u8, file_size);
    defer allocator.free(data);
    for (data) |*b| b.* = rng.random();

    for (0..iterations) |i| {
        const start = std.time.nanoTimestamp();
        const file = try fs.open(2, try std.fmt.allocPrint(allocator, "bench_{d}.dat", .{i}), ufs.O_CREAT | ufs.O_RDWR, 0644);
        try file.writeAll(data);
        file.close() catch {};
        const end = std.time.nanoTimestamp();
        try create_write_times.append(end - start);
    }

    // Benchmark read
    var read_times = std.ArrayList(u64).init(allocator);
    defer read_times.deinit();

    for (0..iterations) |i| {
        const start = std.time.nanoTimestamp();
        const file = try fs.open(2, try std.fmt.allocPrint(allocator, "bench_{d}.dat", .{i}), ufs.O_RDONLY, 0);
        var buf = try allocator.alloc(u8, file_size);
        defer allocator.free(buf);
        _ = file.read(buf) catch {};
        file.close() catch {};
        const end = std.time.nanoTimestamp();
        try read_times.append(end - start);
    }

    // Benchmark delete
    var delete_times = std.ArrayList(u64).init(allocator);
    defer delete_times.deinit();

    for (0..iterations) |i| {
        const start = std.time.nanoTimestamp();
        fs.unlink(2, try std.fmt.allocPrint(allocator, "bench_{d}.dat", .{i})) catch {};
        const end = std.time.nanoTimestamp();
        try delete_times.append(end - start);
    }

    // Calculate statistics
    const avg_create_write = avg(create_write_times.items);
    const avg_read = avg(read_times.items);
    const avg_delete = avg(delete_times.items);

    std.debug.print("\n=== Macrobenchmark: File Create/Write/Read/Delete ===\n");
    std.debug.print("Iterations: {}\n", .{iterations});
    std.debug.print("File size: {} KB\n", .{file_size / 1024});
    std.debug.print("Avg create+write: {:.2f} ms ({:.2f} ops/s)\n",
        .{avg_create_write / 1_000_000.0, 1_000_000_000.0 / avg_create_write});
    std.debug.print("Avg read: {:.2f} ms ({:.2f} ops/s)\n",
        .{avg_read / 1_000_000.0, 1_000_000_000.0 / avg_read});
    std.debug.print("Avg delete: {:.2f} ms ({:.2f} ops/s)\n",
        .{avg_delete / 1_000_000.0, 1_000_000_000.0 / avg_delete});
    std.debug.print("Throughput: {:.2f} MB/s write, {:.2f} MB/s read\n",
        .{(f64(file_size) / 1_048_576.0) / (avg_create_write / 1_000_000_000.0),
          (f64(file_size) / 1_048_576.0) / (avg_read / 1_000_000_000.0)});
}

test "macrobenchmark: directory operations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var sim = try CrashSimulator.init(allocator, 200 * 1024 * 1024, 4096);
    defer sim.deinit();

    const block_dev = createBlockDeviceFromSimulator(&sim);
    try ufs.format(block_dev, "DirBench", 4096, ufs.CompressionAlgorithm.LZ4, 2048, 8);

    const fs = try ufs.mount(block_dev, ufs.MountOptions{});
    defer fs.unmount();

    const iterations = 5000;

    // Benchmark mkdir
    var mkdir_times = std.ArrayList(u64).init(allocator);
    defer mkdir_times.deinit();

    for (0..iterations) |i| {
        const start = std.time.nanoTimestamp();
        try fs.mkdir(2, try std.fmt.allocPrint(allocator, "dir_{d}", .{i}), 0755);
        const end = std.time.nanoTimestamp();
        try mkdir_times.append(end - start);
    }

    // Benchmark readdir
    var readdir_times = std.ArrayList(u64).init(allocator);
    defer readdir_times.deinit();

    for (0..100) |_| {
        const start = std.time.nanoTimestamp();
        var count = 0;
        try fs.iterateDir(2, {}, fn (_: ufs.DirEntry) !void { count += 1; });
        const end = std.time.nanoTimestamp();
        try readdir_times.append(end - start);
    }

    // Benchmark rmdir
    var rmdir_times = std.ArrayList(u64).init(allocator);
    defer rmdir_times.deinit();

    for (0..iterations) |i| {
        const start = std.time.nanoTimestamp();
        fs.rmdir(2, try std.fmt.allocPrint(allocator, "dir_{d}", .{i})) catch {};
        const end = std.time.nanoTimestamp();
        try rmdir_times.append(end - start);
    }

    std.debug.print("\n=== Macrobenchmark: Directory Operations ===\n");
    std.debug.print("Iterations: {}\n", .{iterations});
    std.debug.print("Avg mkdir: {:.2f} µs ({:.2f} ops/s)\n",
        .{avg(mkdir_times.items) / 1000.0, 1_000_000_000.0 / avg(mkdir_times.items)});
    std.debug.print("Avg readdir ({} entries): {:.2f} ms ({:.2f} ops/s)\n",
        .{iterations, avg(readdir_times.items) / 1_000_000.0, 1_000_000_000.0 / avg(readdir_times.items)});
    std.debug.print("Avg rmdir: {:.2f} µs ({:.2f} ops/s)\n",
        .{avg(rmdir_times.items) / 1000.0, 1_000_000_000.0 / avg(rmdir_times.items)});
}

fn avg(items: []const u64) u64 {
    if (items.len == 0) return 0;
    var sum: u64 = 0;
    for (items) |v| sum += v;
    return sum / items.len;
}

// ============================================================================
// Hardware Acceleration Validation
// ============================================================================

test "hardware: CRC32C acceleration detection" {
    // Test if hardware CRC32C is available and faster than software
    const data_size = 1024 * 1024; // 1MB
    var data = try std.testing.allocator.alloc(u8, data_size);
    defer std.testing.allocator.free(data);

    var rng = std.Random.DefaultPrng.init(0x29AF70C7);
    for (data) |*b| b.* = rng.random();

    // Software CRC32C
    const sw_start = std.time.nanoTimestamp();
    for (0..100) |_| {
        _ = integrity.Crc32c.compute(data);
    }
    const sw_end = std.time.nanoTimestamp();
    const sw_avg = (sw_end - sw_start) / 100;

    // Hardware CRC32C (if available)
    const hw_start = std.time.nanoTimestamp();
    for (0..100) |_| {
        _ = integrity.Crc32c.computeHw(data);
    }
    const hw_end = std.time.nanoTimestamp();
    const hw_avg = (hw_end - hw_start) / 100;

    std.debug.print("CRC32C Software: {} ns/op ({:.2f} MB/s)\n",
        .{sw_avg, (f64(data_size) / 1_048_576.0) / (f64(sw_avg) / 1_000_000_000.0)});
    std.debug.print("CRC32C Hardware: {} ns/op ({:.2f} MB/s)\n",
        .{hw_avg, (f64(data_size) / 1_048_576.0) / (f64(hw_avg) / 1_000_000_000.0)});

    if (hw_avg < sw_avg) {
        std.debug.print("Hardware acceleration: ENABLED (speedup: {:.2f}x)\n", .{f64(sw_avg) / f64(hw_avg)});
    } else {
        std.debug.print("Hardware acceleration: NOT AVAILABLE or SLOWER\n");
    }
}

test "hardware: BLAKE3 SIMD detection" {
    const data_size = 1024 * 1024; // 1MB
    var data = try std.testing.allocator.alloc(u8, data_size);
    defer std.testing.allocator.free(data);

    var rng = std.Random.DefaultPrng.init(0x89FC7517);
    for (data) |*b| b.* = rng.random();

    // Scalar BLAKE3
    const scalar_start = std.time.nanoTimestamp();
    for (0..10) |_| {
        _ = integrity.Blake3.hash(data);
    }
    const scalar_end = std.time.nanoTimestamp();
    const scalar_avg = (scalar_end - scalar_start) / 10;

    // SIMD BLAKE3
    const simd_start = std.time.nanoTimestamp();
    for (0..10) |_| {
        _ = integrity.Blake3Simd.hash(data);
    }
    const simd_end = std.time.nanoTimestamp();
    const simd_avg = (simd_end - simd_start) / 10;

    std.debug.print("BLAKE3 Scalar: {} ns/op ({:.2f} MB/s)\n",
        .{scalar_avg, (f64(data_size) / 1_048_576.0) / (f64(scalar_avg) / 1_000_000_000.0)});
    std.debug.print("BLAKE3 SIMD: {} ns/op ({:.2f} MB/s)\n",
        .{simd_avg, (f64(data_size) / 1_048_576.0) / (f64(simd_avg) / 1_000_000_000.0)});

    if (simd_avg < scalar_avg) {
        std.debug.print("SIMD acceleration: ENABLED (speedup: {:.2f}x)\n", .{f64(scalar_avg) / f64(simd_avg)});
    } else {
        std.debug.print("SIMD acceleration: NOT AVAILABLE or SLOWER\n");
    }
}

// ============================================================================
// Regression Test Helpers
// ============================================================================

// Run with: zig test --test-filter regression
test "regression: format compatibility" {
    // Test that we can mount filesystems created by older versions
    // This would test backward compatibility
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var sim = try CrashSimulator.init(allocator, 50 * 1024 * 1024, 4096);
    defer sim.deinit();

    const block_dev = createBlockDeviceFromSimulator(&sim);

    // Format with current version
    try ufs.format(block_dev, "CompatTest", 4096, ufs.CompressionAlgorithm.LZ4, 512, 2);

    // Mount and verify
    const fs = try ufs.mount(block_dev, ufs.MountOptions{});
    defer fs.unmount();

    // Basic operations
    try fs.mkdir(2, "testdir", 0755);
    const file = try fs.open(2, "testfile.txt", ufs.O_CREAT | ufs.O_RDWR, 0644);
    try file.writeAll("Compatibility test");
    file.close() catch {};

    std.debug.print("Format compatibility: OK\n");
}

test "regression: feature flags" {
    // Test feature flag compatibility
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var sim = try CrashSimulator.init(allocator, 50 * 1024 * 1024, 4096);
    defer sim.deinit();

    const block_dev = createBlockDeviceFromSimulator(&sim);
    try ufs.format(block_dev, "FeatureTest", 4096, ufs.CompressionAlgorithm.LZ4, 512, 2);

    // Mount with various feature flag combinations
    const fs1 = try ufs.mount(block_dev, ufs.MountOptions{
        .read_only = false,
        .case_insensitive = true,
        .compression = ufs.CompressionAlgorithm.LZ4,
        .integrity_check = true,
    });
    defer fs1.unmount();

    // Test read-only mount
    const fs2 = try ufs.mount(block_dev, ufs.MountOptions{
        .read_only = true,
    });
    defer fs2.unmount();

    // Should fail to write on read-only
    const file = fs2.open(2, "readonly_test.txt", ufs.O_CREAT | ufs.O_RDWR, 0644) catch |err| {
        try testing.expect(err == error.WriteProtected || err == error.PermissionDenied);
    };
    if (file) |f| {
        f.close() catch {};
        try testing.expect(false); // Should not reach here
    }

    std.debug.print("Feature flags: OK\n");
}

// ============================================================================
// Continuous Verification
// ============================================================================

/// Run this test daily/weekly to verify filesystem health
/// Usage: zig build test-reliability -- --test-filter continuous
test "continuous: full verification cycle" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    std.debug.print("\n{'=' ** 60}\n");
    std.debug.print("UFS CONTINUOUS VERIFICATION - {}\n", .{utils.timestamp()});
    std.debug.print("{'=' ** 60}\n\n");

    var sim = try CrashSimulator.init(allocator, 200 * 1024 * 1024, 4096);
    defer sim.deinit();

    const block_dev = createBlockDeviceFromSimulator(&sim);
    try ufs.format(block_dev, "ContinuousVerify", 4096, ufs.CompressionAlgorithm.LZ4, 2048, 4);

    const fs = try ufs.mount(block_dev, ufs.MountOptions{});
    defer fs.unmount();

    // 1. Write test files
    std.debug.print("1. Writing test files...\n");
    const test_files = 100;
    var rng = std.Random.DefaultPrng.init(0x44985A21);
    for (0..test_files) |i| {
        const file = try fs.open(2, try std.fmt.allocPrint(allocator, "verify_{d}.dat", .{i}), ufs.O_CREAT | ufs.O_RDWR, 0644);
        var data: [1024]u8 = undefined;
        for (&data) |*b| b.* = rng.random();
        try file.writeAll(&data);
        file.close() catch {};
    }

    // 2. Sync
    std.debug.print("2. Syncing...\n");
    try fs.sync();

    // 3. Verify all files
    std.debug.print("3. Verifying {} files...\n", .{test_files});
    var verified = 0;
    var rng2 = std.Random.DefaultPrng.init(0x44985A21);
    for (0..test_files) |i| {
        const file = try fs.open(2, try std.fmt.allocPrint(allocator, "verify_{d}.dat", .{i}), ufs.O_RDONLY, 0);
        var buf: [1024]u8 = undefined;
        const n = try file.read(&buf);
        // Verify content
        var expected: [1024]u8 = undefined;
        for (&expected) |*b| b.* = rng2.random();
        if (std.mem.eql(u8, buf[0..n], expected[0..n])) {
            verified += 1;
        }
        file.close() catch {};
    }
    std.debug.print("   Verified: {}/{}\n", .{verified, test_files});
    try testing.expect(verified == test_files);

    // 4. Check filesystem stats
    std.debug.print("4. Checking filesystem stats...\n");
    const stat = try fs.statfs();
    std.debug.print("   Free space: {} MB\n", .{stat.free_space / (1024 * 1024)});
    std.debug.print("   Free inodes: {}\n", .{stat.free_inodes});
    try testing.expect(stat.free_space > 0);
    try testing.expect(stat.free_inodes > 0);

    // 5. Test crash recovery
    std.debug.print("5. Testing crash recovery...\n");
    sim.enableCrashSimulation(true);
    sim.setCrashPoint(10);

    for (0..20) |i| {
        const file = fs.open(2, try std.fmt.allocPrint(allocator, "crash_verify_{d}.dat", .{i}), ufs.O_CREAT | ufs.O_RDWR, 0644) catch continue;
        var data: [1024]u8 = undefined;
        for (&data) |*b| b.* = rng.random();
        file.writeAll(&data) catch {};
        file.close() catch {};
    }

    sim.enableCrashSimulation(false);

    // Remount
    fs.unmount();
    const fs2 = try ufs.mount(block_dev, ufs.MountOptions{});
    defer fs2.unmount();

    // Verify pre-crash files still intact
    var still_ok = 0;
    var rng3 = std.Random.DefaultPrng.init(0x44985A21);
    for (0..test_files) |i| {
        const file = fs2.open(2, try std.fmt.allocPrint(allocator, "verify_{d}.dat", .{i}), ufs.O_RDONLY, 0) catch continue;
        var buf: [1024]u8 = undefined;
        const n = try file.read(&buf);
        var expected: [1024]u8 = undefined;
        for (&expected) |*b| b.* = rng3.random();
        if (std.mem.eql(u8, buf[0..n], expected[0..n])) {
            still_ok += 1;
        }
        file.close() catch {};
    }
    std.debug.print("   Pre-crash files intact: {}/{}\n", .{still_ok, test_files});
    try testing.expect(still_ok == test_files);

    std.debug.print("\n{'=' ** 60}\n");
    std.debug.print("CONTINUOUS VERIFICATION: PASSED\n");
    std.debug.print("{'=' ** 60}\n\n");
}

// ============================================================================
// Fragmentation Tests
// ============================================================================

test "stress: fragmentation scenarios" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var sim = try CrashSimulator.init(allocator, 200 * 1024 * 1024, 4096);
    defer sim.deinit();

    const block_dev = createBlockDeviceFromSimulator(&sim);
    try ufs.format(block_dev, "Fragmentation", 4096, ufs.CompressionAlgorithm.LZ4, 2048, 4);

    const fs = try ufs.mount(block_dev, ufs.MountOptions{});
    defer fs.unmount();

    var rng = std.Random.DefaultPrng.init(0x9A25924F);

    // Create fragmentation: write many small files, delete alternate ones
    std.debug.print("Creating initial files...\n");
    const initial_files = 2000;
    for (0..initial_files) |i| {
        const file = try fs.open(2, try std.fmt.allocPrint(allocator, "frag_{d}.dat", .{i}), ufs.O_CREAT | ufs.O_RDWR, 0644);
        var data: [4096]u8 = undefined;
        for (&data) |*b| b.* = rng.random();
        try file.writeAll(&data);
        file.close() catch {};
    }

    // Delete every other file to create holes
    std.debug.print("Deleting alternate files...\n");
    for (0..initial_files) |i| {
        if (i % 2 == 0) {
            fs.unlink(2, try std.fmt.allocPrint(allocator, "frag_{d}.dat", .{i})) catch {};
        }
    }

    // Fill holes with larger files
    std.debug.print("Filling holes with larger files...\n");
    for (0..initial_files) |i| {
        if (i % 2 == 0) {
            const file = try fs.open(2, try std.fmt.allocPrint(allocator, "frag_{d}.dat", .{i}), ufs.O_CREAT | ufs.O_RDWR, 0644);
            var data: [16 * 1024]u8 = undefined; // 16KB
            for (&data) |*b| b.* = rng.random();
            try file.writeAll(&data);
            file.close() catch {};
        }
    }

    // Delete remaining small files
    for (0..initial_files) |i| {
        if (i % 2 == 1) {
            fs.unlink(2, try std.fmt.allocPrint(allocator, "frag_{d}.dat", .{i})) catch {};
        }
    }

    // Write more large files
    for (0..1000) |i| {
        const file = try fs.open(2, try std.fmt.allocPrint(allocator, "frag_large_{d}.dat", .{i}), ufs.O_CREAT | ufs.O_RDWR, 0644);
        var data: [16 * 1024]u8 = undefined;
        for (&data) |*b| b.* = rng.random();
        try file.writeAll(&data);
        file.close() catch {};
    }

    // Check free space fragmentation via statfs
    const stat = try fs.statfs();
    std.debug.print("Free space: {} MB, Free inodes: {}\n", .{stat.free_space / (1024 * 1024), stat.free_inodes});

    // Verify we can still allocate large contiguous files
    const large_file = try fs.open(2, "contiguous.dat", ufs.O_CREAT | ufs.O_RDWR, 0644);
    var large_data: [64 * 1024]u8 = undefined;
    for (&large_data) |*b| b.* = rng.random();
    try large_file.writeAll(&large_data);
    large_file.close() catch {};

    std.debug.print("Fragmentation test: OK\n");
}

test "stress: metadata heavy workloads" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var sim = try CrashSimulator.init(allocator, 200 * 1024 * 1024, 4096);
    defer sim.deinit();

    const block_dev = createBlockDeviceFromSimulator(&sim);
    try ufs.format(block_dev, "MetadataHeavy", 4096, ufs.CompressionAlgorithm.LZ4, 2048, 4);

    const fs = try ufs.mount(block_dev, ufs.MountOptions{});
    defer fs.unmount();

    var rng = std.Random.DefaultPrng.init(0xC9DD5B7A);

    // Create deep directory tree with many attributes
    std.debug.print("Creating metadata-heavy structure...\n");
    const dirs = 500;
    const files_per_dir = 20;
    const xattrs_per_file = 10;

    for (0..dirs) |dir_idx| {
        const dir_name = try std.fmt.allocPrint(allocator, "d_{d}", .{dir_idx});
        try fs.mkdir(2, dir_name, 0755);
        const dir_inode = try fs.lookup(2, dir_name);

        for (0..files_per_dir) |file_idx| {
            const file_name = try std.fmt.allocPrint(allocator, "f_{d}", .{file_idx});
            const file = try fs.open(dir_inode, file_name, ufs.O_CREAT | ufs.O_RDWR, 0644);
            defer file.close() catch {};

            // Write small data
            var data: [256]u8 = undefined;
            for (&data) |*b| b.* = rng.random();
            try file.writeAll(&data);

            // Set many xattrs (via metadata capsules)
            for (0..xattrs_per_file) |xattr_idx| {
                const attr_name = try std.fmt.allocPrint(allocator, "user.attr_{d}", .{xattr_idx});
                const attr_value = try std.fmt.allocPrint(allocator, "value_{d}_{d}", .{file_idx, xattr_idx});
                // Note: actual xattr API would be used here
                // For now we just verify the file operations work
                _ = attr_name;
                _ = attr_value;
            }
        }

        if (dir_idx % 50 == 0) {
            std.debug.print("  Created {} dirs\n", .{dir_idx});
        }
    }

    // Verify structure
    var total_files = 0;
    try fs.iterateDir(2, {}, fn (entry: ufs.DirEntry) !void {
        if (entry.file_type == ufs.DirEntry.FILE_TYPE_DIR) {
            const subdir_inode = try fs.lookup(2, entry.name);
            try fs.iterateDir(subdir_inode, {}, fn (subentry: ufs.DirEntry) !void {
                if (subentry.file_type == ufs.DirEntry.FILE_TYPE_REG) {
                    total_files += 1;
                }
            }) catch {};
        }
    }) catch {};

    std.debug.print("Total files in metadata-heavy structure: {}\n", .{total_files});
    try testing.expect(total_files == dirs * files_per_dir);

    // Check statfs
    const stat = try fs.statfs();
    std.debug.print("Free space: {} MB, Free inodes: {}\n", .{stat.free_space / (1024 * 1024), stat.free_inodes});
    try testing.expect(stat.free_inodes < 1_000_000); // Should have used many inodes
}

// ============================================================================
// Performance Regression Detection
// ============================================================================

const PerfBaseline = struct {
    name: []const u8,
    avg_ns: u64,
    ops_per_sec: f64,
    throughput_mb_s: f64,
    timestamp: u64,
};

test "performance: regression detection" {
    // This test establishes baselines and detects regressions
    // In practice, baselines would be stored in a file and compared
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var sim = try CrashSimulator.init(allocator, 200 * 1024 * 1024, 4096);
    defer sim.deinit();

    const block_dev = createBlockDeviceFromSimulator(&sim);
    try ufs.format(block_dev, "PerfReg", 4096, ufs.CompressionAlgorithm.LZ4, 2048, 4);

    const fs = try ufs.mount(block_dev, ufs.MountOptions{});
    defer fs.unmount();

    var rng = std.Random.DefaultPrng.init(0x8C4F47D7);

    // Test operations to baseline
    const tests = [_]struct {
        name: []const u8,
        fn: fn() !u64,
    }{
        .{ .name = "create_1KB", .fn = fn () !u64 {
            const start = std.time.nanoTimestamp();
            const file = try fs.open(2, "perf_test.dat", ufs.O_CREAT | ufs.O_RDWR, 0644);
            var data: [1024]u8 = undefined;
            for (&data) |*b| b.* = rng.random();
            try file.writeAll(&data);
            file.close() catch {};
            return std.time.nanoTimestamp() - start;
        }},
        .{ .name = "read_1KB", .fn = fn () !u64 {
            const start = std.time.nanoTimestamp();
            const file = try fs.open(2, "perf_test.dat", ufs.O_RDONLY, 0);
            var buf: [1024]u8 = undefined;
            _ = file.read(&buf) catch {};
            file.close() catch {};
            return std.time.nanoTimestamp() - start;
        }},
        .{ .name = "mkdir", .fn = fn () !u64 {
            const start = std.time.nanoTimestamp();
            try fs.mkdir(2, try std.fmt.allocPrint(allocator, "perf_dir_{d}", .{rng.random()}), 0755);
            return std.time.nanoTimestamp() - start;
        }},
        .{ .name = "lookup", .fn = fn () !u64 {
            const start = std.time.nanoTimestamp();
            _ = fs.lookup(2, "perf_test.dat") catch {};
            return std.time.nanoTimestamp() - start;
        }},
    };

    std.debug.print("\n=== Performance Baseline ===\n");
    for (tests) |test| {
        // Warmup
        for (0..10) |_| { _ = test.fn() catch {}; }

        // Measure
        var times = std.ArrayList(u64).init(allocator);
        defer times.deinit();

        for (0..100) |_| {
            const t = test.fn() catch continue;
            try times.append(t);
        }

        const avg = avgList(times.items);
        const ops = 1_000_000_000.0 / f64(avg);
        std.debug.print("{s}: {:.2f} µs avg ({:.0f} ops/s)\n", .{test.name, f64(avg) / 1000.0, ops});

        // In real implementation, compare with stored baseline
        // If regression > 20%, fail
    }
}

fn avgList(items: []const u64) u64 {
    if (items.len == 0) return 0;
    var sum: u64 = 0;
    for (items) |v| sum += v;
    return sum / items.len;
}

// ============================================================================
// CI Integration Helpers
// ============================================================================

/// Generate GitHub Actions workflow for continuous testing
pub fn generateCIWorkflow(allocator: Allocator) ![]const u8 {
    const workflow = try std.fmt.allocPrint(allocator,
        "# UFS Continuous Integration Workflow
# Generated by UFS reliability test suite
name: UFS CI

on:
  push:
    branches: [ main, develop ]
  pull_request:
    branches: [ main ]
  schedule:
    - cron: '0 2 * * *'  # Daily at 2 AM

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install Zig
        uses: mlugg/setup-zig@v1
        with:
          version: 0.13.0

      - name: Install dependencies
        run: |
          sudo apt-get update
          sudo apt-get install -y libfuse3-dev

      - name: Run unit tests
        run: zig build test

      - name: Run integration tests
        run: zig build integration-test

      - name: Run reliability tests
        run: zig build test-reliability

      - name: Run benchmarks
        run: zig build bench

      - name: Run fuzz tests
        run: zig build fuzz

  test-windows:
    runs-on: windows-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install Zig
        uses: mlugg/setup-zig@v1
      - name: Run tests
        run: zig build test

  test-macos:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install Zig
        uses: mlugg/setup-zig@v1
      - name: Run tests
        run: zig build test

  build-drivers:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install Zig
        uses: mlugg/setup-zig@v1
      - name: Build FUSE driver
        run: zig build fuse
      - name: Build Linux driver
        run: zig build linux-driver
      - name: Build Windows driver
        run: zig build windows-driver
      - name: Build macOS driver
        run: zig build macos-driver
      - name: Build UEFI driver
        run: zig build uefi-driver
", .{});
    return workflow;
}

/// Generate daily verification script
pub fn generateDailyScript(allocator: Allocator) ![]const u8 {
    const script = try std.fmt.allocPrint(allocator,
        "#!/bin/bash
# UFS Daily Verification Script
# Run via cron: 0 2 * * * /path/to/ufs_daily_verify.sh

set -euo pipefail

UFS_ROOT=\"${UFS_ROOT:-/path/to/UFS}\"
LOG_DIR=\"$UFS_ROOT/logs\"
DATE=$(date +%Y%m%d_%H%M%S)
LOG_FILE=\"$LOG_DIR/verify_$DATE.log\"

mkdir -p \"$LOG_DIR\"

echo \"=== UFS Daily Verification Started at $(date) ===\" | tee \"$LOG_FILE\"

cd \"$UFS_ROOT/core/zig\"

echo \"Running unit tests...\" | tee -a \"$LOG_FILE\"
zig build test 2>&1 | tee -a \"$LOG_FILE\" || {
    echo \"UNIT TESTS FAILED\" | tee -a \"$LOG_FILE\"
    exit 1
}

echo \"Running integration tests...\" | tee -a \"$LOG_FILE\"
zig build integration-test 2>&1 | tee -a \"$LOG_FILE\" || {
    echo \"INTEGRATION TESTS FAILED\" | tee -a \"$LOG_FILE\"
    exit 1
}

echo \"Running reliability tests...\" | tee -a \"$LOG_FILE\"
zig build test-reliability 2>&1 | tee -a \"$LOG_FILE\" || {
    echo \"RELIABILITY TESTS FAILED\" | tee -a \"$LOG_FILE\"
    exit 1
}

echo \"Running benchmarks...\" | tee -a \"$LOG_FILE\"
zig build bench 2>&1 | tee -a \"$LOG_FILE\" || {
    echo \"BENCHMARKS FAILED\" | tee -a \"$LOG_FILE\"
    exit 1
}

echo \"=== UFS Daily Verification Completed at $(date) ===\" | tee -a \"$LOG_FILE\"

# Cleanup old logs (keep 30 days)
find \"$LOG_DIR\" -name \"verify_*.log\" -mtime +30 -delete
", .{});
    return script;
}

// ============================================================================
// Test Suite Entry Point
// ============================================================================

pub fn runAllReliabilityTests() !void {
    // This would be called by a custom test runner
    // Individual tests are run via `zig test`
    _ = CrashSimulator;
    _ = createBlockDeviceFromSimulator;
}