//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import ContainerizationError
import ContainerizationOS
import Foundation
import Logging
import Synchronization

/// Watches a directory for changes and invokes a handler when the contents change.
///
/// `DirectoryWatcher` uses `DispatchSource` file system events to monitor a directory.
/// If the target directory does not exist yet, it polls until the directory is created.
/// the target is created, then transitions to watching the target directly.
///
/// Example usage:
/// ```swift
/// let watcher = DirectoryWatcher(directoryURL: myURL, log: logger)
/// try watcher.startWatching { urls in
///     print("Directory contents changed: \(urls)")
/// }
/// ```
public actor DirectoryWatcher {
    public static let watchPeriod = Duration.seconds(1)

    /// The URL of the directory being watched.
    public let directoryURL: URL

    private var task: Task<Void, any Error>?
    private let monitorQueue: DispatchQueue
    private let source: Mutex<DispatchSourceFileSystemObject?>

    private let log: Logger?

    /// Creates a new `DirectoryWatcher` for the given directory URL.
    ///
    /// - Parameters:
    ///   - directoryURL: The URL of the directory to watch.
    ///   - log: An optional logger for diagnostic messages.
    public init(directoryURL: URL, log: Logger?) {
        self.directoryURL = directoryURL
        self.monitorQueue = DispatchQueue(label: "monitor:\(directoryURL.path)")
        self.log = log
        self.source = Mutex(nil)
    }

    /// Starts watching the directory for changes.
    ///
    /// - Parameters:
    ///   - handler: handler to run on directory state change.
    public func startWatching(handler: @Sendable @escaping ([URL]) throws -> Void) {
        self.task = Task {
            var exists: Bool
            var isDir: ObjCBool = false

            while true {
                do {
                    exists = FileManager.default.fileExists(atPath: self.directoryURL.path, isDirectory: &isDir)
                    if exists && isDir.boolValue && self.source.withLock({ $0 }) == nil {
                        try _startWatching(handler: handler)
                    }
                } catch {
                    log?.error("failed to start watching", metadata: ["error": "\(error)"])
                }

                try await Task.sleep(for: Self.watchPeriod)
            }
        }
    }

    private func _startWatching(
        handler: @escaping ([URL]) throws -> Void
    ) throws {
        let descriptor = open(directoryURL.path, O_EVTONLY)
        guard descriptor > 0 else {
            throw ContainerizationError(.internalError, message: "cannot open \(directoryURL.path), descriptor=\(descriptor)")
        }

        do {
            let files = try FileManager.default.contentsOfDirectory(atPath: directoryURL.path)
            try handler(files.map { directoryURL.appending(path: $0) })
        } catch {
            throw ContainerizationError(.internalError, message: "failed to run handler for \(directoryURL.path)")
        }

        log?.info("starting directory watcher", metadata: ["path": "\(directoryURL.path)"])

        let dispatchSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.delete, .write],
            queue: monitorQueue
        )

        dispatchSource.setCancelHandler {
            close(descriptor)
        }

        dispatchSource.setEventHandler { [weak self] in
            guard let self else { return }

            guard !dispatchSource.data.contains(.delete) else {
                dispatchSource.cancel()
                self.source.withLock { $0 = nil }
                return
            }

            do {
                let files = try FileManager.default.contentsOfDirectory(atPath: directoryURL.path)
                try handler(files.map { directoryURL.appending(path: $0) })
            } catch {
                self.log?.error(
                    "failed to run watch handler",
                    metadata: ["error": "\(error)", "path": "\(directoryURL.path)"])
            }
        }

        source.withLock { $0 = dispatchSource }
        dispatchSource.resume()
    }

    deinit {
        self.task?.cancel()
        source.withLock { $0?.cancel() }
    }
}
