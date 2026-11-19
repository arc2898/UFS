// UFS Allocation Group Manager
// Hybrid free space tracking: B+ tree + bitmap per allocation group

const std = @import("std");
const serialization = @import("serialization.zig");
const utils = @import("utils.zig");
const blockdev = @import("blockdev.zig");
const Allocator = std.mem.Allocator;

pub const AllocationError = error{
    OutOfSpace,
    InvalidArgument,
    CorruptedData,
    IoError,
    NotFound,
    AlreadyExists,
    AlignmentError,
    FragmentedAllocation,
    UnsupportedOperation,
};

pub const AllocationFlags = packed struct {
    contiguous: bool = false,
    zero_fill: bool = false,
    no_overwrite: bool = false,
    prefer_tail: bool = false,
};

pub const AllocationResult = struct {
    start_cluster: u64,
    cluster_count: u64,
    is_contiguous: bool,
};

// Allocation Group Header
pub const AGHeader = struct {
    magic: u32 = 0x41470000,  // "AG\0\0"
    version: u16 = 1,
    flags: u16 = 0,
    ag_index: u32 = 0,
    ag_offset: u64 = 0,       // Cluster offset of this AG
    ag_size: u32 = 0,         // Clusters in AG
    cluster_size: u32 = 0,    // Bytes per cluster
    free_clusters: u64 = 0,
    free_extents: u64 = 0,
    free_tree_root: u64 = 0,     // Block offset of free extent tree root
    bitmap_offset: u64 = 0,      // Cluster offset of allocation bitmap
    inode_table_offset: u64 = 0, // Cluster offset of inode table
    inode_count: u32 = 0,
    free_inodes: u32 = 0,
    generation: u64 = 0,
    crc32c: u32 = 0,

    pub const SIZE = 88; // 4+2+2+4+8+4+4+8+8+8+8+8+4+4+8+4

    pub fn serialize(self: AGHeader, writer: *serialization.Writer(void)) !void {
        try writer.writeU32(self.magic);
        try writer.writeU16(self.version);
        try writer.writeU16(self.flags);
        try writer.writeU32(self.ag_index);
        try writer.writeU64(self.ag_offset);
        try writer.writeU32(self.ag_size);
        try writer.writeU32(self.cluster_size);
        try writer.writeU64(self.free_clusters);
        try writer.writeU64(self.free_extents);
        try writer.writeU64(self.free_tree_root);
        try writer.writeU64(self.bitmap_offset);
        try writer.writeU64(self.inode_table_offset);
        try writer.writeU32(self.inode_count);
        try writer.writeU32(self.free_inodes);
        try writer.writeU64(self.generation);
        // CRC written separately
    }

    pub fn deserialize(reader: *serialization.Reader(void), allocator: Allocator) !AGHeader {
        const magic = try reader.readU32();
        if (magic != 0x41470000) return AllocationError.CorruptedData;
        return .{
            .magic = magic,
            .version = try reader.readU16(),
            .flags = try reader.readU16(),
            .ag_index = try reader.readU32(),
            .ag_offset = try reader.readU64(),
            .ag_size = try reader.readU32(),
            .cluster_size = try reader.readU32(),
            .free_clusters = try reader.readU64(),
            .free_extents = try reader.readU64(),
            .free_tree_root = try reader.readU64(),
            .bitmap_offset = try reader.readU64(),
            .inode_table_offset = try reader.readU64(),
            .inode_count = try reader.readU32(),
            .free_inodes = try reader.readU32(),
            .generation = try reader.readU64(),
            .crc32c = try reader.readU32(),
        };
    }

    pub fn calculateCrc32c(self: AGHeader, allocator: Allocator) !u32 {
        var writer = serialization.createWriter(allocator);
        defer writer.deinit();
        try self.serialize(&writer);
        return utils.crc32c(writer.bytes());
    }
};

