// UFS FUSE Driver
// Filesystem in Userspace implementation for UFS

const std = @import("std");
const ufs = @import("ufs");

const Allocator = std.mem.Allocator;
const print = std.debug.print;

// FUSE operations we'll implement
const FuseOperations = extern struct {
    getattr: *const fn (path: [*c]const u8, stbuf: *c.struct_stat) c_int,
    readdir: *const fn (path: [*c]const u8, buf: *c.void, filler: *c.void, offset: c_off_t, fi: *c.struct_fuse_file_info, flags: c_int) c_int,
    open: *const fn (path: [*c]const u8, fi: *c.struct_fuse_file_info) c_int,
    read: *const fn (path: [*c]const u8, buf: [*c]u8, size: c_size_t, offset: c_off_t, fi: *c.struct_fuse_file_info) c_int,
    write: *const fn (path: [*c]const u8, buf: [*c]const u8, size: c_size_t, offset: c_off_t, fi: *c.struct_fuse_file_info) c_int,
    release: *const fn (path: [*c]const u8, fi: *c.struct_fuse_file_info) c_int,
    mkdir: *const fn (path: [*c]const u8, mode: c_mode_t) c_int,
    rmdir: *const fn (path: [*c]const u8) c_int,
    unlink: *const fn (path: [*c]const u8) c_int,
    rename: *const fn (from: [*c]const u8, to: [*c]const u8, flags: c_uint) c_int,
    create: *const fn (path: [*c]const u8, mode: c_mode_t, fi: *c.struct_fuse_file_info) c_int,
    truncate: *const fn (path: [*c]const u8, offset: c_off_t, fi: *c.struct_fuse_file_info) c_int,
    utimens: *const fn (path: [*c]const u8, ts: [*c]c.struct_timespec) c_int,
    statfs: *const fn (path: [*c]const u8, stbuf: *c.struct_statvfs) c_int,
    init: *const fn (conn: *c.struct_fuse_conn_info, cfg: *c.struct_fuse_config) *c.void,
    destroy: *const fn (private_data: *c.void) c_void,
    fsync: *const fn (path: [*c]const u8, datasync: c_int, fi: *c.struct_fuse_file_info) c_int,
    setxattr: *const fn (path: [*c]const u8, name: [*c]const u8, value: [*c]const u8, size: c_size_t, flags: c_int) c_int,
    getxattr: *const fn (path: [*c]const u8, name: [*c]const u8, value: [*c]u8, size: c_size_t) c_int,
    listxattr: *const fn (path: [*c]const u8, list: [*c]u8, size: c_size_t) c_int,
    removexattr: *const fn (path: [*c]const u8, name: [*c]const u8) c_int,
};

// FUSE context
const FuseContext = extern struct {
    uid: c_uid_t,
    gid: c_gid_t,
    pid: c_pid_t,
    private_data: *c.void,
    umask: c_mode_t,
};

// UFS FUSE state
const UfsFuse = struct {
    fs: *ufs.Fs,
    block_dev: *ufs.BlockDevice,
    mount_options: MountOptions,
};

const MountOptions = struct {
    read_only: bool,
    case_insensitive: bool,
    compression: u8,
    integrity_check: u8,
    journal_size: u64,
    uid: c_uid_t,
    gid: c_gid_t,
    umask: c_mode_t,
};

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
    if (args.len < 3) {
        printUsage(args[0] orelse "ufs-fuse");
        return;
    }

    const device_path = args[1];
    const mount_point = args[2];

    var options = MountOptions{
        .read_only = false,
        .case_insensitive = true,
        .compression = ufs.COMPRESSION_LZ4,
        .integrity_check = 1, // metadata only
        .journal_size = 0,
        .uid = 0,
        .gid = 0,
        .umask = 0o022,
    };

    var fuse_args = std.ArrayList([]const u8).init(allocator);
    defer fuse_args.deinit();

    // Add program name
    try fuse_args.append(args[0]);

    // Parse options
    var i: usize = 3;
    while (i < args.len) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printUsage(args[0] orelse "ufs-fuse");
            return;
        } else if (std.mem.eql(u8, arg, "-o")) {
            i += 1;
            if (i >= args.len) return error.InvalidArgument;
            try parseMountOptions(allocator, args[i], &options);
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--foreground")) {
            try fuse_args.append("-f");
        } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--debug")) {
            try fuse_args.append("-d");
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--single-threaded")) {
            try fuse_args.append("-s");
        } else {
            // Pass through to FUSE
            try fuse_args.append(arg);
        }
        i += 1;
    }

    // Add mount point
    try fuse_args.append(mount_point);

    // Open block device
    const block_dev = try ufs.BlockDevice.open(allocator, device_path, options);
    defer block_dev.close();

    // Check if filesystem needs recovery
    if (ufs.needsRecovery(block_dev)) {
        print("Filesystem needs recovery, running...\n", .{});
        try ufs.recover(block_dev);
    }

    // Mount filesystem
    const mount_opts = ufs.MountOptions{
        .read_only = options.read_only,
        .case_insensitive = options.case_insensitive,
        .compression = options.compression,
        .integrity_check = options.integrity_check,
        .journal_size = options.journal_size,
    };

    var fs = try ufs.mount(block_dev, &mount_opts);
    defer ufs.unmount(fs);

    // Set up FUSE operations
    const fuse_ops = FuseOperations{
        .getattr = getattr,
        .readdir = readdir,
        .open = open,
        .read = read,
        .write = write,
        .release = release,
        .mkdir = mkdir,
        .rmdir = rmdir,
        .unlink = unlink,
        .rename = rename,
        .create = create,
        .truncate = truncate,
        .utimens = utimens,
        .statfs = statfs,
        .init = init,
        .destroy = destroy,
        .fsync = fsync,
        .setxattr = setxattr,
        .getxattr = getxattr,
        .listxattr = listxattr,
        .removexattr = removexattr,
    };

    // Create UFS FUSE state
    var ufs_fuse = UfsFuse{
        .fs = fs,
        .block_dev = block_dev,
        .mount_options = options,
    };

    // Start FUSE main loop
    // Note: This is a simplified version - real implementation would use libfuse C API
    print("Starting UFS FUSE mount at {s}...\n", .{mount_point});
    print("Device: {s}\n", .{device_path});
    print("Options: ro={}, case_insensitive={}, compression={}\n", .{
        options.read_only, options.case_insensitive, compressionToString(options.compression)
    });

    // In real implementation, we would call fuse_main() here
    // For now, we'll show the structure
    _ = fuse_ops;
    _ = ufs_fuse;

    print("FUSE driver structure ready. Need to link with libfuse for actual mounting.\n", .{});
}

