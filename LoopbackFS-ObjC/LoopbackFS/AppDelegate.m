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
//  AppDelegate.m
//  LoopbackFS
//
//  Created by ted on 12/27/07.
//
#import "AppDelegate.h"

#import <macFUSE/macFUSE.h>

#import <AvailabilityMacros.h>

#import "LoopbackFS.h"

static NSString *LoopbackMountPath = @"/Volumes/loop";

@implementation AppDelegate

- (void)mountFailed:(NSNotification *)notification {
  NSLog(@"Got mountFailed notification.");

  NSDictionary *userInfo = [notification userInfo];
  NSError *error = [userInfo objectForKey:kGMUserFileSystemErrorKey];
  NSLog(@"kGMUserFileSystem Error: %@, userInfo=%@", error, [error userInfo]);

  dispatch_async(dispatch_get_main_queue(), ^{
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:@"Mount Failed"];
    [alert setInformativeText:[error localizedDescription] ?: @"Unknown error"];
    [alert runModal];
  
    [[NSApplication sharedApplication] terminate:nil];
  });
}

- (void)didMount:(NSNotification *)notification {
  NSLog(@"Got didMount notification.");

  NSString *parentPath = [LoopbackMountPath stringByDeletingLastPathComponent];
  [[NSWorkspace sharedWorkspace] selectFile:LoopbackMountPath
                   inFileViewerRootedAtPath:parentPath];
}

- (void)didUnmount:(NSNotification*)notification {
  NSLog(@"Got didUnmount notification.");

  dispatch_async(dispatch_get_main_queue(), ^{
    [[NSApplication sharedApplication] terminate:nil];
  });
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
  NSOpenPanel *panel = [NSOpenPanel openPanel];
  [panel setCanChooseFiles:NO];
  [panel setCanChooseDirectories:YES];
  [panel setAllowsMultipleSelection:NO];
  [panel setDirectoryURL:[NSURL fileURLWithPath:@"/tmp"]];
  NSModalResponse ret = [panel runModal];

  if (ret == NSModalResponseCancel) {
    exit(0);
  }
  NSArray *paths = [panel URLs];
  if ([paths count] != 1) {
    exit(0);
  }
  NSString *rootPath = nil;
  rootPath = [[paths objectAtIndex:0] path];

  NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
  [center addObserver:self selector:@selector(mountFailed:)
                 name:kGMUserFileSystemMountFailed object:nil];
  [center addObserver:self selector:@selector(didMount:)
                 name:kGMUserFileSystemDidMount object:nil];
  [center addObserver:self selector:@selector(didUnmount:)
                 name:kGMUserFileSystemDidUnmount object:nil];

  loop_ = [[LoopbackFS alloc] initWithRootPath:rootPath];

  fs_ = [[GMUserFileSystem alloc] initWithDelegate:loop_ isThreadSafe:NO];

  NSMutableArray *options = [NSMutableArray array];

  // Do not use the 'native_xattr' mount-time option unless the underlying
  // file system supports native extended attributes. Typically, the user
  // would be mounting an HFS+ directory through LoopbackFS, so we do want
  // this option in that case.
  [options addObject:@"native_xattr"];

  [options addObject:@"volname=LoopbackFS"];
  [fs_ mountAtPath:LoopbackMountPath
       withOptions:options];
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  [fs_ unmount];
  [fs_ release];
  [loop_ release];
  return NSTerminateNow;
}

@end
