// UFS Serialization Layer - Canonical Binary Encoding
// Handles read/write of all on-disk structures with proper endianness and CRC32C

const std = @import("std");
const utils = @import("utils.zig");
const Allocator = std.mem.Allocator;

pub const Endianness = std.builtin.Endian.Little;

// Writer for serializing structures to bytes
pub fn Writer(comptime T: type) type {
    return struct {
    const Self = @This();
        buffer: std.ArrayList(u8),
        allocator: Allocator,

        pub fn init(allocator: Allocator) Self {
            return .{
                .buffer = std.ArrayList(u8).init(allocator),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.buffer.deinit();
        }

        pub fn bytes(self: *Self) []u8 {
            return self.buffer.items;
        }

        // Transfer ownership so callers can safely return serialized data.
        // The writer remains valid and can still be deinitialized afterwards.
        pub fn toOwnedSlice(self: *Self) ![]u8 {
            return try self.buffer.toOwnedSlice();
        }

        pub fn reset(self: *Self) void {
            self.buffer.clearRetainingCapacity();
        }

        // Write primitive types
        pub fn writeU8(self: *Self, value: u8) !void {
            try self.buffer.append(value);
        }

        pub fn writeU16(self: *Self, value: u16) !void {
            var bytes: [2]u8 = undefined;
            std.mem.writeInt(u16, &bytes, value, Endianness);
            try self.buffer.appendSlice(&bytes);
        }

        pub fn writeU32(self: *Self, value: u32) !void {
            var bytes: [4]u8 = undefined;
            std.mem.writeInt(u32, &bytes, value, Endianness);
            try self.buffer.appendSlice(&bytes);
        }

        pub fn writeU64(self: *Self, value: u64) !void {
            var bytes: [8]u8 = undefined;
            std.mem.writeInt(u64, &bytes, value, Endianness);
            try self.buffer.appendSlice(&bytes);
        }

        pub fn writeI8(self: *Self, value: i8) !void {
            try self.buffer.append(@bitCast(value));
        }

        pub fn writeI16(self: *Self, value: i16) !void {
            var bytes: [2]u8 = undefined;
            std.mem.writeInt(i16, &bytes, value, Endianness);
            try self.buffer.appendSlice(&bytes);
        }

        pub fn writeI32(self: *Self, value: i32) !void {
            var bytes: [4]u8 = undefined;
            std.mem.writeInt(i32, &bytes, value, Endianness);
            try self.buffer.appendSlice(&bytes);
        }

        pub fn writeI64(self: *Self, value: i64) !void {
            var bytes: [8]u8 = undefined;
            std.mem.writeInt(i64, &bytes, value, Endianness);
            try self.buffer.appendSlice(&bytes);
        }

        // Write bytes
        pub fn writeBytes(self: *Self, data: []const u8) !void {
            try self.buffer.appendSlice(data);
        }

        // Write length-prefixed string (u16 length + UTF-8)
        pub fn writeString(self: *Self, str: []const u8) !void {
            if (str.len > 0xFFFF) return error.BufferTooSmall;
            try self.writeU16(@as(u16, @intCast(str.len)));
            try self.buffer.appendSlice(str);
        }

        // Write length-prefixed bytes (u32 length + data)
        pub fn writeVarBytes(self: *Self, data: []const u8) !void {
            if (data.len > @as(usize, std.math.maxInt(u32))) return error.BufferTooSmall;
            try self.writeU32(@as(u32, @intCast(data.len)));
            try self.buffer.appendSlice(data);
        }

        // Write fixed-size array
        pub fn writeArray(self: *Self, comptime N: usize, data: [N]u8) !void {
            try self.buffer.appendSlice(&data);
        }

        // Write struct using its serialize method
        pub fn writeStruct(self: *Self, value: anytype) !void {
            try value.serialize(self);
        }

        // Pad to alignment boundary
        pub fn align(self: *Self, alignment: usize) !void {
            if (alignment == 0) return error.InvalidArgument;
            const padding = (alignment - (self.buffer.items.len % alignment)) % alignment;
            for (0..padding) |_| {
                try self.buffer.append(0);
            }
        }

        // Write CRC32C of all data written so far
        pub fn writeCrc32c(self: *Self) !void {
            const crc = utils.crc32c(self.buffer.items);
            try self.writeU32(crc);
        }
    };
}

// Reader for deserializing structures from bytes
pub fn Reader(comptime T: type) type {
    return struct {
    const Self = @This();
        data: []const u8,
        offset: usize = 0,

        pub fn init(data: []const u8) Self {
            return .{ .data = data };
        }

        pub fn remaining(self: *Self) usize {
            return self.data.len - self.offset;
        }

        pub fn eof(self: *Self) bool {
            return self.offset >= self.data.len;
        }

        // Read primitive types
        pub fn readU8(self: *Self) !u8 {
            if (self.offset >= self.data.len) return error.InvalidFormat;
            const value = self.data[self.offset];
            self.offset += 1;
            return value;
        }

        pub fn readU16(self: *Self) !u16 {
            if (self.offset + 2 > self.data.len) return error.InvalidFormat;
            const value = std.mem.readInt(u16, self.data[self.offset..self.offset+2], Endianness);
            self.offset += 2;
            return value;
        }

        pub fn readU32(self: *Self) !u32 {
            if (self.offset + 4 > self.data.len) return error.InvalidFormat;
            const value = std.mem.readInt(u32, self.data[self.offset..self.offset+4], Endianness);
            self.offset += 4;
            return value;
        }

        pub fn readU64(self: *Self) !u64 {
            if (self.offset + 8 > self.data.len) return error.InvalidFormat;
            const value = std.mem.readInt(u64, self.data[self.offset..self.offset+8], Endianness);
            self.offset += 8;
            return value;
        }

        pub fn readI8(self: *Self) !i8 {
            const u = try self.readU8();
            return @bitCast(u);
        }

        pub fn readI16(self: *Self) !i16 {
            if (self.offset + 2 > self.data.len) return error.InvalidFormat;
            const value = std.mem.readInt(i16, self.data[self.offset..self.offset+2], Endianness);
            self.offset += 2;
            return value;
        }

        pub fn readI32(self: *Self) !i32 {
            if (self.offset + 4 > self.data.len) return error.InvalidFormat;
            const value = std.mem.readInt(i32, self.data[self.offset..self.offset+4], Endianness);
            self.offset += 4;
            return value;
        }

        pub fn readI64(self: *Self) !i64 {
            if (self.offset + 8 > self.data.len) return error.InvalidFormat;
            const value = std.mem.readInt(i64, self.data[self.offset..self.offset+8], Endianness);
            self.offset += 8;
            return value;
        }

        // Read bytes
        pub fn readBytes(self: *Self, len: usize) ![]const u8 {
            if (self.offset + len > self.data.len) return error.InvalidFormat;
            const slice = self.data[self.offset..self.offset+len];
            self.offset += len;
            return slice;
        }

        // Read length-prefixed string
        pub fn readString(self: *Self, allocator: Allocator) ![]u8 {
            const len = try self.readU16();
            const bytes = try self.readBytes(@as(usize, @intCast(len)));
            var result = try allocator.alloc(u8, len);
            @memcpy(result, bytes);
            return result;
        }

        // Read length-prefixed bytes
        pub fn readVarBytes(self: *Self, allocator: Allocator) ![]u8 {
            const len = try self.readU32();
            const bytes = try self.readBytes(@as(usize, @intCast(len)));
            var result = try allocator.alloc(u8, len);
            @memcpy(result, bytes);
            return result;
        }

        // Read fixed-size array
        pub fn readArray(self: *Self, comptime N: usize) ![N]u8 {
            var arr: [N]u8 = undefined;
            const bytes = try self.readBytes(N);
            @memcpy(&arr, bytes);
            return arr;
        }

        // Read struct using its deserialize method
        pub fn readStruct(self: *Self, comptime T: type, allocator: Allocator) !T {
            return T.deserialize(self, allocator);
        }

        // Pad to alignment boundary
        pub fn align(self: *Self, alignment: usize) !void {
            if (alignment == 0) return error.InvalidArgument;
            const padding = (alignment - (self.offset % alignment)) % alignment;
            if (padding > self.data.len -| self.offset) return error.InvalidFormat;
            self.offset += padding;
        }

        // Read and verify CRC32C
        pub fn readAndVerifyCrc32c(self: *Self) !void {
            const expected = try self.readU32();
            const actual = utils.crc32c(self.data[0..self.offset-4]);
            if (expected != actual) return error.CorruptedData;
        }

        // Peek at next bytes without consuming
        pub fn peek(self: *Self, len: usize) ![]const u8 {
            if (self.offset + len > self.data.len) return error.InvalidFormat;
            return self.data[self.offset..self.offset+len];
        }

        // Skip bytes
        pub fn skip(self: *Self, len: usize) !void {
            if (self.offset + len > self.data.len) return error.InvalidFormat;
            self.offset += len;
        }
    };
}

// Trait for serializable types
pub fn Serializable(comptime T: type) bool {
    return @hasDecl(T, "serialize") and @hasDecl(T, "deserialize");
}

// Helper to create writer
pub fn createWriter(allocator: Allocator) Writer(void) {
    return Writer(void).init(allocator);
}

// Helper to create reader
pub fn createReader(data: []const u8) Reader(void) {
    return Reader(void).init(data);
}

// Common serialization patterns for on-disk structures

// Magic number verification
pub fn verifyMagic(reader: *Reader(void), expected: u32) !void {
    const magic = try reader.readU32();
    if (magic != expected) return error.InvalidFormat;
}

// Write magic number
pub fn writeMagic(writer: *Writer(void), magic: u32) !void {
    try writer.writeU32(magic);
}

// Standard header for all major structures
pub const StandardHeader = struct {
    magic: u32,
    version: u16,
    flags: u16,

    pub fn serialize(self: StandardHeader, writer: *Writer(void)) !void {
        try writer.writeU32(self.magic);
        try writer.writeU16(self.version);
        try writer.writeU16(self.flags);
    }

    pub fn deserialize(reader: *Reader(void), allocator: Allocator) !StandardHeader {
        const magic = try reader.readU32();
        const version = try reader.readU16();
        const flags = try reader.readU16();
        return .{ .magic = magic, .version = version, .flags = flags };
    }

    pub fn size() usize {
        return 8; // 4 + 2 + 2
    }
};

// Standard footer with CRC32C
pub const StandardFooter = struct {
    crc32c: u32,

    pub fn serialize(self: StandardFooter, writer: *Writer(void)) !void {
        try writer.writeU32(self.crc32c);
    }

    pub fn deserialize(reader: *Reader(void), allocator: Allocator) !StandardFooter {
        const crc32c = try reader.readU32();
        return .{ .crc32c = crc32c };
    }

    pub fn size() usize {
        return 4;
    }
};

// Calculate CRC32C for a structure (excluding the CRC field itself)
pub fn calculateCrc32c(data: []const u8) u32 {
    return utils.crc32c(data);
}

// Serialize with automatic CRC32C
pub fn serializeWithCrc(
    writer: *Writer(void),
    serializeFn: fn(*Writer(void)) !void,
) !void {
    const start_offset = writer.buffer.items.len;
    try serializeFn(writer);
    const data = writer.buffer.items[start_offset..];
    const crc = utils.crc32c(data);
    try writer.writeU32(crc);
}

// Deserialize with CRC32C verification
pub fn deserializeWithCrc(
    reader: *Reader(void),
    allocator: Allocator,
    deserializeFn: fn(*Reader(void), Allocator) !void,
) !void {
    const start_offset = reader.offset;
    try deserializeFn(reader, allocator);
    const data = reader.data[start_offset..reader.offset-4];
    const expected = try reader.readU32();
    const actual = utils.crc32c(data);
    if (expected != actual) return error.CorruptedData;
}