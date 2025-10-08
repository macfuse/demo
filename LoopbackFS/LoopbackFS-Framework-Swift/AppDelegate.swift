//
//  AppDelegate.swift
//  LoopbackFS-Framework-Swift
//
//  Created by Gunnar Herzog on 27/01/2017.
//  Copyright © 2017 KF Interactive GmbH. All rights reserved.
//  Copyright © 2019-2025 Benjamin Fleischer. All rights reserved.
//

import Cocoa
import System

import macFUSE

private let mountPoint: FilePath = "/Volumes/loop"

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    private var notificationObservers: [NSObjectProtocol] = []

    private var delegate: LoopbackFS?
    private var userFileSystem: UserFileSystem?

    private func addNotifications() {
        let mountObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name(kGMUserFileSystemDidMount),
            object: nil,
            queue: nil
        ) { notification in
            print("Got didMount notification.")

            NSWorkspace.shared.selectFile(
                mountPoint.string,
                inFileViewerRootedAtPath: mountPoint.removingLastComponent().string
            )
        }

        let failedObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name(kGMUserFileSystemMountFailed),
            object: nil,
            queue: .main
        ) { notification in
            print("Got mountFailed notification.")

            guard let userInfo = notification.userInfo,
                  let error = userInfo[kGMUserFileSystemErrorKey] as? NSError else {
                return
            }

            print("kGMUserFileSystem Error: \(error), userInfo=\(error.userInfo)")

            let alert = NSAlert()
            alert.messageText = "Mount Failed"
            alert.informativeText = error.localizedDescription
            alert.runModal()

            NSApplication.shared.terminate(nil)
        }

        let unmountObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name(kGMUserFileSystemDidUnmount),
            object: nil,
            queue: nil
        ) { notification in
            print("Got didUnmount notification.")

            DispatchQueue.main.async {
                NSApplication.shared.terminate(nil)
            }
        }

        notificationObservers = [mountObserver, failedObserver, unmountObserver]
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/tmp")
        let returnValue = panel.runModal()

        guard returnValue != .cancel else {
            exit(0)
        }

        let rootPath = panel.urls.first?.withUnsafeFileSystemRepresentation {
            $0.map { FilePath(platformString: $0) }
        }
        guard let rootPath else {
            exit(0)
        }

        let delegate = LoopbackFS(rootPath: rootPath)
        let userFileSystem = UserFileSystem(delegate: delegate, isThreadSafe: false)

        /*
         * Do not use the 'native_xattr' mount-time option unless the underlying file system
         * supports native extended attributes. Typically, the user would be mounting an APFS
         * directory through LoopbackFS, so we do want this option in that case.
         */
        var options = ["native_xattr", "volname=LoopbackFS"]

        if let iconPath = Bundle.main.path(forResource: "LoopbackFS", ofType: "icns") {
            options.append("volicon=\(iconPath)")
        }

        addNotifications()
        userFileSystem.mount(atPath: mountPoint.string, withOptions: options)

        self.delegate = delegate
        self.userFileSystem = userFileSystem
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        notificationObservers.forEach {
            NotificationCenter.default.removeObserver($0)
        }
        notificationObservers.removeAll()

        if let userFileSystem {
            userFileSystem.unmount()
        }
        return .terminateNow
    }
}
