// UFS UEFI Driver - C Implementation
// UEFI 2.10+ Driver Binding Protocol, Block I/O, Disk I/O, Simple FS

#include <Uefi.h>
#include <Library/UefiLib.h>
#include <Library/UefiBootServicesTableLib.h>
#include <Library/UefiRuntimeServicesTableLib.h>
#include <Library/BaseMemoryLib.h>
#include <Library/MemoryAllocationLib.h>
#include <Library/DebugLib.h>
#include <Library/DevicePathLib.h>
#include <Library/BaseLib.h>
#include <Protocol/BlockIo.h>
#include <Protocol/DiskIo.h>
#include <Protocol/DiskIo2.h>
#include <Protocol/SimpleFileSystem.h>
#include <Protocol/DriverBinding.h>
#include <Protocol/ComponentName.h>
#include <Protocol/ComponentName2.h>
#include <Protocol/DevicePath.h>
#include <Guid/FileInfo.h>

#include "ufs.h"

// ============================================================================
// Driver Global State
// ============================================================================

EFI_DRIVER_BINDING_PROTOCOL g_UfsDriverBinding = {
    .Supported = UfsDriverBindingSupported,
    .Start = UfsDriverBindingStart,
    .Stop = UfsDriverBindingStop,
    .Version = 0x10,
    .ImageHandle = NULL,
    .DriverBindingHandle = NULL
};

EFI_COMPONENT_NAME2_PROTOCOL g_UfsComponentName2 = {
    .GetDriverName = UfsComponentNameGetDriverName,
    .GetControllerName = UfsComponentNameGetControllerName,
    .SupportedLanguages = "en"
};

EFI_COMPONENT_NAME_PROTOCOL g_UfsComponentName = {
    .GetDriverName = UfsComponentNameGetDriverName,
    .GetControllerName = UfsComponentNameGetControllerName,
    .SupportedLanguages = "eng"
};

// ============================================================================
// UFS Volume Context
// ============================================================================

typedef struct _UFS_VOLUME {
    // Signature for validation
    UINT32 Signature;
    #define UFS_VOLUME_SIGNATURE SIGNATURE_32('U','F','S','V')

    // Handles
    EFI_HANDLE Handle;
    EFI_BLOCK_IO_PROTOCOL* BlockIo;
    EFI_DISK_IO_PROTOCOL* DiskIo;
    EFI_DISK_IO2_PROTOCOL* DiskIo2;
    EFI_DEVICE_PATH_PROTOCOL* DevicePath;

    // UFS Core filesystem
    UFS_FS_HANDLE* FsHandle;
    UFS_BLOCK_DEVICE_HANDLE* BlockDevHandle;

    // Simple File System Protocol
    EFI_SIMPLE_FILE_SYSTEM_PROTOCOL SimpleFs;

    // Volume info
    EFI_GUID VolumeGuid;
    CHAR16 VolumeLabel[256];
    UINT64 VolumeSize;
    UINT32 BlockSize;
    UINT32 ClusterSize;
    BOOLEAN ReadOnly;
    BOOLEAN CaseInsensitive;
    UINT8 Compression;
    BOOLEAN IntegrityCheck;

    // Root directory
    EFI_FILE_PROTOCOL* RootFile;

    // Lock
    EFI_LOCK Lock;

    // Reference count
    UINTN RefCount;
} UFS_VOLUME;

// ============================================================================
// UFS File Context
// ============================================================================

typedef struct _UFS_FILE {
    UINT32 Signature;
    #define UFS_FILE_SIGNATURE SIGNATURE_32('U','F','S','F')

    UFS_VOLUME* Volume;
    UFS_FILE_HANDLE* FileHandle;
    UINT64 InodeNumber;
    UINT64 Position;
    BOOLEAN IsDirectory;
    BOOLEAN IsRoot;
    BOOLEAN WriteMode;
    BOOLEAN DeleteOnClose;

    // Directory enumeration
    UFS_DIR_ITERATOR_HANDLE* DirIterHandle;
    BOOLEAN DirIterValid;

    // File info cache
    EFI_FILE_INFO FileInfo;
    BOOLEAN FileInfoValid;

    // Lock
    EFI_LOCK Lock;

    // Reference count
    UINTN RefCount;
} UFS_FILE;

