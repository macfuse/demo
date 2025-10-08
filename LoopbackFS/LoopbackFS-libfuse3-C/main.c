//
//  main.c
//  LoopbackFS-libfuse3-C
//
//  Created by Benjamin Fleischer on 08.10.25.
//

/*
 FUSE: Filesystem in Userspace
 Copyright (C) 2001-2007  Miklos Szeredi <miklos@szeredi.hu>
 Copyright (C) 2025  Benjamin Fleischer

 This program can be distributed under the terms of the GNU GPL.
 See the file LICENSE.txt.
 */

/*
 * Loopback macFUSE file system in C. Uses the high-level FUSE API.
 * Based on the fusexmp_fh.c example from the Linux FUSE distribution.
 * Amit Singh <http://osxbook.com>
 */

#include <AvailabilityMacros.h>

#define HAVE_ACCESS 0

#define FUSE_USE_VERSION 317

#define _GNU_SOURCE

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <fuse3/fuse.h>
#include <fuse3/fuse_lowlevel.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/attr.h>
#include <sys/mount.h>
#include <sys/param.h>
#include <sys/time.h>
#include <sys/vnode.h>
#include <sys/xattr.h>
#include <unistd.h>

#if defined(_POSIX_C_SOURCE)
typedef unsigned char  u_char;
typedef unsigned short u_short;
typedef unsigned int   u_int;
typedef unsigned long  u_long;
#endif

struct loopback {
    uint32_t blocksize;
    bool case_insensitive;
};

static struct loopback loopback;

static void
stat_to_attr(struct stat *stbuf, struct fuse_darwin_attr *attr)
{
    attr->ino = stbuf->st_ino;
    attr->mode = stbuf->st_mode;
    attr->nlink = stbuf->st_nlink;
    attr->uid = stbuf->st_uid;
    attr->gid = stbuf->st_gid;
    attr->rdev = stbuf->st_rdev;
    attr->atimespec = stbuf->st_atimespec;
    attr->mtimespec = stbuf->st_mtimespec;
    attr->ctimespec = stbuf->st_ctimespec;
    attr->size = stbuf->st_size;
    attr->blocks = stbuf->st_blocks;
    attr->blksize = stbuf->st_blksize;
    attr->flags = stbuf->st_flags;
}

static int
getattr(const char *path, struct fuse_file_info *fi,
        struct fuse_darwin_attr *attr)
{
    int res;
    struct stat stbuf;
    struct attrlist attributes;

    if (fi) {
        res = fstat(fi->fh, &stbuf);
    } else {
        res = lstat(path, &stbuf);
    }
    if (res == -1) {
        return -errno;
    }

    stat_to_attr(&stbuf, attr);

    attributes.bitmapcount = ATTR_BIT_MAP_COUNT;
    attributes.reserved = 0;
    attributes.commonattr = ATTR_CMN_CRTIME | ATTR_CMN_BKUPTIME;
    attributes.dirattr = 0;
    attributes.fileattr = 0;
    attributes.forkattr = 0;
    attributes.volattr = 0;

    struct timespecbuf {
        uint32_t size;
        struct timespec btimespec;
        struct timespec bkuptimespec;
    } __attribute__ ((packed)) buf;

    if (fi) {
        res = fgetattrlist(fi->fh, &attributes, &buf, sizeof(buf), 0);
    } else {
        res = getattrlist(path, &attributes, &buf, sizeof(buf), FSOPT_NOFOLLOW);
    }
    if (res == -1) {
        (void)memset(&attr->btimespec, 0, sizeof(attr->btimespec));
        (void)memset(&attr->bkuptimespec, 0, sizeof(attr->bkuptimespec));
    } else {
        (void)memcpy(&attr->btimespec, &buf.btimespec,
                     sizeof(attr->btimespec));
        (void)memcpy(&attr->bkuptimespec, &buf.bkuptimespec,
                     sizeof(attr->btimespec));
    }

    return 0;
}

