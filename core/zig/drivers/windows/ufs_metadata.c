// ufs_metadata.c - Windows Metadata Capsule Integration
// Implements NTFS-compatible metadata namespaces using UFS capsules

#include <ntifs.h>
#include <fltkernel.h>

#include "ufs.h"

// ============================================================================
// Windows-Specific Capsule Namespace IDs (matching ufs.h)
// ============================================================================

#define UFS_NS_NTFS_SECURITY_DESCRIPTOR    0x8001  // SDDL/ACLs
#define UFS_NS_NTFS_ALTERNATE_DATA_STREAMS 0x8002  // ADS
#define UFS_NS_NTFS_REPARSE_POINTS         0x8003  // Reparse points (symlinks, junctions, mount points)
#define UFS_NS_NTFS_FILE_ID                0x8004  // File ID (128-bit)
#define UFS_NS_NTFS_USN_JOURNAL            0x8005  // USN Journal
#define UFS_NS_NTFS_COMPRESSION            0x8006  // Compression state
#define UFS_NS_NTFS_EFS                    0x8007  // EFS encryption
#define UFS_NS_NTFS_OBJECT_ID              0x8008  // Object IDs
#define UFS_NS_NTFS_QUOTA                  0x8009  // Quota

// ============================================================================
// Security Descriptor (NTFS ACLs)
// ============================================================================

NTSTATUS UfsSetNtfsSecurityDescriptor(
    IN PUFS_FCB Fcb,
    IN PSECURITY_DESCRIPTOR SecurityDescriptor,
    IN ULONG Length
) {
    if (!Fcb || !SecurityDescriptor || Length == 0) {
        return STATUS_INVALID_PARAMETER;
    }

    // Validate security descriptor
    if (!RtlValidSecurityDescriptor(SecurityDescriptor)) {
        return STATUS_INVALID_PARAMETER;
    }

    // Store in UFS capsule
    NTSTATUS status = UfsSetXattr(
        Fcb->Vcb->FsHandle,
        Fcb->InodeNumber,
        UFS_NS_NTFS_SECURITY_DESCRIPTOR,
        0,
        "sd",
        SecurityDescriptor,
        Length,
        0
    );

    if (NT_SUCCESS(status)) {
        // Update inode flags
        Fcb->InodeInfo.Flags |= UFS_INODE_FLAG_HAS_CAPSULE;
    }

    return status;
}

NTSTATUS UfsGetNtfsSecurityDescriptor(
    IN PUFS_FCB Fcb,
    OUT PSECURITY_DESCRIPTOR* SecurityDescriptor,
    OUT PULONG Length
) {
    if (!Fcb || !SecurityDescriptor || !Length) {
        return STATUS_INVALID_PARAMETER;
    }

    // Query size first
    ULONG Size = 0;
    NTSTATUS status = UfsGetXattr(
        Fcb->Vcb->FsHandle,
        Fcb->InodeNumber,
        UFS_NS_NTFS_SECURITY_DESCRIPTOR,
        0,
        "sd",
        NULL,
        0,
        &Size
    );

    if (status == STATUS_BUFFER_TOO_SMALL) {
        *SecurityDescriptor = ExAllocatePoolWithTag(PagedPool, Size, 'SDNU');
        if (!*SecurityDescriptor) {
            return STATUS_INSUFFICIENT_RESOURCES;
        }

        status = UfsGetXattr(
            Fcb->Vcb->FsHandle,
            Fcb->InodeNumber,
            UFS_NS_NTFS_SECURITY_DESCRIPTOR,
            0,
            "sd",
            *SecurityDescriptor,
            Size,
            Length
        );

        if (!NT_SUCCESS(status)) {
            ExFreePoolWithTag(*SecurityDescriptor, 'SDNU');
            *SecurityDescriptor = NULL;
        }
    }

    return status;
}

// ============================================================================
// Alternate Data Streams (ADS)
// ============================================================================

NTSTATUS UfsSetAlternateDataStream(
    IN PUFS_FCB Fcb,
    IN PUNICODE_STRING StreamName,
    IN PVOID Data,
    IN ULONG Length
) {
    if (!Fcb || !StreamName || !Data || Length == 0) {
        return STATUS_INVALID_PARAMETER;
    }

    // Convert to ANSI for capsule storage
    ANSI_STRING AnsiName;
    NTSTATUS status = RtlUnicodeStringToAnsiString(&AnsiName, StreamName, TRUE);
    if (!NT_SUCCESS(status)) {
        return status;
    }

    status = UfsSetXattr(
        Fcb->Vcb->FsHandle,
        Fcb->InodeNumber,
        UFS_NS_NTFS_ALTERNATE_DATA_STREAMS,
        0,
        AnsiName.Buffer,
        Data,
        Length,
        0
    );

    RtlFreeAnsiString(&AnsiName);
    return status;
}

