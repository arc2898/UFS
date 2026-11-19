// UFS Utilities - Common helper functions

const std = @import("std");

pub const Allocator = std.mem.Allocator;

// Timestamp utilities
pub fn timestamp() u64 {
    // Return nanoseconds since Unix epoch without narrowing a negative timestamp.
    const ns = std.time.nanoTimestamp();
    return if (ns <= 0) 0 else @intCast(ns);
}

pub fn timestampSec() u64 {
    const seconds = std.time.timestamp();
    return if (seconds <= 0) 0 else @intCast(seconds);
}

// UUIDv7 generation (time-ordered UUID)
pub fn generateUuidv7() u64 {
    // Simplified UUIDv7 - uses timestamp + random
    // Real implementation would follow RFC 9562
    const ts = timestamp() / 1_000_000; // milliseconds
    const random_part = std.crypto.random.int(u32);
    return (ts << 32) | random_part;
}

pub fn generateUuidv7Bytes() [16]u8 {
    var uuid: [16]u8 = undefined;
    const ts = timestamp() / 1_000_000; // milliseconds
    std.crypto.random.bytes(uuid[8..16]);

    // UUIDv7 layout: 48-bit Unix millisecond timestamp followed by random bits.
    const timestamp48: u48 = @truncate(ts);
    uuid[0] = @truncate(timestamp48 >> 40);
    uuid[1] = @truncate(timestamp48 >> 32);
    uuid[2] = @truncate(timestamp48 >> 24);
    uuid[3] = @truncate(timestamp48 >> 16);
    uuid[4] = @truncate(timestamp48 >> 8);
    uuid[5] = @truncate(timestamp48);


    // Set version (7) and variant bits
    uuid[6] = (uuid[6] & 0x0F) | 0x70; // Version 7
    uuid[8] = (uuid[8] & 0x3F) | 0x80; // Variant 10x

    return uuid;
}

// Random bytes
pub fn randomBytes(allocator: Allocator, len: usize) ![]u8 {
    const buf = try allocator.alloc(u8, len);
    std.crypto.random.bytes(buf);
    return buf;
}

pub fn randomBytesFixed(comptime N: usize) [N]u8 {
    var buf: [N]u8 = undefined;
    std.crypto.random.bytes(&buf);
    return buf;
}

// CRC32C (Castagnoli)
pub fn crc32c(data: []const u8) u32 {
    // Use the table from integrity.zig
    return Crc32cSoftware.compute(data);
}

const Crc32cSoftware = struct {
    const Table: [256]u32 = computeTable();

    fn computeTable() [256]u32 {
        var table: [256]u32 = undefined;
        for (0..256) |i| {
            var crc: u32 = @as(u32, @intCast(i));
            for (0..8) |_| {
                if ((crc & 1) != 0) {
                    crc = (crc >> 1) ^ 0x82F63B78;
                } else {
                    crc >>= 1;
                }
            }
            table[i] = crc;
        }
        return table;
    }

    pub fn compute(data: []const u8) u32 {
        var crc: u32 = 0xFFFFFFFF;
        for (data) |byte| {
            crc = Table[@as(usize, @intCast((crc ^ byte) & 0xFF))] ^ (crc >> 8);
        }
        return ~crc;
    }
};

// BLAKE3 hashing. Use Zig's audited implementation rather than the former
// placeholder mixer (which was not BLAKE3 and must never be used for integrity).
pub fn blake3(data: []const u8) [32]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.Blake3.hash(data, &digest, .{});
    return digest;
}

// String utilities
pub fn strcmp(a: []const u8, b: []const u8) i32 {
    return std.mem.order(u8, a, b);
}

pub fn strcasecmp(a: []const u8, b: []const u8) i32 {
    const min_len = @min(a.len, b.len);
    for (0..min_len) |i| {
        const ca = asciiToLower(a[i]);
        const cb = asciiToLower(b[i]);
        if (ca < cb) return -1;
        if (ca > cb) return 1;
    }
    return @as(i32, @intCast(a.len)) - @as(i32, @intCast(b.len));
}

fn asciiToLower(c: u8) u8 {
    if (c >= 'A' and c <= 'Z') return c + 32;
    return c;
}

pub fn asciiToLowerSlice(s: []u8) void {
    for (s) |*c| {
        if (*c >= 'A' and *c <= 'Z') *c += 32;
    }
}