static int
getattrat(int fd, const char *path, struct fuse_darwin_attr *attr)
{
    int res;
    struct stat stbuf;
    struct attrlist attributes;

    res = fstatat(fd, path, &stbuf, AT_SYMLINK_NOFOLLOW);
    if (res == -1) {
        return -errno;
    }

    stat_to_attr(&stbuf, attr);

    attributes.bitmapcount = ATTR_BIT_MAP_COUNT;
    attributes.reserved = 0;
    attributes.commonattr = ATTR_CMN_CRTIME | ATTR_CMN_BKUPTIME;
    attributes.dirattr = 0;
    attributes.fileattr = 0;
    attributes.forkattr = 0;
    attributes.volattr = 0;

    struct timespecbuf {
        uint32_t size;
        struct timespec btimespec;
        struct timespec bkuptimespec;
    } __attribute__ ((packed)) buf;

    res = getattrlistat(fd, path, &attributes, &buf, sizeof(buf),
                        FSOPT_NOFOLLOW);
    if (res == 0) {
        (void)memcpy(&attr->btimespec, &buf.btimespec,
                     sizeof(struct timespec));
        (void)memcpy(&attr->bkuptimespec, &buf.bkuptimespec,
                     sizeof(struct timespec));
    } else {
        (void)memset(&attr->btimespec, 0, sizeof(struct timespec));
        (void)memset(&attr->bkuptimespec, 0, sizeof(struct timespec));
    }

    return 0;
}

static void *
loopback_init(struct fuse_conn_info *conn, struct fuse_config *cfg)
{
    fuse_darwin_set_feature_flag(conn, FUSE_DARWIN_CAP_SETVOLNAME);
    fuse_darwin_set_feature_flag(conn, FUSE_DARWIN_CAP_THREAD_SAFE);

#if HAVE_ACCESS
    fuse_darwin_set_feature_flag(conn, FUSE_DARWIN_CAP_ACCESS_EXT);
#endif

#ifdef FUSE_ENABLE_CASE_INSENSITIVE
    if (loopback.case_insensitive) {
        fuse_darwin_set_feature_flag(conn, FUSE_DARWIN_CAP_CASE_INSENSITIVE);
    }
#endif

    cfg->use_ino = 1;
    cfg->nullpath_ok = 1;

    return NULL;
}

static int
loopback_getattr(const char *path, struct fuse_darwin_attr *attr,
                 struct fuse_file_info *fi)
{
    int res;

    res = getattr(path, fi, attr);

    /*
     * The optimal I/O size can be set on a per-file basis. Setting blksize to
     * zero will cause the kernel extension to fall back on the global I/O size
     * which can be specified at mount-time (option iosize).
     */
    attr->blksize = 0;

    return res;
}

static int
loopback_setattr(const char *path, struct fuse_darwin_attr *attr, int to_set,
                 struct fuse_file_info *fi)
{
    int res;
    uid_t uid = -1;
    gid_t gid = -1;

    if (to_set & FUSE_SET_ATTR_MODE) {
        if (fi) {
            res = fchmod(fi->fh, attr->mode);
        } else {
            res = lchmod(path, attr->mode);
        }
        if (res == -1) {
            return -errno;
        }
    }

    if (to_set & FUSE_SET_ATTR_UID) {
        uid = attr->uid;
    }
    if (to_set & FUSE_SET_ATTR_GID) {
        gid = attr->gid;
    }
    if ((uid != -1) || (gid != -1)) {
        if (fi) {
            res = fchown(fi->fh, uid, gid);
        } else {
            res = lchown(path, uid, gid);
        }
        if (res == -1) {
            return -errno;
        }
    }

    if (to_set & FUSE_SET_ATTR_SIZE) {
        if (fi) {
            res = ftruncate(fi->fh, attr->size);
        } else {
            res = truncate(path, attr->size);
        }
        if (res == -1) {
            return -errno;
        }
    }