NTSTATUS UfsGetAlternateDataStream(
    IN PUFS_FCB Fcb,
    IN PUNICODE_STRING StreamName,
    OUT PVOID* Data,
    OUT PULONG Length
) {
    if (!Fcb || !StreamName || !Data || !Length) {
        return STATUS_INVALID_PARAMETER;
    }

    ANSI_STRING AnsiName;
    NTSTATUS status = RtlUnicodeStringToAnsiString(&AnsiName, StreamName, TRUE);
    if (!NT_SUCCESS(status)) {
        return status;
    }

    ULONG Size = 0;
    status = UfsGetXattr(
        Fcb->Vcb->FsHandle,
        Fcb->InodeNumber,
        UFS_NS_NTFS_ALTERNATE_DATA_STREAMS,
        0,
        AnsiName.Buffer,
        NULL,
        0,
        &Size
    );

    RtlFreeAnsiString(&AnsiName);

    if (status == STATUS_BUFFER_TOO_SMALL) {
        *Data = ExAllocatePoolWithTag(PagedPool, Size, 'SDAU');
        if (!*Data) {
            return STATUS_INSUFFICIENT_RESOURCES;
        }

        status = RtlUnicodeStringToAnsiString(&AnsiName, StreamName, TRUE);
        if (NT_SUCCESS(status)) {
            status = UfsGetXattr(
                Fcb->Vcb->FsHandle,
                Fcb->InodeNumber,
                UFS_NS_NTFS_ALTERNATE_DATA_STREAMS,
                0,
                AnsiName.Buffer,
                *Data,
                Size,
                Length
            );
            RtlFreeAnsiString(&AnsiName);
        }

        if (!NT_SUCCESS(status)) {
            ExFreePoolWithTag(*Data, 'SDAU');
            *Data = NULL;
        }
    }

    return status;
}

NTSTATUS UfsListAlternateDataStreams(
    IN PUFS_FCB Fcb,
    OUT PVOID Buffer,
    IN ULONG BufferLength,
    OUT PULONG ReturnLength
) {
    if (!Fcb || !Buffer || !ReturnLength) {
        return STATUS_INVALID_PARAMETER;
    }

    return UfsListXattr(
        Fcb->Vcb->FsHandle,
        Fcb->InodeNumber,
        UFS_NS_NTFS_ALTERNATE_DATA_STREAMS,
        Buffer,
        BufferLength,
        ReturnLength
    );
}

// ============================================================================
// Reparse Points (Symlinks, Junctions, Mount Points)
// ============================================================================

NTSTATUS UfsSetReparsePoint(
    IN PUFS_FCB Fcb,
    IN PREPARSE_DATA_BUFFER ReparseBuffer,
    IN ULONG Length
) {
    if (!Fcb || !ReparseBuffer || Length == 0) {
        return STATUS_INVALID_PARAMETER;
    }

    // Validate reparse buffer
    if (ReparseBuffer->ReparseTag == 0) {
        return STATUS_INVALID_PARAMETER;
    }

    return UfsSetXattr(
        Fcb->Vcb->FsHandle,
        Fcb->InodeNumber,
        UFS_NS_NTFS_REPARSE_POINTS,
        0,
        "reparse",
        ReparseBuffer,
        Length,
        0
    );
}

