// UFS C API Implementation
// Exported C functions for platform drivers (FUSE, Linux VFS, Windows IFS, macOS, UEFI)

const std = @import("std");
const serialization = @import("serialization.zig");
const metadata = @import("metadata.zig");
const allocation = @import("allocation.zig");
const directory = @import("directory.zig");
const journal = @import("journal.zig");
const integrity = @import("integrity.zig");
const compression = @import("compression.zig");
const version = @import("version.zig");
const blockdev = @import("blockdev.zig");
const utils = @import("utils.zig");

const Allocator = std.mem.Allocator;

// C-compatible error codes (matching ufs.h)
pub const UFS_OK = 0;
pub const UFS_ERROR_OUT_OF_MEMORY = -1;
pub const UFS_ERROR_INVALID_ARGUMENT = -2;
pub const UFS_ERROR_IO = -3;
pub const UFS_ERROR_NOT_FOUND = -4;
pub const UFS_ERROR_ALREADY_EXISTS = -5;
pub const UFS_ERROR_PERMISSION_DENIED = -6;
pub const UFS_ERROR_CORRUPTED_DATA = -7;
pub const UFS_ERROR_UNSUPPORTED_FEATURE = -8;
pub const UFS_ERROR_BUFFER_TOO_SMALL = -9;
pub const UFS_ERROR_INVALID_FORMAT = -10;
pub const UFS_ERROR_INTERNAL = -11;
pub const UFS_ERROR_OUT_OF_SPACE = -12;
pub const UFS_ERROR_ALIGNMENT = -13;
pub const UFS_ERROR_FRAGMENTED = -14;
pub const UFS_ERROR_NOT_INITIALIZED = -15;
pub const UFS_ERROR_WRITE_PROTECTED = -16;
pub const UFS_ERROR_DEVICE_NOT_FOUND = -17;
pub const UFS_ERROR_UNSUPPORTED_OPERATION = -18;
pub const UFS_ERROR_TIMEOUT = -19;

// Map Zig errors to UFS error codes
fn mapError(err: anyerror) i32 {
    return switch (@errorName(err)) {
        "OutOfMemory" => UFS_ERROR_OUT_OF_MEMORY,
        "InvalidArgument" => UFS_ERROR_INVALID_ARGUMENT,
        "IoError" => UFS_ERROR_IO,
        "NotFound" => UFS_ERROR_NOT_FOUND,
        "AlreadyExists" => UFS_ERROR_ALREADY_EXISTS,
        "PermissionDenied" => UFS_ERROR_PERMISSION_DENIED,
        "CorruptedData" => UFS_ERROR_CORRUPTED_DATA,
        "UnsupportedFeature" => UFS_ERROR_UNSUPPORTED_FEATURE,
        "BufferTooSmall" => UFS_ERROR_BUFFER_TOO_SMALL,
        "InvalidFormat" => UFS_ERROR_INVALID_FORMAT,
        "InternalError" => UFS_ERROR_INTERNAL,
        "OutOfSpace" => UFS_ERROR_OUT_OF_SPACE,
        "AlignmentError" => UFS_ERROR_ALIGNMENT,
        "FragmentedAllocation" => UFS_ERROR_FRAGMENTED,
        "NotInitialized" => UFS_ERROR_NOT_INITIALIZED,
        "WriteProtected" => UFS_ERROR_WRITE_PROTECTED,
        "DeviceNotFound" => UFS_ERROR_DEVICE_NOT_FOUND,
        "UnsupportedOperation" => UFS_ERROR_UNSUPPORTED_OPERATION,
        "Timeout" => UFS_ERROR_TIMEOUT,
        else => UFS_ERROR_INTERNAL,
    };
}

// Filesystem handle
const Fs = struct {
    const Self = @This();
    device: *blockdev.BlockDevice,
    allocator: Allocator,
    cluster_size: u32,
    mount_options: MountOptions,
    ag_manager: ?allocation.AllocationGroupManager = null,
    journal_writer: ?journal.JournalWriter = null,
    superblock: version.VolumeFormat,
    root_inode: u64 = 2,
    next_file_handle_id: usize = 1,
    file_handles: std.ArrayList(FileHandle) = std.ArrayList(FileHandle).init(std.heap.page_allocator),

    pub const MountOptions = struct {
        read_only: bool,
        case_insensitive: bool,
        compression: u8,
        integrity_check: u8,
        journal_size: u64,
        cluster_size: u32 = 0, // Optional, for validation
    };

    pub fn init(
        device: *blockdev.BlockDevice,
        allocator: Allocator,
        options: MountOptions,
    ) !Fs {
        const sb = try version.VolumeFormat.load(device, allocator);
        return .{
            .device = device,
            .allocator = allocator,
            .cluster_size = sb.cluster_size,
            .mount_options = options,
            .superblock = sb,
            .file_handles = std.ArrayList(FileHandle).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.journal_writer) |*jw| {
            jw.deinit();
        }
        if (self.ag_manager) |*agm| {
            agm.deinit();
        }
        self.file_handles.deinit();
    }
};

// No global state - filesystem handle is passed explicitly to each function
// This ensures thread safety for multi-threaded platform drivers

// Convert C mount options to Zig mount options
fn convertMountOptions(c_opts: *MountOptionsC) MountOptions {
    return .{
        .read_only = c_opts.read_only != 0,
        .case_insensitive = c_opts.case_insensitive != 0,
        .compression = @as(u8, @intCast(c_opts.compression)),
        .integrity_check = @as(u8, @intCast(c_opts.integrity_check)),
        .journal_size = c_opts.journal_size,
        .cluster_size = 0, // Not in C struct
    };
}

// C-compatible mount options (matching ufs.h)
const MountOptionsC = extern struct {
    read_only: c_int,
    case_insensitive: c_int,
    compression: c_int,
    integrity_check: c_int,
    journal_size: u64,
};

// C-compatible statfs structure (matching ufs.h)
const Statfs = extern struct {
    total_space: u64,
    free_space: u64,
    total_inodes: u64,
    free_inodes: u64,
    cluster_size: u32,
    ag_count: u32,
};

// C-compatible inode info structure (matching ufs.h)
const InodeInfo = extern struct {
    inode: u64,
    mode: u32,
    uid: u32,
    gid: u32,
    size: u64,
    allocated_size: u64,
    link_count: u32,
    flags: u32,
    atime: u64,
    mtime: u64,
    ctime: u64,
    crtime: u64,
    type: u8,
};

// C-compatible directory entry structure (matching ufs.h)
const Dirent = extern struct {
    inode: u64,
    name: [256]c_char,
    type: u8,
};

// C-compatible extent structure (matching ufs.h)
const Extent = extern struct {
    logical_offset: u64,
    physical_offset: u64,
    length: u64,
    compression: u8,
    flags: c_int,
};

// C-compatible scrub result structure (matching ufs.h)
const ScrubResult = extern struct {
    checked: u64,
    errors: u64,
    corrupted_files: u64,
};

// ============================================================================
// Block Device Operations (C API)
// ============================================================================

// Note: The block device is created by the platform driver and passed to ufs_format/ufs_mount
// We don't need to implement the block device vtable here

// File-backed block device for testing (Linux/macOS/WSL)
export fn ufs_block_device_open(path: [*c]const u8, flags: i32) *blockdev.BlockDevice {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    // Note: Arena is leaked intentionally - block device lives until ufs_block_device_close
    const allocator = arena.allocator();

    const zig_flags = blockdev.BlockDeviceFlags{
        .read_only = flags != 0,
        .write_cache = true,
        .flush_on_write = false,
        .direct_io = false,
        .async_io = false,
    };

    const device = blockdev.createFileBlockDevice(allocator, std.mem.span(path), zig_flags) catch return null;

    // Store arena allocator in device context for cleanup
    // We'll use a wrapper to track the arena
    return device;
}

export fn ufs_block_device_close(device: *blockdev.BlockDevice) i32 {
    if (device == null) return UFS_ERROR_INVALID_ARGUMENT;

    // Close the underlying file
    device.close() catch {};

    // Free the device struct (arena allocator will be freed when process exits)
    // In production, we'd track the arena properly
    return UFS_OK;
}

// ============================================================================
// Core Filesystem Operations (C API)
// ============================================================================

