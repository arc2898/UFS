# UFS OS Integration Architecture

**Project:** Project U (U Filesystem - UFS)
**Version:** 1.0
**Date:** 2026-11-13
**Status:** Architecture Definition Phase

---

## 1. Overview

This document describes the platform-specific integration layers for UFS on Windows 11, Linux, and macOS. The core philosophy: **thin platform glue over shared Zig core**.

---

## 2. Windows 11: Native IFS Driver

### 2.1 Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        USER MODE                                 │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────────┐  │
│  │  ufsctl.exe │  │Mount-UFS.ps1│  │   Format-UFS / mkufs    │  │
│  └──────┬──────┘  └──────┬──────┘  └───────────┬─────────────┘  │
│         │                │                     │                 │
│         ▼                ▼                     ▼                 │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │              Win32 API (CreateFile, DeviceIoControl)    │    │
│  └────────────────────────────┬────────────────────────────┘    │
└───────────────────────────────│─────────────────────────────────┘
                                │
                    ┌───────────▼───────────┐
                    │    I/O Manager        │
                    └───────────┬───────────┘
                                │
                    ┌───────────▼───────────┐
                    │    Mount Manager      │
                    └───────────┬───────────┘
                                │
                    ┌───────────▼───────────┐
                    │    Volume Manager     │
                    └───────────┬───────────┘
                                │
┌───────────────────────────────│─────────────────────────────────┐
│                    KERNEL MODE                                  │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │                    UFS.sys (IFS Driver)                 │    │
│  │  ┌────────────┐ ┌────────────┐ ┌────────────────────┐  │    │
│  │  │ IRP Dispatch│ │ Fast I/O   │ │ Cache Manager      │  │    │
│  │  │             │ │ Callbacks  │ │ Integration        │  │    │
│  │  └──────┬─────┘ └──────┬─────┘ └────────┬───────────┘  │    │
│  │         │              │                 │              │    │
│  │  ┌──────▼──────────────▼─────────────────▼────────┐    │    │
│  │  │           ZIG CORE (Static Library)            │    │    │
│  │  │  Serialization │ Metadata │ Allocation │ ...   │    │    │
│  │  └────────────────────────────────────────────────┘    │    │
│  │  ┌────────────────────────────────────────────────┐    │    │
│  │  │           PAL (Platform Abstraction)           │    │    │
│  │  │  Block I/O via IRP_MJ_READ/WRITE               │    │    │
│  │  │  Flush via IRP_MJ_FLUSH_BUFFERS                │    │    │
│  │  │  FUA via IRP_MJ_WRITE + SL_FORCE_DIRECT_WRITE  │    │    │
│  │  │  TRIM via FSCTL_DELETE_NOTIFICATION            │    │    │
│  │  └────────────────────────────────────────────────┘    │    │
│  └─────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────┘
```

### 2.2 Key Components

#### 2.2.1 Driver Entry Points
```c
// DriverEntry
NTSTATUS DriverEntry(PDRIVER_OBJECT DriverObject, PUNICODE_STRING RegistryPath);

// DriverUnload
VOID DriverUnload(PDRIVER_OBJECT DriverObject);
```

#### 2.2.2 Filesystem Entry Points (Major Functions)
```c
// Mount/Unmount
NTSTATUS UfsMountVolume(PDEVICE_OBJECT DeviceObject, PIRP Irp);
NTSTATUS UfsUnmountVolume(PDEVICE_OBJECT DeviceObject, PIRP Irp);

// File Operations
NTSTATUS UfsCreate(PDEVICE_OBJECT DeviceObject, PIRP Irp);
NTSTATUS UfsClose(PDEVICE_OBJECT DeviceObject, PIRP Irp);
NTSTATUS UfsRead(PDEVICE_OBJECT DeviceObject, PIRP Irp);
NTSTATUS UfsWrite(PDEVICE_OBJECT DeviceObject, PIRP Irp);
NTSTATUS UfsSetInformation(PDEVICE_OBJECT DeviceObject, PIRP Irp);
NTSTATUS UfsQueryInformation(PDEVICE_OBJECT DeviceObject, PIRP Irp);
NTSTATUS UfsDirectoryControl(PDEVICE_OBJECT DeviceObject, PIRP Irp);
NTSTATUS UfsFileSystemControl(PDEVICE_OBJECT DeviceObject, PIRP Irp);

