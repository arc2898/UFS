// UFS Compression Pipeline
// LZ4, ZSTD with heuristic incompressible detection
// Per-extent compression with BLAKE3 integrity

const std = @import("std");
const utils = @import("utils.zig");
const Allocator = std.mem.Allocator;

pub const CompressionError = error{
    InvalidAlgorithm,
    CompressionFailed,
    DecompressionFailed,
    BufferTooSmall,
    CorruptedData,
    UnsupportedAlgorithm,
    OutOfMemory,
};

pub const CompressionAlgorithm = enum(u16) {
    NONE = 0,
    LZ4 = 1,
    ZSTD = 2,
    ZSTD_HIGH = 3,
};

pub const CompressionFlags = packed struct {
    verify_checksum: bool = true,
    allow_incompressible: bool = true,
    hint_incompressible: bool = false,
};

pub const CompressionResult = struct {
    algorithm: CompressionAlgorithm,
    original_size: usize,
    compressed_size: usize,
    checksum: [32]u8, // BLAKE3
};

pub const CompressionContext = struct {
    const Self = @This();
    algorithm: CompressionAlgorithm,
    level: i32 = 3,
    allocator: Allocator,

    // LZ4 context
    lz4_ctx: ?*anyopaque = null,

    // ZSTD context
    zstd_ctx: ?*anyopaque = null,

    pub fn init(allocator: Allocator, algorithm: CompressionAlgorithm, level: i32) !CompressionContext {
        var ctx = CompressionContext{
            .algorithm = algorithm,
            .level = level,
            .allocator = allocator,
        };

        // Initialize algorithm-specific contexts
        switch (algorithm) {
            .LZ4 => {
                // LZ4 doesn't need persistent context for basic compression
            },
            .ZSTD, .ZSTD_HIGH => {
                // ZSTD context creation would go here
                // Using system ZSTD library via FFI
            },
            .NONE => {},
        }

        return ctx;
    }

    pub fn deinit(self: *Self) void {
        // Clean up algorithm-specific contexts
        _ = self;
    }

    pub fn compress(self: *Self, input: []const u8, output: []u8) !CompressionResult {
        switch (self.algorithm) {
            .NONE => {
                if (output.len < input.len) return CompressionError.BufferTooSmall;
                @memcpy(output[0..input.len], input);
                return .{
                    .algorithm = .NONE,
                    .original_size = input.len,
                    .compressed_size = input.len,
                    .checksum = utils.blake3(input),
                };
            },
            .LZ4 => {
                return try self.compressLZ4(input, output);
            },
            .ZSTD => {
                return try self.compressZSTD(input, output, 3);
            },
            .ZSTD_HIGH => {
                return try self.compressZSTD(input, output, 12);
            },
        }
    }

    pub fn decompress(self: *Self, input: []const u8, output: []u8, original_size: usize) !usize {
        switch (self.algorithm) {
            .NONE => {
                if (output.len < input.len) return CompressionError.BufferTooSmall;
                @memcpy(output[0..input.len], input);
                return input.len;
            },
            .LZ4 => {
                return try self.decompressLZ4(input, output, original_size);
            },
            .ZSTD, .ZSTD_HIGH => {
                return try self.decompressZSTD(input, output, original_size);
            },
        }
    }

    // LZ4 compression via FFI
    fn compressLZ4(self: *Self, input: []const u8, output: []u8) !CompressionResult {
        // LZ4_compress_default returns compressed size or 0 on failure
        // For now, use a simple implementation or std.compress.LZ4 if available
        const max_dst_size = lz4_compressBound(input.len);
        if (output.len < max_dst_size) return CompressionError.BufferTooSmall;

        const compressed_size = lz4_compress_default(
            input.ptr,
            output.ptr,
            input.len,
            output.len,
        );

        if (compressed_size <= 0) return CompressionError.CompressionFailed;

        // Check if compression actually helped
        if (@as(usize, @intCast(compressed_size)) >= input.len) {
            // Incompressible - store uncompressed
            @memcpy(output[0..input.len], input);
            return .{
                .algorithm = .NONE,
                .original_size = input.len,
                .compressed_size = input.len,
                .checksum = utils.blake3(input),
            };
        }

        return .{
            .algorithm = .LZ4,
            .original_size = input.len,
            .compressed_size = @as(usize, @intCast(compressed_size)),
            .checksum = utils.blake3(output[0..compressed_size]),
        };
    }

    fn decompressLZ4(self: *Self, input: []const u8, output: []u8, original_size: usize) !usize {
        if (output.len < original_size) return CompressionError.BufferTooSmall;

        const decompressed_size = lz4_decompress_safe(
            input.ptr,
            output.ptr,
            input.len,
            original_size,
        );

        if (decompressed_size < 0) return CompressionError.DecompressionFailed;
        return @as(usize, @intCast(decompressed_size));
    }

    // ZSTD compression via FFI
    fn compressZSTD(self: *Self, input: []const u8, output: []u8, level: i32) !CompressionResult {
        const max_dst_size = zstd_compressBound(input.len);
        if (output.len < max_dst_size) return CompressionError.BufferTooSmall;

        const compressed_size = zstd_compress(
            output.ptr,
            output.len,
            input.ptr,
            input.len,
            level,
        );

        if (zstd_isError(compressed_size)) return CompressionError.CompressionFailed;

        if (@as(usize, @intCast(compressed_size)) >= input.len) {
            @memcpy(output[0..input.len], input);
            return .{
                .algorithm = .NONE,
                .original_size = input.len,
                .compressed_size = input.len,
                .checksum = utils.blake3(input),
            };
        }

        return .{
            .algorithm = .ZSTD,
            .original_size = input.len,
            .compressed_size = @as(usize, @intCast(compressed_size)),
            .checksum = utils.blake3(output[0..compressed_size]),
        };
    }

    fn decompressZSTD(self: *Self, input: []const u8, output: []u8, original_size: usize) !usize {
        if (output.len < original_size) return CompressionError.BufferTooSmall;

        const decompressed_size = zstd_decompress(
            output.ptr,
            output.len,
            input.ptr,
            input.len,
        );

        if (zstd_isError(decompressed_size)) return CompressionError.DecompressionFailed;
        return @as(usize, @intCast(decompressed_size));
    }
};

