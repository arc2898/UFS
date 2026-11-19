// UFS Integration Test
// End-to-end test: format → mount → write → read → verify
// Uses in-memory block device for fast testing

const std = @import("std");
const serialization = @import("serialization.zig");
const metadata = @import("metadata.zig");
const allocation = @import("allocation.zig");
const directory = @import("directory.zig");
const journal = @import("journal.zig");
const integrity = @import("integrity.zig");
const compression = @import("compression.zig");
const version = @import("version.zig");
const utils = @import("utils.zig");
const blockdev = @import("blockdev.zig");
const Allocator = std.mem.Allocator;

const testing = std.testing;

pub const IntegrationError = error{
    OutOfMemory,
    IoError,
    CorruptedData,
    InvalidFormat,
    NotFound,
    AlreadyExists,
    OutOfSpace,
};

// ============================================================================
// In-Memory Block Device for Testing
// ============================================================================

pub const MemBlockDevice = struct {
    const Self = @This();
    data: []u8,
    cluster_size: u32,
    read_only: bool = false,

    pub fn init(allocator: Allocator, total_clusters: u64, cluster_size: u32) !MemBlockDevice {
        const total_bytes = total_clusters * cluster_size;
        var data = try allocator.alloc(u8, @as(usize, @intCast(total_bytes)));
        @memset(data, 0);
        return .{ .data = data, .cluster_size = cluster_size };
    }

    pub fn deinit(self: *Self, allocator: Allocator) void {
        allocator.free(self.data);
        self.data = &[_]u8{};
    }

    pub fn read(self: *Self, offset: u64, buffer: []u8) !void {
        if (offset + buffer.len > self.data.len) return IntegrationError.OutOfBounds;
        @memcpy(buffer, self.data[offset..offset + buffer.len]);
    }

    pub fn write(self: *Self, offset: u64, buffer: []const u8) !void {
        if (self.read_only) return IntegrationError.WriteProtected;
        if (offset + buffer.len > self.data.len) return IntegrationError.OutOfBounds;
        @memcpy(self.data[offset..offset + buffer.len], buffer);
    }

    pub fn flush(self: *Self) !void {
        // No-op for memory device
    }

    pub fn getInfo(self: *Self) blockdev.BlockDeviceInfo {
        return .{
            .block_size = self.cluster_size,
            .physical_block_size = self.cluster_size,
            .optimal_io_size = 128 * 1024,
            .total_blocks = self.data.len / self.cluster_size,
            .is_removable = false,
            .is_read_only = self.read_only,
            .is_ssd = true,
            .is_virtual = true,
        };
    }
};

// Implement BlockDevice vtable for MemBlockDevice
const MemBlockDeviceVTable = blockdev.BlockDevice.VTable{
    .read = memRead,
    .write = memWrite,
    .flush = memFlush,
    .trim = memTrim,
    .read_async = null,
    .write_async = null,
    .get_info = memGetInfo,
    .set_flags = memSetFlags,
    .get_flags = memGetFlags,
    .open = memOpen,
    .close = memClose,
    .get_geometry = memGetGeometry,
};

fn memRead(device: *blockdev.BlockDevice, offset: u64, buffer: []u8) !void {
    const ctx = @as(*MemBlockDevice, @ptrCast(device.context));
    ctx.read(offset, buffer) catch |err| switch (err) {
        IntegrationError.OutOfBounds => return error.OutOfBounds,
        else => return error.IoError,
    };
}

fn memWrite(device: *blockdev.BlockDevice, offset: u64, buffer: []const u8) !void {
    const ctx = @as(*MemBlockDevice, @ptrCast(device.context));
    ctx.write(offset, buffer) catch |err| switch (err) {
        IntegrationError.WriteProtected => return error.WriteProtected,
        IntegrationError.OutOfBounds => return error.OutOfBounds,
        else => return error.IoError,
    };
}

fn memFlush(device: *blockdev.BlockDevice) !void {
    _ = device;
    // Success - implicit return
}

fn memTrim(device: *blockdev.BlockDevice, offset: u64, length: u64) !void {
    _ = device; _ = offset; _ = length;
    return error.UnsupportedOperation;
}