// ============================================================================
// Block Device Protocol Implementation (for UFS Core)
// ============================================================================

typedef struct _UFS_BLOCK_DEVICE {
    UFS_VOLUME* Volume;
} UFS_BLOCK_DEVICE;

EFI_STATUS UfsBlockDeviceRead(UFS_BLOCK_DEVICE_HANDLE* Handle, UINT64 Lba, VOID* Buffer, UINTN Size) {
    UFS_BLOCK_DEVICE* Dev = (UFS_BLOCK_DEVICE*)Handle;
    UFS_VOLUME* Volume = Dev->Volume;
    UINTN Blocks = Size / Volume->BlockSize;
    return Volume->BlockIo->ReadBlocks(Volume->BlockIo, Volume->BlockIo->Media->MediaId, Lba, Size, Buffer);
}

EFI_STATUS UfsBlockDeviceWrite(UFS_BLOCK_DEVICE_HANDLE* Handle, UINT64 Lba, VOID* Buffer, UINTN Size) {
    UFS_BLOCK_DEVICE* Dev = (UFS_BLOCK_DEVICE*)Handle;
    UFS_VOLUME* Volume = Dev->Volume;
    if (Volume->ReadOnly) return EFI_WRITE_PROTECTED;
    UINTN Blocks = Size / Volume->BlockSize;
    return Volume->BlockIo->WriteBlocks(Volume->BlockIo, Volume->BlockIo->Media->MediaId, Lba, Size, Buffer);
}

EFI_STATUS UfsBlockDeviceFlush(UFS_BLOCK_DEVICE_HANDLE* Handle) {
    UFS_BLOCK_DEVICE* Dev = (UFS_BLOCK_DEVICE*)Handle;
    UFS_VOLUME* Volume = Dev->Volume;
    return Volume->BlockIo->FlushBlocks(Volume->BlockIo);
}

EFI_STATUS UfsBlockDeviceGetInfo(UFS_BLOCK_DEVICE_HANDLE* Handle, UFS_BLOCK_DEVICE_INFO* Info) {
    UFS_BLOCK_DEVICE* Dev = (UFS_BLOCK_DEVICE*)Handle;
    UFS_VOLUME* Volume = Dev->Volume;
    Info->BlockSize = Volume->BlockSize;
    Info->TotalBlocks = Volume->VolumeSize / Volume->BlockSize;
    Info->OptimalTransferSize = Volume->BlockIo->Media->IoAlign;
    return EFI_SUCCESS;
}

UFS_BLOCK_DEVICE_OPS g_UfsBlockDeviceOps = {
    .Read = UfsBlockDeviceRead,
    .Write = UfsBlockDeviceWrite,
    .Flush = UfsBlockDeviceFlush,
    .GetInfo = UfsBlockDeviceGetInfo
};

// ============================================================================
// Driver Binding Protocol
// ============================================================================

EFI_STATUS EFIAPI UfsDriverBindingSupported(
    IN EFI_DRIVER_BINDING_PROTOCOL* This,
    IN EFI_HANDLE ControllerHandle,
    IN EFI_DEVICE_PATH_PROTOCOL* RemainingDevicePath
) {
    EFI_STATUS Status;
    EFI_BLOCK_IO_PROTOCOL* BlockIo;

    // Check for Block I/O protocol
    Status = gBS->OpenProtocol(ControllerHandle, &gEfiBlockIoProtocolGuid,
                               (VOID**)&BlockIo, This->DriverBindingHandle,
                               ControllerHandle, EFI_OPEN_PROTOCOL_BY_DRIVER);
    if (EFI_ERROR(Status)) {
        return Status;
    }

    // Check if it's a valid block device
    if (!BlockIo->Media->MediaPresent || BlockIo->Media->LogicalPartition) {
        gBS->CloseProtocol(ControllerHandle, &gEfiBlockIoProtocolGuid,
                           This->DriverBindingHandle, ControllerHandle);
        return EFI_UNSUPPORTED;
    }

    gBS->CloseProtocol(ControllerHandle, &gEfiBlockIoProtocolGuid,
                       This->DriverBindingHandle, ControllerHandle);

    return EFI_SUCCESS;
}

