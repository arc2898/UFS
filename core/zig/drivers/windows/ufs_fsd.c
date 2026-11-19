// ufs_fsd.c - File System Driver (FSD) Implementation
// Windows IFS driver - handles IRP_MJ_CREATE, READ, WRITE, etc.

#include <ntifs.h>
#include <fltkernel.h>
#include <ntstrsafe.h>

#include "ufs.h"

// Forward declarations from ufs_ifs.c
extern PUFS_GLOBAL_DATA g_UfsGlobalData;
extern UFS_FCB* UfsFindFcb(PUFS_VCB Vcb, ULONGLONG InodeNumber);
extern NTSTATUS UfsCreateFcb(PUFS_VCB Vcb, ULONGLONG InodeNumber, PUFS_FCB ParentFcb, PUNICODE_STRING FileName, PUFS_FCB* Fcb);
extern NTSTATUS UfsCreateCcb(PUFS_FCB Fcb, PUFS_CCB* Ccb);
extern NTSTATUS UfsReadFile(PUFS_FCB Fcb, ULONGLONG Offset, PVOID Buffer, ULONG Length, PULONG BytesRead);
extern NTSTATUS UfsWriteFile(PUFS_FCB Fcb, ULONGLONG Offset, PVOID Buffer, ULONG Length, PULONG BytesWritten);
extern NTSTATUS UfsSetAttr(UFS_FS_HANDLE* FsHandle, ULONGLONG InodeNumber, ...);
extern NTSTATUS UfsSync(UFS_FS_HANDLE* FsHandle);
extern NTSTATUS UfsDeleteFile(PUFS_FCB Fcb);
extern NTSTATUS UfsLookupPath(PUFS_VCB Vcb, PUFS_FCB StartFcb, PUNICODE_STRING Path, PULONGLONG InodeNumber, PUFS_FCB* ParentFcb);
extern NTSTATUS UfsOpenDir(UFS_FS_HANDLE* FsHandle, ULONGLONG InodeNumber, UFS_DIR_ITERATOR_HANDLE** DirIterHandle);
extern NTSTATUS UfsReadDir(UFS_FS_HANDLE* FsHandle, UFS_DIR_ITERATOR_HANDLE* DirIterHandle, UFS_DIRENT* Entry);
extern NTSTATUS UfsCloseDir(UFS_DIR_ITERATOR_HANDLE* DirIterHandle);
extern NTSTATUS UfsGetAttr(UFS_FS_HANDLE* FsHandle, ULONGLONG InodeNumber, UFS_INODE_INFO* Info);

// ============================================================================
// IRP_MJ_CREATE - Handle file/directory creation and open
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

// ============================================================================
// IRP_MJ_READ - Read file data
// ============================================================================
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

// ============================================================================
// IRP_MJ_WRITE - Write file data
// ============================================================================
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

// ============================================================================
// IRP_MJ_QUERY_INFORMATION - Query file information
// ============================================================================
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

// ============================================================================
// IRP_MJ_SET_INFORMATION - Set file information
// ============================================================================
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

// ============================================================================
// IRP_MJ_DIRECTORY_CONTROL - Directory operations
// ============================================================================
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
// IRP_MJ_FLUSH_BUFFERS - Flush file buffers
// ============================================================================
NTSTATUS UfsDispatchFlushBuffers(PDEVICE_OBJECT DeviceObject, PIRP Irp) {
    PUFS_IRP_CONTEXT IrpContext = Irp->Tail.Overlay.DriverContext[0];
    PUFS_VCB Vcb = IrpContext->Vcb;
    return UfsSync(Vcb->FsHandle);
}

// ============================================================================
// IRP_MJ_SHUTDOWN - Handle system shutdown
// ============================================================================
NTSTATUS UfsDispatchShutdown(PDEVICE_OBJECT DeviceObject, PIRP Irp) {
    PUFS_IRP_CONTEXT IrpContext = Irp->Tail.Overlay.DriverContext[0];
    PUFS_VCB Vcb = IrpContext->Vcb;
    return UfsSync(Vcb->FsHandle);
}

// ============================================================================
// IRP_MJ_CLEANUP - Handle cleanup
// ============================================================================
NTSTATUS UfsDispatchCleanup(PDEVICE_OBJECT DeviceObject, PIRP Irp) {
    PUFS_IRP_CONTEXT IrpContext = Irp->Tail.Overlay.DriverContext[0];
    PFILE_OBJECT FileObject = IrpContext->IrpSp->FileObject;
    PUFS_FCB Fcb = FileObject->FsContext;
    PUFS_CCB Ccb = FileObject->FsContext2;

    if (Ccb) {
        // Close directory iterator if open
        if (Ccb->DirIterHandle) {
            UfsCloseDir(Ccb->DirIterHandle);
            Ccb->DirIterHandle = NULL;
        }
    }

    return STATUS_SUCCESS;
}

