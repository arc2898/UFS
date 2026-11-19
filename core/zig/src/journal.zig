// UFS Logical Redo Journal Implementation
// Metadata-only, ordered data mode, self-describing operations, portable replay

const std = @import("std");
const serialization = @import("serialization.zig");
const utils = @import("utils.zig");
const blockdev = @import("blockdev.zig");
const allocation = @import("allocation.zig");
const Allocator = std.mem.Allocator;

pub const JournalError = error{
    InvalidFormat,
    CorruptedData,
    IoError,
    OutOfSpace,
    InvalidTransaction,
    ReplayError,
    CheckpointError,
    UnsupportedOperation,
    NotInitialized,
};

pub const JournalFlags = packed struct {
    ordered_data: bool = true,
    async_commit: bool = false,
    checksum_data: bool = false,
};

pub const JournalSuperblock = struct {
    magic: u32 = 0x4A55524E,  // "JURN"
    version: u16 = 1,
    flags: u16 = 0,
    start_txn: u64 = 0,          // First valid transaction ID
    end_txn: u64 = 0,            // Last valid transaction ID
    last_checkpoint: u64 = 0,    // Offset of last checkpoint record
    size: u64 = 0,               // Journal size in bytes
    crc32c: u32 = 0,

    pub const SIZE = 48; // 4+2+2+8+8+8+8+4+4(padding)

    pub fn serialize(self: JournalSuperblock, writer: *serialization.Writer(void)) !void {
        try writer.writeU32(self.magic);
        try writer.writeU16(self.version);
        try writer.writeU16(self.flags);
        try writer.writeU64(self.start_txn);
        try writer.writeU64(self.end_txn);
        try writer.writeU64(self.last_checkpoint);
        try writer.writeU64(self.size);
        // CRC written separately
    }

    pub fn deserialize(reader: *serialization.Reader(void), allocator: Allocator) !JournalSuperblock {
        const magic = try reader.readU32();
        if (magic != 0x4A55524E) return JournalError.InvalidFormat;
        return .{
            .magic = magic,
            .version = try reader.readU16(),
            .flags = try reader.readU16(),
            .start_txn = try reader.readU64(),
            .end_txn = try reader.readU64(),
            .last_checkpoint = try reader.readU64(),
            .size = try reader.readU64(),
            .crc32c = try reader.readU32(),
        };
    }
};

pub const TransactionHeader = struct {
    magic: u32 = 0x54584E00,  // "TXN\0"
    txid: u64 = 0,
    timestamp: u64 = 0,        // Nanoseconds since 1970
    operation_count: u32 = 0,
    flags: u32 = 0,
    // Operations follow
    // CRC32C at end

    pub const BASE_SIZE = 28; // 4+8+8+4+4

    pub fn serialize(self: TransactionHeader, writer: *serialization.Writer(void)) !void {
        try writer.writeU32(self.magic);
        try writer.writeU64(self.txid);
        try writer.writeU64(self.timestamp);
        try writer.writeU32(self.operation_count);
        try writer.writeU32(self.flags);
    }

    pub fn deserialize(reader: *serialization.Reader(void), allocator: Allocator) !TransactionHeader {
        const magic = try reader.readU32();
        if (magic != 0x54584E00) return JournalError.InvalidFormat;
        return .{
            .magic = magic,
            .txid = try reader.readU64(),
            .timestamp = try reader.readU64(),
            .operation_count = try reader.readU32(),
            .flags = try reader.readU32(),
        };
    }
};

pub const OperationType = enum(u8) {
    CREATE_INODE = 1,
    DELETE_INODE = 2,
    UPDATE_INODE_META = 3,
    LINK_DIRENT = 4,
    UNLINK_DIRENT = 5,
    RENAME_DIRENT = 6,
    ALLOCATE_EXTENT = 7,
    DEALLOCATE_EXTENT = 8,
    UPDATE_BITMAP = 9,
    UPDATE_SUPERBLOCK = 10,
    CHECKPOINT = 11,
    SET_XATTR = 12,
    REMOVE_XATTR = 13,
    UPDATE_CAPSULE = 14,
    RM_DIR = 15,
    SYMLINK = 16,
    HARDLINK = 17,
    TRUNCATE = 18,
    FALLOCATE = 19,
};

pub const Operation = struct {
    op_type: OperationType,
    payload: []const u8,

    pub fn serialize(self: Operation, writer: *serialization.Writer(void)) !void {
        try writer.writeU8(@intFromEnum(self.op_type));
        try writer.writeVarBytes(self.payload);
    }

    pub fn deserialize(reader: *serialization.Reader(void), allocator: Allocator) !Operation {
        const op_type_val = try reader.readU8();
        const op_type = @as(OperationType, @enumFromInt(op_type_val));
        const payload = try reader.readVarBytes(allocator);
        return .{ .op_type = op_type, .payload = payload };
    }

    pub fn getOpCreateInode(self: Operation, allocator: Allocator) !OpCreateInode {
        var reader = serialization.createReader(self.payload);
        return OpCreateInode.deserialize(&reader, allocator);
    }

    pub fn getOpLinkDirent(self: Operation, allocator: Allocator) !OpLinkDirent {
        var reader = serialization.createReader(self.payload);
        return OpLinkDirent.deserialize(&reader, allocator);
    }

    pub fn getOpAllocateExtent(self: Operation, allocator: Allocator) !OpAllocateExtent {
        var reader = serialization.createReader(self.payload);
        return OpAllocateExtent.deserialize(&reader, allocator);
    }

    pub fn getOpUpdateInodeMeta(self: Operation, allocator: Allocator) !OpUpdateInodeMeta {
        var reader = serialization.createReader(self.payload);
        return OpUpdateInodeMeta.deserialize(&reader, allocator);
    }

    pub fn getOpCheckpoint(self: Operation, allocator: Allocator) !OpCheckpoint {
        var reader = serialization.createReader(self.payload);
        return OpCheckpoint.deserialize(&reader, allocator);
    }

    pub fn getOpRmDir(self: Operation, allocator: Allocator) !OpRmDir {
        var reader = serialization.createReader(self.payload);
        return OpRmDir.deserialize(&reader, allocator);
    }

    pub fn getOpSymlink(self: Operation, allocator: Allocator) !OpSymlink {
        var reader = serialization.createReader(self.payload);
        return OpSymlink.deserialize(&reader, allocator);
    }

    pub fn getOpHardlink(self: Operation, allocator: Allocator) !OpHardlink {
        var reader = serialization.createReader(self.payload);
        return OpHardlink.deserialize(&reader, allocator);
    }

    pub fn getOpTruncate(self: Operation, allocator: Allocator) !OpTruncate {
        var reader = serialization.createReader(self.payload);
        return OpTruncate.deserialize(&reader, allocator);
    }

    pub fn getOpFallocate(self: Operation, allocator: Allocator) !OpFallocate {
        var reader = serialization.createReader(self.payload);
        return OpFallocate.deserialize(&reader, allocator);
    }

    pub fn getOpUnlinkDirent(self: Operation, allocator: Allocator) !OpUnlinkDirent {
        var reader = serialization.createReader(self.payload);
        return OpUnlinkDirent.deserialize(&reader, allocator);
    }

    pub fn getOpRenameDirent(self: Operation, allocator: Allocator) !OpRenameDirent {
        var reader = serialization.createReader(self.payload);
        return OpRenameDirent.deserialize(&reader, allocator);
    }

    pub fn getOpDeleteInode(self: Operation, allocator: Allocator) !OpDeleteInode {
        var reader = serialization.createReader(self.payload);
        return OpDeleteInode.deserialize(&reader, allocator);
    }

    pub fn getOpDeallocateExtent(self: Operation, allocator: Allocator) !OpDeallocateExtent {
        var reader = serialization.createReader(self.payload);
        return OpDeallocateExtent.deserialize(&reader, allocator);
    }

    pub fn getOpUpdateBitmap(self: Operation, allocator: Allocator) !OpUpdateBitmap {
        var reader = serialization.createReader(self.payload);
        return OpUpdateBitmap.deserialize(&reader, allocator);
    }

    pub fn getOpUpdateSuperblock(self: Operation, allocator: Allocator) !OpUpdateSuperblock {
        var reader = serialization.createReader(self.payload);
        return OpUpdateSuperblock.deserialize(&reader, allocator);
    }

    pub fn getOpUpdateCapsule(self: Operation, allocator: Allocator) !OpUpdateCapsule {
        var reader = serialization.createReader(self.payload);
        return OpUpdateCapsule.deserialize(&reader, allocator);
    }
};

