// mkufs - UFS Volume Formatter
// Creates a new UFS filesystem on a block device or file

const std = @import("std");
const ufs = @import("ufs");

const Allocator = std.mem.Allocator;
const print = std.debug.print;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = std.process.argsAlloc(allocator) catch {
        print("Failed to allocate args\n", .{});
        return error.OutOfMemory;
    };
    defer std.process.argsFree(allocator, args);

    try parseAndRun(allocator, args);
}

fn parseAndRun(allocator: Allocator, args: [][]const u8) !void {
    if (args.len < 2) {
        printUsage(args[0] orelse "mkufs");
        return;
    }

    const device_path = args[1];

    // Default options
    var options = FormatOptions{
        .label = "",
        .uuid = null,
        .cluster_size = ufs.DEFAULT_CLUSTER_SIZE,
        .compression = ufs.COMPRESSION_LZ4,
        .journal_size_clusters = 0, // auto
        .ag_count = 0, // auto
        .force = false,
        .verbose = false,
        .dry_run = false,
        .block_size = 0, // auto-detect
    };

    var i: usize = 2;
    while (i < args.len) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printUsage(args[0] orelse "mkufs");
            return;
        } else if (std.mem.eql(u8, arg, "-L") or std.mem.eql(u8, arg, "--label")) {
            i += 1;
            if (i >= args.len) return error.InvalidArgument;
            options.label = args[i];
        } else if (std.mem.eql(u8, arg, "-U") or std.mem.eql(u8, arg, "--uuid")) {
            i += 1;
            if (i >= args.len) return error.InvalidArgument;
            options.uuid = try parseUUID(allocator, args[i]);
        } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--cluster-size")) {
            i += 1;
            if (i >= args.len) return error.InvalidArgument;
            options.cluster_size = try parseSize(args[i]);
        } else if (std.mem.eql(u8, arg, "--compression")) {
            i += 1;
            if (i >= args.len) return error.InvalidArgument;
            options.compression = try parseCompression(args[i]);
        } else if (std.mem.eql(u8, arg, "-J") or std.mem.eql(u8, arg, "--journal-size")) {
            i += 1;
            if (i >= args.len) return error.InvalidArgument;
            options.journal_size_clusters = try parseSize(args[i]);
        } else if (std.mem.eql(u8, arg, "-A") or std.mem.eql(u8, arg, "--ag-count")) {
            i += 1;
            if (i >= args.len) return error.InvalidArgument;
            options.ag_count = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--force")) {
            options.force = true;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            options.verbose = true;
        } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--dry-run")) {
            options.dry_run = true;
        } else if (std.mem.eql(u8, arg, "-b") or std.mem.eql(u8, arg, "--block-size")) {
            i += 1;
            if (i >= args.len) return error.InvalidArgument;
            options.block_size = try parseSize(args[i]);
        } else {
            print("Unknown option: {s}\n", .{arg});
            printUsage(args[0] orelse "mkufs");
            return error.InvalidArgument;
        }
        i += 1;
    }

    // Validate options
    try validateOptions(options);

    if (options.verbose) {
        printOptions(options);
    }

    if (options.dry_run) {
        print("DRY RUN: Would format {s} with options:\n", .{device_path});
        printOptions(options);
        return;
    }

    // Confirm if not forced
    if (!options.force && !try confirmFormat(device_path, options)) {
        print("Aborted.\n", .{});
        return;
    }

    // Open block device
    const block_dev = try openBlockDevice(allocator, device_path, options.block_size);
    defer block_dev.close();

    // Get device info
    const info = block_dev.get_info();
    if (options.verbose) {
        print("Device: {s} ({d} bytes, {d} blocks of {d} bytes)\n", .{device_path, info.total_blocks * info.block_size, info.total_blocks, info.block_size});
    }

    // Format the volume
    try formatVolume(allocator, block_dev, options, info);

    print("Successfully formatted {s} as UFS v1.0\n", .{device_path});
}

