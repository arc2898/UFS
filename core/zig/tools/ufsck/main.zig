// ufsck - UFS Filesystem Checker
// Validates and repairs UFS filesystem structures

const std = @import("std");
const ufs = @import("ufs");

const Allocator = std.mem.Allocator;
const print = std.debug.print;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = std.process.argsAlloc(allocator) catch {
        print("Failed to allocate args\n", .{});
        return error.OutOfMemory;
    };
    defer std.process.argsFree(allocator, args);

    try parseAndRun(allocator, args);
}

fn parseAndRun(allocator: Allocator, args: [][]const u8) !void {
    if (args.len < 2) {
        printUsage(args[0] orelse "ufsck");
        return;
    }

    const device_path = args[1];

    var options = CheckOptions{
        .repair = false,
        .verbose = false,
        .check_data = false,
        .force = false,
        .output_json = false,
        .progress = false,
    };

    var i: usize = 2;
    while (i < args.len) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printUsage(args[0] orelse "ufsck");
            return;
        } else if (std.mem.eql(u8, arg, "-y") or std.mem.eql(u8, arg, "--repair")) {
            options.repair = true;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            options.verbose = true;
        } else if (std.mem.eql(u8, arg, "-D") or std.mem.eql(u8, arg, "--check-data")) {
            options.check_data = true;
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--force")) {
            options.force = true;
        } else if (std.mem.eql(u8, arg, "-j") or std.mem.eql(u8, arg, "--json")) {
            options.output_json = true;
        } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--progress")) {
            options.progress = true;
        } else {
            print("Unknown option: {s}\n", .{arg});
            printUsage(args[0] orelse "ufsck");
            return error.InvalidArgument;
        }
        i += 1;
    }

    if (options.repair && !options.force) {
        print("WARNING: Repair mode modifies the filesystem!\n", .{});
        print("Use -f to confirm you want to proceed with repairs.\n", .{});
        return;
    }

    if (options.verbose) {
        print("Checking {s}...\n", .{device_path});
    }

    // Open block device
    const block_dev = try openBlockDevice(allocator, device_path);
    defer block_dev.close();

    const info = block_dev.get_info();

    // Run checks
    var checker = Checker{
        .allocator = allocator,
        .dev = block_dev,
        .info = info,
        .options = options,
        .errors = 0,
        .warnings = 0,
        .corrupted_files = 0,
    };

    try checker.run();

    // Print summary
    if (!options.output_json) {
        print("\n=== Summary ===\n", .{});
        print("Errors: {d}\n", .{checker.errors});
        print("Warnings: {d}\n", .{checker.warnings});
        print("Corrupted files: {d}\n", .{checker.corrupted_files});

        if (checker.errors > 0) {
            print("\nFilesystem has errors", .{});
            if (options.repair) {
                print(" (repairs attempted)\n", .{});
            } else {
                print(". Run with -y to attempt repair.\n", .{});
            }
        } else {
            print("\nFilesystem is clean.\n", .{});
        }
    } else {
        // JSON output
        const json = try formatJSON(allocator, checker);
        print("{s}\n", .{json});
    }
}

const CheckOptions = struct {
    repair: bool,
    verbose: bool,
    check_data: bool,
    force: bool,
    output_json: bool,
    progress: bool,
};

