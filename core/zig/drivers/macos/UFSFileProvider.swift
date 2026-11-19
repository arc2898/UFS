// UFSFileProvider.swift
// macOS FileProvider Extension for UFS
// Requires macOS 13+ (Ventura) and FileProvider framework

import FileProvider
import Foundation
import OSLog

// ============================================================================
// UFS Volume Wrapper (bridges to Zig C API)
// ============================================================================

class UFSVolume {
    let devicePath: String
    let mountOptions: MountOptions
    private var fsHandle: OpaquePointer? // ufs_fs_t*
    private var blockDevHandle: OpaquePointer? // ufs_block_device_t*

    init(devicePath: String, options: MountOptions) throws {
        self.devicePath = devicePath
        self.mountOptions = options

        // Open block device
        let blockDev = try BlockDevice(path: devicePath)
        self.blockDevHandle = blockDev.handle

        // Check recovery
        if ufs_needs_recovery(blockDev.handle) {
            try ufs_recover(blockDev.handle).throwIfError()
        }

        // Mount
        let mountOpts = UFSMountOptions(from: options)
        self.fsHandle = try ufs_mount(blockDev.handle, &mountOpts).throwIfError()
    }

    deinit {
        if let handle = fsHandle {
            ufs_unmount(handle)
        }
        if let handle = blockDevHandle {
            ufs_block_device_close(handle)
        }
    }

    func lookup(parentInode: UInt64, name: String) throws -> UInt64 {
        var inode: UInt64 = 0
        try ufs_lookup(fsHandle, parentInode, name, &inode).throwIfError()
        return inode
    }

    func getattr(inode: UInt64) throws -> FileAttributes {
        var info = UFSInodeInfo()
        try ufs_getattr(fsHandle, inode, &info).throwIfError()
        return FileAttributes(from: info)
    }

    func read(inode: UInt64, offset: UInt64, length: UInt64) throws -> Data {
        var data = Data(count: Int(length))
        var bytesRead: UInt64 = 0
        try data.withUnsafeMutableBytes { buffer in
            try ufs_read(fsHandle, inode, offset, buffer.baseAddress!, length, &bytesRead).throwIfError()
        }
        return data.prefix(Int(bytesRead))
    }

    func write(inode: UInt64, offset: UInt64, data: Data) throws -> UInt64 {
        var bytesWritten: UInt64 = 0
        try data.withUnsafeBytes { buffer in
            try ufs_write(fsHandle, inode, offset, buffer.baseAddress!, data.count, &bytesWritten).throwIfError()
        }
        return bytesWritten
    }

    func create(parentInode: UInt64, name: String, type: FileType, mode: UInt32) throws -> UInt64 {
        var inode: UInt64 = 0
        try ufs_create_inode(fsHandle, parentInode, name, type.rawValue, mode, getuid(), getgid(), &inode).throwIfError()
        return inode
    }

    func delete(parentInode: UInt64, name: String) throws {
        try ufs_delete_inode(fsHandle, parentInode, name).throwIfError()
    }

    func rename(oldParentInode: UInt64, oldName: String, newParentInode: UInt64, newName: String) throws {
        try ufs_rename(fsHandle, oldParentInode, oldName, newParentInode, newName).throwIfError()
    }

    func readdir(inode: UInt64, offset: UInt64) throws -> [DirEntry] {
        var iter: OpaquePointer?
        try ufs_opendir(fsHandle, inode, &iter).throwIfError()
        defer { ufs_closedir(fsHandle, iter) }

        var entries: [DirEntry] = []
        var entry = UFSDirEnt()
        while true {
            let result = ufs_readdir(fsHandle, iter, &entry)
            if result == UFS_ERROR_NOT_FOUND { break }
            try result.throwIfError()
            entries.append(DirEntry(from: entry))
        }
        return entries
    }

