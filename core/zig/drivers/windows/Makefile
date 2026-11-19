# UFS Windows IFS Driver Makefile
# Build with: nmake /f Makefile (in VS Developer Command Prompt)

!IF "$(TARGET)" == ""
TARGET=ufs
!ENDIF

!IF "$(BUILD)" == ""
BUILD=release
!ENDIF

!IF "$(ARCH)" == ""
ARCH=x64
!ENDIF

# ============================================================================
# Paths
# ============================================================================
UFS_ROOT = ..\..\..
ZIG_DIR = $(UFS_ROOT)\core\zig
ZIG_LIB_DIR = $(ZIG_DIR)\zig-out\lib
ZIG_INC_DIR = $(ZIG_DIR)\src

DRIVER_DIR = .
LIB_DIR = $(DRIVER_DIR)\lib
INC_DIR = $(DRIVER_DIR)\include
OBJ_DIR = $(DRIVER_DIR)\obj\$(ARCH)\$(BUILD)
OUT_DIR = $(DRIVER_DIR)\out\$(ARCH)\$(BUILD)

# ============================================================================
# Tools
# ============================================================================
CC = cl
LINK = link
RC = rc
MC = mc

# ============================================================================
# Compiler Flags
# ============================================================================
CFLAGS_BASE = /nologo /W4 /WX- /wd4201 /wd4214 /wd4115 /wd4100 /wd4127 /wd4706 \
              /D_KERNEL_MODE /DNTDDI_VERSION=0x0A00000A /DWINVER=0x0A00 \
              /D_WIN32_WINNT=0x0A00 /DNT_PROCESSOR_GROUPS=1 \
              /I"$(INC_DIR)" /I"$(ZIG_INC_DIR)" \
              /I"$(DDK_INC_PATH)" /I"$(CRT_INC_PATH)" \
              /Gz /GF /Gy /Oi /GF /GR- /EHs-c- /fp:fast \
              /Zc:forScope /Zc:inline /Zc:rvalueCast /Zc:strictStrings /Zc:throwingNew \
              /sdl /guard:cf /Qpar /Qvec-report:0

!IF "$(BUILD)" == "debug"
CFLAGS_OPT = /Od /Zi /DDEBUG /D_DBG
LDFLAGS_OPT = /DEBUG /INCREMENTAL:NO
!ELSE
CFLAGS_OPT = /O2 /Ob2 /Oi /Ot /Oy /GL /DNDEBUG
LDFLAGS_OPT = /LTCG /INCREMENTAL:NO /OPT:REF /OPT:ICF
!ENDIF

CFLAGS = $(CFLAGS_BASE) $(CFLAGS_OPT)
LDFLAGS = /DRIVER /SUBSYSTEM:NATIVE,10.0 /MACHINE:X64 /ENTRY:DriverEntry $(LDFLAGS_OPT)

# ============================================================================
# Libraries
# ============================================================================
LIBS = ntoskrnl.lib fltMgr.lib $(LIB_DIR)\libufs_core.lib

# ============================================================================
# Source Files
# ============================================================================
SOURCES = \
    ufs_ifs.c \
    ufs_fsd.c \
    ufs_ioctl.c \
    ufs_pnp.c \
    ufs_fastio.c \
    ufs_metadata.c

OBJECTS = $(SOURCES:%.c=$(OBJ_DIR)\%.obj)

# ============================================================================
# Main Targets
# ============================================================================
all: $(OUT_DIR)\$(TARGET).sys

$(OUT_DIR)\$(TARGET).sys: $(OBJECTS) $(LIB_DIR)\libufs_core.lib
    @if not exist $(OUT_DIR) mkdir $(OUT_DIR)
    $(LINK) $(LDFLAGS) /OUT:$@ $(OBJECTS) $(LIBS)

$(OBJ_DIR)\%.obj: %.c
    @if not exist $(OBJ_DIR) mkdir $(OBJ_DIR)
    $(CC) $(CFLAGS) /Fo$@ /c $<

# ============================================================================
# Clean
# ============================================================================
clean:
    @if exist $(OBJ_DIR) rmdir /s /q $(OBJ_DIR)
    @if exist $(OUT_DIR) rmdir /s /q $(OUT_DIR)

# ============================================================================
# Install (copy to system32\drivers)
# ============================================================================
install: $(OUT_DIR)\$(TARGET).sys
    copy $(OUT_DIR)\$(TARGET).sys %SystemRoot%\System32\drivers\

# ============================================================================
# Sign (test signing)
# ============================================================================
sign_test: $(OUT_DIR)\$(TARGET).sys
    signtool sign /v /s My /n "Test Certificate" /t http://timestamp.digicert.com /fd sha256 $(OUT_DIR)\$(TARGET).sys

# ============================================================================
# Sign (production - requires EV certificate)
# ============================================================================
sign_prod: $(OUT_DIR)\$(TARGET).sys
    signtool sign /v /ac cross.cer /s My /n "Your Company Name" /tr http://timestamp.digicert.com /td sha256 /fd sha256 $(OUT_DIR)\$(TARGET).sys

# ============================================================================
# Phony
# ============================================================================
.PHONY: all clean install sign_test sign_prod