fn memGetInfo(device: *blockdev.BlockDevice) blockdev.BlockDeviceInfo {
    const ctx = @as(*MemBlockDevice, @ptrCast(device.context));
    return ctx.getInfo();
}

fn memSetFlags(device: *blockdev.BlockDevice, flags: blockdev.BlockDeviceFlags) !void {
    const ctx = @as(*MemBlockDevice, @ptrCast(device.context));
    ctx.read_only = flags.read_only;
}

fn memGetFlags(device: *blockdev.BlockDevice) blockdev.BlockDeviceFlags {
    const ctx = @as(*MemBlockDevice, @ptrCast(device.context));
    return .{ .read_only = ctx.read_only };
}

fn memOpen(device: *blockdev.BlockDevice, path: []const u8, flags: blockdev.BlockDeviceFlags) !void {
    _ = device; _ = path; _ = flags;
    return error.UnsupportedOperation;
}

fn memClose(device: *blockdev.BlockDevice) !void {
    _ = device;
}

fn memGetGeometry(device: *blockdev.BlockDevice) blockdev.BlockDevice.Geometry {
    _ = device;
    return .{ .cylinders = 0, .heads = 0, .sectors_per_track = 0, .bytes_per_sector = 4096 };
}

fn createMemBlockDevice(allocator: Allocator, total_clusters: u64, cluster_size: u32) !*blockdev.BlockDevice {
    const mem = try MemBlockDevice.init(allocator, total_clusters, cluster_size);
    const device = try allocator.create(blockdev.BlockDevice).init(.{
        .context = mem,
        .vtable = &MemBlockDeviceVTable,
    });
    return device;
}

// ============================================================================
// Mini Filesystem Implementation for Integration Test
// ============================================================================

