//
//  LoopbackFS.swift
//  LoopbackFS
//
//  Created by Gunnar Herzog on 27/01/2017.
//  Copyright © 2017 KF Interactive GmbH. All rights reserved.
//  Copyright © 2019-2025 Benjamin Fleischer. All rights reserved.
//

import Foundation

public final class LoopbackFS: NSObject {
    private let rootPath: String

    public init(rootPath: String) {
        self.rootPath = rootPath
    }

    // MARK: - Moving an Item

    public override func moveItem(atPath source: String, toPath destination: String, options: GMUserFileSystemMoveOption) throws {
        let sourcePath = (rootPath.appending(source) as NSString).utf8String!
        let destinationPath = (rootPath.appending(destination) as NSString).utf8String!

        var returnValue: Int32 = 0
        if options.rawValue == 0 {
            returnValue = rename(sourcePath, destinationPath)
        } else {
            if #available(OSX 10.12, *) {
                var flags: UInt32 = 0;
                if options.rawValue & GMUserFileSystemMoveOption.swap.rawValue != 0 {
                  flags |= UInt32(RENAME_SWAP);
                }
                if options.rawValue & GMUserFileSystemMoveOption.exclusive.rawValue != 0 {
                  flags |= UInt32(RENAME_EXCL);
                }
                returnValue = renamex_np(sourcePath, destinationPath, flags)
            } else {
                throw NSError(posixErrorCode: ENOTSUP);
            };
        }
        if returnValue < 0 {
            throw NSError(posixErrorCode: errno)
        }
    }

    // MARK: - Removing an Item

    public override func removeDirectory(atPath path: String) throws {
        // We need to special-case directories here and use the bsd API since
        // NSFileManager will happily do a recursive remove :-(

        let originalPath = (rootPath.appending(path) as NSString).utf8String!

        let returnValue = rmdir(originalPath)
        if returnValue < 0 {
            throw NSError(posixErrorCode: errno)
        }
    }

    public override func removeItem(atPath path: String) throws {
        let originalPath = rootPath.appending(path)

        return try FileManager.default.removeItem(atPath: originalPath)
    }

    // MARK: - Creating an Item

    public override func createDirectory(atPath path: String, attributes: [FileAttributeKey : Any] = [:]) throws {
        let originalPath = rootPath.appending(path)

        try FileManager.default.createDirectory(atPath: originalPath, withIntermediateDirectories: false, attributes: attributes)
    }

    public override func createFile(atPath path: String, attributes: [FileAttributeKey : Any], flags: Int32, userData: AutoreleasingUnsafeMutablePointer<AnyObject?>) throws {

        guard let mode = attributes[FileAttributeKey.posixPermissions] as? mode_t else {
            throw NSError(posixErrorCode: EPERM)
        }

        let originalPath = rootPath.appending(path)

        let fileDescriptor = open((originalPath as NSString).utf8String!, flags, mode)

        if fileDescriptor < 0 {
            throw NSError(posixErrorCode: errno)
        }

        userData.pointee = NSNumber(value: fileDescriptor)
    }

    // MARK: - Linking an Item

    public override func linkItem(atPath path: String, toPath otherPath: String) throws {
        let originalPath = (rootPath.appending(path) as NSString).utf8String!
        let originalOtherPath = (rootPath.appending(otherPath) as NSString).utf8String!

        // We use link rather than the NSFileManager equivalent because it will copy
        // the file rather than hard link if part of the root path is a symlink.
        if link(originalPath, originalOtherPath) < 0 {
            throw NSError(posixErrorCode: errno)
        }
    }

    // MARK: - Symbolic Links

    public override func createSymbolicLink(atPath path: String, withDestinationPath otherPath: String) throws {
        let sourcePath = rootPath.appending(path)
        try FileManager.default.createSymbolicLink(atPath: sourcePath, withDestinationPath: otherPath)
    }

    public override func destinationOfSymbolicLink(atPath path: String) throws -> String {
        let sourcePath = rootPath.appending(path)
        return try FileManager.default.destinationOfSymbolicLink(atPath: sourcePath)
    }

    // MARK: - File Contents

    public override func openFile(atPath path: String, mode: Int32, userData: AutoreleasingUnsafeMutablePointer<AnyObject?>) throws {
        let originalPath = (rootPath.appending(path) as NSString).utf8String!

        let fileDescriptor = open(originalPath, mode)

        if fileDescriptor < 0 {
            throw NSError(posixErrorCode: errno)
        }

        userData.pointee = NSNumber(value: fileDescriptor)
    }

    public override func releaseFile(atPath path: String, userData: Any!) {
        guard let num = userData as? NSNumber else {
            return
        }

        let fileDescriptor = num.int32Value
        close(fileDescriptor)
    }

    public override func readFile(atPath path: String, userData: Any?, buffer: UnsafeMutablePointer<Int8>, size: Int, offset: off_t, error: NSErrorPointer) -> Int32 {
        guard let num = userData as? NSNumber else {
            error?.pointee = NSError(posixErrorCode: EBADF)
            return -1
        }

        let fileDescriptor = num.int32Value
        let returnValue = Int32(pread(fileDescriptor, buffer, size, offset))

        if returnValue < 0 {
            error?.pointee = NSError(posixErrorCode: errno)
            return -1
        }
        return returnValue
    }

    public override func writeFile(atPath path: String, userData: Any?, buffer: UnsafePointer<Int8>, size: Int, offset: off_t, error: NSErrorPointer) -> Int32 {
        guard let num = userData as? NSNumber else {
            error?.pointee = NSError(posixErrorCode: EBADF)
            return -1
        }

        let fileDescriptor = num.int32Value

        let returnValue = pwrite(fileDescriptor, buffer, size, offset)
        if returnValue < 0 {
            error?.pointee = NSError(posixErrorCode: errno)
        }
        return Int32(returnValue)
    }

    public override func preallocateFile(atPath path: String, userData: Any!, options: Int32, offset: off_t, length: off_t) throws {
        guard let num = userData as? NSNumber else {
            throw NSError(posixErrorCode: EBADF)
        }

        let fileDescriptor = num.int32Value

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
        if fcntl(fileDescriptor, F_PREALLOCATE, &fstore) == -1 {
            throw NSError(posixErrorCode: errno)
        }
    }

    public override func exchangeDataOfItem(atPath path1: String, withItemAtPath path2: String) throws {
        let sourcePath = (rootPath.appending(path1) as NSString).utf8String!
        let destinationPath = (rootPath.appending(path2) as NSString).utf8String!

        let returnValue = exchangedata(sourcePath, destinationPath, 0)
        if returnValue < 0 {
            throw NSError(posixErrorCode: errno)
        }
    }

    // MARK: - Directory Contents

    public override func contentsOfDirectory(atPath path: String, includingAttributesForKeys keys: [FileAttributeKey]) throws -> [GMDirectoryEntry] {
        let originalPath = rootPath.appending(path)
        let contents = try FileManager.default.contentsOfDirectory(atPath: originalPath)

        var entries = [GMDirectoryEntry]()
        for name in contents {
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: originalPath.appending("/\(name)"))
                entries.append(GMDirectoryEntry(name: name, attributes: attributes))
            } catch {
                // Skip entry
            }
        }
        return entries
    }

    // MARK: - Getting and Setting Attributes

    public override func attributesOfItem(atPath path: String, userData: Any?) throws -> [FileAttributeKey : Any] {
        let originalPath = rootPath.appending(path)
        return try FileManager.default.attributesOfItem(atPath: originalPath)
    }

    public override func attributesOfFileSystem(forPath path: String) throws -> [FileAttributeKey : Any] {
        let originalPath = rootPath.appending(path)

        var attributes = try FileManager.default.attributesOfFileSystem(forPath: originalPath)
        attributes[FileAttributeKey(rawValue: kGMUserFileSystemVolumeSupportsExtendedDatesKey)] = true

        let originalUrl = URL(fileURLWithPath: originalPath, isDirectory: true)

        let volumeSupportsCaseSensitiveNames = try originalUrl.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames ?? true
        attributes[FileAttributeKey(rawValue: kGMUserFileSystemVolumeSupportsCaseSensitiveNamesKey)] = volumeSupportsCaseSensitiveNames

        attributes[FileAttributeKey(rawValue: kGMUserFileSystemVolumeSupportsSwapRenamingKey)] = true
        attributes[FileAttributeKey(rawValue: kGMUserFileSystemVolumeSupportsExclusiveRenamingKey)] = true

        attributes[FileAttributeKey(rawValue: kGMUserFileSystemVolumeSupportsSetVolumeNameKey)] = true

        attributes[FileAttributeKey(rawValue: kGMUserFileSystemVolumeSupportsReadWriteNodeLockingKey)] = true

        return attributes
    }

    public override func setAttributes(_ attributes: [FileAttributeKey : Any], ofItemAtPath path: String, userData: Any?) throws {
        let originalPath = rootPath.appending(path)

        if let pathPointer = (originalPath as NSString).utf8String {
            if let offset = attributes[FileAttributeKey.size] as? Int64 {
                let ret = truncate(pathPointer, offset)
                if ret < 0 {
                    throw NSError(posixErrorCode: errno)
                }
            }

            if let flags = attributes[FileAttributeKey(rawValue: kGMUserFileSystemFileFlagsKey)] as? Int32 {
                let rc = chflags(pathPointer, UInt32(flags))
                if rc < 0 {
                    throw NSError(posixErrorCode: errno)
                }
            }
        }

        try FileManager.default.setAttributes(attributes, ofItemAtPath: originalPath)
    }

    public override func setAttributes(_ attributes: [FileAttributeKey : Any], ofFileSystemAtPath path: String) throws {
        // Needed for kGMUserFileSystemVolumeSupportsSetVolumeNameKey
    }

    // MARK: - Extended Attributes

    public override func extendedAttributesOfItem(atPath path: String) throws -> [String] {
        let originalUrl = URL(fileURLWithPath: rootPath.appending(path))

        return try originalUrl.withUnsafeFileSystemRepresentation { fileSystemPath -> [String] in
            let length = listxattr(fileSystemPath, nil, 0, 0)
            guard length >= 0 else { throw NSError(posixErrorCode: errno) }

            // Create buffer with required size:
            var data = Data(count: length)

            // Retrieve attribute list:
            let count = data.count
            let result = data.withUnsafeMutableBytes {
                listxattr(fileSystemPath, $0.baseAddress?.assumingMemoryBound(to: Int8.self), count, XATTR_NOFOLLOW)
            }
            guard result >= 0 else { throw NSError(posixErrorCode: errno) }

            // Extract attribute names:
            let list = data.split(separator: 0).compactMap {
                guard var name = String(data: Data($0), encoding: .utf8) else {
                    return nil as String?
                }
                if name.hasPrefix("com.apple.") {
                    name = "org.apple." + name[name.index(name.startIndex, offsetBy: 10)...]
                }

                return name
            }
            return list
        }
    }

    public override func value(ofExtendedAttribute name: String, ofItemAtPath path: String, position: off_t) throws -> Data {
        let originalUrl = URL(fileURLWithPath: rootPath.appending(path))

        return try originalUrl.withUnsafeFileSystemRepresentation { fileSystemPath -> Data in
            var name = name
            if name.hasPrefix("com.apple.") {
                name = "org.apple." + name[name.index(name.startIndex, offsetBy: 10)...]
            }

            // Determine attribute size:
            let length = getxattr(fileSystemPath, name, nil, 0, UInt32(position), XATTR_NOFOLLOW)
            guard length >= 0 else {
                throw NSError(posixErrorCode: errno)
            }

            // Create buffer with required size:
            var data = Data(count: length)

            // Retrieve attribute:
            let count = data.count
            let result = data.withUnsafeMutableBytes {
                getxattr(fileSystemPath, name, $0.baseAddress?.assumingMemoryBound(to: Int8.self), count, UInt32(position), XATTR_NOFOLLOW)
            }
            guard result >= 0 else {
                throw NSError(posixErrorCode: errno)
            }
            return data
        }
    }

    public override func setExtendedAttribute(_ name: String, ofItemAtPath path: String, value: Data, position: off_t, options: Int32) throws {
        let originalUrl = URL(fileURLWithPath: rootPath.appending(path))

        try originalUrl.withUnsafeFileSystemRepresentation { fileSystemPath in
            // Setting com.apple.FinderInfo happens in the kernel, so security related
            // bits are set in the options. We need to explicitly remove them or the call
            // to setxattr will fail.
            // TODO: Why is this necessary?
            let newOptions = options & ~(XATTR_NOSECURITY | XATTR_NODEFAULT)

            var name = name
            if name.hasPrefix("com.apple.") {
                name = "org.apple." + name[name.index(name.startIndex, offsetBy: 10)...]
            }

            let result = value.withUnsafeBytes {
                setxattr(fileSystemPath, name, $0.baseAddress?.assumingMemoryBound(to: Int8.self), value.count, UInt32(position), newOptions | XATTR_NOFOLLOW)
            }
            guard result >= 0 else { throw NSError(posixErrorCode: errno) }
        }
    }

    public override func removeExtendedAttribute(_ name: String, ofItemAtPath path: String) throws {
        let originalUrl = URL(fileURLWithPath: rootPath.appending(path))

        try originalUrl.withUnsafeFileSystemRepresentation { fileSystemPath in
            var name = name
            if name.hasPrefix("com.apple.") {
                name = "org.apple." + name[name.index(name.startIndex, offsetBy: 10)...]
            }

            let result = removexattr(fileSystemPath, name, XATTR_NOFOLLOW)
            guard result >= 0 else { throw NSError(posixErrorCode: errno) }
        }
    }
}
