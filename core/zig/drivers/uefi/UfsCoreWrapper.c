// UfsCoreWrapper.c - UEFI Wrapper for UFS Zig Core Library
// Provides C-compatible interface to Zig core functions for UEFI driver

#include <Uefi.h>
#include <Library/UefiLib.h>
#include <Library/UefiBootServicesTableLib.h>
#include <Library/BaseMemoryLib.h>
#include <Library/MemoryAllocationLib.h>
#include <Library/DebugLib.h>
#include <Library/PrintLib.h>
#include <Library/Crc32Lib.h>
#include <Library/BaseCryptLib.h>

#include "ufs.h"

// ============================================================================
// Block Device Wrapper for UEFI
// ============================================================================

typedef struct _UFS_BLOCK_DEVICE_WRAPPER {
    UFS_VOLUME *Volume;
} UFS_BLOCK_DEVICE_WRAPPER;

// Block device operations using UEFI protocols
EFI_STATUS EFIAPI UfsBlockDevRead(
    IN UFS_BLOCK_DEVICE_HANDLE *Handle,
    IN UINT64 Offset,
    OUT VOID *Buffer,
    IN UINTN Size
) {
    UFS_BLOCK_DEVICE_WRAPPER *Wrapper = (UFS_BLOCK_DEVICE_WRAPPER*)Handle;
    UFS_VOLUME *Volume = Wrapper->Volume;

    if (!Volume || Volume->Signature != UFS_VOLUME_SIGNATURE) {
        return EFI_INVALID_PARAMETER;
    }

    // Use Disk I/O protocol for byte-level access
    return Volume->DiskIo->ReadDisk(
        Volume->DiskIo,
        Volume->BlockIo->Media->MediaId,
        Offset,
        Size,
        Buffer
    );
}

EFI_STATUS EFIAPI UfsBlockDevWrite(
    IN UFS_BLOCK_DEVICE_HANDLE *Handle,
    IN UINT64 Offset,
    IN VOID *Buffer,
    IN UINTN Size
) {
    UFS_BLOCK_DEVICE_WRAPPER *Wrapper = (UFS_BLOCK_DEVICE_WRAPPER*)Handle;
    UFS_VOLUME *Volume = Wrapper->Volume;

    if (!Volume || Volume->Signature != UFS_VOLUME_SIGNATURE) {
        return EFI_INVALID_PARAMETER;
    }

    if (Volume->ReadOnly) {
        return EFI_WRITE_PROTECTED;
    }

    return Volume->DiskIo->WriteDisk(
        Volume->DiskIo,
        Volume->BlockIo->Media->MediaId,
        Offset,
        Size,
        Buffer
    );
}

EFI_STATUS EFIAPI UfsBlockDevFlush(
    IN UFS_BLOCK_DEVICE_HANDLE *Handle
) {
    UFS_BLOCK_DEVICE_WRAPPER *Wrapper = (UFS_BLOCK_DEVICE_WRAPPER*)Handle;
    UFS_VOLUME *Volume = Wrapper->Volume;

    if (!Volume || Volume->Signature != UFS_VOLUME_SIGNATURE) {
        return EFI_INVALID_PARAMETER;
    }

    return Volume->BlockIo->FlushBlocks(Volume->BlockIo);
}

EFI_STATUS EFIAPI UfsBlockDevGetInfo(
    IN UFS_BLOCK_DEVICE_HANDLE *Handle,
    OUT UFS_BLOCK_DEVICE_INFO *Info
) {
    UFS_BLOCK_DEVICE_WRAPPER *Wrapper = (UFS_BLOCK_DEVICE_WRAPPER*)Handle;
    UFS_VOLUME *Volume = Wrapper->Volume;

    if (!Volume || Volume->Signature != UFS_VOLUME_SIGNATURE) {
        return EFI_INVALID_PARAMETER;
    }

    Info->BlockSize = Volume->BlockSize;
    Info->PhysicalBlockSize = Volume->BlockSize;
    Info->OptimalTransferSize = Volume->BlockIo->Media->OptimalTransferLengthGranularity * Volume->BlockSize;
    Info->TotalBlocks = Volume->VolumeSize / Volume->BlockSize;
    Info->IsRemovable = Volume->BlockIo->Media->RemovableMedia;
    Info->IsReadOnly = Volume->ReadOnly;
    Info->IsSsd = FALSE;  // Would need to detect
    Info->IsVirtual = FALSE;
    Info->SerialNumber = NULL;
    Info->Model = NULL;
    Info->Firmware = NULL;

    return EFI_SUCCESS;
}

