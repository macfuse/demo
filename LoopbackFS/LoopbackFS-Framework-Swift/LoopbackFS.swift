//
//  LoopbackFS.swift
//  LoopbackFS-Framework-Swift
//
//  Created by Gunnar Herzog on 27/01/2017.
//  Copyright © 2017 KF Interactive GmbH. All rights reserved.
//  Copyright © 2019-2025 Benjamin Fleischer. All rights reserved.
//

import Foundation
import System

import macFUSE

public final class LoopbackFS: NSObject {
    private let rootPath: FilePath
    
    public init(rootPath: FilePath) {
        self.rootPath = rootPath
    }

    private func withPlatformPath<T>(
        _ path: FilePath,
        body: (UnsafePointer<CInterop.PlatformChar>) throws -> T
    ) rethrows -> T {
        try path.withPlatformString(body)
    }
    
    private func withPlatformPaths<T>(
        _ path1: FilePath,
        _ path2: FilePath,
        body: (
            UnsafePointer<CInterop.PlatformChar>,
            UnsafePointer<CInterop.PlatformChar>
        ) throws -> T
    ) rethrows -> T {
        try path1.withPlatformString { platformPath1 in
            try path2.withPlatformString { platformPath2 in
                try body(platformPath1, platformPath2)
            }
        }
    }

    // MARK: - Moving an Item

    public override func moveItem(
        atPath path: String,
        toPath otherPath: String,
        options: UserFileSystem.MoveOptions
    ) throws {
        let resolvedPath = rootPath.appending(path)
        let resolvedOtherPath = rootPath.appending(otherPath)
        
        var flags = UInt32(0)
        if options.contains(.swap) {
            flags |= UInt32(RENAME_SWAP)
        }
        if options.contains(.exclusive) {
            flags |= UInt32(RENAME_EXCL)
        }
        
        try withPlatformPaths(resolvedPath, resolvedOtherPath) {
            guard renamex_np($0, $1, flags) == 0 else {
                throw NSError(posixErrorCode: errno)
            }
        }
    }

    // MARK: - Removing an Item

    public override func removeDirectory(atPath path: String) throws {
        let resolvedPath = rootPath.appending(path)
        
        /*
         * We need to special-case directories here and use the BSD API since NSFileManager will
         * happily do a recursive remove.
         */
        
        try withPlatformPath(resolvedPath) {
            guard rmdir($0) == 0 else {
                throw NSError(posixErrorCode: errno)
            }
        }
    }

    public override func removeItem(atPath path: String) throws {
        let resolvedPath = rootPath.appending(path)
        return try FileManager.default.removeItem(atPath: resolvedPath.string)
    }

    // MARK: - Creating an Item

    public override func createDirectory(
        atPath path: String,
        attributes: [FileAttributeKey: Any] = [:]
    ) throws {
        let resolvedPath = rootPath.appending(path)

        try FileManager.default.createDirectory(
            atPath: resolvedPath.string,
            withIntermediateDirectories: false,
            attributes: attributes
        )
    }

    public override func createFile(
        atPath path: String,
        attributes: [FileAttributeKey: Any],
        flags: Int32,
        userData: AutoreleasingUnsafeMutablePointer<AnyObject?>
    ) throws {
        let resolvedPath = rootPath.appending(path)

        guard let mode = attributes[.posixPermissions] as? mode_t else {
            throw NSError(posixErrorCode: EPERM)
        }

        userData.pointee = try withPlatformPath(resolvedPath) {
            let fd = open($0, flags, mode)
            guard fd >= 0 else {
                throw NSError(posixErrorCode: errno)
            }

            return FileHandle(fileDescriptor: fd)
        }
    }

    // MARK: - Linking an Item

    public override func linkItem(atPath path: String, toPath otherPath: String) throws {
        let resolvedPath = rootPath.appending(path)
        let resolvedOtherPath = rootPath.appending(otherPath)

        /*
         * We use link rather than the NSFileManager equivalent because it will copy the file rather
         * than hard link if part of the root path is a symlink.
         */

        try withPlatformPaths(resolvedPath, resolvedOtherPath) {
            guard link($0, $1) >= 0 else {
                throw NSError(posixErrorCode: errno)
            }
        }
    }

    // MARK: - Symbolic Links

    public override func createSymbolicLink(
        atPath path: String,
        withDestinationPath otherPath: String
    ) throws {
        let resolvedPath = rootPath.appending(path)
        try FileManager.default.createSymbolicLink(
            atPath: resolvedPath.string,
            withDestinationPath: otherPath
        )
    }

    public override func destinationOfSymbolicLink(atPath path: String) throws -> String {
        let resolvedPath = rootPath.appending(path)
        return try FileManager.default.destinationOfSymbolicLink(atPath: resolvedPath.string)
    }

