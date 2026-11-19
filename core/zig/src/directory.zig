// UFS Directory Implementation
// Hybrid indexing: Linear (≤64 entries) + B+ tree (>64)
// Case-insensitive with case-preservation, Windows reserved name handling

const std = @import("std");
const serialization = @import("serialization.zig");
const utils = @import("utils.zig");
const metadata = @import("metadata.zig");
const allocation = @import("allocation.zig");
const Allocator = std.mem.Allocator;

pub const DirectoryError = error{
    NotFound,
    AlreadyExists,
    NotDirectory,
    IsDirectory,
    DirectoryNotEmpty,
    InvalidName,
    ReservedName,
    CaseCollision,
    IoError,
    CorruptedData,
    OutOfSpace,
    UnsupportedOperation,
};

pub const DirFlags = packed struct {
    case_insensitive: bool = true,
    case_preserving: bool = true,
    windows_compat: bool = true,
};

pub const DirEntry = struct {
    inode: u64 = 0,
    name: []const u8 = &[_]u8{},
    file_type: u8 = 0,
    flags: u8 = 0,

    pub const FILE_TYPE_REG = 1;
    pub const FILE_TYPE_DIR = 2;
    pub const FILE_TYPE_SYMLINK = 3;
    pub const FILE_TYPE_CHRDEV = 4;
    pub const FILE_TYPE_BLKDEV = 5;
    pub const FILE_TYPE_FIFO = 6;
    pub const FILE_TYPE_SOCKET = 7;
    pub const FILE_TYPE_REPARSE = 8;

    pub fn serialize(self: DirEntry, writer: *serialization.Writer(void)) !void {
        try writer.writeU64(self.inode);
        try writer.writeU16(@as(u16, @intCast(self.name.len)));
        try writer.writeU8(self.file_type);
        try writer.writeU8(self.flags);
        try writer.writeBytes(self.name);
        // Pad to 8-byte boundary
        const padding = (8 - (writer.buffer.items.len % 8)) % 8;
        for (0..padding) |_| {
            try writer.writeU8(0);
        }
    }

    pub fn deserialize(reader: *serialization.Reader(void), allocator: Allocator) !DirEntry {
        const inode = try reader.readU64();
        const name_length = try reader.readU16();
        const file_type = try reader.readU8();
        const flags = try reader.readU8();
        const name = try reader.readBytes(@as(usize, @intCast(name_length)));
        // Skip padding
        const padding = (8 - (reader.offset % 8)) % 8;
        reader.offset += padding;

        return .{
            .inode = inode,
            .name = name,
            .file_type = file_type,
            .flags = flags,
        };
    }

    pub fn calculateSize(self: DirEntry) usize {
        var size = 8 + 2 + 1 + 1 + self.name.len; // inode + name_len + file_type + flags + name
        size = (size + 7) & ~7; // Align to 8 bytes
        return size;
    }
};

// Case folding using Unicode 15.0 (simplified - use ICU in production)
pub const CaseFolder = struct {
    // Simple ASCII case folding for now
    pub fn fold(c: u8) u8 {
        if (c >= 'A' and c <= 'Z') return c + 32;
        return c;
    }

    pub fn foldString(allocator: Allocator, str: []const u8) ![]u8 {
        var result = std.ArrayList(u8).init(allocator);
        for (str) |c| {
            try result.append(fold(c));
        }
        return result.toOwnedSlice();
    }

    pub fn equalsIgnoreCase(a: []const u8, b: []const u8) bool {
        if (a.len != b.len) return false;
        for (a, b) |ac, bc| {
            if (fold(ac) != fold(bc)) return false;
        }
        return true;
    }

    pub fn compareIgnoreCase(a: []const u8, b: []const u8) i32 {
        const min_len = @min(a.len, b.len);
        for (0..min_len) |i| {
            const fa = fold(a[i]);
            const fb = fold(b[i]);
            if (fa < fb) return -1;
            if (fa > fb) return 1;
        }
        return @as(i32, @intCast(a.len)) - @as(i32, @intCast(b.len));
    }

    pub fn hashFNV1a(str: []const u8) u64 {
        var hash: u64 = 0xcbf29ce484222325;
        for (str) |c| {
            hash ^= fold(c);
            hash *= 0x100000001b3;
        }
        return hash;
    }
};