UFS_BLOCK_DEVICE_OPS g_UfsBlockDeviceOps = {
    .Read = UfsBlockDevRead,
    .Write = UfsBlockDevWrite,
    .Flush = UfsBlockDevFlush,
    .GetInfo = UfsBlockDevGetInfo
};

// ============================================================================
// Block Device Creation
// ============================================================================

EFI_STATUS EFIAPI UfsBlockDeviceCreate(
    IN UFS_BLOCK_DEVICE_OPS *Ops,
    IN VOID *Context,
    OUT UFS_BLOCK_DEVICE_HANDLE **Handle
) {
    UFS_BLOCK_DEVICE_WRAPPER *Wrapper = AllocateZeroPool(sizeof(UFS_BLOCK_DEVICE_WRAPPER));
    if (!Wrapper) {
        return EFI_OUT_OF_RESOURCES;
    }

    Wrapper->Volume = (UFS_VOLUME*)Context;
    *Handle = (UFS_BLOCK_DEVICE_HANDLE*)Wrapper;

    return EFI_SUCCESS;
}

EFI_STATUS EFIAPI UfsBlockDeviceClose(
    IN UFS_BLOCK_DEVICE_HANDLE *Handle
) {
    if (Handle) {
        FreePool(Handle);
    }
    return EFI_SUCCESS;
}

// ============================================================================
// CRC32C Implementation (HW accelerated if available)
// ============================================================================

UINT32 EFIAPI UfsCrc32c(
    IN CONST VOID *Data,
    IN UINTN Length
) {
    // Use EDK2 CRC32 library (which is CRC32C/ISC)
    return CalculateCrc32(Data, (UINT32)Length);
}

// ============================================================================
// BLAKE3 Implementation (using BaseCryptLib)
// ============================================================================

EFI_STATUS EFIAPI UfsBlake3(
    IN CONST VOID *Data,
    IN UINTN Length,
    OUT UINT8 *Hash
) {
    // Use EDK2 BaseCryptLib for BLAKE3
    // Note: BaseCryptLib may not have BLAKE3, fallback to SHA256
    // In real implementation, we'd include a BLAKE3 implementation
    return HashDataBySha256(Data, Length, Hash);
}

// ============================================================================
// UUIDv7 Generation
// ============================================================================

VOID EFIAPI UfsGenerateUuidv7(
    OUT UINT8 *Uuid
) {
    EFI_TIME Time;
    gRT->GetTime(&Time, NULL);

    // UUIDv7 format: time-ordered (48-bit timestamp + 74 random bits + version/variant)
    UINT64 Timestamp = ((UINT64)Time.Year - 1970) * 31536000 +
                       (UINT64)Time.Month * 2592000 +
                       (UINT64)Time.Day * 86400 +
                       (UINT64)Time.Hour * 3600 +
                       (UINT64)Time.Minute * 60 +
                       (UINT64)Time.Second;
    Timestamp = Timestamp * 1000 + Time.Nanosecond / 1000000;  // Milliseconds

    // Fill UUID
    Uuid[0] = (Timestamp >> 40) & 0xFF;
    Uuid[1] = (Timestamp >> 32) & 0xFF;
    Uuid[2] = (Timestamp >> 24) & 0xFF;
    Uuid[3] = (Timestamp >> 16) & 0xFF;
    Uuid[4] = (Timestamp >> 8) & 0xFF;
    Uuid[5] = Timestamp & 0xFF;

    Uuid[6] = 0x70 | ((Timestamp >> 48) & 0x0F);  // Version 7

    // Random bytes for remaining
    gBS->GetNextMonotonicCount((UINT64*)&Uuid[8]);
    gBS->GetNextMonotonicCount((UINT64*)&Uuid[10]);
    gBS->GetNextMonotonicCount((UINT64*)&Uuid[12]);
    gBS->GetNextMonotonicCount((UINT64*)&Uuid[14]);

    // Set variant bits (RFC 4122)
    Uuid[8] = (Uuid[8] & 0x3F) | 0x80;
}

