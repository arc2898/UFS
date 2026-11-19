// UFS Windows IFS Driver - C Implementation
// Windows 11 Installable File System (IFS) driver
// Uses File System Filter Manager (FSFM) and IFS Kit

#include <ntifs.h>
#include <fltkernel.h>
#include <ntstrsafe.h>

#include "ufs.h"

// POSIX permission bit definitions (for UfsCheckAccess)
#ifndef S_IRUSR
#define S_IRUSR 00400
#define S_IWUSR 00200
#define S_IXUSR 00100
#define S_IRGRP 00040
#define S_IWGRP 00020
#define S_IXGRP 00010
#define S_IROTH 00004
#define S_IWOTH 00002
#define S_IXOTH 00001
#endif

// Alias for ufs_inode_info_t from ufs.h
typedef ufs_inode_info_t UFS_INODE_INFO;

// ============================================================================
// Driver Global State
// ============================================================================

typedef struct _UFS_GLOBAL_DATA {
    PDRIVER_OBJECT DriverObject;
    UNICODE_STRING RegistryPath;
    FAST_MUTEX Lock;
    UFS_FS_HANDLE* FsHandle;
    PDEVICE_OBJECT ControlDevice;
    UNICODE_STRING DeviceName;
    UNICODE_STRING DosDeviceName;
    ULONG Flags;
    ULONG CompressionAlgorithm;
    BOOLEAN IntegrityCheck;
    BOOLEAN CaseInsensitive;
} UFS_GLOBAL_DATA, *PUFS_GLOBAL_DATA;

static UFS_GLOBAL_DATA g_UfsGlobalData = {0};

// ============================================================================
// Volume Context (VCB - Volume Control Block)
// ============================================================================

typedef struct _UFS_VCB {
    // Volume identification
    PDEVICE_OBJECT TargetDeviceObject;
    PDEVICE_OBJECT VpbDeviceObject;
    VPB* Vpb;
    UNICODE_STRING VolumeLabel;
    GUID VolumeGuid;
    LARGE_INTEGER VolumeSerialNumber;

    // UFS core filesystem
    UFS_FS_HANDLE* FsHandle;
    UFS_BLOCK_DEVICE_HANDLE* BlockDevHandle;

    // Mount state
    BOOLEAN Mounted;
    BOOLEAN ReadOnly;
    BOOLEAN CaseInsensitive;
    UCHAR CompressionAlgorithm;
    BOOLEAN IntegrityCheck;
    ULONG JournalSize;

    // Inode cache (FCB lookup)
    RTL_AVL_TABLE FcbTable;
    FAST_MUTEX FcbTableLock;
    ULONG NextFcbId;

    // Resource for volume operations
    ERESOURCE VolumeResource;
    FAST_MUTEX VolumeLock;

    // Cleanup
    FAST_MUTEX CleanupLock;
    BOOLEAN CleanupInProgress;

    // Reference counting
    LONG ReferenceCount;

    // File system info
    UFS_STATFS_INFO StatFs;
} UFS_VCB, *PUFS_VCB;

// ============================================================================
// File Context (FCB - File Control Block)
// ============================================================================

typedef struct _UFS_FCB {
    // Tree links
    RTL_BALANCED_LINKS Links;
    ULONG FcbId;
    ULONGLONG InodeNumber;

    // File attributes
    FILE_BASIC_INFORMATION BasicInfo;
    FILE_STANDARD_INFORMATION StandardInfo;
    FILE_INTERNAL_INFORMATION InternalInfo;
    FILE_NETWORK_OPEN_INFORMATION NetworkInfo;

    // File type
    UFS_FILE_TYPE FileType;

    // Parent directory
    struct _UFS_FCB* ParentFcb;
    UNICODE_STRING FileName;

    // State
    BOOLEAN DeleteOnClose;
    BOOLEAN PagingFile;
    BOOLEAN SystemFile;
    BOOLEAN TemporaryFile;

    // Locks
    ERESOURCE MainResource;
    ERESOURCE PagingIoResource;
    FAST_MUTEX FcbLock;

    // Reference counting
    LONG ReferenceCount;

    // Cached metadata
    UFS_INODE_INFO InodeInfo;

    // Open handles
    LIST_ENTRY CcbList;
    FAST_MUTEX CcbListLock;
    ULONG OpenHandleCount;

    // VCB back-pointer
    PUFS_VCB Vcb;

    // File object (for stream)
    PFILE_OBJECT StreamFileObject;
} UFS_FCB, *PUFS_FCB;

// ============================================================================
// Context Control Block (CCB - per-handle)
// ============================================================================

typedef struct _UFS_CCB {
    // Flags
    ULONG Flags;
    BOOLEAN DeleteOnClose;
    BOOLEAN IsDirectory;
    BOOLEAN IsStreamHandle;

    // Directory enumeration
    UFS_DIR_ITERATOR_HANDLE* DirIterHandle;
    ULONGLONG DirOffset;

    // File position
    LARGE_INTEGER CurrentByteOffset;

    // FCB back-pointer
    PUFS_FCB Fcb;
} UFS_CCB, *PUFS_CCB;

// ============================================================================
// IRP Context
// ============================================================================

typedef struct _UFS_IRP_CONTEXT {
    PUFS_VCB Vcb;
    PUFS_FCB Fcb;
    PUFS_CCB Ccb;
    PIRP Irp;
    PIO_STACK_LOCATION IrpSp;
    ULONG MajorFunction;
    ULONG MinorFunction;
    BOOLEAN Wait;
    BOOLEAN SynchronousIo;
    BOOLEAN PagingIo;
    NTSTATUS Status;
    ULONG_PTR Information;
} UFS_IRP_CONTEXT, *PUFS_IRP_CONTEXT;

// ============================================================================
// Forward Declarations
// ============================================================================

NTSTATUS UfsCreateVolumeDeviceObject(PUFS_VCB* Vcb, PDEVICE_OBJECT TargetDeviceObject);
VOID UfsDeleteVolumeDeviceObject(PUFS_VCB Vcb);
NTSTATUS UfsMountVolume(PUFS_VCB Vcb, PIRP Irp);
NTSTATUS UfsUnmountVolume(PUFS_VCB Vcb);
NTSTATUS UfsVerifyVolume(PUFS_VCB Vcb);
NTSTATUS UfsRecoverVolume(PUFS_VCB Vcb);

NTSTATUS UfsCreateFcb(PUFS_VCB Vcb, ULONGLONG InodeNumber, PUFS_FCB ParentFcb, PUNICODE_STRING FileName, PUFS_FCB* Fcb);
VOID UfsDeleteFcb(PUFS_FCB Fcb);
PUFS_FCB UfsFindFcb(PUFS_VCB Vcb, ULONGLONG InodeNumber);
VOID UfsReferenceFcb(PUFS_FCB Fcb);
VOID UfsDereferenceFcb(PUFS_FCB Fcb);

NTSTATUS UfsCreateCcb(PUFS_FCB Fcb, PUFS_CCB* Ccb);
VOID UfsDeleteCcb(PUFS_CCB Ccb);

NTSTATUS UfsDispatchCreate(PDEVICE_OBJECT DeviceObject, PIRP Irp);
NTSTATUS UfsDispatchClose(PDEVICE_OBJECT DeviceObject, PIRP Irp);
NTSTATUS UfsDispatchRead(PDEVICE_OBJECT DeviceObject, PIRP Irp);
NTSTATUS UfsDispatchWrite(PDEVICE_OBJECT DeviceObject, PIRP Irp);
NTSTATUS UfsDispatchQueryInformation(PDEVICE_OBJECT DeviceObject, PIRP Irp);
NTSTATUS UfsDispatchSetInformation(PDEVICE_OBJECT DeviceObject, PIRP Irp);
NTSTATUS UfsDispatchQueryVolumeInformation(PDEVICE_OBJECT DeviceObject, PIRP Irp);
NTSTATUS UfsDispatchSetVolumeInformation(PDEVICE_OBJECT DeviceObject, PIRP Irp);
NTSTATUS UfsDispatchDirectoryControl(PDEVICE_OBJECT DeviceObject, PIRP Irp);
NTSTATUS UfsDispatchFileSystemControl(PDEVICE_OBJECT DeviceObject, PIRP Irp);
NTSTATUS UfsDispatchDeviceControl(PDEVICE_OBJECT DeviceObject, PIRP Irp);
NTSTATUS UfsDispatchCleanup(PDEVICE_OBJECT DeviceObject, PIRP Irp);
NTSTATUS UfsDispatchPnp(PDEVICE_OBJECT DeviceObject, PIRP Irp);
NTSTATUS UfsDispatchPower(PDEVICE_OBJECT DeviceObject, PIRP Irp);
NTSTATUS UfsDispatchFsControl(PDEVICE_OBJECT DeviceObject, PIRP Irp);