const FormatOptions = struct {
    label: []const u8,
    uuid: ?[16]u8,
    cluster_size: u32,
    compression: u8,
    journal_size_clusters: u64,
    ag_count: u32,
    force: bool,
    verbose: bool,
    dry_run: bool,
    block_size: u32,
};

fn printUsage(program: []const u8) void {
    print("Usage: {s} <device> [options]\n\n", .{program});
    print("Options:\n", .{});
    print("  -L, --label <label>          Volume label (max 255 chars)\n", .{});
    print("  -U, --uuid <uuid>            Volume UUID (UUIDv4 or UUIDv7 format)\n", .{});
    print("  -c, --cluster-size <size>    Cluster size in bytes (512, 1k, 2k, 4k, 8k, 16k, 32k, 64k)\n", .{});
    print("  --compression <algo>         Compression: none, lz4, zstd, zstd-high (default: lz4)\n", .{});
    print("  -J, --journal-size <size>    Journal size in clusters (default: auto)\n", .{});
    print("  -A, --ag-count <count>       Number of allocation groups (default: auto)\n", .{});
    print("  -b, --block-size <size>      Physical block size (default: auto-detect)\n", .{});
    print("  -f, --force                  Force format without confirmation\n", .{});
    print("  -v, --verbose                Verbose output\n", .{});
    print("  -n, --dry-run                Show what would be done without writing\n", .{});
    print("  -h, --help                   Show this help\n", .{});
    print("\nExamples:\n", .{});
    print("  {s} /dev/sdb1 -L \"MyVolume\" -c 4k\n", .{program});
    print("  {s} ufs.img -L \"Test\" --compression zstd -J 128M\n", .{program});
    print("  {s} /dev/nvme0n1 -f -v\n", .{program});
}

fn parseSize(s: []const u8) !u64 {
    const lower = std.ascii.toLower(s);
    var multiplier: u64 = 1;
    var num_str = lower;

    if (std.mem.endsWith(u8, lower, "k") or std.mem.endsWith(u8, lower, "kb")) {
        multiplier = 1024;
        num_str = lower[0..lower.len - 1];
        if (std.mem.endsWith(u8, num_str, "b")) num_str = num_str[0..num_str.len - 1];
    } else if (std.mem.endsWith(u8, lower, "m") or std.mem.endsWith(u8, lower, "mb")) {
        multiplier = 1024 * 1024;
        num_str = lower[0..lower.len - 1];
        if (std.mem.endsWith(u8, num_str, "b")) num_str = num_str[0..num_str.len - 1];
    } else if (std.mem.endsWith(u8, lower, "g") or std.mem.endsWith(u8, lower, "gb")) {
        multiplier = 1024 * 1024 * 1024;
        num_str = lower[0..lower.len - 1];
        if (std.mem.endsWith(u8, num_str, "b")) num_str = num_str[0..num_str.len - 1];
    }

    const num = try std.fmt.parseInt(u64, num_str, 10);
    return num * multiplier;
}

fn parseCompression(s: []const u8) !u8 {
    const lower = std.ascii.toLower(s);
    if (std.mem.eql(u8, lower, "none")) return ufs.COMPRESSION_NONE;
    if (std.mem.eql(u8, lower, "lz4")) return ufs.COMPRESSION_LZ4;
    if (std.mem.eql(u8, lower, "zstd")) return ufs.COMPRESSION_ZSTD;
    if (std.mem.eql(u8, lower, "zstd-high")) return ufs.COMPRESSION_ZSTD_HIGH;
    return error.InvalidArgument;
}

fn parseUUID(allocator: Allocator, s: []const u8) ![16]u8 {
    // Simple UUID parsing - supports standard format with or without hyphens
    var uuid: [16]u8 = undefined;
    var cleaned: [32]u8 = undefined;
    var ci: usize = 0;

    for (s) |c| {
        if (c != '-' && ci < 32) {
            cleaned[ci] = c;
            ci += 1;
        }
    }

    if (ci != 32) return error.InvalidArgument;

    for (0..16) |i| {
        const hex = cleaned[i*2..i*2+2];
        uuid[i] = try std.fmt.parseInt(u8, hex, 16);
    }

    return uuid;
}

