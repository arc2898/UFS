// Compression Module
// LZ4, ZSTD with heuristic incompressible detection

const std = @import("std");

pub const CompressionError = @import("../src/compression.zig").CompressionError;
pub const CompressionAlgorithm = @import("../src/compression.zig").CompressionAlgorithm;
pub const CompressionFlags = @import("../src/compression.zig").CompressionFlags;
pub const CompressionResult = @import("../src/compression.zig").CompressionResult;
pub const CompressionContext = @import("../src/compression.zig").CompressionContext;
pub const IncompressibleDetector = @import("../src/compression.zig").IncompressibleDetector;
pub const CompressionPipeline = @import("../src/compression.zig").CompressionPipeline;
pub const ExtentCompressionInfo = @import("../src/compression.zig").ExtentCompressionInfo;

pub const Allocator = std.mem.Allocator;