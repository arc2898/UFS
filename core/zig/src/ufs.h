/*
 * UFS C API Header
 * Platform driver interface for the UFS core engine
 * Version: 1.0
 */

#ifndef UFS_H
#define UFS_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// ============================================================================
// Version
// ============================================================================

#define UFS_VERSION_MAJOR 1
#define UFS_VERSION_MINOR 0
#define UFS_VERSION_REVISION 0

#define UFS_VERSION_STRING "1.0.0"

// ============================================================================
// Error Codes
// ============================================================================

typedef enum {
    UFS_OK = 0,
    UFS_ERROR_OUT_OF_MEMORY = -1,
    UFS_ERROR_INVALID_ARGUMENT = -2,
    UFS_ERROR_IO = -3,
    UFS_ERROR_NOT_FOUND = -4,
    UFS_ERROR_ALREADY_EXISTS = -5,
    UFS_ERROR_PERMISSION_DENIED = -6,
    UFS_ERROR_CORRUPTED_DATA = -7,
    UFS_ERROR_UNSUPPORTED_FEATURE = -8,
    UFS_ERROR_BUFFER_TOO_SMALL = -9,
    UFS_ERROR_INVALID_FORMAT = -10,
    UFS_ERROR_INTERNAL = -11,
    UFS_ERROR_OUT_OF_SPACE = -12,
    UFS_ERROR_ALIGNMENT = -13,
    UFS_ERROR_FRAGMENTED = -14,
    UFS_ERROR_NOT_INITIALIZED = -15,
    UFS_ERROR_WRITE_PROTECTED = -16,
    UFS_ERROR_DEVICE_NOT_FOUND = -17,
    UFS_ERROR_UNSUPPORTED_OPERATION = -18,
    UFS_ERROR_TIMEOUT = -19,
} ufs_error_t;

// ============================================================================
// Basic Types
// ============================================================================

typedef uint64_t ufs_inode_t;
typedef uint64_t ufs_cluster_t;
typedef uint64_t ufs_timestamp_t; // nanoseconds since epoch
typedef uint32_t ufs_mode_t;
typedef uint32_t ufs_uid_t;
typedef uint32_t ufs_gid_t;

// File types
typedef enum {
    UFS_FILE_TYPE_REG = 1,
    UFS_FILE_TYPE_DIR = 2,
    UFS_FILE_TYPE_SYMLINK = 3,
    UFS_FILE_TYPE_CHRDEV = 4,
    UFS_FILE_TYPE_BLKDEV = 5,
    UFS_FILE_TYPE_FIFO = 6,
    UFS_FILE_TYPE_SOCKET = 7,
    UFS_FILE_TYPE_REPARSE = 8,
} ufs_file_type_t;

// Inode flags
typedef enum {
    UFS_INODE_FLAG_COMPRESSED = 0x0001,
    UFS_INODE_FLAG_ENCRYPTED = 0x0002,
    UFS_INODE_FLAG_SPARSE = 0x0004,
    UFS_INODE_FLAG_IMMUTABLE = 0x0008,
    UFS_INODE_FLAG_APPEND_ONLY = 0x0010,
    UFS_INODE_FLAG_NOATIME = 0x0020,
    UFS_INODE_FLAG_NODUMP = 0x0040,
    UFS_INODE_FLAG_SYNC = 0x0080,
    UFS_INODE_FLAG_CASE_INSENSITIVE = 0x0100,
    UFS_INODE_FLAG_HAS_CAPSULE = 0x0200,
} ufs_inode_flag_t;

// Compression algorithms
typedef enum {
    UFS_COMPRESSION_NONE = 0,
    UFS_COMPRESSION_LZ4 = 1,
    UFS_COMPRESSION_ZSTD = 2,
    UFS_COMPRESSION_ZSTD_HIGH = 3,
} ufs_compression_algo_t;

// ============================================================================
// Block Device Interface (Platform Abstraction Layer)
// ============================================================================

typedef struct ufs_block_device ufs_block_device_t;

// File-backed block device functions (for testing on Linux/macOS/WSL)
ufs_block_device_t* ufs_block_device_open(const char* path, int flags);
int ufs_block_device_close(ufs_block_device_t* device);

