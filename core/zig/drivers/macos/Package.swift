// swift-tools-version:5.9
// UFS FileProvider Extension Package
// Build with: swift build -c release
// Xcode project: swift package generate-xcodeproj

import PackageDescription

let package = Package(
    name: "UFSFileProvider",
    platforms: [
        .macOS(.v13)  // Ventura+ required for FileProvider
    ],
    products: [
        .executable(name: "UFSFileProvider", targets: ["UFSFileProvider"]),
        .library(name: "UFSCore", targets: ["UFSCore"]),
    ],
    dependencies: [
        // No external dependencies - uses system frameworks only
    ],
    targets: [
        // Main FileProvider Extension
        .executableTarget(
            name: "UFSFileProvider",
            dependencies: ["UFSCore"],
            path: "Sources/UFSFileProvider",
            resources: [
                .process("Resources/Info.plist"),
                .process("Resources/Entitlements.plist"),
            ],
            linkerSettings: [
                .linkedLibrary("ufs_core"),  // Zig-built static library
                .linkedFramework("FileProvider"),
                .linkedFramework("Foundation"),
                .linkedFramework("OSLog"),
                .linkedFramework("UniformTypeIdentifiers"),
                .unsafeFlags(["-L", "../zig/zig-out/lib"]),
            ]
        ),

        // Swift wrapper for UFS C API
        .target(
            name: "UFSCore",
            dependencies: [],
            path: "Sources/UFSCore",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("../../zig/src"),
                .define("UFS_SWIFT_WRAPPER"),
            ],
            linkerSettings: [
                .linkedLibrary("ufs_core"),
                .unsafeFlags(["-L", "../zig/zig-out/lib"]),
            ]
        ),

        // Kernel Extension (built separately via Xcode)
        // See UFSKext/ directory for FSKit kernel extension
    ]
)