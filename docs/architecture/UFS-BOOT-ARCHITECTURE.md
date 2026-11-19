# UFS Boot Architecture

**Project:** Project U (U Filesystem - UFS)
**Version:** 1.0
**Date:** 2026-11-13
**Status:** Architecture Definition Phase

---

## 1. Overview

UFS supports UEFI booting through a dedicated EFI application (`UFS.efi`) that implements the `EFI_SIMPLE_FILE_SYSTEM_PROTOCOL`. This allows UEFI firmware and bootloaders to read files from UFS volumes.

**Key Principle:** UFS does not require firmware support. The bootloader chain loads `UFS.efi` from the ESP (FAT32), which then reads the OS kernel from the UFS partition.

---

## 2. Partition Layout for Boot

### 2.1 Standard Layout (GPT)

```
┌─────────────────────────────────────────────────────────────────────┐
│                        GPT DISK                                     │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  Partition 1: EFI System Partition (ESP)                           │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │ Type: C12A7328-F81F-11D2-BA4B-00A0C93EC93B                 │   │
│  │ Format: FAT32 (required by UEFI spec)                       │   │
│  │ Size: 512 MB - 1 GB (recommended)                           │   │
│  │ Contents:                                                    │   │
│  │   /EFI/BOOT/BOOTX64.EFI        → Fallback bootloader        │   │
│  │   /EFI/UFS/UFS.EFI             → UFS filesystem driver      │   │
│  │   /EFI/UFS/ufs.cfg             → UFS driver config          │   │
│  │   /EFI/<OS>/<BOOTLOADER>.EFI   → OS bootloader (optional)   │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                                                                     │
│  Partition 2: UFS Data Partition                                   │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │ Type: Custom GUID (e.g., 55465300-0000-4146-5300-000000000000) │
│  │ Format: UFS                                                  │   │
│  │ Size: Remaining space                                        │   │
│  │ Contents:                                                    │   │
│  │   /boot/kernel.efi             → OS kernel                   │   │
│  │   /boot/initrd.img             → Initramfs                   │   │
│  │   /boot/ufs.cfg                → Boot configuration          │   │
│  │   /EFI/<OS>/...                → Optional ESP copy           │   │
│  │   / (root filesystem)          → OS root                     │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                                                                     │
│  Optional Partition 3: Swap / Hibernation                          │
│  Optional Partition 4: Additional UFS volumes                      │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

### 2.2 UFS Partition Type GUID

```
UFS_PARTITION_TYPE_GUID = {0x55465300, 0x0000, 0x4146, {0x53, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00}}
// "UFS\0" in first 4 bytes
```

---

## 3. UEFI UFS Driver (UFS.efi)

### 3.1 Supported Architectures

| Architecture | Target Triple | UEFI Spec |
|--------------|---------------|-----------|
| x86-64 | `x86_64-unknown-uefi` | UEFI 2.10+ |
| ARM64/AArch64 | `aarch64-unknown-uefi` | UEFI 2.10+ |

### 3.2 Implemented Protocols

#### EFI_SIMPLE_FILE_SYSTEM_PROTOCOL (Required)
```zig
const SimpleFileSystemProtocol = extern struct {
    Revision: u64,
    OpenVolume: *const fn (
        this: *const SimpleFileSystemProtocol,
        root: **EFI_FILE_PROTOCOL
    ) -> EFI_STATUS,
};
```

#### EFI_FILE_PROTOCOL (Read-Only Subset)
```zig
const FileProtocol = extern struct {
    Revision: u64,
    Open: *const fn (
        this: *const FileProtocol,
        new_handle: **EFI_FILE_PROTOCOL,
        file_name: *const u16,
        open_mode: u64,
        attributes: u64
    ) -> EFI_STATUS,
    Close: *const fn (this: *const FileProtocol) -> EFI_STATUS,
    Read: *const fn (
        this: *const FileProtocol,
        buffer_size: *mut usize,
        buffer: *mut anyopaque
    ) -> EFI_STATUS,
    GetPosition: *const fn (this: *const FileProtocol, position: *mut u64) -> EFI_STATUS,
    SetPosition: *const fn (this: *const FileProtocol, position: u64) -> EFI_STATUS,
    GetInfo: *const fn (
        this: *const FileProtocol,
        info_type: *const EFI_GUID,
        buffer_size: *mut usize,
        buffer: *mut anyopaque
    ) -> EFI_STATUS,
    Flush: *const fn (this: *const FileProtocol) -> EFI_STATUS,
};
```

**Supported Open Modes:**
- `EFI_FILE_MODE_READ` (required)
- `EFI_FILE_MODE_WRITE` (not supported in v1)
- `EFI_FILE_MODE_CREATE` (not supported in v1)

**Supported Info Types:**
- `EFI_FILE_INFO_ID` (file size, attributes, timestamps)
- `EFI_FILE_SYSTEM_INFO_ID` (volume size, free space, label)
- `EFI_FILE_SYSTEM_VOLUME_LABEL_ID` (volume label)

### 3.3 Block I/O Access

```zig
// Uses EFI_BLOCK_IO_PROTOCOL for raw partition access
const BlockIoProtocol = extern struct {
    Revision: u64,
    Media: *const BlockIoMedia,
    Reset: *const fn (this: *const BlockIoProtocol, extended_verification: bool) -> EFI_STATUS,
    ReadBlocks: *const fn (
        this: *const BlockIoProtocol,
        media_id: u32,
        lba: u64,
        buffer_size: usize,
        buffer: *mut anyopaque
    ) -> EFI_STATUS,
    WriteBlocks: *const fn (...) -> EFI_STATUS,
    FlushBlocks: *const fn (this: *const BlockIoProtocol) -> EFI_STATUS,
};

