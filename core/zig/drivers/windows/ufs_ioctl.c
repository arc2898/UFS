// ufs_ioctl.c - Windows IOCTL Implementation
// Handles FSCTL and IOCTL operations for UFS

#include <ntifs.h>
#include <fltkernel.h>

#include "ufs.h"

// ============================================================================
// FSCTL Operations
// ============================================================================

NTSTATUS UfsFsctlGetReparsePoint(
    IN PUFS_FCB Fcb,
    IN PVOID InputBuffer,
    IN ULONG InputBufferLength,
    OUT PVOID OutputBuffer,
    IN ULONG OutputBufferLength,
    OUT PULONG ReturnLength
) {
    // Get reparse point data
    PREPARSE_DATA_BUFFER ReparseBuffer;
    ULONG Length;
    NTSTATUS status = UfsGetReparsePoint(Fcb, &ReparseBuffer, &Length);

    if (NT_SUCCESS(status)) {
        if (OutputBufferLength < Length) {
            ExFreePoolWithTag(ReparseBuffer, 'RPNU');
            return STATUS_BUFFER_TOO_SMALL;
        }
        RtlCopyMemory(OutputBuffer, ReparseBuffer, Length);
        *ReturnLength = Length;
        ExFreePoolWithTag(ReparseBuffer, 'RPNU');
    }

    return status;
}

NTSTATUS UfsFsctlSetReparsePoint(
    IN PUFS_FCB Fcb,
    IN PVOID InputBuffer,
    IN ULONG InputBufferLength,
    OUT PVOID OutputBuffer,
    IN ULONG OutputBufferLength,
    OUT PULONG ReturnLength
) {
    UNREFERENCED_PARAMETER(OutputBuffer);
    UNREFERENCED_PARAMETER(OutputBufferLength);
    UNREFERENCED_PARAMETER(ReturnLength);

    return UfsSetReparsePoint(Fcb, (PREPARSE_DATA_BUFFER)InputBuffer, InputBufferLength);
}

NTSTATUS UfsFsctlDeleteReparsePoint(
    IN PUFS_FCB Fcb,
    IN PVOID InputBuffer,
    IN ULONG InputBufferLength,
    OUT PVOID OutputBuffer,
    IN ULONG OutputBufferLength,
    OUT PULONG ReturnLength
) {
    UNREFERENCED_PARAMETER(InputBuffer);
    UNREFERENCED_PARAMETER(InputBufferLength);
    UNREFERENCED_PARAMETER(OutputBuffer);
    UNREFERENCED_PARAMETER(OutputBufferLength);
    UNREFERENCED_PARAMETER(ReturnLength);

    return UfsDeleteReparsePoint(Fcb);
}

NTSTATUS UfsFsctlSetSparse(
    IN PUFS_FCB Fcb,
    IN PVOID InputBuffer,
    IN ULONG InputBufferLength,
    OUT PVOID OutputBuffer,
    IN ULONG OutputBufferLength,
    OUT PULONG ReturnLength
) {
    UNREFERENCED_PARAMETER(InputBuffer);
    UNREFERENCED_PARAMETER(InputBufferLength);
    UNREFERENCED_PARAMETER(OutputBuffer);
    UNREFERENCED_PARAMETER(OutputBufferLength);
    UNREFERENCED_PARAMETER(ReturnLength);

    if (!Fcb) return STATUS_INVALID_PARAMETER;

    // Mark inode as sparse
    Fcb->InodeInfo.Flags |= UFS_INODE_FLAG_SPARSE;
    return STATUS_SUCCESS;
}