    func getxattr(inode: UInt64, name: String) throws -> Data {
        // Parse namespace from name
        let (ns, attrName) = parseXattrName(name)
        var size: UInt64 = 0
        let result = ufs_getxattr(fsHandle, inode, ns, 0, attrName, nil, 0, &size)
        if result == UFS_ERROR_BUFFER_TOO_SMALL {
            var data = Data(count: Int(size))
            try data.withUnsafeMutableBytes { buffer in
                try ufs_getxattr(fsHandle, inode, ns, 0, attrName, buffer.baseAddress!, size, &size).throwIfError()
            }
            return data
        }
        try result.throwIfError()
        return Data()
    }

    func setxattr(inode: UInt64, name: String, value: Data) throws {
        let (ns, attrName) = parseXattrName(name)
        try value.withUnsafeBytes { buffer in
            try ufs_setxattr(fsHandle, inode, ns, 0, attrName, buffer.baseAddress!, value.count, 0).throwIfError()
        }
    }

    func listxattr(inode: UInt64) throws -> [String] {
        var size: UInt64 = 0
        let result = ufs_listxattr(fsHandle, inode, nil, 0, &size)
        if result == UFS_ERROR_BUFFER_TOO_SMALL {
            var buffer = Data(count: Int(size))
            try buffer.withUnsafeMutableBytes { buf in
                try ufs_listxattr(fsHandle, inode, buf.baseAddress!.assumingMemoryBound(to: CChar.self), size, &size).throwIfError()
            }
            // Parse null-separated list
            let str = String(data: buffer, encoding: .utf8) ?? ""
            return str.split(separator: "\0").map(String.init)
        }
        try result.throwIfError()
        return []
    }

    func removexattr(inode: UInt64, name: String) throws {
        let (ns, attrName) = parseXattrName(name)
        try ufs_removexattr(fsHandle, inode, ns, 0, attrName).throwIfError()
    }

    func statfs() throws -> VolumeStats {
        var stat = UFSStatFs()
        try ufs_statfs(fsHandle, &stat).throwIfError()
        return VolumeStats(from: stat)
    }

    func sync(inode: UInt64) throws {
        try ufs_fsync(fsHandle, inode).throwIfError()
    }

    func checkpoint() throws {
        try ufs_checkpoint(fsHandle).throwIfError()
    }

    // Private helpers
    private func parseXattrName(_ name: String) -> (UInt16, String) {
        if name.hasPrefix("user.") {
            return (UFS_NS_POSIX_XATTR, String(name.dropFirst(5)))
        } else if name.hasPrefix("system.posix_acl") {
            return (UFS_NS_POSIX_ACL, String(name.dropFirst(16)))
        } else if name.hasPrefix("security.") {
            return (UFS_NS_POSIX_CAPS, String(name.dropFirst(9)))
        } else if name.hasPrefix("trusted.") {
            return (UFS_NS_UFS_INTERNAL, String(name.dropFirst(8)))
        } else if name.hasPrefix("com.apple.") {
            return (UFS_NS_MACOS_XATTR, String(name.dropFirst(10)))
        } else if name.hasPrefix("com.apple.metadata:") {
            return (UFS_NS_MACOS_FINDER, String(name.dropFirst(19)))
        } else if name.hasPrefix("com.apple.quarantine") {
            return (UFS_NS_MACOS_QUARANTINE, "quarantine")
        }
        return (UFS_NS_POSIX_XATTR, name)
    }
}

// ============================================================================
// Data Structures
// ============================================================================

struct MountOptions {
    let readOnly: Bool
    let caseInsensitive: Bool
    let compression: CompressionAlgorithm
    let integrityCheck: Bool
    let journalSize: UInt64
    let uid: uid_t
    let gid: gid_t
}

enum CompressionAlgorithm: UInt8 {
    case none = 0
    case lz4 = 1
    case zstd = 2
}

enum FileType: UInt8 {
    case regular = 1
    case directory = 2
    case symlink = 3
    case blockDevice = 4
    case charDevice = 5
    case fifo = 6
    case socket = 7
}

struct FileAttributes {
    let inode: UInt64
    let mode: UInt32
    let linkCount: UInt32
    let uid: uid_t
    let gid: gid_t
    let size: UInt64
    let allocatedSize: UInt64
    let atime: UInt64
    let mtime: UInt64
    let ctime: UInt64
    let creationTime: UInt64
    let fileType: FileType
    let attributes: UInt32