    if (to_set & FUSE_SET_ATTR_MTIME) {
        struct timeval tv[2];
        if ((to_set & FUSE_SET_ATTR_ATIME) == 0) {
            gettimeofday(&tv[0], NULL);
        } else {
            tv[0].tv_sec = attr->atimespec.tv_sec;
            tv[0].tv_usec = attr->atimespec.tv_nsec / 1000;
        }
        tv[1].tv_sec = attr->mtimespec.tv_sec;
        tv[1].tv_usec = attr->mtimespec.tv_nsec / 1000;

        if (fi) {
            res = futimes(fi->fh, tv);
        } else {
            res = lutimes(path, tv);
        }
        if (res == -1) {
            return -errno;
        }
    }

    if (to_set & FUSE_SET_ATTR_CTIME) {
        struct attrlist attributes;

        attributes.bitmapcount = ATTR_BIT_MAP_COUNT;
        attributes.reserved = 0;
        attributes.commonattr = ATTR_CMN_CHGTIME;
        attributes.dirattr = 0;
        attributes.fileattr = 0;
        attributes.forkattr = 0;
        attributes.volattr = 0;

        if (fi) {
            res = fsetattrlist(fi->fh, &attributes, &attr->ctimespec,
                               sizeof(struct timespec), FSOPT_NOFOLLOW);
        } else {
            res = setattrlist(path, &attributes, &attr->ctimespec,
                              sizeof(struct timespec), FSOPT_NOFOLLOW);
        }
        if (res == -1) {
            return -errno;
        }
    }

    if (to_set & FUSE_SET_ATTR_BTIME) {
        struct attrlist attributes;

        attributes.bitmapcount = ATTR_BIT_MAP_COUNT;
        attributes.reserved = 0;
        attributes.commonattr = ATTR_CMN_CRTIME;
        attributes.dirattr = 0;
        attributes.fileattr = 0;
        attributes.forkattr = 0;
        attributes.volattr = 0;

        if (fi) {
            res = fsetattrlist(fi->fh, &attributes, &attr->btimespec,
                               sizeof(struct timespec), FSOPT_NOFOLLOW);
        } else {
            res = setattrlist(path, &attributes, &attr->btimespec,
                              sizeof(struct timespec), FSOPT_NOFOLLOW);
        }
        if (res == -1) {
            return -errno;
        }
    }

    if (to_set & FUSE_SET_ATTR_BKUPTIME) {
        struct attrlist attributes;

        attributes.bitmapcount = ATTR_BIT_MAP_COUNT;
        attributes.reserved = 0;
        attributes.commonattr = ATTR_CMN_BKUPTIME;
        attributes.dirattr = 0;
        attributes.fileattr = 0;
        attributes.forkattr = 0;
        attributes.volattr = 0;

        if (fi) {
            res = fsetattrlist(fi->fh, &attributes, &attr->bkuptimespec,
                               sizeof(struct timespec), FSOPT_NOFOLLOW);
        } else {
            res = setattrlist(path, &attributes, &attr->bkuptimespec,
                              sizeof(struct timespec), FSOPT_NOFOLLOW);
        }
        if (res == -1) {
            return -errno;
        }
    }

    if (to_set & FUSE_SET_ATTR_FLAGS) {
        if (fi) {
            res = fchflags(fi->fh, attr->flags);
        } else {
            res = lchflags(path, attr->flags);
        }
        if (res == -1) {
            return -errno;
        }
    }

    return 0;
}

#if HAVE_ACCESS

static int
loopback_access(const char *path, int mask)
{
    int res;

    /*
     * Standard access permission flags:
     * F_OK            test for existence of file
     * X_OK            test for execute or search permission
     * W_OK            test for write permission
     * R_OK            test for read permission
     *
     * Extended access permission flags that can be enabled by setting
     * FUSE_CAP_ACCESS_EXTENDED (See loopback_init()):
     * _READ_OK        read file data / read directory
     * _WRITE_OK       write file data / add file to directory
     * _EXECUTE_OK     execute file / search in directory
     * _DELETE_OK      delete file / delete directory
     * _APPEND_OK      append to file / add subdirectory to directory
     * _RMFILE_OK      remove file from directory
     * _RATTR_OK       read basic attributes
     * _WATTR_OK       write basic attributes
     * _REXT_OK        read extended attributes
     * _WEXT_OK        write extended attributes
     * _RPERM_OK       read permissions
     * _WPERM_OK       write permissions
     * _CHOWN_OK       change ownership
     */

    res = access(path, mask & (F_OK | X_OK | W_OK | R_OK));
    return res == 0 ? 0 : -errno;
}

