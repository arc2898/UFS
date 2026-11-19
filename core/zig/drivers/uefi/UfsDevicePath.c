// UfsDevicePath.c - UFS Device Path Protocol Implementation
// Creates device paths for UFS volumes

#include <Uefi.h>
#include <Library/UefiLib.h>
#include <Library/UefiBootServicesTableLib.h>
#include <Library/BaseMemoryLib.h>
#include <Library/MemoryAllocationLib.h>
#include <Library/DebugLib.h>
#include <Library/DevicePathLib.h>
#include <Protocol/DevicePath.h>
#include <Protocol/BlockIo.h>

#include "ufs.h"

// ============================================================================
// Device Path Generation
// ============================================================================

EFI_DEVICE_PATH_PROTOCOL* UfsCreateDevicePath(
    IN UFS_VOLUME *Volume
) {
    if (!Volume || Volume->Signature != UFS_VOLUME_SIGNATURE) {
        return NULL;
    }

    // Start with the device path of the underlying block device
    EFI_DEVICE_PATH_PROTOCOL *BlockDevicePath = Volume->DevicePath;
    if (!BlockDevicePath) {
        return NULL;
    }

    // Duplicate the device path
    EFI_DEVICE_PATH_PROTOCOL *DupPath = DuplicateDevicePath(BlockDevicePath);
    if (!DupPath) {
        return NULL;
    }

    // Find the end of the device path
    EFI_DEVICE_PATH_PROTOCOL *Node = DupPath;
    while (!IsDevicePathEnd(Node)) {
        Node = NextDevicePathNode(Node);
    }

    // Add media device path for the UFS partition/volume
    MEDIA_DEVICE_PATH MediaPath = {
        .Header = {
            .Type = MEDIA_DEVICE_PATH,
            .SubType = MEDIA_HARDDRIVE_DP,
            .Length = (UINT16)sizeof(MEDIA_DEVICE_PATH)
        },
        .PartitionNumber = 1,  // Single partition for UFS
        .PartitionStart = 0,
        .PartitionSize = Volume->VolumeSize / 512,  // In 512-byte sectors
    };

    // Copy partition signature (first 8 bytes of UUID)
    CopyMem(&MediaPath.Signature, &Volume->VolumeGuid, sizeof(MediaPath.Signature));

    // MBR vs GPT
    MediaPath.MBRType = MBR_TYPE_EFI_PARTITION_TABLE_HEADER;
    MediaPath.SignatureType = SIGNATURE_TYPE_GUID;

    // Append media device path
    EFI_DEVICE_PATH_PROTOCOL *NewPath = AppendDevicePathNode(DupPath, (EFI_DEVICE_PATH_PROTOCOL*)&MediaPath);
    FreePool(DupPath);

    // Add end node
    EFI_DEVICE_PATH_PROTOCOL *EndPath = AppendDevicePathNode(NewPath, (EFI_DEVICE_PATH_PROTOCOL*)&gEndEntire);
    FreePool(NewPath);

    return EndPath;
}

// ============================================================================
// Device Path Utilities
// ============================================================================

BOOLEAN UfsIsUfsDevicePath(
    IN EFI_DEVICE_PATH_PROTOCOL *DevicePath
) {
    if (!DevicePath) {
        return FALSE;
    }

    // Check if the last media node is a UFS hard drive path
    EFI_DEVICE_PATH_PROTOCOL *Node = DevicePath;
    while (!IsDevicePathEnd(Node)) {
        if (DevicePathType(Node) == MEDIA_DEVICE_PATH &&
            DevicePathSubType(Node) == MEDIA_HARDDRIVE_DP) {
            MEDIA_DEVICE_PATH *Media = (MEDIA_DEVICE_PATH*)Node;
            // Check for UFS-specific partition signature
            // In real impl, we'd check the GUID
            return TRUE;
        }
        Node = NextDevicePathNode(Node);
    }

    return FALSE;
}

EFI_HANDLE UfsGetDeviceHandleFromPath(
    IN EFI_DEVICE_PATH_PROTOCOL *DevicePath
) {
    EFI_HANDLE Handle = NULL;
    EFI_STATUS Status = gBS->LocateDevicePath(&gEfiBlockIoProtocolGuid, &DevicePath, &Handle);
    if (EFI_ERROR(Status)) {
        return NULL;
    }
    return Handle;
}