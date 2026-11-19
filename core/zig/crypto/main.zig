// Crypto Module
// Per-file encryption support

const std = @import("std");

pub const CryptoError = @import("../src/crypto.zig").CryptoError;
pub const EncryptionAlgorithm = @import("../src/crypto.zig").EncryptionAlgorithm;
pub const KeySize = @import("../src/crypto.zig").KeySize;
pub const EncryptionContext = @import("../src/crypto.zig").EncryptionContext;
pub const FileEncryptionKey = @import("../src/crypto.zig").FileEncryptionKey;
pub const VolumeKeyManager = @import("../src/crypto.zig").VolumeKeyManager;
pub const EncryptionMetadata = @import("../src/crypto.zig").EncryptionMetadata;

pub const Allocator = std.mem.Allocator;