NTSTATUS UfsFastIoCheckIfPossible(PFILE_OBJECT FileObject, PLARGE_INTEGER FileOffset, ULONG Length, BOOLEAN Wait, ULONG LockKey, BOOLEAN CheckForReadOperation, PIO_STATUS_BLOCK IoStatus, PDEVICE_OBJECT DeviceObject);
NTSTATUS UfsFastIoRead(PFILE_OBJECT FileObject, PLARGE_INTEGER FileOffset, ULONG Length, BOOLEAN Wait, ULONG LockKey, PVOID Buffer, PMDL* MdlChain, PIO_STATUS_BLOCK IoStatus, PDEVICE_OBJECT DeviceObject);
NTSTATUS UfsFastIoWrite(PFILE_OBJECT FileObject, PLARGE_INTEGER FileOffset, ULONG Length, BOOLEAN Wait, ULONG LockKey, PVOID Buffer, PMDL* MdlChain, PIO_STATUS_BLOCK IoStatus, PDEVICE_OBJECT DeviceObject);
BOOLEAN UfsFastIoQueryBasicInfo(PFILE_OBJECT FileObject, PFILE_BASIC_INFORMATION Buffer, PIO_STATUS_BLOCK IoStatus, PDEVICE_OBJECT DeviceObject);
BOOLEAN UfsFastIoQueryStandardInfo(PFILE_OBJECT FileObject, PFILE_STANDARD_INFORMATION Buffer, PIO_STATUS_BLOCK IoStatus, PDEVICE_OBJECT DeviceObject);
BOOLEAN UfsFastIoLock(PFILE_OBJECT FileObject, PLARGE_INTEGER FileOffset, PLARGE_INTEGER Length, PEPROCESS ProcessId, ULONG Key, BOOLEAN FailImmediately, BOOLEAN ExclusiveLock, PIO_STATUS_BLOCK IoStatus, PDEVICE_OBJECT DeviceObject);
BOOLEAN UfsFastIoUnlockSingle(PFILE_OBJECT FileObject, PLARGE_INTEGER FileOffset, PLARGE_INTEGER Length, PEPROCESS ProcessId, ULONG Key, PIO_STATUS_BLOCK IoStatus, PDEVICE_OBJECT DeviceObject);
BOOLEAN UfsFastIoUnlockAll(PFILE_OBJECT FileObject, PEPROCESS ProcessId, PIO_STATUS_BLOCK IoStatus, PDEVICE_OBJECT DeviceObject);
BOOLEAN UfsFastIoUnlockAllByKey(PFILE_OBJECT FileObject, PVOID ProcessId, ULONG Key, PIO_STATUS_BLOCK IoStatus, PDEVICE_OBJECT DeviceObject);
BOOLEAN UfsFastIoDeviceControl(PFILE_OBJECT FileObject, BOOLEAN Wait, PVOID InputBuffer, ULONG InputBufferLength, PVOID OutputBuffer, ULONG OutputBufferLength, ULONG IoControlCode, PIO_STATUS_BLOCK IoStatus, PDEVICE_OBJECT DeviceObject);
VOID UfsFastIoDetachDevice(PDEVICE_OBJECT SourceDevice, PDEVICE_OBJECT TargetDevice);
BOOLEAN UfsFastIoQueryNetworkOpenInfo(PFILE_OBJECT FileObject, PFILE_NETWORK_OPEN_INFORMATION Buffer, PIO_STATUS_BLOCK IoStatus, PDEVICE_OBJECT DeviceObject);
NTSTATUS UfsFastIoMdlRead(PFILE_OBJECT FileObject, PLARGE_INTEGER FileOffset, ULONG Length, ULONG LockKey, PMDL* MdlChain, PIO_STATUS_BLOCK IoStatus, PDEVICE_OBJECT DeviceObject);
NTSTATUS UfsFastIoMdlReadComplete(PFILE_OBJECT FileObject, PMDL MdlChain, PDEVICE_OBJECT DeviceObject);
NTSTATUS UfsFastIoPrepareMdlWrite(PFILE_OBJECT FileObject, PLARGE_INTEGER FileOffset, ULONG Length, ULONG LockKey, PMDL* MdlChain, PIO_STATUS_BLOCK IoStatus, PDEVICE_OBJECT DeviceObject);
NTSTATUS UfsFastIoMdlWriteComplete(PFILE_OBJECT FileObject, PLARGE_INTEGER FileOffset, PMDL MdlChain, PDEVICE_OBJECT DeviceObject);
NTSTATUS UfsFastIoReadCompressed(PFILE_OBJECT FileObject, PLARGE_INTEGER FileOffset, ULONG Length, ULONG LockKey, PVOID Buffer, PMDL* MdlChain, PIO_STATUS_BLOCK IoStatus, PDEVICE_OBJECT DeviceObject);
NTSTATUS UfsFastIoWriteCompressed(PFILE_OBJECT FileObject, PLARGE_INTEGER FileOffset, ULONG Length, ULONG LockKey, PVOID Buffer, PMDL* MdlChain, PIO_STATUS_BLOCK IoStatus, PDEVICE_OBJECT DeviceObject);
NTSTATUS UfsFastIoMdlReadCompleteCompressed(PFILE_OBJECT FileObject, PMDL MdlChain, PDEVICE_OBJECT DeviceObject);
NTSTATUS UfsFastIoMdlWriteCompleteCompressed(PFILE_OBJECT FileObject, PLARGE_INTEGER FileOffset, PMDL MdlChain, PDEVICE_OBJECT DeviceObject);
NTSTATUS UfsFastIoQueryOpen(PFILE_OBJECT FileObject, PFILE_NETWORK_OPEN_INFORMATION Buffer, PIO_STATUS_BLOCK IoStatus, PDEVICE_OBJECT DeviceObject);

// ============================================================================
// Driver Entry / Unload
// ============================================================================

NTSTATUS DriverEntry(PDRIVER_OBJECT DriverObject, PUNICODE_STRING RegistryPath) {
    NTSTATUS status;

    // Initialize global data
    RtlZeroMemory(&g_UfsGlobalData, sizeof(g_UfsGlobalData));
    g_UfsGlobalData.DriverObject = DriverObject;
    g_UfsGlobalData.RegistryPath = *RegistryPath;
    ExInitializeFastMutex(&g_UfsGlobalData.Lock);

    // Set up dispatch routines
    for (ULONG i = 0; i <= IRP_MJ_MAXIMUM_FUNCTION; i++) {
        DriverObject->MajorFunction[i] = UfsDispatchCommon;
    }

    // Specific dispatches
    DriverObject->MajorFunction[IRP_MJ_CREATE] = UfsDispatchCreate;
    DriverObject->MajorFunction[IRP_MJ_CLOSE] = UfsDispatchClose;
    DriverObject->MajorFunction[IRP_MJ_READ] = UfsDispatchRead;
    DriverObject->MajorFunction[IRP_MJ_WRITE] = UfsDispatchWrite;
    DriverObject->MajorFunction[IRP_MJ_QUERY_INFORMATION] = UfsDispatchQueryInformation;
    DriverObject->MajorFunction[IRP_MJ_SET_INFORMATION] = UfsDispatchSetInformation;
    DriverObject->MajorFunction[IRP_MJ_QUERY_VOLUME_INFORMATION] = UfsDispatchQueryVolumeInformation;
    DriverObject->MajorFunction[IRP_MJ_SET_VOLUME_INFORMATION] = UfsDispatchSetVolumeInformation;
    DriverObject->MajorFunction[IRP_MJ_DIRECTORY_CONTROL] = UfsDispatchDirectoryControl;
    DriverObject->MajorFunction[IRP_MJ_FILE_SYSTEM_CONTROL] = UfsDispatchFileSystemControl;
    DriverObject->MajorFunction[IRP_MJ_DEVICE_CONTROL] = UfsDispatchDeviceControl;
    DriverObject->MajorFunction[IRP_MJ_CLEANUP] = UfsDispatchCleanup;
    DriverObject->MajorFunction[IRP_MJ_PNP] = UfsDispatchPnp;
    DriverObject->MajorFunction[IRP_MJ_POWER] = UfsDispatchPower;
    DriverObject->MajorFunction[IRP_MJ_SHUTDOWN] = UfsDispatchShutdown;
    DriverObject->MajorFunction[IRP_MJ_FLUSH_BUFFERS] = UfsDispatchFlushBuffers;

    DriverObject->DriverUnload = UfsUnload;
    DriverObject->FastIoDispatch = &g_UfsFastIoDispatch;

    // Create control device object
    RtlInitUnicodeString(&g_UfsGlobalData.DeviceName, L"\\Device\\UfsControl");
    status = IoCreateDevice(DriverObject, 0, &g_UfsGlobalData.DeviceName,
                            FILE_DEVICE_FILE_SYSTEM, FILE_DEVICE_SECURE_OPEN, FALSE,
                            &g_UfsGlobalData.ControlDevice);
    if (!NT_SUCCESS(status)) {
        return status;
    }

    RtlInitUnicodeString(&g_UfsGlobalData.DosDeviceName, L"\\DosDevices\\UfsControl");
    IoCreateSymbolicLink(&g_UfsGlobalData.DosDeviceName, &g_UfsGlobalData.DeviceName);

    // Set default options
    g_UfsGlobalData.CompressionAlgorithm = UFS_COMPRESSION_LZ4;
    g_UfsGlobalData.IntegrityCheck = TRUE;
    g_UfsGlobalData.CaseInsensitive = TRUE;

    DbgPrint("UFS IFS Driver loaded\n");
    return STATUS_SUCCESS;
}

VOID UfsUnload(PDRIVER_OBJECT DriverObject) {
    // Delete control device
    if (g_UfsGlobalData.ControlDevice) {
        IoDeleteSymbolicLink(&g_UfsGlobalData.DosDeviceName);
        IoDeleteDevice(g_UfsGlobalData.ControlDevice);
    }

    DbgPrint("UFS IFS Driver unloaded\n");
}

// ============================================================================
// Completion Routine for async I/O operations
// ============================================================================

NTSTATUS UfsCompletionRoutine(PDEVICE_OBJECT DeviceObject, PIRP Irp, PVOID Context) {
    PUFS_IRP_CONTEXT IrpContext = (PUFS_IRP_CONTEXT)Context;

    // If the IRP is pending, we need to mark it as pending and return STATUS_MORE_PROCESSING_REQUIRED
    if (Irp->PendingReturned) {
        IoMarkIrpPending(Irp);
    }

    // Free the IRP context
    ExFreePoolWithTag(IrpContext, 'sfcU');

    // Return STATUS_MORE_PROCESSING_REQUIRED to stop completion processing
    // The caller will complete the IRP
    return STATUS_MORE_PROCESSING_REQUIRED;
}

// ============================================================================
// Common Dispatch
// ============================================================================

