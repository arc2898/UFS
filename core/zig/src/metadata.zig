// UFS Metadata Capsule Implementation
// Namespaced, extensible containers for cross-platform metadata preservation

const std = @import("std");
const serialization = @import("serialization.zig");
const utils = @import("utils.zig");
const Allocator = std.mem.Allocator;

pub const MetadataError = error{
    InvalidNamespace,
    InvalidType,
    InvalidFormat,
    BufferTooSmall,
    NotFound,
    AlreadyExists,
    CrcMismatch,
    UnsupportedOperation,
    OutOfMemory,
};

pub const CapsuleFlags = packed struct {
    inline: bool = false,
    compressed: bool = false,
    encrypted: bool = false,
    signed: bool = false,
};

pub const CapsuleHeader = struct {
    magic: u32 = 0x43415053,  // "CAPS"
    version: u16 = 1,
    flags: u16 = 0,
    capsule_id: u64 = 0,      // UUIDv7 (time-ordered)
    inode: u64 = 0,
    entry_count: u32 = 0,
    size: u32 = 0,            // Total size including header
    crc32c: u32 = 0,

    pub fn serialize(self: CapsuleHeader, writer: *serialization.Writer(void)) !void {
        try writer.writeU32(self.magic);
        try writer.writeU16(self.version);
        try writer.writeU16(self.flags);
        try writer.writeU64(self.capsule_id);
        try writer.writeU64(self.inode);
        try writer.writeU32(self.entry_count);
        try writer.writeU32(self.size);
        // CRC32C written separately after entries
    }

    pub fn deserialize(reader: *serialization.Reader(void), allocator: Allocator) !CapsuleHeader {
        const magic = try reader.readU32();
        if (magic != 0x43415053) return MetadataError.InvalidFormat;
        const version = try reader.readU16();
        const flags = try reader.readU16();
        const capsule_id = try reader.readU64();
        const inode = try reader.readU64();
        const entry_count = try reader.readU32();
        const size = try reader.readU32();
        const crc32c = try reader.readU32();
        return .{
            .magic = magic,
            .version = version,
            .flags = flags,
            .capsule_id = capsule_id,
            .inode = inode,
            .entry_count = entry_count,
            .size = size,
            .crc32c = crc32c,
        };
    }

    pub const SIZE = 36; // 4 + 2 + 2 + 8 + 8 + 4 + 4 + 4
};

pub const CapsuleEntry = struct {
    namespace: u16 = 0,
    type: u16 = 0,
    flags: u16 = 0,
    name_length: u16 = 0,
    value_length: u32 = 0,
    name: []const u8 = &[_]u8{},
    value: []const u8 = &[_]u8{},
    crc32c: u32 = 0,

    pub fn serialize(self: CapsuleEntry, writer: *serialization.Writer(void)) !void {
        try writer.writeU16(self.namespace);
        try writer.writeU16(self.type);
        try writer.writeU16(self.flags);
        try writer.writeU16(self.name_length);
        try writer.writeU32(self.value_length);
        try writer.writeBytes(self.name);
        try writer.writeBytes(self.value);
        // CRC32C of name + value
    }

    pub fn deserialize(reader: *serialization.Reader(void), allocator: Allocator) !CapsuleEntry {
        const namespace = try reader.readU16();
        const type = try reader.readU16();
        const flags = try reader.readU16();
        const name_length = try reader.readU16();
        const value_length = try reader.readU32();
        const name = try reader.readBytes(@as(usize, @intCast(name_length)));
        const value = try reader.readBytes(@as(usize, @intCast(value_length)));
        const crc32c = try reader.readU32();
        return .{
            .namespace = namespace,
            .type = type,
            .flags = flags,
            .name_length = name_length,
            .value_length = value_length,
            .name = name,
            .value = value,
            .crc32c = crc32c,
        };
    }

    pub fn calculateCrc32c(self: CapsuleEntry, allocator: Allocator) !u32 {
        var writer = serialization.createWriter(allocator);
        defer writer.deinit();
        try writer.writeBytes(self.name);
        try writer.writeBytes(self.value);
        return utils.crc32c(writer.bytes());
    }
};

