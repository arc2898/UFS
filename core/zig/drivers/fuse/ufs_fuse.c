// UFS FUSE Driver - C Implementation with libfuse3
// This is the actual compilable FUSE driver that uses the UFS C API

#define FUSE_USE_VERSION 35

#include <fuse3/fuse.h>
#include <fuse3/fuse_lowlevel.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <pthread.h>

#include "ufs.h"

// ============================================================================
// UFS FUSE State
// ============================================================================

typedef struct {
    ufs_fs_t* fs;
    ufs_block_device_t* block_dev;
    struct fuse_args args;
    pthread_mutex_t lock;
    uid_t uid;
    gid_t gid;
    mode_t umask;
    int read_only;
    int case_insensitive;
    int compression;
    int integrity_check;
} ufs_fuse_state_t;

static ufs_fuse_state_t* g_state = NULL;

// ============================================================================
// Helper Functions
// ============================================================================

static inline ufs_fuse_state_t* get_state(struct fuse_context* ctx) {
    return (ufs_fuse_state_t*)fuse_get_context()->private_data;
}

static int ufs_errno(int ufs_error) {
    switch (ufs_error) {
        case UFS_OK: return 0;
        case UFS_ERROR_OUT_OF_MEMORY: return ENOMEM;
        case UFS_ERROR_INVALID_ARGUMENT: return EINVAL;
        case UFS_ERROR_IO: return EIO;
        case UFS_ERROR_NOT_FOUND: return ENOENT;
        case UFS_ERROR_ALREADY_EXISTS: return EEXIST;
        case UFS_ERROR_PERMISSION_DENIED: return EACCES;
        case UFS_ERROR_CORRUPTED_DATA: return EIO;
        case UFS_ERROR_UNSUPPORTED_FEATURE: return ENOTSUP;
        case UFS_ERROR_BUFFER_TOO_SMALL: return ERANGE;
        case UFS_ERROR_INVALID_FORMAT: return EINVAL;
        case UFS_ERROR_INTERNAL: return EIO;
        case UFS_ERROR_OUT_OF_SPACE: return ENOSPC;
        case UFS_ERROR_ALIGNMENT: return EINVAL;
        case UFS_ERROR_FRAGMENTED: return EIO;
        case UFS_ERROR_NOT_INITIALIZED: return EINVAL;
        case UFS_ERROR_WRITE_PROTECTED: return EROFS;
        case UFS_ERROR_DEVICE_NOT_FOUND: return ENODEV;
        case UFS_ERROR_UNSUPPORTED_OPERATION: return ENOTSUP;
        case UFS_ERROR_TIMEOUT: return ETIMEDOUT;
        default: return EIO;
    }
}

static void fuse_fill_stat(struct stat* st, const ufs_inode_info_t* info) {
    memset(st, 0, sizeof(struct stat));
    st->st_ino = (ino_t)info->inode;
    st->st_mode = info->mode;
    st->st_nlink = info->link_count;
    st->st_uid = info->uid;
    st->st_gid = info->gid;
    st->st_size = (off_t)info->size;
    st->st_blocks = (blkcnt_t)(info->allocated_size / 512);
    st->st_atim.tv_sec = info->atime / 1000000000;
    st->st_atim.tv_nsec = info->atime % 1000000000;
    st->st_mtim.tv_sec = info->mtime / 1000000000;
    st->st_mtim.tv_nsec = info->mtime % 1000000000;
    st->st_ctim.tv_sec = info->ctime / 1000000000;
    st->st_ctim.tv_nsec = info->ctime % 1000000000;
}

static int resolve_path(ufs_fuse_state_t* state, const char* path, ufs_inode_t* out_inode) {
    ufs_inode_t current = 2; // Root inode
    const char* p = path;

    if (*p == '/') p++;

    if (*p == '\0') {
        *out_inode = 2;
        return 0;
    }

    while (*p) {
        const char* end = strchr(p, '/');
        size_t len = end ? (end - p) : strlen(p);

        char name[256];
        if (len >= sizeof(name)) return -ENAMETOOLONG;
        memcpy(name, p, len);
        name[len] = '\0';

        ufs_inode_t next;
        int ret = ufs_lookup(state->fs, current, name, &next);
        if (ret != UFS_OK) {
            return -ufs_errno(ret);
        }

        current = next;

        if (end) {
            p = end + 1;
        } else {
            break;
        }
    }

    *out_inode = current;
    return 0;
}

