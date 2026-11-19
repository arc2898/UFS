// Block Device Module
// Platform abstraction layer for block I/O

const std = @import("std");

pub const BlockDevice = @import("../src/blockdev.zig").BlockDevice;
pub const BlockDeviceError = @import("../src/blockdev.zig").BlockDeviceError;
pub const BlockDeviceFlags = @import("../src/blockdev.zig").BlockDeviceFlags;
pub const BlockDeviceInfo = @import("../src/blockdev.zig").BlockDeviceInfo;
pub const IoResult = @import("../src/blockdev.zig").IoResult;
pub const AsyncIoContext = @import("../src/blockdev.zig").AsyncIoContext;
pub const AsyncIoCallback = @import("../src/blockdev.zig").AsyncIoCallback;
pub const Geometry = @import("../src/blockdev.zig").Geometry;
pub const BlockDeviceRegistry = @import("../src/blockdev.zig").BlockDeviceRegistry;

pub fn createFileBlockDevice(allocator: Allocator, path: []const u8, flags: BlockDeviceFlags) !*BlockDevice {
    return @import("../src/blockdev.zig").createFileBlockDevice(allocator, path, flags);
}

pub fn CachedBlockDevice(comptime BaseDevice: type) type {
    return @import("../src/blockdev.zig").CachedBlockDevice(BaseDevice);
}

pub const Allocator = std.mem.Allocator;