// Cleanup
NTSTATUS UfsCleanup(PDEVICE_OBJECT DeviceObject, PIRP Irp);
```

#### 2.2.3 Fast I/O Callbacks
```c
FAST_IO_DISPATCH FastIoDispatch = {
    .SizeOfFastIoDispatch = sizeof(FAST_IO_DISPATCH),
    .FastIoCheckIfPossible = UfsFastIoCheckIfPossible,
    .FastIoRead = UfsFastIoRead,
    .FastIoWrite = UfsFastIoWrite,
    .FastIoQueryBasicInfo = UfsFastIoQueryBasicInfo,
    .FastIoQueryStandardInfo = UfsFastIoQueryStandardInfo,
    .FastIoLock = UfsFastIoLock,
    .FastIoUnlockSingle = UfsFastIoUnlockSingle,
    .FastIoUnlockAll = UfsFastIoUnlockAll,
    .FastIoUnlockAllByKey = UfsFastIoUnlockAllByKey,
    .FastIoDeviceControl = UfsFastIoDeviceControl,
    .AcquireFileForNtCreateSection = UfsAcquireForSectionSync,
    .ReleaseFileForNtCreateSection = UfsReleaseForSectionSync,
    .AcquireForModWrite = UfsAcquireForModWrite,
    .MdlRead = UfsMdlRead,
    .MdlReadComplete = UfsMdlReadComplete,
    .PrepareMdlWrite = UfsPrepareMdlWrite,
    .MdlWriteComplete = UfsMdlWriteComplete,
    .FastIoReadCompressed = UfsFastIoReadCompressed,
    .FastIoWriteCompressed = UfsFastIoWriteCompressed,
    .MdlReadCompleteCompressed = UfsMdlReadCompleteCompressed,
    .MdlWriteCompleteCompressed = UfsMdlWriteCompleteCompressed,
    .FastIoQueryOpen = UfsFastIoQueryOpen,
    .ReleaseForModWrite = UfsReleaseForModWrite,
    .AcquireForCcFlush = UfsAcquireForCcFlush,
    .ReleaseForCcFlush = UfsReleaseForCcFlush,
};
```

#### 2.2.4 Cache Manager Integration
```c
// File initialization
VOID UfsInitializeCacheMap(PFILE_OBJECT FileObject, 
                           PCC_FILE_SIZES FileSizes,
                           PINODE Inode);

// Read ahead
NTSTATUS UfsMdlRead(PFILE_OBJECT FileObject,
                    PLARGE_INTEGER FileOffset,
                    ULONG Length,
                    ULONG LockKey,
                    PMDL *MdlChain,
                    PULONG LengthRead);

// Write behind
NTSTATUS UfsPrepareMdlWrite(PFILE_OBJECT FileObject,
                            PLARGE_INTEGER FileOffset,
                            ULONG Length,
                            ULONG LockKey,
                            PMDL *MdlChain,
                            PULONG LengthWritten);
```

#### 2.2.5 Security Callback
```c
NTSTATUS UfsSecurityCallback(PFILE_OBJECT FileObject,
                             PSECURITY_INFORMATION SecurityInformation,
                             PSECURITY_DESCRIPTOR *SecurityDescriptor,
                             PULONG SecurityDescriptorLength);
```

### 2.3 Data Structures

#### VCB (Volume Control Block) - One per mounted volume
```c
typedef struct _UFS_VCB {
    // Identification
    ULONG Signature;              // 'UFSV'
    PDEVICE_OBJECT TargetDevice;  // Underlying storage device
    PDEVICE_OBJECT VpbDevice;     // VPB device object
    
    // Zig Core Handle
    UfsVolumeHandle ZigVolume;    // Opaque handle to Zig core
    
    // Mount State
    BOOLEAN MountedReadOnly;
    BOOLEAN DismountInProgress;
    LARGE_INTEGER VolumeSize;
    ULONG ClusterSize;
    
    // Synchronization
    ERESOURCE MainResource;       // Main VCB lock
    ERESOURCE FileResource;       // File list lock
    
    // File Tracking
    LIST_ENTRY FcbList;           // Active FCBs
    ULONG FcbCount;
    
    // Journal
    UFS_JOURNAL_CONTEXT Journal;
    
    // Cleanup
    KEVENT DismountEvent;
    ULONG ReferenceCount;
} UFS_VCB, *PUFS_VCB;
```

#### FCB (File Control Block) - One per open file
```c
typedef struct _UFS_FCB {
    // Identification
    ULONG Signature;              // 'UFSF'
    PUFS_VCB Vcb;
    ULONG64 InodeNumber;          // Inode number
    
    // File State
    ULONG64 FileSize;
    ULONG64 AllocatedSize;
    ULONG FileAttributes;         // FILE_ATTRIBUTE_*
    BOOLEAN IsDirectory;
    BOOLEAN IsPagingFile;
    BOOLEAN DeleteOnClose;
    
    // Synchronization
    ERESOURCE MainResource;       // FCB lock (shared/exclusive)
    ERESOURCE PagingIoResource;   // Paging I/O lock
    
    // Cache Manager
    SECTION_OBJECT_POINTERS SectionObjectPointers;
    PRIVATE_CACHE_MAP PrivateCacheMap;
    
    // Naming
    UNICODE_STRING FileName;
    PUFS_FCB ParentFcb;
    
    // Children (for directories)
    LIST_ENTRY ChildFcbList;
    
    // Open Count
    ULONG OpenCount;
    ULONG CleanupCount;
    
    // Zig Core Handle
    UfsFileHandle ZigFile;        // Opaque handle to Zig core
} UFS_FCB, *PUFS_FCB;
```

#### CCB (Context Control Block) - One per open handle
```c
typedef struct _UFS_CCB {
    ULONG Signature;              // 'UFSC'
    PUFS_FCB Fcb;
    ULONG Flags;
    ULONG DesiredAccess;
    ULONG ShareAccess;
    FILE_OBJECT *FileObject;
    
    // Enumeration Context
    ULONG EnumerationIndex;
    PVOID EnumerationBuffer;
    ULONG EnumerationBufferSize;
    
    // Zig Core Handle
    UfsHandle ZigHandle;
} UFS_CCB, *PUFS_CCB;
```

### 2.4 PAL Implementation (Windows)

```c
// Block Read
NTSTATUS UfsPalRead(PUFS_VCB Vcb, ULONG64 Offset, PVOID Buffer, ULONG Length) {
    // Build IRP_MJ_READ, send to storage stack
    // Use synchronous I/O for metadata, async for data
}