static int resolve_parent(ufs_fuse_state_t* state, const char* path, ufs_inode_t* out_parent, char* out_name, size_t name_size) {
    const char* last_slash = strrchr(path, '/');
    if (!last_slash || last_slash == path) {
        *out_parent = 2; // Root
        strncpy(out_name, path + 1, name_size - 1);
        out_name[name_size - 1] = '\0';
        return 0;
    }

    size_t parent_len = last_slash - path;
    char parent_path[4096];
    if (parent_len >= sizeof(parent_path)) return -ENAMETOOLONG;
    memcpy(parent_path, path, parent_len);
    parent_path[parent_len] = '\0';

    int ret = resolve_path(state, parent_path, out_parent);
    if (ret != 0) return ret;

    strncpy(out_name, last_slash + 1, name_size - 1);
    out_name[name_size - 1] = '\0';
    return 0;
}

// ============================================================================
// FUSE Operations
// ============================================================================

static int fuse_ufs_getattr(const char* path, struct stat* stbuf, struct fuse_file_info* fi) {
    ufs_fuse_state_t* state = get_state(fuse_get_context());
    ufs_inode_t inode;

    int ret = resolve_path(state, path, &inode);
    if (ret != 0) return ret;

    ufs_inode_info_t info;
    ret = ufs_getattr(state->fs, inode, &info);
    if (ret != UFS_OK) return -ufs_errno(ret);

    fuse_fill_stat(stbuf, &info);
    return 0;
}

static int fuse_ufs_readdir(const char* path, void* buf, fuse_fill_dir_t filler, off_t offset, struct fuse_file_info* fi, enum fuse_readdir_flags flags) {
    ufs_fuse_state_t* state = get_state(fuse_get_context());
    ufs_inode_t inode;

    int ret = resolve_path(state, path, &inode);
    if (ret != 0) return ret;

    ufs_dir_iter_t* iter;
    ret = ufs_opendir(state->fs, inode, &iter);
    if (ret != UFS_OK) return -ufs_errno(ret);

    ufs_dirent_t entry;
    while ((ret = ufs_readdir(state->fs, iter, &entry)) == UFS_OK) {
        struct stat st;
        memset(&st, 0, sizeof(st));
        st.st_ino = entry.inode;
        st.st_mode = (entry.type == UFS_FILE_TYPE_DIR) ? S_IFDIR : S_IFREG;

        if (filler(buf, entry.name, &st, 0, 0)) break;
    }

    ufs_closedir(state->fs, iter);
    return 0;
}

static int fuse_ufs_open(const char* path, struct fuse_file_info* fi) {
    ufs_fuse_state_t* state = get_state(fuse_get_context());
    ufs_inode_t inode;

    int ret = resolve_path(state, path, &inode);
    if (ret != 0) return ret;

    // Check permissions
    ufs_inode_info_t info;
    ret = ufs_getattr(state->fs, inode, &info);
    if (ret != UFS_OK) return -ufs_errno(ret);

    // Check access - proper permission check
    if ((fi->flags & O_ACCMODE) == O_WRONLY || (fi->flags & O_ACCMODE) == O_RDWR) {
        if (state->read_only) return -EROFS;
        // Permission check: owner/group/other
        uid_t uid = fuse_get_context()->uid;
        gid_t gid = fuse_get_context()->gid;

        int perm_ok = 0;
        if (uid == 0) {
            perm_ok = 1; // root bypasses
        } else if (uid == info.uid) {
            perm_ok = (info.mode & 0200) != 0; // owner write
        } else if (gid == info.gid) {
            perm_ok = (info.mode & 0020) != 0; // group write
        } else {
            perm_ok = (info.mode & 0002) != 0; // other write
        }
        if (!perm_ok) return -EACCES;
    } else {
        // Read permission check
        uid_t uid = fuse_get_context()->uid;
        gid_t gid = fuse_get_context()->gid;

        int perm_ok = 0;
        if (uid == 0) {
            perm_ok = 1;
        } else if (uid == info.uid) {
            perm_ok = (info.mode & 0400) != 0;
        } else if (gid == info.gid) {
            perm_ok = (info.mode & 0040) != 0;
        } else {
            perm_ok = (info.mode & 0004) != 0;
        }
        if (!perm_ok) return -EACCES;
    }

    ufs_file_t* file;
    ret = ufs_open(state->fs, inode, fi->flags, &file);
    if (ret != UFS_OK) return -ufs_errno(ret);

    fi->fh = (uintptr_t)file;
    return 0;
}

