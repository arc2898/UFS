// Utils Module
// Common helper functions

const std = @import("std");

pub const Allocator = std.mem.Allocator;

pub fn timestamp() u64 {
    return @import("../src/utils.zig").timestamp();
}

pub fn timestampSec() u64 {
    return @import("../src/utils.zig").timestampSec();
}

pub fn generateUuidv7() u64 {
    return @import("../src/utils.zig").generateUuidv7();
}

pub fn generateUuidv7Bytes() [16]u8 {
    return @import("../src/utils.zig").generateUuidv7Bytes();
}

pub fn randomBytes(allocator: Allocator, len: usize) ![]u8 {
    return @import("../src/utils.zig").randomBytes(allocator, len);
}

pub fn randomBytesFixed(comptime N: usize) [N]u8 {
    return @import("../src/utils.zig").randomBytesFixed(N);
}

pub fn crc32c(data: []const u8) u32 {
    return @import("../src/utils.zig").crc32c(data);
}

pub fn blake3(data: []const u8) [32]u8 {
    return @import("../src/utils.zig").blake3(data);
}

pub fn strcmp(a: []const u8, b: []const u8) i32 {
    return @import("../src/utils.zig").strcmp(a, b);
}

pub fn strcasecmp(a: []const u8, b: []const u8) i32 {
    return @import("../src/utils.zig").strcasecmp(a, b);
}

pub fn pathJoin(allocator: Allocator, parts: [][]const u8) ![]u8 {
    return @import("../src/utils.zig").pathJoin(allocator, parts);
}

pub fn pathDirname(path: []const u8) []const u8 {
    return @import("../src/utils.zig").pathDirname(path);
}

pub fn pathBasename(path: []const u8) []const u8 {
    return @import("../src/utils.zig").pathBasename(path);
}

pub fn alignUp(value: usize, alignment: usize) usize {
    return @import("../src/utils.zig").alignUp(value, alignment);
}

pub fn alignDown(value: usize, alignment: usize) usize {
    return @import("../src/utils.zig").alignDown(value, alignment);
}

pub fn isPowerOfTwo(x: usize) bool {
    return @import("../src/utils.zig").isPowerOfTwo(x);
}

pub fn nextPowerOfTwo(x: usize) usize {
    return @import("../src/utils.zig").nextPowerOfTwo(x);
}

pub fn hexEncode(input: []const u8, output: []u8) void {
    return @import("../src/utils.zig").hexEncode(input, output);
}

pub fn hexDecode(input: []const u8, output: []u8) !void {
    return @import("../src/utils.zig").hexDecode(input, output);
}

pub fn base64Encode(input: []const u8, allocator: Allocator) ![]u8 {
    return @import("../src/utils.zig").base64Encode(input, allocator);
}

pub fn base64Decode(input: []const u8, allocator: Allocator) ![]u8 {
    return @import("../src/utils.zig").base64Decode(input, allocator);
}

pub const LogLevel = @import("../src/utils.zig").LogLevel;
pub fn setLogLevel(level: LogLevel) void {
    return @import("../src/utils.zig").setLogLevel(level);
}

pub fn log(level: LogLevel, comptime fmt: []const u8, args: anytype) void {
    return @import("../src/utils.zig").log(level, fmt, args);
}