NTSTATUS UfsFsctlSetZeroData(
    IN PUFS_FCB Fcb,
    IN PVOID InputBuffer,
    IN ULONG InputBufferLength,
    OUT PVOID OutputBuffer,
    IN ULONG OutputBufferLength,
    OUT PULONG ReturnLength
) {
    UNREFERENCED_PARAMETER(OutputBuffer);
    UNREFERENCED_PARAMETER(OutputBufferLength);
    UNREFERENCED_PARAMETER(ReturnLength);

    if (!Fcb || InputBufferLength != sizeof(FILE_ZERO_DATA_INFORMATION)) {
        return STATUS_INVALID_PARAMETER;
    }

    PFILE_ZERO_DATA_INFORMATION ZeroInfo = (PFILE_ZERO_DATA_INFORMATION)InputBuffer;

    // Call UFS fallocate with zero range
    return UfsFallocate(
        Fcb->Vcb->FsHandle,
        Fcb->InodeNumber,
        0, // mode
        ZeroInfo->FileOffset.QuadPart,
        ZeroInfo->BeyondFinalZero.QuadPart - ZeroInfo->FileOffset.QuadPart
    );
}

NTSTATUS UfsFsctlQueryAllocatedRanges(
    IN PUFS_FCB Fcb,
    IN PVOID InputBuffer,
    IN ULONG InputBufferLength,
    OUT PVOID OutputBuffer,
    IN ULONG OutputBufferLength,
    OUT PULONG ReturnLength
) {
    if (!Fcb || InputBufferLength != sizeof(FILE_ALLOCATED_RANGE_BUFFER)) {
        return STATUS_INVALID_PARAMETER;
    }

    // Get extent map from UFS
    UFS_EXTENT Extents[64];
    SIZE_T Count = 64;
    NTSTATUS status = UfsGetExtents(Fcb->Vcb->FsHandle, Fcb->InodeNumber, Extents, &Count);

    if (!NT_SUCCESS(status)) return status;

    // Convert to FILE_ALLOCATED_RANGE_BUFFER format
    PFILE_ALLOCATED_RANGE_BUFFER OutBuffer = (PFILE_ALLOCATED_RANGE_BUFFER)OutputBuffer;
    SIZE_T OutCount = OutputBufferLength / sizeof(FILE_ALLOCATED_RANGE_BUFFER);

    SIZE_T i;
    for (i = 0; i < Count && i < OutCount; i++) {
        OutBuffer[i].FileOffset.QuadPart = Extents[i].logical_offset;
        OutBuffer[i].Length.QuadPart = Extents[i].length;
    }

    *ReturnLength = (ULONG)(i * sizeof(FILE_ALLOCATED_RANGE_BUFFER));
    return STATUS_SUCCESS;
}

NTSTATUS UfsFsctlSetEncryption(
    IN PUFS_FCB Fcb,
    IN PVOID InputBuffer,
    IN ULONG InputBufferLength,
    OUT PVOID OutputBuffer,
    IN ULONG OutputBufferLength,
    OUT PULONG ReturnLength
) {
    UNREFERENCED_PARAMETER(Fcb);
    UNREFERENCED_PARAMETER(InputBuffer);
    UNREFERENCED_PARAMETER(InputBufferLength);
    UNREFERENCED_PARAMETER(OutputBuffer);
    UNREFERENCED_PARAMETER(OutputBufferLength);
    UNREFERENCED_PARAMETER(ReturnLength);

    return STATUS_NOT_SUPPORTED;
}

NTSTATUS UfsFsctlSetObjectId(
    IN PUFS_FCB Fcb,
    IN PVOID InputBuffer,
    IN ULONG InputBufferLength,
    OUT PVOID OutputBuffer,
    IN ULONG OutputBufferLength,
    OUT PULONG ReturnLength
) {
    UNREFERENCED_PARAMETER(OutputBuffer);
    UNREFERENCED_PARAMETER(OutputBufferLength);
    UNREFERENCED_PARAMETER(ReturnLength);

    if (!Fcb || InputBufferLength != sizeof(FILE_OBJECT_ID_BUFFER)) {
        return STATUS_INVALID_PARAMETER;
    }

    return UfsSetObjectId(Fcb, (PFILE_OBJECT_ID_BUFFER)InputBuffer);
}