pub const MetadataCapsule = struct {
    const Self = @This();
    header: CapsuleHeader,
    entries: std.ArrayList(CapsuleEntry),
    allocator: Allocator,

    pub fn init(allocator: Allocator) Self {
        return .{
            .header = CapsuleHeader{},
            .entries = std.ArrayList(CapsuleEntry).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.name);
            self.allocator.free(entry.value);
        }
        self.entries.deinit();
    }

    pub fn addEntry(self: *Self, namespace: u16, type: u16, name: []const u8, value: []const u8) !void {
        var entry = CapsuleEntry{
            .namespace = namespace,
            .type = type,
            .flags = 0,
            .name_length = @as(u16, @intCast(name.len)),
            .value_length = @as(u32, @intCast(value.len)),
            .name = try self.allocator.dupe(u8, name),
            .value = try self.allocator.dupe(u8, value),
            .crc32c = 0,
        };
        entry.crc32c = try entry.calculateCrc32c(self.allocator);
        try self.entries.append(entry);
        self.header.entry_count = @as(u32, @intCast(self.entries.items.len));
        self.recalculateSize();
    }

    pub fn getEntry(self: *Self, namespace: u16, type: u16, name: []const u8) ?*CapsuleEntry {
        for (self.entries.items) |*entry| {
            if (entry.namespace == namespace and entry.type == type and std.mem.eql(u8, entry.name, name)) {
                return entry;
            }
        }
        return null;
    }

    pub fn removeEntry(self: *Self, namespace: u16, type: u16, name: []const u8) !bool {
        for (self.entries.items, 0..) |entry, i| {
            if (entry.namespace == namespace and entry.type == type and std.mem.eql(u8, entry.name, name)) {
                self.allocator.free(entry.name);
                self.allocator.free(entry.value);
                try self.entries.orderedRemove(i);
                self.header.entry_count = @as(u32, @intCast(self.entries.items.len));
                self.recalculateSize();
                return true;
            }
        }
        return false;
    }

    fn recalculateSize(self: *Self) void {
        var size: u32 = CapsuleHeader.SIZE;
        for (self.entries.items) |entry| {
            size += 12 + entry.name_length + entry.value_length + 4; // entry header + name + value + crc
        }
        self.header.size = size;
    }

    pub fn serialize(self: *Self, writer: *serialization.Writer(void)) !void {
        // Serialize header (without CRC)
        try writer.writeU32(self.header.magic);
        try writer.writeU16(self.header.version);
        try writer.writeU16(self.header.flags);
        try writer.writeU64(self.header.capsule_id);
        try writer.writeU64(self.header.inode);
        try writer.writeU32(self.header.entry_count);
        try writer.writeU32(self.header.size);

        // Serialize entries
        for (self.entries.items) |entry| {
            try writer.writeU16(entry.namespace);
            try writer.writeU16(entry.type);
            try writer.writeU16(entry.flags);
            try writer.writeU16(entry.name_length);
            try writer.writeU32(entry.value_length);
            try writer.writeBytes(entry.name);
            try writer.writeBytes(entry.value);
            try writer.writeU32(entry.crc32c);
        }

        // Calculate and write CRC32C of everything
        const data = writer.bytes();
        const crc = utils.crc32c(data);
        try writer.writeU32(crc);
    }

    pub fn deserialize(reader: *serialization.Reader(void), allocator: Allocator) !MetadataCapsule {
        const header = try CapsuleHeader.deserialize(reader, allocator);

        var capsule = MetadataCapsule.init(allocator);
        capsule.header = header;

        for (0..header.entry_count) |_| {
            const entry = try CapsuleEntry.deserialize(reader, allocator);
            try capsule.entries.append(entry);
        }

        // Verify CRC32C
        const start_offset = reader.offset - (header.size - 4);
        const data = reader.data[start_offset..reader.offset-4];
        const actual_crc = utils.crc32c(data);
        if (actual_crc != header.crc32c) return MetadataError.CrcMismatch;

        return capsule;
    }

    pub fn clone(self: *Self, allocator: Allocator) !MetadataCapsule {
        var copy = MetadataCapsule.init(allocator);
        copy.header = self.header;
        copy.header.capsule_id = utils.generateUuidv7(); // New ID for copy
        copy.recalculateSize();

        for (self.entries.items) |entry| {
            var new_entry = CapsuleEntry{
                .namespace = entry.namespace,
                .type = entry.type,
                .flags = entry.flags,
                .name_length = entry.name_length,
                .value_length = entry.value_length,
                .name = try allocator.dupe(u8, entry.name),
                .value = try allocator.dupe(u8, entry.value),
                .crc32c = entry.crc32c,
            };
            try copy.entries.append(new_entry);
        }
        return copy;
    }
};