// Allocation Bitmap
pub const AllocationBitmap = struct {
    const Self = @This();
    bits: []u8,
    cluster_count: u64,
    cluster_size: u32,

    pub fn init(allocator: Allocator, cluster_count: u64, cluster_size: u32) !AllocationBitmap {
        const byte_count = @as(usize, @intCast((cluster_count + 7) / 8));
        var bits = try allocator.alloc(u8, byte_count);
        @memset(bits, 0);
        return .{
            .bits = bits,
            .cluster_count = cluster_count,
            .cluster_size = cluster_size,
        };
    }

    pub fn deinit(self: *Self, allocator: Allocator) void {
        allocator.free(self.bits);
        self.bits = &[_]u8{};
    }

    pub fn loadFromDevice(
        allocator: Allocator,
        device: *blockdev.BlockDevice,
        bitmap_offset: u64,
        cluster_count: u64,
        cluster_size: u32,
    ) !AllocationBitmap {
        const byte_count = @as(usize, @intCast((cluster_count + 7) / 8));
        const cluster_count_bytes = (byte_count + cluster_size - 1) / cluster_size * cluster_size;
        var buffer = try allocator.alloc(u8, cluster_count_bytes);
        defer allocator.free(buffer);

        try device.read(bitmap_offset * cluster_size, buffer[0..byte_count]);

        return .{
            .bits = buffer[0..byte_count],
            .cluster_count = cluster_count,
            .cluster_size = cluster_size,
        };
    }

    pub fn writeToDevice(
        self: *Self,
        device: *blockdev.BlockDevice,
        bitmap_offset: u64,
        cluster_size: u32,
    ) !void {
        const byte_count = @as(usize, @intCast((self.cluster_count + 7) / 8));
        try device.write(bitmap_offset * cluster_size, self.bits[0..byte_count]);
    }

    pub fn isAllocated(self: AllocationBitmap, cluster: u64) bool {
        if (cluster >= self.cluster_count) return true;
        const byte_index = @as(usize, @intCast(cluster / 8));
        const bit_index = @as(u8, @intCast(cluster % 8));
        return (self.bits[byte_index] & (1 << bit_index)) != 0;
    }

    pub fn setAllocated(self: *Self, cluster: u64, allocated: bool) void {
        if (cluster >= self.cluster_count) return;
        const byte_index = @as(usize, @intCast(cluster / 8));
        const bit_index = @as(u8, @intCast(cluster % 8));
        if (allocated) {
            self.bits[byte_index] |= (1 << bit_index);
        } else {
            self.bits[byte_index] &= ~(1 << bit_index);
        }
    }

    pub fn findFree(self: AllocationBitmap, start: u64, count: u64) ?u64 {
        var current_start: ?u64 = null;
        var current_count: u64 = 0;

        for (start..@min(start + count, self.cluster_count)) |i| {
            if (!self.isAllocated(i)) {
                if (current_start == null) current_start = i;
                current_count += 1;
            } else {
                if (current_count > 0) {
                    return current_start;
                }
                current_start = null;
                current_count = 0;
            }
        }

        if (current_count > 0) return current_start;
        return null;
    }

    pub fn findFreeExtent(self: AllocationBitmap, min_length: u64, max_length: u64, start_hint: u64) ?struct { start: u64, length: u64 } {
        var best_start: ?u64 = null;
        var best_length: u64 = 0;

        var i: u64 = start_hint;
        while (i < self.cluster_count) {
            if (!self.isAllocated(i)) {
                var length: u64 = 1;
                var j = i + 1;
                while (j < self.cluster_count and !self.isAllocated(j) and length < max_length) {
                    length += 1;
                    j += 1;
                }
                if (length >= min_length) {
                    if (best_start == null or length > best_length) {
                        best_start = i;
                        best_length = length;
                        if (best_length >= max_length) break;
                    }
                }
                i = j;
            } else {
                i += 1;
            }
        }

        if (best_start) |start| return .{ .start = start, .length = best_length };
        return null;
    }

    pub fn countFree(self: AllocationBitmap) u64 {
        var count: u64 = 0;
        for (self.bits) |byte| {
            count += @popCount(byte);
        }
        return self.cluster_count - count;
    }
};