NTSTATUS UfsDispatchCommon(PDEVICE_OBJECT DeviceObject, PIRP Irp) {
    PUFS_IRP_CONTEXT IrpContext = NULL;
    NTSTATUS status;

    // Allocate IRP context
    IrpContext = ExAllocatePoolWithTag(NonPagedPool, sizeof(UFS_IRP_CONTEXT), 'sfcU');
    if (!IrpContext) {
        Irp->IoStatus.Status = STATUS_INSUFFICIENT_RESOURCES;
        Irp->IoStatus.Information = 0;
        IoCompleteRequest(Irp, IO_NO_INCREMENT);
        return STATUS_INSUFFICIENT_RESOURCES;
    }

    RtlZeroMemory(IrpContext, sizeof(UFS_IRP_CONTEXT));
    IrpContext->Irp = Irp;
    IrpContext->IrpSp = IoGetCurrentIrpStackLocation(Irp);
    IrpContext->MajorFunction = IrpContext->IrpSp->MajorFunction;
    IrpContext->MinorFunction = IrpContext->IrpSp->MinorFunction;

    // Get VCB from device object
    if (DeviceObject != g_UfsGlobalData.ControlDevice) {
        IrpContext->Vcb = DeviceObject->DeviceExtension;
        if (IrpContext->Vcb) {
            IrpContext->Fcb = IrpContext->IrpSp->FileObject ? IrpContext->IrpSp->FileObject->FsContext : NULL;
            IrpContext->Ccb = IrpContext->IrpSp->FileObject ? IrpContext->IrpSp->FileObject->FsContext2 : NULL;
        }
    }

    // Check wait flag
    IrpContext->Wait = BooleanFlagOn(IrpContext->IrpSp->Flags, SL_WAIT);
    IrpContext->SynchronousIo = BooleanFlagOn(IrpContext->IrpSp->FileObject ? IrpContext->IrpSp->FileObject->Flags : 0, FO_SYNCHRONOUS_IO);
    IrpContext->PagingIo = BooleanFlagOn(Irp->Flags, IRP_PAGING_IO);

    // Dispatch to specific handler
    switch (IrpContext->MajorFunction) {
        case IRP_MJ_CREATE:
            status = UfsDispatchCreate(DeviceObject, Irp);
            break;
        case IRP_MJ_CLOSE:
            status = UfsDispatchClose(DeviceObject, Irp);
            break;
        case IRP_MJ_READ:
            status = UfsDispatchRead(DeviceObject, Irp);
            break;
        case IRP_MJ_WRITE:
            status = UfsDispatchWrite(DeviceObject, Irp);
            break;
        case IRP_MJ_QUERY_INFORMATION:
            status = UfsDispatchQueryInformation(DeviceObject, Irp);
            break;
        case IRP_MJ_SET_INFORMATION:
            status = UfsDispatchSetInformation(DeviceObject, Irp);
            break;
        case IRP_MJ_QUERY_VOLUME_INFORMATION:
            status = UfsDispatchQueryVolumeInformation(DeviceObject, Irp);
            break;
        case IRP_MJ_SET_VOLUME_INFORMATION:
            status = UfsDispatchSetVolumeInformation(DeviceObject, Irp);
            break;
        case IRP_MJ_DIRECTORY_CONTROL:
            status = UfsDispatchDirectoryControl(DeviceObject, Irp);
            break;
        case IRP_MJ_FILE_SYSTEM_CONTROL:
            status = UfsDispatchFileSystemControl(DeviceObject, Irp);
            break;
        case IRP_MJ_DEVICE_CONTROL:
            status = UfsDispatchDeviceControl(DeviceObject, Irp);
            break;
        case IRP_MJ_CLEANUP:
            status = UfsDispatchCleanup(DeviceObject, Irp);
            break;
        case IRP_MJ_PNP:
            status = UfsDispatchPnp(DeviceObject, Irp);
            break;
        case IRP_MJ_POWER:
            status = UfsDispatchPower(DeviceObject, Irp);
            break;
        case IRP_MJ_SHUTDOWN:
            status = UfsDispatchShutdown(DeviceObject, Irp);
            break;
        case IRP_MJ_FLUSH_BUFFERS:
            status = UfsDispatchFlushBuffers(DeviceObject, Irp);
            break;
        default:
            status = STATUS_INVALID_DEVICE_REQUEST;
            break;
    }

    // Handle completion
    if (status == STATUS_PENDING) {
        // Operation is pending - completion routine will free the context
        IoSetCompletionRoutine(Irp, UfsCompletionRoutine, IrpContext, TRUE, TRUE, TRUE);
        // Do NOT free IrpContext here - it will be freed in completion routine
        // Do NOT complete IRP here - it will be completed by the async operation
    } else {
        // Synchronous completion
        Irp->IoStatus.Status = status;
        IoCompleteRequest(Irp, IO_NO_INCREMENT);
        ExFreePoolWithTag(IrpContext, 'sfcU');
    }

    return status;
}

// ============================================================================
// Mount / Unmount
// ============================================================================

NTSTATUS UfsMountVolume(PUFS_VCB Vcb, PIRP Irp) {
    NTSTATUS status;
    UFS_MOUNT_OPTIONS MountOpts = {0};

    // Open block device
    status = UfsBlockDeviceOpen(Vcb->TargetDeviceObject, &Vcb->BlockDevHandle);
    if (!NT_SUCCESS(status)) {
        return status;
    }

    // Check if recovery needed
    if (UfsNeedsRecovery(Vcb->BlockDevHandle)) {
        status = UfsRecover(Vcb->BlockDevHandle);
        if (!NT_SUCCESS(status)) {
            UfsBlockDeviceClose(Vcb->BlockDevHandle);
            return status;
        }
    }

    // Set mount options
    MountOpts.ReadOnly = Vcb->ReadOnly;
    MountOpts.CaseInsensitive = Vcb->CaseInsensitive;
    MountOpts.Compression = Vcb->CompressionAlgorithm;
    MountOpts.IntegrityCheck = Vcb->IntegrityCheck;
    MountOpts.JournalSize = Vcb->JournalSize;

    // Mount filesystem
    status = UfsMount(Vcb->BlockDevHandle, &MountOpts, &Vcb->FsHandle);
    if (!NT_SUCCESS(status)) {
        UfsBlockDeviceClose(Vcb->BlockDevHandle);
        return status;
    }

    // Get filesystem stats
    status = UfsStatFs(Vcb->FsHandle, &Vcb->StatFs);
    if (!NT_SUCCESS(status)) {
        UfsUnmount(Vcb->FsHandle);
        UfsBlockDeviceClose(Vcb->BlockDevHandle);
        return status;
    }

    // Create root FCB
    PUFS_FCB RootFcb;
    status = UfsCreateFcb(Vcb, 2, NULL, NULL, &RootFcb);
    if (!NT_SUCCESS(status)) {
        UfsUnmount(Vcb->FsHandle);
        UfsBlockDeviceClose(Vcb->BlockDevHandle);
        return status;
    }

    Vcb->Mounted = TRUE;
    DbgPrint("UFS: Volume mounted successfully\n");
    return STATUS_SUCCESS;
}

NTSTATUS UfsUnmountVolume(PUFS_VCB Vcb) {
    if (!Vcb->Mounted) {
        return STATUS_SUCCESS;
    }

    // Flush all data
    UfsSync(Vcb->FsHandle);

    // Unmount filesystem
    UfsUnmount(Vcb->FsHandle);
    Vcb->FsHandle = NULL;

    // Close block device
    UfsBlockDeviceClose(Vcb->BlockDevHandle);
    Vcb->BlockDevHandle = NULL;

    Vcb->Mounted = FALSE;
    DbgPrint("UFS: Volume unmounted\n");
    return STATUS_SUCCESS;
}

// ============================================================================
// VCB/FCB/CCB Management
// ============================================================================

NTSTATUS UfsCreateFcb(PUFS_VCB Vcb, ULONGLONG InodeNumber, PUFS_FCB ParentFcb, PUNICODE_STRING FileName, PUFS_FCB* Fcb) {
    PUFS_FCB NewFcb = ExAllocatePoolWithTag(NonPagedPool, sizeof(UFS_FCB), 'BCFU');
    if (!NewFcb) {
        return STATUS_INSUFFICIENT_RESOURCES;
    }

    RtlZeroMemory(NewFcb, sizeof(UFS_FCB));
    NewFcb->FcbId = InterlockedIncrement(&Vcb->NextFcbId);
    NewFcb->InodeNumber = InodeNumber;
    NewFcb->Vcb = Vcb;
    NewFcb->ParentFcb = ParentFcb;

    ExInitializeResourceLite(&NewFcb->MainResource);
    ExInitializeResourceLite(&NewFcb->PagingIoResource);
    ExInitializeFastMutex(&NewFcb->FcbLock);
    InitializeListHead(&NewFcb->CcbList);
    ExInitializeFastMutex(&NewFcb->CcbListLock);
    NewFcb->ReferenceCount = 1;

    // Get inode info from UFS core
    UfsGetAttr(Vcb->FsHandle, InodeNumber, &NewFcb->InodeInfo);

    // Convert to NT file attributes
    NewFcb->BasicInfo.CreationTime.QuadPart = NewFcb->InodeInfo.CreationTime * 10000000 + 116444736000000000LL;
    NewFcb->BasicInfo.LastAccessTime.QuadPart = NewFcb->InodeInfo.LastAccessTime * 10000000 + 116444736000000000LL;
    NewFcb->BasicInfo.LastWriteTime.QuadPart = NewFcb->InodeInfo.LastWriteTime * 10000000 + 116444736000000000LL;
    NewFcb->BasicInfo.ChangeTime.QuadPart = NewFcb->InodeInfo.ChangeTime * 10000000 + 116444736000000000LL;
    NewFcb->BasicInfo.FileAttributes = UfsFileTypeToAttributes(NewFcb->InodeInfo.FileType);

    NewFcb->StandardInfo.AllocationSize.QuadPart = NewFcb->InodeInfo.AllocatedSize;
    NewFcb->StandardInfo.EndOfFile.QuadPart = NewFcb->InodeInfo.FileSize;
    NewFcb->StandardInfo.NumberOfLinks = NewFcb->InodeInfo.LinkCount;
    NewFcb->StandardInfo.DeletePending = FALSE;
    NewFcb->StandardInfo.Directory = (NewFcb->InodeInfo.FileType == UFS_FILE_TYPE_DIR);

    NewFcb->InternalInfo.IndexNumber.QuadPart = InodeNumber;

    NewFcb->NetworkInfo.CreationTime = NewFcb->BasicInfo.CreationTime;
    NewFcb->NetworkInfo.LastAccessTime = NewFcb->BasicInfo.LastAccessTime;
    NewFcb->NetworkInfo.LastWriteTime = NewFcb->BasicInfo.LastWriteTime;
    NewFcb->NetworkInfo.ChangeTime = NewFcb->BasicInfo.ChangeTime;
    NewFcb->NetworkInfo.AllocationSize = NewFcb->StandardInfo.AllocationSize;
    NewFcb->NetworkInfo.EndOfFile = NewFcb->StandardInfo.EndOfFile;
    NewFcb->NetworkInfo.FileAttributes = NewFcb->BasicInfo.FileAttributes;

    // Copy filename if provided
    if (FileName && FileName->Length > 0) {
        NewFcb->FileName.MaximumLength = FileName->Length;
        NewFcb->FileName.Buffer = ExAllocatePoolWithTag(PagedPool, FileName->Length, 'mNFU');
        if (NewFcb->FileName.Buffer) {
            RtlCopyUnicodeString(&NewFcb->FileName, FileName);
        }
    }

    // Insert into VCB table
    ExAcquireFastMutex(&Vcb->FcbTableLock);
    RtlInsertElementGenericTableAvl(&Vcb->FcbTable, NewFcb, sizeof(UFS_FCB), NULL);
    ExReleaseFastMutex(&Vcb->FcbTableLock);

    *Fcb = NewFcb;
    return STATUS_SUCCESS;
}