// Block Write
NTSTATUS UfsPalWrite(PUFS_VCB Vcb, ULONG64 Offset, PVOID Buffer, ULONG Length, BOOLEAN Fua) {
    // Build IRP_MJ_WRITE
    // If Fua: set SL_FORCE_DIRECT_WRITE in stack location
}

// Flush
NTSTATUS UfsPalFlush(PUFS_VCB Vcb) {
    // Send IRP_MJ_FLUSH_BUFFERS
}

// TRIM
NTSTATUS UfsPalTrim(PUFS_VCB Vcb, ULONG64 Offset, ULONG64 Length) {
    // Build FSCTL_DELETE_NOTIFICATION
    // Send to storage stack
}
```

### 2.5 Installation

#### INF File Structure
```
[Version]
Signature="$WINDOWS NT$"
Class=FileSystem
ClassGuid={...}
Provider=%ProviderName%
DriverVer=...
CatalogFile=ufs.cat

[DestinationDirs]
DefaultDestDir=12  ; drivers
UFS.DriverFiles=12

[SourceDisksNames]
1 = %DiskName%,,,

[SourceDisksFiles]
ufs.sys = 1

[Manufacturer]
%ProviderName%=UFS,NTamd64,NTarm64

[UFS.NTamd64]
%UFS.DeviceDesc%=UFS_Install,ROOT\UFS

[UFS_Install]
CopyFiles=UFS.DriverFiles
AddReg=UFS_AddReg

[UFS.DriverFiles]
ufs.sys

[UFS_AddReg]
HKR,,"Type",0x00010001,2  ; SERVICE_FILE_SYSTEM_DRIVER
HKR,,"Start",0x00010001,0 ; SERVICE_BOOT_START
HKR,,"ErrorControl",0x00010001,1 ; SERVICE_ERROR_NORMAL
HKR,,"Group",0x00000000,"File System"
HKR,,"ImagePath",0x00020000,"\SystemRoot\System32\drivers\ufs.sys"

[Strings]
ProviderName="Project U"
UFS.DeviceDesc="U Filesystem Driver"
DiskName="UFS Installation Disk"
```

#### Installation Script (Install-UFS.ps1)
```powershell
#Requires -RunAsAdministrator

param(
    [string]$DriverPath = ".\ufs.sys",
    [string]$InfPath = ".\ufs.inf",
    [string]$CatPath = ".\ufs.cat"
)