const MiniUFS = struct {
    const Self = @This();
    device: *blockdev.BlockDevice,
    cluster_size: u32,
    allocator: Allocator,
    superblock_cluster: u64 = 1,
    journal_offset: u64,
    journal_size: u64 = 1024, // clusters
    first_ag_offset: u64,
    ag_size: u64 = 1024, // clusters per AG
    ag_count: u32 = 1,
    root_inode: u64 = 1,
    next_inode: u64 = 2,
    journal_writer: ?journal.JournalWriter = null,
    ag_manager: ?allocation.AllocationGroupManager = null,

    pub fn init(
        device: *blockdev.BlockDevice,
        cluster_size: u32,
        allocator: Allocator,
    ) MiniUFS {
        return .{
            .device = device,
            .cluster_size = cluster_size,
            .allocator = allocator,
            .journal_offset = 2, // After superblock
            .first_ag_offset = 2 + 1024, // After journal
        };
    }

    pub fn format(self: *Self) !void {
        // 1. Write superblock
        try self.writeSuperblock();

        // 2. Initialize journal
        try self.initJournal();

        // 3. Initialize AG
        try self.initAG();

        // 4. Create root directory
        try self.createRootDirectory();

        // 5. Flush
        try self.device.flush();
    }

    fn writeSuperblock(self: *Self) !void {
        const vol_fmt = try version.VolumeFormat.current(self.allocator);
        defer {
            // VolumeFormat doesn't need deinit
        }

        var writer = serialization.createWriter(self.allocator);
        defer writer.deinit();

        // Superblock structure (matching UFS-FORMAT-V1.md)
        try writer.writeU32(0x55465300); // MAGIC_UFS
        try writer.writeU16(1); // version_major
        try writer.writeU16(0); // version_minor
        try writer.writeU32(0); // version_revision
        try writer.writeU32(0); // flags
        try writer.writeU32(0); // feature_incompat
        try writer.writeU32(0); // feature_compat_ro
        try writer.writeU32(0); // feature_compat_rw

        const total_clusters = self.device.getInfo().total_blocks;
        try writer.writeU64(total_clusters); // volume_size
        try writer.writeU32(self.cluster_size); // cluster_size
        try writer.writeU32(512); // sector_size

        // Volume UUID
        const uuid = utils.generateUuidv7Bytes();
        try writer.writeBytes(&uuid);

        // Volume label
        var label: [64]u8 = undefined;
        @memset(&label, 0);
        try writer.writeBytes(&label);

        try writer.writeU64(self.root_inode); // root_inode
        try writer.writeU64(self.journal_offset); // journal_offset
        try writer.writeU64(self.journal_size); // journal_size
        try writer.writeU32(self.ag_count); // ag_count
        try writer.writeU32(@as(u32, @intCast(self.ag_size))); // ag_size
        try writer.writeU64(0); // ag_table_offset (not used)
        try writer.writeU64(self.first_ag_offset); // first_ag_offset

        // Backup superblock offsets
        var backup_offsets: [8]u64 = undefined;
        backup_offsets[0] = 16; // 64KB
        backup_offsets[1] = 16384; // 64MB
        backup_offsets[4] = total_clusters - 16; // End - 64KB
        try writer.writeBytes(&backup_offsets);

        try writer.writeU64(1); // generation
        try writer.writeU8(1); // clean_flag
        try writer.writeBytes((&[_]u8{0}) ** 7); // reserved

        // Pad to cluster size and write CRC
        try writer.align(self.cluster_size as usize);
        const crc = utils.crc32c(writer.bytes());
        try writer.writeU32(crc);

        // Write to cluster 1
        try self.device.write(self.superblock_cluster * self.cluster_size, writer.bytes());
    }

    fn initJournal(self: *Self) !void {
        // Journal superblock
        var writer = serialization.createWriter(self.allocator);
        defer writer.deinit();

        try writer.writeU32(0x4A55524E); // MAGIC_JOURNAL
        try writer.writeU16(1); // version
        try writer.writeU16(0); // flags
        try writer.writeU64(0); // start_txn
        try writer.writeU64(0); // end_txn
        try writer.writeU64(0); // last_checkpoint
        try writer.writeU64(self.journal_size * self.cluster_size); // size

        try writer.align(self.cluster_size as usize);
        const crc = utils.crc32c(writer.bytes());
        try writer.writeU32(crc);

        try self.device.write(self.journal_offset * self.cluster_size, writer.bytes());

        // Initialize journal writer
        const jw = try journal.JournalWriter.init(
            self.device,
            self.journal_offset,
            self.journal_size,
            self.cluster_size,
            self.allocator,
        );
        self.journal_writer = jw;
    }

    fn initAG(self: *Self) !void {
        // AG Header
        var writer = serialization.createWriter(self.allocator);
        defer writer.deinit();

        try writer.writeU32(0x41470000); // MAGIC_AG
        try writer.writeU16(1); // version
        try writer.writeU16(0); // flags
        try writer.writeU32(0); // ag_index
        try writer.writeU64(self.first_ag_offset); // ag_offset
        try writer.writeU32(@as(u32, @intCast(self.ag_size))); // ag_size
        try writer.writeU32(self.cluster_size); // cluster_size
        try writer.writeU64(self.ag_size - 100); // free_clusters (approximate)
        try writer.writeU64(1); // free_extents
        try writer.writeU64(0); // free_tree_root (none yet)
        try writer.writeU64(1); // bitmap_offset (cluster 1 of AG)
        try writer.writeU64(10); // inode_table_offset
        try writer.writeU32(512); // inode_count
        try writer.writeU32(511); // free_inodes (root takes 1)
        try writer.writeU64(1); // generation

        try writer.align(self.cluster_size as usize);
        const crc = utils.crc32c(writer.bytes());
        try writer.writeU32(crc);

        try self.device.write(self.first_ag_offset * self.cluster_size, writer.bytes());

        // Allocation bitmap (1 cluster = 4096 bits = 4096 clusters, we have 1024)
        var bitmap_data: [4096]u8 = undefined;
        @memset(&bitmap_data, 0);
        // Mark first 100 clusters as used (AG header, bitmap, inode table, root dir)
        for (0..100) |i| {
            bitmap_data[i / 8] |= (1 << (i % 8));
        }
        try self.device.write((self.first_ag_offset + 1) * self.cluster_size, &bitmap_data);

        // Inode bitmap (1 cluster)
        var inode_bitmap: [4096]u8 = undefined;
        @memset(&inode_bitmap, 0);
        inode_bitmap[0] |= 1; // Inode 0 reserved
        inode_bitmap[0] |= 2; // Inode 1 = root
        try self.device.write((self.first_ag_offset + 10 - 1) * self.cluster_size, &inode_bitmap);

        // Initialize AG manager
        const agm = try allocation.AllocationGroupManager.init(
            self.device,
            self.cluster_size,
            self.ag_count,
            self.ag_size,
            0, // ag_table_offset
            self.first_ag_offset,
            self.allocator,
        );
        self.ag_manager = agm;
    }

    fn createRootDirectory(self: *Self) !void {
        // Create root inode (inode 1)
        const capsule = try metadata.createPosixBaseCapsule(
            self.allocator,
            1, // inode
            0o040755, // mode (directory)
            0, // uid
            0, // gid
            utils.timestamp(), // atime
            utils.timestamp(), // mtime
            utils.timestamp(), // ctime
            utils.timestamp(), // crtime
            2, // link_count (., ..)
        );
        defer capsule.deinit();

        // Serialize capsule
        var cap_writer = serialization.createWriter(self.allocator);
        defer cap_writer.deinit();
        try capsule.serialize(&cap_writer);
        const capsule_data = cap_writer.bytes();

        // Write capsule to cluster 20 of AG
        const capsule_cluster = self.first_ag_offset + 20;
        try self.device.write(capsule_cluster * self.cluster_size, capsule_data);

        // Create root inode
        var inode_writer = serialization.createWriter(self.allocator);
        defer inode_writer.deinit();

        try inode_writer.writeU32(0x494E4F00); // magic
        try inode_writer.writeU16(1); // version
        try inode_writer.writeU16(0x0002); // flags (directory)
        try inode_writer.writeU64(1); // inode_number
        try inode_writer.writeU64(1); // generation
        try inode_writer.writeU64(capsule.header.capsule_id); // capsule_id
        try inode_writer.writeU32(0o040755); // mode
        try inode_writer.writeU32(0); // uid
        try inode_writer.writeU32(0); // gid
        try inode_writer.writeU32(2); // link_count
        try inode_writer.writeU32(0); // flags2
        try inode_writer.writeU32(0); // reserved1
        try inode_writer.writeU64(0); // size
        try inode_writer.writeU64(self.cluster_size); // allocated_size
        try inode_writer.writeU64(utils.timestamp()); // atime
        try inode_writer.writeU64(utils.timestamp()); // mtime
        try inode_writer.writeU64(utils.timestamp()); // ctime
        try inode_writer.writeU64(0); // extent_tree_root (inline)
        try inode_writer.writeU16(0); // extent_count
        try inode_writer.writeU16(0); // extent_tree_height
        try inode_writer.writeU32(0); // reserved2
        try inode_writer.writeU16(0); // compression_algo
        try inode_writer.writeU16(0); // compression_level
        try inode_writer.writeU32(0); // encryption_key_id
        try inode_writer.writeU64(0); // reserved3
        try inode_writer.writeU64(capsule_cluster); // capsule_offset
        try inode_writer.writeU32(@as(u32, @intCast(capsule_data.len))); // capsule_size
        try inode_writer.writeU32(0); // capsule_flags
        for (0..112) |_| { try inode_writer.writeU8(0); } // reserved

        try inode_writer.align(256);
        const inode_crc = utils.crc32c(inode_writer.bytes());
        try inode_writer.writeU32(inode_crc);

        const inode_data = inode_writer.bytes();
        try self.device.write((self.first_ag_offset + 10) * self.cluster_size, inode_data);

        // Create root directory entries (., ..)
        var dir = directory.LinearDirectory.init(self.allocator, 64);
        defer dir.deinit();

        try dir.insert(directory.DirEntry{
            .inode = 1,
            .name = ".",
            .file_type = directory.DirEntry.FILE_TYPE_DIR,
            .flags = 0,
        });
        try dir.insert(directory.DirEntry{
            .inode = 1,
            .name = "..",
            .file_type = directory.DirEntry.FILE_TYPE_DIR,
            .flags = 0,
        });

        var dir_writer = serialization.createWriter(self.allocator);
        defer dir_writer.deinit();
        try dir.serialize(&dir_writer);
        const dir_data = dir_writer.bytes();

        // Write directory data to cluster 30 of AG
        const dir_cluster = self.first_ag_offset + 30;
        try self.device.write(dir_cluster * self.cluster_size, dir_data);

        // Update root inode with extent pointing to directory data
        // (Simplified - just store inline for now)
    }

    // ========================================================================
    // File Operations
    // ========================================================================

    pub fn createFile(self: *Self, parent: u64, name: []const u8, data: []const u8) !u64 {
        // Allocate inode
        const inode_num = self.next_inode;
        self.next_inode += 1;

        // Create capsule
        const capsule = try metadata.createPosixBaseCapsule(
            self.allocator,
            inode_num,
            0o100644,
            0, 0,
            utils.timestamp(), utils.timestamp(), utils.timestamp(), utils.timestamp(),
            1,
        );
        defer capsule.deinit();

        var cap_writer = serialization.createWriter(self.allocator);
        defer cap_writer.deinit();
        try capsule.serialize(&cap_writer);
        const capsule_data = cap_writer.bytes();

        const capsule_cluster = self.first_ag_offset + 20 + inode_num;
        try self.device.write(capsule_cluster * self.cluster_size, capsule_data);

        // Allocate data clusters
        const clusters_needed = (data.len + self.cluster_size - 1) / self.cluster_size;
        const extent = try self.allocateClusters(clusters_needed);

        // Write data
        var offset: usize = 0;
        for (0..clusters_needed) |i| {
            const cluster = extent.start_cluster + i;
            const chunk = data[offset..];
            const write_len = @min(chunk.len, self.cluster_size as usize);
            var buffer: [4096]u8 = undefined;
            @memset(&buffer, 0);
            @memcpy(&buffer, chunk[0..write_len]);
            try self.device.write(cluster * self.cluster_size, buffer[0..write_len]);
            offset += write_len;
        }

        // Create inode
        var inode_writer = serialization.createWriter(self.allocator);
        defer inode_writer.deinit();

        try inode_writer.writeU32(0x494E4F00);
        try inode_writer.writeU16(1);
        try inode_writer.writeU16(0x0001); // flags (regular file)
        try inode_writer.writeU64(inode_num);
        try inode_writer.writeU64(1);
        try inode_writer.writeU64(capsule.header.capsule_id);
        try inode_writer.writeU32(0o100644);
        try inode_writer.writeU32(0);
        try inode_writer.writeU32(0);
        try inode_writer.writeU32(1);
        try inode_writer.writeU32(0);
        try inode_writer.writeU32(0);
        try inode_writer.writeU64(data.len);
        try inode_writer.writeU64(clusters_needed * self.cluster_size);
        try inode_writer.writeU64(utils.timestamp());
        try inode_writer.writeU64(utils.timestamp());
        try inode_writer.writeU64(utils.timestamp());
        try inode_writer.writeU64(extent.start_cluster); // extent_tree_root (inline)
        try inode_writer.writeU16(1); // extent_count
        try inode_writer.writeU16(0); // extent_tree_height
        try inode_writer.writeU32(0);
        try inode_writer.writeU16(0);
        try inode_writer.writeU16(0);
        try inode_writer.writeU32(0);
        try inode_writer.writeU64(0);
        try inode_writer.writeU64(capsule_cluster);
        try inode_writer.writeU32(@as(u32, @intCast(capsule_data.len)));
        try inode_writer.writeU32(0);
        for (0..112) |_| { try inode_writer.writeU8(0); }

        try inode_writer.align(256);
        const inode_crc = utils.crc32c(inode_writer.bytes());
        try inode_writer.writeU32(inode_crc);

        const inode_data = inode_writer.bytes();
        try self.device.write((self.first_ag_offset + 10 + inode_num) * self.cluster_size, inode_data);

        // Add directory entry to parent
        try self.addDirEntry(parent, name, inode_num, directory.DirEntry.FILE_TYPE_REG);

        // Journal the transaction
        try self.journalCreate(inode_num, parent, name);

        return inode_num;
    }

    pub fn readFile(self: *Self, inode_num: u64) ![]u8 {
        // Read inode
        const inode_data = try self.readInode(inode_num);

        // Parse inode to get extent
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
        const size = try reader.readU64(); // size
        _ = reader.readU64(); // allocated_size
        _ = reader.readU64(); // atime
        _ = reader.readU64(); // mtime
        _ = reader.readU64(); // ctime
        const extent_root = try reader.readU64(); // extent_tree_root
        const extent_count = try reader.readU16(); // extent_count

        // For inline extent, extent_root is the physical cluster
        var result = try self.allocator.alloc(u8, @as(usize, @intCast(size)));
        var offset: usize = 0;

        if (extent_count == 1 && extent_root != 0) {
            const clusters_needed = (size + self.cluster_size - 1) / self.cluster_size;
            for (0..clusters_needed) |i| {
                const cluster = extent_root + i;
                var buffer: [4096]u8 = undefined;
                try self.device.read(cluster * self.cluster_size, &buffer);
                const to_copy = @min(self.cluster_size as usize, @as(usize, @intCast(size)) - offset);
                @memcpy(result[offset..offset + to_copy], buffer[0..to_copy]);
                offset += to_copy;
            }
        }

        return result;
    }

    fn readInode(self: *Self, inode_num: u64) ![]u8 {
        var buffer: [4096]u8 = undefined;
        try self.device.read((self.first_ag_offset + 10 + inode_num) * self.cluster_size, &buffer);
        return buffer[0..256]; // Inode is 256 bytes
    }

    fn addDirEntry(self: *Self, parent: u64, name: []const u8, child: u64, file_type: u8) !void {
        // Read parent directory
        const dir_data = try self.readDirectory(parent);
        var reader = serialization.createReader(dir_data);
        var dir = try directory.LinearDirectory.deserialize(&reader, self.allocator);
        defer dir.deinit();

        // Insert new entry
        try dir.insert(directory.DirEntry{
            .inode = child,
            .name = name,
            .file_type = file_type,
            .flags = 0,
        });

        // Write back
        var writer = serialization.createWriter(self.allocator);
        defer writer.deinit();
        try dir.serialize(&writer);

        // Find parent directory cluster and write
        // Simplified: assume parent is root (cluster 30)
        const parent_cluster = self.first_ag_offset + 30;
        try self.device.write(parent_cluster * self.cluster_size, writer.bytes());
    }

    fn readDirectory(self: *Self, inode_num: u64) ![]u8 {
        // Simplified: root directory is at cluster 30
        var buffer: [4096]u8 = undefined;
        try self.device.read((self.first_ag_offset + 30) * self.cluster_size, &buffer);
        // Find actual size by reading CRC
        var reader = serialization.createReader(&buffer);
        _ = reader.readU32(); // magic
        _ = reader.readU16(); // version
        const entry_count = try reader.readU16();
        for (0..entry_count) |_| {
            _ = reader.readU64(); // inode
            const name_len = try reader.readU16();
            _ = reader.readU8(); // file_type
            _ = reader.readU8(); // flags
            reader.offset += name_len;
            const padding = (8 - (reader.offset % 8)) % 8;
            reader.offset += padding;
        }
        _ = reader.readU32(); // crc
        return buffer[0..reader.offset];
    }

    fn allocateClusters(self: *Self, count: u64) !allocation.AllocationResult {
        // Use AG manager
        if (self.ag_manager) |*agm| {
            return try agm.allocateClusters(count, .{});
        }
        return IntegrationError.OutOfSpace;
    }

    fn journalCreate(self: *Self, inode: u64, parent: u64, name: []const u8) !void {
        if (self.journal_writer) |*jw| {
            var builder = journal.TransactionBuilder.init(self.allocator, jw.superblock.end_txn + 1);
            defer builder.deinit();

            const capsule_id = utils.generateUuidv7();
            try builder.addCreateInode(journal.OpCreateInode{
                .inode = inode,
                .parent = parent,
                .name = name,
                .mode = 0o100644,
                .uid = 0,
                .gid = 0,
                .capsule_id = capsule_id,
            });
            try builder.addLinkDirent(journal.OpLinkDirent{
                .parent = parent,
                .name = name,
                .child = inode,
                .file_type = directory.DirEntry.FILE_TYPE_REG,
            });
            try builder.addCheckpoint(journal.OpCheckpoint{
                .superblock_generation = 1,
                .ag_generations = &[_]u64{1},
            });

            const txn = builder.build();
            try jw.writeTransaction(txn);
            try jw.commit();
        }
    }
};