// Path utilities
pub fn pathJoin(allocator: Allocator, parts: [][]const u8) ![]u8 {
    var joined = std.ArrayList(u8).init(allocator);
    defer joined.deinit();

    for (parts, 0..) |part, i| {
        if (i > 0) {
            try joined.append('/');
        }
        try joined.appendSlice(part);
    }

    return joined.toOwnedSlice();
}

pub fn pathDirname(path: []const u8) []const u8 {
    if (path.len == 0) return ".";

    var end = path.len;
    while (end > 1 and path[end - 1] == '/') : (end -= 1) {}
    const normalized = path[0..end];
    if (std.mem.eql(u8, normalized, "/")) return "/";

    if (std.mem.lastIndexOfScalar(u8, normalized, '/')) |slash| {
        if (slash == 0) return "/";
        return normalized[0..slash];
    }
    return ".";
}

pub fn pathBasename(path: []const u8) []const u8 {
    if (path.len == 0) return path;

    var end = path.len;
    while (end > 1 and path[end - 1] == '/') : (end -= 1) {}
    const normalized = path[0..end];
    if (std.mem.eql(u8, normalized, "/")) return normalized;
    if (std.mem.lastIndexOfScalar(u8, normalized, '/')) |slash| {
        return normalized[slash + 1 ..];
    }
    return normalized;
}

pub fn pathExtension(path: []const u8) []const u8 {
    const basename = pathBasename(path);
    if (basename.len == 0) return "";
    const dot = std.mem.lastIndexOfScalar(u8, basename, '.') orelse return "";
    // A leading dot alone denotes a hidden filename, not an extension.
    if (dot == 0) return "";
    return basename[dot + 1 ..];
}

// Bit operations
pub fn alignUp(value: usize, alignment: usize) usize {
    return (value + alignment - 1) & ~(alignment - 1);
}

pub fn alignDown(value: usize, alignment: usize) usize {
    return value & ~(alignment - 1);
}

pub fn isPowerOfTwo(x: usize) bool {
    return x != 0 and (x & (x - 1)) == 0;
}

pub fn nextPowerOfTwo(x: usize) usize {
    if (x == 0) return 1;
    x -= 1;
    x |= x >> 1;
    x |= x >> 2;
    x |= x >> 4;
    x |= x >> 8;
    x |= x >> 16;
    x |= x >> 32;
    return x + 1;
}

// Memory utilities
pub fn zeroMemory(ptr: *u8, len: usize) void {
    @memset(ptr[0..len], 0);
}

pub fn copyMemory(dst: *u8, src: *const u8, len: usize) void {
    @memcpy(dst[0..len], src[0..len]);
}

pub fn compareMemory(a: *const u8, b: *const u8, len: usize) i32 {
    return std.mem.order(u8, a[0..len], b[0..len]);
}

// Endian utilities
pub fn readU16Le(bytes: []const u8) u16 {
    return std.mem.readInt(u16, bytes[0..2], .little);
}

pub fn readU32Le(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .little);
}

pub fn readU64Le(bytes: []const u8) u64 {
    return std.mem.readInt(u64, bytes[0..8], .little);
}

pub fn writeU16Le(bytes: []u8, value: u16) void {
    std.mem.writeInt(u16, bytes[0..2], value, .little);
}

pub fn writeU32Le(bytes: []u8, value: u32) void {
    std.mem.writeInt(u32, bytes[0..4], value, .little);
}

pub fn writeU64Le(bytes: []u8, value: u64) void {
    std.mem.writeInt(u64, bytes[0..8], value, .little);
}

pub fn readU16Be(bytes: []const u8) u16 {
    return std.mem.readInt(u16, bytes[0..2], .big);
}

pub fn readU32Be(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .big);
}

pub fn readU64Be(bytes: []const u8) u64 {
    return std.mem.readInt(u64, bytes[0..8], .big);
}

pub fn writeU16Be(bytes: []u8, value: u16) void {
    std.mem.writeInt(u16, bytes[0..2], value, .big);
}

pub fn writeU32Be(bytes: []u8, value: u32) void {
    std.mem.writeInt(u32, bytes[0..4], value, .big);
}

pub fn writeU64Be(bytes: []u8, value: u64) void {
    std.mem.writeInt(u64, bytes[0..8], value, .big);
}