// ============================================================================
// IRP_MJ_PNP - Plug and Play
// ============================================================================
NTSTATUS UfsDispatchPnp(PDEVICE_OBJECT DeviceObject, PIRP Irp) {
    PUFS_IRP_CONTEXT IrpContext = Irp->Tail.Overlay.DriverContext[0];
    PIO_STACK_LOCATION IrpSp = IrpContext->IrpSp;

    switch (IrpSp->MinorFunction) {
        case IRP_MN_DEVICE_USAGE_NOTIFICATION:
            // Handle paging file, crash dump, hibernation
            break;
        case IRP_MN_QUERY_REMOVE_DEVICE:
        case IRP_MN_CANCEL_REMOVE_DEVICE:
        case IRP_MN_SURPRISE_REMOVAL:
        case IRP_MN_REMOVE_DEVICE:
            // Handle volume removal
            break;
        default:
            break;
    }

    IoSkipCurrentIrpStackLocation(Irp);
    return IoCallDriver(IrpContext->Vcb->TargetDeviceObject, Irp);
}

// ============================================================================
// IRP_MJ_POWER - Power management
// ============================================================================
NTSTATUS UfsDispatchPower(PDEVICE_OBJECT DeviceObject, PIRP Irp) {
    PoStartNextPowerIrp(Irp);
    IoSkipCurrentIrpStackLocation(Irp);
    return PoCallDriver(IrpContext->Vcb->TargetDeviceObject, Irp);
}

// ============================================================================
// IRP_MJ_FILE_SYSTEM_CONTROL - File system control
// ============================================================================
NTSTATUS UfsDispatchFileSystemControl(PDEVICE_OBJECT DeviceObject, PIRP Irp) {
    PUFS_IRP_CONTEXT IrpContext = Irp->Tail.Overlay.DriverContext[0];
    PIO_STACK_LOCATION IrpSp = IrpContext->IrpSp;

    switch (IrpSp->Parameters.FileSystemControl.FsControlCode) {
        case FSCTL_LOCK_VOLUME:
        case FSCTL_UNLOCK_VOLUME:
        case FSCTL_DISMOUNT_VOLUME:
        case FSCTL_MARK_VOLUME_DIRTY:
        case FSCTL_QUERY_FAT_BPB:
        case FSCTL_REQUEST_OPLOCK_LEVEL_1:
        case FSCTL_REQUEST_OPLOCK_LEVEL_2:
        case FSCTL_REQUEST_BATCH_OPLOCK:
        case FSCTL_OPLOCK_BREAK_ACKNOWLEDGE:
        case FSCTL_OPLOCK_BREAK_NOTIFY:
        case FSCTL_OPLOCK_BREAK_ACK_NO_2:
        case FSCTL_CSV_TUNNEL_REQUEST:
        case FSCTL_CSV_QUERY_VETO_FILE_DIRECT_IO:
        case FSCTL_CSV_QUERY_VETO_FILE_METADATA_IO:
        case FSCTL_QUERY_DEPENDENT_VOLUME:
            // Not implemented
            return STATUS_INVALID_DEVICE_REQUEST;
        default:
            return STATUS_INVALID_DEVICE_REQUEST;
    }
}

// ============================================================================
// IRP_MJ_DEVICE_CONTROL - Device I/O control
// ============================================================================
NTSTATUS UfsDispatchDeviceControl(PDEVICE_OBJECT DeviceObject, PIRP Irp) {
    PUFS_IRP_CONTEXT IrpContext = Irp->Tail.Overlay.DriverContext[0];
    PIO_STACK_LOCATION IrpSp = IrpContext->IrpSp;

    ULONG IoControlCode = IrpSp->Parameters.DeviceIoControl.IoControlCode;
    PVOID InputBuffer = IrpSp->Parameters.DeviceIoControl.Type3InputBuffer;
    ULONG InputBufferLength = IrpSp->Parameters.DeviceIoControl.InputBufferLength;
    PVOID OutputBuffer = Irp->UserBuffer;
    ULONG OutputBufferLength = IrpSp->Parameters.DeviceIoControl.OutputBufferLength;

    switch (IoControlCode) {
        case FSCTL_GET_REPARSE_POINT:
        case FSCTL_SET_REPARSE_POINT:
        case FSCTL_DELETE_REPARSE_POINT:
        case FSCTL_SET_SPARSE:
        case FSCTL_SET_ZERO_DATA:
        case FSCTL_QUERY_ALLOCATED_RANGES:
        case FSCTL_SET_ENCRYPTION:
        case FSCTL_WRITE_RAW_ENCRYPTED:
        case FSCTL_READ_RAW_ENCRYPTED:
        case FSCTL_ENCRYPTION_FSCTL_IO:
        case FSCTL_SET_OBJECT_ID:
        case FSCTL_GET_OBJECT_ID:
        case FSCTL_DELETE_OBJECT_ID:
        case FSCTL_SET_ZERO_ON_DEALLOCATION:
        case FSCTL_QUERY_SPARSE_RANGES:
        case FSCTL_QUERY_FILE_LAYOUT:
        case FSCTL_CREATE_OR_GET_OBJECT_ID:
        case FSCTL_SET_INTEGRITY_INFORMATION:
        case FSCTL_QUERY_INTEGRITY_INFORMATION:
        case FSCTL_SET_VOLUME_COMPRESSION_STATE:
        case FSCTL_QUERY_VOLUME_COMPRESSION_STATE:
        case FSCTL_OFFLOAD_READ:
        case FSCTL_OFFLOAD_WRITE:
            // Not implemented in v1
            return STATUS_INVALID_DEVICE_REQUEST;
        default:
            return STATUS_INVALID_DEVICE_REQUEST;
    }
}