fn validateOptions(options: FormatOptions) !void {
    // Cluster size must be power of 2 between 512 and 65536
    if (options.cluster_size < 512 or options.cluster_size > 65536) {
        return error.InvalidArgument;
    }
    if (options.cluster_size & (options.cluster_size - 1) != 0) {
        return error.InvalidArgument;
    }

    // Compression must be valid
    if (options.compression > ufs.COMPRESSION_ZSTD_HIGH) {
        return error.InvalidArgument;
    }

    // Label length
    if (options.label.len > 255) {
        return error.InvalidArgument;
    }
}

fn printOptions(options: FormatOptions) void {
    print("  Label: {s}\n", .{if (options.label.len > 0) options.label else "<none>"});
    if (options.uuid) |uuid| {
        print("  UUID: {02x}{02x}{02x}{02x}-{02x}{02x}-{02x}{02x}-{02x}{02x}-{02x}{02x}{02x}{02x}{02x}{02x}\n", .{
            uuid[0], uuid[1], uuid[2], uuid[3], uuid[4], uuid[5], uuid[6], uuid[7],
            uuid[8], uuid[9], uuid[10], uuid[11], uuid[12], uuid[13], uuid[14], uuid[15]
        });
    }
    print("  Cluster size: {d} bytes\n", .{options.cluster_size});
    print("  Compression: {s}\n", .{compressionToString(options.compression)});
    print("  Journal size: {s}\n", .{if (options.journal_size_clusters > 0) @as([]const u8, @intToStr(options.journal_size_clusters)) else "auto"});
    print("  AG count: {s}\n", .{if (options.ag_count > 0) @as([]const u8, @intToStr(options.ag_count)) else "auto"});
}

fn compressionToString(c: u8) []const u8 {
    return switch (c) {
        ufs.COMPRESSION_NONE => "none",
        ufs.COMPRESSION_LZ4 => "lz4",
        ufs.COMPRESSION_ZSTD => "zstd",
        ufs.COMPRESSION_ZSTD_HIGH => "zstd-high",
        else => "unknown",
    };
}

fn confirmFormat(device_path: []const u8, options: FormatOptions) !bool {
    const stderr = std.io.getStdErr().writer();
    try stderr.print("WARNING: This will DESTROY all data on {s}!\n", .{device_path});
    try stderr.print("Options: label={s}, cluster={d}, compression={s}\n", .{
        if (options.label.len > 0) options.label else "<none>",
        options.cluster_size,
        compressionToString(options.compression)
    });
    try stderr.print("Type 'YES' to confirm: ");

    var buf: [16]u8 = undefined;
    const stdin = std.io.getStdIn().reader();
    const n = try stdin.readUntilDelimiterOrEof(&buf, '\n');
    const input = std.mem.trim(u8, buf[0..n], "\r\n");

    return std.mem.eql(u8, input, "YES");
}