// Free Extent Tree (B+ Tree) - per AG
pub const FreeExtentTree = struct {
    const Self = @This();
    const Node = struct {
        magic: u32 = 0x46524500, // "FRE\0"
        version: u16 = 1,
        flags: u16 = 0,
        entry_count: u16 = 0,
        max_entries: u16 = 0,
        is_leaf: u16 = 0,
        level: u16 = 0,
        entries: []FreeExtentEntry,
        crc32c: u32 = 0,

        pub const FreeExtentEntry = struct {
            key: u64,     // start cluster (leaf) / max child key (internal)
            value: u64,   // length (leaf) / child node block (internal)
        };
    };

    root_block: u64 = 0,
    cluster_size: u32 = 4096,
    max_entries_per_node: u16 = 0,
    device: *blockdev.BlockDevice,
    allocator: Allocator,

    pub fn init(device: *blockdev.BlockDevice, cluster_size: u32, allocator: Allocator) !FreeExtentTree {
        const entry_size = 16; // 8 + 8
        const header_size = 16; // magic + version + flags + entry_count + max_entries + is_leaf + level + crc32c
        const max_entries = (cluster_size - header_size) / entry_size;

        return .{
            .cluster_size = cluster_size,
            .max_entries_per_node = @as(u16, @intCast(max_entries)),
            .device = device,
            .allocator = allocator,
        };
    }

    pub fn createRoot(self: *Self, block: u64) !void {
        var node = Node{
            .magic = 0x46524500,
            .version = 1,
            .flags = 0,
            .entry_count = 0,
            .max_entries = self.max_entries_per_node,
            .is_leaf = 1,
            .level = 0,
            .entries = &[_]Node.FreeExtentEntry{},
            .crc32c = 0,
        };
        try self.writeNode(block, &node);
        self.root_block = block;
    }

    pub fn loadRoot(self: *Self, block: u64) !void {
        self.root_block = block;
    }

    fn writeNode(self: *Self, block: u64, node: *Node) !void {
        var writer = serialization.createWriter(self.allocator);
        defer writer.deinit();

        try writer.writeU32(node.magic);
        try writer.writeU16(node.version);
        try writer.writeU16(node.flags);
        try writer.writeU16(node.entry_count);
        try writer.writeU16(node.max_entries);
        try writer.writeU16(node.is_leaf);
        try writer.writeU16(node.level);

        for (node.entries) |entry| {
            try writer.writeU64(entry.key);
            try writer.writeU64(entry.value);
        }

        // Pad to cluster size
        try writer.align(self.cluster_size as usize);

        const crc = utils.crc32c(writer.bytes());
        try writer.writeU32(crc);

        try self.device.write(block * self.cluster_size, writer.bytes());
    }

    fn readNode(self: *Self, block: u64) !Node {
        var buffer = try self.allocator.alloc(u8, self.cluster_size as usize);
        defer self.allocator.free(buffer);

        try self.device.read(block * self.cluster_size, buffer);

        var reader = serialization.createReader(buffer);
        const magic = try reader.readU32();
        if (magic != 0x46524500) return AllocationError.CorruptedData;

        const node = Node{
            .magic = magic,
            .version = try reader.readU16(),
            .flags = try reader.readU16(),
            .entry_count = try reader.readU16(),
            .max_entries = try reader.readU16(),
            .is_leaf = try reader.readU16(),
            .level = try reader.readU16(),
            .entries = try self.readEntries(&reader, node.entry_count),
            .crc32c = try reader.readU32(),
        };

        // Verify CRC
        const data = buffer[0..reader.offset-4];
        const actual_crc = utils.crc32c(data);
        if (actual_crc != node.crc32c) return AllocationError.CorruptedData;

        return node;
    }

    fn readEntries(self: *Self, reader: *serialization.Reader(void), count: u16) ![]Node.FreeExtentEntry {
        var entries = try self.allocator.alloc(Node.FreeExtentEntry, count);
        for (entries, 0..) |*entry, i| {
            _ = i;
            entry.key = try reader.readU64();
            entry.value = try reader.readU64();
        }
        return entries;
    }

    pub fn insert(self: *Self, start: u64, length: u64) !void {
        if (self.root_block == 0) {
            // Create new root
            try self.allocateNewRoot(start, length);
            return;
        }

        var ctx = InsertContext{
            .tree = self,
            .start = start,
            .length = length,
            .split_key = 0,
            .split_value = 0,
            .split_child = 0,
            .needs_split = false,
        };
        try ctx.insertRecursive(self.root_block);

        if (ctx.needs_split) {
            // Root split - create new root
            try self.handleRootSplit(ctx.split_key, ctx.split_value, ctx.split_child);
        }
    }

    pub fn remove(self: *Self, start: u64, length: u64) !void {
        if (self.root_block == 0) return;

        var ctx = RemoveContext{
            .tree = self,
            .start = start,
            .length = length,
            .needs_merge = false,
            .merge_key = 0,
            .removed = false,
        };
        try ctx.removeRecursive(self.root_block);

        if (ctx.needs_merge && self.root_block != 0) {
            // Check if root is empty internal node
            try self.maybeCollapseRoot();
        }
    }

    pub fn findExtent(self: *Self, min_length: u64) ?struct { start: u64, length: u64 } {
        if (self.root_block == 0) return null;

        var best: ?struct { start: u64, length: u64 } = null;
        var current_block = self.root_block;

        while (current_block != 0) {
            const node = try self.readNode(current_block);

            if (node.is_leaf == 1) {
                // Search leaf for best fit
                for (node.entries) |entry| {
                    if (entry.value >= min_length) {
                        if (best == null || entry.value < best.?.length) {
                            best = .{ .start = entry.key, .length = entry.value };
                        }
                    }
                }
                return best;
            } else {
                // Internal node - find rightmost child that could have extent >= min_length
                // Since we don't store min/max in internal nodes, we search all children
                // In a full implementation, internal nodes would store subtree max length
                var child_block: u64 = 0;
                for (node.entries) |entry| {
                    // For now, just take the rightmost child
                    child_block = entry.value;
                }
                current_block = child_block;
            }
        }

        return best;
    }

    // Internal helper methods for B+ tree operations
    fn allocateNewRoot(self: *Self, start: u64, length: u64) !void {
        // Allocate a new block for root
        const root_block = try self.allocateMetaBlock();
        var node = Node{
            .magic = 0x46524500,
            .version = 1,
            .flags = 0,
            .entry_count = 1,
            .max_entries = self.max_entries_per_node,
            .is_leaf = 1,
            .level = 0,
            .entries = try self.allocator.alloc(Node.FreeExtentEntry, 1),
            .crc32c = 0,
        };
        node.entries[0] = .{ .key = start, .value = length };
        try self.writeNode(root_block, &node);
        self.root_block = root_block;
    }

    fn allocateMetaBlock(self: *Self) !u64 {
        // In a real implementation, this would use the superblock's meta allocator
        // For now, we'll use a simple counter - this needs to be replaced with actual allocation
        // This is a placeholder - the actual allocator should come from the AG manager
        return 1; // Placeholder
    }

    fn handleRootSplit(self: *Self, split_key: u64, split_value: u64, split_child: u64) !void {
        const old_root = self.root_block;
        const new_root = try self.allocateMetaBlock();

        // Create new internal root node
        var new_root_node = Node{
            .magic = 0x46524500,
            .version = 1,
            .flags = 0,
            .entry_count = 2,
            .max_entries = self.max_entries_per_node,
            .is_leaf = 0,
            .level = 1,
            .entries = try self.allocator.alloc(Node.FreeExtentEntry, 2),
            .crc32c = 0,
        };

        // Read old root to get its max key
        const old_root_node = try self.readNode(old_root);
        var max_key: u64 = 0;
        for (old_root_node.entries) |entry| {
            if (entry.key > max_key) max_key = entry.key;
        }

        new_root_node.entries[0] = .{ .key = max_key, .value = old_root };
        new_root_node.entries[1] = .{ .key = split_key, .value = split_child };

        try self.writeNode(new_root, &new_root_node);
        self.root_block = new_root;
    }

    fn maybeCollapseRoot(self: *Self) !void {
        if (self.root_block == 0) return;
        const root = try self.readNode(self.root_block);
        if (root.is_leaf == 0 && root.entry_count == 1) {
            // Root has only one child - collapse
            self.root_block = root.entries[0].value;
        }
    }

    pub fn countExtents(self: *Self) u64 {
        if (self.root_block == 0) return 0;
        var count: u64 = 0;
        // Walk the tree and count leaf entries
        var stack = std.ArrayList(u64).init(self.allocator);
        defer stack.deinit();
        try stack.append(self.root_block);

        while (stack.items.len > 0) {
            const block = stack.items[stack.items.len - 1];
            _ = stack.pop();
            const node = try self.readNode(block);
            if (node.is_leaf == 1) {
                count += node.entry_count;
            } else {
                for (node.entries) |entry| {
                    try stack.append(entry.value);
                }
            }
        }
        return count;
    }
};

