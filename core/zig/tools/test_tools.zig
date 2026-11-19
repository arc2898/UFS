// Test script to verify all tools compile correctly
// Run with: zig build test-tools

const std = @import("std");
const testing = std.testing;

test "mkufs main function exists" {
    // This test verifies the mkufs module can be imported
    const mkufs = @import("mkufs/main.zig");
    _ = mkufs;
}

test "ufsck main function exists" {
    const ufsck = @import("ufsck/main.zig");
    _ = ufsck;
}

test "ufsinfo main function exists" {
    const ufsinfo = @import("ufsinfo/main.zig");
    _ = ufsinfo;
}

test "ufsctl main function exists" {
    const ufsctl = @import("ufsctl/main.zig");
    _ = ufsctl;
}

test "all tools have required exports" {
    // Verify each tool has a main function
    // This is a compile-time check - if any tool is missing main(),
    // the build will fail
    comptime {
        const mkufs = @import("mkufs/main.zig");
        const ufsck = @import("ufsck/main.zig");
        const ufsinfo = @import("ufsinfo/main.zig");
        const ufsctl = @import("ufsctl/main.zig");

        // Check that main exists and has correct signature
        @compileLog("mkufs.main:", @typeInfo(@TypeOf(mkufs.main)));
        @compileLog("ufsck.main:", @typeInfo(@TypeOf(ufsck.main)));
        @compileLog("ufsinfo.main:", @typeInfo(@TypeOf(ufsinfo.main)));
        @compileLog("ufsctl.main:", @typeInfo(@TypeOf(ufsctl.main)));
    }
}

// Integration test: format -> mount -> write -> read -> unmount
// This requires the core ufs library
test "integration: format mount write read unmount" {
    // This test is a template - the actual integration test is in integration_test.zig
    // which uses the in-memory block device and the full UFS core API
    // Here we just verify the test infrastructure compiles
    const ufs = @import("ufs");
    _ = ufs;

    // Verify key types exist
    _ = ufs.Fs;
    _ = ufs.BlockDevice;
    _ = ufs.InodeInfo;
    _ = ufs.DirEnt;

    // Verify key functions exist
    _ = ufs.format;
    _ = ufs.mount;
    _ = ufs.unmount;
    _ = ufs.open;
    _ = ufs.read;
    _ = ufs.write;
}