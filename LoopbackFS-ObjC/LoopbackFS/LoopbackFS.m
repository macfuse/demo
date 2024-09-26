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
//
//  LoopbackFS.m
//  LoopbackFS
//
//  Created by ted on 12/12/07.
//
// This is a simple but complete example filesystem that mounts a local
// directory. You can modify this to see how the Finder reacts to returning
// specific error codes or not implementing a particular GMUserFileSystem
// operation.
//
// For example, you can mount "/tmp" in /Volumes/loop. Note: It is
// probably not a good idea to mount "/" through this filesystem.

#import "LoopbackFS.h"

#import <macFUSE/macFUSE.h>

#import <sys/mount.h>
#import <sys/stat.h>
#import <sys/vnode.h>
#import <sys/xattr.h>

#import "NSError+POSIX.h"

#define HAVE_EXCHANE 0

@implementation LoopbackFS

- (id)initWithRootPath:(NSString *)rootPath {
  if ((self = [super init])) {
    rootPath_ = [rootPath retain];
  }
  return self;
}

- (void) dealloc {
  [rootPath_ release];
  [super dealloc];
}

#pragma mark Moving an Item

- (BOOL)moveItemAtPath:(NSString *)source
                toPath:(NSString *)destination
               options:(GMUserFileSystemMoveOption)options
                 error:(NSError **)error {
  // We use rename directly here since NSFileManager can sometimes fail to
  // rename and return non-posix error codes.
  NSString *p_src = [rootPath_ stringByAppendingString:source];
  NSString *p_dst = [rootPath_ stringByAppendingString:destination];
  int ret = 0;
  if (options == 0) {
    ret = rename([p_src UTF8String], [p_dst UTF8String]);
  } else {
    unsigned int flags = 0;
    if (options & GMUserFileSystemMoveOptionSwap) {
      flags |= RENAME_SWAP;
    }
    if (options & GMUserFileSystemMoveOptionExclusive) {
      flags |= RENAME_EXCL;
    }
    ret = renamex_np([p_src UTF8String], [p_dst UTF8String], flags);
  }
  if (ret < 0) {
    if (error) {
      *error = [NSError errorWithPOSIXCode:errno];
    }
    return NO;
  }
  return YES;
}

#pragma mark Removing an Item

- (BOOL)removeDirectoryAtPath:(NSString *)path error:(NSError **)error {
  // We need to special-case directories here and use the bsd API since
  // NSFileManager will happily do a recursive remove :-(
  NSString *p = [rootPath_ stringByAppendingString:path];
  int ret = rmdir([p UTF8String]);
  if (ret < 0) {
    if (error) {
      *error = [NSError errorWithPOSIXCode:errno];
    }
    return NO;
  }
  return YES;
}

- (BOOL)removeItemAtPath:(NSString *)path error:(NSError **)error {
  // NOTE: If removeDirectoryAtPath is commented out, then this may be called
  // with a directory, in which case NSFileManager will recursively remove all
  // subdirectories. So be careful!
  NSString *p = [rootPath_ stringByAppendingString:path];
  return [[NSFileManager defaultManager] removeItemAtPath:p error:error];
}

#pragma mark Creating an Item

- (BOOL)createDirectoryAtPath:(NSString *)path
                   attributes:(NSDictionary *)attributes
                        error:(NSError **)error {
  NSString *p = [rootPath_ stringByAppendingString:path];
  return [[NSFileManager defaultManager] createDirectoryAtPath:p
                                   withIntermediateDirectories:NO
                                                    attributes:attributes
                                                        error:error];
}

- (BOOL)createFileAtPath:(NSString *)path
              attributes:(NSDictionary *)attributes
                   flags:(int)flags
                userData:(id *)userData
                   error:(NSError **)error {
  NSString *p = [rootPath_ stringByAppendingString:path];
  mode_t mode = [[attributes objectForKey:NSFilePosixPermissions] longValue];
  int fd = open([p UTF8String], flags, mode);
  if (fd < 0) {
    if (error) {
      *error = [NSError errorWithPOSIXCode:errno];
    }
    return NO;
  }
  *userData = [NSNumber numberWithLong:fd];
  return YES;
}

