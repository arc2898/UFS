// UFS Block Device Abstraction - Platform Abstraction Layer (PAL)
// Provides unified interface for block I/O across Windows, Linux, macOS, UEFI

const std = @import("std");
const utils = @import("utils.zig");
const Allocator = std.mem.Allocator;

pub const BlockDeviceError = error{
    NotInitialized,
    InvalidArgument,
    IoError,
    DeviceNotFound,
    PermissionDenied,
    UnsupportedOperation,
    MediaChanged,
    WriteProtected,
    OutOfBounds,
    AlignmentRequired,
    Timeout,
    InternalError,
};

pub const BlockDeviceFlags = packed struct {
    read_only: bool = false,
    write_cache: bool = true,
    flush_on_write: bool = false,
    direct_io: bool = false,
    async_io: bool = false,
};

pub const BlockDeviceInfo = struct {
    block_size: u32 = 512,
    physical_block_size: u32 = 512,
    optimal_io_size: u32 = 0,
    total_blocks: u64 = 0,
    is_removable: bool = false,
    is_read_only: bool = false,
    is_ssd: bool = false,
    is_virtual: bool = false,
    serial_number: []const u8 = &[_]u8{},
    model: []const u8 = &[_]u8{},
    firmware: []const u8 = &[_]u8{},
};

pub const IoResult = struct {
    bytes_transferred: usize = 0,
    status: BlockDeviceError = error.IoError,
};

pub const AsyncIoContext = opaque {};
pub const AsyncIoCallback = *const fn (context: *AsyncIoContext, result: IoResult) void;