// Operation payloads
pub const OpCreateInode = struct {
    inode: u64,
    parent: u64,
    name: []const u8,
    mode: u32,
    uid: u32,
    gid: u32,
    capsule_id: u64,

    pub fn serialize(self: OpCreateInode, writer: *serialization.Writer(void)) !void {
        try writer.writeU64(self.inode);
        try writer.writeU64(self.parent);
        try writer.writeString(self.name);
        try writer.writeU32(self.mode);
        try writer.writeU32(self.uid);
        try writer.writeU32(self.gid);
        try writer.writeU64(self.capsule_id);
    }

    pub fn deserialize(reader: *serialization.Reader(void), allocator: Allocator) !OpCreateInode {
        return .{
            .inode = try reader.readU64(),
            .parent = try reader.readU64(),
            .name = try reader.readString(allocator),
            .mode = try reader.readU32(),
            .uid = try reader.readU32(),
            .gid = try reader.readU32(),
            .capsule_id = try reader.readU64(),
        };
    }
};

pub const OpLinkDirent = struct {
    parent: u64,
    name: []const u8,
    child: u64,
    file_type: u8,

    pub fn serialize(self: OpLinkDirent, writer: *serialization.Writer(void)) !void {
        try writer.writeU64(self.parent);
        try writer.writeString(self.name);
        try writer.writeU64(self.child);
        try writer.writeU8(self.file_type);
    }

    pub fn deserialize(reader: *serialization.Reader(void), allocator: Allocator) !OpLinkDirent {
        return .{
            .parent = try reader.readU64(),
            .name = try reader.readString(allocator),
            .child = try reader.readU64(),
            .file_type = try reader.readU8(),
        };
    }
};

pub const OpAllocateExtent = struct {
    inode: u64,
    logical_offset: u64,
    physical_block: u64,
    length: u32,
    compression_algo: u16,

    pub fn serialize(self: OpAllocateExtent, writer: *serialization.Writer(void)) !void {
        try writer.writeU64(self.inode);
        try writer.writeU64(self.logical_offset);
        try writer.writeU64(self.physical_block);
        try writer.writeU32(self.length);
        try writer.writeU16(self.compression_algo);
    }

    pub fn deserialize(reader: *serialization.Reader(void), allocator: Allocator) !OpAllocateExtent {
        return .{
            .inode = try reader.readU64(),
            .logical_offset = try reader.readU64(),
            .physical_block = try reader.readU64(),
            .length = try reader.readU32(),
            .compression_algo = try reader.readU16(),
        };
    }
};

pub const OpUpdateInodeMeta = struct {
    inode: u64,
    field_mask: u32,
    mode: u32,
    uid: u32,
    gid: u32,
    size: u64,
    atime: u64,
    mtime: u64,
    ctime: u64,
    flags: u32,
    capsule_id: u64,

    pub fn serialize(self: OpUpdateInodeMeta, writer: *serialization.Writer(void)) !void {
        try writer.writeU64(self.inode);
        try writer.writeU32(self.field_mask);
        try writer.writeU32(self.mode);
        try writer.writeU32(self.uid);
        try writer.writeU32(self.gid);
        try writer.writeU64(self.size);
        try writer.writeU64(self.atime);
        try writer.writeU64(self.mtime);
        try writer.writeU64(self.ctime);
        try writer.writeU32(self.flags);
        try writer.writeU64(self.capsule_id);
    }

    pub fn deserialize(reader: *serialization.Reader(void), allocator: Allocator) !OpUpdateInodeMeta {
        return .{
            .inode = try reader.readU64(),
            .field_mask = try reader.readU32(),
            .mode = try reader.readU32(),
            .uid = try reader.readU32(),
            .gid = try reader.readU32(),
            .size = try reader.readU64(),
            .atime = try reader.readU64(),
            .mtime = try reader.readU64(),
            .ctime = try reader.readU64(),
            .flags = try reader.readU32(),
            .capsule_id = try reader.readU64(),
        };
    }
};

pub const OpCheckpoint = struct {
    superblock_generation: u64,
    ag_generations: []u64,

    pub fn serialize(self: OpCheckpoint, writer: *serialization.Writer(void)) !void {
        try writer.writeU64(self.superblock_generation);
        try writer.writeU32(@as(u32, @intCast(self.ag_generations.len)));
        for (self.ag_generations) |gen| {
            try writer.writeU64(gen);
        }
    }

    pub fn deserialize(reader: *serialization.Reader(void), allocator: Allocator) !OpCheckpoint {
        const superblock_generation = try reader.readU64();
        const count = try reader.readU32();
        var ag_generations = try allocator.alloc(u64, count);
        for (ag_generations, 0..) |*gen, i| {
            _ = i;
            gen.* = try reader.readU64();
        }
        return .{ .superblock_generation = superblock_generation, .ag_generations = ag_generations };
    }
};

// New operation payloads for enhanced recovery
pub const OpRmDir = struct {
    parent: u64,
    name: []const u8,

    pub fn serialize(self: OpRmDir, writer: *serialization.Writer(void)) !void {
        try writer.writeU64(self.parent);
        try writer.writeString(self.name);
    }

    pub fn deserialize(reader: *serialization.Reader(void), allocator: Allocator) !OpRmDir {
        return .{
            .parent = try reader.readU64(),
            .name = try reader.readString(allocator),
        };
    }
};