    init(from info: UFSInodeInfo) {
        self.inode = info.inode
        self.mode = info.mode
        self.linkCount = info.link_count
        self.uid = info.uid
        self.gid = info.gid
        self.size = info.size
        self.allocatedSize = info.allocated_size
        self.atime = info.atime
        self.mtime = info.mtime
        self.ctime = info.ctime
        self.creationTime = info.creation_time
        self.fileType = FileType(rawValue: info.file_type) ?? .regular
        self.attributes = info.attributes
    }
}

struct DirEntry {
    let inode: UInt64
    let name: String
    let type: FileType
    let size: UInt64

    init(from entry: UFSDirEnt) {
        self.inode = entry.inode
        self.name = String(cString: entry.name)
        self.type = FileType(rawValue: entry.file_type) ?? .regular
        self.size = entry.size
    }
}

struct VolumeStats {
    let totalSpace: UInt64
    let freeSpace: UInt64
    let totalInodes: UInt64
    let freeInodes: UInt64
    let clusterSize: UInt32
    let sectorSize: UInt32

    init(from stat: UFSStatFs) {
        self.totalSpace = stat.total_space
        self.freeSpace = stat.free_space
        self.totalInodes = stat.total_inodes
        self.freeInodes = stat.free_inodes
        self.clusterSize = stat.cluster_size
        self.sectorSize = stat.sector_size
    }
}

// ============================================================================
// UFS FileProvider Extension
// ============================================================================

class UFSFileProvider: NSFileProviderExtension {
    private let volume: UFSVolume
    private let logger = Logger(subsystem: "com.ufs.fileprovider", category: "UFSFileProvider")
    private let queue = DispatchQueue(label: "com.ufs.fileprovider.operations", qos: .userInitiated)

    // Item identifier mapping
    private var inodeToIdentifier: [UInt64: NSFileProviderItemIdentifier] = [:]
    private var identifierToInode: [NSFileProviderItemIdentifier: UInt64] = [:]
    private let identifierLock = NSLock()

    init(volume: UFSVolume) {
        self.volume = volume
        super.init()

        // Initialize identifier for root
        let rootIdentifier = NSFileProviderItemIdentifier.rootContainer
        inodeToIdentifier[2] = rootIdentifier
        identifierToInode[rootIdentifier] = 2
    }

    // MARK: - Item Enumeration

    override func enumerateItems(for identifier: NSFileProviderItemIdentifier,
                                request: NSFileProviderRequest,
                                completion: @escaping (Error?, [NSFileProviderItem]?, NSFileProviderEnumerationPage?) -> Void) {
        queue.async { [weak self] in
            guard let self = self else {
                completion(NSError(domain: "UFSFileProvider", code: -1, userInfo: nil), nil, nil)
                return
            }

            do {
                let inode = try self.inodeForIdentifier(identifier)
                let entries = try self.volume.readdir(inode: inode, offset: 0)

                var items: [NSFileProviderItem] = []
                for entry in entries {
                    let item = UFSFileProviderItem(entry: entry, volume: self.volume)
                    items.append(item)

                    // Cache identifier mapping
                    self.cacheIdentifier(for: entry.inode, item: item)
                }

                let page = NSFileProviderEnumerationPage(items: items, hasMore: false)
                completion(nil, items, page)
            } catch {
                self.logger.error("Enumerate items failed: \(error.localizedDescription)")
                completion(error, nil, nil)
            }
        }
    }

    override func fetchThumbnails(for itemIdentifiers: [NSFileProviderItemIdentifier],
                                 requestedSize: CGSize,
                                 completion: @escaping (Error?) -> Void) {
        // UFS doesn't generate thumbnails natively
        completion(nil)
    }

    // MARK: - Item Changes