# Verify signatures
# Copy to DriverStore
# PnPUtil install
# Register with MountMgr
# Verify driver loaded
```

### 2.6 Signing Requirements

| Stage | Requirements |
|-------|--------------|
| Development | Test signing certificate, `bcdedit /set testsigning on` |
| Internal Testing | Test signing, Secure Boot disabled |
| Production | EV code signing cert, Microsoft Attestation Signing, WHQL |

---

## 3. Linux: FUSE + Native VFS

### 3.1 FUSE Implementation (Development)

#### Architecture
```
Userspace:                    Kernel:
┌─────────────────────┐      ┌─────────────────┐
│ ufs-fuse (Zig+C)    │◄────►│ fuse.ko         │
│  ┌───────────────┐  │      │  ┌───────────┐  │
│  │ Zig Core      │  │      │  │ VFS       │  │
│  │  - All ops    │  │      │  │  - inode  │  │
│  │  - PAL        │  │      │  │  - file   │  │
│  └───────────────┘  │      │  └───────────┘  │
│  ┌───────────────┐  │      └─────────────────┘
│  │ libfuse3      │  │
│  │  - fuse_lowlevel_ops
│  │  - fuse_opt_parse
│  └───────────────┘  │
└─────────────────────┘
```

#### FUSE Operations Mapping
```c
static struct fuse_lowlevel_ops ufs_fuse_ops = {
    .init = ufs_fuse_init,
    .destroy = ufs_fuse_destroy,
    .lookup = ufs_fuse_lookup,
    .forget = ufs_fuse_forget,
    .getattr = ufs_fuse_getattr,
    .setattr = ufs_fuse_setattr,
    .readlink = ufs_fuse_readlink,
    .mknod = ufs_fuse_mknod,
    .mkdir = ufs_fuse_mkdir,
    .unlink = ufs_fuse_unlink,
    .rmdir = ufs_fuse_rmdir,
    .symlink = ufs_fuse_symlink,
    .rename = ufs_fuse_rename,
    .link = ufs_fuse_link,
    .open = ufs_fuse_open,
    .read = ufs_fuse_read,
    .write = ufs_fuse_write,
    .flush = ufs_fuse_flush,
    .release = ufs_fuse_release,
    .fsync = ufs_fuse_fsync,
    .opendir = ufs_fuse_opendir,
    .readdir = ufs_fuse_readdir,
    .releasedir = ufs_fuse_releasedir,
    .fsyncdir = ufs_fuse_fsyncdir,
    .statfs = ufs_fuse_statfs,
    .setxattr = ufs_fuse_setxattr,
    .getxattr = ufs_fuse_getxattr,
    .listxattr = ufs_fuse_listxattr,
    .removexattr = ufs_fuse_removexattr,
    .access = ufs_fuse_access,
    .create = ufs_fuse_create,
    .getlk = ufs_fuse_getlk,
    .setlk = ufs_fuse_setlk,
    .bmap = ufs_fuse_bmap,
    .ioctl = ufs_fuse_ioctl,
    .poll = ufs_fuse_poll,
    .write_buf = ufs_fuse_write_buf,
    .read_buf = ufs_fuse_read_buf,
    .flock = ufs_fuse_flock,
    .fallocate = ufs_fuse_fallocate,
};
```

#### PAL Implementation (FUSE)
```c
// Uses pread/pwrite on block device file
int ufs_pal_read(void *ctx, uint64_t offset, void *buf, size_t len) {
    return pread((int)ctx, buf, len, offset);
}

int ufs_pal_write(void *ctx, uint64_t offset, const void *buf, size_t len, bool fua) {
    if (fua) {
        return pwritev((int)ctx, &(struct iovec){.iov_base=(void*)buf,.iov_len=len}, 1, offset);
        // Note: Linux doesn't have direct FUA via pwrite; use O_DIRECT + fsync
    }
    return pwrite((int)ctx, buf, len, offset);
}

int ufs_pal_flush(void *ctx) {
    return fsync((int)ctx);
}