NTSTATUS UfsGetReparsePoint(
    IN PUFS_FCB Fcb,
    OUT PREPARSE_DATA_BUFFER* ReparseBuffer,
    OUT PULONG Length
) {
    if (!Fcb || !ReparseBuffer || !Length) {
        return STATUS_INVALID_PARAMETER;
    }

    ULONG Size = 0;
    NTSTATUS status = UfsGetXattr(
        Fcb->Vcb->FsHandle,
        Fcb->InodeNumber,
        UFS_NS_NTFS_REPARSE_POINTS,
        0,
        "reparse",
        NULL,
        0,
        &Size
    );

    if (status == STATUS_BUFFER_TOO_SMALL) {
        *ReparseBuffer = ExAllocatePoolWithTag(PagedPool, Size, 'RPNU');
        if (!*ReparseBuffer) {
            return STATUS_INSUFFICIENT_RESOURCES;
        }

        status = UfsGetXattr(
            Fcb->Vcb->FsHandle,
            Fcb->InodeNumber,
            UFS_NS_NTFS_REPARSE_POINTS,
            0,
            "reparse",
            *ReparseBuffer,
            Size,
            Length
        );

        if (!NT_SUCCESS(status)) {
            ExFreePoolWithTag(*ReparseBuffer, 'RPNU');
            *ReparseBuffer = NULL;
        }
    }

    return status;
}

NTSTATUS UfsDeleteReparsePoint(
    IN PUFS_FCB Fcb
) {
    if (!Fcb) {
        return STATUS_INVALID_PARAMETER;
    }

    return UfsRemoveXattr(
        Fcb->Vcb->FsHandle,
        Fcb->InodeNumber,
        UFS_NS_NTFS_REPARSE_POINTS,
        0,
        "reparse"
    );
}

// ============================================================================
// File ID (128-bit Object Identifier)
// ============================================================================

NTSTATUS UfsSetFileId(
    IN PUFS_FCB Fcb,
    IN PFILE_OBJECT_ID_BUFFER ObjectIdBuffer
) {
    if (!Fcb || !ObjectIdBuffer) {
        return STATUS_INVALID_PARAMETER;
    }

    return UfsSetXattr(
        Fcb->Vcb->FsHandle,
        Fcb->InodeNumber,
        UFS_NS_NTFS_FILE_ID,
        0,
        "fileid",
        ObjectIdBuffer,
        sizeof(FILE_OBJECT_ID_BUFFER),
        0
    );
}

NTSTATUS UfsGetFileId(
    IN PUFS_FCB Fcb,
    OUT PFILE_OBJECT_ID_BUFFER ObjectIdBuffer
) {
    if (!Fcb || !ObjectIdBuffer) {
        return STATUS_INVALID_PARAMETER;
    }

    ULONG Size = 0;
    NTSTATUS status = UfsGetXattr(
        Fcb->Vcb->FsHandle,
        Fcb->InodeNumber,
        UFS_NS_NTFS_FILE_ID,
        0,
        "fileid",
        ObjectIdBuffer,
        sizeof(FILE_OBJECT_ID_BUFFER),
        &Size
    );

    return status;
}

// ============================================================================
// USN Journal (stub - UFS has its own journal)
// ============================================================================

NTSTATUS UfsQueryUsnJournal(
    IN PUFS_FCB Fcb,
    IN PVOID Buffer,
    IN ULONG BufferLength,
    OUT PULONG ReturnLength
) {
    // UFS uses its own logical redo journal
    // This is a stub for NTFS compatibility
    *ReturnLength = 0;
    return STATUS_NOT_SUPPORTED;
}

// ============================================================================
// Compression State
// ============================================================================

NTSTATUS UfsSetCompressionState(
    IN PUFS_FCB Fcb,
    IN USHORT CompressionFormat
) {
    if (!Fcb) {
        return STATUS_INVALID_PARAMETER;
    }

    if (CompressionFormat != COMPRESSION_FORMAT_NONE &&
        CompressionFormat != COMPRESSION_FORMAT_LZNT1) {
        return STATUS_INVALID_PARAMETER;
    }

    return UfsSetXattr(
        Fcb->Vcb->FsHandle,
        Fcb->InodeNumber,
        UFS_NS_NTFS_COMPRESSION,
        0,
        "state",
        &CompressionFormat,
        sizeof(CompressionFormat),
        0
    );
}

NTSTATUS UfsGetCompressionState(
    IN PUFS_FCB Fcb,
    OUT PUSHORT CompressionFormat
) {
    if (!Fcb || !CompressionFormat) {
        return STATUS_INVALID_PARAMETER;
    }

    ULONG Size = 0;
    return UfsGetXattr(
        Fcb->Vcb->FsHandle,
        Fcb->InodeNumber,
        UFS_NS_NTFS_COMPRESSION,
        0,
        "state",
        CompressionFormat,
        sizeof(*CompressionFormat),
        &Size
    );
}

// ============================================================================
// EFS Encryption (stub - returns unsupported in v1)
// ============================================================================