fn parseMountOptions(allocator: Allocator, opt_str: []const u8, options: *MountOptions) !void {
    const parts = std.mem.split(u8, opt_str, ",");
    for (parts) |part| {
        const kv = std.mem.split(u8, part, "=");
        const items = try kv.toOwnedSlice();
        defer allocator.free(items);

        if (items.len == 1) {
            const key = items[0];
            if (std.mem.eql(u8, key, "ro")) options.read_only = true;
            else if (std.mem.eql(u8, key, "rw")) options.read_only = false;
            else if (std.mem.eql(u8, key, "case_insensitive")) options.case_insensitive = true;
            else if (std.mem.eql(u8, key, "no_case_insensitive")) options.case_insensitive = false;
        } else if (items.len == 2) {
            const key = items[0];
            const value = items[1];
            if (std.mem.eql(u8, key, "compression")) {
                options.compression = try parseCompression(value);
            } else if (std.mem.eql(u8, key, "integrity")) {
                if (std.mem.eql(u8, value, "none")) options.integrity_check = 0;
                else if (std.mem.eql(u8, value, "meta")) options.integrity_check = 1;
                else if (std.mem.eql(u8, value, "full")) options.integrity_check = 2;
            } else if (std.mem.eql(u8, key, "uid")) {
                options.uid = try std.fmt.parseInt(c_uid_t, value, 10);
            } else if (std.mem.eql(u8, key, "gid")) {
                options.gid = try std.fmt.parseInt(c_gid_t, value, 10);
            } else if (std.mem.eql(u8, key, "umask")) {
                options.umask = try std.fmt.parseInt(c_mode_t, value, 8);
            }
        }
    }
}