int ufs_pal_trim(void *ctx, uint64_t offset, uint64_t len) {
    struct fstrim_range range = {.start=offset, .len=len, .minlen=0};
    return ioctl((int)ctx, FITRIM, &range);
}
```

### 3.2 Native VFS Kernel Module (Production)

#### Architecture
```
Kernel:
┌─────────────────────────────────────────────────────────────┐
│ ufs.ko                                                        │
│  ┌─────────────────────────────────────────────────────┐    │
│  │ struct file_system_type ufs_fs_type                 │    │
│  │  .name = "ufs"                                      │    │
│  │  .mount = ufs_mount                                 │    │
│  │  .kill_sb = ufs_kill_sb                             │    │
│  │  .fs_flags = FS_REQUIRES_DEV                        │    │
│  └─────────────────────────────────────────────────────┘    │
│  ┌─────────────────────────────────────────────────────┐    │
│  │ struct super_operations ufs_super_ops               │    │
│  │  .alloc_inode = ufs_alloc_inode                     │    │
│  │  .destroy_inode = ufs_destroy_inode                 │    │
│  │  .write_inode = ufs_write_inode                     │    │
│  │  .dirty_inode = ufs_dirty_inode                     │    │
│  │  .evict_inode = ufs_evict_inode                     │    │
│  │  .put_super = ufs_put_super                         │    │
│  │  .sync_fs = ufs_sync_fs                             │    │
│  │  .freeze_fs = ufs_freeze_fs                         │    │
│  │  .unfreeze_fs = ufs_unfreeze_fs                     │    │
│  │  .statfs = ufs_statfs                               │    │
│  │  .show_options = ufs_show_options                   │    │
│  └─────────────────────────────────────────────────────┘    │
│  ┌─────────────────────────────────────────────────────┐    │
│  │ struct inode_operations ufs_file_inode_ops          │    │
│  │  .getattr = ufs_getattr                             │    │
│  │  .setattr = ufs_setattr                             │    │
│  │  .getxattr = ufs_getxattr                           │    │
│  │  .setxattr = ufs_setxattr                           │    │
│  │  .listxattr = ufs_listxattr                         │    │
│  │  .removexattr = ufs_removexattr                     │    │
│  │  .fiemap = ufs_fiemap                               │    │
│  └─────────────────────────────────────────────────────┘    │
│  ┌─────────────────────────────────────────────────────┐    │
│  │ struct file_operations ufs_file_ops                 │    │
│  │  .open = ufs_open                                   │    │
│  │  .release = ufs_release                             │    │
│  │  .read_iter = ufs_read_iter                         │    │
│  │  .write_iter = ufs_write_iter                       │    │
│  │  .mmap = ufs_mmap                                   │    │
│  │  .fsync = ufs_fsync                                 │    │
│  │  .fallocate = ufs_fallocate                         │    │
│  │  .ioctl = ufs_ioctl                                 │    │
│  └─────────────────────────────────────────────────────┘    │
│  ┌─────────────────────────────────────────────────────┐    │
│  │ struct address_space_operations ufs_aops            │    │
│  │  .readpage = ufs_readpage                           │    │
│  │  .readpages = ufs_readpages                         │    │
│  │  .writepage = ufs_writepage                         │    │
│  │  .writepages = ufs_writepages                       │    │
│  │  .write_begin = ufs_write_begin                     │    │
│  │  .write_end = ufs_write_end                         │    │
│  │  .bmap = ufs_bmap                                   │    │
│  │  .invalidatepage = ufs_invalidatepage               │    │
│  │  .releasepage = ufs_releasepage                     │    │
│  │  .migratepage = ufs_migratepage                     │    │
│  │  .is_partially_uptodate = ufs_is_partially_uptodate │    │
│  │  .error_remove_page = ufs_error_remove_page         │    │
│  └─────────────────────────────────────────────────────┘    │
│  ┌─────────────────────────────────────────────────────┐    │
│  │ ZIG CORE (Static Library)                           │    │
│  │  All filesystem logic                               │    │
│  └─────────────────────────────────────────────────────┘    │
│  ┌─────────────────────────────────────────────────────┐    │
│  │ PAL (Kernel Block I/O)                              │    │
│  │  submit_bio() for I/O                               │    │
│  │  blkdev_issue_flush() for flush                     │    │
│  │  blkdev_issue_discard() for TRIM                    │    │
│  │  REQ_FUA flag for FUA                               │    │
│  └─────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
```

#### Key VFS Callbacks

```c
// Mount
static struct dentry *ufs_mount(struct file_system_type *fs_type,
                                int flags, const char *dev_name,
                                void *raw_data) {
    return mount_bdev(fs_type, flags, dev_name, raw_data, ufs_fill_super);
}

// Superblock fill
static int ufs_fill_super(struct super_block *sb, void *data, int silent) {
    // Initialize Zig core with block device
    // Read superblock, validate
    // Set up s_op, s_root, etc.
}

// Inode operations
static struct inode *ufs_alloc_inode(struct super_block *sb) {
    struct ufs_inode_info *ui = kmalloc(sizeof(*ui), GFP_KERNEL);
    inode_init_once(&ui->vfs_inode);
    return &ui->vfs_inode;
}

static void ufs_destroy_inode(struct inode *inode) {
    kmem_cache_free(ufs_inode_cachep, UFS_I(inode));
}

// Read/Write via address_space_operations
static int ufs_readpage(struct file *file, struct page *page) {
    // Use Zig core to read extent
    // Copy to page
    // SetPageUptodate(page)
    // unlock_page(page)
    return 0;
}

static int ufs_write_begin(struct file *file, struct address_space *mapping,
                           loff_t pos, unsigned len, unsigned flags,
                           struct page **pagep, void **fsdata) {
    // Allocate extent if needed
    // Grab page
    // Return
}

static int ufs_write_end(struct file *file, struct address_space *mapping,
                         loff_t pos, unsigned len, unsigned copied,
                         struct page *page, void *fsdata) {
    // Write page data via Zig core
    // Handle partial writes
    return copied;
}
```

#### PAL Implementation (Kernel)

```c
// Block I/O via bio
int ufs_pal_submit_io(void *ctx, struct bio *bio) {
    struct block_device *bdev = (struct block_device *)ctx;
    bio->bi_bdev = bdev;
    submit_bio(bio);
    return 0;
}

