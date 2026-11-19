// UFS Linux VFS Driver - C Implementation
// Native Linux kernel module using VFS interface

#include <linux/fs.h>
#include <linux/init.h>
#include <linux/module.h>
#include <linux/blkdev.h>
#include <linux/buffer_head.h>
#include <linux/slab.h>
#include <linux/uaccess.h>
#include <linux/namei.h>
#include <linux/parser.h>
#include <linux/seq_file.h>
#include <linux/statfs.h>
#include <linux/posix_acl.h>
#include <linux/xattr.h>
#include <linux/exportfs.h>
#include <linux/mount.h>
#include <linux/sched.h>
#include <linux/version.h>

#include "ufs.h"

MODULE_LICENSE("GPL");
MODULE_AUTHOR("UFS Project");
MODULE_DESCRIPTION("Universal Filesystem (UFS) Linux Driver");
MODULE_VERSION("1.0.0");

// ============================================================================
// Module Parameters
// ============================================================================

static bool ufs_read_only = false;
static bool ufs_case_insensitive = true;
static char* ufs_compression = "lz4";
static bool ufs_integrity_check = true;
static int ufs_journal_size = 0;

module_param(ufs_read_only, bool, 0444);
MODULE_PARM_DESC(ufs_read_only, "Mount read-only");
module_param(ufs_case_insensitive, bool, 0444);
MODULE_PARM_DESC(ufs_case_insensitive, "Case-insensitive filename lookup");
module_param(ufs_compression, charp, 0444);
MODULE_PARM_DESC(ufs_compression, "Compression: none, lz4, zstd");
module_param(ufs_integrity_check, bool, 0444);
MODULE_PARM_DESC(ufs_integrity_check, "Enable metadata integrity checks");
module_param(ufs_journal_size, int, 0444);
MODULE_PARM_DESC(ufs_journal_size, "Journal size in MB");

// ============================================================================
// UFS Superblock Context
// ============================================================================

struct ufs_sb_info {
    struct super_block* sb;
    ufs_fs_t* fs;
    ufs_block_device_t* block_dev;
    struct block_device* bdev;
    fmode_t bdev_mode;
    u64 cluster_size;
    u64 total_clusters;
    u64 free_clusters;
    u64 total_inodes;
    u64 free_inodes;
    bool read_only;
    bool case_insensitive;
    u8 compression;
    bool integrity_check;
    struct mutex lock;
    struct workqueue_struct* workqueue;
};

static struct ufs_sb_info* UFS_SB(struct super_block* sb) {
    return sb->s_fs_info;
}

static inline ufs_fs_t* ufs_get_fs(struct super_block* sb) {
    return UFS_SB(sb)->fs;
}

// ============================================================================
// Inode Operations
// ============================================================================

static struct inode* ufs_iget(struct super_block* sb, u64 ino) {
    struct inode* inode = iget_locked(sb, ino);
    if (!inode)
        return ERR_PTR(-ENOMEM);

    if (!(inode->i_state & I_NEW))
        return inode;

    ufs_fs_t* fs = ufs_get_fs(sb);
    ufs_inode_info_t info;
    int ret = ufs_getattr(fs, ino, &info);
    if (ret != UFS_OK) {
        iget_failed(inode);
        return ERR_PTR(-ufs_errno(ret));
    }

    inode->i_mode = info.mode;
    set_nlink(inode, info.link_count);
    i_uid_write(inode, info.uid);
    i_gid_write(inode, info.gid);
    inode->i_size = info.size;
    inode->i_blocks = info.allocated_size >> 9;
    inode->i_atime.tv_sec = info.atime / 1000000000;
    inode->i_atime.tv_nsec = info.atime % 1000000000;
    inode->i_mtime.tv_sec = info.mtime / 1000000000;
    inode->i_mtime.tv_nsec = info.mtime % 1000000000;
    inode->i_ctime.tv_sec = info.ctime / 1000000000;
    inode->i_ctime.tv_nsec = info.ctime % 1000000000;