fn parseCompression(s: []const u8) !u8 {
    const lower = std.ascii.toLower(s);
    if (std.mem.eql(u8, lower, "none")) return ufs.COMPRESSION_NONE;
    if (std.mem.eql(u8, lower, "lz4")) return ufs.COMPRESSION_LZ4;
    if (std.mem.eql(u8, lower, "zstd")) return ufs.COMPRESSION_ZSTD;
    if (std.mem.eql(u8, lower, "zstd-high")) return ufs.COMPRESSION_ZSTD_HIGH;
    return error.InvalidArgument;
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

fn printUsage(program: []const u8) void {
    print("Usage: {s} <device> <mountpoint> [options]\n\n", .{program});
    print("Options:\n", .{});
    print("  -o opt,[opt...]          Mount options\n", .{});
    print("      ro                   Read-only mount\n", .{});
    print("      rw                   Read-write mount (default)\n", .{});
    print("      case_insensitive     Case-insensitive lookup (default)\n", .{});
    print("      no_case_insensitive  Case-sensitive lookup\n", .{});
    print("      compression=algo     Default compression: none, lz4, zstd, zstd-high (default: lz4)\n", .{});
    print("      integrity=level      Integrity: none, meta, full (default: meta)\n", .{});
    print("      uid=N                Override uid\n", .{});
    print("      gid=N                Override gid\n", .{});
    print("      umask=M              Override umask (octal)\n", .{});
    print("  -f, --foreground         Foreground operation\n", .{});
    print("  -d, --debug              Enable debug output\n", .{});
    print("  -s, --single-threaded    Single-threaded operation\n", .{});
    print("  -h, --help               Show this help\n", .{});
    print("\nExample:\n", .{});
    print("  {s} /dev/sdb1 /mnt/ufs -o rw,compression=zstd\n", .{program});
    print("  {s} ufs.img /mnt/ufs -f -d\n", .{program});
}

// ============================================================================
// FUSE Operation Implementations (stubs - require libfuse linkage)
// ============================================================================

fn getattr(path: [*c]const u8, stbuf: *c.struct_stat) c_int {
    // TODO: Implement using ufs_getattr
    // 1. Lookup inode by path
    // 2. Get inode attributes
    // 3. Fill stat buffer
    _ = path; _ = stbuf;
    return -ENOSYS;
}

fn readdir(path: [*c]const u8, buf: *c.void, filler: *c.void, offset: c_off_t, fi: *c.struct_fuse_file_info, flags: c_int) c_int {
    // TODO: Implement using ufs_opendir/ufs_readdir/ufs_closedir
    // 1. Lookup directory inode
    // 2. Open directory iterator
    // 3. Fill entries using filler function
    _ = path; _ = buf; _ = filler; _ = offset; _ = fi; _ = flags;
    return -ENOSYS;
}

fn open(path: [*c]const u8, fi: *c.struct_fuse_file_info) c_int {
    // TODO: Implement using ufs_open
    _ = path; _ = fi;
    return -ENOSYS;
}

fn read(path: [*c]const u8, buf: [*c]u8, size: c_size_t, offset: c_off_t, fi: *c.struct_fuse_file_info) c_int {
    // TODO: Implement using ufs_read
    _ = path; _ = buf; _ = size; _ = offset; _ = fi;
    return -ENOSYS;
}

fn write(path: [*c]const u8, buf: [*c]const u8, size: c_size_t, offset: c_off_t, fi: *c.struct_fuse_file_info) c_int {
    // TODO: Implement using ufs_write
    _ = path; _ = buf; _ = size; _ = offset; _ = fi;
    return -ENOSYS;
}

fn release(path: [*c]const u8, fi: *c.struct_fuse_file_info) c_int {
    // TODO: Implement using ufs_close
    _ = path; _ = fi;
    return 0;
}

fn mkdir(path: [*c]const u8, mode: c_mode_t) c_int {
    // TODO: Implement using ufs_mkdir
    _ = path; _ = mode;
    return -ENOSYS;
}

fn rmdir(path: [*c]const u8) c_int {
    // TODO: Implement using ufs_rmdir
    _ = path;
    return -ENOSYS;
}

fn unlink(path: [*c]const u8) c_int {
    // TODO: Implement using ufs_delete_inode
    _ = path;
    return -ENOSYS;
}

fn rename(from: [*c]const u8, to: [*c]const u8, flags: c_uint) c_int {
    // TODO: Implement using ufs_rename
    _ = from; _ = to; _ = flags;
    return -ENOSYS;
}

fn create(path: [*c]const u8, mode: c_mode_t, fi: *c.struct_fuse_file_info) c_int {
    // TODO: Implement using ufs_create_inode + ufs_open
    _ = path; _ = mode; _ = fi;
    return -ENOSYS;
}

fn truncate(path: [*c]const u8, offset: c_off_t, fi: *c.struct_fuse_file_info) c_int {
    // TODO: Implement using ufs_truncate
    _ = path; _ = offset; _ = fi;
    return -ENOSYS;
}

fn utimens(path: [*c]const u8, ts: [*c]c.struct_timespec) c_int {
    // TODO: Implement using ufs_setattr
    _ = path; _ = ts;
    return -ENOSYS;
}

fn statfs(path: [*c]const u8, stbuf: *c.struct_statvfs) c_int {
    // TODO: Implement using ufs_statfs
    _ = path; _ = stbuf;
    return -ENOSYS;
}

fn init(conn: *c.struct_fuse_conn_info, cfg: *c.struct_fuse_config) *c.void {
    // TODO: Initialize FUSE connection
    _ = conn; _ = cfg;
    return nullptr;
}

fn destroy(private_data: *c.void) c_void {
    // TODO: Cleanup
    _ = private_data;
}

fn fsync(path: [*c]const u8, datasync: c_int, fi: *c.struct_fuse_file_info) c_int {
    // TODO: Implement using ufs_fsync
    _ = path; _ = datasync; _ = fi;
    return -ENOSYS;
}

fn setxattr(path: [*c]const u8, name: [*c]const u8, value: [*c]const u8, size: c_size_t, flags: c_int) c_int {
    // TODO: Implement using ufs_setxattr with namespace detection from name
    _ = path; _ = name; _ = value; _ = size; _ = flags;
    return -ENOSYS;
}

fn getxattr(path: [*c]const u8, name: [*c]const u8, value: [*c]u8, size: c_size_t) c_int {
    // TODO: Implement using ufs_getxattr
    _ = path; _ = name; _ = value; _ = size;
    return -ENOSYS;
}

fn listxattr(path: [*c]const u8, list: [*c]u8, size: c_size_t) c_int {
    // TODO: Implement using ufs_listxattr
    _ = path; _ = list; _ = size;
    return -ENOSYS;
}

fn removexattr(path: [*c]const u8, name: [*c]const u8) c_int {
    // TODO: Implement using ufs_removexattr
    _ = path; _ = name;
    return -ENOSYS;
}