typedef struct {
    uint32_t block_size;
    uint32_t physical_block_size;
    uint32_t optimal_io_size;
    uint64_t total_blocks;
    int is_removable;
    int is_read_only;
    int is_ssd;
    int is_virtual;
    const char* serial_number;
    const char* model;
    const char* firmware;
} ufs_block_device_info_t;

typedef struct {
    int read_only;
    int write_cache;
    int flush_on_write;
    int direct_io;
    int async_io;
} ufs_block_device_flags_t;

typedef struct {
    uint64_t cylinders;
    uint32_t heads;
    uint32_t sectors_per_track;
    uint32_t bytes_per_sector;
} ufs_block_geometry_t;

// Virtual function table for block device
typedef struct {
    // Synchronous operations
    int (*read)(ufs_block_device_t* device, uint64_t offset, void* buffer, size_t size);
    int (*write)(ufs_block_device_t* device, uint64_t offset, const void* buffer, size_t size);
    int (*flush)(ufs_block_device_t* device);
    int (*trim)(ufs_block_device_t* device, uint64_t offset, uint64_t length);

    // Asynchronous operations (optional)
    int (*read_async)(ufs_block_device_t* device, uint64_t offset, void* buffer, size_t size,
                      void (*callback)(void* context, int status, size_t bytes), void* context);
    int (*write_async)(ufs_block_device_t* device, uint64_t offset, const void* buffer, size_t size,
                       void (*callback)(void* context, int status, size_t bytes), void* context);

    // Device management
    ufs_block_device_info_t (*get_info)(ufs_block_device_t* device);
    int (*set_flags)(ufs_block_device_t* device, ufs_block_device_flags_t flags);
    ufs_block_device_flags_t (*get_flags)(ufs_block_device_t* device);
    int (*open)(ufs_block_device_t* device, const char* path, ufs_block_device_flags_t flags);
    int (*close)(ufs_block_device_t* device);

    // Geometry
    ufs_block_geometry_t (*get_geometry)(ufs_block_device_t* device);
} ufs_block_device_vtable_t;

struct ufs_block_device {
    void* context;
    const ufs_block_device_vtable_t* vtable;
};

// Convenience functions
static inline int ufs_block_read(ufs_block_device_t* dev, uint64_t offset, void* buf, size_t sz) {
    return dev->vtable->read(dev, offset, buf, sz);
}
static inline int ufs_block_write(ufs_block_device_t* dev, uint64_t offset, const void* buf, size_t sz) {
    return dev->vtable->write(dev, offset, buf, sz);
}
static inline int ufs_block_flush(ufs_block_device_t* dev) {
    return dev->vtable->flush(dev);
}
static inline ufs_block_device_info_t ufs_block_get_info(ufs_block_device_t* dev) {
    return dev->vtable->get_info(dev);
}

// ============================================================================
// Filesystem Handle
// ============================================================================

typedef struct ufs_fs ufs_fs_t;

// Mount options
typedef struct {
    int read_only;
    int case_insensitive;
    int compression; // 0=none, 1=LZ4, 2=ZSTD, 3=ZSTD_HIGH
    int integrity_check; // 0=none, 1=metadata only, 2=full
    uint64_t journal_size; // clusters, 0 = default
} ufs_mount_options_t;

// Default mount options
#define UFS_MOUNT_OPTIONS_DEFAULTS { \
    .read_only = 0, \
    .case_insensitive = 1, \
    .compression = 1, \
    .integrity_check = 1, \
    .journal_size = 0, \
}

// ============================================================================
// Core Filesystem Operations
// ============================================================================

// Format a new UFS volume
int ufs_format(ufs_block_device_t* device,
               const char* label,
               uint32_t cluster_size,
               int compression_algo,
               uint64_t journal_size_clusters,
               uint32_t ag_count);

// Mount an existing UFS volume
int ufs_mount(ufs_block_device_t* device,
              const ufs_mount_options_t* options,
              ufs_fs_t** out_fs);

// Unmount and cleanup
int ufs_unmount(ufs_fs_t* fs);