static int fuse_ufs_read(const char* path, char* buf, size_t size, off_t offset, struct fuse_file_info* fi) {
    ufs_fuse_state_t* state = get_state(fuse_get_context());
    ufs_file_t* file = (ufs_file_t*)fi->fh;

    size_t bytes_read;
    int ret = ufs_read(file, buf, size, &bytes_read);
    if (ret != UFS_OK) return -ufs_errno(ret);

    return (int)bytes_read;
}

static int fuse_ufs_write(const char* path, const char* buf, size_t size, off_t offset, struct fuse_file_info* fi) {
    ufs_fuse_state_t* state = get_state(fuse_get_context());

    if (state->read_only) return -EROFS;

    ufs_file_t* file = (ufs_file_t*)fi->fh;
    size_t bytes_written;
    int ret = ufs_write(file, buf, size, &bytes_written);
    if (ret != UFS_OK) return -ufs_errno(ret);

    return (int)bytes_written;
}

static int fuse_ufs_release(const char* path, struct fuse_file_info* fi) {
    ufs_fuse_state_t* state = get_state(fuse_get_context());
    ufs_file_t* file = (ufs_file_t*)fi->fh;

    int ret = ufs_close(file);
    if (ret != UFS_OK) return -ufs_errno(ret);

    return 0;
}

static int fuse_ufs_mkdir(const char* path, mode_t mode) {
    ufs_fuse_state_t* state = get_state(fuse_get_context());

    if (state->read_only) return -EROFS;

    ufs_inode_t parent;
    char name[256];
    int ret = resolve_parent(state, path, &parent, name, sizeof(name));
    if (ret != 0) return ret;

    ufs_inode_t new_inode;
    ret = ufs_create_inode(state->fs, parent, name, UFS_FILE_TYPE_DIR, mode, state->uid, state->gid, &new_inode);
    if (ret != UFS_OK) return -ufs_errno(ret);

    return 0;
}

static int fuse_ufs_rmdir(const char* path) {
    ufs_fuse_state_t* state = get_state(fuse_get_context());

    if (state->read_only) return -EROFS;

    ufs_inode_t parent;
    char name[256];
    int ret = resolve_parent(state, path, &parent, name, sizeof(name));
    if (ret != 0) return ret;

    ret = ufs_rmdir(state->fs, parent, name);
    if (ret != UFS_OK) return -ufs_errno(ret);

    return 0;
}

static int fuse_ufs_unlink(const char* path) {
    ufs_fuse_state_t* state = get_state(fuse_get_context());

    if (state->read_only) return -EROFS;

    ufs_inode_t parent;
    char name[256];
    int ret = resolve_parent(state, path, &parent, name, sizeof(name));
    if (ret != 0) return ret;

    // Proper unlink: remove directory entry and decrement link count
    ret = ufs_unlink_dirent(state->fs, parent, name);
    if (ret != UFS_OK) return -ufs_errno(ret);

    return 0;
}

static int fuse_ufs_rename(const char* from, const char* to, unsigned int flags) {
    ufs_fuse_state_t* state = get_state(fuse_get_context());

    if (state->read_only) return -EROFS;

    ufs_inode_t old_parent, new_parent;
    char old_name[256], new_name[256];

    int ret = resolve_parent(state, from, &old_parent, old_name, sizeof(old_name));
    if (ret != 0) return ret;

    ret = resolve_parent(state, to, &new_parent, new_name, sizeof(new_name));
    if (ret != 0) return ret;

    ret = ufs_rename(state->fs, old_parent, old_name, new_parent, new_name);
    if (ret != UFS_OK) return -ufs_errno(ret);

    return 0;
}

