// UFS Core Library - Main Entry Point
// Portable filesystem implementation in Zig

const std = @import("std");

pub const Error = std.fs.File.OpenError || error{
    OutOfMemory,
    InvalidFormat,
    CorruptedData,
    UnsupportedFeature,
    NotFound,
    AlreadyExists,
    PermissionDenied,
    IoError,
    BufferTooSmall,
    InvalidArgument,
    InternalError,
};

pub const Allocator = std.mem.Allocator;

// Re-export core modules
pub const serialization = @import("serialization.zig");
pub const blockdev = @import("blockdev.zig");
pub const metadata = @import("metadata.zig");
pub const allocation = @import("allocation.zig");
pub const journal = @import("journal.zig");
pub const directory = @import("directory.zig");
pub const compression = @import("compression.zig");
pub const integrity = @import("integrity.zig");
pub const version = @import("version.zig");
pub const crypto = @import("crypto.zig");
pub const utils = @import("utils.zig");
pub const c_api = @import("c_api.zig");

// On-disk format constants
pub const MAGIC_UFS = 0x55465300;        // "UFS\0"
pub const MAGIC_JOURNAL = 0x4A55524E;    // "JURN"
pub const MAGIC_TRANSACTION = 0x54584E00; // "TXN\0"
pub const MAGIC_AG = 0x41470000;         // "AG\0\0"
pub const MAGIC_INODE = 0x494E4F00;      // "INO\0"
pub const MAGIC_EXTENT = 0x45585400;     // "EXT\0"
pub const MAGIC_DIR_SMALL = 0x44495200;  // "DIR\0"
pub const MAGIC_DIR_TREE = 0x44545200;   // "DTR\0"
pub const MAGIC_FREE_TREE = 0x46524500;  // "FRE\0"
pub const MAGIC_CAPSULE = 0x43415053;    // "CAPS"

pub const VERSION_MAJOR: u16 = 1;
pub const VERSION_MINOR: u16 = 0;
pub const VERSION_REVISION: u32 = 0;

pub const DEFAULT_CLUSTER_SIZE: u32 = 4096;
pub const DEFAULT_AG_SIZE: u64 = 1_073_741_824; // 1 GB in clusters (with 4KB clusters)
pub const DEFAULT_INODES_PER_AG: u32 = 512;

pub const INODE_FLAG_COMPRESSED = 0x0001;
pub const INODE_FLAG_ENCRYPTED = 0x0002;
pub const INODE_FLAG_SPARSE = 0x0004;
pub const INODE_FLAG_IMMUTABLE = 0x0008;
pub const INODE_FLAG_APPEND_ONLY = 0x0010;
pub const INODE_FLAG_NOATIME = 0x0020;
pub const INODE_FLAG_NODUMP = 0x0040;
pub const INODE_FLAG_SYNC = 0x0080;
pub const INODE_FLAG_CASE_INSENSITIVE = 0x0100;
pub const INODE_FLAG_HAS_CAPSULE = 0x0200;

pub const EXTENT_FLAG_COMPRESSED = 0x0001;
pub const EXTENT_FLAG_ENCRYPTED = 0x0002;
pub const EXTENT_FLAG_SPARSE = 0x0004;
pub const EXTENT_FLAG_UNINITIALIZED = 0x0008;

pub const FILE_TYPE_REG = 1;
pub const FILE_TYPE_DIR = 2;
pub const FILE_TYPE_SYMLINK = 3;
pub const FILE_TYPE_CHRDEV = 4;
pub const FILE_TYPE_BLKDEV = 5;
pub const FILE_TYPE_FIFO = 6;
pub const FILE_TYPE_SOCKET = 7;
pub const FILE_TYPE_REPARSE = 8;

pub const NAMESPACE_POSIX_BASE = 0x0001;
pub const NAMESPACE_POSIX_ACL = 0x0002;
pub const NAMESPACE_POSIX_XATTR = 0x0003;
pub const NAMESPACE_POSIX_CAPS = 0x0004;
pub const NAMESPACE_WINDOWS_SD = 0x0010;
pub const NAMESPACE_WINDOWS_ADS = 0x0011;
pub const NAMESPACE_WINDOWS_REPARSE = 0x0012;
pub const NAMESPACE_WINDOWS_EFS = 0x0013;
pub const NAMESPACE_WINDOWS_USN = 0x0014;
pub const NAMESPACE_WINDOWS_OBJID = 0x0015;
pub const NAMESPACE_WINDOWS_ATTRS = 0x0016;
pub const NAMESPACE_MACOS_XATTR = 0x0020;
pub const NAMESPACE_MACOS_FINDER = 0x0021;
pub const NAMESPACE_MACOS_RESOURCE = 0x0022;
pub const NAMESPACE_MACOS_QUARANTINE = 0x0023;
pub const NAMESPACE_MACOS_FIRMLINK = 0x0024;
pub const NAMESPACE_MACOS_TIMESTAMP = 0x0025;
pub const NAMESPACE_UFS_INTERNAL = 0x8000;
pub const NAMESPACE_OPAQUE = 0xFFFF;

pub const OP_CREATE_INODE = 1;
pub const OP_DELETE_INODE = 2;
pub const OP_UPDATE_INODE_META = 3;
pub const OP_LINK_DIRENT = 4;
pub const OP_UNLINK_DIRENT = 5;
pub const OP_RENAME_DIRENT = 6;
pub const OP_ALLOCATE_EXTENT = 7;
pub const OP_DEALLOCATE_EXTENT = 8;
pub const OP_UPDATE_BITMAP = 9;
pub const OP_UPDATE_SUPERBLOCK = 10;
pub const OP_CHECKPOINT = 11;

pub const INCOMPAT_ENCRYPTION = 0;
pub const INCOMPAT_SNAPSHOTS = 1;
pub const INCOMPAT_DEDUP = 2;
pub const INCOMPAT_QUOTAS = 3;
pub const INCOMPAT_ZNS = 4;

pub const COMPAT_RO_COMPRESSION_LZ4 = 0;
pub const COMPAT_RO_COMPRESSION_ZSTD = 1;
pub const COMPAT_RO_CASE_INSENSITIVE = 2;
pub const COMPAT_RO_METADATA_CSUMS = 3;

pub const COMPAT_RW_XATTR = 0;
pub const COMPAT_RW_ACL = 1;
pub const COMPAT_RW_WINDOWS_META = 2;

pub const COMPRESSION_NONE = 0;
pub const COMPRESSION_LZ4 = 1;
pub const COMPRESSION_ZSTD = 2;
pub const COMPRESSION_ZSTD_HIGH = 3;

pub fn versionString() []const u8 {
    return "UFS v1.0.0";
}

pub fn formatVersion(major: u16, minor: u16, revision: u32) []const u8 {
    var buf: [32]u8 = undefined;
    const len = std.fmt.bufPrint(&buf, "v{}.{}.{}", .{major, minor, revision}) catch 0;
    return buf[0..len];
}