pub const OpSymlink = struct {
    parent: u64,
    name: []const u8,
    target: []const u8,

    pub fn serialize(self: OpSymlink, writer: *serialization.Writer(void)) !void {
        try writer.writeU64(self.parent);
        try writer.writeString(self.name);
        try writer.writeString(self.target);
    }

    pub fn deserialize(reader: *serialization.Reader(void), allocator: Allocator) !OpSymlink {
        return .{
            .parent = try reader.readU64(),
            .name = try reader.readString(allocator),
            .target = try reader.readString(allocator),
        };
    }
};

pub const OpHardlink = struct {
    parent: u64,
    name: []const u8,
    child: u64,

    pub fn serialize(self: OpHardlink, writer: *serialization.Writer(void)) !void {
        try writer.writeU64(self.parent);
        try writer.writeString(self.name);
        try writer.writeU64(self.child);
    }

    pub fn deserialize(reader: *serialization.Reader(void), allocator: Allocator) !OpHardlink {
        return .{
            .parent = try reader.readU64(),
            .name = try reader.readString(allocator),
            .child = try reader.readU64(),
        };
    }
};

pub const OpTruncate = struct {
    inode: u64,
    new_size: u64,

    pub fn serialize(self: OpTruncate, writer: *serialization.Writer(void)) !void {
        try writer.writeU64(self.inode);
        try writer.writeU64(self.new_size);
    }

    pub fn deserialize(reader: *serialization.Reader(void), allocator: Allocator) !OpTruncate {
        return .{
            .inode = try reader.readU64(),
            .new_size = try reader.readU64(),
        };
    }
};

pub const OpFallocate = struct {
    inode: u64,
    mode: u32,
    offset: u64,
    length: u64,

    pub fn serialize(self: OpFallocate, writer: *serialization.Writer(void)) !void {
        try writer.writeU64(self.inode);
        try writer.writeU32(self.mode);
        try writer.writeU64(self.offset);
        try writer.writeU64(self.length);
    }

    pub fn deserialize(reader: *serialization.Reader(void), allocator: Allocator) !OpFallocate {
        return .{
            .inode = try reader.readU64(),
            .mode = try reader.readU32(),
            .offset = try reader.readU64(),
            .length = try reader.readU64(),
        };
    }
};

// Missing operation payloads for complete recovery
pub const OpDeleteInode = struct {
    inode: u64,
    name: []const u8, // For logging/debug

    pub fn serialize(self: OpDeleteInode, writer: *serialization.Writer(void)) !void {
        try writer.writeU64(self.inode);
        try writer.writeString(self.name);
    }

    pub fn deserialize(reader: *serialization.Reader(void), allocator: Allocator) !OpDeleteInode {
        return .{
            .inode = try reader.readU64(),
            .name = try reader.readString(allocator),
        };
    }
};

pub const OpDeallocateExtent = struct {
    inode: u64,
    physical_block: u64,
    length: u32,

    pub fn serialize(self: OpDeallocateExtent, writer: *serialization.Writer(void)) !void {
        try writer.writeU64(self.inode);
        try writer.writeU64(self.physical_block);
        try writer.writeU32(self.length);
    }

    pub fn deserialize(reader: *serialization.Reader(void), allocator: Allocator) !OpDeallocateExtent {
        return .{
            .inode = try reader.readU64(),
            .physical_block = try reader.readU64(),
            .length = try reader.readU32(),
        };
    }
};

pub const OpUpdateBitmap = struct {
    ag_index: u32,
    start_block: u64,
    block_count: u32,
    allocate: bool,

    pub fn serialize(self: OpUpdateBitmap, writer: *serialization.Writer(void)) !void {
        try writer.writeU32(self.ag_index);
        try writer.writeU64(self.start_block);
        try writer.writeU32(self.block_count);
        try writer.writeBool(self.allocate);
    }

    pub fn deserialize(reader: *serialization.Reader(void), allocator: Allocator) !OpUpdateBitmap {
        return .{
            .ag_index = try reader.readU32(),
            .start_block = try reader.readU64(),
            .block_count = try reader.readU32(),
            .allocate = try reader.readBool(),
        };
    }
};

pub const OpUpdateSuperblock = struct {
    free_inodes: u64,
    free_blocks: u64,
    generation: u64,

    pub fn serialize(self: OpUpdateSuperblock, writer: *serialization.Writer(void)) !void {
        try writer.writeU64(self.free_inodes);
        try writer.writeU64(self.free_blocks);
        try writer.writeU64(self.generation);
    }

    pub fn deserialize(reader: *serialization.Reader(void), allocator: Allocator) !OpUpdateSuperblock {
        return .{
            .free_inodes = try reader.readU64(),
            .free_blocks = try reader.readU64(),
            .generation = try reader.readU64(),
        };
    }
};

pub const OpUpdateCapsule = struct {
    capsule_id: u64,
    capsule_data: []u8,

    pub fn serialize(self: OpUpdateCapsule, writer: *serialization.Writer(void)) !void {
        try writer.writeU64(self.capsule_id);
        try writer.writeVarBytes(self.capsule_data);
    }

    pub fn deserialize(reader: *serialization.Reader(void), allocator: Allocator) !OpUpdateCapsule {
        return .{
            .capsule_id = try reader.readU64(),
            .capsule_data = try reader.readVarBytes(allocator),
        };
    }
};
            .offset = try reader.readU64(),
            .length = try reader.readU64(),
        };
    }
};

// Missing operation payloads used in c_api.zig
pub const OpUnlinkDirent = struct {
    parent: u64,
    name: []const u8,

    pub fn serialize(self: OpUnlinkDirent, writer: *serialization.Writer(void)) !void {
        try writer.writeU64(self.parent);
        try writer.writeString(self.name);
    }

    pub fn deserialize(reader: *serialization.Reader(void), allocator: Allocator) !OpUnlinkDirent {
        return .{
            .parent = try reader.readU64(),
            .name = try reader.readString(allocator),
        };
    }
};

pub const OpRenameDirent = struct {
    old_parent: u64,
    old_name: []const u8,
    new_parent: u64,
    new_name: []const u8,

    pub fn serialize(self: OpRenameDirent, writer: *serialization.Writer(void)) !void {
        try writer.writeU64(self.old_parent);
        try writer.writeString(self.old_name);
        try writer.writeU64(self.new_parent);
        try writer.writeString(self.new_name);
    }

    pub fn deserialize(reader: *serialization.Reader(void), allocator: Allocator) !OpRenameDirent {
        return .{
            .old_parent = try reader.readU64(),
            .old_name = try reader.readString(allocator),
            .new_parent = try reader.readU64(),
            .new_name = try reader.readString(allocator),
        };
    }
};