// Block device abstraction for mkufs
const BlockDevice = struct {
    fd: std.os.fd_t,
    path: []const u8,
    block_size: u32,
    total_blocks: u64,
    is_ssd: bool,

    fn open(allocator: Allocator, path: []const u8, preferred_block_size: u32) !BlockDevice {
        const fd = try std.os.openFile(path, .{ .read = true, .write = true, .create = true, .truncate = false }, .{});

        // Get file/device size
        const stat = try std.os.fstat(fd);
        const total_size = stat.size;

        // Determine block size
        var block_size = preferred_block_size;
        if (block_size == 0) {
            // Try to get physical block size from device
            block_size = 4096; // default
        }

        const total_blocks = total_size / block_size;

        return BlockDevice{
            .fd = fd,
            .path = path,
            .block_size = block_size,
            .total_blocks = total_blocks,
            .is_ssd = false, // TODO: detect SSD
        };
    }

    fn close(self: BlockDevice) void {
        std.posix.close(self.fd);
    }

    fn read(self: BlockDevice, offset: u64, buffer: []u8) !usize {
        return try std.posix.pread(self.fd, buffer, @intCast(offset * self.block_size));
    }

    fn write(self: BlockDevice, offset: u64, buffer: []const u8) !usize {
        return try std.posix.pwrite(self.fd, buffer, @intCast(offset * self.block_size));
    }

    fn flush(self: BlockDevice) !void {
        try std.os.fsync(self.fd);
    }

    fn get_info(self: BlockDevice) DeviceInfo {
        return DeviceInfo{
            .block_size = self.block_size,
            .physical_block_size = self.block_size,
            .optimal_io_size = self.block_size * 128,
            .total_blocks = self.total_blocks,
            .is_removable = false,
            .is_read_only = false,
            .is_ssd = self.is_ssd,
            .is_virtual = false,
            .serial_number = "",
            .model = "",
            .firmware = "",
        };
    }
};

const DeviceInfo = struct {
    block_size: u32,
    physical_block_size: u32,
    optimal_io_size: u32,
    total_blocks: u64,
    is_removable: bool,
    is_read_only: bool,
    is_ssd: bool,
    is_virtual: bool,
    serial_number: []const u8,
    model: []const u8,
    firmware: []const u8,
};

// Format the volume with UFS structures
fn formatVolume(allocator: Allocator, dev: BlockDevice, options: FormatOptions, info: DeviceInfo) !void {
    const cluster_size = options.cluster_size;
    const total_clusters = info.total_blocks * (info.block_size / cluster_size);

    if (options.verbose) {
        print("Total clusters: {d}\n", .{total_clusters});
    }

    // Calculate layout
    const layout = try calculateLayout(total_clusters, cluster_size, options);

    if (options.verbose) {
        printLayout(layout);
    }

    // Write superblock (primary)
    try writeSuperblock(allocator, dev, layout, options, 0);

    // Write backup superblocks
    for (layout.backup_superblock_locations) |loc| {
        try writeSuperblock(allocator, dev, layout, options, loc);
    }

    // Write allocation groups
    for (layout.ags.items) |ag| {
        try writeAllocationGroup(allocator, dev, layout, ag, options);
    }

    // Write journal area
    try writeJournalArea(allocator, dev, layout);

    // Flush
    try dev.flush();

    if (options.verbose) {
        print("Format complete!\n", .{});
    }
}

const Layout = struct {
    superblock_offset: u64,
    backup_superblock_locations: []u64,
    journal_start: u64,
    journal_clusters: u64,
    ags: std.ArrayList(AGLayout),
    first_ag_offset: u64,
    cluster_size: u32,
    total_clusters: u64,
};

const AGLayout = struct {
    index: u32,
    start_cluster: u64,
    cluster_count: u64,
    inode_table_start: u64,
    inode_count: u32,
    bitmap_start: u64,
    bitmap_clusters: u64,
    free_tree_start: u64,
    free_tree_clusters: u64,
};

