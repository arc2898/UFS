// UfsBootLoader.c - UFS UEFI Boot Application
// Loads and executes boot loaders from UFS volumes

#include <Uefi.h>
#include <Library/UefiLib.h>
#include <Library/UefiBootServicesTableLib.h>
#include <Library/UefiRuntimeServicesTableLib.h>
#include <Library/BaseMemoryLib.h>
#include <Library/MemoryAllocationLib.h>
#include <Library/DebugLib.h>
#include <Library/DevicePathLib.h>
#include <Library/PrintLib.h>
#include <Protocol/BlockIo.h>
#include <Protocol/SimpleFileSystem.h>
#include <Protocol/LoadedImage.h>
#include <Protocol/DevicePath.h>

#include "ufs.h"

// ============================================================================
// Standard Boot Paths
// ============================================================================

CHAR16 *g_BootPaths[] = {
    L"\\EFI\\BOOT\\BOOTX64.EFI",
    L"\\EFI\\BOOT\\BOOTAA64.EFI",
    L"\\EFI\\MICROSOFT\\BOOT\\BOOTMGFW.EFI",
    L"\\EFI\\UBUNTU\\SHIMX64.EFI",
    L"\\EFI\\FEDORA\\SHIMX64.EFI",
    L"\\EFI\\ARCH\\VMLINUZ-LINUX.EFI",
    L"\\SYSTEM\\LIBRARY\\CORESERVICES\\BOOT.EFI",
    NULL
};

// ============================================================================
// Boot Loader Entry Point
// ============================================================================

EFI_STATUS EFIAPI UfsLoadBootLoader(
    IN EFI_HANDLE ImageHandle,
    IN EFI_HANDLE DeviceHandle
) {
    EFI_STATUS Status;
    EFI_SIMPLE_FILE_SYSTEM_PROTOCOL *SimpleFs = NULL;
    EFI_FILE_PROTOCOL *Root = NULL;
    EFI_DEVICE_PATH_PROTOCOL *FilePath = NULL;
    EFI_HANDLE NewImageHandle = NULL;

    DEBUG((DEBUG_INFO, "UFS: Attempting to load boot loader from device %p\n", DeviceHandle));

    // Open Simple File System protocol
    Status = gBS->HandleProtocol(DeviceHandle, &gEfiSimpleFileSystemProtocolGuid,
                                 (VOID**)&SimpleFs);
    if (EFI_ERROR(Status)) {
        DEBUG((DEBUG_ERROR, "UFS: No SimpleFS on device: %r\n", Status));
        return Status;
    }

    // Open root directory
    Status = SimpleFs->OpenVolume(SimpleFs, &Root);
    if (EFI_ERROR(Status)) {
        DEBUG((DEBUG_ERROR, "UFS: Failed to open root volume: %r\n", Status));
        return Status;
    }

    // Try each standard boot path
    for (UINTN i = 0; g_BootPaths[i] != NULL; i++) {
        EFI_FILE_PROTOCOL *File = NULL;

        Status = Root->Open(Root, &File, g_BootPaths[i],
                            EFI_FILE_MODE_READ, 0);

        if (!EFI_ERROR(Status)) {
            DEBUG((DEBUG_INFO, "UFS: Found boot loader: %s\n", g_BootPaths[i]));

            // Create device path for the file
            FilePath = FileDevicePath(DeviceHandle, g_BootPaths[i]);
            if (!FilePath) {
                File->Close(File);
                Root->Close(Root);
                return EFI_OUT_OF_RESOURCES;
            }

            // Load the image
            Status = gBS->LoadImage(FALSE, ImageHandle, FilePath,
                                    NULL, 0, &NewImageHandle);

            File->Close(File);

            if (!EFI_ERROR(Status)) {
                DEBUG((DEBUG_INFO, "UFS: Loaded boot loader, starting...\n"));

                // Start the image
                Status = gBS->StartImage(NewImageHandle, NULL, NULL);

                // If we get here, the boot loader returned or failed
                DEBUG((DEBUG_ERROR, "UFS: Boot loader exited: %r\n", Status));
            } else {
                DEBUG((DEBUG_ERROR, "UFS: Failed to load %s: %r\n", g_BootPaths[i], Status));
            }

            FreePool(FilePath);
            FilePath = NULL;
        }
    }

    if (Root) {
        Root->Close(Root);
    }

    return EFI_NOT_FOUND;
}