    override func createItem(withName name: String,
                            inParentWithIdentifier parentIdentifier: NSFileProviderItemIdentifier,
                            contents: NSFileProviderItemContents?,
                            options: NSFileProviderCreateItemOptions,
                            completion: @escaping (Error?, NSFileProviderItem?) -> Void) {
        queue.async { [weak self] in
            guard let self = self else {
                completion(NSError(domain: "UFSFileProvider", code: -1, userInfo: nil), nil)
                return
            }

            do {
                let parentInode = try self.inodeForIdentifier(parentIdentifier)
                let type: FileType = options.contains(.directory) ? .directory : .regular
                let mode: UInt32 = options.contains(.directory) ? 0o755 : 0o644

                let inode = try self.volume.create(parentInode: parentInode, name: name, type: type, mode: mode)

                // Write contents if provided
                if let contents = contents {
                    try self.writeContents(inode: inode, contents: contents)
                }

                let item = UFSFileProviderItem(inode: inode, name: name, type: type, volume: self.volume)
                self.cacheIdentifier(for: inode, item: item)

                completion(nil, item)
            } catch {
                self.logger.error("Create item failed: \(error.localizedDescription)")
                completion(error, nil)
            }
        }
    }

    override func modifyItem(_ item: NSFileProviderItem,
                            baseVersion: NSFileProviderItemVersion,
                            changedFields: NSFileProviderItemFields,
                            contents: NSFileProviderItemContents?,
                            options: NSFileProviderModifyItemOptions,
                            completion: @escaping (Error?, NSFileProviderItem?) -> Void) {
        queue.async { [weak self] in
            guard let self = self else {
                completion(NSError(domain: "UFSFileProvider", code: -1, userInfo: nil), nil)
                return
            }

            do {
                let inode = try self.inodeForIdentifier(item.itemIdentifier)

                // Handle content changes
                if changedFields.contains(.contents) && contents != nil {
                    try self.writeContents(inode: inode, contents: contents!)
                }

                // Handle metadata changes
                if changedFields.contains(.attributes) {
                    try self.updateAttributes(inode: inode, item: item)
                }

                // Handle rename
                if changedFields.contains(.name) {
                    let parentInode = try self.inodeForIdentifier(item.parentItemIdentifier)
                    try self.volume.rename(oldParentInode: parentInode, oldName: item.filename,
                                           newParentInode: parentInode, newName: item.filename)
                }

                let updatedItem = UFSFileProviderItem(inode: inode, volume: self.volume)
                completion(nil, updatedItem)
            } catch {
                self.logger.error("Modify item failed: \(error.localizedDescription)")
                completion(error, nil)
            }
        }
    }

    override func deleteItems(withIdentifiers identifiers: [NSFileProviderItemIdentifier],
                             options: NSFileProviderDeleteItemOptions,
                             completion: @escaping (Error?) -> Void) {
        queue.async { [weak self] in
            guard let self = self else {
                completion(NSError(domain: "UFSFileProvider", code: -1, userInfo: nil))
                return
            }

            do {
                for identifier in identifiers {
                    let inode = try self.inodeForIdentifier(identifier)
                    let parentInode = try self.inodeForIdentifier(
                        NSFileProviderItemIdentifier(rawValue: String(identifier.rawValue.split(separator: "/").dropLast().joined(separator: "/")))
                    )
                    // Get name from identifier (simplified)
                    let name = identifier.rawValue.split(separator: "/").last.map(String.init) ?? ""
                    try self.volume.delete(parentInode: parentInode, name: name)
                    self.removeIdentifierCache(for: inode)
                }
                completion(nil)
            } catch {
                self.logger.error("Delete items failed: \(error.localizedDescription)")
                completion(error)
            }
        }
    }

    override func renameItem(withIdentifier identifier: NSFileProviderItemIdentifier,
                            toName newName: String,
                            completion: @escaping (Error?, NSFileProviderItem?) -> Void) {
        queue.async { [weak self] in
            guard let self = self else {
                completion(NSError(domain: "UFSFileProvider", code: -1, userInfo: nil), nil)
                return
            }

            do {
                let inode = try self.inodeForIdentifier(identifier)
                let parentInode = try self.inodeForIdentifier(item.parentItemIdentifier)
                let oldName = identifier.rawValue.split(separator: "/").last.map(String.init) ?? ""

                try self.volume.rename(oldParentInode: parentInode, oldName: oldName,
                                       newParentInode: parentInode, newName: newName)

                let updatedItem = UFSFileProviderItem(inode: inode, name: newName, volume: self.volume)
                self.updateIdentifierCache(for: inode, newName: newName)
                completion(nil, updatedItem)
            } catch {
                self.logger.error("Rename item failed: \(error.localizedDescription)")
                completion(error, nil)
            }
        }
    }