// Heuristic incompressible detection
pub const IncompressibleDetector = struct {
    // Sample first N bytes and check entropy
    pub fn isIncompressible(data: []const u8, sample_size: usize) bool {
        if (data.len < 64) return false; // Too small to judge

        const sample = data[0..@min(sample_size, data.len)];
        var byte_counts: [256]u16 = undefined;
        @memset(&byte_counts, 0);

        for (sample) |b| {
            byte_counts[b] += 1;
        }

        // Calculate Shannon entropy
        var entropy: f64 = 0;
        for (byte_counts) |count| {
            if (count > 0) {
                const p = @as(f64, @intCast(count)) / @as(f64, @intCast(sample.len));
                entropy -= p * @log2(p);
            }
        }

        // High entropy (> 7.5 bits/byte) suggests incompressible
        return entropy > 7.5;
    }

    // Quick check for known incompressible patterns
    pub fn quickCheck(data: []const u8) bool {
        if (data.len < 16) return false;

        // Check for common compressed file signatures
        const signatures = [_][]const u8{
            "PK\3\4",      // ZIP
            "\x1f\x8b",    // GZIP
            "BZh",         // BZIP2
            "\xfd7zXZ",    // XZ
            "\x04\x22\x4d\x18", // LZ4 frame
            "\x28\xb5\x2f\xfd", // ZSTD
        };

        for (signatures) |sig| {
            if (data.len >= sig.len and std.mem.eql(u8, data[0..sig.len], sig)) {
                return true;
            }
        }

        // Check for high entropy in first 256 bytes
        return isIncompressible(data, 256);
    }
};

// Compression pipeline with automatic algorithm selection
pub const CompressionPipeline = struct {
    const Self = @This();
    allocator: Allocator,
    default_algorithm: CompressionAlgorithm = .LZ4,
    default_level: i32 = 3,
    enable_incompressible_detection: bool = true,

    pub fn init(allocator: Allocator) CompressionPipeline {
        return .{ .allocator = allocator };
    }

    pub fn compress(
        self: *Self,
        data: []const u8,
        algorithm: ?CompressionAlgorithm,
        level: ?i32,
    ) !CompressionResult {
        const algo = algorithm orelse self.default_algorithm;
        const lvl = level orelse self.default_level;

        // Check for incompressible data
        if (self.enable_incompressible_detection and algo != .NONE) {
            if (IncompressibleDetector.quickCheck(data)) {
                // Store uncompressed
                var output = try self.allocator.alloc(u8, data.len);
                @memcpy(output, data);
                return .{
                    .algorithm = .NONE,
                    .original_size = data.len,
                    .compressed_size = data.len,
                    .checksum = utils.blake3(data),
                };
            }
        }

        var ctx = try CompressionContext.init(self.allocator, algo, lvl);
        defer ctx.deinit();

        // Estimate output buffer size
        const max_size = switch (algo) {
            .NONE => data.len,
            .LZ4 => lz4_compressBound(data.len),
            .ZSTD, .ZSTD_HIGH => zstd_compressBound(data.len),
        };

        var output = try self.allocator.alloc(u8, @as(usize, @intCast(max_size)));
        defer self.allocator.free(output);

        return try ctx.compress(data, output);
    }

    pub fn decompress(
        self: *Self,
        data: []const u8,
        algorithm: CompressionAlgorithm,
        original_size: usize,
    ) ![]u8 {
        var ctx = try CompressionContext.init(self.allocator, algorithm, 0);
        defer ctx.deinit();

        var output = try self.allocator.alloc(u8, original_size);
        const decompressed = try ctx.decompress(data, output, original_size);

        if (decompressed != original_size) {
            self.allocator.free(output);
            return CompressionError.CorruptedData;
        }

        return output;
    }
};

