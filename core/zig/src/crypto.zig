// UFS Cryptography Module
// Key derivation scaffolding; authenticated encryption is disabled pending validation

const std = @import("std");
const utils = @import("utils.zig");
const integrity = @import("integrity.zig");

// Encryption algorithms are intentionally fail-closed in this release.
// The previous in-tree AES-GCM wrapper, handwritten ChaCha20/Poly1305, and
// AES-XTS code were incomplete or incorrect (including nonce/tweak handling).
// Returning UnsupportedAlgorithm is safer than silently writing ciphertext
// that cannot be authenticated or interoperably decrypted.

pub const CryptoError = error{
    InvalidKey,
    InvalidNonce,
    InvalidTag,
    EncryptionFailed,
    DecryptionFailed,
    KeyDerivationFailed,
    UnsupportedAlgorithm,
    OutOfMemory,
};

pub const EncryptionAlgorithm = enum(u8) {
    NONE = 0,
    AES256_GCM = 1,
    CHACHA20_POLY1305 = 2,
    AES256_XTS = 3, // For full-disk encryption
};

pub const KeySize = enum(u16) {
    BITS_128 = 16,
    BITS_256 = 32,
    BITS_512 = 64,
};

pub const EncryptionContext = struct {
    const Self = @This();
    algorithm: EncryptionAlgorithm,
    key: [32]u8,
    salt: [16]u8,
    nonce_prefix: [8]u8,

    pub fn init(algorithm: EncryptionAlgorithm, key: [32]u8, salt: [16]u8) EncryptionContext {
        return .{
            .algorithm = algorithm,
            .key = key,
            .salt = salt,
            .nonce_prefix = utils.randomBytesFixed(8),
        };
    }

    pub fn deriveKey(
        password: []const u8,
        salt: [16]u8,
        iterations: u32,
        algorithm: EncryptionAlgorithm,
    ) ![32]u8 {
        // Use PBKDF2-HMAC-SHA256 for key derivation
        // This uses the standard-library HMAC primitive
        const hmac = std.crypto.auth.hmac.Hmac(std.crypto.hash.sha2.Sha256);

        if (iterations == 0) return CryptoError.KeyDerivationFailed;
        const key = password;
        var dk: [32]u8 = undefined;

        // PBKDF2 with HMAC-SHA256
        var u: [32]u8 = undefined;
        var mac = hmac.init(key);
        mac.update(salt);
        // Block index = 1 (big endian)
        const block_idx: [4]u8 = .{0, 0, 0, 1};
        mac.update(block_idx);
        mac.final(&u);

        @memcpy(dk[0..32], u[0..32]);

        for (1..iterations) |i| {
            mac = hmac.init(key);
            mac.update(u);
            mac.final(&u);
            for (0..32) |j| {
                dk[j] ^= u[j];
            }
        }

        _ = algorithm; // Algorithm-specific key expansion is not implemented.
        return dk;
    }

    pub fn encrypt(
        self: *Self,
        plaintext: []const u8,
        associated_data: []const u8,
        nonce: ?[12]u8,
    ) !struct {
        ciphertext: []u8,
        tag: [16]u8,
        nonce: [12]u8,
    } {
        if (self.algorithm == .NONE) {
            const copy = try std.heap.page_allocator.dupe(u8, plaintext);
            return .{
                .ciphertext = copy,
                .tag = [_]u8{0} ** 16,
                .nonce = nonce orelse [_]u8{0} ** 12,
            };
        }
        _ = associated_data;
        _ = nonce;
        return CryptoError.UnsupportedAlgorithm;
    }

    pub fn decrypt(
        self: *Self,
        ciphertext: []const u8,
        tag: [16]u8,
        nonce: [12]u8,
        associated_data: []const u8,
    ) ![]u8 {
        if (self.algorithm == .NONE) {
            return try std.heap.page_allocator.dupe(u8, ciphertext);
        }
        _ = tag;
        _ = nonce;
        _ = associated_data;
        return CryptoError.UnsupportedAlgorithm;
    }

};

