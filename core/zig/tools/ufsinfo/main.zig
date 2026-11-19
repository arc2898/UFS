// ufsinfo - UFS Filesystem Inspector
// Displays detailed information about UFS filesystem structures

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
        printUsage(args[0] orelse "ufsinfo");
        return;
    }

    const device_path = args[1];

    var options = InfoOptions{
        .show_superblock = true,
        .show_journal = false,
        .show_ags = false,
        .show_tree = false,
        .show_extents = false,
        .show_capsules = false,
        .inode = 0,
        .output_json = false,
    };

    var i: usize = 2;
    while (i < args.len) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printUsage(args[0] orelse "ufsinfo");
            return;
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--superblock")) {
            options.show_superblock = true;
        } else if (std.mem.eql(u8, arg, "-j") or std.mem.eql(u8, arg, "--journal")) {
            options.show_journal = true;
        } else if (std.mem.eql(u8, arg, "-a") or std.mem.eql(u8, arg, "--ags")) {
            options.show_ags = true;
        } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--tree")) {
            options.show_tree = true;
        } else if (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--extents")) {
            options.show_extents = true;
        } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--capsules")) {
            options.show_capsules = true;
        } else if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--inode")) {
            i += 1;
            if (i >= args.len) return error.InvalidArgument;
            options.inode = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--json")) {
            options.output_json = true;
        } else if (std.mem.eql(u8, arg, "--all")) {
            options.show_superblock = true;
            options.show_journal = true;
            options.show_ags = true;
            options.show_tree = true;
            options.show_extents = true;
            options.show_capsules = true;
        } else {
            print("Unknown option: {s}\n", .{arg});
            printUsage(args[0] orelse "ufsinfo");
            return error.InvalidArgument;
        }
        i += 1;
    }

    // Open block device
    const block_dev = try openBlockDevice(allocator, device_path);
    defer block_dev.close();

    const info = block_dev.get_info();

    // Read superblock
    var buf = try allocator.alloc(u8, 4096);
    defer allocator.free(buf);
    try block_dev.read(0, buf);

    const magic = readU32LE(buf[0..4]);
    if (magic != ufs.MAGIC_UFS) {
        print("Error: Not a UFS filesystem (magic: 0x{08x})\n", .{magic});
        return;
    }

    const sb = Superblock{
        .magic = magic,
        .version_major = readU16LE(buf[4..6]),
        .version_minor = readU16LE(buf[6..8]),
        .version_revision = readU32LE(buf[8..12]),
        .uuid = buf[12..28],
        .label = std.mem.span(buf[28..284], 0),
        .cluster_size = readU32LE(buf[284..288]),
        .total_clusters = readU64LE(buf[288..296]),
        .journal_start = readU64LE(buf[296..304]),
        .journal_clusters = readU64LE(buf[304..312]),
        .ag_count = readU32LE(buf[312..316]),
        .first_ag_offset = readU64LE(buf[316..324]),
        .incompat_flags = readU32LE(buf[324..328]),
        .compat_ro_flags = readU32LE(buf[328..332]),
        .compat_rw_flags = readU32LE(buf[332..336]),
        .default_compression = buf[336],
    };

    if (options.output_json) {
        try outputJSON(allocator, sb, block_dev, options);
    } else {
        outputHuman(sb, block_dev, info, options);
    }
}

const InfoOptions = struct {
    show_superblock: bool,
    show_journal: bool,
    show_ags: bool,
    show_tree: bool,
    show_extents: bool,
    show_capsules: bool,
    inode: u64,
    output_json: bool,
};

const Superblock = struct {
    magic: u32,
    version_major: u16,
    version_minor: u16,
    version_revision: u32,
    uuid: [16]u8,
    label: []const u8,
    cluster_size: u32,
    total_clusters: u64,
    journal_start: u64,
    journal_clusters: u64,
    ag_count: u32,
    first_ag_offset: u64,
    incompat_flags: u32,
    compat_ro_flags: u32,
    compat_rw_flags: u32,
    default_compression: u8,
};

