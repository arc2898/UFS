// UFS Versioning & Feature Flags
// Major.Minor.Revision + INCOMPAT/COMPAT_RO/COMPAT_RW feature flags

const std = @import("std");
const serialization = @import("serialization.zig");
const utils = @import("utils.zig");
const Allocator = std.mem.Allocator;

pub const Version = struct {
    major: u16 = 1,
    minor: u16 = 0,
    revision: u32 = 0,

    pub const CURRENT = Version{ .major = 1, .minor = 0, .revision = 0 };

    pub fn format(self: Version) []const u8 {
        var buf: [32]u8 = undefined;
        const len = std.fmt.bufPrint(&buf, "v{}.{}.{}", .{self.major, self.minor, self.revision}) catch 0;
        return buf[0..len];
    }

    pub fn parse(str: []const u8) !Version {
        // Parse "v1.0.0" or "1.0.0"
        var s = str;
        if (s[0] == 'v') s = s[1..];

        const parts = std.mem.split(u8, s, ".");
        var iterator = parts.iterator();
        const major_str = iterator.next() orelse return error.InvalidArgument;
        const minor_str = iterator.next() orelse return error.InvalidArgument;
        const revision_str = iterator.next() orelse return error.InvalidArgument;

        const major = std.fmt.parseInt(u16, major_str, 10) catch return error.InvalidArgument;
        const minor = std.fmt.parseInt(u16, minor_str, 10) catch return error.InvalidArgument;
        const revision = std.fmt.parseInt(u32, revision_str, 10) catch return error.InvalidArgument;

        return .{ .major = major, .minor = minor, .revision = revision };
    }

    pub fn compare(self: Version, other: Version) i32 {
        if (self.major != other.major) return @as(i32, @intCast(self.major)) - @as(i32, @intCast(other.major));
        if (self.minor != other.minor) return @as(i32, @intCast(self.minor)) - @as(i32, @intCast(other.minor));
        return @as(i32, @intCast(self.revision)) - @as(i32, @intCast(other.revision));
    }

    pub fn isCompatible(self: Version, other: Version) bool {
        // Same major version = compatible
        return self.major == other.major;
    }

    pub fn serialize(self: Version, writer: *serialization.Writer(void)) !void {
        try writer.writeU16(self.major);
        try writer.writeU16(self.minor);
        try writer.writeU32(self.revision);
    }

    pub fn deserialize(reader: *serialization.Reader(void), allocator: Allocator) !Version {
        return .{
            .major = try reader.readU16(),
            .minor = try reader.readU16(),
            .revision = try reader.readU32(),
        };
    }
};