VOID UfsDeleteFcb(PUFS_FCB Fcb) {
    PUFS_VCB Vcb = Fcb->Vcb;

    // Remove from table
    ExAcquireFastMutex(&Vcb->FcbTableLock);
    RtlDeleteElementGenericTableAvl(&Vcb->FcbTable, Fcb);
    ExReleaseFastMutex(&Vcb->FcbTableLock);

    // Free resources
    if (Fcb->FileName.Buffer) {
        ExFreePoolWithTag(Fcb->FileName.Buffer, 'mNFU');
    }

    ExDeleteResourceLite(&Fcb->MainResource);
    ExDeleteResourceLite(&Fcb->PagingIoResource);

    ExFreePoolWithTag(Fcb, 'BCFU');
}

PUFS_FCB UfsFindFcb(PUFS_VCB Vcb, ULONGLONG InodeNumber) {
    UFS_FCB SearchFcb = {0};
    SearchFcb.InodeNumber = InodeNumber;

    ExAcquireFastMutex(&Vcb->FcbTableLock);
    PUFS_FCB Fcb = RtlLookupElementGenericTableAvl(&Vcb->FcbTable, &SearchFcb);
    if (Fcb) {
        UfsReferenceFcb(Fcb);
    }
    ExReleaseFastMutex(&Vcb->FcbTableLock);

    return Fcb;
}

VOID UfsReferenceFcb(PUFS_FCB Fcb) {
    InterlockedIncrement(&Fcb->ReferenceCount);
}

VOID UfsDereferenceFcb(PUFS_FCB Fcb) {
    if (InterlockedDecrement(&Fcb->ReferenceCount) == 0) {
        UfsDeleteFcb(Fcb);
    }
}

NTSTATUS UfsCreateCcb(PUFS_FCB Fcb, PUFS_CCB* Ccb) {
    PUFS_CCB NewCcb = ExAllocatePoolWithTag(NonPagedPool, sizeof(UFS_CCB), 'BCCU');
    if (!NewCcb) {
        return STATUS_INSUFFICIENT_RESOURCES;
    }

    RtlZeroMemory(NewCcb, sizeof(UFS_CCB));
    NewCcb->Fcb = Fcb;
    NewCcb->IsDirectory = (Fcb->InodeInfo.FileType == UFS_FILE_TYPE_DIR);

    ExAcquireFastMutex(&Fcb->CcbListLock);
    InsertTailList(&Fcb->CcbList, &NewCcb->CcbListEntry);
    Fcb->OpenHandleCount++;
    ExReleaseFastMutex(&Fcb->CcbListLock);

    *Ccb = NewCcb;
    return STATUS_SUCCESS;
}

VOID UfsDeleteCcb(PUFS_CCB Ccb) {
    PUFS_FCB Fcb = Ccb->Fcb;

    ExAcquireFastMutex(&Fcb->CcbListLock);
    RemoveEntryList(&Ccb->CcbListEntry);
    Fcb->OpenHandleCount--;
    ExReleaseFastMutex(&Fcb->CcbListLock);

    if (Ccb->DirIterHandle) {
        UfsCloseDir(Ccb->DirIterHandle);
    }

    ExFreePoolWithTag(Ccb, 'BCCU');
}

// ============================================================================
// Dispatch Routines
// ============================================================================

NTSTATUS UfsDispatchCreate(PDEVICE_OBJECT DeviceObject, PIRP Irp) {
    PUFS_IRP_CONTEXT IrpContext = Irp->Tail.Overlay.DriverContext[0];
    PUFS_VCB Vcb = IrpContext->Vcb;
    PIO_STACK_LOCATION IrpSp = IrpContext->IrpSp;
    PFILE_OBJECT FileObject = IrpSp->FileObject;
    NTSTATUS status;

    // Get desired access
    ACCESS_MASK DesiredAccess = IrpSp->Parameters.Create.SecurityContext->DesiredAccess;
    ULONG ShareAccess = IrpSp->Parameters.Create.ShareAccess;
    ULONG CreateOptions = IrpSp->Parameters.Create.Options;
    ULONG CreateDisposition = (CreateOptions >> 24) & 0xFF;

    // Get filename
    PUNICODE_STRING FileName = &FileObject->FileName;

    // Resolve path to inode
    ULONGLONG InodeNumber;
    PUFS_FCB ParentFcb = NULL;

    if (FileName->Length == 0 || (FileName->Length == 2 && FileName->Buffer[0] == L'\\')) {
        // Root directory
        InodeNumber = 2;
    } else {
        // Lookup path
        status = UfsLookupPath(Vcb, FileObject->RelatedFileObject ?
                               FileObject->RelatedFileObject->FsContext : NULL, FileName, &InodeNumber, &ParentFcb);
        if (!NT_SUCCESS(status)) {
            return status;
        }
    }

    // Check if FCB exists
    PUFS_FCB Fcb = UfsFindFcb(Vcb, InodeNumber);
    BOOLEAN NewFcb = FALSE;

    if (!Fcb) {
        // Create new FCB
        status = UfsCreateFcb(Vcb, InodeNumber, ParentFcb, FileName, &Fcb);
        if (!NT_SUCCESS(status)) {
            return status;
        }
        NewFcb = TRUE;
    }

    // Check access permissions
    if (!UfsCheckAccess(Fcb, DesiredAccess)) {
        if (NewFcb) UfsDereferenceFcb(Fcb);
        return STATUS_ACCESS_DENIED;
    }

    // Handle create dispositions
    if (CreateDisposition == FILE_CREATE || CreateDisposition == FILE_OPEN_IF) {
        if (!NewFcb) {
            if (CreateDisposition == FILE_CREATE) {
                UfsDereferenceFcb(Fcb);
                return STATUS_OBJECT_NAME_COLLISION;
            }
        }
    } else if (CreateDisposition == FILE_OPEN || CreateDisposition == FILE_OVERWRITE || CreateDisposition == FILE_OVERWRITE_IF) {
        if (NewFcb) {
            UfsDereferenceFcb(Fcb);
            return STATUS_OBJECT_NAME_NOT_FOUND;
        }
    }

    // Create CCB
    PUFS_CCB Ccb;
    status = UfsCreateCcb(Fcb, &Ccb);
    if (!NT_SUCCESS(status)) {
        UfsDereferenceFcb(Fcb);
        return status;
    }

    // Set file object contexts
    FileObject->FsContext = Fcb;
    FileObject->FsContext2 = Ccb;

    // Set file object flags
    if (FlagOn(CreateOptions, FILE_DIRECTORY_FILE)) {
        SetFlag(FileObject->Flags, FO_DIRECTORY_FILE);
    }
    if (FlagOn(CreateOptions, FILE_NO_INTERMEDIATE_BUFFERING)) {
        SetFlag(FileObject->Flags, FO_NO_INTERMEDIATE_BUFFERING);
    }
    if (FlagOn(CreateOptions, FILE_WRITE_THROUGH)) {
        SetFlag(FileObject->Flags, FO_WRITE_THROUGH);
    }
    if (FlagOn(CreateOptions, FILE_SEQUENTIAL_ONLY)) {
        SetFlag(FileObject->Flags, FO_SEQUENTIAL_ONLY);
    }
    if (FlagOn(CreateOptions, FILE_RANDOM_ACCESS)) {
        SetFlag(FileObject->Flags, FO_RANDOM_ACCESS);
    }

    // Return create info
    Irp->IoStatus.Information = NewFcb ? FILE_CREATED : FILE_OPENED;

    UfsDereferenceFcb(Fcb);
    return STATUS_SUCCESS;
}

NTSTATUS UfsDispatchClose(PDEVICE_OBJECT DeviceObject, PIRP Irp) {
    PUFS_IRP_CONTEXT IrpContext = Irp->Tail.Overlay.DriverContext[0];
    PFILE_OBJECT FileObject = IrpContext->IrpSp->FileObject;
    PUFS_FCB Fcb = FileObject->FsContext;
    PUFS_CCB Ccb = FileObject->FsContext2;

    if (Ccb) {
        UfsDeleteCcb(Ccb);
        FileObject->FsContext2 = NULL;
    }

    if (Fcb) {
        // Check for delete on close
        if (Ccb && Ccb->DeleteOnClose && !Vcb->ReadOnly) {
            UfsDeleteFile(Fcb);
        }
        UfsDereferenceFcb(Fcb);
        FileObject->FsContext = NULL;
    }

    return STATUS_SUCCESS;
}

NTSTATUS UfsDispatchRead(PDEVICE_OBJECT DeviceObject, PIRP Irp) {
    PUFS_IRP_CONTEXT IrpContext = Irp->Tail.Overlay.DriverContext[0];
    PUFS_FCB Fcb = IrpContext->Fcb;
    PUFS_CCB Ccb = IrpContext->Ccb;
    PIO_STACK_LOCATION IrpSp = IrpContext->IrpSp;

    if (!Fcb || Fcb->InodeInfo.FileType != UFS_FILE_TYPE_REG) {
        return STATUS_INVALID_PARAMETER;
    }

    LARGE_INTEGER Offset = IrpSp->Parameters.Read.ByteOffset;
    ULONG Length = IrpSp->Parameters.Read.Length;

    // Get system buffer or MDL
    PVOID Buffer;
    if (Irp->MdlAddress) {
        Buffer = MmGetSystemAddressForMdlSafe(Irp->MdlAddress, NormalPagePriority);
    } else {
        Buffer = Irp->UserBuffer;
    }

    if (!Buffer) {
        return STATUS_INSUFFICIENT_RESOURCES;
    }

    // Read from UFS core
    ULONG BytesRead;
    NTSTATUS status = UfsReadFile(Fcb, Offset.QuadPart, Buffer, Length, &BytesRead);

    Irp->IoStatus.Information = BytesRead;
    return status;
}

