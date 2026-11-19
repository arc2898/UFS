// Metadata Module
// Metadata Capsule implementation for cross-platform metadata

const std = @import("std");

pub const MetadataError = @import("../src/metadata.zig").MetadataError;
pub const CapsuleFlags = @import("../src/metadata.zig").CapsuleFlags;
pub const CapsuleHeader = @import("../src/metadata.zig").CapsuleHeader;
pub const CapsuleEntry = @import("../src/metadata.zig").CapsuleEntry;
pub const MetadataCapsule = @import("../src/metadata.zig").MetadataCapsule;
pub const NamespaceRegistry = @import("../src/metadata.zig").NamespaceRegistry;
pub const PosixBaseType = @import("../src/metadata.zig").PosixBaseType;
pub const WindowsSdType = @import("../src/metadata.zig").WindowsSdType;
pub const WindowsAdsType = @import("../src/metadata.zig").WindowsAdsType;
pub const MacosXattrType = @import("../src/metadata.zig").MacosXattrType;
pub const UfsInternalType = @import("../src/metadata.zig").UfsInternalType;
pub const CapsuleTranslator = @import("../src/metadata.zig").CapsuleTranslator;
pub const TargetOS = @import("../src/metadata.zig").TargetOS;

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
    return @import("../src/metadata.zig").createPosixBaseCapsule(
        allocator, inode, mode, uid, gid, atime, mtime, ctime, crtime, link_count
    );
}

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
    return @import("../src/metadata.zig").parsePosixBaseCapsule(capsule);
}

pub const Allocator = std.mem.Allocator;