    if (S_ISDIR(info.mode)) {
        inode->i_op = &ufs_dir_inode_operations;
        inode->i_fop = &ufs_dir_operations;
    } else if (S_ISREG(info.mode)) {
        inode->i_op = &ufs_file_inode_operations;
        inode->i_fop = &ufs_file_operations;
        inode->i_mapping->a_ops = &ufs_aops;
    } else if (S_ISLNK(info.mode)) {
        inode->i_op = &ufs_symlink_inode_operations;
        inode->i_mapping->a_ops = &ufs_aops;
    } else {
        inode->i_op = &ufs_special_inode_operations;
        init_special_inode(inode, info.mode, info.rdev);
    }

    unlock_new_inode(inode);
    return inode;
}

static int ufs_write_inode(struct inode* inode, struct writeback_control* wbc) {
    struct super_block* sb = inode->i_sb;
    ufs_fs_t* fs = ufs_get_fs(sb);

    ufs_inode_info_t info = {0};
    info.inode = inode->i_ino;
    info.mode = inode->i_mode;
    info.link_count = inode->i_nlink;
    info.uid = i_uid_read(inode);
    info.gid = i_gid_read(inode);
    info.size = inode->i_size;
    info.atime = inode->i_atime.tv_sec * 1000000000 + inode->i_atime.tv_nsec;
    info.mtime = inode->i_mtime.tv_sec * 1000000000 + inode->i_mtime.tv_nsec;
    info.ctime = inode->i_ctime.tv_sec * 1000000000 + inode->i_ctime.tv_nsec;

    int ret = ufs_setattr(fs, inode->i_ino, &info, UFS_ATTR_MODE | UFS_ATTR_UID | UFS_ATTR_GID |
                          UFS_ATTR_SIZE | UFS_ATTR_ATIME | UFS_ATTR_MTIME | UFS_ATTR_CTIME);
    if (ret != UFS_OK)
        return -ufs_errno(ret);

    return 0;
}

static void ufs_evict_inode(struct inode* inode) {
    truncate_inode_pages_final(&inode->i_data);

    if (inode->i_nlink == 0 && !is_bad_inode(inode)) {
        struct super_block* sb = inode->i_sb;
        if (!UFS_SB(sb)->read_only) {
            ufs_fs_t* fs = ufs_get_fs(sb);
            ufs_delete_inode(fs, inode->i_ino);
        }
    }

    clear_inode(inode);
}

// ============================================================================
// File Operations
// ============================================================================

static int ufs_open(struct inode* inode, struct file* filp) {
    struct super_block* sb = inode->i_sb;
    ufs_fs_t* fs = ufs_get_fs(sb);

    ufs_file_t* file;
    int ret = ufs_open(fs, inode->i_ino, filp->f_flags, &file);
    if (ret != UFS_OK)
        return -ufs_errno(ret);

    filp->private_data = file;
    return 0;
}

static int ufs_release(struct inode* inode, struct file* filp) {
    ufs_file_t* file = filp->private_data;
    if (!file)
        return 0;

    int ret = ufs_close(file);
    if (ret != UFS_OK)
        return -ufs_errno(ret);

    filp->private_data = NULL;
    return 0;
}

static ssize_t ufs_read(struct file* filp, char __user* buf, size_t len, loff_t* ppos) {
    ufs_file_t* file = filp->private_data;
    if (!file)
        return -EINVAL;

    char* kbuf = kmalloc(len, GFP_KERNEL);
    if (!kbuf)
        return -ENOMEM;

    size_t bytes_read;
    int ret = ufs_read(file, kbuf, len, &bytes_read);
    if (ret != UFS_OK) {
        kfree(kbuf);
        return -ufs_errno(ret);
    }

    if (copy_to_user(buf, kbuf, bytes_read)) {
        kfree(kbuf);
        return -EFAULT;
    }

    kfree(kbuf);
    *ppos += bytes_read;
    return bytes_read;
}

static ssize_t ufs_write(struct file* filp, const char __user* buf, size_t len, loff_t* ppos) {
    struct super_block* sb = file_inode(filp)->i_sb;
    if (UFS_SB(sb)->read_only)
        return -EROFS;

    ufs_file_t* file = filp->private_data;
    if (!file)
        return -EINVAL;

    char* kbuf = kmalloc(len, GFP_KERNEL);
    if (!kbuf)
        return -ENOMEM;

    if (copy_from_user(kbuf, buf, len)) {
        kfree(kbuf);
        return -EFAULT;
    }

    size_t bytes_written;
    int ret = ufs_write(file, kbuf, len, &bytes_written);
    kfree(kbuf);

    if (ret != UFS_OK)
        return -ufs_errno(ret);

    *ppos += bytes_written;
    return bytes_written;
}