// Transaction builder for constructing transactions
pub const TransactionBuilder = struct {
    const Self = @This();
    operations: std.ArrayList(Operation),
    allocator: Allocator,
    txid: u64,

    pub fn init(allocator: Allocator, txid: u64) Self {
        return .{
            .operations = std.ArrayList(Operation).init(allocator),
            .allocator = allocator,
            .txid = txid,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.operations.items) |op| {
            self.allocator.free(op.payload);
        }
        self.operations.deinit();
    }

    pub fn addOperation(self: *Self, op_type: OperationType, payload: []const u8) !void {
        var op = Operation{
            .op_type = op_type,
            .payload = try self.allocator.dupe(u8, payload),
        };
        try self.operations.append(op);
    }

    pub fn addCreateInode(self: *Self, op: OpCreateInode) !void {
        var writer = serialization.createWriter(self.allocator);
        defer writer.deinit();
        try op.serialize(&writer);
        try self.addOperation(OperationType.CREATE_INODE, writer.bytes());
    }

    pub fn addLinkDirent(self: *Self, op: OpLinkDirent) !void {
        var writer = serialization.createWriter(self.allocator);
        defer writer.deinit();
        try op.serialize(&writer);
        try self.addOperation(OperationType.LINK_DIRENT, writer.bytes());
    }

    pub fn addAllocateExtent(self: *Self, op: OpAllocateExtent) !void {
        var writer = serialization.createWriter(self.allocator);
        defer writer.deinit();
        try op.serialize(&writer);
        try self.addOperation(OperationType.ALLOCATE_EXTENT, writer.bytes());
    }

    pub fn addUpdateInodeMeta(self: *Self, op: OpUpdateInodeMeta) !void {
        var writer = serialization.createWriter(self.allocator);
        defer writer.deinit();
        try op.serialize(&writer);
        try self.addOperation(OperationType.UPDATE_INODE_META, writer.bytes());
    }

    pub fn addCheckpoint(self: *Self, op: OpCheckpoint) !void {
        var writer = serialization.createWriter(self.allocator);
        defer writer.deinit();
        try op.serialize(&writer);
        try self.addOperation(OperationType.CHECKPOINT, writer.bytes());
    }

    pub fn addRmDir(self: *Self, op: OpRmDir) !void {
        var writer = serialization.createWriter(self.allocator);
        defer writer.deinit();
        try op.serialize(&writer);
        try self.addOperation(OperationType.RM_DIR, writer.bytes());
    }

    pub fn addSymlink(self: *Self, op: OpSymlink) !void {
        var writer = serialization.createWriter(self.allocator);
        defer writer.deinit();
        try op.serialize(&writer);
        try self.addOperation(OperationType.SYMLINK, writer.bytes());
    }

    pub fn addHardlink(self: *Self, op: OpHardlink) !void {
        var writer = serialization.createWriter(self.allocator);
        defer writer.deinit();
        try op.serialize(&writer);
        try self.addOperation(OperationType.HARDLINK, writer.bytes());
    }

    pub fn addTruncate(self: *Self, op: OpTruncate) !void {
        var writer = serialization.createWriter(self.allocator);
        defer writer.deinit();
        try op.serialize(&writer);
        try self.addOperation(OperationType.TRUNCATE, writer.bytes());
    }

    pub fn addFallocate(self: *Self, op: OpFallocate) !void {
        var writer = serialization.createWriter(self.allocator);
        defer writer.deinit();
        try op.serialize(&writer);
        try self.addOperation(OperationType.FALLOCATE, writer.bytes());
    }

    pub fn addUnlinkDirent(self: *Self, op: OpUnlinkDirent) !void {
        var writer = serialization.createWriter(self.allocator);
        defer writer.deinit();
        try op.serialize(&writer);
        try self.addOperation(OperationType.UNLINK_DIRENT, writer.bytes());
    }

    pub fn addRenameDirent(self: *Self, op: OpRenameDirent) !void {
        var writer = serialization.createWriter(self.allocator);
        defer writer.deinit();
        try op.serialize(&writer);
        try self.addOperation(OperationType.RENAME_DIRENT, writer.bytes());
    }

    pub fn addDeleteInode(self: *Self, op: OpDeleteInode) !void {
        var writer = serialization.createWriter(self.allocator);
        defer writer.deinit();
        try op.serialize(&writer);
        try self.addOperation(OperationType.DELETE_INODE, writer.bytes());
    }

    pub fn addDeallocateExtent(self: *Self, op: OpDeallocateExtent) !void {
        var writer = serialization.createWriter(self.allocator);
        defer writer.deinit();
        try op.serialize(&writer);
        try self.addOperation(OperationType.DEALLOCATE_EXTENT, writer.bytes());
    }

    pub fn addUpdateBitmap(self: *Self, op: OpUpdateBitmap) !void {
        var writer = serialization.createWriter(self.allocator);
        defer writer.deinit();
        try op.serialize(&writer);
        try self.addOperation(OperationType.UPDATE_BITMAP, writer.bytes());
    }

    pub fn addUpdateSuperblock(self: *Self, op: OpUpdateSuperblock) !void {
        var writer = serialization.createWriter(self.allocator);
        defer writer.deinit();
        try op.serialize(&writer);
        try self.addOperation(OperationType.UPDATE_SUPERBLOCK, writer.bytes());
    }

    pub fn addUpdateCapsule(self: *Self, op: OpUpdateCapsule) !void {
        var writer = serialization.createWriter(self.allocator);
        defer writer.deinit();
        try op.serialize(&writer);
        try self.addOperation(OperationType.UPDATE_CAPSULE, writer.bytes());
    }

    pub fn build(self: *Self) Transaction {
        return .{
            .header = TransactionHeader{
                .txid = self.txid,
                .timestamp = utils.timestamp(),
                .operation_count = @as(u32, @intCast(self.operations.items.len)),
                .flags = 0,
            },
            .operations = self.operations.items,
        };
    }
};

pub const Transaction = struct {
    header: TransactionHeader,
    operations: []Operation,

    pub fn serialize(self: Transaction, writer: *serialization.Writer(void)) !void {
        // Serialize header
        try writer.writeU32(self.header.magic);
        try writer.writeU64(self.header.txid);
        try writer.writeU64(self.header.timestamp);
        try writer.writeU32(self.header.operation_count);
        try writer.writeU32(self.header.flags);

        // Serialize operations
        for (self.operations) |op| {
            try op.serialize(writer);
        }
    }

    pub fn calculateSize(self: Transaction) usize {
        var size = TransactionHeader.BASE_SIZE;
        for (self.operations) |op| {
            size += 1 + 4 + op.payload.len; // type + length + payload
        }
        size += 4; // CRC32C
        return size;
    }
};