// Windows reserved names
pub const WindowsReservedNames = struct {
    const names = [_][]const u8{
        "CON", "PRN", "AUX", "NUL",
        "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
        "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
    };

    pub fn isReserved(name: []const u8) bool {
        // Check base name (before first dot)
        var base_name = name;
        if (name.find('.')) |dot| {
            base_name = name[0..dot];
        }

        for (names) |reserved| {
            if (CaseFolder.equalsIgnoreCase(base_name, reserved)) return true;
        }
        return false;
    }

    pub fn validate(name: []const u8) !void {
        if (isReserved(name)) return DirectoryError.ReservedName;

        // Check for trailing dots/spaces (Windows doesn't allow)
        if (name.len > 0) {
            const last = name[name.len - 1];
            if (last == '.' or last == ' ') return DirectoryError.InvalidName;
        }
    }
};

// Linear directory (≤64 entries, stored inline)
pub const LinearDirectory = struct {
    const Self = @This();
    entries: std.ArrayList(DirEntry),
    max_entries: usize = 64,
    allocator: Allocator,
    case_insensitive: bool = true,

    pub fn init(allocator: Allocator, max_entries: usize) LinearDirectory {
        return .{
            .entries = std.ArrayList(DirEntry).init(allocator),
            .max_entries = max_entries,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.name);
        }
        self.entries.deinit();
    }

    pub fn find(self: LinearDirectory, name: []const u8) ?DirEntry {
        for (self.entries.items) |entry| {
            if (self.case_insensitive) {
                if (CaseFolder.equalsIgnoreCase(entry.name, name)) return entry;
            } else {
                if (std.mem.eql(u8, entry.name, name)) return entry;
            }
        }
        return null;
    }

    pub fn findIndex(self: LinearDirectory, name: []const u8) ?usize {
        for (self.entries.items, 0..) |entry, i| {
            if (self.case_insensitive) {
                if (CaseFolder.equalsIgnoreCase(entry.name, name)) return i;
            } else {
                if (std.mem.eql(u8, entry.name, name)) return i;
            }
        }
        return null;
    }

    pub fn insert(self: *Self, entry: DirEntry) !void {
        if (self.entries.items.len >= self.max_entries) return DirectoryError.OutOfSpace;

        // Check for existing
        if (self.find(entry.name)) |_| return DirectoryError.AlreadyExists;

        // Check for case collision
        if (self.case_insensitive) {
            for (self.entries.items) |existing| {
                if (!std.mem.eql(u8, existing.name, entry.name) and
                    CaseFolder.equalsIgnoreCase(existing.name, entry.name)) {
                    return DirectoryError.CaseCollision;
                }
            }
        }

        // Validate name
        try WindowsReservedNames.validate(entry.name);

        // Insert in sorted order (by case-folded name)
        var insert_pos = self.entries.items.len;
        for (self.entries.items, 0..) |existing, i| {
            if (CaseFolder.compareIgnoreCase(entry.name, existing.name) < 0) {
                insert_pos = i;
                break;
            }
        }

        var new_entry = DirEntry{
            .inode = entry.inode,
            .name = try self.allocator.dupe(u8, entry.name),
            .file_type = entry.file_type,
            .flags = entry.flags,
        };
        try self.entries.insert(insert_pos, new_entry);
    }

    pub fn remove(self: *Self, name: []const u8) !DirEntry {
        if (self.entries.items.len == 0) return DirectoryError.NotFound;

        const index = self.findIndex(name) orelse return DirectoryError.NotFound;
        const entry = self.entries.items[index];
        var result = DirEntry{
            .inode = entry.inode,
            .name = try self.allocator.dupe(u8, entry.name),
            .file_type = entry.file_type,
            .flags = entry.flags,
        };
        self.allocator.free(entry.name);
        try self.entries.orderedRemove(index);
        return result;
    }

    pub fn iterate(self: LinearDirectory, callback: fn(DirEntry) !void) !void {
        for (self.entries.items) |entry| {
            try callback(entry);
        }
    }

    pub fn count(self: LinearDirectory) usize {
        return self.entries.items.len;
    }

    pub fn isFull(self: LinearDirectory) bool {
        return self.entries.items.len >= self.max_entries;
    }

    pub fn serialize(self: LinearDirectory, writer: *serialization.Writer(void)) !void {
        try writer.writeU32(0x44495200); // "DIR\0"
        try writer.writeU16(1); // version
        try writer.writeU16(@as(u16, @intCast(self.entries.items.len)));

        for (self.entries.items) |entry| {
            try entry.serialize(writer);
        }

        // CRC32C
        const crc = utils.crc32c(writer.bytes());
        try writer.writeU32(crc);
    }

    pub fn deserialize(reader: *serialization.Reader(void), allocator: Allocator) !LinearDirectory {
        const magic = try reader.readU32();
        if (magic != 0x44495200) return DirectoryError.CorruptedData;

        _ = try reader.readU16(); // version
        const entry_count = try reader.readU16();

        var dir = LinearDirectory.init(allocator, 64);
        for (0..entry_count) |_| {
            const entry = try DirEntry.deserialize(reader, allocator);
            try dir.entries.append(entry);
        }

        try reader.readAndVerifyCrc32c();
        return dir;
    }
};