// Per-file encryption key management
pub const FileEncryptionKey = struct {
    // Encrypted file key (wrapped with volume master key)
    wrapped_key: [48]u8, // 32 bytes key + 16 bytes auth tag
    algorithm: EncryptionAlgorithm,
    key_id: u32,
    flags: u16,

    pub fn wrap(
        volume_master_key: [32]u8,
        file_key: [32]u8,
        algorithm: EncryptionAlgorithm,
    ) !FileEncryptionKey {
        _ = volume_master_key;
        _ = file_key;
        _ = algorithm;
        return CryptoError.UnsupportedAlgorithm;
    }

    pub fn unwrap(
        self: FileEncryptionKey,
        volume_master_key: [32]u8,
    ) ![32]u8 {
        _ = self;
        _ = volume_master_key;
        return CryptoError.UnsupportedAlgorithm;
    }
};

// Volume master key management
pub const VolumeKeyManager = struct {
    const Self = @This();
    master_key: [32]u8,
    key_id: u32,
    derivation_params: KeyDerivationParams,

    pub const KeyDerivationParams = struct {
        algorithm: EncryptionAlgorithm = .AES256_GCM;
        kdf_algorithm: u8 = 1; // 1=PBKDF2, 2=Argon2id
        iterations: u32 = 100000;
        salt: [16]u8 = [_]u8{} ** 16;
        memory_cost: u32 = 65536; // KiB for Argon2
        parallelism: u32 = 4;
    };

    pub fn createFromPassword(
        password: []const u8,
        params: KeyDerivationParams,
    ) !VolumeKeyManager {
        const salt = params.salt;
        const master_key = try EncryptionContext.deriveKey(
            password,
            salt,
            params.iterations,
            params.algorithm,
        );

        return .{
            .master_key = master_key,
            .key_id = 1,
            .derivation_params = params,
        };
    }

    pub fn createRandom() !VolumeKeyManager {
        return .{
            .master_key = utils.randomBytesFixed(32),
            .key_id = 1,
            .derivation_params = KeyDerivationParams{
                .salt = utils.randomBytesFixed(16),
            },
        };
    }

    pub fn deriveFileKey(self: *Self, file_id: u64) [32]u8 {
        var hasher = integrity.Blake3.Hasher.init();
        hasher.update(&self.master_key);
        var file_id_bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &file_id_bytes, file_id, .little);
        hasher.update(&file_id_bytes);
        return hasher.finalize();
    }

    pub fn changePassword(
        self: *Self,
        old_password: []const u8,
        new_password: []const u8,
    ) !VolumeKeyManager {
        // Verify old password can derive master key
        // Then re-encrypt with new password
        _ = self;
        _ = old_password;
        _ = new_password;
        return CryptoError.UnsupportedAlgorithm;
    }
};

// Encryption metadata stored in UFS_INTERNAL namespace
pub const EncryptionMetadata = struct {
    algorithm: EncryptionAlgorithm,
    key_id: u32,
    wrapped_key: [48]u8,
    nonce_prefix: [8]u8,
    kdf_params: VolumeKeyManager.KeyDerivationParams,

    pub fn serialize(self: EncryptionMetadata, writer: *serialization.Writer(void)) !void {
        try writer.writeU8(@as(u8, @intCast(self.algorithm)));
        try writer.writeU32(self.key_id);
        try writer.writeBytes(&self.wrapped_key);
        try writer.writeBytes(&self.nonce_prefix);
        // KDF params
        try writer.writeU8(self.kdf_params.kdf_algorithm);
        try writer.writeU32(self.kdf_params.iterations);
        try writer.writeBytes(&self.kdf_params.salt);
        try writer.writeU32(self.kdf_params.memory_cost);
        try writer.writeU32(self.kdf_params.parallelism);
    }

    pub fn deserialize(reader: *serialization.Reader(void), allocator: Allocator) !EncryptionMetadata {
        return .{
            .algorithm = @as(EncryptionAlgorithm, @enumFromInt(try reader.readU8())),
            .key_id = try reader.readU32(),
            .wrapped_key = try reader.readArray(48),
            .nonce_prefix = try reader.readArray(8),
            .kdf_params = .{
                .kdf_algorithm = try reader.readU8(),
                .iterations = try reader.readU32(),
                .salt = try reader.readArray(16),
                .memory_cost = try reader.readU32(),
                .parallelism = try reader.readU32(),
            },
        };
    }
};

const serialization = @import("serialization.zig");const Allocator = std.mem.Allocator;