#endif /* HAVE_ACCESS */

static int
loopback_readlink(const char *path, char *buf, size_t size)
{
    int res;

    res = readlink(path, buf, size - 1);
    if (res == -1) {
        return -errno;
    }

    buf[res] = '\0';
    return 0;
}

struct loopback_dirp {
    DIR *dp;
    struct dirent *entry;
    off_t offset;
};

static int
loopback_opendir(const char *path, struct fuse_file_info *fi)
{
    int res;

    struct loopback_dirp *d = malloc(sizeof(struct loopback_dirp));
    if (!d) {
        return -ENOMEM;
    }

    d->dp = opendir(path);
    if (!d->dp) {
        res = -errno;
        free(d);
        return res;
    }

    d->offset = 0;
    d->entry = NULL;

    fi->fh = (unsigned long)d;
    return 0;
}

static inline struct loopback_dirp *
get_dirp(struct fuse_file_info *fi)
{
    return (struct loopback_dirp *)(uintptr_t)fi->fh;
}

static int
loopback_readdir(const char *path, void *buf, fuse_darwin_fill_dir_t filler,
                 off_t offset, struct fuse_file_info *fi,
                 enum fuse_readdir_flags flags)
{
    struct loopback_dirp *d = get_dirp(fi);

    (void)path;

    if (offset == 0) {
        rewinddir(d->dp);
        d->entry = NULL;
        d->offset = 0;
    } else if (offset != d->offset) {
        // Subtract the one that we add when calling telldir() below
        seekdir(d->dp, offset - 1);
        d->entry = NULL;
        d->offset = offset;
    }

    while (1) {
        struct fuse_darwin_attr attr;
        off_t nextoff;
        enum fuse_fill_dir_flags fill_flags = FUSE_FILL_DIR_DEFAULTS;

        if (!d->entry) {
            d->entry = readdir(d->dp);
            if (!d->entry) {
                break;
            }
        }

        if (flags & FUSE_READDIR_PLUS) {
            int res;

            res = getattrat(dirfd(d->dp), d->entry->d_name, &attr);
            if (res == 0) {
                fill_flags |= FUSE_FILL_DIR_PLUS;
            }
        }
        if (!(fill_flags & FUSE_FILL_DIR_PLUS)) {
            memset(&attr, 0, sizeof(attr));
            attr.ino = d->entry->d_ino;
            attr.mode = d->entry->d_type << 12;
        }

        /*
         * Under macOS, telldir() may return 0 the first time it is called.
         * But for libfuse, an offset of zero means that offsets are not
         * supported, so we shift everything by one.
         */
        nextoff = telldir(d->dp) + 1;

        if (filler(buf, d->entry->d_name, &attr, nextoff, fill_flags)) {
            break;
        }

        d->entry = NULL;
        d->offset = nextoff;
    }

    return 0;
}

static int
loopback_releasedir(const char *path, struct fuse_file_info *fi)
{
    struct loopback_dirp *d = get_dirp(fi);

    (void)path;

    closedir(d->dp);
    free(d);

    return 0;
}

static int
loopback_mknod(const char *path, mode_t mode, dev_t rdev)
{
    int res;

    if (S_ISFIFO(mode)) {
        res = mkfifo(path, mode);
    } else {
        res = mknod(path, mode, rdev);
    }
    if (res == -1) {
        return -errno;
    }

    return 0;
}

static int
loopback_mkdir(const char *path, mode_t mode)
{
    int res;

    res = mkdir(path, mode);
    if (res == -1) {
        return -errno;
    }

    return 0;
}

static int
loopback_unlink(const char *path)
{
    int res;

    res = unlink(path);
    if (res == -1) {
        return -errno;
    }

    return 0;
}

static int
loopback_rmdir(const char *path)
{
    int res;

    res = rmdir(path);
    if (res == -1) {
        return -errno;
    }

    return 0;
}