NTSTATUS UfsDispatchWrite(PDEVICE_OBJECT DeviceObject, PIRP Irp) {
    PUFS_IRP_CONTEXT IrpContext = Irp->Tail.Overlay.DriverContext[0];
    PUFS_VCB Vcb = IrpContext->Vcb;
    PUFS_FCB Fcb = IrpContext->Fcb;
    PUFS_CCB Ccb = IrpContext->Ccb;
    PIO_STACK_LOCATION IrpSp = IrpContext->IrpSp;

    if (Vcb->ReadOnly) {
        return STATUS_MEDIA_WRITE_PROTECTED;
    }

    if (!Fcb || Fcb->InodeInfo.FileType != UFS_FILE_TYPE_REG) {
        return STATUS_INVALID_PARAMETER;
    }

    LARGE_INTEGER Offset = IrpSp->Parameters.Write.ByteOffset;
    ULONG Length = IrpSp->Parameters.Write.Length;

    // Get system buffer or MDL
    PVOID Buffer;
    if (Irp->MdlAddress) {
        Buffer = MmGetSystemAddressForMdlSafe(Irp->MdlAddress, NormalPagePriority);
    } else {
        Buffer = Irp->UserBuffer;
    }

    if (!Buffer) {
        return STATUS_INSUFFICIENT_RESOURCES;
    }

    // Write to UFS core
    ULONG BytesWritten;
    NTSTATUS status = UfsWriteFile(Fcb, Offset.QuadPart, Buffer, Length, &BytesWritten);

    Irp->IoStatus.Information = BytesWritten;
    return status;
}

NTSTATUS UfsDispatchQueryInformation(PDEVICE_OBJECT DeviceObject, PIRP Irp) {
    PUFS_IRP_CONTEXT IrpContext = Irp->Tail.Overlay.DriverContext[0];
    PUFS_FCB Fcb = IrpContext->Fcb;
    PIO_STACK_LOCATION IrpSp = IrpContext->IrpSp;

    if (!Fcb) {
        return STATUS_INVALID_PARAMETER;
    }

    FILE_INFORMATION_CLASS FileInformationClass = IrpSp->Parameters.QueryFile.FileInformationClass;
    PVOID Buffer = Irp->UserBuffer;
    ULONG Length = IrpSp->Parameters.QueryFile.Length;

    NTSTATUS status = STATUS_SUCCESS;
    ULONG BytesWritten = 0;

    switch (FileInformationClass) {
        case FileBasicInformation:
            if (Length < sizeof(FILE_BASIC_INFORMATION)) return STATUS_BUFFER_TOO_SMALL;
            RtlCopyMemory(Buffer, &Fcb->BasicInfo, sizeof(FILE_BASIC_INFORMATION));
            BytesWritten = sizeof(FILE_BASIC_INFORMATION);
            break;
        case FileStandardInformation:
            if (Length < sizeof(FILE_STANDARD_INFORMATION)) return STATUS_BUFFER_TOO_SMALL;
            RtlCopyMemory(Buffer, &Fcb->StandardInfo, sizeof(FILE_STANDARD_INFORMATION));
            BytesWritten = sizeof(FILE_STANDARD_INFORMATION);
            break;
        case FileInternalInformation:
            if (Length < sizeof(FILE_INTERNAL_INFORMATION)) return STATUS_BUFFER_TOO_SMALL;
            RtlCopyMemory(Buffer, &Fcb->InternalInfo, sizeof(FILE_INTERNAL_INFORMATION));
            BytesWritten = sizeof(FILE_INTERNAL_INFORMATION);
            break;
        case FileNetworkOpenInformation:
            if (Length < sizeof(FILE_NETWORK_OPEN_INFORMATION)) return STATUS_BUFFER_TOO_SMALL;
            RtlCopyMemory(Buffer, &Fcb->NetworkInfo, sizeof(FILE_NETWORK_OPEN_INFORMATION));
            BytesWritten = sizeof(FILE_NETWORK_OPEN_INFORMATION);
            break;
        case FileAllInformation: {
            if (Length < sizeof(FILE_ALL_INFORMATION)) return STATUS_BUFFER_TOO_SMALL;
            PFILE_ALL_INFORMATION AllInfo = Buffer;
            AllInfo->BasicInformation = Fcb->BasicInfo;
            AllInfo->StandardInformation = Fcb->StandardInfo;
            AllInfo->InternalInformation = Fcb->InternalInfo;
            // ... fill other fields
            BytesWritten = sizeof(FILE_ALL_INFORMATION);
            break;
        }
        default:
            status = STATUS_INVALID_INFO_CLASS;
            break;
    }

    Irp->IoStatus.Information = BytesWritten;
    return status;
}

NTSTATUS UfsDispatchSetInformation(PDEVICE_OBJECT DeviceObject, PIRP Irp) {
    PUFS_IRP_CONTEXT IrpContext = Irp->Tail.Overlay.DriverContext[0];
    PUFS_VCB Vcb = IrpContext->Vcb;
    PUFS_FCB Fcb = IrpContext->Fcb;
    PIO_STACK_LOCATION IrpSp = IrpContext->IrpSp;

    if (Vcb->ReadOnly) {
        return STATUS_MEDIA_WRITE_PROTECTED;
    }

    if (!Fcb) {
        return STATUS_INVALID_PARAMETER;
    }

    FILE_INFORMATION_CLASS FileInformationClass = IrpSp->Parameters.SetFile.FileInformationClass;
    PVOID Buffer = Irp->UserBuffer;
    ULONG Length = IrpSp->Parameters.SetFile.Length;

    NTSTATUS status = STATUS_SUCCESS;

    switch (FileInformationClass) {
        case FileBasicInformation: {
            if (Length < sizeof(FILE_BASIC_INFORMATION)) return STATUS_BUFFER_TOO_SMALL;
            PFILE_BASIC_INFORMATION BasicInfo = Buffer;
            // Update timestamps
            Fcb->BasicInfo = *BasicInfo;
            // Sync to UFS core
            UfsSetAttr(Vcb->FsHandle, Fcb->InodeNumber, ...);
            break;
        }
        case FileDispositionInformation: {
            if (Length < sizeof(FILE_DISPOSITION_INFORMATION)) return STATUS_BUFFER_TOO_SMALL;
            PFILE_DISPOSITION_INFORMATION DispInfo = Buffer;
            if (DispInfo->DeleteFile) {
                // Mark for delete on close
                PUFS_CCB Ccb = IrpContext->Ccb;
                if (Ccb) Ccb->DeleteOnClose = TRUE;
            }
            break;
        }
        case FileRenameInformation: {
            // Handle rename
            break;
        }
        case FileLinkInformation: {
            // Handle hard link
            break;
        }
        default:
            status = STATUS_INVALID_INFO_CLASS;
            break;
    }

    return status;
}

NTSTATUS UfsDispatchQueryVolumeInformation(PDEVICE_OBJECT DeviceObject, PIRP Irp) {
    PUFS_IRP_CONTEXT IrpContext = Irp->Tail.Overlay.DriverContext[0];
    PUFS_VCB Vcb = IrpContext->Vcb;
    PIO_STACK_LOCATION IrpSp = IrpContext->IrpSp;

    FS_INFORMATION_CLASS FsInformationClass = IrpSp->Parameters.QueryVolume.FsInformationClass;
    PVOID Buffer = Irp->UserBuffer;
    ULONG Length = IrpSp->Parameters.QueryVolume.Length;

    NTSTATUS status = STATUS_SUCCESS;
    ULONG BytesWritten = 0;

    switch (FsInformationClass) {
        case FileFsVolumeInformation: {
            if (Length < sizeof(FILE_FS_VOLUME_INFORMATION)) return STATUS_BUFFER_TOO_SMALL;
            PFILE_FS_VOLUME_INFORMATION VolInfo = Buffer;
            VolInfo->VolumeCreationTime.QuadPart = 0; // From superblock
            VolInfo->VolumeSerialNumber = Vcb->VolumeSerialNumber.LowPart;
            VolInfo->VolumeLabelLength = Vcb->VolumeLabel.Length;
            RtlCopyMemory(VolInfo->VolumeLabel, Vcb->VolumeLabel.Buffer, Vcb->VolumeLabel.Length);
            BytesWritten = FIELD_OFFSET(FILE_FS_VOLUME_INFORMATION, VolumeLabel) + Vcb->VolumeLabel.Length;
            break;
        }
        case FileFsSizeInformation: {
            if (Length < sizeof(FILE_FS_SIZE_INFORMATION)) return STATUS_BUFFER_TOO_SMALL;
            PFILE_FS_SIZE_INFORMATION SizeInfo = Buffer;
            SizeInfo->TotalAllocationUnits.QuadPart = Vcb->StatFs.TotalSpace / Vcb->StatFs.ClusterSize;
            SizeInfo->AvailableAllocationUnits.QuadPart = Vcb->StatFs.FreeSpace / Vcb->StatFs.ClusterSize;
            SizeInfo->SectorsPerAllocationUnit = Vcb->StatFs.ClusterSize / Vcb->StatFs.SectorSize;
            SizeInfo->BytesPerSector = Vcb->StatFs.SectorSize;
            BytesWritten = sizeof(FILE_FS_SIZE_INFORMATION);
            break;
        }
        case FileFsAttributeInformation: {
            if (Length < sizeof(FILE_FS_ATTRIBUTE_INFORMATION)) return STATUS_BUFFER_TOO_SMALL;
            PFILE_FS_ATTRIBUTE_INFORMATION AttrInfo = Buffer;
            AttrInfo->FileSystemAttributes = FILE_CASE_SENSITIVE_SEARCH | FILE_CASE_PRESERVED_NAMES |
                                             FILE_SUPPORTS_HARD_LINKS | FILE_SUPPORTS_REPARSE_POINTS |
                                             FILE_SUPPORTS_SPARSE_FILES | FILE_SUPPORTS_ENCRYPTION |
                                             FILE_NAMED_STREAMS | FILE_READ_ONLY_VOLUME |
                                             FILE_VOLUME_IS_COMPRESSED | FILE_SUPPORTS_OBJECT_IDS |
                                             FILE_SUPPORTS_EXTENDED_ATTRIBUTES | FILE_SUPPORTS_OPEN_BY_FILE_ID |
                                             FILE_SUPPORTS_USN_JOURNAL;
            if (Vcb->ReadOnly) AttrInfo->FileSystemAttributes |= FILE_READ_ONLY_VOLUME;
            AttrInfo->MaximumComponentNameLength = 255;
            AttrInfo->FileSystemNameLength = sizeof(L"UFS") - sizeof(WCHAR);
            RtlCopyMemory(AttrInfo->FileSystemName, L"UFS", AttrInfo->FileSystemNameLength);
            BytesWritten = FIELD_OFFSET(FILE_FS_ATTRIBUTE_INFORMATION, FileSystemName) + AttrInfo->FileSystemNameLength;
            break;
        }
        case FileFsFullSizeInformation: {
            if (Length < sizeof(FILE_FS_FULL_SIZE_INFORMATION)) return STATUS_BUFFER_TOO_SMALL;
            PFILE_FS_FULL_SIZE_INFORMATION FullSizeInfo = Buffer;
            FullSizeInfo->TotalAllocationUnits.QuadPart = Vcb->StatFs.TotalSpace / Vcb->StatFs.ClusterSize;
            FullSizeInfo->AvailableAllocationUnits.QuadPart = Vcb->StatFs.FreeSpace / Vcb->StatFs.ClusterSize;
            FullSizeInfo->ActualAvailableAllocationUnits.QuadPart = Vcb->StatFs.FreeSpace / Vcb->StatFs.ClusterSize;
            FullSizeInfo->SectorsPerAllocationUnit = Vcb->StatFs.ClusterSize / Vcb->StatFs.SectorSize;
            FullSizeInfo->BytesPerSector = Vcb->StatFs.SectorSize;
            BytesWritten = sizeof(FILE_FS_FULL_SIZE_INFORMATION);
            break;
        }
        default:
            status = STATUS_INVALID_INFO_CLASS;
            break;
    }

    Irp->IoStatus.Information = BytesWritten;
    return status;
}