NTSTATUS UfsSetEncryption(
    IN PUFS_FCB Fcb,
    IN PVOID EncryptionData,
    IN ULONG Length
) {
    _ = Fcb; _ = EncryptionData; _ = Length;
    return STATUS_NOT_SUPPORTED;
}

NTSTATUS UfsGetEncryption(
    IN PUFS_FCB Fcb,
    OUT PVOID* EncryptionData,
    OUT PULONG Length
) {
    _ = Fcb; _ = EncryptionData; _ = Length;
    return STATUS_NOT_SUPPORTED;
}

// ============================================================================
// Object ID (for distributed link tracking)
// ============================================================================

NTSTATUS UfsSetObjectId(
    IN PUFS_FCB Fcb,
    IN PFILE_OBJECT_ID_BUFFER ObjectIdBuffer
) {
    if (!Fcb || !ObjectIdBuffer) {
        return STATUS_INVALID_PARAMETER;
    }

    return UfsSetXattr(
        Fcb->Vcb->FsHandle,
        Fcb->InodeNumber,
        UFS_NS_NTFS_OBJECT_ID,
        0,
        "objectid",
        ObjectIdBuffer,
        sizeof(FILE_OBJECT_ID_BUFFER),
        0
    );
}

NTSTATUS UfsGetObjectId(
    IN PUFS_FCB Fcb,
    OUT PFILE_OBJECT_ID_BUFFER ObjectIdBuffer
) {
    if (!Fcb || !ObjectIdBuffer) {
        return STATUS_INVALID_PARAMETER;
    }

    ULONG Size = 0;
    return UfsGetXattr(
        Fcb->Vcb->FsHandle,
        Fcb->InodeNumber,
        UFS_NS_NTFS_OBJECT_ID,
        0,
        "objectid",
        ObjectIdBuffer,
        sizeof(FILE_OBJECT_ID_BUFFER),
        &Size
    );
}

// ============================================================================
// Quota (stub)
// ============================================================================

NTSTATUS UfsSetQuota(
    IN PUFS_FCB Fcb,
    IN PVOID QuotaData,
    IN ULONG Length
) {
    _ = Fcb; _ = QuotaData; _ = Length;
    return STATUS_NOT_SUPPORTED;
}

NTSTATUS UfsGetQuota(
    IN PUFS_FCB Fcb,
    OUT PVOID* QuotaData,
    OUT PULONG Length
) {
    _ = Fcb; _ = QuotaData; _ = Length;
    return STATUS_NOT_SUPPORTED;
}

// ============================================================================
// Helper: Convert UFS capsule operations to NTSTATUS
// ============================================================================

NTSTATUS UfsSetXattr(
    IN UFS_FS_HANDLE* FsHandle,
    IN ULONGLONG InodeNumber,
    IN UINT16 NamespaceId,
    IN UINT16 Type,
    IN PCHAR Name,
    IN PVOID Value,
    IN SIZE_T ValueLen,
    IN INT Flags
) {
    return (NTSTATUS)ufs_setxattr(FsHandle, InodeNumber, NamespaceId, Type, Name, Value, ValueLen, Flags);
}

NTSTATUS UfsGetXattr(
    IN UFS_FS_HANDLE* FsHandle,
    IN ULONGLONG InodeNumber,
    IN UINT16 NamespaceId,
    IN UINT16 Type,
    IN PCHAR Name,
    OUT PVOID Buffer,
    IN SIZE_T BufferSize,
    OUT PSIZE_T OutSize
) {
    return (NTSTATUS)ufs_getxattr(FsHandle, InodeNumber, NamespaceId, Type, Name, Buffer, BufferSize, OutSize);
}

NTSTATUS UfsListXattr(
    IN UFS_FS_HANDLE* FsHandle,
    IN ULONGLONG InodeNumber,
    IN UINT16 NamespaceId,
    OUT PVOID Buffer,
    IN SIZE_T BufferSize,
    OUT PSIZE_T OutSize
) {
    // Simplified - would need proper implementation
    return STATUS_NOT_SUPPORTED;
}

NTSTATUS UfsRemoveXattr(
    IN UFS_FS_HANDLE* FsHandle,
    IN ULONGLONG InodeNumber,
    IN UINT16 NamespaceId,
    IN UINT16 Type,
    IN PCHAR Name
) {
    return (NTSTATUS)ufs_removexattr(FsHandle, InodeNumber, NamespaceId, Type, Name);
}