EFI_STATUS EFIAPI UfsDriverBindingStart(
    IN EFI_DRIVER_BINDING_PROTOCOL* This,
    IN EFI_HANDLE ControllerHandle,
    IN EFI_DEVICE_PATH_PROTOCOL* RemainingDevicePath
) {
    EFI_STATUS Status;
    EFI_BLOCK_IO_PROTOCOL* BlockIo;
    EFI_DISK_IO_PROTOCOL* DiskIo;
    EFI_DISK_IO2_PROTOCOL* DiskIo2;
    EFI_DEVICE_PATH_PROTOCOL* DevicePath;
    UFS_VOLUME* Volume;

    // Open protocols
    Status = gBS->OpenProtocol(ControllerHandle, &gEfiBlockIoProtocolGuid,
                               (VOID**)&BlockIo, This->DriverBindingHandle,
                               ControllerHandle, EFI_OPEN_PROTOCOL_BY_DRIVER);
    if (EFI_ERROR(Status)) return Status;

    Status = gBS->OpenProtocol(ControllerHandle, &gEfiDiskIoProtocolGuid,
                               (VOID**)&DiskIo, This->DriverBindingHandle,
                               ControllerHandle, EFI_OPEN_PROTOCOL_BY_DRIVER);
    if (EFI_ERROR(Status)) {
        gBS->CloseProtocol(ControllerHandle, &gEfiBlockIoProtocolGuid,
                           This->DriverBindingHandle, ControllerHandle);
        return Status;
    }

    Status = gBS->OpenProtocol(ControllerHandle, &gEfiDiskIo2ProtocolGuid,
                               (VOID**)&DiskIo2, This->DriverBindingHandle,
                               ControllerHandle, EFI_OPEN_PROTOCOL_BY_DRIVER);
    // DiskIo2 is optional

    Status = gBS->OpenProtocol(ControllerHandle, &gEfiDevicePathProtocolGuid,
                               (VOID**)&DevicePath, This->DriverBindingHandle,
                               ControllerHandle, EFI_OPEN_PROTOCOL_BY_DRIVER);
    if (EFI_ERROR(Status)) {
        gBS->CloseProtocol(ControllerHandle, &gEfiBlockIoProtocolGuid,
                           This->DriverBindingHandle, ControllerHandle);
        gBS->CloseProtocol(ControllerHandle, &gEfiDiskIoProtocolGuid,
                           This->DriverBindingHandle, ControllerHandle);
        return Status;
    }

    // Allocate volume structure
    Volume = AllocateZeroPool(sizeof(UFS_VOLUME));
    if (!Volume) {
        Status = EFI_OUT_OF_RESOURCES;
        goto Error;
    }

    Volume->Signature = UFS_VOLUME_SIGNATURE;
    Volume->Handle = ControllerHandle;
    Volume->BlockIo = BlockIo;
    Volume->DiskIo = DiskIo;
    Volume->DiskIo2 = DiskIo2;
    Volume->DevicePath = DuplicateDevicePath(DevicePath);
    Volume->BlockSize = BlockIo->Media->BlockSize;
    Volume->VolumeSize = BlockIo->Media->LastBlock * BlockIo->Media->BlockSize;

    // Initialize lock
    EfiInitializeLock(&Volume->Lock, TPL_CALLBACK);

    // Create block device for UFS core
    UFS_BLOCK_DEVICE* BlockDev = AllocateZeroPool(sizeof(UFS_BLOCK_DEVICE));
    BlockDev->Volume = Volume;

    UFS_BLOCK_DEVICE_HANDLE* BlockDevHandle;
    Status = UfsBlockDeviceCreate(&g_UfsBlockDeviceOps, BlockDev, &BlockDevHandle);
    if (EFI_ERROR(Status)) {
        goto ErrorFreeVolume;
    }
    Volume->BlockDevHandle = BlockDevHandle;

    // Check if recovery needed
    if (UfsNeedsRecovery(BlockDevHandle)) {
        Status = UfsRecover(BlockDevHandle);
        if (EFI_ERROR(Status)) {
            DEBUG((DEBUG_ERROR, "UFS: Recovery failed: %r\n", Status));
            goto ErrorCloseBlockDev;
        }
    }

    // Mount filesystem
    UFS_MOUNT_OPTIONS MountOpts = {
        .ReadOnly = Volume->ReadOnly,
        .CaseInsensitive = Volume->CaseInsensitive,
        .Compression = Volume->Compression,
        .IntegrityCheck = Volume->IntegrityCheck,
        .JournalSize = 0
    };

    Status = UfsMount(BlockDevHandle, &MountOpts, &Volume->FsHandle);
    if (EFI_ERROR(Status)) {
        DEBUG((DEBUG_ERROR, "UFS: Mount failed: %r\n", Status));
        goto ErrorCloseBlockDev;
    }

    // Get volume info
    UFS_STATFS_INFO StatFs;
    Status = UfsStatFs(Volume->FsHandle, &StatFs);
    if (!EFI_ERROR(Status)) {
        Volume->ClusterSize = StatFs.ClusterSize;
    }

    // Initialize Simple File System Protocol
    Volume->SimpleFs.Revision = EFI_SIMPLE_FILE_SYSTEM_PROTOCOL_REVISION;
    Volume->SimpleFs.OpenVolume = UfsSimpleFsOpenVolume;

    // Install Simple File System Protocol
    Status = gBS->InstallMultipleProtocolInterfaces(&ControllerHandle,
                                                    &gEfiSimpleFileSystemProtocolGuid, &Volume->SimpleFs,
                                                    NULL);
    if (EFI_ERROR(Status)) {
        DEBUG((DEBUG_ERROR, "UFS: Failed to install SimpleFS: %r\n", Status));
        goto ErrorUnmount;
    }

    // Open root directory
    EFI_FILE_PROTOCOL* RootFile;
    Status = Volume->SimpleFs.OpenVolume(&Volume->SimpleFs, &RootFile);
    if (EFI_ERROR(Status)) {
        DEBUG((DEBUG_ERROR, "UFS: Failed to open root: %r\n", Status));
        goto ErrorUninstallProtocol;
    }
    Volume->RootFile = RootFile;

    DEBUG((DEBUG_INFO, "UFS: Volume started on handle %p\n", ControllerHandle));
    return EFI_SUCCESS;

ErrorUninstallProtocol:
    gBS->UninstallMultipleProtocolInterfaces(ControllerHandle,
                                             &gEfiSimpleFileSystemProtocolGuid, &Volume->SimpleFs,
                                             NULL);
ErrorUnmount:
    UfsUnmount(Volume->FsHandle);
ErrorCloseBlockDev:
    UfsBlockDeviceClose(Volume->BlockDevHandle);
ErrorFreeVolume:
    if (Volume->DevicePath) FreePool(Volume->DevicePath);
    FreePool(Volume);
Error:
    if (DiskIo2) {
        gBS->CloseProtocol(ControllerHandle, &gEfiDiskIo2ProtocolGuid,
                           This->DriverBindingHandle, ControllerHandle);
    }
    gBS->CloseProtocol(ControllerHandle, &gEfiDiskIoProtocolGuid,
                       This->DriverBindingHandle, ControllerHandle);
    gBS->CloseProtocol(ControllerHandle, &gEfiBlockIoProtocolGuid,
                       This->DriverBindingHandle, ControllerHandle);
    return Status;
}

