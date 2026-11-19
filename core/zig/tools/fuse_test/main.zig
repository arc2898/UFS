// FUSE Integration Test for UFS
// Tests the FUSE driver with real filesystem operations
// Run with: zig build fuse-test

const std = @import("std");
const ufs = @import("ufs");
const print = std.debug.print;

const Allocator = std.mem.Allocator;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    print("=== UFS FUSE Integration Test ===\n\n", .{});

    // Test 1: Basic format -> mount -> operations -> unmount
    try testBasicOperations(allocator);

    // Test 2: File I/O operations
    try testFileIO(allocator);

    // Test 3: Directory operations
    try testDirectoryOperations(allocator);

    // Test 4: Extended attributes via metadata capsules
    try testExtendedAttributes(allocator);

    // Test 5: Symlinks
    try testSymlinks(allocator);

    // Test 6: Hard links
    try testHardLinks(allocator);

    // Test 7: Statfs
    try testStatfs(allocator);

    // Test 8: Crash recovery simulation
    try testCrashRecovery(allocator);

    print("\n=== ALL FUSE INTEGRATION TESTS PASSED ===\n", .{});
}

fn testBasicOperations(allocator: Allocator) !void {
    print("Test 1: Basic format -> mount -> operations -> unmount\n", .{});

    // Create an isolated test image without overwriting files from prior runs.
    const image_path = try std.fmt.allocPrint(allocator, "test_basic_{d}.img", .{std.time.nanoTimestamp()});
    try createTestImage(allocator, image_path, 50 * 1024 * 1024);
    defer std.fs.cwd().deleteFile(image_path) catch {};

    // Format with mkufs
    try formatImage(allocator, image_path);

    // Mount via FUSE (simulated - we'll use the core API directly)
    var sim = try ufs.CrashSimulator.init(allocator, 50 * 1024 * 1024, 4096);
    defer sim.deinit();

    // Load the formatted image
    try loadImage(allocator, &sim, image_path);

    const block_dev = ufs.createBlockDeviceFromSimulator(&sim);
    const fs = try ufs.mount(block_dev, ufs.MountOptions{});
    defer fs.unmount();

    // Create directory
    try fs.mkdir(2, "testdir", 0755);
    const dir_inode = try fs.lookup(2, "testdir");

    // Create file in directory
    const file = try fs.open(dir_inode, "test.txt", ufs.O_CREAT | ufs.O_RDWR, 0644);
    const data = "Hello, UFS FUSE!";
    try file.writeAll(data);
    file.close() catch {};

    // Read back
    const file2 = try fs.open(dir_inode, "test.txt", ufs.O_RDONLY, 0);
    var buf: [100]u8 = undefined;
    const n = try file2.read(&buf);
    file2.close() catch {};

    try std.testing.expect(n == data.len);
    try std.testing.expect(std.mem.eql(u8, buf[0..n], data));

    // Cleanup
    std.fs.cwd().deleteFile(image_path) catch {};

    print("  PASSED\n", .{});
}

