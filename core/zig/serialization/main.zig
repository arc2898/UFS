// Serialization Module
// Canonical binary encoding for UFS on-disk structures

const std = @import("std");

pub const Writer = @import("../src/serialization.zig").Writer;
pub const Reader = @import("../src/serialization.zig").Reader;
pub const Serializable = @import("../src/serialization.zig").Serializable;
pub const StandardHeader = @import("../src/serialization.zig").StandardHeader;
pub const StandardFooter = @import("../src/serialization.zig").StandardFooter;

pub fn createWriter(allocator: Allocator) Writer(void) {
    return @import("../src/serialization.zig").createWriter(allocator);
}

pub fn createReader(data: []const u8) Reader(void) {
    return @import("../src/serialization.zig").createReader(data);
}

pub fn verifyMagic(reader: *Reader(void), expected: u32) !void {
    return @import("../src/serialization.zig").verifyMagic(reader, expected);
}

pub fn writeMagic(writer: *Writer(void), magic: u32) !void {
    return @import("../src/serialization.zig").writeMagic(writer, magic);
}

pub fn calculateCrc32c(data: []const u8) u32 {
    return @import("../src/serialization.zig").calculateCrc32c(data);
}

pub fn serializeWithCrc(
    writer: *Writer(void),
    serializeFn: fn(*Writer(void)) !void,
) !void {
    return @import("../src/serialization.zig").serializeWithCrc(writer, serializeFn);
}

pub fn deserializeWithCrc(
    reader: *Reader(void),
    allocator: Allocator,
    deserializeFn: fn(*Reader(void), Allocator) !void,
) !void {
    return @import("../src/serialization.zig").deserializeWithCrc(reader, allocator, deserializeFn);
}

pub const Allocator = std.mem.Allocator;