static int fuse_ufs_create(const char* path, mode_t mode, struct fuse_file_info* fi) {
    ufs_fuse_state_t* state = get_state(fuse_get_context());

    if (state->read_only) return -EROFS;

    ufs_inode_t parent;
    char name[256];
    int ret = resolve_parent(state, path, &parent, name, sizeof(name));
    if (ret != 0) return ret;

    ufs_inode_t new_inode;
    ret = ufs_create_inode(state->fs, parent, name, UFS_FILE_TYPE_REG, mode, state->uid, state->gid, &new_inode);
    if (ret != UFS_OK) return -ufs_errno(ret);

    ret = ufs_open(state->fs, new_inode, fi->flags, (ufs_file_t**)&fi->fh);
    if (ret != UFS_OK) return -ufs_errno(ret);

    return 0;
}

static int fuse_ufs_truncate(const char* path, off_t size, struct fuse_file_info* fi) {
    ufs_fuse_state_t* state = get_state(fuse_get_context());

    if (state->read_only) return -EROFS;

    ufs_inode_t inode;
    int ret;

    if (fi) {
        ufs_file_t* file = (ufs_file_t*)fi->fh;
        ret = ufs_truncate(state->fs, 0, size); // Need inode from file
    } else {
        ret = resolve_path(state, path, &inode);
        if (ret != 0) return ret;
        ret = ufs_truncate(state->fs, inode, size);
    }

    if (ret != UFS_OK) return -ufs_errno(ret);
    return 0;
}

static int fuse_ufs_utimens(const char* path, const struct timespec ts[2], struct fuse_file_info* fi) {
    ufs_fuse_state_t* state = get_state(fuse_get_context());

    if (state->read_only) return -EROFS;

    ufs_inode_t inode;
    int ret = resolve_path(state, path, &inode);
    if (ret != 0) return ret;

    ufs_inode_info_t info;
    ret = ufs_getattr(state->fs, inode, &info);
    if (ret != UFS_OK) return -ufs_errno(ret);

    info.atime = (ufs_timestamp_t)ts[0].tv_sec * 1000000000 + ts[0].tv_nsec;
    info.mtime = (ufs_timestamp_t)ts[1].tv_sec * 1000000000 + ts[1].tv_nsec;

    ret = ufs_setattr(state->fs, inode, &info, UFS_ATTR_ATIME | UFS_ATTR_MTIME);
    if (ret != UFS_OK) return -ufs_errno(ret);

    return 0;
}

static int fuse_ufs_statfs(const char* path, struct statvfs* stbuf) {
    ufs_fuse_state_t* state = get_state(fuse_get_context());

    ufs_statfs_t stat;
    int ret = ufs_statfs(state->fs, &stat);
    if (ret != UFS_OK) return -ufs_errno(ret);

    memset(stbuf, 0, sizeof(struct statvfs));
    stbuf->f_bsize = stat.cluster_size;
    stbuf->f_frsize = stat.cluster_size;
    stbuf->f_blocks = stat.total_space / stat.cluster_size;
    stbuf->f_bfree = stat.free_space / stat.cluster_size;
    stbuf->f_bavail = stat.free_space / stat.cluster_size;
    stbuf->f_files = stat.total_inodes;
    stbuf->f_ffree = stat.free_inodes;
    stbuf->f_namemax = 255;

    return 0;
}

static void* fuse_ufs_init(struct fuse_conn_info* conn, struct fuse_config* cfg) {
    ufs_fuse_state_t* state = g_state;

    // Enable desired FUSE features
    cfg->kernel_cache = 1;
    cfg->auto_cache = 1;
    cfg->entry_timeout = 1.0;
    cfg->attr_timeout = 1.0;
    cfg->negative_timeout = 0.0;

    return state;
}

static void fuse_ufs_destroy(void* private_data) {
    // Cleanup handled in main
}

