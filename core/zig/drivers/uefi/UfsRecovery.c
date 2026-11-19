// UfsRecovery.c - UFS Journal Recovery for UEFI
// Handles journal replay and filesystem recovery on boot

#include <Uefi.h>
#include <Library/UefiLib.h>
#include <Library/UefiBootServicesTableLib.h>
#include <Library/BaseMemoryLib.h>
#include <Library/MemoryAllocationLib.h>
#include <Library/DebugLib.h>

#include "ufs.h"

// ============================================================================
// Recovery Functions
// ============================================================================

BOOLEAN EFIAPI UfsNeedsRecovery(
    IN UFS_BLOCK_DEVICE_HANDLE *BlockDevHandle
) {
    if (!BlockDevHandle) {
        return FALSE;
    }

    INT32 NeedsRecovery = 0;
    EFI_STATUS Status = ufs_needs_recovery(BlockDevHandle, &NeedsRecovery);
    return !EFI_ERROR(Status) && NeedsRecovery != 0;
}

EFI_STATUS EFIAPI UfsRecover(
    IN UFS_BLOCK_DEVICE_HANDLE *BlockDevHandle
) {
    if (!BlockDevHandle) {
        return EFI_INVALID_PARAMETER;
    }

    DEBUG((DEBUG_INFO, "UFS: Starting journal recovery...\n"));

    EFI_STATUS Status = ufs_recover(BlockDevHandle);
    if (EFI_ERROR(Status)) {
        DEBUG((DEBUG_ERROR, "UFS: Recovery failed: %r\n", Status));
        return Status;
    }

    DEBUG((DEBUG_INFO, "UFS: Journal recovery completed successfully\n"));
    return EFI_SUCCESS;
}

EFI_STATUS EFIAPI UfsVerifyJournal(
    IN UFS_BLOCK_DEVICE_HANDLE *BlockDevHandle,
    OUT BOOLEAN *IsValid
) {
    if (!BlockDevHandle || !IsValid) {
        return EFI_INVALID_PARAMETER;
    }

    INT32 Ok = 0;
    EFI_STATUS Status = ufs_verify_journal(BlockDevHandle, &Ok);
    if (EFI_ERROR(Status)) {
        return Status;
    }

    *IsValid = (Ok != 0);
    return EFI_SUCCESS;
}

// ============================================================================
// Full Recovery with Filesystem Context
// ============================================================================

typedef struct _UFS_RECOVERY_CONTEXT {
    UFS_BLOCK_DEVICE_HANDLE *BlockDevHandle;
    UFS_ALLOCATION_GROUP_MANAGER *AgManager;
    UINT64 ClusterSize;
} UFS_RECOVERY_CONTEXT;

EFI_STATUS EFIAPI UfsRecoverFull(
    IN UFS_BLOCK_DEVICE_HANDLE *BlockDevHandle,
    IN UFS_ALLOCATION_GROUP_MANAGER *AgManager
) {
    if (!BlockDevHandle || !AgManager) {
        return EFI_INVALID_PARAMETER;
    }

    DEBUG((DEBUG_INFO, "UFS: Starting full recovery with AG manager...\n"));

    // The UFS core recovery engine will:
    // 1. Read journal superblock
    // 2. Find last checkpoint
    // 3. Replay all transactions from checkpoint
    // 4. Apply operations to filesystem structures
    // 5. Update bitmaps and metadata

    // For now, use the standard recovery which will be enhanced
    // once the core journal recovery is fully implemented
    EFI_STATUS Status = ufs_recover(BlockDevHandle);
    if (EFI_ERROR(Status)) {
        DEBUG((DEBUG_ERROR, "UFS: Full recovery failed: %r\n", Status));
        return Status;
    }

    DEBUG((DEBUG_INFO, "UFS: Full recovery completed\n"));
    return EFI_SUCCESS;
}

// ============================================================================
// Scrub/Integrity Check
// ============================================================================

EFI_STATUS EFIAPI UfsScrub(
    IN UFS_FS_HANDLE *FsHandle,
    OUT UFS_SCRUB_RESULT *Result,
    IN EFI_UFS_SCRUB_PROGRESS ProgressCallback OPTIONAL,
    IN VOID *Context OPTIONAL
) {
    if (!FsHandle || !Result) {
        return EFI_INVALID_PARAMETER;
    }

    DEBUG((DEBUG_INFO, "UFS: Starting scrub/integrity check...\n"));

    EFI_STATUS Status = ufs_scrub(FsHandle, Result, ProgressCallback, Context);
    if (EFI_ERROR(Status)) {
        DEBUG((DEBUG_ERROR, "UFS: Scrub failed: %r\n", Status));
        return Status;
    }

    DEBUG((DEBUG_INFO, "UFS: Scrub completed - Checked: %llu, Errors: %llu, Corrupted: %llu\n",
           Result->Checked, Result->Errors, Result->CorruptedFiles));

    return EFI_SUCCESS;
}

// ============================================================================
// Checkpoint/Flush
// ============================================================================

EFI_STATUS EFIAPI UfsCheckpoint(
    IN UFS_FS_HANDLE *FsHandle
) {
    if (!FsHandle) {
        return EFI_INVALID_PARAMETER;
    }

    return ufs_checkpoint(FsHandle);
}

// ============================================================================
// Feature Flags
// ============================================================================

EFI_STATUS EFIAPI UfsGetFeatures(
    IN UFS_FS_HANDLE *FsHandle,
    OUT UINT32 *Incompat,
    OUT UINT32 *CompatRo,
    OUT UINT32 *CompatRw
) {
    if (!FsHandle) {
        return EFI_INVALID_PARAMETER;
    }

    return ufs_get_features(FsHandle, Incompat, CompatRo, CompatRw);
}

EFI_STATUS EFIAPI UfsSetFeature(
    IN UFS_FS_HANDLE *FsHandle,
    IN INT32 Type,
    IN INT32 Bit,
    IN INT32 Enabled
) {
    if (!FsHandle) {
        return EFI_INVALID_PARAMETER;
    }

    return ufs_set_feature(FsHandle, Type, Bit, Enabled);
}