fn calculateLayout(total_clusters: u64, cluster_size: u32, options: FormatOptions) !Layout {
    var layout = Layout{
        .superblock_offset = 0, // First cluster
        .backup_superblock_locations = std.ArrayList(u64).init(std.heap.page_allocator),
        .journal_start = 0,
        .journal_clusters = 0,
        .ags = std.ArrayList(AGLayout).init(std.heap.page_allocator),
        .first_ag_offset = 0,
        .cluster_size = cluster_size,
        .total_clusters = total_clusters,
    };
    defer {
        layout.backup_superblock_locations.deinit();
        layout.ags.deinit();
    }

    // Journal size: default 1% of volume, min 32MB, max 1GB
    var journal_clusters = options.journal_size_clusters;
    if (journal_clusters == 0) {
        journal_clusters = @max(32 * 1024 * 1024 / cluster_size, total_clusters / 100);
        journal_clusters = @min(journal_clusters, 1024 * 1024 * 1024 / cluster_size);
        // Align to cluster boundary
        journal_clusters = (journal_clusters + 63) & ~63;
    }
    layout.journal_clusters = journal_clusters;
    layout.journal_start = 2; // After primary superblock

    // Backup superblocks at fixed locations
    // Standard locations: 1, and then at 1/4, 1/2, 3/4 of volume
    layout.backup_superblock_locations.append(1) catch {};
    if (total_clusters > 4) {
        layout.backup_superblock_locations.append(total_clusters / 4) catch {};
        layout.backup_superblock_locations.append(total_clusters / 2) catch {};
        layout.backup_superblock_locations.append((3 * total_clusters) / 4) catch {};
    }

    // AG count: default 1 per GB
    var ag_count = options.ag_count;
    if (ag_count == 0) {
        ag_count = @max(1, @intCast((total_clusters * cluster_size) / (1024 * 1024 * 1024)));
        ag_count = @min(ag_count, 256);
    }

    const ag_size_clusters = total_clusters / ag_count;
    layout.first_ag_offset = layout.journal_start + layout.journal_clusters + 1; // +1 for gap

    // Create AG layouts
    for (0..ag_count) |i| {
        const ag_start = layout.first_ag_offset + @intCast(i) * ag_size_clusters;
        const ag_clusters = if (i == ag_count - 1) total_clusters - ag_start else ag_size_clusters;

        // Inode table: 1 inode per 1MB default
        const inode_count = @max(DEFAULT_INODES_PER_AG, @intCast(ag_clusters * cluster_size / (1024 * 1024)));
        const inode_table_clusters = (u64(inode_count) * 256 + cluster_size - 1) / cluster_size; // 256 bytes per inode

        // Bitmap: 1 bit per cluster
        const bitmap_bits = ag_clusters;
        const bitmap_bytes = (bitmap_bits + 7) / 8;
        const bitmap_clusters = (bitmap_bytes + cluster_size - 1) / cluster_size;

        // Free extent tree: small, ~1% of AG
        const free_tree_clusters = @max(1, ag_clusters / 100);

        const ag_layout = AGLayout{
            .index = @intCast(i),
            .start_cluster = ag_start,
            .cluster_count = ag_clusters,
            .inode_table_start = ag_start + 1, // AG header at start
            .inode_count = inode_count,
            .bitmap_start = ag_start + 1 + inode_table_clusters,
            .bitmap_clusters = bitmap_clusters,
            .free_tree_start = ag_start + 1 + inode_table_clusters + bitmap_clusters,
            .free_tree_clusters = free_tree_clusters,
        };

        layout.ags.append(ag_layout) catch {};
    }

    return layout;
}

fn printLayout(layout: Layout) void {
    print("\nLayout:\n", .{});
    print("  Primary superblock: cluster {d}\n", .{layout.superblock_offset});
    print("  Backup superblocks: ", .{});
    for (layout.backup_superblock_locations.items) |loc, i| {
        if (i > 0) print(", ", .{});
        print("{d}", .{loc});
    }
    print("\n", .{});
    print("  Journal: cluster {d} ({d} clusters)\n", .{layout.journal_start, layout.journal_clusters});
    print("  First AG: cluster {d}\n", .{layout.first_ag_offset});
    print("  AG count: {d}\n", .{layout.ags.items.len});
    for (layout.ags.items) |ag| {
        print("  AG {d}: start={d}, clusters={d}, inodes={d}, bitmap={d} clusters, free_tree={d} clusters\n", .{
            ag.index, ag.start_cluster, ag.cluster_count, ag.inode_count, ag.bitmap_clusters, ag.free_tree_clusters
        });
    }
}