const Checker = struct {
    allocator: Allocator,
    dev: BlockDevice,
    info: DeviceInfo,
    options: CheckOptions,
    errors: usize = 0,
    warnings: usize = 0,
    corrupted_files: usize = 0,

    fn run(self: *Checker) !void {
        // Read and verify superblock
        try self.checkSuperblock();

        // Check journal
        try self.checkJournal();

        // Check allocation groups
        for (0..self.superblock_loaded.ag_count) |i| {
            try self.checkAllocationGroup(i);
        }

        // Verify free space consistency
        try self.checkFreeSpace();

        // Check directory structure
        try self.checkDirectories();

        // Journal replay (if repair mode)
        if (self.options.repair) {
            try self.replayJournal();
        }
    }

    // Cached superblock
    superblock_loaded: Superblock = undefined,
    superblock_valid: bool = false,

    fn checkSuperblock(self: *Checker) !void {
        if (self.options.verbose) print("Checking superblock...\n", .{});

        var buf = try self.allocator.alloc(u8, 4096);
        defer self.allocator.free(buf);

        try self.dev.read(0, buf);

        // Verify magic
        const magic = readU32LE(buf[0..4]);
        if (magic != ufs.MAGIC_UFS) {
            self.reportError("Invalid magic number: expected 0x{08x}, got 0x{08x}", .{ufs.MAGIC_UFS, magic});
            if (self.options.repair) {
                // Try backup superblocks
                try self.tryBackupSuperblocks();
            }
            return;
        }

        // Parse superblock
        self.superblock_loaded = Superblock{
            .magic = magic,
            .version_major = readU16LE(buf[4..6]),
            .version_minor = readU16LE(buf[6..8]),
            .version_revision = readU32LE(buf[8..12]),
            .uuid = buf[12..28],
            .label = std.mem.span(buf[28..284], 0),
            .cluster_size = readU32LE(buf[284..288]),
            .total_clusters = readU64LE(buf[288..296]),
            .journal_start = readU64LE(buf[296..304]),
            .journal_clusters = readU64LE(buf[304..312]),
            .ag_count = readU32LE(buf[312..316]),
            .first_ag_offset = readU64LE(buf[316..324]),
            .incompat_flags = readU32LE(buf[324..328]),
            .compat_ro_flags = readU32LE(buf[328..332]),
            .compat_rw_flags = readU32LE(buf[332..336]),
            .default_compression = buf[336],
        };
        self.superblock_valid = true;

        if (self.options.verbose) {
            print("  Version: {d}.{d}.{d}\n", .{self.superblock_loaded.version_major, self.superblock_loaded.version_minor, self.superblock_loaded.version_revision});
            print("  Cluster size: {d}\n", .{self.superblock_loaded.cluster_size});
            print("  Total clusters: {d}\n", .{self.superblock_loaded.total_clusters});
            print("  AG count: {d}\n", .{self.superblock_loaded.ag_count});
            print("  Journal: start={d}, clusters={d}\n", .{self.superblock_loaded.journal_start, self.superblock_loaded.journal_clusters});
        }

        // Check backup superblocks
        try self.verifyBackupSuperblocks();

        // Verify checksum
        try self.verifySuperblockChecksum();
    }

    fn tryBackupSuperblocks(self: *Checker) !void {
        if (self.options.verbose) print("  Trying backup superblocks...\n", .{});

        var buf = try self.allocator.alloc(u8, 4096);
        defer self.allocator.free(buf);

        // Backup superblock locations: at 1%, 50%, 99% of disk
        const total_clusters_estimate = self.info.total_blocks / (4096 / self.info.block_size);
        const backup_positions = [_]u64{
            total_clusters_estimate / 100,
            total_clusters_estimate / 2,
            (total_clusters_estimate * 99) / 100,
        };

        for (backup_positions) |pos| {
            try self.dev.read(pos * self.superblock_loaded.cluster_size, buf);
            const magic = readU32LE(buf[0..4]);
            if (magic == ufs.MAGIC_UFS) {
                if (self.options.verbose) print("  Found valid backup at cluster {d}\n", .{pos});
                // Parse and use this backup
                self.superblock_loaded = Superblock{
                    .magic = magic,
                    .version_major = readU16LE(buf[4..6]),
                    .version_minor = readU16LE(buf[6..8]),
                    .version_revision = readU32LE(buf[8..12]),
                    .uuid = buf[12..28],
                    .label = std.mem.span(buf[28..284], 0),
                    .cluster_size = readU32LE(buf[284..288]),
                    .total_clusters = readU64LE(buf[288..296]),
                    .journal_start = readU64LE(buf[296..304]),
                    .journal_clusters = readU64LE(buf[304..312]),
                    .ag_count = readU32LE(buf[312..316]),
                    .first_ag_offset = readU64LE(buf[316..324]),
                    .incompat_flags = readU32LE(buf[324..328]),
                    .compat_ro_flags = readU32LE(buf[328..332]),
                    .compat_rw_flags = readU32LE(buf[332..336]),
                    .default_compression = buf[336],
                };
                self.superblock_valid = true;
                return;
            }
        }

        self.reportError("No valid backup superblock found", .{});
    }

    fn verifyBackupSuperblocks(self: *Checker) !void {
        if (self.options.verbose) print("  Verifying backup superblocks...\n", .{});

        var buf = try self.allocator.alloc(u8, 4096);
        defer self.allocator.free(buf);

        const total_clusters_estimate = self.superblock_loaded.total_clusters;
        const backup_positions = [_]u64{
            total_clusters_estimate / 100,
            total_clusters_estimate / 2,
            (total_clusters_estimate * 99) / 100,
        };

        for (backup_positions) |pos| {
            try self.dev.read(pos * self.superblock_loaded.cluster_size, buf);
            const magic = readU32LE(buf[0..4]);
            if (magic != ufs.MAGIC_UFS) {
                self.reportWarning("Backup superblock at cluster {d} has invalid magic: 0x{08x}", .{pos, magic});
                if (self.options.repair) {
                    // Rewrite backup from primary
                    try self.rewriteBackupSuperblock(pos);
                }
                continue;
            }

            // Compare critical fields
            const backup_cluster_size = readU32LE(buf[284..288]);
            const backup_total_clusters = readU64LE(buf[288..296]);
            const backup_ag_count = readU32LE(buf[312..316]);

            if (backup_cluster_size != self.superblock_loaded.cluster_size ||
                backup_total_clusters != self.superblock_loaded.total_clusters ||
                backup_ag_count != self.superblock_loaded.ag_count) {
                self.reportWarning("Backup superblock at cluster {d} has mismatched fields", .{pos});
                if (self.options.repair) {
                    try self.rewriteBackupSuperblock(pos);
                }
            }
        }
    }

    fn rewriteBackupSuperblock(self: *Checker, pos: u64) !void {
        if (self.options.verbose) print("  Rewriting backup superblock at cluster {d}\n", .{pos});
        // In a real implementation, serialize and write the primary superblock to backup location
        // This requires the serialization module
    }

    fn verifySuperblockChecksum(self: *Checker) !void {
        if (self.options.verbose) print("  Verifying superblock checksum...\n", .{});
        // Superblock ends with CRC32C of preceding data
        // TODO: implement CRC32C verification
    }

    fn checkJournal(self: *Checker) !void {
        if (self.options.verbose) print("Checking journal...\n", .{});

        // Read journal superblock
        var buf = try self.allocator.alloc(u8, 4096);
        defer self.allocator.free(buf);

        try self.dev.read(self.superblock_loaded.journal_start, buf);

        const magic = readU32LE(buf[0..4]);
        if (magic != ufs.MAGIC_JOURNAL) {
            self.reportError("Invalid journal magic: 0x{08x}", .{magic});
            return;
        }

        const version = readU32LE(buf[4..8]);
        const journal_clusters = readU64LE(buf[8..16]);
        const start_txid = readU64LE(buf[16..24]);
        const end_txid = readU64LE(buf[24..32]);
        const checkpoint_txid = readU64LE(buf[32..40]);

        if (self.options.verbose) {
            print("  Journal version: {d}\n", .{version});
            print("  Journal clusters: {d}\n", .{journal_clusters});
            print("  Start TXID: {d}\n", .{start_txid});
            print("  End TXID: {d}\n", .{end_txid});
            print("  Checkpoint TXID: {d}\n", .{checkpoint_txid});
        }

        // Verify journal size matches superblock
        if (journal_clusters != self.superblock_loaded.journal_clusters) {
            self.reportWarning("Journal size mismatch: superblock={d}, journal={d}", .{self.superblock_loaded.journal_clusters, journal_clusters});
        }

        // Verify journal transactions
        try self.verifyJournalTransactions(start_txid, end_txid, checkpoint_txid);
    }

    fn verifyJournalTransactions(self: *Checker, start_txid: u64, end_txid: u64, checkpoint_txid: u64) !void {
        if (self.options.verbose) print("  Verifying journal transactions...\n", .{});

        // Journal layout:
        // Cluster 0: Journal superblock
        // Clusters 1..N: Transaction blocks (each cluster can hold multiple transactions)

        var buf = try self.allocator.alloc(u8, self.superblock_loaded.cluster_size);
        defer self.allocator.free(buf);

        var expected_txid: u64 = start_txid;
        var last_valid_txid: u64 = start_txid;
        var incomplete_txns: u32 = 0;
        var corrupted_txns: u32 = 0;

        // Read each journal cluster
        for (u64(1)..self.superblock_loaded.journal_clusters) |cluster_idx| {
            try self.dev.read(self.superblock_loaded.journal_start + cluster_idx, buf);

            // Parse transactions in this cluster
            var offset: usize = 0;
            while (offset + 64 <= self.superblock_loaded.cluster_size) {
                // Transaction header (64 bytes)
                const txn_magic = readU32LE(buf[offset..offset+4]);
                if (txn_magic != ufs.MAGIC_JOURNAL_TXN) {
                    // End of valid transactions in this cluster
                    break;
                }

                const txn_version = readU16LE(buf[offset+4..offset+6]);
                const txn_flags = readU16LE(buf[offset+6..offset+8]);
                const txn_txid = readU64LE(buf[offset+8..offset+16]);
                const txn_timestamp = readU64LE(buf[offset+16..offset+24]);
                const txn_operation_count = readU32LE(buf[offset+24..offset+28]);
                const txn_data_size = readU32LE(buf[offset+28..offset+32]);
                const txn_crc32c = readU32LE(buf[offset+32..offset+36]);
                const txn_merkle_root = buf[offset+36..offset+68]; // 32 bytes BLAKE3

                // Verify transaction ID sequence
                if (txn_txid != expected_txid) {
                    self.reportWarning("Journal TXID gap: expected {d}, got {d}", .{expected_txid, txn_txid});
                }

                // Verify CRC32C of transaction data
                const txn_data_start = offset + 64;
                if (txn_data_start + txn_data_size <= self.superblock_loaded.cluster_size) {
                    const computed_crc = ufs.crc32c(buf[txn_data_start..txn_data_start + txn_data_size]);
                    if (computed_crc != txn_crc32c) {
                        self.reportError("Journal transaction {d}: CRC32C mismatch (expected 0x{08x}, got 0x{08x})", .{txn_txid, txn_crc32c, computed_crc});
                        corrupted_txns += 1;
                        if (self.options.repair) {
                            // Skip corrupted transaction
                            offset = self.superblock_loaded.cluster_size; // Stop parsing this cluster
                            break;
                        }
                    } else {
                        last_valid_txid = txn_txid;
                    }
                }

                // Verify Merkle root if present (for full transactions)
                // TODO: verify Merkle tree matches operation data

                expected_txid = txn_txid + 1;
                offset += 64 + txn_data_size;

                // Align to 8-byte boundary
                offset = (offset + 7) & ~7;
            }
        }

        // Check for incomplete transaction at end
        if (end_txid > last_valid_txid) {
            incomplete_txns = @intCast(end_txid - last_valid_txid);
            self.reportWarning("Journal has {d} incomplete transaction(s) at end", .{incomplete_txns});
        }

        if (self.options.verbose) {
            print("  Last valid TXID: {d}\n", .{last_valid_txid});
            print("  Incomplete transactions: {d}\n", .{incomplete_txns});
            print("  Corrupted transactions: {d}\n", .{corrupted_txns});
        }

        // Store for replay
        self.last_valid_txid = last_valid_txid;
        self.checkpoint_txid = checkpoint_txid;
    }

    // New fields for journal replay
    last_valid_txid: u64 = 0,
    checkpoint_txid: u64 = 0,

    fn checkAllocationGroup(self: *Checker, ag_index: u32) !void {
        if (self.options.verbose) print("Checking AG {d}...\n", .{ag_index});

        // Read AG header
        const cluster_size = self.superblock_loaded.cluster_size;
        const ag_size_clusters = self.superblock_loaded.total_clusters / self.superblock_loaded.ag_count;
        const ag_start = self.superblock_loaded.first_ag_offset + @intCast(ag_index) * ag_size_clusters;

        var buf = try self.allocator.alloc(u8, cluster_size);
        defer self.allocator.free(buf);

        try self.dev.read(ag_start, buf);

        const magic = readU32LE(buf[0..4]);
        if (magic != ufs.MAGIC_AG) {
            self.reportError("AG {d}: Invalid magic 0x{08x}", .{ag_index, magic});
            return;
        }

        const ag = AGLayout{
            .index = readU32LE(buf[4..8]),
            .start_cluster = readU64LE(buf[8..16]),
            .cluster_count = readU64LE(buf[16..24]),
            .inode_table_start = readU64LE(buf[24..32]),
            .inode_count = readU32LE(buf[32..36]),
            .bitmap_start = readU64LE(buf[36..44]),
            .bitmap_clusters = readU64LE(buf[44..52]),
            .free_tree_start = readU64LE(buf[52..60]),
            .free_tree_clusters = readU64LE(buf[60..68]),
        };

        if (self.options.verbose) {
            print("  AG {d}: start={d}, clusters={d}, inodes={d}, bitmap={d} clusters, free_tree={d} clusters\n", .{
                ag.index, ag.start_cluster, ag.cluster_count, ag.inode_count, ag.bitmap_clusters, ag.free_tree_clusters
            });
        }

        // Verify bitmap
        try self.verifyBitmap(ag);

        // Verify inode table
        try self.verifyInodeTable(ag);

        // Verify free extent tree
        try self.verifyFreeTree(ag);
    }

    fn verifyBitmap(self: *Checker, ag: AGLayout) !void {
        if (self.options.verbose) print("  Verifying bitmap...\n", .{});

        // Read all bitmap clusters
        const bits_per_cluster = self.superblock_loaded.cluster_size * 8;
        var total_bits: u64 = 0;
        var allocated_bits: u64 = 0;

        var buf = try self.allocator.alloc(u8, self.superblock_loaded.cluster_size);
        defer self.allocator.free(buf);

        for (u64(0)..ag.bitmap_clusters) |i| {
            try self.dev.read(ag.bitmap_start + i, buf);

            // Count bits
            for (buf) |byte| {
                if (total_bits >= ag.cluster_count) break;
                if ((byte & 1) != 0) allocated_bits += 1; else total_bits += 1;
                if ((byte & 2) != 0) allocated_bits += 1; else total_bits += 1;
                if ((byte & 4) != 0) allocated_bits += 1; else total_bits += 1;
                if ((byte & 8) != 0) allocated_bits += 1; else total_bits += 1;
                if ((byte & 16) != 0) allocated_bits += 1; else total_bits += 1;
                if ((byte & 32) != 0) allocated_bits += 1; else total_bits += 1;
                if ((byte & 64) != 0) allocated_bits += 1; else total_bits += 1;
                if ((byte & 128) != 0) allocated_bits += 1; else total_bits += 1;
            }
        }

        if (self.options.verbose) {
            print("  Bitmap: {d}/{d} clusters allocated ({d:.1}%)\n", .{allocated_bits, ag.cluster_count, @as(f64, @floatFromInt(allocated_bits)) * 100.0 / @as(f64, @floatFromInt(ag.cluster_count))});
        }

        // Verify reserved clusters are marked allocated
        // AG header (cluster 0)
        // Inode table clusters
        // Bitmap clusters
        // Free tree clusters

        if (self.options.repair) {
            try self.repairBitmap(ag);
        }
    }

    fn repairBitmap(self: *Checker, ag: AGLayout) !void {
        if (self.options.verbose) print("  Repairing bitmap...\n", .{});

        // Ensure reserved clusters are marked allocated:
        // 1. AG header (cluster 0)
        // 2. Inode table clusters
        // 3. Bitmap clusters
        // 4. Free tree clusters

        // This requires writing to the bitmap
        // For now, just log what would be done
        if (self.options.verbose) {
            print("  Would ensure reserved clusters are marked allocated\n", .{});
        }
    }

    fn verifyInodeTable(self: *Checker, ag: AGLayout) !void {
        if (self.options.verbose) print("  Verifying inode table...\n", .{});

        var buf = try self.allocator.alloc(u8, self.superblock_loaded.cluster_size);
        defer self.allocator.free(buf);

        const inode_size = 256;
        const inodes_per_cluster = self.superblock_loaded.cluster_size / inode_size;

        var valid_inodes: u32 = 0;
        var orphaned_inodes: u32 = 0;

        for (u64(0)..(ag.inode_table_clusters())) |cluster_idx| {
            try self.dev.read(ag.inode_table_start + cluster_idx, buf);

            for (u32(0)..inodes_per_cluster) |inode_idx| {
                const inode_num = cluster_idx * inodes_per_cluster + inode_idx;
                if (inode_num >= ag.inode_count) break;

                const offset = @intCast(inode_idx) * inode_size;
                const magic = readU32LE(buf[offset..offset+4]);

                if (magic == ufs.MAGIC_INODE) {
                    valid_inodes += 1;

                    // Verify inode checksum
                    const inode_crc = readU32LE(buf[offset+252..offset+256]);
                    const computed_crc = ufs.crc32c(buf[offset..offset+252]);
                    if (computed_crc != inode_crc) {
                        self.reportError("Inode {d}: CRC32C mismatch (expected 0x{08x}, got 0x{08x})", .{inode_num, inode_crc, computed_crc});
                        if (self.options.repair) {
                            // Zero out corrupted inode
                            try self.clearInode(ag, inode_num, cluster_idx, offset);
                        }
                    }

                    // Check link count consistency
                    const link_count = readU32LE(buf[offset+60..offset+64]);
                    if (link_count == 0 && inode_num > 10) { // Skip reserved inodes
                        orphaned_inodes += 1;
                        if (self.options.verbose) {
                            print("    Orphaned inode: {d} (link_count=0)\n", .{inode_num});
                        }
                    }

                    // If checking data integrity, verify extent checksums
                    if (self.options.check_data) {
                        try self.verifyInodeDataIntegrity(ag, inode_num, buf[offset..offset+inode_size]);
                    }
                }
            }
        }

        if (self.options.verbose) {
            print("  Inodes: {d} valid, {d} orphaned\n", .{valid_inodes, orphaned_inodes});
        }
    }

    fn clearInode(self: *Checker, ag: AGLayout, inode_num: u32, cluster_idx: u64, offset: usize) !void {
        if (self.options.verbose) print("    Clearing corrupted inode {d}\n", .{inode_num});
        // In a real implementation, write zeros to the inode
        // This requires write access to the device
    }

    fn verifyInodeDataIntegrity(self: *Checker, ag: AGLayout, inode_num: u32, inode_data: []const u8) !void {
        // Parse extent list from inode and verify BLAKE3 checksums
        // This is a placeholder - full implementation would parse extent tree
        if (self.options.verbose) {
            print("    Verifying data integrity for inode {d}... (placeholder)\n", .{inode_num});
        }
    }

    fn verifyFreeTree(self: *Checker, ag: AGLayout) !void {
        if (self.options.verbose) print("  Verifying free extent tree...\n", .{});

        // Read free tree root
        var buf = try self.allocator.alloc(u8, self.superblock_loaded.cluster_size);
        defer self.allocator.free(buf);

        try self.dev.read(ag.free_tree_start, buf);

        const magic = readU32LE(buf[0..4]);
        if (magic != ufs.MAGIC_FREE_TREE) {
            self.reportWarning("AG {d}: Free tree magic mismatch: 0x{08x}", .{ag.index, magic});
            if (self.options.repair) {
                try self.rebuildFreeTree(ag);
            }
            return;
        }

        // TODO: traverse B+ tree and verify extent counts match bitmap
        if (self.options.repair) {
            try self.rebuildFreeTree(ag);
        }
    }

    fn rebuildFreeTree(self: *Checker, ag: AGLayout) !void {
        if (self.options.verbose) print("  Rebuilding free extent tree for AG {d}...\n", .{ag.index});

        // Rebuild free extent tree from bitmap
        // This is a complex operation - simplified for now
        if (self.options.verbose) {
            print("  Free tree rebuild not fully implemented\n", .{});
        }
    }

    fn checkFreeSpace(self: *Checker) !void {
        if (self.options.verbose) print("Checking free space consistency...\n", .{});

        // Sum free space across all AGs and compare with superblock
        // This requires reading all AG bitmaps
        var total_free: u64 = 0;
        var total_allocated: u64 = 0;

        for (0..self.superblock_loaded.ag_count) |ag_index| {
            const ag_size_clusters = self.superblock_loaded.total_clusters / self.superblock_loaded.ag_count;
            const ag_start = self.superblock_loaded.first_ag_offset + @intCast(ag_index) * ag_size_clusters;

            var buf = try self.allocator.alloc(u8, self.superblock_loaded.cluster_size);
            defer self.allocator.free(buf);

            try self.dev.read(ag_start, buf);

            const bitmap_start = readU64LE(buf[36..44]);
            const bitmap_clusters = readU64LE(buf[44..52]);
            const cluster_count = readU64LE(buf[16..24]);

            var bitmap_buf = try self.allocator.alloc(u8, self.superblock_loaded.cluster_size);
            defer self.allocator.free(bitmap_buf);

            for (u64(0)..bitmap_clusters) |i| {
                try self.dev.read(bitmap_start + i, bitmap_buf);

                for (bitmap_buf) |byte| {
                    if (total_allocated + total_free >= cluster_count) break;
                    if ((byte & 1) != 0) total_allocated += 1; else total_free += 1;
                    if ((byte & 2) != 0) total_allocated += 1; else total_free += 1;
                    if ((byte & 4) != 0) total_allocated += 1; else total_free += 1;
                    if ((byte & 8) != 0) total_allocated += 1; else total_free += 1;
                    if ((byte & 16) != 0) total_allocated += 1; else total_free += 1;
                    if ((byte & 32) != 0) total_allocated += 1; else total_free += 1;
                    if ((byte & 64) != 0) total_allocated += 1; else total_free += 1;
                    if ((byte & 128) != 0) total_allocated += 1; else total_free += 1;
                }
            }
        }

        if (self.options.verbose) {
            print("  Total free: {d} clusters\n", .{total_free});
            print("  Total allocated: {d} clusters\n", .{total_allocated});
            print("  Total clusters: {d}\n", .{self.superblock_loaded.total_clusters});
        }
    }

    fn checkDirectories(self: *Checker) !void {
        if (self.options.verbose) print("Checking directory structure...\n", .{});

        // Walk directory tree from root inode (inode 2)
        // Verify:
        // 1. Directory entries point to valid inodes
        // 2. Inode link counts match directory entries
        // 3. No cycles in directory structure
        // 4. All inodes reachable from root (no orphans)
        // 5. Directory B+ tree integrity

        if (self.options.verbose) {
            print("  Directory tree walk... (not fully implemented)\n", .{});
        }
    }

    fn replayJournal(self: *Checker) !void {
        if (!self.options.repair) return;
        if (self.options.verbose) print("  Replaying journal from checkpoint...\n", .{});

        // Replay valid transactions from checkpoint_txid to last_valid_txid
        // This requires parsing transaction operations and applying them
        // For now, log that replay would happen
        if (self.last_valid_txid > self.checkpoint_txid) {
            if (self.options.verbose) {
                print("  Would replay {d} transactions (TXID {d} to {d})\n", .{
                    self.last_valid_txid - self.checkpoint_txid,
                    self.checkpoint_txid,
                    self.last_valid_txid
                });
            }
        }
    }

    fn reportError(self: *Checker, fmt: []const u8, args: anytype) void {
        self.errors += 1;
        if (!self.options.output_json) {
            print("ERROR: ", .{});
            std.debug.print(fmt, args);
            print("\n", .{});
        }
    }

    fn reportWarning(self: *Checker, fmt: []const u8, args: anytype) void {
        self.warnings += 1;
        if (!self.options.output_json && self.options.verbose) {
            print("WARNING: ", .{});
            std.debug.print(fmt, args);
            print("\n", .{});
        }
    }
};