EFI_STATUS EFIAPI UfsDriverBindingStop(
    IN EFI_DRIVER_BINDING_PROTOCOL* This,
    IN EFI_HANDLE ControllerHandle,
    IN UINTN NumberOfChildren,
    IN EFI_HANDLE* ChildHandleBuffer
) {
    EFI_STATUS Status;
    EFI_SIMPLE_FILE_SYSTEM_PROTOCOL* SimpleFs;
    UFS_VOLUME* Volume;

    // Get our volume context
    Status = gBS->OpenProtocol(ControllerHandle, &gEfiSimpleFileSystemProtocolGuid,
                               (VOID**)&SimpleFs, This->DriverBindingHandle,
                               ControllerHandle, EFI_OPEN_PROTOCOL_GET_PROTOCOL);
    if (EFI_ERROR(Status)) return Status;

    Volume = BASE_CR(SimpleFs, UFS_VOLUME, SimpleFs);
    if (Volume->Signature != UFS_VOLUME_SIGNATURE) return EFI_INVALID_PARAMETER;

    // Uninstall protocols
    gBS->UninstallMultipleProtocolInterfaces(ControllerHandle,
                                             &gEfiSimpleFileSystemProtocolGuid, &Volume->SimpleFs,
                                             NULL);

    // Close root file
    if (Volume->RootFile) {
        Volume->RootFile->Close(Volume->RootFile);
    }

    // Unmount filesystem
    UfsUnmount(Volume->FsHandle);
    Volume->FsHandle = NULL;

    // Close block device
    UfsBlockDeviceClose(Volume->BlockDevHandle);
    Volume->BlockDevHandle = NULL;

    // Close protocols
    gBS->CloseProtocol(ControllerHandle, &gEfiBlockIoProtocolGuid,
                       This->DriverBindingHandle, ControllerHandle);
    gBS->CloseProtocol(ControllerHandle, &gEfiDiskIoProtocolGuid,
                       This->DriverBindingHandle, ControllerHandle);
    if (Volume->DiskIo2) {
        gBS->CloseProtocol(ControllerHandle, &gEfiDiskIo2ProtocolGuid,
                           This->DriverBindingHandle, ControllerHandle);
    }

    // Free resources
    if (Volume->DevicePath) FreePool(Volume->DevicePath);
    FreePool(Volume);

    return EFI_SUCCESS;
}