// Context for insert operation
const InsertContext = struct {
    const Self = @This();
    tree: *FreeExtentTree,
    start: u64,
    length: u64,
    split_key: u64,
    split_value: u64,
    split_child: u64,
    needs_split: bool,

    fn insertRecursive(self: *Self, block: u64) !void {
        var node = try self.tree.readNode(block);

        if (node.is_leaf == 1) {
            try self.insertIntoLeaf(block, &node);
        } else {
            try self.insertIntoInternal(block, &node);
        }
    }

    fn insertIntoLeaf(self: *Self, block: u64, node: *FreeExtentTree.Node) !void {
        // Find insert position (keep sorted by key)
        var insert_pos = node.entry_count;
        for (node.entries[0..node.entry_count], 0..) |entry, i| {
            if (self.start < entry.key) {
                insert_pos = @as(u16, @intCast(i));
                break;
            }
        }

        // Check if we need to split
        if (node.entry_count >= node.max_entries) {
            try self.splitLeaf(block, node, insert_pos);
            return;
        }

        // Shift entries and insert
        var new_entries = try self.tree.allocator.alloc(FreeExtentTree.Node.FreeExtentEntry, node.entry_count + 1);
        defer self.tree.allocator.free(new_entries);

        var j: u16 = 0;
        for (node.entries[0..node.entry_count], 0..) |entry, i| {
            if (@as(u16, @intCast(i)) == insert_pos) {
                new_entries[j] = .{ .key = self.start, .value = self.length };
                j += 1;
            }
            new_entries[j] = entry;
            j += 1;
        }
        if (insert_pos == node.entry_count) {
            new_entries[j] = .{ .key = self.start, .value = self.length };
        }

        self.tree.allocator.free(node.entries);
        node.entries = new_entries;
        node.entry_count += 1;
        try self.tree.writeNode(block, node);
    }

    fn splitLeaf(self: *Self, block: u64, node: *FreeExtentTree.Node, insert_pos: u16) !void {
        // Create new leaf node
        const new_block = try self.tree.allocateMetaBlock();
        var new_node = FreeExtentTree.Node{
            .magic = 0x46524500,
            .version = 1,
            .flags = 0,
            .entry_count = 0,
            .max_entries = node.max_entries,
            .is_leaf = 1,
            .level = 0,
            .entries = try self.tree.allocator.alloc(FreeExtentTree.Node.FreeExtentEntry, node.max_entries),
            .crc32c = 0,
        };

        // Combine old entries + new entry, then split in middle
        const total = node.entry_count + 1;
        const mid = total / 2;

        var all_entries = try self.tree.allocator.alloc(FreeExtentTree.Node.FreeExtentEntry, total);
        defer self.tree.allocator.free(all_entries);

        var idx: u16 = 0;
        for (node.entries[0..node.entry_count], 0..) |entry, i| {
            if (@as(u16, @intCast(i)) == insert_pos) {
                all_entries[idx] = .{ .key = self.start, .value = self.length };
                idx += 1;
            }
            all_entries[idx] = entry;
            idx += 1;
        }
        if (insert_pos == node.entry_count) {
            all_entries[idx] = .{ .key = self.start, .value = self.length };
        }

        // Split
        node.entry_count = mid;
        self.tree.allocator.free(node.entries);
        node.entries = try self.tree.allocator.alloc(FreeExtentTree.Node.FreeExtentEntry, mid);
        for (0..mid) |i| {
            node.entries[i] = all_entries[i];
        }

        new_node.entry_count = total - mid;
        for (0..new_node.entry_count) |i| {
            new_node.entries[i] = all_entries[mid + i];
        }

        // Write both nodes
        try self.tree.writeNode(block, node);
        try self.tree.writeNode(new_block, &new_node);

        // Propagate split up
        self.split_key = new_node.entries[new_node.entry_count - 1].key;
        self.split_value = 0; // Not used for leaf
        self.split_child = new_block;
        self.needs_split = true;
    }

    fn insertIntoInternal(self: *Self, block: u64, node: *FreeExtentTree.Node) !void {
        // Find child to descend into
        var child_idx: u16 = node.entry_count;
        for (node.entries[0..node.entry_count], 0..) |entry, i| {
            if (self.start <= entry.key) {
                child_idx = @as(u16, @intCast(i));
                break;
            }
        }

        const child_block = node.entries[child_idx].value;
        try self.insertRecursive(child_block);

        if (self.needs_split) {
            // Child was split, need to add new entry to this node
            try self.addToInternal(block, node, child_idx);
        }
    }

    fn addToInternal(self: *Self, block: u64, node: *FreeExtentTree.Node, child_idx: u16) !void {
        if (node.entry_count >= node.max_entries) {
            try self.splitInternal(block, node, child_idx);
            return;
        }

        // Shift and insert
        var new_entries = try self.tree.allocator.alloc(FreeExtentTree.Node.FreeExtentEntry, node.entry_count + 1);
        defer self.tree.allocator.free(new_entries);

        var j: u16 = 0;
        for (node.entries[0..node.entry_count], 0..) |entry, i| {
            if (@as(u16, @intCast(i)) == child_idx + 1) {
                new_entries[j] = .{ .key = self.split_key, .value = self.split_child };
                j += 1;
            }
            new_entries[j] = entry;
            j += 1;
        }
        if (child_idx + 1 == node.entry_count) {
            new_entries[j] = .{ .key = self.split_key, .value = self.split_child };
        }

        self.tree.allocator.free(node.entries);
        node.entries = new_entries;
        node.entry_count += 1;

        // Update keys in this node (max key of each child)
        self.updateInternalKeys(node);

        try self.tree.writeNode(block, node);
        self.needs_split = false;
    }

    fn splitInternal(self: *Self, block: u64, node: *FreeExtentTree.Node, child_idx: u16) !void {
        // Add the new entry first, then split
        const total = node.entry_count + 1;
        const mid = total / 2;

        var all_entries = try self.tree.allocator.alloc(FreeExtentTree.Node.FreeExtentEntry, total);
        defer self.tree.allocator.free(all_entries);

        var idx: u16 = 0;
        for (node.entries[0..node.entry_count], 0..) |entry, i| {
            if (@as(u16, @intCast(i)) == child_idx + 1) {
                all_entries[idx] = .{ .key = self.split_key, .value = self.split_child };
                idx += 1;
            }
            all_entries[idx] = entry;
            idx += 1;
        }
        if (child_idx + 1 == node.entry_count) {
            all_entries[idx] = .{ .key = self.split_key, .value = self.split_child };
        }

        // Create new internal node
        const new_block = try self.tree.allocateMetaBlock();
        var new_node = FreeExtentTree.Node{
            .magic = 0x46524500,
            .version = 1,
            .flags = 0,
            .entry_count = 0,
            .max_entries = node.max_entries,
            .is_leaf = 0,
            .level = node.level,
            .entries = try self.tree.allocator.alloc(FreeExtentTree.Node.FreeExtentEntry, node.max_entries),
            .crc32c = 0,
        };

        // Split
        node.entry_count = mid;
        self.tree.allocator.free(node.entries);
        node.entries = try self.tree.allocator.alloc(FreeExtentTree.Node.FreeExtentEntry, mid);
        for (0..mid) |i| {
            node.entries[i] = all_entries[i];
        }

        new_node.entry_count = total - mid;
        for (0..new_node.entry_count) |i| {
            new_node.entries[i] = all_entries[mid + i];
        }

        // Update keys
        self.updateInternalKeys(node);
        self.updateInternalKeys(&new_node);

        // Write both
        try self.tree.writeNode(block, node);
        try self.tree.writeNode(new_block, &new_node);

        // Propagate split up
        self.split_key = new_node.entries[new_node.entry_count - 1].key;
        self.split_child = new_block;
        self.needs_split = true;
    }

    fn updateInternalKeys(self: *Self, node: *FreeExtentTree.Node) void {
        for (node.entries[0..node.entry_count], 0..) |*entry, i| {
            if (i + 1 < node.entry_count) {
                entry.key = node.entries[i + 1].key;
            } else {
                // Last entry - max key in subtree
                // For simplicity, use the child's max key
                // In a real implementation, we'd read the child's max key
                entry.key = entry.value; // Placeholder
            }
        }
    }
};