// Block device interface - implement for each platform
pub const BlockDevice = struct {
    // Platform-specific context (opaque)
    context: *anyopaque,

    // Virtual function table
    vtable: *const VTable,

    pub const VTable = struct {
        // Synchronous operations
        read: *const fn (device: *BlockDevice, offset: u64, buffer: []u8) !void,
        write: *const fn (device: *BlockDevice, offset: u64, buffer: []const u8) !void,
        flush: *const fn (device: *BlockDevice) !void,
        trim: *const fn (device: *BlockDevice, offset: u64, length: u64) !void,

        // Asynchronous operations (optional)
        read_async: ?*const fn (device: *BlockDevice, offset: u64, buffer: []u8, callback: AsyncIoCallback, context: *AsyncIoContext) !void,
        write_async: ?*const fn (device: *BlockDevice, offset: u64, buffer: []const u8, callback: AsyncIoCallback, context: *AsyncIoContext) !void,

        // Device management
        get_info: *const fn (device: *BlockDevice) BlockDeviceInfo,
        set_flags: *const fn (device: *BlockDevice, flags: BlockDeviceFlags) !void,
        get_flags: *const fn (device: *BlockDevice) BlockDeviceFlags,

        // Lifecycle
        open: *const fn (device: *BlockDevice, path: []const u8, flags: BlockDeviceFlags) !void,
        close: *const fn (device: *BlockDevice) !void,

        // Geometry
        get_geometry: *const fn (device: *BlockDevice) Geometry,
    };

    pub const Geometry = struct {
        cylinders: u64,
        heads: u32,
        sectors_per_track: u32,
        bytes_per_sector: u32,
    };

    // Helper methods
    pub fn read(self: *BlockDevice, offset: u64, buffer: []u8) !void {
        return self.vtable.read(self, offset, buffer);
    }

    pub fn write(self: *BlockDevice, offset: u64, buffer: []const u8) !void {
        return self.vtable.write(self, offset, buffer);
    }

    pub fn flush(self: *BlockDevice) !void {
        return self.vtable.flush(self);
    }

    pub fn trim(self: *BlockDevice, offset: u64, length: u64) !void {
        return self.vtable.trim(self, offset, length);
    }

    pub fn readAsync(self: *BlockDevice, offset: u64, buffer: []u8, callback: AsyncIoCallback, context: *AsyncIoContext) !void {
        if (self.vtable.read_async) |fn| {
            return fn(self, offset, buffer, callback, context);
        }
        return error.UnsupportedOperation;
    }

    pub fn writeAsync(self: *BlockDevice, offset: u64, buffer: []const u8, callback: AsyncIoCallback, context: *AsyncIoContext) !void {
        if (self.vtable.write_async) |fn| {
            return fn(self, offset, buffer, callback, context);
        }
        return error.UnsupportedOperation;
    }

    pub fn getInfo(self: *BlockDevice) BlockDeviceInfo {
        return self.vtable.get_info(self);
    }

    pub fn setFlags(self: *BlockDevice, flags: BlockDeviceFlags) !void {
        return self.vtable.set_flags(self, flags);
    }

    pub fn getFlags(self: *BlockDevice) BlockDeviceFlags {
        return self.vtable.get_flags(self);
    }

    pub fn open(self: *BlockDevice, path: []const u8, flags: BlockDeviceFlags) !void {
        return self.vtable.open(self, path, flags);
    }

    pub fn close(self: *BlockDevice) !void {
        return self.vtable.close(self);
    }

    pub fn getGeometry(self: *BlockDevice) Geometry {
        return self.vtable.get_geometry(self);
    }

    // Convenience methods for cluster-aligned I/O
    pub fn readCluster(self: *BlockDevice, cluster: u64, cluster_size: u32, buffer: []u8) !void {
        const offset = cluster * cluster_size;
        if (buffer.len != cluster_size) return error.InvalidArgument;
        return self.read(offset, buffer);
    }

    pub fn writeCluster(self: *BlockDevice, cluster: u64, cluster_size: u32, buffer: []const u8) !void {
        const offset = cluster * cluster_size;
        if (buffer.len != cluster_size) return error.InvalidArgument;
        return self.write(offset, buffer);
    }

    pub fn readClusters(self: *BlockDevice, start_cluster: u64, cluster_count: u64, cluster_size: u32, buffer: []u8) !void {
        const offset = start_cluster * cluster_size;
        const expected_len = @as(usize, @intCast(cluster_count * cluster_size));
        if (buffer.len != expected_len) return error.InvalidArgument;
        return self.read(offset, buffer);
    }

    pub fn writeClusters(self: *BlockDevice, start_cluster: u64, cluster_count: u64, cluster_size: u32, buffer: []const u8) !void {
        const offset = start_cluster * cluster_size;
        const expected_len = @as(usize, @intCast(cluster_count * cluster_size));
        if (buffer.len != expected_len) return error.InvalidArgument;
        return self.write(offset, buffer);
    }
};

// Block device registry for platform implementations
pub const BlockDeviceRegistry = struct {
    // Registry storage is not implemented yet. Keep registration fail-closed
    // rather than exposing a map with an invalid key/hash configuration.
    pub fn register(name: []const u8, vtable: *const BlockDevice.VTable) !void {
        // Registry storage is not implemented yet; avoid allocating and leaking
        // a name that is never registered.
        _ = name;
        _ = vtable;
    }

    pub fn create(name: []const u8, allocator: Allocator) !*BlockDevice {
        // Look up vtable by name and create instance
        _ = name;
        _ = allocator;
        return error.DeviceNotFound;
    }
};

// Platform-specific implementations will be in separate files:
// - blockdev_linux.zig (io_uring, libaio, pread/pwrite)
// - blockdev_windows.zig (OVERLAPPED, FILE_FLAG_NO_BUFFERING)
// - blockdev_macos.zig (IOKit, kqueue)
// - blockdev_uefi.zig (EFI_BLOCK_IO_PROTOCOL)
// - blockdev_file.zig (regular file for testing)