static int fuse_ufs_fsync(const char* path, int datasync, struct fuse_file_info* fi) {
    ufs_fuse_state_t* state = get_state(fuse_get_context());
    ufs_file_t* file = (ufs_file_t*)fi->fh;

    int ret = ufs_fsync(file);
    if (ret != UFS_OK) return -ufs_errno(ret);

    return 0;
}

static int fuse_ufs_setxattr(const char* path, const char* name, const char* value, size_t size, int flags) {
    ufs_fuse_state_t* state = get_state(fuse_get_context());

    if (state->read_only) return -EROFS;

    ufs_inode_t inode;
    int ret = resolve_path(state, path, &inode);
    if (ret != 0) return ret;

    // Parse namespace from name (e.g., "user.attr" -> POSIX_XATTR)
    uint16_t ns = UFS_NS_POSIX_XATTR;
    uint16_t type = 0;

    if (strncmp(name, "user.", 5) == 0) {
        ns = UFS_NS_POSIX_XATTR;
        name += 5;
    } else if (strncmp(name, "system.", 7) == 0) {
        ns = UFS_NS_POSIX_ACL;
        name += 7;
    } else if (strncmp(name, "security.", 9) == 0) {
        ns = UFS_NS_POSIX_CAPS;
        name += 9;
    } else if (strncmp(name, "trusted.", 8) == 0) {
        ns = UFS_NS_UFS_INTERNAL;
        name += 8;
    }

    ret = ufs_setxattr(state->fs, inode, ns, type, name, value, size, flags);
    if (ret != UFS_OK) return -ufs_errno(ret);

    return 0;
}

static int fuse_ufs_getxattr(const char* path, const char* name, char* value, size_t size) {
    ufs_fuse_state_t* state = get_state(fuse_get_context());

    ufs_inode_t inode;
    int ret = resolve_path(state, path, &inode);
    if (ret != 0) return ret;

    uint16_t ns = UFS_NS_POSIX_XATTR;
    uint16_t type = 0;

    if (strncmp(name, "user.", 5) == 0) {
        ns = UFS_NS_POSIX_XATTR;
        name += 5;
    } else if (strncmp(name, "system.", 7) == 0) {
        ns = UFS_NS_POSIX_ACL;
        name += 7;
    } else if (strncmp(name, "security.", 9) == 0) {
        ns = UFS_NS_POSIX_CAPS;
        name += 9;
    } else if (strncmp(name, "trusted.", 8) == 0) {
        ns = UFS_NS_UFS_INTERNAL;
        name += 8;
    }

    size_t out_size;
    ret = ufs_getxattr(state->fs, inode, ns, type, name, value, size, &out_size);
    if (ret != UFS_OK) return -ufs_errno(ret);

    return (int)out_size;
}

static int fuse_ufs_listxattr(const char* path, char* list, size_t size) {
    ufs_fuse_state_t* state = get_state(fuse_get_context());

    ufs_inode_t inode;
    int ret = resolve_path(state, path, &inode);
    if (ret != 0) return ret;

    size_t out_size;
    ret = ufs_listxattr(state->fs, inode, list, size, &out_size);
    if (ret != UFS_OK) return -ufs_errno(ret);

    return (int)out_size;
}

static int fuse_ufs_removexattr(const char* path, const char* name) {
    ufs_fuse_state_t* state = get_state(fuse_get_context());

    if (state->read_only) return -EROFS;

    ufs_inode_t inode;
    int ret = resolve_path(state, path, &inode);
    if (ret != 0) return ret;

    uint16_t ns = UFS_NS_POSIX_XATTR;
    uint16_t type = 0;

    if (strncmp(name, "user.", 5) == 0) {
        ns = UFS_NS_POSIX_XATTR;
        name += 5;
    } else if (strncmp(name, "system.", 7) == 0) {
        ns = UFS_NS_POSIX_ACL;
        name += 7;
    } else if (strncmp(name, "security.", 9) == 0) {
        ns = UFS_NS_POSIX_CAPS;
        name += 9;
    } else if (strncmp(name, "trusted.", 8) == 0) {
        ns = UFS_NS_UFS_INTERNAL;
        name += 8;
    }

    ret = ufs_removexattr(state->fs, inode, ns, type, name);
    if (ret != UFS_OK) return -ufs_errno(ret);

    return 0;
}