// ============================================================================
// Simple File System Protocol
// ============================================================================

EFI_STATUS EFIAPI UfsSimpleFsOpenVolume(
    IN EFI_SIMPLE_FILE_SYSTEM_PROTOCOL* This,
    OUT EFI_FILE_PROTOCOL** Root
) {
    UFS_VOLUME* Volume = BASE_CR(This, UFS_VOLUME, SimpleFs);
    UFS_FILE* File = AllocateZeroPool(sizeof(UFS_FILE));
    if (!File) return EFI_OUT_OF_RESOURCES;

    File->Signature = UFS_FILE_SIGNATURE;
    File->Volume = Volume;
    File->InodeNumber = 2; // Root inode
    File->IsDirectory = TRUE;
    File->IsRoot = TRUE;
    File->Position = 0;
    EfiInitializeLock(&File->Lock, TPL_CALLBACK);

    // Open file via UFS core
    EFI_STATUS Status = UfsOpenFile(Volume->FsHandle, 2, UFS_OPEN_READ | UFS_OPEN_DIRECTORY, &File->FileHandle);
    if (EFI_ERROR(Status)) {
        FreePool(File);
        return Status;
    }

    // Initialize file protocol
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
    return EFI_SUCCESS;
}

// ============================================================================
// File Protocol Implementation
// ============================================================================