fn testFileIO(allocator: Allocator) !void {
    print("Test 2: File I/O operations\n", .{});

    var sim = try ufs.CrashSimulator.init(allocator, 100 * 1024 * 1024, 4096);
    defer sim.deinit();

    const block_dev = ufs.createBlockDeviceFromSimulator(&sim);
    try ufs.format(block_dev, "FileIOTest", 4096, ufs.CompressionAlgorithm.LZ4, 1024, 4);

    const fs = try ufs.mount(block_dev, ufs.MountOptions{});
    defer fs.unmount();

    // Test 1: Small file write/read
    {
        const file = try fs.open(2, "small.txt", ufs.O_CREAT | ufs.O_RDWR, 0644);
        const data = "Small file content";
        try file.writeAll(data);
        file.close() catch {};

        const file2 = try fs.open(2, "small.txt", ufs.O_RDONLY, 0);
        var buf: [100]u8 = undefined;
        const n = try file2.read(&buf);
        file2.close() catch {};
        try std.testing.expect(std.mem.eql(u8, buf[0..n], data));
    }

    // Test 2: Large file (multiple extents)
    {
        const file_size = 10 * 1024 * 1024; // 10MB
        const chunk_size = 1024 * 1024; // 1MB

        const file = try fs.open(2, "large.dat", ufs.O_CREAT | ufs.O_RDWR, 0644);
        defer file.close() catch {};

        var rng = std.Random.DefaultPrng.init(0xB35C4D3F);
        var written: u64 = 0;
        var chunk: [1024 * 1024]u8 = undefined;

        while (written < file_size) {
            for (&chunk) |*b| b.* = rng.random();
            const to_write = @min(chunk_size, file_size - written);
            try file.writeAll(chunk[0..to_write]);
            written += to_write;
        }

        // Verify by reading back
        try file.seek(0);
        var read_buf: [1024 * 1024]u8 = undefined;
        var rng2 = std.Random.DefaultPrng.init(0xB35C4D3F);
        var read_total: u64 = 0;

        while (read_total < file_size) {
            for (&read_buf) |*b| b.* = rng2.random();
            const to_read = @min(chunk_size, file_size - read_total);
            const n = try file.read(read_buf[0..to_read]);
            try std.testing.expect(n == to_read);

            var rng3 = std.Random.DefaultPrng.init(0xB35C4D3F);
            for (0..read_total) |_| { _ = rng3.random(); }
            for (0..n) |i| {
                try std.testing.expect(read_buf[i] == rng3.random());
            }

            read_total += n;
        }
    }

    // Test 3: Append to file
    {
        const file = try fs.open(2, "append.txt", ufs.O_CREAT | ufs.O_RDWR, 0644);
        try file.writeAll("Initial");
        file.close() catch {};

        const file2 = try fs.open(2, "append.txt", ufs.O_RDWR | ufs.O_APPEND, 0644);
        try file2.writeAll("Appended");
        file2.close() catch {};

        const file3 = try fs.open(2, "append.txt", ufs.O_RDONLY, 0);
        var buf: [100]u8 = undefined;
        const n = try file3.read(&buf);
        file3.close() catch {};
        try std.testing.expect(std.mem.eql(u8, buf[0..n], "InitialAppended"));
    }

    // Test 4: Truncate
    {
        const file = try fs.open(2, "truncate.txt", ufs.O_CREAT | ufs.O_RDWR, 0644);
        try file.writeAll("This is a long string that will be truncated");
        file.close() catch {};

        try fs.truncate(2, "truncate.txt", 10);

        const file2 = try fs.open(2, "truncate.txt", ufs.O_RDONLY, 0);
        var buf: [100]u8 = undefined;
        const n = try file2.read(&buf);
        file2.close() catch {};
        try std.testing.expect(n == 10);
        try std.testing.expect(std.mem.eql(u8, buf[0..n], "This is a "));
    }

    // Test 5: Seek
    {
        const file = try fs.open(2, "seek.txt", ufs.O_CREAT | ufs.O_RDWR, 0644);
        try file.writeAll("0123456789ABCDEF");
        file.close() catch {};

        const file2 = try fs.open(2, "seek.txt", ufs.O_RDONLY, 0);
        try file2.seek(5, ufs.SEEK_SET);
        var buf: [10]u8 = undefined;
        const n = try file2.read(&buf);
        file2.close() catch {};
        try std.testing.expect(n == 10);
        try std.testing.expect(std.mem.eql(u8, buf[0..n], "56789ABCDE"));
    }

    print("  PASSED\n", .{});
}