#pragma mark Linking an Item

- (BOOL)linkItemAtPath:(NSString *)path
                toPath:(NSString *)otherPath
                 error:(NSError **)error {
  NSString *p_path = [rootPath_ stringByAppendingString:path];
  NSString *p_otherPath = [rootPath_ stringByAppendingString:otherPath];

  // We use link rather than the NSFileManager equivalent because it will copy
  // the file rather than hard link if part of the root path is a symlink.
  int ret = link([p_path UTF8String], [p_otherPath UTF8String]);
  if (ret <  0) {
    if (error) {
      *error = [NSError errorWithPOSIXCode:errno];
    }
    return NO;
  }
  return YES;
}

#pragma mark Symbolic Links

- (BOOL)createSymbolicLinkAtPath:(NSString *)path
             withDestinationPath:(NSString *)otherPath
                           error:(NSError **)error {
  NSString *p_src = [rootPath_ stringByAppendingString:path];
  return [[NSFileManager defaultManager] createSymbolicLinkAtPath:p_src
                                              withDestinationPath:otherPath
                                                            error:error];
}

- (NSString *)destinationOfSymbolicLinkAtPath:(NSString *)path
                                        error:(NSError **)error {
  NSString *p = [rootPath_ stringByAppendingString:path];
  return [[NSFileManager defaultManager] destinationOfSymbolicLinkAtPath:p
                                                                   error:error];
}

#pragma mark File Contents

- (BOOL)openFileAtPath:(NSString *)path
                  mode:(int)mode
              userData:(id *)userData
                 error:(NSError **)error {
  NSString *p = [rootPath_ stringByAppendingString:path];
  int fd = open([p UTF8String], mode);
  if (fd < 0) {
    if (error) {
      *error = [NSError errorWithPOSIXCode:errno];
    }
    return NO;
  }
  *userData = [NSNumber numberWithLong:fd];
  return YES;
}

- (void)releaseFileAtPath:(NSString *)path userData:(id)userData {
  NSNumber *num = (NSNumber *)userData;
  int fd = [num intValue];
  close(fd);
}

- (int)readFileAtPath:(NSString *)path
             userData:(id)userData
               buffer:(char *)buffer
                 size:(size_t)size
               offset:(off_t)offset
                error:(NSError **)error {
  NSNumber *num = (NSNumber *)userData;
  int fd = [num intValue];
  size_t ret = pread(fd, buffer, size, offset);
  if (ret < 0) {
    if (error) {
      *error = [NSError errorWithPOSIXCode:errno];
    }
    return -1;
  }
  return (int)ret;
}

- (int)writeFileAtPath:(NSString *)path
              userData:(id)userData
                buffer:(const char *)buffer
                  size:(size_t)size
                offset:(off_t)offset
                 error:(NSError **)error {
  NSNumber *num = (NSNumber *)userData;
  int fd = [num intValue];
  size_t ret = pwrite(fd, buffer, size, offset);
  if (ret < 0) {
    if (error) {
      *error = [NSError errorWithPOSIXCode:errno];
    }
    return -1;
  }
  return (int)ret;
}

