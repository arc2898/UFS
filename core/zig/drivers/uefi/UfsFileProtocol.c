// UfsFileProtocol.c - UFS EFI_FILE_PROTOCOL Implementation
// Full file/directory operations for UEFI Simple File System

#include <Uefi.h>
#include <Library/UefiLib.h>
#include <Library/UefiBootServicesTableLib.h>
#include <Library/BaseMemoryLib.h>
#include <Library/MemoryAllocationLib.h>
#include <Library/DebugLib.h>
#include <Library/PrintLib.h>
#include <Library/DevicePathLib.h>
#include <Protocol/SimpleFileSystem.h>
#include <Guid/FileInfo.h>
#include <Guid/FileSystemInfo.h>
#include <Guid/FileSystemVolumeLabelInfo.h>

#include "ufs.h"

// ============================================================================
// File Protocol: Open
// ============================================================================

EFI_STATUS EFIAPI UfsFileOpen(
    IN EFI_FILE_PROTOCOL *This,
    OUT EFI_FILE_PROTOCOL **NewHandle,
    IN CHAR16 *FileName,
    IN UINT64 OpenMode,
    IN UINT64 Attributes
) {
    UFS_FILE *File = BASE_CR(This, UFS_FILE, FileProtocol);
    if (!File || File->Signature != UFS_FILE_SIGNATURE) {
        return EFI_INVALID_PARAMETER;
    }

    UFS_VOLUME *Volume = File->Volume;
    if (!Volume || Volume->Signature != UFS_VOLUME_SIGNATURE) {
        return EFI_INVALID_PARAMETER;
    }

    if (!File->IsDirectory) {
        return EFI_NOT_FOUND;
    }

    EfiAcquireLock(&Volume->Lock);

    // Convert filename to UTF-8
    CHAR8 AsciiName[256];
    UnicodeStrToAsciiStrS(FileName, AsciiName, sizeof(AsciiName));

    // Handle special names
    if (StrCmp(FileName, L".") == 0) {
        *NewHandle = This;
        EfiReleaseLock(&Volume->Lock);
        return EFI_SUCCESS;
    }

    if (StrCmp(FileName, L"..") == 0) {
        if (File->IsRoot) {
            *NewHandle = This;
        } else {
            // Need parent directory - simplified: return root
            *NewHandle = &Volume->RootFile;
        }
        EfiReleaseLock(&Volume->Lock);
        return EFI_SUCCESS;
    }

    // Lookup inode
    UINT64 InodeNumber;
    EFI_STATUS Status = UfsLookup(Volume->FsHandle, File->InodeNumber, AsciiName, &InodeNumber);

    // Create if not found and CREATE flag set
    if (Status == EFI_NOT_FOUND && (OpenMode & EFI_FILE_MODE_CREATE)) {
        UFS_FILE_TYPE Type = (OpenMode & EFI_FILE_MODE_DIRECTORY) ? UFS_FILE_TYPE_DIR : UFS_FILE_TYPE_REG;
        Status = UfsCreateInode(Volume->FsHandle, File->InodeNumber, AsciiName, Type, 0644, 0, 0, &InodeNumber);
    }

    if (EFI_ERROR(Status)) {
        EfiReleaseLock(&Volume->Lock);
        return Status;
    }

    // Create new file context
    UFS_FILE *NewFile = AllocateZeroPool(sizeof(UFS_FILE));
    if (!NewFile) {
        EfiReleaseLock(&Volume->Lock);
        return EFI_OUT_OF_RESOURCES;
    }

    NewFile->Signature = UFS_FILE_SIGNATURE;
    NewFile->Volume = Volume;
    NewFile->InodeNumber = InodeNumber;
    NewFile->IsDirectory = (OpenMode & EFI_FILE_MODE_DIRECTORY) != 0;
    NewFile->IsRoot = FALSE;
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
        EfiReleaseLock(&Volume->Lock);
        return Status;
    }

    // Initialize EFI_FILE_PROTOCOL
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

    EfiReleaseLock(&Volume->Lock);
    return EFI_SUCCESS;
}

// ============================================================================
// File Protocol: Close
// ============================================================================

EFI_STATUS EFIAPI UfsFileClose(IN EFI_FILE_PROTOCOL *This) {
    UFS_FILE *File = BASE_CR(This, UFS_FILE, FileProtocol);
    if (!File || File->Signature != UFS_FILE_SIGNATURE) {
        return EFI_INVALID_PARAMETER;
    }

    UFS_VOLUME *Volume = File->Volume;
    EfiAcquireLock(&Volume->Lock);

    if (File->FileHandle) {
        UfsCloseFile(File->FileHandle);
        File->FileHandle = NULL;
    }

    if (File->DirIterHandle) {
        UfsCloseDir(File->DirIterHandle);
        File->DirIterHandle = NULL;
    }

    FreePool(File);
    EfiReleaseLock(&Volume->Lock);
    return EFI_SUCCESS;
}