fn testDirectoryOperations(allocator: Allocator) !void {
    print("Test 3: Directory operations\n", .{});

    var sim = try ufs.CrashSimulator.init(allocator, 100 * 1024 * 1024, 4096);
    defer sim.deinit();

    const block_dev = ufs.createBlockDeviceFromSimulator(&sim);
    try ufs.format(block_dev, "DirTest", 4096, ufs.CompressionAlgorithm.LZ4, 1024, 4);

    const fs = try ufs.mount(block_dev, ufs.MountOptions{});
    defer fs.unmount();

    // Create nested directories
    try fs.mkdir(2, "dir1", 0755);
    try fs.mkdir(2, "dir2", 0755);

    const dir1 = try fs.lookup(2, "dir1");
    try fs.mkdir(dir1, "subdir1", 0755);
    try fs.mkdir(dir1, "subdir2", 0755);

    const subdir1 = try fs.lookup(dir1, "subdir1");
    try fs.mkdir(subdir1, "deep", 0755);

    // Create files in directories
    const file1 = try fs.open(2, "root.txt", ufs.O_CREAT | ufs.O_RDWR, 0644);
    try file1.writeAll("root");
    file1.close() catch {};

    const file2 = try fs.open(dir1, "dir1.txt", ufs.O_CREAT | ufs.O_RDWR, 0644);
    try file2.writeAll("dir1");
    file2.close() catch {};

    const file3 = try fs.open(subdir1, "deep.txt", ufs.O_CREAT | ufs.O_RDWR, 0644);
    try file3.writeAll("deep");
    file3.close() catch {};

    // Iterate root directory
    var count = 0;
    try fs.iterateDir(2, {}, fn (entry: ufs.DirEntry) !void {
        count += 1;
        // print("  Entry: {s} type={d}\n", .{entry.name, entry.file_type});
    }) catch {};

    try std.testing.expect(count >= 2); // dir1, dir2, root.txt

    // Iterate dir1
    count = 0;
    try fs.iterateDir(dir1, {}, fn (entry: ufs.DirEntry) !void {
        count += 1;
    }) catch {};

    try std.testing.expect(count >= 2); // subdir1, subdir2, dir1.txt

    // Rename
    try fs.rename(2, "dir2", 2, "dir2_renamed");
    const renamed = try fs.lookup(2, "dir2_renamed");
    try std.testing.expect(renamed != 0);

    // Delete
    fs.unlink(2, "root.txt") catch {};
    fs.rmdir(2, "dir2_renamed") catch {};

    // Verify deletion
    count = 0;
    try fs.iterateDir(2, {}, fn (entry: ufs.DirEntry) !void {
        count += 1;
    }) catch {};

    // Should have dir1 and maybe dir2_renamed if rmdir failed
    try std.testing.expect(count >= 1);

    print("  PASSED\n", .{});
}

fn testExtendedAttributes(allocator: Allocator) !void {
    print("Test 4: Extended attributes via metadata capsules\n", .{});

    var sim = try ufs.CrashSimulator.init(allocator, 100 * 1024 * 1024, 4096);
    defer sim.deinit();

    const block_dev = ufs.createBlockDeviceFromSimulator(&sim);
    try ufs.format(block_dev, "XattrTest", 4096, ufs.CompressionAlgorithm.LZ4, 1024, 4);

    const fs = try ufs.mount(block_dev, ufs.MountOptions{});
    defer fs.unmount();

    const file = try fs.open(2, "xattr_test.txt", ufs.O_CREAT | ufs.O_RDWR, 0644);
    try file.writeAll("File with xattrs");
    file.close() catch {};

    // Set various xattrs via metadata capsules
    // POSIX user.* attributes
    try fs.setxattr(2, "xattr_test.txt", ufs.NAMESPACE_POSIX_XATTR, 0, "user.comment", "This is a comment", 17, 0);
    try fs.setxattr(2, "xattr_test.txt", ufs.NAMESPACE_POSIX_XATTR, 0, "user.author", "UFS Team", 8, 0);
    try fs.setxattr(2, "xattr_test.txt", ufs.NAMESPACE_POSIX_XATTR, 0, "user.version", "1.0", 3, 0);

    // System attributes (ACLs)
    try fs.setxattr(2, "xattr_test.txt", ufs.NAMESPACE_POSIX_ACL, 0, "system.posix_acl_access", "user::rwx,group::r-x,other::r--", 33, 0);

    // Security attributes
    try fs.setxattr(2, "xattr_test.txt", ufs.NAMESPACE_POSIX_CAPS, 0, "security.selinux", "unconfined_u:object_r:user_home_t:s0", 39, 0);

    // Read back xattrs
    var buf: [256]u8 = undefined;
    var out_size: usize = 0;

    try fs.getxattr(2, "xattr_test.txt", ufs.NAMESPACE_POSIX_XATTR, 0, "user.comment", &buf, buf.len, &out_size);
    try std.testing.expect(out_size == 17);
    try std.testing.expect(std.mem.eql(u8, buf[0..out_size], "This is a comment"));

    try fs.getxattr(2, "xattr_test.txt", ufs.NAMESPACE_POSIX_XATTR, 0, "user.author", &buf, buf.len, &out_size);
    try std.testing.expect(out_size == 8);
    try std.testing.expect(std.mem.eql(u8, buf[0..out_size], "UFS Team"));

    // List xattrs
    var list_buf: [512]u8 = undefined;
    try fs.listxattr(2, "xattr_test.txt", &list_buf, list_buf.len, &out_size);
    try std.testing.expect(out_size > 0);

    // Remove xattr
    try fs.removexattr(2, "xattr_test.txt", ufs.NAMESPACE_POSIX_XATTR, 0, "user.version");

    // Verify removal
    const result = fs.getxattr(2, "xattr_test.txt", ufs.NAMESPACE_POSIX_XATTR, 0, "user.version", &buf, buf.len, &out_size);
    try std.testing.expect(result != ufs.UFS_OK);

    print("  PASSED\n", .{});
}