static int fuse_ufs_symlink(const char* target, const char* linkpath) {
    ufs_fuse_state_t* state = get_state(fuse_get_context());

    if (state->read_only) return -EROFS;

    ufs_inode_t parent;
    char name[256];
    int ret = resolve_parent(state, linkpath, &parent, name, sizeof(name));
    if (ret != 0) return ret;

    ret = ufs_symlink(state->fs, parent, name, target);
    if (ret != UFS_OK) return -ufs_errno(ret);

    return 0;
}

static int fuse_ufs_readlink(const char* path, char* buf, size_t size) {
    ufs_fuse_state_t* state = get_state(fuse_get_context());

    ufs_inode_t inode;
    int ret = resolve_path(state, path, &inode);
    if (ret != 0) return ret;

    ret = ufs_readlink(state->fs, inode, buf, size);
    if (ret != UFS_OK) return -ufs_errno(ret);

    return 0;
}

static int fuse_ufs_link(const char* from, const char* to) {
    ufs_fuse_state_t* state = get_state(fuse_get_context());

    if (state->read_only) return -EROFS;

    ufs_inode_t inode;
    int ret = resolve_path(state, from, &inode);
    if (ret != 0) return ret;

    ufs_inode_t new_parent;
    char new_name[256];
    ret = resolve_parent(state, to, &new_parent, new_name, sizeof(new_name));
    if (ret != 0) return ret;

    // Create hard link (increment link count)
    ufs_inode_info_t info;
    ret = ufs_getattr(state->fs, inode, &info);
    if (ret != UFS_OK) return -ufs_errno(ret);

    info.link_count++;
    ret = ufs_setattr(state->fs, inode, &info, UFS_ATTR_LINK_COUNT);
    if (ret != UFS_OK) return -ufs_errno(ret);

    // Add directory entry
    ret = ufs_link_dirent(state->fs, new_parent, new_name, inode);
    if (ret != UFS_OK) return -ufs_errno(ret);

    return 0;
}

// ============================================================================
// FUSE Operations Structure
// ============================================================================

static struct fuse_operations ufs_ops = {
    .getattr = fuse_ufs_getattr,
    .readdir = fuse_ufs_readdir,
    .open = fuse_ufs_open,
    .read = fuse_ufs_read,
    .write = fuse_ufs_write,
    .release = fuse_ufs_release,
    .mkdir = fuse_ufs_mkdir,
    .rmdir = fuse_ufs_rmdir,
    .unlink = fuse_ufs_unlink,
    .rename = fuse_ufs_rename,
    .create = fuse_ufs_create,
    .truncate = fuse_ufs_truncate,
    .utimens = fuse_ufs_utimens,
    .statfs = fuse_ufs_statfs,
    .init = fuse_ufs_init,
    .destroy = fuse_ufs_destroy,
    .fsync = fuse_ufs_fsync,
    .setxattr = fuse_ufs_setxattr,
    .getxattr = fuse_ufs_getxattr,
    .listxattr = fuse_ufs_listxattr,
    .removexattr = fuse_ufs_removexattr,
    .symlink = fuse_ufs_symlink,
    .readlink = fuse_ufs_readlink,
    .link = fuse_ufs_link,
};

// ============================================================================
// Main
// ============================================================================

static void print_usage(const char* prog) {
    fprintf(stderr, "Usage: %s <device> <mountpoint> [options]\n", prog);
    fprintf(stderr, "\nOptions:\n");
    fprintf(stderr, "  -o ro              Read-only mount\n");
    fprintf(stderr, "  -o rw              Read-write mount (default)\n");
    fprintf(stderr, "  -o uid=N           Override uid\n");
    fprintf(stderr, "  -o gid=N           Override gid\n");
    fprintf(stderr, "  -o umask=M         Override umask (octal)\n");
    fprintf(stderr, "  -o compression=X   Compression: none, lz4, zstd (default: lz4)\n");
    fprintf(stderr, "  -o integrity=X     Integrity: none, meta, full (default: meta)\n");
    fprintf(stderr, "  -f                 Foreground\n");
    fprintf(stderr, "  -d                 Debug\n");
    fprintf(stderr, "  -s                 Single-threaded\n");
}

