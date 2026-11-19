// Version Module
// Major.Minor.Revision + feature flags

const std = @import("std");

pub const Version = @import("../src/version.zig").Version;
pub const FeatureFlags = @import("../src/version.zig").FeatureFlags;
pub const MountCompatibility = @import("../src/version.zig").MountCompatibility;
pub const SupportedFeatures = @import("../src/version.zig").SupportedFeatures;
pub const VolumeFormat = @import("../src/version.zig").VolumeFormat;
pub const Migration = @import("../src/version.zig").Migration;
pub const Superblock = @import("../src/version.zig").Superblock;

pub const Allocator = std.mem.Allocator;