// Feature Flags
pub const FeatureFlags = struct {
    // Incompatible features - if set, cannot mount read-write unless understood
    // These change the on-disk format in a way that older implementations cannot handle
    incompat: u32 = 0,

    // Read-only compatible features - can mount read-only, but not read-write unless understood
    compat_ro: u32 = 0,

    // Read-write compatible features - can mount read-write, but may not use the feature
    compat_rw: u32 = 0,

    // Incompatible feature bits
    pub const INCOMPAT_ENCRYPTION = 0;       // Per-file encryption
    pub const INCOMPAT_SNAPSHOTS = 1;        // Snapshot support
    pub const INCOMPAT_DEDUP = 2;            // Deduplication
    pub const INCOMPAT_QUOTAS = 3;           // Quota enforcement
    pub const INCOMPAT_ZNS = 4;              // Zoned namespace support
    pub const INCOMPAT_CASE_INSENSITIVE = 5; // Case-insensitive volume
    pub const INCOMPAT_VERITY = 6;           // fs-verity style integrity

    // Read-only compatible feature bits
    pub const COMPAT_RO_COMPRESSION_LZ4 = 0;        // LZ4 compression
    pub const COMPAT_RO_COMPRESSION_ZSTD = 1;       // ZSTD compression
    pub const COMPAT_RO_COMPRESSION_ZSTD_HIGH = 2;  // ZSTD high compression
    pub const COMPAT_RO_CASE_INSENSITIVE = 3;       // Case-insensitive (read-only safe)
    pub const COMPAT_RO_METADATA_CSUMS = 4;         // Metadata checksums
    pub const COMPAT_RO_PROJECT_QUOTA = 5;          // Project quota
    pub const COMPAT_RO_INLINE_DATA = 6;            // Inline data in inode

    // Read-write compatible feature bits
    pub const COMPAT_RW_XATTR = 0;              // Extended attributes
    pub const COMPAT_RW_ACL = 1;                // POSIX ACLs
    pub const COMPAT_RW_WINDOWS_META = 2;       // Windows metadata namespaces
    pub const COMPAT_RW_MACOS_META = 3;         // macOS metadata namespaces
    pub const COMPAT_RW_SYMLINKS = 4;           // Symbolic links
    pub const COMPAT_RW_HARDLINKS = 5;          // Hard links
    pub const COMPAT_RW_REPARSE = 6;            // Reparse points
    pub const COMPAT_RW_SPARSE = 7;             // Sparse files

    pub fn hasIncompat(self: FeatureFlags, bit: u32) bool {
        return (self.incompat & (1 << bit)) != 0;
    }

    pub fn hasCompatRo(self: FeatureFlags, bit: u32) bool {
        return (self.compat_ro & (1 << bit)) != 0;
    }

    pub fn hasCompatRw(self: FeatureFlags, bit: u32) bool {
        return (self.compat_rw & (1 << bit)) != 0;
    }

    pub fn setIncompat(self: *FeatureFlags, bit: u32, enabled: bool) void {
        if (enabled) self.incompat |= (1 << bit);
        else self.incompat &= ~(1 << bit);
    }

    pub fn setCompatRo(self: *FeatureFlags, bit: u32, enabled: bool) void {
        if (enabled) self.compat_ro |= (1 << bit);
        else self.compat_ro &= ~(1 << bit);
    }

    pub fn setCompatRw(self: *FeatureFlags, bit: u32, enabled: bool) void {
        if (enabled) self.compat_rw |= (1 << bit);
        else self.compat_rw &= ~(1 << bit);
    }

    pub fn serialize(self: FeatureFlags, writer: *serialization.Writer(void)) !void {
        try writer.writeU32(self.incompat);
        try writer.writeU32(self.compat_ro);
        try writer.writeU32(self.compat_rw);
    }

    pub fn deserialize(reader: *serialization.Reader(void), allocator: Allocator) !FeatureFlags {
        return .{
            .incompat = try reader.readU32(),
            .compat_ro = try reader.readU32(),
            .compat_rw = try reader.readU32(),
        };
    }

    pub fn checkCompatibility(
        self: FeatureFlags,
        supported_incompat: u32,
        supported_compat_ro: u32,
        supported_compat_rw: u32,
    ) MountCompatibility {
        var result = MountCompatibility{
            .can_mount_ro = true,
            .can_mount_rw = true,
            .unknown_incompat = 0,
            .unknown_compat_ro = 0,
            .unknown_compat_rw = 0,
        };

        // Check incompatible features
        var unknown_incompat = self.incompat & ~supported_incompat;
        if (unknown_incompat != 0) {
            result.can_mount_ro = false;
            result.can_mount_rw = false;
            result.unknown_incompat = unknown_incompat;
        }

        // Check read-only compatible features
        var unknown_compat_ro = self.compat_ro & ~supported_compat_ro;
        if (unknown_compat_ro != 0) {
            result.can_mount_rw = false;
            result.unknown_compat_ro = unknown_compat_ro;
        }

        // Check read-write compatible features
        var unknown_compat_rw = self.compat_rw & ~supported_compat_rw;
        if (unknown_compat_rw != 0) {
            result.unknown_compat_rw = unknown_compat_rw;
        }

        return result;
    }
};

