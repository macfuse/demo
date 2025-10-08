//
//  LoopbackFS.m
//  LoopbackFS-Framework-ObjC
//
//  Created by Benjamin Fleischer on 08.10.25.
//

// ================================================================
// Copyright (C) 2007 Google Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
// ================================================================

#import "LoopbackFS.h"

@import Darwin;
@import macFUSE;

#import "NSError+POSIX.h"

NS_ASSUME_NONNULL_BEGIN

@interface LoopbackFS ()

@property (nonatomic, copy) NSString *rootPath;

@end

@implementation LoopbackFS

- (instancetype)initWithRootPath:(NSString *)rootPath
{
    self = [super init];
    if (self) {
        self.rootPath = rootPath;
    }
    return self;
}

#pragma mark Moving an Item

- (BOOL)moveItemAtPath:(NSString *)path
                toPath:(NSString *)otherPath
               options:(GMUserFileSystemMoveOption)options
                 error:(NSError * _Nullable * _Nonnull)error
{
    /*
     * We use rename directly here since NSFileManager can sometimes fail to rename and return
     * non-posix error codes.
     */

    NSString *resolvedPath = [self.rootPath stringByAppendingPathComponent:path];
    NSString *resolvedOtherPath = [self.rootPath stringByAppendingPathComponent:otherPath];

    int ret = 0;
    if (!options) {
        ret = rename(resolvedPath.fileSystemRepresentation, resolvedOtherPath.fileSystemRepresentation);
    } else {
        unsigned int flags = 0;
        if (options & GMUserFileSystemMoveOptionSwap) {
            flags |= RENAME_SWAP;
        }
        if (options & GMUserFileSystemMoveOptionExclusive) {
            flags |= RENAME_EXCL;
        }
        ret = renamex_np(resolvedPath.fileSystemRepresentation, resolvedOtherPath.fileSystemRepresentation, flags);
    }
    if (ret < 0) {
        *error = [NSError errorWithPOSIXCode:errno];
        return NO;
    }

    return YES;
}

#pragma mark Removing an Item

- (BOOL)removeDirectoryAtPath:(NSString *)path error:(NSError * _Nullable * _Nonnull)error
{
    NSString *resolvedPath = [self.rootPath stringByAppendingPathComponent:path];

    /*
     * We need to special-case directories here and use the bsd API since NSFileManager will
     * happily do a recursive remove.
     */
    int ret = rmdir(resolvedPath.fileSystemRepresentation);
    if (ret < 0) {
        *error = [NSError errorWithPOSIXCode:errno];
        return NO;
    }

    return YES;
}

- (BOOL)removeItemAtPath:(NSString *)path error:(NSError * _Nullable * _Nonnull)error
{
    /*
     * Note: If removeDirectoryAtPath is commented out, then this may be called with a directory, in
     * which case NSFileManager will recursively remove all subdirectories. So be careful!
     */

    NSString *resolvedPath = [self.rootPath stringByAppendingPathComponent:path];
    return [NSFileManager.defaultManager removeItemAtPath:resolvedPath error:error];
}

#pragma mark Creating an Item

- (BOOL)createDirectoryAtPath:(NSString *)path
                   attributes:(NSDictionary *)attributes
                        error:(NSError * _Nullable * _Nonnull)error
{
    NSString *resolvedPath = [self.rootPath stringByAppendingPathComponent:path];
    return [NSFileManager.defaultManager createDirectoryAtPath:resolvedPath
                                   withIntermediateDirectories:NO
                                                    attributes:attributes
                                                         error:error];
}

- (BOOL)createFileAtPath:(NSString *)path
              attributes:(NSDictionary *)attributes
                   flags:(int)flags
                userData:(id *)userData
                   error:(NSError * _Nullable * _Nonnull)error
{
    NSString *resolvedPath = [self.rootPath stringByAppendingPathComponent:path];
    mode_t mode = [attributes[NSFilePosixPermissions] longValue];

    int fd = open(resolvedPath.fileSystemRepresentation, flags, mode);
    if (fd < 0) {
        *error = [NSError errorWithPOSIXCode:errno];
        return NO;
    }

    *userData = @(fd);
    return YES;
}

#pragma mark Linking an Item