// B+ Tree directory (>64 entries)
pub const BTreeDirectory = struct {
    const Self = @This();
    const Node = struct {
        magic: u32 = 0x44545200, // "DTR\0"
        version: u16 = 1,
        flags: u16 = 0,
        entry_count: u16 = 0,
        max_entries: u16 = 0,
        is_leaf: u16 = 0,
        level: u16 = 0,
        entries: []NodeEntry,
        crc32c: u32 = 0,

        pub const NodeEntry = struct {
            key_hash: u64,
            child: u64,        // Inode (leaf) / node block (internal)
            name: []const u8,  // Full name (leaf only)
        };
    };

    root_block: u64 = 0,
    cluster_size: u32 = 4096,
    device: *blockdev.BlockDevice,
    allocator: Allocator,
    max_entries_per_node: u16 = 0,
    case_insensitive: bool = true,

    pub fn init(device: *blockdev.BlockDevice, cluster_size: u32, allocator: Allocator) !BTreeDirectory {
        const entry_size = 24; // key_hash(8) + child(8) + name_ptr(8) - simplified
        const header_size = 20; // magic + version + flags + entry_count + max_entries + is_leaf + level + crc32c
        const max_entries = (cluster_size - header_size) / entry_size;

        return .{
            .device = device,
            .cluster_size = cluster_size,
            .allocator = allocator,
            .max_entries_per_node = @as(u16, @intCast(max_entries)),
        };
    }

    pub fn createRoot(self: *Self) !u64 {
        // Allocate a block for root
        // In real implementation, use allocation.zig
        var node = Node{
            .magic = 0x44545200,
            .version = 1,
            .flags = 0,
            .entry_count = 0,
            .max_entries = self.max_entries_per_node,
            .is_leaf = 1,
            .level = 0,
            .entries = &[_]Node.NodeEntry{},
            .crc32c = 0,
        };
        // Write node to device
        // For now return dummy block
        self.root_block = 1;
        return 1;
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
            try writer.writeU64(entry.key_hash);
            try writer.writeU64(entry.child);
            // Name would be written for leaf nodes
            if (node.is_leaf == 1) {
                try writer.writeString(entry.name);
            }
        }

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
        if (magic != 0x44545200) return DirectoryError.CorruptedData;

        const entry_count = try reader.readU16();
        _ = try reader.readU16(); // max_entries
        _ = try reader.readU16(); // is_leaf
        _ = try reader.readU16(); // level

        // Read entries (simplified)
        var entries = try self.allocator.alloc(Node.NodeEntry, entry_count);
        for (entries, 0..) |*entry, i| {
            _ = i;
            entry.key_hash = try reader.readU64();
            entry.child = try reader.readU64();
            entry.name = &[_]u8{}; // Would read name for leaf
        }

        const crc32c = try reader.readU32();
        return .{
            .magic = magic,
            .version = 1,
            .flags = 0,
            .entry_count = entry_count,
            .max_entries = self.max_entries_per_node,
            .is_leaf = 1,
            .level = 0,
            .entries = entries,
            .crc32c = crc32c,
        };
    }

    pub fn find(self: *Self, name: []const u8) ?u64 {
        const hash = CaseFolder.hashFNV1a(name);
        var current_block = self.root_block;

        while (current_block != 0) {
            const node = self.readNode(current_block) catch return null;

            if (node.is_leaf == 1) {
                // Linear search in leaf
                for (node.entries) |entry| {
                    if (entry.key_hash == hash) {
                        // Verify name matches (hash collision check)
                        // Would need to read name from disk
                        return entry.child;
                    }
                }
                return null;
            } else {
                // Internal node - find child
                var child_block: u64 = 0;
                for (node.entries) |entry| {
                    if (hash <= entry.key_hash) {
                        child_block = entry.child;
                        break;
                    }
                }
                if (child_block == 0 and node.entries.len > 0) {
                    child_block = node.entries[node.entries.len - 1].child;
                }
                current_block = child_block;
            }
        }

        return null;
    }

    pub fn insert(self: *Self, name: []const u8, inode: u64) !void {
        if (self.root_block == 0) {
            // Create new root
            try self.createRoot();
        }

        var ctx = DirInsertContext{
            .tree = self,
            .name = name,
            .inode = inode,
            .hash = CaseFolder.hashFNV1a(name),
            .split_key_hash = 0,
            .split_child = 0,
            .split_name = &[_]u8{},
            .needs_split = false,
        };
        try ctx.insertRecursive(self.root_block);

        if (ctx.needs_split) {
            try self.handleRootSplit(ctx.split_key_hash, ctx.split_child, ctx.split_name);
        }
    }

    pub fn remove(self: *Self, name: []const u8) !void {
        if (self.root_block == 0) return;

        var ctx = DirRemoveContext{
            .tree = self,
            .name = name,
            .hash = CaseFolder.hashFNV1a(name),
            .needs_merge = false,
            .removed = false,
        };
        try ctx.removeRecursive(self.root_block);

        if (ctx.needs_merge && self.root_block != 0) {
            try self.maybeCollapseRoot();
        }
    }

    fn createRoot(self: *Self) !void {
        // For now, use a simple block allocation - in production this would come from allocation.zig
        const root_block = 1; // Placeholder - needs real allocation
        var node = Node{
            .magic = 0x44545200,
            .version = 1,
            .flags = 0,
            .entry_count = 0,
            .max_entries = self.max_entries_per_node,
            .is_leaf = 1,
            .level = 0,
            .entries = &[_]Node.NodeEntry{},
            .crc32c = 0,
        };
        try self.writeNode(root_block, &node);
        self.root_block = root_block;
    }

    fn handleRootSplit(self: *Self, split_key_hash: u64, split_child: u64, split_name: []const u8) !void {
        const old_root = self.root_block;
        const new_root = 2; // Placeholder - needs real allocation

        // Create new internal root node
        var new_root_node = Node{
            .magic = 0x44545200,
            .version = 1,
            .flags = 0,
            .entry_count = 2,
            .max_entries = self.max_entries_per_node,
            .is_leaf = 0,
            .level = 1,
            .entries = try self.allocator.alloc(Node.NodeEntry, 2),
            .crc32c = 0,
        };

        // Read old root to get its max key
        const old_root_node = try self.readNode(old_root);
        var max_key_hash: u64 = 0;
        for (old_root_node.entries) |entry| {
            if (entry.key_hash > max_key_hash) max_key_hash = entry.key_hash;
        }

        new_root_node.entries[0] = .{
            .key_hash = max_key_hash,
            .child = old_root,
            .name = &[_]u8{},
        };
        new_root_node.entries[1] = .{
            .key_hash = split_key_hash,
            .child = split_child,
            .name = try self.allocator.dupe(u8, split_name),
        };

        try self.writeNode(new_root, &new_root_node);
        self.root_block = new_root;
    }

    fn maybeCollapseRoot(self: *Self) !void {
        if (self.root_block == 0) return;
        const root = try self.readNode(self.root_block);
        if (root.is_leaf == 0 && root.entry_count == 1) {
            // Root has only one child - collapse
            self.root_block = root.entries[0].child;
        }
    }
};

