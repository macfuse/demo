//
//  main.swift
//  HelloFS
//
//  Created by Benjamin Fleischer on 09.10.25.
//

import Foundation
import macFUSE

let hello = (
    path: "hello.txt",
    attributes: [
        FileAttributeKey.type: FileAttributeType.typeRegular,
        FileAttributeKey.posixPermissions: 0o644
    ],
    contents: "Hello world\n".data(using: .utf8)
)

class Delegate: NSObject, UserFileSystem.Operations {
    func contentsOfDirectory(
        atPath path: String,
        includingAttributesForKeys keys: [FileAttributeKey]
    ) throws -> [DirectoryEntry] {
        [DirectoryEntry(name: hello.path, attributes: hello.attributes)]
    }
    
    func attributesOfItem(atPath path: String, userData: Any?) throws -> [FileAttributeKey: Any] {
        guard path == "/\(hello.path)" else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
        }
        return hello.attributes
    }
    
    func contents(atPath path: String) -> Data? {
        guard path == "/\(hello.path)" else {
            return nil
        }
        return hello.contents
    }
}

let delegate = Delegate()
let userFileSystem = UserFileSystem(delegate: delegate, isThreadSafe: true)

userFileSystem.mount(
    atPath: "/Volumes/hello",
    withOptions: ["rdonly", "volname=HelloFS"],
    shouldForeground: true,
    detachNewThread: false
)