// Range utilities
pub fn Range(comptime T: type) struct {
    start: T,
    end: T,

    pub fn contains(self: Range(T), value: T) bool {
        return value >= self.start and value < self.end;
    }

    pub fn length(self: Range(T)) T {
        return self.end - self.start;
    }

    pub fn overlaps(self: Range(T), other: Range(T)) bool {
        return self.start < other.end and other.start < self.end;
    }

    pub fn intersection(self: Range(T), other: Range(T)) ?Range(T) {
        const start = @max(self.start, other.start);
        const end = @min(self.end, other.end);
        if (start < end) return .{ .start = start, .end = end };
        return null;
    }
};

// Result type helpers
pub fn ok(comptime T: type, value: T) !T {
    return value;
}

pub fn err(comptime E: type, error: E) !E {
    return error;
}

// Assertion helpers
pub fn assert(cond: bool, msg: []const u8) void {
    if (!cond) {
        std.debug.panic(msg);
    }
}

pub fn assertEq(comptime T: type, a: T, b: T, msg: []const u8) void {
    if (a != b) {
        std.debug.panic(msg ++ " (expected {}, got {})", .{b, a});
    }
}

// Logging
pub const LogLevel = enum {
    trace,
    debug,
    info,
    warn,
    error,
    fatal,
};

var global_log_level: LogLevel = .info;

pub fn setLogLevel(level: LogLevel) void {
    global_log_level = level;
}

pub fn log(level: LogLevel, comptime fmt: []const u8, args: anytype) void {
    if (level >= global_log_level) {
        const prefix = switch (level) {
            .trace => "[TRACE] ",
            .debug => "[DEBUG] ",
            .info => "[INFO] ",
            .warn => "[WARN] ",
            .error => "[ERROR] ",
            .fatal => "[FATAL] ",
        };
        std.log.info(prefix ++ fmt, args);
    }
}

pub fn trace(comptime fmt: []const u8, args: anytype) void {
    log(.trace, fmt, args);
}

pub fn debug(comptime fmt: []const u8, args: anytype) void {
    log(.debug, fmt, args);
}

pub fn info(comptime fmt: []const u8, args: anytype) void {
    log(.info, fmt, args);
}

pub fn warn(comptime fmt: []const u8, args: anytype) void {
    log(.warn, fmt, args);
}

pub fn error(comptime fmt: []const u8, args: anytype) void {
    log(.error, fmt, args);
}

pub fn fatal(comptime fmt: []const u8, args: anytype) void {
    log(.fatal, fmt, args);
}

// Hex encoding/decoding
pub fn hexEncode(input: []const u8, output: []u8) void {
    const hex_chars = "0123456789abcdef";
    for (input, 0..) |byte, i| {
        output[i * 2] = hex_chars[byte >> 4];
        output[i * 2 + 1] = hex_chars[byte & 0xF];
    }
}

pub fn hexDecode(input: []const u8, output: []u8) !void {
    if (input.len % 2 != 0) return error.InvalidArgument;
    if (output.len < input.len / 2) return error.BufferTooSmall;

    for (input[0..], 0..) |_, i| {
        const high = hexCharToValue(input[i * 2]) catch return error.InvalidArgument;
        const low = hexCharToValue(input[i * 2 + 1]) catch return error.InvalidArgument;
        output[i] = (high << 4) | low;
    }
}

fn hexCharToValue(c: u8) !u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return error.InvalidArgument;
}

// Base64 encoding/decoding (simplified)
pub fn base64Encode(input: []const u8, allocator: Allocator) ![]u8 {
    return std.base64.encode(allocator, input) catch |_| return error.OutOfMemory;
}

pub fn base64Decode(input: []const u8, allocator: Allocator) ![]u8 {
    return std.base64.decode(allocator, input) catch |_| return error.OutOfMemory;
}

// Testing utilities
pub const testing = struct {
    pub fn expectEqual(comptime T: type, actual: T, expected: T) void {
        if (actual != expected) {
            std.testing.fail("Expected {}, got {}", .{expected, actual});
        }
    }

    pub fn expectError(error: anytype, expected: anytype) void {
        if (!std.meta.eql(error, expected)) {
            std.testing.fail("Expected error {}, got {}", .{expected, error});
        }
    }
};