    // MARK: - File Contents

    public override func openFile(
        atPath path: String,
        mode: Int32,
        userData: AutoreleasingUnsafeMutablePointer<AnyObject?>
    ) throws {
        let resolvedPath = rootPath.appending(path)

        userData.pointee = try withPlatformPath(resolvedPath) {
            let fd = open($0, mode)
            guard fd >= 0 else {
                throw NSError(posixErrorCode: errno)
            }

            return FileHandle(fileDescriptor: fd)
        }
    }

    public override func releaseFile(atPath path: String, userData: Any!) {
        guard let fileHandle = userData as? FileHandle else {
            return
        }

        try? fileHandle.close()
    }

    public override func readFile(
        atPath path: String,
        userData: Any?,
        buffer: UnsafeMutablePointer<Int8>,
        size: Int,
        offset: off_t,
        error: NSErrorPointer
    ) -> Int32 {
        guard let fileHandle = userData as? FileHandle else {
            error?.pointee = NSError(posixErrorCode: EBADF)
            return -1
        }

        let byteCount = pread(fileHandle.fileDescriptor, buffer, size, offset)
        guard byteCount >= 0 else {
            error?.pointee = NSError(posixErrorCode: errno)
            return -1
        }
        
        return Int32(byteCount)
    }

    public override func writeFile(
        atPath path: String,
        userData: Any?,
        buffer: UnsafePointer<Int8>,
        size: Int,
        offset: off_t,
        error: NSErrorPointer
    ) -> Int32 {
        guard let fileHandle = userData as? FileHandle else {
            error?.pointee = NSError(posixErrorCode: EBADF)
            return -1
        }

        let byteCount = pwrite(fileHandle.fileDescriptor, buffer, size, offset)
        guard byteCount >= 0 else {
            error?.pointee = NSError(posixErrorCode: errno)
            return -1
        }
        
        return Int32(byteCount)
    }

    public override func preallocateFile(
        atPath path: String,
        userData: Any!,
        options: Int32,
        offset: off_t,
        length: off_t
    ) throws {
        guard let fileHandle = userData as? FileHandle else {
            throw NSError(posixErrorCode: EBADF)
        }

        var fstore = fstore_t()
        if options & ALLOCATECONTIG == 1 {
            fstore.fst_flags = UInt32(F_ALLOCATECONTIG)
        }
        if options & ALLOCATEALL == 1 {
            fstore.fst_flags = fstore.fst_flags & UInt32(ALLOCATEALL)
        }
        if options & ALLOCATEFROMPEOF == 1 {
            fstore.fst_posmode = F_PEOFPOSMODE
        } else if options & ALLOCATEFROMVOL == 1 {
            fstore.fst_posmode = F_VOLPOSMODE
        }
        fstore.fst_offset = offset
        fstore.fst_length = length
        
        guard fcntl(fileHandle.fileDescriptor, F_PREALLOCATE, &fstore) != -1 else {
            throw NSError(posixErrorCode: errno)
        }
    }

    // MARK: - Directory Contents

    public override func contentsOfDirectory(
        atPath path: String,
        includingAttributesForKeys keys: [FileAttributeKey]
    ) throws -> [DirectoryEntry] {
        let resolvedPath = rootPath.appending(path)
        
        return try FileManager.default
            .contentsOfDirectory(atPath: resolvedPath.string)
            .compactMap {
                guard let attributes = try? FileManager.default.attributesOfItem(
                    atPath: resolvedPath.appending($0).string
                ) else {
                    return nil
                }
                
                return DirectoryEntry(name: $0, attributes: attributes)
            }
    }

    // MARK: - Getting and Setting Attributes

    public override func attributesOfItem(
        atPath path: String,
        userData: Any?
    ) throws -> [FileAttributeKey: Any] {
        let resolvedPath = rootPath.appending(path)
        return try FileManager.default.attributesOfItem(atPath: resolvedPath.string)
    }

    public override func attributesOfFileSystem(
        forPath path: String
    ) throws -> [FileAttributeKey: Any] {
        let resolvedPath = rootPath.appending(path)

        var attributes = try FileManager.default.attributesOfFileSystem(forPath: resolvedPath.string)
        
        attributes[.systemSupportsExtendedDates] = true
        attributes[.systemSupportsSwapRenaming] = true
        attributes[.systemSupportsExclusiveRenaming] = true
        attributes[.systemSupportsSetVolumeName] = true
        attributes[.systemSupportsReadWriteNodeLocking] = true
        
        let resolvedUrl = URL(fileURLWithPath: resolvedPath.string, isDirectory: true)
        attributes[.systemSupportsCaseSensitiveNames] = try resolvedUrl
            .resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
            .volumeSupportsCaseSensitiveNames ?? true

        return attributes
    }