// Sync all dirty data to disk
int ufs_sync(ufs_fs_t* fs);

// Get filesystem statistics
typedef struct {
    uint64_t total_space;
    uint64_t free_space;
    uint64_t total_inodes;
    uint64_t free_inodes;
    uint32_t cluster_size;
    uint32_t ag_count;
} ufs_statfs_t;

int ufs_statfs(ufs_fs_t* fs, ufs_statfs_t* out_stat);

// ============================================================================
// Inode Operations
// ============================================================================

typedef struct {
    ufs_inode_t inode;
    ufs_mode_t mode;
    ufs_uid_t uid;
    ufs_gid_t gid;
    uint64_t size;
    uint64_t allocated_size;
    uint32_t link_count;
    uint32_t flags;
    ufs_timestamp_t atime;
    ufs_timestamp_t mtime;
    ufs_timestamp_t ctime;
    ufs_timestamp_t crtime;
    ufs_file_type_t type;
} ufs_inode_info_t;

// Create a new inode (file, dir, symlink, etc.)
int ufs_create_inode(ufs_fs_t* fs,
                     ufs_inode_t parent,
                     const char* name,
                     ufs_file_type_t type,
                     ufs_mode_t mode,
                     ufs_uid_t uid,
                     ufs_gid_t gid,
                     ufs_inode_t* out_inode);

// Lookup inode by path
int ufs_lookup(ufs_fs_t* fs, ufs_inode_t parent, const char* name, ufs_inode_t* out_inode);

// Get inode metadata
int ufs_getattr(ufs_fs_t* fs, ufs_inode_t inode, ufs_inode_info_t* out_info);

// Set inode metadata
int ufs_setattr(ufs_fs_t* fs, ufs_inode_t inode, const ufs_inode_info_t* info, uint32_t valid_mask);

// Delete inode
int ufs_delete_inode(ufs_fs_t* fs, ufs_inode_t inode);

// Remove directory entry (unlink file)
int ufs_unlink_dirent(ufs_fs_t* fs, ufs_inode_t parent, const char* name);

// Add directory entry (link file)
int ufs_link_dirent(ufs_fs_t* fs, ufs_inode_t parent, const char* name, ufs_inode_t child, ufs_file_type_t type);

// ============================================================================
// Directory Operations
// ============================================================================

typedef struct {
    ufs_inode_t inode;
    char name[256];
    ufs_file_type_t type;
} ufs_dirent_t;

typedef struct ufs_dir_iter ufs_dir_iter_t;

// Open directory for iteration
int ufs_opendir(ufs_fs_t* fs, ufs_inode_t inode, ufs_dir_iter_t** out_iter);

// Read next directory entry
int ufs_readdir(ufs_fs_t* fs, ufs_dir_iter_t* iter, ufs_dirent_t* out_entry);

// Close directory iterator
int ufs_closedir(ufs_fs_t* fs, ufs_dir_iter_t* iter);

// Create directory
int ufs_mkdir(ufs_fs_t* fs, ufs_inode_t parent, const char* name, ufs_mode_t mode);

// Remove directory
int ufs_rmdir(ufs_fs_t* fs, ufs_inode_t parent, const char* name);

// Rename/move
int ufs_rename(ufs_fs_t* fs, ufs_inode_t old_parent, const char* old_name,
               ufs_inode_t new_parent, const char* new_name);

// Create symlink
int ufs_symlink(ufs_fs_t* fs, ufs_inode_t parent, const char* name, const char* target);

// Read symlink target
int ufs_readlink(ufs_fs_t* fs, ufs_inode_t inode, char* buffer, size_t buffer_size);

// ============================================================================
// File I/O Operations
// ============================================================================

typedef struct ufs_file ufs_file_t;

// Open file
int ufs_open(ufs_fs_t* fs, ufs_inode_t inode, int flags, ufs_file_t** out_file);

// Close file
int ufs_close(ufs_file_t* file);

// Read from file
int ufs_read(ufs_file_t* file, void* buffer, size_t size, size_t* out_bytes_read);