// Namespace registry for standard namespaces
pub const NamespaceRegistry = struct {
    const StandardNamespace = struct {
        id: u16,
        name: []const u8,
        description: []const u8,
    };

    const namespaces = [_]StandardNamespace{
        .{ .id = 0x0001, .name = "POSIX_BASE", .description = "POSIX mode, uid, gid, timestamps, link_count" },
        .{ .id = 0x0002, .name = "POSIX_ACL", .description = "NFSv4 ACL" },
        .{ .id = 0x0003, .name = "POSIX_XATTR", .description = "Extended attributes (user.*, trusted.*, security.*, system.*)" },
        .{ .id = 0x0004, .name = "POSIX_CAPS", .description = "File capabilities" },
        .{ .id = 0x0010, .name = "WINDOWS_SD", .description = "Security Descriptor (SDDL binary)" },
        .{ .id = 0x0011, .name = "WINDOWS_ADS", .description = "Alternate Data Streams" },
        .{ .id = 0x0012, .name = "WINDOWS_REPARSE", .description = "Reparse points" },
        .{ .id = 0x0013, .name = "WINDOWS_EFS", .description = "EFS encryption" },
        .{ .id = 0x0014, .name = "WINDOWS_USN", .description = "USN Journal" },
        .{ .id = 0x0015, .name = "WINDOWS_OBJID", .description = "Object ID" },
        .{ .id = 0x0016, .name = "WINDOWS_ATTRS", .description = "FILE_ATTRIBUTE_*" },
        .{ .id = 0x0020, .name = "MACOS_XATTR", .description = "com.apple.* extended attributes" },
        .{ .id = 0x0021, .name = "MACOS_FINDER", .description = "Finder metadata (tags, labels, comments)" },
        .{ .id = 0x0022, .name = "MACOS_RESOURCE", .description = "Resource fork" },
        .{ .id = 0x0023, .name = "MACOS_QUARANTINE", .description = "Quarantine attributes" },
        .{ .id = 0x0024, .name = "MACOS_FIRMLINK", .description = "Firmlink" },
        .{ .id = 0x0025, .name = "MACOS_TIMESTAMP", .description = "Creation time" },
        .{ .id = 0x8000, .name = "UFS_INTERNAL", .description = "Compression, checksums, extent refs" },
        .{ .id = 0xFFFF, .name = "OPAQUE", .description = "Unknown/opaque metadata" },
    };

    pub fn getName(id: u16) ?[]const u8 {
        for (namespaces) |ns| {
            if (ns.id == id) return ns.name;
        }
        return null;
    }

    pub fn getDescription(id: u16) ?[]const u8 {
        for (namespaces) |ns| {
            if (ns.id == id) return ns.description;
        }
        return null;
    }

    pub fn isStandard(id: u16) bool {
        for (namespaces) |ns| {
            if (ns.id == id) return true;
        }
        return false;
    }
};

// POSIX_BASE namespace types
pub const PosixBaseType = enum(u16) {
    mode_uid_gid = 0x0001,
    timestamps = 0x0002,
    link_count = 0x0003,
};

// WINDOWS_SD namespace types
pub const WindowsSdType = enum(u16) {
    security_descriptor = 0x0001,
};

// WINDOWS_ADS namespace types
pub const WindowsAdsType = enum(u16) {
    stream = 0x0001, // name = stream name, value = extent reference
};