NTSTATUS UfsFsctlGetObjectId(
    IN PUFS_FCB Fcb,
    IN PVOID InputBuffer,
    IN ULONG InputBufferLength,
    OUT PVOID OutputBuffer,
    IN ULONG OutputBufferLength,
    OUT PULONG ReturnLength
) {
    UNREFERENCED_PARAMETER(InputBuffer);
    UNREFERENCED_PARAMETER(InputBufferLength);

    if (!Fcb || OutputBufferLength < sizeof(FILE_OBJECT_ID_BUFFER)) {
        return STATUS_BUFFER_TOO_SMALL;
    }

    NTSTATUS status = UfsGetObjectId(Fcb, (PFILE_OBJECT_ID_BUFFER)OutputBuffer);
    if (NT_SUCCESS(status)) {
        *ReturnLength = sizeof(FILE_OBJECT_ID_BUFFER);
    }
    return status;
}

NTSTATUS UfsFsctlCreateOrGetObjectId(
    IN PUFS_FCB Fcb,
    IN PVOID InputBuffer,
    IN ULONG InputBufferLength,
    OUT PVOID OutputBuffer,
    IN ULONG OutputBufferLength,
    OUT PULONG ReturnLength
) {
    UNREFERENCED_PARAMETER(InputBuffer);
    UNREFERENCED_PARAMETER(InputBufferLength);

    if (!Fcb || OutputBufferLength < sizeof(FILE_OBJECT_ID_BUFFER)) {
        return STATUS_BUFFER_TOO_SMALL;
    }

    // Try to get existing, create if not exists
    NTSTATUS status = UfsGetObjectId(Fcb, (PFILE_OBJECT_ID_BUFFER)OutputBuffer);
    if (status == STATUS_NOT_FOUND || status == STATUS_OBJECT_NAME_NOT_FOUND) {
        // Generate new object ID
        FILE_OBJECT_ID_BUFFER ObjId = {0};
        ObjId.ObjectId[0] = 0x01; // Simple unique ID
        // In real impl, use UUIDv7
        status = UfsSetObjectId(Fcb, &ObjId);
        if (NT_SUCCESS(status)) {
            RtlCopyMemory(OutputBuffer, &ObjId, sizeof(FILE_OBJECT_ID_BUFFER));
            *ReturnLength = sizeof(FILE_OBJECT_ID_BUFFER);
        }
    } else if (NT_SUCCESS(status)) {
        *ReturnLength = sizeof(FILE_OBJECT_ID_BUFFER);
    }

    return status;
}

// ============================================================================
// Volume IOCTLs
// ============================================================================

NTSTATUS UfsIoctlQueryVolumeInfo(
    IN PUFS_VCB Vcb,
    IN ULONG IoControlCode,
    IN PVOID InputBuffer,
    IN ULONG InputBufferLength,
    OUT PVOID OutputBuffer,
    IN ULONG OutputBufferLength,
    OUT PULONG ReturnLength
) {
    switch (IoControlCode) {
        case IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS: {
            // Return disk extents for volume
            if (OutputBufferLength < sizeof(VOLUME_DISK_EXTENTS)) {
                return STATUS_BUFFER_TOO_SMALL;
            }
            PVOLUME_DISK_EXTENTS Extents = (PVOLUME_DISK_EXTENTS)OutputBuffer;
            Extents->NumberOfDiskExtents = 1;
            Extents->Extents[0].DiskNumber = 0; // Would need actual disk number
            Extents->Extents[0].StartingOffset.QuadPart = Vcb->VolumeSerialNumber.QuadPart;
            Extents->Extents[0].ExtentLength.QuadPart = Vcb->StatFs.TotalSpace;
            *ReturnLength = sizeof(VOLUME_DISK_EXTENTS) + sizeof(DISK_EXTENT);
            return STATUS_SUCCESS;
        }
        case IOCTL_VOLUME_ONLINE:
        case IOCTL_VOLUME_OFFLINE:
            return STATUS_SUCCESS;
        case IOCTL_VOLUME_IS_DYNAMIC: {
            if (OutputBufferLength < sizeof(ULONG)) return STATUS_BUFFER_TOO_SMALL;
            *(PULONG)OutputBuffer = 0; // Not dynamic
            *ReturnLength = sizeof(ULONG);
            return STATUS_SUCCESS;
        }
        default:
            return STATUS_INVALID_DEVICE_REQUEST;
    }
}