// Context for remove operation
const RemoveContext = struct {
    const Self = @This();
    tree: *FreeExtentTree,
    start: u64,
    length: u64,
    needs_merge: bool,
    merge_key: u64,
    removed: bool,

    fn removeRecursive(self: *Self, block: u64) !void {
        var node = try self.tree.readNode(block);

        if (node.is_leaf == 1) {
            try self.removeFromLeaf(block, &node);
        } else {
            try self.removeFromInternal(block, &node);
        }
    }

    fn removeFromLeaf(self: *Self, block: u64, node: *FreeExtentTree.Node) !void {
        // Find the extent to remove
        var found_idx: ?u16 = null;
        for (node.entries[0..node.entry_count], 0..) |entry, i| {
            if (entry.key == self.start && entry.value == self.length) {
                found_idx = @as(u16, @intCast(i));
                break;
            }
        }

        if (found_idx == null) return; // Not found

        // Remove entry
        var new_count = node.entry_count - 1;
        if (new_count == 0) {
            // Node becomes empty - mark for merge
            self.tree.allocator.free(node.entries);
            node.entries = &[_]FreeExtentTree.Node.FreeExtentEntry{};
            node.entry_count = 0;
            try self.tree.writeNode(block, node);
            self.needs_merge = true;
            self.merge_key = self.start;
            return;
        }

        var new_entries = try self.tree.allocator.alloc(FreeExtentTree.Node.FreeExtentEntry, new_count);
        defer self.tree.allocator.free(new_entries);

        var j: u16 = 0;
        for (node.entries[0..node.entry_count], 0..) |entry, i| {
            if (@as(u16, @intCast(i)) != found_idx.?) {
                new_entries[j] = entry;
                j += 1;
            }
        }

        self.tree.allocator.free(node.entries);
        node.entries = new_entries;
        node.entry_count = new_count;
        try self.tree.writeNode(block, node);
        self.removed = true;

        // Check if we need to merge (below minimum fill factor)
        const min_entries = node.max_entries / 2;
        if (node.entry_count < min_entries) {
            self.needs_merge = true;
            self.merge_key = node.entries[0].key;
        }
    }

    fn removeFromInternal(self: *Self, block: u64, node: *FreeExtentTree.Node) !void {
        // Find child
        var child_idx: u16 = node.entry_count;
        for (node.entries[0..node.entry_count], 0..) |entry, i| {
            if (self.start <= entry.key) {
                child_idx = @as(u16, @intCast(i));
                break;
            }
        }

        const child_block = node.entries[child_idx].value;
        try self.removeRecursive(child_block);

        if (self.needs_merge) {
            // Child was merged or became empty
            try self.handleChildMerge(block, node, child_idx);
        }
    }

    fn handleChildMerge(self: *Self, block: u64, node: *FreeExtentTree.Node, child_idx: u16) !void {
        // For simplicity, we just remove the child entry
        // A full implementation would redistribute or merge with sibling
        if (node.entry_count <= 1) {
            // This internal node would become empty
            self.needs_merge = true;
            return;
        }

        // Remove the child entry
        var new_count = node.entry_count - 1;
        var new_entries = try self.tree.allocator.alloc(FreeExtentTree.Node.FreeExtentEntry, new_count);
        defer self.tree.allocator.free(new_entries);

        var j: u16 = 0;
        for (node.entries[0..node.entry_count], 0..) |entry, i| {
            if (@as(u16, @intCast(i)) != child_idx) {
                new_entries[j] = entry;
                j += 1;
            }
        }

        self.tree.allocator.free(node.entries);
        node.entries = new_entries;
        node.entry_count = new_count;
        self.updateInternalKeys(node);
        try self.tree.writeNode(block, node);
        self.needs_merge = false;
    }

    fn updateInternalKeys(self: *Self, node: *FreeExtentTree.Node) void {
        for (node.entries[0..node.entry_count], 0..) |*entry, i| {
            if (i + 1 < node.entry_count) {
                entry.key = node.entries[i + 1].key;
            }
        }
    }
};