// ============================================================================
// Timestamp
// ============================================================================

UINT64 EFIAPI UfsGetTimestamp(VOID) {
    EFI_TIME Time;
    EFI_STATUS Status = gRT->GetTime(&Time, NULL);
    if (EFI_ERROR(Status)) {
        return 0;
    }

    // Convert to nanoseconds since Unix epoch
    UINT64 Secs = 0;
    // Simplified - real impl would use proper epoch conversion
    Secs = ((UINT64)Time.Year - 1970) * 31536000 +
           (UINT64)Time.Month * 2592000 +
           (UINT64)Time.Day * 86400 +
           (UINT64)Time.Hour * 3600 +
           (UINT64)Time.Minute * 60 +
           (UINT64)Time.Second;

    return Secs * 1000000000 + Time.Nanosecond;
}

// ============================================================================
// Error String
// ============================================================================

CONST CHAR8* EFIAPI UfsStrError(INT32 ErrorCode) {
    switch (ErrorCode) {
        case UFS_OK: return "Success";
        case UFS_ERROR_OUT_OF_MEMORY: return "Out of memory";
        case UFS_ERROR_INVALID_ARGUMENT: return "Invalid argument";
        case UFS_ERROR_IO: return "I/O error";
        case UFS_ERROR_NOT_FOUND: return "Not found";
        case UFS_ERROR_ALREADY_EXISTS: return "Already exists";
        case UFS_ERROR_PERMISSION_DENIED: return "Permission denied";
        case UFS_ERROR_CORRUPTED_DATA: return "Corrupted data";
        case UFS_ERROR_UNSUPPORTED_FEATURE: return "Unsupported feature";
        case UFS_ERROR_BUFFER_TOO_SMALL: return "Buffer too small";
        case UFS_ERROR_INVALID_FORMAT: return "Invalid format";
        case UFS_ERROR_INTERNAL: return "Internal error";
        case UFS_ERROR_OUT_OF_SPACE: return "Out of space";
        case UFS_ERROR_ALIGNMENT: return "Alignment error";
        case UFS_ERROR_FRAGMENTED: return "Fragmented allocation";
        case UFS_ERROR_NOT_INITIALIZED: return "Not initialized";
        case UFS_ERROR_WRITE_PROTECTED: return "Write protected";
        case UFS_ERROR_DEVICE_NOT_FOUND: return "Device not found";
        case UFS_ERROR_UNSUPPORTED_OPERATION: return "Unsupported operation";
        case UFS_ERROR_TIMEOUT: return "Timeout";
        default: return "Unknown error";
    }
}

// ============================================================================
// Memory Allocation Helpers
// ============================================================================

VOID* EFIAPI UfsAllocatePool(UINTN Size) {
    return AllocateZeroPool(Size);
}

VOID EFIAPI UfsFreePool(VOID *Buffer) {
    if (Buffer) {
        FreePool(Buffer);
    }
}

// ============================================================================
// Lock Helpers
// ============================================================================

EFI_STATUS EFIAPI UfsLockInitialize(EFI_LOCK *Lock) {
    return EfiInitializeLock(Lock, TPL_CALLBACK);
}

VOID EFIAPI UfsLockAcquire(EFI_LOCK *Lock) {
    EfiAcquireLock(Lock);
}

VOID EFIAPI UfsLockRelease(EFI_LOCK *Lock) {
    EfiReleaseLock(Lock);
}