// Synchronous read
int ufs_pal_read(void *ctx, uint64_t offset, void *buf, size_t len) {
    struct bio *bio = bio_alloc(GFP_KERNEL, 1);
    bio->bi_iter.bi_sector = offset >> 9;
    bio->bi_bdev = (struct block_device *)ctx;
    bio_add_page(bio, virt_to_page(buf), len, offset_in_page(buf));
    bio->bi_opf = REQ_OP_READ;
    submit_bio_wait(bio);
    bio_put(bio);
    return 0;
}

// Synchronous write with FUA
int ufs_pal_write(void *ctx, uint64_t offset, const void *buf, size_t len, bool fua) {
    struct bio *bio = bio_alloc(GFP_KERNEL, 1);
    bio->bi_iter.bi_sector = offset >> 9;
    bio->bi_bdev = (struct block_device *)ctx;
    bio_add_page(bio, virt_to_page((void*)buf), len, offset_in_page(buf));
    bio->bi_opf = REQ_OP_WRITE | (fua ? REQ_FUA : 0);
    submit_bio_wait(bio);
    bio_put(bio);
    return 0;
}

// Flush
int ufs_pal_flush(void *ctx) {
    return blkdev_issue_flush((struct block_device *)ctx, GFP_KERNEL, NULL);
}

// TRIM
int ufs_pal_trim(void *ctx, uint64_t offset, uint64_t len) {
    return blkdev_issue_discard((struct block_device *)ctx, offset >> 9, len >> 9, GFP_KERNEL, 0);
}
```

### 3.3 WSL 2 Development Workflow

```bash
# Build Zig core
zig build -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseFast

# Build FUSE driver
cd drivers/linux-fuse
meson setup build
ninja -C build

# Build native kernel module (against WSL kernel headers)
cd drivers/linux
make KERNEL_SRC=/usr/src/linux-headers-$(uname -r)

# Create test disk image
truncate -s 1G test.img
mkufs test.img

# Test FUSE
mkdir /mnt/ufs
./ufs-fuse test.img /mnt/ufs -o allow_other

# Test native module (requires root)
sudo insmod ufs.ko
sudo mount -t ufs /dev/loop0 /mnt/ufs

# Cleanup
sudo umount /mnt/ufs
sudo rmmod ufs
```

---

## 4. macOS: FSKit File System Extension

### 4.1 Architecture (macOS 13+ Ventura)

```
Userspace:
┌─────────────────────────────────────────────────────────────┐
│ UFS Extension (Swift + Zig Core)                            │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ FileSystemExtension                                 │   │
│  │  - volumeName, volumeUUID                           │   │
│  │  - supportedFeatures                                │   │
│  └─────────────────────────────────────────────────────┘   │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ VolumeHandler                                       │   │
│  │  - openRootDirectory() -> DirectoryHandle           │   │
│  │  - createDirectory() / createFile() / createSymlink()│  │
│  │  - removeItem() / renameItem()                      │   │
│  │  - statFS()                                         │   │
│  │  - sync()                                           │   │
│  └─────────────────────────────────────────────────────┘   │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ DirectoryHandle                                     │   │
│  │  - enumerateDescendants()                           │   │
│  │  - getChild() -> FileHandle / DirectoryHandle       │   │
│  └─────────────────────────────────────────────────────┘   │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ FileHandle                                          │   │
│  │  - read() -> AsyncSequence<Data>                    │   │
│  │  - write(Data) -> Int                               │   │
│  │  - truncate(to:)                                    │   │
│  │  - getAttributes() -> FileAttributes                │   │
│  │  - setAttributes(FileAttributes)                    │   │
│  └─────────────────────────────────────────────────────┘   │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ ZIG CORE (Dynamic Library)                          │   │
│  │  All filesystem logic                               │   │
│  └─────────────────────────────────────────────────────┘   │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ PAL (macOS Block I/O)                               │   │
│  │  - IOService / IOMedia for block device             │   │
│  │  - IODispatchQueue for async I/O                    │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### 4.2 FSKit Extension Structure