// Format a new UFS volume
export fn ufs_format(
    device: *blockdev.BlockDevice,
    label: [*c]const u8,
    cluster_size: u32,
    compression_algo: i32,
    journal_size_clusters: u64,
    ag_count: u32,
) i32 {
    // Create a temporary allocator for formatting
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Validate cluster size
    if (cluster_size < 512 || cluster_size > 65536 || (cluster_size & (cluster_size - 1)) != 0) {
        return UFS_ERROR_INVALID_ARGUMENT;
    }

    // Validate compression algorithm
    if (compression_algo < 0 || compression_algo > 3) {
        return UFS_ERROR_INVALID_ARGUMENT;
    }

    // Format the volume
    const vol_fmt =  version.VolumeFormat.create(
        allocator,
        device,
        cluster_size,
        @as(u8, @intCast(compression_algo)),
        journal_size_clusters,
        ag_count,
        label,
    ) catch |err| return mapError(err);

    // Write superblock
     vol_fmt.write(device, allocator) catch |err| return mapError(err);

    // Initialize journal
    const jw =  journal.JournalWriter.init(
        device,
        vol_fmt.journal_offset,
        vol_fmt.journal_size,
        cluster_size,
        allocator,
    ) catch |err| return mapError(err);

    // Initialize allocation groups
    const agm =  allocation.AllocationGroupManager.init(
        device,
        cluster_size,
        vol_fmt.ag_count,
        vol_fmt.ag_size,
        vol_fmt.ag_table_offset,
        vol_fmt.first_ag_offset,
        allocator,
    ) catch |err| return mapError(err);

    // Load first AG to create root directory
     agm.loadAG(0) catch |err| return mapError(err);

    // Create root directory inode (inode 2)
    const root_capsule =  metadata.createPosixBaseCapsule(
        allocator,
        2, // root inode
        0o040755, // directory mode
        0, 0, // uid, gid
        utils.timestamp(), utils.timestamp(), utils.timestamp(), utils.timestamp(), // atime, mtime, ctime, crtime
        2, // link_count (., ..)
    ) catch |err| return mapError(err);
    defer root_capsule.deinit();

    // Serialize root capsule
    var cap_writer = serialization.createWriter(allocator);
    defer cap_writer.deinit();
     root_capsule.serialize(&cap_writer) catch |err| return mapError(err);
    const capsule_data = cap_writer.bytes();

    // Allocate capsule cluster
    const capsule_cluster =  agm.allocateClusters(1, .{}) catch |err| return mapError(err);
     device.write(capsule_cluster.start_cluster * cluster_size, capsule_data) catch |err| return mapError(err);

    // Create root inode
    var inode_writer = serialization.createWriter(allocator);
    defer inode_writer.deinit();

     inode_writer.writeU32(0x494E4F00) catch |err| return mapError(err); // magic
     inode_writer.writeU16(1) catch |err| return mapError(err); // version
     inode_writer.writeU16(0x0002) catch |err| return mapError(err); // flags (directory)
     inode_writer.writeU64(2) catch |err| return mapError(err); // inode_number
     inode_writer.writeU64(1) catch |err| return mapError(err); // generation
     inode_writer.writeU64(root_capsule.header.capsule_id) catch |err| return mapError(err); // capsule_id
     inode_writer.writeU32(0o040755) catch |err| return mapError(err); // mode
     inode_writer.writeU32(0) catch |err| return mapError(err); // uid
     inode_writer.writeU32(0) catch |err| return mapError(err); // gid
     inode_writer.writeU32(2) catch |err| return mapError(err); // link_count
     inode_writer.writeU32(0) catch |err| return mapError(err); // flags2
     inode_writer.writeU32(0) catch |err| return mapError(err); // reserved1
     inode_writer.writeU64(0) catch |err| return mapError(err); // size
     inode_writer.writeU64(cluster_size) catch |err| return mapError(err); // allocated_size
    const now = utils.timestamp();
     inode_writer.writeU64(now) catch |err| return mapError(err); // atime
     inode_writer.writeU64(now) catch |err| return mapError(err); // mtime
     inode_writer.writeU64(now) catch |err| return mapError(err); // ctime
     inode_writer.writeU64(0) catch |err| return mapError(err); // extent_tree_root (inline)
     inode_writer.writeU16(0) catch |err| return mapError(err); // extent_count
     inode_writer.writeU16(0) catch |err| return mapError(err); // extent_tree_height
     inode_writer.writeU32(0) catch |err| return mapError(err); // reserved2
     inode_writer.writeU16(0) catch |err| return mapError(err); // compression_algo
     inode_writer.writeU16(0) catch |err| return mapError(err); // compression_level
     inode_writer.writeU32(0) catch |err| return mapError(err); // encryption_key_id
     inode_writer.writeU64(0) catch |err| return mapError(err); // reserved3
     inode_writer.writeU64(capsule_cluster.start_cluster) catch |err| return mapError(err); // capsule_offset
     inode_writer.writeU32(@as(u32, @intCast(capsule_data.len))) catch |err| return mapError(err); // capsule_size
     inode_writer.writeU32(0) catch |err| return mapError(err); // capsule_flags
    for (0..112) |_| {  inode_writer.writeU8(0) catch |err| return mapError(err); } // reserved

    try inode_writer.align(256);
    const inode_crc = utils.crc32c(inode_writer.bytes());
     inode_writer.writeU32(inode_crc) catch |err| return mapError(err);

    const inode_data = inode_writer.bytes();
    const inode_table_base = vol_fmt.first_ag_offset + 10; // inode table starts at cluster 10 of AG
     device.write((inode_table_base + 2) * cluster_size, inode_data) catch |err| return mapError(err);

    // Create root directory entries (., ..)
    var dir = directory.LinearDirectory.init(allocator, 64);
    defer dir.deinit();

     dir.insert(directory.DirEntry{
        .inode = 2,
        .name = ".",
        .file_type = directory.DirEntry.FILE_TYPE_DIR,
        .flags = 0,
    }) catch |err| return mapError(err);
     dir.insert(directory.DirEntry{
        .inode = 2,
        .name = "..",
        .file_type = directory.DirEntry.FILE_TYPE_DIR,
        .flags = 0,
    }) catch |err| return mapError(err);

    var dir_writer = serialization.createWriter(allocator);
    defer dir_writer.deinit();
     dir.serialize(&dir_writer) catch |err| return mapError(err);
    const dir_data = dir_writer.bytes();

    // Write directory data
    const dir_cluster =  agm.allocateClusters(1, .{}) catch |err| return mapError(err);
     device.write(dir_cluster.start_cluster * cluster_size, dir_data) catch |err| return mapError(err);

    // Update root inode with extent pointing to directory data
    // (For now, we skip this - the inode is written with extent_root = 0)

    // Write journal checkpoint
     jw.checkpoint() catch |err| return mapError(err);

    // Flush
     device.flush() catch |err| return mapError(err);

    jw.deinit();
    agm.deinit();

    return UFS_OK;
}

// Mount an existing UFS volume
export fn ufs_mount(
    device: *blockdev.BlockDevice,
    options: *MountOptionsC,
    out_fs: **c_void,
) i32 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = arena.allocator();

    // Convert C options to Zig options
    const zig_opts = convertMountOptions(options);

    // Load superblock
    const sb = version.VolumeFormat.load(device, allocator) catch |err| return mapError(err);

    // Validate cluster size matches
    if (zig_opts.cluster_size != 0 && zig_opts.cluster_size != sb.cluster_size) {
        return UFS_ERROR_INVALID_ARGUMENT;
    }

    // Check if recovery needed
    const needs_recovery = journal.needsRecovery(
        device,
        sb.journal_offset,
        sb.journal_size,
        sb.cluster_size,
        allocator,
    ) catch |err| return mapError(err);

    // If recovery needed, run it before mounting
    if (needs_recovery) {
        // Initialize allocation groups first (needed for recovery)
        const agm = allocation.AllocationGroupManager.init(
            device,
            sb.cluster_size,
            sb.ag_count,
            sb.ag_size,
            sb.ag_table_offset,
            sb.first_ag_offset,
            allocator,
        ) catch |err| return mapError(err);

        // Load first AG
         agm.loadAG(0) catch |err| return mapError(err);

        // Run full recovery with filesystem context
        const recovery = journal.RecoveryEngine.init(
            device,
            sb.journal_offset,
            sb.journal_size,
            sb.cluster_size,
            allocator,
        );
         recovery.recoverFull(&agm) catch |err| return mapError(err);

        // Initialize journal after recovery
        const jw = journal.JournalWriter.init(
            device,
            sb.journal_offset,
            sb.journal_size,
            sb.cluster_size,
            allocator,
        ) catch |err| return mapError(err);

        // Create filesystem instance
        var fs =  Fs.init(device, allocator, zig_opts) catch |err| return mapError(err);
        fs.ag_manager = agm;
        fs.journal_writer = jw;

        // Allocate filesystem on heap so it persists beyond this function
        const fs_ptr = allocator.create(Fs) catch |err| return mapError(err);
        fs_ptr.* = fs;

        // Return filesystem handle
        out_fs.* = @as(*c_void, @ptrCast(fs_ptr));

        return UFS_OK;
    }

    // Initialize journal
    const jw = journal.JournalWriter.init(
        device,
        sb.journal_offset,
        sb.journal_size,
        sb.cluster_size,
        allocator,
    ) catch |err| return mapError(err);

    // Initialize allocation groups
    const agm = allocation.AllocationGroupManager.init(
        device,
        sb.cluster_size,
        sb.ag_count,
        sb.ag_size,
        sb.ag_table_offset,
        sb.first_ag_offset,
        allocator,
    ) catch |err| return mapError(err);

    // Load first AG
     agm.loadAG(0) catch |err| return mapError(err);

    // Create filesystem instance
    var fs =  Fs.init(device, allocator, zig_opts) catch |err| return mapError(err);
    fs.ag_manager = agm;
    fs.journal_writer = jw;

    // Allocate filesystem on heap so it persists beyond this function
    const fs_ptr = allocator.create(Fs) catch |err| return mapError(err);
    fs_ptr.* = fs;

    // Return filesystem handle
    out_fs.* = @as(*c_void, @ptrCast(fs_ptr));

    return UFS_OK;
}