// ============================================================================
// File Protocol: Delete
// ============================================================================

EFI_STATUS EFIAPI UfsFileDelete(IN EFI_FILE_PROTOCOL *This) {
    UFS_FILE *File = BASE_CR(This, UFS_FILE, FileProtocol);
    if (!File || File->Signature != UFS_FILE_SIGNATURE) {
        return EFI_INVALID_PARAMETER;
    }

    UFS_VOLUME *Volume = File->Volume;
    if (Volume->ReadOnly) {
        return EFI_WRITE_PROTECTED;
    }

    EfiAcquireLock(&Volume->Lock);

    // Close file first
    if (File->FileHandle) {
        UfsCloseFile(File->FileHandle);
        File->FileHandle = NULL;
    }

    // In a real implementation, we'd need the parent directory and name
    // For now, return unsupported - requires tracking parent
    EfiReleaseLock(&Volume->Lock);
    return EFI_UNSUPPORTED;
}

// ============================================================================
// File Protocol: Read
// ============================================================================

EFI_STATUS EFIAPI UfsFileRead(
    IN EFI_FILE_PROTOCOL *This,
    IN OUT UINTN *BufferSize,
    OUT VOID *Buffer
) {
    UFS_FILE *File = BASE_CR(This, UFS_FILE, FileProtocol);
    if (!File || File->Signature != UFS_FILE_SIGNATURE) {
        return EFI_INVALID_PARAMETER;
    }

    if (File->IsDirectory) {
        return EFI_UNSUPPORTED;
    }

    UFS_VOLUME *Volume = File->Volume;
    EfiAcquireLock(&Volume->Lock);

    UINT64 BytesRead;
    EFI_STATUS Status = UfsReadFile(
        File->FileHandle,
        File->Position,
        Buffer,
        *BufferSize,
        &BytesRead
    );

    if (!EFI_ERROR(Status)) {
        File->Position += BytesRead;
        *BufferSize = (UINTN)BytesRead;
    } else {
        *BufferSize = 0;
    }

    EfiReleaseLock(&Volume->Lock);
    return Status;
}

// ============================================================================
// File Protocol: Write
// ============================================================================

EFI_STATUS EFIAPI UfsFileWrite(
    IN EFI_FILE_PROTOCOL *This,
    IN OUT UINTN *BufferSize,
    IN VOID *Buffer
) {
    UFS_FILE *File = BASE_CR(This, UFS_FILE, FileProtocol);
    if (!File || File->Signature != UFS_FILE_SIGNATURE) {
        return EFI_INVALID_PARAMETER;
    }

    UFS_VOLUME *Volume = File->Volume;
    if (Volume->ReadOnly) {
        return EFI_WRITE_PROTECTED;
    }

    if (File->IsDirectory) {
        return EFI_UNSUPPORTED;
    }

    if (!File->WriteMode) {
        return EFI_ACCESS_DENIED;
    }

    EfiAcquireLock(&Volume->Lock);

    UINT64 BytesWritten;
    EFI_STATUS Status = UfsWriteFile(
        File->FileHandle,
        File->Position,
        Buffer,
        *BufferSize,
        &BytesWritten
    );

    if (!EFI_ERROR(Status)) {
        File->Position += BytesWritten;
        *BufferSize = (UINTN)BytesWritten;
    } else {
        *BufferSize = 0;
    }

    EfiReleaseLock(&Volume->Lock);
    return Status;
}

// ============================================================================
// File Protocol: GetPosition
// ============================================================================

EFI_STATUS EFIAPI UfsFileGetPosition(
    IN EFI_FILE_PROTOCOL *This,
    OUT UINT64 *Position
) {
    UFS_FILE *File = BASE_CR(This, UFS_FILE, FileProtocol);
    if (!File || File->Signature != UFS_FILE_SIGNATURE) {
        return EFI_INVALID_PARAMETER;
    }

    *Position = File->Position;
    return EFI_SUCCESS;
}

// ============================================================================
// File Protocol: SetPosition
// ============================================================================