// ============================================================================
// Dispatch FSCTL
// ============================================================================

NTSTATUS UfsDispatchFsControl(
    IN PDEVICE_OBJECT DeviceObject,
    IN PIRP Irp
) {
    PUFS_IRP_CONTEXT IrpContext = Irp->Tail.Overlay.DriverContext[0];
    PUFS_VCB Vcb = IrpContext->Vcb;
    PUFS_FCB Fcb = IrpContext->Fcb;
    PIO_STACK_LOCATION IrpSp = IrpContext->IrpSp;

    ULONG FsControlCode = IrpSp->Parameters.FileSystemControl.FsControlCode;
    PVOID InputBuffer = IrpSp->Parameters.FileSystemControl.Type3InputBuffer;
    ULONG InputBufferLength = IrpSp->Parameters.FileSystemControl.InputBufferLength;
    PVOID OutputBuffer = Irp->UserBuffer;
    ULONG OutputBufferLength = IrpSp->Parameters.FileSystemControl.OutputBufferLength;
    ULONG ReturnLength = 0;
    NTSTATUS status = STATUS_INVALID_DEVICE_REQUEST;

    // File-level FSCTLs
    if (Fcb) {
        switch (FsControlCode) {
            case FSCTL_GET_REPARSE_POINT:
                status = UfsFsctlGetReparsePoint(Fcb, InputBuffer, InputBufferLength, OutputBuffer, OutputBufferLength, &ReturnLength);
                break;
            case FSCTL_SET_REPARSE_POINT:
                if (Vcb->ReadOnly) return STATUS_MEDIA_WRITE_PROTECTED;
                status = UfsFsctlSetReparsePoint(Fcb, InputBuffer, InputBufferLength, OutputBuffer, OutputBufferLength, &ReturnLength);
                break;
            case FSCTL_DELETE_REPARSE_POINT:
                if (Vcb->ReadOnly) return STATUS_MEDIA_WRITE_PROTECTED;
                status = UfsFsctlDeleteReparsePoint(Fcb, InputBuffer, InputBufferLength, OutputBuffer, OutputBufferLength, &ReturnLength);
                break;
            case FSCTL_SET_SPARSE:
                if (Vcb->ReadOnly) return STATUS_MEDIA_WRITE_PROTECTED;
                status = UfsFsctlSetSparse(Fcb, InputBuffer, InputBufferLength, OutputBuffer, OutputBufferLength, &ReturnLength);
                break;
            case FSCTL_SET_ZERO_DATA:
                if (Vcb->ReadOnly) return STATUS_MEDIA_WRITE_PROTECTED;
                status = UfsFsctlSetZeroData(Fcb, InputBuffer, InputBufferLength, OutputBuffer, OutputBufferLength, &ReturnLength);
                break;
            case FSCTL_QUERY_ALLOCATED_RANGES:
                status = UfsFsctlQueryAllocatedRanges(Fcb, InputBuffer, InputBufferLength, OutputBuffer, OutputBufferLength, &ReturnLength);
                break;
            case FSCTL_SET_ENCRYPTION:
            case FSCTL_WRITE_RAW_ENCRYPTED:
            case FSCTL_READ_RAW_ENCRYPTED:
            case FSCTL_ENCRYPTION_FSCTL_IO:
                status = UfsFsctlSetEncryption(Fcb, InputBuffer, InputBufferLength, OutputBuffer, OutputBufferLength, &ReturnLength);
                break;
            case FSCTL_SET_OBJECT_ID:
                if (Vcb->ReadOnly) return STATUS_MEDIA_WRITE_PROTECTED;
                status = UfsFsctlSetObjectId(Fcb, InputBuffer, InputBufferLength, OutputBuffer, OutputBufferLength, &ReturnLength);
                break;
            case FSCTL_GET_OBJECT_ID:
                status = UfsFsctlGetObjectId(Fcb, InputBuffer, InputBufferLength, OutputBuffer, OutputBufferLength, &ReturnLength);
                break;
            case FSCTL_DELETE_OBJECT_ID:
                if (Vcb->ReadOnly) return STATUS_MEDIA_WRITE_PROTECTED;
                status = UfsDeleteObjectId(Fcb);
                break;
            case FSCTL_CREATE_OR_GET_OBJECT_ID:
                if (Vcb->ReadOnly) return STATUS_MEDIA_WRITE_PROTECTED;
                status = UfsFsctlCreateOrGetObjectId(Fcb, InputBuffer, InputBufferLength, OutputBuffer, OutputBufferLength, &ReturnLength);
                break;
            default:
                status = STATUS_INVALID_DEVICE_REQUEST;
                break;
        }
    }
    // Volume-level FSCTLs
    else {
        status = UfsIoctlQueryVolumeInfo(Vcb, FsControlCode, InputBuffer, InputBufferLength, OutputBuffer, OutputBufferLength, &ReturnLength);
    }

    Irp->IoStatus.Information = ReturnLength;
    return status;
}