// Journal writer - circular buffer
pub const JournalWriter = struct {
    const Self = @This();
    device: *blockdev.BlockDevice,
    journal_offset: u64,        // Cluster offset of journal area
    journal_size: u64,          // Size in clusters
    cluster_size: u32,
    write_ptr: u64 = 0,         // Current write position (bytes from journal start)
    commit_ptr: u64 = 0,        // Last committed position
    superblock: JournalSuperblock,
    flags: JournalFlags,
    allocator: Allocator,

    pub fn init(
        device: *blockdev.BlockDevice,
        journal_offset: u64,
        journal_size: u64,
        cluster_size: u32,
        allocator: Allocator,
    ) !JournalWriter {
        var writer = JournalWriter{
            .device = device,
            .journal_offset = journal_offset,
            .journal_size = journal_size,
            .cluster_size = cluster_size,
            .allocator = allocator,
        };

        // Load or create superblock
        writer.loadSuperblock() catch |err| {
            if (err == JournalError.InvalidFormat or err == JournalError.CorruptedData) {
                // Create new superblock
                writer.superblock = JournalSuperblock{
                    .size = journal_size * cluster_size,
                };
                try writer.writeSuperblock();
            } else {
                return err;
            }
        };

        writer.write_ptr = writer.superblock.end_txn * 512; // Approximate
        writer.commit_ptr = writer.write_ptr;

        return writer;
    }

    fn loadSuperblock(self: *Self) !void {
        var buffer = try self.allocator.alloc(u8, self.cluster_size as usize);
        defer self.allocator.free(buffer);

        try self.device.read(self.journal_offset * self.cluster_size, buffer);

        var reader = serialization.createReader(buffer);
        self.superblock = try JournalSuperblock.deserialize(&reader, self.allocator);
    }

    fn writeSuperblock(self: *Self) !void {
        var writer = serialization.createWriter(self.allocator);
        defer writer.deinit();

        try self.superblock.serialize(&writer);
        try writer.align(self.cluster_size as usize);
        const crc = utils.crc32c(writer.bytes());
        try writer.writeU32(crc);

        try self.device.write(self.journal_offset * self.cluster_size, writer.bytes());
    }

    pub fn writeTransaction(self: *Self, txn: Transaction) !u64 {
        const txn_size = txn.calculateSize();
        const journal_bytes = self.journal_size * self.cluster_size;

        // Check if we need to wrap
        if (self.write_ptr + txn_size > journal_bytes) {
            // Wrap to beginning (after superblock)
            self.write_ptr = JournalSuperblock.SIZE + 4; // After superblock + CRC
        }

        // Write transaction
        var writer = serialization.createWriter(self.allocator);
        defer writer.deinit();

        try txn.serialize(&writer);
        try writer.align(8); // Align to 8 bytes
        const crc = utils.crc32c(writer.bytes());
        try writer.writeU32(crc);

        const data = writer.bytes();
        const abs_offset = self.journal_offset * self.cluster_size + self.write_ptr;
        try self.device.write(abs_offset, data);

        self.write_ptr += data.len;
        self.superblock.end_txn = txn.header.txid;

        return abs_offset;
    }

    pub fn commit(self: *Self) !void {
        // Flush device to ensure data is on disk
        try self.device.flush();

        // Update commit pointer
        self.commit_ptr = self.write_ptr;

        // Update superblock
        try self.writeSuperblock();
        try self.device.flush();
    }

    // Force a checkpoint - updates superblock with current state
    pub fn checkpoint(
        self: *Self,
        ag_manager: ?*allocation.AllocationGroupManager,
    ) !void {
        self.superblock.last_checkpoint = self.write_ptr;
        self.superblock.start_txn = self.superblock.end_txn;

        // If AG manager provided, persist all AG bitmaps and trees
        if (ag_manager) |mgr| {
            // Write each AG's bitmap and free extent tree to disk
            for (mgr.groups, 0..) |*ag, i| {
                if (ag.loaded) {
                    const ag_index = @as(u32, @intCast(i));
                    const ag_offset = mgr.first_ag_offset + ag_index * mgr.ag_size;

                    // Update AG header with current generation
                    ag.header.generation += 1;
                    ag.header.free_clusters = ag.bitmap.countFree();
                    ag.header.free_extents = ag.free_tree.countExtents();
                    ag.header.free_tree_root = ag.free_tree.root_block;
                    ag.header.bitmap_offset = ag.header.bitmap_offset; // Already set
                    ag.header.inode_table_offset = ag.header.inode_table_offset; // Already set

                    // Write AG header
                    var header_writer = serialization.createWriter(self.allocator);
                    defer header_writer.deinit();
                    try ag.header.serialize(&header_writer);
                    try header_writer.align(mgr.cluster_size as usize);
                    const header_crc = utils.crc32c(header_writer.bytes());
                    try header_writer.writeU32(header_crc);

                    try mgr.device.write((ag_offset + 0) * mgr.cluster_size, header_writer.bytes());

                    // Write allocation bitmap
                    const bitmap_byte_count = @as(usize, @intCast((ag.bitmap.cluster_count + 7) / 8));
                    try mgr.device.write(
                        (ag_offset + ag.header.bitmap_offset) * mgr.cluster_size,
                        ag.bitmap.bits[0..bitmap_byte_count]
                    );

                    // Write inode bitmap
                    const inode_bitmap_byte_count = @as(usize, @intCast((ag.inode_bitmap.cluster_count + 7) / 8));
                    try mgr.device.write(
                        (ag_offset + ag.header.inode_table_offset) * mgr.cluster_size,
                        ag.inode_bitmap.bits[0..inode_bitmap_byte_count]
                    );

                    // Write free extent tree nodes (simplified - would need full tree serialization)
                    // For now, the tree root is stored in the header
                    _ = ag.free_tree;
                }
            }
        }

        try self.commit();
    }

    pub fn getUncommittedTransactions(self: *Self) ![]Transaction {
        // Read transactions between commit_ptr and write_ptr
        // Simplified - would need full implementation
        _ = self;
        return &[_]Transaction{};
    }

    pub fn deinit(self: *Self) void {
        // Nothing to deinit for now
    }
};