static loff_t ufs_llseek(struct file* filp, loff_t offset, int whence) {
    return generic_file_llseek(filp, offset, whence);
}

static int ufs_fsync(struct file* filp, loff_t start, loff_t end, int datasync) {
    ufs_file_t* file = filp->private_data;
    if (!file)
        return -EINVAL;

    int ret = ufs_fsync(file);
    if (ret != UFS_OK)
        return -ufs_errno(ret);

    return 0;
}

static long ufs_ioctl(struct file* filp, unsigned int cmd, unsigned long arg) {
    struct inode* inode = file_inode(filp);
    struct super_block* sb = inode->i_sb;
    ufs_fs_t* fs = ufs_get_fs(sb);

    switch (cmd) {
        case UFS_IOC_GET_FLAGS: {
            u32 flags;
            int ret = ufs_get_flags(fs, inode->i_ino, &flags);
            if (ret != UFS_OK)
                return -ufs_errno(ret);
            if (put_user(flags, (u32 __user*)arg))
                return -EFAULT;
            return 0;
        }
        case UFS_IOC_SET_FLAGS: {
            if (UFS_SB(sb)->read_only)
                return -EROFS;
            u32 flags;
            if (get_user(flags, (u32 __user*)arg))
                return -EFAULT;
            int ret = ufs_set_flags(fs, inode->i_ino, flags);
            if (ret != UFS_OK)
                return -ufs_errno(ret);
            return 0;
        }
        case UFS_IOC_GET_VERSION: {
            u64 version;
            int ret = ufs_get_version(fs, inode->i_ino, &version);
            if (ret != UFS_OK)
                return -ufs_errno(ret);
            if (put_user(version, (u64 __user*)arg))
                return -EFAULT;
            return 0;
        }
        case UFS_IOC_GET_COMPRESSION: {
            u8 compression;
            int ret = ufs_get_compression(fs, inode->i_ino, &compression);
            if (ret != UFS_OK)
                return -ufs_errno(ret);
            if (put_user(compression, (u8 __user*)arg))
                return -EFAULT;
            return 0;
        }
        case UFS_IOC_SET_COMPRESSION: {
            if (UFS_SB(sb)->read_only)
                return -EROFS;
            u8 compression;
            if (get_user(compression, (u8 __user*)arg))
                return -EFAULT;
            int ret = ufs_set_compression(fs, inode->i_ino, compression);
            if (ret != UFS_OK)
                return -ufs_errno(ret);
            return 0;
        }
        default:
            return -ENOTTY;
    }
}

// ============================================================================
// Directory Operations
// ============================================================================

static struct dentry* ufs_lookup(struct inode* dir, struct dentry* dentry, unsigned int flags) {
    struct super_block* sb = dir->i_sb;
    ufs_fs_t* fs = ufs_get_fs(sb);

    ufs_inode_t ino;
    int ret = ufs_lookup(fs, dir->i_ino, dentry->d_name.name, &ino);
    if (ret == UFS_ERROR_NOT_FOUND) {
        d_add(dentry, NULL);
        return NULL;
    }
    if (ret != UFS_OK)
        return ERR_PTR(-ufs_errno(ret));

    struct inode* inode = ufs_iget(sb, ino);
    if (IS_ERR(inode))
        return ERR_CAST(inode);

    d_add(dentry, inode);
    return NULL;
}

static int ufs_create(struct inode* dir, struct dentry* dentry, umode_t mode, bool excl) {
    struct super_block* sb = dir->i_sb;
    if (UFS_SB(sb)->read_only)
        return -EROFS;

    ufs_fs_t* fs = ufs_get_fs(sb);
    ufs_inode_t ino;
    int ret = ufs_create_inode(fs, dir->i_ino, dentry->d_name.name,
                                UFS_FILE_TYPE_REG, mode, current_fsuid().val, current_fsgid().val, &ino);
    if (ret != UFS_OK)
        return -ufs_errno(ret);

    struct inode* inode = ufs_iget(sb, ino);
    if (IS_ERR(inode))
        return PTR_ERR(inode);

    d_instantiate(dentry, inode);
    return 0;
}