    // MARK: - Working Set

    override func providePlaceholder(at url: URL, completion: @escaping (Error?) -> Void) {
        // UFS doesn't use placeholders - all data is local
        completion(nil)
    }

    override func startProvidingItem(at url: URL, completion: @escaping (Error?) -> Void) {
        // Data is already local
        completion(nil)
    }

    override func stopProvidingItem(at url: URL) {
        // No-op for local filesystem
    }

    // MARK: - Extended Attributes

    override func fetchExtendedAttributes(forItemWithIdentifier identifier: NSFileProviderItemIdentifier,
                                         completion: @escaping (Error?, [String: Data]?) -> Void) {
        queue.async { [weak self] in
            guard let self = self else {
                completion(NSError(domain: "UFSFileProvider", code: -1, userInfo: nil), nil)
                return
            }

            do {
                let inode = try self.inodeForIdentifier(identifier)
                let names = try self.volume.listxattr(inode: inode)

                var attributes: [String: Data] = [:]
                for name in names {
                    let data = try self.volume.getxattr(inode: inode, name: name)
                    attributes[name] = data
                }
                completion(nil, attributes)
            } catch {
                self.logger.error("Fetch xattrs failed: \(error.localizedDescription)")
                completion(error, nil)
            }
        }
    }

    override func modifyExtendedAttributes(_ attributes: [String: Data],
                                          forItemWithIdentifier identifier: NSFileProviderItemIdentifier,
                                          completion: @escaping (Error?) -> Void) {
        queue.async { [weak self] in
            guard let self = self else {
                completion(NSError(domain: "UFSFileProvider", code: -1, userInfo: nil))
                return
            }

            do {
                let inode = try self.inodeForIdentifier(identifier)
                for (name, data) in attributes {
                    try self.volume.setxattr(inode: inode, name: name, value: data)
                }
                completion(nil)
            } catch {
                self.logger.error("Modify xattrs failed: \(error.localizedDescription)")
                completion(error)
            }
        }
    }

    // MARK: - Replication/Backup

    override func provideItemVisibility(_ item: NSFileProviderItem,
                                       completion: @escaping (Error?, NSFileProviderItemVisibility) -> Void) {
        completion(nil, .visible)
    }

    // MARK: - Helpers

    private func inodeForIdentifier(_ identifier: NSFileProviderItemIdentifier) throws -> UInt64 {
        identifierLock.lock()
        defer { identifierLock.unlock() }

        if identifier == .rootContainer {
            return 2
        }

        if let inode = identifierToInode[identifier] {
            return inode
        }

        // Parse inode from identifier (format: "inode/<number>")
        let components = identifier.rawValue.split(separator: "/")
        if components.count == 2, components[0] == "inode", let inode = UInt64(components[1]) {
            return inode
        }

        throw NSError(domain: "UFSFileProvider", code: -1,
                      userInfo: [NSLocalizedDescriptionKey: "Invalid identifier: \(identifier.rawValue)"])
    }

    private func cacheIdentifier(for inode: UInt64, item: UFSFileProviderItem) {
        identifierLock.lock()
        defer { identifierLock.unlock() }

        let identifier = NSFileProviderItemIdentifier(rawValue: "inode/\(inode)")
        inodeToIdentifier[inode] = identifier
        identifierToInode[identifier] = inode
        item.itemIdentifier = identifier
    }

    private func updateIdentifierCache(for inode: UInt64, newName: String) {
        identifierLock.lock()
        defer { identifierLock.unlock() }

        let identifier = NSFileProviderItemIdentifier(rawValue: "inode/\(inode)")
        inodeToIdentifier[inode] = identifier
        identifierToInode[identifier] = inode
    }