const BlockIoMedia = extern struct {
    MediaId: u32,
    RemovableMedia: bool,
    MediaPresent: bool,
    LogicalPartition: bool,
    ReadOnly: bool,
    WriteCaching: bool,
    BlockSize: u32,
    IoAlign: u32,
    LastBlock: u64,
    LowestAlignedLba: u64,
    LogicalBlocksPerPhysicalBlock: u32,
    OptimalTransferLengthGranularity: u32,
};
```

### 3.4 Driver Binding

```zig
// Installs on partition handles with UFS partition type GUID
const DriverBindingProtocol = extern struct {
    Supported: *const fn (
        this: *const DriverBindingProtocol,
        controller: EFI_HANDLE,
        remaining_device_path: *const EFI_DEVICE_PATH_PROTOCOL
    ) -> EFI_STATUS,
    Start: *const fn (
        this: *const DriverBindingProtocol,
        controller: EFI_HANDLE,
        remaining_device_path: *const EFI_DEVICE_PATH_PROTOCOL
    ) -> EFI_STATUS,
    Stop: *const fn (
        this: *const DriverBindingProtocol,
        controller: EFI_HANDLE,
        number_of_children: u32,
        child_handle_buffer: *const EFI_HANDLE
    ) -> EFI_STATUS,
    Version: u32,
    ImageHandle: EFI_HANDLE,
    DriverBindingHandle: EFI_HANDLE,
};
```

**Supported() Logic:**
1. Open `EFI_BLOCK_IO_PROTOCOL` on controller
2. Read partition superblock (sector 1)
3. Verify UFS magic (`0x55465300`)
4. Return `EFI_SUCCESS` if valid, `EFI_UNSUPPORTED` otherwise

---

## 4. Boot Configuration

### 4.1 ufs.cfg (on UFS Partition)

```ini
# UFS Boot Configuration
# Located at /boot/ufs.cfg on UFS partition

[boot]
# Default kernel to load
default_kernel = /boot/kernel.efi

# Default initrd
default_initrd = /boot/initrd.img

