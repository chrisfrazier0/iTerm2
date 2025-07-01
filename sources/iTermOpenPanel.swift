//
//  iTermOpenPanel.swift
//  iTerm2
//
//  Created by George Nachman on 6/8/25.
//

@objc
class iTermOpenPanelItem: NSObject {
    @objc var urlPromise: iTermRenegablePromise<NSURL>
    @objc var filename: String
    @objc var isDirectory: Bool
    @objc var host: SSHIdentity
    @objc var progress: Progress
    @objc var cancellation: Cancellation

    init(urlPromise: iTermRenegablePromise<NSURL>,
         filename: String,
         isDirectory: Bool,
         host: SSHIdentity,
         progress: Progress,
         cancellation: Cancellation) {
        self.urlPromise = urlPromise
        self.filename = filename
        self.isDirectory = isDirectory
        self.host = host
        self.progress = progress
        self.cancellation = cancellation
    }
}

@objc
@MainActor
class iTermOpenPanel: NSObject {
    @objc var canChooseDirectories = true
    @objc var canChooseFiles = true
    @objc var includeLocalhost = true
    @objc let allowsMultipleSelection = true  // TODO
    @objc private(set) var items: [iTermOpenPanelItem] = []
    static var panels = [iTermOpenPanel]()
    var isSelectable: ((RemoteFile) -> Bool)?

    // Show the panel non-modally with a completion handler
    func begin(_ handler: @escaping (NSApplication.ModalResponse) -> Void) {
        Self.panels.append(self)

        if #available(macOS 11, *) {
            let sshFilePanel = SSHFilePanel()
            sshFilePanel.canChooseDirectories = canChooseDirectories
            sshFilePanel.canChooseFiles = canChooseFiles
            sshFilePanel.isSelectable = isSelectable
            sshFilePanel.includeLocalhost = includeLocalhost
            sshFilePanel.dataSource = ConductorRegistry.instance

            // Present non-modally
            sshFilePanel.begin { [weak self] response in
                guard let self else { return }
                if response == .OK {
                    items = sshFilePanel.promiseItems().map { item in
                        iTermOpenPanelItem(urlPromise: item.promise,
                                           filename: item.filename,
                                           isDirectory: item.isDirectory,
                                           host: item.host,
                                           progress: item.progress,
                                           cancellation: item.cancellation)
                    }
                } else {
                    items = []
                }
                handler(response)
                Self.panels.remove(object: self)
            }
        } else {
            let openPanel = NSOpenPanel()
            openPanel.allowsMultipleSelection = allowsMultipleSelection
            openPanel.canChooseDirectories = canChooseDirectories
            openPanel.canChooseFiles = canChooseFiles

            // Present non-modally
            openPanel.begin { [weak self] response in
                guard let self else { return }
                if response == .OK {
                    items = openPanel.urls.map { url in
                        let promise = iTermRenegablePromise<NSURL> { seal in
                            seal.fulfill(url as NSURL)
                        }
                        var isDirectory = ObjCBool(false)
                        _ = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                        return iTermOpenPanelItem(urlPromise: promise,
                                                  filename: url.path,
                                                  isDirectory: isDirectory.boolValue,
                                                  host: SSHIdentity.localhost,
                                                  progress: Progress(),
                                                  cancellation: Cancellation())
                    }
                } else {
                    items = []
                }
                handler(response)
                Self.panels.remove(object: self)
            }
        }
    }

    func beginSheetModal(for window: NSWindow,
                         completionHandler handler: @escaping (NSApplication.ModalResponse) -> Void) {
        Self.panels.append(self)

        if #available(macOS 11, *) {
            let sshFilePanel = SSHFilePanel()
            sshFilePanel.canChooseDirectories = canChooseDirectories
            sshFilePanel.canChooseFiles = canChooseFiles
            sshFilePanel.isSelectable = isSelectable
            sshFilePanel.includeLocalhost = includeLocalhost
            sshFilePanel.dataSource = ConductorRegistry.instance
            sshFilePanel.beginSheetModal(for: window) { [weak self] response in
                guard let self else { return }
                if response == .OK {
                    items = sshFilePanel.promiseItems().map { item in
                        iTermOpenPanelItem(urlPromise: item.promise,
                                           filename: item.filename,
                                           isDirectory: item.isDirectory,
                                           host: item.host,
                                           progress: item.progress,
                                           cancellation: item.cancellation)
                    }
                } else {
                    items = []
                }
                handler(response)
                Self.panels.remove(object: self)
            }
        } else {
            let openPanel = NSOpenPanel()
            openPanel.allowsMultipleSelection = allowsMultipleSelection
            openPanel.canChooseDirectories = canChooseDirectories
            openPanel.canChooseFiles = canChooseFiles

            openPanel.beginSheetModal(for: window) { [weak self] response in
                guard let self else { return }
                if response == .OK {
                    items = openPanel.urls.map { url in
                        let promise = iTermRenegablePromise<NSURL> { seal in
                            seal.fulfill(url as NSURL)
                        }
                        var isDirectory = ObjCBool(false)
                        _ = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                        return iTermOpenPanelItem(urlPromise: promise,
                                                  filename: url.path,
                                                  isDirectory: isDirectory.boolValue,
                                                  host: SSHIdentity.localhost,
                                                  progress: Progress(),
                                                  cancellation: Cancellation())
                    }
                } else {
                    items = []
                }
                handler(response)
                Self.panels.remove(object: self)
            }
        }
    }
}