// Write to file
int ufs_write(ufs_file_t* file, const void* buffer, size_t size, size_t* out_bytes_written);

// Seek
int ufs_seek(ufs_file_t* file, int64_t offset, int whence, int64_t* out_position);

// Truncate
int ufs_truncate(ufs_fs_t* fs, ufs_inode_t inode, uint64_t new_size);

// Fallocate
int ufs_fallocate(ufs_fs_t* fs, ufs_inode_t inode, int mode, uint64_t offset, uint64_t length);

// Fsync
int ufs_fsync(ufs_file_t* file);

// Get file extent map (for fiemap/ioctl)
typedef struct {
    uint64_t logical_offset;
    uint64_t physical_offset;
    uint64_t length;
    ufs_compression_algo_t compression;
    int flags;
} ufs_extent_t;

int ufs_get_extents(ufs_fs_t* fs, ufs_inode_t inode, ufs_extent_t* extents, size_t* count);

// ============================================================================
// Extended Attributes / Metadata Capsules
// ============================================================================

// Namespace IDs
#define UFS_NS_POSIX_BASE     0x0001
#define UFS_NS_POSIX_ACL      0x0002
#define UFS_NS_POSIX_XATTR    0x0003
#define UFS_NS_POSIX_CAPS     0x0004
#define UFS_NS_WINDOWS_SD     0x0010
#define UFS_NS_WINDOWS_ADS    0x0011
#define UFS_NS_WINDOWS_REPARSE 0x0012
#define UFS_NS_WINDOWS_EFS    0x0013
#define UFS_NS_WINDOWS_USN    0x0014
#define UFS_NS_WINDOWS_OBJID  0x0015
#define UFS_NS_WINDOWS_ATTRS  0x0016
#define UFS_NS_MACOS_XATTR    0x0020
#define UFS_NS_MACOS_FINDER   0x0021
#define UFS_NS_MACOS_RESOURCE 0x0022
#define UFS_NS_MACOS_QUARANTINE 0x0023
#define UFS_NS_MACOS_FIRMLINK 0x0024
#define UFS_NS_MACOS_TIMESTAMP 0x0025
#define UFS_NS_UFS_INTERNAL   0x8000
#define UFS_NS_OPAQUE         0xFFFF

// Set extended attribute
int ufs_setxattr(ufs_fs_t* fs, ufs_inode_t inode,
                 uint16_t namespace_id, uint16_t type,
                 const char* name, const void* value, size_t value_len, int flags);

// Get extended attribute
int ufs_getxattr(ufs_fs_t* fs, ufs_inode_t inode,
                 uint16_t namespace_id, uint16_t type,
                 const char* name, void* buffer, size_t buffer_size, size_t* out_size);

// List extended attributes
int ufs_listxattr(ufs_fs_t* fs, ufs_inode_t inode,
                  char* buffer, size_t buffer_size, size_t* out_size);

// Remove extended attribute
int ufs_removexattr(ufs_fs_t* fs, ufs_inode_t inode,
                    uint16_t namespace_id, uint16_t type,
                    const char* name);

// ============================================================================
// Volume Management
// ============================================================================

// Get volume UUID
int ufs_get_volume_uuid(ufs_fs_t* fs, uint8_t uuid[16]);

// Set volume label
int ufs_set_volume_label(ufs_fs_t* fs, const char* label);

// Get volume label
int ufs_get_volume_label(ufs_fs_t* fs, char* buffer, size_t size);

// Feature flag management
int ufs_get_features(ufs_fs_t* fs, uint32_t* incompat, uint32_t* compat_ro, uint32_t* compat_rw);
int ufs_set_feature(ufs_fs_t* fs, int type, int bit, int enabled);

// Force checkpoint
int ufs_checkpoint(ufs_fs_t* fs);

// Scrub (integrity check)
typedef struct {
    uint64_t checked;
    uint64_t errors;
    uint64_t corrupted_files;
} ufs_scrub_result_t;

int ufs_scrub(ufs_fs_t* fs, ufs_scrub_result_t* result, void (*progress)(uint64_t, uint64_t, void*), void* ctx);

// ============================================================================
// Recovery
// ============================================================================