const BlockDevice = struct {
    fd: std.os.fd_t,
    path: []const u8,
    block_size: u32,
    total_blocks: u64,

    fn open(allocator: Allocator, path: []const u8) !BlockDevice {
        const fd = try std.os.openFile(path, .{ .read = true, .write = false }, .{});
        const stat = try std.os.fstat(fd);
        const block_size = 4096;
        const total_blocks = stat.size / block_size;
        return BlockDevice{
            .fd = fd,
            .path = path,
            .block_size = block_size,
            .total_blocks = total_blocks,
        };
    }

    fn close(self: BlockDevice) void {
        std.posix.close(self.fd);
    }

    fn read(self: BlockDevice, offset: u64, buffer: []u8) !usize {
        return try std.posix.pread(self.fd, buffer, @intCast(offset * self.block_size));
    }

    fn get_info(self: BlockDevice) DeviceInfo {
        return DeviceInfo{
            .block_size = self.block_size,
            .physical_block_size = self.block_size,
            .optimal_io_size = self.block_size * 128,
            .total_blocks = self.total_blocks,
            .is_removable = false,
            .is_read_only = false,
            .is_ssd = false,
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

fn outputHuman(sb: Superblock, dev: BlockDevice, info: DeviceInfo, options: InfoOptions) void {
    if (options.show_superblock) {
        printSuperblock(sb, info);
    }

    if (options.show_journal) {
        printJournal(sb, dev);
    }

    if (options.show_ags) {
        printAGs(sb, dev);
    }

    if (options.show_tree) {
        printDirectoryTree(sb, dev);
    }

    if (options.show_extents) {
        printExtents(sb, dev, options.inode);
    }

    if (options.show_capsules) {
        printCapsules(sb, dev, options.inode);
    }
}

fn printSuperblock(sb: Superblock, info: DeviceInfo) void {
    print("=== Superblock ===\n", .{});
    print("Magic:              0x{08x} (UFS)\n", .{sb.magic});
    print("Version:            {d}.{d}.{d}\n", .{sb.version_major, sb.version_minor, sb.version_revision});

    print("UUID:               ", .{});
    for (sb.uuid) |b, i| {
        if (i == 4 || i == 6 || i == 8 || i == 10) print("-", .{});
        print("{02x}", .{b});
    }
    print("\n", .{});

    print("Label:              {s}\n", .{if (sb.label.len > 0) sb.label else "<none>"});
    print("Cluster size:       {d} bytes\n", .{sb.cluster_size});
    print("Total clusters:     {d} ({d} GB)\n", .{sb.total_clusters, sb.total_clusters * sb.cluster_size / (1024*1024*1024)});
    print("Journal:            start={d}, clusters={d} ({d} MB)\n", .{sb.journal_start, sb.journal_clusters, sb.journal_clusters * sb.cluster_size / (1024*1024)});
    print("Allocation groups:  {d}\n", .{sb.ag_count});
    print("First AG offset:    {d}\n", .{sb.first_ag_offset});

    print("\nFeature flags:\n", .{});
    print("  Incompat:         0x{08x}\n", .{sb.incompat_flags});
    printFlags(sb.incompat_flags, .{
        .{ufs.INCOMPAT_ENCRYPTION, "ENCRYPTION"},
        .{ufs.INCOMPAT_SNAPSHOTS, "SNAPSHOTS"},
        .{ufs.INCOMPAT_DEDUP, "DEDUP"},
        .{ufs.INCOMPAT_QUOTAS, "QUOTAS"},
        .{ufs.INCOMPAT_ZNS, "ZNS"},
    });

    print("  Compat RO:        0x{08x}\n", .{sb.compat_ro_flags});
    printFlags(sb.compat_ro_flags, .{
        .{ufs.COMPAT_RO_COMPRESSION_LZ4, "COMPRESSION_LZ4"},
        .{ufs.COMPAT_RO_COMPRESSION_ZSTD, "COMPRESSION_ZSTD"},
        .{ufs.COMPAT_RO_CASE_INSENSITIVE, "CASE_INSENSITIVE"},
        .{ufs.COMPAT_RO_METADATA_CSUMS, "METADATA_CSUMS"},
    });

    print("  Compat RW:        0x{08x}\n", .{sb.compat_rw_flags});
    printFlags(sb.compat_rw_flags, .{
        .{ufs.COMPAT_RW_XATTR, "XATTR"},
        .{ufs.COMPAT_RW_ACL, "ACL"},
        .{ufs.COMPAT_RW_WINDOWS_META, "WINDOWS_META"},
    });

    print("Default compression: {s}\n", .{compressionToString(sb.default_compression)});
    print("\n", .{});
}

fn printFlags(flags: u32, flag_names: []struct { bit: u32, name: []const u8 }) void {
    var first = true;
    for (flag_names) |f| {
        if ((flags & (1 << f.bit)) != 0) {
            if (!first) print(", ", .{});
            print("{s}", .{f.name});
            first = false;
        }
    }
    if (first) print("  (none)", .{});
    print("\n", .{});
}

fn printJournal(sb: Superblock, dev: BlockDevice) void {
    print("\n=== Journal ===\n", .{});

    var buf = try std.heap.page_allocator.alloc(u8, 4096);
    defer std.heap.page_allocator.free(buf);

    const read_result = dev.read(sb.journal_start, buf) catch {
        print("  Failed to read journal superblock\n", .{});
        return;
    };
    _ = read_result;

    const magic = readU32LE(buf[0..4]);
    if (magic != ufs.MAGIC_JOURNAL) {
        print("  Invalid journal magic: 0x{08x}\n", .{magic});
        return;
    }

    print("Magic:              0x{08x} (JURN)\n", .{magic});
    print("Version:            {d}\n", .{readU32LE(buf[4..8])});
    print("Journal clusters:   {d}\n", .{readU64LE(buf[8..16])});
    print("Start TXID:         {d}\n", .{readU64LE(buf[16..24])});
    print("End TXID:           {d}\n", .{readU64LE(buf[24..32])});
    print("Checkpoint TXID:    {d}\n", .{readU64LE(buf[32..40])});

    // Read transaction headers
    const cluster_size = sb.cluster_size;
    var tx_buf = try std.heap.page_allocator.alloc(u8, cluster_size);
    defer std.heap.page_allocator.free(tx_buf);

    print("\nTransactions:\n", .{});
    for (u64(1)..@min(sb.journal_clusters, 10)) |i| {
        const result = dev.read(sb.journal_start + i, tx_buf) catch break;
        _ = result;

        const tx_magic = readU32LE(tx_buf[0..4]);
        if (tx_magic != ufs.MAGIC_TRANSACTION) continue;

        const txid = readU64LE(tx_buf[4..12]);
        const flags = readU32LE(tx_buf[12..16]);
        const num_ops = readU32LE(tx_buf[16..20]);
        const crc32c = readU32LE(tx_buf[cluster_size-4..cluster_size]);

        print("  TX {d}: flags=0x{04x}, ops={d}, crc=0x{08x}\n", .{txid, flags, num_ops, crc32c});
    }
    if (sb.journal_clusters > 10) {
        print("  ... ({d} more clusters)\n", .{sb.journal_clusters - 10});
    }
    print("\n", .{});
}

fn printAGs(sb: Superblock, dev: BlockDevice) void {
    print("\n=== Allocation Groups ===\n", .{});

    const cluster_size = sb.cluster_size;
    const ag_size_clusters = sb.total_clusters / sb.ag_count;

    for (0..sb.ag_count) |i| {
        const ag_start = sb.first_ag_offset + @intCast(i) * ag_size_clusters;

        var buf = try std.heap.page_allocator.alloc(u8, cluster_size);
        defer std.heap.page_allocator.free(buf);

        const read_result = dev.read(ag_start, buf) catch {
            print("  AG {d}: Failed to read header\n", .{i});
            continue;
        };
        _ = read_result;

        const magic = readU32LE(buf[0..4]);
        if (magic != ufs.MAGIC_AG) {
            print("  AG {d}: Invalid magic 0x{08x}\n", .{i, magic});
            continue;
        }

        print("AG {d}:\n", .{i});
        print("  Index:              {d}\n", .{readU32LE(buf[4..8])});
        print("  Start cluster:      {d}\n", .{readU64LE(buf[8..16])});
        print("  Cluster count:      {d}\n", .{readU64LE(buf[16..24])});
        print("  Inode table start:  {d}\n", .{readU64LE(buf[24..32])});
        print("  Inode count:        {d}\n", .{readU32LE(buf[32..36])});
        print("  Bitmap start:       {d}\n", .{readU64LE(buf[36..44])});
        print("  Bitmap clusters:    {d}\n", .{readU64LE(buf[44..52])});
        print("  Free tree start:    {d}\n", .{readU64LE(buf[52..60])});
        print("  Free tree clusters: {d}\n", .{readU64LE(buf[60..68])});

        // Read bitmap summary
        const bitmap_start = readU64LE(buf[36..44]);
        const bitmap_clusters = readU64LE(buf[44..52]);
        const cluster_count = readU64LE(buf[16..24]);

        var bitmap_buf = try std.heap.page_allocator.alloc(u8, cluster_size);
        defer std.heap.page_allocator.free(bitmap_buf);

        var free_count: u64 = 0;
        var alloc_count: u64 = 0;

        for (u64(0)..bitmap_clusters) |bi| {
            dev.read(bitmap_start + bi, bitmap_buf) catch break;
            for (bitmap_buf) |byte| {
                if (alloc_count + free_count >= cluster_count) break;
                if (byte & 1 != 0) alloc_count += 1; else free_count += 1;
                if (byte & 2 != 0) alloc_count += 1; else free_count += 1;
                if (byte & 4 != 0) alloc_count += 1; else free_count += 1;
                if (byte & 8 != 0) alloc_count += 1; else free_count += 1;
                if (byte & 16 != 0) alloc_count += 1; else free_count += 1;
                if (byte & 32 != 0) alloc_count += 1; else free_count += 1;
                if (byte & 64 != 0) alloc_count += 1; else free_count += 1;
                if (byte & 128 != 0) alloc_count += 1; else free_count += 1;
            }
        }

        print("  Free clusters:      {d} ({d:.1}%)\n", .{free_count, @as(f64, @floatFromInt(free_count)) * 100.0 / @as(f64, @floatFromInt(cluster_count))});
        print("  Allocated clusters: {d}\n", .{alloc_count});

        // Read inode table summary
        const inode_table_start = readU64LE(buf[24..32]);
        const inode_count = readU32LE(buf[32..36]);
        const inode_table_clusters = (u64(inode_count) * 256 + cluster_size - 1) / cluster_size;

        var inode_buf = try std.heap.page_allocator.alloc(u8, cluster_size);
        defer std.heap.page_allocator.free(inode_buf);

        var valid_inodes: u32 = 0;
        for (u64(0)..inode_table_clusters) |ci| {
            dev.read(inode_table_start + ci, inode_buf) catch break;
            for (u32(0)..(cluster_size / 256)) |ii| {
                if (valid_inodes >= inode_count) break;
                const offset = ii * 256;
                if (readU32LE(inode_buf[offset..offset+4]) == ufs.MAGIC_INODE) {
                    valid_inodes += 1;
                }
            }
        }
        print("  Valid inodes:       {d}/{d}\n", .{valid_inodes, inode_count});

        // Read free tree
        const free_tree_start = readU64LE(buf[52..60]);
        var ft_buf = try std.heap.page_allocator.alloc(u8, cluster_size);
        defer std.heap.page_allocator.free(ft_buf);
        dev.read(free_tree_start, ft_buf) catch {};
        const ft_magic = readU32LE(ft_buf[0..4]);
        if (ft_magic == ufs.MAGIC_FREE_TREE) {
            print("  Free tree:          valid (magic OK)\n", .{});
        } else {
            print("  Free tree:          invalid magic 0x{08x}\n", .{ft_magic});
        }

        print("\n", .{});
    }
}

fn printDirectoryTree(sb: Superblock, dev: BlockDevice) void {
    print("\n=== Directory Tree ===\n", .{});

    const cluster_size = sb.cluster_size;

    // Read root inode (inode 2 in AG 0)
    const ag_start = sb.first_ag_offset;
    var ag_buf = try std.heap.page_allocator.alloc(u8, cluster_size);
    defer std.heap.page_allocator.free(ag_buf);
    dev.read(ag_start, ag_buf) catch {
        print("  Failed to read AG 0\n", .{});
        return;
    };

    const inode_table_start = readU64LE(ag_buf[24..32]);
    const inode_size = 256;

    // Read inode 2 (root directory)
    var inode_buf = try std.heap.page_allocator.alloc(u8, cluster_size);
    defer std.heap.page_allocator.free(inode_buf);
    dev.read(inode_table_start, inode_buf) catch {
        print("  Failed to read inode table\n", .{});
        return;
    };

    const root_inode_offset = 2 * inode_size;
    if (readU32LE(inode_buf[root_inode_offset..root_inode_offset+4]) != ufs.MAGIC_INODE) {
        print("  Root inode not found\n", .{});
        return;
    }

    // Parse root inode
    const root_mode = readU16LE(inode_buf[root_inode_offset+16..root_inode_offset+18]);
    const root_size = readU64LE(inode_buf[root_inode_offset+68..root_inode_offset+76]);
    const inline_flag = inode_buf[root_inode_offset+84];

    print("Root inode (2):\n", .{});
    print("  Mode:      0x{04x} ({s})\n", .{root_mode, if ((root_mode & 0xF000) == 0x4000) "directory" else "file"});
    print("  Size:      {d} bytes\n", .{root_size});
    print("  Inline:    {s}\n", .{if (inline_flag != 0) "yes" else "no"});

    // If inline directory, read entries from inode
    if (inline_flag != 0) {
        printDirectoryInline(inode_buf[root_inode_offset+88..root_inode_offset+256]);
    } else {
        // Read extent tree to find directory data clusters
        print("  (Extent tree traversal not fully implemented)\n", .{});
    }
    print("\n", .{});
}

fn printDirectoryInline(data: []const u8) void {
    // Inline directory format: magic + count + entries
    if (data.len < 8) return;
    const magic = readU32LE(data[0..4]);
    if (magic != ufs.MAGIC_DIR_SMALL) return;

    const count = readU16LE(data[4..6]);
    var offset = 8;

    print("  Entries ({d}):\n", .{count});
    for (u16(0)..count) |_| {
        if (offset + 16 > data.len) break;
        const inode = readU64LE(data[offset..offset+8]);
        const name_len = data[offset+8];
        const file_type = data[offset+9];
        const name_start = offset + 10;
        const name_end = @min(name_start + name_len, data.len);
        const name = if (name_end > name_start) data[name_start..name_end] else "";

        const type_str = switch (file_type) {
            ufs.FILE_TYPE_REG => "file",
            ufs.FILE_TYPE_DIR => "dir",
            ufs.FILE_TYPE_SYMLINK => "symlink",
            ufs.FILE_TYPE_CHRDEV => "chrdev",
            ufs.FILE_TYPE_BLKDEV => "blkdev",
            ufs.FILE_TYPE_FIFO => "fifo",
            ufs.FILE_TYPE_SOCKET => "socket",
            ufs.FILE_TYPE_REPARSE => "reparse",
            else => "unknown",
        };

        print("    [{d}] {s} ({s})\n", .{inode, name, type_str});
        offset += 10 + name_len;
        // Align to 2 bytes
        offset = (offset + 1) & ~1;
    }
}

fn printExtents(sb: Superblock, dev: BlockDevice, inode: u64) void {
    print("\n=== Extent Map ===\n", .{});
    if (inode == 0) {
        print("  Use -i <inode> to show extents for a specific inode\n", .{});
    } else {
        print("  Inode {d}:\n", .{inode});
        print("  (Extent tree traversal requires full mount - not implemented in offline mode)\n", .{});
        print("  To view extents, mount the filesystem and use: ufsctl <dev> extents <inode>\n", .{});
    }
    print("\n", .{});
}

fn printCapsules(sb: Superblock, dev: BlockDevice, inode: u64) void {
    print("\n=== Metadata Capsules ===\n", .{});
    if (inode == 0) {
        print("  Use -i <inode> to show capsules for a specific inode\n", .{});
    } else {
        print("  Inode {d}:\n", .{inode});
        print("  (Capsule inspection requires full mount - not implemented in offline mode)\n", .{});
        print("  Capsules are stored in extended attribute area of inode\n", .{});
        print("  Namespaces: POSIX (0x0001-0x0004), Windows (0x0010-0x0016), macOS (0x0020-0x0025)\n", .{});
    }
    print("\n", .{});
}

fn outputJSON(allocator: Allocator, sb: Superblock, dev: BlockDevice, options: InfoOptions) !void {
    var buf = std.ArrayList(u8).init(allocator);
    defer allocator.free(buf.items);

    try buf.writer().print("{{\n", .{});
    try buf.writer().print("  \"superblock\": {{\n", .{});
    try buf.writer().print("    \"magic\": \"0x{08x}\",\n", .{sb.magic});
    try buf.writer().print("    \"version\": \"{d}.{d}.{d}\",\n", .{sb.version_major, sb.version_minor, sb.version_revision});
    try buf.writer().print("    \"uuid\": \"", .{});
    for (sb.uuid) |b, i| {
        if (i == 4 || i == 6 || i == 8 || i == 10) try buf.writer().print("-", .{});
        try buf.writer().print("{02x}", .{b});
    }
    try buf.writer().print("\",\n", .{});
    try buf.writer().print("    \"label\": \"{s}\",\n", .{sb.label});
    try buf.writer().print("    \"cluster_size\": {d},\n", .{sb.cluster_size});
    try buf.writer().print("    \"total_clusters\": {d},\n", .{sb.total_clusters});
    try buf.writer().print("    \"journal_start\": {d},\n", .{sb.journal_start});
    try buf.writer().print("    \"journal_clusters\": {d},\n", .{sb.journal_clusters});
    try buf.writer().print("    \"ag_count\": {d},\n", .{sb.ag_count});
    try buf.writer().print("    \"first_ag_offset\": {d},\n", .{sb.first_ag_offset});
    try buf.writer().print("    \"incompat_flags\": \"0x{08x}\",\n", .{sb.incompat_flags});
    try buf.writer().print("    \"compat_ro_flags\": \"0x{08x}\",\n", .{sb.compat_ro_flags});
    try buf.writer().print("    \"compat_rw_flags\": \"0x{08x}\",\n", .{sb.compat_rw_flags});
    try buf.writer().print("    \"default_compression\": {d}\n", .{sb.default_compression});
    try buf.writer().print("  }}\n", .{});
    try buf.writer().print("}}\n", .{});

    print("{s}\n", .{buf.items});
}

fn printUsage(program: []const u8) void {
    print("Usage: {s} <device> [options]\n\n", .{program});
    print("Options:\n", .{});
    print("  -s, --superblock      Show superblock info (default)\n", .{});
    print("  -j, --journal         Show journal info\n", .{});
    print("  -a, --ags             Show allocation group info\n", .{});
    print("  -t, --tree            Show directory tree\n", .{});
    print("  -e, --extents         Show extent map for inode (use with -i)\n", .{});
    print("  -c, --capsules        Show metadata capsules for inode (use with -i)\n", .{});
    print("  -i, --inode <num>     Inode number for -e/-c\n", .{});
    print("  --all                 Show all information\n", .{});
    print("  --json                Output as JSON\n", .{});
    print("  -h, --help            Show this help\n", .{});
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

fn readU16LE(buf: []const u8) u16 {
    return @intCast(buf[0]) | (@intCast(buf[1]) << 8);
}

fn readU32LE(buf: []const u8) u32 {
    return @intCast(buf[0]) | (@intCast(buf[1]) << 8) | (@intCast(buf[2]) << 16) | (@intCast(buf[3]) << 24);
}

fn readU64LE(buf: []const u8) u64 {
    var val: u64 = 0;
    for (0..8) |i| {
        val |= @as(u64, @intCast(buf[i])) << (i * 8);
    }
    return val;
}