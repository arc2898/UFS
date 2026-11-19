## UFS.dsc - UEFI Driver Package
## Build: build -p UFS.dsc -a X64 -t GCC5

[Defines]
  PLATFORM_NAME                  = UFS
  PLATFORM_GUID                  = 1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d
  PLATFORM_VERSION               = 1.0.0
  DSC_SPECIFICATION              = 0x00010005
  OUTPUT_DIRECTORY               = Build/UFS

[Components]
  UFS/UFS.inf

[LibraryClasses]
  BaseLib|MdePkg/Library/BaseLib/BaseLib.inf
  BaseMemoryLib|MdePkg/Library/BaseMemoryLib/BaseMemoryLib.inf
  DebugLib|MdePkg/Library/DebugLib/DebugLib.inf
  DevicePathLib|MdePkg/Library/DevicePathLib/DevicePathLib.inf
  MemoryAllocationLib|MdePkg/Library/MemoryAllocationLib/MemoryAllocationLib.inf
  UefiBootServicesTableLib|MdePkg/Library/UefiBootServicesTableLib/UefiBootServicesTableLib.inf
  UefiRuntimeServicesTableLib|MdePkg/Library/UefiRuntimeServicesTableLib/UefiRuntimeServicesTableLib.inf
  UefiLib|MdePkg/Library/UefiLib/UefiLib.inf
  PrintLib|MdePkg/Library/PrintLib/PrintLib.inf
  Crc32Lib|MdePkg/Library/BaseCrc32Lib/BaseCrc32Lib.inf
  HashLib|MdePkg/Library/BaseCryptLib/BaseCryptLib.inf

[PcdsFixedAtBuild]
  gUfsDriverDebugLevel|UINT32|0x00000001
  gUfsDriverCompressionDefault|UINT8|0x01
  gUfsDriverIntegrityCheck|BOOLEAN|TRUE
  gUfsDriverCaseInsensitive|BOOLEAN|TRUE

[PcdsFeatureFlag]
  gUfsFeatureCompression|BOOLEAN|TRUE
  gUfsFeatureIntegrity|BOOLEAN|TRUE
  gUfsFeatureEncryption|BOOLEAN|FALSE
  gUfsFeatureCaseInsensitive|BOOLEAN|TRUE

[PcdsPatchableInModule]
  gUfsJournalSizeMb|UINT32|64

[BuildOptions]
  GCC:X64:*_CC_FLAGS            = -Wno-unused-parameter -Wno-missing-field-initializers
  GCC:AARCH64:*_CC_FLAGS        = -Wno-unused-parameter -Wno-missing-field-initializers
  MSFT:X64:*_CC_FLAGS           = /wd4100 /wd4101 /wd4189 /wd4244 /wd4245 /wd4267 /wd4389 /wd4706 /wd4715 /wd4738 /wd4820 /wd4826 /wd4996
  MSFT:AARCH64:*_CC_FLAGS       = /wd4100 /wd4101 /wd4189 /wd4244 /wd4245 /wd4267 /wd4389 /wd4706 /wd4715 /wd4738 /wd4820 /wd4826 /wd4996

[Components.X64]
  UFS/UFS.inf

[Components.AARCH64]
  UFS/UFS.inf