static int ufs_mkdir(struct inode* dir, struct dentry* dentry, umode_t mode) {
    struct super_block* sb = dir->i_sb;
    if (UFS_SB(sb)->read_only)
        return -EROFS;

    ufs_fs_t* fs = ufs_get_fs(sb);
    ufs_inode_t ino;
    int ret = ufs_create_inode(fs, dir->i_ino, dentry->d_name.name,
                                UFS_FILE_TYPE_DIR, mode | S_IFDIR,
                                current_fsuid().val, current_fsgid().val, &ino);
    if (ret != UFS_OK)
        return -ufs_errno(ret);

    struct inode* inode = ufs_iget(sb, ino);
    if (IS_ERR(inode))
        return PTR_ERR(inode);

    inode->i_op = &ufs_dir_inode_operations;
    inode->i_fop = &ufs_dir_operations;

    d_instantiate(dentry, inode);
    return 0;
}

static int ufs_rmdir(struct inode* dir, struct dentry* dentry) {
    struct super_block* sb = dir->i_sb;
    if (UFS_SB(sb)->read_only)
        return -EROFS;

    ufs_fs_t* fs = ufs_get_fs(sb);
    int ret = ufs_rmdir(fs, dir->i_ino, dentry->d_name.name);
    if (ret != UFS_OK)
        return -ufs_errno(ret);

    d_delete(dentry);
    return 0;
}

static int ufs_unlink(struct inode* dir, struct dentry* dentry) {
    struct super_block* sb = dir->i_sb;
    if (UFS_SB(sb)->read_only)
        return -EROFS;

    ufs_fs_t* fs = ufs_get_fs(sb);
    int ret = ufs_unlink(fs, dir->i_ino, dentry->d_name.name);
    if (ret != UFS_OK)
        return -ufs_errno(ret);

    d_delete(dentry);
    return 0;
}

static int ufs_rename(struct inode* old_dir, struct dentry* old_dentry,
                      struct inode* new_dir, struct dentry* new_dentry, unsigned int flags) {
    struct super_block* sb = old_dir->i_sb;
    if (UFS_SB(sb)->read_only)
        return -EROFS;

    ufs_fs_t* fs = ufs_get_fs(sb);
    int ret = ufs_rename(fs, old_dir->i_ino, old_dentry->d_name.name,
                         new_dir->i_ino, new_dentry->d_name.name);
    if (ret != UFS_OK)
        return -ufs_errno(ret);

    return 0;
}

static int ufs_link(struct dentry* old_dentry, struct inode* dir, struct dentry* dentry) {
    struct super_block* sb = dir->i_sb;
    if (UFS_SB(sb)->read_only)
        return -EROFS;

    ufs_fs_t* fs = ufs_get_fs(sb);
    int ret = ufs_link(fs, dir->i_ino, dentry->d_name.name, old_dentry->d_inode->i_ino);
    if (ret != UFS_OK)
        return -ufs_errno(ret);

    d_instantiate(dentry, dget(old_dentry));
    return 0;
}

static int ufs_symlink(struct inode* dir, struct dentry* dentry, const char* target) {
    struct super_block* sb = dir->i_sb;
    if (UFS_SB(sb)->read_only)
        return -EROFS;

    ufs_fs_t* fs = ufs_get_fs(sb);
    ufs_inode_t ino;
    int ret = ufs_create_inode(fs, dir->i_ino, dentry->d_name.name,
                                UFS_FILE_TYPE_SYMLINK, S_IFLNK | 0777,
                                current_fsuid().val, current_fsgid().val, &ino);
    if (ret != UFS_OK)
        return -ufs_errno(ret);

    ret = ufs_write_symlink(fs, ino, target);
    if (ret != UFS_OK)
        return -ufs_errno(ret);

    struct inode* inode = ufs_iget(sb, ino);
    if (IS_ERR(inode))
        return PTR_ERR(inode);

    inode->i_op = &ufs_symlink_inode_operations;
    inode->i_mapping->a_ops = &ufs_aops;

    d_instantiate(dentry, inode);
    return 0;
}