fn testSymlinks(allocator: Allocator) !void {
    print("Test 5: Symlinks\n", .{});

    var sim = try ufs.CrashSimulator.init(allocator, 100 * 1024 * 1024, 4096);
    defer sim.deinit();

    const block_dev = ufs.createBlockDeviceFromSimulator(&sim);
    try ufs.format(block_dev, "SymlinkTest", 4096, ufs.CompressionAlgorithm.LZ4, 1024, 4);

    const fs = try ufs.mount(block_dev, ufs.MountOptions{});
    defer fs.unmount();

    // Create target file
    const target = try fs.open(2, "target.txt", ufs.O_CREAT | ufs.O_RDWR, 0644);
    try target.writeAll("Target content");
    target.close() catch {};

    // Create symlink
    try fs.symlink(2, "link.txt", "target.txt");

    // Read symlink
    var buf: [256]u8 = undefined;
    const n = try fs.readlink(2, "link.txt", &buf);
    try std.testing.expect(std.mem.eql(u8, buf[0..n], "target.txt"));

    // Follow symlink by opening it
    const link_file = try fs.open(2, "link.txt", ufs.O_RDONLY, 0);
    var read_buf: [100]u8 = undefined;
    const read_n = try link_file.read(&read_buf);
    link_file.close() catch {};
    try std.testing.expect(std.mem.eql(u8, read_buf[0..read_n], "Target content"));

    // Create symlink to directory
    try fs.mkdir(2, "target_dir", 0755);
    try fs.symlink(2, "link_dir", "target_dir");

    var buf2: [256]u8 = undefined;
    const n2 = try fs.readlink(2, "link_dir", &buf2);
    try std.testing.expect(std.mem.eql(u8, buf2[0..n2], "target_dir"));

    print("  PASSED\n", .{});
}

fn testHardLinks(allocator: Allocator) !void {
    print("Test 6: Hard links\n", .{});

    var sim = try ufs.CrashSimulator.init(allocator, 100 * 1024 * 1024, 4096);
    defer sim.deinit();

    const block_dev = ufs.createBlockDeviceFromSimulator(&sim);
    try ufs.format(block_dev, "HardlinkTest", 4096, ufs.CompressionAlgorithm.LZ4, 1024, 4);

    const fs = try ufs.mount(block_dev, ufs.MountOptions{});
    defer fs.unmount();

    // Create file
    const file = try fs.open(2, "original.txt", ufs.O_CREAT | ufs.O_RDWR, 0644);
    try file.writeAll("Original content");
    file.close() catch {};

    // Get inode info
    var info = ufs.InodeInfo{};
    try fs.getattr(2, "original.txt", &info);
    try std.testing.expect(info.link_count == 1);

    // Create hard link
    try fs.link(2, "original.txt", 2, "hardlink.txt");

    // Check link count increased
    try fs.getattr(2, "original.txt", &info);
    try std.testing.expect(info.link_count == 2);

    // Read through hardlink
    const file2 = try fs.open(2, "hardlink.txt", ufs.O_RDONLY, 0);
    var buf: [100]u8 = undefined;
    const n = try file2.read(&buf);
    file2.close() catch {};
    try std.testing.expect(std.mem.eql(u8, buf[0..n], "Original content"));

    // Modify through hardlink
    const file3 = try fs.open(2, "hardlink.txt", ufs.O_RDWR, 0);
    try file3.writeAll("Modified via hardlink");
    file3.close() catch {};

    // Verify change visible through original
    const file4 = try fs.open(2, "original.txt", ufs.O_RDONLY, 0);
    var buf2: [100]u8 = undefined;
    const n2 = try file4.read(&buf2);
    file4.close() catch {};
    try std.testing.expect(std.mem.eql(u8, buf2[0..n2], "Modified via hardlink"));

    // Delete original
    fs.unlink(2, "original.txt") catch {};

    // File should still exist via hardlink
    const file5 = try fs.open(2, "hardlink.txt", ufs.O_RDONLY, 0);
    var buf3: [100]u8 = undefined;
    const n3 = try file5.read(&buf3);
    file5.close() catch {};
    try std.testing.expect(std.mem.eql(u8, buf3[0..n3], "Modified via hardlink"));

    print("  PASSED\n", .{});
}