// Unmount and cleanup
export fn ufs_unmount(fs_ptr: *c_void) i32 {
    const fs = @as(*Fs, @ptrCast(fs_ptr));
    fs.deinit();

    // Free the arena allocator (stored in fs.allocator)
    // The arena allocator will be deinit'd by the caller
    // For now, we just free the Fs struct
    fs.allocator.destroy(fs);

    return UFS_OK;
}

// Sync all dirty data to disk
export fn ufs_sync(fs_ptr: *c_void) i32 {
    const fs = @as(*Fs, @ptrCast(fs_ptr));
    return fs.device.flush() catch |err| mapError(err);
}

// Get filesystem statistics
export fn ufs_statfs(fs_ptr: *c_void, out_stat: *Statfs) i32 {
    const fs = @as(*Fs, @ptrCast(fs_ptr));

    // Get AG info
    if (fs.ag_manager) |agm| {
         agm.loadAG(0) catch |err| return mapError(err);
        const ag = &agm.groups[0];

        out_stat.total_space = fs.superblock.volume_size * fs.cluster_size;
        out_stat.free_space = ag.header.free_clusters * fs.cluster_size;
        out_stat.total_inodes = ag.header.inode_count * fs.superblock.ag_count;
        out_stat.free_inodes = ag.header.free_inodes * fs.superblock.ag_count;
        out_stat.cluster_size = fs.cluster_size;
        out_stat.ag_count = fs.superblock.ag_count;
    } else {
        out_stat.total_space = 0;
        out_stat.free_space = 0;
        out_stat.total_inodes = 0;
        out_stat.free_inodes = 0;
        out_stat.cluster_size = fs.cluster_size;
        out_stat.ag_count = 1;
    }

    return UFS_OK;
}

// ============================================================================
// Inode Operations (C API)
// ============================================================================

// Create a new inode
export fn ufs_create_inode(
    fs_ptr: *c_void,
    parent: u64,
    name: [*c]const u8,
    file_type: u8,
    mode: u32,
    uid: u32,
    gid: u32,
    out_inode: *u64,
) i32 {
    const fs = @as(*Fs, @ptrCast(fs_ptr));
    if (fs.mount_options.read_only) return UFS_ERROR_WRITE_PROTECTED;

    const name_slice = std.mem.span(name);

    // Allocate inode number
    if (fs.ag_manager) |agm| {
         agm.loadAG(0) catch |err| return mapError(err);
        const ag = &agm.groups[0];

        // Find free inode
        var inode_num: u64 = 0;
        for (0..ag.header.inode_count) |i| {
            if (!ag.inode_bitmap.isAllocated(i)) {
                inode_num = @as(u64, @intCast(i));
                break;
            }
        }
        if (inode_num == 0) return UFS_ERROR_OUT_OF_SPACE;

        // Mark inode as allocated
        ag.inode_bitmap.setAllocated(inode_num, true);

        // Create capsule
        const capsule = metadata.createPosixBaseCapsule(
            fs.allocator,
            inode_num,
            mode,
            uid, gid,
            utils.timestamp(), utils.timestamp(), utils.timestamp(), utils.timestamp(),
            1, // link_count
        ) catch |err| return mapError(err);
        defer capsule.deinit();

        // Serialize capsule
        var cap_writer = serialization.createWriter(fs.allocator);
        defer cap_writer.deinit();
         capsule.serialize(&cap_writer) catch |err| return mapError(err);
        const capsule_data = cap_writer.bytes();

        // Allocate capsule cluster
        const capsule_cluster =  agm.allocateClusters(1, .{}) catch |err| return mapError(err);
         fs.device.write(capsule_cluster.start_cluster * fs.cluster_size, capsule_data) catch |err| return mapError(err);

        // Create inode
        var inode_writer = serialization.createWriter(fs.allocator);
        defer inode_writer.deinit();

         inode_writer.writeU32(0x494E4F00) catch |err| return mapError(err);
         inode_writer.writeU16(1) catch |err| return mapError(err);
         inode_writer.writeU16(file_type == 2 ? 0x0002 : 0x0001) catch |err| return mapError(err); // directory vs file
         inode_writer.writeU64(inode_num) catch |err| return mapError(err);
         inode_writer.writeU64(1) catch |err| return mapError(err);
         inode_writer.writeU64(capsule.header.capsule_id) catch |err| return mapError(err);
         inode_writer.writeU32(mode) catch |err| return mapError(err);
         inode_writer.writeU32(uid) catch |err| return mapError(err);
         inode_writer.writeU32(gid) catch |err| return mapError(err);
         inode_writer.writeU32(1) catch |err| return mapError(err); // link_count
         inode_writer.writeU32(0) catch |err| return mapError(err);
         inode_writer.writeU32(0) catch |err| return mapError(err);
         inode_writer.writeU64(0) catch |err| return mapError(err); // size
         inode_writer.writeU64(0) catch |err| return mapError(err); // allocated_size
        const now = utils.timestamp();
         inode_writer.writeU64(now) catch |err| return mapError(err);
         inode_writer.writeU64(now) catch |err| return mapError(err);
         inode_writer.writeU64(now) catch |err| return mapError(err);
         inode_writer.writeU64(0) catch |err| return mapError(err);
         inode_writer.writeU16(0) catch |err| return mapError(err);
         inode_writer.writeU16(0) catch |err| return mapError(err);
         inode_writer.writeU32(0) catch |err| return mapError(err);
         inode_writer.writeU16(0) catch |err| return mapError(err);
         inode_writer.writeU16(0) catch |err| return mapError(err);
         inode_writer.writeU32(0) catch |err| return mapError(err);
         inode_writer.writeU64(0) catch |err| return mapError(err);
         inode_writer.writeU64(capsule_cluster.start_cluster) catch |err| return mapError(err);
         inode_writer.writeU32(@as(u32, @intCast(capsule_data.len))) catch |err| return mapError(err);
         inode_writer.writeU32(0) catch |err| return mapError(err);
        for (0..112) |_| {  inode_writer.writeU8(0) catch |err| return mapError(err); }

        try inode_writer.align(256);
        const inode_crc = utils.crc32c(inode_writer.bytes());
         inode_writer.writeU32(inode_crc) catch |err| return mapError(err);

        const inode_data = inode_writer.bytes();
        const inode_table_base = fs.superblock.first_ag_offset + 10;
         fs.device.write((inode_table_base + inode_num) * fs.cluster_size, inode_data) catch |err| return mapError(err);

        // Add directory entry to parent
         addDirEntry(fs, parent, name_slice, inode_num, file_type) catch |err| return mapError(err);

        // Write inode bitmap back
         ag.inode_bitmap.writeToDevice(fs.device, ag.header.inode_table_offset - 1, fs.cluster_size) catch |err| return mapError(err);

        // Journal the transaction
        if (fs.journal_writer) |*jw| {
            var builder = journal.TransactionBuilder.init(fs.allocator, jw.superblock.end_txn + 1);
            defer builder.deinit();

            const capsule_id = utils.generateUuidv7();
             builder.addCreateInode(journal.OpCreateInode{
                .inode = inode_num,
                .parent = parent,
                .name = name_slice,
                .mode = mode,
                .uid = uid,
                .gid = gid,
                .capsule_id = capsule_id,
            }) catch |err| return mapError(err);
             builder.addLinkDirent(journal.OpLinkDirent{
                .parent = parent,
                .name = name_slice,
                .child = inode_num,
                .file_type = file_type,
            }) catch |err| return mapError(err);
             builder.addCheckpoint(journal.OpCheckpoint{
                .superblock_generation = 1,
                .ag_generations = &[_]u64{1},
            }) catch |err| return mapError(err);

            const txn = builder.build();
             jw.writeTransaction(txn) catch |err| return mapError(err);
             jw.checkpoint() catch |err| return mapError(err);
        }

        out_inode.* = inode_num;
        return UFS_OK;
    }

    return UFS_ERROR_INTERNAL;
}

// Lookup inode by path
export fn ufs_lookup(fs_ptr: *c_void, parent: u64, name: [*c]const u8, out_inode: *u64) i32 {
    const fs = @as(*Fs, @ptrCast(fs_ptr));
    const name_slice = std.mem.span(name);

    // Read parent directory
    const dir_data = readDirectory(fs, parent) catch |err| return mapError(err);
    var reader = serialization.createReader(dir_data);
    var dir = directory.LinearDirectory.deserialize(&reader, fs.allocator) catch |err| return mapError(err);
    defer dir.deinit();

    // Find entry
    if (dir.find(name_slice)) |entry| {
        out_inode.* = entry.inode;
        return UFS_OK;
    }

    return UFS_ERROR_NOT_FOUND;
}