fn writeSuperblock(allocator: Allocator, dev: BlockDevice, layout: Layout, options: FormatOptions, location: u64) !void {
    // Superblock structure per UFS spec
    const sb_size = 4096;
    var buf = try allocator.alloc(u8, sb_size);
    defer allocator.free(buf);
    @memset(buf, 0);

    // Magic
    writeU32LE(buf[0..4], ufs.MAGIC_UFS);

    // Version
    writeU16LE(buf[4..6], ufs.VERSION_MAJOR);
    writeU16LE(buf[6..8], ufs.VERSION_MINOR);
    writeU32LE(buf[8..12], ufs.VERSION_REVISION);

    // UUID
    var uuid = options.uuid.? else {
        var new_uuid: [16]u8 = undefined;
        std.crypto.random.fill(&new_uuid);
        // Set UUIDv7 version bits
        new_uuid[6] = (new_uuid[6] & 0x0F) | 0x70;
        new_uuid[8] = (new_uuid[8] & 0x3F) | 0x80;
        uuid = new_uuid;
    };
    @memcpy(buf[12..28], &uuid);

    // Label
    if (options.label.len > 0) {
        @memcpy(buf[28..28+@min(options.label.len, 255)], options.label);
    }

    // Cluster size
    writeU32LE(buf[284..288], layout.cluster_size);

    // Total clusters
    writeU64LE(buf[288..296], layout.total_clusters);

    // Journal
    writeU64LE(buf[296..304], layout.journal_start);
    writeU64LE(buf[304..312], layout.journal_clusters);

    // AG info
    writeU32LE(buf[312..316], @intCast(layout.ags.items.len));
    writeU64LE(buf[316..324], layout.first_ag_offset);

    // Feature flags
    writeU32LE(buf[324..328], 0); // incompat
    writeU32LE(buf[328..332], (1 << ufs.COMPAT_RO_COMPRESSION_LZ4) | (1 << ufs.COMPAT_RO_METADATA_CSUMS)); // compat_ro
    writeU32LE(buf[332..336], (1 << ufs.COMPAT_RW_XATTR) | (1 << ufs.COMPAT_RW_ACL)); // compat_rw

    // Default compression
    buf[336] = options.compression;

    // Checksum (placeholder - will be computed by core)
    writeU32LE(buf[sb_size-4..sb_size], 0);

    // Write to device
    try dev.write(location, buf[0..cluster_size]);
}

fn writeAllocationGroup(allocator: Allocator, dev: BlockDevice, layout: Layout, ag: AGLayout, options: FormatOptions) !void {
    const cluster_size = layout.cluster_size;

    // AG Header
    var ag_header = try allocator.alloc(u8, cluster_size);
    defer allocator.free(ag_header);
    @memset(ag_header, 0);

    writeU32LE(ag_header[0..4], ufs.MAGIC_AG);
    writeU32LE(ag_header[4..8], ag.index);
    writeU64LE(ag_header[8..16], ag.start_cluster);
    writeU64LE(ag_header[16..24], ag.cluster_count);
    writeU64LE(ag_header[24..32], ag.inode_table_start);
    writeU32LE(ag_header[32..36], ag.inode_count);
    writeU64LE(ag_header[36..44], ag.bitmap_start);
    writeU64LE(ag_header[44..52], ag.bitmap_clusters);
    writeU64LE(ag_header[52..60], ag.free_tree_start);
    writeU64LE(ag_header[60..68], ag.free_tree_clusters);
    writeU32LE(ag_header[cluster_size-4..cluster_size], 0); // checksum placeholder

    try dev.write(ag.start_cluster, ag_header);

    // Inode table (zero-initialized)
    var zero_cluster = try allocator.alloc(u8, cluster_size);
    defer allocator.free(zero_cluster);
    @memset(zero_cluster, 0);

    for (0..ag.inode_count) |_| {
        // Each inode is 256 bytes, so 16 inodes per 4KB cluster
        if (ag.index * 16 == 0) {
            // Root inode at index 2 (0 and 1 reserved)
        }
    }

    // Write inode table clusters
    const inode_table_clusters = (u64(ag.inode_count) * 256 + cluster_size - 1) / cluster_size;
    for (u64(0)..inode_table_clusters) |i| {
        try dev.write(ag.inode_table_start + i, zero_cluster);
    }

    // Bitmap (zero-initialized - all free)
    const bitmap_clusters = ag.bitmap_clusters;
    for (u64(0)..bitmap_clusters) |i| {
        try dev.write(ag.bitmap_start + i, zero_cluster);
    }

    // Mark AG header, inode table, bitmap, and free tree as allocated in bitmap
    // This is done by the core when mounting, but we pre-mark here
    markBitmapAllocated(dev, ag, 0); // AG header
    for (u64(0)..inode_table_clusters) |i| {
        markBitmapAllocated(dev, ag, 1 + i);
    }
    for (u64(0)..bitmap_clusters) |i| {
        markBitmapAllocated(dev, ag, 1 + inode_table_clusters + i);
    }
    for (u64(0)..ag.free_tree_clusters) |i| {
        markBitmapAllocated(dev, ag, 1 + inode_table_clusters + bitmap_clusters + i);
    }

    // Free extent tree (zero-initialized)
    for (u64(0)..ag.free_tree_clusters) |i| {
        try dev.write(ag.free_tree_start + i, zero_cluster);
    }

    // Create root directory inode (inode 2)
    try createRootInode(allocator, dev, ag, layout, options);
}