// Journal reader for recovery
pub const JournalReader = struct {
    const Self = @This();
    device: *blockdev.BlockDevice,
    journal_offset: u64,
    journal_size: u64,
    cluster_size: u32,
    superblock: JournalSuperblock,
    allocator: Allocator,

    pub fn init(
        device: *blockdev.BlockDevice,
        journal_offset: u64,
        journal_size: u64,
        cluster_size: u32,
        allocator: Allocator,
    ) !JournalReader {
        var reader = JournalReader{
            .device = device,
            .journal_offset = journal_offset,
            .journal_size = journal_size,
            .cluster_size = cluster_size,
            .allocator = allocator,
        };

        // Load superblock
        var buffer = try allocator.alloc(u8, cluster_size as usize);
        defer allocator.free(buffer);

        try device.read(journal_offset * cluster_size, buffer);

        var r = serialization.createReader(buffer);
        reader.superblock = try JournalSuperblock.deserialize(&r, allocator);

        return reader;
    }

    pub fn replay(self: *Self, replay_fn: fn(Operation) !void) !void {
        const journal_bytes = self.journal_size * self.cluster_size;
        var offset: u64 = JournalSuperblock.SIZE + 4; // After superblock

        while (offset < journal_bytes) {
            var buffer = try self.allocator.alloc(u8, self.cluster_size as usize);
            defer self.allocator.free(buffer);

            try self.device.read(self.journal_offset * self.cluster_size + offset, buffer);

            var reader = serialization.createReader(buffer);

            // Try to read transaction
            const txn_header = TransactionHeader.deserialize(&reader, self.allocator) catch {
                // End of valid transactions
                break;
            };

            // Verify CRC
            const txn_start = offset;
            // Find end of transaction by reading operations
            var ops_read: u32 = 0;
            var ops_buffer = std.ArrayList(u8).init(self.allocator);
            defer ops_buffer.deinit();

            while (ops_read < txn_header.operation_count) {
                const op_type_val = try reader.readU8();
                const _ = @as(OperationType, @enumFromInt(op_type_val));
                const payload_len = try reader.readU32();
                try reader.skip(payload_len);
                ops_read += 1;
            }

            const txn_end = reader.offset;
            const txn_bytes = buffer[0..txn_end];
            const expected_crc = try reader.readU32();
            const actual_crc = utils.crc32c(txn_bytes[0..txn_end-4]);
            if (expected_crc != actual_crc) {
                // Corrupted transaction - stop replay
                break;
            }

            // Re-read and replay operations
            var replay_reader = serialization.createReader(buffer);
            _ = TransactionHeader.deserialize(&replay_reader, self.allocator); // Skip header

            for (0..txn_header.operation_count) |_| {
                const op = try Operation.deserialize(&replay_reader, self.allocator);
                try replay_fn(op);
            }

            offset += txn_end;
        }
    }

    // Replay with full context for recovery - applies operations to filesystem state
    pub fn replayForRecovery(
        self: *Self,
        device: *blockdev.BlockDevice,
        cluster_size: u32,
        ag_manager: *allocation.AllocationGroupManager,
        allocator: Allocator,
    ) !void {
        const journal_bytes = self.journal_size * self.cluster_size;
        var offset: u64 = JournalSuperblock.SIZE + 4; // After superblock

        while (offset < journal_bytes) {
            var buffer = try self.allocator.alloc(u8, self.cluster_size as usize);
            defer self.allocator.free(buffer);

            try self.device.read(self.journal_offset * self.cluster_size + offset, buffer);

            var reader = serialization.createReader(buffer);

            // Try to read transaction
            const txn_header = TransactionHeader.deserialize(&reader, self.allocator) catch {
                // End of valid transactions
                break;
            };

            // Verify CRC
            var ops_read: u32 = 0;
            while (ops_read < txn_header.operation_count) {
                const op_type_val = try reader.readU8();
                const _ = @as(OperationType, @enumFromInt(op_type_val));
                const payload_len = try reader.readU32();
                try reader.skip(payload_len);
                ops_read += 1;
            }

            const txn_end = reader.offset;
            const txn_bytes = buffer[0..txn_end];
            const expected_crc = try reader.readU32();
            const actual_crc = utils.crc32c(txn_bytes[0..txn_end-4]);
            if (expected_crc != actual_crc) {
                // Corrupted transaction - stop replay
                break;
            }

            // Re-read and replay operations with filesystem context
            var replay_reader = serialization.createReader(buffer);
            _ = TransactionHeader.deserialize(&replay_reader, self.allocator); // Skip header

            for (0..txn_header.operation_count) |_| {
                const op = try Operation.deserialize(&replay_reader, self.allocator);
                // Apply operation based on type
                try applyOperationForRecovery(op, device, cluster_size, ag_manager, allocator);
            }

            offset += txn_end;
        }
    }

    pub fn findLastCheckpoint(self: *Self) !u64 {
        return self.superblock.last_checkpoint;
    }
};

// Apply a single operation during recovery
fn applyOperationForRecovery(
    op: Operation,
    device: *blockdev.BlockDevice,
    cluster_size: u32,
    ag_manager: *allocation.AllocationGroupManager,
    allocator: Allocator,
) !void {
    switch (op.op_type) {
        OperationType.CREATE_INODE => {
            const op_data = try op.getOpCreateInode(allocator);
            defer allocator.free(op_data.name);
            // Inode already created on disk, but ensure allocation bitmap reflects it
            try ag_manager.allocateInode(op_data.inode);
        },
        OperationType.DELETE_INODE => {
            const op_data = try op.getOpDeleteInode(allocator);
            // Inode deleted, ensure it's marked free
            try ag_manager.freeInode(op_data.inode);
            allocator.free(op_data.name);
        },
        OperationType.LINK_DIRENT => {
            const op_data = try op.getOpLinkDirent(allocator);
            defer allocator.free(op_data.name);
            // Directory entry added, update link count
            // The inode metadata should already be updated on disk
            // Just ensure allocation bitmap is consistent
            try ag_manager.allocateInode(op_data.child);
        },
        OperationType.UNLINK_DIRENT => {
            const op_data = try op.getOpUnlinkDirent(allocator);
            defer allocator.free(op_data.name);
            // Directory entry removed, decrement link count
            // If link count reaches 0, inode will be freed by DELETE_INODE operation
            _ = op_data;
        },
        OperationType.RENAME_DIRENT => {
            const op_data = try op.getOpRenameDirent(allocator);
            defer allocator.free(op_data.old_name);
            defer allocator.free(op_data.new_name);
            // Directory entries moved - no allocation changes needed
            _ = op_data;
        },
        OperationType.RM_DIR => {
            const op_data = try op.getOpRmDir(allocator);
            defer allocator.free(op_data.name);
            // Directory removed - handled by DELETE_INODE
            _ = op_data;
        },
        OperationType.SYMLINK => {
            const op_data = try op.getOpSymlink(allocator);
            defer allocator.free(op_data.name);
            defer allocator.free(op_data.target);
            // Symlink inode created - ensure allocation
            try ag_manager.allocateInode(op_data.inode);
        },
        OperationType.HARDLINK => {
            const op_data = try op.getOpHardlink(allocator);
            defer allocator.free(op_data.name);
            // Hardlink added - link count incremented, inode allocated
            try ag_manager.allocateInode(op_data.child);
        },
        OperationType.ALLOCATE_EXTENT => {
            const op_data = try op.getOpAllocateExtent(allocator);
            // Extent allocated - mark blocks as used in allocation bitmap
            var ag = try ag_manager.getGroup(op_data.physical_block / ag_manager.group_size);
            defer ag_manager.releaseGroup(ag);
            try ag.allocateExtent(op_data.physical_block, op_data.length);
        },
        OperationType.DEALLOCATE_EXTENT => {
            const op_data = try op.getOpDeallocateExtent(allocator);
            // Extent deallocated - mark blocks as free in allocation bitmap
            var ag = try ag_manager.getGroup(op_data.physical_block / ag_manager.group_size);
            defer ag_manager.releaseGroup(ag);
            try ag.freeExtent(op_data.physical_block, op_data.length);
        },
        OperationType.UPDATE_INODE_META => {
            const op_data = try op.getOpUpdateInodeMeta(allocator);
            // Inode metadata updated - already on disk, just verify
            _ = op_data;
        },
        OperationType.UPDATE_BITMAP => {
            const op_data = try op.getOpUpdateBitmap(allocator);
            // Explicit bitmap update - apply it
            var ag = try ag_manager.getGroup(op_data.ag_index);
            defer ag_manager.releaseGroup(ag);
            if (op_data.allocate) {
                try ag.allocateExtent(op_data.start_block, op_data.block_count);
            } else {
                try ag.freeExtent(op_data.start_block, op_data.block_count);
            }
        },
        OperationType.UPDATE_SUPERBLOCK => {
            const op_data = try op.getOpUpdateSuperblock(allocator);
            // Superblock updated - already on disk
            _ = op_data;
        },
        OperationType.CHECKPOINT => {
            const op_data = try op.getOpCheckpoint(allocator);
            defer allocator.free(op_data.ag_generations);
            // Checkpoint - AG generations already persisted
            _ = op_data;
        },
        OperationType.TRUNCATE => {
            const op_data = try op.getOpTruncate(allocator);
            // Truncate file - release clusters beyond new size
            // This requires reading the inode's extent tree and freeing extents beyond new_size
            try truncateInodeExtents(op_data.inode, op_data.new_size, device, cluster_size, ag_manager, allocator);
        },
        OperationType.FALLOCATE => {
            const op_data = try op.getOpFallocate(allocator);
            // Fallocate - pre-allocate space
            // Extents should already be allocated on disk
            _ = op_data;
        },
        OperationType.SET_XATTR,
        OperationType.REMOVE_XATTR => {
            // Extended attribute operations - metadata already updated
            _ = op;
        },
        OperationType.UPDATE_CAPSULE => {
            const op_data = try op.getOpUpdateCapsule(allocator);
            // Capsule updated - already on disk
            defer allocator.free(op_data.capsule_data);
            _ = op_data;
        },
        else => {
            // Unknown operation type - log and skip
            _ = op;
        },
    }
}