// Allocation Group Manager
pub const AllocationGroupManager = struct {
    const Self = @This();
    device: *blockdev.BlockDevice,
    cluster_size: u32,
    ag_count: u32,
    ag_size: u64,
    ag_table_offset: u64,
    first_ag_offset: u64,
    groups: []AllocationGroup,
    allocator: Allocator,

    pub const AllocationGroup = struct {
        header: AGHeader,
        bitmap: AllocationBitmap,
        free_tree: FreeExtentTree,
        inode_bitmap: AllocationBitmap,
        loaded: bool = false,
    };

    pub fn init(
        device: *blockdev.BlockDevice,
        cluster_size: u32,
        ag_count: u32,
        ag_size: u64,
        ag_table_offset: u64,
        first_ag_offset: u64,
        allocator: Allocator,
    ) !AllocationGroupManager {
        var groups = try allocator.alloc(AllocationGroup, ag_count);
        for (groups, 0..) |*g, i| {
            _ = i;
            g.* = AllocationGroup{
                .header = AGHeader{},
                .bitmap = AllocationBitmap{},
                .free_tree = FreeExtentTree{},
                .inode_bitmap = AllocationBitmap{},
                .loaded = false,
            };
        }

        return .{
            .device = device,
            .cluster_size = cluster_size,
            .ag_count = ag_count,
            .ag_size = ag_size,
            .ag_table_offset = ag_table_offset,
            .first_ag_offset = first_ag_offset,
            .groups = groups,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.groups) |*g| {
            if (g.loaded) {
                g.bitmap.deinit(self.allocator);
                g.inode_bitmap.deinit(self.allocator);
            }
        }
        self.allocator.free(self.groups);
    }

    pub fn loadAG(self: *Self, ag_index: u32) !void {
        if (ag_index >= self.ag_count) return AllocationError.InvalidArgument;
        var ag = &self.groups[ag_index];
        if (ag.loaded) return;

        const ag_offset = self.first_ag_offset + ag_index * self.ag_size;

        // Read AG header
        var header_buf = try self.allocator.alloc(u8, self.cluster_size as usize);
        defer self.allocator.free(header_buf);
        try self.device.read(ag_offset * self.cluster_size, header_buf);

        var reader = serialization.createReader(header_buf);
        ag.header = try AGHeader.deserialize(&reader, self.allocator);

        // Load allocation bitmap
        const bitmap_clusters = (ag.header.ag_size + 7) / 8 + self.cluster_size - 1 / self.cluster_size;
        ag.bitmap = try AllocationBitmap.loadFromDevice(
            self.allocator,
            self.device,
            ag.header.bitmap_offset,
            ag.header.ag_size,
            self.cluster_size,
        );

        // Load inode bitmap
        const inode_bitmap_bytes = (ag.header.inode_count + 7) / 8;
        const inode_bitmap_clusters = (inode_bitmap_bytes + self.cluster_size - 1) / self.cluster_size;
        ag.inode_bitmap = try AllocationBitmap.loadFromDevice(
            self.allocator,
            self.device,
            ag.header.inode_table_offset - inode_bitmap_clusters, // Before inode table
            ag.header.inode_count,
            self.cluster_size,
        );

        // Load free extent tree
        ag.free_tree = try FreeExtentTree.init(self.device, self.cluster_size, self.allocator);
        if (ag.header.free_tree_root != 0) {
            ag.free_tree.loadRoot(ag.header.free_tree_root);
        }

        ag.loaded = true;
    }

    pub fn unloadAG(self: *Self, ag_index: u32) !void {
        if (ag_index >= self.ag_count) return AllocationError.InvalidArgument;
        var ag = &self.groups[ag_index];
        if (!ag.loaded) return;

        // Write back AG header
        var writer = serialization.createWriter(self.allocator);
        defer writer.deinit();
        try ag.header.serialize(&writer);
        try writer.align(self.cluster_size as usize);
        const crc = utils.crc32c(writer.bytes());
        try writer.writeU32(crc);

        try self.device.write((self.first_ag_offset + ag_index * self.ag_size) * self.cluster_size, writer.bytes());

        // Write back bitmaps
        try ag.bitmap.writeToDevice(self.device, ag.header.bitmap_offset, self.cluster_size);
        try ag.inode_bitmap.writeToDevice(self.device, ag.header.inode_table_offset - 1, self.cluster_size);

        ag.bitmap.deinit(self.allocator);
        ag.inode_bitmap.deinit(self.allocator);
        ag.loaded = false;
    }

    pub fn allocateClusters(self: *Self, count: u64, flags: AllocationFlags) !AllocationResult {
        // Try each AG in round-robin or by free space
        for (0..self.ag_count) |i| {
            try self.loadAG(i);
            var ag = &self.groups[i];
            if (ag.header.free_clusters >= count) {
                // Try bitmap first for small allocations
                if (count <= 64) {
                    if (ag.bitmap.findFree(0, ag.header.ag_size)) |start| {
                        // Mark allocated
                        for (start..start + count) |c| {
                            ag.bitmap.setAllocated(c, true);
                        }
                        ag.header.free_clusters -= count;
                        ag.header.free_extents -= 1;
                        ag.header.generation += 1;
                        return .{
                            .start_cluster = ag.header.ag_offset + start,
                            .cluster_count = count,
                            .is_contiguous = true,
                        };
                    }
                }

                // Try free extent tree for larger allocations
                if (ag.free_tree.findExtent(count)) |extent| {
                    try ag.free_tree.remove(extent.start, extent.length);
                    // Mark allocated in bitmap
                    for (extent.start..extent.start + count) |c| {
                        ag.bitmap.setAllocated(c, true);
                    }
                    ag.header.free_clusters -= count;
                    ag.header.free_extents -= 1;
                    ag.header.generation += 1;
                    return .{
                        .start_cluster = ag.header.ag_offset + extent.start,
                        .cluster_count = count,
                        .is_contiguous = true,
                    };
                }
            }
        }

        return AllocationError.OutOfSpace;
    }

    pub fn freeClusters(self: *Self, start_cluster: u64, count: u64) !void {
        // Find which AG this belongs to
        for (0..self.ag_count) |i| {
            try self.loadAG(i);
            var ag = &self.groups[i];
            const ag_start = ag.header.ag_offset;
            const ag_end = ag_start + ag.header.ag_size;

            if (start_cluster >= ag_start and start_cluster + count <= ag_end) {
                const local_start = start_cluster - ag_start;
                // Mark free in bitmap
                for (local_start..local_start + count) |c| {
                    ag.bitmap.setAllocated(c, false);
                }
                ag.header.free_clusters += count;
                ag.header.free_extents += 1;
                ag.header.generation += 1;

                // Add to free extent tree
                try ag.free_tree.insert(local_start, count);
                return;
            }
        }
        return AllocationError.NotFound;
    }

    pub fn allocateInode(self: *Self, ag_index: u32) !u32 {
        try self.loadAG(ag_index);
        var ag = &self.groups[ag_index];

        if (ag.header.free_inodes == 0) return AllocationError.OutOfSpace;

        for (0..ag.header.inode_count) |i| {
            if (!ag.inode_bitmap.isAllocated(i)) {
                ag.inode_bitmap.setAllocated(i, true);
                ag.header.free_inodes -= 1;
                ag.header.generation += 1;
                return i;
            }
        }

        return AllocationError.OutOfSpace;
    }

    pub fn freeInode(self: *Self, ag_index: u32, inode_index: u32) !void {
        try self.loadAG(ag_index);
        var ag = &self.groups[ag_index];

        if (inode_index >= ag.header.inode_count) return AllocationError.InvalidArgument;

        ag.inode_bitmap.setAllocated(inode_index, false);
        ag.header.free_inodes += 1;
        ag.header.generation += 1;
    }

    pub fn getAGInfo(self: *Self, ag_index: u32) !struct {
        free_clusters: u64,
        free_extents: u64,
        free_inodes: u32,
        total_clusters: u32,
        total_inodes: u32,
    } {
        try self.loadAG(ag_index);
        var ag = &self.groups[ag_index];
        return .{
            .free_clusters = ag.header.free_clusters,
            .free_extents = ag.header.free_extents,
            .free_inodes = ag.header.free_inodes,
            .total_clusters = ag.header.ag_size,
            .total_inodes = ag.header.inode_count,
        };
    }
};