- (BOOL)preallocateFileAtPath:(NSString *)path
                     userData:(id)userData
                      options:(int)options
                       offset:(off_t)offset
                       length:(off_t)length
                        error:(NSError **)error {
  NSNumber *num = (NSNumber *)userData;
  int fd = [num intValue];

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

#if HAVE_EXCHANE

- (BOOL)exchangeDataOfItemAtPath:(NSString *)path1
                  withItemAtPath:(NSString *)path2
                           error:(NSError **)error {
  NSString *p1 = [rootPath_ stringByAppendingString:path1];
  NSString *p2 = [rootPath_ stringByAppendingString:path2];
  int ret = exchangedata([p1 UTF8String], [p2 UTF8String], 0);
  if (ret < 0) {
    if (error) {
      *error = [NSError errorWithPOSIXCode:errno];
    }
    return NO;
  }
  return YES;
}

#endif /* HAVE_EXCHANGE */

#pragma mark Directory Contents

- (NSArray *)contentsOfDirectoryAtPath:(NSString *)path error:(NSError **)error {
  NSString *p = [rootPath_ stringByAppendingString:path];
  return [[NSFileManager defaultManager] contentsOfDirectoryAtPath:p error:error];
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

- (NSDictionary *)attributesOfItemAtPath:(NSString *)path
                                userData:(id)userData
                                   error:(NSError **)error {
  NSString *p = [rootPath_ stringByAppendingString:path];
  NSDictionary *d =
    [[NSFileManager defaultManager] attributesOfItemAtPath:p error:error];
  if (d) {
    NSMutableDictionary *attribs =
      [NSMutableDictionary dictionaryWithDictionary:d];
    int ret = 0;

    struct stat stbuf;
    ret = lstat([p UTF8String], &stbuf);
    if (ret < 0) {
      if (error) {
        *error = [NSError errorWithPOSIXCode:errno];
      }
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
    } __attribute__ ((packed));

    struct timeattrbuf timebuf;

    ret = getattrlist([p UTF8String], &attributes, &timebuf, sizeof(timebuf),
                      FSOPT_NOFOLLOW);
    if (ret < 0) {
      if (error) {
        *error = [NSError errorWithPOSIXCode:errno];
      }
      return nil;
    }

    [attribs setObject:[NSNumber numberWithInt:stbuf.st_flags]
                forKey:kGMUserFileSystemFileFlagsKey];
    [attribs setObject:DateFromTimespec(stbuf.st_atimespec)
                forKey:kGMUserFileSystemFileAccessDateKey];
    [attribs setObject:DateFromTimespec(stbuf.st_ctimespec)
                forKey:kGMUserFileSystemFileChangeDateKey];
    [attribs setObject:DateFromTimespec(timebuf.bkuptime)
                forKey:kGMUserFileSystemFileBackupDateKey];
    [attribs setObject:[NSNumber numberWithLongLong:stbuf.st_blocks]
                forKey:kGMUserFileSystemFileSizeInBlocksKey];
    [attribs setObject:[NSNumber numberWithInt:stbuf.st_blksize]
                forKey:kGMUserFileSystemFileOptimalIOSizeKey];
    return attribs;
  }
  return nil;
}

- (NSDictionary *)attributesOfFileSystemForPath:(NSString *)path
                                          error:(NSError **)error {
  NSString *p = [rootPath_ stringByAppendingString:path];
  NSDictionary *d =
    [[NSFileManager defaultManager] attributesOfFileSystemForPath:p
                                                            error:error];
  if (d) {
    NSMutableDictionary *attribs =
      [NSMutableDictionary dictionaryWithDictionary:d];

    struct statfs stbuf;
    int ret = statfs([p UTF8String], &stbuf);
    if (ret < 0) {
      if (error) {
        *error = [NSError errorWithPOSIXCode:errno];
      }
      return nil;
    }

    NSURL *URL = [NSURL fileURLWithPath:p isDirectory:YES];
    NSNumber *supportsCaseSensitiveNames = nil;
    if (![URL getResourceValue:&supportsCaseSensitiveNames
                        forKey:NSURLVolumeSupportsCaseSensitiveNamesKey
                         error:error]) {
      return nil;
    }
    if (!supportsCaseSensitiveNames) {
      supportsCaseSensitiveNames = [NSNumber numberWithBool:YES];
    }

    [attribs setObject:[NSNumber numberWithBool:YES]
                forKey:kGMUserFileSystemVolumeSupportsExtendedDatesKey];
    [attribs setObject:[NSNumber numberWithInt:255]
                forKey:kGMUserFileSystemVolumeMaxFilenameLengthKey];
    [attribs setObject:[NSNumber numberWithUnsignedLong:stbuf.f_bsize]
                forKey:kGMUserFileSystemVolumeFileSystemBlockSizeKey];
    [attribs setObject:supportsCaseSensitiveNames
                forKey:kGMUserFileSystemVolumeSupportsCaseSensitiveNamesKey];
    [attribs setObject:[NSNumber numberWithBool:YES]
                forKey:kGMUserFileSystemVolumeSupportsSwapRenamingKey];
    [attribs setObject:[NSNumber numberWithBool:YES]
                forKey:kGMUserFileSystemVolumeSupportsExclusiveRenamingKey];
    [attribs setObject:[NSNumber numberWithBool:YES]
                forKey:kGMUserFileSystemVolumeSupportsSetVolumeNameKey];
    [attribs setObject:[NSNumber numberWithBool:YES]
                forKey:kGMUserFileSystemVolumeSupportsReadWriteNodeLockingKey];
    return attribs;
  }
  return nil;
}

- (BOOL)setAttributes:(NSDictionary *)attributes
         ofItemAtPath:(NSString *)path
             userData:(id)userData
                error:(NSError **)error {
  NSString *p = [rootPath_ stringByAppendingString:path];

  NSNumber *offset = [attributes objectForKey:NSFileSize];
  if (offset) {
    int ret = truncate([p UTF8String], [offset longLongValue]);
    if (ret < 0) {
      if (error) {
        *error = [NSError errorWithPOSIXCode:errno];
      }
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
    int ret = setattrlist([p UTF8String], &attributes, &acctime,
                          sizeof(struct timespec), FSOPT_NOFOLLOW);
    if (ret < 0) {
      if (error) {
        *error = [NSError errorWithPOSIXCode:errno];
      }
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
    int ret = setattrlist([p UTF8String], &attributes, &chgtime,
                          sizeof(struct timespec), FSOPT_NOFOLLOW);
    if (ret < 0) {
      if (error) {
        *error = [NSError errorWithPOSIXCode:errno];
      }
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
    int ret = setattrlist([p UTF8String], &attributes, &bkuptime,
                          sizeof(struct timespec), FSOPT_NOFOLLOW);
    if (ret < 0) {
      if (error) {
        *error = [NSError errorWithPOSIXCode:errno];
      }
      return NO;
    }
  }

  NSNumber *flags = [attributes objectForKey:kGMUserFileSystemFileFlagsKey];
  if (flags != nil) {
    int ret = lchflags([p UTF8String], [flags intValue]);
    if (ret < 0) {
      if (error) {
        *error = [NSError errorWithPOSIXCode:errno];
      }
      return NO;
    }
  }

  return [[NSFileManager defaultManager] setAttributes:attributes
                                          ofItemAtPath:p
                                                 error:error];
}

- (BOOL)setAttributes:(NSDictionary *)attributes
   ofFileSystemAtPath:(NSString *)path
                error:(NSError **)error {
  return YES;
}

#pragma mark Extended Attributes

#define G_PREFIX              "org"
#define G_KAUTH_FILESEC_XATTR G_PREFIX ".apple.system.Security"
#define A_PREFIX              "com"
#define A_KAUTH_FILESEC_XATTR A_PREFIX ".apple.system.Security"
#define XATTR_APPLE_PREFIX    "com.apple."

- (NSArray *)extendedAttributesOfItemAtPath:(NSString *)path error:(NSError **)error {
  NSString *p = [rootPath_ stringByAppendingString:path];

  ssize_t size = listxattr([p UTF8String], NULL, 0, XATTR_NOFOLLOW);
  if (size < 0) {
    if (error) {
      *error = [NSError errorWithPOSIXCode:errno];
    }
    return nil;
  }

  NSMutableData *data = [NSMutableData dataWithLength:size];
  size = listxattr([p UTF8String], [data mutableBytes], [data length], XATTR_NOFOLLOW);
  if (size < 0) {
    if (error) {
      *error = [NSError errorWithPOSIXCode:errno];
    }
    return nil;
  }

  NSMutableArray *contents = [NSMutableArray array];
  char *ptr = (char *)[data bytes];
  while (ptr < (((char *)[data bytes]) + size)) {
    NSString *s = [NSString stringWithUTF8String:ptr];
    if (strcmp(ptr, G_KAUTH_FILESEC_XATTR) != 0) {
      [contents addObject:s];
    }
    ptr += ([s length] + 1);
  }
  return contents;
}

- (NSData *)valueOfExtendedAttribute:(NSString *)name
                        ofItemAtPath:(NSString *)path
                            position:(off_t)position
                               error:(NSError **)error {
  NSString *p = [rootPath_ stringByAppendingString:path];

  const char *n = [name UTF8String];
  if (strcmp(n, A_KAUTH_FILESEC_XATTR) == 0) {
    char new_name[MAXPATHLEN];
    memcpy(new_name, A_KAUTH_FILESEC_XATTR, sizeof(A_KAUTH_FILESEC_XATTR));
    memcpy(new_name, G_PREFIX, sizeof(G_PREFIX) - 1);
    n = new_name;
  }

  ssize_t size = getxattr([p UTF8String], n, NULL, 0, (uint32_t)position,
                          XATTR_NOFOLLOW);
  if (size < 0) {
    if (error) {
      *error = [NSError errorWithPOSIXCode:errno];
    }
    return nil;
  }

  NSMutableData *data = [NSMutableData dataWithLength:size];
  ssize_t ret = getxattr([p UTF8String], n, [data mutableBytes], [data length],
                         (uint32_t)position, XATTR_NOFOLLOW);
  if (ret == -1) {
    if (error) {
      *error = [NSError errorWithPOSIXCode:errno];
    }
    return nil;
  }

  return data;
}

- (BOOL)setExtendedAttribute:(NSString *)name
                ofItemAtPath:(NSString *)path
                       value:(NSData *)value
                    position:(off_t)position
                       options:(int)options
                       error:(NSError **)error {
  // Setting com.apple.FinderInfo happens in the kernel, so security related
  // bits are set in the options. We need to explicitly remove them or the call
  // to setxattr will fail.
  // TODO: Why is this necessary?

  NSString *p = [rootPath_ stringByAppendingString:path];

  const char *n = [name UTF8String];
  if (strcmp(n, A_KAUTH_FILESEC_XATTR) == 0) {
    char new_name[MAXPATHLEN];
    memcpy(new_name, A_KAUTH_FILESEC_XATTR, sizeof(A_KAUTH_FILESEC_XATTR));
    memcpy(new_name, G_PREFIX, sizeof(G_PREFIX) - 1);
    n = new_name;
  }

  options |= XATTR_NOFOLLOW;
  if (!strncmp(n, XATTR_APPLE_PREFIX, sizeof(XATTR_APPLE_PREFIX) - 1)) {
      options &= ~(XATTR_NOSECURITY);
  }

  int ret = setxattr([p UTF8String], n, [value bytes], [value length],
                     (uint32_t)position, options);
  if (ret == -1) {
    if (error) {
      *error = [NSError errorWithPOSIXCode:errno];
    }
    return NO;
  }

  return YES;
}

- (BOOL)removeExtendedAttribute:(NSString *)name
                   ofItemAtPath:(NSString *)path
                          error:(NSError **)error {
  NSString *p = [rootPath_ stringByAppendingString:path];

  const char *n = [name UTF8String];
  if (strcmp(n, A_KAUTH_FILESEC_XATTR) == 0) {
    char new_name[MAXPATHLEN];
    memcpy(new_name, A_KAUTH_FILESEC_XATTR, sizeof(A_KAUTH_FILESEC_XATTR));
    memcpy(new_name, G_PREFIX, sizeof(G_PREFIX) - 1);
    n = new_name;
  }

  int res = removexattr([p UTF8String], n, XATTR_NOFOLLOW);
  if (res == -1) {
    if (error) {
      *error = [NSError errorWithPOSIXCode:errno];
    }
    return NO;
  }

  return YES;
}

@end