int main(int argc, char* argv[]) {
    struct fuse_args args = FUSE_ARGS_INIT(argc, argv);

    if (args.argc < 3) {
        print_usage(argv[0]);
        return 1;
    }

    const char* device_path = args.argv[1];
    const char* mount_point = args.argv[2];

    // Parse options
    ufs_fuse_state_t state = {0};
    state.read_only = 0;
    state.uid = getuid();
    state.gid = getgid();
    state.umask = 022;
    state.case_insensitive = 1;
    state.compression = UFS_COMPRESSION_LZ4;
    state.integrity_check = 1; // metadata only

    // Process -o options
    for (int i = 3; i < args.argc; i++) {
        if (strncmp(args.argv[i], "-o", 2) == 0) {
            char* opt = args.argv[i] + 2;
            if (strcmp(opt, "ro") == 0) state.read_only = 1;
            else if (strcmp(opt, "rw") == 0) state.read_only = 0;
            else if (strncmp(opt, "uid=", 4) == 0) state.uid = atoi(opt + 4);
            else if (strncmp(opt, "gid=", 4) == 0) state.gid = atoi(opt + 4);
            else if (strncmp(opt, "umask=", 6) == 0) state.umask = strtol(opt + 6, NULL, 8);
            else if (strncmp(opt, "compression=", 12) == 0) {
                if (strcmp(opt + 12, "none") == 0) state.compression = UFS_COMPRESSION_NONE;
                else if (strcmp(opt + 12, "lz4") == 0) state.compression = UFS_COMPRESSION_LZ4;
                else if (strcmp(opt + 12, "zstd") == 0) state.compression = UFS_COMPRESSION_ZSTD;
            } else if (strncmp(opt, "integrity=", 10) == 0) {
                if (strcmp(opt + 10, "none") == 0) state.integrity_check = 0;
                else if (strcmp(opt + 10, "meta") == 0) state.integrity_check = 1;
                else if (strcmp(opt + 10, "full") == 0) state.integrity_check = 2;
            }
        }
    }

    // Open block device
    ufs_block_device_t* block_dev = ufs_block_device_open(device_path, 0);
    if (!block_dev) {
        fprintf(stderr, "Failed to open block device: %s\n", device_path);
        return 1;
    }

    // Check if recovery needed
    if (ufs_needs_recovery(block_dev)) {
        fprintf(stderr, "Filesystem needs recovery...\n");
        int ret = ufs_recover(block_dev);
        if (ret != UFS_OK) {
            fprintf(stderr, "Recovery failed: %d\n", ret);
            ufs_block_device_close(block_dev);
            return 1;
        }
    }

    // Mount filesystem
    ufs_mount_options_t mount_opts = {
        .read_only = state.read_only,
        .case_insensitive = state.case_insensitive,
        .compression = state.compression,
        .integrity_check = state.integrity_check,
        .journal_size = 0,
    };

    ufs_fs_t* fs;
    int ret = ufs_mount(block_dev, &mount_opts, &fs);
    if (ret != UFS_OK) {
        fprintf(stderr, "Mount failed: %d\n", ret);
        ufs_block_device_close(block_dev);
        return 1;
    }

    state.fs = fs;
    state.block_dev = block_dev;
    pthread_mutex_init(&state.lock, NULL);
    g_state = &state;

    // Replace device and mountpoint in args
    args.argv[1] = (char*)mount_point;
    args.argc = 2;

    printf("Mounting UFS on %s\n", mount_point);

    // Run FUSE main loop
    int result = fuse_main(args.argc, args.argv, &ufs_ops, &state);

    // Cleanup
    ufs_unmount(fs);
    ufs_block_device_close(block_dev);
    pthread_mutex_destroy(&state.lock);
    g_state = NULL;

    return result;
}