pub const MountCompatibility = struct {
    can_mount_ro: bool,
    can_mount_rw: bool,
    unknown_incompat: u32,
    unknown_compat_ro: u32,
    unknown_compat_rw: u32,

    pub fn describe(self: MountCompatibility) []const u8 {
        var buf: [256]u8 = undefined;
        var writer = std.io.fixedBufferStream(&buf).writer();

        if (!self.can_mount_ro) {
            _ = writer.print("Cannot mount: unknown incompatible features: 0x{:08x}", .{self.unknown_incompat});
        } else if (!self.can_mount_rw) {
            _ = writer.print("Read-only mount: unknown compat_ro features: 0x{:08x}", .{self.unknown_compat_ro});
        } else {
            _ = writer.print("Full read-write mount");
            if (self.unknown_compat_rw != 0) {
                _ = writer.print(" (unknown compat_rw features: 0x{:08x} will be ignored)", .{self.unknown_compat_rw});
            }
        }

        return buf[0..writer.bytesWritten()];
    }
};

// Supported features by this implementation
pub const SupportedFeatures = struct {
    pub const INCOMPAT = 0
        | (1 << FeatureFlags.INCOMPAT_ENCRYPTION)
        | (1 << FeatureFlags.INCOMPAT_SNAPSHOTS)
        | (1 << FeatureFlags.INCOMPAT_DEDUP)
        | (1 << FeatureFlags.INCOMPAT_QUOTAS)
        | (1 << FeatureFlags.INCOMPAT_ZNS)
        | (1 << FeatureFlags.INCOMPAT_CASE_INSENSITIVE)
        | (1 << FeatureFlags.INCOMPAT_VERITY);

    pub const COMPAT_RO = 0
        | (1 << FeatureFlags.COMPAT_RO_COMPRESSION_LZ4)
        | (1 << FeatureFlags.COMPAT_RO_COMPRESSION_ZSTD)
        | (1 << FeatureFlags.COMPAT_RO_COMPRESSION_ZSTD_HIGH)
        | (1 << FeatureFlags.COMPAT_RO_CASE_INSENSITIVE)
        | (1 << FeatureFlags.COMPAT_RO_METADATA_CSUMS)
        | (1 << FeatureFlags.COMPAT_RO_PROJECT_QUOTA)
        | (1 << FeatureFlags.COMPAT_RO_INLINE_DATA);

    pub const COMPAT_RW = 0
        | (1 << FeatureFlags.COMPAT_RW_XATTR)
        | (1 << FeatureFlags.COMPAT_RW_ACL)
        | (1 << FeatureFlags.COMPAT_RW_WINDOWS_META)
        | (1 << FeatureFlags.COMPAT_RW_MACOS_META)
        | (1 << FeatureFlags.COMPAT_RW_SYMLINKS)
        | (1 << FeatureFlags.COMPAT_RW_HARDLINKS)
        | (1 << FeatureFlags.COMPAT_RW_REPARSE)
        | (1 << FeatureFlags.COMPAT_RW_SPARSE);
};