EFI_STATUS EFIAPI UfsFileOpen(
    IN EFI_FILE_PROTOCOL* This,
    OUT EFI_FILE_PROTOCOL** NewHandle,
    IN CHAR16* FileName,
    IN UINT64 OpenMode,
    IN UINT64 Attributes
) {
    UFS_FILE* File = BASE_CR(This, UFS_FILE, FileProtocol);
    UFS_VOLUME* Volume = File->Volume;
    EFI_STATUS Status;

    if (!File->IsDirectory) return EFI_NOT_FOUND;

    // Convert filename to UTF-8
    CHAR8 AsciiName[256];
    UINTN AsciiSize = sizeof(AsciiName);
    UnicodeStrToAsciiStrS(FileName, AsciiName, AsciiSize);

    // Lookup inode
    UINT64 InodeNumber;
    Status = UfsLookup(Volume->FsHandle, File->InodeNumber, AsciiName, &InodeNumber);
    if (EFI_ERROR(Status)) {
        if (Status == EFI_NOT_FOUND && (OpenMode & EFI_FILE_MODE_CREATE)) {
            // Create new file
            UFS_FILE_TYPE Type = (OpenMode & EFI_FILE_MODE_DIRECTORY) ? UFS_FILE_TYPE_DIR : UFS_FILE_TYPE_REG;
            Status = UfsCreateInode(Volume->FsHandle, File->InodeNumber, AsciiName, Type, 0644, 0, 0, &InodeNumber);
        }
        if (EFI_ERROR(Status)) return Status;
    }

    // Create new file handle
    UFS_FILE* NewFile = AllocateZeroPool(sizeof(UFS_FILE));
    if (!NewFile) return EFI_OUT_OF_RESOURCES;

    NewFile->Signature = UFS_FILE_SIGNATURE;
    NewFile->Volume = Volume;
    NewFile->InodeNumber = InodeNumber;
    NewFile->IsDirectory = (OpenMode & EFI_FILE_MODE_DIRECTORY) != 0;
    NewFile->WriteMode = (OpenMode & EFI_FILE_MODE_WRITE) != 0;
    NewFile->Position = 0;
    EfiInitializeLock(&NewFile->Lock, TPL_CALLBACK);

    // Open via UFS core
    UINT32 UfsOpenMode = 0;
    if (NewFile->IsDirectory) UfsOpenMode |= UFS_OPEN_DIRECTORY;
    if (NewFile->WriteMode) UfsOpenMode |= UFS_OPEN_WRITE;
    else UfsOpenMode |= UFS_OPEN_READ;

    Status = UfsOpenFile(Volume->FsHandle, InodeNumber, UfsOpenMode, &NewFile->FileHandle);
    if (EFI_ERROR(Status)) {
        FreePool(NewFile);
        return Status;
    }

    // Initialize file protocol
    NewFile->FileProtocol.Revision = EFI_FILE_PROTOCOL_REVISION;
    NewFile->FileProtocol.Open = UfsFileOpen;
    NewFile->FileProtocol.Close = UfsFileClose;
    NewFile->FileProtocol.Delete = UfsFileDelete;
    NewFile->FileProtocol.Read = UfsFileRead;
    NewFile->FileProtocol.Write = UfsFileWrite;
    NewFile->FileProtocol.GetPosition = UfsFileGetPosition;
    NewFile->FileProtocol.SetPosition = UfsFileSetPosition;
    NewFile->FileProtocol.GetInfo = UfsFileGetInfo;
    NewFile->FileProtocol.SetInfo = UfsFileSetInfo;
    NewFile->FileProtocol.Flush = UfsFileFlush;

    *NewHandle = &NewFile->FileProtocol;
    return EFI_SUCCESS;
}

EFI_STATUS EFIAPI UfsFileClose(IN EFI_FILE_PROTOCOL* This) {
    UFS_FILE* File = BASE_CR(This, UFS_FILE, FileProtocol);

    if (File->FileHandle) {
        UfsCloseFile(File->FileHandle);
        File->FileHandle = NULL;
    }

    if (File->DirIterHandle) {
        UfsCloseDir(File->DirIterHandle);
        File->DirIterHandle = NULL;
    }

    FreePool(File);
    return EFI_SUCCESS;
}

EFI_STATUS EFIAPI UfsFileDelete(IN EFI_FILE_PROTOCOL* This) {
    UFS_FILE* File = BASE_CR(This, UFS_FILE, FileProtocol);
    UFS_VOLUME* Volume = File->Volume;

    if (Volume->ReadOnly) return EFI_WRITE_PROTECTED;

    // Close file first
    if (File->FileHandle) {
        UfsCloseFile(File->FileHandle);
        File->FileHandle = NULL;
    }

    // Delete inode (need parent inode - simplified)
    // In real implementation, we'd track parent
    return EFI_UNSUPPORTED;
}

EFI_STATUS EFIAPI UfsFileRead(
    IN EFI_FILE_PROTOCOL* This,
    IN OUT UINTN* BufferSize,
    OUT VOID* Buffer
) {
    UFS_FILE* File = BASE_CR(This, UFS_FILE, FileProtocol);
    UFS_VOLUME* Volume = File->Volume;

    if (File->IsDirectory) return EFI_UNSUPPORTED;

    UINT64 BytesRead;
    EFI_STATUS Status = UfsReadFile(File->FileHandle, File->Position, Buffer, *BufferSize, &BytesRead);
    if (EFI_ERROR(Status)) {
        *BufferSize = 0;
        return Status;
    }

    File->Position += BytesRead;
    *BufferSize = (UINTN)BytesRead;
    return EFI_SUCCESS;
}