NTSTATUS UfsDispatchDirectoryControl(PDEVICE_OBJECT DeviceObject, PIRP Irp) {
    PUFS_IRP_CONTEXT IrpContext = Irp->Tail.Overlay.DriverContext[0];
    PUFS_FCB Fcb = IrpContext->Fcb;
    PUFS_CCB Ccb = IrpContext->Ccb;
    PIO_STACK_LOCATION IrpSp = IrpContext->IrpSp;

    if (!Fcb || Fcb->InodeInfo.FileType != UFS_FILE_TYPE_DIR) {
        return STATUS_INVALID_PARAMETER;
    }

    ULONG MinorFunction = IrpSp->MinorFunction;

    switch (MinorFunction) {
        case IRP_MN_QUERY_DIRECTORY: {
            FILE_INFORMATION_CLASS FileInformationClass = IrpSp->Parameters.QueryDirectory.FileInformationClass;
            PVOID Buffer = Irp->UserBuffer;
            ULONG Length = IrpSp->Parameters.QueryDirectory.Length;
            PUNICODE_STRING FileName = IrpSp->Parameters.QueryDirectory.FileName;
            ULONG Flags = IrpSp->Parameters.QueryDirectory.Flags;

            // Initialize directory iterator if needed
            if (!Ccb->DirIterHandle) {
                NTSTATUS status = UfsOpenDir(Fcb->Vcb->FsHandle, Fcb->InodeNumber, &Ccb->DirIterHandle);
                if (!NT_SUCCESS(status)) return status;
            }

            UFS_DIRENT Entry;
            NTSTATUS status;
            ULONG TotalBytes = 0;

            while (TotalBytes < Length) {
                status = UfsReadDir(Fcb->Vcb->FsHandle, Ccb->DirIterHandle, &Entry);
                if (status == UFS_ERROR_NOT_FOUND) {
                    status = STATUS_NO_MORE_FILES;
                    break;
                }
                if (!NT_SUCCESS(status)) break;

                // Skip . and .. if not requested
                if (Entry.Name[0] == '.' && (Entry.Name[1] == '\0' || (Entry.Name[1] == '.' && Entry.Name[2] == '\0'))) {
                    if (!(Flags & SL_RESTART_SCAN)) continue;
                }

                // Filter by filename if provided
                if (FileName && FileName->Length > 0) {
                    UNICODE_STRING EntryName;
                    RtlInitUnicodeString(&EntryName, Entry.Name);
                    if (!RtlEqualUnicodeString(&EntryName, FileName, TRUE)) continue;
                }

                // Fill buffer based on information class
                ULONG EntrySize = 0;
                switch (FileInformationClass) {
                    case FileDirectoryInformation: {
                        PFILE_DIRECTORY_INFORMATION DirInfo = (PUCHAR)Buffer + TotalBytes;
                        if (TotalBytes + sizeof(FILE_DIRECTORY_INFORMATION) + Entry.NameLength > Length) {
                            status = STATUS_BUFFER_OVERFLOW;
                            goto Done;
                        }
                        DirInfo->CreationTime.QuadPart = Entry.CreationTime * 10000000 + 116444736000000000LL;
                        DirInfo->LastAccessTime.QuadPart = Entry.LastAccessTime * 10000000 + 116444736000000000LL;
                        DirInfo->LastWriteTime.QuadPart = Entry.LastWriteTime * 10000000 + 116444736000000000LL;
                        DirInfo->ChangeTime.QuadPart = Entry.ChangeTime * 10000000 + 116444736000000000LL;
                        DirInfo->EndOfFile.QuadPart = Entry.FileSize;
                        DirInfo->AllocationSize.QuadPart = Entry.AllocatedSize;
                        DirInfo->FileAttributes = UfsFileTypeToAttributes(Entry.FileType);
                        DirInfo->FileNameLength = Entry.NameLength * sizeof(WCHAR);
                        RtlCopyMemory(DirInfo->FileName, Entry.Name, Entry.NameLength * sizeof(WCHAR));
                        EntrySize = FIELD_OFFSET(FILE_DIRECTORY_INFORMATION, FileName) + DirInfo->FileNameLength;
                        // Align to 8 bytes
                        EntrySize = (EntrySize + 7) & ~7;
                        break;
                    }
                    // ... other info classes
                }

                if (EntrySize > 0) {
                    PFILE_DIRECTORY_INFORMATION DirInfo = (PUCHAR)Buffer + TotalBytes;
                    DirInfo->NextEntryOffset = (TotalBytes + EntrySize < Length) ? EntrySize : 0;
                    TotalBytes += EntrySize;
                }

                if (FileName && FileName->Length > 0) break;
            }

Done:
            Irp->IoStatus.Information = TotalBytes;
            return status;
        }
        case IRP_MN_NOTIFY_CHANGE_DIRECTORY: {
            // Directory change notification - implement with FS filter
            return STATUS_NOT_SUPPORTED;
        }
        default:
            return STATUS_INVALID_DEVICE_REQUEST;
    }
}

// ============================================================================
// Fast I/O Dispatch
// ============================================================================

FAST_IO_DISPATCH g_UfsFastIoDispatch = {
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
    .AcquireFileForNtCreateSection = NULL,
    .ReleaseFileForNtCreateSection = NULL,
    .FastIoDetachDevice = UfsFastIoDetachDevice,
    .FastIoQueryNetworkOpenInfo = UfsFastIoQueryNetworkOpenInfo,
    .AcquireForModWrite = NULL,
    .MdlRead = UfsFastIoMdlRead,
    .MdlReadComplete = UfsFastIoMdlReadComplete,
    .PrepareMdlWrite = UfsFastIoPrepareMdlWrite,
    .MdlWriteComplete = UfsFastIoMdlWriteComplete,
    .FastIoReadCompressed = UfsFastIoReadCompressed,
    .FastIoWriteCompressed = UfsFastIoWriteCompressed,
    .MdlReadCompleteCompressed = UfsFastIoMdlReadCompleteCompressed,
    .MdlWriteCompleteCompressed = UfsFastIoMdlWriteCompleteCompressed,
    .FastIoQueryOpen = UfsFastIoQueryOpen,
};

BOOLEAN UfsFastIoCheckIfPossible(PFILE_OBJECT FileObject, PLARGE_INTEGER FileOffset, ULONG Length, BOOLEAN Wait, ULONG LockKey, BOOLEAN CheckForReadOperation, PIO_STATUS_BLOCK IoStatus, PDEVICE_OBJECT DeviceObject) {
    // Fast I/O is possible for cached I/O on regular files
    PUFS_FCB Fcb = FileObject->FsContext;
    if (!Fcb || Fcb->InodeInfo.FileType != UFS_FILE_TYPE_REG) {
        return FALSE;
    }
    if (FlagOn(FileObject->Flags, FO_NO_INTERMEDIATE_BUFFERING)) {
        return FALSE;
    }
    return TRUE;
}

BOOLEAN UfsFastIoRead(PFILE_OBJECT FileObject, PLARGE_INTEGER FileOffset, ULONG Length, BOOLEAN Wait, ULONG LockKey, PVOID Buffer, PMDL* MdlChain, PIO_STATUS_BLOCK IoStatus, PDEVICE_OBJECT DeviceObject) {
    PUFS_FCB Fcb = FileObject->FsContext;
    ULONG BytesRead;
    NTSTATUS status = UfsReadFile(Fcb, FileOffset->QuadPart, Buffer, Length, &BytesRead);
    IoStatus->Status = status;
    IoStatus->Information = BytesRead;
    return NT_SUCCESS(status);
}

BOOLEAN UfsFastIoWrite(PFILE_OBJECT FileObject, PLARGE_INTEGER FileOffset, ULONG Length, BOOLEAN Wait, ULONG LockKey, PVOID Buffer, PMDL* MdlChain, PIO_STATUS_BLOCK IoStatus, PDEVICE_OBJECT DeviceObject) {
    PUFS_FCB Fcb = FileObject->FsContext;
    PUFS_VCB Vcb = Fcb->Vcb;
    if (Vcb->ReadOnly) {
        IoStatus->Status = STATUS_MEDIA_WRITE_PROTECTED;
        return FALSE;
    }
    ULONG BytesWritten;
    NTSTATUS status = UfsWriteFile(Fcb, FileOffset->QuadPart, Buffer, Length, &BytesWritten);
    IoStatus->Status = status;
    IoStatus->Information = BytesWritten;
    return NT_SUCCESS(status);
}

BOOLEAN UfsFastIoQueryBasicInfo(PFILE_OBJECT FileObject, PFILE_BASIC_INFORMATION Buffer, PIO_STATUS_BLOCK IoStatus, PDEVICE_OBJECT DeviceObject) {
    PUFS_FCB Fcb = FileObject->FsContext;
    *Buffer = Fcb->BasicInfo;
    IoStatus->Status = STATUS_SUCCESS;
    IoStatus->Information = sizeof(FILE_BASIC_INFORMATION);
    return TRUE;
}

BOOLEAN UfsFastIoQueryStandardInfo(PFILE_OBJECT FileObject, PFILE_STANDARD_INFORMATION Buffer, PIO_STATUS_BLOCK IoStatus, PDEVICE_OBJECT DeviceObject) {
    PUFS_FCB Fcb = FileObject->FsContext;
    *Buffer = Fcb->StandardInfo;
    IoStatus->Status = STATUS_SUCCESS;
    IoStatus->Information = sizeof(FILE_STANDARD_INFORMATION);
    return TRUE;
}

