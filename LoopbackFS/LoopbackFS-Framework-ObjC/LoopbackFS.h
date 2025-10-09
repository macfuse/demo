//
//  LoopbackFS.h
//  LoopbackFS-Framework-ObjC
//
//  Created by Benjamin Fleischer on 08.10.25.
//

@import Foundation;
@import macFUSE;

NS_ASSUME_NONNULL_BEGIN

@interface LoopbackFS : NSObject <GMUserFileSystemOperations>

- (instancetype)initWithRootPath:(NSString *)rootPath;

@end

NS_ASSUME_NONNULL_END