// MACOS_XATTR namespace types
pub const MacosXattrType = enum(u16) {
    generic = 0x0001,
};

// UFS_INTERNAL namespace types
pub const UfsInternalType = enum(u16) {
    compression_info = 0x0001,
    extent_checksums = 0x0002,
    encryption_info = 0x0003,
    snapshot_ref = 0x0004,
};

// Capsule translation framework (stub for cross-platform translation)
pub const CapsuleTranslator = struct {
    pub fn translate(
        capsule: *MetadataCapsule,
        from_os: TargetOS,
        to_os: TargetOS,
        allocator: Allocator,
    ) !MetadataCapsule {
        // This is a stub - full implementation in Milestone 3 Week 2-3
        // For now, just clone
        return capsule.clone(allocator);
    }
};

pub const TargetOS = enum {
    linux,
    windows,
    macos,
    uefi,
    unknown,
};

// Helper: Create POSIX_BASE capsule from inode metadata
pub fn createPosixBaseCapsule(
    allocator: Allocator,
    inode: u64,
    mode: u32,
    uid: u32,
    gid: u32,
    atime: u64,
    mtime: u64,
    ctime: u64,
    crtime: u64,
    link_count: u32,
) !MetadataCapsule {
    var capsule = MetadataCapsule.init(allocator);
    capsule.header.capsule_id = utils.generateUuidv7();
    capsule.header.inode = inode;

    // mode, uid, gid
    var buf: [12]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], mode, serialization.Endianness);
    std.mem.writeInt(u32, buf[4..8], uid, serialization.Endianness);
    std.mem.writeInt(u32, buf[8..12], gid, serialization.Endianness);
    try capsule.addEntry(0x0001, 0x0001, "mode_uid_gid", &buf);

    // timestamps
    var ts_buf: [32]u8 = undefined;
    std.mem.writeInt(u64, ts_buf[0..8], atime, serialization.Endianness);
    std.mem.writeInt(u64, ts_buf[8..16], mtime, serialization.Endianness);
    std.mem.writeInt(u64, ts_buf[16..24], ctime, serialization.Endianness);
    std.mem.writeInt(u64, ts_buf[24..32], crtime, serialization.Endianness);
    try capsule.addEntry(0x0001, 0x0002, "timestamps", &ts_buf);

    // link_count
    var lc_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &lc_buf, link_count, serialization.Endianness);
    try capsule.addEntry(0x0001, 0x0003, "link_count", &lc_buf);

    return capsule;
}

// Helper: Parse POSIX_BASE capsule
pub fn parsePosixBaseCapsule(capsule: *MetadataCapsule) !struct {
    mode: u32,
    uid: u32,
    gid: u32,
    atime: u64,
    mtime: u64,
    ctime: u64,
    crtime: u64,
    link_count: u32,
} {
    const entry1 = capsule.getEntry(0x0001, 0x0001, "mode_uid_gid") orelse return MetadataError.NotFound;
    const entry2 = capsule.getEntry(0x0001, 0x0002, "timestamps") orelse return MetadataError.NotFound;
    const entry3 = capsule.getEntry(0x0001, 0x0003, "link_count") orelse return MetadataError.NotFound;

    if (entry1.value.len != 12 or entry2.value.len != 32 or entry3.value.len != 4) {
        return MetadataError.InvalidFormat;
    }

    return .{
        .mode = std.mem.readInt(u32, entry1.value[0..4], serialization.Endianness),
        .uid = std.mem.readInt(u32, entry1.value[4..8], serialization.Endianness),
        .gid = std.mem.readInt(u32, entry1.value[8..12], serialization.Endianness),
        .atime = std.mem.readInt(u64, entry2.value[0..8], serialization.Endianness),
        .mtime = std.mem.readInt(u64, entry2.value[8..16], serialization.Endianness),
        .ctime = std.mem.readInt(u64, entry2.value[16..24], serialization.Endianness),
        .crtime = std.mem.readInt(u64, entry2.value[24..32], serialization.Endianness),
        .link_count = std.mem.readInt(u32, entry3.value, serialization.Endianness),
    };
}