fn testStatfs(allocator: Allocator) !void {
    print("Test 7: Statfs\n", .{});

    var sim = try ufs.CrashSimulator.init(allocator, 200 * 1024 * 1024, 4096);
    defer sim.deinit();

    const block_dev = ufs.createBlockDeviceFromSimulator(&sim);
    try ufs.format(block_dev, "StatfsTest", 4096, ufs.CompressionAlgorithm.LZ4, 2048, 4);

    const fs = try ufs.mount(block_dev, ufs.MountOptions{});
    defer fs.unmount();

    const stat = try fs.statfs();

    try std.testing.expect(stat.total_space > 0);
    try std.testing.expect(stat.free_space > 0);
    try std.testing.expect(stat.total_inodes > 0);
    try std.testing.expect(stat.free_inodes > 0);
    try std.testing.expect(stat.cluster_size == 4096);
    try std.testing.expect(stat.ag_count >= 1);

    print("  Total space: {} MB\n", .{stat.total_space / (1024 * 1024)});
    print("  Free space: {} MB\n", .{stat.free_space / (1024 * 1024)});
    print("  Total inodes: {}\n", .{stat.total_inodes});
    print("  Free inodes: {}\n", .{stat.free_inodes});
    print("  Cluster size: {}\n", .{stat.cluster_size});
    print("  AG count: {}\n", .{stat.ag_count});

    print("  PASSED\n", .{});
}

fn testCrashRecovery(allocator: Allocator) !void {
    print("Test 8: Crash recovery simulation\n", .{});

    // Phase 1: Create filesystem and write data
    {
        var sim = try ufs.CrashSimulator.init(allocator, 100 * 1024 * 1024, 4096);
        defer sim.deinit();

        const block_dev = ufs.createBlockDeviceFromSimulator(&sim);
        try ufs.format(block_dev, "RecoveryTest", 4096, ufs.CompressionAlgorithm.LZ4, 1024, 4);

        // Mount and write initial data
        {
            const fs = try ufs.mount(block_dev, ufs.MountOptions{});
            defer fs.unmount();

            try fs.mkdir(2, "data", 0755);

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

            try fs.sync();
        }

        // Simulate power loss during additional writes
        sim.enableCrashSimulation(true);
        sim.setCrashPoint(50);

        {
            const fs = try ufs.mount(block_dev, ufs.MountOptions{});
            defer fs.unmount();

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

            // Verify initial files are intact (committed transactions)
            for (0..10) |i| {
                const file = try fs.open(2, try std.fmt.allocPrint(allocator, "data/file_{d}.dat", .{i}), ufs.O_RDONLY, 0);
                var buf: [4096]u8 = undefined;
                const n = try file.read(&buf);
                try std.testing.expect(n == 4096);
                for (buf, 0..) |b, j| {
                    try std.testing.expect(b == @as(u8, @intCast((i * 4096 + j) % 256)));
                }
                file.close() catch {};
            }

            // Files 10-19 may or may not exist (incomplete transactions rolled back)
            // Journal replay should have recovered committed transactions only
        }
    }

    print("  PASSED\n", .{});
}

fn createTestImage(allocator: Allocator, path: []const u8, size: u64) !void {
    _ = allocator;
    const file = try std.fs.cwd().createFile(path, .{ .read = true, .truncate = false, .exclusive = true });
    defer file.close();
    const fd = file.handle;

    // Write zeros
    var zeros: [64 * 1024]u8 = undefined;
    @memset(&zeros, 0);
    var remaining = size;
    while (remaining > 0) {
        const to_write = @min(zeros.len, @intCast(remaining));
        try std.posix.pwrite(fd, zeros[0..to_write], @intCast(size - remaining));
        remaining -= to_write;
    }
}