EFI_STATUS EFIAPI UfsFileSetPosition(
    IN EFI_FILE_PROTOCOL *This,
    IN UINT64 Position
) {
    UFS_FILE *File = BASE_CR(This, UFS_FILE, FileProtocol);
    if (!File || File->Signature != UFS_FILE_SIGNATURE) {
        return EFI_INVALID_PARAMETER;
    }

    File->Position = Position;
    return EFI_SUCCESS;
}

// ============================================================================
// File Protocol: GetInfo
// ============================================================================

EFI_STATUS EFIAPI UfsFileGetInfo(
    IN EFI_FILE_PROTOCOL *This,
    IN EFI_GUID *InformationType,
    IN OUT UINTN *BufferSize,
    OUT VOID *Buffer
) {
    UFS_FILE *File = BASE_CR(This, UFS_FILE, FileProtocol);
    if (!File || File->Signature != UFS_FILE_SIGNATURE) {
        return EFI_INVALID_PARAMETER;
    }

    UFS_VOLUME *Volume = File->Volume;
    EfiAcquireLock(&Volume->Lock);

    // EFI_FILE_INFO
    if (CompareGuid(InformationType, &gEfiFileInfoGuid)) {
        if (!File->FileInfoValid) {
            UFS_INODE_INFO InodeInfo;
            EFI_STATUS Status = UfsGetAttr(Volume->FsHandle, File->InodeNumber, &InodeInfo);
            if (EFI_ERROR(Status)) {
                EfiReleaseLock(&Volume->Lock);
                return Status;
            }

            // Build file info
            File->FileInfo.Size = sizeof(EFI_FILE_INFO) + StrSize(File->FileInfo.FileName);
            File->FileInfo.FileSize = InodeInfo.FileSize;
            File->FileInfo.PhysicalSize = InodeInfo.AllocatedSize;
            File->FileInfo.CreateTime = UfsTimeToEfiTime(InodeInfo.CreationTime);
            File->FileInfo.LastAccessTime = UfsTimeToEfiTime(InodeInfo.LastAccessTime);
            File->FileInfo.ModificationTime = UfsTimeToEfiTime(InodeInfo.LastWriteTime);
            File->FileInfo.Attribute = InodeInfo.Attributes;

            // Set filename
            if (File->IsRoot) {
                StrCpyS(File->FileInfo.FileName, sizeof(File->FileInfo.FileName) / sizeof(CHAR16), L"\\");
            }
            // In real impl, we'd track the name

            File->FileInfoValid = TRUE;
        }

        UINTN RequiredSize = File->FileInfo.Size;
        if (*BufferSize < RequiredSize) {
            *BufferSize = RequiredSize;
            EfiReleaseLock(&Volume->Lock);
            return EFI_BUFFER_TOO_SMALL;
        }

        CopyMem(Buffer, &File->FileInfo, RequiredSize);
        *BufferSize = RequiredSize;
        EfiReleaseLock(&Volume->Lock);
        return EFI_SUCCESS;
    }

    // EFI_FILE_SYSTEM_INFO
    if (CompareGuid(InformationType, &gEfiFileSystemInfoGuid)) {
        UFS_STATFS_INFO StatFs;
        EFI_STATUS Status = UfsStatFs(Volume->FsHandle, &StatFs);
        if (EFI_ERROR(Status)) {
            EfiReleaseLock(&Volume->Lock);
            return Status;
        }

        EFI_FILE_SYSTEM_INFO *Info = Buffer;
        UINTN RequiredSize = sizeof(EFI_FILE_SYSTEM_INFO);
        if (*BufferSize < RequiredSize) {
            *BufferSize = RequiredSize;
            EfiReleaseLock(&Volume->Lock);
            return EFI_BUFFER_TOO_SMALL;
        }

        Info->Size = RequiredSize;
        Info->ReadOnly = Volume->ReadOnly;
        Info->VolumeSize = StatFs.TotalSpace;
        Info->FreeSpace = StatFs.FreeSpace;
        Info->BlockSize = StatFs.ClusterSize;

        CopyMem(Buffer, Info, RequiredSize);
        *BufferSize = RequiredSize;
        EfiReleaseLock(&Volume->Lock);
        return EFI_SUCCESS;
    }

    // EFI_FILE_SYSTEM_VOLUME_LABEL_INFO
    if (CompareGuid(InformationType, &gEfiFileSystemVolumeLabelInfoGuid)) {
        EFI_FILE_SYSTEM_VOLUME_LABEL_INFO *Info = Buffer;
        UINTN RequiredSize = sizeof(EFI_FILE_SYSTEM_VOLUME_LABEL_INFO) + StrSize(Volume->VolumeLabel);
        if (*BufferSize < RequiredSize) {
            *BufferSize = RequiredSize;
            EfiReleaseLock(&Volume->Lock);
            return EFI_BUFFER_TOO_SMALL;
        }

        Info->Size = RequiredSize;
        StrCpyS(Info->VolumeLabel, sizeof(Volume->VolumeLabel) / sizeof(CHAR16), Volume->VolumeLabel);

        CopyMem(Buffer, Info, RequiredSize);
        *BufferSize = RequiredSize;
        EfiReleaseLock(&Volume->Lock);
        return EFI_SUCCESS;
    }

    EfiReleaseLock(&Volume->Lock);
    return EFI_UNSUPPORTED;
}