// Get inode metadata
export fn ufs_getattr(fs_ptr: *c_void, inode: u64, out_info: *InodeInfo) i32 {
    const fs = @as(*Fs, @ptrCast(fs_ptr));

    // Read inode
    const inode_data = readInode(fs, inode) catch |err| return mapError(err);
    var reader = serialization.createReader(inode_data);

    // Parse inode
    _ = reader.readU32(); // magic
    _ = reader.readU16(); // version
    const flags = reader.readU16();
    const inode_num = reader.readU64();
    _ = reader.readU64(); // generation
    _ = reader.readU64(); // capsule_id
    const mode = reader.readU32();
    const uid = reader.readU32();
    const gid = reader.readU32();
    const link_count = reader.readU32();
    _ = reader.readU32(); // flags2
    _ = reader.readU32(); // reserved1
    const size = reader.readU64();
    const allocated_size = reader.readU64();
    const atime = reader.readU64();
    const mtime = reader.readU64();
    const ctime = reader.readU64();
    _ = reader.readU64(); // extent_tree_root
    _ = reader.readU16(); // extent_count
    _ = reader.readU16(); // extent_tree_height

    // Determine file type from flags
    const file_type: u8 = if ((flags & 0x0002) != 0) 2 else 1; // directory vs regular

    out_info.inode = inode_num;
    out_info.mode = mode;
    out_info.uid = uid;
    out_info.gid = gid;
    out_info.size = size;
    out_info.allocated_size = allocated_size;
    out_info.link_count = link_count;
    out_info.flags = flags;
    out_info.atime = atime;
    out_info.mtime = mtime;
    out_info.ctime = ctime;
    out_info.crtime = ctime; // Use ctime as crtime if not stored separately
    out_info.type = file_type;

    return UFS_OK;
}

// Set inode metadata
export fn ufs_setattr(fs_ptr: *c_void, inode: u64, info: *InodeInfo, valid_mask: u32) i32 {
    const fs = @as(*Fs, @ptrCast(fs_ptr));
    if (fs.mount_options.read_only) return UFS_ERROR_WRITE_PROTECTED;

    // Read current inode
    const inode_data = readInode(fs, inode) catch |err| return mapError(err);

    // Update fields based on valid_mask
    var reader = serialization.createReader(inode_data);
    var writer = serialization.createWriter(fs.allocator);
    defer writer.deinit();

    // Copy all fields, updating those in valid_mask
    _ = writer.writeU32(reader.readU32()); // magic
    _ = writer.writeU16(reader.readU16()); // version
    _ = writer.writeU16(reader.readU16()); // flags
    _ = writer.writeU64(reader.readU64()); // inode_num
    _ = writer.writeU64(reader.readU64()); // generation
    _ = writer.writeU64(reader.readU64()); // capsule_id
    const mode = if ((valid_mask & 0x01) != 0) info.mode else reader.readU32();
    _ = writer.writeU32(mode);
    const uid = if ((valid_mask & 0x02) != 0) info.uid else reader.readU32();
    _ = writer.writeU32(uid);
    const gid = if ((valid_mask & 0x04) != 0) info.gid else reader.readU32();
    _ = writer.writeU32(gid);
    const link_count = if ((valid_mask & 0x08) != 0) info.link_count else reader.readU32();
    _ = writer.writeU32(link_count);
    _ = writer.writeU32(reader.readU32()); // flags2
    _ = writer.writeU32(reader.readU32()); // reserved1
    const size = if ((valid_mask & 0x10) != 0) info.size else reader.readU64();
    _ = writer.writeU64(size);
    _ = writer.writeU64(reader.readU64()); // allocated_size
    const atime = if ((valid_mask & 0x20) != 0) info.atime else reader.readU64();
    _ = writer.writeU64(atime);
    const mtime = if ((valid_mask & 0x40) != 0) info.mtime else reader.readU64();
    _ = writer.writeU64(mtime);
    const ctime = if ((valid_mask & 0x80) != 0) info.ctime else reader.readU64();
    _ = writer.writeU64(ctime);

    // Copy remaining fields
    for (0..128) |_| {
        _ = writer.writeU8(reader.readU8());
    }

    try writer.align(256);
    const crc = utils.crc32c(writer.bytes());
    _ = writer.writeU32(crc);

    // Write back
    const inode_table_base = fs.superblock.first_ag_offset + 10;
     fs.device.write((inode_table_base + inode) * fs.cluster_size, writer.bytes()) catch |err| return mapError(err);

    return UFS_OK;
}

// Delete inode
export fn ufs_delete_inode(fs_ptr: *c_void, inode: u64) i32 {
    const fs = @as(*Fs, @ptrCast(fs_ptr));
    if (fs.mount_options.read_only) return UFS_ERROR_WRITE_PROTECTED;

    // Read inode to get extent tree
    const inode_data = readInode(fs, inode) catch |err| return mapError(err);
    defer fs.allocator.free(inode_data);

    // Parse inode to find extent tree root
    var reader = serialization.createReader(inode_data);
    _ = reader.readU32(); // magic
    _ = reader.readU16(); // version
    _ = reader.readU16(); // flags
    _ = reader.readU64(); // inode_number
    _ = reader.readU64(); // generation
    _ = reader.readU64(); // capsule_id
    _ = reader.readU32(); // mode
    _ = reader.readU32(); // uid
    _ = reader.readU32(); // gid
    _ = reader.readU32(); // link_count
    _ = reader.readU32(); // flags2
    _ = reader.readU32(); // reserved1
    _ = reader.readU64(); // size
    _ = reader.readU64(); // allocated_size
    _ = reader.readU64(); // atime
    _ = reader.readU64(); // mtime
    _ = reader.readU64(); // ctime
    const extent_tree_root = reader.readU64(); // extent_tree_root
    const extent_count = reader.readU16(); // extent_count
    const extent_tree_height = reader.readU16(); // extent_tree_height

    // Free all extents if extent tree exists
    if (extent_tree_root != 0 and extent_count > 0) {
         freeInodeExtents(
            fs,
            extent_tree_root,
            extent_tree_height,
            extent_count,
            fs.cluster_size,
        ) catch |err| return mapError(err);
    }

    // Mark inode as free in bitmap
    if (fs.ag_manager) |agm| {
         agm.loadAG(0) catch |err| return mapError(err);
        const ag = &agm.groups[0];
        ag.inode_bitmap.setAllocated(inode, false);
         ag.inode_bitmap.writeToDevice(fs.device, ag.header.inode_table_offset - 1, fs.cluster_size) catch |err| return mapError(err);
    }

    // TODO: Remove directory entries pointing to this inode (would require scanning all directories)

    // Journal the deletion
    if (fs.journal_writer) |*jw| {
        var builder = journal.TransactionBuilder.init(fs.allocator, jw.superblock.end_txn + 1);
        defer builder.deinit();
         builder.addDeleteInode(journal.OpDeleteInode{
            .inode = inode,
            .name = "",
        }) catch |err| return mapError(err);
        const txn = builder.build();
         jw.writeTransaction(txn) catch |err| return mapError(err);
         jw.checkpoint() catch |err| return mapError(err);
    }

    return UFS_OK;
}

// Free all extents of an inode during deletion
fn freeInodeExtents(
    fs: *Fs,
    root_block: u64,
    tree_height: u16,
    extent_count: u16,
    cluster_size: u32,
) !void {
    var current_block = root_block;
    var current_height = tree_height;

    // Use a stack for iterative traversal
    var stack = std.ArrayList(StackEntry).init(fs.allocator);
    defer stack.deinit();

    const StackEntry = struct {
        block: u64,
        height: u16,
        child_index: u16,
    };

    try stack.append(.{ .block = root_block, .height = tree_height, .child_index = 0 });

    while (stack.items.len > 0) {
        var entry = stack.items[stack.items.len - 1];
        stack.items[stack.items.len - 1] = entry;

        // Read node
        var buffer = try fs.allocator.alloc(u8, cluster_size as usize);
        try fs.device.read(entry.block * cluster_size, buffer);
        defer fs.allocator.free(buffer);

        var reader = serialization.createReader(buffer);
        const magic = try reader.readU32();
        if (magic != 0x45585400) { // "EXT\0" - extent tree magic
            break;
        }
        _ = reader.readU16(); // version
        _ = reader.readU16(); // flags
        const entry_count = try reader.readU16();
        _ = reader.readU16(); // max_entries
        const is_leaf = try reader.readU16();
        const level = try reader.readU16();

        if (is_leaf == 1) {
            // Leaf node - free all extents
            for (0..entry_count) |i| {
                const start_cluster = try reader.readU64();
                const length = try reader.readU64();
                freeExtentRange(fs, start_cluster, length, cluster_size);
            }
        } else {
            // Internal node - push children to stack
            if (entry.child_index < entry_count) {
                const child_block = try reader.readU64();
                entry.child_index += 1;
                stack.items[stack.items.len - 1] = entry;
                try stack.append(.{ .block = child_block, .height = level - 1, .child_index = 0 });
            } else {
                _ = stack.pop();
            }
        }
    }
}

// Free a range of clusters
fn freeExtentRange(fs: *Fs, start_cluster: u64, length: u64, cluster_size: u32) !void {
    if (fs.ag_manager) |agm| {
        const ag_index = start_cluster / agm.ag_size;
        if (ag_index < agm.ag_count) {
            var ag = try agm.getGroup(ag_index);
            defer agm.releaseGroup(ag);
            const local_start = start_cluster % agm.ag_size;
            for (local_start..local_start + length) |cluster| {
                ag.bitmap.setAllocated(cluster, false);
            }
            // Also remove from free extent tree
            try ag.free_tree.remove(start_cluster, length);
        }
    }
}