```swift
// Main Extension
@main
struct UFSExtension: FileSystemExtension {
    var configuration: FileSystemExtensionConfiguration {
        FileSystemExtensionConfiguration(
            volumeName: "UFS",
            volumeUUID: UUID(),
            supportedFeatures: [
                .caseInsensitive,
                .extendedAttributes,
                .accessControlLists,
                .compression,
                .sparseFiles,
                .hardLinks,
                .symbolicLinks
            ]
        )
    }
    
    func makeVolumeHandler(for volume: Volume) -> VolumeHandler {
        UFSVolumeHandler(volume: volume)
    }
}

// Volume Handler
class UFSVolumeHandler: VolumeHandler {
    let zigVolume: OpaquePointer  // Zig core handle
    
    init(volume: Volume) {
        // Initialize Zig core with block device
        self.zigVolume = ufs_volume_open(volume.blockDevicePath)
    }
    
    func openRootDirectory() -> DirectoryHandle {
        return UFSDirectoryHandle(zigVolume: zigVolume, inode: 2) // Root inode
    }
    
    func statFS() async throws -> FileSystemStatistics {
        // Call Zig core for volume stats
    }
    
    func sync() async throws {
        // Call Zig core for flush + journal commit
    }
}

// Directory Handle
class UFSDirectoryHandle: DirectoryHandle {
    let zigVolume: OpaquePointer
    let inode: UInt64
    
    func enumerateDescendants() -> AsyncThrowingStream<DirectoryEntry, Error> {
        // Call Zig core for directory enumeration
        // Convert to DirectoryEntry stream
    }
    
    func getChild(name: String) async throws -> FileSystemHandle {
        // Call Zig core for lookup
        // Return FileHandle or DirectoryHandle
    }
    
    func createDirectory(name: String, attributes: FileAttributes) async throws -> DirectoryHandle {
        // Call Zig core for mkdir
        // Return new DirectoryHandle
    }
    
    func createFile(name: String, attributes: FileAttributes) async throws -> FileHandle {
        // Call Zig core for create
        // Return new FileHandle
    }
    
    func createSymlink(name: String, target: String, attributes: FileAttributes) async throws -> FileHandle {
        // Call Zig core for symlink
        // Return new FileHandle
    }
    
    func removeItem(name: String) async throws {
        // Call Zig core for unlink
    }
    
    func renameItem(from: String, to: String) async throws {
        // Call Zig core for rename
    }
}

// File Handle
class UFSFileHandle: FileHandle {
    let zigVolume: OpaquePointer
    let inode: UInt64
    var offset: UInt64 = 0
    
    func read() -> AsyncThrowingStream<Data, Error> {
        // Call Zig core for read
        // Return data stream
    }
    
    func write(_ data: Data) async throws -> Int {
        // Call Zig core for write
        // Return bytes written
    }
    
    func truncate(to offset: UInt64) async throws {
        // Call Zig core for truncate
    }
    
    func getAttributes() async throws -> FileAttributes {
        // Call Zig core for stat
        // Convert capsule to FileAttributes
    }
    
    func setAttributes(_ attributes: FileAttributes) async throws {
        // Convert FileAttributes to capsule updates
        // Call Zig core for setattr
    }
}
```

### 4.3 PAL Implementation (macOS)

```swift
// Block I/O via IOKit
class BlockDevice {
    let media: IOMedia
    let queue: IODispatchQueue
    
    func read(offset: UInt64, length: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let request = IORequest()
            request.buffer = malloc(length)
            request.offset = offset
            request.length = length
            request.completion = { result in
                if let error = result.error {
                    continuation.resume(throwing: error)
                } else {
                    let data = Data(bytesNoCopy: request.buffer!, count: length, deallocator: .free)
                    continuation.resume(returning: data)
                }
            }
            media.asyncRead(request, on: queue)
        }
    }
    
    func write(offset: UInt64, data: Data, fua: Bool) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let request = IORequest()
            request.buffer = UnsafeMutableRawPointer(mutating: (data as NSData).bytes)
            request.offset = offset
            request.length = data.count
            request.options = fua ? .forceUnitAccess : []
            request.completion = { result in
                if let error = result.error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
            media.asyncWrite(request, on: queue)
        }
    }
    
    func flush() async throws {
        try await media.synchronizeCache()
    }
    
    func trim(offset: UInt64, length: UInt64) async throws {
        try await media.trim(offset: offset, length: length)
    }
}
```

### 4.4 Entitlements

```xml
<!-- UFS.entitlements -->
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.developer.filesystem-extension</key>
    <true/>
    <key>com.apple.security.files.user-selected.read-write</key>
    <true/>
</dict>
</plist>
```

### 4.5 Distribution

1. **App Store**: Package as .appex inside .app, notarize
2. **Developer ID**: Sign with Developer ID Application cert, notarize
3. **System Extension**: Install to `/Library/Extensions/` or `~/Library/Extensions/`

---

## 5. UEFI Boot Application

### 5.1 Architecture