fn markBitmapAllocated(dev: BlockDevice, ag: AGLayout, cluster_offset: u64) !void {
    const cluster_size = 4096; // TODO: use actual cluster size
    const byte_offset = cluster_offset / 8;
    const bit = cluster_offset % 8;
    const bitmap_cluster = ag.bitmap_start + byte_offset / cluster_size;
    const offset_in_cluster = byte_offset % cluster_size;

    var buf: [4096]u8 = undefined;
    try dev.read(bitmap_cluster, &buf);
    buf[offset_in_cluster] |= (1 << bit);
    try dev.write(bitmap_cluster, &buf);
}

fn createRootInode(allocator: Allocator, dev: BlockDevice, ag: AGLayout, layout: Layout, options: FormatOptions) !void {
    const cluster_size = layout.cluster_size;
    const inode_size = 256;
    const inode_index = 2; // Root inode

    var inode_buf = try allocator.alloc(u8, inode_size);
    defer allocator.free(inode_buf);
    @memset(inode_buf, 0);

    // Inode header
    writeU32LE(inode_buf[0..4], ufs.MAGIC_INODE);
    writeU32LE(inode_buf[4..8], 1); // generation
    writeU64LE(inode_buf[8..16], 2); // inode number

    // Mode: directory, 0755
    writeU32LE(inode_buf[16..20], 0x41ED); // S_IFDIR | 0755

    // UID/GID
    writeU32LE(inode_buf[20..24], 0);
    writeU32LE(inode_buf[24..28], 0);

    // Timestamps (current time)
    const now = std.time.timestamp();
    writeU64LE(inode_buf[28..36], @intCast(now));
    writeU64LE(inode_buf[36..44], @intCast(now));
    writeU64LE(inode_buf[44..52], @intCast(now));
    writeU64LE(inode_buf[52..60], @intCast(now));

    // Link count
    writeU32LE(inode_buf[60..64], 2); // . and ..

    // Flags
    writeU32LE(inode_buf[64..68], 0);

    // Size (0 for directory, data in extent tree)
    writeU64LE(inode_buf[68..76], 0);
    writeU64LE(inode_buf[76..84], cluster_size); // allocated size

    // Extent tree root (inline for small dirs)
    // For now, mark as inline
    inode_buf[84] = 1; // inline flag

    // Parent inode (self for root)
    writeU64LE(inode_buf[88..96], 2);

    // Checksum placeholder
    writeU32LE(inode_buf[inode_size-4..inode_size], 0);

    // Write inode to inode table
    const inode_cluster = ag.inode_table_start + (inode_index * inode_size) / cluster_size;
    const offset_in_cluster = (inode_index * inode_size) % cluster_size;

    var cluster_buf: [4096]u8 = undefined;
    try dev.read(inode_cluster, &cluster_buf);
    @memcpy(cluster_buf[offset_in_cluster..offset_in_cluster+inode_size], inode_buf);
    try dev.write(inode_cluster, &cluster_buf);

    // Create directory entries for . and ..
    try createRootDirEntries(allocator, dev, ag, layout, cluster_size);
}