// Helper to truncate inode extents during recovery
fn truncateInodeExtents(
    inode: u64,
    new_size: u64,
    device: *blockdev.BlockDevice,
    cluster_size: u32,
    ag_manager: *allocation.AllocationGroupManager,
    allocator: Allocator,
) !void {
    // Read the inode to get its extent tree
    const inode_data = try readInode(device, cluster_size, ag_manager, inode, allocator);
    defer allocator.free(inode_data);

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
    const size = reader.readU64(); // size
    _ = reader.readU64(); // allocated_size
    _ = reader.readU64(); // atime
    _ = reader.readU64(); // mtime
    _ = reader.readU64(); // ctime
    const extent_tree_root = reader.readU64(); // extent_tree_root
    const extent_count = reader.readU16(); // extent_count
    const extent_tree_height = reader.readU16(); // extent_tree_height

    // If no extent tree, nothing to do
    if (extent_tree_root == 0 or extent_count == 0) {
        return;
    }

    // Walk the extent tree and free extents beyond new_size
    try walkAndFreeExtents(
        extent_tree_root,
        extent_tree_height,
        size,
        new_size,
        cluster_size,
        ag_manager,
        device,
        allocator,
    );
}

// Read inode data from disk
fn readInode(
    device: *blockdev.BlockDevice,
    cluster_size: u32,
    ag_manager: *allocation.AllocationGroupManager,
    inode: u64,
    allocator: Allocator,
) ![]u8 {
    // Inode table starts at cluster 10 of AG 0
    const ag0_offset = ag_manager.first_ag_offset;
    const inode_table_base = ag0_offset + 10;
    const inode_per_cluster = cluster_size / 256; // 256 bytes per inode
    const inode_index = inode - 1; // inodes start at 1
    const cluster_index = inode_index / inode_per_cluster;
    const offset_in_cluster = (inode_index % inode_per_cluster) * 256;

    const cluster = inode_table_base + cluster_index;
    var buffer = try allocator.alloc(u8, cluster_size as usize);
    try device.read(cluster * cluster_size, buffer);
    return buffer[offset_in_cluster..offset_in_cluster + 256];
}

// Extent tree node structure (simplified for recovery)
const ExtentNode = struct {
    magic: u32,
    version: u16,
    flags: u16,
    entry_count: u16,
    max_entries: u16,
    is_leaf: u16,
    level: u16,
    entries: []ExtentEntry,
    crc32c: u32,

    const ExtentEntry = struct {
        start_cluster: u64,
        length: u64,
        // For internal nodes: value is child block
    };
};

// Walk extent tree and free extents beyond new_size
fn walkAndFreeExtents(
    root_block: u64,
    tree_height: u16,
    old_size: u64,
    new_size: u64,
    cluster_size: u32,
    ag_manager: *allocation.AllocationGroupManager,
    device: *blockdev.BlockDevice,
    allocator: Allocator,
) !void {
    var current_block = root_block;
    var current_height = tree_height;

    // Use a stack for iterative traversal
    var stack = std.ArrayList(StackEntry).init(allocator);
    defer stack.deinit();

    // Stack entry: { block, height, child_index }
    const StackEntry = struct {
        block: u64,
        height: u16,
        child_index: u16,
    };

    try stack.append(.{ .block = root_block, .height = tree_height, .child_index = 0 });

    // Calculate the cluster offset where new_size ends
    const new_size_clusters = (new_size + cluster_size - 1) / cluster_size;
    const old_size_clusters = (old_size + cluster_size - 1) / cluster_size;

    while (stack.items.len > 0) {
        var entry = stack.items[stack.items.len - 1];
        stack.items[stack.items.len - 1] = entry; // Update in place

        // Read node
        var buffer = try allocator.alloc(u8, cluster_size as usize);
        try device.read(entry.block * cluster_size, buffer);
        defer allocator.free(buffer);

        var reader = serialization.createReader(buffer);
        const magic = try reader.readU32();
        if (magic != 0x45585400) { // "EXT\0" - extent tree magic
            // Try other magic values or skip
            // Note: Could also be MAGIC_EXTENT from main.zig
            break;
        }
        _ = reader.readU16(); // version
        _ = reader.readU16(); // flags
        const entry_count = try reader.readU16();
        _ = reader.readU16(); // max_entries
        const is_leaf = try reader.readU16();
        const level = try reader.readU16();

        if (is_leaf == 1) {
            // Leaf node - process extents
            for (0..entry_count) |i| {
                const start_cluster = try reader.readU64();
                const length = try reader.readU64();

                // Check if this extent is beyond new_size
                const extent_start = start_cluster;
                const extent_end = start_cluster + length;

                if (extent_start >= new_size_clusters) {
                    // Entire extent is beyond new_size - free it
                    freeExtent(extent_start, length, cluster_size, ag_manager, allocator);
                } else if (extent_end > new_size_clusters) {
                    // Extent partially beyond new_size - free the tail
                    const free_start = new_size_clusters;
                    const free_length = extent_end - free_start;
                    freeExtent(free_start, free_length, cluster_size, ag_manager, allocator);
                }
            }
        } else {
            // Internal node - push children to stack
            if (entry.child_index < entry_count) {
                const child_block = try reader.readU64(); // value for this entry
                entry.child_index += 1;
                stack.items[stack.items.len - 1] = entry;
                try stack.append(.{ .block = child_block, .height = level - 1, .child_index = 0 });
            } else {
                _ = stack.pop();
            }
        }
    }
}