static const char* ufs_get_link(struct dentry* dentry, struct inode* inode, struct delayed_call* done) {
    struct super_block* sb = inode->i_sb;
    ufs_fs_t* fs = ufs_get_fs(sb);

    char* target = kmalloc(PATH_MAX, GFP_KERNEL);
    if (!target)
        return ERR_PTR(-ENOMEM);

    int ret = ufs_readlink(fs, inode->i_ino, target, PATH_MAX);
    if (ret != UFS_OK) {
        kfree(target);
        return ERR_PTR(-ufs_errno(ret));
    }

    set_delayed_call(done, kfree_link, target);
    return target;
}

// ============================================================================
// Extended Attributes (via Metadata Capsules)
// ============================================================================

static int ufs_xattr_get(struct inode* inode, const char* name, void* buffer, size_t size) {
    struct super_block* sb = inode->i_sb;
    ufs_fs_t* fs = ufs_get_fs(sb);

    uint16_t ns = UFS_NS_POSIX_XATTR;
    uint16_t type = 0;

    if (strncmp(name, "user.", 5) == 0) {
        ns = UFS_NS_POSIX_XATTR;
        name += 5;
    } else if (strncmp(name, "system.posix_acl", 16) == 0) {
        ns = UFS_NS_POSIX_ACL;
        name += 16;
    } else if (strncmp(name, "security.", 9) == 0) {
        ns = UFS_NS_POSIX_CAPS;
        name += 9;
    } else if (strncmp(name, "trusted.", 8) == 0) {
        ns = UFS_NS_UFS_INTERNAL;
        name += 8;
    } else {
        return -EOPNOTSUPP;
    }

    size_t out_size;
    int ret = ufs_getxattr(fs, inode->i_ino, ns, type, name, buffer, size, &out_size);
    if (ret == UFS_ERROR_BUFFER_TOO_SMALL)
        return -ERANGE;
    if (ret != UFS_OK)
        return -ufs_errno(ret);

    return out_size;
}

static int ufs_xattr_set(struct inode* inode, const char* name, const void* value, size_t size, int flags) {
    struct super_block* sb = inode->i_sb;
    if (UFS_SB(sb)->read_only)
        return -EROFS;

    ufs_fs_t* fs = ufs_get_fs(sb);

    uint16_t ns = UFS_NS_POSIX_XATTR;
    uint16_t type = 0;

    if (strncmp(name, "user.", 5) == 0) {
        ns = UFS_NS_POSIX_XATTR;
        name += 5;
    } else if (strncmp(name, "system.posix_acl", 16) == 0) {
        ns = UFS_NS_POSIX_ACL;
        name += 16;
    } else if (strncmp(name, "security.", 9) == 0) {
        ns = UFS_NS_POSIX_CAPS;
        name += 9;
    } else if (strncmp(name, "trusted.", 8) == 0) {
        ns = UFS_NS_UFS_INTERNAL;
        name += 8;
    } else {
        return -EOPNOTSUPP;
    }

    int ret = ufs_setxattr(fs, inode->i_ino, ns, type, name, value, size, flags);
    if (ret != UFS_OK)
        return -ufs_errno(ret);

    return 0;
}

static ssize_t ufs_xattr_list(struct inode* inode, char* buffer, size_t size) {
    struct super_block* sb = inode->i_sb;
    ufs_fs_t* fs = ufs_get_fs(sb);

    size_t out_size;
    int ret = ufs_listxattr(fs, inode->i_ino, buffer, size, &out_size);
    if (ret != UFS_OK)
        return -ufs_errno(ret);

    return out_size;
}

// ============================================================================
// Address Space Operations
// ============================================================================

static sector_t ufs_bmap(struct address_space* mapping, sector_t block) {
    struct inode* inode = mapping->host;
    struct super_block* sb = inode->i_sb;
    ufs_fs_t* fs = ufs_get_fs(sb);

    u64 phys_block;
    int ret = ufs_bmap(fs, inode->i_ino, block, &phys_block);
    if (ret != UFS_OK)
        return 0;

    return phys_block;
}

static const struct address_space_operations ufs_aops = {
    .readpage = mpage_readpage,
    .readpages = mpage_readpages,
    .writepage = mpage_writepage,
    .writepages = mpage_writepages,
    .bmap = ufs_bmap,
    .direct_IO = noop_direct_IO,
};