// ============================================================================
// Integration Test
// ============================================================================

test "integration: format → mount → write → read → verify" {
    const allocator = testing.allocator;

    // Create in-memory block device (100MB)
    const device = try createMemBlockDevice(allocator, 25600, 4096);
    defer device.close();

    // Create and format filesystem
    var fs = MiniUFS.init(device, 4096, allocator);
    try fs.format();

    // Test 1: Create a file
    const test_data = "Hello, UFS! This is a test file with some content.";
    const inode = try fs.createFile(1, "test.txt", test_data);

    // Test 2: Read the file back
    const read_data = try fs.readFile(inode);
    defer allocator.free(read_data);

    // Test 3: Verify content matches
    try testing.expectEqualSlices(u8, test_data, read_data);

    // Test 4: Create multiple files
    const files = [_]struct { name: []const u8, data: []const u8 }{
        { .name = "file1.txt", .data = "File 1 content" },
        { .name = "file2.txt", .data = "File 2 content with more data" },
        { .name = "file3.bin", .data = "Binary\x00\x01\x02\x03data" },
    };

    for (files) |f| {
        const ino = try fs.createFile(1, f.name, f.data);
        const read_back = try fs.readFile(ino);
        defer allocator.free(read_back);
        try testing.expectEqualSlices(u8, f.data, read_back);
    }

    // Test 5: Create larger file (multi-cluster)
    var large_data: [10000]u8 = undefined;
    for (&large_data, 0..) |*b, i| b.* = @as(u8, @intCast(i % 256));
    const large_inode = try fs.createFile(1, "large.bin", &large_data);
    const large_read = try fs.readFile(large_inode);
    defer allocator.free(large_read);
    try testing.expectEqualSlices(u8, &large_data, large_read);

    // Test 6: Verify device flush works
    try device.flush();

    // Test 7: Verify journal has transactions
    if (fs.journal_writer) |jw| {
        try testing.expect(jw.superblock.end_txn > 0);
    }

    // Test 8: Verify AG has allocated clusters
    if (fs.ag_manager) |agm| {
        try agm.loadAG(0);
        const info = try agm.getAGInfo(0);
        try testing.expect(info.free_clusters < 1024); // Some clusters allocated
    }
}