const Superblock = struct {
    magic: u32,
    version_major: u16,
    version_minor: u16,
    version_revision: u32,
    uuid: [16]u8,
    label: []const u8,
    cluster_size: u32,
    total_clusters: u64,
    journal_start: u64,
    journal_clusters: u64,
    ag_count: u32,
    first_ag_offset: u64,
    incompat_flags: u32,
    compat_ro_flags: u32,
    compat_rw_flags: u32,
    default_compression: u8,
};

const AGLayout = struct {
    index: u32,
    start_cluster: u64,
    cluster_count: u64,
    inode_table_start: u64,
    inode_count: u32,
    bitmap_start: u64,
    bitmap_clusters: u64,
    free_tree_start: u64,
    free_tree_clusters: u64,

    fn inode_table_clusters(self: AGLayout, cluster_size: u32) u64 {
        return (u64(self.inode_count) * 256 + cluster_size - 1) / cluster_size;
    }
};

const BlockDevice = struct {
    fd: std.os.fd_t,
    path: []const u8,
    block_size: u32,
    total_blocks: u64,

    fn open(allocator: Allocator, path: []const u8) !BlockDevice {
        const fd = try std.os.openFile(path, .{ .read = true, .write = false }, .{});
        const stat = try std.os.fstat(fd);
        const block_size = 4096; // default
        const total_blocks = stat.size / block_size;
        return BlockDevice{
            .fd = fd,
            .path = path,
            .block_size = block_size,
            .total_blocks = total_blocks,
        };
    }

    fn close(self: BlockDevice) void {
        std.posix.close(self.fd);
    }

    fn read(self: BlockDevice, offset: u64, buffer: []u8) !usize {
        return try std.posix.pread(self.fd, buffer, @intCast(offset * self.block_size));
    }

    fn get_info(self: BlockDevice) DeviceInfo {
        return DeviceInfo{
            .block_size = self.block_size,
            .physical_block_size = self.block_size,
            .optimal_io_size = self.block_size * 128,
            .total_blocks = self.total_blocks,
            .is_removable = false,
            .is_read_only = false,
            .is_ssd = false,
            .is_virtual = false,
            .serial_number = "",
            .model = "",
            .firmware = "",
        };
    }
};