// ============================================================================
// File Protocol: SetInfo
// ============================================================================

EFI_STATUS EFIAPI UfsFileSetInfo(
    IN EFI_FILE_PROTOCOL *This,
    IN EFI_GUID *InformationType,
    IN UINTN BufferSize,
    IN VOID *Buffer
) {
    UFS_FILE *File = BASE_CR(This, UFS_FILE, FileProtocol);
    if (!File || File->Signature != UFS_FILE_SIGNATURE) {
        return EFI_INVALID_PARAMETER;
    }

    UFS_VOLUME *Volume = File->Volume;
    if (Volume->ReadOnly) {
        return EFI_WRITE_PROTECTED;
    }

    EfiAcquireLock(&Volume->Lock);

    if (CompareGuid(InformationType, &gEfiFileInfoGuid)) {
        EFI_FILE_INFO *Info = Buffer;

        UFS_INODE_INFO InodeInfo;
        UfsGetAttr(Volume->FsHandle, File->InodeNumber, &InodeInfo);

        // Update size if provided
        if (Info->FileSize != InodeInfo.FileSize) {
            InodeInfo.FileSize = Info->FileSize;
            UfsSetAttr(Volume->FsHandle, File->InodeNumber, &InodeInfo, UFS_ATTR_SIZE);
        }

        // Update attributes
        InodeInfo.Attributes = Info->Attribute;
        UfsSetAttr(Volume->FsHandle, File->InodeNumber, &InodeInfo, UFS_ATTR_ATTR);

        // Update timestamps (convert from EFI_TIME)
        // InodeInfo.CreationTime = EfiTimeToUfsTime(Info->CreateTime);
        // InodeInfo.LastAccessTime = EfiTimeToUfsTime(Info->LastAccessTime);
        // InodeInfo.LastWriteTime = EfiTimeToUfsTime(Info->ModificationTime);

        File->FileInfo = *Info;
        File->FileInfoValid = TRUE;
    }

    EfiReleaseLock(&Volume->Lock);
    return EFI_SUCCESS;
}

// ============================================================================
// File Protocol: Flush
// ============================================================================

EFI_STATUS EFIAPI UfsFileFlush(IN EFI_FILE_PROTOCOL *This) {
    UFS_FILE *File = BASE_CR(This, UFS_FILE, FileProtocol);
    if (!File || File->Signature != UFS_FILE_SIGNATURE) {
        return EFI_INVALID_PARAMETER;
    }

    UFS_VOLUME *Volume = File->Volume;
    EfiAcquireLock(&Volume->Lock);

    EFI_STATUS Status = EFI_SUCCESS;
    if (File->FileHandle) {
        Status = UfsFlushFile(File->FileHandle);
    }

    EfiReleaseLock(&Volume->Lock);
    return Status;
}

// ============================================================================
// Time Conversion Helpers
// ============================================================================

EFI_TIME UfsTimeToEfiTime(UFS_TIMESTAMP UfsTime) {
    EFI_TIME Time = {0};
    UINT64 Secs = UfsTime / 1000000000;
    UINT64 Nanos = UfsTime % 1000000000;

    // Unix epoch (1970-01-01) to UEFI time
    // Days since 1970
    UINT64 Days = Secs / 86400;
    Secs %= 86400;

    // Approximate year (real impl would use proper calendar)
    Time.Year = 1970 + (Days / 365);
    Days %= 365;
    Time.Month = 1 + (Days / 30);
    Days %= 30;
    Time.Day = 1 + Days;

    Time.Hour = Secs / 3600;
    Secs %= 3600;
    Time.Minute = Secs / 60;
    Time.Second = Secs % 60;
    Time.Nanosecond = (UINT32)Nanos;
    Time.TimeZone = EFI_UNSPECIFIED_TIMEZONE;
    Time.Daylight = 0;
    Time.Pad1 = 0;

    return Time;
}