# Kernel command line
cmdline = "root=PARTUUID=<ufs-partition-uuid> ro quiet"

# Timeout in seconds (0 = no timeout)
timeout = 5

[uefi]
# Driver configuration
driver_path = /EFI/UFS/UFS.EFI
# Optional: load driver from ESP instead
# driver_path = /EFI/UFS/UFS.EFI

[recovery]
# Enable recovery mode
enabled = true
# Recovery kernel
recovery_kernel = /boot/kernel-recovery.efi
```

### 4.2 UEFI Boot Variables

```
Boot#### = "UFS Boot" 
  -> HD(1,GPT,<esp-guid>,0x800,0x100000)/EFI/UFS/UFS.EFI
  -> HD(2,GPT,<ufs-guid>,0x100000,0x...)/boot/kernel.efi
```

---

## 5. Boot Sequence

### 5.1 Standard Boot

```
1. UEFI Firmware Initialization
   │
   ▼
2. Firmware Loads Boot Manager (Boot####)
   │
   ▼
3. Boot Manager Loads UFS.efi from ESP
   │   (via EFI_SIMPLE_FILE_SYSTEM_PROTOCOL on ESP)
   │
   ▼
4. UFS.efi Driver Binding Protocol Installs
   │   - Detects UFS partition
   │   - Installs EFI_SIMPLE_FILE_SYSTEM_PROTOCOL on UFS partition handle
   │
   ▼
5. Boot Manager Loads Kernel from UFS Partition
   │   - Opens UFS volume via new protocol
   │   - Reads /boot/kernel.efi
   │
   ▼
6. Kernel Execution Begins
   │   - Kernel receives UFS partition handle via boot services
   │   - Kernel's native UFS driver takes over
   │
   ▼
7. OS Initialization
   │   - Mount root filesystem
   │   - Start userspace
```

### 5.2 Recovery Boot

```
1. UEFI Firmware
   │
   ▼
2. Boot Manager -> UFS.efi (same as standard)
   │
   ▼
3. UFS.efi detects recovery request
   │   - Via boot variable, key press, or config
   │
   ▼
4. Load recovery kernel/initrd
   │   - /boot/kernel-recovery.efi
   │   - /boot/initrd-recovery.img
   │
   ▼
5. Recovery Environment
   │   - Includes ufsck, mkufs, ufsctl
   │   - Can repair/maintain UFS volumes
```

---

## 6. Secure Boot Support

### 6.1 Signing Requirements

| Component | Signing |
|-----------|---------|
| UFS.efi | Microsoft UEFI CA (for Windows) or vendor cert |
| Kernel | OS vendor cert |
| Initrd | Measured/verified by kernel |

### 6.2 Secure Boot Flow

```
1. Firmware verifies UFS.efi signature
   │
   ▼
2. UFS.efi runs, installs protocol
   │
   ▼
3. Boot manager loads kernel
   │   - Kernel must be signed
   │
   ▼
4. Kernel verifies initrd (if measured boot)
   │
   ▼
5. Kernel initializes, loads native UFS driver
   │   - Driver must be signed (kernel module)
```

### 6.3 Shim Support

For distributions using Shim:
```
Shim -> UFS.efi (enrolled in MOK) -> Kernel
```

---

## 7. Apple Silicon (Mac) Considerations

### 7.1 Current State

- **Apple Silicon Macs**: Do not use standard UEFI boot process
- **Boot Process**: iBoot → XNU kernel (no EFI applications)
- **UFS on macOS**: FSKit extension for runtime access only
- **Boot from UFS**: Not supported on Apple Silicon (v1)

### 7.2 Intel Macs (Legacy)

- Standard UEFI boot supported
- UFS.efi works on Intel Macs with UEFI firmware
- Requires `bless` to set boot volume

---

## 8. Implementation Details

### 8.1 Zig UEFI Build

```bash
# x86-64 UEFI
zig build -Dtarget=x86_64-unknown-uefi -Doptimize=ReleaseFast

# ARM64 UEFI  
zig build -Dtarget=aarch64-unknown-uefi -Doptimize=ReleaseFast

# Output: zig-out/bin/UFS.efi (PE/COFF)
```

### 8.2 Zig UEFI Target Configuration

```zig
// build.zig.uefi
const uefi_target = .{
    .cpu_arch = .x86_64,  // or .aarch64
    .os_tag = .uefi,
    .abi = .gnu,  // or .msvc for Windows UEFI
};

// Compile options
const options = .{
    .optimize = .ReleaseFast,
    .strip = true,
    .single_threaded = true,
    .emit = .obj,  // For manual linking with gnu-efi
};

// Entry point
pub fn efi_main(image_handle: EFI_HANDLE, system_table: *EFI_SYSTEM_TABLE) EFI_STATUS {
    // Initialize UFS driver
    // Install DriverBindingProtocol
    return EFI_SUCCESS;
}
```

### 8.3 Memory Constraints

- UEFI runtime memory: ~1-4 MB typical
- UFS.efi target size: < 500 KB
- No dynamic allocation (use pool allocation)
- Stack: 64 KB

### 8.4 Features Supported in UEFI Driver

| Feature | Support |
|---------|---------|
| Read superblock | ✅ |
| Read journal | ✅ (verify only) |
| Read inodes | ✅ |
| Read directories | ✅ |
| Read file data | ✅ |
| Decompress (LZ4/ZSTD) | ✅ |
| Verify BLAKE3 | ✅ |
| Journal recovery | ❌ (assumes clean) |
| Write support | ❌ |
| Compression write | ❌ |
| Encryption | ❌ |

---

## 9. Testing

### 9.1 QEMU/OVMF Testing

```bash
# Create disk image
qemu-img create -f raw test.img 2G

# Partition
parted test.img mklabel gpt
parted test.img mkpart ESP fat32 1MiB 513MiB
parted test.img set 1 esp on
parted test.img mkpart UFS ufs 513MiB 100%

# Format ESP
sudo mkfs.vfat -F32 -n ESP test.img1

# Format UFS
sudo mkufs test.img2

# Mount and populate
sudo mount test.img1 /mnt/esp
mkdir -p /mnt/esp/EFI/UFS
cp UFS.efi /mnt/esp/EFI/UFS/
cp ufs.cfg /mnt/esp/EFI/UFS/

sudo mount test.img2 /mnt/ufs
mkdir -p /mnt/ufs/boot
cp kernel.efi /mnt/ufs/boot/
cp initrd.img /mnt/ufs/boot/
cp ufs.cfg /mnt/ufs/boot/

# Run QEMU
qemu-system-x86_64 \
    -bios /usr/share/OVMF/OVMF_CODE.fd \
    -drive file=test.img,format=raw \
    -net none
```

### 9.2 Hardware Testing

- Test on: Intel NUC, AMD Ryzen, ARM64 (Ampere, Raspberry Pi 4/5)
- Verify: Cold boot, warm boot, Secure Boot on/off

---

## 10. Limitations (v1)

1. **Read-only**: UEFI driver cannot write/modify
2. **No journal recovery**: Assumes clean unmount
3. **No encryption**: Encrypted volumes not bootable
4. **No Apple Silicon**: Different boot architecture
5. **Single partition**: Only one UFS partition per disk recognized
6. **No RAID**: Boot from single UFS partition only

---

## 11. Future Enhancements (v2+)

1. **Write support in UEFI**: For boot config updates
2. **Journal recovery in UEFI**: For unclean shutdowns
3. **Encryption support**: With pre-boot authentication
4. **Apple Silicon support**: Via custom boot stub
5. **PXE/Network boot**: Load UFS.efi from network
6. **Measured boot**: Extend PCRs with UFS metadata

---

*End of UFS Boot Architecture*