// ============================================================================
// Superblock Operations
// ============================================================================

static int ufs_statfs(struct dentry* dentry, struct kstatfs* buf) {
    struct super_block* sb = dentry->d_sb;
    ufs_fs_t* fs = ufs_get_fs(sb);

    ufs_statfs_t stat;
    int ret = ufs_statfs(fs, &stat);
    if (ret != UFS_OK)
        return -ufs_errno(ret);

    buf->f_type = UFS_SUPER_MAGIC;
    buf->f_bsize = stat.cluster_size;
    buf->f_blocks = stat.total_space / stat.cluster_size;
    buf->f_bfree = stat.free_space / stat.cluster_size;
    buf->f_bavail = stat.free_space / stat.cluster_size;
    buf->f_files = stat.total_inodes;
    buf->f_ffree = stat.free_inodes;
    buf->f_namelen = 255;

    return 0;
}

static int ufs_sync_fs(struct super_block* sb, int wait) {
    if (UFS_SB(sb)->read_only)
        return 0;

    ufs_fs_t* fs = ufs_get_fs(sb);
    int ret = ufs_sync(fs);
    if (ret != UFS_OK)
        return -ufs_errno(ret);

    return 0;
}

static int ufs_freeze(struct super_block* sb) {
    if (UFS_SB(sb)->read_only)
        return 0;

    ufs_fs_t* fs = ufs_get_fs(sb);
    int ret = ufs_checkpoint(fs);
    if (ret != UFS_OK)
        return -ufs_errno(ret);

    return 0;
}

static int ufs_unfreeze(struct super_block* sb) {
    return 0;
}

static int ufs_show_options(struct seq_file* seq, struct dentry* root) {
    struct super_block* sb = root->d_sb;
    struct ufs_sb_info* sbi = UFS_SB(sb);

    if (sbi->read_only)
        seq_puts(seq, ",ro");
    if (sbi->case_insensitive)
        seq_puts(seq, ",case_insensitive");
    if (sbi->compression != UFS_COMPRESSION_NONE) {
        seq_printf(seq, ",compression=%s",
                   sbi->compression == UFS_COMPRESSION_LZ4 ? "lz4" : "zstd");
    }
    if (!sbi->integrity_check)
        seq_puts(seq, ",nointegrity");

    return 0;
}

static int ufs_remount_fs(struct super_block* sb, int* flags, char* data) {
    struct ufs_sb_info* sbi = UFS_SB(sb);

    if ((*flags & SB_RDONLY) && !sbi->read_only) {
        // Transition to read-only
        ufs_fs_t* fs = ufs_get_fs(sb);
        int ret = ufs_sync(fs);
        if (ret != UFS_OK)
            return -ufs_errno(ret);
        sbi->read_only = true;
    } else if (!(*flags & SB_RDONLY) && sbi->read_only) {
        // Transition to read-write
        sbi->read_only = false;
    }

    return 0;
}

static const struct super_operations ufs_super_ops = {
    .alloc_inode = ufs_alloc_inode,
    .free_inode = ufs_free_inode,
    .write_inode = ufs_write_inode,
    .evict_inode = ufs_evict_inode,
    .statfs = ufs_statfs,
    .sync_fs = ufs_sync_fs,
    .freeze = ufs_freeze,
    .unfreeze = ufs_unfreeze,
    .show_options = ufs_show_options,
    .remount_fs = ufs_remount_fs,
};

// ============================================================================
// Mount / Unmount
// ============================================================================