// Remove directory entry (unlink file)
export fn ufs_unlink_dirent(fs_ptr: *c_void, parent: u64, name: [*c]const u8) i32 {
    const fs = @as(*Fs, @ptrCast(fs_ptr));
    if (fs.mount_options.read_only) return UFS_ERROR_WRITE_PROTECTED;

    const name_slice = std.mem.span(name);

    // Read parent directory
    const dir_data = readDirectory(fs, parent) catch |err| return mapError(err);
    var reader = serialization.createReader(dir_data);
    var dir = directory.LinearDirectory.deserialize(&reader, fs.allocator) catch |err| return mapError(err);

    // Find the child inode before removing
    const child_inode =  findDirEntry(fs, parent, name_slice) catch |err| return mapError(err);

    // Remove entry
     dir.remove(name_slice) catch |err| return mapError(err);

    // Write back
    var writer = serialization.createWriter(fs.allocator);
    defer writer.deinit();
     dir.serialize(&writer) catch |err| return mapError(err);

    const dir_cluster = findDirectoryCluster(fs, parent);
     fs.device.write(dir_cluster * fs.cluster_size, writer.bytes()) catch |err| return mapError(err);

    // Decrement link count on child inode
    const child_inode_data = readInode(fs, child_inode) catch |err| return mapError(err);
    var child_reader = serialization.createReader(child_inode_data);
    var child_writer = serialization.createWriter(fs.allocator);
    defer child_writer.deinit();

    // Copy all fields up to link_count
    for (0..5) |_| { // magic, version, flags, inode_num, generation
        _ = child_writer.writeU64(child_reader.readU64());
    }
    _ = child_writer.writeU64(child_reader.readU64()); // capsule_id
    for (0..2) |_| { // mode, uid
        _ = child_writer.writeU32(child_reader.readU32());
    }
    _ = child_writer.writeU32(child_reader.readU32()); // gid
    const link_count = child_reader.readU32();
    if (link_count > 0) {
        _ = child_writer.writeU32(link_count - 1);
    } else {
        _ = child_writer.writeU32(0);
    }
    _ = child_writer.writeU32(child_reader.readU32()); // flags2
    _ = child_writer.writeU32(child_reader.readU32()); // reserved1

    // Copy remaining fields
    for (0..128) |_| {
        _ = child_writer.writeU8(child_reader.readU8());
    }

    // Write updated inode
    const inode_table_base = fs.superblock.first_ag_offset + 10;
     fs.device.write((inode_table_base + child_inode) * fs.cluster_size, child_writer.bytes()) catch |err| return mapError(err);

    // If link count reaches 0, delete the inode
    if (link_count <= 1) {
        if (ufs_delete_inode(fs_ptr, child_inode) != UFS_OK) return UFS_ERROR_IO;
    }

    // Journal
    if (fs.journal_writer) |*jw| {
        var builder = journal.TransactionBuilder.init(fs.allocator, jw.superblock.end_txn + 1);
        defer builder.deinit();
         builder.addUnlinkDirent(journal.OpUnlinkDirent{
            .parent = parent,
            .name = name_slice,
        }) catch |err| return mapError(err);
        const txn = builder.build();
         jw.writeTransaction(txn) catch |err| return mapError(err);
         jw.checkpoint() catch |err| return mapError(err);
    }

    return UFS_OK;
}

// Add directory entry (link file)
export fn ufs_link_dirent(fs_ptr: *c_void, parent: u64, name: [*c]const u8, child: u64, file_type: u8) i32 {
    const fs = @as(*Fs, @ptrCast(fs_ptr));
    if (fs.mount_options.read_only) return UFS_ERROR_WRITE_PROTECTED;

    const name_slice = std.mem.span(name);

    // Read parent directory
    const dir_data = readDirectory(fs, parent) catch |err| return mapError(err);
    var reader = serialization.createReader(dir_data);
    var dir = directory.LinearDirectory.deserialize(&reader, fs.allocator) catch |err| return mapError(err);

    // Insert entry
     dir.insert(directory.DirEntry{
        .inode = child,
        .name = name_slice,
        .file_type = file_type,
        .flags = 0,
    }) catch |err| return mapError(err);

    // Write back
    var writer = serialization.createWriter(fs.allocator);
    defer writer.deinit();
     dir.serialize(&writer) catch |err| return mapError(err);

    const dir_cluster = findDirectoryCluster(fs, parent);
     fs.device.write(dir_cluster * fs.cluster_size, writer.bytes()) catch |err| return mapError(err);

    // Increment link count on child inode
    const child_inode_data = readInode(fs, child) catch |err| return mapError(err);
    var child_reader = serialization.createReader(child_inode_data);
    var child_writer = serialization.createWriter(fs.allocator);
    defer child_writer.deinit();

    // Copy up to link_count
    for (0..7) |_| { _ = child_writer.writeU8(child_reader.readU8()); } // magic, version, flags, inode_num (partial)
    _ = child_writer.writeU64(child_reader.readU64()); // inode_num
    _ = child_writer.writeU64(child_reader.readU64()); // generation
    _ = child_writer.writeU64(child_reader.readU64()); // capsule_id
    _ = child_writer.writeU32(child_reader.readU32()); // mode
    _ = child_writer.writeU32(child_reader.readU32()); // uid
    _ = child_writer.writeU32(child_reader.readU32()); // gid
    const link_count = child_reader.readU32() + 1;
    _ = child_writer.writeU32(link_count);

    // Copy rest
    for (0..200) |_| {
        _ = child_writer.writeU8(child_reader.readU8());
    }

    try child_writer.align(256);
    const crc = utils.crc32c(child_writer.bytes());
    _ = child_writer.writeU32(crc);

    const inode_table_base = fs.superblock.first_ag_offset + 10;
     fs.device.write((inode_table_base + child) * fs.cluster_size, child_writer.bytes()) catch |err| return mapError(err);

    // Journal
    if (fs.journal_writer) |*jw| {
        var builder = journal.TransactionBuilder.init(fs.allocator, jw.superblock.end_txn + 1);
        defer builder.deinit();
         builder.addLinkDirent(journal.OpLinkDirent{
            .parent = parent,
            .name = name_slice,
            .child = child,
            .file_type = file_type,
        }) catch |err| return mapError(err);
        const txn = builder.build();
         jw.writeTransaction(txn) catch |err| return mapError(err);
         jw.checkpoint() catch |err| return mapError(err);
    }

    return UFS_OK;
}

// ============================================================================
// Directory Operations (C API)
// ============================================================================

// Open directory for iteration
export fn ufs_opendir(fs_ptr: *c_void, inode: u64, out_iter: **c_void) i32 {
    const fs = @as(*Fs, @ptrCast(fs_ptr));

    const dir_data = readDirectory(fs, inode) catch |err| return mapError(err);
    var reader = serialization.createReader(dir_data);
    var dir = directory.LinearDirectory.deserialize(&reader, fs.allocator) catch |err| return mapError(err);

    // Store iterator in heap
    const iter_ptr = fs.allocator.create(directory.LinearDirectory) catch |err| return mapError(err);
    iter_ptr.* = dir;
    out_iter.* = @as(*c_void, @ptrCast(iter_ptr));

    return UFS_OK;
}

// Read next directory entry
export fn ufs_readdir(fs_ptr: *c_void, iter_ptr: *c_void, out_entry: *Dirent) i32 {
    const fs = @as(*Fs, @ptrCast(fs_ptr));
    const iter = @as(*directory.LinearDirectory, @ptrCast(iter_ptr));

    // Simple iteration - in real implementation, track position
    if (iter.entries.items.len > 0) {
        const entry = iter.entries.items[0];
        // Remove first entry to simulate iteration
        _ = iter.entries.orderedRemove(0);

        // Copy to output
        @memcpy(out_entry.name, entry.name);
        out_entry.name[entry.name.len] = 0;
        out_entry.inode = entry.inode;
        out_entry.type = entry.file_type;
        return UFS_OK;
    }

    return UFS_ERROR_NOT_FOUND; // End of directory
}

// Close directory iterator
export fn ufs_closedir(fs_ptr: *c_void, iter_ptr: *c_void) i32 {
    const fs = @as(*Fs, @ptrCast(fs_ptr));
    const iter = @as(*directory.LinearDirectory, @ptrCast(iter_ptr));
    iter.deinit(fs.allocator);
    fs.allocator.destroy(iter);
    return UFS_OK;
}

// Create directory
export fn ufs_mkdir(fs_ptr: *c_void, parent: u64, name: [*c]const u8, mode: u32) i32 {
    return ufs_create_inode(fs_ptr, parent, name, 2, mode, 0, 0, &_ = 0);
}

// Remove directory
export fn ufs_rmdir(fs_ptr: *c_void, parent: u64, name: [*c]const u8) i32 {
    return ufs_unlink_dirent(fs_ptr, parent, name);
}