fn createRootDirEntries(allocator: Allocator, dev: BlockDevice, ag: AGLayout, layout: Layout, cluster_size: u32) !void {
    // For root directory, we use inline directory format (linear array)
    // Directory entry structure per UFS spec

    // Allocate one cluster for root directory data
    var dir_cluster = try allocator.alloc(u8, cluster_size);
    defer allocator.free(dir_cluster);
    @memset(dir_cluster, 0);

    // Magic for small directory
    writeU32LE(dir_cluster[0..4], ufs.MAGIC_DIR_SMALL);

    // Entry count
    writeU16LE(dir_cluster[4..6], 2);

    // Entry 0: "."
    var offset = 8;
    writeU64LE(dir_cluster[offset..offset+8], 2); // inode
    dir_cluster[offset+8] = 1; // name length
    dir_cluster[offset+9] = 2; // type = directory
    dir_cluster[offset+10] = '.';
    offset += 16;

    // Entry 1: ".."
    writeU64LE(dir_cluster[offset..offset+8], 2); // inode (self)
    dir_cluster[offset+8] = 2; // name length
    dir_cluster[offset+9] = 2; // type = directory
    dir_cluster[offset+10] = '.';
    dir_cluster[offset+11] = '.';

    // Write to first data cluster of root inode
    // For simplicity, we'll use the first cluster after AG structures
    const root_data_cluster = ag.free_tree_start + ag.free_tree_clusters;
    try dev.write(root_data_cluster, dir_cluster);

    // Mark this cluster as allocated in bitmap
    markBitmapAllocated(dev, ag, root_data_cluster - ag.start_cluster);
}

fn writeJournalArea(allocator: Allocator, dev: BlockDevice, layout: Layout) !void {
    const cluster_size = layout.cluster_size;
    var zero_cluster = try allocator.alloc(u8, cluster_size);
    defer allocator.free(zero_cluster);
    @memset(zero_cluster, 0);

    // Journal superblock
    var journal_sb = try allocator.alloc(u8, cluster_size);
    defer allocator.free(journal_sb);
    @memset(journal_sb, 0);

    writeU32LE(journal_sb[0..4], ufs.MAGIC_JOURNAL);
    writeU32LE(journal_sb[4..8], 1); // version
    writeU64LE(journal_sb[8..16], layout.journal_clusters);
    writeU64LE(journal_sb[16..24], 0); // start transaction ID
    writeU64LE(journal_sb[24..32], 0); // end transaction ID
    writeU64LE(journal_sb[32..40], 0); // checkpoint transaction ID
    writeU32LE(journal_sb[cluster_size-4..cluster_size], 0); // checksum

    try dev.write(layout.journal_start, journal_sb);

    // Zero out journal data area
    for (u64(1)..layout.journal_clusters) |i| {
        try dev.write(layout.journal_start + i, zero_cluster);
    }
}

fn writeU16LE(buf: []u8, val: u16) void {
    buf[0] = @intCast(val & 0xFF);
    buf[1] = @intCast((val >> 8) & 0xFF);
}

fn writeU32LE(buf: []u8, val: u32) void {
    buf[0] = @intCast(val & 0xFF);
    buf[1] = @intCast((val >> 8) & 0xFF);
    buf[2] = @intCast((val >> 16) & 0xFF);
    buf[3] = @intCast((val >> 24) & 0xFF);
}

fn writeU64LE(buf: []u8, val: u64) void {
    for (0..8) |i| {
        buf[i] = @intCast((val >> (i * 8)) & 0xFF);
    }
}