EFI_STATUS EFIAPI UfsFileWrite(
    IN EFI_FILE_PROTOCOL* This,
    IN OUT UINTN* BufferSize,
    IN VOID* Buffer
) {
    UFS_FILE* File = BASE_CR(This, UFS_FILE, FileProtocol);
    UFS_VOLUME* Volume = File->Volume;

    if (Volume->ReadOnly) return EFI_WRITE_PROTECTED;
    if (File->IsDirectory) return EFI_UNSUPPORTED;
    if (!File->WriteMode) return EFI_ACCESS_DENIED;

    UINT64 BytesWritten;
    EFI_STATUS Status = UfsWriteFile(File->FileHandle, File->Position, Buffer, *BufferSize, &BytesWritten);
    if (EFI_ERROR(Status)) {
        *BufferSize = 0;
        return Status;
    }

    File->Position += BytesWritten;
    *BufferSize = (UINTN)BytesWritten;
    return EFI_SUCCESS;
}

EFI_STATUS EFIAPI UfsFileGetPosition(
    IN EFI_FILE_PROTOCOL* This,
    OUT UINT64* Position
) {
    UFS_FILE* File = BASE_CR(This, UFS_FILE, FileProtocol);
    *Position = File->Position;
    return EFI_SUCCESS;
}

EFI_STATUS EFIAPI UfsFileSetPosition(
    IN EFI_FILE_PROTOCOL* This,
    IN UINT64 Position
) {
    UFS_FILE* File = BASE_CR(This, UFS_FILE, FileProtocol);
    File->Position = Position;
    return EFI_SUCCESS;
}

EFI_STATUS EFIAPI UfsFileGetInfo(
    IN EFI_FILE_PROTOCOL* This,
    IN EFI_GUID* InformationType,
    IN OUT UINTN* BufferSize,
    OUT VOID* Buffer
) {
    UFS_FILE* File = BASE_CR(This, UFS_FILE, FileProtocol);
    UFS_VOLUME* Volume = File->Volume;

    if (!CompareGuid(InformationType, &gEfiFileInfoGuid)) {
        return EFI_UNSUPPORTED;
    }

    // Get file info from UFS core if not cached
    if (!File->FileInfoValid) {
        UFS_INODE_INFO InodeInfo;
        EFI_STATUS Status = UfsGetAttr(Volume->FsHandle, File->InodeNumber, &InodeInfo);
        if (EFI_ERROR(Status)) return Status;

        File->FileInfo.Size = sizeof(EFI_FILE_INFO) + StrSize(File->FileInfo.FileName);
        File->FileInfo.FileSize = InodeInfo.FileSize;
        File->FileInfo.PhysicalSize = InodeInfo.AllocatedSize;
        File->FileInfo.CreateTime = EfiTimeToEfiTime(InodeInfo.CreationTime);
        File->FileInfo.LastAccessTime = EfiTimeToEfiTime(InodeInfo.LastAccessTime);
        File->FileInfo.ModificationTime = EfiTimeToEfiTime(InodeInfo.LastWriteTime);
        File->FileInfo.Attribute = InodeInfo.Attributes;
        File->FileInfoValid = TRUE;
    }

    UINTN RequiredSize = File->FileInfo.Size;
    if (*BufferSize < RequiredSize) {
        *BufferSize = RequiredSize;
        return EFI_BUFFER_TOO_SMALL;
    }

    CopyMem(Buffer, &File->FileInfo, RequiredSize);
    *BufferSize = RequiredSize;
    return EFI_SUCCESS;
}