// File-backed block device for testing
pub fn createFileBlockDevice(allocator: Allocator, path: []const u8, flags: BlockDeviceFlags) !*BlockDevice {
    const file = std.fs.cwd().openFile(path, .{ .mode = if (flags.read_only) .read_only else .read_write }) catch |err| switch (err) {
        error.NotFound => return error.DeviceNotFound,
        error.AccessDenied => return error.PermissionDenied,
        else => return error.IoError,
    };

    const info = try file.stat();
    const block_size: u32 = 4096;
    const total_blocks = info.size / block_size;

    const device_info = BlockDeviceInfo{
        .block_size = block_size,
        .physical_block_size = block_size,
        .optimal_io_size = 128 * 1024,
        .total_blocks = total_blocks,
        .is_removable = false,
        .is_read_only = flags.read_only,
        .is_ssd = false,
        .is_virtual = true,
    };

    const vtable = &FileBlockDeviceVTable;
    const context = try allocator.create(FileContext);
    context.* = .{
        .file = file,
        .info = device_info,
        .flags = flags,
        .path = try allocator.dupe(u8, path),
    };

    return try allocator.create(BlockDevice).init(.{
        .context = context,
        .vtable = vtable,
    });
}

const FileContext = struct {
    file: std.fs.File,
    info: BlockDeviceInfo,
    flags: BlockDeviceFlags,
    path: []u8,
};

const FileBlockDeviceVTable = BlockDevice.VTable{
    .read = fileRead,
    .write = fileWrite,
    .flush = fileFlush,
    .trim = fileTrim,
    .read_async = null,
    .write_async = null,
    .get_info = fileGetInfo,
    .set_flags = fileSetFlags,
    .get_flags = fileGetFlags,
    .open = fileOpen,
    .close = fileClose,
    .get_geometry = fileGetGeometry,
};

fn fileRead(device: *BlockDevice, offset: u64, buffer: []u8) !void {
    const ctx = @as(*FileContext, @ptrCast(device.context));
    const file = ctx.file;
    const bytes_read = file.pread(buffer, offset) catch return error.IoError;
    if (bytes_read != buffer.len) return error.IoError;
}

fn fileWrite(device: *BlockDevice, offset: u64, buffer: []const u8) !void {
    const ctx = @as(*FileContext, @ptrCast(device.context));
    const file = ctx.file;
    if (ctx.flags.read_only) return error.WriteProtected;
    const bytes_written = file.pwrite(buffer, offset) catch return error.IoError;
    if (bytes_written != buffer.len) return error.IoError;
}

fn fileFlush(device: *BlockDevice) !void {
    const ctx = @as(*FileContext, @ptrCast(device.context));
    ctx.file.sync() catch return error.IoError;
}

fn fileTrim(device: *BlockDevice, offset: u64, length: u64) !void {
    // File-backed doesn't support trim
    _ = offset;
    _ = length;
    return error.UnsupportedOperation;
}

fn fileGetInfo(device: *BlockDevice) BlockDeviceInfo {
    const ctx = @as(*FileContext, @ptrCast(device.context));
    return ctx.info;
}

fn fileSetFlags(device: *BlockDevice, flags: BlockDeviceFlags) !void {
    const ctx = @as(*FileContext, @ptrCast(device.context));
    ctx.flags = flags;
}

fn fileGetFlags(device: *BlockDevice) BlockDeviceFlags {
    const ctx = @as(*FileContext, @ptrCast(device.context));
    return ctx.flags;
}

fn fileOpen(device: *BlockDevice, path: []const u8, flags: BlockDeviceFlags) !void {
    _ = device;
    _ = path;
    _ = flags;
    return error.UnsupportedOperation;
}

fn fileClose(device: *BlockDevice) !void {
    const ctx = @as(*FileContext, @ptrCast(device.context));
    _ = ctx.file.close();
}

fn fileGetGeometry(device: *BlockDevice) BlockDevice.Geometry {
    _ = device;
    return .{
        .cylinders = 0,
        .heads = 0,
        .sectors_per_track = 0,
        .bytes_per_sector = 4096,
    };
}