    private func removeIdentifierCache(for inode: UInt64) {
        identifierLock.lock()
        defer { identifierLock.unlock() }

        if let identifier = inodeToIdentifier[inode] {
            identifierToInode.removeValue(forKey: identifier)
            inodeToIdentifier.removeValue(forKey: inode)
        }
    }

    private func writeContents(inode: UInt64, contents: NSFileProviderItemContents) throws {
        // Write file contents from NSFileProviderItemContents
        // This would read from the contents provider and write to UFS
    }

    private func updateAttributes(inode: UInt64, item: NSFileProviderItem) throws {
        // Update file attributes
    }
}

// ============================================================================
// UFS FileProvider Item
// ============================================================================

class UFSFileProviderItem: NSObject, NSFileProviderItem {
    var itemIdentifier: NSFileProviderItemIdentifier
    var parentItemIdentifier: NSFileProviderItemIdentifier
    var filename: String
    var typeIdentifier: String
    var contentType: UTType?
    var capabilities: NSFileProviderItemCapabilities
    var documentSize: NSNumber?
    var creationDate: Date?
    var lastUsedDate: Date?
    var contentModificationDate: Date?
    var metadataModificationDate: Date?

    init(entry: DirEntry, volume: UFSVolume) {
        self.itemIdentifier = NSFileProviderItemIdentifier(rawValue: "inode/\(entry.inode)")
        self.parentItemIdentifier = .rootContainer // Simplified
        self.filename = entry.name
        self.typeIdentifier = entry.type == .directory ? UTType.folder.identifier : UTType.data.identifier
        self.capabilities = entry.type == .directory ?
            [.allowsReading, .allowsWriting, .allowsDeleting, .allowsRenaming, .allowsSubItems] :
            [.allowsReading, .allowsWriting, .allowsDeleting, .allowsRenaming]
        super.init()
    }

    init(inode: UInt64, name: String, type: FileType, volume: UFSVolume) {
        self.itemIdentifier = NSFileProviderItemIdentifier(rawValue: "inode/\(inode)")
        self.parentItemIdentifier = .rootContainer
        self.filename = name
        self.typeIdentifier = type == .directory ? UTType.folder.identifier : UTType.data.identifier
        self.capabilities = type == .directory ?
            [.allowsReading, .allowsWriting, .allowsDeleting, .allowsRenaming, .allowsSubItems] :
            [.allowsReading, .allowsWriting, .allowsDeleting, .allowsRenaming]
        super.init()
    }

    init(inode: UInt64, volume: UFSVolume) {
        self.itemIdentifier = NSFileProviderItemIdentifier(rawValue: "inode/\(inode)")
        self.parentItemIdentifier = .rootContainer
        self.filename = ""
        self.typeIdentifier = UTType.data.identifier
        self.capabilities = [.allowsReading, .allowsWriting, .allowsDeleting, .allowsRenaming]
        super.init()
    }
}

// ============================================================================
// XPC Kernel Protocol
// ============================================================================

@objc protocol UFSKernelProtocol {
    func lookup(parentInode: UInt64, name: String, reply: @escaping (UInt64?, Error?) -> Void)
    func getattr(inode: UInt64, reply: @escaping (FileAttributes?, Error?) -> Void)
    func read(inode: UInt64, offset: UInt64, length: UInt64, reply: @escaping (Data?, Error?) -> Void)
    func write(inode: UInt64, offset: UInt64, data: Data, reply: @escaping (UInt64, Error?) -> Void)
    func create(parentInode: UInt64, name: String, type: UInt8, mode: UInt32, reply: @escaping (UInt64?, Error?) -> Void)
    func remove(parentInode: UInt64, name: String, reply: @escaping (Error?) -> Void)
    func rename(oldParentInode: UInt64, oldName: String, newParentInode: UInt64, newName: String, reply: @escaping (Error?) -> Void)
    func readdir(inode: UInt64, offset: UInt64, reply: @escaping ([DirEntry]?, Error?) -> Void)
    func getxattr(inode: UInt64, name: String, reply: @escaping (Data?, Error?) -> Void)
    func setxattr(inode: UInt64, name: String, value: Data, flags: UInt32, reply: @escaping (Error?) -> Void)
    func listxattr(inode: UInt64, reply: @escaping ([String]?, Error?) -> Void)
    func removexattr(inode: UInt64, name: String, reply: @escaping (Error?) -> Void)
    func sync(inode: UInt64, reply: @escaping (Error?) -> Void)
    func statfs(reply: @escaping (VolumeStats?, Error?) -> Void)
}