    public override func setAttributes(
        _ attributes: [FileAttributeKey: Any],
        ofItemAtPath path: String,
        userData: Any?
    ) throws {
        let resolvedPath = rootPath.appending(path)

        try withPlatformPath(resolvedPath) {
            if let offset = attributes[.size] as? Int64 {
                guard truncate($0, offset) == 0 else {
                    throw NSError(posixErrorCode: errno)
                }
            }
            
            if let flags = attributes[.flags] as? UInt32 {
                guard chflags($0, flags) == 0 else {
                    throw NSError(posixErrorCode: errno)
                }
            }
        }

        try FileManager.default.setAttributes(attributes, ofItemAtPath: resolvedPath.string)
    }

    public override func setAttributes(
        _ attributes: [FileAttributeKey: Any],
        ofFileSystemAtPath path: String
    ) throws {
        // Needed for FileAttributeKey.systemSupportsSetVolumeName
    }

    // MARK: - Extended Attributes

    public override func extendedAttributesOfItem(atPath path: String) throws -> [String] {
        let resolvedPath = rootPath.appending(path)
        
        return try withPlatformPath(resolvedPath) { platformPath in
            let byteCount = listxattr(platformPath, nil, 0, 0)
            guard byteCount >= 0 else {
                throw NSError(posixErrorCode: errno)
            }
            
            var data = Data(count: byteCount)
            try data.withUnsafeMutableBytes {
                guard listxattr(
                    platformPath,
                    $0.baseAddress,
                    $0.count,
                    XATTR_NOFOLLOW
                ) >= 0 else {
                    throw NSError(posixErrorCode: errno)
                }
            }
            
            return data
                .split(separator: 0)
                .compactMap {
                    guard var name = String(data: Data($0), encoding: .utf8) else {
                        return nil
                    }
                    
                    if name.hasPrefix("com.apple.") {
                        name = "org.apple." + name[name.index(name.startIndex, offsetBy: 10)...]
                    }
                    return name
                }
        }
    }

    public override func value(
        ofExtendedAttribute name: String,
        ofItemAtPath path: String,
        position: off_t
    ) throws -> Data {
        let resolvedPath = rootPath.appending(path)
        
        var name = name
        if name.hasPrefix("com.apple.") {
            name = "org.apple." + name[name.index(name.startIndex, offsetBy: 10)...]
        }

        return try withPlatformPath(resolvedPath) { platformPath in
            let byteCount = getxattr(platformPath, name, nil, 0, UInt32(position), XATTR_NOFOLLOW)
            guard byteCount >= 0 else {
                throw NSError(posixErrorCode: errno)
            }

            var data = Data(count: byteCount)
            try data.withUnsafeMutableBytes {
                guard getxattr(
                    platformPath,
                    name,
                    $0.baseAddress,
                    $0.count,
                    UInt32(position),
                    XATTR_NOFOLLOW
                ) > 0 else {
                    throw NSError(posixErrorCode: errno)
                }
            }
            return data
        }
    }

    public override func setExtendedAttribute(
        _ name: String,
        ofItemAtPath path: String,
        value: Data,
        position: off_t,
        options: Int32
    ) throws {
        let resolvedPath = rootPath.appending(path)
        
        var name = name
        if name.hasPrefix("com.apple.") {
            name = "org.apple." + name[name.index(name.startIndex, offsetBy: 10)...]
        }
        
        /*
         * Setting com.apple.FinderInfo happens in the kernel, so security related bits are set
         * in the options. We need to explicitly remove them or the call to setxattr will fail.
         * TODO: Why is this necessary?
         */
        let options = (options | XATTR_NOFOLLOW) & ~(XATTR_NOSECURITY | XATTR_NODEFAULT)
        
        try value.withUnsafeBytes { valuePointer in
            try withPlatformPath(resolvedPath) {
                guard setxattr(
                    $0,
                    name,
                    valuePointer.baseAddress,
                    valuePointer.count,
                    UInt32(position),
                    options
                ) == 0 else {
                    throw NSError(posixErrorCode: errno)
                }
            }
        }
    }

    public override func removeExtendedAttribute(_ name: String, ofItemAtPath path: String) throws {
        let resolvedPath = rootPath.appending(path)

        var name = name
        if name.hasPrefix("com.apple.") {
            name = "org.apple." + name[name.index(name.startIndex, offsetBy: 10)...]
        }

        try withPlatformPath(resolvedPath) {
            guard removexattr($0, name, XATTR_NOFOLLOW) >= 0 else {
                throw NSError(posixErrorCode: errno)
            }
        }
    }
}