// Rename/move
export fn ufs_rename(fs_ptr: *c_void, old_parent: u64, old_name: [*c]const u8, new_parent: u64, new_name: [*c]const u8) i32 {
    const fs = @as(*Fs, @ptrCast(fs_ptr));
    if (fs.mount_options.read_only) return UFS_ERROR_WRITE_PROTECTED;

    const old_name_slice = std.mem.span(old_name);
    const new_name_slice = std.mem.span(new_name);

    // Read old parent directory
    const old_dir_data = readDirectory(fs, old_parent) catch |err| return mapError(err);
    var old_reader = serialization.createReader(old_dir_data);
    var old_dir = directory.LinearDirectory.deserialize(&old_reader, fs.allocator) catch |err| return mapError(err);

    // Find entry
    const entry = old_dir.find(old_name_slice) orelse return UFS_ERROR_NOT_FOUND;
    const child_inode = entry.inode;
    const file_type = entry.file_type;

    // Remove from old parent
     old_dir.remove(old_name_slice) catch |err| return mapError(err);

    var old_writer = serialization.createWriter(fs.allocator);
    defer old_writer.deinit();
     old_dir.serialize(&old_writer) catch |err| return mapError(err);
    const old_dir_cluster = findDirectoryCluster(fs, old_parent);
     fs.device.write(old_dir_cluster * fs.cluster_size, old_writer.bytes()) catch |err| return mapError(err);

    // Add to new parent
    const new_dir_data = readDirectory(fs, new_parent) catch |err| return mapError(err);
    var new_reader = serialization.createReader(new_dir_data);
    var new_dir = directory.LinearDirectory.deserialize(&new_reader, fs.allocator) catch |err| return mapError(err);

     new_dir.insert(directory.DirEntry{
        .inode = child_inode,
        .name = new_name_slice,
        .file_type = file_type,
        .flags = 0,
    }) catch |err| return mapError(err);

    var new_writer = serialization.createWriter(fs.allocator);
    defer new_writer.deinit();
     new_dir.serialize(&new_writer) catch |err| return mapError(err);
    const new_dir_cluster = findDirectoryCluster(fs, new_parent);
     fs.device.write(new_dir_cluster * fs.cluster_size, new_writer.bytes()) catch |err| return mapError(err);

    // Journal
    if (fs.journal_writer) |*jw| {
        var builder = journal.TransactionBuilder.init(fs.allocator, jw.superblock.end_txn + 1);
        defer builder.deinit();
         builder.addRenameDirent(journal.OpRenameDirent{
            .old_parent = old_parent,
            .old_name = old_name_slice,
            .new_parent = new_parent,
            .new_name = new_name_slice,
        }) catch |err| return mapError(err);
        const txn = builder.build();
         jw.writeTransaction(txn) catch |err| return mapError(err);
         jw.checkpoint() catch |err| return mapError(err);
    }

    return UFS_OK;
}

// Create symlink
export fn ufs_symlink(fs_ptr: *c_void, parent: u64, name: [*c]const u8, target: [*c]const u8) i32 {
    return ufs_create_inode(fs_ptr, parent, name, 3, 0o120777, 0, 0, &_ = 0);
}

// Read symlink target
export fn ufs_readlink(fs_ptr: *c_void, inode: u64, buffer: [*c]u8, buffer_size: usizeize) i32 {
    const fs = @as(*Fs, @ptrCast(fs_ptr));

    // Read inode data to get symlink target
    const inode_data = readInode(fs, inode) catch |err| return mapError(err);
    // For symlinks, target is stored in extent data
    // Simplified: return empty
    buffer[0] = 0;
    return UFS_OK;
}

// ============================================================================
// File I/O Operations (C API)
// ============================================================================

const FileHandle = struct {
    id: usize,
    fs: *Fs,
    inode: u64,
    offset: u64,
};

// File handles are opaque, monotonically increasing tokens. Never encode an
// ArrayList index in a pointer: index zero becomes NULL and removal shifts peers.
fn findFileHandle(fs: *Fs, token: *c_void) ?*FileHandle {
    const id = @intFromPtr(token);
    if (id == 0) return null;
    for (fs.file_handles.items) |*handle| {
        if (handle.id == id and handle.inode != 0) return handle;
    }
    return null;
}

// Open file
export fn ufs_open(fs_ptr: *c_void, inode: u64, flags: i32, out_file: **c_void) i32 {
    _ = flags;
    const fs = @as(*Fs, @ptrCast(fs_ptr));
    if (fs.next_file_handle_id == 0 or fs.next_file_handle_id == std.math.maxInt(usize)) {
        return UFS_ERROR_OUT_OF_SPACE;
    }

    const id = fs.next_file_handle_id;
    fs.next_file_handle_id += 1;
    const handle = FileHandle{ .id = id, .fs = fs, .inode = inode, .offset = 0 };

    // Reuse closed slots without reusing their externally visible IDs.
    var stored = false;
    for (fs.file_handles.items) |*slot| {
        if (slot.inode == 0) {
            slot.* = handle;
            stored = true;
            break;
        }
    }
    if (!stored) fs.file_handles.append(handle) catch |err| return mapError(err);

    out_file.* = @ptrFromInt(id);
    return UFS_OK;
}

export fn ufs_close(fs_ptr: *c_void, file_ptr: *c_void) i32 {
    const fs = @as(*Fs, @ptrCast(fs_ptr));
    const handle = findFileHandle(fs, file_ptr) orelse return UFS_ERROR_INVALID_ARGUMENT;
    handle.inode = 0;
    handle.offset = 0;
    return UFS_OK;
}

export fn ufs_read(fs_ptr: *c_void, file_ptr: *c_void, buffer: [*c]u8, size: usize, out_bytes_read: *usize) i32 {
    const fs = @as(*Fs, @ptrCast(fs_ptr));
    const handle = findFileHandle(fs, file_ptr) orelse return UFS_ERROR_INVALID_ARGUMENT;
    if (size == 0) { out_bytes_read.* = 0; return UFS_OK; }
    if (buffer == null) return UFS_ERROR_INVALID_ARGUMENT;
    const data = readFileData(fs, handle.inode, handle.offset, size) catch |err| return mapError(err);
    const to_copy = @min(data.len, size);
    const end_offset = std.math.add(u64, handle.offset, to_copy) catch {
        fs.allocator.free(data);
        return UFS_ERROR_INVALID_ARGUMENT;
    };
    @memcpy(buffer[0..to_copy], data[0..to_copy]);
    handle.offset = end_offset;
    out_bytes_read.* = to_copy;
    fs.allocator.free(data);
    return UFS_OK;
}

export fn ufs_write(fs_ptr: *c_void, file_ptr: *c_void, buffer: [*c]const u8, size: usize, out_bytes_written: *usize) i32 {
    const fs = @as(*Fs, @ptrCast(fs_ptr));
    const handle = findFileHandle(fs, file_ptr) orelse return UFS_ERROR_INVALID_ARGUMENT;
    if (size == 0) { out_bytes_written.* = 0; return UFS_OK; }
    if (buffer == null) return UFS_ERROR_INVALID_ARGUMENT;
    if (fs.mount_options.read_only) return UFS_ERROR_WRITE_PROTECTED;
    const end_offset = std.math.add(u64, handle.offset, size) catch return UFS_ERROR_INVALID_ARGUMENT;
    writeFileData(fs, handle.inode, handle.offset, buffer[0..size]) catch |err| return mapError(err);
    handle.offset = end_offset;
    out_bytes_written.* = size;
    return UFS_OK;
}

export fn ufs_seek(fs_ptr: *c_void, file_ptr: *c_void, offset: i64, whence: i32, out_position: *i64) i32 {
    const fs = @as(*Fs, @ptrCast(fs_ptr));
    const handle = findFileHandle(fs, file_ptr) orelse return UFS_ERROR_INVALID_ARGUMENT;
    switch (whence) {
        0 => {
            if (offset < 0) return UFS_ERROR_INVALID_ARGUMENT;
            handle.offset = @intCast(offset);
        },
        1 => {
            const current: i64 = std.math.cast(i64, handle.offset) orelse return UFS_ERROR_INVALID_ARGUMENT;
            const next = std.math.add(i64, current, offset) catch return UFS_ERROR_INVALID_ARGUMENT;
            if (next < 0) return UFS_ERROR_INVALID_ARGUMENT;
            handle.offset = @intCast(next);
        },
        2 => {
            var info = InodeInfo{};
            if (ufs_getattr(handle.fs, handle.inode, &info) != UFS_OK) return UFS_ERROR_IO;
            const file_size: i64 = std.math.cast(i64, info.size) orelse return UFS_ERROR_INVALID_ARGUMENT;
            const next = std.math.add(i64, file_size, offset) catch return UFS_ERROR_INVALID_ARGUMENT;
            if (next < 0) return UFS_ERROR_INVALID_ARGUMENT;
            handle.offset = @intCast(next);
        },
        else => return UFS_ERROR_INVALID_ARGUMENT,
    }
    out_position.* = std.math.cast(i64, handle.offset) orelse return UFS_ERROR_INVALID_ARGUMENT;
    return UFS_OK;
}

// Truncate
export fn ufs_truncate(fs_ptr: *c_void, inode: u64, new_size: u64) i32 {
    const fs = @as(*Fs, @ptrCast(fs_ptr));
    if (fs.mount_options.read_only) return UFS_ERROR_WRITE_PROTECTED;

    // Update inode size
    var info = InodeInfo{}; // Using var since we modify it
    if (ufs_getattr(fs, inode, &info) != UFS_OK) return UFS_ERROR_IO;
    info.size = new_size;
    if (ufs_setattr(fs, inode, &info, 0x10) != UFS_OK) return UFS_ERROR_IO; // UFS_ATTR_SIZE

    // TODO: Free excess clusters

    return UFS_OK;
}

// Fallocate
export fn ufs_fallocate(fs_ptr: *c_void, inode: u64, mode: i32, offset: u64, length: u64) i32 {
    _ = fs_ptr; _ = inode; _ = mode; _ = offset; _ = length;
    return UFS_ERROR_UNSUPPORTED_OPERATION;
}