EFI_STATUS EFIAPI UfsFileSetInfo(
    IN EFI_FILE_PROTOCOL* This,
    IN EFI_GUID* InformationType,
    IN UINTN BufferSize,
    IN VOID* Buffer
) {
    UFS_FILE* File = BASE_CR(This, UFS_FILE, FileProtocol);
    UFS_VOLUME* Volume = File->Volume;

    if (Volume->ReadOnly) return EFI_WRITE_PROTECTED;

    if (CompareGuid(InformationType, &gEfiFileInfoGuid)) {
        EFI_FILE_INFO* Info = Buffer;
        // Update timestamps, attributes
        File->FileInfo = *Info;
        File->FileInfoValid = TRUE;

        // Sync to UFS core
        UFS_INODE_INFO InodeInfo;
        UfsGetAttr(Volume->FsHandle, File->InodeNumber, &InodeInfo);
        InodeInfo.FileSize = Info->FileSize;
        InodeInfo.Attributes = Info->Attribute;
        // ... convert times
        UfsSetAttr(Volume->FsHandle, File->InodeNumber, &InodeInfo, UFS_ATTR_SIZE | UFS_ATTR_ATTR);
    }

    return EFI_SUCCESS;
}

EFI_STATUS EFIAPI UfsFileFlush(IN EFI_FILE_PROTOCOL* This) {
    UFS_FILE* File = BASE_CR(This, UFS_FILE, FileProtocol);
    UFS_VOLUME* Volume = File->Volume;

    if (File->FileHandle) {
        return UfsFlushFile(File->FileHandle);
    }

    return EFI_SUCCESS;
}

// ============================================================================
// Component Name Protocol
// ============================================================================

EFI_STATUS EFIAPI UfsComponentNameGetDriverName(
    IN EFI_COMPONENT_NAME_PROTOCOL* This,
    IN CHAR8* Language,
    OUT CHAR16** DriverName
) {
    *DriverName = AllocateCopyPool(StrSize(L"UFS Filesystem Driver"), L"UFS Filesystem Driver");
    return *DriverName ? EFI_SUCCESS : EFI_OUT_OF_RESOURCES;
}

EFI_STATUS EFIAPI UfsComponentNameGetControllerName(
    IN EFI_COMPONENT_NAME_PROTOCOL* This,
    IN EFI_HANDLE ControllerHandle,
    IN EFI_HANDLE ChildHandle OPTIONAL,
    IN CHAR8* Language,
    OUT CHAR16** ControllerName
) {
    *ControllerName = AllocateCopyPool(StrSize(L"UFS Volume"), L"UFS Volume");
    return *ControllerName ? EFI_SUCCESS : EFI_OUT_OF_RESOURCES;
}

// ============================================================================
// Driver Entry Point
// ============================================================================

EFI_STATUS EFIAPI UfsDriverEntryPoint(
    IN EFI_HANDLE ImageHandle,
    IN EFI_SYSTEM_TABLE* SystemTable
) {
    EFI_STATUS Status;

    // Install Driver Binding Protocol
    g_UfsDriverBinding.ImageHandle = ImageHandle;
    Status = gBS->InstallMultipleProtocolInterfaces(&ImageHandle,
                                                    &gEfiDriverBindingProtocolGuid, &g_UfsDriverBinding,
                                                    &gEfiComponentName2ProtocolGuid, &g_UfsComponentName2,
                                                    &gEfiComponentNameProtocolGuid, &g_UfsComponentName,
                                                    NULL);

    if (EFI_ERROR(Status)) {
        return Status;
    }

    DEBUG((DEBUG_INFO, "UFS UEFI Driver loaded\n"));
    return EFI_SUCCESS;
}

// ============================================================================
// Helper Functions
// ============================================================================

EFI_TIME EfiTimeToEfiTime(UFS_TIMESTAMP UfsTime) {
    EFI_TIME Time = {0};
    UINT64 Secs = UfsTime / 1000000000;
    UINT64 Nanos = UfsTime % 1000000000;

    // Convert from Unix epoch (1970) to UEFI epoch (1998)
    // Simplified - use proper time conversion
    Time.Year = 1970 + (Secs / 31536000);
    Secs %= 31536000;
    Time.Month = 1 + (Secs / 2592000);
    Secs %= 2592000;
    Time.Day = 1 + (Secs / 86400);
    Secs %= 86400;
    Time.Hour = Secs / 3600;
    Secs %= 3600;
    Time.Minute = Secs / 60;
    Time.Second = Secs % 60;
    Time.Nanosecond = (UINT32)Nanos;

    return Time;
}