- (BOOL)linkItemAtPath:(NSString *)path
                toPath:(NSString *)otherPath
                 error:(NSError * _Nullable * _Nonnull)error
{
    NSString *resolvedPath = [self.rootPath stringByAppendingPathComponent:path];
    NSString *resolvedOtherPath = [self.rootPath stringByAppendingPathComponent:otherPath];

    /*
     * We use link rather than the NSFileManager equivalent because it will copy the file rather
     * than hard link if part of the root path is a symlink.
     */
    int ret = link(resolvedPath.fileSystemRepresentation,
                   resolvedOtherPath.fileSystemRepresentation);
    if (ret <  0) {
        *error = [NSError errorWithPOSIXCode:errno];
        return NO;
    }

    return YES;
}

#pragma mark Symbolic Links

- (BOOL)createSymbolicLinkAtPath:(NSString *)path
             withDestinationPath:(NSString *)otherPath
                           error:(NSError * _Nullable * _Nonnull)error
{
    NSString *resolvedPath = [self.rootPath stringByAppendingPathComponent:path];
    return [NSFileManager.defaultManager createSymbolicLinkAtPath:resolvedPath
                                              withDestinationPath:otherPath
                                                            error:error];
}

- (nullable NSString *)destinationOfSymbolicLinkAtPath:(NSString *)path
                                                 error:(NSError * _Nullable * _Nonnull)error
{
    NSString *resolvedPath = [self.rootPath stringByAppendingPathComponent:path];
    return [NSFileManager.defaultManager destinationOfSymbolicLinkAtPath:resolvedPath error:error];
}

#pragma mark File Contents

- (BOOL)openFileAtPath:(NSString *)path
                  mode:(int)mode
              userData:(id *)userData
                 error:(NSError * _Nullable * _Nonnull)error
{
    NSString *resolvedPath = [self.rootPath stringByAppendingPathComponent:path];

    int fd = open(resolvedPath.fileSystemRepresentation, mode);
    if (fd < 0) {
        *error = [NSError errorWithPOSIXCode:errno];
        return NO;
    }

    *userData = @(fd);
    return YES;
}

- (void)releaseFileAtPath:(NSString *)path userData:(nullable id)userData
{
    NSNumber *num = (NSNumber *)userData;
    int fd = num.intValue;

    close(fd);
}

- (int)readFileAtPath:(NSString *)path
             userData:(nullable id)userData
               buffer:(char *)buffer
                 size:(size_t)size
               offset:(off_t)offset
                error:(NSError * _Nullable * _Nonnull)error
{
    NSNumber *num = (NSNumber *)userData;
    int fd = num.intValue;

    size_t ret = pread(fd, buffer, size, offset);
    if (ret < 0) {
        *error = [NSError errorWithPOSIXCode:errno];
        return -1;
    }

    return (int)ret;
}

- (int)writeFileAtPath:(NSString *)path
              userData:(nullable id)userData
                buffer:(const char *)buffer
                  size:(size_t)size
                offset:(off_t)offset
                 error:(NSError * _Nullable * _Nonnull)error
{
    NSNumber *num = (NSNumber *)userData;
    int fd = num.intValue;

    size_t ret = pwrite(fd, buffer, size, offset);
    if (ret < 0) {
        *error = [NSError errorWithPOSIXCode:errno];
        return -1;
    }

    return (int)ret;
}

- (BOOL)preallocateFileAtPath:(NSString *)path
                     userData:(nullable id)userData
                      options:(int)options
                       offset:(off_t)offset
                       length:(off_t)length
                        error:(NSError * _Nullable * _Nonnull)error
{
    NSNumber *num = (NSNumber *)userData;
    int fd = num.intValue;

    fstore_t fstore;

    fstore.fst_flags = 0;
    if (options & ALLOCATECONTIG) {
        fstore.fst_flags |= F_ALLOCATECONTIG;
    }
    if (options & ALLOCATEALL) {
        fstore.fst_flags |= F_ALLOCATEALL;
    }

    if (options & ALLOCATEFROMPEOF) {
        fstore.fst_posmode = F_PEOFPOSMODE;
    } else if (options & ALLOCATEFROMVOL) {
        fstore.fst_posmode = F_VOLPOSMODE;
    }

    fstore.fst_offset = offset;
    fstore.fst_length = length;

    if (fcntl(fd, F_PREALLOCATE, &fstore) == -1) {
        *error = [NSError errorWithPOSIXCode:errno];
        return NO;
    }

    return YES;
}

#pragma mark Directory Contents