// Fsync
export fn ufs_fsync(fs_ptr: *c_void, file_ptr: *c_void) i32 {
    const fs = @as(*Fs, @ptrCast(fs_ptr));
    const handle = findFileHandle(fs, file_ptr) orelse return UFS_ERROR_INVALID_ARGUMENT;
    return handle.fs.device.flush() catch |err| mapError(err);
}

// Get file extent map
export fn ufs_get_extents(fs_ptr: *c_void, inode: u64, extents: *Extent, count: *usize) i32 {
    _ = fs_ptr; _ = inode; _ = extents; _ = count;
    return UFS_ERROR_UNSUPPORTED_OPERATION;
}

// ============================================================================
// Extended Attributes / Metadata Capsules (C API)
// ============================================================================

// Set extended attribute
export fn ufs_setxattr(fs_ptr: *c_void, inode: u64, namespace_id: u16, type: u16, name: [*c]const u8, value: *c_void, value_len: usize, flags: i32) i32 {
    _ = fs_ptr; _ = inode; _ = namespace_id; _ = type; _ = name; _ = value; _ = value_len; _ = flags;
    return UFS_ERROR_UNSUPPORTED_OPERATION;
}

// Get extended attribute
export fn ufs_getxattr(fs_ptr: *c_void, inode: u64, namespace_id: u16, type: u16, name: [*c]const u8, buffer: *c_void, buffer_size: usize, out_size: *usize) i32 {
    _ = fs_ptr; _ = inode; _ = namespace_id; _ = type; _ = name; _ = buffer; _ = buffer_size; _ = out_size;
    return UFS_ERROR_UNSUPPORTED_OPERATION;
}

// List extended attributes
export fn ufs_listxattr(fs_ptr: *c_void, inode: u64, buffer: *c_void, buffer_size: usize, out_size: *usize) i32 {
    _ = fs_ptr; _ = inode; _ = buffer; _ = buffer_size; _ = out_size;
    return UFS_ERROR_UNSUPPORTED_OPERATION;
}

// Remove extended attribute
export fn ufs_removexattr(fs_ptr: *c_void, inode: u64, namespace_id: u16, type: u16, name: [*c]const u8) i32 {
    _ = fs_ptr; _ = inode; _ = namespace_id; _ = type; _ = name;
    return UFS_ERROR_UNSUPPORTED_OPERATION;
}

// ============================================================================
// Volume Management (C API)
// ============================================================================

// Get volume UUID
export fn ufs_get_volume_uuid(fs_ptr: *c_void, uuid: *[16]u8) i32 {
    const fs = @as(*Fs, @ptrCast(fs_ptr));
    @memcpy(uuid[0..16], fs.superblock.uuid[0..16]);
    return UFS_OK;
}

// Set volume label
export fn ufs_set_volume_label(fs_ptr: *c_void, label: [*c]const u8) i32 {
    _ = fs_ptr; _ = label;
    return UFS_ERROR_UNSUPPORTED_OPERATION;
}

// Get volume label
export fn ufs_get_volume_label(fs_ptr: *c_void, buffer: [*c]u8, size: usize) i32 {
    const fs = @as(*Fs, @ptrCast(fs_ptr));
    const label = std.mem.span(&fs.superblock.label);
    const to_copy = @min(label.len, size - 1);
    @memcpy(buffer[0..to_copy], label[0..to_copy]);
    buffer[to_copy] = 0;
    return UFS_OK;
}

// Feature flag management
export fn ufs_get_features(fs_ptr: *c_void, incompat: *u32, compat_ro: *u32, compat_rw: *u32) i32 {
    const fs = @as(*Fs, @ptrCast(fs_ptr));
    incompat.* = fs.superblock.feature_incompat;
    compat_ro.* = fs.superblock.feature_compat_ro;
    compat_rw.* = fs.superblock.feature_compat_rw;
    return UFS_OK;
}

export fn ufs_set_feature(fs_ptr: *c_void, type: i32, bit: i32, enabled: i32) i32 {
    _ = fs_ptr; _ = type; _ = bit; _ = enabled;
    return UFS_ERROR_UNSUPPORTED_OPERATION;
}

// Force checkpoint
export fn ufs_checkpoint(fs_ptr: *c_void) i32 {
    const fs = @as(*Fs, @ptrCast(fs_ptr));
    if (fs.journal_writer) |*jw| {
        return jw.checkpoint() catch |err| mapError(err);
    }
    return UFS_OK;
}

// Scrub (integrity check)
export fn ufs_scrub(fs_ptr: *c_void, result: *ScrubResult, progress: *c_void, ctx: *c_void) i32 {
    _ = fs_ptr; _ = result; _ = progress; _ = ctx;
    return UFS_ERROR_UNSUPPORTED_OPERATION;
}

// ============================================================================
// Recovery (C API)
// ============================================================================

// Check if volume needs recovery
export fn ufs_needs_recovery(device: *blockdev.BlockDevice) i32 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const sb = version.VolumeFormat.load(device, allocator) catch |err| return mapError(err);

    const needs_recovery = journal.needsRecovery(
        device,
        sb.journal_offset,
        sb.journal_size,
        sb.cluster_size,
        allocator,
    ) catch |err| return mapError(err);

    return if (needs_recovery) 1 else 0;
}

// Run recovery
export fn ufs_recover(device: *blockdev.BlockDevice) i32 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const sb = version.VolumeFormat.load(device, allocator) catch |err| return mapError(err);

    // Initialize allocation groups (needed for recovery)
    const agm = allocation.AllocationGroupManager.init(
        device,
        sb.cluster_size,
        sb.ag_count,
        sb.ag_size,
        sb.ag_table_offset,
        sb.first_ag_offset,
        allocator,
    ) catch |err| return mapError(err);

    // Load first AG
     agm.loadAG(0) catch |err| return mapError(err);

    // Run full recovery with filesystem context
    const recovery = journal.RecoveryEngine.init(
        device,
        sb.journal_offset,
        sb.journal_size,
        sb.cluster_size,
        allocator,
    );
     recovery.recoverFull(&agm) catch |err| return mapError(err);

    agm.deinit();
    return UFS_OK;
}

// Verify journal integrity
export fn ufs_verify_journal(device: *blockdev.BlockDevice, out_ok: *i32) i32 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const sb = version.VolumeFormat.load(device, allocator) catch |err| return mapError(err);
    const recovery = journal.RecoveryEngine.init(
        device,
        sb.journal_offset,
        sb.journal_size,
        sb.cluster_size,
        allocator,
    );
    const ok = recovery.verifyJournal() catch false;
    out_ok.* = if (ok) 1 else 0;
    return UFS_OK;
}

// ============================================================================
// Compression (C API)
// ============================================================================

export fn ufs_set_compression(fs_ptr: *c_void, inode: u64, algo: u8, level: i32) i32 {
    _ = fs_ptr; _ = inode; _ = algo; _ = level;
    return UFS_ERROR_UNSUPPORTED_OPERATION;
}

export fn ufs_get_compression(fs_ptr: *c_void, inode: u64, algo: *u8, level: *i32) i32 {
    _ = fs_ptr; _ = inode; _ = algo; _ = level;
    return UFS_ERROR_UNSUPPORTED_OPERATION;
}

// ============================================================================
// Encryption (C API - stub)
// ============================================================================

export fn ufs_set_encryption(fs_ptr: *c_void, inode: u64, algo: i32, key: *c_void, key_len: usize) i32 {
    _ = fs_ptr; _ = inode; _ = algo; _ = key; _ = key_len;
    return UFS_ERROR_UNSUPPORTED_FEATURE;
}

// ============================================================================
// Utility Functions (C API)
// ============================================================================

export fn ufs_strerror(error_code: i32) [*c]const u8 {
    return switch (error_code) {
        UFS_OK => "Success",
        UFS_ERROR_OUT_OF_MEMORY => "Out of memory",
        UFS_ERROR_INVALID_ARGUMENT => "Invalid argument",
        UFS_ERROR_IO => "I/O error",
        UFS_ERROR_NOT_FOUND => "Not found",
        UFS_ERROR_ALREADY_EXISTS => "Already exists",
        UFS_ERROR_PERMISSION_DENIED => "Permission denied",
        UFS_ERROR_CORRUPTED_DATA => "Corrupted data",
        UFS_ERROR_UNSUPPORTED_FEATURE => "Unsupported feature",
        UFS_ERROR_BUFFER_TOO_SMALL => "Buffer too small",
        UFS_ERROR_INVALID_FORMAT => "Invalid format",
        UFS_ERROR_INTERNAL => "Internal error",
        UFS_ERROR_OUT_OF_SPACE => "Out of space",
        UFS_ERROR_ALIGNMENT => "Alignment error",
        UFS_ERROR_FRAGMENTED => "Fragmented allocation",
        UFS_ERROR_NOT_INITIALIZED => "Not initialized",
        UFS_ERROR_WRITE_PROTECTED => "Write protected",
        UFS_ERROR_DEVICE_NOT_FOUND => "Device not found",
        UFS_ERROR_UNSUPPORTED_OPERATION => "Unsupported operation",
        UFS_ERROR_TIMEOUT => "Timeout",
        else => "Unknown error",
    };
}

export fn ufs_timestamp() u64 {
    return utils.timestamp();
}

export fn ufs_generate_uuidv7(uuid: *[16]u8) void {
    const generated = utils.generateUuidv7Bytes();
    @memcpy(uuid[0..16], generated[0..16]);
}

