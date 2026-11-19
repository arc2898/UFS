# UFS Linux Kernel Module Makefile
# Build with: make -C /lib/modules/$(shell uname -r)/build M=$(PWD) modules

# Kernel build directory (can be overridden)
KDIR ?= /lib/modules/$(shell uname -r)/build

# Module name
MODULE_NAME = ufs

# Object files
$(MODULE_NAME)-objs := \
	ufs_super.o \
	ufs_inode.o \
	ufs_file.o \
	ufs_dir.o \
	ufs_xattr.o \
	ufs_aops.o \
	ufs_bmap.o \
	ufs_ioctl.o \
	ufs_core.o \
	ufs_blockdev.o

obj-$(CONFIG_UFS_FS) += $(MODULE_NAME).o

# Compiler flags
ccflags-y := -I$(src)/../../src \
	     -I$(src) \
	     -D__KERNEL__ \
	     -DMODULE \
	     -std=gnu11 \
	     -Wall -Wextra \
	     -Wno-unused-parameter \
	     -Wno-missing-field-initializers \
	     -O2 \
	     -fno-strict-aliasing \
	     -fno-common \
	     -fno-pie \
	     -mno-sse \
	     -mno-mmx \
	     -mno-sse2 \
	     -mno-3dnow \
	     -mno-avx

# Debug flags
ifdef CONFIG_UFS_FS_DEBUG
ccflags-y += -DDEBUG -DDEBUG_VERBOSE
endif

# Feature flags
ifdef CONFIG_UFS_FS_COMPRESSION
ccflags-y += -DCONFIG_UFS_COMPRESSION
endif

ifdef CONFIG_UFS_FS_INTEGRITY
ccflags-y += -DCONFIG_UFS_INTEGRITY
endif

ifdef CONFIG_UFS_FS_POSIX_ACL
ccflags-y += -DCONFIG_UFS_POSIX_ACL
endif

ifdef CONFIG_UFS_FS_SECURITY
ccflags-y += -DCONFIG_UFS_SECURITY
endif

ifdef CONFIG_UFS_FS_XATTR
ccflags-y += -DCONFIG_UFS_XATTR
endif

ifdef CONFIG_UFS_FS_QUOTA
ccflags-y += -DCONFIG_UFS_QUOTA
endif

ifdef CONFIG_UFS_FS_CASE_INSENSITIVE
ccflags-y += -DCONFIG_UFS_CASE_INSENSITIVE
endif

ifdef CONFIG_UFS_FS_STRICT
ccflags-y += -DCONFIG_UFS_STRICT
endif

# Link against the UFS core static library (built from Zig)
# This requires the Zig core to be built first as a static library
# and placed in the kernel build directory or linked explicitly
#
# To build the Zig core library:
#   cd ../../zig && zig build -Dtarget=x86_64-linux-gnu.2.17 -Doptimize=ReleaseFast
#   cp zig-out/lib/libufs_core.a .
#
# Then link it:
# LDFLAGS_ufs.o += -L$(src)/../../zig -lufs_core

# Alternative: Build core as part of kernel module (requires Zig compiler in kernel build)
# This is the recommended approach for distribution

# Phony targets
.PHONY: all clean install uninstall modules headers

all: modules

modules:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
	rm -f *.ko *.mod.c *.mod.o *.o .*.cmd Module.symvers modules.order
	rm -rf .tmp_versions

install: modules
	$(MAKE) -C $(KDIR) M=$(PWD) modules_install
	depmod -a

uninstall:
	rm -f $(DESTDIR)/lib/modules/$(shell uname -r)/kernel/fs/ufs/ufs.ko
	depmod -a

# Generate headers for userspace tools
headers:
	$(MAKE) -C $(KDIR) M=$(PWD) headers_install

# Build Zig core library (must be done before building this module)
build-zig-core:
	cd ../../zig && zig build -Dtarget=x86_64-linux-gnu.2.17 -Doptimize=ReleaseFast -Dstrip=true
	cp zig-out/lib/libufs_core.a ../linux/

# Check for required kernel headers
check-headers:
	@if [ ! -d "$(KDIR)/include/linux" ]; then \
		echo "Kernel headers not found at $(KDIR)"; \
		echo "Install with: sudo apt-get install linux-headers-$$(uname -r)"; \
		exit 1; \
	fi

# Development build with debug symbols
debug: ccflags-y += -g -O0 -DDEBUG
debug: modules

# Release build with optimizations
release: ccflags-y += -O3 -march=native
release: modules

# Static analysis
analyze:
	$(MAKE) -C $(KDIR) M=$(PWD) C=1 CHECK=clang-analyzer

# Generate compile_commands.json for IDE support
compile-commands:
	$(MAKE) -C $(KDIR) M=$(PWD) COMPILE_COMMANDS=1
	cp $(KDIR)/compile_commands.json .

# DKMS support
dkms-install:
	dkms add -m ufs -v $(shell cat VERSION 2>/dev/null || echo "1.0.0")
	dkms build -m ufs -v $(shell cat VERSION 2>/dev/null || echo "1.0.0")
	dkms install -m ufs -v $(shell cat VERSION 2>/dev/null || echo "1.0.0")

dkms-remove:
	dkms remove -m ufs -v $(shell cat VERSION 2>/dev/null || echo "1.0.0") --all

# Help
help:
	@echo "UFS Linux Kernel Module Build System"
	@echo ""
	@echo "Targets:"
	@echo "  all           - Build module (default)"
	@echo "  modules       - Build kernel module"
	@echo "  clean         - Clean build artifacts"
	@echo "  install       - Install module to kernel"
	@echo "  uninstall     - Remove module from kernel"
	@echo "  debug         - Build with debug symbols"
	@echo "  release       - Build with optimizations"
	@echo "  analyze       - Run static analysis"
	@echo "  build-zig-core - Build Zig core library first"
	@echo "  dkms-install  - Install via DKMS"
	@echo "  dkms-remove   - Remove via DKMS"
	@echo ""
	@echo "Variables:"
	@echo "  KDIR          - Kernel build directory (default: /lib/modules/$$(uname -r)/build)"
	@echo ""
	@echo "Example:"
	@echo "  make KDIR=/usr/src/linux-headers-$$(uname -r)"
	@echo "  make build-zig-core && make"