// ============================================================================
// C Bridge Definitions (from ufs.h)
// ============================================================================

// These would be imported via bridging header from ufs.h
// typedef struct ufs_fs_t ufs_fs_t;
// typedef struct ufs_block_device_t ufs_block_device_t;
// typedef struct ufs_inode_info_t { ... } ufs_inode_info_t;
// typedef struct ufs_statfs_t { ... } ufs_statfs_t;
// typedef struct ufs_dirent_t { ... } ufs_dirent_t;
//
// int ufs_mount(ufs_block_device_t*, const ufs_mount_options_t*, ufs_fs_t**);
// int ufs_unmount(ufs_fs_t*);
// int ufs_lookup(ufs_fs_t*, uint64_t, const char*, uint64_t*);
// int ufs_getattr(ufs_fs_t*, uint64_t, ufs_inode_info_t*);
// int ufs_read(ufs_fs_t*, uint64_t, uint64_t, void*, size_t, size_t*);
// int ufs_write(ufs_fs_t*, uint64_t, uint64_t, const void*, size_t, size_t*);
// int ufs_create_inode(ufs_fs_t*, uint64_t, const char*, uint8_t, uint32_t, uid_t, gid_t, uint64_t*);
// int ufs_delete_inode(ufs_fs_t*, uint64_t, const char*);
// int ufs_rename(ufs_fs_t*, uint64_t, const char*, uint64_t, const char*);
// int ufs_opendir(ufs_fs_t*, uint64_t, ufs_dir_iter_t**);
// int ufs_readdir(ufs_fs_t*, ufs_dir_iter_t*, ufs_dirent_t*);
// int ufs_closedir(ufs_fs_t*, ufs_dir_iter_t*);
// int ufs_getxattr(ufs_fs_t*, uint64_t, uint16_t, uint16_t, const char*, void*, size_t, size_t*);
// int ufs_setxattr(ufs_fs_t*, uint64_t, uint16_t, uint16_t, const char*, const void*, size_t, int);
// int ufs_listxattr(ufs_fs_t*, uint64_t, char*, size_t, size_t*);
// int ufs_removexattr(ufs_fs_t*, uint64_t, uint16_t, uint16_t, const char*);
// int ufs_statfs(ufs_fs_t*, ufs_statfs_t*);
// int ufs_fsync(ufs_fs_t*, uint64_t);
// int ufs_checkpoint(ufs_fs_t*);
// int ufs_needs_recovery(ufs_block_device_t*);
// int ufs_recover(ufs_block_device_t*);
// int ufs_block_device_open(const char*, int, ufs_block_device_t**);
// void ufs_block_device_close(ufs_block_device_t*);

// ============================================================================
// Error Handling
// ============================================================================

extension Int32 {
    func throwIfError() throws {
        if self != 0 {
            throw UFSError(code: self)
        }
    }
}

enum UFSError: Error, LocalizedError {
    case ioError
    case notFound
    case permissionDenied
    case noSpace
    case corrupted
    case invalidFormat
    case unsupportedFeature
    case unknown(Int32)

    init(code: Int32) {
        switch code {
        case UFS_ERROR_IO: self = .ioError
        case UFS_ERROR_NOT_FOUND: self = .notFound
        case UFS_ERROR_PERMISSION_DENIED: self = .permissionDenied
        case UFS_ERROR_OUT_OF_SPACE: self = .noSpace
        case UFS_ERROR_CORRUPTED_DATA: self = .corrupted
        case UFS_ERROR_INVALID_FORMAT: self = .invalidFormat
        case UFS_ERROR_UNSUPPORTED_FEATURE: self = .unsupportedFeature
        default: self = .unknown(code)
        }
    }