- (nullable NSArray<GMDirectoryEntry *> *)contentsOfDirectoryAtPath:(NSString *)path
                                         includingAttributesForKeys:(NSArray<NSString *> *)keys
                                                              error:(NSError * _Nullable * _Nonnull)error
{
    NSString *resolvedPath = [self.rootPath stringByAppendingPathComponent:path];
    NSArray<NSString *> *contents = [NSFileManager.defaultManager contentsOfDirectoryAtPath:resolvedPath
                                                                                      error:error];
    if (!contents) {
        return nil;
    }

    NSMutableArray *entries = [NSMutableArray array];
    for (NSString *name in contents) {
        NSString *resolvedName = [resolvedPath stringByAppendingPathComponent:name];
        
        NSDictionary *d = [NSFileManager.defaultManager attributesOfItemAtPath:resolvedName
                                                                         error:nil];
        if (!d) {
            continue;
        }

        GMDirectoryEntry *entry = [GMDirectoryEntry directoryEntryWithName:name attributes:d];
        [entries addObject:entry];
    }
    return entries;
}

#pragma mark Getting and Setting Attributes

#define DateFromTimespec(t) \
    [NSDate dateWithTimeIntervalSince1970:((t).tv_sec + (t).tv_nsec / 1000000000.0)]

#define TimespecFromDate(d) \
    ({ \
        NSTimeInterval _i = [(d) timeIntervalSince1970]; \
        struct timespec _t; \
        _t.tv_sec = (__darwin_time_t)_i; \
        _t.tv_nsec = (long)((_i - _t.tv_sec) * 1000000000); \
        _t; \
    })

- (nullable NSDictionary *)attributesOfItemAtPath:(NSString *)path
                                         userData:(nullable id)userData
                                            error:(NSError * _Nullable * _Nonnull)error
{
    NSString *resolvedPath = [self.rootPath stringByAppendingPathComponent:path];
    NSDictionary *d = [NSFileManager.defaultManager attributesOfItemAtPath:resolvedPath
                                                                     error:error];
    if (d) {
        NSMutableDictionary *attribs = [NSMutableDictionary dictionaryWithDictionary:d];
        int ret = 0;

        struct stat stbuf;
        ret = lstat(resolvedPath.fileSystemRepresentation, &stbuf);
        if (ret < 0) {
            *error = [NSError errorWithPOSIXCode:errno];
            return nil;
        }

        struct attrlist attributes;

        attributes.bitmapcount = ATTR_BIT_MAP_COUNT;
        attributes.reserved = 0;
        attributes.commonattr = ATTR_CMN_BKUPTIME;
        attributes.dirattr = 0;
        attributes.fileattr = 0;
        attributes.forkattr = 0;
        attributes.volattr = 0;

        struct timeattrbuf {
            uint32_t size;
            struct timespec bkuptime;
        } __attribute__ ((packed)) timebuf;

        ret = getattrlist(resolvedPath.fileSystemRepresentation, &attributes, &timebuf,
                          sizeof(timebuf), FSOPT_NOFOLLOW);
        if (ret < 0) {
            *error = [NSError errorWithPOSIXCode:errno];
            return nil;
        }

        attribs[kGMUserFileSystemFileFlagsKey] = @(stbuf.st_flags);
        attribs[kGMUserFileSystemFileAccessDateKey] = DateFromTimespec(stbuf.st_atimespec);
        attribs[kGMUserFileSystemFileChangeDateKey] = DateFromTimespec(stbuf.st_ctimespec);
        attribs[kGMUserFileSystemFileBackupDateKey] = DateFromTimespec(timebuf.bkuptime);
        attribs[kGMUserFileSystemFileSizeInBlocksKey] = @(stbuf.st_blocks);
        attribs[kGMUserFileSystemFileOptimalIOSizeKey] = @(stbuf.st_blksize);
        return attribs;
    }
    return nil;
}

- (nullable NSDictionary<NSFileAttributeKey, id> *)attributesOfFileSystemForPath:(NSString *)path
                                                                           error:(NSError * _Nullable * _Nonnull)error
{
    NSString *resolvedPath = [self.rootPath stringByAppendingPathComponent:path];
    NSDictionary *d = [NSFileManager.defaultManager attributesOfFileSystemForPath:resolvedPath
                                                                            error:error];
    if (d) {
        NSMutableDictionary *attribs = [NSMutableDictionary dictionaryWithDictionary:d];

        struct statfs stbuf;
        int ret = statfs(resolvedPath.fileSystemRepresentation, &stbuf);
        if (ret < 0) {
            *error = [NSError errorWithPOSIXCode:errno];
            return nil;
        }

        NSURL *URL = [NSURL fileURLWithPath:resolvedPath isDirectory:YES];
        NSNumber *supportsCaseSensitiveNames = nil;
        if (![URL getResourceValue:&supportsCaseSensitiveNames
                            forKey:NSURLVolumeSupportsCaseSensitiveNamesKey
                             error:error]) {
            return nil;
        }
        if (!supportsCaseSensitiveNames) {
            supportsCaseSensitiveNames = @YES;
        }

        attribs[kGMUserFileSystemVolumeSupportsExtendedDatesKey] = @YES;
        attribs[kGMUserFileSystemVolumeMaxFilenameLengthKey] = @(255);
        attribs[kGMUserFileSystemVolumeFileSystemBlockSizeKey] = @(stbuf.f_bsize);
        attribs[kGMUserFileSystemVolumeSupportsCaseSensitiveNamesKey] = supportsCaseSensitiveNames;
        attribs[kGMUserFileSystemVolumeSupportsSwapRenamingKey] = @YES;
        attribs[kGMUserFileSystemVolumeSupportsExclusiveRenamingKey] = @YES;
        attribs[kGMUserFileSystemVolumeSupportsSetVolumeNameKey] = @YES;
        attribs[kGMUserFileSystemVolumeSupportsReadWriteNodeLockingKey] = @YES;
    return attribs;
  }
  return nil;
}