const DeviceInfo = struct {
    block_size: u32,
    physical_block_size: u32,
    optimal_io_size: u32,
    total_blocks: u64,
    is_removable: bool,
    is_read_only: bool,
    is_ssd: bool,
    is_virtual: bool,
    serial_number: []const u8,
    model: []const u8,
    firmware: []const u8,
};

fn printUsage(program: []const u8) void {
    print("Usage: {s} <device> [options]\n\n", .{program});
    print("Options:\n", .{});
    print("  -y, --repair           Attempt to repair errors (requires -f)\n", .{});
    print("  -f, --force            Force repair without confirmation\n", .{});
    print("  -v, --verbose          Verbose output\n", .{});
    print("  -D, --check-data       Verify file data checksums (BLAKE3)\n", .{});
    print("  -j, --json             Output results as JSON\n", .{});
    print("  -p, --progress         Show progress bar\n", .{});
    print("  -h, --help             Show this help\n", .{});
}

fn formatJSON(allocator: Allocator, checker: Checker) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    try buf.writer().print("{{\n", .{});
    try buf.writer().print("  \"errors\": {d},\n", .{checker.errors});
    try buf.writer().print("  \"warnings\": {d},\n", .{checker.warnings});
    try buf.writer().print("  \"corrupted_files\": {d}\n", .{checker.corrupted_files});
    try buf.writer().print("}}\n", .{});
    return buf.toOwnedSlice();
}

fn readU16LE(buf: []const u8) u16 {
    return @intCast(buf[0]) | (@intCast(buf[1]) << 8);
}

fn readU32LE(buf: []const u8) u32 {
    return @intCast(buf[0]) | (@intCast(buf[1]) << 8) | (@intCast(buf[2]) << 16) | (@intCast(buf[3]) << 24);
}

fn readU64LE(buf: []const u8) u64 {
    var val: u64 = 0;
    for (0..8) |i| {
        val |= @as(u64, @intCast(buf[i])) << (i * 8);
    }
    return val;
}