```
UEFI Environment:
┌─────────────────────────────────────────────────────────────┐
│ UFS.efi (Zig compiled for UEFI)                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ EFI_LOADED_IMAGE_PROTOCOL                           │   │
│  │  - ImageBase, ImageSize                              │   │
│  │  - DeviceHandle, FilePath                            │   │
│  └─────────────────────────────────────────────────────┘   │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ EFI_SIMPLE_FILE_SYSTEM_PROTOCOL                     │   │
│  │  - OpenVolume() -> EFI_FILE_PROTOCOL                │   │
│  └─────────────────────────────────────────────────────┘   │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ EFI_BLOCK_IO_PROTOCOL (for raw access)              │   │
│  │  - ReadBlocks() / WriteBlocks() / FlushBlocks()     │   │
│  └─────────────────────────────────────────────────────┘   │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ ZIG CORE (UEFI Target)                              │   │
│  │  - Read-only superblock, journal, inodes, dirs      │   │
│  │  - No journal recovery (assumes clean)              │   │
│  │  - No compression (optional: decompress only)       │   │
│  └─────────────────────────────────────────────────────┘   │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ PAL (UEFI Block I/O)                                │   │
│  │  - EFI_BLOCK_IO_PROTOCOL.ReadBlocks/WriteBlocks     │   │
│  │  - EFI_BLOCK_IO_PROTOCOL.FlushBlocks                │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### 5.2 UEFI Protocols Implementation

```zig
// EFI_SIMPLE_FILE_SYSTEM_PROTOCOL
const SimpleFileSystemProtocol = extern struct {
    Revision: u64,
    OpenVolume: *const fn (this: *const SimpleFileSystemProtocol, root: **EFI_FILE_PROTOCOL) -> EFI_STATUS,
};

// EFI_FILE_PROTOCOL (read-only subset)
const FileProtocol = extern struct {
    Revision: u64,
    Open: *const fn (this: *const FileProtocol, new_handle: **EFI_FILE_PROTOCOL, file_name: *const u16, open_mode: u64, attributes: u64) -> EFI_STATUS,
    Close: *const fn (this: *const FileProtocol) -> EFI_STATUS,
    Delete: *const fn (this: *const FileProtocol) -> EFI_STATUS,
    Read: *const fn (this: *const FileProtocol, buffer_size: *mut usize, buffer: *mut anyopaque) -> EFI_STATUS,
    Write: *const fn (this: *const FileProtocol, buffer_size: *mut usize, buffer: *const anyopaque) -> EFI_STATUS,
    GetPosition: *const fn (this: *const FileProtocol, position: *mut u64) -> EFI_STATUS,
    SetPosition: *const fn (this: *const FileProtocol, position: u64) -> EFI_STATUS,
    GetInfo: *const fn (this: *const FileProtocol, info_type: *const EFI_GUID, buffer_size: *mut usize, buffer: *mut anyopaque) -> EFI_STATUS,
    SetInfo: *const fn (this: *const FileProtocol, info_type: *const EFI_GUID, buffer_size: usize, buffer: *const anyopaque) -> EFI_STATUS,
    Flush: *const fn (this: *const FileProtocol) -> EFI_STATUS,
};
```

### 5.3 Bootloader Integration

```
EFI System Partition (FAT32):
  /EFI/BOOT/BOOTX64.EFI          -> UFS.efi (or chainloader)
  /EFI/UFS/UFS.EFI               -> UFS.efi
  /EFI/UFS/ufs.cfg               -> Configuration

UFS Partition:
  /boot/kernel.efi               -> OS kernel
  /boot/initrd.img               -> Initramfs
  /boot/ufs.cfg                  -> Boot config
```

### 5.4 Building for UEFI

```bash
# Zig UEFI target
zig build -Dtarget=x86_64-unknown-uefi -Doptimize=ReleaseFast
zig build -Dtarget=aarch64-unknown-uefi -Doptimize=ReleaseFast

# Output: UFS.efi (PE/COFF format)
```

---

## 6. Cross-Platform Consistency Guarantees

| Aspect | Windows | Linux (VFS) | Linux (FUSE) | macOS | UEFI |
|--------|---------|-------------|--------------|-------|------|
| Metadata Capsules | Full | Full | Full | Full | Read-only |
| Journal Recovery | Full | Full | Full | Full | N/A |
| Compression | Full | Full | Full | Full | Decompress |
| Integrity | Full | Full | Full | Full | Verify |
| Case Sensitivity | Config | Config | Config | Config | Config |
| Permissions | ACLs | POSIX+ACL | POSIX+ACL | POSIX+ACL | Read |
| xattrs/ADS | ADS→xattr | Native | Native | Native | Read |
| Timestamps | 100ns/1601 | ns/1970 | ns/1970 | ns/1970 | ns/1970 |
| Hard Links | Yes | Yes | Yes | Yes | Read |
| Symlinks | Reparse | Native | Native | Native | Read |
| Sparse Files | Yes | Yes | Yes | Yes | Read |
| TRIM/Discard | Yes | Yes | Yes | Yes | N/A |

---

*End of UFS OS Integration Architecture*