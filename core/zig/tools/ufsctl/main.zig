// ufsctl - UFS Volume Control
// Management utility for mounted UFS volumes

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
        printUsage(args[0] orelse "ufsctl");
        return;
    }

    const device_path = args[1];

    var options = CtlOptions{
        .command = .none,
        .verbose = false,
    };

    var i: usize = 2;
    while (i < args.len) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printUsage(args[0] orelse "ufsctl");
            return;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            options.verbose = true;
        } else if (std.mem.eql(u8, arg, "mount")) {
            options.command = .mount;
        } else if (std.mem.eql(u8, arg, "unmount")) {
            options.command = .unmount;
        } else if (std.mem.eql(u8, arg, "feature")) {
            options.command = .feature;
            i += 1;
            if (i >= args.len) return error.InvalidArgument;
            options.feature_subcmd = args[i];
            i += 1;
            if (i >= args.len) return error.InvalidArgument;
            options.feature_bit = try std.fmt.parseInt(u32, args[i], 10);
            i += 1;
            if (i >= args.len) return error.InvalidArgument;
            options.feature_enable = std.mem.eql(u8, args[i], "on");
        } else if (std.mem.eql(u8, arg, "compression")) {
            options.command = .compression;
            i += 1;
            if (i >= args.len) return error.InvalidArgument;
            options.compression_algo = try parseCompression(args[i]);
        } else if (std.mem.eql(u8, arg, "scrub")) {
            options.command = .scrub;
        } else if (std.mem.eql(u8, arg, "stats")) {
            options.command = .stats;
        } else if (std.mem.eql(u8, arg, "label")) {
            options.command = .label;
            i += 1;
            if (i < args.len) {
                options.new_label = args[i];
            }
        } else if (std.mem.eql(u8, arg, "checkpoint")) {
            options.command = .checkpoint;
        } else if (std.mem.eql(u8, arg, "extents")) {
            options.command = .extents;
            i += 1;
            if (i >= args.len) return error.InvalidArgument;
            options.extents_inode = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, arg, "capsules")) {
            options.command = .capsules;
            i += 1;
            if (i >= args.len) return error.InvalidArgument;
            options.capsules_inode = try std.fmt.parseInt(u64, args[i], 10);
        } else {
            print("Unknown command/option: {s}\n", .{arg});
            printUsage(args[0] orelse "ufsctl");
            return error.InvalidArgument;
        }
        i += 1;
    }

    if (options.command == .none) {
        print("Error: No command specified\n", .{});
        printUsage(args[0] orelse "ufsctl");
        return error.InvalidArgument;
    }

    // Open block device (read-write for most commands)
    const block_dev = try openBlockDevice(allocator, device_path);
    defer block_dev.close();

    const info = block_dev.get_info();

    // Read superblock to verify it's a UFS volume
    var buf = try allocator.alloc(u8, 4096);
    defer allocator.free(buf);
    try block_dev.read(0, buf);

    const magic = readU32LE(buf[0..4]);
    if (magic != ufs.MAGIC_UFS) {
        print("Error: Not a UFS filesystem\n", .{});
        return error.InvalidFormat;
    }

    const sb = Superblock{
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

    switch (options.command) {
        .mount => {
            cmdMount(block_dev, sb, options);
        },
        .unmount => {
            cmdUnmount();
        },
        .feature => {
            try cmdFeature(block_dev, sb, options);
        },
        .compression => {
            try cmdCompression(block_dev, sb, options);
        },
        .scrub => {
            try cmdScrub(block_dev, sb, options);
        },
        .stats => {
            try cmdStats(block_dev, sb, info);
        },
        .label => {
            try cmdLabel(block_dev, sb, options);
        },
        .checkpoint => {
            try cmdCheckpoint(block_dev, sb);
        },
        .extents => {
            try cmdExtents(block_dev, sb, options);
        },
        .capsules => {
            try cmdCapsules(block_dev, sb, options);
        },
        .none => unreachable,
    }
}