BOOLEAN UfsFastIoQueryNetworkOpenInfo(PFILE_OBJECT FileObject, PFILE_NETWORK_OPEN_INFORMATION Buffer, PIO_STATUS_BLOCK IoStatus, PDEVICE_OBJECT DeviceObject) {
    PUFS_FCB Fcb = FileObject->FsContext;
    *Buffer = Fcb->NetworkInfo;
    IoStatus->Status = STATUS_SUCCESS;
    IoStatus->Information = sizeof(FILE_NETWORK_OPEN_INFORMATION);
    return TRUE;
}

// ============================================================================
// Metadata Capsule Integration for Windows
// ============================================================================

// Windows-specific capsule namespaces
#define UFS_NS_NTFS_SECURITY_DESCRIPTOR    0x8001  // SDDL/ACLs
#define UFS_NS_NTFS_ALTERNATE_DATA_STREAMS 0x8002  // ADS
#define UFS_NS_NTFS_REPARSE_POINTS         0x8003  // Reparse points (symlinks, junctions, mount points)
#define UFS_NS_NTFS_FILE_ID                0x8004  // File ID (128-bit)
#define UFS_NS_NTFS_USN_JOURNAL            0x8005  // USN Journal
#define UFS_NS_NTFS_COMPRESSION            0x8006  // Compression state
#define UFS_NS_NTFS_EFS                    0x8007  // EFS encryption
#define UFS_NS_NTFS_OBJECT_ID              0x8008  // Object IDs
#define UFS_NS_NTFS_QUOTA                  0x8009  // Quota

NTSTATUS UfsSetNtfsSecurityDescriptor(PUFS_FCB Fcb, PSECURITY_DESCRIPTOR SecurityDescriptor, ULONG Length) {
    return UfsSetXattr(Fcb->Vcb->FsHandle, Fcb->InodeNumber, UFS_NS_NTFS_SECURITY_DESCRIPTOR, 0,
                       "sd", SecurityDescriptor, Length, 0);
}

NTSTATUS UfsGetNtfsSecurityDescriptor(PUFS_FCB Fcb, PSECURITY_DESCRIPTOR* SecurityDescriptor, PULONG Length) {
    // Query size first
    ULONG Size = 0;
    NTSTATUS status = UfsGetXattr(Fcb->Vcb->FsHandle, Fcb->InodeNumber, UFS_NS_NTFS_SECURITY_DESCRIPTOR, 0,
                                   "sd", NULL, 0, &Size);
    if (status == STATUS_BUFFER_TOO_SMALL) {
        *SecurityDescriptor = ExAllocatePoolWithTag(PagedPool, Size, 'SDNU');
        if (!*SecurityDescriptor) return STATUS_INSUFFICIENT_RESOURCES;
        return UfsGetXattr(Fcb->Vcb->FsHandle, Fcb->InodeNumber, UFS_NS_NTFS_SECURITY_DESCRIPTOR, 0,
                           "sd", *SecurityDescriptor, Size, Length);
    }
    return status;
}

NTSTATUS UfsSetAlternateDataStream(PUFS_FCB Fcb, PUNICODE_STRING StreamName, PVOID Data, ULONG Length) {
    CHAR AnsiName[256];
    RtlUnicodeStringToAnsiString(&AnsiString, StreamName, TRUE);
    return UfsSetXattr(Fcb->Vcb->FsHandle, Fcb->InodeNumber, UFS_NS_NTFS_ALTERNATE_DATA_STREAMS, 0,
                       AnsiName.Buffer, Data, Length, 0);
}

NTSTATUS UfsGetAlternateDataStream(PUFS_FCB Fcb, PUNICODE_STRING StreamName, PVOID* Data, PULONG Length) {
    CHAR AnsiName[256];
    RtlUnicodeStringToAnsiString(&AnsiString, StreamName, TRUE);
    ULONG Size = 0;
    NTSTATUS status = UfsGetXattr(Fcb->Vcb->FsHandle, Fcb->InodeNumber, UFS_NS_NTFS_ALTERNATE_DATA_STREAMS, 0,
                                   AnsiName.Buffer, NULL, 0, &Size);
    if (status == STATUS_BUFFER_TOO_SMALL) {
        *Data = ExAllocatePoolWithTag(PagedPool, Size, 'SDAU');
        if (!*Data) return STATUS_INSUFFICIENT_RESOURCES;
        return UfsGetXattr(Fcb->Vcb->FsHandle, Fcb->InodeNumber, UFS_NS_NTFS_ALTERNATE_DATA_STREAMS, 0,
                           AnsiName.Buffer, *Data, Size, Length);
    }
    return status;
}

NTSTATUS UfsSetReparsePoint(PUFS_FCB Fcb, PREPARSE_DATA_BUFFER ReparseBuffer, ULONG Length) {
    return UfsSetXattr(Fcb->Vcb->FsHandle, Fcb->InodeNumber, UFS_NS_NTFS_REPARSE_POINTS, 0,
                       "reparse", ReparseBuffer, Length, 0);
}

NTSTATUS UfsGetReparsePoint(PUFS_FCB Fcb, PREPARSE_DATA_BUFFER* ReparseBuffer, PULONG Length) {
    ULONG Size = 0;
    NTSTATUS status = UfsGetXattr(Fcb->Vcb->FsHandle, Fcb->InodeNumber, UFS_NS_NTFS_REPARSE_POINTS, 0,
                                   "reparse", NULL, 0, &Size);
    if (status == STATUS_BUFFER_TOO_SMALL) {
        *ReparseBuffer = ExAllocatePoolWithTag(PagedPool, Size, 'RPNU');
        if (!*ReparseBuffer) return STATUS_INSUFFICIENT_RESOURCES;
        return UfsGetXattr(Fcb->Vcb->FsHandle, Fcb->InodeNumber, UFS_NS_NTFS_REPARSE_POINTS, 0,
                           "reparse", *ReparseBuffer, Size, Length);
    }
    return status;
}

// ============================================================================
// Helper Functions
// ============================================================================

ULONG UfsFileTypeToAttributes(UFS_FILE_TYPE FileType) {
    switch (FileType) {
        case UFS_FILE_TYPE_REG: return FILE_ATTRIBUTE_NORMAL;
        case UFS_FILE_TYPE_DIR: return FILE_ATTRIBUTE_DIRECTORY;
        case UFS_FILE_TYPE_SYMLINK: return FILE_ATTRIBUTE_REPARSE_POINT;
        case UFS_FILE_TYPE_BLOCK_DEV: return FILE_ATTRIBUTE_DEVICE;
        case UFS_FILE_TYPE_CHAR_DEV: return FILE_ATTRIBUTE_DEVICE;
        case UFS_FILE_TYPE_FIFO: return FILE_ATTRIBUTE_NORMAL;
        case UFS_FILE_TYPE_SOCKET: return FILE_ATTRIBUTE_NORMAL;
        default: return FILE_ATTRIBUTE_NORMAL;
    }
}

BOOLEAN UfsCheckAccess(PUFS_FCB Fcb, ACCESS_MASK DesiredAccess) {
    // Check POSIX permissions + Windows ACLs
    UFS_INODE_INFO* info = &Fcb->InodeInfo;

    // Get current process token for SID
    // For simplicity, we'll check POSIX-style permissions
    // Real implementation would check Windows ACLs against token

    BOOLEAN is_owner = FALSE; // Would check against current process token
    BOOLEAN is_group = FALSE; // Would check against current process token groups

    // POSIX permission bits from mode
    USHORT mode = info->mode & 0x1FF; // Lower 9 bits are permissions

    // Check read access
    if (DesiredAccess & (FILE_READ_DATA | FILE_READ_ATTRIBUTES | FILE_READ_EA | SYNCHRONIZE)) {
        if (is_owner) {
            if (!(mode & S_IRUSR)) return FALSE;
        } else if (is_group) {
            if (!(mode & S_IRGRP)) return FALSE;
        } else {
            if (!(mode & S_IROTH)) return FALSE;
        }
    }

    // Check write access
    if (DesiredAccess & (FILE_WRITE_DATA | FILE_WRITE_ATTRIBUTES | FILE_WRITE_EA | FILE_APPEND_DATA)) {
        if (Fcb->Vcb->ReadOnly) return FALSE;

        if (is_owner) {
            if (!(mode & S_IWUSR)) return FALSE;
        } else if (is_group) {
            if (!(mode & S_IWGRP)) return FALSE;
        } else {
            if (!(mode & S_IWOTH)) return FALSE;
        }
    }

    // Check execute access
    if (DesiredAccess & (FILE_EXECUTE | FILE_TRAVERSE)) {
        if (is_owner) {
            if (!(mode & S_IXUSR)) return FALSE;
        } else if (is_group) {
            if (!(mode & S_IXGRP)) return FALSE;
        } else {
            if (!(mode & S_IXOTH)) return FALSE;
        }
    }

    // Check delete access (requires write permission on parent directory)
    if (DesiredAccess & DELETE) {
        // For files: check write permission on parent directory
        // For directories: check write + execute on parent directory
        // Simplified: just check write on this inode
        if (is_owner) {
            if (!(mode & S_IWUSR)) return FALSE;
        } else if (is_group) {
            if (!(mode & S_IWGRP)) return FALSE;
        } else {
            if (!(mode & S_IWOTH)) return FALSE;
        }
    }

    // Check standard rights
    if (DesiredAccess & (READ_CONTROL | WRITE_DAC | WRITE_OWNER)) {
        // Only owner can change ACLs/owner
        if (!is_owner) return FALSE;
    }

    return TRUE;
}