- (BOOL)setAttributes:(NSDictionary <NSFileAttributeKey, id> *)attributes
         ofItemAtPath:(NSString *)path
             userData:(nullable id)userData
                error:(NSError * _Nullable * _Nonnull)error
{
    NSString *resolvedPath = [self.rootPath stringByAppendingPathComponent:path];

    NSNumber *offset = attributes[NSFileSize];
    if (offset) {
        int ret = truncate(resolvedPath.fileSystemRepresentation, [offset longLongValue]);
        if (ret < 0) {
            *error = [NSError errorWithPOSIXCode:errno];
            return NO;
        }
    }

    NSDate *accessDate = attributes[kGMUserFileSystemFileAccessDateKey];
    if (accessDate) {
        struct attrlist attributes;

        attributes.bitmapcount = ATTR_BIT_MAP_COUNT;
        attributes.reserved = 0;
        attributes.commonattr = ATTR_CMN_ACCTIME;
        attributes.dirattr = 0;
        attributes.fileattr = 0;
        attributes.forkattr = 0;
        attributes.volattr = 0;

        struct timespec acctime = TimespecFromDate(accessDate);
        int ret = setattrlist(resolvedPath.fileSystemRepresentation, &attributes, &acctime,
                              sizeof(struct timespec), FSOPT_NOFOLLOW);
        if (ret < 0) {
            *error = [NSError errorWithPOSIXCode:errno];
            return NO;
        }
    }

    NSDate *changeDate = attributes[kGMUserFileSystemFileChangeDateKey];
    if (changeDate) {
        struct attrlist attributes;

        attributes.bitmapcount = ATTR_BIT_MAP_COUNT;
        attributes.reserved = 0;
        attributes.commonattr = ATTR_CMN_CHGTIME;
        attributes.dirattr = 0;
        attributes.fileattr = 0;
        attributes.forkattr = 0;
        attributes.volattr = 0;

        struct timespec chgtime = TimespecFromDate(changeDate);
        int ret = setattrlist(resolvedPath.fileSystemRepresentation, &attributes, &chgtime,
                              sizeof(struct timespec), FSOPT_NOFOLLOW);
        if (ret < 0) {
            *error = [NSError errorWithPOSIXCode:errno];
            return NO;
        }
    }

    NSDate *backupDate = attributes[kGMUserFileSystemFileBackupDateKey];
    if (backupDate) {
        struct attrlist attributes;

        attributes.bitmapcount = ATTR_BIT_MAP_COUNT;
        attributes.reserved = 0;
        attributes.commonattr = ATTR_CMN_BKUPTIME;
        attributes.dirattr = 0;
        attributes.fileattr = 0;
        attributes.forkattr = 0;
        attributes.volattr = 0;

        struct timespec bkuptime = TimespecFromDate(backupDate);
        int ret = setattrlist(resolvedPath.fileSystemRepresentation, &attributes, &bkuptime,
                              sizeof(struct timespec), FSOPT_NOFOLLOW);
        if (ret < 0) {
            *error = [NSError errorWithPOSIXCode:errno];
            return NO;
        }
    }

    NSNumber *flags = attributes[kGMUserFileSystemFileFlagsKey];
    if (flags != nil) {
        int ret = lchflags(resolvedPath.fileSystemRepresentation, flags.intValue);
        if (ret < 0) {
            *error = [NSError errorWithPOSIXCode:errno];
            return NO;
        }
    }

    return [NSFileManager.defaultManager setAttributes:attributes
                                          ofItemAtPath:resolvedPath
                                                 error:error];
}