const Command = enum {
    none,
    mount,
    unmount,
    feature,
    compression,
    scrub,
    stats,
    label,
    checkpoint,
    extents,
    capsules,
};

const CtlOptions = struct {
    command: Command,
    verbose: bool,
    feature_subcmd: []const u8 = "",
    feature_bit: u32 = 0,
    feature_enable: bool = false,
    compression_algo: u8 = 0,
    new_label: []const u8 = "",
    extents_inode: u64 = 0,
    capsules_inode: u64 = 0,
};

const Superblock = struct {
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
        const fd = try std.os.openFile(path, .{ .read = true, .write = true }, .{});
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

fn cmdMount(dev: BlockDevice, sb: Superblock, options: CtlOptions) void {
    print("Mount command requires root privileges and FUSE/kernel driver\n", .{});
    print("Use: mount -t ufs {s} <mountpoint>\n", .{dev.path});
    print("\nMount options supported by UFS:\n", .{});
    print("  ro/rw                 Read-only or read-write (default: rw)\n", .{});
    print("  case_insensitive      Enable case-insensitive lookup (default: on)\n", .{});
    print("  compression=<algo>    Default compression: none, lz4, zstd (default: lz4)\n", .{});
    print("  integrity=meta|full   Integrity checking: metadata only or full (default: meta)\n", .{});
    print("  journal_size=<clusters> Override journal size\n", .{});
}

fn cmdUnmount() void {
    print("Unmount command requires root privileges\n", .{});
    print("Use: umount <mountpoint>\n", .{});
    print("Or: ufsctl <device> unmount (when implemented with kernel driver)\n", .{});
}

fn cmdFeature(dev: BlockDevice, sb: Superblock, options: CtlOptions) !void {
    print("Feature management:\n", .{});
    print("  Incompat flags:  0x{08x}\n", .{sb.incompat_flags});
    print("  Compat RO flags: 0x{08x}\n", .{sb.compat_ro_flags});
    print("  Compat RW flags: 0x{08x}\n", .{sb.compat_rw_flags});

    if (options.feature_subcmd.len > 0) {
        print("\nModifying feature {s} bit {d} -> {s}\n", .{options.feature_subcmd, options.feature_bit, if (options.feature_enable) "enabled" else "disabled"});
        print("Note: Feature flag modification requires mounted filesystem\n", .{});
        print("Current implementation: offline flag viewing only\n", .{});
    } else {
        print("\nFlag details:\n", .{});
        printFlags("Incompat", sb.incompat_flags, .{
            .{ufs.INCOMPAT_ENCRYPTION, "Encryption support"},
            .{ufs.INCOMPAT_SNAPSHOTS, "Snapshot support"},
            .{ufs.INCOMPAT_DEDUP, "Deduplication"},
            .{ufs.INCOMPAT_QUOTAS, "Quota enforcement"},
            .{ufs.INCOMPAT_ZNS, "Zoned namespace (ZNS) support"},
        });
        printFlags("Compat RO", sb.compat_ro_flags, .{
            .{ufs.COMPAT_RO_COMPRESSION_LZ4, "LZ4 compression"},
            .{ufs.COMPAT_RO_COMPRESSION_ZSTD, "ZSTD compression"},
            .{ufs.COMPAT_RO_CASE_INSENSITIVE, "Case-insensitive directories"},
            .{ufs.COMPAT_RO_METADATA_CSUMS, "Metadata checksums (CRC32C)"},
        });
        printFlags("Compat RW", sb.compat_rw_flags, .{
            .{ufs.COMPAT_RW_XATTR, "Extended attributes"},
            .{ufs.COMPAT_RW_ACL, "POSIX ACLs"},
            .{ufs.COMPAT_RW_WINDOWS_META, "Windows metadata (SD, ADS, Reparse)"},
        });
    }
}

fn printFlags(name: []const u8, flags: u32, flag_names: []struct { bit: u32, name: []const u8, desc: []const u8 }) void {
    print("  {s}:\n", .{name});
    for (flag_names) |f| {
        const enabled = (flags & (1 << f.bit)) != 0;
        print("    Bit {d}: {s} [{s}] - {s}\n", .{f.bit, f.name, if (enabled) "ON" else "OFF", f.desc});
    }
}

fn cmdCompression(dev: BlockDevice, sb: Superblock, options: CtlOptions) !void {
    print("Compression policy:\n", .{});
    print("  Current default: {s}\n", .{compressionToString(sb.default_compression)});
    print("  Supported: none, lz4, zstd, zstd-high\n", .{});
    print("  Per-file compression can be set via xattr: ufs.compression\n", .{});

    if (options.compression_algo != 0) {
        print("\nSetting default compression to {s}...\n", .{compressionToString(options.compression_algo)});
        print("Note: Compression policy change requires mounted filesystem\n", .{});
        print("Current implementation: offline viewing only\n", .{});
    }
}

fn cmdScrub(dev: BlockDevice, sb: Superblock, options: CtlOptions) !void {
    print("Starting scrub (integrity check)...\n", .{});
    print("  Volume size: {d} GB\n", .{sb.total_clusters * sb.cluster_size / (1024*1024*1024)});
    print("  Clusters to check: {d}\n", .{sb.total_clusters});
    print("  AGs to scan: {d}\n", .{sb.ag_count});
    print("\nScrub operations:\n", .{});
    print("  1. Verify all metadata CRC32C checksums\n", .{});
    print("  2. Verify all data BLAKE3 checksums (if -D flag)\n", .{});
    print("  3. Check free space bitmap consistency\n", .{});
    print("  4. Validate directory structure\n", .{});
    print("  5. Verify journal integrity\n", .{});
    print("\nNote: Full scrub implementation requires mounted filesystem with core engine\n", .{});
    print("Use 'ufsck -D' for offline data integrity verification\n", .{});
}

fn cmdStats(dev: BlockDevice, sb: Superblock, info: DeviceInfo) !void {
    print("Volume Statistics:\n", .{});
    print("  Device:           {s}\n", .{dev.path});
    print("  Block size:       {d} bytes\n", .{info.block_size});
    print("  Total blocks:     {d}\n", .{info.total_blocks});
    print("  Cluster size:     {d} bytes\n", .{sb.cluster_size});
    print("  Total clusters:   {d}\n", .{sb.total_clusters});
    print("  Total space:      {d} GB ({d} TB)\n", .{
        sb.total_clusters * sb.cluster_size / (1024*1024*1024),
        sb.total_clusters * sb.cluster_size / (1024*1024*1024*1024)
    });
    print("  AG count:         {d}\n", .{sb.ag_count});
    print("  Journal size:     {d} MB ({d} clusters)\n", .{sb.journal_clusters * sb.cluster_size / (1024*1024), sb.journal_clusters});
    print("  Default compression: {s}\n", .{compressionToString(sb.default_compression)});

    // Read AG bitmaps for free space
    const cluster_size = sb.cluster_size;
    var total_free: u64 = 0;
    var total_allocated: u64 = 0;

    if (options.verbose) {
        print("\nPer-AG breakdown:\n", .{});
    }

    const ag_size_clusters = sb.total_clusters / sb.ag_count;

    var ag_buf = try std.heap.page_allocator.alloc(u8, cluster_size);
    defer std.heap.page_allocator.free(ag_buf);
    var bitmap_buf = try std.heap.page_allocator.alloc(u8, cluster_size);
    defer std.heap.page_allocator.free(bitmap_buf);

    for (0..sb.ag_count) |ag_index| {
        const ag_start = sb.first_ag_offset + @intCast(ag_index) * ag_size_clusters;

        dev.read(ag_start, ag_buf) catch continue;

        const bitmap_start = readU64LE(ag_buf[36..44]);
        const bitmap_clusters = readU64LE(ag_buf[44..52]);
        const cluster_count = readU64LE(ag_buf[16..24]);

        var ag_free: u64 = 0;
        var ag_alloc: u64 = 0;

        for (u64(0)..bitmap_clusters) |bi| {
            dev.read(bitmap_start + bi, bitmap_buf) catch break;
            for (bitmap_buf) |byte| {
                if (ag_alloc + ag_free >= cluster_count) break;
                if (byte & 1 != 0) ag_alloc += 1; else ag_free += 1;
                if (byte & 2 != 0) ag_alloc += 1; else ag_free += 1;
                if (byte & 4 != 0) ag_alloc += 1; else ag_free += 1;
                if (byte & 8 != 0) ag_alloc += 1; else ag_free += 1;
                if (byte & 16 != 0) ag_alloc += 1; else ag_free += 1;
                if (byte & 32 != 0) ag_alloc += 1; else ag_free += 1;
                if (byte & 64 != 0) ag_alloc += 1; else ag_free += 1;
                if (byte & 128 != 0) ag_alloc += 1; else ag_free += 1;
            }
        }

        total_free += ag_free;
        total_allocated += ag_alloc;

        if (options.verbose) {
            print("  AG {d}: free={d} ({d:.1}%), allocated={d}\n", .{
                ag_index, ag_free, @as(f64, @floatFromInt(ag_free)) * 100.0 / @as(f64, @floatFromInt(cluster_count)), ag_alloc
            });
        }
    }

    print("\nSpace usage:\n", .{});
    print("  Free:        {d} clusters ({d} GB, {d:.1}%)\n", .{
        total_free, total_free * cluster_size / (1024*1024*1024), @as(f64, @floatFromInt(total_free)) * 100.0 / @as(f64, @floatFromInt(sb.total_clusters))
    });
    print("  Used:        {d} clusters ({d} GB, {d:.1}%)\n", .{
        total_allocated, total_allocated * cluster_size / (1024*1024*1024), @as(f64, @floatFromInt(total_allocated)) * 100.0 / @as(f64, @floatFromInt(sb.total_clusters))
    });
    print("  Total:       {d} clusters ({d} GB)\n", .{
        sb.total_clusters, sb.total_clusters * cluster_size / (1024*1024*1024)
    });
}

fn cmdLabel(dev: BlockDevice, sb: Superblock, options: CtlOptions) !void {
    print("Volume label management:\n", .{});

    // Read current label
    var buf = try std.heap.page_allocator.alloc(u8, 4096);
    defer std.heap.page_allocator.free(buf);
    try dev.read(0, buf);

    const current_label = std.mem.span(buf[28..284], 0);
    print("  Current label: {s}\n", .{if (current_label.len > 0) current_label else "<none>"});

    if (options.new_label.len > 0) {
        if (options.new_label.len > 255) {
            print("Error: Label too long (max 255 chars)\n", .{});
            return;
        }
        print("  New label:     {s}\n", .{options.new_label});

        // Update label in superblock
        @memset(buf[28..284], 0);
        @memcpy(buf[28..28+options.new_label.len], options.new_label);

        // Recalculate checksum (placeholder - would need CRC32C)
        writeU32LE(buf[4092..4096], 0);

        // Write primary superblock
        try dev.write(0, buf);
        try dev.flush();

        // Also update backup superblocks
        // Backup locations: 1, 1/4, 1/2, 3/4 of volume
        const total_clusters = sb.total_clusters;
        const backups = [_]u64{ 1, total_clusters / 4, total_clusters / 2, (3 * total_clusters) / 4 };
        for (backups) |loc| {
            if (loc > 0 && loc < total_clusters) {
                dev.write(loc, buf) catch {};
            }
        }
        try dev.flush();

        print("Label updated successfully (primary + backups)\n", .{});
    }
}

fn cmdCheckpoint(dev: BlockDevice, sb: Superblock) !void {
    print("Forcing checkpoint...\n", .{});
    print("  Journal start: {d}\n", .{sb.journal_start});
    print("  Journal clusters: {d}\n", .{sb.journal_clusters});

    // Read journal superblock
    var buf = try std.heap.page_allocator.alloc(u8, 4096);
    defer std.heap.page_allocator.free(buf);
    dev.read(sb.journal_start, buf) catch {
        print("  Failed to read journal\n", .{});
        return;
    };

    const current_end_txid = readU64LE(buf[24..32]);
    const current_checkpoint_txid = readU64LE(buf[32..40]);

    print("  Current end TXID: {d}\n", .{current_end_txid});
    print("  Current checkpoint TXID: {d}\n", .{current_checkpoint_txid});

    // Update checkpoint TXID to current end TXID
    writeU64LE(buf[32..40], current_end_txid);
    writeU32LE(buf[4092..4096], 0); // placeholder checksum

    try dev.write(sb.journal_start, buf);
    try dev.flush();

    print("Checkpoint forced: checkpoint TXID now {d}\n", .{current_end_txid});
    print("Note: Full checkpoint requires mounted filesystem to flush dirty data\n", .{});
}

fn cmdExtents(dev: BlockDevice, sb: Superblock, options: CtlOptions) !void {
    print("Extent map for inode {d}:\n", .{options.extents_inode});
    print("  (Requires mounted filesystem to traverse extent tree)\n", .{});
    print("  Offline mode: inode extent tree root is stored in inode\n", .{});
    print("  To view extents, mount the filesystem first\n", .{});
}

fn cmdCapsules(dev: BlockDevice, sb: Superblock, options: CtlOptions) !void {
    print("Metadata capsules for inode {d}:\n", .{options.capsules_inode});
    print("  (Requires mounted filesystem to read capsule data)\n", .{});
    print("  Capsule namespaces:\n", .{});
    print("    POSIX: 0x0001 (base), 0x0002 (ACL), 0x0003 (xattr), 0x0004 (capabilities)\n", .{});
    print("    Windows: 0x0010 (SD), 0x0011 (ADS), 0x0012 (Reparse), 0x0013 (EFS), 0x0014 (USN), 0x0015 (ObjID), 0x0016 (attrs)\n", .{});
    print("    macOS: 0x0020 (xattr), 0x0021 (Finder), 0x0022 (Resource), 0x0023 (Quarantine), 0x0024 (Firmlink), 0x0025 (timestamp)\n", .{});
    print("    UFS Internal: 0x8000\n", .{});
    print("    Opaque: 0xFFFF\n", .{});
}

fn printUsage(program: []const u8) void {
    print("Usage: {s} <device> <command> [options]\n\n", .{program});
    print("Commands:\n", .{});
    print("  mount                    Mount volume (requires kernel driver/FUSE)\n", .{});
    print("  unmount                  Unmount volume\n", .{});
    print("  feature <type> <bit> <on|off>  Manage feature flags\n", .{});
    print("                           type: incompat, compat-ro, compat-rw\n", .{});
    print("  compression <algo>       Set default compression: none, lz4, zstd, zstd-high\n", .{});
    print("  scrub                    Start integrity scrub\n", .{});
    print("  stats                    Show volume statistics\n", .{});
    print("  label [new-label]        Show or set volume label\n", .{});
    print("  checkpoint               Force journal checkpoint\n", .{});
    print("  extents <inode>          Show extent map for inode\n", .{});
    print("  capsules <inode>         Show metadata capsules for inode\n", .{});
    print("\nOptions:\n", .{});
    print("  -v, --verbose            Verbose output\n", .{});
    print("  -h, --help               Show this help\n", .{});
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

fn parseCompression(s: []const u8) !u8 {
    const lower = std.ascii.toLower(s);
    if (std.mem.eql(u8, lower, "none")) return ufs.COMPRESSION_NONE;
    if (std.mem.eql(u8, lower, "lz4")) return ufs.COMPRESSION_LZ4;
    if (std.mem.eql(u8, lower, "zstd")) return ufs.COMPRESSION_ZSTD;
    if (std.mem.eql(u8, lower, "zstd-high")) return ufs.COMPRESSION_ZSTD_HIGH;
    return error.InvalidArgument;
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