NTSTATUS UfsLookupPath(PUFS_VCB Vcb, PUFS_FCB StartFcb, PUNICODE_STRING Path, PULONGLONG InodeNumber, PUFS_FCB* ParentFcb) {
    NTSTATUS status;
    ULONGLONG current_inode = StartFcb ? StartFcb->InodeNumber : Vcb->RootInodeNumber;
    PUFS_FCB current_fcb = StartFcb;
    PUFS_FCB parent_fcb = NULL;

    // If path is empty or just backslash, return current directory
    if (Path->Length == 0 || (Path->Length == sizeof(WCHAR) && Path->Buffer[0] == L'\\')) {
        if (InodeNumber) *InodeNumber = current_inode;
        if (ParentFcb) *ParentFcb = current_fcb;
        if (current_fcb) UfsReferenceFcb(current_fcb);
        return STATUS_SUCCESS;
    }

    // Convert Unicode path to UTF-8 for UFS core
    ULONG utf8_len = WideCharToMultiByte(CP_UTF8, 0, Path->Buffer, Path->Length / sizeof(WCHAR), NULL, 0, NULL, NULL);
    if (utf8_len == 0) {
        return STATUS_INVALID_PARAMETER;
    }

    PCHAR utf8_path = ExAllocatePoolWithTag(PagedPool, utf8_len + 1, 'sfcU');
    if (!utf8_path) {
        return STATUS_INSUFFICIENT_RESOURCES;
    }

    WideCharToMultiByte(CP_UTF8, 0, Path->Buffer, Path->Length / sizeof(WCHAR), utf8_path, utf8_len, NULL, NULL);
    utf8_path[utf8_len] = '\0';

    // Parse path components
    PCHAR component_start = utf8_path;
    if (*component_start == '/') component_start++;

    while (*component_start) {
        // Find next component
        PCHAR component_end = component_start;
        while (*component_end && *component_end != '/') component_end++;

        ULONG component_len = (ULONG)(component_end - component_start);
        if (component_len == 0) {
            component_start = component_end + 1;
            continue;
        }

        // Look up component in current directory
        ULONGLONG next_inode;
        int result = ufs_lookup(Vcb->FsHandle, current_inode, component_start, &next_inode);
        if (result != 0) {
            ExFreePoolWithTag(utf8_path, 'sfcU');
            if (current_fcb) UfsDereferenceFcb(current_fcb);
            return STATUS_OBJECT_NAME_NOT_FOUND;
        }

        // Release previous FCB if any
        if (current_fcb) {
            UfsDereferenceFcb(current_fcb);
        }

        // Get FCB for the next inode
        current_fcb = UfsGetFcb(Vcb, next_inode);
        if (!current_fcb) {
            ExFreePoolWithTag(utf8_path, 'sfcU');
            return STATUS_INSUFFICIENT_RESOURCES;
        }

        current_inode = next_inode;
        parent_fcb = current_fcb;

        // Move to next component
        component_start = component_end;
        if (*component_start == '/') component_start++;
    }

    ExFreePoolWithTag(utf8_path, 'sfcU');

    if (InodeNumber) *InodeNumber = current_inode;
    if (ParentFcb) *ParentFcb = parent_fcb;

    return STATUS_SUCCESS;
}

NTSTATUS UfsOpenDir(UFS_FS_HANDLE* FsHandle, ULONGLONG InodeNumber, UFS_DIR_ITERATOR_HANDLE** DirIterHandle) {
    return UfsOpenDir(FsHandle, InodeNumber, DirIterHandle);
}

NTSTATUS UfsReadDir(UFS_FS_HANDLE* FsHandle, UFS_DIR_ITERATOR_HANDLE* DirIterHandle, UFS_DIRENT* Entry) {
    return UfsReadDir(FsHandle, DirIterHandle, Entry);
}

NTSTATUS UfsCloseDir(UFS_DIR_ITERATOR_HANDLE* DirIterHandle) {
    return UfsCloseDir(DirIterHandle);
}

NTSTATUS UfsReadFile(PUFS_FCB Fcb, ULONGLONG Offset, PVOID Buffer, ULONG Length, PULONG BytesRead) {
    return UfsRead(Fcb->Vcb->FsHandle, Fcb->InodeNumber, Offset, Buffer, Length, BytesRead);
}

NTSTATUS UfsWriteFile(PUFS_FCB Fcb, ULONGLONG Offset, PVOID Buffer, ULONG Length, PULONG BytesWritten) {
    return UfsWrite(Fcb->Vcb->FsHandle, Fcb->InodeNumber, Offset, Buffer, Length, BytesWritten);
}

NTSTATUS UfsSetAttr(UFS_FS_HANDLE* FsHandle, ULONGLONG InodeNumber, ...) {
    // Set attributes via UFS core
    return STATUS_SUCCESS;
}

NTSTATUS UfsSync(UFS_FS_HANDLE* FsHandle) {
    return UfsSync(FsHandle);
}

NTSTATUS UfsDeleteFile(PUFS_FCB Fcb) {
    return UfsDeleteInode(Fcb->Vcb->FsHandle, Fcb->ParentFcb->InodeNumber, Fcb->FileName);
}

NTSTATUS UfsDispatchSetVolumeInformation(PDEVICE_OBJECT DeviceObject, PIRP Irp) {
    return STATUS_NOT_IMPLEMENTED;
}

NTSTATUS UfsDispatchFileSystemControl(PDEVICE_OBJECT DeviceObject, PIRP Irp) {
    return STATUS_NOT_IMPLEMENTED;
}

NTSTATUS UfsDispatchDeviceControl(PDEVICE_OBJECT DeviceObject, PIRP Irp) {
    return STATUS_NOT_IMPLEMENTED;
}

NTSTATUS UfsDispatchCleanup(PDEVICE_OBJECT DeviceObject, PIRP Irp) {
    return STATUS_SUCCESS;
}

NTSTATUS UfsDispatchPnp(PDEVICE_OBJECT DeviceObject, PIRP Irp) {
    return STATUS_NOT_IMPLEMENTED;
}

NTSTATUS UfsDispatchPower(PDEVICE_OBJECT DeviceObject, PIRP Irp) {
    return STATUS_NOT_IMPLEMENTED;
}

NTSTATUS UfsDispatchShutdown(PDEVICE_OBJECT DeviceObject, PIRP Irp) {
    PUFS_IRP_CONTEXT IrpContext = Irp->Tail.Overlay.DriverContext[0];
    PUFS_VCB Vcb = IrpContext->Vcb;
    return UfsUnmountVolume(Vcb);
}

NTSTATUS UfsDispatchFlushBuffers(PDEVICE_OBJECT DeviceObject, PIRP Irp) {
    PUFS_IRP_CONTEXT IrpContext = Irp->Tail.Overlay.DriverContext[0];
    PUFS_VCB Vcb = IrpContext->Vcb;
    return UfsSync(Vcb->FsHandle);
}

NTSTATUS UfsFastIoLock(PFILE_OBJECT FileObject, PLARGE_INTEGER FileOffset, PLARGE_INTEGER Length, PEPROCESS ProcessId, ULONG Key, BOOLEAN FailImmediately, BOOLEAN ExclusiveLock, PIO_STATUS_BLOCK IoStatus, PDEVICE_OBJECT DeviceObject) {
    return FALSE;
}

BOOLEAN UfsFastIoUnlockSingle(PFILE_OBJECT FileObject, PLARGE_INTEGER FileOffset, PLARGE_INTEGER Length, PEPROCESS ProcessId, ULONG Key, PIO_STATUS_BLOCK IoStatus, PDEVICE_OBJECT DeviceObject) {
    return FALSE;
}

BOOLEAN UfsFastIoUnlockAll(PFILE_OBJECT FileObject, PEPROCESS ProcessId, PIO_STATUS_BLOCK IoStatus, PDEVICE_OBJECT DeviceObject) {
    return FALSE;
}

BOOLEAN UfsFastIoUnlockAllByKey(PFILE_OBJECT FileObject, PVOID ProcessId, ULONG Key, PIO_STATUS_BLOCK IoStatus, PDEVICE_OBJECT DeviceObject) {
    return FALSE;
}

BOOLEAN UfsFastIoDeviceControl(PFILE_OBJECT FileObject, BOOLEAN Wait, PVOID InputBuffer, ULONG InputBufferLength, PVOID OutputBuffer, ULONG OutputBufferLength, ULONG IoControlCode, PIO_STATUS_BLOCK IoStatus, PDEVICE_OBJECT DeviceObject) {
    return FALSE;
}

VOID UfsFastIoDetachDevice(PDEVICE_OBJECT SourceDevice, PDEVICE_OBJECT TargetDevice) {
}

NTSTATUS UfsFastIoMdlRead(PFILE_OBJECT FileObject, PLARGE_INTEGER FileOffset, ULONG Length, ULONG LockKey, PMDL* MdlChain, PIO_STATUS_BLOCK IoStatus, PDEVICE_OBJECT DeviceObject) {
    return STATUS_NOT_SUPPORTED;
}

NTSTATUS UfsFastIoMdlReadComplete(PFILE_OBJECT FileObject, PMDL MdlChain, PDEVICE_OBJECT DeviceObject) {
    return STATUS_NOT_SUPPORTED;
}

NTSTATUS UfsFastIoPrepareMdlWrite(PFILE_OBJECT FileObject, PLARGE_INTEGER FileOffset, ULONG Length, ULONG LockKey, PMDL* MdlChain, PIO_STATUS_BLOCK IoStatus, PDEVICE_OBJECT DeviceObject) {
    return STATUS_NOT_SUPPORTED;
}

NTSTATUS UfsFastIoMdlWriteComplete(PFILE_OBJECT FileObject, PLARGE_INTEGER FileOffset, PMDL MdlChain, PDEVICE_OBJECT DeviceObject) {
    return STATUS_NOT_SUPPORTED;
}

NTSTATUS UfsFastIoReadCompressed(PFILE_OBJECT FileObject, PLARGE_INTEGER FileOffset, ULONG Length, ULONG LockKey, PVOID Buffer, PMDL* MdlChain, PIO_STATUS_BLOCK IoStatus, PDEVICE_OBJECT DeviceObject) {
    return STATUS_NOT_SUPPORTED;
}

NTSTATUS UfsFastIoWriteCompressed(PFILE_OBJECT FileObject, PLARGE_INTEGER FileOffset, ULONG Length, ULONG LockKey, PVOID Buffer, PMDL* MdlChain, PIO_STATUS_BLOCK IoStatus, PDEVICE_OBJECT DeviceObject) {
    return STATUS_NOT_SUPPORTED;
}

NTSTATUS UfsFastIoMdlReadCompleteCompressed(PFILE_OBJECT FileObject, PMDL MdlChain, PDEVICE_OBJECT DeviceObject) {
    return STATUS_NOT_SUPPORTED;
}

NTSTATUS UfsFastIoMdlWriteCompleteCompressed(PFILE_OBJECT FileObject, PLARGE_INTEGER FileOffset, PMDL MdlChain, PDEVICE_OBJECT DeviceObject) {
    return STATUS_NOT_SUPPORTED;
}

NTSTATUS UfsFastIoQueryOpen(PFILE_OBJECT FileObject, PFILE_NETWORK_OPEN_INFORMATION Buffer, PIO_STATUS_BLOCK IoStatus, PDEVICE_OBJECT DeviceObject) {
    return UfsFastIoQueryNetworkOpenInfo(FileObject, Buffer, IoStatus, DeviceObject);
}