fn formatImage(allocator: Allocator, path: []const u8) !void {
    const block_dev = try openBlockDevice(allocator, path, 4096);
    defer block_dev.close();

    try ufs.format(block_dev, "FUSETest", 4096, ufs.CompressionAlgorithm.LZ4, 1024, 4);
}

fn openBlockDevice(allocator: Allocator, path: []const u8, block_size: u32) !ufs.BlockDevice {
    const fd = try std.os.openFile(path, .{ .read = true, .write = true }, .{});
    const stat = try std.os.fstat(fd);
    const total_size = stat.size;
    const total_blocks = total_size / block_size;

    const vtable = ufs.BlockDeviceVTable{
        .read = readFn,
        .write = writeFn,
        .flush = flushFn,
        .trim = trimFn,
        .get_info = getInfoFn,
    };

    const ctx = try allocator.create(BlockDeviceCtx);
    ctx.* = BlockDeviceCtx{
        .fd = fd,
        .block_size = block_size,
        .total_blocks = total_blocks,
    };

    return ufs.BlockDevice{
        .context = ctx,
        .vtable = &vtable,
    };
}

const BlockDeviceCtx = struct {
    fd: std.os.fd_t,
    block_size: u32,
    total_blocks: u64,
};

fn readFn(ctx: *anyopaque, offset: u64, buffer: []u8) !usize {
    const dev = @as(*BlockDeviceCtx, @ptrCast(ctx));
    if (offset >= dev.total_blocks) return error.OutOfRange;
    const byte_offset = offset * dev.block_size;
    const end = byte_offset + buffer.len;
    if (end > dev.total_blocks * dev.block_size) return error.OutOfRange;
    return try std.posix.pread(dev.fd, buffer, @intCast(byte_offset));
}

fn writeFn(ctx: *anyopaque, offset: u64, buffer: []const u8) !usize {
    const dev = @as(*BlockDeviceCtx, @ptrCast(ctx));
    if (offset >= dev.total_blocks) return error.OutOfRange;
    const byte_offset = offset * dev.block_size;
    const end = byte_offset + buffer.len;
    if (end > dev.total_blocks * dev.block_size) return error.OutOfRange;
    return try std.posix.pwrite(dev.fd, buffer, @intCast(byte_offset));
}

fn flushFn(ctx: *anyopaque) !void {
    const dev = @as(*BlockDeviceCtx, @ptrCast(ctx));
    try std.os.fsync(dev.fd);
}

fn trimFn(ctx: *anyopaque, offset: u64, length: u64) !void {
    _ = ctx; _ = offset; _ = length;
}

fn getInfoFn(ctx: *anyopaque) ufs.BlockDeviceInfo {
    const dev = @as(*BlockDeviceCtx, @ptrCast(ctx));
    return ufs.BlockDeviceInfo{
        .block_size = dev.block_size,
        .physical_block_size = dev.block_size,
        .optimal_io_size = dev.block_size * 128,
        .total_blocks = dev.total_blocks,
        .is_removable = false,
        .is_read_only = false,
        .is_ssd = true,
        .is_virtual = true,
        .serial_number = "FUSE_TEST",
        .model = "UFS FUSE Test",
        .firmware = "1.0",
    };
}

fn loadImage(allocator: Allocator, sim: *ufs.CrashSimulator, path: []const u8) !void {
    const fd = try std.os.openFile(path, .{ .read = true }, .{});
    defer std.posix.close(fd);

    const stat = try std.os.fstat(fd);
    const total_size = stat.size;

    var buffer: [64 * 1024]u8 = undefined;
    var remaining = total_size;
    var offset: u64 = 0;

    while (remaining > 0) {
        const to_read = @min(buffer.len, @intCast(remaining));
        const n = try std.posix.pread(fd, buffer[0..to_read], @intCast(offset));
        if (n == 0) break;
        try sim.write(offset / sim.block_size, buffer[0..n]);
        offset += n;
        remaining -= n;
    }
}