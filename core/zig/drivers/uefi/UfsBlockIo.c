// UfsBlockIo.c - UFS Block I/O Protocol Implementation
// Provides EFI_BLOCK_IO_PROTOCOL and EFI_DISK_IO_PROTOCOL for UFS volumes

#include <Uefi.h>
#include <Library/UefiLib.h>
#include <Library/UefiBootServicesTableLib.h>
#include <Library/BaseMemoryLib.h>
#include <Library/MemoryAllocationLib.h>
#include <Library/DebugLib.h>
#include <Protocol/BlockIo.h>
#include <Protocol/DiskIo.h>
#include <Protocol/DiskIo2.h>
#include <Protocol/DevicePath.h>

#include "ufs.h"

// ============================================================================
// Block I/O Protocol Implementation
// ============================================================================

EFI_STATUS EFIAPI UfsBlockIoReset(
    IN EFI_BLOCK_IO_PROTOCOL *This,
    IN BOOLEAN ExtendedVerification
) {
    UFS_VOLUME *Volume = BASE_CR(This, UFS_VOLUME, BlockIo);
    if (!Volume || Volume->Signature != UFS_VOLUME_SIGNATURE) {
        return EFI_INVALID_PARAMETER;
    }

    EfiAcquireLock(&Volume->Lock);
    EFI_STATUS Status = UfsFlushFile(Volume->FsHandle); // Sync filesystem
    EfiReleaseLock(&Volume->Lock);

    if (ExtendedVerification) {
        // Run full integrity check
        UFS_SCRUB_RESULT ScrubResult;
        Status = UfsScrub(Volume->FsHandle, &ScrubResult, NULL, NULL);
    }

    return Status;
}

EFI_STATUS EFIAPI UfsBlockIoReadBlocks(
    IN EFI_BLOCK_IO_PROTOCOL *This,
    IN UINT32 MediaId,
    IN EFI_LBA Lba,
    IN UINTN BufferSize,
    OUT VOID *Buffer
) {
    UFS_VOLUME *Volume = BASE_CR(This, UFS_VOLUME, BlockIo);
    if (!Volume || Volume->Signature != UFS_VOLUME_SIGNATURE) {
        return EFI_INVALID_PARAMETER;
    }

    if (MediaId != Volume->BlockIo->Media->MediaId) {
        return EFI_MEDIA_CHANGED;
    }

    if (Lba + (BufferSize / Volume->BlockSize) > Volume->BlockIo->Media->LastBlock) {
        return EFI_INVALID_PARAMETER;
    }

    EfiAcquireLock(&Volume->Lock);
    EFI_STATUS Status = UfsReadFile(
        Volume->FsHandle,
        Lba * Volume->BlockSize,
        Buffer,
        BufferSize,
        NULL
    );
    EfiReleaseLock(&Volume->Lock);

    return Status;
}

EFI_STATUS EFIAPI UfsBlockIoWriteBlocks(
    IN EFI_BLOCK_IO_PROTOCOL *This,
    IN UINT32 MediaId,
    IN EFI_LBA Lba,
    IN UINTN BufferSize,
    IN VOID *Buffer
) {
    UFS_VOLUME *Volume = BASE_CR(This, UFS_VOLUME, BlockIo);
    if (!Volume || Volume->Signature != UFS_VOLUME_SIGNATURE) {
        return EFI_INVALID_PARAMETER;
    }

    if (Volume->ReadOnly) {
        return EFI_WRITE_PROTECTED;
    }

    if (MediaId != Volume->BlockIo->Media->MediaId) {
        return EFI_MEDIA_CHANGED;
    }

    if (Lba + (BufferSize / Volume->BlockSize) > Volume->BlockIo->Media->LastBlock) {
        return EFI_INVALID_PARAMETER;
    }

    EfiAcquireLock(&Volume->Lock);
    EFI_STATUS Status = UfsWriteFile(
        Volume->FsHandle,
        Lba * Volume->BlockSize,
        Buffer,
        BufferSize,
        NULL
    );
    EfiReleaseLock(&Volume->Lock);

    return Status;
}

EFI_STATUS EFIAPI UfsBlockIoFlushBlocks(
    IN EFI_BLOCK_IO_PROTOCOL *This
) {
    UFS_VOLUME *Volume = BASE_CR(This, UFS_VOLUME, BlockIo);
    if (!Volume || Volume->Signature != UFS_VOLUME_SIGNATURE) {
        return EFI_INVALID_PARAMETER;
    }

    EfiAcquireLock(&Volume->Lock);
    EFI_STATUS Status = UfsFlushFile(Volume->FsHandle);
    EfiReleaseLock(&Volume->Lock);

    return Status;
}

// ============================================================================
// Disk I/O Protocol Implementation
// ============================================================================

EFI_STATUS EFIAPI UfsDiskIoReadDisk(
    IN EFI_DISK_IO_PROTOCOL *This,
    IN UINT32 MediaId,
    IN UINT64 Offset,
    IN UINTN BufferSize,
    OUT VOID *Buffer
) {
    UFS_VOLUME *Volume = BASE_CR(This, UFS_VOLUME, DiskIo);
    if (!Volume || Volume->Signature != UFS_VOLUME_SIGNATURE) {
        return EFI_INVALID_PARAMETER;
    }

    if (MediaId != Volume->BlockIo->Media->MediaId) {
        return EFI_MEDIA_CHANGED;
    }

    if (Offset + BufferSize > Volume->VolumeSize) {
        return EFI_INVALID_PARAMETER;
    }

    EfiAcquireLock(&Volume->Lock);
    EFI_STATUS Status = UfsReadFile(
        Volume->FsHandle,
        Offset,
        Buffer,
        BufferSize,
        NULL
    );
    EfiReleaseLock(&Volume->Lock);

    return Status;
}