// ============================================================================
// UEFI Application Entry Point (for UFS.efi as BOOTX64.EFI)
// ============================================================================

EFI_STATUS EFIAPI UfsBootEntryPoint(
    IN EFI_HANDLE ImageHandle,
    IN EFI_SYSTEM_TABLE *SystemTable
) {
    EFI_STATUS Status;

    // Initialize libraries
    gST = SystemTable;
    gBS = SystemTable->BootServices;
    gRT = SystemTable->RuntimeServices;

    // Clear screen and show banner
    gST->ConOut->ClearScreen(gST->ConOut);
    Print(L"UFS UEFI Boot Loader v1.0\n");
    Print(L"Copyright (c) 2024 UFS Project\n");
    Print(L"\n");

    // Find all block devices
    EFI_HANDLE *Handles = NULL;
    UINTN HandleCount = 0;

    Status = gBS->LocateHandleBuffer(ByProtocol, &gEfiBlockIoProtocolGuid,
                                     NULL, &HandleCount, &Handles);
    if (EFI_ERROR(Status)) {
        Print(L"No block devices found\n");
        return Status;
    }

    Print(L"Found %d block devices\n", HandleCount);

    // Check each device for UFS
    for (UINTN i = 0; i < HandleCount; i++) {
        EFI_BLOCK_IO_PROTOCOL *BlockIo = NULL;

        Status = gBS->HandleProtocol(Handles[i], &gEfiBlockIoProtocolGuid,
                                     (VOID**)&BlockIo);
        if (EFI_ERROR(Status)) continue;

        if (!BlockIo->Media->MediaPresent) continue;

        // Check for UFS signature
        UINT8 *Buffer = AllocatePool(BlockIo->Media->BlockSize);
        if (!Buffer) continue;

        Status = BlockIo->ReadBlocks(BlockIo, BlockIo->Media->MediaId,
                                     0, BlockIo->Media->BlockSize, Buffer);
        if (EFI_ERROR(Status)) {
            FreePool(Buffer);
            continue;
        }

        // Check UFS magic (at cluster 1 = 4096 bytes offset, or superblock at LBA 0/1)
        // UFS superblock is at cluster 1 (4096 bytes), but we check LBA 0 for MBR/GPT
        UINT32 Magic = 0;
        if (BlockIo->Media->BlockSize >= 4) {
            Magic = *(UINT32*)Buffer;  // MBR/GPT at LBA 0
        }

        // Also check cluster 1 (LBA 8 for 4K clusters)
        if (Magic != 0x55465300 && BlockIo->Media->BlockSize >= 4096) {
            UINT64 Cluster1Lba = 4096 / BlockIo->Media->BlockSize;
            Status = BlockIo->ReadBlocks(BlockIo, BlockIo->Media->MediaId,
                                         Cluster1Lba, 4096, Buffer);
            if (!EFI_ERROR(Status)) {
                Magic = *(UINT32*)Buffer;
            }
        }

        FreePool(Buffer);

        if (Magic == 0x55465300) {  // "UFS\0"
            Print(L"Found UFS volume on device %d\n", i);

            // Try to load boot loader
            Status = UfsLoadBootLoader(ImageHandle, Handles[i]);
            if (!EFI_ERROR(Status)) {
                // Boot loader took over
                FreePool(Handles);
                return Status;
            }
        }
    }

    Print(L"No bootable UFS volume found\n");
    Print(L"Press any key to continue...\n");

    // Wait for key
    UINTN Index;
    gBS->WaitForEvent(1, &gST->ConIn->WaitForKey, &Index);

    FreePool(Handles);
    return EFI_NOT_FOUND;
}

// ============================================================================
// Install as Boot Loader
// ============================================================================

EFI_STATUS UfsInstallBootLoader(
    IN EFI_HANDLE DeviceHandle,
    IN CHAR16 *BootLoaderPath
) {
    // This would be called from a UEFI shell or OS to install UFS.efi
    // as the default boot loader on a UFS volume
    return EFI_UNSUPPORTED;
}