export fn ufs_crc32c(data: *c_void, len: usize) u32 {
    return utils.crc32c(data[0..len]);
}

export fn ufs_blake3(data: *c_void, len: usize, out: *[32]u8) void {
    var hasher = integrity.Blake3.Hasher.init();
    hasher.update(data[0..len]);
    out.* = hasher.finalize();
}

// ============================================================================
// Helper Functions
// ============================================================================

fn readInode(fs: *Fs, inode_num: u64) ![]u8 {
    const inode_table_base = fs.superblock.first_ag_offset + 10;
    var buffer: [4096]u8 = undefined;
    try fs.device.read((inode_table_base + inode_num) * fs.cluster_size, &buffer);
    return buffer[0..256];
}

fn readDirectory(fs: *Fs, inode_num: u64) ![]u8 {
    // Read inode to get directory extent
    const inode_data = readInode(fs, inode_num) catch |err| return err;
    var reader = serialization.createReader(inode_data);

    // Skip to extent info
    for (0..12) |_| { _ = reader.readU64(); } // magic through ctime
    const extent_root = reader.readU64();
    _ = reader.readU16(); // extent_count

    if (extent_root == 0) return error.NotFound;

    // Read directory data from extent
    var buffer: [4096]u8 = undefined;
    try fs.device.read(extent_root * fs.cluster_size, &buffer);

    // Find actual size by parsing
    var dir_reader = serialization.createReader(&buffer);
    _ = dir_reader.readU32(); // magic
    _ = dir_reader.readU16(); // version
    const entry_count = dir_reader.readU16() catch 0;
    for (0..entry_count) |_| {
        _ = dir_reader.readU64();
        const name_len = dir_reader.readU16() catch 0;
        _ = dir_reader.readU8();
        _ = dir_reader.readU8();
        dir_reader.offset += @as(usize, @intCast(name_len));
        const padding = (8 - (dir_reader.offset % 8)) % 8;
        dir_reader.offset += padding;
    }
    _ = dir_reader.readU32(); // crc
    return buffer[0..dir_reader.offset];
}

// Find directory entry inode number
fn findDirEntry(fs: *Fs, parent: u64, name: []const u8) !u64 {
    const dir_data = readDirectory(fs, parent) catch |err| return err;
    var reader = serialization.createReader(dir_data);
    var dir = directory.LinearDirectory.deserialize(&reader, fs.allocator) catch |err| return err;
    defer dir.deinit();

    const entry = dir.find(name) orelse return error.NotFound;
    return entry.inode;
}

fn findDirectoryCluster(fs: *Fs, inode_num: u64) u64 {
    // Read inode to get directory extent
    const inode_data = readInode(fs, inode_num) catch |_| return fs.superblock.first_ag_offset + 30;
    var reader = serialization.createReader(inode_data);

    // Skip to extent info
    for (0..12) |_| { _ = reader.readU64(); } // magic through ctime
    const extent_root = reader.readU64();

    if (extent_root == 0) return fs.superblock.first_ag_offset + 30;
    return extent_root;
}

fn addDirEntry(fs: *Fs, parent: u64, name: []const u8, child: u64, file_type: u8) !void {
    const dir_data = readDirectory(fs, parent) catch |err| return err;
    var reader = serialization.createReader(dir_data);
    var dir = directory.LinearDirectory.deserialize(&reader, fs.allocator) catch |err| return err;
    defer dir.deinit();

    dir.insert(directory.DirEntry{
        .inode = child,
        .name = name,
        .file_type = file_type,
        .flags = 0,
    }) catch |err| return err;

    var writer = serialization.createWriter(fs.allocator);
    defer writer.deinit();
    dir.serialize(&writer) catch |err| return err;

    const dir_cluster = findDirectoryCluster(fs, parent);
    fs.device.write(dir_cluster * fs.cluster_size, writer.bytes()) catch |err| return err;
}

fn readFileData(fs: *Fs, inode_num: u64, offset: u64, size: usize) ![]u8 {
    // Read inode to get extent
    const inode_data = readInode(fs, inode_num) catch |err| return err;
    var reader = serialization.createReader(inode_data);

    // Skip to extent info
    for (0..12) |_| { _ = reader.readU64(); } // magic through ctime
    const extent_root = reader.readU64();
    _ = reader.readU16(); // extent_count

    if (extent_root == 0) return error.NotFound;

    const clusters_needed = (size + fs.cluster_size - 1) / fs.cluster_size;
    const start_cluster = extent_root + offset / fs.cluster_size;

    var result = try fs.allocator.alloc(u8, size);
    var result_offset: usize = 0;

    for (0..clusters_needed) |i| {
        const cluster = start_cluster + i;
        var buffer: [4096]u8 = undefined;
        try fs.device.read(cluster * fs.cluster_size, &buffer);
        const to_copy = @min(fs.cluster_size as usize, size - result_offset);
        @memcpy(result[result_offset..result_offset + to_copy], buffer[0..to_copy]);
        result_offset += to_copy;
    }

    return result;
}

fn writeFileData(fs: *Fs, inode_num: u64, offset: u64, data: []const u8) !void {
    // Simplified: would need to allocate clusters, update extent tree
    _ = fs; _ = inode_num; _ = offset; _ = data;
}

// ============================================================================
// C API Type Definitions (matching ufs.h)
// ============================================================================

// Note: These are defined inline in the function signatures above
// The actual C types are defined in ufs.h

// MountOptions for C API
export fn ufs_mount_options_defaults() MountOptions {
    return .{
        .read_only = false,
        .case_insensitive = true,
        .compression = 1, // LZ4
        .integrity_check = 1, // metadata only
        .journal_size = 0,
    };
}

// ============================================================================
// Build-time verification that all C API functions are exported
// ============================================================================

const _ = @typeInfo(Fs);
const _ = @typeInfo(MountOptions);

// Export verification - these will cause compile errors if functions don't exist
const _ = @typeInfo(@TypeOf(ufs_format));
const _ = @typeInfo(@TypeOf(ufs_mount));
const _ = @typeInfo(@TypeOf(ufs_unmount));
const _ = @typeInfo(@TypeOf(ufs_sync));
const _ = @typeInfo(@TypeOf(ufs_statfs));
const _ = @typeInfo(@TypeOf(ufs_create_inode));
const _ = @typeInfo(@TypeOf(ufs_lookup));
const _ = @typeInfo(@TypeOf(ufs_getattr));
const _ = @typeInfo(@TypeOf(ufs_setattr));
const _ = @typeInfo(@TypeOf(ufs_delete_inode));
const _ = @typeInfo(@TypeOf(ufs_unlink_dirent));
const _ = @typeInfo(@TypeOf(ufs_link_dirent));
const _ = @typeInfo(@TypeOf(ufs_opendir));
const _ = @typeInfo(@TypeOf(ufs_readdir));
const _ = @typeInfo(@TypeOf(ufs_closedir));
const _ = @typeInfo(@TypeOf(ufs_mkdir));
const _ = @typeInfo(@TypeOf(ufs_rmdir));
const _ = @typeInfo(@TypeOf(ufs_rename));
const _ = @typeInfo(@TypeOf(ufs_symlink));
const _ = @typeInfo(@TypeOf(ufs_readlink));
const _ = @typeInfo(@TypeOf(ufs_open));
const _ = @typeInfo(@TypeOf(ufs_close));
const _ = @typeInfo(@TypeOf(ufs_read));
const _ = @typeInfo(@TypeOf(ufs_write));
const _ = @typeInfo(@TypeOf(ufs_seek));
const _ = @typeInfo(@TypeOf(ufs_truncate));
const _ = @typeInfo(@TypeOf(ufs_fallocate));
const _ = @typeInfo(@TypeOf(ufs_fsync));
const _ = @typeInfo(@TypeOf(ufs_get_extents));
const _ = @typeInfo(@TypeOf(ufs_setxattr));
const _ = @typeInfo(@TypeOf(ufs_getxattr));
const _ = @typeInfo(@TypeOf(ufs_listxattr));
const _ = @typeInfo(@TypeOf(ufs_removexattr));
const _ = @typeInfo(@TypeOf(ufs_get_volume_uuid));
const _ = @typeInfo(@TypeOf(ufs_set_volume_label));
const _ = @typeInfo(@TypeOf(ufs_get_volume_label));
const _ = @typeInfo(@TypeOf(ufs_get_features));
const _ = @typeInfo(@TypeOf(ufs_set_feature));
const _ = @typeInfo(@TypeOf(ufs_checkpoint));
const _ = @typeInfo(@TypeOf(ufs_scrub));
const _ = @typeInfo(@TypeOf(ufs_needs_recovery));
const _ = @typeInfo(@TypeOf(ufs_recover));
const _ = @typeInfo(@TypeOf(ufs_verify_journal));
const _ = @typeInfo(@TypeOf(ufs_set_compression));
const _ = @typeInfo(@TypeOf(ufs_get_compression));
const _ = @typeInfo(@TypeOf(ufs_set_encryption));
const _ = @typeInfo(@TypeOf(ufs_strerror));
const _ = @typeInfo(@TypeOf(ufs_timestamp));
const _ = @typeInfo(@TypeOf(ufs_generate_uuidv7));
const _ = @typeInfo(@TypeOf(ufs_crc32c));
const _ = @typeInfo(@TypeOf(ufs_blake3));