static struct dentry* ufs_mount(struct file_system_type* fs_type, int flags,
                                 const char* dev_name, void* data) {
    struct block_device* bdev;
    fmode_t mode = FMODE_READ;
    if (!(flags & SB_RDONLY))
        mode |= FMODE_WRITE;

    bdev = blkdev_get_by_path(dev_name, mode, fs_type);
    if (IS_ERR(bdev))
        return ERR_CAST(bdev);

    // Open block device via UFS core
    ufs_block_device_t* block_dev = ufs_block_device_open_bdev(bdev, mode);
    if (!block_dev) {
        blkdev_put(bdev, mode);
        return ERR_PTR(-EINVAL);
    }

    // Check if recovery needed
    if (ufs_needs_recovery(block_dev)) {
        int ret = ufs_recover(block_dev);
        if (ret != UFS_OK) {
            ufs_block_device_close(block_dev);
            blkdev_put(bdev, mode);
            return ERR_PTR(-ufs_errno(ret));
        }
    }

    // Parse mount options
    struct ufs_sb_info* sbi = kzalloc(sizeof(*sbi), GFP_KERNEL);
    if (!sbi) {
        ufs_block_device_close(block_dev);
        blkdev_put(bdev, mode);
        return ERR_PTR(-ENOMEM);
    }

    sbi->bdev = bdev;
    sbi->bdev_mode = mode;
    sbi->block_dev = block_dev;
    sbi->read_only = flags & SB_RDONLY;
    sbi->case_insensitive = ufs_case_insensitive;
    if (strcmp(ufs_compression, "lz4") == 0)
        sbi->compression = UFS_COMPRESSION_LZ4;
    else if (strcmp(ufs_compression, "zstd") == 0)
        sbi->compression = UFS_COMPRESSION_ZSTD;
    else
        sbi->compression = UFS_COMPRESSION_NONE;
    sbi->integrity_check = ufs_integrity_check;
    mutex_init(&sbi->lock);

    ufs_mount_options_t mount_opts = {
        .read_only = sbi->read_only,
        .case_insensitive = sbi->case_insensitive,
        .compression = sbi->compression,
        .integrity_check = sbi->integrity_check,
        .journal_size = ufs_journal_size * 1024 * 1024,
    };

    ufs_fs_t* fs;
    int ret = ufs_mount(block_dev, &mount_opts, &fs);
    if (ret != UFS_OK) {
        kfree(sbi);
        ufs_block_device_close(block_dev);
        blkdev_put(bdev, mode);
        return ERR_PTR(-ufs_errno(ret));
    }

    sbi->fs = fs;

    struct super_block* sb = sget(fs_type, NULL, set_anon_super, flags & ~SB_POSIXACL, NULL);
    if (IS_ERR(sb)) {
        ufs_unmount(fs);
        ufs_block_device_close(block_dev);
        blkdev_put(bdev, mode);
        kfree(sbi);
        return ERR_CAST(sb);
    }

    sb->s_fs_info = sbi;
    sb->s_op = &ufs_super_ops;
    sb->s_magic = UFS_SUPER_MAGIC;
    sb->s_maxbytes = MAX_LFS_FILESIZE;
    sb->s_time_gran = 1;  // nanosecond
    sb->s_flags |= SB_POSIXACL;

    if (sbi->read_only)
        sb->s_flags |= SB_RDONLY;

    struct inode* root = ufs_iget(sb, 2);  // Root inode is 2
    if (IS_ERR(root)) {
        deactivate_locked_super(sb);
        return ERR_CAST(root);
    }

    struct dentry* root_dentry = d_make_root(root);
    if (!root_dentry) {
        iput(root);
        deactivate_locked_super(sb);
        return ERR_PTR(-ENOMEM);
    }

    sb->s_root = root_dentry;
    return root_dentry;
}

static void ufs_kill_sb(struct super_block* sb) {
    struct ufs_sb_info* sbi = UFS_SB(sb);
    if (!sbi)
        return;

    ufs_unmount(sbi->fs);
    ufs_block_device_close(sbi->block_dev);
    blkdev_put(sbi->bdev, sbi->bdev_mode);
    kfree(sbi);
    kill_anon_super(sb);
}

// ============================================================================
// Module Registration
// ============================================================================

static struct file_system_type ufs_fs_type = {
    .owner = THIS_MODULE,
    .name = "ufs",
    .mount = ufs_mount,
    .kill_sb = ufs_kill_sb,
    .fs_flags = FS_REQUIRES_DEV | FS_BINARY_MOUNTDATA,
};

static int __init ufs_init(void) {
    int ret = register_filesystem(&ufs_fs_type);
    if (ret) {
        pr_err("UFS: Failed to register filesystem: %d\n", ret);
        return ret;
    }
    pr_info("UFS: Filesystem driver loaded\n");
    return 0;
}

static void __exit ufs_exit(void) {
    unregister_filesystem(&ufs_fs_type);
    pr_info("UFS: Filesystem driver unloaded\n");
}

module_init(ufs_init);
module_exit(ufs_exit);