// Cached block device wrapper. Cached blocks are owned by the cache allocator;
// dirty blocks are flushed before eviction and every allocation has one owner.
pub fn CachedBlockDevice(comptime BaseDevice: type) type {
    return struct {
        const Self = @This();
        base: BaseDevice,
        allocator: Allocator,
        cache: std.AutoHashMap(u64, CachedBlock),
        cache_size: usize = 0,
        max_cache_size: usize,

        pub const CachedBlock = struct {
            cluster: u64,
            data: []u8,
            dirty: bool,
            last_access: u64,
        };

        pub fn init(base: BaseDevice, max_cache_size: usize, allocator: Allocator) !Self {
            return .{
                .base = base,
                .allocator = allocator,
                .cache = std.AutoHashMap(u64, CachedBlock).init(allocator),
                .cache_size = 0,
                .max_cache_size = max_cache_size,
            };
        }

        pub fn deinit(self: *Self) void {
            var iterator = self.cache.iterator();
            while (iterator.next()) |entry| {
                self.allocator.free(entry.value_ptr.data);
            }
            self.cache.deinit();
            self.cache_size = 0;
        }

        pub fn read(self: *Self, cluster: u64, cluster_size: u32) ![]u8 {
            if (self.cache.getPtr(cluster)) |entry| {
                entry.last_access = utils.timestamp();
                return entry.data;
            }

            const buffer = try self.allocator.alloc(u8, cluster_size);
            self.base.read(cluster * cluster_size, buffer) catch |err| {
                self.allocator.free(buffer);
                return err;
            };
            self.cache.put(cluster, .{
                .cluster = cluster,
                .data = buffer,
                .dirty = false,
                .last_access = utils.timestamp(),
            }) catch |err| {
                self.allocator.free(buffer);
                return err;
            };
            self.cache_size += buffer.len;
            try self.evictIfNeeded(cluster);
            const cached = self.cache.getPtr(cluster) orelse return error.InternalError;
            return cached.data;
        }

        pub fn write(self: *Self, cluster: u64, cluster_size: u32, data: []const u8) !void {
            if (data.len != cluster_size) return error.InvalidArgument;
            if (self.cache.getPtr(cluster)) |entry| {
                @memcpy(entry.data, data);
                entry.dirty = true;
                entry.last_access = utils.timestamp();
            } else {
                const buffer = try self.allocator.dupe(u8, data);
                self.cache.put(cluster, .{
                    .cluster = cluster,
                    .data = buffer,
                    .dirty = true,
                    .last_access = utils.timestamp(),
                }) catch |err| {
                    self.allocator.free(buffer);
                    return err;
                };
                self.cache_size += buffer.len;
            }
            try self.evictIfNeeded(cluster);
        }

        pub fn flush(self: *Self) !void {
            var iterator = self.cache.iterator();
            while (iterator.next()) |entry| {
                if (entry.value_ptr.dirty) {
                    try self.base.write(entry.value_ptr.cluster * entry.value_ptr.data.len, entry.value_ptr.data);
                    entry.value_ptr.dirty = false;
                }
            }
            try self.base.flush();
        }

        fn evictIfNeeded(self: *Self, protected_cluster: u64) !void {
            while (self.cache_size > self.max_cache_size and self.cache.count() > 1) {
                var oldest_key: ?u64 = null;
                var oldest_access: u64 = std.math.maxInt(u64);
                var iterator = self.cache.iterator();
                while (iterator.next()) |entry| {
                    if (entry.key_ptr.* == protected_cluster) continue;
                    if (entry.value_ptr.last_access <= oldest_access) {
                        oldest_access = entry.value_ptr.last_access;
                        oldest_key = entry.key_ptr.*;
                    }
                }
                const key = oldest_key orelse break;
                if (self.cache.getPtr(key)) |entry| {
                    if (entry.dirty) {
                        try self.base.write(entry.cluster * entry.data.len, entry.data);
                    }
                    const data = entry.data;
                    self.cache_size -= data.len;
                    self.allocator.free(data);
                }
                _ = self.cache.remove(key);
            }
        }
    };
}