static int
loopback_symlink(const char *from, const char *to)
{
    int res;

    res = symlink(from, to);
    if (res == -1) {
        return -errno;
    }

    return 0;
}

static int
loopback_rename(const char *from, const char *to, unsigned int flags)
{
    int res;

    res = renamex_np(from, to, flags);
    if (res == -1) {
        return -errno;
    }

    return 0;
}

static int
loopback_link(const char *from, const char *to)
{
    int res;

    res = link(from, to);
    if (res == -1) {
        return -errno;
    }

    return 0;
}

static int
loopback_create(const char *path, mode_t mode, struct fuse_file_info *fi)
{
    int fd;

    fd = open(path, fi->flags, mode);
    if (fd == -1) {
        return -errno;
    }

    fi->fh = fd;
    return 0;
}

static int
loopback_open(const char *path, struct fuse_file_info *fi)
{
    int fd;

    fd = open(path, fi->flags);
    if (fd == -1) {
        return -errno;
    }

    fi->fh = fd;
    return 0;
}

static int
loopback_read(const char *path, char *buf, size_t size, off_t offset,
              struct fuse_file_info *fi)
{
    int res;

    (void)path;

    res = pread(fi->fh, buf, size, offset);
    if (res == -1) {
        res = -errno;
    }

    return res;
}

static int
loopback_write(const char *path, const char *buf, size_t size,
               off_t offset, struct fuse_file_info *fi)
{
    int res;

    (void)path;

    res = pwrite(fi->fh, buf, size, offset);
    if (res == -1) {
        res = -errno;
    }

    return res;
}

static int
loopback_statfs(const char *path, struct statfs *stbuf)
{
    int res;

    res = statfs(path, stbuf);
    if (res == -1) {
        return -errno;
    }

    stbuf->f_blocks = stbuf->f_blocks * stbuf->f_bsize / loopback.blocksize;
    stbuf->f_bavail = stbuf->f_bavail * stbuf->f_bsize / loopback.blocksize;
    stbuf->f_bfree = stbuf->f_bfree * stbuf->f_bsize / loopback.blocksize;
    stbuf->f_bsize = loopback.blocksize;

    return 0;
}

static int
loopback_flush(const char *path, struct fuse_file_info *fi)
{
    int res;

    (void)path;

    /*
     * This is called from every close on an open file, so call the close on the
     * underlying filesystem. But since flush may be called multiple times for
     * an open file, this must not really close the file. This is important if
     * used on a network filesystem like NFS which flush the data/metadata on
     * close()
     */
    res = close(dup(fi->fh));
    if (res == -1) {
        return -errno;
    }

    return 0;
}

static int
loopback_release(const char *path, struct fuse_file_info *fi)
{
    (void)path;

    close(fi->fh);

    return 0;
}

static int
loopback_fsync(const char *path, int isdatasync, struct fuse_file_info *fi)
{
    int res;

    (void)path;
    (void)isdatasync;

    res = fsync(fi->fh);
    if (res == -1) {
        return -errno;
    }

    return 0;
}

static int
loopback_fallocate(const char *path, int mode, off_t offset, off_t length,
                   struct fuse_file_info *fi)
{
    int res;
    fstore_t fstore;

    if (!(mode & PREALLOCATE)) {
        return -ENOTSUP;
    }

    fstore.fst_flags = 0;
    if (mode & ALLOCATECONTIG) {
        fstore.fst_flags |= F_ALLOCATECONTIG;
    }
    if (mode & ALLOCATEALL) {
        fstore.fst_flags |= F_ALLOCATEALL;
    }

    if (mode & ALLOCATEFROMPEOF) {
        fstore.fst_posmode = F_PEOFPOSMODE;
    } else if (mode & ALLOCATEFROMVOL) {
        fstore.fst_posmode = F_VOLPOSMODE;
    }

    fstore.fst_offset = offset;
    fstore.fst_length = length;

    res = fcntl(fi->fh, F_PREALLOCATE, &fstore);
    if (res == -1) {
        return -errno;
    }

    return 0;
}