    var errorDescription: String? {
        switch self {
        case .ioError: return "I/O error"
        case .notFound: return "Item not found"
        case .permissionDenied: return "Permission denied"
        case .noSpace: return "No space left on device"
        case .corrupted: return "Filesystem corrupted"
        case .invalidFormat: return "Invalid format"
        case .unsupportedFeature: return "Unsupported feature"
        case .unknown(let code): return "Unknown error: \(code)"
        }
    }
}

// ============================================================================
// Constants (matching ufs.h)
// ============================================================================

let UFS_NS_POSIX_XATTR: UInt16 = 0x0001
let UFS_NS_POSIX_ACL: UInt16 = 0x0002
let UFS_NS_POSIX_CAPS: UInt16 = 0x0003
let UFS_NS_UFS_INTERNAL: UInt16 = 0x0004
let UFS_NS_MACOS_XATTR: UInt16 = 0x4001
let UFS_NS_MACOS_FINDER: UInt16 = 0x4002
let UFS_NS_MACOS_QUARANTINE: UInt16 = 0x4003
let UFS_NS_MACOS_RESOURCE_FORK: UInt16 = 0x4004

let UFS_ERROR_OK: Int32 = 0
let UFS_ERROR_OUT_OF_MEMORY: Int32 = -1
let UFS_ERROR_INVALID_ARGUMENT: Int32 = -2
let UFS_ERROR_IO: Int32 = -3
let UFS_ERROR_NOT_FOUND: Int32 = -4
let UFS_ERROR_ALREADY_EXISTS: Int32 = -5
let UFS_ERROR_PERMISSION_DENIED: Int32 = -6
let UFS_ERROR_CORRUPTED_DATA: Int32 = -7
let UFS_ERROR_UNSUPPORTED_FEATURE: Int32 = -8
let UFS_ERROR_BUFFER_TOO_SMALL: Int32 = -9
let UFS_ERROR_INVALID_FORMAT: Int32 = -10
let UFS_ERROR_INTERNAL: Int32 = -11
let UFS_ERROR_OUT_OF_SPACE: Int32 = -12
let UFS_ERROR_ALIGNMENT: Int32 = -13
let UFS_ERROR_FRAGMENTED: Int32 = -14
let UFS_ERROR_NOT_INITIALIZED: Int32 = -15
let UFS_ERROR_WRITE_PROTECTED: Int32 = -16
let UFS_ERROR_DEVICE_NOT_FOUND: Int32 = -17
let UFS_ERROR_UNSUPPORTED_OPERATION: Int32 = -18
let UFS_ERROR_TIMEOUT: Int32 = -19

// ============================================================================
// C Struct Definitions (matching ufs.h)
// ============================================================================

struct UFSInodeInfo {
    var inode: UInt64
    var mode: UInt32
    var link_count: UInt32
    var uid: uid_t
    var gid: gid_t
    var size: UInt64
    var allocated_size: UInt64
    var atime: UInt64
    var mtime: UInt64
    var ctime: UInt64
    var creation_time: UInt64
    var file_type: UInt8
    var attributes: UInt32
}

struct UFSStatFs {
    var total_space: UInt64
    var free_space: UInt64
    var total_inodes: UInt64
    var free_inodes: UInt64
    var cluster_size: UInt32
    var sector_size: UInt32
}

struct UFSDirEnt {
    var inode: UInt64
    var name: (CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar)
    var file_type: UInt8
    var size: UInt64
}

struct UFSMountOptions {
    var read_only: Bool
    var case_insensitive: Bool
    var compression: UInt8
    var integrity_check: Bool
    var journal_size: UInt64

    init(from options: MountOptions) {
        self.read_only = options.readOnly
        self.case_insensitive = options.caseInsensitive
        self.compression = options.compression.rawValue
        self.integrity_check = options.integrityCheck
        self.journal_size = options.journalSize
    }
}