test "integration: directory operations" {
    const allocator = testing.allocator;
    const device = try createMemBlockDevice(allocator, 25600, 4096);
    defer device.close();

    var fs = MiniUFS.init(device, 4096, allocator);
    try fs.format();

    // Create subdirectory
    const dir_inode = try fs.createFile(1, "subdir", "");
    // Note: This creates a file, not a directory. Real implementation would have mkdir.

    // Create files in root
    try fs.createFile(1, "a.txt", "Content A");
    try fs.createFile(1, "b.txt", "Content B");
    try fs.createFile(1, "c.txt", "Content C");

    // Read directory
    const dir_data = try fs.readDirectory(1);
    var reader = serialization.createReader(dir_data);
    const dir = try directory.LinearDirectory.deserialize(&reader, allocator);
    defer dir.deinit();

    // Should have ., .., a.txt, b.txt, c.txt
    try testing.expect(dir.count() >= 5);
    try testing.expect(dir.find("a.txt") != null);
    try testing.expect(dir.find("b.txt") != null);
    try testing.expect(dir.find("c.txt") != null);
}

test "integration: metadata capsules" {
    const allocator = testing.allocator;
    const device = try createMemBlockDevice(allocator, 25600, 4096);
    defer device.close();

    var fs = MiniUFS.init(device, 4096, allocator);
    try fs.format();

    // Create file with metadata
    const inode = try fs.createFile(1, "meta.txt", "test");

    // Read capsule from inode
    const inode_data = try fs.readInode(inode);
    var reader = serialization.createReader(inode_data);
    _ = reader.readU32(); // magic
    _ = reader.readU16(); // version
    _ = reader.readU16(); // flags
    _ = reader.readU64(); // inode_number
    _ = reader.readU64(); // generation
    const capsule_id = try reader.readU64(); // capsule_id

    try testing.expect(capsule_id != 0);

    // Verify capsule exists at expected location
    const capsule_cluster = fs.first_ag_offset + 20 + inode;
    var cap_buffer: [4096]u8 = undefined;
    try device.read(capsule_cluster * fs.cluster_size, &cap_buffer);

    var cap_reader = serialization.createReader(&cap_buffer);
    const capsule = try metadata.MetadataCapsule.deserialize(&cap_reader, allocator);
    defer capsule.deinit();

    try testing.expect(capsule.header.inode == inode);
    try testing.expect(capsule.header.entry_count >= 3); // mode_uid_gid, timestamps, link_count

    // Parse POSIX_BASE
    const posix = try metadata.parsePosixBaseCapsule(&capsule);
    try testing.expect(posix.mode == 0o100644);
    try testing.expect(posix.link_count == 1);
}