// Global allocator that spans all AGs
pub const GlobalAllocator = struct {
    const Self = @This();
    ag_manager: AllocationGroupManager,
    next_ag_hint: u32 = 0,

    pub fn allocate(self: *Self, count: u64, flags: AllocationFlags) !AllocationResult {
        const start_hint = self.next_ag_hint;
        for (0..self.ag_manager.ag_count) |i| {
            const ag_index = (start_hint + i) % self.ag_manager.ag_count;
            try self.ag_manager.loadAG(ag_index);
            var ag = &self.ag_manager.groups[ag_index];
            if (ag.header.free_clusters >= count) {
                const result = try self.ag_manager.allocateClusters(count, flags);
                self.next_ag_hint = (ag_index + 1) % self.ag_manager.ag_count;
                return result;
            }
        }
        return AllocationError.OutOfSpace;
    }

    pub fn free(self: *Self, start_cluster: u64, count: u64) !void {
        try self.ag_manager.freeClusters(start_cluster, count);
    }

    pub fn getFreeSpace(self: *Self) u64 {
        var total: u64 = 0;
        for (0..self.ag_manager.ag_count) |i| {
            try self.ag_manager.loadAG(i);
            total += self.ag_manager.groups[i].header.free_clusters;
        }
        return total * self.ag_manager.cluster_size;
    }
};