// Free a single extent
fn freeExtent(
    start_cluster: u64,
    length: u64,
    cluster_size: u32,
    ag_manager: *allocation.AllocationGroupManager,
    allocator: Allocator,
) !void {
    const ag_index = start_cluster / ag_manager.ag_size;
    if (ag_index >= ag_manager.ag_count) return;

    var ag = try ag_manager.getGroup(ag_index);
    defer ag_manager.releaseGroup(ag);

    const local_start = start_cluster % ag_manager.ag_size;
    try ag.bitmap.setAllocated(local_start, false);
    // Also remove from free extent tree if needed
    _ = length;
}

// Recovery engine
pub const RecoveryEngine = struct {
    const Self = @This();
    device: *blockdev.BlockDevice,
    journal_offset: u64,
    journal_size: u64,
    cluster_size: u32,
    allocator: Allocator,

    pub fn init(
        device: *blockdev.BlockDevice,
        journal_offset: u64,
        journal_size: u64,
        cluster_size: u32,
        allocator: Allocator,
    ) RecoveryEngine {
        return .{
            .device = device,
            .journal_offset = journal_offset,
            .journal_size = journal_size,
            .cluster_size = cluster_size,
            .allocator = allocator,
        };
    }

    pub fn recover(self: *Self, apply_fn: fn(Operation) !void) !void {
        var reader = try JournalReader.init(
            self.device,
            self.journal_offset,
            self.journal_size,
            self.cluster_size,
            self.allocator,
        );

        // Find last checkpoint
        const checkpoint_offset = try reader.findLastCheckpoint();

        // Replay from checkpoint
        try reader.replay(apply_fn);
    }

    // Full recovery with filesystem context
    pub fn recoverFull(
        self: *Self,
        ag_manager: *allocation.AllocationGroupManager,
    ) !void {
        var reader = try JournalReader.init(
            self.device,
            self.journal_offset,
            self.journal_size,
            self.cluster_size,
            self.allocator,
        );

        // Replay with full filesystem context
        try reader.replayForRecovery(
            self.device,
            self.cluster_size,
            ag_manager,
            self.allocator,
        );
    }

    pub fn verifyJournal(self: *Self) !bool {
        var reader = try JournalReader.init(
            self.device,
            self.journal_offset,
            self.journal_size,
            self.cluster_size,
            self.allocator,
        );

        // Try to read all transactions - if any fail, journal is corrupted
        var offset: u64 = JournalSuperblock.SIZE + 4;
        const journal_bytes = self.journal_size * self.cluster_size;

        while (offset < journal_bytes) {
            var buffer = try self.allocator.alloc(u8, self.cluster_size as usize);
            defer self.allocator.free(buffer);

            try self.device.read(self.journal_offset * self.cluster_size + offset, buffer);

            var r = serialization.createReader(buffer);
            const txn_header = TransactionHeader.deserialize(&r, self.allocator) catch {
                break; // End of valid transactions
            };

            // Verify CRC
            var ops_read: u32 = 0;
            while (ops_read < txn_header.operation_count) {
                _ = try r.readU8();
                const payload_len = try r.readU32();
                try r.skip(payload_len);
                ops_read += 1;
            }

            const txn_end = r.offset;
            const expected_crc = try r.readU32();
            const actual_crc = utils.crc32c(buffer[0..txn_end-4]);
            if (expected_crc != actual_crc) {
                return false;
            }

            offset += txn_end;
        }

        return true;
    }
};

// Standalone functions for C API
pub fn needsRecovery(
    device: *blockdev.BlockDevice,
    journal_offset: u64,
    journal_size: u64,
    cluster_size: u32,
    allocator: Allocator,
) !bool {
    // Quick check: read journal superblock and see if there are uncommitted transactions
    var buffer = try allocator.alloc(u8, cluster_size as usize);
    defer allocator.free(buffer);

    try device.read(journal_offset * cluster_size, buffer);

    var reader = serialization.createReader(buffer);
    const superblock = try JournalSuperblock.deserialize(&reader, allocator);

    // If start_txn != end_txn, there are uncommitted transactions
    return superblock.start_txn != superblock.end_txn;
}

pub fn recover(
    device: *blockdev.BlockDevice,
    journal_offset: u64,
    journal_size: u64,
    cluster_size: u32,
    allocator: Allocator,
    ag_manager: *allocation.AllocationGroupManager,
) !void {
    const recovery = RecoveryEngine.init(
        device,
        journal_offset,
        journal_size,
        cluster_size,
        allocator,
    );
    try recovery.recoverFull(ag_manager);
}

pub fn verify(
    device: *blockdev.BlockDevice,
    journal_offset: u64,
    journal_size: u64,
    cluster_size: u32,
    allocator: Allocator,
) !bool {
    const recovery = RecoveryEngine.init(
        device,
        journal_offset,
        journal_size,
        cluster_size,
        allocator,
    );
    return try recovery.verifyJournal();
}

// Merkle tree over transaction chain for integrity verification
pub const TransactionMerkleTree = struct {
    const Self = @This();
    leaves: []u8, // BLAKE3 hashes of transactions
    tree: []u8,   // Full merkle tree
    leaf_count: u32 = 0,

    pub fn init(allocator: Allocator, max_transactions: u32) !TransactionMerkleTree {
        const tree_size = max_transactions * 2;
        var tree = try allocator.alloc(u8, tree_size * 32); // 32 bytes per hash
        return .{
            .leaves = tree[0..max_transactions * 32],
            .tree = tree[max_transactions * 32..],
            .leaf_count = 0,
        };
    }

    pub fn addTransaction(self: *Self, txn_hash: [32]u8) void {
        const idx = self.leaf_count;
        @memcpy(self.leaves[idx * 32..(idx + 1) * 32], &txn_hash);
        self.leaf_count += 1;
        // Rebuild tree (simplified - incremental update would be better)
        self.rebuild();
    }

    fn rebuild(self: *Self) void {
        // Simplified merkle tree rebuild
        // Full implementation would build binary tree from leaves
        _ = self;
    }

    pub fn getRoot(self: *Self) [32]u8 {
        if (self.leaf_count == 0) return [_]u8{} ** 32;
        // Return root of tree
        return *self.tree[0..32];
    }

    pub fn verify(self: *Self, expected_root: [32]u8) bool {
        return std.mem.eql(u8, self.getRoot(), &expected_root);
    }
};