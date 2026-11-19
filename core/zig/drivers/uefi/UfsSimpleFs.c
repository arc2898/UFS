// UfsSimpleFs.c - UFS Simple File System Protocol Implementation
// Provides EFI_SIMPLE_FILE_SYSTEM_PROTOCOL for UFS volumes

#include <Uefi.h>
#include <Library/UefiLib.h>
#include <Library/UefiBootServicesTableLib.h>
#include <Library/BaseMemoryLib.h>
#include <Library/MemoryAllocationLib.h>
#include <Library/DebugLib.h>
#include <Library/PrintLib.h>
#include <Protocol/SimpleFileSystem.h>
#include <Protocol/DevicePath.h>
#include <Guid/FileInfo.h>

#include "ufs.h"

// ============================================================================
// Simple File System Protocol: OpenVolume
// ============================================================================

EFI_STATUS EFIAPI UfsSimpleFsOpenVolume(
    IN EFI_SIMPLE_FILE_SYSTEM_PROTOCOL *This,
    OUT EFI_FILE_PROTOCOL **Root
) {
    UFS_VOLUME *Volume = BASE_CR(This, UFS_VOLUME, SimpleFs);
    if (!Volume || Volume->Signature != UFS_VOLUME_SIGNATURE) {
        return EFI_INVALID_PARAMETER;
    }

    EfiAcquireLock(&Volume->Lock);

    // Create file context for root directory
    UFS_FILE *File = AllocateZeroPool(sizeof(UFS_FILE));
    if (!File) {
        EfiReleaseLock(&Volume->Lock);
        return EFI_OUT_OF_RESOURCES;
    }

    File->Signature = UFS_FILE_SIGNATURE;
    File->Volume = Volume;
    File->InodeNumber = 2;  // Root inode
    File->IsDirectory = TRUE;
    File->IsRoot = TRUE;
    File->Position = 0;
    File->WriteMode = !Volume->ReadOnly;
    EfiInitializeLock(&File->Lock, TPL_CALLBACK);

    // Open root directory via UFS core
    EFI_STATUS Status = UfsOpenFile(Volume->FsHandle, 2,
        UFS_OPEN_READ | (File->WriteMode ? UFS_OPEN_WRITE : 0) | UFS_OPEN_DIRECTORY,
        &File->FileHandle);
    if (EFI_ERROR(Status)) {
        FreePool(File);
        EfiReleaseLock(&Volume->Lock);
        return Status;
    }

    // Initialize EFI_FILE_PROTOCOL
    File->FileProtocol.Revision = EFI_FILE_PROTOCOL_REVISION;
    File->FileProtocol.Open = UfsFileOpen;
    File->FileProtocol.Close = UfsFileClose;
    File->FileProtocol.Delete = UfsFileDelete;
    File->FileProtocol.Read = UfsFileRead;
    File->FileProtocol.Write = UfsFileWrite;
    File->FileProtocol.GetPosition = UfsFileGetPosition;
    File->FileProtocol.SetPosition = UfsFileSetPosition;
    File->FileProtocol.GetInfo = UfsFileGetInfo;
    File->FileProtocol.SetInfo = UfsFileSetInfo;
    File->FileProtocol.Flush = UfsFileFlush;

    *Root = &File->FileProtocol;

    EfiReleaseLock(&Volume->Lock);
    return EFI_SUCCESS;
}

// ============================================================================
// Simple File System Protocol
// ============================================================================

EFI_SIMPLE_FILE_SYSTEM_PROTOCOL g_UfsSimpleFsProtocol = {
    .Revision = EFI_SIMPLE_FILE_SYSTEM_PROTOCOL_REVISION,
    .OpenVolume = UfsSimpleFsOpenVolume
};