EFI_STATUS EFIAPI UfsDiskIoWriteDisk(
    IN EFI_DISK_IO_PROTOCOL *This,
    IN UINT32 MediaId,
    IN UINT64 Offset,
    IN UINTN BufferSize,
    IN VOID *Buffer
) {
    UFS_VOLUME *Volume = BASE_CR(This, UFS_VOLUME, DiskIo);
    if (!Volume || Volume->Signature != UFS_VOLUME_SIGNATURE) {
        return EFI_INVALID_PARAMETER;
    }

    if (Volume->ReadOnly) {
        return EFI_WRITE_PROTECTED;
    }

    if (MediaId != Volume->BlockIo->Media->MediaId) {
        return EFI_MEDIA_CHANGED;
    }

    if (Offset + BufferSize > Volume->VolumeSize) {
        return EFI_INVALID_PARAMETER;
    }

    EfiAcquireLock(&Volume->Lock);
    EFI_STATUS Status = UfsWriteFile(
        Volume->FsHandle,
        Offset,
        Buffer,
        BufferSize,
        NULL
    );
    EfiReleaseLock(&Volume->Lock);

    return Status;
}

// ============================================================================
// Disk I/O 2 Protocol Implementation (64-bit offsets, better alignment)
// ============================================================================

EFI_STATUS EFIAPI UfsDiskIo2ReadDiskEx(
    IN EFI_DISK_IO2_PROTOCOL *This,
    IN UINT32 MediaId,
    IN UINT64 Offset,
    IN OUT EFI_DISK_IO2_TOKEN *Token
) {
    if (!Token || !Token->Buffer) {
        return EFI_INVALID_PARAMETER;
    }

    EFI_STATUS Status = UfsDiskIoReadDisk(
        (EFI_DISK_IO_PROTOCOL *)This,
        MediaId,
        Offset,
        Token->BufferSize,
        Token->Buffer
    );

    if (Token->Event) {
        gBS->SignalEvent(Token->Event);
    }

    return Status;
}

EFI_STATUS EFIAPI UfsDiskIo2WriteDiskEx(
    IN EFI_DISK_IO2_PROTOCOL *This,
    IN UINT32 MediaId,
    IN UINT64 Offset,
    IN OUT EFI_DISK_IO2_TOKEN *Token
) {
    if (!Token || !Token->Buffer) {
        return EFI_INVALID_PARAMETER;
    }

    EFI_STATUS Status = UfsDiskIoWriteDisk(
        (EFI_DISK_IO_PROTOCOL *)This,
        MediaId,
        Offset,
        Token->BufferSize,
        Token->Buffer
    );

    if (Token->Event) {
        gBS->SignalEvent(Token->Event);
    }

    return Status;
}

EFI_STATUS EFIAPI UfsDiskIo2FlushDiskEx(
    IN EFI_DISK_IO2_PROTOCOL *This,
    IN OUT EFI_DISK_IO2_TOKEN *Token
) {
    UFS_VOLUME *Volume = BASE_CR(This, UFS_VOLUME, DiskIo2);
    if (!Volume || Volume->Signature != UFS_VOLUME_SIGNATURE) {
        return EFI_INVALID_PARAMETER;
    }

    EfiAcquireLock(&Volume->Lock);
    EFI_STATUS Status = UfsFlushFile(Volume->FsHandle);
    EfiReleaseLock(&Volume->Lock);

    if (Token && Token->Event) {
        gBS->SignalEvent(Token->Event);
    }

    return Status;
}

EFI_DISK_IO2_PROTOCOL g_UfsDiskIo2Protocol = {
    .Revision = EFI_DISK_IO2_PROTOCOL_REVISION,
    .ReadDiskEx = UfsDiskIo2ReadDiskEx,
    .WriteDiskEx = UfsDiskIo2WriteDiskEx,
    .FlushDiskEx = UfsDiskIo2FlushDiskEx
};

// ============================================================================
// Media Structures
// ============================================================================

EFI_BLOCK_IO_MEDIA g_UfsBlockIoMedia = {
    .MediaId = 1,
    .RemovableMedia = FALSE,
    .MediaPresent = TRUE,
    .LogicalPartition = FALSE,
    .ReadOnly = FALSE,
    .WriteCaching = TRUE,
    .BlockSize = 4096,  // UFS cluster size
    .IoAlign = 4096,
    .LastBlock = 0,  // Set at runtime
    .LowestAlignedLba = 1,
    .LogicalBlocksPerPhysicalBlock = 1,
    .OptimalTransferLengthGranularity = 1
};

EFI_BLOCK_IO_PROTOCOL g_UfsBlockIoProtocol = {
    .Revision = EFI_BLOCK_IO_PROTOCOL_REVISION2,
    .Media = &g_UfsBlockIoMedia,
    .Reset = UfsBlockIoReset,
    .ReadBlocks = UfsBlockIoReadBlocks,
    .WriteBlocks = UfsBlockIoWriteBlocks,
    .FlushBlocks = UfsBlockIoFlushBlocks
};

EFI_DISK_IO_PROTOCOL g_UfsDiskIoProtocol = {
    .Revision = EFI_DISK_IO_PROTOCOL_REVISION,
    .ReadDisk = UfsDiskIoReadDisk,
    .WriteDisk = UfsDiskIoWriteDisk
};