// Volume format version (stored in superblock)
pub const VolumeFormat = struct {
    version: Version,
    features: FeatureFlags,
    creation_time: u64, // nanoseconds since epoch
    last_mount_time: u64,
    last_write_time: u64,
    mount_count: u32,
    max_mount_count: u32,
    check_interval: u32, // seconds
    last_check_time: u64,
    creator_os: u32,
    default_mount_opts: u32,

    // On-disk layout fields (populated from superblock)
    cluster_size: u32 = 4096,
    volume_size: u64 = 0,
    root_inode: u64 = 2,
    journal_offset: u64 = 2,
    journal_size: u64 = 1024,
    ag_count: u32 = 1,
    ag_size: u32 = 262144,
    ag_table_offset: u64 = 0,
    first_ag_offset: u64 = 1026,
    uuid: [16]u8 = undefined,
    label: [64]u8 = undefined,

    pub const OS_LINUX = 0;
    pub const OS_WINDOWS = 1;
    pub const OS_MACOS = 2;
    pub const OS_UEFI = 3;
    pub const OS_FREEBSD = 4;
    pub const OS_OPENBSD = 5;
    pub const OS_NETBSD = 6;
    pub const OS_SOLARIS = 7;

    pub fn current(allocator: Allocator) !VolumeFormat {
        const now = std.time.timestamp();
        return .{
            .version = Version.CURRENT,
            .features = FeatureFlags{},
            .creation_time = now,
            .last_mount_time = now,
            .last_write_time = now,
            .mount_count = 0,
            .max_mount_count = 20,
            .check_interval = 180 * 24 * 60 * 60, // 180 days
            .last_check_time = now,
            .creator_os = if (std.target.os.tag == .windows) OS_WINDOWS else if (std.target.os.tag == .macos) OS_MACOS else if (std.target.os.tag == .uefi) OS_UEFI else OS_LINUX,
            .default_mount_opts = 0,
        };
    }

    pub fn create(
        allocator: Allocator,
        device: *blockdev.BlockDevice,
        cluster_size: u32,
        compression_algo: u8,
        journal_size_clusters: u64,
        ag_count: u32,
        label: [*c]const u8,
    ) !VolumeFormat {
        const info = device.get_info();
        const total_clusters = info.total_blocks;

        // Calculate layout
        const superblock_cluster: u64 = 1;
        const journal_offset: u64 = 2;
        const journal_size: u64 = if (journal_size_clusters > 0) journal_size_clusters else 1024;
        const first_ag_offset: u64 = journal_offset + journal_size;

        // AG size: 1GB default (in clusters)
        const ag_size: u64 = if (ag_count > 0) {
            (total_clusters - first_ag_offset) / ag_count
        } else {
            1_073_741_824 / cluster_size // 1GB in clusters
        };

        const ag_table_offset: u64 = 0; // Not used yet

        // Volume UUID
        var uuid: [16]u8 = utils.generateUuidv7Bytes();

        // Volume label
        var vol_label: [64]u8 = undefined;
        @memset(&vol_label, 0);
        if (label != null) {
            const label_len = @min(std.mem.span(label).len, 63);
            @memcpy(vol_label[0..label_len], std.mem.span(label)[0..label_len]);
        }

        // Feature flags based on compression
        var features = FeatureFlags{};
        switch (compression_algo) {
            1 => features.setCompatRo(FeatureFlags.COMPAT_RO_COMPRESSION_LZ4, true),
            2 => features.setCompatRo(FeatureFlags.COMPAT_RO_COMPRESSION_ZSTD, true),
            3 => features.setCompatRo(FeatureFlags.COMPAT_RO_COMPRESSION_ZSTD_HIGH, true),
            else => {},
        }

        return .{
            .version = Version.CURRENT,
            .features = features,
            .creation_time = std.time.timestamp(),
            .last_mount_time = 0,
            .last_write_time = std.time.timestamp(),
            .mount_count = 0,
            .max_mount_count = 20,
            .check_interval = 180 * 24 * 60 * 60,
            .last_check_time = 0,
            .creator_os = if (std.target.os.tag == .windows) OS_WINDOWS else if (std.target.os.tag == .macos) OS_MACOS else if (std.target.os.tag == .uefi) OS_UEFI else OS_LINUX,
            .default_mount_opts = 0,
        };
    }

    pub fn serialize(self: VolumeFormat, writer: *serialization.Writer(void)) !void {
        try self.version.serialize(writer);
        try self.features.serialize(writer);
        try writer.writeU64(self.creation_time);
        try writer.writeU64(self.last_mount_time);
        try writer.writeU64(self.last_write_time);
        try writer.writeU32(self.mount_count);
        try writer.writeU32(self.max_mount_count);
        try writer.writeU32(self.check_interval);
        try writer.writeU64(self.last_check_time);
        try writer.writeU32(self.creator_os);
        try writer.writeU32(self.default_mount_opts);
    }

    pub fn deserialize(reader: *serialization.Reader(void), allocator: Allocator) !VolumeFormat {
        return .{
            .version = try Version.deserialize(reader, allocator),
            .features = try FeatureFlags.deserialize(reader, allocator),
            .creation_time = try reader.readU64(),
            .last_mount_time = try reader.readU64(),
            .last_write_time = try reader.readU64(),
            .mount_count = try reader.readU32(),
            .max_mount_count = try reader.readU32(),
            .check_interval = try reader.readU32(),
            .last_check_time = try reader.readU64(),
            .creator_os = try reader.readU32(),
            .default_mount_opts = try reader.readU32(),
            .cluster_size = 4096,
            .volume_size = 0,
            .root_inode = 2,
            .journal_offset = 2,
            .journal_size = 1024,
            .ag_count = 1,
            .ag_size = 262144,
            .ag_table_offset = 0,
            .first_ag_offset = 1026,
            .uuid = undefined,
            .label = undefined,
        };
    }

    pub fn load(device: *blockdev.BlockDevice, allocator: Allocator) !VolumeFormat {
        var buffer: [4096]u8 = undefined;
        try device.read(1 * 4096, &buffer);

        var reader = serialization.createReader(&buffer);
        const magic = try reader.readU32();
        if (magic != 0x55465300) return error.InvalidFormat;

        const version_major = try reader.readU16();
        const version_minor = try reader.readU16();
        const version_revision = try reader.readU32();
        _ = try reader.readU32(); // flags
        const features = try FeatureFlags.deserialize(reader, allocator);

        const volume_size = try reader.readU64();
        const cluster_size = try reader.readU32();
        _ = try reader.readU32(); // sector_size
        var uuid: [16]u8 = undefined;
        _ = try reader.readBytes(&uuid);
        var label: [64]u8 = undefined;
        _ = try reader.readBytes(&label);
        const root_inode = try reader.readU64();
        const journal_offset = try reader.readU64();
        const journal_size = try reader.readU64();
        const ag_count = try reader.readU32();
        const ag_size = try reader.readU32();
        const ag_table_offset = try reader.readU64();
        const first_ag_offset = try reader.readU64();
        _ = try reader.readBytes(64); // backup_offsets
        _ = try reader.readU64(); // generation
        _ = try reader.readU8(); // clean_flag
        _ = try reader.readBytes(7); // reserved

        return .{
            .version = Version{ .major = version_major, .minor = version_minor, .revision = version_revision },
            .features = features,
            .creation_time = 0,
            .last_mount_time = 0,
            .last_write_time = 0,
            .mount_count = 0,
            .max_mount_count = 0,
            .check_interval = 0,
            .last_check_time = 0,
            .creator_os = 0,
            .default_mount_opts = 0,
            .cluster_size = cluster_size,
            .volume_size = volume_size,
            .root_inode = root_inode,
            .journal_offset = journal_offset,
            .journal_size = journal_size,
            .ag_count = ag_count,
            .ag_size = ag_size,
            .ag_table_offset = ag_table_offset,
            .first_ag_offset = first_ag_offset,
            .uuid = uuid,
            .label = label,
        };
    }

    pub fn write(self: VolumeFormat, device: *blockdev.BlockDevice, allocator: Allocator) !void {
        var writer = serialization.createWriter(allocator);
        defer writer.deinit();

        // Superblock structure
        try writer.writeU32(0x55465300); // MAGIC_UFS
        try writer.writeU16(self.version.major);
        try writer.writeU16(self.version.minor);
        try writer.writeU32(self.version.revision);
        try writer.writeU32(0); // flags
        try self.features.serialize(&writer);

        // Volume info
        const info = device.get_info();
        const total_clusters = info.total_blocks;
        try writer.writeU64(total_clusters); // volume_size (total clusters)
        try writer.writeU32(self.cluster_size);
        try writer.writeU32(512); // sector_size

        // UUID
        try writer.writeBytes(&self.uuid);

        // Volume label
        try writer.writeBytes(&self.label);

        // Root inode, journal, AG info
        try writer.writeU64(self.root_inode);
        try writer.writeU64(self.journal_offset);
        try writer.writeU64(self.journal_size);
        try writer.writeU32(self.ag_count);
        try writer.writeU32(self.ag_size);
        try writer.writeU64(self.ag_table_offset);
        try writer.writeU64(self.first_ag_offset);

        // Backup superblock offsets
        var backup_offsets: [8]u64 = undefined;
        backup_offsets[0] = 16;
        backup_offsets[1] = 16384;
        backup_offsets[4] = total_clusters - 16;
        try writer.writeBytes(&backup_offsets);

        try writer.writeU64(1); // generation
        try writer.writeU8(1); // clean_flag
        try writer.writeBytes((&[_]u8{0}) ** 7); // reserved

        // Pad to cluster size and write CRC
        try writer.align(self.cluster_size as usize);
        const crc = utils.crc32c(writer.bytes());
        try writer.writeU32(crc);

        // Write to cluster 1
        try device.write(1 * self.cluster_size, writer.bytes());
    }

    pub fn load(device: *blockdev.BlockDevice, allocator: Allocator) !VolumeFormat {
        var buffer: [4096]u8 = undefined;
        try device.read(1 * 4096, &buffer);

        var reader = serialization.createReader(&buffer);
        const magic = try reader.readU32();
        if (magic != 0x55465300) return error.InvalidFormat;

        const version_major = try reader.readU16();
        const version_minor = try reader.readU16();
        const version_revision = try reader.readU32();
        _ = try reader.readU32(); // flags
        const features = try FeatureFlags.deserialize(reader, allocator);

        const volume_size = try reader.readU64();
        const cluster_size = try reader.readU32();
        _ = try reader.readU32(); // sector_size
        var uuid: [16]u8 = undefined;
        _ = try reader.readBytes(&uuid);
        var label: [64]u8 = undefined;
        _ = try reader.readBytes(&label);
        const root_inode = try reader.readU64();
        const journal_offset = try reader.readU64();
        const journal_size = try reader.readU64();
        const ag_count = try reader.readU32();
        const ag_size = try reader.readU32();
        const ag_table_offset = try reader.readU64();
        const first_ag_offset = try reader.readU64();
        _ = try reader.readBytes(64); // backup_offsets
        _ = try reader.readU64(); // generation
        _ = try reader.readU8(); // clean_flag
        _ = try reader.readBytes(7); // reserved

        return .{
            .version = Version{ .major = version_major, .minor = version_minor, .revision = version_revision },
            .features = features,
            .creation_time = 0,
            .last_mount_time = 0,
            .last_write_time = 0,
            .mount_count = 0,
            .max_mount_count = 0,
            .check_interval = 0,
            .last_check_time = 0,
            .creator_os = 0,
            .default_mount_opts = 0,
        };
    }
};

// Migration support for future versions
pub const Migration = struct {
    pub const MigrationStep = struct {
        from_version: Version,
        to_version: Version,
        migrate_fn: fn(device: *blockdev.BlockDevice, superblock: *Superblock) !void,
    };

    const migrations: []MigrationStep = &[_]MigrationStep{};

    pub fn needsMigration(volume: VolumeFormat, target: Version) bool {
        return volume.version.compare(target) < 0;
    }

    pub fn migrate(device: *blockdev.BlockDevice, superblock: *Superblock, target: Version) !void {
        // Apply migrations in order
        _ = device;
        _ = superblock;
        _ = target;
        // Implementation would iterate through migrations
    }
};

// Superblock reference for migration
pub const Superblock = struct {
    magic: u32,
    version_major: u16,
    version_minor: u16,
    version_revision: u32,
    features: FeatureFlags,
    // ... other fields
};