// Context for directory insert
const DirInsertContext = struct {
    const Self = @This();
    tree: *BTreeDirectory,
    name: []const u8,
    inode: u64,
    hash: u64,
    split_key_hash: u64,
    split_child: u64,
    split_name: []const u8,
    needs_split: bool,

    fn insertRecursive(self: *Self, block: u64) !void {
        var node = try self.tree.readNode(block);

        if (node.is_leaf == 1) {
            try self.insertIntoLeaf(block, &node);
        } else {
            try self.insertIntoInternal(block, &node);
        }
    }

    fn insertIntoLeaf(self: *Self, block: u64, node: *BTreeDirectory.Node) !void {
        // Check for existing entry with same name (case-insensitive)
        for (node.entries[0..node.entry_count]) |entry| {
            if (entry.key_hash == self.hash) {
                // Hash collision - check actual name
                // In a real implementation, we'd read the name from disk
                // For now, assume it's a collision and return AlreadyExists
                return DirectoryError.AlreadyExists;
            }
        }

        // Find insert position (keep sorted by hash)
        var insert_pos = node.entry_count;
        for (node.entries[0..node.entry_count], 0..) |entry, i| {
            if (self.hash < entry.key_hash) {
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
        var new_entries = try self.tree.allocator.alloc(Node.NodeEntry, node.entry_count + 1);
        defer self.tree.allocator.free(new_entries);

        var j: u16 = 0;
        for (node.entries[0..node.entry_count], 0..) |entry, i| {
            if (@as(u16, @intCast(i)) == insert_pos) {
                new_entries[j] = .{
                    .key_hash = self.hash,
                    .child = self.inode,
                    .name = try self.tree.allocator.dupe(u8, self.name),
                };
                j += 1;
            }
            new_entries[j] = entry;
            j += 1;
        }
        if (insert_pos == node.entry_count) {
            new_entries[j] = .{
                .key_hash = self.hash,
                .child = self.inode,
                .name = try self.tree.allocator.dupe(u8, self.name),
            };
        }

        // Free old entries' names
        for (node.entries[0..node.entry_count]) |entry| {
            if (entry.name.len > 0) {
                self.tree.allocator.free(entry.name);
            }
        }
        self.tree.allocator.free(node.entries);
        node.entries = new_entries;
        node.entry_count += 1;
        try self.tree.writeNode(block, node);
    }

    fn splitLeaf(self: *Self, block: u64, node: *BTreeDirectory.Node, insert_pos: u16) !void {
        // Create new leaf node
        const new_block = 3; // Placeholder - needs real allocation
        var new_node = BTreeDirectory.Node{
            .magic = 0x44545200,
            .version = 1,
            .flags = 0,
            .entry_count = 0,
            .max_entries = node.max_entries,
            .is_leaf = 1,
            .level = 0,
            .entries = try self.tree.allocator.alloc(Node.NodeEntry, node.max_entries),
            .crc32c = 0,
        };

        // Combine old entries + new entry, then split in middle
        const total = node.entry_count + 1;
        const mid = total / 2;

        var all_entries = try self.tree.allocator.alloc(Node.NodeEntry, total);
        defer self.tree.allocator.free(all_entries);

        var idx: u16 = 0;
        for (node.entries[0..node.entry_count], 0..) |entry, i| {
            if (@as(u16, @intCast(i)) == insert_pos) {
                all_entries[idx] = .{
                    .key_hash = self.hash,
                    .child = self.inode,
                    .name = try self.tree.allocator.dupe(u8, self.name),
                };
                idx += 1;
            }
            all_entries[idx] = entry;
            idx += 1;
        }
        if (insert_pos == node.entry_count) {
            all_entries[idx] = .{
                .key_hash = self.hash,
                .child = self.inode,
                .name = try self.tree.allocator.dupe(u8, self.name),
            };
        }

        // Split
        node.entry_count = mid;
        // Free old entries' names
        for (node.entries[0..node.entry_count + (total - mid)]) |entry| {
            if (entry.name.len > 0) {
                self.tree.allocator.free(entry.name);
            }
        }
        self.tree.allocator.free(node.entries);
        node.entries = try self.tree.allocator.alloc(Node.NodeEntry, mid);
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
        self.split_key_hash = new_node.entries[new_node.entry_count - 1].key_hash;
        self.split_child = new_block;
        self.split_name = new_node.entries[new_node.entry_count - 1].name;
        self.needs_split = true;
    }

    fn insertIntoInternal(self: *Self, block: u64, node: *BTreeDirectory.Node) !void {
        // Find child to descend into
        var child_idx: u16 = node.entry_count;
        for (node.entries[0..node.entry_count], 0..) |entry, i| {
            if (self.hash <= entry.key_hash) {
                child_idx = @as(u16, @intCast(i));
                break;
            }
        }

        const child_block = node.entries[child_idx].child;
        try self.insertRecursive(child_block);

        if (self.needs_split) {
            try self.addToInternal(block, node, child_idx);
        }
    }

    fn addToInternal(self: *Self, block: u64, node: *BTreeDirectory.Node, child_idx: u16) !void {
        if (node.entry_count >= node.max_entries) {
            try self.splitInternal(block, node, child_idx);
            return;
        }

        // Shift and insert
        var new_entries = try self.tree.allocator.alloc(Node.NodeEntry, node.entry_count + 1);
        defer self.tree.allocator.free(new_entries);

        var j: u16 = 0;
        for (node.entries[0..node.entry_count], 0..) |entry, i| {
            if (@as(u16, @intCast(i)) == child_idx + 1) {
                new_entries[j] = .{
                    .key_hash = self.split_key_hash,
                    .child = self.split_child,
                    .name = try self.tree.allocator.dupe(u8, self.split_name),
                };
                j += 1;
            }
            new_entries[j] = entry;
            j += 1;
        }
        if (child_idx + 1 == node.entry_count) {
            new_entries[j] = .{
                .key_hash = self.split_key_hash,
                .child = self.split_child,
                .name = try self.tree.allocator.dupe(u8, self.split_name),
            };
        }

        // Free old entries' names
        for (node.entries[0..node.entry_count]) |entry| {
            if (entry.name.len > 0) {
                self.tree.allocator.free(entry.name);
            }
        }
        self.tree.allocator.free(node.entries);
        node.entries = new_entries;
        node.entry_count += 1;

        // Update keys in this node (max key of each child)
        self.updateInternalKeys(node);

        try self.tree.writeNode(block, node);
        self.needs_split = false;
    }

    fn splitInternal(self: *Self, block: u64, node: *BTreeDirectory.Node, child_idx: u16) !void {
        // Add the new entry first, then split
        const total = node.entry_count + 1;
        const mid = total / 2;

        var all_entries = try self.tree.allocator.alloc(Node.NodeEntry, total);
        defer self.tree.allocator.free(all_entries);

        var idx: u16 = 0;
        for (node.entries[0..node.entry_count], 0..) |entry, i| {
            if (@as(u16, @intCast(i)) == child_idx + 1) {
                all_entries[idx] = .{
                    .key_hash = self.split_key_hash,
                    .child = self.split_child,
                    .name = try self.tree.allocator.dupe(u8, self.split_name),
                };
                idx += 1;
            }
            all_entries[idx] = entry;
            idx += 1;
        }
        if (child_idx + 1 == node.entry_count) {
            all_entries[idx] = .{
                .key_hash = self.split_key_hash,
                .child = self.split_child,
                .name = try self.tree.allocator.dupe(u8, self.split_name),
            };
        }

        // Create new internal node
        const new_block = 4; // Placeholder - needs real allocation
        var new_node = BTreeDirectory.Node{
            .magic = 0x44545200,
            .version = 1,
            .flags = 0,
            .entry_count = 0,
            .max_entries = node.max_entries,
            .is_leaf = 0,
            .level = node.level,
            .entries = try self.tree.allocator.alloc(Node.NodeEntry, node.max_entries),
            .crc32c = 0,
        };

        // Split
        node.entry_count = mid;
        // Free old entries' names
        for (node.entries[0..node.entry_count + (total - mid)]) |entry| {
            if (entry.name.len > 0) {
                self.tree.allocator.free(entry.name);
            }
        }
        self.tree.allocator.free(node.entries);
        node.entries = try self.tree.allocator.alloc(Node.NodeEntry, mid);
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
        self.split_key_hash = new_node.entries[new_node.entry_count - 1].key_hash;
        self.split_child = new_block;
        self.split_name = new_node.entries[new_node.entry_count - 1].name;
        self.needs_split = true;
    }

    fn updateInternalKeys(self: *Self, node: *BTreeDirectory.Node) void {
        for (node.entries[0..node.entry_count], 0..) |*entry, i| {
            if (i + 1 < node.entry_count) {
                entry.key_hash = node.entries[i + 1].key_hash;
            }
        }
    }
};

// Context for directory remove
const DirRemoveContext = struct {
    const Self = @This();
    tree: *BTreeDirectory,
    name: []const u8,
    hash: u64,
    needs_merge: bool,
    removed: bool,

    fn removeRecursive(self: *Self, block: u64) !void {
        var node = try self.tree.readNode(block);

        if (node.is_leaf == 1) {
            try self.removeFromLeaf(block, &node);
        } else {
            try self.removeFromInternal(block, &node);
        }
    }

    fn removeFromLeaf(self: *Self, block: u64, node: *BTreeDirectory.Node) !void {
        // Find the entry to remove
        var found_idx: ?u16 = null;
        for (node.entries[0..node.entry_count], 0..) |entry, i| {
            if (entry.key_hash == self.hash) {
                // Hash match - in real impl, verify name
                found_idx = @as(u16, @intCast(i));
                break;
            }
        }

        if (found_idx == null) return; // Not found

        // Free the name
        if (node.entries[found_idx.?].name.len > 0) {
            self.tree.allocator.free(node.entries[found_idx.?].name);
        }

        // Remove entry
        var new_count = node.entry_count - 1;
        if (new_count == 0) {
            // Node becomes empty
            self.tree.allocator.free(node.entries);
            node.entries = &[_]Node.NodeEntry{};
            node.entry_count = 0;
            try self.tree.writeNode(block, node);
            self.needs_merge = true;
            return;
        }

        var new_entries = try self.tree.allocator.alloc(Node.NodeEntry, new_count);
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
        }
    }

    fn removeFromInternal(self: *Self, block: u64, node: *BTreeDirectory.Node) !void {
        // Find child
        var child_idx: u16 = node.entry_count;
        for (node.entries[0..node.entry_count], 0..) |entry, i| {
            if (self.hash <= entry.key_hash) {
                child_idx = @as(u16, @intCast(i));
                break;
            }
        }

        const child_block = node.entries[child_idx].child;
        try self.removeRecursive(child_block);

        if (self.needs_merge) {
            try self.handleChildMerge(block, node, child_idx);
        }
    }

    fn handleChildMerge(self: *Self, block: u64, node: *BTreeDirectory.Node, child_idx: u16) !void {
        if (node.entry_count <= 1) {
            // This internal node would become empty
            self.needs_merge = true;
            return;
        }

        // Free the child's name
        if (node.entries[child_idx].name.len > 0) {
            self.tree.allocator.free(node.entries[child_idx].name);
        }

        // Remove the child entry
        var new_count = node.entry_count - 1;
        var new_entries = try self.tree.allocator.alloc(Node.NodeEntry, new_count);
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

    fn updateInternalKeys(self: *Self, node: *BTreeDirectory.Node) void {
        for (node.entries[0..node.entry_count], 0..) |*entry, i| {
            if (i + 1 < node.entry_count) {
                entry.key_hash = node.entries[i + 1].key_hash;
            }
        }
    }
};

// Unified directory interface
pub const Directory = struct {
    const Self = @This();
    linear: ?LinearDirectory = null,
    btree: ?BTreeDirectory = null,
    is_btree: bool = false,
    inode: u64 = 0,
    cluster_size: u32 = 4096,
    device: *blockdev.BlockDevice,
    allocator: Allocator,
    case_insensitive: bool = true,

    pub fn init(
        device: *blockdev.BlockDevice,
        cluster_size: u32,
        allocator: Allocator,
    ) Directory {
        return .{
            .device = device,
            .cluster_size = cluster_size,
            .allocator = allocator,
        };
    }

    pub fn loadLinear(self: *Self, data: []const u8) !void {
        var reader = serialization.createReader(data);
        self.linear = try LinearDirectory.deserialize(&reader, self.allocator);
        if (self.linear.?.isFull()) {
            try self.convertToBTree();
        }
    }

    pub fn loadBTree(self: *Self, root_block: u64) !void {
        self.btree = try BTreeDirectory.init(self.device, self.cluster_size, self.allocator);
        self.btree.?.root_block = root_block;
        self.is_btree = true;
    }

    fn convertToBTree(self: *Self) !void {
        if (self.linear == null) return;

        var btree = try BTreeDirectory.init(self.device, self.cluster_size, self.allocator);
        try btree.createRoot();

        // Insert all linear entries into btree
        var linear = self.linear.?;
        for (linear.entries.items) |entry| {
            try btree.insert(entry.name, entry.inode);
        }

        self.btree = btree;
        self.is_btree = true;
        linear.deinit(self.allocator);
        self.linear = null;
    }

    pub fn find(self: Directory, name: []const u8) ?u64 {
        if (self.is_btree) {
            return self.btree.?.find(name);
        } else if (self.linear) |linear| {
            return linear.find(name).?.inode;
        }
        return null;
    }

    pub fn insert(self: *Self, name: []const u8, inode: u64, file_type: u8) !void {
        // Validate name
        try WindowsReservedNames.validate(name);

        if (self.is_btree) {
            try self.btree.?.insert(name, inode);
        } else if (self.linear) |*linear| {
            try linear.insert(DirEntry{
                .inode = inode,
                .name = name,
                .file_type = file_type,
                .flags = 0,
            });
            if (linear.isFull()) {
                try self.convertToBTree();
            }
        } else {
            // Create new linear directory
            var linear = LinearDirectory.init(self.allocator, 64);
            try linear.insert(DirEntry{
                .inode = inode,
                .name = name,
                .file_type = file_type,
                .flags = 0,
            });
            self.linear = linear;
        }
    }

    pub fn remove(self: *Self, name: []const u8) !void {
        if (self.is_btree) {
            try self.btree.?.remove(name);
            // Could convert back to linear if small enough
        } else if (self.linear) |*linear| {
            _ = try linear.remove(name);
        }
    }

    pub fn iterate(self: Directory, callback: fn(u64, []const u8, u8) !void) !void {
        if (self.is_btree) {
            // Would need full btree iteration
            _ = callback;
        } else if (self.linear) |linear| {
            for (linear.entries.items) |entry| {
                try callback(entry.inode, entry.name, entry.file_type);
            }
        }
    }

    pub fn count(self: Directory) usize {
        if (self.is_btree) {
            // Would need btree count
            return 0;
        } else if (self.linear) |linear| {
            return linear.count();
        }
        return 0;
    }

    pub fn serialize(self: Directory) ![]u8 {
        var writer = serialization.createWriter(self.allocator);
        defer writer.deinit();

        if (self.is_btree) {
            // Serialize btree root reference
            try writer.writeU32(0x44545200);
            try writer.writeU64(self.btree.?.root_block);
        } else if (self.linear) |linear| {
            try linear.serialize(&writer);
        } else {
            // Empty directory
            try writer.writeU32(0x44495200);
            try writer.writeU16(1);
            try writer.writeU16(0);
            const crc = utils.crc32c(writer.bytes());
            try writer.writeU32(crc);
        }

        return try writer.toOwnedSlice();
    }
};

// Directory operations for journal
pub const DirJournalOps = struct {
    pub fn createLink(allocator: Allocator, parent: u64, name: []const u8, child: u64, file_type: u8) ![]u8 {
        var op = metadata.OpLinkDirent{
            .parent = parent,
            .name = name,
            .child = child,
            .file_type = file_type,
        };
        var writer = serialization.createWriter(allocator);
        defer writer.deinit();
        try op.serialize(&writer);
        return writer.toOwnedSlice();
    }

    pub fn removeLink(parent: u64, name: []const u8) ![]u8 {
        // Similar structure
        _ = parent;
        _ = name;
        return &[_]u8{};
    }

    pub fn renameLink(parent: u64, old_name: []const u8, new_name: []const u8) ![]u8 {
        _ = parent;
        _ = old_name;
        _ = new_name;
        return &[_]u8{};
    }
};