static int
loopback_setxattr(const char *path, const char *name, const char *value,
                  size_t size, int flags, uint32_t position)
{
    int res;

    flags |= XATTR_NOFOLLOW;

    if (strncmp(name, "com.apple.", 10) == 0) {
        char new_name[MAXPATHLEN] = "org.apple.";
        strncpy(new_name + 10, name + 10, sizeof(new_name) - 10);
        name = new_name;
    }

    res = setxattr(path, name, value, size, position, flags);
    if (res == -1) {
        return -errno;
    }

    return 0;
}

static int
loopback_getxattr(const char *path, const char *name, char *value, size_t size,
                  uint32_t position)
{
    int res;

    if (strncmp(name, "com.apple.", 10) == 0) {
        char new_name[MAXPATHLEN] = "org.apple.";
        strncpy(new_name + 10, name + 10, sizeof(new_name) - 10);
        name = new_name;
    }

    res = getxattr(path, name, value, size, position, XATTR_NOFOLLOW);
    if (res == -1) {
        return -errno;
    }

    return res;
}

static int
loopback_listxattr(const char *path, char *list, size_t size)
{
    ssize_t res = listxattr(path, list, size, XATTR_NOFOLLOW);
    if (res == -1) {
        return -errno;
    }

    if (res > 0 && list) {
        size_t len = 0;
        char *current = list;
        do {
            size_t current_len = strlen(current) + 1;
            if (strncmp(current, "com.apple.", 10) == 0) {
                current[0] = 'o';
                current[1] = 'r';
                current[2] = 'g';
            }
            current += current_len;
            len += current_len;
        } while (len < res);
    }

    return res;
}

static int
loopback_removexattr(const char *path, const char *name)
{
    int res;

    if (strncmp(name, "com.apple.", 10) == 0) {
        char new_name[MAXPATHLEN] = "org.apple.";
        strncpy(new_name + 10, name + 10, sizeof(new_name) - 10);
        name = new_name;
    }

    res = removexattr(path, name, XATTR_NOFOLLOW);
    if (res == -1) {
        return -errno;
    }

    return 0;
}

static int
loopback_setvolname(const char *name)
{
    return 0;
}

static struct fuse_operations loopback_oper = {
    .init        = loopback_init,
    .getattr     = loopback_getattr,
    .setattr     = loopback_setattr,

#if HAVE_ACCESS
    .access      = loopback_access,
#endif

    .readlink    = loopback_readlink,
    .opendir     = loopback_opendir,
    .readdir     = loopback_readdir,
    .releasedir  = loopback_releasedir,
    .mknod       = loopback_mknod,
    .mkdir       = loopback_mkdir,
    .unlink      = loopback_unlink,
    .rmdir       = loopback_rmdir,
    .symlink     = loopback_symlink,
    .rename      = loopback_rename,
    .link        = loopback_link,
    .create      = loopback_create,
    .open        = loopback_open,
    .read        = loopback_read,
    .write       = loopback_write,
    .statfs      = loopback_statfs,
    .flush       = loopback_flush,
    .release     = loopback_release,
    .fsync       = loopback_fsync,
    .fallocate   = loopback_fallocate,
    .setxattr    = loopback_setxattr,
    .getxattr    = loopback_getxattr,
    .listxattr   = loopback_listxattr,
    .removexattr = loopback_removexattr,
    .setvolname  = loopback_setvolname,
};

static const struct fuse_opt loopback_opts[] = {
    { "fsblocksize=%u", offsetof(struct loopback, blocksize), 0 },
    { "case_insensitive", offsetof(struct loopback, case_insensitive), true },
    FUSE_OPT_END
};

int
main(int argc, char *argv[])
{
    int res = 0;
    struct fuse_args args = FUSE_ARGS_INIT(argc, argv);

    loopback.blocksize = 4096;
    loopback.case_insensitive = 0;
    if (fuse_opt_parse(&args, &loopback, loopback_opts, NULL) == -1) {
        exit(1);
    }

    umask(0);
    res = fuse_main(args.argc, args.argv, &loopback_oper, NULL);

    fuse_opt_free_args(&args);
    return res;
}