// Extent compression info stored in UFS_INTERNAL namespace
pub const ExtentCompressionInfo = struct {
    algorithm: CompressionAlgorithm,
    original_size: u32,
    compressed_size: u32,
    checksum: [32]u8, // BLAKE3 of compressed data
    level: u16,
    flags: u16,

    pub fn serialize(self: ExtentCompressionInfo, writer: *serialization.Writer(void)) !void {
        try writer.writeU16(@as(u16, @intCast(self.algorithm)));
        try writer.writeU16(self.level);
        try writer.writeU16(self.flags);
        try writer.writeU16(0); // reserved
        try writer.writeU32(self.original_size);
        try writer.writeU32(self.compressed_size);
        try writer.writeBytes(&self.checksum);
    }

    pub fn deserialize(reader: *serialization.Reader(void), allocator: Allocator) !ExtentCompressionInfo {
        return .{
            .algorithm = @as(CompressionAlgorithm, @enumFromInt(try reader.readU16())),
            .level = try reader.readU16(),
            .flags = try reader.readU16(),
            .original_size = try reader.readU32(),
            .compressed_size = try reader.readU32(),
            .checksum = try reader.readArray(32),
        };
    }
};

// FFI declarations for LZ4
extern "c" {
    fn lz4_compressBound(input_size: c_int) c_int;
    fn lz4_compress_default(src: [*c]const u8, dst: [*c]u8, src_size: c_int, dst_capacity: c_int) c_int;
    fn lz4_decompress_safe(src: [*c]const u8, dst: [*c]u8, compressed_size: c_int, max_dst_size: c_int) c_int;
}

// FFI declarations for ZSTD
extern "c" {
    fn zstd_compressBound(src_size: usize) usize;
    fn zstd_compress(dst: [*c]u8, dst_capacity: usize, src: [*c]const u8, src_size: usize, compression_level: c_int) usize;
    fn zstd_decompress(dst: [*c]u8, dst_capacity: usize, src: [*c]const u8, compressed_size: usize) usize;
    fn zstd_isError(code: usize) bool;
}

// Fallback implementations if libraries not available
fn lz4_compressBound(input_size: c_int) c_int {
    return input_size + (input_size / 255) + 16;
}

fn lz4_compress_default(src: [*c]const u8, dst: [*c]u8, src_size: c_int, dst_capacity: c_int) c_int {
    // Simple fallback - no actual compression
    _ = src;
    _ = dst;
    _ = src_size;
    _ = dst_capacity;
    return 0; // Indicate failure
}

fn lz4_decompress_safe(src: [*c]const u8, dst: [*c]u8, compressed_size: c_int, max_dst_size: c_int) c_int {
    _ = src;
    _ = dst;
    _ = compressed_size;
    _ = max_dst_size;
    return -1;
}

fn zstd_compressBound(src_size: usize) usize {
    return src_size + src_size / 6 + 128;
}

fn zstd_compress(dst: [*c]u8, dst_capacity: usize, src: [*c]const u8, src_size: usize, compression_level: c_int) usize {
    _ = dst;
    _ = dst_capacity;
    _ = src;
    _ = src_size;
    _ = compression_level;
    return 0x80000000; // Error code
}

fn zstd_decompress(dst: [*c]u8, dst_capacity: usize, src: [*c]const u8, compressed_size: usize) usize {
    _ = dst;
    _ = dst_capacity;
    _ = src;
    _ = compressed_size;
    return 0x80000000;
}

fn zstd_isError(code: usize) bool {
    return (code & 0x80000000) != 0;
}