- (BOOL)setAttributes:(NSDictionary<NSFileAttributeKey, id> *)attributes
   ofFileSystemAtPath:(NSString *)path
                error:(NSError * _Nullable * _Nonnull)error
{
    return YES;
}

#pragma mark Extended Attributes

- (nullable NSArray<NSString *> *)extendedAttributesOfItemAtPath:(NSString *)path
                                                           error:(NSError * _Nullable * _Nonnull)error
{
    NSString *resolvedPath = [self.rootPath stringByAppendingPathComponent:path];

    ssize_t size = listxattr(resolvedPath.fileSystemRepresentation, NULL, 0, XATTR_NOFOLLOW);
    if (size < 0) {
        *error = [NSError errorWithPOSIXCode:errno];
        return nil;
    }

    NSMutableData *data = [NSMutableData dataWithLength:size];
    size = listxattr(resolvedPath.fileSystemRepresentation, data.mutableBytes, data.length,
                     XATTR_NOFOLLOW);
    if (size < 0) {
        *error = [NSError errorWithPOSIXCode:errno];
        return nil;
    }

    NSMutableArray *contents = [NSMutableArray array];
    char *ptr = (char *)[data bytes];
    while (ptr < (((char *)[data bytes]) + size)) {
        NSString *s = [NSString stringWithUTF8String:ptr];
        if ([s hasPrefix:@"com.apple."]) {
            s = [@"org.apple." stringByAppendingString: [s substringFromIndex:10]];
        }
        [contents addObject:s];
        ptr += (s.length + 1);
    }
    return contents;
}

- (nullable NSData *)valueOfExtendedAttribute:(NSString *)name
                                 ofItemAtPath:(NSString *)path
                                     position:(off_t)position
                                        error:(NSError * _Nullable * _Nonnull)error
{
    NSString *resolvedPath = [self.rootPath stringByAppendingPathComponent:path];

    if ([name hasPrefix:@"com.apple."]) {
        name = [@"org.apple." stringByAppendingString: [name substringFromIndex:10]];
    }

    const char *n = name.UTF8String;
    ssize_t size = getxattr(resolvedPath.fileSystemRepresentation, n, NULL, 0, (uint32_t)position,
                            XATTR_NOFOLLOW);
    if (size < 0) {
        *error = [NSError errorWithPOSIXCode:errno];
        return nil;
    }

    NSMutableData *data = [NSMutableData dataWithLength:size];
    ssize_t ret = getxattr(resolvedPath.fileSystemRepresentation, n, data.mutableBytes, data.length,
                           (uint32_t)position, XATTR_NOFOLLOW);
    if (ret == -1) {
        *error = [NSError errorWithPOSIXCode:errno];
        return nil;
    }

    return data;
}

- (BOOL)setExtendedAttribute:(NSString *)name
                ofItemAtPath:(NSString *)path
                       value:(NSData *)value
                    position:(off_t)position
                     options:(int)options
                       error:(NSError * _Nullable * _Nonnull)error
{
    /*
     * Setting com.apple.FinderInfo happens in the kernel, so security related bits are set in the
     * options. We need to explicitly remove them or the call to setxattr will fail.
     * TODO: Why is this necessary?
     */

    NSString *resolvedPath = [self.rootPath stringByAppendingPathComponent:path];

    if ([name hasPrefix:@"com.apple."]) {
        name = [@"org.apple." stringByAppendingString: [name substringFromIndex:10]];
    }

    const char *n = name.UTF8String;
    options |= XATTR_NOFOLLOW;
    int ret = setxattr(resolvedPath.fileSystemRepresentation, n, value.bytes, value.length,
                       (uint32_t)position, options);
    if (ret == -1) {
        *error = [NSError errorWithPOSIXCode:errno];
        return NO;
    }

    return YES;
}

- (BOOL)removeExtendedAttribute:(NSString *)name
                   ofItemAtPath:(NSString *)path
                          error:(NSError * _Nullable * _Nonnull)error
{
    NSString *resolvedPath = [self.rootPath stringByAppendingPathComponent:path];

    if ([name hasPrefix:@"com.apple."]) {
        name = [@"org.apple." stringByAppendingString: [name substringFromIndex:10]];
    }

    const char *n = name.UTF8String;
    int res = removexattr(resolvedPath.fileSystemRepresentation, n, XATTR_NOFOLLOW);
    if (res == -1) {
        *error = [NSError errorWithPOSIXCode:errno];
        return NO;
    }

    return YES;
}

@end

NS_ASSUME_NONNULL_END