// Check if volume needs recovery
int ufs_needs_recovery(ufs_block_device_t* device);

// Run recovery (called automatically on mount if needed)
int ufs_recover(ufs_block_device_t* device);

// Verify journal integrity
int ufs_verify_journal(ufs_block_device_t* device, int* out_ok);

// ============================================================================
// Compression
// ============================================================================

// Set default compression for new files
int ufs_set_compression(ufs_fs_t* fs, ufs_inode_t inode, ufs_compression_algo_t algo, int level);

// Get compression info for file
int ufs_get_compression(ufs_fs_t* fs, ufs_inode_t inode, ufs_compression_algo_t* algo, int* level);

// ============================================================================
// Encryption (v2 stub)
// ============================================================================

typedef enum {
    UFS_ENCRYPTION_NONE = 0,
    UFS_ENCRYPTION_AES256_GCM = 1,
    UFS_ENCRYPTION_CHACHA20_POLY1305 = 2,
    UFS_ENCRYPTION_AES256_XTS = 3,
} ufs_encryption_algo_t;

// Set encryption on file (stub - returns UNSUPPORTED in v1)
int ufs_set_encryption(ufs_fs_t* fs, ufs_inode_t inode, ufs_encryption_algo_t algo, const void* key, size_t key_len);

// ============================================================================
// Utility Functions
// ============================================================================

// Get error string
const char* ufs_strerror(int error_code);

// Get current timestamp (nanoseconds since epoch)
ufs_timestamp_t ufs_timestamp(void);

// Generate UUIDv7
void ufs_generate_uuidv7(uint8_t uuid[16]);

// CRC32C
uint32_t ufs_crc32c(const void* data, size_t len);

// BLAKE3
void ufs_blake3(const void* data, size_t len, uint8_t out[32]);

// ============================================================================
// UEFI-Specific Types and Protocols
// ============================================================================

#ifdef __UEFI__

#include <Uefi.h>

// UFS Block Device Operations for UEFI
typedef struct {
    EFI_STATUS (*read)(void* context, uint64_t offset, void* buffer, size_t size);
    EFI_STATUS (*write)(void* context, uint64_t offset, const void* buffer, size_t size);
    EFI_STATUS (*flush)(void* context);
    EFI_STATUS (*get_info)(void* context, ufs_block_device_info_t* info);
} ufs_block_device_ops_t;

typedef void* ufs_block_device_handle_t;

EFI_STATUS ufs_block_device_create(const ufs_block_device_ops_t* ops, void* context, ufs_block_device_handle_t** handle);
EFI_STATUS ufs_block_device_close(ufs_block_device_handle_t* handle);

// UEFI Core Wrapper Functions
uint32_t ufs_crc32c(const void* data, size_t len);
void ufs_blake3(const void* data, size_t len, uint8_t out[32]);
void ufs_generate_uuidv7(uint8_t uuid[16]);
uint64_t ufs_timestamp(void);
const char* ufs_strerror(int error_code);

void* ufs_allocate_pool(size_t size);
void ufs_free_pool(void* buffer);

EFI_STATUS ufs_lock_initialize(void* lock);
void ufs_lock_acquire(void* lock);
void ufs_lock_release(void* lock);

// UEFI Recovery Functions
BOOLEAN ufs_needs_recovery(ufs_block_device_handle_t* block_dev);
EFI_STATUS ufs_recover(ufs_block_device_handle_t* block_dev);
EFI_STATUS ufs_verify_journal(ufs_block_device_handle_t* block_dev, BOOLEAN* is_valid);
EFI_STATUS ufs_recover_full(ufs_block_device_handle_t* block_dev, void* ag_manager);
EFI_STATUS ufs_scrub(void* fs_handle, ufs_scrub_result_t* result, void* progress, void* ctx);
EFI_STATUS ufs_checkpoint(void* fs_handle);

// UEFI Boot Loader Functions
EFI_STATUS ufs_load_boot_loader(EFI_HANDLE image_handle, EFI_HANDLE device_handle);

#endif // __UEFI__

#ifdef __cplusplus
}
#endif

#endif // UFS_H