// ============================================================================
// Dispatch Device Control (IOCTL)
// ============================================================================

NTSTATUS UfsDispatchDeviceControl(
    IN PDEVICE_OBJECT DeviceObject,
    IN PIRP Irp
) {
    PUFS_IRP_CONTEXT IrpContext = Irp->Tail.Overlay.DriverContext[0];
    PIO_STACK_LOCATION IrpSp = IrpContext->IrpSp;

    ULONG IoControlCode = IrpSp->Parameters.DeviceIoControl.IoControlCode;
    PVOID InputBuffer = IrpSp->Parameters.DeviceIoControl.Type3InputBuffer;
    ULONG InputBufferLength = IrpSp->Parameters.DeviceIoControl.InputBufferLength;
    PVOID OutputBuffer = Irp->UserBuffer;
    ULONG OutputBufferLength = IrpSp->Parameters.DeviceIoControl.OutputBufferLength;
    ULONG ReturnLength = 0;
    NTSTATUS status = STATUS_INVALID_DEVICE_REQUEST;

    // Handle common IOCTLs
    switch (IoControlCode) {
        case IOCTL_DISK_GET_DRIVE_GEOMETRY:
        case IOCTL_DISK_GET_DRIVE_GEOMETRY_EX:
        case IOCTL_DISK_GET_PARTITION_INFO:
        case IOCTL_DISK_GET_PARTITION_INFO_EX:
        case IOCTL_DISK_GET_LENGTH_INFO:
        case IOCTL_DISK_IS_WRITABLE:
        case IOCTL_DISK_UPDATE_PROPERTIES:
        case IOCTL_STORAGE_QUERY_PROPERTY:
        case IOCTL_STORAGE_GET_DEVICE_NUMBER:
        case IOCTL_STORAGE_GET_HOTPLUG_INFO:
        case IOCTL_STORAGE_GET_MEDIA_TYPES_EX:
            // Forward to underlying block device
            if (IrpContext->Vcb && IrpContext->Vcb->TargetDeviceObject) {
                IoSkipCurrentIrpStackLocation(Irp);
                return IoCallDriver(IrpContext->Vcb->TargetDeviceObject, Irp);
            }
            break;

        case FSCTL_LOCK_VOLUME:
        case FSCTL_UNLOCK_VOLUME:
        case FSCTL_DISMOUNT_VOLUME:
        case FSCTL_MARK_VOLUME_DIRTY:
            // Handle volume lock/dismount
            status = STATUS_SUCCESS;
            break;

        default:
            status = STATUS_INVALID_DEVICE_REQUEST;
            break;
    }

    Irp->IoStatus.Information = ReturnLength;
    return status;
}