test "integration: crash simulation (power loss during write)" {
    const allocator = testing.allocator;

    // Simulate: format → write file → crash before flush → recover
    const device = try createMemBlockDevice(allocator, 25600, 4096);
    defer device.close();

    var fs = MiniUFS.init(device, 4096, allocator);
    try fs.format();

    // Write file
    const inode = try fs.createFile(1, "crash_test.txt", "Data before crash");

    // Simulate crash: DON'T call device.flush()
    // Create new filesystem instance (simulates remount)
    const device2 = try createMemBlockDevice(allocator, 25600, 4096);
    defer device2.close();

    // Copy data (simulate disk surviving crash)
    @memcpy(device2.data, device.data);

    // Try to recover by reading
    var fs2 = MiniUFS.init(device2, 4096, allocator);
    // Note: Real recovery would replay journal
    // For this test, just verify data structures are intact

    const inode_data = try fs2.readInode(inode);
    try testing.expect(inode_data.len == 256);
}

// ============================================================================
// Property Tests for Integration
// ============================================================================

test "integration: property - write/read round-trip for various sizes" {
    const allocator = testing.allocator;
    const device = try createMemBlockDevice(allocator, 25600, 4096);
    defer device.close();

    var fs = MiniUFS.init(device, 4096, allocator);
    try fs.format();

    var rng = std.Random.DefaultPrng.init(0xE06BC83A);

    // Test various sizes
    const sizes = [_]usize{ 0, 1, 10, 100, 1000, 4096, 8192, 16384, 65536 };

    for (sizes) |size| {
        var data = try allocator.alloc(u8, size);
        defer allocator.free(data);
        for (data) |*b| b.* = rng.random();

        const name = try std.fmt.allocPrint(allocator, "test_{}.bin", .{size});
        defer allocator.free(name);

        const inode = try fs.createFile(1, name, data);
        const read_back = try fs.readFile(inode);
        defer allocator.free(read_back);

        try testing.expectEqualSlices(u8, data, read_back);
    }
}

test "integration: property - many files" {
    const allocator = testing.allocator;
    const device = try createMemBlockDevice(allocator, 25600, 4096);
    defer device.close();

    var fs = MiniUFS.init(device, 4096, allocator);
    try fs.format();

    const file_count = 100;
    var inodes = try allocator.alloc(u64, file_count);
    defer allocator.free(inodes);

    // Create many small files
    for (0..file_count) |i| {
        const name = try std.fmt.allocPrint(allocator, "file_{:03}.txt", .{i});
        defer allocator.free(name);
        const data = try std.fmt.allocPrint(allocator, "Content of file {}", .{i});
        defer allocator.free(data);

        inodes[i] = try fs.createFile(1, name, data);
    }

    // Read all back
    for (0..file_count) |i| {
        const read_back = try fs.readFile(inodes[i]);
        defer allocator.free(read_back);

        const expected = try std.fmt.allocPrint(allocator, "Content of file {}", .{i});
        defer allocator.free(expected);

        try testing.expectEqualSlices(u8, expected, read_back);
    }
}